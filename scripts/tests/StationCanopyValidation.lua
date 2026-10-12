-- 基于3D场景脚手架，逐站调用生产Station.BuildOne；真实几何射线与近景/总览验收。
local Route=require "world.Route"
local Station=require "world.Station"
---@type Scene?
local scene_=nil
---@type Node?
local root_=nil
---@type Node?
local cameraNode_=nil
---@type Camera?
local camera_=nil
local index_,age_,views_,checks_,failed_=1,0,0,0,false
local checked_,captured_={},{}
local function check(value,message)
    checks_=checks_+1
    assert(value,message)
end
local function guarded(action)
    if failed_ then return end
    local ok,message=xpcall(action,debug.traceback)
    if not ok then failed_=true;log:Write(LOG_ERROR,tostring(message));engine:Exit() end
end
local function activate(index)
    if root_ then root_:Dispose();root_=nil end
    Station.Init()
    index_,age_=index,0
    local station=assert(Route.GetStations()[index])
    root_=assert(scene_):CreateChild("ProductionStationValidation")
    Station.BuildOne(root_,station)
    print("[CanopyValidation] CASE "..station.name)
end
function Start()
    guarded(function()
        Route.Build()
        scene_=Scene()
        local octree=scene_:CreateComponent("Octree")
        octree:SetSize(BoundingBox(Vector3(-50000,-1000,-50000),Vector3(50000,1000,50000)),8)
        local zone=scene_:CreateComponent("Zone")
        zone.boundingBox=BoundingBox(Vector3(-50000,-1000,-50000),Vector3(50000,1000,50000))
        zone.ambientSource=AMBIENT_COLOR
        zone.ambientColor=Color(.34,.37,.40)
        zone.fogColor=Color(.64,.73,.81)
        zone.fogStart,zone.fogEnd=400,900
        local sun=scene_:CreateChild("ValidationSun")
        sun.direction=Vector3(.35,-1,.55)
        local light=sun:CreateComponent("Light")
        light.lightType,light.brightness,light.castShadows=LIGHT_DIRECTIONAL,1.8,true
        cameraNode_=scene_:CreateChild("ValidationCamera")
        camera_=cameraNode_:CreateComponent("Camera")
        camera_.nearClip,camera_.farClip,camera_.viewMask=.10,1000,7
        renderer:SetViewport(0,Viewport:new(scene_,camera_))
        renderer.hdrRendering=true
        renderer.dynamicInstancing=true
        activate(1)
        SubscribeToEvent("PostUpdate","HandleCanopyValidationUpdate")
        SubscribeToEvent("EndRendering","HandleCanopyValidationCapture")
    end)
end
---@param eventType string
---@param eventData PostUpdateEventData
function HandleCanopyValidationUpdate(eventType,eventData)
    guarded(function()
        age_=age_+1
        local station=Route.GetStations()[index_]
        local origin,_,yaw=Route.Sample(station.s-80)
        local rotation=Quaternion(yaw,Vector3.UP)
        local camera=assert(camera_)
        local node=assert(cameraNode_)
        local close=age_<=12
        node.worldPosition=origin+rotation*(close and Vector3(4.7,2.9,-8) or Vector3(35,24,44))
        node:LookAt(origin+rotation*(close and Vector3(7.4,4.8,7) or Vector3(-35,3,-35)))
        camera.fov=close and 64 or 65
        check(age_<40,"雨棚截图未在有界帧数内完成")
    end)
end
local function checkGeometry()
    local scene=assert(scene_)
    local root=assert(root_)
    local station=Route.GetStations()[index_]
    local node=assert(root:GetChild("Station_"..station.name))
    local frame=assert(node:GetChild("CityCanopyStructure")):GetComponent("CustomGeometry")
    local roof=assert(node:GetChild("CityProfileCanopies")):GetComponent("CustomGeometry")
    local drainage=assert(node:GetChild("CityCanopyDrainage")):GetComponent("CustomGeometry")
    local details=assert(node:GetChild("CanopySeamsAndConnections")):GetComponent("CustomGeometry")
    check(frame and roof and drainage and details,"生产雨棚几何缺失")
    check(frame.viewMask==6 and roof.viewMask==6,"结构不参加生产净空射线")
    local vertices=0
    for _,geometry in ipairs({frame,roof,drainage,details}) do
        local count=geometry:GetNumVertices(0)
        check(count>0 and count<50000,"单个雨棚批无效或几何预算失控")
        vertices=vertices+count
    end
    check(vertices<100000,"雨棚总几何超过10万顶点预算")
    check(details.drawDistance==150 and drainage.drawDistance==200,"微细件远景距离失效")
    check(#node:GetChildrenWithComponent("CustomGeometry",true)<50,"逐根支柱增加独立绘制节点")
    local octree=assert(scene:GetComponent("Octree"))
    local dimensions=Station.GetDimensions()
    check(dimensions.sideGap>=.20,"改棚时缩小列车台缘间隙")
    local _,_,yaw=Route.Sample(station.s)
    local right=Quaternion(yaw,Vector3.UP)*Vector3.RIGHT
    for _,along in ipairs({-90,-70,-30,0,15}) do
        for _,lane in ipairs({-5,0,10.8}) do
            -- 轨道上方4..7米截面必须无棚；只查生产结构mask4，不查标牌/铺装。
            local origin=Route.SampleOffset(station.s+along,lane,4)
            local hit=octree:RaycastSingle(Ray(origin,Vector3.UP),RAY_TRIANGLE,3,DRAWABLE_GEOMETRY,4)
            check(not hit.drawable,"雨棚跨入运营股道上方")
        end
    end
    local firsts={-155,-150,-118,-168,-190}
    local along=firsts[index_]+1
    for _,side in ipairs({-1,1}) do
        local lateral=side*7.65+(side<0 and -11 or 0)
        local columnCenter=Route.SampleOffset(station.s+along,lateral,dimensions.platformTopY+1)
        local hit=octree:RaycastSingle(Ray(columnCenter-right*.30,right),RAY_TRIANGLE,.6,DRAWABLE_GEOMETRY,4)
        check(hit.drawable and hit.drawable==frame,"圆管支柱侧面缺失/绕序错误/负台搬迁失效")
        check(math.abs(hit.distance-.22)<.012,"圆管柱半径不是80毫米")
    end
    check(#Station.GetPlacementData()==1,"站房被错误净空检查拒绝")
    check(Station.GetPlacementData()[1].clearance>=25,"站房侵入铁路包络")
    print(string.format("[CanopyValidation] GEOMETRY station=%d roof=%d steel=%d drain=%d detail=%d total=%d customBatches=%d",index_,roof:GetNumVertices(0),frame:GetNumVertices(0),drainage:GetNumVertices(0),details:GetNumVertices(0),vertices,#node:GetChildrenWithComponent("CustomGeometry",true)))
end
---@param eventType string
---@param eventData EndRenderingEventData
function HandleCanopyValidationCapture(eventType,eventData)
    guarded(function()
        if not checked_[index_] and age_>=6 then checkGeometry();checked_[index_]=true end
        local close=age_<=12
        local key=string.format("%d_%s",index_,close and "close" or "overview")
        if age_%12<8 or captured_[key] then return end
        local image=Image()
        if not graphics:TakeScreenShot(image) then image:Dispose();return end
        check(image.width==graphics:GetWidth() and image.height==graphics:GetHeight(),"截图不是真实输出尺寸")
        check(image:SavePNG("/workspace/screenshots/canopy_structural_"..key..".png"),"雨棚实渲截图落盘失败")
        image:Dispose()
        captured_[key]=true
        views_=views_+1
        print(string.format("[CanopyValidation] REAL_CAPTURE %s batches=%d primitives=%d",key,renderer.numBatches,renderer.numPrimitives))
        if not close then
            if index_==#Route.GetStations() then
                check(views_==10,"五站近景/总览未全部保存")
                print(string.format("ALL_CANOPY_STRUCTURAL_PASS stations=5 views=%d checks=%d",views_,checks_))
                engine:Exit()
            else activate(index_+1) end
        end
    end)
end
