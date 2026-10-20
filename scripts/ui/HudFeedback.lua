-- HUD 只读反馈投影。环境/停站等待/下载进度均由 main 注入，不在这里推进世界或累计站停。
local UI = require "urhox-libs/UI"
local Skin = require "ui.CabStyle"
local C = Skin.Colors
local Feedback = {}
local data_ = { environment = "", departure = "", reason = "", waitSeconds = 0,
    blocked = false, loading = false, ratio = 0, loadingText = "", version = "", caption = "", captionKey = "", captionTime = 0 }
---@type Label?
local environment_ = nil
---@type Label?
local departure_ = nil
---@type Label?
local version_ = nil
---@type Label?
local caption_ = nil
---@type Panel?
local loading_ = nil
---@type ProgressBar?
local progress_ = nil
---@type Label?
local loadingText_ = nil
---@type Button?
local cancel_ = nil
---@type fun()|nil
local onCancel_ = nil
local captionWidth_ = 320

-- Label 的 maxLines 不保证裁掉完整行；先按真实字宽显式折成两行，超长以省略号摘要。
-- 保留 data_.caption 完整原文用于诊断，展示文本只在事件/布局宽度改变时计算。
local function FormatCaption()
    if not caption_ then return end
    local lines, line = {}, ""
    local size, face = UI.Theme.FontSize(9), UI.Theme.FontFace("sans", "normal")
    -- width 为外层卡宽，扣除16px内边距及额外24px字形overhang/换行余量。
    local width = math.max(32,captionWidth_-40)
    local source = data_.caption:gsub("[\r\n]+"," ")
    for _,code in utf8.codes(source) do
        local char = utf8.char(code)
        if UI.MeasureTextWidth(line..char.."…",size,face) > width and line ~= "" then
            if #lines == 1 then
                lines[2] = line .. "…"
                local display = table.concat(lines,"\n")
                if caption_:GetText() ~= display then caption_:SetText(display) end
                return
            end
            lines[1],line = line,char
        else line = line .. char end
    end
    lines[#lines+1] = line
    local display = table.concat(lines,"\n")
    if caption_:GetText() ~= display then caption_:SetText(display) end
end

local WEATHER = { clear = "晴天", cloudy = "阴天", rain = "雨天", fog = "雾天" }
local REASON = { passengers = "等待乘降完成", boarding = "等待乘降完成", doors = "等待车门关闭",
    signal = "等待前方信号", red_signal = "等待前方信号", occupied = "等待前方列车",
    platform = "等待站台放行", dwell = "等待站停完成", paused = "旅程已暂停" }

---@param value any
---@param fallback number
---@return number
local function number(value, fallback)
    local n = tonumber(value)
    return n and n == n and n ~= math.huge and n ~= -math.huge and n or fallback
end
---@param widget Label?
---@param value string
local function text(widget, value)
    if widget and widget:GetText() ~= value then widget:SetText(value) end
end

function Feedback.Create()
    environment_ = UI.Label { id = "worldEnvironment", text = data_.environment,
        height = 18, minHeight = 18, flexShrink = 0, fontSize = 9, fontColor = C.secondary,
        visible = data_.environment ~= "", maxLines = 1, minWidth = 0, pointerEvents = "none" }
    departure_ = UI.Label { id = "departureStatus", text = data_.departure, height = 32,
        minHeight = 32, flexShrink = 0, fontSize = 9, fontColor = C.orange,
        visible = data_.blocked, whiteSpace = "normal", maxLines = 2, lineHeight = 1.05,
        minWidth = 0, pointerEvents = "none" }
    caption_ = UI.Label { id = "announcementCaption", text = "", fontSize = 9,
        fontColor = C.teal, height = 46, minHeight = 46, flexShrink = 0,
        visible = data_.captionTime > 0, whiteSpace = "normal", maxLines = 2,
        lineHeight = 1.25, verticalAlign = "top", paddingVertical = 3,
        minWidth = 0, pointerEvents = "none" }
    FormatCaption()
    version_ = UI.Label { id = "featureVersion", text = data_.version, fontSize = 8,
        fontColor = C.muted, height = 16, visible = data_.version ~= "", maxLines = 1,
        minWidth = 0, pointerEvents = "none" }
    loadingText_ = UI.Label { id = "trainLoadingText", text = data_.loadingText,
        fontSize = 9, fontColor = C.text, maxLines = 2, whiteSpace = "normal",
        minWidth = 0, flexGrow = 1, flexShrink = 1 }
    cancel_ = UI.Button { id = "cancelTrainLoading", text = "取消", width = 52, height = 48,
        minWidth = 48, minHeight = 48, paddingHorizontal = 3, variant = "secondary",
        visible = onCancel_ ~= nil, onClick = function()
            local action = onCancel_
            if action and data_.loading then action() end
        end }
    progress_ = UI.ProgressBar { id = "trainLoadingProgress", value = data_.ratio, max = 1,
        height = 6, width = "100%", showLabel = false, backgroundColor = C.black, fillColor = C.teal }
    loading_ = UI.Panel { id = "trainLoading", position = "absolute", height = 70,
        paddingHorizontal = 8, paddingVertical = 5, gap = 4, visible = data_.loading,
        borderRadius = 3, borderWidth = 1, borderColor = C.edge,
        backgroundColor = { 12, 21, 27, 225 }, pointerEvents = "box-none", children = {
            UI.Panel { height = 48, minHeight = 48, flexDirection = "row", alignItems = "center", gap = 6,
                pointerEvents = "box-none", children = { loadingText_, cancel_ } }, progress_,
        } }
    return { environment = environment_, departure = departure_, caption = caption_, version = version_, loading = loading_ }
end

---@param status table?
function Feedback.SetEnvironment(status)
    if not status then return end
    local total = math.floor((number(status.hour, 12) % 24) * 60) % 1440
    if status.minute ~= nil then total = (total // 60) * 60 + math.floor(number(status.minute, 0)) % 60 end
    local clock = status.clockText or string.format("%02d:%02d", total // 60, total % 60)
    local weather = WEATHER[status.weather] or status.label or "天气待同步"
    data_.environment = "世界 " .. clock .. " · " .. weather .. (status.running == false and " · 时间暂停" or "")
    text(environment_, data_.environment)
    if environment_ then environment_:Show() end
end

---@param status table?
function Feedback.SetDepartureStatus(status)
    local current = status or {}
    data_.blocked, data_.reason = current.blocked == true, tostring(current.reason or "")
    data_.waitSeconds = math.max(0, number(current.waitSeconds, 0))
    local message = current.message
    if type(message) ~= "string" or message == "" then message = REASON[data_.reason] or "等待发车条件满足" end
    local seconds = math.floor(data_.waitSeconds)
    data_.departure = data_.blocked and (message .. " · 本站已等待 "
        .. string.format("%02d:%02d", seconds // 60, seconds % 60)) or ""
    text(departure_, data_.departure)
    if departure_ then departure_:SetVisible(data_.blocked) end
end

---@param active boolean
---@param ratio number?
---@param message string?
---@param onCancel fun()|nil
function Feedback.SetTrainLoading(active, ratio, message, onCancel)
    data_.loading = active == true
    data_.ratio = math.max(0, math.min(1, number(ratio, 0)))
    data_.loadingText = (message or "正在准备列车") .. string.format(" · %d%%", math.floor(data_.ratio * 100 + .5))
    onCancel_ = data_.loading and onCancel or nil
    text(loadingText_, data_.loadingText)
    if loading_ then loading_:SetVisible(data_.loading) end
    if cancel_ then cancel_:SetVisible(onCancel_ ~= nil) end
    if progress_ and progress_:GetValue() ~= data_.ratio then progress_:SetValue(data_.ratio) end
end

---@param value string?
function Feedback.SetVersion(value)
    data_.version = value or ""
    text(version_, data_.version)
    if version_ then version_:SetVisible(data_.version ~= "") end
end

--- voiced 只做兼容参数，不宣称已经配音；字幕由实际运营事件触发。
---@param value string?
---@param voiced boolean?
---@param eventKey string?
function Feedback.SetAnnouncement(value,voiced,eventKey)
    local message = value or ""
    local key = tostring(eventKey or "")
    if message == data_.caption and key == data_.captionKey then return end
    data_.caption, data_.captionKey = message, key
    data_.captionTime = message ~= "" and 8 or 0
    FormatCaption()
    if caption_ then caption_:SetVisible(data_.captionTime > 0) end
end
---@param dt number
function Feedback.Update(dt)
    if data_.captionTime <= 0 then return false end
    data_.captionTime = math.max(0,data_.captionTime-dt)
    if data_.captionTime == 0 then
        if caption_ then caption_:Hide() end
        return true
    end
    return false
end

function Feedback.GetHeight()
    return (data_.environment ~= "" and 20 or 0) + (data_.blocked and 34 or 0)
        + (data_.captionTime > 0 and 48 or 0)
end
function Feedback.IsLoading() return data_.loading end

---@param left number
---@param top number
---@param width number
function Feedback.Layout(left, top, width)
    if captionWidth_ ~= width then captionWidth_ = width; FormatCaption() end
    if loading_ then loading_:SetStyle({ left = left, top = top, width = width }) end
end

function Feedback.GetReadings()
    return { environmentText = data_.environment, departureText = data_.departure,
        departureBlocked = data_.blocked, departureReason = data_.reason,
        departureWaitSeconds = data_.waitSeconds, trainLoading = data_.loading,
        trainLoadingRatio = data_.ratio, trainLoadingText = data_.loadingText, version = data_.version,
        announcementText = data_.caption, announcementVisible = data_.captionTime > 0, announcementKey = data_.captionKey }
end
function Feedback.Reset()
    data_ = { environment = "", departure = "", reason = "", waitSeconds = 0,
        blocked = false, loading = false, ratio = 0, loadingText = "", version = "", caption = "", captionKey = "", captionTime = 0 }
    environment_, departure_, version_, loading_, progress_, loadingText_, cancel_, onCancel_, caption_ = nil,nil,nil,nil,nil,nil,nil,nil,nil
end
return Feedback
