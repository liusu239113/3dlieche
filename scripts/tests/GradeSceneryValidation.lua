-- 山地装饰回归：生产建筑/花池/乘客CPU模型与真实离屏像素，不加载main或玩家存档。
-- 基于scaffold-3d-scene的Scene持有/相机/viewport；-grade-cpu只跑引擎CPU验收。
local Modes = require "config.GameModes"
local Route = require "world.Route"
local Station = require "world.Station"
local Buildings = require "world.StationBuildings"
local Passengers = require "world.Passengers"
local Vegetation = require "world.Vegetation"
local Infrastructure = require "world.Infrastructure"
local Terrain = require "world.Terrain"
local Scenery = require "world.RailwayScenery"
local World = require "world.WorldMaterials"
---@type Scene?
local scene_ = nil
---@type Node?
local cameraNode_ = nil
---@type Node?
local stationRoot_ = nil
local checks_,frame_,phase_,phaseStart_,shots_ = 0,0,1,0,0
local done_,cpu_ = false,false
local originalMode_ = Modes.GetId()
local stationIndex_ = 2
local function check(value,message) checks_=checks_+1; assert(value,"[GradeScenery] "..message) end
local function near(a,b,tolerance,message) check(math.abs(a-b)<=tolerance,message..string.format(" (%.5f / %.5f)",a,b)) end
local function guard(action)
    if done_ then return end
    local ok,err=xpcall(action,debug.traceback)
    if not ok then done_=true;log:Write(LOG_ERROR,tostring(err));engine:Exit() end
end
local function buildStation(index)
    local station=assert(Route.GetStations()[index])
    local owner=assert(scene_):CreateChild("GradeStationFixture_"..index)
    Station.BuildOne(owner,station)
    local house=assert(owner:GetChild("StationHouse",true))
    near(house.worldPosition.y,Route.Sample(station.s).y,.01,"站房父节点漏加/重复基高")
    near((house.worldRotation*Vector3.UP).y,1,.00001,"站房不应随线路俯仰")
    local minimum=math.huge
    for _,geometry in ipairs(house:GetComponents("CustomGeometry",true)) do
        check(geometry:GetNumVertices(0)>0,"站房实际几何为空")
        for i=0,geometry:GetNumVertices(0)-1 do
            local p=geometry.node:LocalToWorld(geometry:GetVertex(0,i).position)
            minimum=math.min(minimum,p.y)
        end
    end
    for _,model in ipairs(house:GetComponents("StaticModel",true)) do
        minimum=math.min(minimum,model:GetWorldBoundingBox().min.y)
        check(model.model~=nil,"独立站房没有真实模型")
    end
    -- terminal挑檐柱原设计深入基础0.20m，正常/山地图均保持，不把基础误当悬空屋体。
    local footing = Buildings.Styles[index].archetype=="terminal" and -.20 or 0
    near(minimum,house.worldPosition.y+footing,.03,"站房真实mesh底部未保留原局部基础标高")
    print(string.format("[GradeScenery] BUILDING station=%d s=%.3f baseY=%.3f meshBottom=%.3f",index,station.s,house.worldPosition.y,minimum))
    return owner
end
local function checkActors(index)
    local station=assert(Route.GetStations()[index])
    local top=Station.GetDimensions().platformTopY
    local poses={} ---@type PlatformPassengerPose[]
    for i=1,8 do
        poses[i]={id=i,appearance=i,position=Route.SampleOffset(station.s-55+i*1.3,6.2,top+.045),
            yaw=select(3,Route.Sample(station.s))-90,visible=true,walking=i%2==0,walkDistance=i*.19}
    end
    Passengers.Update(index,poses,.02)
    Passengers.Update(index,poses,.02)
    local root=assert(assert(scene_):GetChild("PlatformPassengers"))
    local active=0
    for _,actor in ipairs(root:GetChildren()) do if actor.enabled then
        active=active+1
        near(actor.worldPosition.y,Route.Sample(station.s).y+top+.045,.015,"乘客脚根漏加/重复站点高程")
        near((actor.worldRotation*Vector3.UP).y,1,.00001,"乘客没有保持世界竖直")
        local model=assert(actor:GetComponent("StaticModel",true))
        local bounds=model:GetWorldBoundingBox()
        check(bounds.size.y>1 and bounds.size.y<2.5,"乘客真实模型高度错误")
        near(bounds.min.y,actor.worldPosition.y,.13,"乘客真实模型脚底偏离根节点")
        check(model.model:GetGeometry(0,0):GetVertexBuffer(0).vertexCount>100,"乘客没有真实CPU帧模型")
    end end
    check(active>=20 and Passengers.GetStats().npcRigidBodies==0,"人物模型不完整/错误增加刚体")
    print(string.format("[GradeScenery] PEOPLE station=%d active=%d platformWorldY=%.3f",index,active,Route.Sample(station.s).y+top))
end
local function checkPlanters(owner,index)
    local base=Route.Sample(assert(Route.GetStations()[index]).s).y
    local count=0
    for _,node in ipairs(owner:GetChildren(true)) do
        if node.name=="PlanterFoliage" then
            for _,child in ipairs(node:GetChildren()) do
                if child.name:find("_Instance",1,true) then
                    local asset=Vegetation.GetAsset(child.name:find("Bush",1,true) and "bush" or "grass")
                    check(asset~=nil,"花池没有实际植物资源")
                    local bounds=assert(asset).bounds
                    local bottom=child:LocalToWorld(Vector3(bounds.center.x,bounds.min.y,bounds.center.z))
                    near(bottom.y,base+.28,.015,"花池植物重复高程或被地面高度覆盖")
                    count=count+1
                end
            end
        end
    end
    check(count>0,"站台没有实际花池模型")
end
local function checkScenery()
    Terrain.Init()
    local plots=Scenery.GetExclusions()
    check(#plots>0,"山地沿线装饰规划全部消失")
    for _,plot in ipairs(plots) do
        check(plot.groundDrop>=0 and plot.groundDrop<=.300001,"山地地块陡坡未拒绝")
        local ground=Terrain.GetGroundHeight(plot.pos.x,plot.pos.z)
        check(plot.pos.y>=ground-.025 and plot.pos.y-ground<=.325,"乡野建筑底部未适配真实地面")
    end
    local plot=assert(plots[1])
    local owner=assert(scene_):CreateChild("GradeSceneryFixture")
    check(Scenery.BuildChunk(owner,plot.s-.01,plot.s+.01)>0,"乡野规划未生成真实几何")
    check(#Scenery.GetMeshes()>0,"乡野真实mesh缺失")
    print(string.format("[GradeScenery] SCENERY retained=%d rejected=%d firstY=%.3f",#plots,Scenery.GetStats().rejected,plot.pos.y))
    Scenery.ForgetChunk(plot.s-.01,plot.s+.01);owner:Dispose()
end
local function checkTrough()
    local best,bestGrade=0,0
    for s=100,Route.GetLength()-100,100 do
        local inYard=false
        for _,st in ipairs(Route.GetStations()) do
            if math.abs(s-st.s)<2300 then inYard=true end
        end
        local grade=math.abs(Route.GetGrade(s))
        if not inYard and grade>bestGrade then best,bestGrade=s,grade end
    end
    check(bestGrade>.01,"验收没有找到真实区间纵坡")
    local owner=assert(scene_):CreateChild("GradeInfrastructureFixture")
    Infrastructure.Init();Infrastructure.BuildChunk(owner,best,best+4)
    local geometry=assert(assert(owner:GetChild("CableTroughsAndPosts")):GetComponent("CustomGeometry"))
    check(geometry:GetNumVertices(0)>=36,"真实电缆槽几何缺失")
    for i=0,35 do
        local p=geometry.node:LocalToWorld(geometry:GetVertex(0,i).position)
        local _,s=Route.DistanceTo(p)
        local height=p.y-Route.Sample(s).y
        check(math.min(math.abs(height-.02),math.abs(height-.19))<.025,"槽顶底未随两端纵坡")
    end
    print(string.format("[GradeScenery] TROUGH s=%.3f grade=%.5f vertices=%d",best,bestGrade,geometry:GetNumVertices(0)))
    owner:Dispose()
end
local function aim()
    local s=assert(Route.GetStations()[stationIndex_]).s
    local node=assert(cameraNode_)
    if phase_==1 then
        node.position=Route.SampleOffset(s-105,-115,22)
        node:LookAt(Route.SampleOffset(s-55,-62,5))
    else
        node.position=Route.SampleOffset(s-45,12,2.8)
        node:LookAt(Route.SampleOffset(s-49,6.2,2.3))
    end
end
function Start()
    guard(function()
        for _,arg in ipairs(GetArguments()) do if arg=="-grade-cpu" then cpu_=true end end
        scene_=Scene();scene_:CreateComponent("Octree")
        Modes.Apply("normal");Route.Build();Station.Init()
        near(Route.Sample(Route.GetStations()[2].s).y,0,.000001,"普通模式基高改变")
        local ordinary=buildStation(2);checkPlanters(ordinary,2)
        Station.Forget(2);ordinary:Dispose()
        Modes.Apply("rage");Route.Build();Station.Init()
        check(type(Route.GetGrade)=="function" and type(Terrain.GetGroundHeight)=="function","新纵坡/地表接口未就绪")
        checkScenery();checkTrough()
        Passengers.Init(scene_)
        for index=1,#Route.GetStations() do
            local owner=buildStation(index)
            checkActors(index);checkPlanters(owner,index)
            Station.Forget(index);owner:Dispose()
        end
        check(math.abs(Route.Sample(Route.GetStations()[stationIndex_].s).y)>1,"坡站fixture高程必须非零")
        stationRoot_=buildStation(stationIndex_);checkActors(stationIndex_)
        print(string.format("ALL_GRADE_SCENERY_CPU_PASS checks=%d buildings=7 actors=actual_cpu_models saveIO=NONE",checks_))
        if cpu_ then done_=true;engine:Exit();return end
        -- 真实离屏只增验收灯光/底板，不调用或替换生产环境/地图接口。
        renderer.hdrRendering=true
        local zone=scene_:CreateChild("GradeFixtureZone"):CreateComponent("Zone")
        zone.boundingBox=BoundingBox(-100000,100000);zone.ambientSource=AMBIENT_COLOR
        zone.ambientColor=Color(.40,.43,.46);zone.fogColor=Color(.63,.72,.79)
        zone.depthFogStart,zone.depthFogEnd=1000,4000
        local light=scene_:CreateChild("GradeFixtureSun"):CreateComponent("Light")
        light.lightType=LIGHT_DIRECTIONAL;light.brightness=1.4;light.node.direction=Vector3(.4,-1,.6)
        local ground=World.NewBatch(scene_:CreateChild("GradeFixtureFlatStationGround"),World.Grassland(),false,12)
        local center=Route.Sample(Route.GetStations()[stationIndex_].s)
        ground:AddBox(center-Vector3(0,.12,0),Vector3(1500,.24,1500));ground:Finish()
        cameraNode_=scene_:CreateChild("GradeFixtureCamera")
        local camera=cameraNode_:CreateComponent("Camera")
        camera.nearClip,camera.farClip,camera.fov,camera.viewMask=.1,3500,58,7
        renderer:SetViewport(0,Viewport:new(scene_,camera));aim()
        SubscribeToEvent("Update","GradeSceneryUpdate")
        SubscribeToEvent("EndRendering","GradeSceneryCapture")
    end)
end
function GradeSceneryUpdate() frame_=frame_+1 end
function GradeSceneryCapture()
    guard(function()
        if frame_<120 or frame_-phaseStart_<32 then return end
        local image=Image()
        check(graphics:TakeScreenShot(image),"真实离屏读回失败")
        local path=phase_==1 and "/home/Maker/grade-scenery-station.png" or "/home/Maker/grade-scenery-people.png"
        check(image:SavePNG(path),"真实离屏PNG落盘失败")
        local decoded=Image();check(decoded:Load(path),"PNG回读解码失败")
        check(decoded.width==graphics:GetWidth() and decoded.height==graphics:GetHeight(),"PNG不是实际物理分辨率")
        local lo,hi=1,0
        for y=1,9 do for x=1,13 do
            local color=decoded:GetPixel(math.floor(decoded.width*x/14),math.floor(decoded.height*y/10))
            local value=(color.r+color.g+color.b)/3
            lo,hi=math.min(lo,value),math.max(hi,value)
        end end
        check(hi-lo>.05,"离屏输出为空场景/单色")
        image:Dispose();decoded:Dispose();shots_=shots_+1
        print(string.format("[GradeScenery] REAL_PNG %s frame=%d batches=%d",path,frame_,renderer.numBatches))
        if phase_==2 then
            print(string.format("ALL_GRADE_SCENERY_VISUAL_PASS checks=%d screenshots=%d saveIO=NONE",checks_,shots_))
            done_=true;engine:Exit()
        else phase_,phaseStart_=2,frame_;aim() end
    end)
end
function Stop()
    Passengers.Shutdown();Station.Shutdown();Scenery.Shutdown()
    if scene_ then scene_:Dispose();scene_=nil end
    Modes.Apply(originalMode_)
end
