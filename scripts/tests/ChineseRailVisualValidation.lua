-- 基于既有3D场景/StationSign验证脚手架，真实生产几何读回截图；不用AI替代图。
-- 不运行main，不读/写存档，不调用云；受控帧推进，不依赖渲染墙钟时间。
local Route=require "world.Route"
local Rail=require "world.RailNetwork"
local Track=require "world.Track"
local Station=require "world.Station"
local Yard=require "world.StationYard"
local World=require "world.WorldMaterials"
local Train=require "train.Train"
local Traffic=require "game.Traffic"
---@type Scene?
local scene_=nil
---@type Node?
local owner_=nil
---@type Node?
local camera_=nil
local phase_,age_,captures_=1,0,0
local phaseRenderFrames_,warmReadbacks_,holdFrames_=0,0,0
local captured_=false
---@type Vector3
local expectedCamera_=Vector3.ZERO
---@type Vector3
local expectedLook_=Vector3.ZERO
local expectedTrainS_=0
local expectedReversing_=false
local expectedLane_,expectedBaseLane_,expectedTurnbackLane_=0,0,0
local failed_=false
local cases_={"station_left_running","west_crossover_before","west_crossover_middle","west_crossover_cleared","up_platform"}
local function guard(fn)
    if failed_ then return end
    local ok,message=xpcall(fn,debug.traceback)
    if not ok then failed_=true;log:Write(LOG_ERROR,tostring(message));engine:Exit() end
end
local function buildAt(st)
    if owner_ then owner_:Dispose();Yard.Shutdown();Station.Shutdown() end
    owner_=assert(scene_):CreateChild("ChineseRailTopology")
    Station.Init();Yard.Init()
    Station.BuildOne(owner_,st)
    Yard.Build(owner_,st)
    for s=st.s-1200,st.s+560,120 do Track.BuildChunk(owner_:CreateChild("ActualTrack"),math.max(0,s),math.min(Route.GetLength(),s+120),true) end
    local ground=World.NewBatch(owner_:CreateChild("Ground"),World.Solid(Color(.29,.34,.22),0,1),false)
    ground:AddBox(Route.SampleOffset(st.s-300,0,-.12),Vector3(500,.20,2100),math.rad(select(3,Route.Sample(st.s))))
    ground:Finish()
end
local function aim(position,target)
    expectedCamera_,expectedLook_=position,target
    assert(camera_).position=position
    camera_:LookAt(target)
end
local function verifyIdentity()
    local node=assert(camera_)
    assert((node.position-expectedCamera_):Length()<.0001,"case camera position drift")
    local direction=(expectedLook_-expectedCamera_):Normalized()
    assert(node.worldDirection:DotProduct(direction)>.99999,"case camera look direction drift")
    assert(math.abs(Train.GetS()-expectedTrainS_)<.0001 and Train.IsReversing()==expectedReversing_,
        "case train identity/position changed before readback")
    local crossing=Rail.GetTurnback()
    assert(Rail.GetPlayerLane(Train.GetS())==expectedLane_ and Rail.GetBaseLane()==expectedBaseLane_
        and (crossing and crossing.lane or 0)==expectedTurnbackLane_,"case topology identity drift")
end
local function setView()
    phaseRenderFrames_,warmReadbacks_,holdFrames_=0,0,0
    captured_=false
    local stations=Route.GetStations()
    local last=stations[#stations]
    if phase_==1 then
        buildAt(stations[3])
        Train.Reset(stations[3].s)
        aim(Route.SampleOffset(stations[3].s-360,185,180),Route.SampleOffset(stations[3].s-70,-7,0))
    elseif phase_>=2 and phase_<=4 then
        Traffic.Shutdown()
        if phase_==2 then buildAt(last) end
        Train.Reset(last.s)
        assert(Train.ToggleReversing())
        local cross=assert(Rail.GetTurnback())
        local s=phase_==2 and cross.last+20 or (phase_==3 and (cross.first+cross.last)/2+80 or cross.first-Train.GetActiveLength()-30)
        local saved=Train.ExportState();saved.s=s;saved.v=0
        Train.RestoreState(saved);Train.UpdateVisuals(0)
        local mid=(cross.first+cross.last)/2
        aim(Route.SampleOffset(mid-160,95,145),Route.SampleOffset(mid,2.5,0))
    else
        buildAt(stations[3])
        local saved=Train.ExportState();saved.s=stations[3].s;saved.v=0;saved.reversing=true
        saved.topology={mode=Rail.GetTopologyMode(),baseLane=1}
        Train.RestoreState(saved);Train.UpdateVisuals(0)
        aim(Route.SampleOffset(stations[3].s-115,35,10),Route.SampleOffset(stations[3].s-75,6,2.2))
    end
    expectedTrainS_,expectedReversing_=Train.GetS(),Train.IsReversing()
    expectedLane_=Rail.GetPlayerLane(expectedTrainS_)
    expectedBaseLane_=Rail.GetBaseLane()
    local crossing=Rail.GetTurnback()
    expectedTurnbackLane_=crossing and crossing.lane or 0
    Traffic.Init(nil)
    Yard.UpdateSignals(Traffic)
    print("[ChineseRailVisual] actual scene "..cases_[phase_])
end
function Start()
    guard(function()
        Route.Build();scene_=Scene();scene_:CreateComponent("Octree")
        local zone=scene_:CreateComponent("Zone")
        zone.boundingBox=BoundingBox(Vector3(-60000,-2000,-60000),Vector3(60000,2000,60000))
        zone.priority=10000
        zone.ambientSource=AMBIENT_COLOR;zone.ambientColor=Color(.30,.33,.36)
        zone.fogColor=Color(.61,.72,.81);zone.depthFogStart=20000;zone.depthFogEnd=40000
        zone.autoExposureEnabled=false;zone.bloomWeight=0;zone.tonemapMode=TONEMAP_MODE_ACES
        zone.heightFogEnable=false;zone.depthFogEnable=false;zone.volumetricFogEnabled=false
        zone.heightFogDensity=0;zone.depthFogDensity=0;zone.volumetricFogDensity=0
        local sunNode=scene_:CreateChild("Sun");sunNode.direction=Vector3(.35,-1,.55)
        local sun=sunNode:CreateComponent("Light");sun.lightType=LIGHT_DIRECTIONAL;sun.brightness=1.5
        renderer.hdrRendering=true;renderer.drawShadows=false
        camera_=scene_:CreateChild("AcceptanceCamera")
        local camera=camera_:CreateComponent("Camera");camera.fov=55;camera.farClip=4000;camera.nearClip=.5
        renderer:SetViewport(0,Viewport:new(scene_,camera))
        Train.Build(scene_)
        setView()
        SubscribeToEvent("Update","HandleChineseRailVisualUpdate")
        SubscribeToEvent("EndRendering","HandleChineseRailVisualCapture")
    end)
end
function HandleChineseRailVisualUpdate()
    guard(function()
        age_=age_+1
        verifyIdentity()
    end)
end
function HandleChineseRailVisualCapture()
    guard(function()
        verifyIdentity()
        phaseRenderFrames_=phaseRenderFrames_+1
        if captured_ then
            holdFrames_=holdFrames_+1
            if holdFrames_<2 then return end
            phase_,age_=phase_+1,0
            if phase_>#cases_ then
                print("CHINESE_RAIL_VISUAL_ALL_PASS actualCaptures="..captures_)
                engine:Exit()
            else setView() end
            return
        end
        if age_<10 or phaseRenderFrames_<10 then return end
        local image=Image()
        if not graphics:TakeScreenShot(image) then image:Dispose();return end
        verifyIdentity()
        if warmReadbacks_==0 then
            warmReadbacks_=1
            image:Dispose()
            print("[ChineseRailVisual] READBACK_WARMUP_DISCARDED "..cases_[phase_])
            return
        end
        assert(image.width==graphics:GetWidth() and image.height==graphics:GetHeight(),"readback size is not current framebuffer")
        local output="/workspace/screenshots/china_topology_"..cases_[phase_]..".png"
        assert(image:SavePNG(output),"real screenshot not saved")
        image:Dispose();captures_=captures_+1;captured_=true
        print(string.format("[ChineseRailVisual] REAL_CAPTURE %s lockedUpdate=%d lockedRender=%d s=%.3f lane=%d base=%d turnback=%d camera=%.3f,%.3f,%.3f",
            output,age_,phaseRenderFrames_,expectedTrainS_,expectedLane_,expectedBaseLane_,expectedTurnbackLane_,
            expectedCamera_.x,expectedCamera_.y,expectedCamera_.z))
    end)
end
