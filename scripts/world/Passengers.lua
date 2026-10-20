-- 乘客视觉层：共享离线CPU蒙皮帧，运行时仅StaticModel，不向移动GPU上传骨矩阵。
-- 程序化行走clip按实际步行距离驱动；不创建人物刚体，不冒充动捕/自然步态。
local Route = require "world.Route"
local Station = require "world.Station"
local PoseCache = require "world.PassengerPoseCache"
local StationVisualConfig = require "config.StationVisualConfig"
local Passengers = {}
---@class PlatformPassengerPose
---@field id integer
---@field appearance integer
---@field position Vector3
---@field yaw number
---@field visible boolean
---@field walking boolean
---@field state? string
---@field walkDistance number
---@class PlatformPassengerVisual
---@field root Node
---@field body Node
---@field model StaticModel
---@field poseFrame integer
---@field hasPosition boolean
---@field appearanceKind integer
---@class PlatformDoorPose
---@field id integer
---@field edge Vector3
---@field position Vector3
---@field clear Vector3
---@type Scene?
local scene_ = nil
---@type Node?
local root_ = nil
---@type table<number, PlatformPassengerVisual>
local actors_ = {}
---@type PlatformPassengerVisual[]
local pool_ = {}
local created_,reused_ = 0,0
---@type Model[]
local models_ = {}
---@type Material[]
local materials_ = {}
---@type Animation[]
local animations_ = {}
---@type PassengerBakedSet[]
local baked_ = {}
local stationIndex_,clock_,walkingCount_ = 0,0.0,0
local qualityId_ = "medium"
local maxVisible_ = 36
local backgroundLimit_ = 12
local lastFacingDot_ = 1.0
---@type PlatformPassengerPose[]
local background_ = {}
---@type string[]
local MODEL_PATHS = {
    "model/1327bd4517494f618b98f9cbd7dd6d14/Meshes/rig-1-abb7fccb-4c30-41bb-87c6-2041221288d0.mdl",
    "model/dc91a901-3f95-58cd-8f9b-3b4f45ddd16a/Meshes/rig-1-d508011a-048f-4b5d-b63f-253a09217cff.mdl",
}
local DIFFUSE_PATHS = {
    "model/1327bd4517494f618b98f9cbd7dd6d14/Textures/rig-1-abb7fccb-4c30-41bb-87c6-2041221288d0_00_D.jpg",
    "model/dc91a901-3f95-58cd-8f9b-3b4f45ddd16a/Textures/rig-1-d508011a-048f-4b5d-b63f-253a09217cff_00_D.jpg",
}
local NORMAL_PATHS = {
    "model/1327bd4517494f618b98f9cbd7dd6d14/Textures/rig-1-abb7fccb-4c30-41bb-87c6-2041221288d0_00_N.png",
    "model/dc91a901-3f95-58cd-8f9b-3b4f45ddd16a/Textures/rig-1-d508011a-048f-4b5d-b63f-253a09217cff_00_N.jpg",
}
---@type string[]
local ANIMATION_PATHS = {"Animations/Passengers/male_walk.ani","Animations/Passengers/female_walk.ani"}
-- 原步态把所有关节当成相同局部轴，实际左右骨骼的绑定朝向不同，导致交叉腿和外撇手臂。
-- 保留每款模型自己的绑定姿态，将模型空间的屈伸轴换算到各骨骼局部空间。
---@param model Model
---@param source Animation
---@param kind integer
---@return Animation
local function correctedWalk(model,source,kind)
    local animation=source:Clone(source.animationName.."_station_corrected")
    local skeleton=model:GetSkeleton()
    local bindRotations={} ---@type table<number,Quaternion>
    for i=0,skeleton:GetNumBones()-1 do
        local bone=skeleton:GetBone(i)
        local parentRotation=bindRotations[bone.parentIndex]
        local bindRotation=parentRotation and parentRotation*bone.initialRotation or bone.initialRotation
        bindRotations[i]=bindRotation
        local track=animation:GetTrack(bone.name)
        assert(track,"行走动画缺失骨骼："..bone.name)
        local pitchAxis=bindRotation:Inverse()*Vector3.RIGHT
        local rollAxis=bindRotation:Inverse()*Vector3.FORWARD
        for k=0,track:GetNumKeyFrames()-1 do
            local key=track:GetKeyFrame(k)
            local phase=key.time/source.length*math.pi*2
            local left=bone.name:sub(1,2)=="L_"
            local stride=math.sin(phase+(left and 0 or math.pi))
            local pitch,roll=0.0,0.0
            if bone.name=="L_Thigh" or bone.name=="R_Thigh" then pitch=stride*20
            elseif bone.name=="L_Calf" or bone.name=="R_Calf" then pitch=-math.max(0,-stride)*32
            elseif bone.name=="L_Foot" or bone.name=="R_Foot" then pitch=-stride*7
            elseif bone.name=="L_Upperarm" or bone.name=="R_Upperarm" then
                pitch=-stride*10
                local restAngle=kind==1 and 20 or 5
                roll=left and restAngle or -restAngle
            elseif bone.name=="L_Forearm" or bone.name=="R_Forearm" then pitch=6+math.max(0,stride)*8 end
            key.rotation=bone.initialRotation*Quaternion(roll,rollAxis)*Quaternion(pitch,pitchAxis)
            track:SetKeyFrame(k,key)
        end
    end
    return animation
end
---@param kind integer
---@return PassengerBakedSet
function Passengers.BakeOffline(kind)
    assert(kind==1 or kind==2,"未知人物烘焙款式")
    print(string.format("[烘焙检查点] 款式%d 源MDL读取前",kind))
    local modelPath = MODEL_PATHS[1]
    if kind == 2 then modelPath = MODEL_PATHS[2] end
    assert(modelPath,"乘客模型路径缺失")
    local model=assert(cache:GetResource("Model",modelPath))
    print(string.format("[烘焙检查点] 款式%d 源MDL读完，源ANI读取前",kind))
    local animationPath = ANIMATION_PATHS[1]
    if kind == 2 then animationPath = ANIMATION_PATHS[2] end
    assert(animationPath,"乘客动画路径缺失")
    local source=assert(cache:GetResource("Animation",animationPath))
    print(string.format("[烘焙检查点] 款式%d 源ANI读完，correctedWalk前",kind))
    local corrected=correctedWalk(model,source,kind)
    print(string.format("[烘焙检查点] 款式%d correctedWalk完成，Build前",kind))
    local set=PoseCache.Build(model,corrected)
    print(string.format("[烘焙检查点] 款式%d Build完成",kind))
    corrected:Dispose()
    return set
end
local function clear()
    for _,actor in pairs(actors_) do
        actor.root.enabled=false
        pool_[#pool_+1]=actor
    end
    if root_ then root_.enabled=false end
    actors_,background_,stationIndex_,walkingCount_ = {},{},0,0
end
function Passengers.Shutdown()
    clear()
    if root_ then root_:Dispose() end
    root_,pool_,created_,reused_=nil,{},0,0
    -- 模型、源动画和贴图由 cache 拥有；材质及修正动画由本模块创建。
    for _,mat in ipairs(materials_) do mat:Dispose() end
    for _,animation in ipairs(animations_) do animation:Dispose() end
    for _,set in ipairs(baked_) do PoseCache.Dispose(set) end
    maxVisible_,backgroundLimit_,qualityId_ = 36,12,"medium"
    scene_,models_,materials_,animations_,baked_,clock_ = nil,{},{},{},{},0
end
---@param scene Scene
function Passengers.Init(scene)
    local started=os.clock()
    Passengers.Shutdown()
    scene_ = scene
    for i=1,2 do
        local modelPath = assert(MODEL_PATHS[i])
        models_[i] = assert(cache:GetResource("Model",modelPath))
        -- 场景光照为 PBR 体系；legacy DiffNormal 材质在 ACES+PBR 光下会过曝发白。
        -- 与列车一致改用 PBRDiffNormal，并显式设 Metallic/Roughness。
        local mat = Material:new()
        mat:SetTechnique(0, assert(cache:GetResource("Technique","Techniques/PBR/PBRDiffNormal.xml")))
        local diffuse = assert(cache:GetResource("Texture2D",DIFFUSE_PATHS[i]),"人物漫反射贴图无法加载")
        local normal = assert(cache:GetResource("Texture2D",NORMAL_PATHS[i]),"人物法线贴图无法加载")
        diffuse:SetSRGB(true)
        normal:SetSRGB(false)
        mat:SetTexture(TU_DIFFUSE,diffuse)
        mat:SetTexture(TU_NORMAL,normal)
        mat:SetShaderParameter("MatDiffColor",Variant(Color(1,1,1,1)))
        mat:SetShaderParameter("Metallic",Variant(.05))
        mat:SetShaderParameter("Roughness",Variant(.72))
        materials_[i] = mat
        baked_[i]=PoseCache.Load(i)
        local bounds=models_[i].boundingBox.size
        assert(bounds.y==bounds.y and bounds.y>.1 and bounds.y<5
            and bounds.x<5 and bounds.z<5,"人物模型尺寸异常，拒绝巨型缩放")
        assert(models_[i]:GetSkeleton():GetNumBones()==41,"人物骨骼不完整")
        print(string.format("[Passengers] 人物%d: 高%.3fm / 源41骨 / 24周期帧+静止帧 / 无GPU蒙皮 / PBR材质",i,
            models_[i].boundingBox.size.y))
    end
    print(string.format("[乘客] 预烘焙帧/贴图载入CPU耗时%.3fs；手机耗时尚待实测",os.clock()-started))
end
---@param pose PlatformPassengerPose
---@return PlatformPassengerVisual
local function create(pose)
    local root = assert(root_):CreateChild("Passenger_"..pose.id)
    local index = pose.appearance%2+1
    local body = root:CreateChild("BakedBody")
    -- 连续步行前侧实拍确认：CPU帧应用公共导入变换后，人物正面朝+Z。
    -- 保持单位旋转；沿用旧AnimatedModel的180度补偿会让静态帧倒着走。
    body.rotation = Quaternion.IDENTITY
    local model = body:CreateComponent("StaticModel")
    model.model = baked_[index].idle
    model:SetMaterial(0,materials_[index])
    model.viewMask,model.castShadows,model.drawDistance = 2,false,240
    local height = 1.64+(pose.appearance%5)*.035
    body.scale = Vector3.ONE*(height/models_[index].boundingBox.size.y)
    created_=created_+1
    return {root=root,body=body,model=model,poseFrame=0,hasPosition=false,appearanceKind=index}
end
---@param pose PlatformPassengerPose
---@return PlatformPassengerVisual
local function acquire(pose)
    local index=pose.appearance%2+1
    local slot=#pool_
    for i,actor in ipairs(pool_) do
        if actor.appearanceKind==index then slot=i;break end
    end
    local actor=slot>0 and table.remove(pool_,slot) or create(pose)
    if slot>0 then reused_=reused_+1 end
    if actor.appearanceKind~=index then
        -- 外观与共享CPU缓存一起复用，不混用另一款人物姿态。
        actor.root:Dispose()
        actor=create(pose)
    end
    actor.root.name="Passenger_"..pose.id
    actor.root.enabled=true
    actor.hasPosition=false -- 池复用是传送，不得拿上一名乘客的位置推断朝向
    actor.body.scale=Vector3.ONE*((1.64+(pose.appearance%5)*.035)/models_[index].boundingBox.size.y)
    return actor
end
local background
function Passengers.SetQuality(qualityId)
    local id = StationVisualConfig.NormalizeQuality(qualityId)
    local budget = StationVisualConfig.GetQuality(id)
    local nextVisible = budget.passengerMaxVisible
    local nextBackground = budget.passengerBackground
    if qualityId_ == id and maxVisible_ == nextVisible and backgroundLimit_ == nextBackground then return end
    qualityId_, maxVisible_, backgroundLimit_ = id, nextVisible, nextBackground
    local activeStation = stationIndex_
    if activeStation ~= 0 then
        clear()
        if root_ then root_.enabled = true end
        background(activeStation)
        stationIndex_ = activeStation
    end
    print(string.format("[Passengers] 画质=%s：站台人物上限%d，背景行人%d",id,maxVisible_,backgroundLimit_))
end
-- 俯视净空：up1轨心+5 | 台沿+6.9 | 安全线+7.7 | 步行线+8.7 | 台外沿+13.9。
-- 只使用实体站台内的连续通道；纵向限于台端/梯道之前，high档20人也不能走出台面。
local function backgroundPosition(st,index)
    local dimensions=Station.GetDimensions()
    local first=math.max(dimensions.platformStart+12,-175)
    local last=math.min(dimensions.platformEnd-30,57)
    local stride=math.min(18,(last-first-12)/math.max(1,backgroundLimit_-1))
    local phase=(clock_*.55+index*4)%24
    local along=st.s+first+(index-1)*stride+(phase<=12 and phase or 24-phase)
    local position=Route.SampleOffset(along,dimensions.upPlatformMin+1.80,dimensions.platformTopY+.045)
    local yaw=select(3,Route.Sample(along))+(phase<=12 and 0 or 180)
    return position,yaw
end
---@param stationIndex integer
background = function(stationIndex)
    local st = Route.GetStations()[stationIndex]
    if not st then return end
    for i=1,backgroundLimit_ do
        local position,yaw=backgroundPosition(st,i)
        background_[i] = {id=-stationIndex*100-i,appearance=i+stationIndex,
            position=position,yaw=yaw,visible=true,walking=false,walkDistance=0}
    end
    print(string.format("[Passengers] %s 背景步行线=%.2fm，人数%d，按真实站台限制纵向",st.name,
        Station.GetDimensions().upPlatformMin+1.80,backgroundLimit_))
end
---@param stationIndex integer?
---@param passengers PlatformPassengerPose[]
---@param dt number?
---@param doors PlatformDoorPose[]?
---@param phase string?
function Passengers.Update(stationIndex,passengers,dt,doors,phase)
    if not scene_ then return end
    clock_ = clock_+math.max(0,dt or 0)
    if not stationIndex then clear(); return end
    if stationIndex_~=stationIndex then
        clear();stationIndex_=stationIndex
        if not root_ then root_=scene_:CreateChild("PlatformPassengers") end
        root_.enabled=true
        background(stationIndex)
    end
    -- 背景旅客在安全走廊往返，不横穿股道，不把真实乘降人数混入背景。
    local station=Route.GetStations()[stationIndex]
    if station then
        for i,p in ipairs(background_) do
            p.position,p.yaw=backgroundPosition(station,i)
            p.walking,p.walkDistance=true,clock_*.55
        end
    end
    local poses = {} ---@type PlatformPassengerPose[]
    -- 活动跨门乘客最优先；等待队列按id分散采样，不能让数组头占满所有人物名额。
    for _,p in ipairs(passengers) do
        if p.visible and p.walking and p.state~="waiting" then poses[#poses+1]=p end
    end
    local visibleWaiting = {} ---@type PlatformPassengerPose[]
    for _,p in ipairs(passengers) do
        if p.visible and (not p.walking or p.state=="waiting") then visibleWaiting[#visibleWaiting+1]=p end
    end
    local budget = math.max(0,maxVisible_-#poses-6)
    -- 画质档只改变视觉预算，不改变乘降权威人数和路径。
    local chosen={} ---@type table<number,boolean>
    -- 已入镜的候车人保留名额，队列减少时不反复切换远处人物造成闪现。
    for _,p in ipairs(visibleWaiting) do
        if actors_[p.id] and budget>0 then
            poses[#poses+1]=p;chosen[p.id]=true;budget=budget-1
        end
    end
    local stride = math.max(1,math.ceil(#visibleWaiting/math.max(1,budget)))
    for i=1,#visibleWaiting,stride do
        local p=visibleWaiting[i]
        if budget>0 and not chosen[p.id] then poses[#poses+1]=p;budget=budget-1 end
    end
    for _,p in ipairs(background_) do poses[#poses+1]=p end
    local retained = {} ---@type table<number, boolean>
    for i,p in ipairs(poses) do if i<=maxVisible_ then retained[p.id]=true end end
    -- 先回收失去名额的演员，再分配新名额，活跃+池中总数不超过36。
    for id,actor in pairs(actors_) do
        if not retained[id] then
            actor.root.enabled=false
            pool_[#pool_+1]=actor
            actors_[id]=nil
        end
    end
    walkingCount_=0
    for i,p in ipairs(poses) do
        if i<=maxVisible_ then
            local actor=actors_[p.id]
            if actor and actor.appearanceKind~=p.appearance%2+1 then
                actor.root.enabled=false;pool_[#pool_+1]=actor;actors_[p.id]=nil;actor=nil
            end
            if not actor then actor=acquire(p);actors_[p.id]=actor end
            local delta=p.position-actor.root.position
            local horizontal=Vector3(delta.x,0,delta.z)
            local moved=actor.hasPosition and p.walking and horizontal:LengthSquared()>.00000001
                and horizontal:LengthSquared()<4 -- 忽略存档恢复/传送，不当作真实步行
            local yaw=moved and math.deg(math.atan(delta.x,delta.z)) or p.yaw
            actor.root.position,actor.root.rotation=p.position,Quaternion(yaw,Vector3.UP)
            actor.hasPosition=true
            if moved then
                local visualForward=actor.body.worldRotation*Vector3.FORWARD
                lastFacingDot_=visualForward:DotProduct(horizontal:Normalized())
            end
            local mesh,frame=PoseCache.Select(baked_[actor.appearanceKind],p.walking,p.walkDistance)
            if actor.poseFrame~=frame then actor.model.model=mesh;actor.poseFrame=frame end
            if p.walking then walkingCount_=walkingCount_+1 end
        end
    end
end
function Passengers.GetStats()
    local n=0
    for _ in pairs(actors_) do n=n+1 end
    local cacheBytes,indexBytes,shadowBytes,sharedFrames=0,0,0,0
    for _,set in ipairs(baked_) do
        cacheBytes=cacheBytes+set.vertexBytes
        indexBytes=indexBytes+(set.indexBytes or 0)
        shadowBytes=shadowBytes+(set.shadowBytes or 0)
        sharedFrames=sharedFrames+#set.frames+1
    end
    -- poseGpuBytes保留旧VB载荷含义；其余为初始化时缓存的真实缓冲载荷，不是驱动显存/RSS。
    return {visible=n,walking=walkingCount_,stationIndex=stationIndex_,roots=root_ and 1 or 0,
        sharedModels=#models_,sharedMaterials=#materials_,geometryBuilds=0,offlinePoseGeometries=sharedFrames*2,npcRigidBodies=0,
        background=#background_,maxVisible=maxVisible_,doorMarkers=0,skinned=false,bonesPerActor=0,
        sourceBones=41,cpuBaked=true,sharedPoseFrames=sharedFrames,poseGpuBytes=cacheBytes,
        poseIndexBytes=indexBytes,poseBufferPayloadBytes=cacheBytes+indexBytes,
        poseShadowBytes=shadowBytes,lastFacingDot=lastFacingDot_,
        pooled=#pool_,created=created_,reused=reused_,allocated=n+#pool_}
end
return Passengers
