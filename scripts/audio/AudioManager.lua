-- 生成的长运行循环：固定音高，温和响度，初始化和换车淡入。
-- 怠速、运行与环境使用持久声源；缺失时静默，不回退已停用的合成声。
-- 源、WAV buffer 与自建 Sound 强持有；暂停和用户静音独立。
local Profiles = require "audio.AudioProfiles"
local AudioCache = require "audio.AudioCache"
local AudioManager = {}

local LOOP_TYPE = "FantasyRail.Loops"
local CUE_TYPE = "FantasyRail.Cues"
local TRAIN_LAYERS = { "idle", "running" }
local ENVIRONMENTS = { "city", "forest", "river", "tunnel" }
local ENVIRONMENT_FILES = {
    city = "audio/sfx/comfort/ambience_city_loop.wav",
    forest = "audio/sfx/comfort/ambience_forest_loop.wav",
    river = "audio/sfx/comfort/ambience_river_loop.wav",
    tunnel = "audio/sfx/comfort/ambience_tunnel_loop.wav",
}
local ENVIRONMENT_DETAIL_GAINS = { city = .48, forest = .65, river = .36, tunnel = .40 }
local ENVIRONMENT_BED_GAINS = { city = .09, forest = .08, river = .12, tunnel = .10 }

---@class FantasyLoopSource
---@field id string
---@field trainId string
---@field layer string
---@field node Node
---@field source SoundSource
---@field clip ProceduralSound
---@field gain number
---@field pitch number
---@field playCalls integer
---@field restarts integer
---@field generatedEnvironment? boolean
---@field resourcePath? string

---@class FantasyTrainBank
---@field id string
---@field profile FantasyAudioProfile
---@field loops FantasyLoopSource[]
---@field mix number
---@field retiring boolean

---@class FantasyLoopDiagnostic
---@field id string
---@field trainId string
---@field layer string
---@field playing boolean
---@field gain number
---@field frequency number
---@field pitch number
---@field sampleRate number
---@field soundId string
---@field looped boolean
---@field timePosition number
---@field rms number
---@field peak number
---@field seamDelta number
---@field loopBoundaryDelta number
---@field periodicClosureDelta number
---@field samples integer
---@field duration number
---@field RMS number
---@field generationSeconds number
---@field maxAdjacentDelta number
---@field playCalls integer
---@field restarts integer
---@field bankMix number
---@field generatedEnvironment boolean
---@field resourcePath string
---@field bakedPCM boolean
---@field cacheLoadSeconds number

---@type Node|nil
local audioNode_ = nil
---@type Scene|nil
local scene_ = nil
---@type FantasyTrainBank[]
local banks_ = {}
---@type FantasyLoopSource[]
local environments_ = {}
---@type table<string, ProceduralSound>
local ownedClips_ = {}
---@type table<string, Sound>
local cachedHorns_ = {}
---@type table<string, boolean>
local missing_ = {}
---@type SoundSource|nil
local hornSource_ = nil
---@type SoundSource|nil
local brakeSource_ = nil
---@type SoundSource|nil
local announcerSource_ = nil
local profile_ = Profiles.Default("diesel")
local environment_ = "city"
local suspended_ = false
local volume_ = .55
local enabled_ = true -- 新生成声以低响度素材和保守主音量淡入
local smoothedSpeed_ = 0.0
local smoothedThrottle_ = 0.0
local stationDistance_ = math.huge
local elapsed_ = 0.0
local monitorTimer_ = 0.0
local hornCooldown_ = 0.0
local brakeCooldown_ = 0.0
local hornGain_,brakeGain_ = 0.0,0.0
local sourceSerial_ = 0
local announcementId_ = ""
local announcementKind_ = ""
local failedClips_ = {} ---@type table<string, boolean>
local requests_ = {} ---@type table<string, boolean>
local generation_ = 0
local trainPosition_ = Vector3(0, 0, 0)
local trainRotation_ = Quaternion.IDENTITY

---@param value number
---@param low number
---@param high number
---@return number
local function clamp(value, low, high)
    return math.max(low, math.min(high, value))
end

---@param value number
---@param target number
---@param dt number
---@param response number
---@return number
local function smooth(value, target, dt, response)
    return value + (target - value) * (1 - math.exp(-dt * response))
end

---@param key string
---@param create fun():ProceduralSound|nil
---@return ProceduralSound|nil
local function ownedClip(key, create)
    if ownedClips_[key] then return ownedClips_[key] end
    -- 未下载不等于损坏；每个请求完成后解锁，下一次操作可以重试。
    if requests_[key] then return nil end
    local clip = AudioCache.Load(key)
    if clip then
        ownedClips_[key],failedClips_[key] = clip,nil
        return clip
    end
    requests_[key] = true
    local generation = generation_
    AudioCache.Request(key,function(ready)
        if generation ~= generation_ then return end
        requests_[key] = nil
        if ready then
            local loaded = AudioCache.Load(key)
            if loaded then ownedClips_[key],failedClips_[key]=loaded,nil
            else failedClips_[key]=true end
        else failedClips_[key]=true end
    end)
    return ownedClips_[key]
end

---@param profile FantasyAudioProfile
---@param kind string
---@return ProceduralSound|nil
local function cueClip(profile, kind)
    if kind == "brake" then
        local path = "audio/sfx/comfort/comfort_brake_air.wav"
        return ownedClip(path, function() return nil end)
    end
    return nil -- 不再播放旧尖锐提示音、制动音或程序气笛
end

---@param name string
---@param soundType string
---@return SoundSource|nil
local function createSource(name, soundType)
    if not audioNode_ then return nil end
    local source = audioNode_:CreateChild(name):CreateComponent("SoundSource")
    source:SetSoundType(soundType)
    source:SetDeclickEnabled(true)
    return source
end

---@param layer string
---@param trainId string
---@param clip ProceduralSound
---@param initialGain number
---@param panning number
---@return FantasyLoopSource|nil
local function createLoop(layer, trainId, clip, initialGain, panning)
    if not audioNode_ then return nil end
    sourceSerial_ = sourceSerial_ + 1
    local id = trainId .. ":" .. layer .. ":" .. sourceSerial_
    local node = audioNode_:CreateChild(id)
    local source = node:CreateComponent("SoundSource")
    source:SetSoundType(LOOP_TYPE)
    source:SetDeclickEnabled(true)
    source:Play(clip.sound, clip.sound:GetFrequency(), (suspended_ or not enabled_) and 0 or initialGain, panning)
    return {
        id = id, trainId = trainId, layer = layer, node = node, source = source,
        clip = clip, gain = initialGain, pitch = 1, playCalls = 1, restarts = 0,
        resourcePath = clip.resourcePath or "",
    }
end

---@param bank FantasyTrainBank
local function disposeBank(bank)
    for _, entry in ipairs(bank.loops) do
        entry.source:StopImmediate()
        entry.node:Dispose()
    end
    bank.loops = {}
end

-- 声源只在 Init/SetTrainId 创建；换车通过既有声源交叉淡入。
-- 已生成 PCM 在 Shutdown 前保留，快速重选不会重复合成或提前释放仍播放的声音。
---@param kind string
---@param first boolean
local function ensureEnvironment(kind, first)
    for _, entry in ipairs(environments_) do if entry.layer == kind .. "_detail" then return end end
    local path = ENVIRONMENT_FILES[kind]
    if not path or failedClips_[path] then return end
    local clip = ownedClip(path, function() return nil end)
    if clip then
        local entry = createLoop(kind .. "_detail", "environment", clip, 0, 0)
        if entry then
            entry.generatedEnvironment,entry.resourcePath = true,path
            environments_[#environments_+1] = entry
        end
    end
end

---@param profile FantasyAudioProfile
---@param first boolean
local function selectProfile(profile, first)
    -- 快速重选尚在淡出的声音档案时，也先停止旧车型一次性音效。
    if hornSource_ then hornSource_:StopImmediate() end
    if brakeSource_ then brakeSource_:StopImmediate() end
    if announcerSource_ then announcerSource_:StopImmediate() end
    announcementId_, announcementKind_ = "", ""
    hornCooldown_, brakeCooldown_ = 0, 0
    for _, bank in ipairs(banks_) do bank.retiring = true end
    for _, bank in ipairs(banks_) do
        if bank.id == profile.id then
            bank.retiring = false
            profile_ = profile
            return
        end
    end
    profile_ = profile
    if not audioNode_ then return end
    ---@type FantasyTrainBank
    local bank = { id = profile.id, profile = profile, loops = {}, mix = first and 1 or 0, retiring = false }
    for _, layer in ipairs(TRAIN_LAYERS) do
        local path = layer == "idle" and profile.idlePath or profile.runningPath
        local clip = ownedClip(path, function() return nil end)
        if clip then
            local initialGain = 0 -- 初始化和换车均从静默淡入
            local entry = createLoop(layer, profile.id, clip, initialGain, layer == "rolling" and -.08 or 0)
            if entry then bank.loops[#bank.loops + 1] = entry end
        end
    end
    banks_[#banks_ + 1] = bank
    -- 一次性音效在首次触发时加载处理好的生成WAV；不合成备用气笛。
    print("[Audio] Selected " .. profile.name .. " (" .. profile.id .. ") / loops=" .. #bank.loops)
end

---@param scene Scene
---@param trainRoot Node|nil
---@param powerType? string
---@param selectedId? string
function AudioManager.Init(scene, trainRoot, powerType, selectedId)
    AudioManager.Shutdown()
    scene_ = scene -- 借用调用者的 scene/trainRoot，不能 Dispose
    audioNode_ = Node()
    audioNode_.name = "FantasyRailAudio"
    if trainRoot then AudioManager.SetTrainPose(trainRoot.worldPosition, trainRoot.worldRotation) end
    hornSource_ = createSource("Horn", CUE_TYPE)
    brakeSource_ = createSource("Brake", CUE_TYPE)
    announcerSource_ = createSource("StationChime", CUE_TYPE)
    local selected = selectedId and Profiles.Find(selectedId) or nil
    selectProfile(selected or Profiles.Default(powerType or "diesel"), true)
    -- 懒加载：其他环境/车型首次使用才载入；缺失资源静默并保留错误诊断。
    ensureEnvironment(environment_, true)
    if suspended_ or not enabled_ then audio:PauseSoundType(LOOP_TYPE)
    else audio:ResumeSoundType(LOOP_TYPE) end
    audio:ResumeSoundType(CUE_TYPE)
    print("[Audio] PCM loop system ready / " .. profile_.name .. "; environments=" .. #environments_)
    if not audio:IsInitialized() then
        print("[Audio] Warning: audio device is not initialized; loop PCM is ready but no device output yet")
    end
end

---@param id string
---@return boolean
function AudioManager.SetTrainId(id)
    local profile = Profiles.Find(id)
    if not profile then
        print("[Audio] Unknown train sound ID: " .. tostring(id))
        return false
    end
    if profile.id == profile_.id and #banks_ > 0 then
        failedClips_={}
        for _,path in ipairs({profile.idlePath,profile.runningPath,profile.hornPath}) do
            ownedClip(path,function() return nil end)
        end
        return true
    end
    selectProfile(profile, false)
    return true
end

--- 兼容旧接口。车型身份必须用 SetTrainId 设置，不能仅靠 powerType
--- 区分四款电力车型；相同动力类型不会覆盖现有声音档案。
---@param powerType string
function AudioManager.SetPowerType(powerType)
    local normal = powerType == "diesel" and "diesel" or "electric"
    if profile_.powerType ~= normal then selectProfile(Profiles.Default(normal), false) end
end

function AudioManager.GetPowerType() return profile_.powerType end
function AudioManager.GetTrainId() return profile_.id end

---@param kind string
---@return boolean
function AudioManager.SetEnvironment(kind)
    local normal = string.lower(kind)
    local aliases = { town = "city", urban = "city", station = "city", woods = "forest", trees = "forest",
        woodland = "forest", water = "river", bridge = "river", underground = "tunnel" }
    normal = aliases[normal] or normal
    for _, available in ipairs(ENVIRONMENTS) do
        if normal == available then
            if audioNode_ then ensureEnvironment(normal, false) end
            environment_ = normal
            return true
        end
    end
    print("[Audio] Unknown environment: " .. tostring(kind))
    return false
end

---@param position Vector3
---@param rotation Quaternion
function AudioManager.SetTrainPose(position, rotation)
    trainPosition_, trainRotation_ = position, rotation
    if audioNode_ then
        audioNode_.position = position
        audioNode_.rotation = rotation
    end
    -- 使用驾驶体验的二维声源，不依赖相机距离衰减；切换自由相机
    -- 不会意外让车辆的持续声音静默。
end

local function refreshPlaybackState()
    local blocked = suspended_ or not enabled_
    if blocked then
        for _, bank in ipairs(banks_) do
            for _, entry in ipairs(bank.loops) do entry.source:SetGain(0) end
        end
        for _, entry in ipairs(environments_) do entry.source:SetGain(0) end
        -- 只暂停本模块专用声音类别，保留 PCM 与播放位置。
        audio:PauseSoundType(LOOP_TYPE)
        if hornSource_ then hornSource_:StopImmediate() end
        if brakeSource_ then brakeSource_:StopImmediate() end
        if announcerSource_ then announcerSource_:StopImmediate() end
    else
        audio:ResumeSoundType(LOOP_TYPE)
        -- 从静默淡入；不重新 Play、不重新分配资源、不重置循环相位。
        for _, bank in ipairs(banks_) do
            for _, entry in ipairs(bank.loops) do entry.gain = 0 end
        end
        for _, entry in ipairs(environments_) do entry.gain = 0 end
    end
end

---@param suspended boolean
function AudioManager.SetSuspended(suspended)
    if suspended_ == suspended then return end
    suspended_ = suspended
    refreshPlaybackState()
end

---@param enabled boolean
function AudioManager.SetEnabled(enabled)
    if enabled_ == enabled then return end
    enabled_ = enabled
    refreshPlaybackState()
end

---@param value number
function AudioManager.SetVolume(value)
    volume_=clamp(value,0,1)
    local scale=(suspended_ or not enabled_) and 0 or volume_
    for _,bank in ipairs(banks_) do
        for _,entry in ipairs(bank.loops) do entry.source:SetGain(entry.gain*scale) end
    end
    for _,entry in ipairs(environments_) do entry.source:SetGain(entry.gain*scale) end
    if hornSource_ then hornSource_:SetGain(hornGain_*scale) end
    if brakeSource_ then brakeSource_:SetGain(brakeGain_*scale) end
end
function AudioManager.GetVolume() return volume_ end
function AudioManager.IsEnabled() return enabled_ end

---@param profile FantasyAudioProfile
---@param layer string
---@return number, number
local function trainTargets(profile, layer)
    local speed = math.max(0, smoothedSpeed_)
    local ratio = clamp(speed / profile.speedScale, 0, 1.5)
    local load = clamp(smoothedThrottle_ / profile.throttleNotches, 0, 1)
    if layer == "idle" then return .42 * (1 - .35 * math.min(1,ratio)), 1 end
    -- 启动时随牵引淡入，惯行仍保留轮轨；只调响度，不把采样升频变成尖啸。
    local moving = 1 - math.exp(-speed / 12)
    return (.12 * load + .55 * moving) * (environment_=="tunnel" and 1.08 or 1), 1
end

---@param entry FantasyLoopSource
---@param gain number
---@param pitch number
---@param dt number
local function updateLoop(entry, gain, pitch, dt)
    entry.gain = smooth(entry.gain, clamp(gain, 0, .78), dt, gain > entry.gain and 6 or 4)
    entry.pitch = 1
    entry.source:SetGain(entry.gain * volume_)
    entry.source:SetFrequency(entry.clip.sound:GetFrequency() * entry.pitch)
end

-- 仅在低频检查确实停止的声源后恢复，不属于正常循环路径。
-- 暂停时不运行；IsPlaying 为真本身不等同于设备实际可听。
local function monitorLoops()
    for _, bank in ipairs(banks_) do
        for _, entry in ipairs(bank.loops) do
            if not entry.source:IsPlaying() then
                entry.source:Play(entry.clip.sound, entry.clip.sound:GetFrequency() * entry.pitch, entry.gain * volume_)
                entry.playCalls = entry.playCalls + 1
                entry.restarts = entry.restarts + 1
                print("[Audio] Recovered stopped loop " .. entry.id)
            end
        end
    end
    for _, entry in ipairs(environments_) do
        if not entry.source:IsPlaying() then
            entry.source:Play(entry.clip.sound, entry.clip.sound:GetFrequency() * entry.pitch, entry.gain * volume_)
            entry.playCalls = entry.playCalls + 1
            entry.restarts = entry.restarts + 1
            print("[Audio] Recovered stopped environment " .. entry.id)
        end
    end
end

---@param dt number
---@param speedKmh number
---@param throttle number 兼容现有 Train.GetThrottle() 档位 0..8。
---@param stationDistance? number 距最近站点的米数，原调用签名不变。
function AudioManager.Update(dt, speedKmh, throttle, stationDistance)
    if not audioNode_ then return end
    -- 下载回调缓存就绪的 PCM；下一帧只补缺层，不重启已播放的长循环。
    for _,bank in ipairs(banks_) do
        if not bank.retiring then
            for _,layer in ipairs(TRAIN_LAYERS) do
                local found=false
                for _,entry in ipairs(bank.loops) do if entry.layer==layer then found=true end end
                local path=layer=="idle" and bank.profile.idlePath or bank.profile.runningPath
                local clip=path and ownedClips_[path]
                if not found and clip then
                    local entry=createLoop(layer,bank.id,clip,0,0)
                    if entry then bank.loops[#bank.loops+1]=entry end
                end
            end
        end
    end
    ensureEnvironment(environment_,false)
    if suspended_ or not enabled_ then return end
    local step = clamp(dt, 0, .25)
    elapsed_ = elapsed_ + step
    hornCooldown_ = math.max(0, hornCooldown_ - step)
    brakeCooldown_ = math.max(0, brakeCooldown_ - step)
    smoothedSpeed_ = smooth(smoothedSpeed_, math.abs(speedKmh), step, 5)
    smoothedThrottle_ = smooth(smoothedThrottle_, clamp(throttle, 0, 8), step, 7)
    stationDistance_ = stationDistance and math.max(0, stationDistance) or math.huge
    for index = #banks_, 1, -1 do
        local bank = banks_[index]
        bank.mix = smooth(bank.mix, bank.retiring and 0 or 1, step, 5)
        if bank.retiring and bank.mix < .002 then
            disposeBank(bank)
            table.remove(banks_, index)
        else
            for _, entry in ipairs(bank.loops) do
                local gain, pitch = trainTargets(bank.profile, entry.layer)
                updateLoop(entry, gain * bank.mix, pitch, step)
            end
        end
    end
    for _, entry in ipairs(environments_) do
        local gain = 0.0
        if entry.generatedEnvironment then
            if entry.layer == environment_ .. "_detail" then
                gain = ENVIRONMENT_DETAIL_GAINS[environment_] or .35
            end
        elseif entry.layer == environment_ then
            local detailPresent = false
            for _, other in ipairs(environments_) do
                if other.generatedEnvironment and other.layer == environment_ .. "_detail" then detailPresent = true end
            end
            if detailPresent then
                gain = ENVIRONMENT_BED_GAINS[environment_] or .10
            elseif entry.layer == "city" then
                gain = .13 + .15 * clamp(1 - stationDistance_ / 280, 0, 1)
            elseif entry.layer == "forest" then gain = .20
            elseif entry.layer == "river" then gain = .24
            else gain = .16 + .11 * clamp(smoothedSpeed_ / 140, 0, 1) end
        end
        updateLoop(entry, gain, 1, step)
    end
    monitorTimer_ = monitorTimer_ + step
    if monitorTimer_ >= 1 then monitorTimer_ = 0; monitorLoops() end
end

---@return Sound|nil
local function currentHorn()
    local path = profile_.hornPath -- AudioProfiles.lua 中保留六条字面资源路径
    local clip = ownedClip(path, function() return nil end)
    return clip and clip.sound or nil
end

---@return boolean
function AudioManager.PlayHorn()
    if suspended_ or not enabled_ or not hornSource_ then return false end
    if hornCooldown_ > 0 or hornSource_:IsPlaying() then return true end
    local sound = currentHorn()
    if not sound then return false end
    hornGain_=profile_.hornGain
    hornSource_:Play(sound, sound:GetFrequency(), hornGain_ * volume_)
    hornCooldown_ = .25
    return true
end

---@param intensity? number
---@return boolean
function AudioManager.PlayBrake(intensity)
    if suspended_ or not enabled_ or not brakeSource_ then return false end
    if brakeCooldown_ > 0 or brakeSource_:IsPlaying() then return true end
    local clip = cueClip(profile_, "brake")
    if not clip then return false end
    local amount = clamp(intensity or 1, 0, 1)
    brakeGain_=.15+.20*amount
    brakeSource_:Play(clip.sound, clip.sound:GetFrequency(), brakeGain_ * volume_)
    brakeCooldown_ = .6
    return true
end

---@param kind string
---@return boolean
local function announce(kind)
    if suspended_ or not enabled_ or not announcerSource_ then return false end
    local clip = cueClip(profile_, kind)
    if not clip then return false end
    announcerSource_:Play(clip.sound, 0, .52)
    announcementId_, announcementKind_ = clip.stats.id, kind
    return true
end

--- 站点索引不映射现实地名语音；旧程序提示音已停用。
---@param stationIndex? integer
---@return boolean
function AudioManager.AnnounceArrival(stationIndex) return announce("arrival") end

---@param stationIndex? integer
---@return boolean
function AudioManager.AnnounceDeparture(stationIndex) return announce("departure") end

--- 兼容旧调用，只发非语言提示音，不加载旧广播文件。
---@param voiceIndex integer
---@return boolean
function AudioManager.PlayVoice(voiceIndex)
    return announce(voiceIndex > 5 and "departure" or "arrival")
end

---@param entry FantasyLoopSource
---@param bankMix number
---@return FantasyLoopDiagnostic
local function loopDiagnostic(entry, bankMix)
    local stats = entry.clip.stats
    return {
        id = entry.id, trainId = entry.trainId, layer = entry.layer,
        playing = entry.source:IsPlaying(), gain = entry.source:GetGain(),
        frequency = entry.source:GetFrequency(), pitch = entry.pitch,
        sampleRate = entry.clip.sound:GetFrequency(), soundId = stats.id,
        looped = entry.clip.sound:IsLooped(), timePosition = entry.source:GetTimePosition(),
        rms = stats.rms, RMS = stats.rms, peak = stats.peak, seamDelta = stats.seamDelta,
        loopBoundaryDelta = stats.loopBoundaryDelta, periodicClosureDelta = stats.periodicClosureDelta,
        samples = stats.samples, duration = stats.duration, generationSeconds = stats.generationSeconds,
        maxAdjacentDelta = stats.maxAdjacentDelta, playCalls = entry.playCalls,
        restarts = entry.restarts, bankMix = bankMix,
        generatedEnvironment = entry.generatedEnvironment == true, resourcePath = entry.resourcePath or "",
        bakedPCM = entry.clip.baked == true, cacheLoadSeconds = entry.clip.loadSeconds or 0,
    }
end

function AudioManager.GetDiagnostics()
    local loops = {} ---@type FantasyLoopDiagnostic[]
    local environmentLoops = {} ---@type FantasyLoopDiagnostic[]
    local audible, playing, restarts = 0, 0, 0
    for _, bank in ipairs(banks_) do
        for _, entry in ipairs(bank.loops) do
            local data = loopDiagnostic(entry, bank.mix)
            loops[#loops + 1] = data
            if data.playing then playing = playing + 1 end
            if data.playing and data.gain > .001 and not suspended_ and enabled_ then audible = audible + 1 end
            restarts = restarts + data.restarts
        end
    end
    for _, entry in ipairs(environments_) do
        local data = loopDiagnostic(entry, 1)
        environmentLoops[#environmentLoops + 1] = data
        if data.playing then playing = playing + 1 end
        if data.playing and data.gain > .001 and not suspended_ and enabled_ then audible = audible + 1 end
        restarts = restarts + data.restarts
    end
    local ownedCount, pcmBytes, bakedCount, fallbackCount = 0, 0, 0, 0
    for _, clip in pairs(ownedClips_) do
        ownedCount = ownedCount + 1
        pcmBytes = pcmBytes + clip.sound:GetDataSize()
        if clip.baked then bakedCount = bakedCount + 1 else fallbackCount = fallbackCount + 1 end
    end
    return {
        initialized = audioNode_ ~= nil, trainId = profile_.id, trainName = profile_.name,
        profileDescription = profile_.description, powerType = profile_.powerType,
        environment = environment_, suspended = suspended_, enabled = enabled_, muted = not enabled_,
        speedKmh = smoothedSpeed_,
        throttleNotch = smoothedThrottle_, stationDistance = stationDistance_,
        loops = loops, environmentLoops = environmentLoops,
        loopSourcesPlaying = playing, loopSourcesAudible = audible, loopRestarts = restarts,
        ownedSoundCount = ownedCount, pcmBytes = pcmBytes, elapsed = elapsed_,
        bakedSoundCount = bakedCount, realtimeFallbackSoundCount = fallbackCount,
        bakedCache = AudioCache.GetDiagnostics(),
        hornPath = profile_.hornPath, hornGain = profile_.hornGain,
        hornUsingFallback = missing_[profile_.hornPath] == true,
        hornPlaying = hornSource_ and hornSource_:IsPlaying() or false,
        brakePlaying = brakeSource_ and brakeSource_:IsPlaying() or false,
        announcementPlaying = announcerSource_ and announcerSource_:IsPlaying() or false,
        announcementSoundId = announcementId_, announcementKind = announcementKind_,
        announcementProcedural = false, announcementPath = "", announcementsEnabled = false,
        hornOutputGain=hornSource_ and hornSource_:GetGain() or 0,
        brakeOutputGain=brakeSource_ and brakeSource_:GetGain() or 0,
        audioDevicePlaying = audio:IsPlaying(), audioDeviceInitialized = audio:IsInitialized(),
        mixRate = audio:GetMixRate(), loopsPaused = audio:IsSoundTypePaused(LOOP_TYPE),
        failedClips = failedClips_, trainPosition = trainPosition_, trainRotation = trainRotation_,
        synthesis = "generated long loops / offline lowpass / controlled loudness / original sample frequency",
        volume = volume_,
    }
end

function AudioManager.Shutdown()
    generation_=generation_+1
    requests_={}
    -- 先停声源并释放其引用，再 Dispose 本模块自行创建的 Sound。
    for _, bank in ipairs(banks_) do disposeBank(bank) end
    for _, entry in ipairs(environments_) do
        entry.source:StopImmediate()
        entry.node:Dispose()
    end
    if hornSource_ then hornSource_:StopImmediate() end
    if brakeSource_ then brakeSource_:StopImmediate() end
    if announcerSource_ then announcerSource_:StopImmediate() end
    if audioNode_ then audioNode_:Dispose() end
    banks_, environments_ = {}, {}
    hornSource_, brakeSource_, announcerSource_ = nil, nil, nil
    audioNode_, scene_ = nil, nil
    for _, clip in pairs(ownedClips_) do clip.sound:Dispose() end
    ownedClips_, failedClips_ = {}, {}
    -- 外部喇叭归缓存所有，禁止 Dispose 或 SetLooped 修改。
    cachedHorns_, missing_ = {}, {}
    AudioCache.ResetDiagnostics()
    audio:ResumeSoundType(LOOP_TYPE)
    environment_, suspended_ = "city", false
    smoothedSpeed_, smoothedThrottle_, elapsed_, monitorTimer_ = 0, 0, 0, 0
    stationDistance_, hornCooldown_, brakeCooldown_ = math.huge, 0, 0
    announcementId_, announcementKind_ = "", ""
    hornGain_,brakeGain_=0,0
end

return AudioManager
