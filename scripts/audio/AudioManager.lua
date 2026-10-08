-- ============================================================================
-- AudioManager - 音效与车站广播
-- 引擎声 / 汽笛 / 制动 / 轮轨声 / 站台环境音 / 到发车广播
-- 资源缺失时静默降级，不影响游戏运行
-- ============================================================================

local AudioManager = {}

local SFX = "audio/sfx/"
local VOICE = "audio/voice/"
local VOICE_SUFFIX = "_aca51c5d8ff454f4.ogg"

local _sounds = {}
local _missing = {}

-- 2D 声源挂在独立节点上；必须由模块级变量持有，否则会被 GC 回收
---@type Node|nil
local _audioNode = nil

-- 声源
---@type SoundSource3D|nil
local engineSource_ = nil
---@type SoundSource3D|nil
local clackSource_ = nil
---@type SoundSource|nil
local hornSource_ = nil
---@type SoundSource|nil
local brakeSource_ = nil
---@type SoundSource|nil
local ambienceSource_ = nil
---@type SoundSource|nil
local announcerSource_ = nil

---@type Sound|nil
local tractionSound_ = nil
---@type Node|nil
local engineNode_ = nil
---@type Node|nil
local clackNode_ = nil
local powerType_ = "diesel"
local suspended_ = false
local ambienceOn_ = false

-- ---------------------------------------------------------------------------
-- 资源加载
-- ---------------------------------------------------------------------------
---@param path string
---@return Sound|nil
local function load(path)
    if _missing[path] then return nil end
    local s = _sounds[path]
    if s then return s end
    s = cache:GetResource("Sound", path)
    if s then
        _sounds[path] = s
    else
        _missing[path] = true
        print("[Audio] 缺少音频: " .. path)
    end
    return s
end

-- ---------------------------------------------------------------------------
-- 初始化
-- ---------------------------------------------------------------------------

---@param scene Scene
---@param trainRoot Node
---@param powerType? string
function AudioManager.Init(scene, trainRoot, powerType)
    AudioManager.Shutdown()
    suspended_ = false
    _audioNode = Node()
    local node = _audioNode

    -- 列车根节点保持不动；每帧将两个声源更新到真实头车姿态。
    if trainRoot then
        engineNode_ = trainRoot:CreateChild("EngineAudio")
        engineSource_ = engineNode_:CreateComponent("SoundSource3D")
        engineSource_.nearDistance = 5.0
        engineSource_.farDistance = 260.0
        engineSource_.rolloffFactor = 1.4

        clackNode_ = trainRoot:CreateChild("ClackAudio")
        clackSource_ = clackNode_:CreateComponent("SoundSource3D")
        clackSource_.nearDistance = 4.0
        clackSource_.farDistance = 120.0
        clackSource_.rolloffFactor = 1.8
    end

    hornSource_ = node:CreateChild("Horn"):CreateComponent("SoundSource")
    brakeSource_ = node:CreateChild("Brake"):CreateComponent("SoundSource")
    ambienceSource_ = node:CreateChild("Ambience"):CreateComponent("SoundSource")
    announcerSource_ = node:CreateChild("Announcer"):CreateComponent("SoundSource")

    AudioManager.SetPowerType(powerType or "diesel")

    -- 轮轨声循环（音量随速度调制）
    local clack = load(SFX .. "rail_clack.mp3")
    if clack and clackSource_ then
        clack:SetLooped(true)
        clackSource_:Play(clack, clack:GetFrequency(), 0.0)
    end

    -- 站台环境音（靠近车站时淡入）
    local amb = load(SFX .. "station_ambience.mp3")
    if amb and ambienceSource_ then
        amb:SetLooped(true)
        ambienceSource_:Play(amb, amb:GetFrequency(), 0.0)
        ambienceOn_ = true
    end

    print("[Audio] 音频系统就绪")
end

---@param powerType string
function AudioManager.SetPowerType(powerType)
    powerType_ = powerType == "diesel" and "diesel" or "electric"
    if engineSource_ then engineSource_:StopImmediate() end
    local path = powerType_ == "diesel" and SFX .. "engine_idle_loop.mp3"
        or SFX .. "electric_traction_loop.mp3"
    tractionSound_ = load(path)
    if tractionSound_ and engineSource_ then
        tractionSound_:SetLooped(true)
        engineSource_:Play(tractionSound_, tractionSound_:GetFrequency(), 0.0)
    end
    print("[Audio] 牵引动力声切换: " .. powerType_)
end

---@param position Vector3
---@param rotation Quaternion
function AudioManager.SetTrainPose(position, rotation)
    if engineNode_ then
        engineNode_.worldPosition = position + rotation * Vector3(0, 1.4, -2.5)
        engineNode_.worldRotation = rotation
    end
    if clackNode_ then
        clackNode_.worldPosition = position + rotation * Vector3(0, 0.6, 0)
        clackNode_.worldRotation = rotation
    end
end

---@param suspended boolean
function AudioManager.SetSuspended(suspended)
    suspended_ = suspended
    if suspended then
        if engineSource_ then engineSource_:SetGain(0) end
        if clackSource_ then clackSource_:SetGain(0) end
    end
end

function AudioManager.GetPowerType() return powerType_ end
function AudioManager.GetTractionSource() return engineSource_ end

-- ---------------------------------------------------------------------------
-- 每帧更新
-- ---------------------------------------------------------------------------

---@param dt number
---@param speedKmh number
---@param throttle number
---@param stationDistance number 距最近车站的距离（米）
function AudioManager.Update(dt, speedKmh, throttle, stationDistance)
    local speed = math.abs(speedKmh)

    -- 只更新频率/增益，不每帧 Play 重启循环；电力车没有柴油怠速。
    if tractionSound_ and engineSource_ then
        local speedFactor = math.min(1.0, speed / 110.0)
        local throttleFactor = math.max(0, math.min(1, throttle / 8.0))
        local pitch, gain
        if powerType_ == "diesel" then
            pitch = 0.70 + speedFactor * 0.50 + throttleFactor * 0.45
            gain = 0.28 + throttleFactor * 0.42 + speedFactor * 0.18
        else
            pitch = 0.65 + speedFactor * 0.65 + throttleFactor * 0.25
            gain = speedFactor * 0.14 + throttleFactor * 0.36
        end
        engineSource_:SetFrequency(tractionSound_:GetFrequency() * pitch)
        engineSource_:SetGain(suspended_ and 0 or gain)
    end

    -- 轮轨声：速度越快越响
    if clackSource_ then
        local clack = _sounds[SFX .. "rail_clack.mp3"]
        if clack then
            local gain = 0.0
            if speed > 3.0 then
                gain = math.min(0.55, (speed / 90.0) * 0.55)
            end
            clackSource_:SetGain(suspended_ and 0 or gain)
        end
    end

    -- 站台环境音：进入 260 米内淡入
    if ambienceOn_ and ambienceSource_ then
        local target = 0.0
        if stationDistance and stationDistance < 260.0 then
            target = 0.42 * (1.0 - stationDistance / 260.0)
        end
        local cur = ambienceSource_:GetGain()
        local next_ = cur + (target - cur) * math.min(1.0, dt * 1.6)
        ambienceSource_:SetGain(next_)
    end
end

-- ---------------------------------------------------------------------------
-- 一次性音效
-- ---------------------------------------------------------------------------

function AudioManager.PlayHorn()
    local snd = load(SFX .. "train_horn.mp3")
    if snd and hornSource_ then
        hornSource_:Play(snd, 0, 0.9)
        return true
    end
    return false
end

---@param intensity number
function AudioManager.PlayBrake(intensity)
    local snd = load(SFX .. "brake_squeal.mp3")
    if snd and brakeSource_ then
        brakeSource_:Play(snd, snd:GetFrequency() * (1.0 - intensity * 0.12), 0.5)
        return true
    end
    return false
end

--- 到站广播
---@param stationIndex integer
function AudioManager.AnnounceArrival(stationIndex)
    return AudioManager.PlayVoice(stationIndex)
end

--- 发车广播（目标站）
---@param stationIndex integer
function AudioManager.AnnounceDeparture(stationIndex)
    return AudioManager.PlayVoice(5 + stationIndex)
end

---@param voiceIndex integer
function AudioManager.PlayVoice(voiceIndex)
    local path = VOICE .. "station_announce_" .. voiceIndex .. VOICE_SUFFIX
    local snd = load(path)
    if snd and announcerSource_ then
        announcerSource_:Stop()
        announcerSource_:Play(snd, 0, 0.95)
        return true
    end
    return false
end

function AudioManager.Shutdown()
    if engineSource_ then engineSource_:StopImmediate() end
    if clackSource_ then clackSource_:StopImmediate() end
    if hornSource_ then hornSource_:StopImmediate() end
    if brakeSource_ then brakeSource_:StopImmediate() end
    if ambienceSource_ then ambienceSource_:StopImmediate() end
    if announcerSource_ then announcerSource_:StopImmediate() end
    if engineNode_ then engineNode_:Remove(); engineNode_:Dispose() end
    if clackNode_ then clackNode_:Remove(); clackNode_:Dispose() end
    if _audioNode then _audioNode:Dispose() end
    engineSource_, clackSource_ = nil, nil
    hornSource_, brakeSource_, ambienceSource_, announcerSource_ = nil, nil, nil, nil
    engineNode_, clackNode_, _audioNode = nil, nil, nil
    tractionSound_ = nil
    ambienceOn_ = false
end

return AudioManager
