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
local Connections = require "train.EMUConnections"
local RailNetwork = require "world.RailNetwork"
local Accident = require "train.Accident"
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
---@field number string
---@field service string
---@field frontEnd RollingStockEndFace|nil
---@field rearEnd RollingStockEndFace|nil

---@type EMUConnection[]
local connections_ = {}
---@type Material|nil
local connectionMaterial_ = nil
---@type Material|nil
local identityMaterial_ = nil

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
local drivingMode_ = GameConfig.Gameplay.DrivingMode or "relaxed"
local visualsDirty_ = true
local lastVisualS_ = math.huge
---@type table<string, boolean>
local ready_ = {}
---@type table<string, string>
local readyMessages_ = {}

---@param entry TrainCatalogEntry
---@param role string
---@return string, boolean
local function roleProfile(entry, role)
    local roles = entry.roles
    local spec = roles and (role == "head" and roles.head or (role == "tail" and roles.tail or roles.middle))
    if spec then return spec.profile, spec.reverse == true end
    return role == "middle" and assert(entry.middle) or entry.head, role == "tail"
end

---@param entry TrainCatalogEntry
---@return string[]
local function entryProfiles(entry)
    if entry.kind ~= "emu" then return {entry.head} end
    local result = {} ---@type string[]
    local seen = {} ---@type table<string, boolean>
    for _, role in ipairs({"head","middle","tail"}) do
        local id = roleProfile(entry,role)
        if not seen[id] then result[#result+1]=id; seen[id]=true end
    end
    return result
end

local function releaseUnused()
    -- 先释放Locomotive专用旧蓝白缓存；RollingStock保留独立尾profile和当前车辆真正使用的资源。
    local head = selected_.kind == "emu" and roleProfile(selected_,"head") or selected_.head
    local middle = selected_.kind == "emu" and roleProfile(selected_,"middle") or nil
    RollingStock.RetainProfiles(entryProfiles(selected_))
    Locomotive.ReleaseExcept(head,middle)
end

---@param entry TrainCatalogEntry
---@return boolean, string
local function prepareEntry(entry)
    local ok, message = true, "成品可加载"
    for _, id in ipairs(entryProfiles(entry)) do
        ok, message = RollingStock.EnsureBakedAvailable(id)
        if not ok then break end
        if id == "blue_white" then ok, message = Locomotive.Prepare(id)
        else ok, message = RollingStock.Prepare(id) end
        if not ok then break end
    end
    ready_[entry.id], readyMessages_[entry.id] = ok, message
    return ok, message
end

---@param entry TrainCatalogEntry
---@return boolean
local function availableEntry(entry)
    for _, id in ipairs(entryProfiles(entry)) do if not RollingStock.IsAvailable(id) then return false end end
    return true
end

--- 构建暂存子树，成功后才替换旧车辆；Train根及音效组件永不因Select移除。
---@param entry TrainCatalogEntry
---@return boolean, string
local function rebuildVehicles(entry)
    if not root_ then return false, "列车尚未构建" end
    local staging = root_:CreateChild("Vehicles_" .. entry.id)
    local oldCars, oldPositions, oldWheels = cars_, carPositions_, wheels_
    local oldHeadlight = headLightNode_
    local oldConnections, oldConnectionMaterial = connections_, connectionMaterial_
    local oldIdentityMaterial = identityMaterial_
    cars_, carPositions_, wheels_, connections_ = {}, {}, {}, {}
    headLightNode_, connectionMaterial_, identityMaterial_ = nil, nil, nil
    -- 非动车编组由本机车牵引专属客车队：换机车即换客车涂装与车队色带。
    if entry.kind ~= "emu" then Coach.SelectLivery(entry.id) end
    local totalLength = 0.0
    local started = os.clock()
    local ok, message = pcall(function()
        local previousLength, previousOffset = 0.0, 0.0
        for i = 1, 8 do
            local isLead, isTail = i == 1, i == 8
            local profileId = isLead and entry.head or "coach"
            local reverse = false
            if entry.kind == "emu" then
                profileId, reverse = roleProfile(entry,isLead and "head" or (isTail and "tail" or "middle"))
            end
            local profile = Catalog.Profiles[profileId]
            local length = profile and profile.length or (isLead and Locomotive.Length or Coach.Length)
            local gap = i == 2 and entry.gap or (entry.kind == "emu" and entry.gap or T.CarGap)
            -- 原Coach包络含两端0.80米车钩；新机车完整包络需与其外端再留间隙。
            if i == 2 and entry.kind ~= "emu" and entry.id ~= "blue_white" then gap = gap + .80 end
            local offset = isLead and 0 or previousOffset - previousLength * .5 - length * .5 - gap
            local frontEnd = entry.kind == "emu" and RollingStock.GetConnectionEnd(profileId,"front",reverse) or nil
            local rearEnd = entry.kind == "emu" and RollingStock.GetConnectionEnd(profileId,"rear",reverse) or nil
            local previous = cars_[i-1]
            local connectionGap = entry.connectionGap or entry.gap
            if previous and previous.rearEnd and frontEnd then
                -- 距离从实测端面起算。真实车钩仍在模型中：保留其包络，不能为缩缝把车钩穿进车体。
                local clearance = (previous.rearEnd.center.z+previous.length*.5)
                    + (length*.5-frontEnd.center.z)+entry.gap
                connectionGap = math.max(connectionGap,clearance)
                offset = previous.offset+previous.rearEnd.center.z-frontEnd.center.z-connectionGap
            end
            local node = staging:CreateChild("Car" .. i)
            local bogies = {} ---@type {node:Node,z:number}[]
            if entry.kind == "emu" then
                local _, drawable = RollingStock.Build(node, profileId, reverse)
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
            local identity = entry.formation and entry.formation[i]
            local car = {node=node, offset=offset, pivot=profile and profile.pivot or (isLead and 6.6 or 8.5),
                bogies=bogies, length=length, profile=profileId, reverse=reverse,
                number=identity and identity.number or string.format("%02d",i),
                service=identity and identity.service or (isLead and "motor" or "trailer"),
                frontEnd=frontEnd,rearEnd=rearEnd} --[[@as TrainCar]]
            cars_[i] = car
            if entry.kind == "emu" then
                if not connectionMaterial_ then connectionMaterial_ = Connections.CreateMaterial() end
                if not identityMaterial_ then identityMaterial_ = Connections.CreateIdentityMaterial() end
                Connections.BuildIdentity(car,identityMaterial_)
                if previous and previous.rearEnd and frontEnd then
                    connections_[#connections_+1] = Connections.Create(staging,previous,car,connectionGap,connectionMaterial_)
                elseif previous then
                    print(string.format("[Train] %s %02d-%02d未生成风挡：缺少合法实测平端（资产保留，外观须修复）",entry.id,i-1,i))
                end
            end
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
        visualsDirty_ = true
        Train.UpdateVisuals(0)
    end)
    if not ok then
        staging:Dispose()
        if connectionMaterial_ then connectionMaterial_:Dispose() end
        if identityMaterial_ then identityMaterial_:Dispose() end
        cars_, carPositions_, wheels_, headLightNode_ = oldCars, oldPositions, oldWheels, oldHeadlight
        connections_, connectionMaterial_, identityMaterial_ = oldConnections, oldConnectionMaterial, oldIdentityMaterial
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
    if previousVehicles then previousVehicles:Dispose() end
    if oldConnectionMaterial then oldConnectionMaterial:Dispose() end
    if oldIdentityMaterial then oldIdentityMaterial:Dispose() end
    selected_, activeLength_, wheelAngle_ = entry, totalLength, 0
    Train.SetHeadlight(headlightOn_)
    local liveryNote = entry.kind == "emu" and "" or ("；客车队 " .. Coach.GetLiveryName())
    print(string.format("[Train] %s：8节 %s，全长%.3fm，%d车轮，%.2fs；运营%.0f/构造%.0fkm/h%s",
        entry.id, entry.kind == "emu" and "头+6中间+反向尾" or "1机车+7原Coach",
        totalLength, #wheels_, os.clock() - started, entry.operatingSpeedKmh, entry.maxSpeedKmh, liveryNote))
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
    releaseUnused()
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
---@param maximumS? number 前方闭塞安全界；不从本模块反向引用Traffic
---@param minimumS? number 后方闭塞安全界
function Train.Update(dt, maximumS, minimumS)
    if Accident.IsActive() then
        Accident.Update(dt)
        state_.v = 0
        return
    end
    local velocity = state_.v
    local absVelocity = math.abs(velocity)
    local force = 0.0
    if state_.throttle > 0 then
        local tractionScale = drivingMode_ == "relaxed" and GameConfig.Gameplay.RelaxedTractiveScale or 1
        local powerScale = drivingMode_ == "relaxed" and GameConfig.Gameplay.RelaxedPowerScale or 1
        force = math.min(selected_.maxTractive * tractionScale,
            selected_.powerW * powerScale / math.max(absVelocity, .1))
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
    state_.v = nextVelocity -- 不把建议/构造速度当自动限速器，危险由事故系统处理。
    -- 锁存实际行驶经历，推油门但被制动锁住不算移动；停稳后仍可用于接站。
    if math.abs(state_.v) > 0.02 then state_.moving = true end
    local oldS = state_.s
    local nextS = state_.s + state_.v * dt
    -- 闭塞界仅用于显示提示；玩家纵向积分不再强制收油、制动或钳位置。
    state_.s = Route.Wrap(nextS)
    Accident.Evaluate(dt,state_.v,selected_.maxSpeedKmh,nextS,activeLength_,Train.GetTrackSample,cars_)
    if Accident.IsActive() then
        for _,connection in ipairs(connections_) do connection.node.enabled=false end
    end
    state_.distanceTravelled = state_.distanceTravelled + (Route.IsClosed()
        and math.abs(state_.v) * dt or math.abs(state_.s - oldS))
    RailNetwork.UpdatePlayer(state_.s, activeLength_, state_.reversing)
end

---@param dt number
function Train.UpdateVisuals(dt)
    if not root_ then return end
    if Accident.IsActive() then
        Accident.UpdateVisuals()
        for i,car in ipairs(cars_) do carPositions_[i]=car.node.worldPosition end
        return
    end
    if not visualsDirty_ and math.abs(state_.s - lastVisualS_) < .0001 then return end
    lastVisualS_, visualsDirty_ = state_.s, false
    for i, car in ipairs(cars_) do
        local centerS = state_.s + car.offset
        local front = Train.GetTrackSample(centerS + car.pivot)
        local rear = Train.GetTrackSample(centerS - car.pivot)
        local midpoint = (front + rear) * 0.5
        local chord = front - rear
        local yaw = math.deg(math.atan(chord.x, chord.z))
        local rotation = Quaternion(yaw, Vector3.UP)
        car.node.position = midpoint
        car.node.rotation = rotation
        carPositions_[i] = midpoint
        for _, bogie in ipairs(car.bogies) do
            -- 支点在弧线上，车体中心在弦中点：弯道不能只旋转车体而把轮轴放到轨外。
            local bogiePosition = Train.GetTrackSample(centerS + bogie.z)
            local axleFront = Train.GetTrackSample(centerS + bogie.z + 1.2)
            local axleRear = Train.GetTrackSample(centerS + bogie.z - 1.2)
            local axis = axleFront - axleRear
            local bogieYaw = math.deg(math.atan(axis.x, axis.z))
            bogie.node.position = rotation:Inverse() * (bogiePosition - midpoint)
            bogie.node.rotation = Quaternion(bogieYaw - yaw, Vector3.UP)
        end
    end
    for _, connection in ipairs(connections_) do Connections.Update(connection) end
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
    Accident.Reset()
    for _,connection in ipairs(connections_) do connection.node.enabled=true end
    state_.s = Route.Wrap(s or 0)
    state_.v, state_.throttle, state_.brake = 0, 0, 0
    state_.reversing, state_.moving = false, false
    visualsDirty_ = true
    RailNetwork.Reset(state_.s, activeLength_, false)
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
-- 场景销毁前清除所有借用节点，避免再次开始时访问已Dispose的旧Train根。
function Train.Shutdown()
    Accident.Reset()
    Locomotive.ForgetLead()
    if root_ then root_:Dispose() end
    if connectionMaterial_ then connectionMaterial_:Dispose() end
    if identityMaterial_ then identityMaterial_:Dispose() end
    root_,vehicles_,headLightNode_,connectionMaterial_,identityMaterial_=nil,nil,nil,nil,nil
    cars_,carPositions_,wheels_,connections_={},{},{},{}
    activeLength_,visualsDirty_=0,true
end
function Train.ExportState()
    return {id=selected_.id,s=state_.s,v=state_.v,throttle=state_.throttle,brake=state_.brake,
        reversing=state_.reversing,moving=state_.moving,distanceTravelled=state_.distanceTravelled,
        drivingMode=drivingMode_,derailed=Accident.IsActive()}
end
function Train.RestoreState(data)
    assert(type(data)=="table" and data.id==selected_.id,"存档车型不一致")
    assert(type(data.s)=="number" and data.s>=0 and data.s<=Route.GetLength(),"存档位置无效")
    assert(type(data.v)=="number" and math.abs(data.v)<200,"存档速度无效")
    Train.Reset(data.s)
    state_.reversing,state_.moving=data.reversing==true,data.moving==true
    state_.distanceTravelled=math.max(0,tonumber(data.distanceTravelled) or 0)
    drivingMode_=data.drivingMode=="simulation" and "simulation" or "relaxed"
    state_.v=data.v
    Train.SetThrottle(math.floor(tonumber(data.throttle) or 0))
    Train.SetBrake(tonumber(data.brake) or 1)
    RailNetwork.UpdatePlayer(state_.s,activeLength_,state_.reversing)
    visualsDirty_=true;Train.UpdateVisuals(0)
    -- 事故由入口在客流/运营恢复完成后重建，避免先结束本局再恢复开门队列。
end

---@return TrainCar[]
function Train.GetCars() return cars_ end
---@return EMUConnection[]
function Train.GetConnections() return connections_ end

---@param s number
---@return Vector3, Vector3, number
function Train.GetTrackSample(s)
    return RailNetwork.Sample(s, RailNetwork.GetPlayerLane(s))
end

function Train.GetAccidentStatus() return Accident.GetStatus() end
function Train.IsDerailed() return Accident.IsActive() end
function Train.Derail(reason)
    if Accident.Trigger(cars_,state_.v,reason) then
        for _,connection in ipairs(connections_) do connection.node.enabled=false end
    end
end
function Train.GetDrivingMode() return drivingMode_ end
---@param name string
---@return boolean, string
function Train.SetDrivingMode(name)
    if name ~= "relaxed" and name ~= "simulation" then return false, "未知驾驶模式" end
    if math.abs(state_.v) > .02 then return false, "请停稳后切换驾驶模式" end
    drivingMode_ = name
    return true, name == "relaxed" and "休闲牵引：响应更敏捷" or "模拟牵引：原SI动力参数"
end

---@param id? string
---@return boolean, string
function Train.GetAppearanceStatus(id)
    local entry = id and Catalog.Find(id) or selected_
    if not entry then return false, "未知车型" end
    for _, profile in ipairs(entryProfiles(entry)) do
        local report = RollingStock.GetAppearanceReport(profile)
        if not report.accepted then return false, report.message end
    end
    return true, "外观及实测端面已验收"
end
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
---@field appearanceReady boolean
---@field appearanceMessage string

---@return TrainCatalogItem[]
function Train.GetCatalog()
    local result = {}
    for _, entry in ipairs(Catalog.Entries) do
        local appearanceReady, appearanceMessage = Train.GetAppearanceStatus(entry.id)
        result[#result + 1] = {id=entry.id, name=entry.name, kind=entry.kind,
            description=entry.description .. (appearanceReady and "" or " 外观仍需检修"),
            maxSpeedKmh=entry.maxSpeedKmh, ready=availableEntry(entry),
            appearanceReady=appearanceReady,
            appearanceMessage=appearanceReady and (entry.kind=="emu" and "平端与连接校准通过 · 派生车体" or "派生车体可用 · 局部修补") or "部分车体外观仍需检修"}
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
    if Accident.IsActive() then return false,"事故后请重开本局，再选择车型" end
    if math.abs(state_.v) > .1 then return false, "请先停稳列车再换车（速度须不超过0.1m/s）" end
    local entry = Catalog.Find(id)
    if not entry then return false, "未知车型，请从车队目录选择" end
    if not root_ then return false, "列车尚未构建" end
    local ready, message = prepareEntry(entry)
    if not ready then
        releaseUnused()
        print("[Train] 车型资源准备失败：" .. entry.name .. "：" .. message)
        return false, entry.name .. "资源未准备好，请稍后重试"
    end
    if entry.id ~= selected_.id then
        local ok, result = rebuildVehicles(entry)
        if not ok then
            releaseUnused()
            return false, entry.name .. "装配失败，原列车已保留"
        end
    end
    releaseUnused()
    -- 不调用Reset：弧长、行驶经历、站序与XP的拥有者都保留；仅安全锁存驾驶控件。
    state_.v, state_.throttle, state_.brake = 0, 0, 1
    visualsDirty_ = true
    RailNetwork.UpdatePlayer(state_.s, activeLength_, state_.reversing)
    Train.UpdateVisuals(0)
    return true, "已选择" .. entry.name .. "，制动已锁定"
end

return Train
