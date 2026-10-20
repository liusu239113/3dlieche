-- 狂暴音乐回归：基于 SoundscapeValidation 的 pcall/退出脚手架。
-- 真实引擎解码与单声源状态验证；类别主增益强制静音，不冒充设备听感验收。
local Soundscape=require "audio.Soundscape"
local NORMAL="audio/music/railway_journey_loop.wav"
local RAGE="audio/music/rage_ignition_loop.ogg"
local MUSIC_TYPE="FantasyRail.Music"
local TYPES={MUSIC_TYPE,"FantasyRail.Crowd.Platform","FantasyRail.Crowd.Carriage","FantasyRail.Environment.Rain"}
local savedGains_={} ---@type table<string,number>
local checks_=0
local settings_={sound=true,music=true,volume=.75,musicVolume=.65,ambienceVolume=.45}
local function check(condition,message)
    checks_=checks_+1
    assert(condition,"[RageMusicValidation] "..message)
end
local function snapshot() return Soundscape.GetDiagnostics() end
local function advance()
    for _=1,5 do Soundscape.Update(.02) end
end
---@return SoundSource
local function musicSource()
    local count=0
    ---@type SoundSource?
    local found=nil
    for _,source in ipairs(audio:GetSoundSources()) do
        if source:GetSoundType()==MUSIC_TYPE then count=count+1;found=source end
    end
    check(count==1,"必须只有一个音乐声源，实际="..tostring(count))
    return assert(found)
end
local function verify()
    for _,soundType in ipairs(TYPES) do
        savedGains_[soundType]=audio:GetMasterGain(soundType)
        audio:SetMasterGain(soundType,0)
    end
    check(cache:Exists(NORMAL),"普通曲素材缺失")
    check(cache:Exists(RAGE),"狂暴曲素材缺失")
    local paths=Soundscape.GetResourcePaths()
    local normalFound,rageFound=false,false
    for _,path in ipairs(paths) do normalFound=normalFound or path==NORMAL;rageFound=rageFound or path==RAGE end
    check(normalFound and rageFound,"预载接口必须同时包含两首音乐")
    Soundscape.SetGameMode("normal")
    Soundscape.Init()
    Soundscape.SetSettings(settings_)
    Soundscape.SetContext("cab",math.huge,0,false,false)
    advance()
    local normal=snapshot()
    check(normal.gameMode=="normal" and normal.channels.music.path==NORMAL,"普通模式没有保留原曲")
    check(normal.channels.music.ready and normal.errors.music==nil,"普通WAV未真实解码")
    local source=musicSource()
    check(not source:GetSound():IsCompressed(),"普通曲不应被替换为OGG")
    local calls=normal.channels.music.playCalls
    Soundscape.SetGameMode("normal")
    check(snapshot().channels.music.playCalls==calls,"重复选择相同模式重新Play")
    Soundscape.SetGameMode("rage")
    local stopped=snapshot()
    check(stopped.gameMode=="rage" and stopped.channels.music.path==RAGE,"切换没有立即选择狂暴路径")
    check(not stopped.channels.music.ready and stopped.channels.music.gain==0,"换曲前必须先停止旧曲并清零")
    check(not source:IsPlaying(),"狂暴新曲加载前旧曲仍在播放")
    check(musicSource()==source,"切换不应新建第二个音乐声源")
    advance()
    local rage=snapshot()
    check(rage.channels.music.ready and rage.errors.music==nil,"狂暴OGG未真实解码")
    check(source:GetSound():IsCompressed() and source:GetSound():IsLooped(),"狂暴曲不是循环Vorbis")
    check(source:GetSound():GetFrequency()==44100,"狂暴曲采样率错误")
    check(math.abs(source:GetSound():GetLength()-117.3)<.2,"狂暴循环时长错误")
    check(rage.channels.music.gain>0,"菜单音乐增益语义被破坏")
    check(rage.musicVolume==settings_.musicVolume and rage.masterVolume==settings_.volume,"切换覆盖用户音量")
    Soundscape.SetContext("cab",1000,0,false,true)
    Soundscape.SetTrainMix(0,0,65,1)
    for _=1,50 do Soundscape.Update(.02) end
    check(Soundscape.GetAnnouncementGain()>0,"狂暴曲使广播静音")
    local mixed=snapshot()
    check(mixed.channels.music.gain>.30,"狂暴OP仍被普通高速背景duck压到几乎听不见")
    check(mixed.channels.music.gain<=.60 and mixed.estimatedMusicPeak<.36,"音乐没有保留撞击广播峰值余量")
    Soundscape.SetTrainMix(.0001,.0002,160,1)
    advance()
    check(snapshot().channels.music.gain>.30,"微弱列车参考把狂暴音乐预算归零")
    Soundscape.SetBlocked(true)
    local beforePause=snapshot()
    Soundscape.SetGameMode("normal");Soundscape.Update(.02)
    local blocked=snapshot()
    check(blocked.blocked and blocked.channels.music.paused and blocked.channels.music.gain==0,"暂停切换解除静音")
    check(not blocked.channels.music.ready,"暂停期间不应加载并启动新曲")
    Soundscape.SetGameMode("rage");Soundscape.Update(.02)
    check(snapshot().channels.music.playCalls==beforePause.channels.music.playCalls,"暂停期间重复Play")
    Soundscape.SetBlocked(false);advance()
    check(snapshot().channels.music.ready,"解除暂停后狂暴音乐未加载")
    settings_.music=false;Soundscape.SetSettings(settings_)
    Soundscape.SetGameMode("normal");advance()
    local musicOff=snapshot()
    check(musicOff.channels.music.paused and musicOff.channels.music.gain==0,"音乐关闭后换曲仍发声")
    check(not musicOff.channels.platform.paused,"音乐开关影响环境声")
    settings_.music=true;settings_.volume=0;Soundscape.SetSettings(settings_)
    Soundscape.SetGameMode("rage");advance()
    check(snapshot().channels.music.gain==0 and snapshot().masterVolume==0,"总音量0被换曲覆盖")
    settings_.volume=.75;settings_.musicVolume=0;Soundscape.SetSettings(settings_)
    Soundscape.SetGameMode("normal");advance()
    check(snapshot().channels.music.gain==0 and snapshot().musicVolume==0,"音乐音量0被换曲覆盖")
    settings_.musicVolume=.65;settings_.sound=false;Soundscape.SetSettings(settings_)
    Soundscape.SetGameMode("rage");advance()
    check(snapshot().channels.music.paused and snapshot().channels.music.gain==0,"总静音后模式切换发声")
    check(musicSource()==source,"连续换曲泄漏音乐声源")
    Soundscape.Shutdown()
    check(next(snapshot().channels)==nil,"Shutdown遗留音乐通道")
    Soundscape.Init();Soundscape.SetSettings({sound=true,music=true,volume=.75,musicVolume=.65})
    Soundscape.Update(.02)
    check(snapshot().gameMode=="rage" and snapshot().channels.music.path==RAGE,"重建音频模块丢失显式模式")
    check(snapshot().channels.music.ready,"重建未加载已选择的狂暴曲")
    print(string.format("RAGE_MUSIC_VALIDATION_PASS checks=%d normal=WAV rage=Vorbis seconds=117.3 singleSource=PASS pauseMuteVolume=PASS deviceOutput=NOT_RUN audible=NOT_RUN phone=NOT_RUN",checks_))
end
function Start()
    local ok,message=pcall(verify)
    local cleaned,cleanupError=pcall(function()
        Soundscape.Shutdown()
        Soundscape.SetGameMode("normal")
        for soundType,gain in pairs(savedGains_) do audio:SetMasterGain(soundType,gain) end
    end)
    if not ok or not cleaned then
        local detail=tostring(not ok and message or cleanupError)
        print("RAGE_MUSIC_VALIDATION_FAILED "..detail)
        log:Write(LOG_ERROR,detail)
    end
    engine:Exit()
end
