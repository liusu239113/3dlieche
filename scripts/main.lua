-- ============================================================================
-- 火车驾驶模拟 - 主入口
-- 星澜群域：五站架空客运干线、六款独立车队、乘降与驾驶运营
-- ============================================================================

local GameConfig = require "config.GameConfig"
local GameModes = require "config.GameModes"
local VisualQuality = require "config.VisualQuality"
local Route = require "world.Route"
local WorldStream = require "world.WorldStream"
local Terrain = require "world.Terrain"
local RoadCorridor = require "world.RoadCorridor"
local SkyUtils = require "urhox-libs.Rendering.SkyUtils"
local Sky = require "world.Sky"
local Train = require "train.Train"
local Camera = require "train.Camera"
local Hud = require "ui.Hud"
local AudioManager = require "audio.AudioManager"
local Soundscape = require "audio.Soundscape"
local RageAudio = require "audio.RageAudio"
local Game = require "game.Game"
local Traffic = require "game.Traffic"
local StationYard = require "world.StationYard"
local RailwayInfrastructure = require "world.RailwayInfrastructure"
local PassengerService = require "game.PassengerService"
local Landmarks = require "world.Landmarks"
local UI = require "urhox-libs/UI"
local Menu = require "ui.Menu"
local MediaGate = require "core.MediaGate"
local ViewDrag = require "train.ViewDrag"
local UiAudio = require "audio.UiAudio"
local SaveStore = require "game.SaveStore"
local RailNetwork = require "world.RailNetwork"
local Catalog = require "config.TrainCatalog"
local Environment = require "world.Environment"
local Station = require "world.Station"
local Announcements = require "audio.Announcements"
local TrainSelection = require "core.TrainSelection"
local ExperienceFeedback = require "core.ExperienceFeedback"
local LightingDiagnostics = require "core.LightingDiagnostics"
local FEATURE_VERSION = "灯光真机对照 LD-20261020-B / 默认非集群"
local application_ = "menu"
local loadGeneration_ = 0
---@type thread?
local loadingWork_ = nil
---@type table?
local restore_ = nil
---@type table?
local migration_ = nil
---@type table?
local legacyRouteBackup_ = nil
local saveTimer_ = 0.0
local savedJourney_ = nil ---@type table?
local savedJourneys_ = {} ---@type table<string,table>
local settings_ = {quality="medium",sound=true,volume=.75,music=true,musicVolume=.35,
    ambienceVolume=.45,trainVolume=1.0,announcementVolume=.85,language="both",sensitivity=.20,cloud=false,
    environment={hour=12,running=true,weather="clear"}}
---@type RailwayAnnouncements|nil
local announcements_ = nil
---@type RailwayFeedback|nil
local feedback_ = nil
---@type TrainSelection|nil
local trainSelection_ = nil
local feedbackTimer_ = 0.0
local announcementSerial_ = 0
local focused_ = true
local settingsRevision_ = 0
---@type fun()
local ShowMenu
---@type fun(restore:boolean,modeId?:string)
local BeginGame
---@type fun()
local ShowSettings
---@type fun(cloud:boolean):boolean
local SaveProgress
local initialized_ = false
local restarting_ = false
local hudCallbacks_ = {} ---@type CabHudCallbacks
---@type fun()|nil
local SyncVolumeSettings = nil

---@type Scene|nil
local scene_ = nil
local paused_ = false
local brakeHeld_ = false
local touchBrakeHeld_ = false
local selectorOpen_ = false
local simulationDebt_ = 0.0
local frameSimulated_ = 0.0
local totalSimulated_ = 0.0
---@type fun()
local RestartJourney
---@type fun(selected:boolean):boolean
local SelectLightingCluster
local STEP = .02
local MAX_STEPS = 50
local renderQuality_ = GameConfig.RenderQuality or "performance"

-- 菜单暂停和用户暂停独立；关菜单不能把原本已暂停的游戏自动恢复。
local function IsPaused() return paused_ or selectorOpen_ end

local function SyncPause()
    local paused = IsPaused()
    if paused then simulationDebt_, frameSimulated_ = 0, 0 end
    Hud.SetPaused(paused)
    local audioBlocked = paused or not focused_ or application_~="playing"
    AudioManager.SetSuspended(audioBlocked)
    Soundscape.SetBlocked(audioBlocked)
    RageAudio.SetBlocked(audioBlocked)
    PassengerService.SetPaused(paused)
    UiAudio.SetBlocked(audioBlocked)
    Environment.SetPaused(audioBlocked)
    if announcements_ then announcements_:SetBlocked(audioBlocked) end
    if audioBlocked then Hud.SetAnnouncement("") end
    ViewDrag.Reset()
    if paused then brakeHeld_, touchBrakeHeld_ = false, false end
end

---@param id string
---@return boolean,string
local function CanSelectTrain(id)
    if not Catalog.Find(id) then return false,"未知车型，请从车队目录选择" end
    if math.abs(Train.GetSpeedKmh()) > 0.1 then return false,"请先停稳后再换车" end
    local passengers=PassengerService.GetStatus()
    if passengers.onboard+passengers.waiting>PassengerService.GetCapacity(id) then
        return false,"该编组容量不足，请完成当前旅程清客后再换车"
    end
    return true,""
end

local function OnTrainSelected()
    brakeHeld_,touchBrakeHeld_=false,false
    Hud.SetSelectedTrain(Train.GetSelectedId(),Train.GetSelectedName())
    Hud.SetTrainCatalog(Train.GetCatalog() --[[@as CabTrainCatalogEntry[] ]],Train.GetSelectedId())
    AudioManager.SetTrainId(Train.GetSelectedId())
    AudioManager.SetPowerType(Train.GetPowerType())
    local lead=Train.GetLeadNode()
    if lead then AudioManager.SetTrainPose(lead.worldPosition,lead.worldRotation) end
    PassengerService.RefreshDoorPlan()
    Game.UpdateHud(0)
    print("[Main] 换车完成，保留站序/经验/线路位置："..Train.GetSelectedName())
end

local function GetTrainSelection()
    if not trainSelection_ then
        trainSelection_=TrainSelection.new({
            resources=function(id) return MediaGate.ForTrain(id,false) end,
            download=function(paths,done,progress) MediaGate.Begin(paths,done,progress) end,
            cancelDownload=function() if application_~="loading" then MediaGate.Cancel() end end,
            canSelect=CanSelectTrain,
            select=function(id,force) return Train.Select(id,force) end,
            isActive=function() return application_=="playing" and initialized_ end,
            name=function(id) local entry=Catalog.Find(id);return entry and entry.name or "列车" end,
            onSelected=function() OnTrainSelected() end,
            onMessage=function(message) Hud.Toast(message,3) end,
            onProgress=function(active,ratio,message)
                Hud.SetTrainLoading(active,ratio,message,function() CancelTrainSelection() end)
            end,
        })
    end
    return trainSelection_
end

---@param message? string
function CancelTrainSelection(message)
    if trainSelection_ then trainSelection_:Cancel(message or "已取消切车，原列车保留") end
end

---@param id string
---@param done? fun(ok:boolean,message:string)
---@return boolean,string
function SelectTrain(id,done)
    -- 无论目标资源是否已缓存，新意图都先使旧下载回调失效。
    return GetTrainSelection():Request(id,done,id==Train.GetSelectedId())
end

local function AnnouncementSnapshot()
    local status=Game.GetAnnouncementState()
    local passenger=PassengerService.GetStatus()
    status.visits=PassengerService.GetStats().visits
    status.reversing=Train.IsReversing()
    status.s=Train.GetS()
    status.phase=passenger.phase
    status.terminal=Game.IsTerminal()
    status.dwelling=Game.IsDwelling()
    local endpoint=status.reversing and 1 or #Route.GetStations()
    status.terminalStop=status.dwelling and status.lastArrival==endpoint
    return status --[[@as AnnouncementSnapshot]]
end

local function UpdateExperienceFeedback(dt)
    local departure=Game.GetDepartureStatus()
    if feedback_ and not GameModes.IsRage() then
        local target=Game.GetNextStation()
        feedback_:Update(AnnouncementSnapshot(),departure,target and target.s or nil)
    end
    if announcements_ then announcements_:Update(dt) end
    feedbackTimer_=feedbackTimer_+dt
    if feedbackTimer_>=.2 or dt==0 then
        feedbackTimer_=0
        Hud.SetEnvironment(Environment.GetStatus())
        Hud.SetDepartureStatus(departure)
        if announcements_ then
            local status=announcements_:GetStatus()
            local key=tostring(announcementSerial_)..":"..tostring(status.accepted)..":"
                ..tostring(status.lastEvent and status.lastEvent.key or "")
            Hud.SetAnnouncement(status.currentText or "",false,key)
        end
    end
end

---@param patch table
local function ChangeEnvironment(patch)
    if type(patch)~="table" then return false end
    if patch.hour~=nil and (type(patch.hour)~="number" or patch.hour~=patch.hour
        or patch.hour==math.huge or patch.hour==-math.huge) then return false end
    if patch.running~=nil and type(patch.running)~="boolean" then return false end
    if patch.weather~=nil and patch.weather~="clear" and patch.weather~="cloudy"
        and patch.weather~="rain" and patch.weather~="fog" then return false end
    if initialized_ and not Environment.Configure(patch) then return false end
    settingsRevision_=settingsRevision_+1
    if initialized_ then
        settings_.environment=Environment.Export()
        Hud.SetEnvironment(Environment.GetStatus())
        Game.UpdateHud(0)
    else
        local values=settings_.environment
        if patch.hour~=nil then values.hour=patch.hour%24 end
        if patch.running~=nil then values.running=patch.running end
        if patch.weather~=nil then values.weather=patch.weather end
        if savedJourney_ then
            local savedEnvironment={}
            for key,value in pairs(savedJourney_.environment or values) do savedEnvironment[key]=value end
            if patch.hour~=nil then
                local previous=tonumber(savedEnvironment.minutes) or (tonumber(savedEnvironment.hour) or values.hour)*60
                local nextMinutes=math.floor(previous/1440)*1440+values.hour*60
                if math.abs(nextMinutes-previous)>1e-7 then
                    savedEnvironment.revision=math.floor(tonumber(savedEnvironment.revision) or 0)+1
                end
                savedEnvironment.hour=values.hour
                savedEnvironment.minutes=nextMinutes
            end
            if patch.running~=nil then savedEnvironment.running=values.running end
            if patch.weather~=nil then savedEnvironment.weather=values.weather end
            savedJourney_.environment=savedEnvironment
        end
    end
    SaveProgress(false)
    return true
end

-- 画质只改变渲染负载与视觉表现，不改线路、AI班次、碰撞界或动力参数。
-- 三档：low 流畅 / medium 标准 / high 极致。旧档名自动归一化。
---@param quality string
---@return boolean
function SetRenderQuality(quality)
    local id = VisualQuality.Normalize(quality)
    if not VisualQuality.IsValid(id) then return false end
    renderQuality_ = id
    settings_.quality = id
    local preset = VisualQuality.Get(id)
    WorldStream.SetQuality(preset)

    renderer.dynamicInstancing = true
    renderer.drawShadows = preset.shadows
    renderer.specularLighting = preset.shadows
    -- 材质质量固定 MEDIUM：QUALITY_HIGH 的 PBR 变体在部分 GLES 环境编译失败。
    -- 画质差异由阴影、视距、纹理密度与植被密度承担，不靠这个开关。
    renderer.materialQuality = QUALITY_MEDIUM
    renderer.shadowMapSize = preset.shadowMapSize
    -- HDR 由 Camera.Build 统一开启（原有行为），此处不重复设置。

    -- 玩家模型保持相同细节；远处AI在自身drawable上独立使用LOD偏置。
    local camera = Camera.GetCamera()
    if camera then
        camera.lodBias = preset.lodBias
        camera.farClip = preset.farClip
    end

    if scene_ then
        local lighting = scene_:GetChild("DayLighting")
        if lighting then
            ApplyAtmosphere(lighting, preset)
            Environment.SetQuality(preset)
        end
        -- 密度参数同步到世界生成模块（仅影响后续新加载的格子）。
        Terrain.SetQuality(preset)
        Traffic.SetVisualQuality(id)
        PassengerService.SetVisualQuality(id)
    end
    Hud.SetRenderQuality(preset.label)
    print(string.format("[Main] 画质 -> %s（%s）：雾 %.0f..%.0fm / 阴影%s / 植被×%.2f / 树距%.0fm",
        preset.label, id, preset.fogStart, preset.fogEnd,
        preset.shadows and "开" or "关", preset.vegetationScale, preset.treeDistance))
    return true
end

-- 把画质档应用到 Zone / 太阳。可在世界未构建时安全调用。
-- 注意：本环境的 shadercache 只提供基础 PBR 变体，Bloom/SSAO/SSR/体积雾
-- 等后效的着色器变体缺失，一旦开启会导致 glLinkProgram 失败、整屏几何消失。
-- 因此这里只下发雾、色调映射、FXAA 与太阳参数——这些不切换着色器变体，
-- 画面提升由写实天空、地表纹理、植被密度承担。
---@param lighting Node
---@param preset VisualQualityPreset
function ApplyAtmosphere(lighting, preset)
    local zone = lighting:GetComponent("Zone")
    if zone then
        zone.fogColor = preset.fogColor
        zone.depthFogStart = preset.fogStart
        zone.depthFogEnd = preset.fogEnd
        -- 不设 fogDensity / heightFog：它们会切换雾着色器变体，本环境缺失。
        -- 深度雾（fogStart/fogEnd/fogColor）已足够表达远景大气。
        zone.tonemapMode = TONEMAP_MODE_ACES
        zone.fxaaEnabled = preset.fxaa
        -- 关闭所有需要额外着色器变体的后效，避免整屏几何消失。
        zone.vignetteEnabled = false
        zone.autoExposureEnabled = false
        zone.bloomWeight = 0.0
        zone.ssaoIntensity = 0.0
        zone.ssrEnabled = false
        zone.ssgiEnabled = false
        zone.motionBlurEnabled = false
        zone.volumetricFogEnabled = false
        -- 环境光用天色调纯色：AMBIENT_SKYBOX 的后台烘焙在部分环境不可用。
        zone.ambientSource = AMBIENT_COLOR
        zone.ambientColor = preset.ambientMode == "skybox"
            and Color(0.34, 0.40, 0.48) or Color(0.24, 0.27, 0.30)
    end
    local sun = lighting:GetComponent("Light", true)
    if sun then
        sun.color = preset.sunColor
        sun.brightness = preset.sunBrightness
        sun.castShadows = preset.shadows
        sun.specularIntensity = preset.shadows and 0.7 or 0.0
        if preset.shadows then
            -- 与原有可用配置同形：三级级联，末级覆盖远中景。
            local d = preset.shadowCascadeDistances
            sun.shadowBias = BiasParameters(0.00025, 0.5)
            sun.shadowCascade = CascadeParameters(d * 0.06, d * 0.25, d, 0.0, 0.85)
        end
    end
end

function GetRenderQuality() return renderQuality_ end

-- ============================================================================
-- 生命周期
-- ============================================================================

local function LoadingStage(message,ratio)
    if loadingWork_ then Menu.Progress(message,ratio);coroutine.yield() end
end

local function BuildGame()
    print("========================================")
    print("[Main] " .. GameConfig.Title .. " 启动")
    print("========================================")

    local t0 = os.clock()
    -- 首批世界必须使用玩家已保存的档位，不能先按旧performance生成再切到low。
    SetRenderQuality(settings_.quality)
    paused_, selectorOpen_ = false, false
    brakeHeld_, touchBrakeHeld_ = false, false

    scene_ = Scene()
    local octree = scene_:CreateComponent("Octree")
    scene_:CreateComponent("DebugRenderer")

    Route.Build()
    -- 两种开放干线都超出默认八叉树范围，必须按当前地图建立全线包络。
    -- 渲染、相机三角射线都使用同一全线包络；流式加载量仍按WorldStream预算限制。
    local worldBounds = BoundingBox()
    for _, point in ipairs(Route.GetPoints()) do
        worldBounds:Merge(point.pos - Vector3(3000, 1000, 3000))
        worldBounds:Merge(point.pos + Vector3(3000, 2000, 3000))
    end
    octree:SetSize(worldBounds, 8)
    print(string.format("[Main] 全线八叉树 %.0f×%.0f×%.0f米，8级；覆盖全线车站射线/渲染",worldBounds.size.x,worldBounds.size.y,worldBounds.size.z))
    CreateLighting()
    -- 世界生成前先下发画质密度，确保首批格子就按目标档位生成。
    Terrain.SetQuality(VisualQuality.Get(renderQuality_))
    -- 首次从星汐总站内开始，完整编组、站前街区与候车乘客都在视野内。
    local firstStation = Route.GetStations()[1]
    -- 停靠点后1米仍在站台内；Game会先完成始发登乘，再选择下一站。
    local initialS = restore_ and restore_.train.s or (firstStation and firstStation.s + 1 or 0)
    LoadingStage("构建车站与连续轨道",.10)
    -- WorldStream 把 0..1 的局部构建进度回传，映射到加载页 0.10..0.80 区间。
    WorldStream.Build(scene_, initialS, function(ratio)
        LoadingStage("加载站场、街区与地貌", .10 + .70 * math.max(0, math.min(1, ratio or 0)))
    end)
    LoadingStage("装配列车",.85)
    Train.Build(scene_)
    if restore_ and restore_.train.id~=Train.GetSelectedId() then assert(Train.Select(restore_.train.id)) end
    if migration_ and migration_.train and migration_.train.id~=Train.GetSelectedId() then
        assert(Train.Select(migration_.train.id))
    end
    if restore_ then
        -- AI布置前恢复整列真实股道/渡线；不能先按去程0股道发车，再把玩家放回上行。
        Train.RestoreState(restore_.train)
        RailNetwork.RestoreChoices(restore_.choices or {})
        -- RestoreState会先清进路并贴正线；恢复侧线后停车状态也必须重新贴轨。
        Train.UpdateVisuals(0,true)
    else
        Train.Reset(initialS)
    end
    LoadingStage("准备行车与相机",.90)
    Traffic.Init(scene_)
    Traffic.SetVisualQuality(settings_.quality)
    Camera.Build(scene_)
    renderer.dynamicInstancing = true
    renderer.shadowMapSize = 1024
    local cameraNode = assert(Camera.GetNode())
    local listener = cameraNode:CreateComponent("SoundListener")
    audio:SetListener(listener)

    AudioManager.Init(scene_, scene_:GetChild("Train"), Train.GetPowerType(), Train.GetSelectedId())
    RageAudio.Init(scene_)
    RageAudio.SetGameMode(GameModes.GetId())
    announcements_=Announcements.new({volume=settings_.announcementVolume,language=settings_.language})
    announcementSerial_=announcementSerial_+1
    feedbackTimer_=0
    announcements_:SetSettings(settings_)
    feedback_=ExperienceFeedback.new(function(kind,index,direction)
        if announcements_ then announcements_:Announce(kind,index,direction) end
    end,function()
        if announcements_ then announcements_:Reset() end
        Hud.SetAnnouncement("")
    end)
    PassengerService.Init(scene_)
    PassengerService.SetVisualQuality(settings_.quality)
    LoadingStage("准备驾驶界面",.95)
    LoadingStage("旅程准备完成",1)
    Menu.Shutdown()
    -- 驾驶界面音量弹窗的唯一权威来源：main 的设置。弹窗只发请求，不回写。
    SyncVolumeSettings=function()
        Hud.SyncVolumeSettings({volume=settings_.volume,trainVolume=settings_.trainVolume,
            announcementVolume=settings_.announcementVolume,musicVolume=settings_.musicVolume,
            sound=settings_.sound})
    end
    hudCallbacks_={
        onMainMenu = function() ShowMenu() end,
        onSettings = function() ShowSettings() end,
        onThrottleUp = function() if not selectorOpen_ then Game.ThrottleUp() end end,
        onThrottleDown = function() if not selectorOpen_ then Game.ThrottleDown() end end,
        onBrake = function() if not selectorOpen_ then Game.Brake(0.25) end end,
        onBrakeHold = function(held) touchBrakeHeld_ = held and not selectorOpen_ end,
        onBrakeRelease = function() touchBrakeHeld_ = false end,
        onReleaseBrake = function()
            if not selectorOpen_ and not Game.IsDwelling() then Train.SetBrake(0) end
        end,
        onReverse = function()
            if selectorOpen_ then return end
            ReverseTrain()
        end,
        onSwitch = function(dir) if not selectorOpen_ then Game.SetSwitch(dir) end end,
        onHeadlightMode = function(mode) ChangeHeadlightMode(mode) end,
        onLightingDiagnostics = function()
            if LightingDiagnostics.Request("manual_capture") then
                Hud.Toast("灯光诊断 LD-20261020-B 已请求，请稍候再提交调试反馈（附日志）",8)
            end
        end,
        onLightingCluster = function(selected) SelectLightingCluster(selected) end,
        onHorn = function() if not selectorOpen_ then Game.Horn() end end,
        onCamera = function()
            if selectorOpen_ then return end
            Camera.CycleMode()
            Hud.SetCameraMode(Camera.GetMode(), Camera.GetModeName())
        end,
        onSelectCamera = function(id)
            if selectorOpen_ then return false, "请先关闭车型选择" end
            Camera.SetMode(id)
            Hud.SetCameraMode(Camera.GetMode(), Camera.GetModeName())
            return true
        end,
        onDrivingMode = function() if not selectorOpen_ then Game.ToggleDrivingMode() end end,
        onService = function() if not selectorOpen_ then Game.CycleService() end end,
        onRenderQuality = function()
            SetRenderQuality(VisualQuality.Next(renderQuality_))
        end,
        onRestart = function() RestartJourney() end,
        onSoundVolume = function(value)
            settings_.volume=value
            AudioManager.SetVolume(value)
            Hud.SetSoundVolume(value)
            Soundscape.SetSettings(settings_)
            UiAudio.SetSettings(settings_.sound,value,settings_.language)
            if announcements_ then announcements_:SetSettings(settings_) end
            SaveProgress(false)
        end,
        onSoundToggle = function(enabled)
            settings_.sound=enabled
            UiAudio.SetSettings(enabled,settings_.volume,settings_.language)
            AudioManager.SetEnabled(enabled)
            if announcements_ then announcements_:SetSettings(settings_) end
            Soundscape.SetSettings(settings_)
            Hud.SetSoundEnabled(enabled)
            if SyncVolumeSettings then SyncVolumeSettings() end
            SaveProgress(false)
        end,
        onTrainVolume = function(value)
            settings_.trainVolume=value
            AudioManager.SetTrainVolume(value)
            SaveProgress(false)
        end,
        onAnnouncementVolume = function(value)
            settings_.announcementVolume=value
            if announcements_ then announcements_:SetSettings(settings_) end
            SaveProgress(false)
        end,
        onMusicToggle = function(enabled)
            settings_.music=enabled
            Soundscape.SetSettings(settings_)
            Hud.SetMusicSettings(enabled,settings_.musicVolume)
            SaveProgress(false)
        end,
        onMusicVolume = function(value)
            settings_.musicVolume=value
            Soundscape.SetSettings(settings_)
            Hud.SetMusicSettings(settings_.music,value)
            SaveProgress(false)
        end,
        onPause = function() TogglePause() end,
        onSelectTrain = function(id,done)
            return SelectTrain(id,function(ok,message) done(ok,message) end)
        end,
        onCancelTrainSelection = function() CancelTrainSelection() end,
        getTrainCatalog = function() return Train.GetCatalog() end,
        onOpenTrainSelector = function(open)
            if not open then CancelTrainSelection() end
            selectorOpen_ = open
            SyncPause()
            print("[Main] 车型选择器 " .. (open and "打开" or "关闭"))
        end,
    }
    Hud.SetGameMode(GameModes.GetId())
    Hud.Init(hudCallbacks_)
    Hud.SetVersion(FEATURE_VERSION)
    Hud.SetEnvironment(Environment.GetStatus())
    local catalog = Train.GetCatalog() --[[@as CabTrainCatalogEntry[] ]]
    Hud.SetTrainCatalog(catalog, Train.GetSelectedId())
    Hud.SetSelectedTrain(Train.GetSelectedId(), Train.GetSelectedName())
    Hud.SetCameraCatalog(Camera.GetPresets(), Camera.GetMode())
    Hud.SetCameraMode(Camera.GetMode(), Camera.GetModeName())
    Hud.SetDrivingMode(Train.GetDrivingMode() == "relaxed" and "休闲牵引" or "模拟牵引")
    Hud.SetSoundEnabled(AudioManager.IsEnabled())
    SetRenderQuality(settings_.quality)
    Traffic.SetVisualQuality(settings_.quality)
    PassengerService.SetVisualQuality(settings_.quality)
    AudioManager.SetEnabled(settings_.sound)
    AudioManager.SetVolume(settings_.volume)
    AudioManager.SetTrainVolume(settings_.trainVolume)
    AudioManager.SetAmbienceVolume(settings_.ambienceVolume)
    Soundscape.SetSettings(settings_)
    Hud.SetSoundEnabled(settings_.sound)
    Hud.SetSoundVolume(settings_.volume)
    Hud.SetMusicSettings(settings_.music,settings_.musicVolume)
    SyncVolumeSettings()
    UiAudio.SetSettings(settings_.sound,settings_.volume,settings_.language)
    ViewDrag.Init(function()
        return application_=="playing" and not selectorOpen_
            and not Hud.IsCameraSelectorOpen() and not Hud.IsVolumePanelOpen()
    end)
    ViewDrag.SetSensitivity(settings_.sensitivity)
    SyncPause()
    simulationDebt_, frameSimulated_, totalSimulated_ = 0, 0, 0

    if restore_ and restore_.environment then
        assert(Environment.Restore(restore_.environment), "环境存档无效，未恢复旅程")
    end
    Game.Init()
    if migration_ then
        -- 旧地图坐标、进路、时刻表不可套入新山图；保留完整原档副本和累计成绩。
        Game.RestoreRouteProgress(migration_.game)
        local fresh = Train.ExportState()
        fresh.distanceTravelled = math.max(0,tonumber(migration_.train and migration_.train.distanceTravelled) or 0)
        fresh.headlightMode = migration_.train and migration_.train.headlightMode or "auto"
        Train.RestoreState(fresh)
        Train.SetBrake(1)
        paused_ = true
        local routeName=GameModes.Get().routeName
        Hud.Toast("旧旅程已接续到"..routeName.."起点，累计成绩与原地图备份已保留",8)
    end
    if restore_ then
        -- 初始化始发流程可能施加紧急制动；读档只恢复原控制值，不再次重置股道或AI。
        Train.SetThrottle(math.floor(tonumber(restore_.train.throttle) or 0))
        Train.SetBrake(tonumber(restore_.train.brake) or 1)
        PassengerService.RestoreState(restore_.passengers)
        Game.RestoreState(restore_.game)
        if restore_.train.derailed then Train.Derail("恢复事故旅程 · 本局已结束，请重开") end
        Camera.SetMode(restore_.camera or "front_chase")
        paused_=true
        SyncPause()
    end
    Game.UpdateHud(0)
    Camera.Update(0,Train.GetS())
    PassengerService.UpdateVisuals(0)
    application_,initialized_="playing",true
    -- 后台完成加载时保持暂停，回到前台后由玩家手动继续旅程。
    if not focused_ then paused_=true end
    SyncPause()
    UiAudio.ResetJourney()
    if feedback_ then feedback_:Reset(AnnouncementSnapshot(),restore_==nil and not GameModes.IsRage()) end
    UpdateExperienceFeedback(0)
    print("[Main] 功能版本 "..FEATURE_VERSION)
    print(string.format("[Main] 世界构建总耗时 %.2f 秒", os.clock() - t0))
end

local function ReleaseGame()
    CancelTrainSelection("世界已退出，切车请求取消")
    initialized_,restarting_=false,false
    feedback_=nil
    if announcements_ then announcements_:Shutdown();announcements_=nil end
    Environment.Destroy()
    ViewDrag.Shutdown()
    PassengerService.Shutdown()
    Traffic.Shutdown()
    RageAudio.Shutdown()
    if Camera.Shutdown then Camera.Shutdown() end
    WorldStream.Shutdown()
    AudioManager.Shutdown()
    Train.Shutdown()
    renderer:SetNumViewports(0)
    if scene_ then scene_:Dispose();scene_=nil end
end
SaveProgress=function(cloud)
    -- 重开恢复尚未提交时保留上一份完整旅程，不保存新列车位置与旧客流的混合状态。
    if restarting_ then return true end
    if initialized_ then
        local choices={}
        for index,choice in pairs(RailNetwork.GetChoices()) do choices[#choices+1]={index=index,lane=choice.lane} end
        settings_.environment=Environment.Export()
        savedJourney_={mode=GameModes.GetId(),routeId=GameModes.Get().routeId,legacyRouteBackup=legacyRouteBackup_,
            train=Train.ExportState(),passengers=PassengerService.ExportState(),game=Game.ExportState(),
            camera=Camera.GetMode(),choices=choices,environment=Environment.Export()}
        savedJourneys_[GameModes.GetId()]=savedJourney_
    end
    return SaveStore.Write({version=1,settings=settings_,journey=savedJourney_,journeys=savedJourneys_},cloud)
end
local function NormalizeSettings()
    settings_.quality=VisualQuality.Normalize(settings_.quality)
    settings_.sound=settings_.sound~=false
    settings_.music=settings_.music~=false
    settings_.volume=math.max(0,math.min(1,tonumber(settings_.volume) or .75))
    settings_.musicVolume=math.max(0,math.min(1,tonumber(settings_.musicVolume) or .35))
    settings_.ambienceVolume=math.max(0,math.min(1,tonumber(settings_.ambienceVolume) or .45))
    settings_.trainVolume=math.max(0,math.min(1,tonumber(settings_.trainVolume) or 1))
    settings_.announcementVolume=math.max(0,math.min(1,tonumber(settings_.announcementVolume) or .85))
    settings_.sensitivity=math.max(.05,math.min(1,tonumber(settings_.sensitivity) or .20))
    settings_.cloud=settings_.cloud==true
    local environment=type(settings_.environment)=="table" and settings_.environment or {}
    local hour=tonumber(environment.hour) or 12
    if hour~=hour or hour==math.huge or hour==-math.huge then hour=12 end
    settings_.environment={hour=hour%24,running=environment.running~=false,
        weather=(environment.weather=="cloudy" or environment.weather=="rain" or environment.weather=="fog")
            and environment.weather or "clear"}
end
local function ApplySettings()
    NormalizeSettings()
    AudioManager.SetEnabled(settings_.sound);AudioManager.SetVolume(settings_.volume)
    AudioManager.SetTrainVolume(settings_.trainVolume)
    AudioManager.SetAmbienceVolume(settings_.ambienceVolume)
    Soundscape.SetSettings(settings_)
    UiAudio.SetSettings(settings_.sound,settings_.volume,settings_.language)
    if announcements_ then announcements_:SetSettings(settings_) end
    ViewDrag.SetSensitivity(settings_.sensitivity)
    SaveStore.SetCloud(settings_.cloud)
    if initialized_ then
        SetRenderQuality(settings_.quality)
        Hud.SetSoundEnabled(settings_.sound)
        Hud.SetSoundVolume(settings_.volume)
        Hud.SetMusicSettings(settings_.music,settings_.musicVolume)
    end
end
-- 旧档未标模式时属于普通线路；两种地图的里程与时刻表不能交叉恢复。
local function AcceptSavedJourneys(data)
    savedJourneys_={}
    if type(data.journeys)=="table" then
        for _,id in ipairs({"normal","rage"}) do
            local journey=data.journeys[id]
            if type(journey)=="table" and (journey.mode or "normal")==id then
                savedJourneys_[id]=journey
            end
        end
    end
    savedJourney_=type(data.journey)=="table" and data.journey or nil
    if savedJourney_ then
        local id=savedJourney_.mode or "normal"
        if id=="normal" or id=="rage" then savedJourneys_[id]=savedJourney_ else savedJourney_=nil end
    end
end
local function InitMenu()
    Menu.Init({
        start=function(resume,modeId) BeginGame(resume,modeId) end,
        cancel=function() ShowMenu() end,
        click=UiAudio.Click,
        onEnvironmentChanged=ChangeEnvironment,
        actionError=function(actionError)
            -- 菜单动作异常不能静默停留在按压态；把异常送到可见错误页，便于移动端反馈。
            local message="操作未完成："..tostring(actionError)
            print("[Main] 菜单动作异常："..message)
            if application_=="menu" or application_=="settings" then
                application_="error"
                Menu.Error(message)
            end
        end,
        settings=function(values)
            settingsRevision_=settingsRevision_+1
            ApplySettings();SaveProgress(false)
            if settings_.cloud then SaveStore.ReadCloud(function(data)
                if not initialized_ and data then AcceptSavedJourneys(data) end
            end) end
        end,
        back=function()
            if initialized_ then
                Menu.Shutdown();Hud.Init(hudCallbacks_)
                Hud.SetVersion(FEATURE_VERSION)
                Hud.SetEnvironment(Environment.GetStatus())
                local catalog=Train.GetCatalog() --[[@as CabTrainCatalogEntry[] ]]
                Hud.SetTrainCatalog(catalog,Train.GetSelectedId())
                Hud.SetSelectedTrain(Train.GetSelectedId(),Train.GetSelectedName())
                Hud.SetCameraCatalog(Camera.GetPresets(),Camera.GetMode())
                Hud.SetCameraMode(Camera.GetMode(),Camera.GetModeName())
                application_="playing"
                ViewDrag.Init(function()
                    return application_=="playing" and not selectorOpen_
                        and not Hud.IsCameraSelectorOpen() and not Hud.IsVolumePanelOpen()
                end)
                ApplySettings();SyncPause();Game.UpdateHud(0)
                UpdateExperienceFeedback(0)
            else Menu.Show(savedJourney_~=nil) end
        end,
    },settings_,{
        version=FEATURE_VERSION,
        getSavedMode=function() return savedJourney_ and savedJourney_.mode or "normal" end,
        hasSavedMode=function(id) return savedJourneys_[id]~=nil end,
        getEnvironmentState=function()
            return initialized_ and Environment.GetStatus() or settings_.environment
        end,
    })
end
ShowMenu=function()
    loadGeneration_=loadGeneration_+1
    loadingWork_=nil;MediaGate.Cancel();restore_=nil;migration_=nil
    if initialized_ then SaveProgress(true) end
    ReleaseGame();Hud.Shutdown(true)
    application_="menu"
    Soundscape.SetGameMode("normal")
    Soundscape.SetContext("",math.huge,0,false,false)
    Soundscape.SetBlocked(not focused_)
    UiAudio.ResetJourney();UiAudio.SetBlocked(false)
    InitMenu();Menu.Show(savedJourney_~=nil)
    print("[Main] 主菜单就绪；未创建游戏Scene")
end
ShowSettings=function()
    CancelTrainSelection("进入设置，切车请求已取消")
    selectorOpen_=false
    SaveProgress(false)
    paused_=true;SyncPause()
    application_="settings"
    ViewDrag.Shutdown();Hud.Shutdown(true)
    InitMenu();Menu.Settings()
end
BeginGame=function(resume,modeId)
    loadGeneration_=loadGeneration_+1
    local generation=loadGeneration_
    local candidate=resume and (modeId and savedJourneys_[modeId] or savedJourney_) or nil
    local selectedMode=modeId or (candidate and candidate.mode) or "normal"
    if selectedMode~="normal" and selectedMode~="rage" then selectedMode="normal" end
    if candidate and candidate.routeId~=nil and candidate.routeId~=GameModes.Get(selectedMode).routeId
        and not (selectedMode=="rage" and candidate.routeId=="rage_long_corridor_v1")
        and not (selectedMode=="normal" and candidate.routeId=="normal_corridor_v1") then
        application_="error"
        Menu.Error("该旅程来自尚不支持的地图版本，原存档已保留，未载入或迁移")
        print("[Main] 拒绝未知地图版本，未覆盖原存档")
        return
    end
    -- 先选择规则与地图，之后才请求媒体和创建Scene；取消加载不会污染另一模式存档。
    GameModes.Apply(selectedMode)
    Soundscape.SetGameMode(selectedMode)
    restore_=candidate and (candidate.mode or "normal")==selectedMode and candidate or nil
    migration_=nil
    legacyRouteBackup_=restore_ and restore_.legacyRouteBackup or nil
    if restore_ and restore_.routeId~=GameModes.Get().routeId then
        migration_,restore_=restore_,nil
        legacyRouteBackup_=migration_
        print("[Main] 旧地图接续：保留原档与累计成绩，新版本从始发站安全停车开始")
    end
    print(string.format("[Main] 模式=%s，恢复=%s，地图尚未构建",selectedMode,tostring(restore_~=nil)))
    application_="loading"
    Soundscape.SetBlocked(true)
    UiAudio.Click();UiAudio.SetBlocked(true)
    Menu.Loading("准备列车、站台与环境",0,restore_~=nil,selectedMode)
    local id=(restore_ and restore_.train.id) or (migration_ and migration_.train and migration_.train.id) or Catalog.DefaultId
    local paths=MediaGate.ForTrain(id,true)
    -- 进入驾驶前同时门控当前线路的站台、城市、植被、天空与站房资源；
    -- 未完成时不创建Scene，避免玩家看到空站台或模型热替换。
    -- 当前线路是开放端点顺序站场；门禁覆盖当前站及下一站，避免接近下一站时出现资产热替换。
    local requiredStations = {} ---@type integer[]
    requiredStations[1],requiredStations[2] = 1,2
    if restore_ and restore_.game and restore_.game.nextIndex then
        local nextIndex = tonumber(restore_.game.nextIndex)
        if nextIndex and nextIndex >= 1 then
            local firstRequired = math.max(1,math.min(10,nextIndex))
            local secondRequired = math.max(1,math.min(10,nextIndex+1))
            requiredStations[1],requiredStations[2] = firstRequired,secondRequired
        end
    end
    local seenWorld = {} ---@type table<string,boolean>
    for _,stationIndex in ipairs(requiredStations) do
        for _,path in ipairs(MediaGate.ForWorld(stationIndex,settings_.quality)) do
            if not seenWorld[path] then seenWorld[path]=true;paths[#paths+1]=path end
        end
    end
    -- 恢复/默认装配失败时可能尝试蓝白编组；该路径也必须先完整门控。
    for _,fallback in ipairs({Catalog.DefaultId,Catalog.FallbackId}) do
        if id~=fallback then
            for _,path in ipairs(MediaGate.ForTrain(fallback,false)) do paths[#paths+1]=path end
        end
    end
    if GameModes.IsRage() then
        -- 混合交通不能在首个相遇时才解码尚未下载的其他车型。
        for _,entry in ipairs(Catalog.Entries) do
            for _,path in ipairs(MediaGate.ForTrain(entry.id,false)) do paths[#paths+1]=path end
        end
    end
    MediaGate.Begin(paths,function(success,message)
        if generation~=loadGeneration_ then return end
        if not success then application_="error";Menu.Error(message);return end
        loadingWork_=coroutine.create(BuildGame)
    end,function(ratio) Menu.Progress("下载列车、站台与环境资产",ratio*.10) end)
end
function Start()
    LightingDiagnostics.Init()
    renderer:SetNumViewports(0)
    local saved=SaveStore.Load()
    if saved then
        AcceptSavedJourneys(saved)
        for key,value in pairs(saved.settings) do if settings_[key]~=nil then settings_[key]=value end end
    end
    NormalizeSettings()
    Soundscape.Init()
    UiAudio.Init();ApplySettings()
    ShowMenu()
    SubscribeToEvent("Update","HandleUpdate")
    SubscribeToEvent("PostUpdate","HandlePostUpdate")
    SubscribeToEvent("InputFocus","HandleApplicationPaused")
    if settings_.cloud then
        local revision=settingsRevision_
        SaveStore.ReadCloud(function(data)
            if application_=="menu" and data then
                AcceptSavedJourneys(data)
                -- 异步云恢复不能覆盖玩家在等待期间刚修改的设置。
                if revision==settingsRevision_ and type(data.settings)=="table" then
                    for key,value in pairs(data.settings) do
                        if settings_[key]~=nil then settings_[key]=value end
                    end
                    ApplySettings()
                end
                Menu.Show(savedJourney_~=nil)
            end
        end)
    end
end
function Stop()
    if initialized_ then SaveProgress(true) end
    loadGeneration_=loadGeneration_+1;loadingWork_=nil;MediaGate.Cancel()
    ReleaseGame();Hud.Shutdown();UiAudio.Shutdown();Soundscape.Shutdown()
    LightingDiagnostics.Shutdown()
end
---@param eventType string
---@param eventData InputFocusEventData
function HandleApplicationPaused(eventType,eventData)
    focused_=eventData:GetBool("Focus")
    if not focused_ then
        Soundscape.SetBlocked(true)
        AudioManager.SetSuspended(true)
        UiAudio.SetBlocked(true)
        if initialized_ then SaveProgress(true);paused_=true;SyncPause() end
    elseif initialized_ then
        SyncPause()
    else
        local blocked=application_=="loading"
        Soundscape.SetBlocked(blocked)
        UiAudio.SetBlocked(blocked)
    end
end
function GetApplicationState() return application_ end
function GetGameScene() return scene_ end
function BeginJourney(resume,modeId) BeginGame(resume==true,modeId) end
function GetGameMode() return GameModes.GetId() end
function ReturnToMainMenu() ShowMenu() end
function SaveJourneyNow() return SaveProgress(true) end

-- ============================================================================
-- 光照
-- ============================================================================

-- 显式创建日间光照，不依赖包含编辑器专用资源的预设。
function CreateLighting()
    if not scene_ then return end
    local group = scene_:CreateChild("DayLighting")
    local zone = group:CreateComponent("Zone")
    zone.ambientSource = AMBIENT_COLOR
    zone.ambientColor = Color(0.20, 0.23, 0.26)
    -- 开放线路按实际采样包络覆盖，不能继续使用旧环线的固定±60km范围。
    local bounds = BoundingBox()
    for _, point in ipairs(Route.GetPoints()) do
        bounds:Merge(point.pos - Vector3(3000, 1000, 3000))
        bounds:Merge(point.pos + Vector3(3000, 2000, 3000))
    end
    zone.boundingBox = bounds
    local sunNode = group:CreateChild("Sun")
    sunNode.direction = Vector3(0.45, -1.0, 0.55)
    local sun = sunNode:CreateComponent("Light")
    sun.lightType = LIGHT_DIRECTIONAL
    -- 真实积云天空（官方写实 cubemap；不可用时自动回退程序化渐变）。
    Sky.Create(scene_, VisualQuality.Get(renderQuality_))
    -- 雾/后效/太阳参数统一由画质档下发。
    ApplyAtmosphere(group, VisualQuality.Get(renderQuality_))
    assert(Environment.Init(scene_,group,{quality=VisualQuality.Get(renderQuality_),skyNode=scene_:GetChild("Sky"),
        hour=settings_.environment.hour,running=settings_.environment.running,weather=settings_.environment.weather}),
        "时间天气环境初始化失败")
    print("[Main] 统一天空、太阳、雾与昼夜天气已加载（不改变驾驶动力）")
end

-- ============================================================================
-- 暂停
-- ============================================================================

---@param mode? string
function ChangeHeadlightMode(mode)
    if not initialized_ or application_~="playing" then return false end
    local selected=mode or (Train.GetHeadlightMode()=="auto" and "on"
        or (Train.GetHeadlightMode()=="on" and "off" or "auto"))
    if not Train.SetHeadlightMode(selected) then return false end
    UpdateDriveStatus()
    Hud.Toast("车灯："..(selected=="auto" and "自动随昼夜" or (selected=="on" and "手动开启" or "手动关闭")),2)
    SaveProgress(false)
    return true
end

function UpdateDriveStatus()
    local diagnostics=Soundscape.GetDiagnostics()
    local code=diagnostics.mutedReasonCode
    local musicState="loading"
    if code=="sound_off" or code=="master_zero" or code=="bus_muted" then musicState="muted"
    elseif code=="music_off" then musicState="disabled"
    elseif code=="music_zero" then musicState="volume0"
    elseif code=="blocked" then musicState="paused"
    elseif code=="load_error" then musicState="error"
    elseif code=="device_uninitialized" or code=="device_stopped" then musicState="device"
    elseif code=="" and diagnostics.isPlaying then musicState="playing" end
    local position,tangent=Train.GetTrackSample(Train.GetS())
    local horizontal=math.sqrt(tangent.x*tangent.x+tangent.z*tangent.z)
    Hud.SetDriveStatus({headlightMode=Train.GetHeadlightMode(),headlightOn=Train.GetHeadlightDiagnostics().enabled,
        musicTitle=diagnostics.title,musicState=musicState,musicVolume=settings_.musicVolume,musicEnabled=settings_.music,
        grade=horizontal>1e-8 and tangent.y/horizontal or 0,elevation=position.y})
end

function ReverseTrain()
    if Train.IsDerailed() then return end
    local passengers = Game.GetPassengerStatus()
    if passengers.doorsOpen or passengers.phase == "door_closing" then
        Hud.Toast("乘客正在乘降，请待车门关闭后换向", 2)
        return
    end
    local reversing,changed,message = Train.ToggleReversing()
    if changed==false then Hud.Toast(message or "当前进路不允许换向",3);return end
    if feedback_ then feedback_:Reset(AnnouncementSnapshot(),false) end
    Hud.SetReversing(reversing)
    Hud.Toast(message or (reversing and "换向：后退" or "换向：前进"), 2.5)
end

function RestartJourney()
    if not initialized_ or restarting_ then return end
    CancelTrainSelection("重新开始旅程，取消切车")
    loadGeneration_=loadGeneration_+1
    local generation=loadGeneration_
    restarting_=true
    Hud.SetTrainSelectorOpen(false)
    Hud.SetCameraSelectorOpen(false)
    Train.Reset(assert(Route.GetStations()[1]).s+1)
    Traffic.Reset()
    RoadCorridor.ResetTraffic()
    simulationDebt_,frameSimulated_,totalSimulated_=0,0,0
    paused_,selectorOpen_,brakeHeld_,touchBrakeHeld_ = true,false,false,false
    application_="loading"
    SyncPause()
    local viewport=assert(renderer:GetViewport(0))
    renderer:SetNumViewports(0)
    Hud.Shutdown(true)
    InitMenu()
    Menu.Loading("正在恢复始发站台与站场，请稍候",0,false,GameModes.GetId())
    loadingWork_=coroutine.create(function()
        local steps=0
        WorldStream.Reset(Train.GetS(),function()
            steps=steps+1
            Menu.Progress("恢复站台、雨棚、天桥与站场",math.min(.94,steps/(steps+80)))
            coroutine.yield()
        end)
        if generation~=loadGeneration_ then return end
        assert(WorldStream.IsStationReady(1),"始发站实体未完成，不能恢复驾驶")
        Camera.SetMode("chase")
        Camera.Update(0,Train.GetS())
        Menu.Shutdown()
        Hud.Init(hudCallbacks_)
        Hud.SetGameMode(GameModes.GetId())
        Hud.SetVersion(FEATURE_VERSION)
        Hud.SetTrainCatalog(Train.GetCatalog() --[[@as CabTrainCatalogEntry[] ]],Train.GetSelectedId())
        Hud.SetSelectedTrain(Train.GetSelectedId(),Train.GetSelectedName())
        Hud.SetCameraCatalog(Camera.GetPresets(),Camera.GetMode())
        Hud.SetCameraMode(Camera.GetMode(),Camera.GetModeName())
        Hud.SetDrivingMode(Train.GetDrivingMode()=="relaxed" and "休闲牵引" or "模拟牵引")
        -- 先恢复 HUD，再建立新旅程的站序、候车队列和小地图，避免重建控件清掉始发提示。
        Hud.SetEnvironment(Environment.GetStatus())
        Game.Setup()
        ApplySettings()
        if SyncVolumeSettings then SyncVolumeSettings() end
        paused_,restarting_=not focused_,false
        application_="playing"
        renderer:SetNumViewports(1);renderer:SetViewport(0,viewport)
        SyncPause()
        Game.UpdateHud(0)
        PassengerService.UpdateVisuals(0)
        UiAudio.ResetJourney()
        if feedback_ then feedback_:Reset(AnnouncementSnapshot(),not GameModes.IsRage()) end
        UpdateExperienceFeedback(0)
        print("[Main] 事故重开：始发站实体已完成，恢复驾驶与真实登乘")
    end)
end
-- 暂停真实玩法/时钟后只切视口开关，灯位、强度、材质和机位保持不变；不自动恢复驾驶。
---@param selected boolean
---@return boolean
SelectLightingCluster=function(selected)
    if application_~="playing" or selectorOpen_ or Train.IsDerailed() then return false end
    paused_=true
    SyncPause()
    if not LightingDiagnostics.SelectCluster(selected) then
        Hud.Toast("灯光路径切换未确认，已保持暂停；请回传调试日志",6)
        return false
    end
    Hud.SetLightingDiagnosticsStatus(LightingDiagnostics.GetClusterStatus())
    Hud.Toast((selected and "已选 A 集群" or "已选 B 非集群").."，已暂停。保持视角等待预热完成，再切另一组或提交反馈",8)
    return true
end

function TogglePause()
    if selectorOpen_ or Train.IsDerailed() then return end
    paused_ = not paused_
    SyncPause()
    Hud.Toast(paused_ and "已暂停" or "继续行驶", 1.5)
end

-- ============================================================================
-- 更新
-- ============================================================================

---@param eventType string
---@param eventData UpdateEventData
function HandleUpdate(eventType, eventData)
    local wallDt = math.max(0, eventData:GetFloat("TimeStep"))
    if initialized_ and application_=="playing" then
        local passenger=PassengerService.GetStatus()
        Soundscape.SetContext(Camera.GetMode(),Game.GetNearestStationDistance(),
            passenger.onboard,passenger.doorsOpen,true)
    else
        Soundscape.SetContext("",math.huge,0,false,false)
    end
    if application_=="loading" then
        Soundscape.Update(wallDt)
        if loadingWork_ then
            local work=loadingWork_
            local ok,message=true,nil
            local started=os.clock()
            for _=1,64 do
                ok,message=coroutine.resume(work)
                if not ok or coroutine.status(work)=="dead" or os.clock()-started>=.006 then break end
            end
            if not ok then
                loadingWork_=nil;ReleaseGame();Hud.Shutdown(true);InitMenu()
                application_="error";Menu.Error("场景加载失败："..tostring(message))
                print("[Main] 加载失败，已释放半成品："..tostring(message))
            elseif coroutine.status(work)=="dead" then loadingWork_=nil;restore_=nil;migration_=nil;SaveProgress(false) end
        end
        return
    end
    if application_~="playing" then Soundscape.Update(wallDt);return end
    -- 广播在本帧列车/背景预算更新后驱动，避免加载时播报或沿用上一帧预算。
    saveTimer_=saveTimer_+wallDt
    if saveTimer_>=20 then saveTimer_=0;SaveProgress(true) end
    HandleKeyboard(math.min(wallDt, .2))
    frameSimulated_ = 0
    if IsPaused() then simulationDebt_ = 0;Soundscape.Update(wallDt);return end
    -- 低帧率不能每帧丢掉0.1秒以外的时间。用固定步长消化真实时间，积欠保留到下一帧。
    -- 长时间切后台不一次追赶数分钟；最多保留2秒，避免恢复时瞬间冲过信号/站台。
    simulationDebt_ = math.min(2, simulationDebt_ + wallDt)
    for _ = 1, MAX_STEPS do
        if simulationDebt_ + 1e-9 < STEP then break end
        simulationDebt_ = math.max(0, simulationDebt_ - STEP)
        frameSimulated_ = frameSimulated_ + STEP
        totalSimulated_ = totalSimulated_ + STEP
        if brakeHeld_ or touchBrakeHeld_ then
            Train.AddBrake(1.6 * STEP)
            if Train.GetThrottle() > 0 then Train.SetThrottle(0) end
        end
        -- 先执行客运联锁，直接设置Train油门也不能绕过开门/登乘检查。
        Game.EnforceDepartureInterlock()
        Traffic.Update(STEP)
        -- 手动驾驶：信号/曲线仅警告，不自动收油制动；实际冲突触发事故。
        Train.Update(STEP)
        Traffic.CheckPlayerCollision()
        if Train.IsDerailed() and Camera.IsCabView() then Camera.SetMode("front_chase") end
        Environment.Advance(STEP)
        Game.Update(STEP)
    end
    local environment = Landmarks.GetEnvironmentAt(Train.GetS())
    AudioManager.SetEnvironment(environment == "urban" and "city"
        or (environment == "water" and "river" or environment))
    AudioManager.Update(frameSimulated_, Train.GetSpeedKmh(), Train.GetThrottle(),
        Game.GetNearestStationDistance())
    Soundscape.Update(wallDt)
    UpdateExperienceFeedback(frameSimulated_)
    UiAudio.Update()
end

---@param eventType string
---@param eventData PostUpdateEventData
function HandlePostUpdate(eventType, eventData)
    if application_~="playing" then
        LightingDiagnostics.Update(eventData:GetFloat("TimeStep"),application_,nil)
        return
    end
    local dt = eventData:GetFloat("TimeStep")
    if dt > 0.1 then dt = 0.1 end

    Train.UpdateVisuals(IsPaused() and 0 or frameSimulated_)
    Traffic.UpdateVisuals(IsPaused() and 0 or frameSimulated_)
    StationYard.UpdateSignals(Traffic)
    local lead = Train.GetLeadNode()
    if lead then AudioManager.SetTrainPose(lead.worldPosition, lead.worldRotation) end
    Camera.Update(dt, Train.GetS())
    Environment.SetSheltered(Camera.IsCabView())
    local cameraNode=Camera.GetNode()
    Environment.Update(0,cameraNode and cameraNode.worldPosition or Train.GetHeadPosition(),Camera.GetLightingFocus())
    local atmosphere=Environment.GetStatus()
    Station.SetEnvironment(atmosphere.lampFactor)
    Soundscape.SetEnvironment(atmosphere)
    Train.UpdateHeadlight(atmosphere.lampFactor)
    UpdateDriveStatus()
    local listenerPosition=cameraNode and cameraNode.worldPosition or Train.GetHeadPosition()
    local impacts=Traffic.DrainImpactEvents(32) --[[@as RailwayRageAudioEvent[] ]]
    RageAudio.Update(dt,impacts,settings_,listenerPosition)
    -- 选择器/用户暂停期间也补齐当前画面，但不会推进车辆和玩法。
    WorldStream.Update(Train.GetS(), dt)
    RoadCorridor.Update(IsPaused() and 0 or frameSimulated_,Train.GetS())
    RailwayInfrastructure.Update(IsPaused() and 0 or frameSimulated_,Train,Traffic)
    PassengerService.UpdateVisuals(IsPaused() and 0 or frameSimulated_)
    LightingDiagnostics.Update(eventData:GetFloat("TimeStep"),application_,scene_)
    Hud.SetLightingDiagnosticsStatus(LightingDiagnostics.GetClusterStatus())
end

-- 只读计时统计，供验收核实低帧率没有永久丢弃普通帧的时间。
function GetFrameSimulationStats()
    return {simulated = frameSimulated_, debt = simulationDebt_, total = totalSimulated_}
end

-- ============================================================================
-- 键盘
-- ============================================================================

---@param dt number
function HandleKeyboard(dt)
    if selectorOpen_ or Train.IsDerailed() then
        brakeHeld_, touchBrakeHeld_ = false, false
        return
    end
    -- 油门
    if input:GetKeyPress(KEY_W) then Game.ThrottleUp() end
    if input:GetKeyPress(KEY_S) then Game.ThrottleDown() end

    -- 刹车（按住）
    if input:GetKeyDown(KEY_SPACE) then
        brakeHeld_ = true
    else
        brakeHeld_ = false
    end
    if input:GetKeyPress(KEY_X) then Game.EmergencyBrake() end
    if input:GetKeyPress(KEY_B) and not Game.IsDwelling() then Train.SetBrake(0) end

    -- 汽笛和手动车灯
    if input:GetKeyPress(KEY_H) then Game.Horn() end
    if input:GetKeyPress(KEY_L) then ChangeHeadlightMode() end

    -- 换向
    if input:GetKeyPress(KEY_R) then ReverseTrain() end

    -- 道岔
    if input:GetKeyPress(KEY_Q) then Game.SetSwitch(-1) end
    if input:GetKeyPress(KEY_E) then Game.SetSwitch(1) end

    -- 视角
    if input:GetKeyPress(KEY_C) then
        Camera.CycleMode()
        Hud.SetCameraMode(Camera.GetMode(), Camera.GetModeName())
    end
    if input:GetKeyDown(KEY_A) then Camera.AddYaw(-110 * dt) end
    if input:GetKeyDown(KEY_D) then Camera.AddYaw(110 * dt) end
    if input:GetKeyDown(KEY_UP) then Camera.AddPitch(-40 * dt) end
    if input:GetKeyDown(KEY_DOWN) then Camera.AddPitch(40 * dt) end

    -- 暂停
    if input:GetKeyPress(KEY_P) then TogglePause() end
end
