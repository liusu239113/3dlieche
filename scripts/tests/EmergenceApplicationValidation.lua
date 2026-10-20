-- 真 main 入口双模式 E2E；基于 ApplicationValidation 的生命周期/触摸/存档保护脚手架。
-- 默认内存文件fixture：只在同步Save.Load/Write期间替换File，仍执行生产SaveStore校验。
-- 不打开/覆写玩家railway_autosave_v1.json，不请求真实云；main.Stop也在隔离期内执行。
-- 不构造替代 Scene/Train/Traffic，不改业务模块；只注入受控时间步、正常列车恢复坐标。
-- Q/E 使用明确标注的 keyboardPollingInjection（非硬件输入），随后执行真实 HandleKeyboard。
-- 截图仅供内部检查。headless 自动关闭截图；也可传 -emergence-no-capture。
require "main"
local mainStart,mainUpdate,mainPost,mainStop=Start,HandleUpdate,HandlePostUpdate,Stop
local mainKeyboard=HandleKeyboard
local UI=require "urhox-libs/UI"
local Menu=require "ui.Menu"
local Hud=require "ui.Hud"
local Modes=require "config.GameModes"
local Config=require "config.GameConfig"
local Catalog=require "config.TrainCatalog"
local Train=require "train.Train"
local Camera=require "train.Camera"
local Route=require "world.Route"
local Rail=require "world.RailNetwork"
local Environment=require "world.Environment"
local NightLighting=require "world.NightLighting"
local Passenger=require "game.PassengerService"
local Game=require "game.Game"
local Traffic=require "game.Traffic"
local TrafficVisuals=require "game.TrafficVisuals"
local Save=require "game.SaveStore"
local RageAudio=require "audio.RageAudio"
local Soundscape=require "audio.Soundscape"

local PATH="railway_autosave_v1.json"
local MOUNTAIN_ID="rage_mountain_corridor_v2"
local MOUNTAIN_LENGTH=133589.41090064118
local PREFIX="[EmergenceApplicationValidation] "
local PERSISTED_STATS={"score","impacts","playerImpacts","npcImpacts","chains","maxChain","launches","landings"}
local originalSetCloud,originalReadCloud=Save.SetCloud,Save.ReadCloud
local originalLoad,originalWrite=Save.Load,Save.Write
local started_,cleaned_=false,false
local memoryText_,memoryWrites_="",0
local legacyNormal_=false
local migrationMode_="rage"
local normalStationTable_={} ---@type table
local normalSegments_={} ---@type table
local failed_,complete_,captureEnabled_=false,false,true
local cloudRequests_,cloudReads_,checks_,frames_,stageFrame_=0,0,0,0,0
local stage_,pendingCapture_="menu",""
local rageSnapshot_,normalSnapshot_={},{} ---@type table,table
-- GameModes.Apply会换整张十站地图表；先固定normal真源，再比较rage->normal引用恢复。
Modes.Apply("normal")
local normalMode_=Modes.Get("normal")
normalStationTable_=Config.Stations
normalSegments_=Config.RouteSegments
local normalSeed_=Config.WorldStream.Seed
---@type {index:integer, geometry:RailwayRoutingSection?}
local routeFixture_={index=0}
local collisionFixture_={} ---@type table
local legacyFixture_={} ---@type table
local unknownRoute_,unknownSave_,legacyNoRoute_,migrationOnly_=false,false,false,false
local unknownNormal_=false
local seedText_=""
local slopeS_=0.0
local stableSeconds_=0.0
local originalCloud_=clientCloud
local cloudGuardCalls_=0
---@type NVGContextWrapper?
local uiContext_=nil
local startedAt_=os.clock()
local screenshotCount_=0
local captureFocusId_=""
---@type StaticModel?
local captureFocusDrawable_=nil

local function check(condition,message)
    checks_=checks_+1
    assert(condition,PREFIX..message)
end
local function near(actual,expected,message,tolerance)
    check(type(actual)=="number" and type(expected)=="number" and math.abs(actual-expected)<(tolerance or .0001),
        message..string.format("（actual=%s expected=%s）",tostring(actual),tostring(expected)))
end
local function copy(value) return cjson.decode(cjson.encode(value)) end
local function transition(name)
    stage_,stageFrame_=name,frames_
    print(PREFIX.."stage="..name.." frame="..frames_)
end
local function elapsedFrames() return frames_-stageFrame_ end

-- 仅SaveStore同步函数作用域替换文件API；其他引擎/资源加载仍使用真实File。
local function memoryIO(action)
    local realFile,realSystem=File,fileSystem
    local function fixtureFile(path,mode)
        assert(path==PATH,PREFIX.."内存fixture越界："..tostring(path))
        local handle={
            IsOpen=function() return true end,
            ReadString=function() assert(mode==FILE_READ);return memoryText_ end,
            WriteString=function(_,text)
                assert(mode==FILE_WRITE);memoryText_=text;memoryWrites_=memoryWrites_+1;return true
            end,
            Dispose=function() end,
        }
        -- 仅适配SaveStore确实用到的File接口；未实现的方法调用会直接失败。
        return handle --[[@as File]]
    end
    File=fixtureFile
    fileSystem={FileExists=function(_,path) assert(path==PATH);return true end} --[[@as FileSystem]]
    local ok,result=xpcall(action,debug.traceback)
    File,fileSystem=realFile,realSystem
    assert(ok,result)
    return result
end

-- 成功、失败、Runtime正常Stop均在隔离期内运行生产Stop，然后恢复函数映射。
local function cleanup()
    if cleaned_ then return end
    cleaned_=true
    local stopOK,stopError=pcall(function() if started_ then mainStop() end end)
    Save.SetCloud,Save.ReadCloud=originalSetCloud,originalReadCloud
    Save.Load,Save.Write=originalLoad,originalWrite
    _G.clientCloud=originalCloud_
    print(string.format(PREFIX.."MEMORY_FIXTURE_CLEANED interceptedWrites=%d cloudRequested=%d interceptedCloudReads=%d playerSaveIO=0 externalCloudCalls=0",
        memoryWrites_,cloudRequests_,cloudReads_))
    if not stopOK then failed_=true;log:Write(LOG_ERROR,PREFIX.."main.Stop失败："..tostring(stopError)) end
end
local function guard(action)
    if failed_ or complete_ then return end
    local ok,message=xpcall(action,debug.traceback)
    if not ok then
        failed_=true
        log:Write(LOG_ERROR,tostring(message))
        cleanup()
        engine:Exit()
    end
end

---@param root Widget
---@param id string
---@param scrollId? string
local function tap(root,id,scrollId)
    UI.Layout()
    local control=assert(root:FindById(id),PREFIX.."缺少真实控件："..id)
    local scroll=root:FindById(scrollId or "menuScroll") --[[@as ScrollView?]]
    if scroll then
        scroll:UpdateContentSize()
        local r=control:GetAbsoluteLayoutForHitTest()
        local bounds=scroll:GetAbsoluteLayoutForHitTest()
        if r.y<bounds.y or r.y+r.h>bounds.y+bounds.h then
            scroll:ScrollBy(0,r.y+r.h*.5-bounds.y-bounds.h*.5)
            UI.Layout()
        end
    end
    local r=control:GetAbsoluteLayoutForHitTest()
    check(r.w>0 and r.h>0,"按钮实际布局为空："..id)
    check(UI.FindWidgetAt(r.x+r.w*.5,r.y+r.h*.5)==control,"真实触摸未命中按钮："..id)
    local x,y=(r.x+r.w*.5)*UI.GetScale(),(r.y+r.h*.5)*UI.GetScale()
    UI.InputAdapter.HandleTouchBegin(918,x,y,.5)
    UI.InputAdapter.HandleTouchEnd(918,x,y)
    print(PREFIX.."REAL_TOUCH "..id)
end

-- Input没有原生按键注入API；只在真实keyboard处理函数的一次调用内替换polling源。
-- 不替换Game.SetSwitch/Rail.SetPlayerChoice/Train采样，不声称覆盖操作系统硬件输入。
---@param key Key
local function pressKey(key)
    local hardware=input
    _G.input={
        GetKeyPress=function(_,candidate) return candidate==key end,
        GetKeyDown=function() return false end,
    }
    local ok,message=xpcall(function() mainKeyboard(.02) end,debug.traceback)
    _G.input=hardware
    assert(ok,message)
    print(PREFIX.."keyboardPollingInjection=true key="..tostring(key))
end

---@param dt number
local function step(dt)
    local event=VariantMap();event["TimeStep"]=Variant(dt)
    mainUpdate("Update",event --[[@as UpdateEventData]])
end
---@param count integer
local function simulate(count)
    for _=1,count do step(.02) end
end

local function assertNoScene(message)
    check(GetGameScene()==nil and renderer.numViewports==0,message.."意外创建/保留Scene或viewport")
end
local function assertMode(id)
    check(GetGameMode()==id and Modes.GetId()==id and Modes.IsRage()==(id=="rage"),"模式真源不一致："..id)
    local scene=assert(GetGameScene(),PREFIX.."真实main Scene不存在")
    check(renderer.numViewports==1 and Train.GetRoot()~=nil and assert(Train.GetRoot()).scene==scene,
        "当前列车/viewport不属于main真实Scene")
    check(Train.GetCarCount()==8,"玩家编组不是八节")
    check(Train.ValidateBindings(),"玩家八节实际MDL/材质绑定失败")
    check(UI.GetNVGContext()==uiContext_,"切页/重建世界意外重建UI上下文")
end
local function beginMode(id,resume)
    check(GetApplicationState()=="menu" and Menu.GetPage()=="menu","模式选择未从主菜单开始")
    tap(assert(Menu.GetRoot()),"startGame")
    check(Menu.GetPage()=="modes" and GetApplicationState()=="menu","开始按钮没有先打开模式页")
    assertNoScene("模式页")
    tap(assert(Menu.GetRoot()),(resume and "continueMode_" or "selectMode_")..id)
    check(GetApplicationState()=="loading" and GetGameMode()==id,"模式卡片未触发真实指定模式加载")
end
local function returnMenu()
    local root=assert(Hud.GetRoot())
    if not Hud.GetReadings().operationsExpanded then tap(root,"toggleOperations") end
    tap(root,"returnMainMenu","operationsDetails")
    check(GetApplicationState()=="menu" and Menu.GetPage()=="menu","HUD返回没有进入主菜单")
    assertNoScene("返回主菜单")
end
local function snapshot()
    check(SaveJourneyNow(),"真实main旅程保存失败")
    local data=assert(Save.Get())
    local mode=GetGameMode()
    check(data.journey.mode==mode and data.journeys[mode].mode==mode,"存档缺少正确的模式槽位")
    check(data.journeys[mode].routeId==Modes.Get(mode).routeId,"模式槽位没有独立的地图版本routeId")
    if mode=="rage" then
        check(data.journey.routeId==MOUNTAIN_ID,"新山图保存成旧狂暴routeId")
        check(data.journey.legacyRouteBackup and data.journey.legacyRouteBackup.train.s==legacyFixture_.train.s,
            "保存新山图丢失旧地图原始备份")
    end
    -- 重新解码生产SaveStore实际写出的内存字节，不能只比较Save.Get的引用。
    check(memoryWrites_>0,"生产SaveStore没有写出fixture")
    local decoded=cjson.decode(memoryText_)
    near(decoded.journeys[mode].train.s,Train.GetS(),"磁盘槽位坐标与真实列车不一致")
    return copy(decoded.journeys[mode])
end
local function assertStats(actual,expected,message)
    check(type(actual)=="table" and type(expected)=="table",message.."统计不存在")
    for _,key in ipairs(PERSISTED_STATS) do near(actual[key],expected[key],message.."统计混入/丢失："..key) end
end
local function assertRestored(saved,id)
    assertMode(id)
    near(Train.GetS(),saved.train.s,id.."恢复真实弧长错误",.001)
    near(Train.GetDistanceTravelled(),saved.train.distanceTravelled,id.."累计里程丢失",.001)
    near(Game.GetXp(),saved.game.xp,id.."运营经验串档")
    near(Game.GetElapsed(),saved.game.elapsed,id.."运营时间串档",.001)
    check(Hud.GetReadings().paused,id.."读档未安全暂停")
    check(Train.GetSelectedId()==saved.train.id and Camera.GetMode()==saved.camera,id.."车型/机位恢复错误")
    near(Environment.Export().hour,saved.environment.hour,id.."环境时刻串档")
    check(saved.routeId==Modes.Get(id).routeId,id.."恢复时地图routeId不匹配")
    check(Train.GetHeadlightMode()==saved.train.headlightMode,id.."车灯模式读档丢失")
    for _,car in ipairs(Train.GetCars()) do
        local front=Train.GetTrackSample(Train.GetS()+car.offset+car.pivot)
        local rear=Train.GetTrackSample(Train.GetS()+car.offset-car.pivot)
        near((car.node.worldPosition-(front+rear)*.5):Length(),0,id.."暂停恢复后真实车节仍留在旧主线路径",.015)
        check((car.node.worldRotation*Vector3.FORWARD):DotProduct((front-rear):Normalized())>.9999,
            id.."暂停恢复后真实车体朝向未匹配存档路径")
    end
    if id=="rage" then
        check(Rail.GetChoices()[routeFixture_.index].lane==2 and Rail.GetChoices()[routeFixture_.index].locked,
            "侧线暂停读档没有恢复车下真实锁定进路")
        assertStats(Traffic.ExportRageState(),saved.game.rageStats,"rage恢复")
        check(not Game.GetDepartureStatus().blocked and not Game.IsDwelling(),"rage读档进入普通客运联锁")
    else
        check(Traffic.GetRageStats()==nil and Game.ExportState().rageStats==nil,"normal泄漏狂暴统计")
        near(Passenger.GetStatus().onboard,#saved.passengers.onboard,"normal乘客数恢复错误")
        near(Passenger.GetStats().boarded,saved.passengers.boarded,"normal登乘统计恢复错误")
        near(Passenger.GetStats().alighted,saved.passengers.alighted,"normal下车统计恢复错误")
    end
end

-- fixture只恢复玩家合法状态，不写NPC/内部碰撞状态。按文档几何取入口，不硬编码岔长。
local function setTrainPosition(s,velocity)
    local state=Train.ExportState()
    state.s,state.v,state.throttle,state.brake=s,velocity or 0,0,0
    state.reversing,state.moving,state.derailed=false,(velocity or 0)~=0,false
    state.topology={mode=Rail.GetTopologyMode(),baseLane=0}
    Train.RestoreState(state)
end
local function assertRealMixedModels()
    local scene=assert(GetGameScene())
    local root=assert(scene:GetChild("RageTraffic"),PREFIX.."混合Traffic实际渲染子树缺失")
    local found={} ---@type table<string,boolean>
    local count=0
    for _,drawable in ipairs(root:GetComponents("StaticModel",true)) do
        if drawable:IsEnabledEffective() and drawable.node.name~="TrafficWarmMarker" then
            local model=assert(drawable.model,PREFIX.."Traffic实际Model为空")
            local matched=false
            for profile,asset in pairs(Catalog.Assets) do
                if asset.modelPath==model.name then
                    found[profile],matched=true,true
                    for geometry=0,model.numGeometries-1 do
                        local material=assert(drawable:GetMaterial(geometry),PREFIX.."Traffic真实材质为空")
                        check(material:GetTexture(TU_DIFFUSE)==cache:GetResource("Texture2D",asset.diffusePath),
                            "Traffic真实漫反射贴图不是对应成品："..profile)
                        check(material:GetTexture(TU_NORMAL)==cache:GetResource("Texture2D",asset.normalPath),
                            "Traffic真实法线贴图不是对应成品："..profile)
                    end
                    break
                end
            end
            check(matched,"Traffic用非目录模型/程序替代体冒充混合车流："..model.name)
            count=count+1
        end
    end
    local distinct=0
    for _ in pairs(found) do distinct=distinct+1 end
    local fleetTypes=0
    for _,entry in ipairs(Catalog.Entries) do
        local head=entry.roles and entry.roles.head.profile or entry.head
        local middle=entry.kind=="emu" and (entry.roles and entry.roles.middle.profile or entry.middle) or entry.id.."_coach"
        if found[head] or found[middle] then
            check(found[head] and found[middle],"近场可见正式编组头/中车节不完整："..entry.id)
            fleetTypes=fleetTypes+1
        end
    end
    local stats=assert(Traffic.GetRageStats())
    -- 六型目录可用于逻辑调度，但1850m内不强迫六型同帧出现；否则会反向破坏正常八节安全车距。
    local scheduled={}
    for _,vehicle in ipairs(Traffic.GetTrains()) do scheduled[vehicle.modelId]=true end
    for _,entry in ipairs(Catalog.Entries) do check(scheduled[entry.id],"真实混合调度遗漏车型："..entry.id) end
    check(count>=8 and count%8==0 and fleetTypes>=1 and stats.modelTypes>=6,
        "近场实际完整八节正式MDL/六型逻辑调度缺失")
    check(stats.errors==0 and stats.sharedResources and stats.visible<=stats.maxVisible,"混合交通资源错误或突破渲染预算")
    print(string.format(PREFIX.."REAL_MIXED_RESOURCES models=%d profiles=%d fleetTypes=%d visible=%d",count,distinct,fleetTypes,stats.visible))
end
local function assertNight()
    local atmosphere=Environment.GetStatus()
    check(atmosphere.hour==22 and not atmosphere.running and atmosphere.lampFactor>.95,"Environment夜间真源配置未生效")
    local scene=assert(GetGameScene())
    local pool=assert(scene:GetChild("NightLightingPool"),PREFIX.."真实夜灯池节点缺失")
    local enabled=0
    for _,light in ipairs(pool:GetComponents("Light",true)) do
        check(light.lightType==LIGHT_POINT and light.punctualLight and not light.castShadows,"夜灯池不是固定预算普通点光")
        if light:IsEnabledEffective() then
            check(light.brightness>0 and light.range>0,"夜灯启用但没有实际照明强度/范围")
            enabled=enabled+1
        end
    end
    local diagnostics=NightLighting.GetStats()
    check(diagnostics.sites>0 and diagnostics.stationSites>0 and diagnostics.roadSites>0,"真实世界未注册站台/道路灯位")
    check(enabled>0 and enabled==diagnostics.activeStation+diagnostics.activeRoad,"真实启用Light与诊断不一致")
    check(diagnostics.poolLights<=28,"夜灯Light节点超过固定池预算")
    local headlights=0
    for _,light in ipairs(assert(Train.GetRoot()):GetComponents("Light",true)) do
        if light:IsEnabledEffective() and light.lightType==LIGHT_SPOT and light.brightness>0 then headlights=headlights+1 end
    end
    check(headlights>=1,"夜间真实玩家前灯未启用")
    print(string.format(PREFIX.."REAL_NIGHT_LIGHTS enabled=%d pool=%d head=%d",enabled,diagnostics.poolLights,headlights))
end

-- 只给真实飞行车节取证：保留生产Camera.Update，再在PostUpdate末尾临时定点观察。
-- 不增建Scene/模型、不改物理/节点姿态；按实际drawable包围盒确认整车处于视锥。
local function focusFlyingForCapture()
    if not captureEnabled_ or captureFocusId_=="" then return end
    local target=nil ---@type table?
    for _,car in ipairs(Traffic.GetRageCars()) do
        if car.id==captureFocusId_ then target=car;break end
    end
    local car=assert(target,PREFIX.."近景真实飞行车节丢失")
    check(car.state=="flying","近景捕获目标已不在飞行状态")
    local root=assert(assert(GetGameScene()):GetChild("RageTraffic"))
    local selected=nil ---@type StaticModel?
    local distance=math.huge
    for _,drawable in ipairs(root:GetComponents("StaticModel",true)) do
        if drawable:IsEnabledEffective() and drawable.node.name~="TrafficWarmMarker" then
            local offset=(drawable.worldBoundingBox.center-car.position):Length()
            if offset<distance then selected,distance=drawable,offset end
        end
    end
    local drawable=assert(selected,PREFIX.."飞行状态没有实际启用的正式车节Model")
    check(distance<5,"实际Model包围盒没有跟随真实飞行质心")
    captureFocusDrawable_=drawable
    local camera=assert(Camera.GetCamera())
    local node=assert(Camera.GetNode())
    local heading=Train.GetCars()[1].node.worldRotation
    local eye=car.position+heading*Vector3(48,22,-12)
    node.worldPosition=eye
    check(node:LookAt(car.position,Vector3.UP,TS_WORLD),"飞行近景LookAt失败")
    camera.fov=46
    local bounds=drawable.worldBoundingBox
    for _,x in ipairs({bounds.min.x,bounds.max.x}) do
        for _,y in ipairs({bounds.min.y,bounds.max.y}) do
            for _,z in ipairs({bounds.min.z,bounds.max.z}) do
                local point=Vector3(x,y,z)
                local localPoint=node:WorldToLocal(point)
                local projected=camera:WorldToScreenPoint(point)
                check(localPoint.z>0 and projected.x>.06 and projected.x<.94 and projected.y>.12 and projected.y<.90,
                    "真实飞行车体未完整进入相机中央视锥")
            end
        end
    end
end

local function post()
    local event=VariantMap();event["TimeStep"]=Variant(.02)
    mainPost("PostUpdate",event --[[@as PostUpdateEventData]])
end
local function readSeed() return memoryText_ end
local function sameTree(actual,expected,message)
    if type(expected)~="table" then check(actual==expected,message);return end
    check(type(actual)=="table",message.."类型不一致")
    for key,value in pairs(expected) do sameTree(actual[key],value,message.."."..tostring(key)) end
    for key in pairs(actual) do check(expected[key]~=nil,message.."多出字段："..tostring(key)) end
end
local function finish(label)
    check(cloudGuardCalls_==0,"越过Save拦截触及云接口")
    cleanup()
    check(not failed_,"清理或存档恢复失败")
    complete_=true
    print(string.format("%s checks=%d frames=%d screenshots=%d realMain=true realTouch=true keyboardPollingInjection=true externalCloudCalls=0 gpuPixelsValidated=false audibleValidated=false",
        label,checks_,frames_,screenshotCount_))
    engine:Exit()
end
local function assertMigration()
    local mode=migrationMode_
    local target=Modes.Get(mode).routeId
    near(Train.GetS(),assert(Route.GetStations()[1]).s+1,"旧地图坐标没有迁到新地图始发",.001)
    near(Train.GetSpeedKmh(),0,"迁移后仍继承旧速度")
    check(Hud.GetReadings().paused and Train.GetThrottle()==0 and Train.GetBrake()==1,"旧地图迁移没有安全停稳暂停")
    check(not Train.IsReversing() and Rail.GetBaseLane()==0,"旧地图方向/上行拓扑错误地套用新图")
    near(Train.GetDistanceTravelled(),legacyFixture_.train.distanceTravelled,"迁移丢失累计驾驶里程")
    local actual=Game.ExportState()
    for _,key in ipairs({"xp","elapsed","completedTrips","rewardedStops","passengerPoints"}) do
        near(actual[key],legacyFixture_.game[key],"迁移丢失累计成绩："..key)
    end
    if mode=="rage" then
        assertStats(actual.rageStats,legacyFixture_.game.rageStats,"旧地图迁移")
        check(actual.timetable==nil and #actual.rewarded==0 and actual.nextIndex==2,
            "rage迁移沿用旧站序时刻表/奖励状态")
    else
        check(#Route.GetStations()==10 and Config.RouteId==target,"normal迁移不是十站山海新地图")
        near(Route.GetLength(),Modes.Get("normal").routeLength,"normal迁移长度不匹配",.001)
        check(actual.nextIndex==1 and Game.IsDwelling() and Passenger.HasActiveStop(),"normal迁移未重新始发登乘")
        check(actual.timetable~=nil and actual.rageStats==nil,"normal迁移没有新时刻表或泄漏rage")
    end
    local saved=assert(Save.Get()).journeys[mode]
    check(saved.routeId==target,"迁移未持久化新地图routeId")
    sameTree(saved.legacyRouteBackup,legacyFixture_,"legacyRouteBackup必须完整保留旧journey")
    print(PREFIX.."LEGACY_MIGRATION_PASS mode="..mode.." source="..tostring(legacyFixture_.routeId).." target="..saved.routeId)
end
local function assertMountain()
    near(Route.GetLength(),MOUNTAIN_LENGTH,"新凌岳天路真实长度错误",.001)
    check(Config.RouteId==MOUNTAIN_ID and Modes.Get().routeId==MOUNTAIN_ID and Modes.Get().routeName=="凌岳天路",
        "实际地图不是rage_mountain_corridor_v2凌岳天路")
    local high,low,maxGrade,negative=0.0,math.huge,0.0,false
    for s=100,Route.GetLength()-100,125 do
        local position,tangent=Route.Sample(s)
        local horizontal=math.sqrt(tangent.x*tangent.x+tangent.z*tangent.z)
        local grade=tangent.y/horizontal
        near(position.y,Route.HeightAt(s),"山图Route.Sample与设计高程不一致",.002)
        near(grade,Route.GradeAt(s),"山图真实3D切线没有匹配纵坡",.00005)
        high,low=math.max(high,position.y),math.min(low,position.y)
        negative=negative or grade<-.015
        if grade>maxGrade then maxGrade,slopeS_=grade,s end
    end
    check(high-low>1000 and maxGrade>.035 and negative,"新路线只是平面地图/没有真实上下山纵坡")
    print(string.format(PREFIX.."MOUNTAIN_GEOMETRY length=%.6f elevationRange=%.3f maxGrade=%.6f slopeFixture=%.3f",
        Route.GetLength(),high-low,maxGrade,slopeS_))
end
local function assertDriveStatus()
    local drive=Hud.GetDriveStatus()
    local position,tangent=Train.GetTrackSample(Train.GetS())
    local horizontal=math.sqrt(tangent.x*tangent.x+tangent.z*tangent.z)
    near(drive.grade,tangent.y/horizontal,"main没有将真实坡度传给Hud.SetDriveStatus",.00001)
    near(drive.elevation,position.y,"main没有将真实海拔传给Hud.SetDriveStatus",.002)
    local diagnostics=Train.GetHeadlightDiagnostics()
    check(drive.headlightMode==Train.GetHeadlightMode() and drive.headlightOn==diagnostics.enabled,
        "HUD灯mode/开关不是Train真实状态")
    local music=Soundscape.GetDiagnostics()
    check(drive.musicTitle==music.title and drive.musicEnabled==false and drive.musicState=="disabled",
        "音乐关闭时HUD虚报播放/曲目状态")
end
local function assertStableTraffic()
    local stats=assert(Traffic.GetRageStats())
    check(stats.formationCars==8 and stats.playerCausalOnly and stats.minHeadway>=95,"狂暴不是正常八节安全交通")
    check(stats.impacts==0 and stats.playerImpacts==0 and stats.npcImpacts==0 and stats.launches==0
        and stats.airborne==0 and stats.score==0,"未接触玩家时NPC自主乱撞/刷分")
    local active=0
    for _,vehicle in ipairs(Traffic.GetTrains()) do
        check(vehicle.carCount==8,"NPC正常编组不是八节："..vehicle.id)
        check((vehicle.dir==1 and (vehicle.lane==0 or vehicle.lane==2))
            or (vehicle.dir==-1 and (vehicle.lane==1 or vehicle.lane==5)),"NPC无玩家接触随机逆行")
        if vehicle.active then
            active=active+1
            check(vehicle.airborne==0 and vehicle.wrecks==0 and vehicle.damagedAt<0,"NPC无接触自行脱轨")
        end
    end
    check(active>=8,"正常高密车流意外全部退出")
    local onRail=0
    for _,car in ipairs(Traffic.GetRageCars()) do
        if car.active then check(car.state=="rail","正常巡航车节自行飞散");onRail=onRail+1 end
    end
    check(onRail==active*8,"八节实际车节数与车辆快照不一致")
end

function Start()
    guard(function()
        for _,argument in ipairs(GetArguments()) do
            if argument=="-graphicsheadless" or argument=="-emergence-no-capture" then captureEnabled_=false end
            if argument=="-emergence-unknown-route" then unknownRoute_=true end
            if argument=="-emergence-unknown-normal" then unknownNormal_,unknownRoute_=true,true end
            if argument=="-emergence-unknown-save" then unknownSave_=true end
            if argument=="-emergence-legacy-no-route" then legacyNoRoute_=true end
            if argument=="-emergence-migration-only" then migrationOnly_=true end
            if argument=="-emergence-legacy-normal" then legacyNormal_,migrationOnly_=true,true end
        end
        migrationMode_=legacyNormal_ and "normal" or "rage"
        -- 在main.Load前隔离历史设置/损坏档；cloud=true专门证明现有云开关也无法越过拦截。
        legacyFixture_={mode="rage",routeId=legacyNoRoute_ and nil or "rage_long_corridor_v1",
            train={id=Catalog.DefaultId,s=58432.75,v=-53,throttle=4,brake=0,reversing=true,moving=true,
                distanceTravelled=98765.25,headlightMode="auto",topology={mode=Rail.GetTopologyMode(),baseLane=1}},
            game={mode="rage",xp=4321,elapsed=987,completedTrips=7,rewardedStops=9,passengerPoints=123,
                state="driving",nextIndex=5,rewarded={2,4},timetable=nil,
                rageStats={version=1,seed=12345,kinds={},score=1050,impacts=5,playerImpacts=2,npcImpacts=3,
                    chains=2,maxChain=8,launches=12,landings=12}},
            choices={{index=2,lane=2}},camera="distant",passengers={oldMapMarker="must-not-restore"},
            environment={hour=22,running=false,weather="rain"},unknownLegacyField={keep="verbatim"}}
        if legacyNormal_ then
            legacyFixture_.mode="normal";legacyFixture_.game.mode="normal"
            legacyFixture_.routeId="normal_corridor_v1"
        end
        if legacyNoRoute_ then legacyFixture_.routeId=nil end
        if unknownRoute_ then legacyFixture_.routeId="rage_future_unknown_v9000" end
        if unknownNormal_ then
            legacyFixture_.mode="normal";legacyFixture_.game.mode="normal"
            legacyFixture_.routeId="normal_corridor_v3"
        end
        local isolated={version=unknownSave_ and 9000 or 1,settings={cloud=true,quality="medium",sound=false,music=false,
            environment={hour=12,running=false,weather="clear"}},journey=legacyFixture_,journeys={}}
        isolated.journeys[legacyFixture_.mode]=legacyFixture_
        seedText_=cjson.encode(isolated)
        memoryText_=seedText_
        Save.Load=function() return memoryIO(originalLoad) end
        Save.Write=function(data,cloud) return memoryIO(function() return originalWrite(data,cloud) end) end
        -- 二重防护：即使生产意外绕过Save facade也在本地fail loud，不能真实云外调。
        _G.clientCloud=setmetatable({}, {__index=function(_,key)
            return function() cloudGuardCalls_=cloudGuardCalls_+1;error("禁止真实云接口："..tostring(key)) end
        end})
        Save.SetCloud=function(enabled)
            if enabled then cloudRequests_=cloudRequests_+1 end
            originalSetCloud(false)
        end
        Save.ReadCloud=function(callback)
            cloudReads_=cloudReads_+1
            callback(Save.Get())
        end
        started_=true
        mainStart()
        check(GetApplicationState()=="menu" and Menu.GetPage()=="menu","未从真实main菜单启动")
        assertNoScene("初始菜单")
        if unknownSave_ then
            check(Save.Get()==nil and not SaveJourneyNow(),"未知未来格式没有触发写保护")
            check(readSeed()==seedText_,"未知未来存档被主菜单保存覆盖")
            mainStop();started_=false
            check(readSeed()==seedText_,"未知未来存档被main.Stop覆盖")
            finish("UNKNOWN_SAVE_PROTECTION_PASS")
            return
        end
        check(cloudRequests_>0 and cloudReads_>0,"测试没有真正覆盖开启云存档时的拦截")
        uiContext_=UI.GetNVGContext()
        if captureEnabled_ then
            check(graphics:GetWidth()==1280 and graphics:GetHeight()==720,"视觉验收请使用1280x720")
            SubscribeToEvent("EndRendering","EmergenceApplicationCapture")
            pendingCapture_="menu"
        end
    end)
end

---@param eventType string
---@param eventData UpdateEventData
function HandleUpdate(eventType,eventData)
    guard(function()
        frames_=frames_+1
        -- 与生产main相同的固定步流水线；不以软渲染wall time推进数分钟旅程。
        step(.02)
        check(elapsedFrames()<2400,"阶段超过有界帧预算："..stage_)
        check(os.clock()-startedAt_<900,"端到端CPU总预算超限")
        check(GetApplicationState()~="error","真实入口加载错误："..stage_)
        if stage_=="menu" and elapsedFrames()>=3 then
            tap(assert(Menu.GetRoot()),"startGame")
            check(Menu.GetPage()=="modes" and GetApplicationState()=="menu","Start没有先进入模式页")
            assertNoScene("首次模式页")
            check(Config.Stations==normalStationTable_ and Config.RouteSegments==normalSegments_,"只打开模式页就更改了地图配置")
            pendingCapture_="modes";transition("modes")
        elseif stage_=="modes" and elapsedFrames()>=3 then
            tap(assert(Menu.GetRoot()),"continueMode_"..((unknownNormal_ or legacyNormal_) and "normal" or "rage"))
            if unknownRoute_ then
                check(GetApplicationState()=="error","未知地图版本未被main拒绝")
                assertNoScene("未知地图版本")
                check(Modes.GetId()=="normal" and Config.Stations==normalStationTable_,"未知地图拒绝前污染模式/地图")
                check(readSeed()==seedText_,"未知地图拒绝时覆盖了原档")
                mainStop();started_=false
                check(readSeed()==seedText_,"未知地图拒绝后Stop覆盖了原档")
                finish("UNKNOWN_ROUTE_PROTECTION_PASS")
                return
            end
            check(GetApplicationState()=="loading" and GetGameMode()==migrationMode_,"旧旅程继续卡片没有启动真实加载")
            transition("rage-loading")
        elseif stage_=="rage-loading" and GetApplicationState()=="playing" then
            assertMode(migrationMode_)
            if migrationMode_=="rage" then assertMountain() end
            assertMigration()
            if migrationOnly_ then
                finish(legacyNormal_ and "NORMAL_LEGACY_MIGRATION_PASS" or "LEGACY_NO_ROUTE_MIGRATION_PASS");return
            end
            pressKey(KEY_P)
            check(not Hud.GetReadings().paused,"旧旅程迁移安全暂停不能真实P继续")
            check(Route.GetLength()>=normalMode_.routeLength*1.5 and Config.RouteId==Modes.Get().routeId,"狂暴没有构建独立真实长地图")
            check(Config.Stations~=normalStationTable_ and Config.RouteSegments~=normalSegments_,"狂暴仍在使用普通地图表")
            check(Route.PlatformEnd-Route.PlatformStart>=550,"狂暴站台未使用长站台几何")
            local rules=Modes.Get().rules
            check(rules.FreeDrive and rules.IgnoreLineSpeedLimits and rules.DisableDerailment and rules.MixedTraffic,
                "狂暴核心规则配置缺失")
            check(not Game.IsDwelling() and not Game.GetDepartureStatus().blocked,"狂暴始发仍被客运锁停")
            check(not Passenger.HasActiveStop() and not Game.GetPassengerStatus().doorsOpen,"狂暴仍创建强制乘降队列")
            local s=Train.GetS()
            pressKey(KEY_B) -- 旧旅程迁移安全制动必须由真实缓解按键主动解除。
            pressKey(KEY_W)
            check(Train.GetThrottle()==1 and Train.GetBrake()==0,"真实W业务路径不能自由牵引")
            simulate(10)
            check(Train.GetS()>s and Train.GetThrottle()==1 and Train.GetBrake()==0,"main固定步仍强制收油/停车")
            Train.EmergencyBrake()
            Camera.SetMode("front_chase")
            transition("rage-warm")
        elseif stage_=="rage-warm" and elapsedFrames()>=100 then
            assertRealMixedModels()
            setTrainPosition(assert(Route.GetStations()[1]).s+1,0)
            Train.EmergencyBrake()
            Traffic.Reset()
            stableSeconds_=0
            transition("rage-stable")
        elseif stage_=="rage-stable" then
            -- 真main固定步60s；玩家停车，NPC有完整调度/跟车/合流，不应靠自主碰撞演示狂暴。
            for _=1,5 do step(.2) end
            stableSeconds_=stableSeconds_+1
            if stableSeconds_%10==0 then assertStableTraffic() end
            if stableSeconds_>=60 then
                assertStableTraffic()
                local diagnostic=RageAudio.GetDiagnostics()
                check(diagnostic.initialized and diagnostic.gameMode=="rage" and diagnostic.consumed==0,
                    "无接触巡航仍制造/消费虚假撞击音频事件")
                print(PREFIX.."NPC_UNTOUCHED_STABLE seconds="..stableSeconds_.." formation=8 noImpacts=true noLaunches=true")
                pendingCapture_="rage-day"
                transition("rage-day")
            end
        elseif stage_=="rage-day" and elapsedFrames()>=3 then
            check(Environment.Configure({hour=22,running=false,weather="clear"}),"夜间真源配置失败")
            transition("rage-night")
        elseif stage_=="rage-night" and elapsedFrames()>=4 then
            assertNight()
            post();assertDriveStatus()
            check(Train.GetHeadlightMode()=="auto" and Train.GetHeadlightDiagnostics().enabled,"自动灯夜间未实际开启")
            pressKey(KEY_L);post()
            check(Train.GetHeadlightMode()=="on" and Train.GetHeadlightDiagnostics().enabled,"真实L未切到常亮")
            assertDriveStatus()
            pressKey(KEY_L);post()
            check(Train.GetHeadlightMode()=="off" and not Train.GetHeadlightDiagnostics().enabled,"真实L关闭没有作用到灯")
            assertDriveStatus()
            tap(assert(Hud.GetRoot()),"headlightMode");post()
            check(Train.GetHeadlightMode()=="auto" and Train.GetHeadlightDiagnostics().enabled,"真实灯按钮未从off循环auto")
            assertDriveStatus()
            -- 真实设置操作解除总静音并开启音乐：无声卡必须诚实显示device/loading，不能虚报playing。
            tap(assert(Hud.GetRoot()),"toggleSound")
            tap(assert(Hud.GetRoot()),"toggleMusic")
            for _=1,3 do step(.02);post() end
            local music=Soundscape.GetDiagnostics()
            local drive=Hud.GetDriveStatus()
            check(drive.musicEnabled and Hud.GetReadings().soundEnabled and music.enabled,
                "常驻声音/音乐按钮没有提交生产设置")
            check(drive.musicTitle==music.title,"HUD音乐曲目不是实际Soundscape诊断")
            if not music.deviceInitialized then
                check(drive.musicState=="device" or drive.musicState=="loading", "无声卡时HUD虚报播放")
            end
            print(PREFIX.."MUSIC_DEVICE_STATE state="..tostring(drive.musicState).." device="..tostring(music.deviceInitialized)
                .." audibleValidated=false")
            tap(assert(Hud.GetRoot()),"toggleMusic")
            tap(assert(Hud.GetRoot()),"toggleSound")
            step(.02);post();assertDriveStatus()
            pendingCapture_="rage-night"
            transition("rage-routing")
        elseif stage_=="rage-routing" and elapsedFrames()>=3 then
            local candidates={}
            for _,section in ipairs(Rail.GetRoutingSections()) do
                if section.kind=="interval" then candidates[#candidates+1]=section end
            end
            check(#candidates>=12,"133km山线缺少多处真实区间选道")
            local geometry=assert(candidates[3])
            local index=geometry.index
            check(index<0,"区间岔偷用客运站点编号")
            setTrainPosition(geometry.first-100,0)
            routeFixture_={index=index,geometry=geometry}
            Game.UpdateHud(0);post()
            local nextSwitch=Hud.GetDriveStatus().nextSwitch
            check(nextSwitch.index==index and nextSwitch.kind=="interval" and nextSwitch.distance>0,
                "HUD没有得到真实下一区间岔/距离")
            pressKey(KEY_Q)
            check(Rail.GetChoices()[index] and Rail.GetChoices()[index].lane==0,"真实Q处理未预选正线")
            pressKey(KEY_E)
            check(Rail.GetChoices()[index].lane==2,"真实E处理未预选真实侧线")
            Game.UpdateHud(0)
            -- 常驻道岔按钮不借滚动容器：真实命中并验证路径选择，不直接调用onClick。
            tap(assert(Hud.GetRoot()),"switchMainline")
            check(Rail.GetChoices()[index].lane==0,"常驻正线按钮未作用于真实路由")
            Game.UpdateHud(0)
            tap(assert(Hud.GetRoot()),"switchSiding")
            check(Rail.GetChoices()[index].lane==2,"常驻侧线按钮未作用于真实路由")
            -- 以正常RestoreState定位到岔前，再真实固定步驶过入口；保持前面预选的choice。
            local state=Train.ExportState()
            state.s,state.v,state.throttle,state.brake=geometry.first-25,50,0,0
            local savedChoices={}
            for index,choice in pairs(Rail.GetChoices()) do savedChoices[#savedChoices+1]={index=index,lane=choice.lane} end
            Train.RestoreState(state);Rail.RestoreChoices(savedChoices)
            simulate(20)
            check(Rail.GetStatus().locked and Rail.GetChoices()[index].locked,"真实车头进入入口后未锁岔")
            local accepted=Rail.SetSectionChoice(index,0,Train.GetS(),Train.GetActiveLength())
            check(not accepted and Rail.GetChoices()[index].lane==2,"占用进路能被车下直接扳动")
            pressKey(KEY_Q)
            check(Rail.GetChoices()[index].lane==2,"Q改动了当前已占用进路而非仅预选下一区段")
            transition("rage-routing-drive")
        elseif stage_=="rage-routing-drive" then
            simulate(25)
            local geometry=routeFixture_.geometry
            if Train.GetS()>=geometry.plateauFirst+30 then
                local branch=Train.GetTrackSample(Train.GetS())
                local expected=Rail.Sample(Train.GetS(),2)
                local mainline=Rail.Sample(Train.GetS(),0)
                near((branch-expected):Length(),0,"玩家采样未沿真实侧线")
                check((branch-mainline):Length()>5,"侧线选择只改文字未改变真实路径")
                check(not Train.IsDerailed() and not Game.IsDwelling(),"狂暴通过真实道岔仍侧翻/强制站停")
                local state=Train.ExportState()
                state.s,state.v,state.throttle,state.brake=geometry.last+20,50,0,0
                local choices={}
                for index,choice in pairs(Rail.GetChoices()) do choices[#choices+1]={index=index,lane=choice.lane} end
                Train.RestoreState(state);Rail.RestoreChoices(choices)
                check(Rail.GetChoices()[routeFixture_.index].locked,"车头出岔但车尾未清空就解锁")
                local accepted=Rail.SetSectionChoice(routeFixture_.index,0,Train.GetS(),Train.GetActiveLength())
                check(not accepted,"车尾占用区间仍允许扳动原岔")
                simulate(math.ceil((Train.GetActiveLength()+30)/(.02*45)))
                check(not Rail.GetChoices()[routeFixture_.index].locked,"整列真实驶过清尾后仍不能解除锁岔")
                print(PREFIX.."INTERVAL_REAL_DRIVE_PASS index="..routeFixture_.index.." tailLock=true realQE=true")
                -- 高于目录构造速度的真实动力步，不以GetMaxSpeed文案代替不限速验证。
                local specification=assert(Catalog.Find(Train.GetSelectedId()))
                local curve=assert(Route.GetSegments()[2])
                setTrainPosition(curve.s+math.min(curve.length*.4,500),160)
                Train.SetThrottle(Config.Train.MaxThrottle);Train.SetBrake(0)
                simulate(30)
                check(Train.GetSpeedKmh()>specification.maxSpeedKmh and not Train.IsDerailed(),"狂暴构造/曲线超速仍限速或侧翻")
                check(Train.GetThrottle()==Config.Train.MaxThrottle and Train.GetBrake()==0,"狂暴超速被自动抢控制")
                check(Game.GetSpeedLimit()>1e6,"狂暴仍有线路/车型/站区速度钳制")
                -- 停在真实下一路标时继续走生产Game.Update，不得进入普通站停。
                local marker=assert(Game.GetNextStation())
                setTrainPosition(marker.s,0);simulate(2)
                check(not Game.IsDwelling() and not Game.GetDepartureStatus().blocked,"狂暴路标停车触发了强制乘降")
                -- 真实山坡：整列节点forward必须含坡度，不能沿固定UP平移冒充爬山。
                setTrainPosition(slopeS_,32)
                simulate(5);post();assertDriveStatus()
                check(math.abs(Hud.GetDriveStatus().grade)>.03 and Hud.GetDriveStatus().elevation>100,
                    "真实main驾驶HUD仍显示平地")
                for _,car in ipairs(Train.GetCars()) do
                    local s=Train.GetS()+car.offset
                    local front=Train.GetTrackSample(s+car.pivot)
                    local rear=Train.GetTrackSample(s-car.pivot)
                    local chord=(front-rear):Normalized()
                    local forward=car.node.worldRotation*Vector3.FORWARD
                    check(forward:DotProduct(chord)>.9999 and math.abs(forward.y)>.02,
                        "山坡上的真实车体仍保持平UP/没有沿纵坡俯仰")
                end
                check(Environment.Configure({hour=12,running=false,weather="clear"}),"白昼灯夹具失败")
                post();assertDriveStatus()
                check(not Train.GetHeadlightDiagnostics().enabled,"auto白昼车灯未自动关闭")
                pressKey(KEY_L);post()
                check(Train.GetHeadlightMode()=="on" and Train.GetHeadlightDiagnostics().enabled,"手动常亮被白昼环境强制关掉")
                assertDriveStatus()
                -- 回始发区域，恢复实际混合车流（官方Reset，非修改NPC内部状态）。
                -- 撞飞像素用明亮远景机位，夜间照明已在前一阶段独立检验。
                check(Environment.Configure({hour=16,running=false,weather="clear"}),"撞飞验收白昼配置失败")
                Camera.SetMode("distant")
                setTrainPosition(assert(Route.GetStations()[1]).s+1,0)
                Traffic.Reset()
                transition("rage-collision-prepare")
            end
        elseif stage_=="rage-collision-prepare" and elapsedFrames()>=36 then
            local target=nil ---@type table?
            for _,vehicle in ipairs(Traffic.GetTrains()) do
                if vehicle.active and vehicle.id=="R01" and vehicle.lane==0 then target=vehicle;break end
            end
            check(target~=nil,"真实混合车流没有同股测试目标R01")
            local vehicle=assert(target)
            setTrainPosition(vehicle.lo-80-Train.GetCars()[1].length*.5,110)
            Traffic.CheckPlayerCollision() -- 正常瞬移检测只重置历史，不扫过整条线路。
            collisionFixture_={before=copy(Traffic.ExportRageState()),audio=RageAudio.GetDiagnostics()}
            check(collisionFixture_.before.playerImpacts==0 and collisionFixture_.before.npcImpacts==0,
                "主动撞击前已出现未由玩家触发的碰撞")
            Train.SetThrottle(0);Train.SetBrake(0)
            transition("rage-collision")
        elseif stage_=="rage-collision" then
            simulate(12)
            local stats=assert(Traffic.GetRageStats())
            if stats.playerImpacts>collisionFixture_.before.playerImpacts and stats.airborne>0 then
                check(stats.score>collisionFixture_.before.score and stats.launches>0 and stats.impacts>0,"真实碰撞未产生持久统计")
                check(not Train.IsDerailed() and Train.GetThrottle()==0 and Train.GetBrake()==0,"NPC撞飞改变了玩家事故/控制状态")
                local flying=nil ---@type table?
                for _,car in ipairs(Traffic.GetRageCars()) do
                    if car.state=="flying" then flying=car;break end
                end
                check(flying~=nil,"统计声称撞飞但没有实际飞行车节")
                local car=assert(flying)
                collisionFixture_.flying={id=car.id,position=car.position,rotation=car.rotation,age=car.age}
                local queued=Traffic.GetImpactEvents()
                check(#queued>0,"真实碰撞没有发出可消费事件")
                local last=queued[#queued].sequence
                post()
                local audioStatus=RageAudio.GetDiagnostics()
                check(audioStatus.consumed>collisionFixture_.audio.consumed and audioStatus.lastSequence>=last,
                    "真实main.PostUpdate没有消费Traffic碰撞事件到RageAudio")
                check(#Traffic.GetImpactEvents()==0 and audioStatus.started==0 and audioStatus.activeVoices==0,
                    "静音设置下事件积压/仍然开启声音")
                post()
                check(RageAudio.GetDiagnostics().consumed==audioStatus.consumed,"空事件帧重复消费/制造音频")
                print(string.format(PREFIX.."REAL_IMPACT_AUDIO_CONSUMED consumed=%d sequence=%d muted=true audibleValidated=false",
                    audioStatus.consumed,audioStatus.lastSequence))
                captureFocusId_=car.id
                pendingCapture_="rage-flight-a"
                transition("rage-ballistic")
            else check(elapsedFrames()<80,"有限固定步内真实同股碰撞未触发") end
        elseif stage_=="rage-ballistic" then
            simulate(10)
            local before=collisionFixture_.flying
            local current=nil ---@type table?
            for _,car in ipairs(Traffic.GetRageCars()) do if car.id==before.id then current=car;break end end
            local car=assert(current)
            local offset=car.position-before.position --[[@as Vector3]]
            check(car.age>before.age and offset:Length()>.5,"撞飞车节没有实际弹道运动")
            check((car.rotation*Vector3.UP-before.rotation*Vector3.UP):Length()>.02,"撞飞车体不旋转")
            Game.UpdateHud(0)
            -- 保留实际碰撞累计，再把玩家合法恢复至先前真实侧线路径；暂停读档必须立即呈现8节侧线姿态。
            captureFocusId_,captureFocusDrawable_="",nil
            setTrainPosition(routeFixture_.geometry.plateauFirst+Train.GetActiveLength()+40,0)
            Rail.RestoreChoices({{index=routeFixture_.index,lane=2}})
            step(.02);post()
            Train.EmergencyBrake();pressKey(KEY_P)
            check(Hud.GetReadings().paused,"保存前没有暂停真实main模拟")
            post()
            check(RageAudio.GetDiagnostics().blocked and RageAudio.GetDiagnostics().activeVoices==0,
                "真实暂停没有阻止RageAudio输出")
            rageSnapshot_=snapshot()
            check(rageSnapshot_.game.rageStats.playerImpacts>0 and rageSnapshot_.game.rageStats.score>0,"真实rage统计未写入旅程")
            pendingCapture_="rage-impact"
            transition("rage-saved")
        elseif stage_=="rage-saved" and elapsedFrames()>=3 then
            captureFocusId_,captureFocusDrawable_="",nil
            returnMenu()
            check(not RageAudio.GetDiagnostics().initialized,"返回菜单没有Shutdown真实RageAudio")
            assertStats(assert(Save.Get()).journeys.rage.game.rageStats,rageSnapshot_.game.rageStats,"返回菜单后rage")
            beginMode("normal",false)
            transition("normal-loading")
        elseif stage_=="normal-loading" and GetApplicationState()=="playing" then
            assertMode("normal")
            check(Config.Stations==normalStationTable_ and Config.RouteSegments==normalSegments_,"普通模式没有恢复原地图配置引用")
            near(Route.GetLength(),normalMode_.routeLength,"普通模式真实线路长度改变",1)
            check(Config.WorldStream.Seed==normalSeed_ and Route.PlatformEnd-Route.PlatformStart==310,"普通地图随机种子/站台几何被狂暴污染")
            check(Game.IsDwelling() and Game.GetDepartureStatus().blocked and Passenger.HasActiveStop(),"普通始发缺少真实客运联锁")
            check(Traffic.GetRageStats()==nil and Game.ExportState().rageStats==nil,"普通模式混入狂暴统计")
            check(Passenger.GetStatus().totalBoarding>0,"普通模式未创建真实乘降清单")
            local s=Train.GetS()
            pressKey(KEY_W)
            Train.SetThrottle(Config.Train.MaxThrottle);Train.SetBrake(0)
            simulate(5)
            near(Train.GetS(),s,"普通客运联锁被直接油门绕过")
            check(Train.GetThrottle()==0 and Train.GetBrake()==1,"普通生产流水线没有强制客运制动")
            check(Game.GetSpeedLimit()<1e6,"普通模式丢失限速规则")
            check(not Modes.Get().rules.FreeDrive and not Modes.Get().rules.DisableDerailment,"普通规则仍是狂暴")
            check(Environment.Configure({hour=22,running=false,weather="clear"}),"普通夜间配置失败")
            -- 默认逆向班次在前1200m，灯仅420m内启用；正式Reset的调度原点参数建立近距来车。
            -- 不改玩家位置/客运队列，不写NPC表，仍由生产Update完成运动和渲染绑定。
            Traffic.Reset(Train.GetS()-1000)
            Camera.SetMode("front_chase")
            transition("normal-night")
        elseif stage_=="normal-night" and elapsedFrames()>=36 then
            local stats=TrafficVisuals.GetStats()
            local nearest=math.huge
            for _,vehicle in ipairs(Traffic.GetTrains()) do
                if vehicle.active then nearest=math.min(nearest,math.max(0,vehicle.lo-Train.GetS(),Train.GetS()-vehicle.hi)) end
            end
            check(nearest<420,"普通夜间夹具没有真实近距来车")
            check(stats.headlights>0 and stats.headlights<=3 and stats.errors==0,
                "普通AI真实前灯未启用或突破3组预算："..cjson.encode(stats))
            print(PREFIX.."NORMAL_AI_HEADLIGHTS count="..stats.headlights.." nearest="..nearest)
            Traffic.Reset()
            check(Environment.Configure({hour=12,running=false,weather="clear"}),"普通白昼配置失败")
            transition("normal-warm")
        elseif stage_=="normal-warm" and elapsedFrames()>=8 then
            pendingCapture_="normal-day"
            pressKey(KEY_P)
            normalSnapshot_=snapshot()
            check(math.abs(normalSnapshot_.train.s-rageSnapshot_.train.s)>100,"测试坐标没有形成可验证的双模式差异")
            local saved=assert(Save.Get())
            assertStats(saved.journeys.rage.game.rageStats,rageSnapshot_.game.rageStats,"normal保存后rage")
            near(saved.journeys.rage.train.s,rageSnapshot_.train.s,"normal覆盖了rage坐标")
            transition("normal-saved")
        elseif stage_=="normal-saved" and elapsedFrames()>=3 then
            returnMenu();beginMode("rage",true)
            transition("rage-restoring")
        elseif stage_=="rage-restoring" and GetApplicationState()=="playing" then
            assertRestored(rageSnapshot_,"rage")
            check(Route.GetLength()>=normalMode_.routeLength*1.5,"恢复rage错误地载入普通地图")
            pendingCapture_="rage-restored"
            transition("rage-restored")
        elseif stage_=="rage-restored" and elapsedFrames()>=4 then
            near(Train.GetS(),rageSnapshot_.train.s,"恢复后安全暂停未阻止rage移动",.001)
            returnMenu()
            local data=assert(Save.Get())
            near(data.journeys.normal.train.s,normalSnapshot_.train.s,"rage返回覆盖了normal坐标")
            check(data.journeys.normal.game.rageStats==nil,"rage统计写入normal槽位")
            beginMode("normal",true)
            transition("normal-restoring")
        elseif stage_=="normal-restoring" and GetApplicationState()=="playing" then
            assertRestored(normalSnapshot_,"normal")
            check(Config.Stations==normalStationTable_ and Config.RouteSegments==normalSegments_,"normal读档没有恢复原地图")
            check(Game.GetDepartureStatus().blocked and Game.IsDwelling(),"normal读档丢失客运联锁")
            assertStats(assert(Save.Get()).journeys.rage.game.rageStats,rageSnapshot_.game.rageStats,"normal恢复后rage")
            pendingCapture_="normal-restored"
            transition("normal-restored")
        elseif stage_=="normal-restored" and elapsedFrames()>=4 then
            near(Train.GetS(),normalSnapshot_.train.s,"normal暂停读档坐标漂移",.001)
            finish("ALL_EMERGENCE_APPLICATION_VALIDATION_PASS")
        end
    end)
end

---@param eventType string
---@param eventData PostUpdateEventData
function HandlePostUpdate(eventType,eventData)
    guard(function()
        local event=VariantMap();event["TimeStep"]=Variant(.02)
        mainPost("PostUpdate",event --[[@as PostUpdateEventData]])
        focusFlyingForCapture()
    end)
end
function EmergenceApplicationCapture()
    guard(function()
        if not captureEnabled_ or pendingCapture_=="" then return end
        local name=pendingCapture_;pendingCapture_=""
        if captureFocusId_~="" then
            local drawable=assert(captureFocusDrawable_)
            check(drawable.inView,"正式飞行车体未被实际渲染相机判为inView")
            print(string.format(PREFIX.."REAL_FLYING_PIXELS id=%s model=%s inView=true worldY=%.3f frame=%s",
                captureFocusId_,assert(drawable.model).name,drawable.worldBoundingBox.center.y,name))
        end
        local image=Image()
        check(graphics:TakeScreenShot(image),"真实渲染截图失败："..name)
        local path="/home/Maker/emergence-"..name..".png"
        check(image:SavePNG(path),"内部截图保存失败："..path)
        image:Dispose()
        screenshotCount_=screenshotCount_+1
        print(PREFIX.."REAL_SCREENSHOT "..path)
    end)
end
function Stop() cleanup() end
