-- HUD 信息与运营面板：折叠后只占小条，细节保留真实控件且可滚动。
-- 不使用 Cab.Panel（其 Render 强制 Metal），RGBA 背景不影响文字/按钮透明度。
local UI = require "urhox-libs/UI"
local Skin = require "ui.CabStyle"
local Passenger = require "ui.HudPassenger"
local C = Skin.Colors
local Panels = {}
-- 44px标题行 + 2px间距 + 上下各1px显式padding；borderWidth仅绘制，不占Yoga布局。
Panels.OperationsCollapsedHeight = 48

---@class CabHudRouteParts
---@field panel Panel
---@field stationRow Panel
---@field header Panel
---@field toggle Button
---@field details ScrollView
---@field passenger CabPassengerStrip

---@param stationRow Panel
---@param statusRow Panel
---@param detailRows Widget[]
---@param onToggle fun()
---@return CabHudRouteParts
function Panels.Route(stationRow, statusRow, detailRows, onToggle)
    local toggle = UI.Button { id = "toggleRouteInfo", text = "详情", width = 52, height = 44,
        paddingHorizontal = 3, variant = "secondary", onClick = onToggle }
    local header = UI.Panel { height = 44, flexDirection = "row", alignItems = "center", gap = 6,
        pointerEvents = "box-none", children = { stationRow, toggle } }
    local details = UI.ScrollView { id = "routeDetails", height = 76, width = "100%", visible = false,
        scrollY = true, scrollX = false, bounces = false, showScrollbar = true,
        backgroundColor = { 0, 0, 0, 0 }, children = detailRows }
    local passenger = Passenger.Strip { id = "passengerStatus", visible = false }
    local panel = UI.Panel { id = "routeInfo", position = "absolute", width = 340, height = 76,
        paddingHorizontal = 8, paddingVertical = 5, gap = 2,
        backgroundColor = { 12, 21, 27, 142 }, borderColor = { 103, 120, 127, 90 },
        borderWidth = 1, borderRadius = 5, opacity = 1,
        overflow = "hidden", pointerEvents = "box-none",
        children = { header, statusRow, passenger, details } }
    return { panel = panel, stationRow = stationRow, header = header, toggle = toggle,
        details = details, passenger = passenger }
end

---@class CabHudOperationParts
---@field panel Panel
---@field body ScrollView
---@field toggle Button

---@param rows Widget[]
---@param onToggle fun()
---@return CabHudOperationParts
function Panels.Operations(rows, onToggle)
    local toggle = UI.Button { id = "toggleOperations", text = "展开", width = 64, height = 44,
        minHeight = 44, flexShrink = 0,
        variant = "secondary", paddingHorizontal = 3, onClick = onToggle }
    -- 四个44px操作行+三处4px间距+上下4px内边距=196px。
    -- 显式自然高度/no-shrink，避免受窄滚动视口的Yoga内容约束压缩。
    local contentHeight = math.max(0, #rows - 1) * 4 + 8
    for _, row in ipairs(rows) do
        local height=math.max(44,tonumber(row.props.minHeight) or 44)
        row:SetStyle({height=height,minHeight=height,flexShrink=0})
        contentHeight=contentHeight+height
    end
    local body = UI.ScrollView { id = "operationsDetails", width = "100%", height = 196, visible = false,
        minHeight = 52, flexShrink = 0,
        scrollX = false, scrollY = true, bounces = false, showScrollbar = true,
        backgroundColor = { 0, 0, 0, 0 }, children = {
            UI.Panel { id = "operationsContent", width = "100%", height = contentHeight,
                minHeight = contentHeight, flexShrink = 0, padding = 4, gap = 4,
                pointerEvents = "box-none", children = rows },
        } }
    local panel = UI.Panel { id = "railwayControls", position = "absolute", width = 250,
        height = Panels.OperationsCollapsedHeight,
        padding = 1, -- 显式为绘制边框留空间，不能假定borderWidth会内缩Yoga内容。
        gap = 2, backgroundColor = { 12, 21, 27, 148 }, borderColor = C.edge,
        borderWidth = 1, borderRadius = 5, overflow = "hidden", pointerEvents = "box-none",
        children = {
            UI.Panel { height = 44, minHeight = 44, flexShrink = 0,
                flexDirection = "row", alignItems = "center", paddingLeft = 8,
                pointerEvents = "box-none", children = {
                    UI.Label { text = "运营控制", fontSize = 10, fontWeight = "bold", fontColor = C.text,
                        minWidth = 0, flexGrow = 1, flexShrink = 1, maxLines = 1 }, toggle,
                } }, body,
        } }
    return { panel = panel, body = body, toggle = toggle }
end

return Panels
