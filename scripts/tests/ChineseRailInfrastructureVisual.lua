-- 基于scaffold-3d-scene生命周期的专项实图；只加载真实Route/Track/设施/Landmarks。
-- 禁止require main/Game/Save/Cloud；不加载/保存玩家进度，不伪造截图像素。
local Route=require "world.Route"
local Track=require "world.Track"
local Landmarks=require "world.Landmarks"
local Infra=require "world.RailwayInfrastructure"
local World=require "world.WorldMaterials"
---@type Scene?
local scene_=nil
---@type Node?
local root_=nil
---@type Node?
local cameraNode_=nil
local cases_={} ---@type table[]
local index_,age_,captures_=1,0,0
local failed_=false
local function guard(action)
    if failed_ then return end
    local ok,err=xpcall(action,debug.traceback)
    if not ok then failed_=true;log:Write(LOG_ERROR,tostring(err));engine:Exit() end
end
local function pos(s,x,y) return Route.SampleOffset(s,x,y) end
local function dispose(node)
    for _,child in ipairs(node:GetChildren()) do dispose(child) end
    node:RemoveAllComponents();node:Dispose()
end
local function setup()
    if root_ then Infra.Shutdown();dispose(root_) end
    root_=assert(scene_):CreateChild("Fixture")
    local c=cases_[index_]
    local a,b=math.max(0,math.floor((c.s-c.behind)/50)*50),math.min(Route.GetLength(),math.ceil((c.s+c.ahead)/50)*50)
    Infra.Init(scene_)
    for first=a,b-.001,50 do
        Track.BuildChunk(root_:CreateChild("真实1435mm轨枕"),first,math.min(b,first+50),true)
        Infra.BuildChunk(root_:CreateChild("真实50m设施"),first,math.min(b,first+50))
    end
    if c.structure then
        Landmarks.BuildChunk(root_,a,b)
    else
        local ground=World.NewBatch(root_:CreateChild("测试地面非设施"),World.Solid(Color(.22,.29,.19),0,.97),false,6)
        ground:AddQuad(pos(a,-55,-.25),pos(b,-55,-.25),pos(b,55,-.25),pos(a,55,-.25));ground:Finish()
    end
    local camera=assert(cameraNode_):GetComponent("Camera")
    camera.fov=c.fov or 55
    cameraNode_.position=pos(c.s+c.cameraS,c.cameraX,c.cameraY)
    cameraNode_:LookAt(pos(c.s+c.targetS,c.targetX or 2.5,c.targetY or 4))
    Infra.Update(.2,{s=c.s,lane=0,reversing=false}) -- unknown/未初始化Traffic，保守红灯。
    age_=0
    print(string.format("[ChineseRailVisual] CASE %s s=%.2f nativeVertices=%d infraMeshes=%d",c.name,c.s,Infra.GetStats().vertices,Infra.GetStats().meshes))
end
function Start()
    guard(function()
        Route.Build();Landmarks.Init()
        scene_=Scene();scene_:CreateComponent("Octree")
        -- 与已有运行时验收相同的单Zone环境，避免LightGroup引用编辑器专用暗角贴图。
        local lg=scene_:CreateChild("TestLighting")
        local zone=lg:CreateComponent("Zone")
        local sun=lg:CreateChild("Sun");sun.direction=Vector3(.4,-.8,.55)
        local light=sun:CreateComponent("Light");light.lightType=LIGHT_DIRECTIONAL
        light.color=Color(1,.96,.88);light.brightness=1.1
        zone.ambientSource=AMBIENT_COLOR;zone.ambientColor=Color(.22,.25,.28)
        zone.boundingBox=BoundingBox(Vector3(-100000,-10000,-100000),Vector3(100000,10000,100000))
        zone.depthFogStart=1000;zone.depthFogEnd=3000;zone.fogColor=Color(.64,.73,.79)
        zone.tonemapMode=TONEMAP_MODE_ACES;zone.autoExposureEnabled=false;zone.vignetteEnabled=false
        zone.bloomWeight=.06
        renderer.hdrRendering=true;renderer.drawShadows=false
        cameraNode_=scene_:CreateChild("Camera")
        local camera=cameraNode_:CreateComponent("Camera");camera.nearClip=.10;camera.farClip=3000
        renderer:SetViewport(0,Viewport:new(scene_,camera))
        cases_={
            {name="01_interval_left_signal",s=1600,behind=100,ahead=250,cameraS=-28,cameraX=-12,cameraY=4.1,targetS=28,targetX=1,targetY=4.0},
            {name="02_anchor_return_cable",s=2400,behind=100,ahead=160,cameraS=-25,cameraX=-14,cameraY=7,targetS=20,targetX=1,targetY=3.6},
            {name="03_kilometre_marker",s=2000,behind=50,ahead=100,cameraS=-10,cameraX=-8,cameraY=2.6,targetS=6,targetX=-1,targetY=1.5,fov=52},
            {name="04_station_portal_island",s=Route.GetStations()[2].s,behind=100,ahead=140,cameraS=-45,cameraX=-25,cameraY=8,targetS=30,targetX=1,targetY=5},
        }
        for _,def in ipairs(Landmarks.GetDefinitions()) do
            if def.kind=="bridge" and #cases_<5 then
                cases_[#cases_+1]={name="05_bridge_deck_masts",s=def.s,behind=120,ahead=150,cameraS=-70,cameraX=-28,cameraY=14,targetS=40,targetX=2.5,targetY=2,structure=true}
            end
        end
        for _,def in ipairs(Landmarks.GetDefinitions()) do
            if def.kind=="tunnel" and #cases_<6 then
                cases_[#cases_+1]={name="06_tunnel_roof_suspension",s=def.s,behind=100,ahead=160,cameraS=-28,cameraX=0,cameraY=4.4,targetS=40,targetX=2.5,targetY=7.2,structure=true,fov=62}
            end
        end
        setup()
        SubscribeToEvent("Update","HandleChineseRailVisualUpdate")
        SubscribeToEvent("EndRendering","HandleChineseRailVisualCapture")
    end)
end
function HandleChineseRailVisualUpdate() age_=age_+1 end
function HandleChineseRailVisualCapture()
    guard(function()
        if age_<(index_==1 and 12 or 6) then return end
        local image=Image()
        -- llvmpipe读回偶发未就绪只等后续真实帧，绝不生成/复用假像素。
        if not graphics:TakeScreenShot(image) then
            image:Dispose()
            assert(age_<80,"real framebuffer repeatedly failed")
            return
        end
        local path="/workspace/screenshots/chinese_rail_"..cases_[index_].name..".png"
        assert(image:SavePNG(path),"real screenshot write failed");image:Dispose()
        captures_=captures_+1
        print(string.format("[ChineseRailVisual] CAPTURE %s batches=%d primitives=%d",path,graphics.numBatches,graphics.numPrimitives))
        if index_==#cases_ then print("CHINESE_RAIL_VISUAL_PASS captures="..captures_);engine:Exit()
        else index_=index_+1;setup() end
    end)
end
function Stop() Infra.Shutdown() end
