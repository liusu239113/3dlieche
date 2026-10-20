-- 界面反馈只播放一次性提示音；旧 Boarding 兼容入口委托有界广播队列。
-- 主入口使用自己的 Announcements 实例时，不应同时调用 UiAudio.Boarding。
local Soundscape = require "audio.Soundscape"
local Announcements = require "audio.Announcements"
local UiAudio = {}
local PATHS={
    click="audio/sfx/rail_ui_soft_click.mp3",
    announcement="audio/sfx/rail_announcement_chime.wav",
    door="audio/sfx/rail_door_close_chime.wav",
}
---@type Node?
local root_=nil
---@type SoundSource?
local click_=nil
---@type RailwayAnnouncements?
local legacy_=nil
---@type table<string,Sound>
local sounds_={}
local pending_={} ---@type table<string,number>
local requestedAt_={} ---@type table<string,number>
local retryAt_={} ---@type table<string,number>
local generation_,serial_,clock_=0,0,0.0
local enabled_,volume_,language_,blocked_=true,.55,"both",false
local lastVisit_=""
local function load(path)
    if sounds_[path] or pending_[path] or clock_<(retryAt_[path] or 0) then return end
    serial_=serial_+1
    local request,generation=serial_,generation_
    pending_[path]=request;requestedAt_[path]=clock_
    local function complete(resource)
        if generation~=generation_ or pending_[path]~=request then return end
        pending_[path]=nil
        if resource and (resource --[[@as Sound]]):GetLength()>0 then sounds_[path]=resource --[[@as Sound]]
        else retryAt_[path]=clock_+10 end
    end
    if cache:Exists(path) then complete(cache:GetResource("Sound",path))
    else cache:GetResourceAsync("Sound",path,complete) end
end
function UiAudio.Init()
    UiAudio.Shutdown()
    root_=Node();root_.name="RailwayInterfaceAudio"
    click_=root_:CreateChild("Clicks"):CreateComponent("SoundSource")
    click_:SetSoundType("FantasyRail.Interface");click_:SetDeclickEnabled(true)
    load(PATHS.click)
end
---@param kind string click / announcement / door
---@return boolean
function UiAudio.Prompt(kind)
    if not enabled_ or blocked_ or volume_<=0 or not click_ then return false end
    local path=PATHS[kind]
    if not path then return false end
    load(path)
    local sound=sounds_[path]
    if not sound then return false end -- 不排队，避免按钮反馈延迟到下一页面才发声。
    local gain=kind=="click" and .12*Soundscape.GetBackgroundDuck() or Soundscape.GetAnnouncementGain()
    click_:Play(sound,0,volume_*gain)
    return true
end
function UiAudio.Click() return UiAudio.Prompt("click") end
function UiAudio.DoorClose() return UiAudio.Prompt("door") end
---@param key string 每次站停唯一键；兼容旧HUD调用，不在此推断目标站。
function UiAudio.Boarding(key)
    if key==lastVisit_ or blocked_ or not enabled_ then return end
    lastVisit_=key
    if not legacy_ then legacy_=Announcements.new({volume=volume_,language=language_,enabled=enabled_}) end
    legacy_:Reset()
    legacy_:Announce("welcome")
end
---@param dt? number
function UiAudio.Update(dt)
    clock_=clock_+math.max(0,math.min(1,tonumber(dt) or 1/60))
    if legacy_ then legacy_:Update(dt) end
    -- 界面音效下载是可选；异步回调永远不回来也不能锁死后续点击重试。
    for path in pairs(pending_) do
        if clock_-(requestedAt_[path] or clock_)>=8 then
            pending_[path]=nil;requestedAt_[path]=nil;retryAt_[path]=clock_+10
        end
    end
end
function UiAudio.SetSettings(enabled,volume,language)
    enabled_,volume_=enabled~=false,math.max(0,math.min(1,tonumber(volume) or 0))
    if language=="zh" or language=="en" or language=="both" or language=="off" then language_=language end
    if legacy_ then
        legacy_:SetSettings({sound=enabled_,volume=volume_,language=language_})
        legacy_:SetBlocked(blocked_)
    end
    if click_ then
        click_:SetGain((enabled_ and not blocked_) and volume_*.12*Soundscape.GetBackgroundDuck() or 0)
        if not enabled_ or blocked_ or volume_==0 then click_:StopImmediate() end
    end
end
function UiAudio.SetBlocked(blocked)
    blocked_=blocked
    if legacy_ then legacy_:SetBlocked(blocked) end
    if blocked and click_ then click_:StopImmediate() end
end
function UiAudio.ResetJourney()
    lastVisit_=""
    if legacy_ then legacy_:Reset() end
    if click_ then click_:StopImmediate() end
end
function UiAudio.GetResourcePaths()
    local paths=Announcements.GetResourcePaths()
    paths[#paths+1]=PATHS.click
    return paths
end
function UiAudio.GetStatus()
    local status=legacy_ and legacy_:GetStatus() or {queued=0,playing=false}
    status.language=language_;status.enabled=enabled_;status.blocked=blocked_;status.volume=volume_
    local legacySounds=legacy_ and legacy_.sounds or sounds_
    status.readyZh=legacySounds["audio/voice/fictional_boarding_zh_1_aca51c5d8ff454f4.ogg"]~=nil
    status.readyEn=legacySounds["audio/voice/fictional_boarding_en_1_aca51c5d8ff454f4.ogg"]~=nil
    return status
end
function UiAudio.Shutdown()
    generation_=generation_+1
    if legacy_ then legacy_:Shutdown();legacy_=nil end
    if root_ then root_:Dispose() end
    root_,click_=nil,nil
    sounds_,pending_,requestedAt_,retryAt_,lastVisit_={},{},{},{},""
    blocked_=false;clock_=0
end
return UiAudio
