-- 紧凑型机车驾驶 HUD，兼容原有 main/Game API。
-- 只读 GameConfig；不依赖 Game/Train/world，避免循环加载。
local UI = require "urhox-libs/UI"
local GameConfig = require "config.GameConfig"
local Skin = require "ui.CabStyle"
local Cab = require "ui.CabInstruments"
local TrainSelector = require "ui.TrainSelector"
local C = Skin.Colors
local Hud = {}

---@class CabHudCallbacks
---@field onThrottleUp? fun()
---@field onThrottleDown? fun()
---@field onBrake? fun() 保留旧接口：按下一次追加一档制动
---@field onBrakeHold? fun(held: boolean) Main owns continuous braking when provided
---@field onBrakeRelease? fun() Ends hold, does NOT clear existing brake pressure
---@field onReleaseBrake? fun() Explicit brake pressure release / 缓解
---@field onHorn? fun()
---@field onPause? fun()
---@field onCamera? fun()
---@field onReverse? fun()
---@field onSwitch? fun(dir: number) Retained; no fake turnout UI on a single-line loop
---@field onSelectTrain? fun(id: string): boolean, string? Main owns authoritative selection
---@field onOpenTrainSelector? fun(open: boolean) Main owns pause/restore and gameplay input gating
---@type CabHudCallbacks
local callbacks_ = {}

---@class CabHudRefs
---@field root? Panel
---@field info? CabPanel
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
---@field left? Panel
---@field hint? Label
---@field banner? CabPanel
---@field bannerTitle? Label
---@field bannerSub? Label
---@field toast? CabPanel
---@field toastText? Label
---@field trainBar? CabPanel
---@field trainName? Label
---@field trainSelector? CabTrainSelector
---@type CabHudRefs
local refs_ = {}

local state_ = {
    speed = 0.0,
    limit = GameConfig.Gameplay.SpeedLimitKmh,
    instrumentMax = 400,
    notch = 0,
    maxNotch = GameConfig.Train.MaxThrottle,
    brake = 0.0,
    reversing = false,
    paused = false,
    dwelling = false,
    station = GameConfig.Stations[1] and GameConfig.Stations[1].name or "下一站",
    distance = "计算距离",
    clock = "00:00",
    xp = "0",
    switch = 0.0,
    mapVisible = false,
    toastTime = 0.0,
    selectedTrainId = "",
    selectedTrainName = "待同步车型",
}
---@type CabTrainCatalogEntry[]
local trainCatalog_ = {}
---@type CabMapPoint[]
local mapPoints_ = {}
---@type CabMapStation[]
local mapStations_ = {}
local mapTrain_ = { x = 0.0, z = 0.0 }
---@type integer?
local activeStation_ = nil
local lastLayout_ = ""
local lastStatus_ = ""
-- 使用专用暂停同步接口后，Toast 文案不再参与暂停状态管理。
local explicitPause_ = false

---@param value number|string|nil
---@param fallback number
---@return number
local function Number(value, fallback)
    local n = tonumber(value)
    if not n or n ~= n or n == math.huge or n == -math.huge then return fallback end
    return n
end

---@param label Label?
---@param text string
local function Text(label, text)
    if label and label:GetText() ~= text then label:SetText(text) end
end

local function RefreshStatus()
    local text, color = "待发", C.secondary
    if state_.paused then text, color = "暂停", C.orange
    elseif state_.dwelling then text, color = "站停", C.teal
    elseif math.abs(state_.speed) > state_.limit + 0.5 then text, color = "超速", C.red
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

---@param notch integer
local function SelectThrottle(notch)
    if state_.paused or state_.dwelling then return end
    local target = math.max(0, math.min(state_.maxNotch, notch))
    local callback = target > state_.notch and callbacks_.onThrottleUp or callbacks_.onThrottleDown
    if not callback then return end
    -- 旧 API 只提供逐档回调，因此仅重放档位差；下一帧由
    -- SetThrottle 的权威反馈校正手柄位置。
    for _ = 1, math.abs(target - state_.notch) do callback() end
    state_.notch = target
    if refs_.throttle then refs_.throttle:SetNotch(target, state_.maxNotch) end
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
    local safe = UI.GetSafeAreaInsets()
    local insetTop = safe.top
    if sdk and sdk.GetNativeExitMenuRect then
        local menu = sdk:GetNativeExitMenuRect()
        if menu then insetTop = math.max(insetTop, menu.bottom * graphics:GetHeight() / UI.GetScale()) end
    end
    local signature = string.format("%.1f %.1f %.1f %.1f %.1f %.1f", vw, vh,
        safe.left, insetTop, safe.right, safe.bottom)
    if signature == lastLayout_ then return end
    lastLayout_ = signature
    local edge = 12
    local left, right = safe.left + edge, safe.right + edge
    local top, bottom = insetTop + edge, safe.bottom + edge
    local w, h = vw - left - right, vh - top - bottom
    local small = h < 490
    local narrow = w < 590
    local meterSize = small and 150 or 184
    local leverHeight = small and 134 or 150
    local deskWidth = 198
    local deskHeight = leverHeight + 58
    if refs_.actions then refs_.actions:SetStyle({ top = top, right = right }) end
    if refs_.info then
        refs_.info:SetStyle({ left = left, top = narrow and top + 52 or top,
            width = math.min(520, narrow and w or math.max(220, w - 158)), height = 50 })
    end
    if refs_.extras then refs_.extras:SetVisible(w >= 740) end
    if refs_.meter then
        refs_.meter:SetStyle({ width = meterSize, height = meterSize,
            right = narrow and right or right + deskWidth + 10,
            bottom = narrow and bottom + deskHeight + 9 or bottom + 4 })
    end
    if refs_.desk then refs_.desk:SetStyle({ right = right, bottom = bottom,
        width = deskWidth, height = deskHeight }) end
    if refs_.throttle then refs_.throttle:SetHeight(leverHeight) end
    if refs_.brake then refs_.brake:SetHeight(leverHeight) end
    if refs_.left then refs_.left:SetStyle({ left = left, bottom = bottom }) end
    if refs_.hint then refs_.hint:SetVisible(not narrow and not small) end
    if refs_.map then
        refs_.map:SetStyle({ right = right, top = narrow and top + 110 or top + 60,
            width = small and 160 or 176, height = small and 92 or 104 })
    end
    if refs_.banner then refs_.banner:SetStyle({ top = narrow and top + 110 or top + 62,
        left = left, width = math.min(370, w - (narrow and 0 or 190)) }) end
    if refs_.toast then refs_.toast:SetStyle({ top = narrow and top + 174 or top + 119,
        left = left, width = math.min(370, w - (narrow and 0 or 190)) }) end
    if refs_.trainBar then refs_.trainBar:SetStyle({ left = left, bottom = bottom + (small and 0 or 30) + 72,
        width = math.min(290, math.max(0, w - deskWidth - (narrow and 16 or meterSize + 26))), height = 44 }) end
    if refs_.trainSelector then refs_.trainSelector:SetBounds(left, top, w, h) end
    print(string.format("[Hud] 驾驶仪表 %.0fx%.0f base px, %s", vw, vh, narrow and "窄屏布局" or "横屏布局"))
end

---@class CabHudRoot : Panel
---@overload fun(props?: PanelProps): CabHudRoot
local HudRoot = UI.Panel:Extend("CabHudRoot")
---@param dt number
function HudRoot:Update(dt)
    LayoutHud()
    RefreshStatus()
    if state_.toastTime > 0 then
        state_.toastTime = math.max(0, state_.toastTime - dt)
        if state_.toastTime == 0 and refs_.toast then refs_.toast:Hide() end
    end
end

---@param cbs CabHudCallbacks?
function Hud.Init(cbs)
    if refs_.trainSelector then refs_.trainSelector:Close() end
    callbacks_ = cbs or {}
    state_.limit = Number(GameConfig.Gameplay.SpeedLimitKmh, 80)
    if state_.limit <= 0 then state_.limit = 80 end
    state_.paused = false
    explicitPause_ = false
    state_.mapVisible = false
    state_.toastTime = 0
    UI.Init({ theme = Skin.CreateTheme(), scale = UI.Scale.DEFAULT })
    Hud.BuildRoot()
    print("[Hud] 金属驾驶仪表就绪，初始限速 " .. tostring(state_.limit) .. " km/h")
end

--- 保留重建 API；重建前安全释放按住的制动手柄。
function Hud.BuildRoot()
    if refs_.trainSelector then refs_.trainSelector:Close() end
    if refs_.brake then refs_.brake:ReleaseHold() end
    refs_ = {}
    lastLayout_, lastStatus_ = "", ""
    local station = Label { id = "stationName", text = state_.station, fontSize = 13.5,
        fontWeight = "bold", minWidth = 64, flexGrow = 1, flexShrink = 1 }
    local distance = Label { id = "nextVal", text = state_.distance, fontColor = C.teal,
        fontSize = 12, fontWeight = "bold", minWidth = 62, textAlign = "right" }
    local status = Label { id = "runningState", text = "待发", fontSize = 9, fontColor = C.secondary }
    local statusLamp = UI.Panel { width = 4, height = 4, borderRadius = 2,
        backgroundColor = C.secondary, pointerEvents = "none" }
    local clock = Label { text = state_.clock, fontSize = 9, fontColor = C.secondary }
    local xp = Label { text = "经验 " .. state_.xp, fontSize = 9, fontColor = C.muted }
    local extras = UI.Panel { flexDirection = "row", gap = 12, pointerEvents = "none", children = { clock, xp } }
    local info = Cab.Panel {
        id = "routeInfo", position = "absolute", width = 520, height = 50,
        paddingHorizontal = 12, paddingVertical = 6, gap = 2, pointerEvents = "none",
        children = {
            UI.Panel { flexDirection = "row", alignItems = "center", gap = 12,
                pointerEvents = "none", children = { station, distance } },
            UI.Panel { flexDirection = "row", alignItems = "center", gap = 6,
                pointerEvents = "none", children = {
                    Label { text = "下一站", fontSize = 8, fontColor = C.muted },
                    statusLamp, status, UI.Panel { flexGrow = 1 }, extras,
                } },
        },
    }
    local pause = Cab.Key { icon = "pause", text = "暂停", width = 44, height = 44,
        onClick = function()
            if refs_.brake then refs_.brake:ReleaseHold() end
            if callbacks_.onPause then callbacks_.onPause() end
        end }
    local mapKey = Cab.Key { icon = "map", text = "线路", width = 44, height = 44,
        onClick = function() Hud.SetMinimapVisible(not state_.mapVisible) end }
    local actions = UI.Panel { position = "absolute", flexDirection = "row", gap = 6,
        pointerEvents = "box-none", children = {
            mapKey,
            Cab.Key { icon = "camera", text = "视角", width = 44, height = 44,
                onClick = function() if callbacks_.onCamera then callbacks_.onCamera() end end },
            pause,
        } }
    local meter = Cab.Speedometer { id = "speedInstrument", position = "absolute",
        maxSpeed = state_.instrumentMax, limit = state_.limit }
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
                            onClick = function() if callbacks_.onThrottleUp then callbacks_.onThrottleUp() end end },
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
            reverse,
        } },
    } }
    local map = Cab.Minimap { id = "minimap", position = "absolute", visible = state_.mapVisible }
    map:SetRoute(mapPoints_, mapStations_)
    map:SetTrain(mapTrain_.x, mapTrain_.z, activeStation_)
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
    local trainBar = Cab.Panel { id = "trainModelBar", position = "absolute", width = 290, height = 44,
        flexDirection = "row", alignItems = "center", paddingLeft = 10, gap = 8,
        pointerEvents = "box-none", children = {
            trainName,
            UI.Button { id = "openTrainSelector", text = "车型", width = 64, height = 44,
                variant = "secondary", onClick = function() Hud.SetTrainSelectorOpen(true) end },
        } }
    local selector = TrainSelector { id = "trainSelector" }
    selector:SetCallbacks({
        onSelect = callbacks_.onSelectTrain and function(id)
            local success, message = callbacks_.onSelectTrain(id)
            if success == true then
                -- main 可在回调内同步真实选择；未同步时从已注入的目录补齐名称。
                if state_.selectedTrainId ~= id then
                    local entry = selector:FindTrain(id)
                    Hud.SetSelectedTrain(id, entry and entry.name or id)
                end
                Hud.Toast(message or "车型已切换", 2)
            end
            return success, message
        end or nil,
        onOpen = function(open)
            if callbacks_.onOpenTrainSelector then callbacks_.onOpenTrainSelector(open) end
        end,
    })
    selector:SetCatalog(trainCatalog_)
    selector:SetSelected(state_.selectedTrainId, state_.selectedTrainName)
    selector:SetOperatingState(state_.speed, state_.limit)
    local root = HudRoot { id = "hudRoot", width = "100%", height = "100%",
        pointerEvents = "box-none", children = { info, actions, meter, desk, left, map, banner, toast,
            trainBar, selector } }
    refs_ = {
        root = root, info = info, actions = actions, station = station, distance = distance,
        clock = clock, xp = xp, extras = extras, status = status, statusLamp = statusLamp,
        meter = meter, desk = desk, throttle = throttle, brake = brake, reverse = reverse,
        pause = pause, mapKey = mapKey, map = map, left = left, hint = hint,
        banner = banner, bannerTitle = bannerTitle, bannerSub = bannerSub, toast = toast, toastText = toastText,
        trainBar = trainBar, trainName = trainName, trainSelector = selector,
    }
    UI.SetRoot(root, true)
    -- 检查挂载与真实 ID，避免只有 refs 可用、按钮树却漏挂选择器。
    assert(root:FindById("trainSelector") == selector, "车型选择器未正确挂载到 HUD")
    LayoutHud()
    RefreshStatus()
end

-- 原有数据更新 API 保持有效；新增站名/方向更新无需反向引用
-- 已经依赖 HUD 的 Game 或 Train 模块。
---@param text string
function Hud.SetNextStation(text)
    state_.distance = text or "计算距离"
    state_.dwelling = state_.distance == "停靠中" or state_.distance == "站停"
    Text(refs_.distance, state_.distance)
    RefreshStatus()
end
---@param name string
function Hud.SetStationName(name)
    state_.station = name or "下一站"
    Text(refs_.station, state_.station)
end
---@param maximum number
function Hud.SetSpeedRange(maximum)
    state_.instrumentMax = math.max(40, math.ceil(Number(maximum, 400) / 20) * 20)
    if refs_.meter then refs_.meter:SetRange(state_.instrumentMax) end
end

---@param kmh number|string|nil
function Hud.SetLimit(kmh)
    local value = Number(kmh, GameConfig.Gameplay.SpeedLimitKmh)
    state_.limit = value >= 0 and value or GameConfig.Gameplay.SpeedLimitKmh
    if refs_.meter then refs_.meter:SetReading(state_.speed, state_.limit) end
    if refs_.trainSelector then refs_.trainSelector:SetOperatingState(state_.speed, state_.limit) end
    RefreshStatus()
end
---@param kmh number
---@param limit number|string|nil Optional, preserves old SetSpeed(kmh) call
function Hud.SetSpeed(kmh, limit)
    state_.speed = Number(kmh, 0)
    if limit ~= nil then Hud.SetLimit(limit) end
    if refs_.meter then refs_.meter:SetReading(state_.speed, state_.limit) end
    if refs_.trainSelector then refs_.trainSelector:SetOperatingState(state_.speed, state_.limit) end
    RefreshStatus()
end
---@param seconds number
function Hud.SetTime(seconds)
    local t = math.max(0, math.floor(Number(seconds, 0)))
    state_.clock = string.format("%02d:%02d", math.floor(t / 60), t % 60)
    Text(refs_.clock, state_.clock)
end
function Hud.SetXp(xp)
    state_.xp = tostring(xp or 0)
    Text(refs_.xp, "经验 " .. state_.xp)
end
---@param notch integer
---@param maxNotch integer
function Hud.SetThrottle(notch, maxNotch)
    state_.maxNotch = math.max(1, math.floor(Number(maxNotch, 8)))
    state_.notch = math.max(0, math.min(state_.maxNotch, math.floor(Number(notch, 0))))
    if refs_.throttle then refs_.throttle:SetNotch(state_.notch, state_.maxNotch) end
    RefreshStatus()
end
---@param ratio number
function Hud.SetBrake(ratio)
    state_.brake = math.max(0, math.min(1, Number(ratio, 0)))
    if refs_.brake then refs_.brake:SetRatio(state_.brake) end
    RefreshStatus()
end
---@param reversing boolean
function Hud.SetReversing(reversing)
    state_.reversing = reversing == true
    if refs_.reverse then
        refs_.reverse:SetText(state_.reversing and "后退" or "前进")
        refs_.reverse:SetActive(state_.reversing)
    end
end
---@param pos number
function Hud.SetSwitch(pos)
    -- 仅保留兼容数据，单线环线没有真实道岔可操作。
    state_.switch = math.max(-1, math.min(1, Number(pos, 0)))
end
function Hud.ShowBanner(title, sub)
    Text(refs_.bannerTitle, title or "")
    Text(refs_.bannerSub, sub or "")
    if refs_.banner then refs_.banner:Show() end
end
function Hud.HideBanner()
    if refs_.banner then refs_.banner:Hide() end
end
--- main 同步有效暂停（用户暂停 OR 车型选择器开启），此后不再解析 Toast 文案。
---@param paused boolean
function Hud.SetPaused(paused)
    explicitPause_ = true
    state_.paused = paused == true
    if state_.paused and refs_.brake then refs_.brake:ReleaseHold() end
    if refs_.pause then refs_.pause:SetActive(state_.paused) end
    RefreshStatus()
end

---@param text string
---@param seconds number|nil
function Hud.Toast(text, seconds)
    Text(refs_.toastText, text or "")
    if refs_.toast then refs_.toast:Show() end
    state_.toastTime = math.max(0.1, Number(seconds, 2))
    -- 未迁移的旧 main 仍兼容文案协议；SetPaused 接入后只把 Toast 当提示。
    if not explicitPause_ then
        if text == "已暂停" then
            state_.paused = true
            if refs_.brake then refs_.brake:ReleaseHold() end
        elseif text == "继续行驶" then state_.paused = false end
    end
    if refs_.pause then refs_.pause:SetActive(state_.paused) end
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
    state_.mapVisible = visible == true
    if refs_.map then refs_.map:SetVisible(state_.mapVisible) end
    if refs_.mapKey then refs_.mapKey:SetActive(state_.mapVisible) end
end

--- 目录由 main 从 Train.GetCatalog() 注入。允许 Init 前调用，不猜测初始车型。
---@param catalog CabTrainCatalogEntry[]?
---@param selectedId string?
function Hud.SetTrainCatalog(catalog, selectedId)
    trainCatalog_ = catalog or {}
    if refs_.trainSelector then refs_.trainSelector:SetCatalog(trainCatalog_) end
    local id = selectedId or state_.selectedTrainId
    for _, entry in ipairs(trainCatalog_) do
        if entry.id == id then
            Hud.SetSelectedTrain(id, entry.name)
            return
        end
    end
    if selectedId then Hud.SetSelectedTrain(selectedId, selectedId) end
end

--- 仅显示权威选择，不修改速度仪表或线路限速。
---@param id string
---@param name string
function Hud.SetSelectedTrain(id, name)
    state_.selectedTrainId = id or ""
    state_.selectedTrainName = name and name ~= "" and name or "待同步车型"
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
        if refs_.brake then refs_.brake:ReleaseHold() end
        refs_.trainSelector:Open()
    else refs_.trainSelector:Close() end
end

---@class CabHudReadings
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

--- 返回显示值快照；仅供测试/验收，不允许修改 HUD 内部状态。
---@return CabHudReadings
function Hud.GetReadings()
    local readings = {
        selectedTrainId = state_.selectedTrainId,
        selectedTrainName = state_.selectedTrainName,
        trainSelectorOpen = Hud.IsTrainSelectorOpen(),
        speedKmh = state_.speed,
        speedLimitKmh = state_.limit,
        instrumentLimitKmh = refs_.meter and refs_.meter.limit_ or state_.limit,
        instrumentMaxKmh = refs_.meter and refs_.meter.maxSpeed_ or state_.instrumentMax,
        throttle = state_.notch, maxThrottle = state_.maxNotch, brakeRatio = state_.brake,
        brakeHeld = refs_.brake ~= nil and refs_.brake.pointer_ ~= nil,
        reversing = state_.reversing, paused = state_.paused,
        stationName = state_.station, nextStation = state_.distance,
        mapVisible = state_.mapVisible,
    }
    return readings
end

--- 验收时使用 root:FindById("speedInstrument") --[[@as CabSpeedometer?]]。
---@return Panel?
function Hud.GetRoot() return refs_.root end

--- 返回已挂载的选择器；验收仍应核实 GetRoot():FindById 与此引用一致。
---@return CabTrainSelector?
function Hud.GetTrainSelector() return refs_.trainSelector end

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
        scale = UI.GetScale(),
    }
end

---@param dt number
function Hud.Update(dt)
    -- 保留 Game.UpdateHud 的调用接口；动画、按住/松手和提示计时
    -- 由 UI 单次自动更新负责，暂停时仍可交互，不在此重复推进。
    RefreshStatus()
end
function Hud.Shutdown()
    if refs_.trainSelector then refs_.trainSelector:Close() end
    if refs_.brake then refs_.brake:ReleaseHold() end
    UI.Shutdown()
    refs_ = {}
    callbacks_ = {}
    trainCatalog_ = {}
    explicitPause_ = false
    state_.selectedTrainId, state_.selectedTrainName = "", "待同步车型"
end

return Hud
