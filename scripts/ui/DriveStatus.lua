-- 驾驶状态只投影主入口注入的诊断；不查询音频、不推进道岔、不乐观改灯光。
local UI = require "urhox-libs/UI"
local Skin = require "ui.CabStyle"
local C = Skin.Colors
local Drive = {}

---@class CabDriveStatus
---@field headlightMode? string auto / on / off
---@field headlightOn? boolean
---@field musicTitle? string
---@field musicState? string playing / muted / disabled / volume0 / loading / error / paused
---@field musicVolume? number
---@field musicEnabled? boolean
---@field grade? number dy/ds，显示为千分坡
---@field elevation? number 米
---@field nextJunction? table|false 可选；通常由SetRailwayStatus.nextSwitch提供

local snapshot_ = {} ---@type CabDriveStatus
local nextSwitch_ = {} ---@type table
local junctionKnown_, hasJunction_ = false, false
local enabled_, volume_ = true, .35
local switchReady_, switchLocked_, paused_ = false, true, false
local legacySwitchText_ = "道岔待同步"
local callbacks_ = {} ---@type table
local refs_ = {} ---@type table<string, Widget>
local switchWidth_ = 250
local lastMusicBorder_ = ""
local lastSwitchEnabled_ = false

local function finite(value)
    return type(value) == "number" and value == value and math.abs(value) < math.huge
end
local function text(id, value)
    local label = refs_[id] --[[@as Label|Button?]]
    if label and label.props.text ~= value then label:SetText(value) end
end
local function fit(value, width, size)
    if not UI.GetNVGContext() then return value end
    local face, font = UI.Theme.FontFace("sans", "bold"), UI.Theme.FontSize(size)
    if UI.MeasureTextWidth(value, font, face) <= width then return value end
    local result = ""
    for _, code in utf8.codes(value) do
        local char = utf8.char(code)
        if UI.MeasureTextWidth(result .. char .. "…", font, face) > width then break end
        result = result .. char
    end
    return result .. "…"
end
local function distance(value)
    if not finite(value) then return "距离待同步" end
    return value >= 1000 and string.format("%.1fkm", value / 1000)
        or string.format("%dm", math.max(0, math.floor(value + .5)))
end
local function musicState()
    -- 播放/加载/失败仅由音频诊断提供；设置只能证明关闭或零音量。
    if not enabled_ then return "disabled" end
    if snapshot_.musicState == "muted" then return "muted" end
    if volume_ <= 0 then return "volume0" end
    return snapshot_.musicState or "unknown"
end
local function refresh()
    local mode = snapshot_.headlightMode
    local modes = { auto = "自动", on = "常亮", off = "关闭" }
    text("headlightLabel", "车灯 " .. (modes[mode or ""] or "待同步") .. " L")
    text("headlightState", snapshot_.headlightOn == nil and "状态待同步"
        or (snapshot_.headlightOn and "已亮 · 点击循环" or "未亮 · 点击循环"))
    local state = musicState()
    local names = { playing = "播放", muted = "总静音", disabled = "关闭", volume0 = "音量0",
        volume_zero = "音量0", loading = "加载中", error = "加载失败", paused = "暂停",
        device = "设备无声", unknown = "待同步" }
    local hints = { muted = "点声音解除", disabled = "点击开启", volume0 = "点音量调高",
        volume_zero = "点音量调高", loading = "等待音频就绪", error = "音频未就绪",
        paused = "等待继续", device = "检查音频设备", unknown = "等待音频诊断" }
    local title = snapshot_.musicTitle or ""
    text("musicLabel", "音乐 " .. (names[state] or "待同步"))
    text("musicHint", fit(hints[state] or (title ~= "" and title or "点击关闭音乐"), 78, 7.5))
    text("musicDiagnostics", "BGM · " .. (names[state] or "待同步")
        .. (title ~= "" and (" · " .. title) or "")
        .. (state == "muted" and " · 点声音解除总静音" or ""))
    local light = refs_.headlight --[[@as Button?]]
    if light and light:IsDisabled() ~= (callbacks_.onHeadlightMode == nil) then
        light:SetDisabled(callbacks_.onHeadlightMode == nil)
    end
    local music = refs_.music --[[@as Button?]]
    if music and music:IsDisabled() ~= (callbacks_.onMusicToggle == nil) then
        music:SetDisabled(callbacks_.onMusicToggle == nil)
    end
    local border = state == "playing" and "playing" or (state == "error" and "error" or "normal")
    if music and border ~= lastMusicBorder_ then
        lastMusicBorder_ = border
        music:SetStyle({ borderColor = border == "playing" and C.teal or (border == "error" and C.red or C.edge) })
    end
    local grade = snapshot_.grade
    local terrain = finite(grade) and string.format("坡度 %+.1f‰", grade * 1000) or "坡度待同步"
    if finite(snapshot_.elevation) then terrain = terrain .. string.format(" · 海拔 %.0fm", snapshot_.elevation) end
    text("terrain", terrain)
end
local function canSwitch()
    return callbacks_.onSwitch ~= nil and switchReady_ and not paused_
        and (not junctionKnown_ or hasJunction_) and not switchLocked_
end
local function refreshSwitch()
    local hint = legacySwitchText_
    if junctionKnown_ then
        if not hasJunction_ then hint = "前方无道岔 · 沿当前线路行驶"
        else
            hint = (nextSwitch_.kind == "interval" and "区间岔 · " or "站场岔 · ")
                .. tostring(nextSwitch_.name or "前方道岔") .. " · " .. distance(nextSwitch_.distance)
                .. (switchLocked_ and " · 整列通过锁定" or " · 可预选")
        end
    elseif switchLocked_ then hint = "整列通过锁定 · " .. legacySwitchText_ end
    -- 两行保留区间名与真实距离，不把所有区间岔误称为进站。
    text("switchHint", hint)
    local lockedPrefix = switchLocked_ and "锁 · " or ""
    local selected = hasJunction_ and nextSwitch_.selected or ""
    text("switchMainline", lockedPrefix .. (selected == "main" and "已选主 Q" or "主线 Q"))
    text("switchSiding", lockedPrefix .. (selected == "siding" and "已选侧 E" or "侧线 E"))
    local enabled = canSwitch()
    if enabled ~= lastSwitchEnabled_ then
        lastSwitchEnabled_ = enabled
        for _, id in ipairs({ "switchMainline", "switchSiding" }) do
            local button = refs_[id] --[[@as Button?]]
            if button then button:SetDisabled(not enabled) end
        end
    end
end

---@param status CabDriveStatus?
function Drive.SetStatus(status)
    for key, value in pairs(status or {}) do
        if key ~= "nextJunction" then snapshot_[key] = value end
    end
    if status and status.musicEnabled ~= nil then enabled_ = status.musicEnabled == true end
    if status and status.musicVolume ~= nil then volume_ = status.musicVolume end
    if status and status.nextJunction ~= nil then
        Drive.SetRailway({ nextSwitch = status.nextJunction, locked = switchLocked_ }, paused_)
    end
    refresh()
end
function Drive.SetMusicSettings(enabled, volume)
    enabled_, volume_ = enabled == true, volume
    refresh()
end
function Drive.SetRailway(status, paused)
    if status then
        switchReady_ = true
        if status.nextSwitch ~= nil or status.hasNextSwitch ~= nil then
            junctionKnown_ = true
            hasJunction_ = type(status.nextSwitch) == "table" and status.hasNextSwitch ~= false
            nextSwitch_ = {}
            if hasJunction_ then
                for key, value in pairs(status.nextSwitch) do nextSwitch_[key] = value end
            end
        end
        if status.switchText ~= nil then legacySwitchText_ = status.switchText end
        if junctionKnown_ and hasJunction_ then switchLocked_ = nextSwitch_.locked == true
        elseif status.locked ~= nil then switchLocked_ = status.locked == true end
    end
    paused_ = paused == true
    refreshSwitch()
end
function Drive.CanSwitch() return canSwitch() end
function Drive.Layout(width)
    switchWidth_ = width
    local hint = refs_.switchHint --[[@as Label?]]
    if hint then hint:SetFontSize(width < 210 and 7.5 or 8) end
end

local function statusButton(id, width, mainId, subId, action)
    local main = UI.Label { id = mainId, text = "待同步", fontSize = 8.5, fontWeight = "bold",
        height = 17, width = "100%", maxLines = 1, textAlign = "center", fontColor = C.text, pointerEvents = "none" }
    local sub = UI.Label { id = subId, text = "", fontSize = 7.5, height = 14, width = "100%",
        maxLines = 1, textAlign = "center", fontColor = C.secondary, pointerEvents = "none" }
    refs_[mainId], refs_[subId] = main, sub
    return UI.Button { id = id, width = width, height = 44, minHeight = 44, padding = 3, gap = 0,
        justifyContent = "center", alignItems = "center", variant = "secondary", onClick = action,
        children = { main, sub } }
end
function Drive.Create(callbacks)
    callbacks_, refs_ = callbacks or {}, {}
    lastMusicBorder_, lastSwitchEnabled_ = "", false
    local headlight = statusButton("headlightMode", 74, "headlightLabel", "headlightState", function()
        if callbacks_.onHeadlightMode then
            local nextMode = { auto = "on", on = "off", off = "auto" }
            callbacks_.onHeadlightMode(nextMode[snapshot_.headlightMode or "auto"] or "auto")
        end
    end)
    local music = statusButton("toggleMusic", 84, "musicLabel", "musicHint", function()
        if callbacks_.onMusicToggle then callbacks_.onMusicToggle(not enabled_) end
    end)
    local controls = UI.Panel { id = "driveStatus", height = 44, flexDirection = "row", gap = 4,
        pointerEvents = "box-none", children = { headlight, music } }
    local terrain = UI.Label { id = "driveTerrain", text = "坡度待同步", height = 18, fontSize = 8.5,
        fontColor = C.secondary, minWidth = 0, maxLines = 1, pointerEvents = "none" }
    local diagnostics = UI.Label { id = "musicDiagnostics", text = "BGM · 待同步", fontSize = 9,
        fontColor = C.secondary, whiteSpace = "normal", maxLines = 2, minWidth = 0, pointerEvents = "none" }
    refs_.headlight, refs_.music, refs_.terrain, refs_.musicDiagnostics = headlight, music, terrain, diagnostics
    local function switchButton(id, dir)
        return UI.Button { id = id, text = "道岔待同步", height = 44, width = 0, flexGrow = 1,
            flexBasis = 0, flexShrink = 1, minWidth = 44, paddingHorizontal = 3, variant = "secondary",
            disabled = true, onClick = function() if canSwitch() then callbacks_.onSwitch(dir) end end }
    end
    local mainline, siding = switchButton("switchMainline", -1), switchButton("switchSiding", 1)
    local hint = UI.Label { id = "switchHint", text = "道岔待同步", height = 30, minHeight = 30,
        width = "100%", minWidth = 0, flexShrink = 0, fontSize = 8, fontColor = C.secondary,
        whiteSpace = "normal", maxLines = 2, lineHeight = 1.0, pointerEvents = "none" }
    local strip = UI.Panel { id = "switchStrip", position = "absolute", width = switchWidth_, height = 82,
        padding = 3, gap = 2, backgroundColor = C.surface, pointerEvents = "box-none", children = {
            hint, UI.Panel { height = 44, flexDirection = "row", gap = 4,
                pointerEvents = "box-none", children = { mainline, siding } } } }
    refs_.switchMainline, refs_.switchSiding, refs_.switchHint = mainline, siding, hint
    refresh(); refreshSwitch()
    return { controls = controls, terrain = terrain, diagnostics = diagnostics, switchStrip = strip,
        switchMainline = mainline, switchSiding = siding, switchHint = hint, music = music }
end
function Drive.GetReadings()
    local copy = {} ---@type table
    for key, value in pairs(snapshot_) do copy[key] = value end
    copy.musicState, copy.musicVolume, copy.musicEnabled = musicState(), volume_, enabled_
    copy.canSwitch, copy.hasNextSwitch = canSwitch(), hasJunction_
    copy.nextSwitch = {}
    for key, value in pairs(nextSwitch_) do copy.nextSwitch[key] = value end
    if junctionKnown_ then copy.nextJunction = hasJunction_ and copy.nextSwitch or false end
    return copy
end
function Drive.ResetRailway()
    nextSwitch_ = {}
    junctionKnown_, hasJunction_, switchReady_, switchLocked_ = false, false, false, true
    legacySwitchText_ = "道岔待同步"
    refreshSwitch()
end
function Drive.Reset()
    snapshot_, nextSwitch_, refs_, callbacks_ = {}, {}, {}, {}
    junctionKnown_, hasJunction_, switchReady_, switchLocked_, paused_ = false, false, false, true, false
    enabled_, volume_, legacySwitchText_ = true, .35, "道岔待同步"
end
return Drive
