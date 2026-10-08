-- ============================================================================
-- 火车驾驶模拟 - 主入口
-- 中式客运线路：5 座车站、蓝白长机罩内燃机车 + 客车编组、驾驶仪表
-- ============================================================================

local GameConfig = require "config.GameConfig"
local Materials = require "config.Materials"
local Route = require "world.Route"
local Track = require "world.Track"
local Station = require "world.Station"
local Terrain = require "world.Terrain"
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

-- ============================================================================
-- 生命周期
-- ============================================================================

function Start()
    print("========================================")
    print("[Main] " .. GameConfig.Title .. " 启动")
    print("========================================")

    local t0 = os.clock()

    scene_ = Scene()
    scene_:CreateComponent("Octree")
    scene_:CreateComponent("DebugRenderer")

    CreateLighting()
    Route.Build()
    Track.Build(scene_)
    Station.Build(scene_)
    Terrain.Build(scene_)
    Train.Build(scene_)
    -- 首次展示在北京站入口的直线段，避免旧起点被外围建筑遮挡。
    local firstStation = Route.GetStations()[1]
    if firstStation then Train.Reset(firstStation.s - 55.0) end
    Camera.Build(scene_)

    AudioManager.Init(scene_, scene_:GetChild("Train"))
    Hud.Init({
        onThrottleUp = function() Game.ThrottleUp() end,
        onThrottleDown = function() Game.ThrottleDown() end,
        onBrake = function() Game.Brake(0.25) end,
        onBrakeHold = function(held) touchBrakeHeld_ = held end,
        onBrakeRelease = function() touchBrakeHeld_ = false end,
        onReleaseBrake = function()
            if not Game.IsDwelling() then Train.SetBrake(0) end
        end,
        onReverse = function()
            local reversing = Train.ToggleReversing()
            Hud.SetReversing(reversing)
            Hud.Toast(reversing and "换向：后退" or "换向：前进", 1.5)
        end,
        onSwitch = function(dir) Game.SetSwitch(dir) end,
        onHorn = function() Game.Horn() end,
        onCamera = function() Camera.CycleMode() end,
        onPause = function() TogglePause() end,
    })

    Game.Init()
    Game.UpdateHud(0)

    SubscribeToEvent("Update", "HandleUpdate")
    SubscribeToEvent("PostUpdate", "HandlePostUpdate")

    print(string.format("[Main] 世界构建总耗时 %.2f 秒", os.clock() - t0))
end

function Stop()
    AudioManager.Shutdown()
    Hud.Shutdown()
end

-- ============================================================================
-- 光照
-- ============================================================================

-- 自建平色环境光与雾色背景，不依赖远端环境全景资源。
-- 如后续启用预设IBL，应直接替换本组Zone/太阳，避免叠加两个Zone。
function CreateLighting()
    local zoneNode = scene_:CreateChild("Zone")
    local zone = zoneNode:CreateComponent("Zone")
    zone.boundingBox = BoundingBox(Vector3(-3000, -3000, -3000), Vector3(3000, 3000, 3000))
    zone.ambientSource = AMBIENT_COLOR
    zone.ambientColor = Color(0.32, 0.35, 0.39)
    -- 背景 = 雾色，形成天空
    zone.fogColor = Color(0.58, 0.72, 0.88)
    zone.fogStart = 300.0
    zone.fogEnd = 1600.0

    -- 太阳（方向光）
    local sunNode = scene_:CreateChild("Sun")
    sunNode.direction = Vector3(0.45, -1.0, 0.55)
    local sun = sunNode:CreateComponent("Light")
    sun.lightType = LIGHT_DIRECTIONAL
    sun.color = Color(1.0, 0.97, 0.90)
    sun.brightness = 2.0
    sun.castShadows = true
    sun.shadowBias = BiasParameters(0.00025, 0.5)
    sun.shadowCascade = CascadeParameters(20.0, 80.0, 320.0, 0.0, 0.85)

    print("[Main] 光照与雾色天空就绪")
end

-- ============================================================================
-- 暂停
-- ============================================================================

function TogglePause()
    paused_ = not paused_
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

    if not paused_ then
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

    Train.UpdateVisuals(paused_ and 0 or dt)
    Camera.Update(dt, Train.GetS())
end

-- ============================================================================
-- 键盘
-- ============================================================================

---@param dt number
function HandleKeyboard(dt)
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
