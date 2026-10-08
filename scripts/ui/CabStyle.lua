-- 驾驶仪表共用皮肤：借用 ui-brawlforge 的冲压金属、层叠表面和输入反馈，
-- 不照搬竞技配色。尺寸均为 UI 基准像素，由 UI.Scale.DEFAULT 处理 DPR。
local UI = require "urhox-libs/UI"

local CabStyle = {}

CabStyle.Colors = {
    text = { 237, 236, 225, 255 },
    secondary = { 172, 184, 185, 255 },
    muted = { 109, 127, 132, 255 },
    orange = { 232, 160, 86, 255 },
    teal = { 101, 194, 174, 255 },
    red = { 231, 108, 92, 255 },
    edge = { 103, 120, 127, 110 },
    black = { 8, 13, 17, 245 },
    surface = { 22, 32, 38, 222 },
    highlight = { 44, 57, 64, 236 },
}

function CabStyle.CreateTheme()
    -- 将 BrawlForge 的结构默认值调整为真实驾驶台：
    -- 细接缝、低饱和表面、小倒角和橙色/青绿指示灯。
    return UI.Theme.ExtendTheme(UI.Theme.GetRegisteredTheme("default-dark") or UI.Theme.defaultTheme, {
        fonts = {
            { family = "sans", weights = {
                normal = "Fonts/MiSans-Regular.ttf", bold = "Fonts/MiSans-Bold.ttf",
            } },
        },
        colors = {
            text = CabStyle.Colors.text,
            textSecondary = CabStyle.Colors.secondary,
            textDisabled = CabStyle.Colors.muted,
            background = { 12, 19, 24, 0 },
            surface = CabStyle.Colors.surface,
            surfaceHover = CabStyle.Colors.highlight,
            primary = CabStyle.Colors.teal,
            primaryHover = { 126, 216, 193, 255 },
            primaryPressed = { 65, 144, 130, 255 },
            secondary = { 53, 68, 75, 255 },
            secondaryHover = { 66, 83, 90, 255 },
            secondaryPressed = { 26, 38, 45, 255 },
            border = CabStyle.Colors.edge,
            borderFocus = CabStyle.Colors.teal,
            success = CabStyle.Colors.teal,
            warning = CabStyle.Colors.orange,
            error = CabStyle.Colors.red,
            disabled = { 24, 33, 39, 240 },
            disabledText = CabStyle.Colors.muted,
            overlay = { 7, 16, 28, 187 },
        },
        spacing = { xs = 4, sm = 8, md = 12, lg = 16, xl = 24, xxl = 32 },
        radius = { none = 0, sm = 3, md = 6, lg = 8, xl = 10, full = 9999 },
        componentDefaults = { borderRadius = 0 },
        components = {
            Panel = { borderRadius = 0 },
            Label = { fontSize = 10.5, fontColor = CabStyle.Colors.text },
            Button = {
                height = 44, borderRadius = 3, borderWidth = 1,
                borderColor = CabStyle.Colors.edge, fontSize = 10.5,
                fontWeight = "bold", boxShadow = {}, decorations = {},
            },
        },
    })
end

---@param color number[]
---@return NVGcolor
function CabStyle.Color(color)
    return nvgRGBA(color[1], color[2], color[3], color[4] or 255)
end

---@param vg NVGContextWrapper
---@param x number
---@param y number
---@param w number
---@param h number
---@param radius number
---@param color number[]
function CabStyle.Rect(vg, x, y, w, h, radius, color)
    nvgBeginPath(vg)
    nvgRoundedRect(vg, x, y, math.max(0, w), math.max(0, h), radius)
    nvgFillColor(vg, CabStyle.Color(color))
    nvgFill(vg)
end

---@param vg NVGContextWrapper
---@param x1 number
---@param y1 number
---@param x2 number
---@param y2 number
---@param color number[]
---@param width number|nil
function CabStyle.Line(vg, x1, y1, x2, y2, color, width)
    nvgBeginPath(vg)
    nvgMoveTo(vg, x1, y1)
    nvgLineTo(vg, x2, y2)
    nvgStrokeColor(vg, CabStyle.Color(color))
    nvgStrokeWidth(vg, width or 1)
    nvgStroke(vg)
end

---@param vg NVGContextWrapper
---@param x number
---@param y number
---@param radius number
---@param color number[]
function CabStyle.Circle(vg, x, y, radius, color)
    nvgBeginPath(vg)
    nvgCircle(vg, x, y, radius)
    nvgFillColor(vg, CabStyle.Color(color))
    nvgFill(vg)
end

---@param vg NVGContextWrapper
---@param x number
---@param y number
---@param text string
---@param px number UI 基准像素字号，交给主题转换为 pt
---@param color number[]
---@param align number|nil
---@param bold boolean|nil
function CabStyle.Text(vg, x, y, text, px, color, align, bold)
    nvgFontFace(vg, UI.Theme.FontFace("sans", bold and "bold" or "normal"))
    nvgFontSize(vg, UI.Theme.FontSize(px * 0.75))
    nvgTextAlign(vg, align or (NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE))
    nvgFillColor(vg, CabStyle.Color(color))
    nvgText(vg, x, y, text)
end

---@param vg NVGContextWrapper
---@param x number
---@param y number
function CabStyle.Screw(vg, x, y)
    CabStyle.Circle(vg, x, y + 0.5, 2.4, { 4, 9, 13, 220 })
    CabStyle.Circle(vg, x, y, 1.7, { 90, 103, 109, 155 })
    CabStyle.Line(vg, x - 1.0, y + 0.5, x + 1.0, y - 0.5, { 12, 22, 27, 225 }, 0.7)
end

--- 拉丝倒角、克制高光和细接缝，不使用不透明全屏填充。
---@param vg NVGContextWrapper
---@param l table UI.Widget:GetAbsoluteLayout() 返回的布局表
---@param pressed boolean|nil
---@param hovered boolean|nil
function CabStyle.Metal(vg, l, pressed, hovered)
    local c = CabStyle.Colors
    CabStyle.Rect(vg, l.x + 1, l.y + 3, l.w, l.h, 6, { 0, 0, 0, 65 })
    nvgBeginPath(vg)
    nvgRoundedRect(vg, l.x, l.y, l.w, l.h, 5)
    local top = pressed and { 16, 26, 32, 238 } or (hovered and c.highlight or { 35, 46, 53, 218 })
    nvgFillPaint(vg, nvgLinearGradient(vg, l.x, l.y, l.x, l.y + l.h,
        CabStyle.Color(top), CabStyle.Color({ 12, 21, 27, 225 })))
    nvgFill(vg)
    nvgStrokeColor(vg, CabStyle.Color(hovered and { 108, 179, 164, 160 } or c.edge))
    nvgStrokeWidth(vg, 1)
    nvgStroke(vg)
    CabStyle.Line(vg, l.x + 6, l.y + 1.5, l.x + l.w - 6, l.y + 1.5, { 184, 199, 202, 45 })
    CabStyle.Line(vg, l.x + 5, l.y + l.h - 2, l.x + l.w - 5, l.y + l.h - 2, { 0, 0, 0, 130 })
end

return CabStyle
