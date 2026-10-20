-- 参考场景真实生产帧验收：复用3D scene scaffold与NightProductionValidation的存档隔离。
-- 只调用main/WorldStream生产代码；等playing与近景实体就绪，记录远景队列余量再读真实帧。
-- 验收图片只写screenshots，绝不读取/改写玩家旅程，不把节点计数冒充画面复刻程度。
local Save=require "game.SaveStore"
local originalLoad,originalWrite,originalCloud,originalSet=Save.Load,Save.Write,Save.ReadCloud,Save.SetCloud
Save.Load=function() return nil end
Save.Write=function() return true end
Save.ReadCloud=function(callback) callback(nil) end
Save.SetCloud=function() end
require "main"
local mainStart,mainUpdate,mainPost,mainStop=Start,HandleUpdate,HandlePostUpdate,Stop
local Train=require "train.Train"
local Route=require "world.Route"
local Camera=require "train.Camera"
local Stream=require "world.WorldStream"
local Terrain=require "world.Terrain"
local Environment=require "world.Environment"
local Station=require "world.Station"
local Night=require "world.NightLighting"
local Landmarks=require "world.Landmarks"
local UI=require "urhox-libs/UI"
local Json=require "cjson"
local index_,frames_,settled_,captures_,checks_=1,0,0,0,0
local ready_,done_,stopped_=false,false,false
local cases_={}
local currentS_=-1.0
local warmed_=false
local evidence_={}
local OUTPUT="/workspace/screenshots/reference_scene_"
local selected_="all"
local expected_=12
local Config=require "config.GameConfig"
---@type string[]
local criticalKeys_={}
---@type Viewport|nil
local productionViewport_=nil
local viewportBound_=false
local renderFrames_=0
for _,arg in ipairs(GetArguments()) do
    local value=arg:match("^%-reference%-case=(.+)$")
    if value then selected_=value end
end
local function check(value,message)
    checks_=checks_+1
    assert(value,"[ReferenceScene] "..message)
end
local function cleanup()
    if stopped_ then return end
    stopped_=true
    pcall(mainStop)
    Save.Load,Save.Write,Save.ReadCloud,Save.SetCloud=originalLoad,originalWrite,originalCloud,originalSet
end
local function guard(action)
    if done_ then return end
    local ok,message=xpcall(action,debug.traceback)
    if not ok then
        done_=true;print("REFERENCE_SCENE_FAIL "..tostring(message));log:Write(LOG_ERROR,tostring(message))
        cleanup();engine:Exit()
    end
end
local function prepare()
    local st=assert(Route.GetStations()[1])
    local bridge=nil ---@type RailwayLandmark?
    for _,def in ipairs(Landmarks.GetDefinitions()) do
        if def.kind=="bridge" then bridge=def;break end
    end
    check(bridge~=nil,"没有真实生产高架桥")
    local ruralS=st.s+1400
    local forestS=nil ---@type number?
    for _,region in ipairs(Config.RouteRegions or {}) do
        if region.theme=="forest" and not forestS then
            for s=region.first+1120,region.last-1120,160 do
                local clear=Landmarks.GetEnvironmentAt(s)=="forest"
                for _,station in ipairs(Route.GetStations()) do
                    if math.abs(s-station.s)<2900 then clear=false;break end
                end
                for _,def in ipairs(Landmarks.GetDefinitions()) do
                    if s+1050>def.first and s-1050<def.last then clear=false;break end
                end
                if clear then forestS=s;break end
            end
        end
    end
    check(forestS~=nil,"没有满足净空的真实forest验收区间")
    local terminal=assert(Route.GetStations()[10])
    cases_={
        {name="01_platform_day",s=st.s,hour=12,along=-185,lateral=-5.4,eye=3.25,look=-20,targetX=-5.4,targetY=4.4},
        {name="02_station_day_overview",s=st.s,hour=12,along=85,lateral=63,eye=23,look=-95,targetX=-12,targetY=4.2},
        {name="03_platform_night",s=st.s,hour=22,along=-185,lateral=-5.4,eye=3.25,look=-20,targetX=-5.4,targetY=4.4},
        {name="04_city_models_day",s=st.s,hour=12,along=-90,lateral=148,eye=9.5,look=210,targetX=185,targetY=18},
        {name="05_blue_nose_headlights",s=ruralS,hour=22,train="CRH380A",along=38,lateral=-6.5,eye=4.0,look=9,targetX=0,targetY=2.0},
        {name="06_night_driving_track",s=ruralS,hour=22,train="CRH380A",along=15.0,lateral=0,eye=2.7,look=110,targetX=0,targetY=.5},
        {name="07_near_mid_far_forest",s=assert(forestS),hour=12,along=-75,lateral=-22,eye=22,look=260,targetX=35,targetY=13},
        {name="08_bridge_piers_landscape",s=assert(bridge).s,hour=12,along=-170,lateral=-150,eye=47,look=75,targetX=2.5,targetY=-7},
        {name="09_corridor_driver_day",s=assert(Route.GetStations()[2]).s-2800,hour=12,camera="cab",along=0,lateral=0,eye=3.3,look=220,targetX=0,targetY=3.0},
        {name="10_mountain_driver_day",s=terminal.s-1800,hour=12,camera="cab",along=0,lateral=0,eye=3.3,look=220,targetX=0,targetY=3.0},
        {name="11_terminal_platform_day",s=terminal.s,hour=12,along=-185,lateral=-5.4,eye=3.25,look=-20,targetX=-5.4,targetY=4.4},
        {name="12_terminal_platform_night",s=terminal.s,hour=22,along=-185,lateral=-5.4,eye=3.25,look=-20,targetX=-5.4,targetY=4.4},
    }
    if selected_~="all" then
        local selected={}
        for _,case in ipairs(cases_) do
            if case.name==selected_ then selected[#selected+1]=case end
        end
        check(#selected==1,"未找到指定镜头："..selected_)
        cases_=selected;expected_=1
    end
end
local function planCritical(case)
    criticalKeys_={}
    local seen={}
    local function add(key)
        if not seen[key] then criticalKeys_[#criticalKeys_+1]=key;seen[key]=true end
    end
    local function window(kind,step,behind,ahead)
        local first=math.floor(math.max(0,case.s-behind)/step)
        local last=math.ceil((math.min(Route.GetLength(),case.s+ahead)-.000001)/step)-1
        for index=first,last do add(kind.."_"..index) end
    end
    window("nearRail",Config.WorldStream.TrackChunkLength,240,240)
    if Config.MountainTerrain and case.s>(Config.MountainTerrain.First or 0) then
        -- 山区远地表是独立生产任务；没有它时远坡会露出雾底，不能当成完整林海。
        window("mountainBackdrop",Config.WorldStream.TrackChunkLength,960,1440)
    end
    window("infrastructure",Config.WorldStream.InfrastructureChunkLength,320,320)
    window("scenery",Config.WorldStream.SceneryChunkLength,720,720)
    window("vegetation",80,400,640)
    window("woodland",160,560,800)
    window("forest",160,640,960)
    local size=Config.WorldStream.TerrainCellSize
    local position=Route.Sample(case.s)
    local cx,cz=math.floor(position.x/size),math.floor(position.z/size)
    for x=cx-3,cx+3 do for z=cz-3,cz+3 do add("terrain_"..x.."_"..z) end end
    for ds=400,1000,120 do
        for _,lateral in ipairs({-300,-150,0,150,300}) do
            local point=Route.SampleOffset(case.s+ds,lateral,0)
            add("terrain_"..math.floor(point.x/size).."_"..math.floor(point.z/size))
        end
    end
    for index,station in ipairs(Route.GetStations()) do
        if math.abs(case.s-station.s)<.001 then
            add("station_"..index);add("city_"..index)
        end
    end
end
local function criticalReady()
    local root=Stream.GetStats().root
    local completed=0
    if root then
        for _,key in ipairs(criticalKeys_) do
            local node=root:GetChild(key)
            if node and node.enabled then completed=completed+1 end
        end
    end
    return completed==#criticalKeys_,completed
end
local function activate()
    local case=assert(cases_[index_])
    if case.train and Train.GetSelectedId()~=case.train then check(Train.Select(case.train,true),"蓝色动车装配失败") end
    local saved=Train.ExportState()
    saved.s,saved.v,saved.throttle,saved.brake=case.s,0,0,1
    saved.reversing,saved.moving,saved.derailed=false,false,false
    saved.topology=nil;saved.headlightMode=case.hour>=6 and case.hour<18 and "auto" or "on"
    Train.RestoreState(saved)
    check(math.abs(Train.GetS()-case.s)<.001,"生产列车恢复失败")
    if math.abs(currentS_-case.s)>500 then
        Stream.Reset(case.s)
    end
    currentS_=case.s
    planCritical(case)
    check(Config.WorldStream.FrameBudgetMs==3,"验收改变了生产流式预算")
    Environment.Configure({hour=case.hour,running=false,weather="clear"})
    Camera.SetMode(case.camera or "track_front")
    UI.SetRoot(nil)
    -- 仅预热时暂停viewport，仍用正式main的原Viewport/Scene/灯光；不渲染隐藏的半成品。
    renderer:SetNumViewports(0)
    viewportBound_,renderFrames_=false,0
    frames_,settled_,warmed_=0,0,false
    print("REFERENCE_SCENE_CASE "..Json.encode({index=index_,name=case.name,s=case.s,hour=case.hour}))
end
function Start()
    guard(function()
        mainStart();SetRenderQuality("medium");BeginJourney(false,"normal")
        SubscribeToEvent("EndFrame","HandleReferenceSceneCapture")
    end)
end
function HandleUpdate(eventType,eventData)
    guard(function()
        local event=VariantMap();event["TimeStep"]=Variant(.02)
        if not ready_ then
            mainUpdate(eventType,event --[[@as UpdateEventData]])
            if GetApplicationState()=="playing" then
                productionViewport_=assert(renderer:GetViewport(0))
                ready_=true;TogglePause();prepare();currentS_=Train.GetS();activate()
            end
            check(GetApplicationState()~="error","生产main场景加载失败")
            return
        end
        frames_=frames_+1
        -- 正式mainPost每帧调用一次Stream.Update；这里仅观察，不能双倍预算预热。
        local stream=Stream.GetStats()
        local nearby,completed=criticalReady()
        if nearby then settled_=settled_+1 else settled_=0 end
        if settled_>=5 and not viewportBound_ then
            renderer:SetNumViewports(1)
            renderer:SetViewport(0,assert(productionViewport_))
            viewportBound_=true
            print(string.format("REFERENCE_SCENE_READY critical=%d/%d pending=%d",completed,#criticalKeys_,stream.pendingTasks))
        end
        if frames_%120==0 then
            print(string.format("REFERENCE_SCENE_PENDING frames=%d critical=%d/%d pending=%d",frames_,completed,#criticalKeys_,stream.pendingTasks))
        end
        check(frames_<3600,"目标可见窗口未交付，不接受半成品截图")
    end)
end
function HandlePostUpdate(eventType,eventData)
    guard(function()
        mainPost(eventType,eventData)
        if not ready_ then return end
        local case=assert(cases_[index_])
        local node=assert(Camera.GetNode())
        if not case.camera then
            node.worldPosition=Route.SampleOffset(case.s+case.along,case.lateral,case.eye)
            node:LookAt(Route.SampleOffset(case.s+case.look,case.targetX,case.targetY))
        end
        Environment.Update(0,node.worldPosition)
        local status=Environment.GetStatus()
        Station.SetEnvironment(status.lampFactor)
        Train.UpdateHeadlight(status.lampFactor)
        Night.Update(node.worldPosition)
    end)
end
function HandleReferenceSceneCapture()
    guard(function()
        if not ready_ or not viewportBound_ then return end
        renderFrames_=renderFrames_+1
        if renderFrames_<12 then return end
        check(criticalReady(),"读回时可见生产窗口未就绪")
        local image=Image()
        if not graphics:TakeScreenShot(image) then
            image:Dispose()
            check(renderFrames_<36,"真实帧缓冲连续读回失败")
            return
        end
        if not warmed_ then warmed_=true;image:Dispose();return end
        local case=assert(cases_[index_])
        check(image.width==graphics:GetWidth() and image.height==graphics:GetHeight(),"读回并非当前分辨率")
        check(image:SavePNG(OUTPUT..case.name..".png"),"截图落盘失败")
        local width,height=image.width,image.height
        image:Dispose();captures_=captures_+1
        local decoded=Image()
        check(decoded:Load(OUTPUT..case.name..".png"),"截图PNG回读失败")
        check(decoded.width==width and decoded.height==height,"截图回读尺寸不符")
        local low,high=1.0,0.0
        for y=1,8 do for x=1,12 do
            local pixel=decoded:GetPixel(math.floor(width*x/13),math.floor(height*y/9))
            local value=(pixel.r+pixel.g+pixel.b)/3
            low,high=math.min(low,value),math.max(high,value)
        end end
        decoded:Dispose()
        check(high-low>.06,"不接受纯色/空白帧")
        local viewport=assert(productionViewport_)
        local group=assert(viewport.scene:GetChild("DayLighting"))
        local zone=assert(group:GetComponent("Zone"))
        local sun=assert(group:GetComponent("Light",true))
        print("REFERENCE_SCENE_RENDER_STATE "..Json.encode({hdr=renderer.hdrRendering,
            ambientSource=zone.ambientSource,ambient={zone.ambientColor.r,zone.ambientColor.g,zone.ambientColor.b},
            sun=sun.brightness,tonemap=zone.tonemapMode,bloomPlus=zone.bloomPlusEnabled,bloomWeight=zone.bloomWeight,
            autoExposure=zone.autoExposureEnabled,shadows=renderer.drawShadows}))
        local path=viewport.renderPath
        for i=0,path:GetNumCommands()-1 do
            local command=path:GetCommand(i)
            print(string.format("REFERENCE_SCENE_RENDER_COMMAND index=%d tag=%s enabled=%s pixel=%s defines=%s",
                i,command.tag,tostring(command.enabled),command.pixelShaderName,command.pixelShaderDefines))
        end
        local stream=Stream.GetStats()
        local lights=Night.GetStats()
        local head=Train.GetHeadlightDiagnostics()
        local world=Terrain.GetLandscapeStats()
        local row={name=case.name,captures=captures_,pending=stream.pendingTasks,batches=renderer.numBatches,
            criticalRequired=#criticalKeys_,criticalCompleted=select(2,criticalReady()),localWindowOnly=true,
            fullWorldComplete=stream.pendingTasks==0,width=width,height=height,budgetMs=Config.WorldStream.FrameBudgetMs,
            directProductionAssembly=true,primitives=renderer.numPrimitives,lights=lights,
            headlight={enabled=head.enabled,mode=head.mode,lights=head.lights,range=head.range,profile=head.profile,endSign=head.endSign},world=world}
        evidence_[#evidence_+1]=row
        print("REFERENCE_SCENE_REAL_FRAME "..Json.encode(row))
        if index_==#cases_ then
            check(captures_==expected_,"未完成全部真实截图")
            print(string.format("REFERENCE_SCENE_CAPTURE_PASS captures=%d checks=%d noSaveIO=true noCloudIO=true visualReviewRequired=true",captures_,checks_))
            done_=true;cleanup();engine:Exit()
        else index_=index_+1;activate() end
    end)
end
function Stop() cleanup() end
