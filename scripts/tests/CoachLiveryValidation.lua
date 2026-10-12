-- 专属客车验证：四款机车各牵引独立涂装的云舟 C24 客车队。
-- 只读取材质颜色与场景图，不改几何；用真实渲染帧出图供人眼核对。
local Catalog = require "config.TrainCatalog"
local Route = require "world.Route"
local Train = require "train.Train"
local Coach = require "train.Coach"
local CoachLiveries = require "config.CoachLiveries"

local Validation = {}
---@type Scene|nil
local scene_ = nil
---@type Node|nil
local cameraNode_ = nil
---@type Node|nil
local preview_ = nil
local captureFrame_ = 0
local liveries_ = { "blue_white", "DF4D", "SS9G", "HXD3D" }
local captured_ = {} ---@type table<string, boolean>

local SHOTS = {
    { frame=120, id="blue_white", name="coach_livery_blue_white" },
    { frame=150, id="DF4D",       name="coach_livery_DF4D" },
    { frame=180, id="SS9G",       name="coach_livery_SS9G" },
    { frame=210, id="HXD3D",      name="coach_livery_HXD3D" },
}

---@param id string
local function findCoachDrawable(id)
    local cars = Train.GetCars()
    for _, car in ipairs(cars) do
        if car.profile == "coach" then return car end
    end
    return nil
end

---@param color Color
---@return string
local function key(color)
    return string.format("%.3f,%.3f,%.3f", color.r, color.g, color.b)
end

---@param id string
---@return string
local function sampleBodyColor(id)
    local car = assert(findCoachDrawable(id), "未找到客车节点：" .. id)
    local drawable = assert(car.node:GetComponent("StaticModel", true), "客车缺少StaticModel")
    local material = assert(drawable:GetMaterial(0), "客车缺少材质")
    local variant = material:GetShaderParameter("MatDiffColor")
    return key(variant:GetColor())
end

local function buildCamera()
    if cameraNode_ then return end
    cameraNode_ = scene_:CreateChild("CoachLiveryCamera")
    local camera = cameraNode_:CreateComponent("Camera")
    camera.fov = 46
    camera.nearClip = .1
    camera.farClip = 600
    cameraNode_:CreateComponent("SoundListener")
    renderer:SetViewport(0, Viewport:new(assert(scene_), camera))
    renderer.hdrRendering = false
end

---@param id string
local function viewConsist(id)
    local cars = Train.GetCars()
    local coach = assert(findCoachDrawable(id))
    local head = assert(cars[1])
    local target = coach.node.worldPosition + Vector3(0, 1.4, 0)
    local offset = head.node.worldRotation * Vector3(46, 12, 0)
    cameraNode_.worldPosition = target + offset
    cameraNode_:LookAt(target)
end

function Validation.Run()
    scene_ = Scene()
    scene_:CreateComponent("Octree")
    local zoneNode = scene_:CreateChild("Zone")
    local zone = zoneNode:CreateComponent("Zone")
    zone.boundingBox = BoundingBox(Vector3(-4000, -400, -4000), Vector3(4000, 400, 4000))
    zone.ambientColor = Color(.42, .45, .48)
    zone.fogColor = Color(.59, .66, .71)
    zone.fogStart = 600.0
    zone.fogEnd = 1800.0
    local lightNode = scene_:CreateChild("Sun")
    lightNode.direction = Vector3(.35, -1.0, .45)
    local light = lightNode:CreateComponent("Light")
    light.lightType = LIGHT_DIRECTIONAL
    light.brightness = 1.15
    light.color = Color(1.0, .97, .90)
    Route.Build()
    Train.Build(assert(scene_))
    Train.Reset(450)
    buildCamera()

    local seen = {} ---@type table<string, string>
    for _, id in ipairs(liveries_) do
        local entry = assert(Catalog.Find(id), "未知机车：" .. id)
        assert(entry.kind == "locomotive", id .. " 不是机车，不能验证客车队")
        local ok, message = Train.Select(id)
        assert(ok, message)
        assert(Coach.GetLiveryId() == id, "换机车后客车队未跟随：" .. Coach.GetLiveryId() .. " != " .. id)
        local name = Coach.GetLiveryName()
        local color = sampleBodyColor(id)
        assert(not seen[color], string.format("%s 的客车车体色与 %s 完全相同：%s", id, seen[color] or "?", color))
        seen[color] = id
        print(string.format("[CoachLiveryValidation] %s -> %s，车体色 %s，%s", id, name, color,
            entry.name))
    end
    -- 动车编组仍是独立模型路径，不应被机车客车涂装影响。
    assert(Train.Select("CR400AF"), "旗舰动车无法选择")
    assert(Train.GetCarCount() == 8, "动车编组不是八节")
    print("[CoachLiveryValidation] 四款机车客车队颜色互不相同；动车编组不受影响")
    assert(Train.Select("blue_white"), "回到默认机车失败")
end

function Validation.View(id)
    Train.Select(id)
    viewConsist(id)
end

function Start()
    local ok, message = pcall(Validation.Run)
    if not ok then print("[CoachLiveryValidation] FAIL " .. tostring(message)) end
    local viewOK, viewMessage = pcall(Validation.View, "blue_white")
    if not viewOK then print("[CoachLiveryValidation] 预览不可用：" .. tostring(viewMessage)) end
    captureFrame_ = 0
    SubscribeToEvent("Update", "HandleCoachLiveryUpdate")
    SubscribeToEvent("EndRendering", "HandleCoachLiveryCapture")
end

---@param eventType string
---@param eventData UpdateEventData
function HandleCoachLiveryUpdate(eventType, eventData)
    captureFrame_ = captureFrame_ + 1
    for _, shot in ipairs(SHOTS) do
        if captureFrame_ == shot.frame - 10 and not captured_[shot.id] then
            local ok, message = pcall(Validation.View, shot.id)
            if not ok then log:Write(LOG_ERROR, "[CoachLiveryValidation] " .. tostring(message)) end
        end
    end
end

---@param eventType string
---@param eventData EndRenderingEventData
function HandleCoachLiveryCapture(eventType, eventData)
    for _, shot in ipairs(SHOTS) do
        if captureFrame_ == shot.frame and not captured_[shot.id] then
            captured_[shot.id] = true
            local image = Image()
            if graphics:TakeScreenShot(image) then
                if image:SavePNG("/workspace/screenshots/" .. shot.name .. ".png") then
                    print("[CoachLiveryValidation] Screenshot " .. shot.name)
                end
            end
            image:Dispose()
        end
    end
end
