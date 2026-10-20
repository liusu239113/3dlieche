-- 有界广播事件队列：目标站索引、去重、下载超时、暂停/读档/换向清队列。
-- Caption 与 voiced 分离：字幕存在不代表已录制了该站语音。
local Catalog = require "config.AnnouncementCatalog"
local Soundscape = require "audio.Soundscape"

---@class RailwayAnnouncementJob
---@field definition RailwayAnnouncementDefinition
---@field clips string[]
---@field index integer
---@field created number
---@field waitingSince number
---@field key string

---@class RailwayAnnouncements
---@field root Node?
---@field source SoundSource?
---@field queue RailwayAnnouncementJob[]
---@field sounds table<string,Sound>
---@field pending table<string,number>
---@field retryAt table<string,number>
---@field errors table<string,string>
---@field seen table<string,boolean>
---@field clock number
---@field generation integer
---@field requestSerial integer
---@field language string
---@field volume number
---@field masterVolume number
---@field enabled boolean
---@field blocked boolean
---@field stopped boolean
---@field direction number
---@field lastDeparture number
---@field activeUntil number
---@field activePath string
---@field caption string
---@field currentText string
---@field lastCaption string
---@field lastEnglishCaption string
---@field lastEvent table
---@field accepted integer
---@field played integer
---@field skipped integer
---@field duplicates integer
local Announcements = {}
Announcements.__index = Announcements
local SOUND_TYPE = "FantasyRail.JourneyAnnouncements"

local function clamp(value) return math.max(0,math.min(1,tonumber(value) or 0)) end

---@param options? table
---@return RailwayAnnouncements
function Announcements.new(options)
    local self=setmetatable({},Announcements) ---@type RailwayAnnouncements
    self:init(options or {})
    return self --[[@as RailwayAnnouncements]]
end
function Announcements:init(options)
    self.root=Node();self.root.name="RailwayJourneyAnnouncements"
    self.source=self.root:CreateChild("Voice"):CreateComponent("SoundSource")
    self.source:SetSoundType(SOUND_TYPE);self.source:SetDeclickEnabled(true)
    self.queue,self.sounds,self.pending,self.retryAt,self.errors,self.seen={},{},{},{},{},{}
    self.clock,self.generation,self.requestSerial=0,1,0
    -- 广播默认接近满档：素材本身已归一化到 -15dB RMS，再压低就听不清了。
    self.language,self.volume,self.enabled=options.language or "both",clamp(options.volume or .85),options.enabled~=false
    self.masterVolume=1
    self.blocked,self.stopped=false,false
    self.direction,self.lastDeparture,self.activeUntil,self.activePath=0,0,0,""
    self.caption,self.currentText,self.lastCaption,self.lastEnglishCaption="","","",""
    self.lastEvent={};self.accepted,self.played,self.skipped,self.duplicates=0,0,0,0
end

---@return string[]
function Announcements.GetResourcePaths() return Catalog.GetResourcePaths() end
---@param kind string
---@param index? number
---@return string,string
function Announcements.GetCaption(kind,index)
    local definition=Catalog.Get(kind,index)
    return definition and definition.text or "",definition and definition.englishText or ""
end

function Announcements:Reset()
    if self.source then self.source:StopImmediate() end
    self.queue,self.seen={},{}
    self.activePath,self.activeUntil="",0
    self.direction,self.lastDeparture=0,0
    self.caption,self.currentText,self.lastCaption,self.lastEnglishCaption="","","",""
    self.lastEvent={}
end
function Announcements:Stop() self:Reset() end
-- 暂停/静音只丢弃过期播放，不清除本区间去重；恢复后不能重放相同站事件。
function Announcements:DiscardPlayback()
    local seen,direction,departure=self.seen,self.direction,self.lastDeparture
    self:Reset()
    self.seen,self.direction,self.lastDeparture=seen,direction,departure
end
---@param blocked boolean
function Announcements:SetBlocked(blocked)
    if blocked==self.blocked then return end
    self.blocked=blocked
    if blocked then self:DiscardPlayback() end
    if self.source then self.source:SetGain(blocked and 0 or self.volume*Soundscape.GetAnnouncementGain()) end
end
---@param volume number
function Announcements:SetVolume(volume)
    local value=clamp(volume)
    if value==0 and self.volume~=0 then self:DiscardPlayback() end
    self.volume=value
    if self.source then self.source:SetGain((self.enabled and not self.blocked) and value*Soundscape.GetAnnouncementGain() or 0) end
end
---@param language string
function Announcements:SetLanguage(language)
    if language~="zh" and language~="en" and language~="both" and language~="off" then return end
    if language~=self.language then self:Reset();self.language=language end
end
---@param settings table
function Announcements:SetSettings(settings)
    local enabled=settings.sound~=false and settings.enabled~=false
    if enabled~=self.enabled then self.enabled=enabled;if not enabled then self:DiscardPlayback() end end
    -- 应用设置包含announcementVolume时，volume是主音量；旧独立实例的volume参数仍是广播音量。
    if settings.announcementVolume~=nil then
        self.masterVolume=clamp(settings.volume==nil and self.masterVolume or settings.volume)
        if self.masterVolume==0 then self:DiscardPlayback() end
    end
    self:SetVolume(settings.announcementVolume or settings.volume or self.volume)
    self:SetLanguage(settings.announcementLanguage or settings.broadcastLanguage or settings.language or self.language)
end

---@param path string
function Announcements:Load(path)
    if self.sounds[path] or self.pending[path] or self.clock<(self.retryAt[path] or 0) then return end
    self.requestSerial=self.requestSerial+1
    local request,generation=self.requestSerial,self.generation
    self.pending[path]=request;self.errors[path]=nil
    local function finished(resource)
        if self.stopped or generation~=self.generation or self.pending[path]~=request then return end
        self.pending[path]=nil
        if resource then
            local sound=resource --[[@as Sound]]
            if sound:GetLength()>0 then self.sounds[path]=sound;self.errors[path]=nil;return end
        end
        self.errors[path]="音频不可用；本条跳过，稍后事件可重试"
        self.retryAt[path]=self.clock+10
        print("[Announcements] Missing/invalid "..path)
    end
    if cache:Exists(path) then finished(cache:GetResource("Sound",path));return end
    cache:GetResourceAsync("Sound",path,finished)
end

--- bool 表示接受了有效事件，不表示该站中文/英文语音已经录制。第二返回值始终为原创中文字幕。
--- index 是目标站；同方向新 departure 目标开启新站区间，换向自动 Reset。
---@param kind string
---@param index? number
---@param direction? number
---@return boolean,string
function Announcements:Announce(kind,index,direction)
    local definition=Catalog.Get(kind,index)
    if not definition or self.stopped or not self.enabled or self.blocked or self.language=="off" then return false,"" end
    local travelDirection=direction and (direction<0 and -1 or 1) or self.direction
    if self.direction~=0 and travelDirection~=0 and travelDirection~=self.direction then self:Reset() end
    self.direction=travelDirection
    if definition.kind=="departure" and definition.index~=self.lastDeparture then
        self.seen={};self.lastDeparture=definition.index
    end
    local key=definition.kind..":"..definition.index..":"..travelDirection
    if self.seen[key] then self.duplicates=self.duplicates+1;return false,definition.text end
    self.seen[key]=true
    self.caption,self.currentText,self.lastCaption=definition.text,definition.text,definition.text
    self.lastEnglishCaption=definition.englishText
    local clips={definition.chime}
    local voicedZh=(self.language=="zh" or self.language=="both") and definition.zhPath~=nil
    local voicedEn=(self.language=="en" or self.language=="both") and definition.enPath~=nil
    if voicedZh then clips[#clips+1]=assert(definition.zhPath) end
    if voicedEn then clips[#clips+1]=assert(definition.enPath) end
    self.lastEvent={kind=definition.kind,index=definition.index,direction=travelDirection,
        voiced=voicedZh or voicedEn,voicedZh=voicedZh,voicedEn=voicedEn,
        stationVoice=definition.generated,legacyFallback=definition.legacyFallback,text=definition.text,
        englishText=definition.englishText,key=key}
    -- 新进站/到站事件使旧站的未播队列失效；不强切正在播的短片段。
    if definition.kind=="approach" or definition.kind=="arrival" or definition.kind=="terminal" then
        self.queue={}
    end
    if #self.queue>=8 then table.remove(self.queue,1);self.skipped=self.skipped+1 end
    if self.volume>0 and self.masterVolume>0 and Soundscape.GetAnnouncementGain()>0 then
        self.queue[#self.queue+1]={definition=definition,clips=clips,index=1,created=self.clock,waitingSince=self.clock,key=key}
        for _,path in ipairs(clips) do self:Load(path) end
    end
    self.accepted=self.accepted+1
    print(string.format("[Announcements] accepted %s station=%d voicedZh=%s voicedEn=%s",
        definition.kind,definition.index,tostring(voicedZh),tostring(voicedEn)))
    return true,definition.text
end

---@param dt? number
function Announcements:Update(dt)
    if self.stopped or self.blocked then return end
    self.clock=self.clock+math.max(0,math.min(1,tonumber(dt) or 1/60))
    if not self.source then return end
    local gain=Soundscape.GetAnnouncementGain()
    self.source:SetGain((self.enabled and self.masterVolume>0) and self.volume*gain or 0)
    if not self.enabled or self.masterVolume==0 or self.volume==0 or self.language=="off" or gain==0 then
        if #self.queue>0 or self.activePath~="" then self:DiscardPlayback() end
        return
    end
    if self.source:IsPlaying() and self.clock<self.activeUntil then return end
    if self.source:IsPlaying() then self.source:StopImmediate();self.skipped=self.skipped+1 end
    self.activePath=""
    -- 有界扫描：失败、回调丢失或素材缺失绝不永久堵住后续事件。
    for _=1,24 do
        local job=self.queue[1]
        if not job then return end
        if self.clock-job.created>60 then
            table.remove(self.queue,1);self.skipped=self.skipped+1
        else
            local path=job.clips[job.index]
            if not path then table.remove(self.queue,1)
            else
                self:Load(path)
                local sound=self.sounds[path]
                if sound then
                    job.index=job.index+1;job.waitingSince=self.clock
                    self.source:Play(sound,0,self.volume*Soundscape.GetAnnouncementGain())
                    self.activePath,self.activeUntil=path,self.clock+math.min(60,math.max(.1,sound:GetLength()))+2
                    self.played=self.played+1
                    return
                elseif self.errors[path] or self.clock-job.waitingSince>=8 then
                    self.pending[path]=nil;self.retryAt[path]=self.clock+10
                    self.errors[path]="下载失败或等待超时，本片段已跳过"
                    job.index=job.index+1;job.waitingSince=self.clock;self.skipped=self.skipped+1
                else return end
            end
        end
    end
end
function Announcements:GetStatus()
    local gain=self.source and self.source:GetGain() or 0
    local playing=self.source and self.source:IsPlaying() or false
    local reason=""
    if self.stopped then reason="shutdown"
    elseif not self.enabled then reason="sound_off"
    elseif self.blocked then reason="blocked"
    elseif self.masterVolume==0 then reason="master_zero"
    elseif self.volume==0 then reason="announcement_zero"
    elseif self.language=="off" then reason="language_off"
    elseif not audio:IsInitialized() or not audio:IsPlaying() then reason="device_unavailable"
    elseif audio:GetMasterGain(SOUND_MASTER)<=0 or audio:GetMasterGain(SOUND_TYPE)<=0 then reason="bus_muted"
    elseif self.activePath~="" and gain==0 then reason="mix_muted"
    elseif self.lastEvent.voiced==false then reason="language_voice_unavailable" end
    return {queued=#self.queue,playing=playing,
        language=self.language,volume=self.volume,masterVolume=self.masterVolume,enabled=self.enabled,blocked=self.blocked,
        gain=gain,timePosition=self.source and self.source:GetTimePosition() or 0,
        frequency=self.source and self.source:GetFrequency() or 0,mutedReasonCode=reason,
        deviceInitialized=audio:IsInitialized(),devicePlaying=audio:IsPlaying(),audibleValidated=false,
        caption=self.caption,currentText=self.currentText,lastCaption=self.lastCaption,
        englishCaption=self.lastEnglishCaption,lastEvent=self.lastEvent,activePath=self.activePath,
        accepted=self.accepted,played=self.played,skipped=self.skipped,duplicates=self.duplicates,
        errors=self.errors,voiceCoverage=Catalog.GetCoverage(),
        chineseStationVoices=Catalog.GetCoverage().chineseStationVoices,englishStationVoices=false}
end
function Announcements:Shutdown()
    if self.stopped then return end
    self:Reset();self.stopped=true;self.generation=self.generation+1
    if self.root then self.root:Dispose() end
    self.root,self.source=nil,nil
    self.sounds,self.pending={},{}
end
return Announcements
