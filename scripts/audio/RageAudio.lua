-- 狂暴真实事件音效：不合成、不轮询碰撞计数、不重播静音期间积压事件。
-- SoundSource为二维输出，依据世界接触点/当前listener手动衰减，避免与相机listener双重衰减。
local RageAudio = {}
local SOUND_TYPE = "FantasyRail.Rage.Impacts"
local MAX_VOICES, MAX_STARTS = 4, 3
local PEAK_BUDGET = .42 -- 四个并发声源的保守线性峰值和（未乘用户主音量）
local PATHS = {
    metalA="audio/sfx/rage/rage_metal_impact_a.wav",
    metalB="audio/sfx/rage/rage_metal_impact_b.wav",
    whoosh="audio/sfx/rage/rage_launch_whoosh.wav",
    landing="audio/sfx/rage/rage_landing_scrape.wav",
}
local PEAKS = {metalA=.471131,metalB=.465607,whoosh=.418732,landing=.497315}
local KINDS = {head_on="metal",rear_end="metal",merge="metal",air_strike="metal",landing="landing"}
local COOLDOWNS = {metal=.12,whoosh=.25,landing=.28}
---@class RailwayRageAudioEvent
---@field sequence number 进程内单调递增，来自DrainImpactEvents，不是累计统计
---@field position Vector3 世界接触点，米
---@field strength number 相对接触速度/落地法向速度，米每秒
---@field kind string head_on/rear_end/merge/air_strike/landing
---@class RailwayRageClip
---@field sound? Sound
---@field buffer? VectorBuffer
---@field requested boolean
---@field serial integer
---@field requestedAt number
---@field retryAt number
---@class RailwayRageVoice
---@field source SoundSource
---@field clip string
---@field position Vector3
---@field baseGain number
---@field outputGain number
---@field sequence number
---@type Node?
local root_=nil
---@type RailwayRageVoice[]
local voices_={}
---@type table<string,RailwayRageClip>
local clips_={}
local errors_={} ---@type table<string,string>
local nextAt_={} ---@type table<string,number>
local clock_,generation_,lastSequence_=0.0,0,0
local mode_,blocked_,enabled_,volume_,effectVolume_="normal",false,true,.75,1.0
local tokens_,metalIndex_,started_,dropped_,consumed_=4.0,0,0,0,0
local listener_=Vector3(0,0,0)
local hasListener_=false
local function clamp(x,a,b) return math.max(a,math.min(b,x)) end
local function finite(value)
    return type(value)=="number" and value==value and value>-math.huge and value<math.huge
end
local function permitted()
    return mode_=="rage" and enabled_ and not blocked_ and volume_>0 and effectVolume_>0 and hasListener_
end
local function stopVoices()
    for _,voice in ipairs(voices_) do
        voice.source:SetGain(0);voice.source:StopImmediate()
        voice.clip="";voice.outputGain=0
    end
end
local function distanceGain(position)
    local dx,dy,dz=position.x-listener_.x,position.y-listener_.y,position.z-listener_.z
    local distance=math.sqrt(dx*dx+dy*dy+dz*dz)
    if distance>=240 then return 0 end
    local inverse=1/(1+(distance/38)^2)
    return inverse*clamp((240-distance)/60,0,1)
end
local function load(key,entry)
    if entry.sound or entry.requested or clock_<entry.retryAt then return end
    local path=PATHS[key]
    local function decode()
        local file=cache:GetFile(path) --[[@as File?]]
        if not file then errors_[key]="素材不可读："..path;return end
        file:Seek(0)
        local buffer=file:Read(file:GetSize());file:Dispose();buffer:Seek(0)
        local sound=Sound()
        if not sound:LoadWav(tolua.cast(buffer,"Deserializer") --[[@as Deserializer]] ) or sound:GetLength()<=0 then
            sound:Dispose();errors_[key]="WAV解码失败："..path;return
        end
        sound:SetLooped(false);sound:FixInterpolation()
        entry.sound,entry.buffer=sound,buffer
        errors_[key]=nil
        print("[RageAudio] Ready "..key.." / "..path)
    end
    entry.retryAt=clock_+10
    if cache:Exists(path) then decode();return end
    entry.requested=true;entry.requestedAt=clock_;entry.serial=entry.serial+1
    local generation,serial=generation_,entry.serial
    cache:DownloadResources({path},function(success)
        if generation~=generation_ or serial~=entry.serial then return end
        entry.requested=false;entry.retryAt=clock_+10
        if success and cache:Exists(path) then decode()
        else errors_[key]="素材下载未完成："..path end
    end)
end
local function updateVoiceGains()
    local sum=0.0
    for _,voice in ipairs(voices_) do
        if voice.clip~="" and voice.source:IsPlaying() then
            voice.outputGain=permitted() and voice.baseGain*distanceGain(voice.position)*effectVolume_ or 0
            sum=sum+voice.outputGain*(PEAKS[voice.clip] or .50)
        else voice.clip="";voice.outputGain=0 end
    end
    local scale=math.min(1,PEAK_BUDGET/math.max(.000001,sum))
    for _,voice in ipairs(voices_) do
        voice.outputGain=voice.outputGain*scale*volume_
        voice.source:SetGain(voice.outputGain)
    end
end
---@param scene? Scene 调用兼容；不持有、不释放外部场景。自建Node由模块强持有。
function RageAudio.Init(scene)
    RageAudio.Shutdown()
    root_=Node();root_.name="RailwayRageAudio"
    for _=1,MAX_VOICES do
        local source=root_:CreateChild("Impact"):CreateComponent("SoundSource")
        source:SetSoundType(SOUND_TYPE);source:SetDeclickEnabled(true)
        voices_[#voices_+1]={source=source,clip="",position=Vector3(0,0,0),baseGain=0,outputGain=0,sequence=0}
    end
    for key in pairs(PATHS) do
        local clip={requested=false,serial=0,requestedAt=0,retryAt=0}
        clips_[key]=clip;load(key,clip)
    end
    print("[RageAudio] Real impacts ready; voices<=4, peak budget=.42, no synthetic fallback")
end
---@param id string
function RageAudio.SetGameMode(id)
    local mode=id=="rage" and "rage" or "normal"
    if mode_==mode then return end
    mode_=mode;stopVoices();nextAt_={};tokens_=4
end
---@param blocked boolean
function RageAudio.SetBlocked(blocked)
    blocked_=blocked
    if blocked then stopVoices() end
end
---@param settings table
function RageAudio.SetSettings(settings)
    enabled_=settings.sound~=false
    volume_=clamp(tonumber(settings.volume) or .75,0,1)
    effectVolume_=clamp(tonumber(settings.effectsVolume) or 1,0,1)
    if not enabled_ or volume_<=0 or effectVolume_<=0 then stopVoices()
    else updateVoiceGains() end
end
---@param key string
---@param group string
---@param event RailwayRageAudioEvent
---@param gain number
---@return boolean
local function startVoice(key,group,event,gain)
    if clock_<(nextAt_[group] or 0) or tokens_<1 then return false end
    local clip=clips_[key]
    if not clip or not clip.sound then return false end
    if distanceGain(event.position)<.004 then return false end
    for _,voice in ipairs(voices_) do
        if voice.clip=="" or not voice.source:IsPlaying() then
            voice.clip,voice.position,voice.baseGain,voice.sequence=key,event.position,gain,event.sequence
            -- 频率传0=素材原速；绝不能传.95一类pitch倍率，后者会变成.95Hz。
            voice.source:Play(clip.sound,0,0)
            nextAt_[group]=clock_+COOLDOWNS[group]
            tokens_=tokens_-1;started_=started_+1
            return true
        end
    end
    return false -- 不抢占仍在播放的金属尾音，避免无限语音与硬截断。
end
--- 主流程每帧消费一次Traffic.DrainImpactEvents(32)并传入。空数组只更新现有尾音，不生成事件。
--- muted/blocked/normal下仍消费sequence，解除后不补播；listener缺失也不默认在原点播放。
---@param dt number
---@param events RailwayRageAudioEvent[]
---@param settings? table
---@param listenerPosition? Vector3
function RageAudio.Update(dt,events,settings,listenerPosition)
    if not root_ then return end
    local step=finite(dt) and clamp(dt,0,.25) or 0
    clock_=clock_+step;tokens_=math.min(4,tokens_+step*7)
    hasListener_=listenerPosition~=nil
    if listenerPosition then listener_=listenerPosition end
    if settings then RageAudio.SetSettings(settings) end
    for key,entry in pairs(clips_) do
        if entry.requested and clock_-entry.requestedAt>12 then
            entry.serial=entry.serial+1;entry.requested=false;entry.retryAt=clock_+10
            errors_[key]="下载回调超时"
        end
        if mode_=="rage" then load(key,entry) end
    end
    local starts=0
    for index,event in ipairs(events or {}) do
        if index>32 then break end
        if finite(event.sequence) and event.sequence>lastSequence_ then
            lastSequence_=event.sequence;consumed_=consumed_+1
            local group=KINDS[event.kind]
            if permitted() and group and finite(event.strength) and event.position and starts<MAX_STARTS then
                local speed=clamp(event.strength,0,140)
                local key=group
                if group=="metal" then metalIndex_=metalIndex_+1;key=metalIndex_%2==1 and "metalA" or "metalB" end
                local amount=math.sqrt(clamp(speed/(group=="landing" and 35 or 90),0,1))
                local gain=.30+.48*amount
                local played=startVoice(key,group,event,gain)
                if played then starts=starts+1 else dropped_=dropped_+1 end
                -- air_strike是实接触后撞飞，不使用飞车数量或统计值臆造掠过。
                -- 同一帧rear_end/head_on已触发金属时，air_strike仍可播放独立掠过层。
                if event.kind=="air_strike" and starts<MAX_STARTS then
                    if startVoice("whoosh","whoosh",event,.36+.22*amount) then starts=starts+1 end
                end
            else dropped_=dropped_+1 end
        end
    end
    updateVoiceGains()
end
function RageAudio.GetPaths()
    return {PATHS.metalA,PATHS.metalB,PATHS.whoosh,PATHS.landing}
end
function RageAudio.GetResourcePaths() return RageAudio.GetPaths() end
function RageAudio.GetDiagnostics()
    local voices={}
    local peak,active,ready=0.0,0,0
    for _,voice in ipairs(voices_) do
        local playing=voice.source:IsPlaying()
        if playing then active=active+1 end
        peak=peak+voice.outputGain*(PEAKS[voice.clip] or 0)
        voices[#voices+1]={path=PATHS[voice.clip] or "",sequence=voice.sequence,playing=playing,
            gain=voice.source:GetGain(),frequency=voice.source:GetFrequency()}
    end
    for _,clip in pairs(clips_) do if clip.sound then ready=ready+1 end end
    return {initialized=root_~=nil,gameMode=mode_,enabled=enabled_,blocked=blocked_,volume=volume_,
        readyClips=ready,voices=voices,activeVoices=active,maxVoices=MAX_VOICES,peakBudget=PEAK_BUDGET,
        estimatedPeak=peak,started=started_,dropped=dropped_,consumed=consumed_,lastSequence=lastSequence_,
        hasListener=hasListener_,errors=errors_,deviceInitialized=audio:IsInitialized(),
        devicePlaying=audio:IsPlaying(),audibleValidated=false}
end
function RageAudio.Shutdown()
    generation_=generation_+1
    stopVoices()
    -- Node:Dispose不保证外部Lua voice引用持有的Component立即析构；显式摘除并释放声源。
    for _,voice in ipairs(voices_) do voice.source:Remove();voice.source:Dispose() end
    if root_ then root_:RemoveAllChildren();root_:Dispose() end
    for _,clip in pairs(clips_) do if clip.sound then clip.sound:Dispose() end end
    root_,voices_,clips_=nil,{},{}
    errors_,nextAt_={},{}
    clock_,tokens_,metalIndex_,started_,dropped_,consumed_=0,4,0,0,0,0
    blocked_,hasListener_=false,false
    -- lastSequence保持进程单调，Init/Shutdown不能让旧队列再次发声；模式由主显式选择。
end
return RageAudio
