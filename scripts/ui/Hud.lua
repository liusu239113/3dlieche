-- 紧凑型机车驾驶 HUD，兼容原有 main/Game API。
-- 只读 GameConfig；不依赖 Game/Train/world，避免循环加载。
local UI = require "urhox-libs/UI"
local GameConfig = require "config.GameConfig"
local Skin = require "ui.CabStyle"
local Cab = require "ui.CabInstruments"
local TrainSelector = require "ui.TrainSelector"
local CameraSelector = require "ui.CameraSelector"
local VolumePanel = require "ui.VolumePanel"
local HudPanels = require "ui.HudPanels"
local Passenger = require "ui.HudPassenger"
local Feedback = require "ui.HudFeedback"
local TimetablePanel = require "ui.TimetablePanel"
local Rage = require "ui.RagePanel"
local Drive = require "ui.DriveStatus"
local C = Skin.Colors
-- BrawlForge warning token 用于真实黄灯，非把驾驶台橙色提示当黄灯。
local SIGNAL_YELLOW = { 255, 198, 26, 255 }
local Hud = {}

---@class CabHudCallbacks
---@field onMainMenu? fun()
---@field onSettings? fun()
---@field onThrottleUp? fun()
---@field onThrottleDown? fun()
---@field onBrake? fun() 保留旧接口：按下一次追加一档制动
---@field onBrakeHold? fun(held: boolean) Main owns continuous braking when provided
---@field onBrakeRelease? fun() Ends hold, does NOT clear existing brake pressure
---@field onReleaseBrake? fun() Explicit brake pressure release / 缓解
---@field onHorn? fun()
---@field onPause? fun()
---@field onCamera? fun() 保留原顺序循环，独立“下一视角”按钮调用
---@field onSelectCamera? fun(id: string): boolean?, string? main 选择真实 Camera id；false 拒绝
---@field onReverse? fun()
---@field onSwitch? fun(dir: integer) -1 正线 / 1 站内到发线；main -> Game.SetSwitch -> RailNetwork
---@field onDrivingMode? fun() main 切换休闲/模拟；未接入禁用
---@field onService? fun() main 选择下一真实运营任务；未接入禁用
---@field onRenderQuality? fun() main 切换流畅/细致；HUD 不修改 renderer
---@field onSelectTrain? fun(id: string, done: fun(success:boolean,message?:string)): boolean, string? true仅受理，done才完成
---@field onCancelTrainSelection? fun(id:string)
---@field getTrainCatalog? fun(): TrainCatalogItem[]
---@field onOpenTrainSelector? fun(open: boolean) Main owns pause/restore and gameplay input gating
---@field onRestart? fun()
---@field onSoundVolume? fun(value:number)
---@field onTrainVolume? fun(value:number)
---@field onAnnouncementVolume? fun(value:number) 到站广播音量；未接入时该滑杆禁用
---@field onSoundToggle? fun(enabled: boolean) 可选：请求音频开关，main 用 SetSoundEnabled 回传实际状态
---@field onHeadlightMode? fun(mode: string) 请求auto/on/off；main回传真实灯光状态
---@field onLightingDiagnostics? fun() 请求记录真机现场，HUD不读取或修改渲染器
---@field onLightingCluster? fun(enabled:boolean) 请求A/B光照路径；main暂停并回传真实状态
---@field onMusicToggle? fun(enabled: boolean) 只切音乐；main持久化并用SetMusicSettings回传
---@field onMusicVolume? fun(value:number)
---@type CabHudCallbacks
local callbacks_ = {}

---@class CabTimetablePanel
---@field SetStatus fun(self: CabTimetablePanel, status: table?)
---@field SetVisible fun(self: CabTimetablePanel, visible: boolean)
---@field SetBounds fun(self: CabTimetablePanel, x: number, y: number, right: number, desk: number, meter: number, meterLeft: number)

---@class CabHudRefs
---@field gameOver? Panel
---@field gameOverReason? Label
---@field root? Panel
---@field info? Panel
---@field routeToggle? Button
---@field routeDetails? ScrollView
---@field passenger? CabPassengerStrip
---@field stationRow? Panel
---@field statusRow? Panel
---@field actions? Panel
---@field station? Label
---@field distance? Label
---@field clock? Label
---@field xp? Label
---@field extras? Panel
---@field status? Label
---@field statusLamp? Panel
---@field meter? CabSpeedometer
---@field desk? CabPanel
---@field throttle? CabLever
---@field brake? CabLever
---@field reverse? CabKey
---@field pause? CabKey
---@field mapKey? CabKey
---@field map? CabMinimap
---@field timetable? CabTimetablePanel
---@field left? Panel
---@field hint? Label
---@field banner? CabPanel
---@field bannerTitle? Label
---@field bannerSub? Label
---@field toast? CabPanel
---@field toastText? Label
---@field trainBar? Panel
---@field trainName? Label
---@field trainSelector? CabTrainSelector
---@field cameraSelector? CabCameraSelector
---@field volumePanel? CabVolumePanel
---@field cameraKey? Button
---@field signalRed? Panel
---@field signalYellow? Panel
---@field signalGreen? Panel
---@field signalText? Label
---@field track? Label
---@field switchText? Label
---@field objective? Label
---@field cameraName? Label
---@field railwayControls? Panel
---@field operationsToggle? Button
---@field operationsDetails? ScrollView
---@field soundToggle? Button
---@field soundVolume? Slider
---@field musicToggle? Button
---@field musicVolume? Slider
---@field switchMainline? Button
---@field switchSiding? Button
---@field drivingMode? Button
---@field nextService? Button
---@field renderQuality? Button
---@field lightingDiagnosticsStatus? Label
---@field operationModeRow? Panel
---@field switchStrip? Panel
---@field switchHint? Label
---@type CabHudRefs
local refs_ = {}

local state_ = {
    gameMode = "normal",
    rage = false,
    speed = 0.0,
    limit = GameConfig.Gameplay.SpeedLimitKmh,
    instrumentMax = 400,
    notch = 0,
    maxNotch = GameConfig.Train.MaxThrottle,
    brake = 0.0,
    reversing = false,
    paused = false,
    lightingDiagnosticsStatus = "灯光对照：等待驾驶视口",
    dwelling = false,
    station = GameConfig.Stations[1] and GameConfig.Stations[1].name or "下一站",
    distance = "计算距离",
    clock = "00:00",
    clockSecond = -1,
    xp = "0",
    switch = 0.0,
    mapVisible = false,
    toastTime = 0.0,
    selectedTrainId = "",
    selectedTrainName = "待同步车型",
    selectedCameraId = "",
    selectedCameraName = "待同步视角",
    drivingMode = "待同步",
    renderQuality = "流畅",
    railwayReady = false,
    aspect = "unknown",
    signalText = "信号待同步",
    track = "线路待同步",
    switchText = "道岔待同步",
    switchLocked = true,
    objective = "运营任务待同步",
    serviceName = "",
    routeExpanded = false,
    operationsExpanded = false,
    passengerSynced = false,
    passenger = Passenger.Snapshot(nil),
    soundEnabled = true,
    soundVolume = .75,
    musicEnabled = true,
    musicVolume = .35,
}
---@type CabCameraCatalogEntry[]
local cameraCatalog_ = {}
---@type CabTrainCatalogEntry[]
local trainCatalog_ = {}
---@type CabMapPoint[]
local mapPoints_ = {}
---@type CabMapStation[]
local mapStations_ = {}
local mapTrain_ = { x = 0.0, z = 0.0 }
local timetableSnapshot_ = {} ---@type table
---@type integer?
local activeStation_ = nil
local lastLayout_ = ""
local lastStatus_ = ""
local layoutTimer_ = 0.0
local layoutViewportW_, layoutViewportH_, layoutScale_ = 0.0, 0.0, 0.0
local statusDirty_ = true
-- 使用专用暂停同步接口后，Toast 文案不再参与暂停状态管理。
local explicitPause_ = false
local syncingAudio_ = false

---@param value number|string|nil
---@param fallback number
---@return number
local function Number(value, fallback)
    local n = tonumber(value)
    if not n or n ~= n or n == math.huge or n == -math.huge then return fallback end
    return n
end

---@param name string?
---@param id string
---@param fallback string
---@return string
local function DisplayName(name, id, fallback)
    -- 目录 ID 是业务键，不是车型或镜头展示名；缺名时不泄露内部业务/资源键。
    return type(name) == "string" and name ~= "" and name ~= id and name or fallback
end

---@param label Label?
---@param text string
local function Text(label, text)
    if label and label:GetText() ~= text then label:SetText(text) end
end

---@param button Button?
---@param disabled boolean
local function Disabled(button, disabled)
    if button and button:IsDisabled() ~= disabled then button:SetDisabled(disabled) end
end

local function ObjectiveText()
    if state_.serviceName == "" or string.find(state_.objective, state_.serviceName, 1, true) then
        return state_.objective
    end
    return state_.serviceName .. " · " .. state_.objective
end

local function RefreshOperations()
    Drive.SetRailway(nil, state_.paused)
    Disabled(refs_.drivingMode, state_.rage or not callbacks_.onDrivingMode or state_.paused)
    Disabled(refs_.nextService, state_.rage or not callbacks_.onService or state_.paused or math.abs(state_.speed) > 0.1)
    if refs_.operationModeRow then refs_.operationModeRow:SetVisible(not state_.rage) end
    Disabled(refs_.renderQuality, not callbacks_.onRenderQuality)
end

local function RefreshStatus()
    if not statusDirty_ then return end
    statusDirty_ = false
    local text, color = "待发", C.secondary
    if state_.paused then text, color = "暂停", C.orange
    elseif not state_.rage and state_.dwelling then text, color = "站停", C.teal
    elseif not state_.rage and math.abs(state_.speed) > state_.limit + 0.5 then text, color = "超速", C.red
    elseif state_.brake > 0.01 then text, color = "制动", C.orange
    elseif state_.notch > 0 then text, color = "牵引", C.teal
    elseif math.abs(state_.speed) > 0.5 then text, color = "惰行", C.secondary end
    if text ~= lastStatus_ then
        lastStatus_ = text
        Text(refs_.status, text)
        if refs_.status then refs_.status:SetFontColor(color) end
        if refs_.statusLamp then refs_.statusLamp:SetStyle({ backgroundColor = color }) end
    end
end

---@param held boolean
local function BrakeHold(held)
    if held then
        if state_.paused then return end
        -- 保留按下时追加一档的旧语义；提供按住回调后，持续加压只由
        -- main 按时间步长执行，不再叠加旧回调重复触发。
        if callbacks_.onBrake then callbacks_.onBrake() end
        if callbacks_.onBrakeHold then callbacks_.onBrakeHold(true) end
    else
        if callbacks_.onBrakeHold then callbacks_.onBrakeHold(false) end
        if callbacks_.onBrakeRelease then callbacks_.onBrakeRelease() end
    end
end

local function BrakeRepeat()
    if not state_.paused and not callbacks_.onBrakeHold and callbacks_.onBrake then
        callbacks_.onBrake()
    end
end

local function CanIncreaseThrottle()
    if state_.paused then return false end
    if state_.passengerSynced then
        return state_.passenger.ready and not state_.passenger.doorsOpen
    end
    return not state_.dwelling
end

---@param notch integer
local function SelectThrottle(notch)
    if state_.paused then return end
    local target = math.max(0, math.min(state_.maxNotch, notch))
    if target > state_.notch and not CanIncreaseThrottle() then return end
    local callback = target > state_.notch and callbacks_.onThrottleUp or callbacks_.onThrottleDown
    if not callback then return end
    -- 逐档请求仍走旧 API；不把请求当权威结果，不写乐观 notch。
    -- main/Game 拒绝（门开/未许可等）时手柄保持原真实档位，SetThrottle 才更新读数。
    local steps = math.abs(target - state_.notch)
    for _ = 1, steps do
        if target > state_.notch and not CanIncreaseThrottle() then break end
        callback()
    end
end

---@param props LabelProps
---@return Label
local function Label(props)
    props.fontColor = props.fontColor or C.text
    props.fontSize = props.fontSize or 10.5
    props.maxLines = props.maxLines or 1
    return UI.Label(props)
end

-- 所有元素使用 UI 基准像素；响应式断点只调整组件尺寸，
-- 不修改全局缩放，也不重复乘物理像素比。
local function LayoutHud()
    if not refs_.root then return end
    local vw, vh = UI.GetViewportSize()
    local scale = UI.GetScale()
    local resized = vw ~= layoutViewportW_ or vh ~= layoutViewportH_ or scale ~= layoutScale_
    if not resized and layoutTimer_ > 0 then return end
    layoutViewportW_, layoutViewportH_, layoutScale_ = vw, vh, scale
    layoutTimer_ = 0.25 -- 胶囊/安全区签名最多 4Hz；视口或 DPR 改变则本帧立即重排。
    local safe = UI.GetSafeAreaInsets()
    local insetTop = safe.top
    -- 文档公开接口；当前SDK桩仅含成就API，以局部类型补全，不改引擎声明。
    local host=sdk --[[@as table?]]
    if host then
        local getMenu=host["GetNativeExitMenuRect"] --[[@as (fun(self:table):table?)?]]
        local menu=getMenu and getMenu(host) or nil
        if menu then insetTop = math.max(insetTop, menu.bottom * graphics:GetHeight() / UI.GetScale()) end
    end
    local signature = string.format("%.1f %.1f %.1f %.1f %.1f %.1f %s %s %s", vw, vh,
        safe.left, insetTop, safe.right, safe.bottom, tostring(state_.routeExpanded),
        tostring(state_.operationsExpanded), tostring(state_.passengerSynced)) .. " " .. Feedback.GetHeight()
        .. " " .. tostring(Feedback.IsLoading())
    if signature == lastLayout_ then return end
    lastLayout_ = signature
    local edge = 12
    local left, right = safe.left + edge, safe.right + edge
    local top, bottom = insetTop + edge, safe.bottom + edge
    local w, h = vw - left - right, vh - top - bottom
    local small = h < 490
    local narrow = w < 590
    local large = w >= 900 and h >= 580
    if not large and state_.routeExpanded and state_.operationsExpanded then
        state_.routeExpanded = false -- 从大屏旋转/缩窗时仍只保留一个细节窗口。
    end
    local stacked = narrow and h >= 560
    local meterSize = small and 150 or 184
    local leverHeight = small and 134 or 150
    local deskWidth = 198
    local deskHeight = leverHeight + 58
    local topStacked = w < 760 and h >= 340
    local infoTop = topStacked and top + 52 or top
    local routeBodyHeight = math.max(32, math.min(large and 86 or 66, h - 230))
    local infoHeight = (state_.rage and 98 or 76) + Feedback.GetHeight()
        + (not state_.rage and state_.passengerSynced and 36 or 0)
        + (state_.routeExpanded and routeBodyHeight + 2 or 0)
    local infoWidth = math.min(large and 420 or 340,
        topStacked and w or math.max(140, w - 326))
    -- 极矮窄屏中上方信息可能落到右侧手柄的高度：缩窄信息而非覆盖制动。
    if infoTop - top + infoHeight > h - deskHeight - 8 then
        infoWidth = math.min(infoWidth, math.max(140, w - deskWidth - 12))
    end
    if refs_.actions then refs_.actions:SetStyle({ top = top, right = right }) end
    if refs_.info then
        refs_.info:SetStyle({ left = left, top = infoTop, width = infoWidth, height = infoHeight })
    end
    if refs_.routeDetails then
        refs_.routeDetails:SetHeight(routeBodyHeight)
        refs_.routeDetails:SetVisible(state_.routeExpanded)
    end
    if refs_.routeToggle then refs_.routeToggle:SetText(state_.routeExpanded and "收起" or "详情") end
    if refs_.passenger then refs_.passenger:SetVisible(not state_.rage and state_.passengerSynced) end
    if state_.rage then Rage.Layout(infoWidth - 16) end
    if refs_.switchText then refs_.switchText:SetStyle({ maxWidth = 160 }) end
    if refs_.extras then refs_.extras:SetVisible(large) end
    if refs_.meter then
        refs_.meter:SetStyle({ width = meterSize, height = meterSize,
            right = stacked and right or right + deskWidth + 10,
            bottom = stacked and bottom + deskHeight + 9 or bottom + 4 })
    end
    if refs_.desk then refs_.desk:SetStyle({ right = right, bottom = bottom,
        width = deskWidth, height = deskHeight }) end
    if refs_.throttle then refs_.throttle:SetHeight(leverHeight) end
    if refs_.brake then refs_.brake:SetHeight(leverHeight) end
    if refs_.left then refs_.left:SetStyle({ left = left, bottom = bottom }) end
    local hintVisible = not narrow and not small
    if refs_.hint then refs_.hint:SetVisible(hintVisible) end
    -- 原64px仅覆盖52px底部按钮+12px留白；显示提示时补上其真实行高和8px gap。
    local operationBottom = 116 + (hintVisible and refs_.hint and Number(refs_.hint.props.height, 0) + 8 or 0)
    if refs_.timetable and refs_.mapKey then
        -- Resolve Yoga after positioning actions; use the real button edge, never infoHeight.
        UI.Layout()
        local anchor=refs_.mapKey:GetAbsoluteLayout()
        local deskTop=vh-bottom-deskHeight
        local meterTop=stacked and vh-bottom-deskHeight-9-meterSize or vh-bottom-4-meterSize
        local meterLeft=stacked and vw-right-meterSize or vw-right-deskWidth-10-meterSize
        refs_.timetable:SetBounds(anchor.x,anchor.y+anchor.h,vw-right,deskTop,meterTop,meterLeft)
    end
    if refs_.banner then refs_.banner:SetStyle({ top = infoTop + infoHeight + 8,
        left = left, width = math.min(370, w - (narrow and 0 or 190)) }) end
    if refs_.toast then refs_.toast:SetStyle({ top = infoTop + infoHeight + (small and 2 or 8),
        left = left, width = math.min(370, infoWidth),
        minHeight = small and 16 or 34, maxHeight = small and 16 or 52,
        paddingVertical = small and 2 or 6, overflow = "hidden" }) end
    if refs_.toastText then refs_.toastText:SetStyle({ maxLines = small and 1 or 2,
        whiteSpace = small and "nowrap" or "normal", fontSize = small and 9 or 10.5 }) end
    local leftWidth = math.max(144, w - deskWidth - (stacked and 12 or meterSize + 26))
    local operationWidth = math.min(large and 290 or 250, leftWidth)
    -- 道岔占独立常驻条，固定在左下按钮上方；运营展开区再向上，绝不侵入仪表。
    local switchBottom = operationBottom
    Drive.Layout(operationWidth)
    if refs_.switchStrip then refs_.switchStrip:SetStyle({ left = left, bottom = bottom + switchBottom,
        width = operationWidth, height = 82 }) end
    local operationBaseHeight = HudPanels.OperationsCollapsedHeight
    local available = h - switchBottom - 90 - (infoTop - top + infoHeight) - operationBaseHeight - 8
    local operationBodyHeight = math.max(52, math.min(large and 196 or 92, available))
    if refs_.railwayControls then refs_.railwayControls:SetStyle({ left = left, bottom = bottom + switchBottom + 90,
        width = operationWidth, height = operationBaseHeight + (state_.operationsExpanded and operationBodyHeight or 0) }) end
    if refs_.operationsDetails then
        refs_.operationsDetails:SetHeight(operationBodyHeight)
        refs_.operationsDetails:SetVisible(state_.operationsExpanded)
    end
    if refs_.operationsToggle then refs_.operationsToggle:SetText(state_.operationsExpanded and "收起" or "展开") end
    if refs_.trainSelector then refs_.trainSelector:SetBounds(left, top, w, h) end
    local downloading = Feedback.IsLoading()
    -- 临时下载卡复用信息栏所在区域，不额外堆叠在驾驶控件上方；切车结束即恢复。
    if refs_.info then refs_.info:SetVisible(not downloading) end
    if refs_.railwayControls then refs_.railwayControls:SetVisible(not downloading) end
    Feedback.Layout(left, infoTop, math.min(infoWidth, math.max(140, w - deskWidth - 12)))
    if refs_.cameraSelector then
        local reserveTop = h >= 260 and 52 or 0
        refs_.cameraSelector:SetBounds(left, top + reserveTop,
            math.min(350, math.max(0, w - deskWidth - 12)), math.max(0, h - reserveTop))
    end
    if refs_.volumePanel and refs_.left then
        -- 弹窗贴着汽笛/音量键所在行的上沿展开，与按钮保持同一条竖线。
        UI.Layout()
        local anchor = refs_.left:GetAbsoluteLayout()
        local panelTop = math.max(top, anchor.y - 300 - 10)
        refs_.volumePanel:SetBounds(left, panelTop, math.min(316, math.max(0, w - deskWidth - 12)),
            math.max(0, math.min(vh - bottom, anchor.y - 10) - panelTop))
    end
    print(string.format("[Hud] 驾驶仪表 %.0fx%.0f base px, %s", vw, vh, narrow and "窄屏布局" or "横屏布局"))
end

---@class CabHudRoot : Panel
---@overload fun(props?: PanelProps): CabHudRoot
local HudRoot = UI.Panel:Extend("CabHudRoot")
local renderedFrames_=0
function HudRoot:Render(vg)
    renderedFrames_=renderedFrames_+1
    UI.Panel.Render(self,vg)
end
function Hud.GetRenderedFrames() return renderedFrames_ end
---@param dt number
function HudRoot:Update(dt)
    layoutTimer_ = math.max(0, layoutTimer_ - dt)
    if Feedback.Update(dt) then layoutTimer_ = 0 end
    LayoutHud()
    RefreshStatus()
    if state_.toastTime > 0 then
        state_.toastTime = math.max(0, state_.toastTime - dt)
        if state_.toastTime == 0 and refs_.toast then refs_.toast:Hide() end
    end
end

---@param cbs CabHudCallbacks?
function Hud.Init(cbs)
    if refs_.cameraSelector then refs_.cameraSelector:Close() end
    if refs_.trainSelector then refs_.trainSelector:Close() end
    callbacks_ = cbs or {}
    state_.limit = Number(GameConfig.Gameplay.SpeedLimitKmh, 80)
    if state_.limit <= 0 then state_.limit = 80 end
    state_.paused = false
    explicitPause_ = false
    state_.mapVisible = false
    state_.toastTime = 0
    state_.routeExpanded, state_.operationsExpanded = false, false
    -- 菜单、加载页与 HUD 共用同一套事件和渲染上下文；独立 HUD 测试仍可自行初始化。
    if not UI.GetNVGContext() then
        UI.Init({ theme = Skin.CreateTheme(), scale = UI.Scale.DEFAULT })
    end
    UI.SetEnabled(true)
    renderedFrames_=0
    Hud.BuildRoot()
    print("[Hud] 金属驾驶仪表就绪，初始限速 " .. tostring(state_.limit) .. " km/h")
end

--- 保留重建 API；重建前安全释放按住的制动手柄。
function Hud.BuildRoot()
    if refs_.cameraSelector then refs_.cameraSelector:Close() end
    if refs_.trainSelector then refs_.trainSelector:Close() end
    if refs_.brake then refs_.brake:ReleaseHold() end
    refs_ = {}
    lastLayout_, lastStatus_ = "", ""
    layoutTimer_, statusDirty_ = 0, true
    local station = Label { id = "stationName", text = state_.station, fontSize = 13.5, height = 20,
        fontWeight = "bold", minWidth = 64, flexGrow = 1, flexShrink = 1 }
    local distance = Label { id = "nextVal", text = state_.distance, fontColor = C.teal,
        fontSize = 10.5, height = 20, fontWeight = "bold", minWidth = 0, textAlign = "left" }
    local status = Label { id = "runningState", text = "待发", fontSize = 9, fontColor = C.secondary }
    local statusLamp = UI.Panel { width = 4, height = 4, borderRadius = 2,
        backgroundColor = C.secondary, pointerEvents = "none" }
    local cameraName = Label { id = "selectedCameraName", text = state_.selectedCameraName,
        fontSize = 9, fontColor = C.secondary, maxWidth = 100, minWidth = 0, flexShrink = 1 }
    local feedback = Feedback.Create()
    local drive = Drive.Create(callbacks_)
    local clock = Label { id = "journeyElapsed", text = "旅程 " .. state_.clock, fontSize = 9, fontColor = C.secondary }
    local xp = Label { text = "经验 " .. state_.xp, fontSize = 9, fontColor = C.muted }
    local extras = UI.Panel { flexDirection = "row", gap = 12, pointerEvents = "none", children = { clock, xp } }
    local signalRed = UI.Panel { id = "signalRed", width = 7, height = 7,
        borderRadius = 4, backgroundColor = state_.aspect == "red" and C.red or C.muted,
        pointerEvents = "none" }
    local signalYellow = UI.Panel { id = "signalYellow", width = 7, height = 7,
        borderRadius = 4, backgroundColor = state_.aspect == "yellow" and SIGNAL_YELLOW or C.muted,
        pointerEvents = "none" }
    local signalGreen = UI.Panel { id = "signalGreen", width = 7, height = 7,
        borderRadius = 4, backgroundColor = state_.aspect == "green" and C.teal or C.muted,
        pointerEvents = "none" }
    local signalText = Label { id = "railwaySignalText", text = state_.signalText,
        fontSize = 9, minWidth = 0, flexGrow = 1, flexShrink = 1 }
    local track = Label { id = "railwayTrack", text = state_.track, fontSize = 9,
        minWidth = 0, flexGrow = 1, flexShrink = 1, fontColor = C.teal }
    local switchText = Label { id = "railwaySwitchText",
        text = (state_.switchLocked and "锁定 · " or "") .. state_.switchText, fontSize = 9,
        minWidth = 0, flexShrink = 1, fontColor = state_.switchLocked and C.orange or C.secondary }
    local objective = Label { id = "railwayObjective", text = ObjectiveText(), fontSize = 9,
        fontColor = C.secondary, whiteSpace = "normal", maxLines = 2, lineHeight = 1.0,
        height = 28, minWidth = 0, flexShrink = 1 }
    local stationRow = UI.Panel { height = 40, flexGrow = 1, flexBasis = 0, minWidth = 0,
        flexShrink = 1, gap = 0, pointerEvents = "none", children = {
            UI.Panel { height = 20, flexDirection = "row", alignItems = "center", gap = 5,
                pointerEvents = "none", children = {
                    Label { text = "下一站", fontSize = 8.5, fontColor = C.secondary }, station,
                } },
            distance,
        } }
    local statusRow = UI.Panel { height = 18, flexDirection = "row", alignItems = "center", gap = 5,
        pointerEvents = "none", children = { signalRed, signalYellow, signalGreen, signalText } }
    local routeParts = HudPanels.Route(stationRow, statusRow, {
        UI.Panel { height = 20, flexDirection = "row", alignItems = "center", gap = 6,
            pointerEvents = "none", children = { statusLamp, status, cameraName, extras } },
        UI.Panel { height = 20, flexDirection = "row", alignItems = "center", gap = 6,
            pointerEvents = "none", children = { track, switchText } }, objective, drive.terrain, drive.diagnostics,
    }, function() Hud.SetRouteExpanded(not state_.routeExpanded) end)
    if state_.rage then
        local rage = Rage.Create()
        stationRow:ClearChildren(); stationRow:AddChild(rage.header)
        statusRow:ClearChildren(); statusRow:SetHeight(40); statusRow:AddChild(rage.summary)
        routeParts.details:InsertChild(rage.details, 1)
    end
    local info = routeParts.panel
    info:InsertChild(feedback.environment, 3)
    info:InsertChild(feedback.departure, 4)
    info:InsertChild(feedback.caption, 5)
    routeParts.details:AddChild(feedback.version)
    routeParts.passenger:SetStatus(state_.passenger)
    local pause = Cab.Key { id = "pauseGame", icon = "pause", text = "暂停", width = 44, height = 44,
        onClick = function()
            if refs_.brake then refs_.brake:ReleaseHold() end
            if callbacks_.onPause then callbacks_.onPause() end
        end }
    local mapKey = Cab.Key { id="toggleMinimap", icon = "map", text = "线路", width = 44, height = 44,
        onClick = function() Hud.SetMinimapVisible(not state_.mapVisible) end }
    local cameraKey = UI.Button { id = "openCameraSelector", text = "视角选择", width = 72, height = 44,
        paddingHorizontal = 3, variant = "secondary", disabled = not callbacks_.onSelectCamera,
        onClick = function() Hud.SetCameraSelectorOpen(not Hud.IsCameraSelectorOpen()) end }
    local actions = UI.Panel { position = "absolute", flexDirection = "row", gap = 6,
        paddingRight = 2, pointerEvents = "box-none", children = {
            mapKey, cameraKey,
            UI.Button { id = "openTrainSelector", text = "换车", width = 56, height = 44,
                variant = "secondary", onClick = function() Hud.SetTrainSelectorOpen(true) end },
            UI.Button { id = "cycleCamera", text = "下一视角", width = 72, height = 44,
                paddingHorizontal = 3, variant = "secondary", disabled = not callbacks_.onCamera,
                onClick = function() if callbacks_.onCamera then callbacks_.onCamera() end end },
            pause,
        } }
    local meter = Cab.Speedometer { id = "speedInstrument", position = "absolute",
        maxSpeed = state_.instrumentMax, limit = state_.limit, unlimited = state_.rage }
    meter:SetReading(state_.speed, state_.limit)
    local throttle = Cab.Lever { id = "throttleHandle", kind = "throttle", onSelect = SelectThrottle }
    throttle:SetNotch(state_.notch, state_.maxNotch)
    local brake = Cab.Lever { id = "brakeHandle", kind = "brake", onHold = BrakeHold, onRepeat = BrakeRepeat }
    brake:SetRatio(state_.brake)
    local desk = Cab.Panel { position = "absolute", width = 198, height = 208,
        padding = 7, gap = 2, pointerEvents = "box-none", children = {
            UI.Panel { flexDirection = "row", gap = 4, pointerEvents = "box-none", children = {
                UI.Panel { width = 40, gap = 6, justifyContent = "center",
                    alignSelf = "stretch",
                    pointerEvents = "box-none", children = {
                        Cab.Key { id = "throttleUp", icon = "up", hint = "W", width = 40, height = 44,
                            onClick = function()
                                if callbacks_.onThrottleUp and CanIncreaseThrottle() then callbacks_.onThrottleUp() end
                            end },
                        Cab.Key { id = "throttleDown", icon = "down", hint = "S", width = 40, height = 44,
                            onClick = function() if callbacks_.onThrottleDown then callbacks_.onThrottleDown() end end },
                    } },
                throttle, brake,
            } },
            UI.Panel { flexDirection = "row", alignItems = "center", justifyContent = "space-between",
                height = 42, pointerEvents = "box-none", children = {
                    Label { text = "按住制动", fontSize = 8.5, fontColor = C.muted },
                    Cab.Key { id = "releaseBrake", text = "缓解", hint = "释放制动力", width = 76, height = 42,
                        onClick = function()
                            if refs_.brake then refs_.brake:ReleaseHold() end
                            if callbacks_.onReleaseBrake then callbacks_.onReleaseBrake()
                            else Hud.Toast("缓解未接入", 1.5) end
                        end },
                } },
        } }
    local reverse = Cab.Key { id = "reverser", text = state_.reversing and "后退" or "前进",
        hint = "换向 R", width = 72, height = 52, active = state_.reversing,
        onClick = function()
            if callbacks_.onReverse then callbacks_.onReverse()
            else Hud.Toast("按 R 切换前进 / 后退", 1.5) end
        end }
    local hint = Label { text = "W / S 牵引   SPACE 制动   X 紧急", fontSize = 8.5, fontColor = C.secondary }
    local left = UI.Panel { position = "absolute", gap = 8, pointerEvents = "box-none", children = {
        hint,
        UI.Panel { flexDirection = "row", gap = 8, pointerEvents = "box-none", children = {
            Cab.Key { text = "汽笛", icon = "horn", width = 64, height = 52,
                onClick = function() if callbacks_.onHorn then callbacks_.onHorn() end end },
            Cab.Key { id = "openVolumePanel", text = "音量", icon = "volume", width = 64, height = 52,
                onClick = function() Hud.SetVolumePanelOpen(not Hud.IsVolumePanelOpen()) end },
            reverse,
        } },
    } }
    local map = Cab.Minimap { id = "minimap" }
    map:SetRoute(mapPoints_, mapStations_)
    map:SetTrain(mapTrain_.x, mapTrain_.z, activeStation_)
    local timetable=TimetablePanel.new(map,function() Hud.SetMinimapVisible(false) end)
    timetable:SetStatus(timetableSnapshot_)
    timetable:SetVisible(state_.mapVisible)
    local bannerTitle = Label { text = "", fontSize = 15, fontWeight = "bold" }
    local bannerSub = Label { text = "", fontSize = 10, fontColor = C.teal }
    local banner = Cab.Panel { position = "absolute", height = 57, paddingHorizontal = 12,
        justifyContent = "center", pointerEvents = "none", visible = false,
        children = { bannerTitle, bannerSub } }
    local toastText = Label { text = "", fontSize = 10.5, fontColor = C.orange, whiteSpace = "normal", maxLines = 2 }
    local toast = Cab.Panel { position = "absolute", minHeight = 34, maxHeight = 52,
        paddingHorizontal = 12, paddingVertical = 7, pointerEvents = "none", visible = false,
        children = { toastText } }
    local trainName = Label { id = "selectedTrainName", text = state_.selectedTrainName,
        fontSize = 10.5, fontWeight = "bold", minWidth = 0, flexGrow = 1, flexShrink = 1 }
    local trainBar = UI.Panel { id = "trainModelBar", width = "100%", height = 44,
        flexDirection = "row", alignItems = "center", paddingLeft = 6, gap = 4,
        pointerEvents = "box-none", children = {
            trainName,
        } }
    local switchStrip = drive.switchStrip
    local switchMainline, switchSiding, switchHint = drive.switchMainline, drive.switchSiding, drive.switchHint
    local drivingMode = UI.Button { id = "drivingMode", text = "驾驶 · " .. state_.drivingMode,
        height = 44, width = 0, flexGrow = 1, flexBasis = 0, flexShrink = 1,
        minWidth = 44, paddingHorizontal = 3, variant = "secondary",
        disabled = not callbacks_.onDrivingMode, onClick = function()
            if not state_.rage and callbacks_.onDrivingMode and not state_.paused then callbacks_.onDrivingMode() end
        end }
    local nextService = UI.Button { id = "nextService", text = "下一任务", height = 44, width = 0,
        flexGrow = 1, flexBasis = 0, flexShrink = 1, minWidth = 44, paddingHorizontal = 3,
        variant = "secondary", disabled = not callbacks_.onService, onClick = function()
            if not state_.rage and callbacks_.onService and not state_.paused and math.abs(state_.speed) <= 0.1 then
                callbacks_.onService()
            end
        end }
    local renderQuality = UI.Button { id = "renderQuality", text = "画质 · " .. state_.renderQuality,
        width = 0, height = 44, flexGrow = 1, flexBasis = 0, minWidth = 44, flexShrink = 1,
        paddingHorizontal = 3, variant = "secondary", disabled = not callbacks_.onRenderQuality,
        onClick = function() if callbacks_.onRenderQuality then callbacks_.onRenderQuality() end end }
    local soundToggle = UI.Button { id = "toggleSound", text = state_.soundEnabled and "声音开" or "总静音",
        width = 48, height = 44, fontSize = 8, paddingHorizontal = 2, variant = "secondary",
        visible = callbacks_.onSoundToggle ~= nil,
        onClick = function()
            if callbacks_.onSoundToggle then callbacks_.onSoundToggle(not state_.soundEnabled) end
        end }
    drive.controls:AddChild(soundToggle)
    left:AddChild(drive.controls) -- 灯光/音乐/总静音常驻；与原声音行同高，不再藏在滚动区。
    local volumeSlider=UI.Slider {id="soundVolume",min=0,max=1,value=state_.soundVolume,height=36,width="100%",
        disabled=not callbacks_.onSoundVolume,
        onChange=function(self,value) if not syncingAudio_ and callbacks_.onSoundVolume then callbacks_.onSoundVolume(value) end end}
    local musicToggle = drive.music
    local musicSlider=UI.Slider {id="musicVolume",min=0,max=1,value=state_.musicVolume,height=36,width="100%",
        disabled=not callbacks_.onMusicVolume,visible=callbacks_.onMusicVolume~=nil,
        onChange=function(self,value) if not syncingAudio_ and callbacks_.onMusicVolume then callbacks_.onMusicVolume(value) end end}
    local operationModeRow = UI.Panel { height = 44, flexDirection = "row", gap = 4,
        minWidth = 0, pointerEvents = "box-none", children = { drivingMode, nextService } }
    local lightingDiagnosticsStatus=Label{id="lightingDiagnosticsStatus",text=state_.lightingDiagnosticsStatus,
        height=36,fontSize=10,fontColor=C.teal,whiteSpace="normal",maxLines=2,
        visible=callbacks_.onLightingCluster~=nil}
    local operationParts = HudPanels.Operations({
        UI.Panel { height = 44, flexDirection = "row", gap = 4, minWidth = 0,
            pointerEvents = "box-none", children = { renderQuality } },
        lightingDiagnosticsStatus,
        UI.Panel {height=44,flexDirection="row",gap=4,width="100%",visible=callbacks_.onLightingCluster~=nil,
            children={
                UI.Button{id="lightingClusterA",text="A 集群",height=44,width=0,flexGrow=1,flexBasis=0,flexShrink=1,
                    variant="secondary",onClick=function() if callbacks_.onLightingCluster then callbacks_.onLightingCluster(true) end end},
                UI.Button{id="lightingClusterB",text="B 非集群",height=44,width=0,flexGrow=1,flexBasis=0,flexShrink=1,
                    variant="secondary",onClick=function() if callbacks_.onLightingCluster then callbacks_.onLightingCluster(false) end end},
            }},
        UI.Button {id="captureLightingDiagnostics",text="灯光取证 · LD-20261020-B",height=48,minHeight=48,width="100%",
            visible=callbacks_.onLightingDiagnostics~=nil,variant="secondary",
            onClick=function() if callbacks_.onLightingDiagnostics then callbacks_.onLightingDiagnostics() end end},
        Label{text="主音量",fontSize=9,fontColor=C.secondary},volumeSlider,
        Label{text="音乐音量",fontSize=9,fontColor=C.secondary,visible=callbacks_.onMusicVolume~=nil},musicSlider,
        operationModeRow,
        UI.Panel { height=44,flexDirection="row",gap=4,pointerEvents="box-none",children={
            UI.Button{id="returnMainMenu",text="主菜单",height=44,flexGrow=1,visible=callbacks_.onMainMenu~=nil,
                onClick=function() if callbacks_.onMainMenu then callbacks_.onMainMenu() end end},
            UI.Button{id="openSettings",text="设置",height=44,flexGrow=1,visible=callbacks_.onSettings~=nil,
                onClick=function() if callbacks_.onSettings then callbacks_.onSettings() end end},
        } },trainBar,
    }, function() Hud.SetOperationsExpanded(not state_.operationsExpanded) end)
    local railwayControls = operationParts.panel
    local cameraSelector = CameraSelector { id = "cameraSelector" }
    cameraSelector:SetCallbacks({
        onSelect = callbacks_.onSelectCamera,
        onOpen = function(open)
            -- 不通知 onOpenTrainSelector，不暂停，不释放制动：镜头菜单可以边驾驶边点。
            if refs_.cameraKey then
                refs_.cameraKey:SetText(open and "关闭视角" or "视角选择")
            end
        end,
    })
    cameraSelector:SetCatalog(cameraCatalog_)
    cameraSelector:SetSelected(state_.selectedCameraId, state_.selectedCameraName)
    local selector = TrainSelector { id = "trainSelector" }
    selector:SetCallbacks({
        -- true 只是受理。done 由选择器持有请求代次，关闭/取消后旧回调不可提交。
        -- main 用 SetSelectedTrain 回传实际车型，HUD 不把返回值当切车成功。
        onSelect = callbacks_.onSelectTrain,
        onCancel = callbacks_.onCancelTrainSelection,
        getCatalog = callbacks_.getTrainCatalog,
        onOpen = function(open)
            if callbacks_.onOpenTrainSelector then callbacks_.onOpenTrainSelector(open) end
        end,
    })
    selector:SetCatalog(trainCatalog_)
    selector:SetSelected(state_.selectedTrainId, state_.selectedTrainName)
    selector:SetOperatingState(state_.speed, state_.limit)
    local gameOverReason=Label {text="",fontSize=12,whiteSpace="normal",maxLines=3,height=54}
    local gameOverCard=UI.Panel {width="88%",maxWidth=620,padding=20,gap=12,
        backgroundColor={20,25,33,240},borderRadius=12,
        children={Label{text="脱轨事故 · 本局结束",fontSize=20,fontWeight="bold"},gameOverReason,
            UI.Button{id="restartJourney",text="重开旅程",height=46,variant="primary",
                onClick=function() if callbacks_.onRestart then callbacks_.onRestart() end end}}}
    local gameOver=UI.Panel {id="gameOver",position="absolute",left=0,top=0,width="100%",height="100%",
        justifyContent="center",alignItems="center",pointerEvents="auto",visible=false,
        backgroundColor={0,0,0,55},children={gameOverCard}}
    local volumePanel = VolumePanel { id = "volumePanel" }
    volumePanel:SetCallbacks({
        onVolume = function(value) if callbacks_.onSoundVolume then callbacks_.onSoundVolume(value) end end,
        onTrainVolume = function(value) if callbacks_.onTrainVolume then callbacks_.onTrainVolume(value) end end,
        onAnnouncementVolume = function(value)
            if callbacks_.onAnnouncementVolume then callbacks_.onAnnouncementVolume(value) end
        end,
        onMusicVolume = function(value) if callbacks_.onMusicVolume then callbacks_.onMusicVolume(value) end end,
        onSoundToggle = function(enabled) if callbacks_.onSoundToggle then callbacks_.onSoundToggle(enabled) end end,
    })
    local root = HudRoot { id = "hudRoot", width = "100%", height = "100%",
        pointerEvents = "box-none", children = { info, actions, meter, desk, left, banner, toast, switchStrip,
            railwayControls, timetable.root, feedback.loading, cameraSelector, selector, volumePanel, gameOver } }
    refs_ = {
        gameOver=gameOver,gameOverReason=gameOverReason,
        root = root, info = info, stationRow = stationRow, statusRow = statusRow,
        routeToggle = routeParts.toggle, routeDetails = routeParts.details, passenger = routeParts.passenger,
        actions = actions, station = station, distance = distance,
        clock = clock, xp = xp, extras = extras, status = status, statusLamp = statusLamp,
        meter = meter, desk = desk, throttle = throttle, brake = brake, reverse = reverse,
        pause = pause, mapKey = mapKey, map = map, timetable=timetable, left = left, hint = hint,
        banner = banner, bannerTitle = bannerTitle, bannerSub = bannerSub, toast = toast, toastText = toastText,
        trainBar = trainBar, trainName = trainName, trainSelector = selector,
        cameraSelector = cameraSelector, cameraKey = cameraKey, volumePanel = volumePanel,
        signalRed = signalRed, signalYellow = signalYellow, signalGreen = signalGreen,
        signalText = signalText, track = track, switchText = switchText, objective = objective,
        cameraName = cameraName,
        railwayControls = railwayControls, switchMainline = switchMainline, switchSiding = switchSiding,
        drivingMode = drivingMode, nextService = nextService, switchStrip = switchStrip, switchHint = switchHint,
        renderQuality = renderQuality, lightingDiagnosticsStatus=lightingDiagnosticsStatus, operationModeRow = operationModeRow,
        operationsToggle = operationParts.toggle, operationsDetails = operationParts.body, soundToggle = soundToggle,
        soundVolume=volumeSlider,musicToggle=musicToggle,musicVolume=musicSlider,
    }
    UI.SetRoot(root, true)
    -- 检查挂载与真实 ID，避免只有 refs 可用、按钮树却漏挂选择器。
    assert(root:FindById("trainSelector") == selector, "车型选择器未正确挂载到 HUD")
    assert(root:FindById("cameraSelector") == cameraSelector, "镜头选择器未正确挂载到 HUD")
    LayoutHud()
    RefreshStatus()
    RefreshOperations()
end

---@param text string
function Hud.SetLightingDiagnosticsStatus(text)
    if state_.lightingDiagnosticsStatus==text then return end
    state_.lightingDiagnosticsStatus=text
    if refs_.lightingDiagnosticsStatus then refs_.lightingDiagnosticsStatus:SetText(text) end
end

--- 真正模式变化才清理跨模式状态；相同 id 的 0.1s 同步不重建、不清分。
---@param id string
function Hud.SetGameMode(id)
    local rage = id == "rage"
    local mode = rage and "rage" or "normal"
    if state_.gameMode == mode then return end
    state_.gameMode, state_.rage = mode, rage
    Drive.ResetRailway()
    Rage.Reset()
    state_.routeExpanded, state_.operationsExpanded, state_.dwelling = false, false, false
    state_.passengerSynced, state_.passenger = false, Passenger.Snapshot(nil)
    state_.limit = Number(GameConfig.Gameplay.SpeedLimitKmh, 80)
    state_.railwayReady, state_.switchLocked = false, true
    state_.serviceName, state_.objective = "", "运营任务待同步"
    Feedback.SetDepartureStatus(nil); Feedback.SetAnnouncement("")
    if refs_.root then Hud.BuildRoot() end
end

---@param stats CabRageStats?
function Hud.SetRageStats(stats)
    if state_.rage then Rage.SetStats(stats) end
end

---@param expanded boolean
function Hud.SetRouteExpanded(expanded)
    local value = expanded == true
    if state_.routeExpanded == value then return end
    state_.routeExpanded = value
    -- 小屏保持一个细节窗口，不把左右 HUD 一起展开成墙；大屏允许并列。
    local w, h = UI.GetViewportSize()
    if value and (w < 900 or h < 580) then state_.operationsExpanded = false end
    layoutTimer_ = 0
    LayoutHud()
end

---@param expanded boolean
function Hud.SetOperationsExpanded(expanded)
    local value = expanded == true
    if state_.operationsExpanded == value then return end
    state_.operationsExpanded = value
    local w, h = UI.GetViewportSize()
    if value and (w < 900 or h < 580) then state_.routeExpanded = false end
    layoutTimer_ = 0
    LayoutHud()
end

--- 只读客运快照：自动乘降与闭门由 Game 实现；不要求手动门按钮。
---@param status CabPassengerStatus|table?
function Hud.SetPassengerStatus(status)
    if not status then return end
    state_.passenger = Passenger.Snapshot(status)
    if refs_.passenger then refs_.passenger:SetStatus(state_.passenger) end
    if not state_.passengerSynced then
        state_.passengerSynced = true
        layoutTimer_ = 0
        LayoutHud()
    end
end

--- 世界时刻和本站等待只显示注入值；从不复用 SetTime 的旅程累计秒数。
---@param status table?
function Hud.SetEnvironment(status)
    local height = Feedback.GetHeight()
    Feedback.SetEnvironment(status)
    if height ~= Feedback.GetHeight() then layoutTimer_ = 0; LayoutHud() end
end
---@param status table?
function Hud.SetDepartureStatus(status)
    if state_.rage then status = nil end
    local height = Feedback.GetHeight()
    Feedback.SetDepartureStatus(status)
    if height ~= Feedback.GetHeight() then layoutTimer_ = 0; LayoutHud() end
end
---@param active boolean
---@param ratio number?
---@param text string?
---@param onCancel fun()|nil
function Hud.SetTrainLoading(active,ratio,text,onCancel)
    local changed = Feedback.IsLoading() ~= (active == true)
    Feedback.SetTrainLoading(active,ratio,text,onCancel)
    if active then
        Hud.HideBanner()
        if refs_.toast then refs_.toast:Hide() end
        if refs_.trainSelector then refs_.trainSelector:SetLoading(ratio or 0,text) end
    end
    if changed then layoutTimer_ = 0; LayoutHud() end
end
---@param text string?
function Hud.SetVersion(text) Feedback.SetVersion(text) end
---@param text string?
---@param voiced boolean?
---@param eventKey string?
function Hud.SetAnnouncement(text,voiced,eventKey)
    local height = Feedback.GetHeight()
    Feedback.SetAnnouncement(text,voiced,eventKey)
    if height ~= Feedback.GetHeight() then layoutTimer_ = 0; LayoutHud() end
end

---@param enabled boolean
function Hud.SetSoundEnabled(enabled)
    state_.soundEnabled = enabled == true
    if refs_.soundToggle then
        refs_.soundToggle:SetText(state_.soundEnabled and "声音开" or "总静音")
    end
end

---@param value number
function Hud.SetSoundVolume(value)
    state_.soundVolume=math.max(0,math.min(1,Number(value,.75)))
    syncingAudio_=true
    if refs_.soundVolume then refs_.soundVolume:SetValue(state_.soundVolume) end
    syncingAudio_=false
end
---@param enabled boolean
---@param volume number
function Hud.SetMusicSettings(enabled,volume)
    state_.musicEnabled=enabled==true
    state_.musicVolume=math.max(0,math.min(1,Number(volume,.35)))
    Drive.SetMusicSettings(state_.musicEnabled, state_.musicVolume)
    syncingAudio_=true
    if refs_.musicVolume then refs_.musicVolume:SetValue(state_.musicVolume) end
    syncingAudio_=false
end

--- 主入口提供真实灯光/音频/地形诊断，UI不猜测加载或播放。
---@param snapshot CabDriveStatus?
function Hud.SetDriveStatus(snapshot)
    if not snapshot then return end
    local enabled, volume = state_.musicEnabled, state_.musicVolume
    if snapshot.musicEnabled ~= nil then enabled = snapshot.musicEnabled end
    if snapshot.musicVolume ~= nil then volume = snapshot.musicVolume end
    if enabled ~= state_.musicEnabled or volume ~= state_.musicVolume then
        Hud.SetMusicSettings(enabled, volume)
    end
    Drive.SetStatus(snapshot)
end
function Hud.GetDriveStatus() return Drive.GetReadings() end

-- 原有数据更新 API 保持有效；新增站名/方向更新无需反向引用
-- 已经依赖 HUD 的 Game 或 Train 模块。
---@param text string
function Hud.SetNextStation(text)
    local value = text or "计算距离"
    if value == state_.distance then return end
    state_.distance = value
    state_.dwelling = state_.distance == "停靠中" or state_.distance == "站停"
    Text(refs_.distance, state_.distance)
    statusDirty_ = true
    RefreshStatus()
end
---@param name string
function Hud.SetStationName(name)
    local value = name or "下一站"
    if value == state_.station then return end
    state_.station = value
    Text(refs_.station, state_.station)
end
---@param maximum number
function Hud.SetSpeedRange(maximum)
    local value = math.max(40, math.ceil(Number(maximum, 400) / 20) * 20)
    if value == state_.instrumentMax then return end
    state_.instrumentMax = value
    if refs_.meter then refs_.meter:SetRange(value) end
end

---@param kmh number|string|nil
function Hud.SetLimit(kmh)
    local value = Number(kmh, GameConfig.Gameplay.SpeedLimitKmh)
    local limit = value >= 0 and value or GameConfig.Gameplay.SpeedLimitKmh
    if limit == state_.limit then return end
    state_.limit = limit
    if refs_.meter then refs_.meter:SetReading(state_.speed, limit) end
    if refs_.trainSelector then refs_.trainSelector:SetOperatingState(state_.speed, limit) end
    statusDirty_ = true
    RefreshStatus()
end
---@param kmh number
---@param limit number|string|nil Optional, preserves old SetSpeed(kmh) call
function Hud.SetSpeed(kmh, limit)
    local speed = Number(kmh, 0)
    local nextLimit = state_.limit
    if limit ~= nil then
        local value = Number(limit, GameConfig.Gameplay.SpeedLimitKmh)
        nextLimit = value >= 0 and value or GameConfig.Gameplay.SpeedLimitKmh
    end
    if speed == state_.speed and nextLimit == state_.limit then return end
    local stoppedChanged = (math.abs(speed) <= 0.1) ~= (math.abs(state_.speed) <= 0.1)
    state_.speed, state_.limit = speed, nextLimit
    -- 合并 speed/limit，只发送一次仪表 reading，避免每帧 SetLimit 再 SetReading。
    if refs_.meter then refs_.meter:SetReading(speed, nextLimit) end
    if refs_.trainSelector then refs_.trainSelector:SetOperatingState(speed, nextLimit) end
    if stoppedChanged then RefreshOperations() end
    statusDirty_ = true
    RefreshStatus()
end
---@param seconds number
function Hud.SetTime(seconds)
    local t = math.max(0, math.floor(Number(seconds, 0)))
    if t == state_.clockSecond then return end
    state_.clockSecond = t
    local value = string.format("%02d:%02d", math.floor(t / 60), t % 60)
    if state_.clock == value then return end
    state_.clock = value
    Text(refs_.clock, "旅程 " .. value)
end
---@param xp number|string?
function Hud.SetXp(xp)
    local value = tostring(xp or 0)
    if state_.xp == value then return end
    state_.xp = value
    Text(refs_.xp, "经验 " .. value)
end
---@param notch integer
---@param maxNotch integer
function Hud.SetThrottle(notch, maxNotch)
    local maximum = math.max(1, math.floor(Number(maxNotch, 8)))
    local value = math.max(0, math.min(maximum, math.floor(Number(notch, 0))))
    if value == state_.notch and maximum == state_.maxNotch then return end
    state_.maxNotch, state_.notch = maximum, value
    if refs_.throttle then refs_.throttle:SetNotch(value, maximum) end
    statusDirty_ = true
    RefreshStatus()
end
---@param ratio number
function Hud.SetBrake(ratio)
    local value = math.max(0, math.min(1, Number(ratio, 0)))
    if value == state_.brake then return end
    state_.brake = value
    if refs_.brake then refs_.brake:SetRatio(value) end
    statusDirty_ = true
    RefreshStatus()
end
---@param reversing boolean
function Hud.SetReversing(reversing)
    local value = reversing == true
    if value == state_.reversing then return end
    state_.reversing = value
    if refs_.reverse then
        refs_.reverse:SetText(value and "后退" or "前进")
        refs_.reverse:SetActive(value)
    end
end
---@param pos number
function Hud.SetSwitch(pos)
    -- 兼容旧接口，仅记录 main 回传的位置；轨道/锁定状态只由 SetRailwayStatus 提供。
    local value = math.max(-1, math.min(1, Number(pos, 0)))
    if value ~= state_.switch then state_.switch = value end
end
---@class CabRailwayStatus
---@field aspect? string green / yellow / red；未知显示灰灯，不自行计算信号
---@field text? string 信号说明
---@field track? string 下行正线 / 上行正线 / 站内到发线
---@field switchText? string 正线进路 / 侧线进路 / 道岔距离
---@field locked? boolean 实际占用/安全锁定，由 RailNetwork 决定
---@field objective? string 真实车次与运营任务
---@field nextSwitch? table|false 最近前方实际道岔；false=无岔，锁定独立于当前全列占岔
---@field hasNextSwitch? boolean

--- 更新独立字段，重复状态不发 SetText/SetStyle，也不修改轨迹/信号/任务。
---@param railway CabRailwayStatus?
function Hud.SetRailwayStatus(railway)
    if not railway then return end
    Drive.SetRailway(railway, state_.paused)
    local readyChanged = not state_.railwayReady
    state_.railwayReady = true
    if railway.aspect ~= nil and railway.aspect ~= state_.aspect then
        local before = state_.aspect
        state_.aspect = railway.aspect
        if refs_.signalRed and ((before == "red") ~= (railway.aspect == "red")) then
            refs_.signalRed:SetStyle({ backgroundColor = railway.aspect == "red" and C.red or C.muted })
        end
        if refs_.signalYellow and ((before == "yellow") ~= (railway.aspect == "yellow")) then
            refs_.signalYellow:SetStyle({ backgroundColor = railway.aspect == "yellow" and SIGNAL_YELLOW or C.muted })
        end
        if refs_.signalGreen and ((before == "green") ~= (railway.aspect == "green")) then
            refs_.signalGreen:SetStyle({ backgroundColor = railway.aspect == "green" and C.teal or C.muted })
        end
    end
    if railway.text ~= nil and railway.text ~= state_.signalText then
        state_.signalText = railway.text
        Text(refs_.signalText, railway.text)
    end
    if railway.track ~= nil and railway.track ~= state_.track then
        state_.track = railway.track
        Text(refs_.track, railway.track)
    end
    local locked = railway.locked
    local lockChanged = locked ~= nil and locked ~= state_.switchLocked
    local switchChanged = railway.switchText ~= nil and railway.switchText ~= state_.switchText
    if lockChanged then state_.switchLocked = locked == true end
    if switchChanged then state_.switchText = railway.switchText or "" end
    if lockChanged or switchChanged then
        Text(refs_.switchText, (state_.switchLocked and "锁定 · " or "") .. state_.switchText)
        if lockChanged and refs_.switchText then
            refs_.switchText:SetFontColor(state_.switchLocked and C.orange or C.secondary)
        end
    end
    if railway.objective ~= nil and railway.objective ~= state_.objective then
        state_.objective = railway.objective
        Text(refs_.objective, ObjectiveText())
    end
    if readyChanged or lockChanged then RefreshOperations() end
end

---@param name string
function Hud.SetServiceName(name)
    if name == state_.serviceName then return end
    state_.serviceName = name
    Text(refs_.objective, ObjectiveText())
end

---@param name string
function Hud.SetDrivingMode(name)
    if name == state_.drivingMode then return end
    state_.drivingMode = name
    if refs_.drivingMode then refs_.drivingMode:SetText("驾驶 · " .. name) end
end

---@param name string 流畅 / 细致，由 main 回传实际性能档位
function Hud.SetRenderQuality(name)
    if name == state_.renderQuality then return end
    state_.renderQuality = name
    if refs_.renderQuality then refs_.renderQuality:SetText("画质 · " .. name) end
end

--- 目录是 Camera 的真实 id/name；不硬编码 16 个展示标签或猜测其顺序。
---@param catalog CabCameraCatalogEntry[]?
---@param selectedId string?
function Hud.SetCameraCatalog(catalog, selectedId)
    cameraCatalog_ = {}
    for _, entry in ipairs(catalog or {}) do
        cameraCatalog_[#cameraCatalog_ + 1] = {
            id = entry.id, name = DisplayName(entry.name, entry.id, "待同步视角"),
        }
    end
    if refs_.cameraSelector then refs_.cameraSelector:SetCatalog(cameraCatalog_) end
    local id = selectedId or state_.selectedCameraId
    for _, entry in ipairs(cameraCatalog_) do
        if entry.id == id then Hud.SetCameraMode(id, entry.name); return end
    end
    if selectedId then Hud.SetCameraMode(selectedId, nil) end
end

---@param id string
---@param name string?
function Hud.SetCameraMode(id, name)
    local resolved = name
    if not resolved or resolved == "" or resolved == id then
        for _, entry in ipairs(cameraCatalog_) do if entry.id == id then resolved = entry.name; break end end
    end
    local value = DisplayName(resolved, id, "待同步视角")
    if id == state_.selectedCameraId and value == state_.selectedCameraName then return end
    state_.selectedCameraId, state_.selectedCameraName = id, value
    Text(refs_.cameraName, value)
    if refs_.cameraSelector then refs_.cameraSelector:SetSelected(id, value) end
end
---@return boolean
function Hud.IsVolumePanelOpen()
    return refs_.volumePanel ~= nil and refs_.volumePanel:IsOpen()
end
---@param open boolean
function Hud.SetVolumePanelOpen(open)
    if not refs_.volumePanel then return end
    if open then refs_.volumePanel:Open() else refs_.volumePanel:Close() end
end
--- 用 main 的权威设置回填弹窗，避免滑杆与真实音频状态脱节。
---@param values table
function Hud.SyncVolumeSettings(values)
    if refs_.volumePanel then refs_.volumePanel:Sync(values) end
end
function Hud.IsCameraSelectorOpen()
    return refs_.cameraSelector ~= nil and refs_.cameraSelector:IsOpen()
end
---@param open boolean
function Hud.SetCameraSelectorOpen(open)
    if not refs_.cameraSelector then return end
    if open then
        if not callbacks_.onSelectCamera or Hud.IsTrainSelectorOpen() then return end
        Hud.SetMinimapVisible(false)
        refs_.cameraSelector:Open()
    else refs_.cameraSelector:Close() end
end

function Hud.ShowBanner(title, sub)
    Text(refs_.bannerTitle, title or "")
    Text(refs_.bannerSub, sub or "")
    if refs_.banner then refs_.banner:Show() end
end
function Hud.ShowGameOver(reason)
    Hud.SetMinimapVisible(false)
    Hud.SetTrainSelectorOpen(false)
    Hud.SetCameraSelectorOpen(false)
    if refs_.brake then refs_.brake:ReleaseHold() end
    if refs_.gameOverReason then refs_.gameOverReason:SetText(reason) end
    if refs_.gameOver then refs_.gameOver:Show() end
end
function Hud.HideGameOver() if refs_.gameOver then refs_.gameOver:Hide() end end
function Hud.HideBanner()
    if refs_.banner then refs_.banner:Hide() end
end
--- main 同步有效暂停（用户暂停 OR 车型选择器开启），此后不再解析 Toast 文案。
---@param paused boolean
function Hud.SetPaused(paused)
    explicitPause_ = true
    local value = paused == true
    if value == state_.paused then return end
    state_.paused = value
    if value and refs_.brake then refs_.brake:ReleaseHold() end
    if refs_.pause then refs_.pause:SetActive(value) end
    statusDirty_ = true
    RefreshStatus()
    RefreshOperations()
end

---@param text string
---@param seconds number|nil
function Hud.Toast(text, seconds)
    Text(refs_.toastText, text or "")
    if refs_.toast then refs_.toast:Show() end
    state_.toastTime = math.max(0.1, Number(seconds, 2))
    -- 未迁移的旧 main 仍兼容文案协议；SetPaused 接入后只把 Toast 当提示。
    if not explicitPause_ then
        local before = state_.paused
        if text == "已暂停" then
            state_.paused = true
            if refs_.brake then refs_.brake:ReleaseHold() end
        elseif text == "继续行驶" then state_.paused = false end
        if before ~= state_.paused then
            if refs_.pause then refs_.pause:SetActive(state_.paused) end
            statusDirty_ = true
            RefreshOperations()
        end
    end
    RefreshStatus()
end

---@class CabRouteSample
---@field pos Vector3

---@param points CabRouteSample[] Samples {pos = Vector3}
---@param stations CabMapStation[] Marks {x, z, active?}
function Hud.BuildMinimap(points, stations)
    mapPoints_, mapStations_ = {}, {}
    -- 小型示意图约 256 个采样点足够，不必每帧处理数千段路径。
    -- 保留最后采样点，不自行发明闭合线段。
    local count = #(points or {})
    local stride = math.max(1, math.ceil(count / 256))
    for i = 1, count, stride do
        local p = points[i].pos
        if p then mapPoints_[#mapPoints_ + 1] = { x = p.x, z = p.z } end
    end
    if count > 0 and (count - 1) % stride ~= 0 then
        local p = points[count].pos
        if p then mapPoints_[#mapPoints_ + 1] = { x = p.x, z = p.z } end
    end
    for _, st in ipairs(stations or {}) do
        -- 视图状态独立保存，不将 active 标记写回调用者的数据。
        mapStations_[#mapStations_ + 1] = { x = st.x, z = st.z, active = st.active == true }
    end
    if refs_.map then refs_.map:SetRoute(mapPoints_, mapStations_) end
end
---@param x number
---@param z number
---@param activeIndex integer|nil
function Hud.SetMinimapTrain(x, z, activeIndex)
    mapTrain_.x, mapTrain_.z = x, z
    activeStation_ = activeIndex
    if refs_.map then refs_.map:SetTrain(x, z, activeIndex) end
end
---@param visible boolean
function Hud.SetMinimapVisible(visible)
    local value = visible == true
    if value == state_.mapVisible then return end
    state_.mapVisible = value
    if refs_.timetable then refs_.timetable:SetVisible(value) end
    if refs_.mapKey then refs_.mapKey:SetActive(value) end
    if value then Hud.SetCameraSelectorOpen(false) end
    layoutTimer_=0
    LayoutHud()
end

---@param status table?
function Hud.SetTimetable(status)
    timetableSnapshot_=status or {}
    if refs_.timetable then refs_.timetable:SetStatus(status) end
end

--- 目录由 main 从 Train.GetCatalog() 注入。允许 Init 前调用，不猜测初始车型。
---@param catalog CabTrainCatalogEntry[]?
---@param selectedId string?
function Hud.SetTrainCatalog(catalog, selectedId)
    trainCatalog_ = {}
    for _, entry in ipairs(catalog or {}) do
        trainCatalog_[#trainCatalog_ + 1] = {
            id = entry.id, name = DisplayName(entry.name, entry.id, "待同步车型"),
            kind = entry.kind, description = entry.description,
            maxSpeedKmh = entry.maxSpeedKmh, ready = entry.ready, readinessMessage = entry.readinessMessage,
        }
    end
    if refs_.trainSelector then refs_.trainSelector:SetCatalog(trainCatalog_) end
    local id = selectedId or state_.selectedTrainId
    for _, entry in ipairs(trainCatalog_) do
        if entry.id == id then
            Hud.SetSelectedTrain(id, entry.name)
            return
        end
    end
    if selectedId then Hud.SetSelectedTrain(selectedId, "待同步车型") end
end

--- 仅显示权威选择，不修改速度仪表或线路限速。
---@param id string
---@param name string
function Hud.SetSelectedTrain(id, name)
    local selectedId = id or ""
    local selectedName = DisplayName(name, selectedId, "待同步车型")
    if selectedId == state_.selectedTrainId and selectedName == state_.selectedTrainName then return end
    state_.selectedTrainId, state_.selectedTrainName = selectedId, selectedName
    Text(refs_.trainName, state_.selectedTrainName)
    if refs_.trainSelector then
        refs_.trainSelector:SetSelected(state_.selectedTrainId, state_.selectedTrainName)
    end
end

---@return boolean
function Hud.IsTrainSelectorOpen()
    return refs_.trainSelector ~= nil and refs_.trainSelector:IsOpen()
end

--- 开窗只释放 UI 按住的制动，不自行改变暂停状态；关闭/重建/Shutdown 都通知 main。
---@param open boolean
function Hud.SetTrainSelectorOpen(open)
    if not refs_.trainSelector then return end
    if open then
        Hud.SetMinimapVisible(false)
        if refs_.cameraSelector then refs_.cameraSelector:Close() end
        if refs_.brake then refs_.brake:ReleaseHold() end
        refs_.trainSelector:Open()
    else refs_.trainSelector:Close() end
end

---@class CabHudReadings
---@field gameMode string
---@field rageStats CabRageStats
---@field instrumentUnlimited boolean
---@field instrumentLimitText string
---@field runningState string
---@field speedKmh number
---@field speedLimitKmh number
---@field instrumentLimitKmh number 实际速度仪表使用的限速，非配置副本
---@field instrumentMaxKmh number 实际速度仪表量程
---@field throttle integer
---@field maxThrottle integer
---@field brakeRatio number
---@field brakeHeld boolean
---@field reversing boolean
---@field paused boolean
---@field stationName string
---@field nextStation string
---@field mapVisible boolean
---@field selectedTrainId string
---@field selectedTrainName string
---@field trainSelectorOpen boolean
---@field selectedCameraId string
---@field selectedCameraName string
---@field cameraSelectorOpen boolean
---@field cameraCount integer
---@field drivingMode string
---@field renderQuality string
---@field railwayReady boolean
---@field signalAspect string
---@field signalText string
---@field track string
---@field switchText string
---@field switchLocked boolean
---@field objective string
---@field serviceName string
---@field passenger CabPassengerStatus
---@field passengerSynced boolean
---@field routeExpanded boolean
---@field operationsExpanded boolean
---@field soundEnabled boolean
---@field soundVolume number
---@field musicEnabled boolean
---@field musicVolume number
---@field environmentText string
---@field departureText string
---@field departureBlocked boolean
---@field departureReason string
---@field departureWaitSeconds number
---@field trainLoading boolean
---@field trainLoadingRatio number
---@field trainLoadingText string
---@field version string
---@field announcementText string
---@field announcementVisible boolean
---@field announcementKey string

--- 返回显示值快照；仅供测试/验收，不允许修改 HUD 内部状态。
---@return CabHudReadings
function Hud.GetReadings()
    local feedback = Feedback.GetReadings()
    ---@type CabHudReadings
    local readings = {
        gameMode = state_.gameMode, rageStats = Rage.GetStats(), runningState = lastStatus_,
        instrumentUnlimited = refs_.meter and refs_.meter.unlimited_ or state_.rage,
        instrumentLimitText = refs_.meter and refs_.meter:GetLimitText() or (state_.rage and "不限速" or "限速 " .. math.floor(state_.limit)),
        environmentText = feedback.environmentText, departureText = feedback.departureText,
        departureBlocked = feedback.departureBlocked, departureReason = feedback.departureReason,
        departureWaitSeconds = feedback.departureWaitSeconds, trainLoading = feedback.trainLoading,
        trainLoadingRatio = feedback.trainLoadingRatio, trainLoadingText = feedback.trainLoadingText,
        version = feedback.version, announcementText = feedback.announcementText,
        announcementVisible = feedback.announcementVisible, announcementKey = feedback.announcementKey,
        selectedTrainId = state_.selectedTrainId,
        selectedTrainName = state_.selectedTrainName,
        trainSelectorOpen = Hud.IsTrainSelectorOpen(),
        selectedCameraId = state_.selectedCameraId,
        selectedCameraName = state_.selectedCameraName,
        cameraSelectorOpen = Hud.IsCameraSelectorOpen(),
        cameraCount = #cameraCatalog_, drivingMode = state_.drivingMode,
        renderQuality = state_.renderQuality,
        railwayReady = state_.railwayReady, signalAspect = state_.aspect,
        signalText = state_.signalText, track = state_.track,
        switchText = state_.switchText, switchLocked = state_.switchLocked, objective = state_.objective,
        serviceName = state_.serviceName,
        speedKmh = state_.speed,
        speedLimitKmh = state_.limit,
        instrumentLimitKmh = refs_.meter and refs_.meter.limit_ or state_.limit,
        instrumentMaxKmh = refs_.meter and refs_.meter.maxSpeed_ or state_.instrumentMax,
        throttle = state_.notch, maxThrottle = state_.maxNotch, brakeRatio = state_.brake,
        brakeHeld = refs_.brake ~= nil and refs_.brake.pointer_ ~= nil,
        reversing = state_.reversing, paused = state_.paused,
        stationName = state_.station, nextStation = state_.distance,
        mapVisible = state_.mapVisible,
        passenger = Passenger.Snapshot(state_.passenger), passengerSynced = state_.passengerSynced,
        routeExpanded = state_.routeExpanded, operationsExpanded = state_.operationsExpanded,
        soundEnabled = state_.soundEnabled,
        soundVolume = state_.soundVolume, musicEnabled = state_.musicEnabled, musicVolume = state_.musicVolume,
    }
    return readings
end

--- 验收时使用 root:FindById("speedInstrument") --[[@as CabSpeedometer?]]。
---@return Panel?
function Hud.GetRoot() return refs_.root end

--- 返回已挂载的选择器；验收仍应核实 GetRoot():FindById 与此引用一致。
---@return CabTrainSelector?
function Hud.GetTrainSelector() return refs_.trainSelector end

---@return CabCameraSelector?
function Hud.GetCameraSelector() return refs_.cameraSelector end

--- 返回仪表实际布局；单位为 UI 基准像素，不乘 DPR。
---@return table
function Hud.GetLayout()
    return {
        speedometer = refs_.meter and refs_.meter:GetAbsoluteLayout() or {},
        controls = refs_.desk and refs_.desk:GetAbsoluteLayout() or {},
        station = refs_.info and refs_.info:GetAbsoluteLayout() or {},
        actions = refs_.actions and refs_.actions:GetAbsoluteLayout() or {},
        trainModel = refs_.trainBar and refs_.trainBar:GetAbsoluteLayout() or {},
        trainSelector = refs_.trainSelector and refs_.trainSelector.drawer_:GetAbsoluteLayout() or {},
        cameraSelector = refs_.cameraSelector and refs_.cameraSelector:GetAbsoluteLayout() or {},
        railwayControls = refs_.railwayControls and refs_.railwayControls:GetAbsoluteLayout() or {},
        switchStrip = refs_.switchStrip and refs_.switchStrip:GetAbsoluteLayout() or {},
        routeToggle = refs_.routeToggle and refs_.routeToggle:GetAbsoluteLayout() or {},
        operationsToggle = refs_.operationsToggle and refs_.operationsToggle:GetAbsoluteLayout() or {},
        mapButton=refs_.mapKey and refs_.mapKey:GetAbsoluteLayout() or {},
        routeDropdown=refs_.timetable and refs_.timetable.root:GetAbsoluteLayout() or {},
        minimap=refs_.map and refs_.map:GetAbsoluteLayout() or {},
        passenger = refs_.passenger and refs_.passenger:GetAbsoluteLayout() or {},
        scale = UI.GetScale(),
    }
end

---@param dt number
function Hud.Update(dt)
    -- 保留 Game.UpdateHud 的调用接口；动画、按住/松手和提示计时
    -- 由 UI 单次自动更新负责，暂停时仍可交互，不在此重复推进。
    RefreshStatus()
end
---@param keepUI boolean? 页面切换时保留共享 UI；应用结束/独立测试才关闭。
function Hud.Shutdown(keepUI)
    if refs_.cameraSelector then refs_.cameraSelector:Close() end
    if refs_.trainSelector then refs_.trainSelector:Close() end
    if refs_.brake then refs_.brake:ReleaseHold() end
    if not keepUI then UI.Shutdown() end
    refs_ = {}
    callbacks_ = {}
    trainCatalog_, cameraCatalog_ = {}, {}
    explicitPause_ = false
    state_.selectedTrainId, state_.selectedTrainName = "", "待同步车型"
    state_.selectedCameraId, state_.selectedCameraName = "", "待同步视角"
    state_.railwayReady, state_.switchLocked = false, true
    state_.aspect, state_.signalText, state_.track = "unknown", "信号待同步", "线路待同步"
    state_.switchText, state_.objective, state_.drivingMode = "道岔待同步", "运营任务待同步", "待同步"
    state_.serviceName = ""
    state_.renderQuality = "流畅"
    state_.routeExpanded, state_.operationsExpanded = false, false
    state_.passengerSynced, state_.passenger = false, Passenger.Snapshot(nil)
    Rage.Reset() -- 清快照但保留模式选择；返回设置后 Init 可先收到同 id。
    Drive.Reset()
    state_.soundEnabled = true
    state_.soundVolume,state_.musicEnabled,state_.musicVolume=.75,true,.35
    Feedback.Reset()
    timetableSnapshot_={}
end

return Hud
