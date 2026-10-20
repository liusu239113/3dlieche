-- 有预算上限的单线程AI车辆渲染，沿用scene脚手架的场景持有和
-- Update/PostUpdate生命周期；不自行创建相机或视口。
-- Node.Clone共享已加载Model/Material，本模块只拥有克隆节点，
-- 不Dispose玩家资源，不修改cache，也不重复加载大资产。
local Train = require "train.Train"
local RailNetwork = require "world.RailNetwork"
local RoadCorridor = require "world.RoadCorridor"
local RoadVehicles = require "world.RoadVehicles"
local BodyShellRepairs = require "train.BodyShellRepairs"
local NightLighting = require "world.NightLighting"
local World = require "world.WorldMaterials"
local StationVisualConfig = require "config.StationVisualConfig"
local VisualQuality = require "config.VisualQuality"
local Visuals = {}

---@class TrafficVisualVehicle
---@field id string
---@field dir number
---@field lane integer
---@field headS number
---@field frontOffset number
---@field speedMs number
---@field lo number
---@field hi number
---@field active boolean
---@field visible boolean
---@class TrafficVisualCar
---@field node Node
---@field offset number
---@field pivot number
---@field bogies {node:Node,z:number}[]
---@field previous Vector3
---@field target Vector3
---@field previousRotation Quaternion
---@field targetRotation Quaternion
---@class TrafficVisualFormation
---@field id string
---@field root Node
---@field cars TrafficVisualCar[]
---@field ready boolean
---@field age number
---@field elapsed number
---@field wanted boolean
---@field distance number
---@field headlight Light?
---@field headlightMarkers Node?

---@type Node|nil
local root_ = nil
---@type table<string, TrafficVisualFormation>
local formations_ = {}
local selected_ = ""
local leadId_ = -1
local refresh_ = 0.0
local clones_ = 0
local rebuilds_ = 0
local errorLogged_ = false
local errors_ = 0
local error_ = ""
local qualityId_ = "medium"
local maxVisible_ = 3
local range_ = 2400
local RANGE_BASE = 2400
---@type Node|nil
local roadRoot_ = nil
---@class TrafficRoadCar
---@field node Node?
---@field plan CorridorMovingVehiclePlan
---@field s number
---@type TrafficRoadCar[]
local roadCars_ = {}
---@type CorridorMovingVehiclePlan[]
local roadPlanSource_ = {}
local STEP = .10

---@param formation TrafficVisualFormation
local function destroy(formation)
    -- 只释放节点和组件，不释放共享Model/Material。
    formation.root:Dispose()
    formations_[formation.id] = nil
end

function Visuals.Shutdown()
    if root_ then root_:Dispose() end
    if roadRoot_ then roadRoot_:Dispose() end
    root_, formations_ = nil, {}
    selected_, leadId_, refresh_ = "", -1, 0
    roadRoot_,roadCars_,roadPlanSource_ = nil,{},{}
end

---@param scene Scene|nil
function Visuals.Init(scene)
    Visuals.Shutdown()
    clones_, rebuilds_, errorLogged_, errors_, error_ = 0, 0, false, 0, ""
    if scene then
        root_ = scene:CreateChild("AITraffic", LOCAL)
        roadRoot_ = scene:CreateChild("RoadTraffic", LOCAL)
        roadRoot_.enabled = false
    end
end

function Visuals.Reset()
    for _, formation in pairs(formations_) do formation.root:Dispose() end
    formations_ = {}
    refresh_ = STEP
end

---@param qualityId string|nil
function Visuals.SetQuality(qualityId)
    local id = StationVisualConfig.NormalizeQuality(qualityId)
    local budget = StationVisualConfig.GetQuality(id)
    local nextVisible = budget.trafficMaxFormations
    local nextRange = budget.trafficRange
    local changed = qualityId_ ~= id or maxVisible_ ~= nextVisible or range_ ~= nextRange
    qualityId_, maxVisible_, range_ = id, nextVisible, nextRange
    if changed then
        Visuals.Reset()
        print(string.format("[TrafficVisuals] 画质=%s：最多%d组AI编组，显示范围%.0fm",id,maxVisible_,range_))
    end
end

---@param node Node
local function prune(node)
    -- Identity/gangway材质由Train在换车时显式Dispose，因此克隆
    -- 必须移除这些装饰节点；真实八节车体仍完整保留。
    for _, child in ipairs(node:GetChildren()) do
        local name = string.lower(child.name)
        if name:find("caridentity", 1, true) or name:find("gangway", 1, true)
            or name:find("interior", 1, true) or name:find("cabinterior", 1, true)
            or name:find("passengerseat", 1, true) or name == "headlight" then
            child:Dispose()
        else
            prune(child)
        end
    end
    for _, component in ipairs(node:GetComponents("Light")) do component:Dispose() end
    for _, component in ipairs(node:GetComponents("SoundSource")) do component:Dispose() end
    for _, component in ipairs(node:GetComponents("SoundSource3D")) do component:Dispose() end
    for _, component in ipairs(node:GetComponents("RigidBody")) do component:Dispose() end
    for _, component in ipairs(node:GetComponents("CollisionShape")) do component:Dispose() end
    for _, component in ipairs(node:GetComponents("LuaScriptInstance")) do component:Dispose() end
    for _, component in ipairs(node:GetComponents("AnimationController")) do component:Dispose() end
    for _, component in ipairs(node:GetComponents("ParticleEmitter")) do component:Dispose() end
    for _, drawable in ipairs(node:GetComponents("StaticModel")) do
        -- 玩家司机视角会隐藏头车外壳，AI的克隆外壳必须重新启用。
        drawable.enabled, drawable.castShadows, drawable.viewMask = true, false, 1
        -- 只降低远处AI的LOD偏置；不改共享模型阈值或玩家近车细节。
        drawable.lodBias, drawable.drawDistance = .18, range_ + 400
    end
    for _, drawable in ipairs(node:GetComponents("CustomGeometry")) do
        drawable.castShadows, drawable.viewMask = false, 1
        drawable.drawDistance = range_ + 400
    end
end

---@param source Node
---@param target Node
local function shareDrawables(source,target)
    -- Clone按序列化属性复制；程序化Material可能没有资源名，必须
    -- 显式重新共享源引用，而不是让克隆去加载一个空材质路径。
    local sourceModels,targetModels = source:GetComponents("StaticModel"),target:GetComponents("StaticModel")
    for index,model in ipairs(sourceModels) do
        local copy = targetModels[index]
        if copy then
            copy.model = model.model
            for geometry = 0,model.numGeometries-1 do copy:SetMaterial(geometry,model:GetMaterial(geometry)) end
        end
    end
    local sourceGeometry,targetGeometry = source:GetComponents("CustomGeometry"),target:GetComponents("CustomGeometry")
    for index,geometry in ipairs(sourceGeometry) do
        local copy = targetGeometry[index]
        if copy then
            for section = 0,geometry.numGeometries-1 do copy:SetMaterial(section,geometry:GetMaterial(section)) end
        end
    end
    local children = target:GetChildren()
    for index,child in ipairs(source:GetChildren()) do
        local copy = children[index]
        if copy then shareDrawables(child,copy) end
    end
end

---@param formation TrafficVisualFormation
---@return boolean
local function buildOneCar(formation)
    local source = Train.GetCars()[#formation.cars + 1]
    if not source then return false end
    local cloned = source.node:Clone(LOCAL)
    cloned:SetParent(formation.root)
    cloned.enabled = true
    shareDrawables(source.node,cloned)
    BodyShellRepairs.RestoreClone(cloned)
    prune(cloned)
    local bogies = {} ---@type {node:Node,z:number}[]
    for _, sourceBogie in ipairs(source.bogies or {}) do
        local bogie = cloned:GetChild(sourceBogie.node.name, true)
        if bogie then bogies[#bogies + 1] = {node=bogie,z=sourceBogie.z} end
    end
    formation.cars[#formation.cars + 1] = {
        node=cloned, offset=source.offset, pivot=source.pivot, bogies=bogies,
        previous=Vector3.ZERO,target=Vector3.ZERO,
        previousRotation=Quaternion(),targetRotation=Quaternion(),
    }
    clones_ = clones_ + 1
    if #formation.cars == 8 then
        formation.ready = true
        -- 只在完整编组真正车头建立一组灯，不克隆玩家双束或给每节车加灯。
        local lead = formation.cars[1].node
        local front = Train.GetCars()[1].length*.5-.30
        local node = lead:CreateChild("AITrafficHeadlight",LOCAL)
        node.position,node.direction = Vector3(0,2.79,front+.46),Vector3(0,-.08,1)
        local light = node:CreateComponent("Light")
        light.lightType,light.range,light.fov = LIGHT_SPOT,125,36
        light.innerConeAngle,light.outerConeAngle = 11.7,18
        light.punctualLight = true
        light.color,light.brightness = Color(1,.95,.82),0
        light.castShadows,light.affectVolumetricFog = false,false
        light.specularIntensity,light.aspectRatio = .10,1.3
        light.viewMask,light.lightMask = 3,2
        light.enabled = false
        formation.headlight = light
        local markers = lead:CreateChild("AITrafficHeadlightMarkers",LOCAL)
        local batch = World.NewBatch(markers,NightLighting.GetBulbMaterial("ai"),false,1)
        for _,x in ipairs({-.64,.64}) do
            batch:AddBox(Vector3(x,2.79,front+.045),Vector3(.24,.18,.065))
        end
        batch:Finish()
        batch.geometry.viewMask,batch.geometry.drawDistance = 3,900
        formation.headlightMarkers = markers
    end
    return true
end

---@param chord Vector3
---@return Quaternion
local function trackRotation(chord)
    -- 真实纵坡的局部+Z必须和轨面弦一致；只算yaw会让轮组及车灯仍水平穿山。
    local rotation = Quaternion()
    rotation:FromLookRotation(chord:Normalized(), Vector3.UP)
    return rotation
end

---@param formation TrafficVisualFormation
---@param train TrafficVisualVehicle
---@param playerS number
---@param dt number
local function pose(formation, train, playerS, dt)
    local near = formation.distance <= 700
    formation.elapsed = formation.elapsed + dt
    local sampleNow = near or formation.age == 0 or formation.elapsed >= STEP
    if sampleNow then
        formation.elapsed = 0
        for _, car in ipairs(formation.cars) do
            local centerS = train.headS - train.dir * train.frontOffset + train.dir * car.offset
            local front = RailNetwork.Sample(centerS + train.dir * car.pivot, train.lane)
            local rear = RailNetwork.Sample(centerS - train.dir * car.pivot, train.lane)
            local chord = front - rear
            local position = (front + rear) * .5
            local rotation = trackRotation(chord)
            car.previous = formation.age == 0 and position or car.node.position
            car.previousRotation = formation.age == 0 and rotation or car.node.rotation
            -- 远距离向0.1秒预测弦姿态插值；近距离逐帧采样，
            -- 高速会车不会因可见性10Hz检查变成跳帧运动。
            if not near and train.speedMs > 0 then
                local nextCenter = centerS + train.dir * train.speedMs * STEP
                local nextFront = RailNetwork.Sample(nextCenter + train.dir * car.pivot, train.lane)
                local nextRear = RailNetwork.Sample(nextCenter - train.dir * car.pivot, train.lane)
                local nextChord = nextFront - nextRear
                car.target = (nextFront + nextRear) * .5
                car.targetRotation = trackRotation(nextChord)
            else
                car.target, car.targetRotation = position, rotation
            end
            if near then car.node.position, car.node.rotation = position, rotation end
            for _, bogie in ipairs(car.bogies) do
                local at = centerS + train.dir * bogie.z
                local point = RailNetwork.Sample(at, train.lane)
                local a = RailNetwork.Sample(at + train.dir * 1.2, train.lane)
                local b = RailNetwork.Sample(at - train.dir * 1.2, train.lane)
                local axis = a - b
                bogie.node.position = rotation:Inverse() * (point - position)
                bogie.node.rotation = rotation:Inverse() * trackRotation(axis)
            end
        end
    end
    if not near then
        local fraction = math.min(1, formation.elapsed / STEP)
        for _, car in ipairs(formation.cars) do
            car.node.position = car.previous + (car.target - car.previous) * fraction
            car.node.rotation = car.previousRotation:Nlerp(car.targetRotation,fraction,true)
        end
    end
    formation.age = formation.age + dt + .000001
    formation.root.enabled = formation.ready and formation.wanted
    local factor = NightLighting.GetFactor()
    if formation.headlight then
        -- 头车局部+Z已经由pose按真实train.dir定向；不另猜正/反向世界坐标。
        formation.headlight.enabled = formation.root.enabled and factor>.02 and formation.distance<420
        formation.headlight.brightness = 1200*factor*math.max(0,math.min(1,(420-formation.distance)/100))
    end
    if formation.headlightMarkers then
        formation.headlightMarkers.enabled = formation.root.enabled and factor>.02
    end
end

---@param dt number
---@param playerS number
function Visuals.UpdateRoadVehicles(dt,playerS)
    local owner=roadRoot_
    if not owner then return end
    local plans=RoadCorridor.GetMovingVehiclePlan()
    if plans~=roadPlanSource_ then
        for _,car in ipairs(roadCars_) do if car.node then car.node:Dispose() end end
        roadCars_={};roadPlanSource_=plans
        for _,plan in ipairs(plans) do roadCars_[#roadCars_+1]={plan=plan,s=plan.startS} end
    end
    local enabled=StationVisualConfig.GetQuality(qualityId_).trafficProxyEnabled
        and VisualQuality.Get(qualityId_).id~="low"
    owner.enabled=enabled
    if not enabled then return end
    for _,car in ipairs(roadCars_) do
        local plan=car.plan
        car.s=RoadCorridor.AdvanceMovingVehicle(plan,car.s,dt,playerS)
        local visible=math.abs(car.s-playerS)<900
        if visible and not car.node then
            local asset=RoadVehicles.GetAsset(plan.kind)
            if asset then
                car.node=owner:CreateChild(plan.id,LOCAL)
                local drawable=car.node:CreateComponent("StaticModel")
                RoadVehicles.ApplyAsset(drawable,asset)
                drawable.castShadows=true;drawable.shadowDistance=120;drawable.viewMask=6
                drawable.drawDistance=900;drawable.lodBias=.7
            end
        end
        if car.node then
            car.node.enabled=visible
            if visible then
                local surface,forward=RoadCorridor.SampleVehicle(car.s,plan.direction,plan.kind)
                RoadVehicles.Pose(car.node,surface,forward,plan.kind)
            end
        end
    end
end
function Visuals.GetRoadVehicleStats()
    local rows={}
    for _,car in ipairs(roadCars_) do
        rows[#rows+1]={id=car.plan.id,kind=car.plan.kind,s=car.s,direction=car.plan.direction,
            first=car.plan.first,last=car.plan.last,node=car.node,
            visible=roadRoot_~=nil and roadRoot_.enabled and car.node~=nil and car.node.enabled}
    end
    return {count=#roadCars_,maxVehicles=4,vehicles=rows,playerFollowSpawn=false,buses=0}
end

---@param playerS number
function Visuals.Update(dt, trains, playerS)
    if not root_ then return end
    Visuals.UpdateRoadVehicles(dt,playerS)
    local lead = Train.GetLeadNode()
    local id = lead and lead.ID or -1
    local selected = Train.GetSelectedId()
    if selected ~= selected_ or id ~= leadId_ then
        Visuals.Reset() -- 必须先释放旧车型克隆，再共享新车型资源
        selected_, leadId_ = selected, id
        rebuilds_, errorLogged_ = rebuilds_ + 1, false
        print("[TrafficVisuals] 共享当前玩家车型 " .. selected .. "；重建最多3组8节，不加载新车型")
    end
    refresh_ = refresh_ + math.max(0,dt)
    if refresh_ >= STEP then
        refresh_ = 0
        local candidates = {} ---@type {train:TrafficVisualVehicle,distance:number}[]
        for _, train in ipairs(trains) do
            train.visible = false
            if train.active then
                local distance = math.max(0,train.lo - playerS,playerS - train.hi)
                if distance <= range_ then candidates[#candidates+1] = {train=train,distance=distance} end
            end
        end
        table.sort(candidates,function(a,b) return a.distance < b.distance end)
        for _, formation in pairs(formations_) do formation.wanted = false end
        for i = 1, math.min(maxVisible_,#candidates) do
            local candidate = candidates[i]
            local formation = formations_[candidate.train.id]
            if not formation then
                local parent = root_:CreateChild("AI_" .. candidate.train.id, LOCAL)
                parent.enabled = false
                formation = {id=candidate.train.id,root=parent,cars={},ready=false,
                    age=0,elapsed=0,wanted=true,distance=candidate.distance}
                formations_[formation.id] = formation
            end
            formation.wanted, formation.distance = true, candidate.distance
        end
        local retired = {} ---@type TrafficVisualFormation[]
        for _, formation in pairs(formations_) do
            if not formation.wanted then retired[#retired+1] = formation end
        end
        for _, formation in ipairs(retired) do destroy(formation) end
    end
    -- 每次调用至多克隆一节已有源车辆子树，不创建异步资产加载任务。
    for _, train in ipairs(trains) do
        local formation = formations_[train.id]
        if formation and formation.wanted and not formation.ready and #Train.GetCars() == 8 then
            local ok, result = pcall(buildOneCar,formation)
            if not ok then
                errors_,error_ = errors_+1,tostring(result)
                if not errorLogged_ then
                    errorLogged_ = true
                    print("[TrafficVisuals] 克隆失败（逻辑仍运行）：" .. error_)
                end
                destroy(formation)
            end
            break
        end
    end
    for _, train in ipairs(trains) do
        local formation = formations_[train.id]
        if formation then
            pose(formation,train,playerS,math.max(0,dt))
            train.visible = formation.ready and formation.wanted
        else train.visible = false end
    end
end

---@return table
function Visuals.GetStats()
    local visible, cars, pending, headlights = 0, 0, 0, 0
    for _, formation in pairs(formations_) do
        if formation.headlight and formation.headlight.enabled then headlights=headlights+1 end
        cars = cars + #formation.cars
        if formation.ready and formation.wanted then visible = visible + 1 else pending = pending + 1 end
    end
    return {visible=visible,clonedCars=cars,totalClones=clones_,rebuilds=rebuilds_,
        pending=pending,maxVisible=maxVisible_,range=range_,sharedResources=true,errors=errors_,error=error_,headlights=headlights,maxHeadlights=maxVisible_}
end

return Visuals
