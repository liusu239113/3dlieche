-- 独立验证入口：无需场景环境/UI；tests下不参与main导入。
-- 主线程可用Run()/ViewProfile(id,"front"|"side"|"nose")/ViewConsist(id)调用。
-- 默认Start测全部profile和Select事务，然后显示CR400AF完整编组。
local Catalog = require "config.TrainCatalog"
local GameConfig = require "config.GameConfig"
local RollingStock = require "train.RollingStock"
local Train = require "train.Train"
local Locomotive = require "train.Locomotive"
local Route = require "world.Route"
local Validation = {}

---@type Scene|nil
local scene_ = nil
---@type Node|nil
local cameraNode_ = nil
---@type Node|nil
local preview_ = nil
---@type Node[]
local rails_ = {}
local captureFrame_ = 0
local SHOTS = {
    { frame=120, id="CR400AF_head", view="nose", name="rolling_CR400AF_head" },
    { frame=145, id="CR400AF_middle", view="side", name="rolling_CR400AF_middle" },
    { frame=170, id="CRH380A_head", view="nose", name="rolling_CRH380A_head" },
    { frame=195, id="CRH380A_middle", view="side", name="rolling_CRH380A_middle" },
    { frame=220, id="CR400AF", view="consist", name="rolling_CR400AF_consist" },
    { frame=245, id="DF4D", view="nose", name="rolling_DF4D" },
    { frame=270, id="SS9G", view="nose", name="rolling_SS9G" },
    { frame=295, id="HXD3D", view="nose", name="rolling_HXD3D" },
}

local function expectNear(actual, expected, tolerance, label)
    assert(math.abs(actual - expected) <= tolerance,
        string.format("%s actual %.6f expected %.6f tolerance %.6f", label, actual, expected, tolerance))
end

local function ensureScene()
    if scene_ then return end
    scene_ = Scene()
    scene_:CreateComponent("Octree")
    local zone = scene_:CreateComponent("Zone")
    zone.boundingBox = BoundingBox(Vector3(-1000,-1000,-1000), Vector3(1000,1000,1000))
    zone.ambientSource = AMBIENT_COLOR
    zone.ambientColor = Color(.42,.42,.44)
    zone.fogColor = Color(.18,.21,.25)
    zone.fogStart, zone.fogEnd = 700, 800
    zone.tonemapMode = TONEMAP_MODE_ACES
    local sunNode = scene_:CreateChild("ProbeSun")
    sunNode.direction = Vector3(.35,-.8,.45)
    local sun = sunNode:CreateComponent("Light")
    sun.lightType = LIGHT_DIRECTIONAL
    sun.color, sun.brightness = Color(1,.96,.90), 1.1
    cameraNode_ = scene_:CreateChild("ProbeCamera")
    local camera = cameraNode_:CreateComponent("Camera")
    camera.farClip, camera.nearClip, camera.fov = 800, .1, 45
    renderer:SetViewport(0, Viewport:new(scene_, camera))
    renderer.hdrRendering = true
    -- 仅铺两根轨头，便于看踏面；无环境模型和整world开销。
    local steel = Material:new()
    steel:SetTechnique(0, assert(cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml")))
    steel:SetShaderParameter("MatDiffColor", Variant(Color(.5,.5,.52)))
    for _, side in ipairs({-1,1}) do
        local rail = scene_:CreateChild("ProbeRail")
        rails_[#rails_ + 1] = rail
        rail.position = Vector3(side*GameConfig.RailGauge*.5, Catalog.RailTop-.04, -105)
        rail.scale = Vector3(.09,.08,280)
        local model = rail:CreateComponent("StaticModel")
        model.model = assert(cache:GetResource("Model", "Models/Box.mdl"))
        model.material = steel
    end
end

---@return boolean
function Validation.Run()
    ensureScene()
    local started = os.clock()
    for id, profile in pairs(Catalog.Profiles) do
        local ok, message = RollingStock.Prepare(id)
        assert(ok, id .. " " .. message)
        local data = assert(RollingStock.GetCalibration(id))
        expectNear(data.bounds.size.x, profile.width, .025, id .. " width")
        expectNear(data.bounds.size.y, profile.height, .10, id .. " height")
        expectNear(data.bounds.size.z, profile.length, .01, id .. " length")
        expectNear(data.bounds.center.z, 0, .001, id .. " centeredZ")
        expectNear(math.abs(data.contactRight.x - data.contactLeft.x), GameConfig.RailGauge, .001, id .. " gauge")
        expectNear(data.contactLeft.y, Catalog.RailTop, .001, id .. " leftTread")
        expectNear(data.contactRight.y, Catalog.RailTop, .001, id .. " rightTread")
        assert(data.model:GetNumGeometryLodLevels(0) >= 1)
        assert(cache:Exists(data.diffusePath) and cache:Exists(data.normalPath))
        print("[RollingStockValidation] profile PASS " .. id)
    end
    Route.Build()
    Train.Build(assert(scene_))
    Train.Reset(450)
    local root = assert(Train.GetRoot())
    local audioSentinel = root:CreateChild("AudioReferenceSentinel")
    local preservedS = Train.GetS()
    local original = Train.GetSelectedId()
    for _, item in ipairs(Train.GetCatalog()) do
        assert(item.ready, item.id .. "未ready")
        local ok, message = Train.Select(item.id)
        assert(ok, message)
        assert(Train.GetRoot() == root and audioSentinel.parent == root, "Select悬空了Train根引用")
        expectNear(Train.GetS(), preservedS, .000001, "Select preserves S")
        assert(Train.GetSpeedMs() == 0 and Train.GetThrottle() == 0 and Train.GetBrake() == 1)
        assert(Train.GetCarCount() == 8 and Train.GetActiveLength() < 310)
        local cars = Train.GetCars()
        if item.kind == "emu" then
            assert(cars[1].profile ~= cars[2].profile)
            assert(cars[8].profile == cars[1].profile and cars[8].reverse)
            for i = 2, 7 do assert(cars[i].profile == cars[2].profile) end
        end
        for i = 2, #cars do assert(cars[i].offset < cars[i-1].offset) end
        print(string.format("[RollingStockValidation] Select PASS %s length %.3f", item.id, Train.GetActiveLength()))
    end
    local selected = Train.GetSelectedId()
    local bad = Train.Select("not_a_train")
    assert(not bad and Train.GetSelectedId() == selected)
    Train.SetBrake(0)
    Train.SetThrottle(8)
    Train.Update(.5)
    assert(math.abs(Train.GetSpeedMs()) > .1)
    local movingSelect = Train.Select("blue_white")
    assert(not movingSelect and Train.GetSelectedId() == selected, "允许了移动换车")
    Train.EmergencyBrake()
    for _ = 1, 100 do Train.Update(.1) end
    assert(Train.Select(original))
    -- 司机视角换车不重置隐藏状态：只隐藏新首车壳，不禁用中间或尾车。
    Locomotive.SetCabView(true)
    for _, id in ipairs({"CR400AF", "DF4D", "CRH380A"}) do
        assert(Train.Select(id))
        local lead = assert(Train.GetLeadNode())
        local leadDrawable = assert(lead:GetComponent("StaticModel", true))
        assert(not leadDrawable.enabled, "司机换车后新车壳遮住视野")
        local cars = Train.GetCars()
        for i = 2, #cars do
            for _, drawable in ipairs(cars[i].node:GetComponents("StaticModel", true)) do
                assert(drawable.enabled, "司机视角隐藏了中间或尾车")
            end
        end
    end
    Locomotive.SetCabView(false)
    local visibleLead = assert(Train.GetLeadNode()):GetComponent("StaticModel", true)
    assert(visibleLead and visibleLead.enabled, "第三人称未恢复新首车壳")
    assert(Train.Select(original))
    print("[RollingStockValidation] Cab selection visibility PASS")
    print(string.format("[RollingStockValidation] ALL PASS %.2fs", os.clock()-started))
    return true
end

---@param id string
---@param view? string
function Validation.ViewProfile(id, view)
    ensureScene()
    if preview_ then preview_:Remove() end
    local trainRoot = Train.GetRoot()
    if trainRoot then
        trainRoot:SetEnabledRecursive(false)
        for _, drawable in ipairs(trainRoot:GetComponents("StaticModel", true)) do
            assert(not drawable.node.enabled, "预览隔离失败，列车子网格仍启用")
        end
    end
    for i, rail in ipairs(rails_) do
        rail.position = Vector3((i == 1 and -1 or 1)*GameConfig.RailGauge*.5, Catalog.RailTop-.04, 0)
        rail.rotation = Quaternion()
        rail.scale = Vector3(.09,.08,65)
    end
    preview_ = assert(scene_):CreateChild("ProfilePreview")
    RollingStock.Build(preview_, id)
    local profile = assert(Catalog.Profiles[id])
    local target = Vector3(0, profile.height*.45, 0)
    local camera = assert(cameraNode_)
    if view == "front" then
        camera.position = Vector3(0, profile.height*.4, profile.length*.5+12)
    elseif view == "nose" then
        target = Vector3(0, profile.height*.5, profile.length*.28)
        camera.position = Vector3(profile.width*2, profile.height*.8, profile.length*.5+11)
    else
        camera.position = Vector3(profile.length*1.2, profile.height*.60, 0)
    end
    camera:LookAt(target)
end

---@param id string
function Validation.ViewConsist(id)
    ensureScene()
    if preview_ then preview_:Remove(); preview_=nil end
    Route.Build()
    if Train.GetCarCount() == 0 then Train.Build(assert(scene_)) end
    local root = assert(Train.GetRoot())
    root:SetEnabledRecursive(true)
    Train.EmergencyBrake()
    Train.Reset(450)
    assert(Train.Select(id))
    root:SetEnabledRecursive(true)
    local length = Train.GetActiveLength()
    local lead = Train.GetLeadPosition()
    local rotation = Train.GetLeadRotation()
    local target = lead + rotation * Vector3(0,2,-length*.45)
    for i, rail in ipairs(rails_) do
        rail.position = lead + rotation * Vector3((i == 1 and -1 or 1)*GameConfig.RailGauge*.5,
            Catalog.RailTop-.04, -length*.45)
        rail.rotation = rotation
        rail.scale = Vector3(.09,.08,length+50)
    end
    local camera = assert(cameraNode_)
    camera.position = target + rotation * Vector3(length*.70,65,length*.07)
    camera:LookAt(target)
end

function Start()
    Validation.Run()
    Validation.ViewConsist("CR400AF")
    captureFrame_ = 0
    SubscribeToEvent("Update", "HandleRollingStockProbeUpdate")
    SubscribeToEvent("EndRendering", "HandleRollingStockProbeCapture")
end

---@param eventType string
---@param eventData UpdateEventData
function HandleRollingStockProbeUpdate(eventType, eventData)
    captureFrame_ = captureFrame_ + 1
    for _, shot in ipairs(SHOTS) do
        if captureFrame_ == shot.frame - 15 then
            if shot.view == "consist" then Validation.ViewConsist(shot.id)
            else Validation.ViewProfile(shot.id, shot.view) end
        end
    end
end

---@param eventType string
---@param eventData EndRenderingEventData
function HandleRollingStockProbeCapture(eventType, eventData)
    for _, shot in ipairs(SHOTS) do
        if captureFrame_ == shot.frame then
            local image = Image()
            assert(graphics:TakeScreenShot(image), "车型实际帧截图失败")
            assert(image:SavePNG("/workspace/screenshots/" .. shot.name .. ".png"), "车型截图未落盘")
            image:Dispose()
            print("[RollingStockValidation] Screenshot " .. shot.name)
        end
    end
end

function Stop()
    UnsubscribeFromEvent("Update")
    UnsubscribeFromEvent("EndRendering")
    if scene_ then scene_:Dispose(); scene_=nil end
    cameraNode_, preview_ = nil, nil
end

return Validation
