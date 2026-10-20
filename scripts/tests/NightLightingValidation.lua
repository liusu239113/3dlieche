-- 夜景真实像素回归：生产站台/道路/列车Spot，不读玩家存档、不加载main、不改渲染管线。
-- 复用scaffold-3d-scene持有Scene/Camera；EndRendering读回开关对照，不能仅以Light节点存在判通过。
local Route = require "world.Route"
local Station = require "world.Station"
local Road = require "world.RoadCorridor"
local Track = require "world.Track"
local World = require "world.WorldMaterials"
local Environment = require "world.Environment"
local NightLighting = require "world.NightLighting"
local Train = require "train.Train"
---@type Scene?
local scene_ = nil
---@type Node?
local cameraNode_ = nil
---@type Node?
local beamRoot_ = nil
---@type Node?
local stationRoot_ = nil
---@type Image?
local previous_ = nil
local frame_, phase_, checks_ = 0, 1, 0
local done_ = false
local names_ = {"station_off","station_on","road_off","road_on","headlight_off","headlight_on"}
local s_, stationS_ = 0.0, 0.0
local minDelta_ = math.huge
local function check(v,message) checks_=checks_+1; assert(v,"[NightLightingValidation] "..message) end
local function guard(action)
    if done_ then return end
    local ok,err=xpcall(action,debug.traceback)
    if not ok then done_=true;log:Write(LOG_ERROR,tostring(err));engine:Exit() end
end
local function aim(s,lateral,height,targetS,targetLateral,targetHeight)
    cameraNode_.position=Route.SampleOffset(s,lateral,height)
    cameraNode_:LookAt(Route.SampleOffset(targetS,targetLateral,targetHeight))
end
local function activate()
    local on=phase_%2==0
    if phase_<=2 then
        aim(stationS_-170,-26,8,stationS_-45,-1,1.5)
    elseif phase_<=4 then
        local pos,right = Road.Sample(s_)
        local forward = Vector3(-right.z,0,right.x)
        cameraNode_.position = pos-forward*28-right*8+Vector3(0,4.5,0)
        cameraNode_:LookAt(pos+forward*45+Vector3(0,1,0))
    else
        aim(s_-26,0,3.6,s_+100,0,.34)
    end
    NightLighting.SetEnvironment((phase_<=4 and on) and 1 or 0,"medium")
    Station.SetEnvironment((phase_<=2 and on) and 1 or 0)
    -- Station.SetEnvironment也驱动共享池，路段case单独重设。
    if phase_>=3 then NightLighting.SetEnvironment(phase_==4 and 1 or 0,"medium") end
    for _, light in ipairs(beamRoot_:GetComponents("Light",true)) do light.enabled=phase_==6 end
    NightLighting.Update(cameraNode_.worldPosition)
    frame_=0
    print("[NightLightingValidation] CASE "..names_[phase_])
end
function Start()
    guard(function()
        Route.Build();Track.Init()
        scene_=Scene();scene_:CreateComponent("Octree")
        renderer.hdrRendering=true;renderer.drawShadows=false
        renderer.materialQuality=QUALITY_MEDIUM;renderer.specularLighting=false
        local group=scene_:CreateChild("NightLighting")
        local zone=group:CreateComponent("Zone")
        zone.boundingBox=BoundingBox(-100000,100000)
        zone.ambientSource=AMBIENT_COLOR;zone.ambientColor=Color(.075,.090,.125)
        zone.fogColor=Color(.03,.045,.08);zone.depthFogStart=1200;zone.depthFogEnd=4000
        zone.autoExposureEnabled=false;zone.vignetteEnabled=false;zone.tonemapMode=TONEMAP_MODE_ACES
        zone.bloomWeight=0;zone.ssaoIntensity=0;zone.ssrEnabled=false;zone.ssgiEnabled=false;zone.volumetricFogEnabled=false
        local moon=group:CreateChild("Moon"):CreateComponent("Light")
        moon.lightType=LIGHT_DIRECTIONAL;moon.color=Color(.55,.66,1);moon.brightness=.30
        moon.node.direction=Vector3(.35,-1,.25)
        local ground=World.NewBatch(scene_:CreateChild("Ground"),World.Solid(Color(.24,.30,.18),0,1),false,20)
        local center=Route.Sample(2000)
        ground:AddBox(Vector3(center.x,-.25,center.z),Vector3(14000,.5,14000));ground:Finish()
        local station=Route.GetStations()[1]
        stationS_=station.s
        stationRoot_=scene_:CreateChild("StationFixture")
        Station.Init();Station.BuildOne(stationRoot_,station)
        Road.Init(scene_)
        s_=stationS_+1300
        for s=math.max(0,stationS_-250),stationS_+220,120 do Track.BuildChunk(scene_,s,s+120,true) end
        for s=s_-240,s_+360,120 do
            Track.BuildChunk(scene_,s,s+120,true)
            Road.BuildChunk(scene_,s,s+120)
        end
        beamRoot_=scene_:CreateChild("ProductionHeadlightFixture")
        beamRoot_.position=Route.Sample(s_-16)
        local _,_,yaw=Route.Sample(s_-16);beamRoot_.rotation=Quaternion(yaw,Vector3.UP)
        Train.BuildHeadlight(beamRoot_,24)
        cameraNode_=scene_:CreateChild("NightCamera")
        local camera=cameraNode_:CreateComponent("Camera")
        camera.nearClip,camera.farClip,camera.fov=.1,4200,62
        camera.viewMask=3
        renderer:SetViewport(0,Viewport:new(scene_,camera))
        local stats=NightLighting.GetDiagnostics()
        check(stats.stationSites>=36,"三座平台灯位不足")
        check(stats.roadSites>=20,"道路两侧没有沿流式chunk建灯")
        activate()
        SubscribeToEvent("Update","NightValidationUpdate")
        SubscribeToEvent("EndRendering","NightValidationCapture")
    end)
end
function NightValidationUpdate()
    guard(function()
        frame_=frame_+1
        NightLighting.Update(cameraNode_.worldPosition)
    end)
end
function NightValidationCapture()
    guard(function()
        if frame_<5 then return end
        local image=Image()
        check(graphics:TakeScreenShot(image),"真实帧缓冲读取失败")
        check(image:SavePNG("/workspace/screenshots/night_lighting_"..names_[phase_]..".png"),"截图写盘失败")
        local stats=NightLighting.GetDiagnostics()
        check(stats.poolLights<=26 and stats.activeStation<=18 and stats.activeRoad<=8,"超过标准投光预算")
        if phase_%2==0 then
            check(previous_~=nil,"缺少关灯对照")
            local total,increase,bright=0,0,0
            for y=math.floor(image.height*.35),image.height-1,3 do
                for x=0,image.width-1,3 do
                    local a,b=image:GetPixel(x,y),previous_:GetPixel(x,y)
                    local la=(a.r+a.g+a.b)/3
                    local lb=(b.r+b.g+b.b)/3
                    total=total+1
                    if la>lb+.012 then increase=increase+1 end
                    if la>.95 then bright=bright+1 end
                end
            end
            local delta=increase/total
            minDelta_=math.min(minDelta_,delta)
            -- 道路只占当前画面约8%，不能把站台的大面积阈值套在细长路面上。
            check(delta>(phase_==4 and .002 or .005),"开灯真实像素无变化："..names_[phase_].." delta="..delta)
            check(bright/total<.12,"夜景大面积泛白："..names_[phase_])
            print(string.format("[NightLightingValidation] PIXELS %s lit=%.5f white=%.5f station=%d road=%d batches=%d primitives=%d",
                names_[phase_],delta,bright/total,stats.activeStation,stats.activeRoad,graphics.numBatches,graphics.numPrimitives))
            previous_:Dispose();previous_=nil
            image:Dispose()
        else previous_=image end
        if phase_==#names_ then
            Station.Forget(1)
            check(NightLighting.GetDiagnostics().stationSites==0,"卸载站台残留灯位")
            for s=s_-240,s_+360,120 do Road.ForgetChunk(s,s+120) end
            check(NightLighting.GetDiagnostics().roadSites==0,"道路流式卸载残留灯位")
            NightLighting.SetEnvironment(1,"low");NightLighting.Update(cameraNode_.worldPosition)
            check(NightLighting.GetDiagnostics().poolLights<=18,"低档没有缩减池")
            NightLighting.SetEnvironment(0);NightLighting.Update(cameraNode_.worldPosition)
            check(NightLighting.GetDiagnostics().activeStation==0 and NightLighting.GetDiagnostics().activeRoad==0,"白天未关闭投光")
            print(string.format("ALL_NIGHT_LIGHTING_VALIDATION_PASS checks=%d screenshots=6 minimumLitDelta=%.5f maxRefreshMs=%.3f",
                checks_,minDelta_,NightLighting.GetDiagnostics().maxRefreshMs))
            done_=true
        else phase_=phase_+1;activate() end
    end)
end
function Stop()
    Station.Shutdown();Road.Shutdown();NightLighting.Shutdown()
    if previous_ then previous_:Dispose() end
end
