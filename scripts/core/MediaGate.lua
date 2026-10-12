-- 关卡媒体门控：本地模式即时完成，DWP 模式依赖回调，不轮询、不提前读 WAV。
local Catalog = require "config.TrainCatalog"
local Profiles = require "audio.AudioProfiles"
local MediaGate = {}
local generation_,group_ = 0,0
local active_,completed_,total_,failed_ = false,0,0,0
local NPC = {
    "Animations/Passengers/male_walk.ani","Animations/Passengers/female_walk.ani",
    "model/62a13e80-74a8-5078-b777-5530e5a4346e/Materials/rig-1-4db698a0-fa75-4297-921d-cb4897aad9cb_00_tripo_material_8547aae4-7585-4381-9471-199ca2c0c6ae.xml",
    "model/dc91a901-3f95-58cd-8f9b-3b4f45ddd16a/Materials/rig-1-d508011a-048f-4b5d-b63f-253a09217cff_00_tripo_material_f0fb9b57-4d33-459d-ad17-a1be250e3b90.xml",
    "model/62a13e80-74a8-5078-b777-5530e5a4346e/Textures/rig-1-4db698a0-fa75-4297-921d-cb4897aad9cb_00_D.jpg",
    "model/62a13e80-74a8-5078-b777-5530e5a4346e/Textures/rig-1-4db698a0-fa75-4297-921d-cb4897aad9cb_00_N.jpg",
    "model/dc91a901-3f95-58cd-8f9b-3b4f45ddd16a/Textures/rig-1-d508011a-048f-4b5d-b63f-253a09217cff_00_D.jpg",
    "model/dc91a901-3f95-58cd-8f9b-3b4f45ddd16a/Textures/rig-1-d508011a-048f-4b5d-b63f-253a09217cff_00_N.jpg",
    "Textures/Railway/concrete.png","Textures/Railway/ballast.png","Textures/Railway/grass.png","Textures/Railway/brick.png",
}
local SOUND = {
    "audio/sfx/comfort/metadata.json","audio/sfx/comfort/ambience_city_loop.wav",
    "audio/sfx/comfort/comfort_brake_air.wav","audio/sfx/rail_ui_soft_click.mp3",
    "audio/voice/fictional_boarding_zh_1_aca51c5d8ff454f4.ogg",
    "audio/voice/fictional_boarding_en_1_aca51c5d8ff454f4.ogg",
}
---@param id string
---@param passengers? boolean
---@return string[]
function MediaGate.ForTrain(id,passengers)
    local entry=assert(Catalog.Find(id))
    local paths={} ---@type string[]
    local seen={} ---@type table<string,boolean>
    local function add(path)
        if path and not seen[path] then seen[path]=true;paths[#paths+1]=path end
    end
    local heads={entry.head,entry.middle}
    for _,key in ipairs(heads) do
        local asset=assert(Catalog.Assets[key])
        add(asset.modelPath);add(asset.metadataPath);add(asset.diffusePath);add(asset.normalPath)
    end
    local profile=assert(Profiles.Find(id))
    add(profile.idlePath);add(profile.runningPath);add(profile.hornPath)
    if passengers then
        for _,path in ipairs(NPC) do add(path) end
        for _,path in ipairs(SOUND) do add(path) end
    end
    return paths
end
---@param paths string[]
---@param done fun(success:boolean,message:string)
---@param progress? fun(ratio:number)
function MediaGate.Begin(paths,done,progress)
    MediaGate.Cancel()
    local generation=generation_
    completed_,total_,failed_,active_=0,#paths,0,true
    local missing={} ---@type string[]
    for _,path in ipairs(paths) do if not cache:Exists(path) then missing[#missing+1]=path end end
    if #missing==0 then
        completed_,active_=total_,false
        if progress then progress(1) end
        done(true,"");return
    end
    print("[MediaGate] 等待媒体 "..#missing.." 项；未完成前不解码或进入游戏")
    local group=cache:DownloadResources(missing,function(success,failedCount)
        if generation~=generation_ then return end
        failed_,active_,group_=failedCount,false,0
        for _,path in ipairs(paths) do
            if not cache:Exists(path) then success=false end
        end
        completed_=success and total_ or completed_
        done(success,success and "" or "部分资源未下载完成，请检查网络后重试")
    end,function(completed,total)
        if generation~=generation_ then return end
        completed_=#paths-#missing+completed
        if progress then progress(completed_/math.max(1,total_)) end
    end)
    if active_ then group_=group end
end
function MediaGate.Cancel()
    generation_=generation_+1
    if group_~=0 then cache:CancelDownloadGroup(group_) end
    group_,active_=0,false
end
function MediaGate.GetStatus() return {active=active_,completed=completed_,total=total_,failed=failed_} end
return MediaGate
