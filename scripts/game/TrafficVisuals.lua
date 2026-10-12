-- 有预算上限的单线程AI车辆渲染，沿用scene脚手架的场景持有和
-- Update/PostUpdate生命周期；不自行创建相机或视口。
-- Node.Clone共享已加载Model/Material，本模块只拥有克隆节点，
-- 不Dispose玩家资源，不修改cache，也不重复加载大资产。
local Train = require "train.Train"
local RailNetwork = require "world.RailNetwork"
local BodyShellRepairs = require "train.BodyShellRepairs"
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
local MAX_VISIBLE = 3
local RANGE = 2400
local STEP = .10

---@param formation TrafficVisualFormation
local function destroy(formation)
    -- 只释放节点和组件，不释放共享Model/Material。
    formation.root:Dispose()
    formations_[formation.id] = nil
end

function Visuals.Shutdown()
    if root_ then root_:Dispose() end
    root_, formations_ = nil, {}
    selected_, leadId_, refresh_ = "", -1, 0
end

---@param scene Scene|nil
function Visuals.Init(scene)
    Visuals.Shutdown()
    clones_, rebuilds_, errorLogged_, errors_, error_ = 0, 0, false, 0, ""
    if scene then root_ = scene:CreateChild("AITraffic", LOCAL) end
end

function Visuals.Reset()
    for _, formation in pairs(formations_) do formation.root:Dispose() end
    formations_ = {}
    refresh_ = STEP
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
        drawable.lodBias, drawable.drawDistance = .18, RANGE + 400
    end
    for _, drawable in ipairs(node:GetComponents("CustomGeometry")) do
        drawable.castShadows, drawable.viewMask = false, 1
        drawable.drawDistance = RANGE + 400
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
    if #formation.cars == 8 then formation.ready = true end
    return true
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
            local yaw = math.deg(math.atan(chord.x, chord.z))
            local rotation = Quaternion(yaw, Vector3.UP)
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
                car.targetRotation = Quaternion(math.deg(math.atan(nextChord.x,nextChord.z)),Vector3.UP)
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
                bogie.node.rotation = Quaternion(math.deg(math.atan(axis.x,axis.z)) - yaw,Vector3.UP)
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
end

---@param dt number
---@param trains TrafficVisualVehicle[]
---@param playerS number
function Visuals.Update(dt, trains, playerS)
    if not root_ then return end
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
                if distance <= RANGE then candidates[#candidates+1] = {train=train,distance=distance} end
            end
        end
        table.sort(candidates,function(a,b) return a.distance < b.distance end)
        for _, formation in pairs(formations_) do formation.wanted = false end
        for i = 1, math.min(MAX_VISIBLE,#candidates) do
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
    local visible, cars, pending = 0, 0, 0
    for _, formation in pairs(formations_) do
        cars = cars + #formation.cars
        if formation.ready and formation.wanted then visible = visible + 1 else pending = pending + 1 end
    end
    return {visible=visible,clonedCars=cars,totalClones=clones_,rebuilds=rebuilds_,
        pending=pending,maxVisible=MAX_VISIBLE,sharedResources=true,errors=errors_,error=error_}
end

return Visuals
