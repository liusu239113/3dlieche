-- 中国铁路真实main入口E2E。基于ApplicationValidation的真实触摸/禁云脚手架。
-- 必须在screenshots/validation-sandbox-app独立cwd及-tapcode_dir中运行；绝不覆盖既有存档。
-- 软件GLES只是渲染正确性验收，原生DrawCall/triangles实录不代表60fps达标。
require "main"
local mainStart,mainUpdate,mainPost,mainStop=Start,HandleUpdate,HandlePostUpdate,Stop
local UI=require "urhox-libs/UI"
local Menu=require "ui.Menu"
local Hud=require "ui.Hud"
local Train=require "train.Train"
local Camera=require "train.Camera"
local Route=require "world.Route"
local Rail=require "world.RailNetwork"
local Traffic=require "game.Traffic"
local Game=require "game.Game"
local Passenger=require "game.PassengerService"
local Save=require "game.SaveStore"
local Environment=require "world.Environment"
local Stream=require "world.WorldStream"
local Infrastructure=require "world.RailwayInfrastructure"
local Road=require "world.RoadCorridor"
local Scenery=require "world.RailwayScenery"
local Terrain=require "world.Terrain"
local Announcements=require "audio.Announcements"
local Catalog=require "config.TrainCatalog"
local VoiceCatalog=require "config.AnnouncementCatalog"
local Landmarks=require "world.Landmarks"
local Audio=require "audio.AudioManager"
local SANDBOX="/workspace/screenshots/validation-sandbox-app"
local SAVE_PATH="railway_autosave_v1.json"
local saveSetCloud,saveReadCloud=Save.SetCloud,Save.ReadCloud
local announcementsNew=Announcements.new
---@type RailwayAnnouncements?
local announcements_=nil
local frames_,stageFrame_,checks_,captures_=0,0,0,0
local stage_="menu"
local failed_,complete_,started_,isolated_=false,false,false,false
local cloudReads_,cloudRequests_=0,0
local pendingCapture_=""
local captureRetries_,captureDue_=0,0
local missingCaptures_={} ---@type string[]
local baseline_={} ---@type table
local weatherIndex_=1
local weatherFrames_=0
local weatherCases_={"clear","cloudy","rain","fog"} ---@type string[]
local compact_=false
for _,arg in ipairs(GetArguments()) do
    if arg=="-app-weather-compact" then compact_=true;weatherCases_={"rain","fog"} end
end
local renderedWorldFrames_=0
local sampleMs_,sampleDraws_,sampleTriangles_={},{},{} ---@type number[],number[],number[]
local function check(value,message)
    checks_=checks_+1
    assert(value,"[ChinaRailApplication] "..message)
end
local function guard(action)
    if failed_ or complete_ then return end
    local ok,message=xpcall(action,debug.traceback)
    if not ok then
        failed_=true
        print("CHINA_RAIL_APPLICATION_FAILED stage="..stage_.." frame="..frames_)
        log:Write(LOG_ERROR,tostring(message))
    end
end
local function nextStage(name)
    stage_,stageFrame_=name,frames_
    print("[ChinaRailApplication] stage="..name.." frame="..frames_)
end
---@param root Widget
---@param id string
---@param scrollId? string
local function tap(root,id,scrollId)
    UI.Layout()
    local control=assert(root:FindById(id),"缺少真实控件 "..id)
    local scroll=root:FindById(scrollId or "menuScroll") --[[@as ScrollView?]]
    if scroll then
        scroll:UpdateContentSize()
        local r,b=control:GetAbsoluteLayoutForHitTest(),scroll:GetAbsoluteLayoutForHitTest()
        if r.y<b.y or r.y+r.h>b.y+b.h then
            scroll:ScrollBy(0,r.y+r.h*.5-b.y-b.h*.5)
            UI.Layout()
        end
    end
    local r=control:GetAbsoluteLayoutForHitTest()
    check(r.w>0 and r.h>0,"触摸控件无实际布局 "..id)
    local x,y=r.x+r.w*.5,r.y+r.h*.5
    check(x>=0 and y>=0 and x<graphics:GetWidth()/UI.GetScale() and y<graphics:GetHeight()/UI.GetScale(),
        "触摸中心在屏外 "..id)
    check(UI.FindWidgetAt(x,y)==control,"实际命中被遮挡 "..id)
    UI.InputAdapter.HandleTouchBegin(921,x*UI.GetScale(),y*UI.GetScale(),.5)
    UI.InputAdapter.HandleTouchEnd(921,x*UI.GetScale(),y*UI.GetScale())
end
local function assertEnvironment(saved,context)
    local actual=Environment.Export()
    for _,key in ipairs({"hour","dayLength","cloud","rain","sunScale","fogScale","fog"}) do
        check(type(saved[key])=="number" and math.abs(actual[key]-saved[key])<.00001,context.."环境标量丢失 "..key)
    end
    check(actual.weather==saved.weather and actual.running==saved.running
        and actual.overcastSky==saved.overcastSky,context.."天气/流动/天空迟滞丢失")
end
local function assertNativeZone()
    local scene=assert(GetGameScene())
    local zone=assert(assert(scene:GetChild("DayLighting")):GetComponent("Zone"))
    local status=Environment.GetStatus()
    check(math.abs(zone.depthFogStart-status.fogStart)<.002
        and math.abs(zone.depthFogEnd-status.fogEnd)<.002,"状态雾距未下发真实原生Zone")
    check(#scene:GetComponents("Zone",true)==1,"新设施重复创建Zone")
end
local function assertCaptureEnvironment(name)
    local expected=name:match("^playing%-(.+)$")
    if name=="playing-new-world" or name=="route-map-under-button" or name=="station-timetable" then expected="clear"
    elseif name=="df4d-retained" or name=="continued-fog-df4d" or name=="streamed-road-scenery" then expected="fog" end
    local status=Environment.GetStatus()
    local readings=Hud.GetReadings()
    local label=assert(assert(Hud.GetRoot()):FindById("worldEnvironment")) --[[@as Label]]
    check(expected~=nil and status.weather==expected,"捕图前天气目标不符 "..name)
    check(readings.environmentText:find(status.weatherLabel,1,true)~=nil,
        "捕图前HUD未显示真实天气 "..name.." text="..readings.environmentText)
    check(label:GetText()==readings.environmentText,"真实HUD Label与反馈读数不同 "..name)
    assertNativeZone()
    if expected=="fog" then
        check(status.fogIntensity>0 and status.fogIntensity<1,"主入口截图应覆盖fog过渡而非宣称成熟浓雾")
        assertEnvironment(baseline_.environment,"捕图"..name)
    end
    print(string.format("[ChinaRailApplication] CAPTURE_ENV name=%s target=%s fogIntensity=%.6f rainIntensity=%.6f fogStart=%.3f fogEnd=%.3f hud=%s visualClaim=TRANSITION_ONLY",
        name,status.weather,status.fogIntensity,status.rainIntensity,status.fogStart,status.fogEnd,label:GetText()))
end
local function capture(name)
    -- 读回前再次核对真实Label/天气/原生Zone；设置页选中目标不能冒充主场景效果。
    if GetApplicationState()=="playing" then assertCaptureEnvironment(name) end
    local image=Image()
    if not graphics:TakeScreenShot(image) then image:Dispose();return false end
    check(image.width==1280 and image.height==720,"真实截图尺寸错误")
    check(image:SavePNG(SANDBOX.."/china-rail-app-"..name..".png"),"内部截图保存失败")
    image:Dispose()
    captures_=captures_+1
    print(string.format("[ChinaRailApplication] REAL_RENDER capture=%s frame=%d nativeDrawCalls=%d nativeTriangles=%d rendererBatches=%d rendererPrimitives=%d fps60=NOT_CLAIMED",
        name,frames_,graphics.numBatches,graphics.numPrimitives,renderer.numBatches,renderer.numPrimitives))
    return true
end
local function logSceneryQueue(context)
    local stream,scenery=Stream.GetStats(),Scenery.GetStats()
    print(string.format("[ChinaRailApplication] SCENERY_QUEUE context=%s frame=%d s=%.3f pending=%d loaded=%d nearRail=%d farRail=%d infrastructure=%d scenery=%d sceneryVertices=%d sceneryMeshes=%d",
        context,frames_,stream.lastS,stream.pendingTasks,stream.loadedChunks,stream.nearRailChunks,stream.farRailChunks,
        stream.infrastructureChunks,stream.sceneryChunks,scenery.vertices,scenery.meshes))
end
local function checkDoors(isDF4D)
    local station=assert(Route.GetStations()[1])
    local plan=Passenger.BuildDoorPlan(station)
    check(plan.valid and plan.lane==0,"真实始发主线门计划无效")
    check(#plan.doors>0,"实际始发无可用门")
    if isDF4D then check(#plan.doors==14,"DF4D未保留七节客车14个模拟玄关门") end
    for _,door in ipairs(plan.doors) do
        local lateral=(door.edge-Route.Sample(door.s)):DotProduct(Route.RightAt(door.s))
        check(door.side==-1 and lateral>=plan.platformMin-.01 and lateral<=plan.platformMax+.01,
            "主线0未朝左侧岛台开门或跨越另一运营股道")
        if isDF4D then
            check(door.carIndex>1 and door.source=="simulated_coach_end_vestibule",
                "机车被当成客门或虚称工程实测门")
        end
    end
end
local function checkLeftRunning()
    local s=Train.GetS()
    check(Rail.GetTopologyMode()=="cn_left_v1","未使用中国双线左行拓扑")
    check(Rail.GetPlayerLane(s)==0 and not Train.IsReversing(),"始发未在下行0股道")
    local down=Rail.Sample(s,0)
    local up=Rail.Sample(s,1)
    check(math.abs((up-down):DotProduct(Route.RightAt(s))-5)<.002,"上行未在下行右侧5米")
    check(Rail.GetNormalDirection(0)==1 and Rail.GetNormalDirection(1)==-1,"双线正常方向不是左行")
    local active,opposing=0,0
    for _,train in ipairs(Traffic.GetTrains()) do
        if train.active then
            active=active+1
            check(train.lane==(train.dir>0 and 0 or 1),"main实际AI违背双线左行 "..train.id)
            if train.dir<0 then opposing=opposing+1 end
        end
    end
    check(active>0 and opposing>0,"真实main无活动对向班次")
    check(Traffic.GetBlockSignalAspect(s,0,-1)=="red" and Traffic.GetBlockSignalAspect(s,1,1)=="red",
        "未经授权的逆股方向信号未保持红灯")
end
local function meshVertices(meshes)
    local vertices=0
    for _,mesh in ipairs(meshes) do
        check(mesh.node~=nil and mesh:GetMaterial()~=nil,"新增道路/景物网格丢失真实节点/材质")
        for i=0,mesh.numGeometries-1 do vertices=vertices+mesh:GetNumVertices(i) end
    end
    return vertices
end
local function checkWorld(context,requireScenery)
    local scene=assert(GetGameScene())
    local stats=Stream.GetStats()
    local infra,road,scenery=Infrastructure.GetStats(),Road.GetStats(),Scenery.GetStats()
    for _,name in ipairs({"WorldStream","Train","DayLighting","EnvironmentRain"}) do
        local count=0
        for _,node in ipairs(scene:GetChildren()) do if node.name==name then count=count+1 end end
        check(count==1,"warm场景重复/缺失根节点 "..name.." "..context)
    end
    check(stats.root==scene:GetChild("WorldStream") and stats.infrastructureChunks>0
        and stats.sceneryChunks>0 and stats.stationChunks>0,"真实main未接入新增流式块 "..context)
    check(infra.loadedChunks>=stats.infrastructureChunks and infra.supports>0 and infra.wireLength>0 and infra.vertices>0,
        "接触网只存在于规划表 "..context)
    local actual=Infrastructure.GetValidationData()
    check(#actual.chunks>0 and #actual.objects>0 and scene:GetChild("中国铁路设施",true)~=nil,
        "真实场景无中国铁路设施节点 "..context)
    check(road.initialized and road.loadedChunks>0 and road.vertices>0 and road.length>0,
        "main未生成道路几何 "..context)
    check(road.rightHandTraffic and road.trafficMode=="dynamic" and road.movingVehicles>=0,
        "道路未接入右行动态交通")
    check(Road.GetTrafficStats().staticVehicles==0 and Road.GetTrafficStats().poolSize<=64,
        "动态车流仍夹带静态车或超过节点上限")
    check(meshVertices(Road.GetMeshes())>0,"道路统计非零但真实CustomGeometry为空")
    check(scenery.initialized and scenery.planned>0 and #Scenery.GetExclusions()==scenery.planned,
        "main未规划新乡野景物 "..context)
    if requireScenery then
        check(scenery.loadedChunks>0 and scenery.vertices>0 and scenery.meshes>0,
            "合法plot窗口未生成新乡野景物几何 "..context)
        check(meshVertices(Scenery.GetMeshes())>0,"景物统计非零但真实CustomGeometry为空")
    end
    local plan=assert(Game.GetTimetableStatus(),"main未建立站点运行图")
    check(#plan.rows>=4 and type(plan.minutes)=="number","main运行图站序/世界钟无效 "..context)
    local worldClock=Environment.GetClock()
    check(math.abs(plan.minutes-worldClock.minutes)<=math.max(1,worldClock.rate*1.1),"main时刻表脱离唯一世界钟或缓存超过1秒")
    local voiceCoverage=VoiceCatalog.GetCoverage()
    check(voiceCoverage.generatedChinese==34 and voiceCoverage.plannedChinese==34
        and voiceCoverage.generatedStationChinese==30 and voiceCoverage.chineseStationVoices
        and voiceCoverage.namedChineseStations==10 and voiceCoverage.unvoicedChineseStations==0
        and voiceCoverage.generationStatus=="complete","main未接入十站34段选定女声")
    local landmarkDefinitions=Landmarks.GetDefinitions()
    local bridges,tunnels=0,0
    for _,definition in ipairs(landmarkDefinitions) do
        if definition.kind=="bridge" then bridges=bridges+1 elseif definition.kind=="tunnel" then tunnels=tunnels+1 end
    end
    check(bridges==4 and tunnels==7,"main默认线路未接入新增4桥7隧")
    check(infra.duplicateBuilds==0 and infra.providerErrors==0,"设施重建重复或真实信号provider异常")
    assertNativeZone()
    checkLeftRunning()
    print(string.format("[ChinaRailApplication] WORLD context=%s s=%.3f chunks=%d infrastructure=%d supports=%d wires=%.1f roadChunks=%d roadVertices=%d sceneryChunks=%d sceneryVertices=%d",
        context,Train.GetS(),stats.loadedChunks,infra.loadedChunks,infra.supports,infra.wireLength,
        road.loadedChunks,road.vertices,scenery.loadedChunks,scenery.vertices))
end
local function checkReleased(context)
    local stream,infra,road,scenery=Stream.GetStats(),Infrastructure.GetStats(),Road.GetStats(),Scenery.GetStats()
    check(GetGameScene()==nil and renderer.numViewports==0,"退出未释放主场景/viewport "..context)
    check(stream.root==nil and stream.loadedChunks==0 and stream.pendingTasks==0,"退出仍持有世界块或协程 "..context)
    check(infra.loadedChunks==0 and infra.signals==0 and infra.supports==0 and infra.pendingChunks==0,
        "退出仍持有设施灯/支柱/半成品引用 "..context)
    check(not road.initialized and road.loadedChunks==0 and #Road.GetMeshes()==0
        and #Road.GetProfile()==0 and #Road.GetExclusions()==0,"退出仍持有Road引用 "..context)
    check(not scenery.initialized and scenery.loadedChunks==0 and #Scenery.GetMeshes()==0
        and #Scenery.GetExclusions()==0,"退出仍持有Scenery引用 "..context)
    check(Terrain.GetLandscapeStats().loadedCells==0,"退出仍持有地形cell")
    check(not Environment.GetStatus().skyReady and not Environment.GetStatus().rainReady,"退出仍持有天气GPU资源")
    check(Train.GetRoot()==nil and Train.GetCarCount()==0 and Camera.GetNode()==nil,"退出仍持有列车/相机")
    check(announcements_~=nil and announcements_.stopped,"退出未Shutdown真实广播实例")
end
local function openSettings()
    local root=assert(Hud.GetRoot())
    tap(root,"toggleOperations")
    tap(root,"openSettings","operationsDetails")
    check(GetApplicationState()=="settings" and Menu.GetPage()=="settings","真实HUD设置按钮未进入设置页")
end
local function chooseWeather()
    openSettings()
    local weather=assert(weatherCases_[weatherIndex_])
    tap(assert(Menu.GetRoot()),"settingsWeather_"..weather)
    check(Environment.GetStatus().weather==weather,"真实触摸天气未桥接main "..weather)
    local saved=assert(Save.Get())
    check(saved.settings.environment.weather==weather and saved.journey.environment.weather==weather,
        "真实天气触摸未立即写入设置和旅程 "..weather)
    local before=Environment.Export()
    check(Environment.GetStatus().paused,"设置页未冻结天气")
    baseline_.weatherBefore=before
    pendingCapture_="settings-"..weather
    nextStage("weather-settings")
end
function Start()
    guard(function()
        -- 双门禁：命令行隔离tapcode + 独立配置marker。若有任何既有设备档，mainStart前拒绝；不备份覆盖。
        local found=false
        for _,arg in ipairs(GetArguments()) do if arg=="-tapcode_dir="..SANDBOX then found=true end end
        check(found,"必须传独立-tapcode_dir="..SANDBOX)
        local toolMode=false
        for _,arg in ipairs(GetArguments()) do if arg=="-tool_mode" then toolMode=true end end
        check(toolMode,"必须使用-tool_mode，禁止运行期写入普通游戏日志目录")
        check(os.getenv("PWD")==SANDBOX,"必须从独立sandbox cwd运行，拒绝读取原工程设备档")
        local config=File(SANDBOX.."/.project/project.json",FILE_READ)
        check(config:IsOpen(),"缺少隔离项目配置")
        local settings=cjson.decode(config:ReadString());config:Dispose()
        check(settings.project_id=="china_rail_application_validation_isolated","隔离项目标记错误")
        check(not fileSystem:FileExists(SAVE_PATH),"发现既有设备存档，拒绝启动或覆盖；请使用空隔离cwd")
        isolated_=true
        Save.SetCloud=function(enabled)
            if enabled then cloudRequests_=cloudRequests_+1 end
            saveSetCloud(false)
        end
        Save.ReadCloud=function(callback) cloudReads_=cloudReads_+1;callback(Save.Get()) end
        Announcements.new=function(options)
            local actual=announcementsNew(options);announcements_=actual;return actual
        end
        started_=true
        mainStart()
        check(GetApplicationState()=="menu" and GetGameScene()==nil and renderer.numViewports==0,"真实入口未先显示无场景菜单")
        check(graphics:GetWidth()==1280 and graphics:GetHeight()==720,"软件GLES实际尺寸不是1280x720")
        baseline_.uiContext=UI.GetNVGContext()
        SubscribeToEvent("EndRendering","ChinaRailApplicationCapture")
        pendingCapture_="menu"
    end)
end
function ChinaRailApplicationCapture()
    guard(function()
        if GetApplicationState()=="playing" then
            check(graphics.numBatches>0 and graphics.numPrimitives>100,"真实主场景未提交原生draws/triangles")
            renderedWorldFrames_=renderedWorldFrames_+1
            sampleDraws_[#sampleDraws_+1]=graphics.numBatches
            sampleTriangles_[#sampleTriangles_+1]=graphics.numPrimitives
        end
        if pendingCapture_~="" then
            if captureDue_==0 then captureDue_=frames_+2;return end
            if frames_<captureDue_ then return end
            if capture(pendingCapture_) then pendingCapture_,captureRetries_,captureDue_="",0,0
            else
                captureRetries_=captureRetries_+1
                if captureRetries_>=4 then
                    missingCaptures_[#missingCaptures_+1]=pendingCapture_
                    print("[ChinaRailApplication] CAPTURE_MISSING name="..pendingCapture_.." attempts=4; continue realUI assertions, final evidence cannot PASS")
                    pendingCapture_,captureRetries_,captureDue_="",0,0
                else captureDue_=frames_+2 end
            end
        end
    end)
end
---@param eventType string
---@param eventData UpdateEventData
function HandleUpdate(eventType,eventData)
    guard(function()
        frames_=frames_+1
        mainUpdate(eventType,eventData)
        check(frames_-stageFrame_<600,"有界阶段超时 "..stage_)
        if pendingCapture_~="" then return end -- 延后读回期间不换页，避免拿下一页冒充原机位。
        if GetApplicationState()=="error" then
            capture("error-"..stage_)
            check(false,"真实入口加载错误 "..stage_.."；请查看main加载失败日志及内部error截图")
        end
        if GetApplicationState()=="playing" then sampleMs_[#sampleMs_+1]=eventData:GetFloat("TimeStep")*1000 end
        if stage_=="menu" and frames_>=4 then
            tap(assert(Menu.GetRoot()),"gameSettings")
            tap(assert(Menu.GetRoot()),"settingsTimeDay")
            tap(assert(Menu.GetRoot()),"settingsTimeRunning") -- 空隔离配置默认running=true。
            tap(assert(Menu.GetRoot()),"settingsWeather_clear")
            tap(assert(Menu.GetRoot()),"settingsBack")
            tap(assert(Menu.GetRoot()),"startGame")
            check(Menu.GetPage()=="modes" and GetGameScene()==nil,"模式选择前提前加载地图")
            tap(assert(Menu.GetRoot()),"selectMode_normal")
            check(GetApplicationState()=="loading","真实普通模式按钮未进入加载页")
            pendingCapture_="loading";nextStage("loading")
        elseif stage_=="loading" and GetApplicationState()=="playing" then
            check(UI.GetNVGContext()==baseline_.uiContext,"加载重新创建UI上下文")
            check(Train.GetCarCount()==8 and Train.ValidateBindings(),"首发八节实际MDL无效")
            check(Environment.GetStatus().skyReady and not Environment.GetStatus().running,"真实天空或时间暂停设置未应用")
            check(Passenger.GetStatus().totalBoarding>300,"main始发客流不存在")
            checkDoors(false)
            checkLeftRunning()
            Camera.SetMode("side");Camera.Update(0,Train.GetS())
            tap(assert(Hud.GetRoot()),"pauseGame")
            check(Hud.GetReadings().paused,"真实暂停按钮失败")
            nextStage("world")
        elseif stage_=="world" and frames_>=stageFrame_+2 then
            checkWorld("initial",false)
            baseline_.s=Train.GetS()
            baseline_.timetable=cjson.encode(Game.ExportState().timetable)
            baseline_.clockMinutes=Environment.GetClock().minutes
            baseline_.infrastructureObjects=#Infrastructure.GetValidationData().objects
            pendingCapture_="playing-new-world"
            nextStage("route-map")
        elseif stage_=="route-map" and frames_>=stageFrame_+2 then
            local root=assert(Hud.GetRoot())
            tap(root,"toggleMinimap")
            UI.Layout()
            local button=assert(root:FindById("toggleMinimap")):GetAbsoluteLayout()
            local dropdown=assert(root:FindById("routeDropdown")):GetAbsoluteLayout()
            check(dropdown.y>=button.y+button.h,"main线路图未在按钮下方")
            check(dropdown.w>200 and dropdown.h>70,"main线路图弹层无可用空间")
            pendingCapture_="route-map-under-button"
            nextStage("station-timetable")
        elseif stage_=="station-timetable" and frames_>=stageFrame_+2 then
            local root=assert(Hud.GetRoot())
            tap(root,"routeTimetableTab")
            local plan=assert(Game.GetTimetableStatus())
            check(#plan.rows==5 and plan.rows[2].actualArrival==nil,"main时刻表伪造未来站实际到达")
            check(root:FindById("timetablePlan_2")~=nil,"main未创建第二站计划文本")
            pendingCapture_="station-timetable"
            nextStage("route-close")
        elseif stage_=="route-close" and frames_>=stageFrame_+2 then
            tap(assert(Hud.GetRoot()),"closeRouteDropdown")
            nextStage("weather-start")
        elseif stage_=="weather-start" and frames_>=stageFrame_+2 then
            chooseWeather()
        elseif stage_=="weather-settings" and frames_>=stageFrame_+2 then
            assertEnvironment(baseline_.weatherBefore,"设置暂停")
            tap(assert(Menu.GetRoot()),"settingsBack")
            check(GetApplicationState()=="playing" and Hud.GetReadings().paused,"设置返回没有保留驾驶暂停")
            local weather=weatherCases_[weatherIndex_]
            check(Hud.GetReadings().environmentText:find(Environment.GetStatus().weatherLabel,1,true)~=nil,
                "HUD没有回读真实天气 "..weather)
            tap(assert(Hud.GetRoot()),"pauseGame")
            check(not Hud.GetReadings().paused,"真实恢复驾驶触摸失败")
            weatherFrames_=0
            nextStage("weather-playing")
        elseif stage_=="weather-playing" then
            weatherFrames_=weatherFrames_+1
            if weatherFrames_>=8 then
                local weather=weatherCases_[weatherIndex_]
                check(Environment.GetStatus().weather==weather,"实际天气目标漂移")
                -- 固定步已推进状态，原生Zone在本帧mainPost统一提交；在PostUpdate后验。
                if weather=="rain" then check(Environment.GetStatus().rainIntensity>0,"雨目标未驱动真实平滑降水状态") end
                if weather=="fog" then
                    check(Environment.GetStatus().fogIntensity>0 and Environment.GetStatus().fogEnd<baseline_.fogStartEnd,
                        "雾目标未收近真实视距")
                end
                tap(assert(Hud.GetRoot()),"pauseGame")
                check(Hud.GetReadings().paused,"天气截图前无法真实暂停")
                if weather=="fog" then
                    baseline_.environment=Environment.Export()
                    check(baseline_.environment.fog>0 and baseline_.environment.fog<1,"未覆盖保存平滑过渡中的fog权重")
                    check(SaveJourneyNow(),"真实fog旅程保存失败")
                    assertEnvironment(assert(Save.Get()).journey.environment,"写档fog")
                    pendingCapture_="playing-fog"
                    nextStage("selecting")
                else
                    if weather=="rain" then baseline_.fogStartEnd=Environment.GetStatus().fogEnd end
                    pendingCapture_="playing-"..weather
                    weatherIndex_=weatherIndex_+1
                    nextStage("weather-start")
                end
            end
        elseif stage_=="selecting" and frames_>=stageFrame_+2 then
            baseline_.s,baseline_.xp,baseline_.nextIndex=Train.GetS(),Game.GetXp(),Game.GetNextStation().index
            baseline_.trainRoot=Train.GetRoot()
            baseline_.onboard,baseline_.waiting=Passenger.GetStatus().onboard,Passenger.GetStatus().waiting
            tap(assert(Hud.GetRoot()),"openTrainSelector")
            check(assert(Hud.GetTrainSelector()):IsOpen(),"真实换车选择器未打开")
            tap(assert(Hud.GetRoot()),"selectTrain_DF4D")
            tap(assert(Hud.GetRoot()),"confirmTrain")
            nextStage("switching")
        elseif stage_=="switching" and not assert(Hud.GetTrainSelector()):IsBusy() then
            check(Train.GetSelectedId()=="DF4D" and Train.ValidateBindings(),"DF4D切车未绑定实际八节MDL")
            check(Train.GetRoot()==baseline_.trainRoot and math.abs(Train.GetS()-baseline_.s)<.00001,"切车改变根或线路s")
            check(Game.GetXp()==baseline_.xp and Game.GetNextStation().index==baseline_.nextIndex,"切车破坏经验/站序")
            check(Passenger.GetStatus().onboard==baseline_.onboard and Passenger.GetStatus().waiting==baseline_.waiting,
                "切车丢失真实乘客清单")
            check(Train.GetThrottle()==0 and Train.GetBrake()==1 and Hud.GetReadings().paused,"切车未保留用户暂停/安全制动")
            check(Audio.GetPowerType()=="diesel","DF4D音频动力未同步")
            for _,car in ipairs(Train.GetCars()) do
                local model=assert(car.drawable).model
                check(model~=nil and model.name==assert(Catalog.Assets[car.profile]).modelPath,"DF4D车壳被程序占位替代")
            end
            checkDoors(true)
            assertEnvironment(baseline_.environment,"DF4D换车")
            baseline_.camera=Camera.GetMode()
            baseline_.trainRoot=nil -- 不由验收额外持有旧场景节点。
            check(SaveJourneyNow(),"DF4D旅程保存失败")
            local disk=File(SAVE_PATH,FILE_READ)
            check(disk:IsOpen(),"设备存档未落盘")
            local saved=cjson.decode(disk:ReadString());disk:Dispose()
            check(saved.journey.train.id=="DF4D" and saved.journey.environment.weather=="fog"
                and math.abs(saved.journey.environment.fog-baseline_.environment.fog)<.00001,"磁盘DF4D/fog未保真")
            check(saved.journey.game.timetable~=nil,"磁盘没有站点时刻表")
            baseline_.savedTimetable=saved.journey.game.timetable
            baseline_.savedMinutes=saved.journey.environment.minutes
            check(saved.journey.train.topology.mode=="cn_left_v1" and saved.journey.train.topology.baseLane==0,
                "磁盘未保存中国左行拓扑")
            pendingCapture_="df4d-retained"
            nextStage("return")
        elseif stage_=="return" and frames_>=stageFrame_+2 then
            tap(assert(Hud.GetRoot()),"toggleOperations")
            tap(assert(Hud.GetRoot()),"returnMainMenu","operationsDetails")
            check(GetApplicationState()=="menu","真实返回按钮未到主菜单")
            checkReleased("first-return")
            pendingCapture_="menu-after-return"
            nextStage("continue")
        elseif stage_=="continue" and frames_>=stageFrame_+3 then
            checkReleased("idle-menu")
            -- 同一进程真正Stop/Start，Save.Load回读设备文件；不是只检查内存savedJourney。
            mainStop()
            checkReleased("warm-stop")
            mainStart()
            check(GetApplicationState()=="menu" and GetGameScene()==nil and renderer.numViewports==0,
                "warm Start遗留旧场景")
            local loaded=assert(Save.Get())
            check(loaded.journey.train.id=="DF4D" and loaded.journey.environment.weather=="fog",
                "warm Start未回读DF4D/fog设备存档")
            tap(assert(Menu.GetRoot()),"continueGame")
            check(GetApplicationState()=="loading","真实继续按钮未进入loading")
            nextStage("restoring")
        elseif stage_=="restoring" and GetApplicationState()=="playing" then
            check(Train.GetSelectedId()=="DF4D" and Train.GetCarCount()==8 and Train.ValidateBindings(),"继续旅程DF4D实际MDL丢失")
            check(math.abs(Train.GetS()-baseline_.s)<.001 and Game.GetXp()==baseline_.xp
                and Game.GetNextStation().index==baseline_.nextIndex,"继续旅程s/经验/站序改变")
            check(Camera.GetMode()==baseline_.camera and Hud.GetReadings().paused,"继续旅程相机/安全暂停丢失")
            check(Passenger.GetStatus().onboard==baseline_.onboard and Passenger.GetStatus().waiting==baseline_.waiting,
                "继续旅程乘客清单丢失")
            local resumedTimetable=assert(Game.ExportState().timetable)
            check(#resumedTimetable.rows==#baseline_.savedTimetable.rows,"继续旅程时刻表行丢失")
            for index,row in ipairs(baseline_.savedTimetable.rows) do
                local actual=assert(resumedTimetable.rows[index])
                for _,key in ipairs({"stationIndex","trip","phase","plannedArrival","plannedDeparture","actualArrival","actualDeparture"}) do
                    local equal=type(actual[key])=="number" and type(row[key])=="number"
                        and math.abs(actual[key]-row[key])<.000001 or actual[key]==row[key]
                    check(equal,"继续旅程计划/实际改变 "..index.." "..key)
                end
            end
            check(math.abs(Environment.GetClock().minutes-baseline_.savedMinutes)<.000001,"继续旅程世界绝对分钟丢失")
            check(assert(announcements_):GetStatus().queued==0,"继续旅程重播旧广播队列")
            assertEnvironment(baseline_.environment,"继续恢复fog")
            checkDoors(true)
            nextStage("restored-world")
        elseif stage_=="restored-world" and frames_>=stageFrame_+2 then
            checkWorld("warm-continue",false)
            check(Infrastructure.GetStats().duplicateBuilds==0,"warm restart重复建设施")
            assertEnvironment(baseline_.environment,"恢复后保持fog暂停")
            pendingCapture_="continued-fog-df4d"
            nextStage("scenery-observe")
        elseif stage_=="scenery-observe" and frames_>=stageFrame_+2 then
            local plot=assert(Scenery.GetExclusions()[1],"没有可观察的合法景物plot")
            for _,item in ipairs(Scenery.GetExclusions()) do
                if math.abs(item.s-baseline_.s)<math.abs(plot.s-baseline_.s) then plot=item end
            end
            check(Hud.GetReadings().paused,"观察流式plot前真实驾驶未暂停")
            -- 仅验收观察传送；不声称实际驾驶抵达，不直接Build或修改流式预算。
            -- 先完成全部DF4D/fog/客流读档断言，避免用观察传送冒充旅程恢复。
            baseline_.observeS=plot.s
            baseline_.sceneryPlanned=Scenery.GetStats().planned
            Train.Reset(plot.s)
            Camera.SetMode("side")
            print(string.format("[ChinaRailApplication] OBSERVATION_TELEPORT s=%.3f kind=%s realDrivingArrival=false directBuildCalls=0",plot.s,plot.kind))
            nextStage("scenery-stream")
        elseif stage_=="scenery-stream" then
            local elapsed=frames_-stageFrame_
            if elapsed==1 or elapsed%20==0 or elapsed>=110 then logSceneryQueue("observing-plot") end
            check(elapsed<110,"合法plot正常mainPost流式生成超出110帧预算")
            if Scenery.GetStats().vertices>0 then
                logSceneryQueue("plot-geometry-ready")
                checkWorld("plot-streamed",true)
                check(math.abs(Stream.GetStats().lastS-baseline_.observeS)<.001,"流式目标不是实际观察里程")
                check(Scenery.GetStats().planned==baseline_.sceneryPlanned,"流式生成改变全线解析规划")
                pendingCapture_="streamed-road-scenery"
                nextStage("final-return")
            end
        elseif stage_=="final-return" and frames_>=stageFrame_+2 then
            tap(assert(Hud.GetRoot()),"toggleOperations")
            tap(assert(Hud.GetRoot()),"returnMainMenu","operationsDetails")
            checkReleased("warm-final-return")
            nextStage("complete")
        elseif stage_=="complete" and frames_>=stageFrame_+3 then
            checkReleased("warm-idle-menu")
            check(renderedWorldFrames_>=30,"未获得足够真实主场景帧")
            print(string.format("CHINA_RAIL_APPLICATION_LOGIC_PASS checks=%d frames=%d missingCaptures=%d realMain=true realTouch=true weatherCases=%d fogTransitionSaved=true mdlDF4DRetained=true leftRunning=true warmRestart=true",
                checks_,frames_,#missingCaptures_,#weatherCases_))
            check(#missingCaptures_==0 and captures_>=(compact_ and 13 or 17),"真实截图缺项，不能声明完整E2E PASS："..table.concat(missingCaptures_,","))
            table.sort(sampleMs_);table.sort(sampleDraws_);table.sort(sampleTriangles_)
            local count=#sampleMs_
            print(string.format("[ChinaRailApplication] NATIVE_SAMPLE playingFrames=%d samples=%d frameMsMedian=%.2f frameMsMax=%.2f nativeDrawCallsMin=%.0f nativeDrawCallsMax=%.0f nativeTrianglesMin=%.0f nativeTrianglesMax=%.0f softwareGLES=true fps60=NOT_CLAIMED",
                renderedWorldFrames_,count,sampleMs_[math.max(1,math.ceil(count*.5))] or 0,sampleMs_[count] or 0,
                sampleDraws_[1] or 0,sampleDraws_[#sampleDraws_] or 0,sampleTriangles_[1] or 0,sampleTriangles_[#sampleTriangles_] or 0))
            print(string.format("ALL_CHINA_RAIL_APPLICATION_VALIDATION_PASS checks=%d frames=%d captures=%d realMain=true realTouch=true weatherCases=%d fogTransitionSaved=true mdlDF4DRetained=true leftRunning=true doorSide=true roadScenery=true warmRestart=true externalCloudCalls=0 selectedFemaleVoices=34/34 timetableRestored=true bridges=4 tunnels=7",checks_,frames_,captures_,#weatherCases_))
            complete_=true
        end
    end)
end
---@param eventType string
---@param eventData PostUpdateEventData
function HandlePostUpdate(eventType,eventData)
    guard(function()
        mainPost(eventType,eventData)
        if GetApplicationState()=="playing" then assertNativeZone() end
    end)
end
function Stop()
    -- mainStop保存/释放期间仍保持禁云；只删除本次独立运行新建的测试档。
    if started_ then mainStop() end
    Announcements.new=announcementsNew
    Save.SetCloud,Save.ReadCloud=saveSetCloud,saveReadCloud
    if isolated_ then
        check(not fileSystem:FileExists(SAVE_PATH) or fileSystem:Delete(SAVE_PATH),"隔离测试档清理失败")
        print(string.format("[ChinaRailApplication] ISOLATED_SAVE_CLEANED priorSaveAbsent=true cloudRequests=%d interceptedCloudReads=%d externalCloudCalls=0 completed=%s",cloudRequests_,cloudReads_,tostring(complete_)))
    end
    if not complete_ and not failed_ then log:Write(LOG_ERROR,"[ChinaRailApplication] INCOMPLETE stage="..stage_.." frame="..frames_) end
end
