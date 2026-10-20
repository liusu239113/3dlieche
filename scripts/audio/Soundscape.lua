-- 应用级音乐与人群环境：独立设置，持久声源，相位保持，列车优先预算。
-- 只播放真实项目素材；缺失时记录诊断，不用音乐或程序噪声冒充人群。
local Soundscape = {}
local GameConfig = require "config.GameConfig"
-- 普通曲不替换；狂暴曲为官方生成的原创176BPM动漫铁路冒险OP纯音乐。
local RAGE_MUSIC = "audio/music/rage_ignition_loop.ogg"
local RAGE_TITLE = "赤轨破晓 · Crimson Rail Ignition"
-- 素材实测：普通曲较狂暴OP低12.4dB，独立音乐总线补偿，不重写/正常化原资产。
local NORMAL_RMS, NORMAL_PEAK = .02589843, .16998291
local RAGE_RMS, RAGE_PEAK = .108382, .595764
---@type table<string,string>
local TYPES = { music="FantasyRail.Music", platform="FantasyRail.Crowd.Platform", carriage="FantasyRail.Crowd.Carriage", rain="FantasyRail.Environment.Rain" }
local PATHS = {
    music="audio/music/railway_journey_loop.wav",
    platform="audio/sfx/crowd/platform_loop.wav",
    carriage="audio/sfx/crowd/carriage_loop.wav",
    rain="audio/sfx/rail_rain_soft_loop.wav",
}
-- 素材离线交付上限，不是设备听感实测。RMS/peak 超标需先正常化再接入。
local CLIP_RMS, CLIP_PEAK = .04, .18
---@class RailwaySoundscapeLoop
---@field source SoundSource
---@field sound? Sound
---@field ownedSound? boolean WAV自建资源；OGG来自cache，不能Dispose共享资源
---@field buffer? VectorBuffer
---@field gain number
---@field requested boolean
---@field requestedAt number
---@field requestSerial integer
---@field retryAt number
---@field playCalls integer
---@field path string
---@type Node?
local root_=nil
---@type table<string,RailwaySoundscapeLoop>
local loops_={}
local enabled_,musicEnabled_,blocked_=true,true,false
local master_,musicVolume_,ambienceVolume_=.75,.35,.45
local playing_,camera_,stationDistance_,onboard_,doors_=false,"",math.huge,0.0,false
local trainRms_,trainPeak_,speed_,load_=0.0,0.0,0.0,0.0
local generation_,clock_=0,0.0
local rain_,night_,weather_=0.0,0.0,"clear"
local errors_={} ---@type table<string,string>
---@type string?
local requestedMode_=nil
local gameMode_="normal"

local function clamp(value,low,high) return math.max(low,math.min(high,value)) end
local function smooth(value,target,dt,response) return value+(target-value)*(1-math.exp(-dt*response)) end
local function paused(kind)
    return blocked_ or not enabled_ or master_<=0
        or (kind=="music" and (not musicEnabled_ or musicVolume_<=0))
        or (kind~="music" and ambienceVolume_<=0)
end
local function refreshState()
    for kind,entry in pairs(loops_) do
        if paused(kind) then
            entry.source:SetGain(0)
            audio:PauseSoundType(TYPES[kind])
        else
            local wasPaused=audio:IsSoundTypePaused(TYPES[kind])
            audio:ResumeSoundType(TYPES[kind])
            if wasPaused then entry.gain=0 end
            entry.source:SetGain(entry.gain*master_)
        end
    end
end
local function load(kind,entry)
    if entry.sound or entry.requested or clock_<entry.retryAt then return end
    local function decode()
        local ogg=entry.path:sub(-4):lower()==".ogg"
        if ogg then
            -- LoadOggVorbis(VectorBuffer)仅解析压缩头，缺少资源完整加载生命周期：
            -- 设备实测返回true/时长正确，但Play立即停止、timePosition永远0。
            -- cache加载会完成压缩解码器初始化；这条专用音乐资源仅设循环，不Dispose。
            local sound=cache:GetResource("Sound",entry.path) --[[@as Sound?]]
            if not sound or sound:GetLength()<=0 then errors_[kind]="OGG完整资源加载失败";return end
            sound:SetLooped(true)
            entry.sound,entry.buffer,entry.ownedSound=sound,nil,false
            entry.source:Play(sound,0,0)
            entry.playCalls=entry.playCalls+1
            errors_[kind]=nil
            print("[Soundscape] Ready "..kind.." / "..entry.path.." (complete resource decoder)")
            return
        end
        local file=cache:GetFile(entry.path) --[[@as File?]]
        if not file then errors_[kind]="素材不可读";return end
        file:Seek(0)
        local buffer=file:Read(file:GetSize());file:Dispose();buffer:Seek(0)
        local sound=Sound()
        local reader=tolua.cast(buffer,"Deserializer") --[[@as Deserializer]]
        if not sound:LoadWav(reader) then
            sound:Dispose();errors_[kind]="WAV解码失败";return
        end
        sound:SetLooped(true);sound:FixInterpolation()
        entry.sound,entry.buffer,entry.ownedSound=sound,buffer,true
        entry.source:Play(sound,0,0)
        entry.playCalls=entry.playCalls+1
        errors_[kind]=nil
        print("[Soundscape] Ready "..kind.." / "..entry.path)
    end
    if cache:Exists(entry.path) then decode();entry.retryAt=clock_+10;return end
    entry.requested=true;entry.requestedAt=clock_;entry.requestSerial=entry.requestSerial+1
    local generation,serial=generation_,entry.requestSerial
    cache:DownloadResources({entry.path},function(success)
        if generation~=generation_ or serial~=entry.requestSerial then return end
        entry.requested=false;entry.retryAt=clock_+10
        if success and cache:Exists(entry.path) then decode()
        else errors_[kind]="素材下载未完成，稍后重试" end
    end)
end
---@param id string
local function applyGameMode(id)
    gameMode_=id=="rage" and "rage" or "normal"
    local path=gameMode_=="rage" and RAGE_MUSIC or PATHS.music
    local entry=loops_.music
    if not entry or entry.path==path then return end
    -- 同一声源先硬停旧曲；序号失效旧异步下载，禁止晚到回调覆盖新选择。
    entry.requestSerial=entry.requestSerial+1
    entry.requested=false;entry.requestedAt=0;entry.retryAt=0
    entry.source:SetGain(0);entry.source:StopImmediate()
    if entry.sound and entry.ownedSound then entry.sound:Dispose() end
    entry.sound,entry.buffer,entry.ownedSound=nil,nil,false
    entry.path=path;entry.gain=0;errors_.music=nil
    print("[Soundscape] Music mode="..gameMode_.." / "..path)
end
local function selectedMode()
    return requestedMode_ or tostring(rawget(GameConfig,"GameMode") or "normal")
end
--- 主流程在模式选择变化时调用；Init 前调用也有效，重复设置不重启曲目。
--- 不改变总开关、独立音乐开关、主/音乐音量、暂停类别或菜单播放规则。
---@param id string
function Soundscape.SetGameMode(id)
    requestedMode_=id=="rage" and "rage" or "normal"
    applyGameMode(requestedMode_)
end
function Soundscape.Init()
    Soundscape.Shutdown()
    root_=Node();root_.name="RailwaySoundscape"
    for kind,path in pairs(PATHS) do
        local source=root_:CreateChild(kind):CreateComponent("SoundSource")
        source:SetSoundType(TYPES[kind]);source:SetDeclickEnabled(true)
        loops_[kind]={source=source,gain=0,requested=false,requestedAt=0,requestSerial=0,retryAt=0,playCalls=0,path=path}
    end
    applyGameMode(selectedMode())
    refreshState()
    print("[Soundscape] Music/crowd mixer ready; train has priority")
end
---@param settings table
function Soundscape.SetSettings(settings)
    enabled_,musicEnabled_=settings.sound~=false,settings.music~=false
    master_=clamp(tonumber(settings.volume) or .75,0,1)
    musicVolume_=clamp(tonumber(settings.musicVolume) or .35,0,1)
    ambienceVolume_=clamp(tonumber(settings.ambienceVolume) or .45,0,1)
    -- 音量0也冻结相位；每次幂等恢复专属类别，不能依赖旧布尔值发生变化。
    refreshState()
    for kind,entry in pairs(loops_) do
        if (kind=="music" and musicVolume_==0) or (kind~="music" and ambienceVolume_==0) then entry.gain=0 end
        entry.source:SetGain(paused(kind) and 0 or entry.gain*master_)
    end
end
---@param blocked boolean
function Soundscape.SetBlocked(blocked)
    if blocked_==blocked then return end
    blocked_=blocked;refreshState()
end
---@param cameraMode string
---@param stationDistance number
---@param onboard number
---@param doorsOpen boolean
---@param playing boolean
function Soundscape.SetContext(cameraMode,stationDistance,onboard,doorsOpen,playing)
    camera_,stationDistance_=cameraMode,math.max(0,stationDistance)
    onboard_,doors_,playing_=math.max(0,onboard),doorsOpen,playing
    if not playing then trainRms_,trainPeak_,speed_,load_=0,0,0,0 end
end
--- Environment.GetStatus 原样可传；night/lampFactor 只调雨声遮蔽，不添加夜间噪声循环。
---@param status table
function Soundscape.SetEnvironment(status)
    local rain=tonumber(status.rainIntensity) or tonumber(status.rain)
    if rain==nil then rain=status.rain==true and 1 or (status.weather=="rain" and 1 or 0) end
    local night=tonumber(status.night) or tonumber(status.lampFactor)
    if night==nil then night=status.night==true and 1 or 0 end
    rain_,night_=clamp(rain,0,1),clamp(night,0,1)
    weather_=status.weather or (rain_>0 and "rain" or "clear")
end
function Soundscape.GetResourcePaths()
    return {PATHS.music,PATHS.platform,PATHS.carriage,PATHS.rain,RAGE_MUSIC}
end
--- AudioManager 提供最强列车层的实际素材RMS×增益（未乘主音量）。
--- 仅人群/雨声共享列车优先预算；两种模式的音乐均是独立用户音乐总线。
--- 普通曲原先再乘 .32*.18 及列车20%预算，默认驾驶约-66dBFS。
---@param rms number
---@param peak number
---@param speed number
---@param throttleLoad number
function Soundscape.SetTrainMix(rms,peak,speed,throttleLoad)
    trainRms_,trainPeak_,speed_,load_=math.max(0,rms),math.max(0,peak),math.abs(speed),clamp(throttleLoad,0,1)
end
---@return number
function Soundscape.GetBackgroundDuck()
    if not playing_ then return 1 end
    return clamp(1-.62*clamp(speed_/65,0,1)-.20*load_,.18,1)
end
--- 到站广播是人声提示，必须盖过机组噪声；这里只做轻微避让，
--- 不套用背景音乐的强 duck。素材实测 RMS -15dB、peak -1dB。
---@return number
function Soundscape.GetAnnouncementGain()
    if blocked_ or not enabled_ or master_<=0 then return 0 end
    -- 广播独立音量仍受主音量约束；不能让“声音0”只静音乐而广播继续出声。
    if not playing_ or trainRms_<=.000001 or trainPeak_<=.000001 then return .62*master_ end
    return (.62+.38*Soundscape.GetBackgroundDuck())*master_
end
---@return number,number
function Soundscape.GetEnvironmentBudget()
    return trainRms_*.12,trainPeak_*.12
end
---@param dt number
function Soundscape.Update(dt)
    if not root_ then return end
    applyGameMode(selectedMode())
    local step=blocked_ and 0 or clamp(dt,0,.25);clock_=clock_+step
    local interior=camera_=="passenger" or camera_=="carriage" or camera_=="interior"
    local cab=camera_=="cab" or camera_=="cab_window" or camera_=="copilot" or camera_=="instruments"
    local near=clamp(1-stationDistance_/200,0,1)
    local lowSpeed=1-clamp(speed_/45,0,1)
    local crowd=clamp(onboard_/12,0,1)
    local duck=Soundscape.GetBackgroundDuck()
    local rageMusic=gameMode_=="rage"
    local targets={
        -- 两首曲目都不依赖列车RMS/环境duck；普通资产低12.4dB，用感知音量曲线补偿。
        -- 主音量保持线性，音乐滑杆采用等功率响应（全范围单调）；满档普通曲peak贡献<=.17。
        music=rageMusic and math.min(.80,musicVolume_*(playing_ and .95 or .90)*(1-.10*clamp(speed_/160,0,1)))
            or math.sqrt(musicVolume_)*(playing_ and .98 or .95)*(1-.05*clamp(speed_/160,0,1)),
        platform=playing_ and ambienceVolume_*.20*near*lowSpeed*(interior and (doors_ and .45 or .08) or cab and .18 or 1)*duck or 0,
        carriage=playing_ and ambienceVolume_*.13*crowd*(interior and 1 or cab and .24 or (doors_ and near*.18 or 0))*duck or 0,
        rain=playing_ and ambienceVolume_*.45*rain_*(interior and (doors_ and .38 or .16) or cab and .25 or 1)*(1-.12*night_)*duck or 0,
    }
    local rms,peak=0.0,0.0
    for kind,entry in pairs(loops_) do
        if entry.requested and clock_-entry.requestedAt>12 then
            entry.requested=false;entry.requestSerial=entry.requestSerial+1;entry.retryAt=clock_+10
            errors_[kind]="下载回调超时，稍后重试"
        end
        local target=paused(kind) and 0 or targets[kind]
        if target>0 then load(kind,entry) end
        entry.gain=paused(kind) and 0 or smooth(entry.gain,target,step,target>entry.gain and 2.2 or 8)
        if entry.sound and kind~="music" then
            rms=rms+entry.gain*CLIP_RMS;peak=peak+entry.gain*CLIP_PEAK
        end
    end
    -- 立即向下限幅，避免减油/降低列车音量后缓慢淡出的一帧背景反盖列车。
    local hasTrainReference=trainRms_>.000001 and trainPeak_>.000001
    local budgetRms=playing_ and hasTrainReference and trainRms_*.20 or .014
    local budgetPeak=playing_ and hasTrainReference and trainPeak_*.20 or .065
    local scale=math.min(1,budgetRms/math.max(rms,.000001),budgetPeak/math.max(peak,.000001))
    for kind,entry in pairs(loops_) do
        if kind~="music" then entry.gain=entry.gain*scale end
        entry.source:SetGain(paused(kind) and 0 or entry.gain*master_)
        if entry.sound and not paused(kind) and not entry.source:IsPlaying() then
            entry.source:Play(entry.sound,0,entry.gain*master_)
            entry.playCalls=entry.playCalls+1
        end
    end
end
function Soundscape.GetDiagnostics()
    local channels={}
    for kind,entry in pairs(loops_) do
        channels[kind]={path=entry.path,ready=entry.sound~=nil,gain=entry.source:GetGain(),
            playing=entry.source:IsPlaying(),paused=audio:IsSoundTypePaused(TYPES[kind]),
            playCalls=entry.playCalls,timePosition=entry.source:GetTimePosition(),
            frequency=entry.source:GetFrequency(),sampleRate=entry.sound and entry.sound:GetFrequency() or 0,
            duration=entry.sound and entry.sound:GetLength() or 0,requested=entry.requested}
    end
    local music=loops_.music
    local gain=music and music.source:GetGain() or 0
    local isPlaying=music~=nil and music.source:IsPlaying()
    local reason,reasonCode="",""
    if not enabled_ then reason,reasonCode="声音已关闭","sound_off"
    elseif not musicEnabled_ then reason,reasonCode="音乐已关闭","music_off"
    elseif master_<=0 then reason,reasonCode="主音量为0","master_zero"
    elseif musicVolume_<=0 then reason,reasonCode="音乐音量为0","music_zero"
    elseif blocked_ then reason,reasonCode="暂停或应用不在前台","blocked"
    elseif not audio:IsInitialized() then reason,reasonCode="音频设备未就绪，请点击声音按钮解锁","device_uninitialized"
    elseif not audio:IsPlaying() then reason,reasonCode="音频输出未启动，请点击声音按钮解锁","device_stopped"
    elseif audio:GetMasterGain(TYPES.music)<=0 or audio:GetMasterGain(SOUND_MASTER)<=0 then
        reason,reasonCode="音频总线已静音","bus_muted"
    elseif errors_.music then reason,reasonCode=errors_.music,"load_error"
    elseif not music or not music.sound then reason,reasonCode="音乐正在载入","loading"
    elseif not isPlaying then reason,reasonCode="音乐播放未启动","source_stopped" end
    return {musicEnabled=musicEnabled_,enabled=enabled_,blocked=blocked_,masterVolume=master_,gameMode=gameMode_,
        title=gameMode_=="rage" and RAGE_TITLE or "铁路旅途",path=music and music.path or "",
        isPlaying=isPlaying,gain=gain,mutedReason=reason,mutedReasonCode=reasonCode,
        deviceInitialized=audio:IsInitialized(),devicePlaying=audio:IsPlaying(),
        estimatedMusicRms=gain*(gameMode_=="rage" and RAGE_RMS or NORMAL_RMS),
        estimatedMusicPeak=gain*(gameMode_=="rage" and RAGE_PEAK or NORMAL_PEAK),
        musicMixPolicy=gameMode_=="rage" and "heroic_music_bus" or "independent_music_bus",
        musicVolume=musicVolume_,ambienceVolume=ambienceVolume_,contextPlaying=playing_,
        camera=camera_,stationDistance=stationDistance_,onboard=onboard_,doorsOpen=doors_,
        rainIntensity=rain_,night=night_,weather=weather_,continuousTrainLoops=false,
        trainReferenceRms=trainRms_,trainReferencePeak=trainPeak_,duck=Soundscape.GetBackgroundDuck(),
        channels=channels,errors=errors_,audibleValidated=false}
end
function Soundscape.Shutdown()
    generation_=generation_+1
    for _,entry in pairs(loops_) do
        entry.source:StopImmediate();entry.source:Remove();entry.source:Dispose()
    end
    if root_ then root_:RemoveAllChildren();root_:Dispose() end
    for _,entry in pairs(loops_) do if entry.sound and entry.ownedSound then entry.sound:Dispose() end end
    root_,loops_=nil,{}
    for _,kind in pairs(TYPES) do audio:ResumeSoundType(kind) end
    errors_={};clock_=0
    playing_,camera_,stationDistance_,onboard_,doors_=false,"",math.huge,0,false
    blocked_=false
    trainRms_,trainPeak_,speed_,load_=0,0,0,0
    rain_,night_,weather_=0,0,"clear"
end
return Soundscape
