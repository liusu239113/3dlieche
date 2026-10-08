-- ============================================================================
-- Camera - 列车相机：库驱动环绕、场景网格净空检查、司机视角
-- ============================================================================

local GameConfig = require "config.GameConfig"
local Route = require "world.Route"
local Locomotive = require "train.Locomotive"
local Train = require "train.Train"
local ThirdPersonCamera = require "urhox-libs.Camera.ThirdPersonCamera"

local Camera = {}
local CFG = GameConfig.Camera

---@type ThirdPersonCameraInstance|nil
local follow_ = nil
---@type Node|nil
local target_ = nil
---@type Octree|nil
local octree_ = nil
---@type Node|nil
local node_ = nil
---@type Camera|nil
local camera_ = nil

local mode_ = "chase"
local yawOffset_ = 140.0
local pitch_ = 9.0
local sightDistance_ = 0.0
local obstructionLogged_ = false
local AIM_HEIGHT = 2.6
local ENVIRONMENT_MASK = 2

local MODES = {
    chase = { distance = 27.0, offset = Vector3(0, AIM_HEIGHT, 0), fov = 54.0,
        yaw = 140.0, pitch = 9.0 },
    side = { distance = 56.0, offset = Vector3(0, AIM_HEIGHT, 0), fov = 52.0,
        yaw = 110.0, pitch = 14.0 },
    cab = { distance = 0.0, offset = Vector3.ZERO, fov = 68.0,
        yaw = 0.0, pitch = -2.0 },
}

-- 净空检测（不是车辆物理）：
-- 注视点 * ===== 八条平行探测射线 ===== [相机近裁剪面]
--         列车 mask=1，不检测自身；站房/雨棚/地面 mask=2。
-- 碰到网格 -> 相机立即缩到障碍前0.6m，避免插值穿墙；擦边由0.35m探测半径覆盖。
-- 对真实三角形检测，不能只用整块合并网格的巨大 AABB。
---@param aim Vector3
---@param desired Vector3
---@return Vector3
local function constrainSight(aim, desired)
    local delta = desired - aim
    local length = delta:Length()
    if length < 0.01 or not octree_ then return desired end
    local direction = delta / length
    local right = direction:CrossProduct(Vector3.UP):Normalized()
    local up = right:CrossProduct(direction):Normalized()
    local safe = length
    for i = 0, 8 do
        local offset = Vector3.ZERO
        if i > 0 then
            local angle = (i - 1) * math.pi / 4
            offset = (right * math.cos(angle) + up * math.sin(angle)) * 0.35
        end
        local hit = octree_:RaycastSingle(Ray(aim + offset, direction),
            RAY_TRIANGLE, length + 0.6, DRAWABLE_GEOMETRY, ENVIRONMENT_MASK)
        if hit.drawable then safe = math.min(safe, math.max(0.5, hit.distance - 0.6)) end
    end
    sightDistance_ = safe
    if safe < length - 0.1 and not obstructionLogged_ then
        print(string.format("[Camera] 环境遮挡保护：%.1fm -> %.1fm", length, safe))
        obstructionLogged_ = true
    elseif safe >= length - 0.1 then
        obstructionLogged_ = false
    end
    return aim + direction * safe
end

---@param scene Scene
function Camera.Build(scene)
    follow_ = ThirdPersonCamera.Create(scene, {
        modes = MODES, initialMode = "chase", transitionSpeed = 12.0,
        nearClip = 0.15, farClip = math.min(CFG.FarClip, 1500.0),
        minDistance = 0.5, collisionMask = ENVIRONMENT_MASK,
    })
    target_ = scene:CreateChild("CameraTarget")
    octree_ = scene:GetComponent("Octree")
    node_ = follow_:GetNode()
    camera_ = follow_:GetCamera()
    camera_.viewMask = 7
    mode_ = "chase"
    Camera.ResetView()
    Locomotive.SetCabView(false)
    renderer:SetViewport(0, Viewport:new(scene, camera_))
    renderer.hdrRendering = true
    print("[Camera] 库驱动相机就绪：列车/环境分层，三角网格八射线防穿墙")
end

---@return Node|nil
function Camera.GetNode() return node_ end
---@return Camera|nil
function Camera.GetCamera() return camera_ end
---@return number
function Camera.GetSightDistance() return sightDistance_ end
---@return string
function Camera.GetMode() return mode_ end

---@param name string
function Camera.SetMode(name)
    if not MODES[name] then return end
    mode_ = name
    if follow_ and name ~= "cab" then follow_:SetMode(name) end
    Camera.ResetView()
    Locomotive.SetCabView(name == "cab")
    print("[Camera] 视角切换 -> " .. name)
end

function Camera.CycleMode()
    Camera.SetMode(mode_ == "chase" and "side" or (mode_ == "side" and "cab" or "chase"))
    return mode_
end

---@param delta number
function Camera.AddYaw(delta)
    yawOffset_ = (yawOffset_ + delta + 180) % 360 - 180
    if mode_ == "cab" then yawOffset_ = Clamp(yawOffset_, -75, 75) end
end

---@param delta number
function Camera.AddPitch(delta)
    pitch_ = Clamp(pitch_ + delta, mode_ == "cab" and -25 or 3, mode_ == "cab" and 20 or 50)
end

function Camera.ResetView()
    yawOffset_ = MODES[mode_].yaw
    pitch_ = MODES[mode_].pitch
end

---@param dt number
---@param trainS number 机车中心弧长
function Camera.Update(dt, trainS)
    if not follow_ or not target_ or not node_ or not camera_ then return end
    local position, _, yaw = Route.Sample(Route.Wrap(trainS))
    local rotation = Quaternion(yaw, Vector3.UP)
    local lead = Train.GetLeadNode()
    if lead then
        -- Train两支点弦姿态是唯一来源，不能司机相机另采弧线而相对车头摆动。
        position = lead.worldPosition
        rotation = lead.worldRotation
        yaw = rotation:YawAngle()
    end
    target_.position = position
    if mode_ == "cab" then
        node_.position = position + rotation * Train.GetCabOffset()
        node_.rotation = Quaternion(yaw + yawOffset_, Vector3.UP) * Quaternion(pitch_, Vector3.RIGHT)
        camera_.fov = MODES.cab.fov
        return
    end
    -- 环绕位置与旋转由 ThirdPersonCamera 库计算；这里只约束环境净空。
    follow_:Update(dt, target_, yaw + yawOffset_, pitch_)
    -- 竖屏保留机车横向构图，不能把横屏纵向FOV照搬导致车头被裁掉。
    local width, height = graphics:GetWidth(), graphics:GetHeight()
    if width > 0 and height > width then
        local halfFov = math.rad(follow_:GetCurrentFOV() * 0.5)
        camera_.fov = math.min(100, math.deg(2 * math.atan(math.tan(halfFov) * (16 / 9) * height / width)))
    end
    local aim = position + Vector3(0, AIM_HEIGHT, 0)
    node_.position = constrainSight(aim, node_.position)
    -- 低角度下地面保护，防止玩家俯仰把近裁剪面埋进地面。
    local constrained = node_.position
    if constrained.y < 0.8 then
        node_.position = Vector3(constrained.x, 0.8, constrained.z)
        node_:LookAt(aim)
    end
end

return Camera
