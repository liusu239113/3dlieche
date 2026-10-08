-- ============================================================================
-- Train - 蓝白长机罩内燃机车与客车编组
-- 纵向自由度 s/v；车体按两转向架支点弦摆放，转向架各自跟随线路。
-- ============================================================================

local GameConfig = require "config.GameConfig"
local Coach = require "train.Coach"
local Route = require "world.Route"
local Locomotive = require "train.Locomotive"
local RollingStock = require "train.RollingStock"
local Catalog = require "config.TrainCatalog"
local Train = {}
local T = GameConfig.Train
local KMH = 3.6
local RAIL_TOP = 0.34
local WHEEL_R = 0.46

local state_ = {
    s = 0.0, v = 0.0, throttle = 0, brake = 0.0,
    reversing = false, moving = false, distanceTravelled = 0.0,
}

---@class TrainBogie
---@field node Node
---@field z number

---@class TrainCar
---@field node Node
---@field offset number
---@field pivot number
---@field bogies {node:Node,z:number}[]
---@field length number
---@field profile string
---@field reverse boolean

---@type Node|nil
local root_ = nil
---@type TrainCar[]
local cars_ = {}
---@type Vector3[]
local carPositions_ = {}
---@type {node:Node,base:Quaternion}[]
local wheels_ = {}
---@type Node|nil
local headLightNode_ = nil
local wheelAngle_ = 0.0
---@type TrainCatalogEntry
local selected_ = assert(Catalog.Find(Catalog.FallbackId))
---@type Node|nil
local vehicles_ = nil
local activeLength_ = 0.0
local headlightOn_ = true
---@type table<string, boolean>
local ready_ = {}
---@type table<string, string>
local readyMessages_ = {}

---@param entry TrainCatalogEntry
---@return boolean, string
local function prepareEntry(entry)
    local ok, message = RollingStock.EnsureBakedAvailable(entry.head)
    if ok and entry.middle then ok, message = RollingStock.EnsureBakedAvailable(entry.middle) end
    if ok then ok, message = Locomotive.Prepare(entry.head) end
    if ok and entry.middle then ok, message = RollingStock.Prepare(entry.middle) end
    ready_[entry.id], readyMessages_[entry.id] = ok, message
    return ok, message
end

---@param entry TrainCatalogEntry
---@return boolean
local function availableEntry(entry)
    return RollingStock.IsAvailable(entry.head) and (not entry.middle or RollingStock.IsAvailable(entry.middle))
end

--- 构建暂存子树，成功后才替换旧车辆；Train根及音效组件永不因Select移除。
---@param entry TrainCatalogEntry
---@return boolean, string
local function rebuildVehicles(entry)
    if not root_ then return false, "列车尚未构建" end
    local staging = root_:CreateChild("Vehicles_" .. entry.id)
    local oldCars, oldPositions, oldWheels = cars_, carPositions_, wheels_
    local oldHeadlight = headLightNode_
    cars_, carPositions_, wheels_ = {}, {}, {}
    headLightNode_ = nil
    local totalLength = 0.0
    local started = os.clock()
    local ok, message = pcall(function()
        local previousLength, previousOffset = 0.0, 0.0
        for i = 1, 8 do
            local isLead, isTail = i == 1, i == 8
            local profileId = entry.kind == "emu" and ((isLead or isTail) and entry.head or assert(entry.middle))
                or (isLead and entry.head or "coach")
            local profile = Catalog.Profiles[profileId]
            local length = profile and profile.length or (isLead and Locomotive.Length or Coach.Length)
            local gap = i == 2 and entry.gap or (entry.kind == "emu" and entry.gap or T.CarGap)
            -- 原Coach包络含两端0.80米车钩；新机车完整包络需与其外端再留间隙。
            if i == 2 and entry.kind ~= "emu" and entry.id ~= "blue_white" then gap = gap + .80 end
            local offset = isLead and 0 or previousOffset - previousLength * .5 - length * .5 - gap
            local node = staging:CreateChild("Car" .. i)
            local bogies = {} ---@type {node:Node,z:number}[]
            if entry.kind == "emu" then
                local _, drawable = RollingStock.Build(node, profileId, isTail)
                if isLead then
                    Locomotive.RegisterLead(drawable)
                    Train.BuildHeadlight(node, length)
                end
            elseif isLead then
                Train.BuildLocomotive(node, entry.head)
            else
                local result = Coach.Build(node, i - 1, 1)
                bogies = result.bogies
                for _, wheel in ipairs(result.wheels) do Train.RegisterWheel(wheel, 1) end
            end
            cars_[i] = {node=node, offset=offset, pivot=profile and profile.pivot or (isLead and 6.6 or 8.5),
                bogies=bogies, length=length, profile=profileId, reverse=entry.kind == "emu" and isTail}
            carPositions_[i] = Vector3.ZERO
            previousLength, previousOffset = length, offset
        end
        local first, last = assert(cars_[1]), assert(cars_[#cars_])
        local front = first.length * .5
        local rear = last.offset - last.length * .5 - (entry.kind == "emu" and 0 or .80)
        totalLength = front - rear
        assert(totalLength < Route.PlatformEnd - Route.PlatformStart, "车型编组超过310米站台")
        assert(rear >= Route.PlatformStart and front <= Route.PlatformEnd, "编组不在站台停靠包络内")
        for _, drawable in ipairs(staging:GetComponents("StaticModel", true)) do drawable.viewMask = 1 end
        for _, drawable in ipairs(staging:GetComponents("CustomGeometry", true)) do drawable.viewMask = 1 end
        Train.UpdateVisuals(0)
    end)
    if not ok then
        staging:Remove()
        cars_, carPositions_, wheels_, headLightNode_ = oldCars, oldPositions, oldWheels, oldHeadlight
        local oldLead = Train.GetLeadNode()
        if oldLead then
            local drawable = oldLead:GetComponent("StaticModel", true)
            if drawable then Locomotive.RegisterLead(drawable) end
        end
        print("[Train] 车辆替换失败，保留原编组：" .. tostring(message))
        return false, tostring(message)
    end
    local previousVehicles = vehicles_
    vehicles_ = staging
    if previousVehicles then previousVehicles:Remove() end
    selected_, activeLength_, wheelAngle_ = entry, totalLength, 0
    Train.SetHeadlight(headlightOn_)
    print(string.format("[Train] %s：8节 %s，全长%.3fm，%d车轮，%.2fs；运营%.0f/构造%.0fkm/h",
        entry.id, entry.kind == "emu" and "头+6中间+反向尾" or "1机车+7原Coach",
        totalLength, #wheels_, os.clock() - started, entry.operatingSpeedKmh, entry.maxSpeedKmh))
    return true, "已选择" .. entry.name
end

---@param scene Scene
function Train.Build(scene)
    -- Build只在项目初始化/重建场景调用；同一scene复用Train根，不悬空AudioManager引用。
    if not root_ or root_.scene ~= scene then
        root_ = scene:CreateChild("Train")
        vehicles_ = nil
    end
    local default = assert(Catalog.Find(Catalog.DefaultId))
    local ok, message = prepareEntry(default)
    if ok then ok, message = rebuildVehicles(default) end
    if not ok and default.id ~= Catalog.FallbackId then
        print("[Train] 默认动车确实失败，按需准备蓝白回退：" .. message)
        local fallback = assert(Catalog.Find(Catalog.FallbackId))
        ok, message = prepareEntry(fallback)
        if ok then ok, message = rebuildVehicles(fallback) end
    end
    assert(ok, message)
    Locomotive.ReleaseExcept(selected_.head, selected_.middle)
end

---@param node Node
---@param length number
function Train.BuildHeadlight(node, length)
    local lightNode = node:CreateChild("HeadLight")
    lightNode.position = Vector3(0, RAIL_TOP + 2.45, length * 0.5 - 0.3)
    lightNode.direction = Vector3(0, -0.10, 1)
    local light = lightNode:CreateComponent("Light")
    light.lightType = LIGHT_SPOT
    light.color = Color(1.0, 0.96, 0.86)
    light.brightness, light.range, light.fov = 12, 70, 46
    light.castShadows = false
    light.enabled = headlightOn_
    headLightNode_ = lightNode
end

---@param node Node
---@param id? string
function Train.BuildLocomotive(node, id)
    Locomotive.Build(node, id)
    Train.BuildHeadlight(node, Locomotive.GetLength(id))
end

---@param node Node
---@param index integer
---@param forwardSign number
function Train.BuildCoach(node, index, forwardSign)
    local result = Coach.Build(node, index, forwardSign)
    for _, wheel in ipairs(result.wheels) do Train.RegisterWheel(wheel, forwardSign) end
    return result
end

---@param node Node
---@param forwardSign number
function Train.RegisterWheel(node, forwardSign)
    -- 轮轴已烘焙为X；保存实际朝向，不能硬编码Y轴圆柱的旋转。
    wheels_[#wheels_ + 1] = {node = node, base = node.rotation}
end

---@param dt number
function Train.Update(dt)
    local velocity = state_.v
    local absVelocity = math.abs(velocity)
    local force = 0.0
    if state_.throttle > 0 then
        force = math.min(selected_.maxTractive, selected_.powerW / math.max(absVelocity, .1))
            * state_.throttle / T.MaxThrottle * (state_.reversing and -1 or 1)
    end
    local braking = selected_.maxBrakeForce * state_.brake
    -- 每车型全编组SI阻力；不要再把旧机车等效加速度乘动车质量。
    local resistance = selected_.resistA + selected_.resistB * absVelocity + selected_.resistC * absVelocity * absVelocity
    local net = force
    if absVelocity > 0.01 then
        net = force - (velocity > 0 and 1 or -1) * (braking + resistance)
    elseif math.abs(force) <= braking + resistance then
        net = 0
        velocity = 0
    else
        net = force - (force > 0 and 1 or -1) * (braking + resistance)
    end
    local nextVelocity = velocity + net / selected_.mass * dt
    -- 减速不得跨过零速度变成倒车；只有显式换向并牵引才能反向启动。
    if velocity * nextVelocity < 0 and (state_.throttle == 0 or force * velocity >= 0) then
        nextVelocity = 0
    end
    if math.abs(nextVelocity) < 0.02 and state_.throttle == 0 then nextVelocity = 0 end
    state_.v = Clamp(nextVelocity, -math.min(selected_.maxSpeedKmh * .5, 60) / KMH, selected_.maxSpeedKmh / KMH)
    -- 锁存实际行驶经历，推油门但被制动锁住不算移动；停稳后仍可用于接站。
    if math.abs(state_.v) > 0.02 then state_.moving = true end
    state_.distanceTravelled = state_.distanceTravelled + math.abs(state_.v) * dt
    state_.s = Route.Wrap(state_.s + state_.v * dt)
end

---@param dt number
function Train.UpdateVisuals(dt)
    if not root_ then return end
    for i, car in ipairs(cars_) do
        local centerS = Route.Wrap(state_.s + car.offset)
        local front = Route.Sample(centerS + car.pivot)
        local rear = Route.Sample(centerS - car.pivot)
        local midpoint = (front + rear) * 0.5
        local chord = front - rear
        local yaw = math.deg(math.atan(chord.x, chord.z))
        local rotation = Quaternion(yaw, Vector3.UP)
        car.node.position = midpoint
        car.node.rotation = rotation
        carPositions_[i] = midpoint
        for _, bogie in ipairs(car.bogies) do
            -- 支点在弧线上，车体中心在弦中点：弯道不能只旋转车体而把轮轴放到轨外。
            local bogiePosition = Route.Sample(centerS + bogie.z)
            local axleFront = Route.Sample(centerS + bogie.z + 1.2)
            local axleRear = Route.Sample(centerS + bogie.z - 1.2)
            local axis = axleFront - axleRear
            local bogieYaw = math.deg(math.atan(axis.x, axis.z))
            bogie.node.position = rotation:Inverse() * (bogiePosition - midpoint)
            bogie.node.rotation = Quaternion(bogieYaw - yaw, Vector3.UP)
        end
    end
    if dt > 0 and math.abs(state_.v) > 0.01 then Train.SpinWheels(state_.v / WHEEL_R * dt) end
end

---@param delta number
function Train.SpinWheels(delta)
    wheelAngle_ = (wheelAngle_ + delta) % (2 * math.pi)
    local spin = Quaternion(math.deg(wheelAngle_), Vector3.RIGHT)
    for _, wheel in ipairs(wheels_) do wheel.node.rotation = spin * wheel.base end
end

function Train.ThrottleUp()
    if state_.throttle < T.MaxThrottle then
        state_.throttle = state_.throttle + 1
    end
    return state_.throttle
end

function Train.ThrottleDown()
    state_.throttle = math.max(0, state_.throttle - 1)
    return state_.throttle
end

---@param notch integer
function Train.SetThrottle(notch)
    state_.throttle = math.max(0, math.min(T.MaxThrottle, math.floor(notch)))
end

---@param value number
function Train.SetBrake(value) state_.brake = Clamp(value, 0, 1) end
---@param delta number
function Train.AddBrake(delta) Train.SetBrake(state_.brake + delta) end

function Train.EmergencyBrake()
    state_.throttle, state_.brake = 0, 1
end

function Train.ToggleReversing()
    if math.abs(state_.v) < 0.3 then state_.reversing = not state_.reversing end
    return state_.reversing
end

---@param s number
function Train.Reset(s)
    state_.s = Route.Wrap(s or 0)
    state_.v, state_.throttle, state_.brake = 0, 0, 0
    state_.reversing, state_.moving = false, false
    Train.UpdateVisuals(0)
end

---@param on boolean
function Train.SetHeadlight(on)
    headlightOn_ = on
    if headLightNode_ then
        local light = headLightNode_:GetComponent("Light")
        if light then light.enabled = on end
    end
end

---@return number
function Train.GetOperatingSpeedKmh() return selected_.operatingSpeedKmh end
---@return number
function Train.GetMaxSpeedKmh() return selected_.maxSpeedKmh end
---@return number
function Train.GetServiceDeceleration() return selected_.serviceDeceleration end

---@return number
function Train.GetSpeedKmh() return state_.v * KMH end
---@return number
function Train.GetSpeedMs() return state_.v end
---@return integer
function Train.GetThrottle() return state_.throttle end
---@return number
function Train.GetBrake() return state_.brake end
---@return boolean
function Train.IsReversing() return state_.reversing end
---@return number 机车中心弧长
function Train.GetS() return state_.s end
---@return boolean
function Train.IsMoving() return state_.moving end
---@return number
function Train.GetDistanceTravelled() return state_.distanceTravelled end
---@return Node|nil
function Train.GetLeadNode() return cars_[1] and cars_[1].node or nil end
---@return Vector3
function Train.GetLeadPosition() return carPositions_[1] or Vector3.ZERO end
---@return integer
function Train.GetCarCount() return #cars_ end
---@return Vector3[]
function Train.GetCarPositions() return carPositions_ end
---@return TrainCar[]
function Train.GetCars() return cars_ end
---@return Vector3
function Train.GetHeadPosition()
    local lead = Train.GetLeadNode()
    if lead then return lead:LocalToWorld(Vector3(0, 0, Locomotive.GetLength(selected_.head) * 0.5)) end
    return Vector3.ZERO
end

---@class TrainCatalogItem
---@field id string
---@field name string
---@field kind string
---@field description string
---@field maxSpeedKmh number
---@field ready boolean

---@return TrainCatalogItem[]
function Train.GetCatalog()
    local result = {}
    for _, entry in ipairs(Catalog.Entries) do
        result[#result + 1] = {id=entry.id, name=entry.name, kind=entry.kind,
            description=entry.description, maxSpeedKmh=entry.maxSpeedKmh, ready=availableEntry(entry)}
    end
    return result
end

---@return string
function Train.GetSelectedId() return selected_.id end
---@return string
function Train.GetSelectedName() return selected_.name end
---@return string
function Train.GetPowerType()
    if selected_.kind == "emu" then return "emu" end
    return (selected_.id == "SS9G" or selected_.id == "HXD3D") and "electric" or "diesel"
end
---@return number
function Train.GetActiveLength() return activeLength_ end
---@return Vector3
function Train.GetCabOffset()
    local profile = Catalog.Profiles[selected_.head]
    return profile and profile.cab or Vector3(0, 3.35, Locomotive.Length * .5 - 2.2)
end
---@return Quaternion
function Train.GetLeadRotation()
    local lead = Train.GetLeadNode()
    return lead and lead.worldRotation or Quaternion()
end
---@return Node|nil
function Train.GetRoot() return root_ end

---@param id string
---@return boolean, string
function Train.Select(id)
    if math.abs(state_.v) > .1 then return false, "请先停稳列车再换车（速度须不超过0.1m/s）" end
    local entry = Catalog.Find(id)
    if not entry then return false, "未知车型：" .. tostring(id) end
    if not root_ then return false, "列车尚未构建" end
    local ready, message = prepareEntry(entry)
    if not ready then
        Locomotive.ReleaseExcept(selected_.head, selected_.middle)
        return false, "车型资源未准备好，可重试：" .. message
    end
    if entry.id ~= selected_.id then
        local ok, result = rebuildVehicles(entry)
        if not ok then
            Locomotive.ReleaseExcept(selected_.head, selected_.middle)
            return false, result
        end
    end
    Locomotive.ReleaseExcept(selected_.head, selected_.middle)
    -- 不调用Reset：弧长、行驶经历、站序与XP的拥有者都保留；仅安全锁存驾驶控件。
    state_.v, state_.throttle, state_.brake = 0, 0, 1
    Train.UpdateVisuals(0)
    return true, "已选择" .. entry.name .. "，制动已锁定"
end

return Train
