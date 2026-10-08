-- ============================================================================
-- Train - 蓝白长机罩内燃机车与客车编组
-- 纵向自由度 s/v；车体按两转向架支点弦摆放，转向架各自跟随线路。
-- ============================================================================

local GameConfig = require "config.GameConfig"
local Coach = require "train.Coach"
local Route = require "world.Route"
local Locomotive = require "train.Locomotive"
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

---@param scene Scene
function Train.Build(scene)
    if root_ then root_:Remove() end
    root_ = scene:CreateChild("Train")
    cars_, carPositions_, wheels_ = {}, {}, {}
    wheelAngle_ = 0
    local started = os.clock()
    for i = 1, T.Cars do
        local offset = i == 1 and 0 or -(Locomotive.Length * 0.5 + T.CarLength * 0.5
            + 1.025 + (i - 2) * (T.CarLength + T.CarGap))
        local node = root_:CreateChild("Car" .. i)
        local bogies = {} ---@type {node:Node,z:number}[]
        if i == 1 then
            Train.BuildLocomotive(node)
        else
            local result = Coach.Build(node, i - 1, 1)
            bogies = result.bogies
            for _, wheel in ipairs(result.wheels) do Train.RegisterWheel(wheel, 1) end
        end
        cars_[i] = {node = node, offset = offset, pivot = i == 1 and 6.6 or 8.5, bogies = bogies}
        carPositions_[i] = Vector3.ZERO
    end
    -- 相机射线只看环境mask=2；所有列车网格使用mask=1。
    for _, drawable in ipairs(root_:GetComponents("StaticModel", true)) do drawable.viewMask = 1 end
    for _, drawable in ipairs(root_:GetComponents("CustomGeometry", true)) do drawable.viewMask = 1 end
    Train.UpdateVisuals(0)
    print(string.format("[Train] 编组：1机车+%d客车、%d独立车轮，%.2fs",
        T.Cars - 1, #wheels_, os.clock() - started))
end

---@param node Node
function Train.BuildLocomotive(node)
    Locomotive.Build(node)
    local lightNode = node:CreateChild("HeadLight")
    lightNode.position = Vector3(0, RAIL_TOP + 2.45, Locomotive.Length * 0.5 - 0.3)
    lightNode.direction = Vector3(0, -0.10, 1)
    local light = lightNode:CreateComponent("Light")
    light.lightType = LIGHT_SPOT
    light.color = Color(1.0, 0.96, 0.86)
    light.brightness, light.range, light.fov = 12, 70, 46
    light.castShadows = false
    headLightNode_ = lightNode
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
        force = T.MaxTractive * math.min(1, T.PowerKneeSpeed / math.max(absVelocity, T.PowerKneeSpeed))
            * state_.throttle / T.MaxThrottle * (state_.reversing and -1 or 1)
    end
    local braking = T.MaxBrakeForce * state_.brake
    local resistance = (T.ResistA + T.ResistB * absVelocity + T.ResistC * absVelocity * absVelocity) * T.Mass
    local net = force
    if absVelocity > 0.01 then
        net = force - (velocity > 0 and 1 or -1) * (braking + resistance)
    elseif math.abs(force) <= braking + resistance then
        net = 0
        velocity = 0
    else
        net = force - (force > 0 and 1 or -1) * (braking + resistance)
    end
    local nextVelocity = velocity + net / T.Mass * dt
    -- 减速不得跨过零速度变成倒车；只有显式换向并牵引才能反向启动。
    if velocity * nextVelocity < 0 and (state_.throttle == 0 or force * velocity >= 0) then
        nextVelocity = 0
    end
    if math.abs(nextVelocity) < 0.02 and state_.throttle == 0 then nextVelocity = 0 end
    state_.v = Clamp(nextVelocity, -T.MaxSpeedKmh / KMH * 0.5, T.MaxSpeedKmh / KMH)
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
    if headLightNode_ then
        local light = headLightNode_:GetComponent("Light")
        if light then light.enabled = on end
    end
end

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
    if lead then return lead:LocalToWorld(Vector3(0, 0, Locomotive.Length * 0.5)) end
    return Vector3.ZERO
end

return Train
