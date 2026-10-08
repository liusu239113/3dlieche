-- ============================================================================
-- AudioManager - 音效与车站广播
-- 汽笛 / 制动 / 站台环境音 / 到发车广播
-- 不播放持续行驶音：循环牵引/轮轨声体验差且各车型无法区分，已移除。
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
---@type SoundSource|nil
local hornSource_ = nil
---@type SoundSource|nil
local brakeSource_ = nil
---@type SoundSource|nil
local ambienceSource_ = nil
---@type SoundSource|nil
local announcerSource_ = nil

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

    -- 不创建牵引/轮轨 3D 循环声源；行驶中只有玩家主动触发的汽笛与制动。
    powerType_ = powerType == "diesel" and "diesel" or "electric"

    hornSource_ = node:CreateChild("Horn"):CreateComponent("SoundSource")
    brakeSource_ = node:CreateChild("Brake"):CreateComponent("SoundSource")
    ambienceSource_ = node:CreateChild("Ambience"):CreateComponent("SoundSource")
    announcerSource_ = node:CreateChild("Announcer"):CreateComponent("SoundSource")

    -- 站台环境音（靠近车站时淡入）
    local amb = load(SFX .. "station_ambience.mp3")
    if amb and ambienceSource_ then
        amb:SetLooped(true)
        ambienceSource_:Play(amb, amb:GetFrequency(), 0.0)
        ambienceOn_ = true
    end

    print("[Audio] 音频系统就绪（无持续行驶音）")
end

---@param powerType string
function AudioManager.SetPowerType(powerType)
    -- 保留动力类型供汽笛等音效区分；不再切换持续牵引循环声。
    powerType_ = powerType == "diesel" and "diesel" or "electric"
end

---@param position Vector3
---@param rotation Quaternion
function AudioManager.SetTrainPose(position, rotation)
    -- 无 3D 行驶声源后无需跟随列车姿态。
end

---@param suspended boolean
function AudioManager.SetSuspended(suspended)
    suspended_ = suspended
    if suspended and ambienceSource_ then ambienceSource_:SetGain(0) end
end

function AudioManager.GetPowerType() return powerType_ end

-- ---------------------------------------------------------------------------
-- 每帧更新
-- ---------------------------------------------------------------------------

---@param dt number
---@param speedKmh number
---@param throttle number
---@param stationDistance number 距最近车站的距离（米）
function AudioManager.Update(dt, speedKmh, throttle, stationDistance)
    -- 无持续行驶音；只更新站台环境音的距离淡入。
    if ambienceOn_ and ambienceSource_ then
        local target = 0.0
        if stationDistance and stationDistance < 260.0 then
            target = 0.42 * (1.0 - stationDistance / 260.0)
        end
        local cur = ambienceSource_:GetGain()
        local next_ = cur + (target - cur) * math.min(1.0, dt * 1.6)
        ambienceSource_:SetGain(suspended_ and 0 or next_)
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
    if hornSource_ then hornSource_:StopImmediate() end
    if brakeSource_ then brakeSource_:StopImmediate() end
    if ambienceSource_ then ambienceSource_:StopImmediate() end
    if announcerSource_ then announcerSource_:StopImmediate() end
    if _audioNode then _audioNode:Dispose() end
    hornSource_, brakeSource_, ambienceSource_, announcerSource_ = nil, nil, nil, nil
    _audioNode = nil
    ambienceOn_ = false
end

return AudioManager
