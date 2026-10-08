-- ============================================================================
-- 火车驾驶模拟 - 主入口
-- 中式客运线路：5 座车站、多种中国机车与8节动车组、驾驶仪表
-- ============================================================================

local GameConfig = require "config.GameConfig"
local Route = require "world.Route"
local WorldStream = require "world.WorldStream"
local SkyUtils = require "urhox-libs.Rendering.SkyUtils"
local Train = require "train.Train"
local Camera = require "train.Camera"
local Hud = require "ui.Hud"
local AudioManager = require "audio.AudioManager"
local Game = require "game.Game"

---@type Scene|nil
local scene_ = nil
local paused_ = false
local brakeHeld_ = false
local touchBrakeHeld_ = false
local selectorOpen_ = false

-- 菜单暂停和用户暂停独立；关菜单不能把原本已暂停的游戏自动恢复。
local function IsPaused() return paused_ or selectorOpen_ end

local function SyncPause()
    local paused = IsPaused()
    Hud.SetPaused(paused)
    AudioManager.SetSuspended(paused)
    if paused then brakeHeld_, touchBrakeHeld_ = false, false end
end

---@param id string
---@return boolean, string
function SelectTrain(id)
    if math.abs(Train.GetSpeedKmh()) > 0.1 then
        return false, "请先停稳后再换车"
    end
    local ok, message = Train.Select(id)
    if not ok then return false, message end
    brakeHeld_, touchBrakeHeld_ = false, false
    Hud.SetSelectedTrain(Train.GetSelectedId(), Train.GetSelectedName())
    AudioManager.SetPowerType(Train.GetPowerType())
    local lead = Train.GetLeadNode()
    if lead then AudioManager.SetTrainPose(lead.worldPosition, lead.worldRotation) end
    Game.UpdateHud(0)
    print("[Main] 换车完成，保留站序/经验/线路位置: " .. Train.GetSelectedName())
    return true, message
end

-- ============================================================================
-- 生命周期
-- ============================================================================

function Start()
    print("========================================")
    print("[Main] " .. GameConfig.Title .. " 启动")
    print("========================================")

    local t0 = os.clock()
    paused_, selectorOpen_ = false, false
    brakeHeld_, touchBrakeHeld_ = false, false

    scene_ = Scene()
    scene_:CreateComponent("Octree")
    scene_:CreateComponent("DebugRenderer")

    Route.Build()
    CreateLighting()
    -- 从首站驶出后的直线区间开始，可直接体验牵引而不是先在55米内停车。
    local firstStation = Route.GetStations()[1]
    local initialS = firstStation and firstStation.s + 600 or 600
    WorldStream.Build(scene_, initialS)
    Train.Build(scene_)
    Train.Reset(initialS)
    Camera.Build(scene_)
    local cameraNode = assert(Camera.GetNode())
    local listener = cameraNode:CreateComponent("SoundListener")
    audio:SetListener(listener)

    AudioManager.Init(scene_, scene_:GetChild("Train"), Train.GetPowerType())
    Hud.Init({
        onThrottleUp = function() if not selectorOpen_ then Game.ThrottleUp() end end,
        onThrottleDown = function() if not selectorOpen_ then Game.ThrottleDown() end end,
        onBrake = function() if not selectorOpen_ then Game.Brake(0.25) end end,
        onBrakeHold = function(held) touchBrakeHeld_ = held and not selectorOpen_ end,
        onBrakeRelease = function() touchBrakeHeld_ = false end,
        onReleaseBrake = function()
            if not selectorOpen_ and not Game.IsDwelling() then Train.SetBrake(0) end
        end,
        onReverse = function()
            if selectorOpen_ then return end
            local reversing = Train.ToggleReversing()
            Hud.SetReversing(reversing)
            Hud.Toast(reversing and "换向：后退" or "换向：前进", 1.5)
        end,
        onSwitch = function(dir) if not selectorOpen_ then Game.SetSwitch(dir) end end,
        onHorn = function() if not selectorOpen_ then Game.Horn() end end,
        onCamera = function() if not selectorOpen_ then Camera.CycleMode() end end,
        onPause = function() TogglePause() end,
        onSelectTrain = SelectTrain,
        onOpenTrainSelector = function(open)
            selectorOpen_ = open
            SyncPause()
            print("[Main] 车型选择器 " .. (open and "打开" or "关闭"))
        end,
    })
    local catalog = Train.GetCatalog() --[[@as CabTrainCatalogEntry[] ]]
    Hud.SetTrainCatalog(catalog, Train.GetSelectedId())
    Hud.SetSelectedTrain(Train.GetSelectedId(), Train.GetSelectedName())
    SyncPause()

    Game.Init()
    Game.UpdateHud(0)

    SubscribeToEvent("Update", "HandleUpdate")
    SubscribeToEvent("PostUpdate", "HandlePostUpdate")

    print(string.format("[Main] 世界构建总耗时 %.2f 秒", os.clock() - t0))
end

function Stop()
    WorldStream.Shutdown()
    AudioManager.Shutdown()
    Hud.Shutdown()
end

-- ============================================================================
-- 光照
-- ============================================================================

-- 显式创建日间光照，不依赖包含编辑器专用资源的预设。
function CreateLighting()
    if not scene_ then return end
    local group = scene_:CreateChild("DayLighting")
    local zone = group:CreateComponent("Zone")
    zone.ambientSource = AMBIENT_COLOR
    zone.ambientColor = Color(0.16, 0.18, 0.21)
    -- 覆盖新大半径线路，不能沿用旧环线±5000米的Zone。
    zone.boundingBox = BoundingBox(Vector3(-60000, -1000, -60000), Vector3(60000, 2000, 60000))
    zone.fogColor = Color(0.59, 0.66, 0.71)
    zone.fogStart = 450.0
    zone.fogEnd = 1450.0
    -- 显式使用解析 ACES，避免离屏 GLES 环境的 3D LUT Shader 编译失败。
    zone.tonemapMode = TONEMAP_MODE_ACES
    zone.vignetteEnabled = false
    -- 亚像素接触线和薄雨棚边缘使用FXAA，避免移动端近景锯齿。
    zone.fxaaEnabled = true
    -- 固定日间曝光，避免移动端多一组全屏亮度直方图。
    zone.autoExposureEnabled = false
    local sunNode = group:CreateChild("Sun")
    sunNode.direction = Vector3(0.45, -1.0, 0.55)
    local sun = sunNode:CreateComponent("Light")
    sun.lightType = LIGHT_DIRECTIONAL
    if sun then
        sun.color = Color(1.0, 0.96, 0.88)
        sun.brightness = 1.15
        sun.castShadows = true
        sun.shadowBias = BiasParameters(0.00025, 0.5)
        sun.shadowCascade = CascadeParameters(20.0, 80.0, 320.0, 0.0, 0.85)
    end
    -- 程序化渐变仍由库创建；官方默认天空依赖已补齐真实XML与六面KTX资源。
    SkyUtils.CreateGradientSky(scene_, {
        zenith = Color(0.16, 0.32, 0.54),
        horizon = zone.fogColor,
        ground = Color(0.32, 0.37, 0.29),
        skyExp = 0.65,
        hdrBoost = 1.45,
    })
    print("[Main] 日间太阳光、渐变天空、低饱和远景雾与ACES已加载")
end

-- ============================================================================
-- 暂停
-- ============================================================================

function TogglePause()
    if selectorOpen_ then return end
    paused_ = not paused_
    SyncPause()
    Hud.Toast(paused_ and "已暂停" or "继续行驶", 1.5)
end

-- ============================================================================
-- 更新
-- ============================================================================

---@param eventType string
---@param eventData UpdateEventData
function HandleUpdate(eventType, eventData)
    local dt = eventData:GetFloat("TimeStep")
    if dt > 0.1 then dt = 0.1 end

    HandleKeyboard(dt)

    if not IsPaused() then
        -- 刹车按钮按住时持续制动
        if brakeHeld_ or touchBrakeHeld_ then
            Train.AddBrake(1.6 * dt)
            if Train.GetThrottle() > 0 then Train.SetThrottle(0) end
        end

        Train.Update(dt)
        Game.Update(dt)
        AudioManager.Update(dt, Train.GetSpeedKmh(), Train.GetThrottle(),
            Game.GetNearestStationDistance())
    end
end

---@param eventType string
---@param eventData PostUpdateEventData
function HandlePostUpdate(eventType, eventData)
    local dt = eventData:GetFloat("TimeStep")
    if dt > 0.1 then dt = 0.1 end

    Train.UpdateVisuals(IsPaused() and 0 or dt)
    local lead = Train.GetLeadNode()
    if lead then AudioManager.SetTrainPose(lead.worldPosition, lead.worldRotation) end
    Camera.Update(dt, Train.GetS())
    -- 选择器/用户暂停期间也补齐当前画面，但不会推进车辆和玩法。
    WorldStream.Update(Train.GetS(), dt)
end

-- ============================================================================
-- 键盘
-- ============================================================================

---@param dt number
function HandleKeyboard(dt)
    if selectorOpen_ then
        brakeHeld_, touchBrakeHeld_ = false, false
        return
    end
    -- 油门
    if input:GetKeyPress(KEY_W) then Game.ThrottleUp() end
    if input:GetKeyPress(KEY_S) then Game.ThrottleDown() end

    -- 刹车（按住）
    if input:GetKeyDown(KEY_SPACE) then
        brakeHeld_ = true
    else
        brakeHeld_ = false
    end
    if input:GetKeyPress(KEY_X) then Game.EmergencyBrake() end
    if input:GetKeyPress(KEY_B) and not Game.IsDwelling() then Train.SetBrake(0) end

    -- 汽笛
    if input:GetKeyPress(KEY_H) then Game.Horn() end

    -- 换向
    if input:GetKeyPress(KEY_R) then
        local rev = Train.ToggleReversing()
        Hud.Toast(rev and "换向：后退" or "换向：前进", 1.5)
    end

    -- 道岔
    if input:GetKeyPress(KEY_Q) then Game.SetSwitch(-1) end
    if input:GetKeyPress(KEY_E) then Game.SetSwitch(1) end

    -- 视角
    if input:GetKeyPress(KEY_C) then Camera.CycleMode() end
    if input:GetKeyDown(KEY_A) then Camera.AddYaw(-110 * dt) end
    if input:GetKeyDown(KEY_D) then Camera.AddYaw(110 * dt) end
    if input:GetKeyDown(KEY_UP) then Camera.AddPitch(-40 * dt) end
    if input:GetKeyDown(KEY_DOWN) then Camera.AddPitch(40 * dt) end

    -- 暂停
    if input:GetKeyPress(KEY_P) then TogglePause() end
end
