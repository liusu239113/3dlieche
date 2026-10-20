-- 基于scaffold-3d-scene真实Scene/LightGroup/Camera，直接运行生产WorldStream。
-- 没有Game/main/Save/云、AI图片或替代景片。仅screenshots/relief_sandbox写图与证据。
local Route=require "world.Route"
local WorldStream=require "world.WorldStream"
local Landmarks=require "world.Landmarks"
local Terrain=require "world.Terrain"
local Quality=require "config.VisualQuality"
local Sky=require "world.Sky"
local Visual={}
---@type Scene?
local scene_=nil
---@type Node?
local camera_=nil
local index_,age_=1,0
local capturedAge_=-1
local readbackAttempts_=0
local warmed_=false
local complete_,failed_=false,false
local evidence_={}
local OUTPUT="/workspace/screenshots/relief_sandbox/"
local cases={
    {name="01_driver_langang_first_portal",s=8508,eye=4.1,look=180},
    {name="02_driver_true_tunnel_inside",s=8650,eye=4.1,look=170},
    {name="03_driver_group_open_cut",s=10450,eye=4.1,look=210},
    {name="04_driver_yuzen_cut_slope",s=11780,eye=4.1,look=220},
    {name="05_driver_yuzen_creek_bridge",s=13650,eye=4.1,look=240},
    {name="06_valley_bridge_real_supports",s=15470,eye=70,look=120,overview=true},
}
local singleCase_=false
for _,argument in ipairs(GetArguments()) do
    local selected=argument:match("^%-relief%-case=(%d+)$")
    if selected then
        index_=math.max(1,math.min(#cases,tonumber(selected) or 1));singleCase_=true
    end
end
local function guard(fn)
    if failed_ or complete_ then return end
    local ok,err=xpcall(fn,debug.traceback)
    if not ok then failed_=true;log:Write(LOG_ERROR,tostring(err));engine:Exit() end
end
local function activate()
    local case=cases[index_]
    WorldStream.Build(assert(scene_),case.s)
    local node=assert(camera_)
    if case.overview then
        node.position=Route.SampleOffset(case.s-150,-185,case.eye)
        node:LookAt(Route.SampleOffset(case.s,2.5,-7))
    else
        node.position=Route.SampleOffset(case.s,-.65,case.eye)
        node:LookAt(Route.SampleOffset(case.s+case.look,-.65,3.7))
    end
    age_=0;capturedAge_=-1;warmed_=false;readbackAttempts_=0
    print(string.format("[ReliefVisual] CASE %s chainage=%.3f eyeY=%.2f productionWorldStream=true",case.name,case.s,case.eye))
end
function Start()
    guard(function()
        Route.Build()
        Terrain.SetQuality(Quality.Get("low"))
        scene_=Scene();scene_:CreateComponent("Octree")
        renderer.hdrRendering=true;renderer.drawShadows=false;renderer.specularLighting=false
        local lighting=scene_:CreateChild("LightGroup")
        lighting:LoadXML(assert(cache:GetResource("XMLFile","LightGroup/Daytime.xml")):GetRoot())
        local zone=assert(lighting:GetComponent("Zone",true))
        zone.boundingBox=BoundingBox(Vector3(-100000,-1000,-100000),Vector3(100000,3000,100000))
        zone:SetAttribute("Bloom Enable",Variant(false))
        zone.depthFogStart=1100;zone.depthFogEnd=2400
        local sun=assert(lighting:GetComponent("Light",true));sun.castShadows=false
        Sky.Create(scene_,Quality.Get("low"))
        camera_=scene_:CreateChild("驾驶高度验收相机")
        local component=camera_:CreateComponent("Camera")
        component.nearClip=.12;component.farClip=2400;component.fov=68;component.viewMask=3
        renderer:SetViewport(0,Viewport:new(scene_,component))
        activate()
        SubscribeToEvent("Update","HandleReliefVisualUpdate")
        SubscribeToEvent("EndRendering","HandleReliefVisualCapture")
    end)
end
function HandleReliefVisualUpdate()
    guard(function()
        age_=age_+1
        WorldStream.Update(cases[index_].s,1/30)
    end)
end
function HandleReliefVisualCapture()
    guard(function()
        if age_<125 then return end
        if capturedAge_>=0 then
            if age_<capturedAge_+2 then return end
            if singleCase_ or index_==#cases then
                -- tool_mode游戏File仍受沙箱限制；证据已逐帧stdout输出，由调用方仅在截图沙箱汇总。
                print("RELIEF_EVIDENCE_JSON "..cjson.encode(evidence_))
                complete_=true
                print("ALL_RELIEF_REAL_FRAME_PASS captures="..#evidence_.." noSave=true noCloud=true")
                engine:Exit()
            else index_=index_+1;activate() end
            return
        end
        if not warmed_ then
            local discarded=Image()
            if not graphics:TakeScreenShot(discarded) then
                discarded:Dispose();readbackAttempts_=readbackAttempts_+1
                assert(readbackAttempts_<6,"六次预热framebuffer失败")
                return
            end
            discarded:Dispose();warmed_=true
            return
        end
        local case=cases[index_]
        local stats=Landmarks.GetStats()
        local stream=WorldStream.GetStats()
        assert(stats.vertices>0 and stats.meshes>0 and stats.loadedChunks>0,"Landmarks没有流式实际实体")
        local image=Image()
        if not graphics:TakeScreenShot(image) then
            image:Dispose();readbackAttempts_=readbackAttempts_+1
            assert(readbackAttempts_<6,"六次真实framebuffer读取失败")
            return
        end
        assert(image:SavePNG(OUTPUT..case.name..".png"),"截图写入失败")
        image:Dispose()
        local row={name=case.name,s=case.s,eye=case.eye,vertices=stats.vertices,meshes=stats.meshes,
            loadedLandmarkChunks=stats.loadedChunks,tunnels=stats.tunnels,bridges=stats.bridges,slopes=stats.slopes,
            portals=stats.portals,piers=stats.piers,sceneryChunks=stream.sceneryChunks,pendingTasks=stream.pendingTasks,
            disposedChunks=stream.disposedChunks,frameBudgetMs=3,maxTaskMs=stream.maxTaskMs,lastUpdateMs=stream.lastUpdateMs,
            actualBatches=renderer.numBatches,actualPrimitives=renderer.numPrimitives}
        evidence_[#evidence_+1]=row
        print("RELIEF_REAL_FRAME "..cjson.encode(row))
        capturedAge_=age_
    end)
end
function Stop() WorldStream.Shutdown() end
return Visual
