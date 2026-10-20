-- 狂暴音频验收：沿用AudioOutputValidation的设备混音与pcall退出骨架。
-- 默认无设备也可验证真实WAV/OGG解码和事件状态；-rage-audio-device使用SDL disk/dummy驱动。
-- 绝不把SoundSource存在/统计峰值当作真人听感或手机解锁验收。
local RageAudio=require "audio.RageAudio"
local Soundscape=require "audio.Soundscape"
local checks_,frame_,failed_,device_=0,0,false,false
local settings_={sound=true,volume=.75,music=true,musicVolume=.35,ambienceVolume=0}
local ORIGIN=Vector3(0,0,0)
local sequence_=1000000
local savedGains_={} ---@type table<string,number>
local clock_=0.0
local function check(condition,message)
    checks_=checks_+1;assert(condition,"[RageAudioValidation] "..message)
end
---@param kind string
---@param position? Vector3
local function event(kind,position)
    sequence_=sequence_+1
    return {sequence=sequence_,position=position or ORIGIN,strength=90,kind=kind}
end
local function update(events,dt,position)
    RageAudio.Update(dt or .02,events or {},settings_,position or ORIGIN)
end
local function voices()
    local count=0
    for _,source in ipairs(audio:GetSoundSources()) do
        if source:GetSoundType()=="FantasyRail.Rage.Impacts" then count=count+1 end
    end
    return count
end
local function verify()
    RageAudio.Init();RageAudio.SetGameMode("rage")
    check(RageAudio.GetDiagnostics().readyClips==4,"4个生成WAV未真实解码")
    check(voices()==4,"不是固定4声源池")
    check(#RageAudio.GetPaths()==4,"媒体预载路径不完整")
    local hit=event("head_on")
    update({hit})
    local first=RageAudio.GetDiagnostics()
    check(first.started==1 and first.activeVoices==1,"真实撞车事件没有触发一次金属冲击")
    local nearGain=first.voices[1].gain
    check(nearGain>.30,"近处冲击仍过小")
    check(first.voices[1].frequency==44100,"音效传入了pitch倍数而非绝对Hz")
    update({hit})
    check(RageAudio.GetDiagnostics().started==1,"同一sequence被重复播放")
    update({})
    check(RageAudio.GetDiagnostics().started==1,"空队列凭统计值或帧数生成撞击")
    settings_.sound=false;update({event("air_strike")})
    check(RageAudio.GetDiagnostics().activeVoices==0,"总开关未立即停止撞击尾音")
    local mutedCount=RageAudio.GetDiagnostics().started
    settings_.sound=true;update({})
    check(RageAudio.GetDiagnostics().started==mutedCount,"解除静音补播历史事件")
    RageAudio.SetBlocked(true);update({event("landing")})
    check(RageAudio.GetDiagnostics().activeVoices==0,"后台/暂停仍发声")
    RageAudio.SetBlocked(false);update({})
    check(RageAudio.GetDiagnostics().started==mutedCount,"回到前台补播旧落地")
    RageAudio.SetGameMode("normal");update({event("head_on")})
    check(RageAudio.GetDiagnostics().activeVoices==0,"普通模式启用了狂暴音效")
    RageAudio.SetGameMode("rage");update({event("head_on",Vector3(180,0,0))},.25)
    local far=RageAudio.GetDiagnostics()
    check(far.activeVoices==1 and far.voices[1].gain<nearGain*.10,"远处接触没有距离衰减")
    RageAudio.SetGameMode("normal");RageAudio.SetGameMode("rage")
    local distantCount=RageAudio.GetDiagnostics().started
    update({event("head_on",Vector3(300,0,0))},.25)
    check(RageAudio.GetDiagnostics().started==distantCount,"240米外事件未剔除")
    RageAudio.Update(.25,{event("head_on")},settings_,nil)
    check(RageAudio.GetDiagnostics().started==distantCount,"listener丢失仍默认在原点播放")
    RageAudio.SetGameMode("normal");RageAudio.SetGameMode("rage")
    update({event("air_strike")},.25)
    check(RageAudio.GetDiagnostics().activeVoices==2,"真实撞飞未产生冲击与掠过双层")
    RageAudio.SetGameMode("normal");RageAudio.SetGameMode("rage")
    update({event("rear_end"),event("air_strike")},.25)
    check(RageAudio.GetDiagnostics().activeVoices==2,"同帧真实追尾+撞飞被金属冷却错误吞掉掠过")
    for _=1,20 do update({event("head_on"),event("landing"),event("air_strike")},.15) end
    local limited=RageAudio.GetDiagnostics()
    check(limited.activeVoices<=4 and voices()==4,"并发声源无界增长")
    check(limited.estimatedPeak<=limited.peakBudget*settings_.volume+.00001,"总撞击峰值预算越界")
    check(limited.dropped>0,"连续接触没有限频/语音上限")
    settings_.volume=0;update({event("head_on")})
    check(RageAudio.GetDiagnostics().activeVoices==0,"主音量0没有立即停音")
    settings_.volume=.75
    RageAudio.Shutdown()
    check(voices()==0,"Shutdown泄漏声源")
    RageAudio.Init();RageAudio.SetGameMode("rage")
    update({hit})
    check(RageAudio.GetDiagnostics().started==0,"Init重置去重序号而重播旧事件")
    RageAudio.Shutdown()
    Soundscape.SetGameMode("rage");Soundscape.Init();Soundscape.SetSettings(settings_)
    Soundscape.SetContext("cab",1000,0,false,true);Soundscape.SetTrainMix(.0001,.0002,160,1)
    for _=1,100 do Soundscape.Update(.02) end
    local music=Soundscape.GetDiagnostics()
    check(music.path=="audio/music/rage_ignition_loop.ogg" and music.channels.music.ready,"新OP未真实解码")
    check(music.gain>.20 and music.estimatedMusicRms>.02,"默认狂暴OP仍因列车预算/高速duck消失")
    check(music.title~="" and music.musicMixPolicy=="heroic_music_bus","HUD曲名/音乐总线诊断丢失")
    settings_.sound=false;Soundscape.SetSettings(settings_)
    check(Soundscape.GetDiagnostics().mutedReasonCode=="sound_off","用户静音原因不可诊断")
    settings_.sound=true;Soundscape.SetSettings(settings_)
    print(string.format("RAGE_AUDIO_STATE_PASS checks=%d generatedClips=4 decodedMusic=Vorbis sourcePool=4 muteSequenceDistancePeak=PASS",checks_))
end
local function cleanup()
    RageAudio.Shutdown();Soundscape.Shutdown();Soundscape.SetGameMode("normal")
    for soundType,gain in pairs(savedGains_) do audio:SetMasterGain(soundType,gain) end
end
function Start()
    local ok,message=pcall(function()
        for _,arg in ipairs(GetArguments()) do if arg=="-rage-audio-device" then device_=true end end
        for _,soundType in ipairs({"FantasyRail.Rage.Impacts","FantasyRail.Music"}) do
            savedGains_[soundType]=audio:GetMasterGain(soundType)
            audio:SetMasterGain(soundType,device_ and 1 or 0)
        end
        if device_ then
            engine:SetMaxFps(20);engine:SetMaxInactiveFps(20)
            check(audio:SetMode(50,44100,true,true),"设备输出初始化失败")
            check(audio:Play() and audio:IsPlaying(),"设备没有开始混音")
        end
        verify()
        if device_ then
            RageAudio.Init();RageAudio.SetGameMode("rage")
            SubscribeToEvent("Update","RageAudioValidationUpdate")
        end
    end)
    if not ok then failed_=true;print("RAGE_AUDIO_FAILED "..tostring(message));log:Write(LOG_ERROR,tostring(message)) end
    if failed_ or not device_ then cleanup();engine:Exit() end
end
---@param eventType string
---@param eventData UpdateEventData
function RageAudioValidationUpdate(eventType,eventData)
    local ok,message=pcall(function()
        frame_=frame_+1;clock_=clock_+eventData:GetFloat("TimeStep")
        local events={}
        if frame_==15 then events={event("head_on")} end
        if frame_==35 then events={event("air_strike")} end
        if frame_==55 then events={event("landing")} end
        -- 实际设备运行跨越静音与前后台，最终由SDL disk PCM另测RMS/peak。
        if frame_==75 then settings_.sound=false;Soundscape.SetSettings(settings_) end
        if frame_==95 then settings_.sound=true;Soundscape.SetSettings(settings_) end
        if frame_==115 then Soundscape.SetBlocked(true);RageAudio.SetBlocked(true) end
        if frame_==135 then Soundscape.SetBlocked(false);RageAudio.SetBlocked(false) end
        if frame_==165 then settings_.music=false;Soundscape.SetSettings(settings_) end
        if frame_==170 then events={event("air_strike")} end
        if frame_==190 then events={event("landing")} end
        if frame_==205 then RageAudio.SetBlocked(true) end
        update(events,.05);Soundscape.Update(.05)
        if frame_==30 or frame_==75 or frame_==95 or frame_==115 or frame_==135 or frame_==145 or frame_==165 or frame_==205 then
            local state=Soundscape.GetDiagnostics()
            print(string.format("[RageAudioValidation] frame=%d gain=%.5f playing=%s paused=%s calls=%d pos=%.3f reason=%s",
                frame_,state.gain,tostring(state.isPlaying),tostring(state.channels.music.paused),
                state.channels.music.playCalls,state.channels.music.timePosition,state.mutedReasonCode))
        end
        if frame_==225 then
            local music=Soundscape.GetDiagnostics()
            check(music.deviceInitialized and music.devicePlaying,"设备运行中断")
            check(music.channels.music.playCalls==1,"静音/前后台恢复重启音乐相位")
            check(music.channels.music.timePosition>5,"完整资源仅解析头，没有真正推进音乐解码器")
            print(string.format("RAGE_AUDIO_DEVICE_PASS checks=%d frames=%d seconds=%.3f position=%.3f calls=%d output=DEVICE_DRIVER audible=NOT_RUN phone=NOT_RUN",
                checks_,frame_,clock_,music.channels.music.timePosition,music.channels.music.playCalls))
            cleanup();engine:Exit()
        end
    end)
    if not ok then
        print("RAGE_AUDIO_FAILED "..tostring(message));log:Write(LOG_ERROR,tostring(message));cleanup();engine:Exit()
    end
end
function Stop() cleanup() end
