-- 实际音频设备输出验收：SDL disk 驱动录制混音结果，不用 -nosound。
-- 本入口只创建声音场景；不以程序统计冒充已经听过或手机性能验收。
local AudioManager = require "audio.AudioManager"
local Profiles = require "audio.AudioProfiles"
local V = {checks=0}
---@type Scene?
local scene_ = nil
local frame_, caseFrame_, index_ = 0, 0, 1
local failed_, complete_ = false, false
local rate_ = 44100
local ENVIRONMENTS = {"city", "forest", "river", "tunnel", "forest", "city"}
local longLoops_,caseFrames_ = false,125
local previousTimes_,wraps_ = {},{} ---@type table<string,number>,table<string,boolean>
local pausedTimes_ = {} ---@type table<string,number>

local function check(condition, message)
    V.checks = V.checks+1
    if not condition then error("[AudioOutput] " .. message, 2) end
end
local function guarded(action)
    if failed_ or complete_ then return end
    local ok, message = xpcall(action, debug.traceback)
    if not ok then
        failed_ = true
        print("[AudioOutput] FAILED " .. tostring(message))
        error(message, 0)
    end
end
local function selectCase()
    caseFrame_ = 0
    previousTimes_,wraps_,pausedTimes_={},{},{}
    local id = assert(Profiles.Ids[index_])
    check(AudioManager.SetTrainId(id), "车型声音档案切换失败")
    check(AudioManager.SetEnvironment(assert(ENVIRONMENTS[index_])), "环境声切换失败")
    print(string.format("[AudioOutput] CASE %d %s environment=%s time=%.3f",
        index_, assert(Profiles.Find(id)).name, ENVIRONMENTS[index_], time:GetElapsedTime()))
end

function Start()
    guarded(function()
        for _,argument in ipairs(GetArguments()) do
            if argument=="-audio-long-loops" then longLoops_,caseFrames_=true,1120 end
        end
        engine:SetMaxFps(20)
        engine:SetMaxInactiveFps(20)
        check(audio:SetMode(50, rate_, true, true), "真实音频设备初始化失败")
        check(audio:Play(), "真实音频设备未开始混音")
        scene_ = Scene()
        local listener = scene_:CreateChild("Listener"):CreateComponent("SoundListener")
        audio:SetListener(listener)
        AudioManager.Init(scene_, nil, "diesel", Profiles.Ids[1])
        AudioManager.SetEnabled(true)
        check(audio:IsInitialized() and audio:IsPlaying(), "仅存在Sound对象但音频设备未运行")
        selectCase()
        SubscribeToEvent("Update", "AudioOutputUpdate")
        print(string.format("[AudioOutput] DEVICE sampleSize=%d mixRate=%d stereo=%s",
            audio:GetSampleSize(), audio:GetMixRate(), tostring(audio:IsStereo())))
    end)
end

---@param eventType string
---@param eventData UpdateEventData
function AudioOutputUpdate(eventType, eventData)
    guarded(function()
        frame_, caseFrame_ = frame_+1, caseFrame_+1
        local dt = math.min(.1, math.max(.02, eventData:GetFloat("TimeStep")))
        local speed = caseFrame_ <= 20 and 0 or (caseFrame_ <= 40 and (caseFrame_-20)*2 or 120)
        local throttle = caseFrame_ <= 20 and 0 or 6
        AudioManager.Update(dt, speed, throttle, caseFrame_ <= 20 and 0 or 800)
        if caseFrame_ == 61 then check(AudioManager.PlayHorn(), "生成喇叭未播放") end
        if caseFrame_ == 65 then
            local diag = AudioManager.GetDiagnostics()
            check(diag.trainId == Profiles.Ids[index_], "声音档案错误")
            check(not diag.hornUsingFallback, "未使用已生成的独立喇叭")
            check(diag.loopSourcesAudible >= 3, "两层生成运行声与环境声仍静音")
            check(diag.loopRestarts == 0, "健康循环被反复重新播放")
            check(diag.realtimeFallbackSoundCount == 0, "正常切换仍触发现场PCM合成")
            check(diag.bakedCache.metadataLoaded and next(diag.bakedCache.errors) == nil, "预烘缓存缺失或失效")
            for _, loop in ipairs(diag.loops) do
                if loop.trainId == Profiles.Ids[index_] then
                    check(loop.looped and loop.playing, "循环层停止或非循环")
                    check(loop.rms > .01 and loop.peak <= .18, "生成素材静音或响度处理未生效")
                    check(loop.pitch==1 and loop.frequency==loop.sampleRate,"生成音效被升频拉尖")
                    check(loop.duration>25 and loop.resourcePath:find("comfort",1,true),"没有使用长生成循环音效")
                    check(loop.playCalls == 1, "每帧重复Play")
                    check(loop.bakedPCM and loop.cacheLoadSeconds < .1, "PCM未预烘或单层读取仍卡顿")
                end
            end
            print(string.format("[AudioOutput] OBSERVED %s audible=%d restarts=%d PCM=%d bytes horn=%s",
                diag.trainName, diag.loopSourcesAudible, diag.loopRestarts, diag.pcmBytes, diag.hornPath))
        end
        if longLoops_ then
            if caseFrame_==70 then
                AudioManager.SetVolume(0)
                local muted=AudioManager.GetDiagnostics()
                check(muted.hornOutputGain==0,"调整音量没有立即静音已播放汽笛")
                for _,loop in ipairs(muted.loops) do check(loop.gain==0,"运行循环未立即响应音量") end
                for _,loop in ipairs(muted.environmentLoops) do check(loop.gain==0,"环境声未立即响应音量") end
                AudioManager.SetVolume(.55)
            elseif caseFrame_==100 then
                AudioManager.SetSuspended(true)
                for _,loop in ipairs(AudioManager.GetDiagnostics().loops) do pausedTimes_[loop.id]=loop.timePosition end
            elseif caseFrame_==110 then
                local paused=AudioManager.GetDiagnostics()
                check(paused.loopsPaused,"暂停没有冻结循环类别")
                for _,loop in ipairs(paused.loops) do
                    check(math.abs(loop.timePosition-(pausedTimes_[loop.id] or loop.timePosition))<.1,"暂停后循环相位仍推进")
                end
                AudioManager.SetSuspended(false)
            elseif caseFrame_==130 then AudioManager.SetEnabled(false)
            elseif caseFrame_==140 then
                check(AudioManager.GetDiagnostics().loopsPaused,"静音没有暂停持久声源")
                AudioManager.SetEnabled(true)
            end
            local diag=AudioManager.GetDiagnostics()
            for _,loop in ipairs(diag.loops) do
                if loop.trainId==Profiles.Ids[index_] then
                    local previous=previousTimes_[loop.id]
                    if previous and loop.timePosition<previous-.5 then wraps_[loop.layer]=true end
                    previousTimes_[loop.id]=loop.timePosition
                end
            end
            if caseFrame_==caseFrames_ then
                check(wraps_.idle and wraps_.running,"实际设备播放尚未跨越完整循环周期")
                check(diag.loopRestarts==0,"长循环或暂停恢复触发重复Play")
                print(string.format("[AudioOutput] FULL_LOOP_PASS %s idle=%s running=%s time=%.3f",
                    diag.trainName,tostring(wraps_.idle),tostring(wraps_.running),time:GetElapsedTime()))
            end
        end
        if caseFrame_ >= caseFrames_ then
            if index_ < #Profiles.Ids then
                index_ = index_+1
                selectCase()
            else
                complete_ = true
                print(string.format("ALL_FICTIONAL_AUDIO_OUTPUT_PASS cases=%d assertions=%d frames=%d mixRate=%d",
                    #Profiles.Ids, V.checks, frame_, audio:GetMixRate()))
            end
        end
    end)
end

function Stop()
    AudioManager.Shutdown()
    if scene_ then scene_:Dispose(); scene_=nil end
end
