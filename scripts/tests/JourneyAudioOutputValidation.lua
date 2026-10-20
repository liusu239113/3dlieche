-- 生产音频设备回归，沿用 RageAudioValidation 的 SDL disk/pcall/退出脚手架。
-- 不加载main、不读写玩家存档；PCM另行量化，不把IsPlaying当实际出声。
local Soundscape=require "audio.Soundscape"
local Announcements=require "audio.Announcements"
local Catalog=require "config.AnnouncementCatalog"
local checks_,frame_,failed_=0,0,false
local settings_={sound=true,music=true,volume=.75,musicVolume=.35,ambienceVolume=0,announcementVolume=.85,language="zh"}
---@type RailwayAnnouncements?
local announcements_=nil
local beforePause_,beforeMute_=0.0,0.0
local normalGain_,voiceProgress_,reentryVoiceProgress_=0.0,0.0,0.0
local startTime_=0.0
local sweep_=false
---@type RailwayAnnouncementDefinition[]
local recordings_={}
local recordingIndex_,recordingMax_,recordingStarted_=0,0.0,0.0
local TYPES={"FantasyRail.Music","FantasyRail.Crowd.Platform","FantasyRail.Crowd.Carriage","FantasyRail.Environment.Rain","FantasyRail.JourneyAnnouncements"}
local savedGains_={} ---@type table<string,number>
local function check(condition,message)
    checks_=checks_+1;assert(condition,"[JourneyAudioOutput] "..message)
end
local function initMusic()
    Soundscape.SetGameMode("normal");Soundscape.Init();Soundscape.SetSettings(settings_)
    Soundscape.SetContext("cab",1000,0,false,true)
    -- 最弱合法列车参考曾把普通音乐压为近零；不实际播放列车以隔离music-only输出。
    Soundscape.SetTrainMix(.0001,.0002,160,1)
end
local function createAnnouncements()
    if announcements_ then announcements_:Shutdown() end
    local instance=Announcements.new({language="zh",volume=.85})
    instance:SetSettings(settings_)
    announcements_=instance
end
local function mark(name)
    local music=Soundscape.GetDiagnostics()
    local a=announcements_ and announcements_:GetStatus()
    print(string.format("[JourneyAudioOutput] MARK %s frame=%d elapsed=%.3f gain=%.6f pos=%.3f calls=%d voice=%s voicePos=%.3f",
        name,frame_,time:GetElapsedTime()-startTime_,music.gain,music.channels.music.timePosition,
        music.channels.music.playCalls,a and a.activePath or "",a and a.timePosition or 0))
end
local function cleanup()
    if announcements_ then announcements_:Shutdown();announcements_=nil end
    Soundscape.Shutdown();Soundscape.SetGameMode("normal")
    for kind,gain in pairs(savedGains_) do audio:SetMasterGain(kind,gain) end
end
local function nextRecording()
    recordingIndex_=recordingIndex_+1;recordingMax_=0;recordingStarted_=time:GetElapsedTime()
    local definition=recordings_[recordingIndex_]
    if not definition then
        check(recordingIndex_==#recordings_+1,"正式录音设备扫描与真实交付清单长度不一致")
        print(string.format("JOURNEY_VOICE_SWEEP_PASS checks=%d recordings=%d actualDecoderProgress=PASS PCM=SDL_DISK humanListening=NOT_RUN phone=NOT_RUN",checks_,#recordings_))
        cleanup();engine:Exit();return
    end
    local a=assert(announcements_);a:Reset()
    check(a:Announce(definition.kind,definition.index>0 and definition.index or nil,1),"正式录音事件未接受")
    mark("sweep_"..definition.kind.."_"..definition.index)
end
function Start()
    local ok,message=pcall(function()
        for _,argument in ipairs(GetArguments()) do if argument=="-journey-voice-sweep" then sweep_=true end end
        engine:SetMaxFps(20);engine:SetMaxInactiveFps(20)
        check(audio:SetMode(50,44100,true,true) and audio:Play(),"真实设备未开始混音")
        check(audio:GetSampleSize()==4 and audio:GetMixRate()==44100 and audio:IsStereo(),"录制格式不是44100Hz stereo s16")
        for _,kind in ipairs(TYPES) do savedGains_[kind]=audio:GetMasterGain(kind);audio:SetMasterGain(kind,1) end
        startTime_=time:GetElapsedTime();initMusic();createAnnouncements()
        SubscribeToEvent("Update","JourneyAudioOutputUpdate")
        if sweep_ then
            settings_.music=false;Soundscape.SetSettings(settings_)
            local plan=Catalog.GetRecordingPlan()
            for _,definition in ipairs(plan) do
                if definition.generated then recordings_[#recordings_+1]=definition end
            end
            local coverage=Catalog.GetCoverage()
            check(#recordings_>0 and #recordings_==coverage.generatedChinese,"扫描清单与真实生成数量不一致")
            check(coverage.generationStatus=="complete" and #recordings_==#plan,
                "完整交付声明与扫描清单不一致")
            nextRecording()
        else mark("normal_music_only") end
    end)
    if not ok then failed_=true;print("JOURNEY_AUDIO_OUTPUT_FAILED "..tostring(message));cleanup();engine:Exit() end
end
---@param eventType string
---@param eventData UpdateEventData
function JourneyAudioOutputUpdate(eventType,eventData)
    if failed_ then return end
    local ok,message=pcall(function()
        frame_=frame_+1
        local a=assert(announcements_)
        if sweep_ then
            local definition=assert(recordings_[recordingIndex_])
            Soundscape.Update(.05);a:Update(.05)
            local status=a:GetStatus()
            if status.activePath==definition.zhPath then recordingMax_=math.max(recordingMax_,status.timePosition) end
            if recordingMax_>2 then
                print(string.format("[JourneyAudioOutput] VOICE_DECODE_PASS kind=%s index=%d elapsed=%.3f position=%.3f gain=%.5f path=%s",
                    definition.kind,definition.index,time:GetElapsedTime()-startTime_,recordingMax_,status.gain,status.activePath))
                nextRecording()
            else check(time:GetElapsedTime()-recordingStarted_<12,"正式录音未真实推进："..tostring(definition.zhPath)) end
            return
        end
        if frame_==60 then normalGain_=Soundscape.GetDiagnostics().gain;mark("normal_settled") end
        if frame_==80 then
            settings_.sound=false;Soundscape.SetSettings(settings_);a:SetSettings(settings_)
            beforeMute_=Soundscape.GetDiagnostics().channels.music.timePosition;mark("sound_off")
        elseif frame_==100 then
            check(math.abs(Soundscape.GetDiagnostics().channels.music.timePosition-beforeMute_)<.1,"静音后音乐相位未冻结")
            settings_.sound=true;Soundscape.SetSettings(settings_);a:SetSettings(settings_);mark("sound_resume")
        elseif frame_==140 then
            Soundscape.SetBlocked(true);a:SetBlocked(true)
            beforePause_=Soundscape.GetDiagnostics().channels.music.timePosition;mark("background")
        elseif frame_==160 then
            check(math.abs(Soundscape.GetDiagnostics().channels.music.timePosition-beforePause_)<.1,"后台音乐相位未冻结")
            Soundscape.SetBlocked(false);a:SetBlocked(false);mark("foreground")
        elseif frame_==200 then
            check(Soundscape.GetDiagnostics().channels.music.playCalls==1,"静音/后台恢复重播音乐")
            initMusic();createAnnouncements();mark("reinit_music")
        elseif frame_==260 then
            settings_.music=false;Soundscape.SetSettings(settings_)
            check(a:Announce("arrival",1,1),"重进后到站事件未接受");mark("arrival_after_reinit")
        elseif frame_==380 then
            mark("arrival_progress")
            a:SetBlocked(true);mark("voice_background")
        elseif frame_==400 then
            a:SetBlocked(false)
            check(a:GetStatus().queued==0 and not a:GetStatus().playing,"恢复补播过期广播")
            mark("voice_foreground_no_replay")
        elseif frame_==420 then
            createAnnouncements();a=assert(announcements_)
            check(a:Announce("arrival",1,1),"新实例被旧seen键阻挡");mark("new_instance_arrival")
        elseif frame_==540 then
            settings_.volume=0;Soundscape.SetSettings(settings_);a:SetSettings(settings_);mark("master_zero")
        elseif frame_==560 then
            check(a:GetStatus().queued==0 and not a:GetStatus().playing,"主音量0保留正在播放或过期广播")
            settings_.volume=.75;Soundscape.SetSettings(settings_);a:SetSettings(settings_);mark("master_resume_no_replay")
        elseif frame_==580 then
            check(a:Announce("arrival",2,1),"恢复后新到站事件未接受");mark("new_arrival_after_volume_resume")
        end
        Soundscape.Update(.05);a:Update(.05)
        local status=a:GetStatus()
        local arrival=assert(Catalog.Get("arrival",1)).zhPath
        if status.activePath==arrival and a.source then
            if frame_<400 then voiceProgress_=math.max(voiceProgress_,a.source:GetTimePosition())
            else reentryVoiceProgress_=math.max(reentryVoiceProgress_,a.source:GetTimePosition()) end
        end
        if frame_==700 then
            mark("done")
            check(normalGain_>.18,"普通默认音乐仍被高速duck/微弱列车预算压到近静音")
            check(voiceProgress_>2,"重进后OGG没有真实推进（不只检查头/IsPlaying）")
            check(reentryVoiceProgress_>2,"新广播实例OGG没有真实推进")
            check(next(a:GetStatus().errors)==nil,"广播加载错误")
            print(string.format("JOURNEY_AUDIO_OUTPUT_PASS checks=%d frames=%d normalGain=%.6f voiceProgress=%.3f reentryProgress=%.3f PCM=SDL_DISK humanListening=NOT_RUN phone=NOT_RUN",
                checks_,frame_,normalGain_,voiceProgress_,reentryVoiceProgress_))
            cleanup();engine:Exit()
        end
    end)
    if not ok then failed_=true;print("JOURNEY_AUDIO_OUTPUT_FAILED "..tostring(message));log:Write(LOG_ERROR,tostring(message));cleanup();engine:Exit() end
end
function Stop() cleanup() end
