-- 真正周期连续的 Lua 程序 PCM：整数周期振荡器 + 首尾一阶导数连续的随机噪声。
-- 不使用预录机车运行声；Lua 无 Sound:SetData(void*) 接口，按绑定使用
-- VectorBuffer 构造 PCM16 WAV → Seek(0) → Sound:LoadWav(Deserializer)。
-- 运行时默认不落盘；离线 Bake 入口显式保留 WAV buffer 导出项目资源。
local Synth = {}
local RATE = 22050
local captureWav_ = false

---@param capture boolean
function Synth.SetBakeCapture(capture) captureWav_ = capture end
local TAU = math.pi * 2

---@class ProceduralSoundStats
---@field id string
---@field sampleRate integer
---@field samples integer
---@field duration number
---@field rms number
---@field peak number
---@field seamDelta number
---@field loopBoundaryDelta number
---@field periodicClosureDelta number
---@field generationSeconds number
---@field maxAdjacentDelta number
---@field looped boolean
---@field synthesis string

---@class ProceduralSound
---@field sound Sound
---@field stats ProceduralSoundStats
---@field wav? VectorBuffer 只在离线 Bake 模式保留可导出的 WAV 内存
---@field baked? boolean
---@field resourcePath? string
---@field loadSeconds? number

---@param value number
---@param low number
---@param high number
---@return number
local function clamp(value, low, high)
    return math.max(low, math.min(high, value))
end

-- C1 周期三次插值随机场：末段回到首个节点，导数也与首段完全一致。
-- 循环边界不重新随机、不加音量谷、不插入静默或重复首样本。
-- 每款/每层独立种子，不改变玩法使用的 math.random 状态。
---@param seed integer
---@param count integer
---@return fun(phase:number):number
local function noiseField(seed, count)
    local values = {} ---@type number[]
    local state = seed
    for i = 1, count do
        state = (state * 48271) % 2147483647
        values[i] = state / 1073741823.5 - 1
    end
    return function(phase)
        local x = (phase % 1) * count
        local whole = math.floor(x)
        local u = x - whole
        local p0 = assert(values[(whole - 1) % count + 1])
        local p1 = assert(values[whole % count + 1])
        local p2 = assert(values[(whole + 1) % count + 1])
        local p3 = assert(values[(whole + 2) % count + 1])
        return .5 * ((2 * p1) + (-p0 + p2) * u
            + (2 * p0 - 5 * p1 + 4 * p2 - p3) * u * u
            + (-p0 + 3 * p1 - 3 * p2 + p3) * u * u * u)
    end
end

---@param seed integer
---@param duration number
---@param colour number
---@return fun(phase:number):number
local function colouredNoise(seed, duration, colour)
    local low = noiseField(seed, math.floor(duration * 65))
    local middle = noiseField(seed + 97, math.floor(duration * 480))
    local high = noiseField(seed + 277, math.floor(duration * 2300))
    return function(phase)
        return colour * low(phase) + .38 * middle(phase) + (1 - colour) * .55 * high(phase)
    end
end

---@param hz number
---@param duration number
---@return integer
local function cycles(hz, duration)
    return math.max(1, math.floor(hz * duration + .5))
end

---@param phase number
---@param count integer
---@param harmonics number[]
---@param modulation number
---@return number
local function harmonicTone(phase, count, harmonics, modulation)
    local angle = TAU * phase * count + modulation * math.sin(TAU * phase * 5)
    local result = 0.0
    for index, amplitude in ipairs(harmonics) do
        result = result + amplitude * math.sin(angle * index)
    end
    return result
end

---@param id string
---@param duration number
---@param looped boolean
---@param waveform fun(phase:number,time:number):number
---@return ProceduralSound|nil
local function encode(id, duration, looped, waveform)
    local started = os.clock()
    local sampleCount = math.floor(duration * RATE)
    local samples = {} ---@type number[]
    local sum = 0.0
    for i = 1, sampleCount do
        local time = (i - 1) / RATE
        local value = waveform((i - 1) / sampleCount, time)
        samples[i] = value
        sum = sum + value
    end
    -- 去直流保持周期性；按 RMS 与峰值共同规范化，保证底声可听，
    -- 同时留出多层混音的余量，不把各通道都推到满幅。
    local mean = looped and sum / sampleCount or 0
    local peak, energy = 0.0, 0.0
    for i = 1, sampleCount do
        local value = assert(samples[i]) - mean
        samples[i] = value
        peak = math.max(peak, math.abs(value))
        energy = energy + value * value
    end
    local rms = math.sqrt(energy / sampleCount)
    local scale = math.min(.24 / math.max(rms, .000001), .82 / math.max(peak, .000001))
    local dataSize = sampleCount * 2
    local buffer = VectorBuffer()
    buffer:Resize(44 + dataSize)
    buffer:Seek(0)
    buffer:WriteFileID("RIFF")
    buffer:WriteUInt(36 + dataSize)
    buffer:WriteFileID("WAVE")
    buffer:WriteFileID("fmt ")
    buffer:WriteUInt(16)
    buffer:WriteUShort(1) -- PCM，非压缩
    buffer:WriteUShort(1) -- 单声道；左右声像由声源控制
    buffer:WriteUInt(RATE)
    buffer:WriteUInt(RATE * 2)
    buffer:WriteUShort(2)
    buffer:WriteUShort(16)
    buffer:WriteFileID("data")
    buffer:WriteUInt(dataSize)
    local maxDelta = 0.0
    local previous = assert(samples[1]) * scale
    for i = 1, sampleCount do
        local value = clamp(assert(samples[i]) * scale, -.999, .999)
        maxDelta = math.max(maxDelta, math.abs(value - previous))
        previous = value
        buffer:WriteShort(math.floor(value * 32767 + .5))
    end
    buffer:Seek(0)
    local sound = Sound()
    -- @as 只影响静态类型；此处必须真实转换 tolua userdata。
    -- 原生 probe 已验证：VectorBuffer → tolua.cast(...,"Deserializer")
    -- → Sound:LoadWav 成功，1 秒 PCM 的采样率/大小/时长全部准确。
    -- buffer 原变量在整个加载期间强持有，不对 File 做多重继承盲转换。
    local reader = tolua.cast(buffer, "Deserializer") --[[@as Deserializer]]
    local ok, loaded = pcall(function()
        return sound:LoadWav(reader)
    end)
    if not ok or not loaded then
        print("[AudioSynth] WAV load failed: " .. id .. " / " .. tostring(loaded))
        sound:Dispose()
        return nil
    end
    sound:SetLooped(looped)
    if looped then sound:FixInterpolation() end
    ---@type ProceduralSoundStats
    local stats = {
        id = id, sampleRate = RATE, samples = sampleCount, duration = sampleCount / RATE,
        rms = rms * scale, peak = peak * scale,
        seamDelta = math.abs(assert(samples[1]) - assert(samples[sampleCount])) * scale,
        loopBoundaryDelta = math.abs(assert(samples[1]) - assert(samples[sampleCount])) * scale,
        periodicClosureDelta = looped and math.abs(waveform(0, 0) - waveform(1, sampleCount / RATE)) * scale or 0,
        generationSeconds = os.clock() - started,
        maxAdjacentDelta = maxDelta, looped = looped,
        synthesis = "periodic-cubic-noise+integer-cycle-oscillators/PCM16-WAV",
    }
    return { sound = sound, stats = stats, wav = captureWav_ and buffer or nil }
end

---@param profile FantasyAudioProfile
---@param layer string
---@return ProceduralSound|nil
function Synth.TrainLoop(profile, layer)
    local duration = layer == "wind" and 4 or 2
    local seedOffset = ({ idle = 11, traction = 101, rolling = 401, wind = 701 })[layer] or 11
    local colour = layer == "wind" and profile.windColour or profile.railColour
    local noise = colouredNoise(profile.seed + seedOffset, duration, colour)
    local idleCycles = cycles(profile.idleHz, duration)
    local tractionCycles = cycles(profile.tractionHz, duration)
    local pulseCycles = cycles(profile.pulseHz, duration)
    local railCycles = cycles(profile.railHz, duration)
    return encode(profile.id .. ":" .. layer, duration, true, function(phase)
        local air = noise(phase)
        if layer == "idle" then
            local pulse = .68 + .32 * math.cos(TAU * phase * pulseCycles)
            local motor = harmonicTone(phase, idleCycles, profile.idleHarmonics, .06)
            if profile.powerType == "diesel" then
                return .66 * motor * pulse + .22 * air
                    + .10 * math.sin(TAU * phase * pulseCycles * 3)
            end
            return .36 * motor + .40 * air * (.85 + .15 * math.cos(TAU * phase * 2))
        elseif layer == "traction" then
            local tone = harmonicTone(phase, tractionCycles, profile.tractionHarmonics, profile.modulation)
            local load = .83 + .17 * math.cos(TAU * phase * pulseCycles)
            return .65 * tone * load + .22 * air
        elseif layer == "rolling" then
            local joint = (.5 + .5 * math.cos(TAU * phase * railCycles)) ^ 12
            local wheel = math.sin(TAU * phase * railCycles * 19)
                + .32 * math.sin(TAU * phase * railCycles * 41)
            return .66 * air * (.65 + .35 * joint) + .27 * joint * wheel
                + .12 * math.sin(TAU * phase * 37)
        end
        return air * (.81 + .13 * math.sin(TAU * phase * 3)
            + .06 * math.sin(TAU * phase * 7))
    end)
end

---@param kind string
---@return ProceduralSound|nil
function Synth.EnvironmentLoop(kind)
    local duration = 4
    local seeds = { city = 7111, forest = 8117, river = 9127, tunnel = 10133 }
    local noise = colouredNoise(seeds[kind] or seeds.city, duration, kind == "river" and .36 or .68)
    local fine = noiseField((seeds[kind] or seeds.city) + 411, 2400)
    return encode("environment:" .. kind, duration, true, function(phase)
        local bed = noise(phase)
        if kind == "forest" then
            -- 周期 FM 振荡器配平滑包络模拟鸟鸣；鸟鸣之间和循环边界
            -- 均保留连续树叶沙沙声，不用静默段拼接。
            local bird = 0.0
            for index = 1, 3 do
                local chirpPhase = (phase * (index + 1) + index * .23) % 1
                local envelope = math.sin(math.pi * chirpPhase) ^ 32
                bird = bird + envelope * math.sin(TAU * phase * (13760 + index * 1360)
                    + 7 * math.sin(TAU * phase * (index + 5))) * .12
            end
            return .52 * bed + .16 * fine(phase) + bird
        elseif kind == "river" then
            local eddy = .74 + .15 * math.sin(TAU * phase * 3) + .11 * math.sin(TAU * phase * 7)
            return .74 * bed * eddy + .13 * fine(phase)
        elseif kind == "tunnel" then
            return .56 * bed + .13 * math.sin(TAU * phase * 344)
                + .08 * math.sin(TAU * phase * 568) + .08 * math.sin(TAU * phase * 936)
        end
        -- 抽象城镇通行/通风声，无语音或现实地名。
        return .70 * bed * (.82 + .18 * math.cos(TAU * phase * 2))
            + .09 * math.sin(TAU * phase * 448) + .07 * fine(phase)
    end)
end

---@param profile FantasyAudioProfile
---@param kind string
---@return ProceduralSound|nil
function Synth.Cue(profile, kind)
    if kind == "brake" then
        local noise = colouredNoise(profile.seed + 1717, 1.25, .22)
        return encode(profile.id .. ":brake", 1.25, false, function(phase, time)
            local envelope = math.sin(math.pi * phase) ^ 2
            local squeal = math.sin(TAU * ((950 + profile.tractionHz) * time - 160 * time * time))
            return envelope * (.57 * noise(phase) + .23 * squeal)
        end)
    elseif kind == "horn" then
        return encode(profile.id .. ":horn-fallback", 1.65, false, function(phase, time)
            local attack = clamp(time / .06, 0, 1)
            local release = clamp((1.65 - time) / .17, 0, 1)
            local envelope = attack * attack * (3 - 2 * attack)
                * release * release * (3 - 2 * release)
            local tone = 0.0
            for _, hz in ipairs(profile.hornNotes) do
                tone = tone + math.sin(TAU * hz * time) + .22 * math.sin(TAU * hz * time * 2)
            end
            return tone * .22 * envelope
        end)
    end
    local notes = kind == "departure" and { 523.25, 659.25, 783.99 } or { 783.99, 659.25, 523.25 }
    return encode(profile.id .. ":" .. kind .. "-chime", 1.3, false, function(_, time)
        local value = 0.0
        for index, hz in ipairs(notes) do
            local noteTime = time - (index - 1) * .25
            if noteTime >= 0 and noteTime < .65 then
                local envelope = math.sin(math.pi * noteTime / .65) ^ 2
                value = value + envelope * (math.sin(TAU * hz * noteTime)
                    + .20 * math.sin(TAU * hz * 2 * noteTime))
            end
        end
        return value * .4
    end)
end

-- 读取辅助环境 WAV 的实际 PCM 统计，不虚构 RMS 或首尾误差。
-- 仅支持本项目素材约定的单声道 PCM16 格式。
---@param source Deserializer
---@param id string
---@return ProceduralSoundStats|nil
function Synth.InspectWav(source, id)
    source:Seek(0)
    if source:ReadFileID() ~= "RIFF" then return nil end
    source:ReadUInt()
    if source:ReadFileID() ~= "WAVE" then return nil end
    local rate, channels, bits, format = 0, 0, 0, 0
    local dataOffset, dataBytes = 0, 0
    while source:GetPosition() + 8 <= source:GetSize() do
        local chunk = source:ReadFileID()
        local size = source:ReadUInt()
        local position = source:GetPosition()
        if chunk == "fmt " and size >= 16 then
            format = source:ReadUShort()
            channels = source:ReadUShort()
            rate = source:ReadUInt()
            source:ReadUInt()
            source:ReadUShort()
            bits = source:ReadUShort()
        elseif chunk == "data" then
            dataOffset, dataBytes = position, size
        end
        source:Seek(position + size + size % 2)
        if dataBytes > 0 and rate > 0 then break end
    end
    if format ~= 1 or channels ~= 1 or bits ~= 16 or dataBytes < 2 then return nil end
    source:Seek(dataOffset)
    local count = dataBytes // 2
    local energy, peak, maxDelta = 0.0, 0.0, 0.0
    local first, previous, last = 0.0, 0.0, 0.0
    for index = 1, count do
        local value = source:ReadShort() / 32768
        if index == 1 then first, previous = value, value end
        peak = math.max(peak, math.abs(value))
        energy = energy + value * value
        maxDelta = math.max(maxDelta, math.abs(value - previous))
        previous, last = value, value
    end
    return {
        id = id, sampleRate = rate, samples = count, duration = count / rate,
        rms = math.sqrt(energy / count), peak = peak, seamDelta = math.abs(first - last),
        loopBoundaryDelta = math.abs(first - last), maxAdjacentDelta = maxDelta,
        periodicClosureDelta = -1, -- 非解析振荡器，没有可用的解析周期闭合值
        generationSeconds = 0, looped = true,
        synthesis = "generated-fictional-environment/PCM16-WAV/1s-cosine-overlap",
    }
end

return Synth
