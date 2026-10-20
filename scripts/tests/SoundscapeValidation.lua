-- 真实生产Soundscape探针：本地WAV解码/增益/类别暂停/生命周期，不加载main、不写存档。
-- 基于SoundBindingValidation的一次性pcall脚手架，结束总是engine:Exit。
-- 所有测试类别设备输出强制静音；可听效果始终NOT_RUN，不代表手机通过。
local Soundscape=require "audio.Soundscape"
local KINDS={"music","platform","carriage","rain"}
local TYPES={"FantasyRail.Music","FantasyRail.Crowd.Platform","FantasyRail.Crowd.Carriage","FantasyRail.Environment.Rain"}
local PATHS={
    music="audio/music/railway_journey_loop.wav",
    platform="audio/sfx/crowd/platform_loop.wav",
    carriage="audio/sfx/crowd/carriage_loop.wav",
    rain="audio/sfx/rail_rain_soft_loop.wav",
}
---@class SoundscapeProbeChannel
---@field path string
---@field ready boolean
---@field gain number
---@field playing boolean
---@field paused boolean
---@field playCalls integer
---@field timePosition number
---@class SoundscapeProbeDiagnostics
---@field channels table<string,SoundscapeProbeChannel>
---@field errors table<string,string>
---@field masterVolume number
---@field musicVolume number
---@field ambienceVolume number
---@field musicEnabled boolean
---@field enabled boolean
---@field blocked boolean
---@field trainReferenceRms number
---@field trainReferencePeak number
---@field duck number
local checks_=0
local deviceReady_=false
local oldGains_={} ---@type table<string,number>
local settings_={sound=true,music=true,volume=.75,musicVolume=1.0,ambienceVolume=1.0,trainVolume=1.0}
local TRAIN_RMS,TRAIN_PEAK=.03,.15
local EPS=0.000001
---@param condition boolean
---@param message string
local function check(condition,message)
    checks_=checks_+1
    assert(condition,"[SoundscapeValidation] "..message)
end
---@return SoundscapeProbeDiagnostics
local function snapshot()
    return Soundscape.GetDiagnostics() --[[@as SoundscapeProbeDiagnostics]]
end
---@param frames integer
local function advance(frames)
    for _=1,frames do Soundscape.Update(.02) end
end
local function zeroOutputs()
    local data=snapshot()
    for _,kind in ipairs(KINDS) do
        check(math.abs(assert(data.channels[kind]).gain)<=EPS,"输出未静音："..kind)
    end
end
local function budget()
    local data=snapshot()
    local rms,peak=0.0,0.0
    for _,kind in ipairs(KINDS) do
        local channel=assert(data.channels[kind])
        check(channel.gain>=0 and channel.gain==channel.gain,"非法增益："..kind)
        if kind~="music" then
            rms=rms+channel.gain*.04
            peak=peak+channel.gain*.18
        end
    end
    -- 人群/雨声仍严格受列车预算约束；音乐是独立用户总线，不以“低到不可听”为通过标准。
    check(rms<=TRAIN_RMS*.20*settings_.volume+EPS,"人群/雨声总RMS预算超限")
    check(peak<=TRAIN_PEAK*.20*settings_.volume+EPS,"人群/雨声总peak预算超限")
    local music=assert(data.channels.music)
    check(music.gain>.65 and music.gain<=.75,"满档普通音乐没有独立可听增益或越过主音量")
    check(music.gain*.169983<.13,"普通音乐未保留广播/提示音峰值余量")
    local envRms,envPeak=Soundscape.GetEnvironmentBudget()
    local voiceGain=Soundscape.GetAnnouncementGain()
    check(envRms<=TRAIN_RMS*.12+EPS and envPeak<=TRAIN_PEAK*.12+EPS,"沿线环境预算超限")
    check(voiceGain>=.62*settings_.volume and voiceGain<=settings_.volume,
        "广播必须有清晰度保底且不越过主音量")
end
local function validate()
    deviceReady_=audio:IsInitialized() and audio:IsPlaying()
    print("[SoundscapeValidation] deviceInitialized="..tostring(audio:IsInitialized())
        .." devicePlaying="..tostring(audio:IsPlaying()).." deviceOutput=NOT_RUN")
    for _,kind in ipairs(KINDS) do
        check(cache:Exists(PATHS[kind]),"要求预下载本地素材："..PATHS[kind])
    end
    -- 即便设备可用也不发声；只检查真实Sound/SoundSource状态和增益。
    for _,soundType in ipairs(TYPES) do
        oldGains_[soundType]=audio:GetMasterGain(soundType)
        audio:SetMasterGain(soundType,0)
    end
    Soundscape.Init()
    Soundscape.SetSettings(settings_)
    Soundscape.SetContext("interior",0,40,true,true)
    Soundscape.SetTrainMix(TRAIN_RMS,TRAIN_PEAK,0,0)
    Soundscape.SetEnvironment({weather="rain",rainIntensity=.8,lampFactor=.6})
    advance(1) -- 所有paths本地，触发生产File/VectorBuffer/Sound:LoadWav解码。
    local decoded=snapshot()
    local loadedCount=0
    for _,kind in ipairs(KINDS) do
        local channel=assert(decoded.channels[kind])
        check(channel.ready,"生产模块未完成WAV解码："..kind)
        check(channel.path==PATHS[kind],"生产资源路径错误："..kind)
        check(decoded.errors[kind]==nil,"生产解码诊断错误："..kind)
    end
    for _,source in ipairs(audio:GetSoundSources()) do
        local soundType=source:GetSoundType()
        for _,expected in ipairs(TYPES) do
            if soundType==expected then
                local sound=source:GetSound()
                check(sound~=nil,"持久声源没有真实Sound："..expected)
                check(sound:GetDataSize()>0 and sound:GetFrequency()==22050,"实际PCM格式错误："..expected)
                check(sound:GetLength()>20 and sound:IsLooped(),"实际时长或循环标志错误："..expected)
                loadedCount=loadedCount+1
                print(string.format("[SoundscapeValidation] DECODED %s bytes=%d rate=%.0f duration=%.3f looped=%s",
                    expected,sound:GetDataSize(),sound:GetFrequency(),sound:GetLength(),tostring(sound:IsLooped())))
            end
        end
    end
    check(loadedCount==4,"生产声源数量不等于四层（音乐/站台/车厢/雨）")
    -- 无设备时仅用一次Update分配增益；不把IsPlaying=false的正常恢复计为错误。
    advance(deviceReady_ and 100 or 1)
    budget()
    local beforePause=snapshot()
    Soundscape.SetBlocked(true)
    zeroOutputs()
    local blocked=snapshot()
    for _,kind in ipairs(KINDS) do check(assert(blocked.channels[kind]).paused,"类别未暂停："..kind) end
    Soundscape.SetBlocked(false)
    local resumed=snapshot()
    for _,kind in ipairs(KINDS) do
        check(assert(resumed.channels[kind]).playCalls==assert(beforePause.channels[kind]).playCalls,
            "SetBlocked恢复直接重复Play："..kind)
    end
    if deviceReady_ then
        local stable=true
        for _,kind in ipairs(KINDS) do stable=stable and assert(resumed.channels[kind]).playing end
        if stable then
            advance(20)
            local after=snapshot()
            for _,kind in ipairs(KINDS) do
                check(assert(after.channels[kind]).playCalls==assert(resumed.channels[kind]).playCalls,
                    "运行中暂停/恢复后重复Play："..kind)
            end
            print("[SoundscapeValidation] resumeMonitor=PASS (device state only, not audible)")
        else print("[SoundscapeValidation] resumeMonitor=NOT_RUN reason=source-not-playing") end
    else print("[SoundscapeValidation] resumeMonitor=NOT_RUN reason=audio-device-unavailable") end
    settings_.music=false
    Soundscape.SetSettings(settings_)
    advance(1)
    local musicOff=snapshot()
    check(assert(musicOff.channels.music).paused and assert(musicOff.channels.music).gain==0,"独立音乐关闭失败")
    check(not assert(musicOff.channels.platform).paused and not assert(musicOff.channels.carriage).paused,
        "关闭音乐误暂停人群")
    check(musicOff.musicVolume==1,"音乐关闭丢失音量")
    settings_.music=true
    settings_.volume=0
    Soundscape.SetSettings(settings_)
    zeroOutputs()
    check(snapshot().masterVolume==0,"主音量0被默认值覆盖")
    settings_.volume=.75
    settings_.musicVolume=0
    settings_.ambienceVolume=0
    settings_.trainVolume=0
    Soundscape.SetSettings(settings_)
    -- 生产列车音量0通过AudioManager喂零reference；本探针不声称测了Train API。
    Soundscape.SetTrainMix(0,0,0,0)
    advance(1)
    zeroOutputs()
    local zeros=snapshot()
    check(zeros.musicVolume==0 and zeros.ambienceVolume==0,"分轨音量0丢失")
    local envRms,envPeak=Soundscape.GetEnvironmentBudget()
    check(envRms==0 and envPeak==0 and Soundscape.GetAnnouncementGain()>0,"无持续列车声时广播保底不可用")
    settings_.sound=false
    Soundscape.SetSettings(settings_)
    Soundscape.SetBlocked(true);Soundscape.SetBlocked(false)
    zeroOutputs()
    local muted=snapshot()
    for _,kind in ipairs(KINDS) do check(assert(muted.channels[kind]).paused,"总静音被解除暂停覆盖："..kind) end
    Soundscape.Shutdown()
    check(next(snapshot().channels)==nil,"Shutdown遗留声源引用")
    print(string.format("SOUNDSCAPE_VALIDATION_PASS checks=%d decoded=4 budget=PASS deviceOutput=NOT_RUN audible=NOT_RUN phone=NOT_RUN",checks_))
end
function Start()
    local ok,message=pcall(validate)
    -- 失败路径也释放生产模块与恢复类别主增益，不触碰用户存档。
    local cleanupOk,cleanupError=pcall(function()
        Soundscape.Shutdown()
        for soundType,gain in pairs(oldGains_) do audio:SetMasterGain(soundType,gain) end
    end)
    if not ok or not cleanupOk then
        local detail=tostring(not ok and message or cleanupError)
        print("SOUNDSCAPE_VALIDATION_FAILED "..detail)
        log:Write(LOG_ERROR,detail)
    end
    engine:Exit()
end
