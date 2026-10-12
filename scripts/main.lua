-- ============================================================================
-- 火车驾驶模拟 - 主入口
-- 星澜群域：五站架空客运干线、六款独立车队、乘降与驾驶运营
-- ============================================================================

local GameConfig = require "config.GameConfig"
local Route = require "world.Route"
local WorldStream = require "world.WorldStream"
local SkyUtils = require "urhox-libs.Rendering.SkyUtils"
local Train = require "train.Train"
local Camera = require "train.Camera"
local Hud = require "ui.Hud"
local AudioManager = require "audio.AudioManager"
local Game = require "game.Game"
local Traffic = require "game.Traffic"
local StationYard = require "world.StationYard"
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
local application_ = "menu"
local loadGeneration_ = 0
---@type thread?
local loadingWork_ = nil
---@type table?
local restore_ = nil
local saveTimer_ = 0.0
local savedJourney_ = nil ---@type table?
local settings_ = {quality="performance",sound=true,volume=.55,language="both",sensitivity=.20,cloud=false}
---@type fun()
local ShowMenu
---@type fun(restore:boolean)
local BeginGame
---@type fun()
local ShowSettings
---@type fun(cloud:boolean):boolean
local SaveProgress
local initialized_ = false
local hudCallbacks_ = {} ---@type CabHudCallbacks

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
local STEP = .02
local MAX_STEPS = 50
local renderQuality_ = GameConfig.RenderQuality or "performance"

-- 菜单暂停和用户暂停独立；关菜单不能把原本已暂停的游戏自动恢复。
local function IsPaused() return paused_ or selectorOpen_ end

local function SyncPause()
    local paused = IsPaused()
    if paused then simulationDebt_, frameSimulated_ = 0, 0 end
    Hud.SetPaused(paused)
    AudioManager.SetSuspended(paused)
    PassengerService.SetPaused(paused)
    UiAudio.SetBlocked(paused)
    ViewDrag.Reset()
    if paused then brakeHeld_, touchBrakeHeld_ = false, false end
end

---@param id string
---@return boolean, string
function SelectTrain(id)
    if math.abs(Train.GetSpeedKmh()) > 0.1 then
        return false, "请先停稳后再换车"
    end
    local passengers = PassengerService.GetStatus()
    if passengers.onboard + passengers.waiting > PassengerService.GetCapacity(id) then
        return false,"该编组容量不足，请完成当前旅程清客后再换车"
    end
    local paths=MediaGate.ForTrain(id,false)
    for _,path in ipairs(paths) do
        if not cache:Exists(path) then
            MediaGate.Begin(paths,function(success,message)
                if application_~="playing" then return end
                if success then
                    local selected,result=SelectTrain(id)
                    Hud.Toast(result,3)
                else Hud.Toast(message,3) end
            end)
            return false,"正在下载该车型涂装和声音，完成后自动换车"
        end
    end
    local ok, message = Train.Select(id)
    if not ok then return false, message end
    brakeHeld_, touchBrakeHeld_ = false, false
    Hud.SetSelectedTrain(Train.GetSelectedId(), Train.GetSelectedName())
    AudioManager.SetTrainId(Train.GetSelectedId())
    AudioManager.SetPowerType(Train.GetPowerType())
    local lead = Train.GetLeadNode()
    if lead then AudioManager.SetTrainPose(lead.worldPosition, lead.worldRotation) end
    PassengerService.RefreshDoorPlan()
    Game.UpdateHud(0)
    print("[Main] 换车完成，保留站序/经验/线路位置: " .. Train.GetSelectedName())
    return true, message
end

-- 画质只改变渲染负载，不改线路、AI班次、碰撞界或动力参数。
---@param quality string
---@return boolean
function SetRenderQuality(quality)
    if quality ~= "performance" and quality ~= "detailed" then return false end
    renderQuality_ = quality
    settings_.quality=quality
    local detailed = quality == "detailed"
    renderer.dynamicInstancing = true
    renderer.drawShadows = detailed
    renderer.specularLighting = detailed
    renderer.materialQuality = detailed and QUALITY_HIGH or QUALITY_MEDIUM
    renderer.shadowMapSize = 1024
    -- 玩家模型保持相同细节；远处AI在自身drawable上独立使用LOD偏置。
    local camera = Camera.GetCamera()
    if camera then camera.lodBias = 1 end
    if scene_ then
        local lighting = scene_:GetChild("DayLighting")
        local zone = lighting and lighting:GetComponent("Zone")
        if zone then
            zone.ssrEnabled = false
            zone.ssgiEnabled = false
            zone.motionBlurEnabled = false
            zone.volumetricFogEnabled = false
        end
        local sun = lighting and lighting:GetComponent("Light", true)
        if sun then sun.shadowCascade = CascadeParameters(80.0, 0.0, 0.0, 0.0, .85) end
    end
    Hud.SetRenderQuality(detailed and "细致" or "流畅")
    print("[Main] 画质 -> " .. (detailed and "细致：单级近景阴影/镜面" or "流畅：关闭实时阴影/镜面，保留双线与列车"))
    return true
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
    paused_, selectorOpen_ = false, false
    brakeHeld_, touchBrakeHeld_ = false, false

    scene_ = Scene()
    local octree = scene_:CreateComponent("Octree")
    scene_:CreateComponent("DebugRenderer")

    Route.Build()
    -- 五站分布在33公里开放走廊，默认八叉树范围不包含远站。
    -- 渲染、相机三角射线都使用同一全线包络；流式加载量仍按WorldStream预算限制。
    local worldBounds = BoundingBox()
    for _, point in ipairs(Route.GetPoints()) do
        worldBounds:Merge(point.pos - Vector3(3000, 1000, 3000))
        worldBounds:Merge(point.pos + Vector3(3000, 2000, 3000))
    end
    octree:SetSize(worldBounds, 8)
    print(string.format("[Main] 全线八叉树 %.0f×%.0f×%.0f米，8级；覆盖后四站射线/渲染",worldBounds.size.x,worldBounds.size.y,worldBounds.size.z))
    CreateLighting()
    -- 首次从星汐总站内开始，完整编组、站前街区与候车乘客都在视野内。
    local firstStation = Route.GetStations()[1]
    -- 停靠点后1米仍在站台内；Game会先完成始发登乘，再选择下一站。
    local initialS = restore_ and restore_.train.s or (firstStation and firstStation.s + 1 or 0)
    LoadingStage("构建车站与连续轨道",.65)
    -- WorldStream 把 0..1 的局部构建进度回传，映射到加载页 0.55..0.80 区间。
    WorldStream.Build(scene_, initialS, function(ratio)
        LoadingStage("加载站场、街区与地貌", .55 + .25 * math.max(0, math.min(1, ratio or 0)))
    end)
    LoadingStage("装配列车",.82)
    Train.Build(scene_)
    if restore_ and restore_.train.id~=Train.GetSelectedId() then assert(Train.Select(restore_.train.id)) end
    Train.Reset(initialS)
    LoadingStage("准备行车与相机",.87)
    Traffic.Init(scene_)
    Camera.Build(scene_)
    renderer.dynamicInstancing = true
    renderer.shadowMapSize = 1024
    local cameraNode = assert(Camera.GetNode())
    local listener = cameraNode:CreateComponent("SoundListener")
    audio:SetListener(listener)

    AudioManager.Init(scene_, scene_:GetChild("Train"), Train.GetPowerType(), Train.GetSelectedId())
    PassengerService.Init(scene_)
    LoadingStage("准备驾驶界面",.95)
    LoadingStage("旅程准备完成",1)
    Menu.Shutdown()
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
            SetRenderQuality(renderQuality_ == "performance" and "detailed" or "performance")
        end,
        onRestart = function() RestartJourney() end,
        onSoundVolume = function(value) settings_.volume=value;AudioManager.SetVolume(value);UiAudio.SetSettings(settings_.sound,value,settings_.language) end,
        onSoundToggle = function(enabled)
            settings_.sound=enabled
            UiAudio.SetSettings(enabled,settings_.volume,settings_.language)
            AudioManager.SetEnabled(enabled)
            Hud.SetSoundEnabled(AudioManager.IsEnabled())
        end,
        onPause = function() TogglePause() end,
        onSelectTrain = SelectTrain,
        onOpenTrainSelector = function(open)
            selectorOpen_ = open
            SyncPause()
            print("[Main] 车型选择器 " .. (open and "打开" or "关闭"))
        end,
    }
    Hud.Init(hudCallbacks_)
    local catalog = Train.GetCatalog() --[[@as CabTrainCatalogEntry[] ]]
    Hud.SetTrainCatalog(catalog, Train.GetSelectedId())
    Hud.SetSelectedTrain(Train.GetSelectedId(), Train.GetSelectedName())
    Hud.SetCameraCatalog(Camera.GetPresets(), Camera.GetMode())
    Hud.SetCameraMode(Camera.GetMode(), Camera.GetModeName())
    Hud.SetDrivingMode(Train.GetDrivingMode() == "relaxed" and "休闲牵引" or "模拟牵引")
    Hud.SetSoundEnabled(AudioManager.IsEnabled())
    SetRenderQuality(settings_.quality)
    AudioManager.SetEnabled(settings_.sound)
    AudioManager.SetVolume(settings_.volume)
    Hud.SetSoundEnabled(settings_.sound)
    UiAudio.SetSettings(settings_.sound,settings_.volume,settings_.language)
    ViewDrag.Init(function() return application_=="playing" and not selectorOpen_ and not Hud.IsCameraSelectorOpen() end)
    ViewDrag.SetSensitivity(settings_.sensitivity)
    SyncPause()
    simulationDebt_, frameSimulated_, totalSimulated_ = 0, 0, 0

    Game.Init()
    if restore_ then
        Train.RestoreState(restore_.train)
        RailNetwork.RestoreChoices(restore_.choices or {})
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
    UiAudio.ResetJourney()
    UiAudio.Boarding("stop:"..PassengerService.GetStats().visits)
    print(string.format("[Main] 世界构建总耗时 %.2f 秒", os.clock() - t0))
end

local function ReleaseGame()
    initialized_=false
    ViewDrag.Shutdown()
    PassengerService.Shutdown()
    Traffic.Shutdown()
    if Camera.Shutdown then Camera.Shutdown() end
    WorldStream.Shutdown()
    AudioManager.Shutdown()
    Train.Shutdown()
    renderer:SetNumViewports(0)
    if scene_ then scene_:Dispose();scene_=nil end
end
SaveProgress=function(cloud)
    if initialized_ then
        local choices={}
        for index,choice in pairs(RailNetwork.GetChoices()) do choices[#choices+1]={index=index,lane=choice.lane} end
        savedJourney_={train=Train.ExportState(),passengers=PassengerService.ExportState(),game=Game.ExportState(),
            camera=Camera.GetMode(),choices=choices}
    end
    return SaveStore.Write({version=1,settings=settings_,journey=savedJourney_},cloud)
end
local function ApplySettings()
    AudioManager.SetEnabled(settings_.sound);AudioManager.SetVolume(settings_.volume)
    UiAudio.SetSettings(settings_.sound,settings_.volume,settings_.language)
    ViewDrag.SetSensitivity(settings_.sensitivity)
    SaveStore.SetCloud(settings_.cloud)
    if initialized_ then SetRenderQuality(settings_.quality);Hud.SetSoundEnabled(settings_.sound) end
end
local function InitMenu()
    Menu.Init({
        start=function(resume) BeginGame(resume) end,
        cancel=function() ShowMenu() end,
        click=UiAudio.Click,
        settings=function(values)
            ApplySettings();SaveProgress(false)
            if settings_.cloud then SaveStore.ReadCloud(function(data)
                if not initialized_ and data then savedJourney_=data.journey end
            end) end
        end,
        back=function()
            if initialized_ then
                Menu.Shutdown();Hud.Init(hudCallbacks_)
                local catalog=Train.GetCatalog() --[[@as CabTrainCatalogEntry[] ]]
                Hud.SetTrainCatalog(catalog,Train.GetSelectedId())
                Hud.SetSelectedTrain(Train.GetSelectedId(),Train.GetSelectedName())
                Hud.SetCameraCatalog(Camera.GetPresets(),Camera.GetMode())
                Hud.SetCameraMode(Camera.GetMode(),Camera.GetModeName())
                application_="playing"
                ViewDrag.Init(function() return application_=="playing" and not selectorOpen_ and not Hud.IsCameraSelectorOpen() end)
                ApplySettings();SyncPause();Game.UpdateHud(0)
            else Menu.Show(savedJourney_~=nil) end
        end,
    },settings_)
end
ShowMenu=function()
    loadGeneration_=loadGeneration_+1
    loadingWork_=nil;MediaGate.Cancel();restore_=nil
    if initialized_ then SaveProgress(true) end
    ReleaseGame();Hud.Shutdown(true)
    application_="menu"
    UiAudio.ResetJourney();UiAudio.SetBlocked(false)
    InitMenu();Menu.Show(savedJourney_~=nil)
    print("[Main] 主菜单就绪；未创建游戏Scene")
end
ShowSettings=function()
    SaveProgress(false)
    paused_=true;SyncPause()
    application_="settings"
    ViewDrag.Shutdown();Hud.Shutdown(true)
    InitMenu();Menu.Settings()
end
BeginGame=function(resume)
    loadGeneration_=loadGeneration_+1
    local generation=loadGeneration_
    restore_=resume and savedJourney_ or nil
    application_="loading"
    UiAudio.Click();UiAudio.SetBlocked(true)
    Menu.Loading("准备人物、涂装与声音",0,resume)
    local id=restore_ and restore_.train.id or Catalog.DefaultId
    local paths=MediaGate.ForTrain(id,true)
    if id~=Catalog.DefaultId then
        for _,path in ipairs(MediaGate.ForTrain(Catalog.DefaultId,false)) do paths[#paths+1]=path end
    end
    MediaGate.Begin(paths,function(success,message)
        if generation~=loadGeneration_ then return end
        if not success then application_="error";Menu.Error(message);return end
        loadingWork_=coroutine.create(BuildGame)
    end,function(ratio) Menu.Progress("下载人物动画、涂装与声音",ratio*.60) end)
end
function Start()
    renderer:SetNumViewports(0)
    local saved=SaveStore.Load()
    if saved then
        savedJourney_=saved.journey
        for key,value in pairs(saved.settings) do if settings_[key]~=nil then settings_[key]=value end end
    end
    settings_.quality=settings_.quality=="detailed" and "detailed" or "performance"
    settings_.volume=math.max(0,math.min(1,tonumber(settings_.volume) or .55))
    UiAudio.Init();ApplySettings()
    ShowMenu()
    SubscribeToEvent("Update","HandleUpdate")
    SubscribeToEvent("PostUpdate","HandlePostUpdate")
    SubscribeToEvent("InputFocus","HandleApplicationPaused")
    if settings_.cloud then SaveStore.ReadCloud(function(data)
        if application_=="menu" and data then savedJourney_=data.journey;Menu.Show(savedJourney_~=nil) end
    end) end
end
function Stop()
    if initialized_ then SaveProgress(true) end
    loadGeneration_=loadGeneration_+1;loadingWork_=nil;MediaGate.Cancel()
    ReleaseGame();Hud.Shutdown();UiAudio.Shutdown()
end
---@param eventType string
---@param eventData InputFocusEventData
function HandleApplicationPaused(eventType,eventData)
    if initialized_ and not eventData:GetBool("Focus") then SaveProgress(true);paused_=true;SyncPause() end
end
function GetApplicationState() return application_ end
function GetGameScene() return scene_ end
function BeginJourney(resume) BeginGame(resume==true) end
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
    zone.ambientColor = Color(0.16, 0.18, 0.21)
    -- 开放线路按实际采样包络覆盖，不能继续使用旧环线的固定±60km范围。
    local bounds = BoundingBox()
    for _, point in ipairs(Route.GetPoints()) do
        bounds:Merge(point.pos - Vector3(3000, 1000, 3000))
        bounds:Merge(point.pos + Vector3(3000, 2000, 3000))
    end
    zone.boundingBox = bounds
    zone.fogColor = Color(0.59, 0.66, 0.71)
    zone.fogStart = 700.0
    zone.fogEnd = 2300.0
    -- 显式使用解析 ACES，避免离屏 GLES 环境的 3D LUT Shader 编译失败。
    zone.tonemapMode = TONEMAP_MODE_ACES
    zone.vignetteEnabled = false
    -- 亚像素接触线和薄雨棚边缘使用FXAA，避免移动端近景锯齿。
    zone.fxaaEnabled = true
    -- 固定日间曝光，避免移动端多一组全屏亮度直方图。
    zone.autoExposureEnabled = false
    local sunNode = group:CreateChild("Sun")
    sunNode.direction = Vector3(0.45, -1.0, 0.55)
    local sun = sunNode:CreateComponent("Light")
    sun.lightType = LIGHT_DIRECTIONAL
    if sun then
        sun.color = Color(1.0, 0.96, 0.88)
        sun.brightness = 1.15
        sun.castShadows = true
        sun.shadowBias = BiasParameters(0.00025, 0.5)
        sun.shadowCascade = CascadeParameters(20.0, 80.0, 320.0, 0.0, 0.85)
    end
    -- 程序化渐变仍由库创建；官方默认天空依赖已补齐真实XML与六面KTX资源。
    SkyUtils.CreateGradientSky(scene_, {
        zenith = Color(0.16, 0.32, 0.54),
        horizon = zone.fogColor,
        ground = Color(0.32, 0.37, 0.29),
        skyExp = 0.65,
        hdrBoost = 1.45,
    })
    print("[Main] 日间太阳光、渐变天空、低饱和远景雾与ACES已加载")
end

-- ============================================================================
-- 暂停
-- ============================================================================

function ReverseTrain()
    if Train.IsDerailed() then return end
    local passengers = Game.GetPassengerStatus()
    if passengers.doorsOpen or passengers.phase == "door_closing" then
        Hud.Toast("乘客正在乘降，请待车门关闭后换向", 2)
        return
    end
    local reversing = Train.ToggleReversing()
    Hud.SetReversing(reversing)
    Hud.Toast(reversing and "换向：后退" or "换向：前进", 1.5)
end

function RestartJourney()
    Hud.SetTrainSelectorOpen(false)
    Hud.SetCameraSelectorOpen(false)
    Train.Reset(assert(Route.GetStations()[1]).s+1)
    Traffic.Reset()
    simulationDebt_,frameSimulated_,totalSimulated_=0,0,0
    paused_,selectorOpen_,brakeHeld_,touchBrakeHeld_ = false,false,false,false
    Hud.HideGameOver()
    Hud.HideBanner()
    Game.Setup()
    SyncPause()
    Camera.SetMode("chase")
    Game.UpdateHud(0)
    UiAudio.ResetJourney();SaveProgress(false)
    print("[Main] 事故状态清除，新旅程重新始发登乘")
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
    UiAudio.Update()
    if application_=="loading" then
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
            elseif coroutine.status(work)=="dead" then loadingWork_=nil;restore_=nil;SaveProgress(false) end
        end
        return
    end
    if application_~="playing" then return end
    saveTimer_=saveTimer_+wallDt
    if saveTimer_>=20 then saveTimer_=0;SaveProgress(true) end
    local passenger=PassengerService.GetStatus()
    if passenger.doorsOpen then UiAudio.Boarding("stop:"..PassengerService.GetStats().visits) end
    HandleKeyboard(math.min(wallDt, .2))
    frameSimulated_ = 0
    if IsPaused() then simulationDebt_ = 0; return end
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
        Game.Update(STEP)
    end
    local environment = Landmarks.GetEnvironmentAt(Train.GetS())
    AudioManager.SetEnvironment(environment == "urban" and "city"
        or (environment == "water" and "river" or environment))
    AudioManager.Update(frameSimulated_, Train.GetSpeedKmh(), Train.GetThrottle(),
        Game.GetNearestStationDistance())
end

---@param eventType string
---@param eventData PostUpdateEventData
function HandlePostUpdate(eventType, eventData)
    if application_~="playing" then return end
    local dt = eventData:GetFloat("TimeStep")
    if dt > 0.1 then dt = 0.1 end

    Train.UpdateVisuals(IsPaused() and 0 or frameSimulated_)
    Traffic.UpdateVisuals(IsPaused() and 0 or frameSimulated_)
    StationYard.UpdateSignals(Traffic)
    local lead = Train.GetLeadNode()
    if lead then AudioManager.SetTrainPose(lead.worldPosition, lead.worldRotation) end
    Camera.Update(dt, Train.GetS())
    -- 选择器/用户暂停期间也补齐当前画面，但不会推进车辆和玩法。
    WorldStream.Update(Train.GetS(), dt)
    PassengerService.UpdateVisuals(IsPaused() and 0 or frameSimulated_)
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

    -- 汽笛
    if input:GetKeyPress(KEY_H) then Game.Horn() end

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
