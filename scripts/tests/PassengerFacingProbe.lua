-- 乘客朝向探针：把单个乘客放在原点，从 +Z 与 +X 两个方向各拍一张，
-- 用于确定源模型正面朝向，修正"横着走"的 90° 误差。
local Passengers = require "world.Passengers"

local probe_ = {}
---@type Scene|nil
local scene_ = nil
---@type Node|nil
local cameraNode_ = nil
local frame_ = 0
local shots_ = {
    { name = "probe_passenger_from_plusZ", dir = Vector3(0, 0, 1) },
    { name = "probe_passenger_from_plusX", dir = Vector3(1, 0, 0) },
    { name = "probe_passenger_from_minusZ", dir = Vector3(0, 0, -1) },
}

function Start()
    scene_ = Scene()
    scene_:CreateComponent("Octree")
    local zone = scene_:CreateChild("Zone"):CreateComponent("Zone")
    zone.boundingBox = BoundingBox(Vector3(-50, -10, -50), Vector3(50, 30, 50))
    zone.ambientColor = Color(.55, .57, .60)
    local light = scene_:CreateChild("Sun"):CreateComponent("Light")
    light.lightType = LIGHT_DIRECTIONAL
    light.brightness = 1.2
    light.color = Color(1, .97, .92)

    -- 直接用 Passengers 的创建路径，保证与运行时朝向完全一致。
    Passengers.Init(assert(scene_))
    local pose = { id = 1, appearance = 0, position = Vector3(0, 0, 0), yaw = 0,
        visible = true, walking = false, walkDistance = 0 }
    Passengers.Update(1, { pose }, 0.016, nil, "waiting")

    cameraNode_ = scene_:CreateChild("ProbeCamera")
    local camera = cameraNode_:CreateComponent("Camera")
    camera.fov = 40
    camera.nearClip = .1
    camera.farClip = 100
    renderer:SetViewport(0, Viewport:new(assert(scene_), camera))
    SubscribeToEvent("Update", "HandleProbeUpdate")
    SubscribeToEvent("EndRendering", "HandleProbeCapture")
    print("[PassengerFacingProbe] 就绪")
end

---@param eventType string
---@param eventData UpdateEventData
function HandleProbeUpdate(eventType, eventData)
    frame_ = frame_ + 1
    local index = math.floor((frame_ - 1) / 30) + 1
    local shot = shots_[index]
    if not shot then return end
    cameraNode_.position = Vector3(0, 1.05, 0) + shot.dir * 4.2
    cameraNode_:LookAt(Vector3(0, 1.05, 0))
end

---@param eventType string
---@param eventData EndRenderingEventData
function HandleProbeCapture(eventType, eventData)
    for i, shot in ipairs(shots_) do
        if frame_ == i * 30 then
            local image = Image()
            if graphics:TakeScreenShot(image) then
                image:SavePNG("/workspace/screenshots/" .. shot.name .. ".png")
                print("[PassengerFacingProbe] 截图 " .. shot.name)
            end
            image:Dispose()
        end
    end
end
