-- 菜单/UI 点击与架空中英文广播；资源下载后缓存，声音不归场景所有。
local UiAudio = {}
local CLICK="audio/sfx/rail_ui_soft_click.mp3"
local VOICES={
    zh="audio/voice/fictional_boarding_zh_1_aca51c5d8ff454f4.ogg",
    en="audio/voice/fictional_boarding_en_1_aca51c5d8ff454f4.ogg",
}
---@type Node?
local root_=nil
---@type SoundSource?
local click_=nil
---@type SoundSource?
local voice_=nil
---@type table<string,Sound>
local sounds_={}
local pending_={} ---@type table<string,boolean>
local queue_={} ---@type string[]
local generation_=0
local enabled_,volume_,language_,blocked_=true,.55,"both",false
local lastVisit_=""
local function load(path)
    if sounds_[path] or pending_[path] then return end
    if cache:Exists(path) then
        sounds_[path]=cache:GetResource("Sound",path);return
    end
    pending_[path]=true
    local generation=generation_
    cache:GetResourceAsync("Sound",path,function(resource)
        if generation~=generation_ then return end
        pending_[path]=nil
        if resource then sounds_[path]=resource --[[@as Sound]] end
    end)
end
function UiAudio.Init()
    UiAudio.Shutdown()
    root_=Node();root_.name="RailwayInterfaceAudio"
    click_=root_:CreateChild("Clicks"):CreateComponent("SoundSource")
    voice_=root_:CreateChild("Announcements"):CreateComponent("SoundSource")
    click_:SetSoundType("FantasyRail.Interface")
    voice_:SetSoundType("FantasyRail.Announcements")
    click_:SetDeclickEnabled(true);voice_:SetDeclickEnabled(true)
    load(CLICK)
end
function UiAudio.Click()
    if not enabled_ or not click_ then return end
    load(CLICK)
    local sound=sounds_[CLICK]
    if sound then click_:Play(sound,sound:GetFrequency(),volume_*.24) end
end
---@param key string 每次站停唯一键；重复HUD刷新不会重复广播。
function UiAudio.Boarding(key)
    if key==lastVisit_ then return end
    lastVisit_=key
    queue_={}
    if language_=="zh" or language_=="both" then queue_[#queue_+1]=VOICES.zh;load(VOICES.zh) end
    if language_=="en" or language_=="both" then queue_[#queue_+1]=VOICES.en;load(VOICES.en) end
end
function UiAudio.Update()
    if not voice_ or not enabled_ or blocked_ or voice_:IsPlaying() then return end
    local path=queue_[1]
    if not path then return end
    local sound=sounds_[path]
    if not sound then return end
    table.remove(queue_,1)
    voice_:Play(sound,sound:GetFrequency(),volume_*.70)
    print("[UiAudio] 上车广播 "..path)
end
function UiAudio.SetSettings(enabled,volume,language)
    enabled_,volume_=enabled,math.max(0,math.min(1,volume))
    if language=="zh" or language=="en" or language=="both" or language=="off" then language_=language end
    if click_ then click_:SetGain(enabled_ and volume_*.24 or 0) end
    if voice_ then voice_:SetGain(enabled_ and volume_*.70 or 0) end
end
function UiAudio.SetBlocked(blocked)
    blocked_=blocked
    if blocked then audio:PauseSoundType("FantasyRail.Announcements")
    else audio:ResumeSoundType("FantasyRail.Announcements") end
end
function UiAudio.ResetJourney()
    queue_,lastVisit_={},""
    if voice_ then voice_:StopImmediate() end
end
function UiAudio.GetStatus()
    return {queued=#queue_,language=language_,playing=voice_ and voice_:IsPlaying() or false,
        readyZh=sounds_[VOICES.zh]~=nil,readyEn=sounds_[VOICES.en]~=nil}
end
function UiAudio.Shutdown()
    generation_=generation_+1
    if root_ then root_:Dispose() end
    root_,click_,voice_=nil,nil,nil
    sounds_,pending_,queue_,lastVisit_={},{},{},""
    audio:ResumeSoundType("FantasyRail.Announcements")
end
return UiAudio
