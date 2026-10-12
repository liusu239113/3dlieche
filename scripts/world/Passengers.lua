-- 独立骨骼乘客视觉层：缓存两套人物资源，门口行走者优先，最多36人。
-- 行走动画按实际步行距离驱动；不创建人物刚体，不冒充动捕动画。
local Route = require "world.Route"
local Station = require "world.Station"
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
---@field model AnimatedModel
---@field animation AnimationState
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
local stationIndex_,clock_,walkingCount_ = 0,0.0,0
local MAX_VISIBLE = 36
---@type PlatformPassengerPose[]
local background_ = {}
local MODEL_PATHS = {
    "model/62a13e80-74a8-5078-b777-5530e5a4346e/Meshes/rig-1-4db698a0-fa75-4297-921d-cb4897aad9cb.mdl",
    "model/dc91a901-3f95-58cd-8f9b-3b4f45ddd16a/Meshes/rig-1-d508011a-048f-4b5d-b63f-253a09217cff.mdl",
}
local MATERIAL_PATHS = {
    "model/62a13e80-74a8-5078-b777-5530e5a4346e/Materials/rig-1-4db698a0-fa75-4297-921d-cb4897aad9cb_00_tripo_material_8547aae4-7585-4381-9471-199ca2c0c6ae.xml",
    "model/dc91a901-3f95-58cd-8f9b-3b4f45ddd16a/Materials/rig-1-d508011a-048f-4b5d-b63f-253a09217cff_00_tripo_material_f0fb9b57-4d33-459d-ad17-a1be250e3b90.xml",
}
local ANIMATION_PATHS = {"Animations/Passengers/male_walk.ani","Animations/Passengers/female_walk.ani"}
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
    -- 三类资源均由 cache 拥有，禁止 Dispose。
    scene_,models_,materials_,animations_,clock_ = nil,{},{},{},0
end
---@param scene Scene
function Passengers.Init(scene)
    Passengers.Shutdown()
    scene_ = scene
    for i=1,2 do
        models_[i] = assert(cache:GetResource("Model",MODEL_PATHS[i]))
        materials_[i] = assert(cache:GetResource("Material",MATERIAL_PATHS[i]))
        animations_[i] = assert(cache:GetResource("Animation",ANIMATION_PATHS[i]))
        assert(animations_[i].numTracks>0 and animations_[i].length>0,"人物行走动画尚未就绪")
        assert(models_[i]:GetSkeleton():GetNumBones()==41,"人物骨骼不完整")
        print(string.format("[Passengers] 人物%d: 高%.3fm / 41骨骼 / %d行走轨道",i,
            models_[i].boundingBox.size.y,animations_[i].numTracks))
    end
end
---@param pose PlatformPassengerPose
---@return PlatformPassengerVisual
local function create(pose)
    local root = assert(root_):CreateChild("Passenger_"..pose.id)
    local index = pose.appearance%2+1
    local body = root:CreateChild("SkinnedBody")
    -- 三次实拍（-90/+90/180）一致得出正面方向 φ 等于旋转角，即模型原生正面就朝 +Z。
    -- 行走 yaw 用 atan2(dx,dz)（局部+Z为前进），所以这里不做旋转，朝向才与移动方向一致。
    body.rotation = Quaternion()
    local model = body:CreateComponent("AnimatedModel")
    model.model = models_[index]
    model:SetMaterial(0,materials_[index])
    model.viewMask,model.castShadows,model.drawDistance = 2,false,240
    model.animationLodBias,model.updateInvisible = 2,false
    local height = 1.64+(pose.appearance%5)*.035
    body.scale = Vector3.ONE*(height/models_[index].boundingBox.size.y)
    local animation = model:AddAnimationState(animations_[index])
    animation:SetLooped(true)
    animation:SetWeight(1)
    animation:SetTime(0)
    created_=created_+1
    return {root=root,body=body,model=model,animation=animation,appearanceKind=index}
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
        actor.model:RemoveAllAnimationStates()
        actor.model.model=models_[index]
        actor.model:SetMaterial(0,materials_[index])
        actor.animation=actor.model:AddAnimationState(animations_[index])
        actor.animation:SetLooped(true);actor.animation:SetWeight(1)
        actor.appearanceKind=index
    end
    actor.root.name="Passenger_"..pose.id
    actor.root.enabled=true
    actor.body.scale=Vector3.ONE*((1.64+(pose.appearance%5)*.035)/models_[index].boundingBox.size.y)
    return actor
end
---@param stationIndex integer
local function background(stationIndex)
    local st = Route.GetStations()[stationIndex]
    if not st then return end
    for i=1,12 do
        background_[i] = {id=-stationIndex*100-i,appearance=i+stationIndex,
            position=Route.SampleOffset(st.s-180+i*18,4.7,Station.GetDimensions().platformTopY+.045),
            yaw=select(3,Route.Sample(st.s))-90,visible=true,walking=false,walkDistance=0}
    end
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
            local phase=(clock_*.55+i*4)%24
            local along=station.s-175+i*18+(phase<=12 and phase or 24-phase)
            p.position=Route.SampleOffset(along,6.2,Station.GetDimensions().platformTopY+.045)
            p.yaw=select(3,Route.Sample(along))+(phase<=12 and 0 or 180)
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
    local budget = math.max(0,MAX_VISIBLE-#poses-6)
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
    for i,p in ipairs(poses) do if i<=MAX_VISIBLE then retained[p.id]=true end end
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
        if i<=MAX_VISIBLE then
            local actor=actors_[p.id]
            if not actor then actor=acquire(p);actors_[p.id]=actor end
            actor.root.position,actor.root.rotation=p.position,Quaternion(p.yaw,Vector3.UP)
            local length=actor.animation:GetLength()
            actor.animation:SetTime(p.walking and ((p.walkDistance/1.25)%1)*length or 0)
            if p.walking then walkingCount_=walkingCount_+1 end
        end
    end
end
function Passengers.GetStats()
    local n=0
    for _ in pairs(actors_) do n=n+1 end
    return {visible=n,walking=walkingCount_,stationIndex=stationIndex_,roots=root_ and 1 or 0,
        sharedModels=#models_,sharedMaterials=#materials_,geometryBuilds=0,npcRigidBodies=0,
        background=#background_,maxVisible=MAX_VISIBLE,doorMarkers=0,skinned=true,bonesPerActor=41,
        pooled=#pool_,created=created_,reused=reused_,allocated=n+#pool_}
end
return Passengers
