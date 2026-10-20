-- 关卡媒体门控：本地模式即时完成，DWP 模式依赖回调，不轮询、不提前读 WAV。
local Catalog = require "config.TrainCatalog"
local CoachModels = require "config.CoachModels"
local Profiles = require "audio.AudioProfiles"
local PassengerPoses = require "world.PassengerPoseCache"
local Announcements = require "audio.Announcements"
local Soundscape = require "audio.Soundscape"
local RageAudio = require "audio.RageAudio"
local UiAudio = require "audio.UiAudio"
local StationVisualConfig = require "config.StationVisualConfig"
local MediaGate = {}
local generation_,group_ = 0,0
local active_,completed_,total_,failed_ = false,0,0,0
local NPC = {
    "model/1327bd4517494f618b98f9cbd7dd6d14/Meshes/rig-1-abb7fccb-4c30-41bb-87c6-2041221288d0.mdl",
    "model/dc91a901-3f95-58cd-8f9b-3b4f45ddd16a/Meshes/rig-1-d508011a-048f-4b5d-b63f-253a09217cff.mdl",
    "Animations/Passengers/male_walk.ani","Animations/Passengers/female_walk.ani",
    "model/1327bd4517494f618b98f9cbd7dd6d14/Materials/rig-1-abb7fccb-4c30-41bb-87c6-2041221288d0_00_tripo_material_bc4cfaad-2587-4fbe-b062-0195a084de9e.xml",
    "model/dc91a901-3f95-58cd-8f9b-3b4f45ddd16a/Materials/rig-1-d508011a-048f-4b5d-b63f-253a09217cff_00_tripo_material_f0fb9b57-4d33-459d-ad17-a1be250e3b90.xml",
    "model/1327bd4517494f618b98f9cbd7dd6d14/Textures/rig-1-abb7fccb-4c30-41bb-87c6-2041221288d0_00_D.jpg",
    "model/1327bd4517494f618b98f9cbd7dd6d14/Textures/rig-1-abb7fccb-4c30-41bb-87c6-2041221288d0_00_N.png",
    "model/dc91a901-3f95-58cd-8f9b-3b4f45ddd16a/Textures/rig-1-d508011a-048f-4b5d-b63f-253a09217cff_00_D.jpg",
    "model/dc91a901-3f95-58cd-8f9b-3b4f45ddd16a/Textures/rig-1-d508011a-048f-4b5d-b63f-253a09217cff_00_N.jpg",
    "Textures/Railway/concrete.png","Textures/Railway/ballast.png","Textures/Railway/grass.png","Textures/Railway/brick.png",
    "model/ea12c55a04ce49e7a62e1e952b2b85d0/Meshes/ea12c55a04ce49e7a62e1e952b2b85d0.mdl",
    "model/ea12c55a04ce49e7a62e1e952b2b85d0/Materials/ea12c55a04ce49e7a62e1e952b2b85d0_00_tripo_material_0c2865ef-2546-4809-bf47-24f0b98a798d.xml",
    "model/ea12c55a04ce49e7a62e1e952b2b85d0/Textures/ea12c55a04ce49e7a62e1e952b2b85d0_00_D.jpg",
    "model/ea12c55a04ce49e7a62e1e952b2b85d0/Textures/ea12c55a04ce49e7a62e1e952b2b85d0_00_N.png",
}
local SOUND = {
    "audio/music/railway_journey_loop.wav",
    "audio/sfx/crowd/platform_loop.wav","audio/sfx/crowd/carriage_loop.wav",
    "audio/sfx/comfort/metadata.json","audio/sfx/comfort/ambience_city_loop.wav",
    "audio/sfx/rail_ui_soft_click.mp3",
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
    local heads={entry.head}
    if entry.middle then heads[#heads+1]=entry.middle end
    if entry.roles then
        for _,role in ipairs({entry.roles.head,entry.roles.middle,entry.roles.tail}) do
            heads[#heads+1]=role.profile
        end
    end
    for _,key in ipairs(heads) do
        local asset=assert(Catalog.Assets[key])
        add(asset.modelPath);add(asset.metadataPath);add(asset.diffusePath);add(asset.normalPath)
    end
    local profile=assert(Profiles.Find(id))
    add(profile.idlePath);add(profile.runningPath);add(profile.hornPath)
    -- 独立生成客车：机车牵引的7节客车用此款成品，随头车一起预下载。
    local coach=CoachModels.Find(id)
    if coach and coach.profileId then
        local coachAsset=Catalog.Assets[coach.profileId]
        if coachAsset then
            add(coachAsset.modelPath);add(coachAsset.metadataPath)
            add(coachAsset.diffusePath);add(coachAsset.normalPath)
        end
    end
    if id=="DF4D" then add("RollingStockBaked/DF4D_body_shell_patch.json") end
    if id=="HXD3D" then
        add("RollingStockBaked/HXD3D_body_shell_patch.json")
        -- 手工克隆的补片材质不在成品MDL引用链里，必须显式等待真实D/N。
        add("FictionalLiveries/Leisun_E32_patch_D.png")
        add("FictionalLiveries/Leisun_E32_patch_N.png")
    end
    if entry.kind=="locomotive" then
        -- 客车细节为程序化材质，不能指望MDL/XML自动带出这些纹理依赖。
        for _,path in ipairs({"Textures/Railway/coach_paint.png","Textures/Railway/coach_paint_normal.png",
            "Textures/Railway/coach_steel.png","Textures/Railway/coach_glass.png",
            "FictionalLiveries/Yunzhou_C24_detail_D.png"}) do add(path) end
    end
    if passengers then
        for _,path in ipairs(NPC) do add(path) end
        for _,path in ipairs(PassengerPoses.GetResourcePaths()) do add(path) end
        for _,path in ipairs(SOUND) do add(path) end
        for _,path in ipairs(Announcements.GetResourcePaths()) do add(path) end
        for _,path in ipairs(Soundscape.GetResourcePaths()) do add(path) end
        for _,path in ipairs(RageAudio.GetPaths()) do add(path) end
        for _,path in ipairs(UiAudio.GetResourcePaths()) do add(path) end
    end
    return paths
end
function MediaGate.ForWorld(stationIndex,qualityId)
    local paths=StationVisualConfig.GetRequiredResources(stationIndex,qualityId)
    local seen={} ---@type table<string,boolean>
    for _,path in ipairs(paths) do seen[path]=true end
    -- 实际天空由Sky.GetRealisticPath首选26；旧Skybox.ktx不是它。
    -- 这里只列路径，不能调用GetRealisticPath提前GetResource触发占位或解码。
    -- 坡草仍用于桥谷/洞壳，与地表专用三图一起ready。
    for _,path in ipairs({"Textures/Sky/RealisticSky26.ktx",
        "Textures/Railway/grass_detail.tga","Textures/Railway/grass_detail_normal.tga",
        "Textures/Railway/ground_meadow.png","Textures/Railway/ground_verge.png","Textures/Railway/ground_earth.png"}) do
        if not seen[path] then seen[path]=true;paths[#paths+1]=path end
    end
    -- 本地MDL之外，叶片透明裁剪、树皮及公交贴图必须一起ready，不能进场后才热补。
    for _,resources in ipairs({require("world.Vegetation").GetResourcePaths(),require("world.RoadVehicles").GetResourcePaths()}) do
        for _,path in ipairs(resources) do
            if not seen[path] then seen[path]=true;paths[#paths+1]=path end
        end
    end
    return paths
end
---@param paths string[]
---@param done fun(success:boolean,message:string)
---@param progress? fun(ratio:number)
function MediaGate.Begin(paths,done,progress)
    MediaGate.Cancel()
    local generation=generation_
    local unique={} ---@type string[]
    local seen={} ---@type table<string,boolean>
    local function add(path)
        -- manifest里的递归引用是uuid://；与显式路径按同一资源身份去重。
        -- 原始本地tool_mode可能没有manifest/查询方法，仍保留原路径校验。
        local key=path
        if type(cache.GetResUuidPath)=="function" then
            local ok,uri=pcall(cache.GetResUuidPath,cache,path)
            if ok and type(uri)=="string" and uri~="" then key=uri end
        end
        if not seen[key] then seen[key]=true;unique[#unique+1]=path end
    end
    for _,path in ipairs(paths) do add(path) end
    if type(cache.GetResRefs)=="function" then
        -- GetResRefs本身递归并合并去重；不载入资源，不把占位GetResource当ready。
        -- pcall 下重载不解析，这里按 string[] 重载显式调用。
        local ok,refs=pcall(function() return cache:GetResRefs(paths,true) end)
        if ok and type(refs)=="table" then
            for _,path in ipairs(refs) do add(path) end
        end
    end
    paths=unique
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
        local stillMissing={} ---@type string[]
        for _,path in ipairs(paths) do
            if not cache:Exists(path) then success=false;stillMissing[#stillMissing+1]=path end
        end
        failed_=math.max(failed_,#stillMissing)
        completed_=total_-#stillMissing
        for _,path in ipairs(stillMissing) do print("[MediaGate] 未就绪："..path) end
        print(string.format("[MediaGate] 完成 total=%d ready=%d failed=%d generation=%d",total_,completed_,failed_,generation))
        done(success,success and "" or string.format("%d项资源未就绪（可能未入包或下载失败），原列车保留，请重试",failed_))
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
