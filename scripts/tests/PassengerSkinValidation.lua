-- 兼容回归探针，不代表手机GPU已通过。
-- 连续距离、原点/五站/30km坐标、LOD距离切换、同ID外观复用。
local Passengers = require "world.Passengers"
local Route = require "world.Route"
local SkyUtils = require "urhox-libs.Rendering.SkyUtils"
---@type Scene?
local scene_ = nil
---@type Node?
local cameraNode_ = nil
local frame_,caseIndex_,captures_,caseFrame_ = 0,0,0,0
local CASE_START=math.max(1,math.floor(tonumber(os.getenv("PASSENGER_CASE_START")) or 1))
local CASE_END=math.max(CASE_START,math.floor(tonumber(os.getenv("PASSENGER_CASE_END")) or 21))
local OUTPUT_TAG=os.getenv("PASSENGER_PROBE_TAG") or "passenger_cpu"
local failed_ = false
local poses_ = {} ---@type PlatformPassengerPose[]
local cases_ = {} ---@type {name:string,count:integer,appearance:integer,origin:Vector3,distance:number,walking:boolean,reverse:boolean}[]
local seenFrames_ = {} ---@type table<number,boolean>
local checkedModels_ = {} ---@type table<Model,boolean>
local function guard(action)
    if failed_ then return end
    local ok,err=xpcall(action,debug.traceback)
    if not ok then failed_=true;print("PASSENGER_SKIN_FAILED "..tostring(err));log:Write(LOG_ERROR,tostring(err));engine:Exit() end
end
---@param index integer
local function activate(index)
    caseIndex_,caseFrame_=index,0
    local case=assert(cases_[index])
    poses_={}
    for i=1,case.count do
        -- 各case沿用相同ID，刻意切换男女外观（包括尚活跃的演员）。
        poses_[i]={id=i,appearance=case.appearance+(case.count>1 and i or 0),
            position=case.origin+Vector3(((i-1)%6)*1.4,0,math.floor((i-1)/6)*1.6),
            yaw=case.reverse and 180 or 0,visible=true,walking=case.walking,walkDistance=0}
    end
    print(string.format("[乘客CPU验收] 用例%s 原点=%.2f,%.2f,%.2f 相机距离=%.1f",case.name,
        case.origin.x,case.origin.y,case.origin.z,case.distance))
end
function Start()
    guard(function()
        scene_=Scene()
        local octree=scene_:CreateComponent("Octree")
        octree:SetSize(BoundingBox(Vector3(-120000,-5000,-120000),Vector3(120000,5000,120000)),8)
        -- 探针只需固定日间光；不加载带编辑器暗角纹理依赖的LightGroup预设。
        local group=scene_:CreateChild("PassengerProbeLighting")
        local zone=group:CreateComponent("Zone")
        zone.boundingBox=BoundingBox(Vector3(-120000,-5000,-120000),Vector3(120000,5000,120000))
        zone.ambientSource=AMBIENT_COLOR
        zone.ambientColor=Color(.20,.23,.26)
        zone.tonemapMode=TONEMAP_MODE_ACES
        zone.vignetteEnabled=false
        zone.autoExposureEnabled=false
        zone.fogStart,zone.fogEnd=250,300
        local sunNode=group:CreateChild("Sun")
        sunNode.direction=Vector3(.45,-1,.55)
        local sun=sunNode:CreateComponent("Light")
        sun.lightType=LIGHT_DIRECTIONAL
        sun.color=Color(1,.96,.88)
        sun.brightness=1.15
        sun.castShadows=false
        SkyUtils.CreateGradientSky(assert(scene_),SkyUtils.Presets.Day)
        Route.Build()
        local origins={Vector3.ZERO}
        for _,station in ipairs(Route.GetStations()) do origins[#origins+1]=Route.Sample(station.s) end
        origins[#origins+1]=Vector3(30000,0,30000)
        for index,origin in ipairs(origins) do
            cases_[#cases_+1]={name="world_"..index.."_male_forward",count=1,appearance=0,
                origin=origin,distance=3.5,walking=true,reverse=false}
            cases_[#cases_+1]={name="world_"..index.."_female_reverse",count=1,appearance=1,
                origin=origin,distance=3.5,walking=true,reverse=true}
        end
        for _,distance in ipairs({20,39,41,90,180}) do
            cases_[#cases_+1]={name="crowd_distance_"..distance,count=36,appearance=1,
                origin=Vector3(30000,0,30000),distance=distance,walking=true,reverse=false}
        end
        cases_[#cases_+1]={name="pooled_idle_male",count=1,appearance=0,origin=Vector3.ZERO,
            distance=3.5,walking=false,reverse=false}
        cases_[#cases_+1]={name="same_id_idle_female",count=1,appearance=1,origin=Vector3.ZERO,
            distance=3.5,walking=false,reverse=false}
        local ok,maxBones=pcall(function() return graphics:GetMaxBones() end)
        print("[乘客CPU验收] Graphics:GetMaxBones可用="..tostring(ok).." 返回="..tostring(maxBones))
        Passengers.Init(assert(scene_))
        local stats=Passengers.GetStats()
        assert(stats.cpuBaked and not stats.skinned and stats.bonesPerActor==0)
        assert(stats.sharedPoseFrames==50 and stats.poseGpuBytes<=20*1024*1024,"共享缓存超出预算")
        cameraNode_=scene_:CreateChild("Camera")
        local camera=cameraNode_:CreateComponent("Camera")
        camera.fov,camera.nearClip,camera.farClip=50,.1,300
        renderer:SetViewport(0,Viewport:new(assert(scene_),camera))
        assert(CASE_START<=#cases_ and CASE_END<=#cases_,"人物验收用例范围越界")
        print(string.format("[乘客CPU验收] 本次明确覆盖用例%d..%d/%d；其余用例不计本次通过",CASE_START,CASE_END,#cases_))
        activate(CASE_START)
        SubscribeToEvent("Update","HandlePassengerSkinUpdate")
        SubscribeToEvent("EndRendering","HandlePassengerSkinCapture")
    end)
end
---@param eventType string
---@param eventData UpdateEventData
function HandlePassengerSkinUpdate(eventType,eventData)
    guard(function()
        frame_,caseFrame_=frame_+1,caseFrame_+1
        local case=assert(cases_[caseIndex_])
        -- 固定60Hz步行距离，完整覆盖24帧，不只检查一个固定stride。
        local step=case.walking and 1.25/60 or 0
        for _,pose in ipairs(poses_) do
            pose.walkDistance=pose.walkDistance+step
            pose.position=pose.position+Vector3(0,0,case.reverse and -step or step)
        end
        Passengers.Update(1,poses_,0,nil,"waiting")
        local root=assert(scene_):GetChild("PlatformPassengers")
        for _,child in ipairs(root:GetChildren()) do
            if child.name:find("Passenger_-",1,true) then child.enabled=false end
        end
        local focus=assert(poses_[1]).position
        -- 正向与反向都从行进方向的前侧观察，避免只看背影无法校验倒走。
        local viewZ=case.reverse and -case.distance or case.distance
        cameraNode_.position=focus+Vector3(2.2,1.1,viewZ)
        cameraNode_:LookAt(focus+Vector3(0,1,0))
        local stats=Passengers.GetStats()
        assert(stats.allocated<=36 and stats.geometryBuilds==0 and stats.offlinePoseGeometries==100,
            "运行中重复CPU烘焙/池超额")
        if case.walking and caseFrame_>1 then assert(stats.lastFacingDot>.999,"可视面朝向与实际位移相反") end
    end)
end
---@param model Model
local function checkVertices(model)
    if checkedModels_[model] then return end
    checkedModels_[model]=true
    assert(model:GetSkeleton():GetNumBones()==0,"CPU帧仍带GPU骨架")
    for level=0,model:GetNumGeometryLodLevels(0)-1 do
        local vb=model:GetGeometry(0,level):GetVertexBuffer(0)
        assert(vb.vertexSize==52 and not vb:HasElement(SEM_BLENDINDICES)
            and not vb:HasElement(SEM_BLENDWEIGHTS),"CPU帧仍带GPU blend属性")
        local data=vb:GetData()
        local bounds=BoundingBox()
        for i=0,vb.vertexCount-1 do
            data:Seek(i*vb.vertexSize)
            local p=data:ReadVector3()
            assert(p.x==p.x and p.y==p.y and p.z==p.z and p:Length()<3,"实际顶点NaN或巨型三角")
            bounds:Merge(p)
        end
        assert(bounds.size.x<2 and bounds.size.y<2 and bounds.size.z<2,"实际顶点包络失控")
        print(string.format("[乘客CPU顶点验收] %s 定义LOD%d 顶点=%d 距离阈值=%.1f，未包含骨索引",
            model.name,level,vb.vertexCount,model:GetGeometry(0,level).lodDistance))
    end
end
---@param eventType string
---@param eventData EndRenderingEventData
function HandlePassengerSkinCapture(eventType,eventData)
    guard(function()
        if frame_<1 or caseFrame_<1 then return end -- 首次EndRendering可能先于Update
        local case=assert(cases_[caseIndex_])
        local root=assert(scene_):GetChild("PlatformPassengers")
        local checked=0
        for _,child in ipairs(root:GetChildren()) do
            if child:IsEnabled() then
                checked=checked+1
                assert(not child:GetComponent("AnimatedModel",true),"可视演员仍使用AnimatedModel")
                local model=assert(child:GetComponent("StaticModel",true))
                local id=assert(tonumber(child.name:match("Passenger_(%d+)")))
                local appearance=case.appearance+(case.count>1 and id or 0)
                local expectedKind=appearance%2+1
                local nearVertices=expectedKind==1 and 3386 or 6672
                local farVertices=expectedKind==1 and 1782 or 3017
                assert(model.model:GetGeometry(0,0):GetVertexBuffer(0).vertexCount==nearVertices
                    and model.model:GetGeometry(0,1):GetVertexBuffer(0).vertexCount==farVertices,
                    "同ID外观/池复用混入另一款CPU缓存")
                checkVertices(model.model)
                local expectedPose=math.floor((assert(poses_[id]).walkDistance/1.25%1)*24)
                if case.walking then
                    local actualPose=assert(tonumber(model.model.name:match("walk_(%d%d)%.mdl$")),
                        "实际Model资源名不是预烘焙步态帧")
                    assert(actualPose==expectedPose,"实际渲染Model未切换到对应步态帧")
                    seenFrames_[actualPose]=true
                else
                    assert(model.model.name:match("idle%.mdl$"),"静止人物仍使用周期步态帧")
                end
            end
        end
        assert(checked==case.count,"实际可视演员数量不足")
        if caseFrame_~=59 then return end
        local image=Image()
        local inView=0
        for _,child in ipairs(root:GetChildren()) do
            local drawable=child:GetComponent("StaticModel",true)
            if child:IsEnabled() and drawable and drawable:IsInView() then inView=inView+1 end
        end
        print(string.format("[乘客CPU验收] 用例%s 入镜=%d/%d 三角=%d 批次=%d；无currentLOD公开API，距离不等于LOD证明",
            case.name,inView,case.count,renderer:GetNumPrimitives(),renderer:GetNumBatches()))
        assert(inView>0,"截图时没有任何待测人物入镜")
        assert(graphics:TakeScreenShot(image),"GPU截图失败")
        assert(image:SavePNG("/workspace/screenshots/"..OUTPUT_TAG.."_"..case.name..".png"))
        image:Dispose()
        captures_=captures_+1
        if caseIndex_==CASE_END then
            local seen=0;for _ in pairs(seenFrames_) do seen=seen+1 end
            if CASE_START<=19 then assert(seen==24,"连续步态未覆盖全部24帧") end
            if CASE_START==1 and CASE_END==#cases_ then
                print("PASSENGER_CPU_STRUCTURAL_PASS 截图="..captures_.."；GPU图像须人工复核，不等于手机验收")
            else
                print(string.format("PASSENGER_CPU_RANGE_PASS 用例=%d..%d/%d 截图=%d 步态帧=%d；仅本次范围，不等于完整/手机通过",
                    CASE_START,CASE_END,#cases_,captures_,seen))
            end
            engine:Exit()
        else activate(caseIndex_+1) end
    end)
end
function Stop() Passengers.Shutdown() end
