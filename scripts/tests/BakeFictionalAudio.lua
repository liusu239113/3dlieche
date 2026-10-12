-- 离线幻想声音烘焙：每帧处理一项，完成后退出。只写正式 assets，不播放音频。
-- 28 条持续程序 loop、4 条既有环境 WAV 的统计先完成；再烘焙一次性提示音，
-- 防止生产中的首次制动/广播也触发同步合成停顿。不修改已有环境/喇叭素材。
local Profiles = require "audio.AudioProfiles"
local Synth = require "audio.ProceduralAudio"
local Paths = require "audio.AudioBakePaths"

---@class FictionalAudioBakeTask
---@field key string
---@field kind string
---@field profile? FantasyAudioProfile
---@field layer string
---@field path string

---@class FictionalAudioBakedEntry
---@field path string
---@field dataSize integer
---@field stats ProceduralSoundStats

---@type FictionalAudioBakeTask[]
local tasks_ = {}
---@type table<string, FictionalAudioBakedEntry>
local entries_ = {}
---@type ProceduralSound|nil
local activeClip_ = nil
local index_ = 1
local failed_ = false
local finished_ = false
local loopCount_, cueCount_, detailCount_ = 0, 0, 0
local started_ = 0.0

---@param action fun()
---@return boolean
local function guarded(action)
    local ok, err = pcall(action)
    if not ok then
        failed_ = true
        if activeClip_ then activeClip_.sound:Dispose(); activeClip_ = nil end
        Synth.SetBakeCapture(false)
        log:Write(LOG_ERROR, "[BakeFictionalAudio] " .. tostring(err))
        engine:Exit()
    end
    return ok
end

---@param path string
---@param buffer VectorBuffer
local function writeBuffer(path, buffer)
    local file = File(path, FILE_WRITE)
    assert(file and file:IsOpen(), "不能打开输出文件 " .. path)
    buffer:Seek(0)
    local count = file:Write(buffer)
    local expected = buffer:GetSize()
    file:Flush()
    file:Dispose()
    assert(count == expected, "输出不完整 " .. path .. " " .. count .. "/" .. expected)
end

---@param path string
---@param value table
local function writeJson(path, value)
    local text = cjson.encode(value)
    local buffer = VectorBuffer()
    -- WriteString 会附加零字节，不适合作为普通 JSON；字节写入只在离线运行。
    for index = 1, #text do buffer:WriteUByte(string.byte(text, index)) end
    writeBuffer(path, buffer)
end

---@param task FictionalAudioBakeTask
local function bakeTask(task)
    if task.kind == "detail" then
        assert(cache:Exists(task.path), "辅助环境素材不存在 " .. task.path)
        local file = cache:GetFile(task.path)
        file:Seek(0)
        local buffer = file:Read(file:GetSize())
        buffer:Seek(0)
        local reader = tolua.cast(buffer, "Deserializer") --[[@as Deserializer]]
        local stats = assert(Synth.InspectWav(reader, "environment-generated:" .. task.layer))
        entries_[task.key] = { path = task.path, dataSize = stats.samples * 2, stats = stats }
        detailCount_ = detailCount_ + 1
        return
    end
    if task.kind == "train" then
        activeClip_ = Synth.TrainLoop(assert(task.profile), task.layer)
        loopCount_ = loopCount_ + 1
    elseif task.kind == "environment" then
        activeClip_ = Synth.EnvironmentLoop(task.layer)
        loopCount_ = loopCount_ + 1
    else
        activeClip_ = Synth.Cue(assert(task.profile), task.layer)
        cueCount_ = cueCount_ + 1
    end
    local clip = assert(activeClip_, "合成失败 " .. task.key)
    local wav = assert(clip.wav, "缺少离线 WAV 内存 " .. task.key)
    assert(clip.stats.rms > .01 and clip.stats.peak > .01, "合成 PCM 静默 " .. task.key)
    if clip.stats.looped then
        assert(clip.stats.periodicClosureDelta < 1e-8, "循环不闭合 " .. task.key)
    end
    writeBuffer(Paths.Root .. task.path, wav)
    entries_[task.key] = { path = task.path, dataSize = clip.sound:GetDataSize(), stats = clip.stats }
    clip.sound:Dispose()
    activeClip_ = nil
end

local function saveManifest()
    writeJson(Paths.Root .. Paths.Metadata, {
        version = Paths.Version, entries = entries_, loops = loopCount_, cues = cueCount_,
        environmentDetails = detailCount_, synthesis = "Lua ProceduralAudio / PCM16 WAV",
    })
end

function Start()
    started_ = os.clock()
    guarded(function()
        assert(fileSystem:CreateDir(Paths.Root .. "audio/synthesized")
            or fileSystem:DirExists(Paths.Root .. "audio/synthesized"), "创建烘焙资源目录失败")
        Synth.SetBakeCapture(true)
        for _, id in ipairs(Profiles.Ids) do
            local profile = assert(Profiles.Find(id))
            for _, layer in ipairs(Paths.TrainLayers) do
                local key = id .. ":" .. layer
                tasks_[#tasks_ + 1] = {
                    key = key, kind = "train", profile = profile, layer = layer, path = assert(Paths.Wavs[key]),
                }
            end
        end
        for _, kind in ipairs(Paths.Environments) do
            local key = "environment:" .. kind
            tasks_[#tasks_ + 1] = {
                key = key, kind = "environment", layer = kind, path = assert(Paths.Wavs[key]),
            }
        end
        for _, kind in ipairs(Paths.Environments) do
            tasks_[#tasks_ + 1] = {
                key = "environment-detail:" .. kind, kind = "detail", layer = kind, path = assert(Paths.Details[kind]),
            }
        end
        for _, id in ipairs(Profiles.Ids) do
            local profile = assert(Profiles.Find(id))
            for _, kind in ipairs(Paths.CueKinds) do
                local key = id .. ":cue:" .. kind
                tasks_[#tasks_ + 1] = {
                    key = key, kind = "cue", profile = profile, layer = kind, path = assert(Paths.Wavs[key]),
                }
            end
        end
        SubscribeToEvent("Update", "BakeFictionalAudioUpdate")
        print("[BakeFictionalAudio] 开始离线烘焙，任务=" .. #tasks_ .. "，每帧一项")
    end)
end

---@param eventType string
---@param eventData UpdateEventData
function BakeFictionalAudioUpdate(eventType, eventData)
    if failed_ or finished_ then return end
    local ok = guarded(function()
        local task = assert(tasks_[index_])
        local begin = os.clock()
        bakeTask(task)
        print(string.format("[BakeFictionalAudio] %d/%d %s seconds=%.3f",
            index_, #tasks_, task.key, os.clock() - begin))
        -- 第32项后先提交全部28个loop及环境metadata，核心产物不等待cue。
        if index_ == 32 then saveManifest(); print("FICTIONAL_AUDIO_28_LOOPS_BAKED") end
        index_ = index_ + 1
        if index_ > #tasks_ then
            saveManifest()
            finished_ = true
            print(string.format("ALL_FICTIONAL_AUDIO_BAKE_PASS loops=%d cues=%d environmentMetadata=%d seconds=%.3f",
                loopCount_, cueCount_, detailCount_, os.clock() - started_))
        end
    end)
    if ok and finished_ then
        Synth.SetBakeCapture(false)
        engine:Exit() -- 必须在保护函数外，完成或失败均退出
    end
end

function Stop()
    if activeClip_ then activeClip_.sound:Dispose(); activeClip_ = nil end
    Synth.SetBakeCapture(false)
end
