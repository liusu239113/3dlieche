-- 驾驶仪表控件在 UI 框架已有 NanoVG 帧内绘制。
-- 不另建上下文、字体或渲染事件，所有坐标使用 UI 基准像素。
local UI = require "urhox-libs/UI"
local Skin = require "ui.CabStyle"
local C = Skin.Colors
local Cab = {}

---@class CabPanel : Panel
---@overload fun(props?: PanelProps): CabPanel
local MetalPanel = UI.Panel:Extend("CabPanel")
function MetalPanel:Render(vg)
    local l = self:GetAbsoluteLayout()
    Skin.Metal(vg, { x = l.x, y = l.y, w = l.w, h = l.h })
end
Cab.Panel = MetalPanel

---@class CabSpeedometerProps : WidgetProps
---@field maxSpeed? number
---@field limit? number

---@class CabSpeedometer : Widget
---@overload fun(props?: CabSpeedometerProps): CabSpeedometer
---@field props CabSpeedometerProps
---@field speed_ number
---@field needle_ number
---@field limit_ number
---@field maxSpeed_ number
local Speedometer = UI.Widget:Extend("CabSpeedometer")

---@param props CabSpeedometerProps?
function Speedometer:Init(props)
    props = props or {}
    props.width = props.width or 184
    props.height = props.height or 184
    props.pointerEvents = "none"
    UI.Widget.Init(self, props)
    self.speed_ = 0
    self.needle_ = 0
    self.limit_ = props.limit or 80
    self.maxSpeed_ = math.max(40, props.maxSpeed or 120)
end

---@param maximum number
function Speedometer:SetRange(maximum)
    self.maxSpeed_ = math.max(40, math.ceil(maximum / 20) * 20)
end

---@param speed number
---@param limit number|nil
function Speedometer:SetReading(speed, limit)
    self.speed_ = math.abs(speed)
    if limit then self.limit_ = limit end
end

---@param dt number
function Speedometer:Update(dt)
    self.needle_ = self.needle_ + (self.speed_ - self.needle_) * (1 - math.exp(-12 * dt))
end

---@param vg NVGContextWrapper
function Speedometer:Render(vg)
    local l = self:GetAbsoluteLayout()
    local cx, cy = l.x + l.w * 0.5, l.y + l.h * 0.46
    local r = math.min(l.w, l.h) * 0.44
    if r <= 1 then return end
    local over = self.speed_ > self.limit_ + 0.5
    local start = math.rad(135)
    local sweep = math.rad(270)
    nvgSave(vg)
    -- 车削钢质外圈与内凹炭灰表盘，不添加巨大矩形底板。
    Skin.Circle(vg, cx, cy + 3, r + 3, { 0, 0, 0, 90 })
    nvgBeginPath(vg)
    nvgCircle(vg, cx, cy, r + 2)
    nvgFillPaint(vg, nvgLinearGradient(vg, cx, cy - r, cx, cy + r,
        Skin.Color({ 124, 137, 140, 225 }), Skin.Color({ 23, 34, 41, 240 })))
    nvgFill(vg)
    Skin.Circle(vg, cx, cy, r - 2, { 8, 16, 21, 242 })
    nvgBeginPath(vg)
    nvgCircle(vg, cx, cy, r - 5)
    nvgFillPaint(vg, nvgRadialGradient(vg, cx - r * 0.3, cy - r * 0.5, 1, r * 1.6,
        Skin.Color({ 33, 46, 52, 243 }), Skin.Color({ 10, 19, 25, 245 })))
    nvgFill(vg)
    nvgStrokeColor(vg, Skin.Color({ 123, 147, 153, 70 }))
    nvgStrokeWidth(vg, 0.8)
    nvgStroke(vg)

    -- 量程随车型切换；高速表减少密集数字，橙色游标单独显示当前线路限制。
    nvgBeginPath(vg)
    nvgArc(vg, cx, cy, r * 0.90, start, start + sweep, NVG_CW)
    nvgStrokeColor(vg, Skin.Color({ 141, 165, 169, 70 }))
    nvgStrokeWidth(vg, 1)
    nvgStroke(vg)
    local majorStep = self.maxSpeed_ > 200 and 50 or 20
    local minorStep = self.maxSpeed_ > 200 and 10 or 5
    for value = 0, math.floor(self.maxSpeed_), minorStep do
        local a = start + sweep * value / self.maxSpeed_
        local major = value % majorStep == 0
        local outer = r * 0.86
        local inner = r * (major and 0.73 or 0.80)
        local cosA, sinA = math.cos(a), math.sin(a)
        local color = value > self.limit_ and { 201, 132, 86, 165 } or { 199, 211, 205, 225 }
        Skin.Line(vg, cx + cosA * inner, cy + sinA * inner,
            cx + cosA * outer, cy + sinA * outer, color, major and 1.5 or 0.7)
        if major then
            Skin.Text(vg, cx + cosA * r * 0.62, cy + sinA * r * 0.62,
                tostring(value), r * 0.13, C.secondary)
        end
    end
    local limitAngle = start + sweep * math.min(1, self.limit_ / self.maxSpeed_)
    Skin.Line(vg, cx + math.cos(limitAngle) * r * 0.91, cy + math.sin(limitAngle) * r * 0.91,
        cx + math.cos(limitAngle) * r * 0.98, cy + math.sin(limitAngle) * r * 0.98, C.orange, 3)
    Skin.Text(vg, cx, cy - r * 0.30, "速度", r * 0.11, C.muted)

    -- 阻尼指针、橙色针尖和小型中心轴承。
    local a = start + sweep * math.min(1, self.needle_ / self.maxSpeed_)
    local dx, dy = math.cos(a), math.sin(a)
    nvgBeginPath(vg)
    nvgMoveTo(vg, cx - dx * r * 0.13 - dy * 2, cy - dy * r * 0.13 + dx * 2)
    nvgLineTo(vg, cx + dx * r * 0.75, cy + dy * r * 0.75)
    nvgLineTo(vg, cx - dx * r * 0.13 + dy * 2, cy - dy * r * 0.13 - dx * 2)
    nvgClosePath(vg)
    nvgFillColor(vg, Skin.Color(over and C.red or C.orange))
    nvgFill(vg)
    Skin.Circle(vg, cx, cy, r * 0.075, { 109, 126, 130, 255 })
    Skin.Circle(vg, cx, cy, r * 0.05, { 27, 39, 46, 255 })
    Skin.Text(vg, cx, cy + r * 0.43, tostring(math.floor(self.speed_ + 0.5)),
        r * 0.35, over and C.red or C.text, nil, true)
    Skin.Text(vg, cx, cy + r * 0.68, "km/h", r * 0.11, C.muted)

    -- 下方弧形留白区放置清晰数字限速，永不显示空值。
    local bw, bh = r * 0.91, r * 0.26
    local bx, by = cx - bw * 0.5, cy + r * 0.79
    Skin.Rect(vg, bx, by, bw, bh, 3, { 14, 24, 30, 244 })
    nvgBeginPath(vg)
    nvgRoundedRect(vg, bx, by, bw, bh, 3)
    nvgStrokeColor(vg, Skin.Color(over and C.red or { 192, 142, 91, 145 }))
    nvgStrokeWidth(vg, 1)
    nvgStroke(vg)
    Skin.Text(vg, cx, by + bh * 0.5, "限速 " .. math.floor(self.limit_ + 0.5), r * 0.15,
        over and C.red or C.orange, nil, true)
    for _, offset in ipairs({ -1, 1 }) do
        Skin.Screw(vg, cx + offset * r * 0.92, cy)
    end
    nvgRestore(vg)
end
Cab.Speedometer = Speedometer

---@class CabKeyProps : WidgetProps
---@field text? string
---@field icon? string
---@field hint? string
---@field active? boolean

---@class CabKey : Widget
---@overload fun(props?: CabKeyProps): CabKey
---@field props CabKeyProps
---@field hovered_ boolean
---@field pressed_ boolean
local Key = UI.Widget:Extend("CabKey")

---@param props CabKeyProps?
function Key:Init(props)
    props = props or {}
    props.width = props.width or 48
    props.height = props.height or 44
    UI.Widget.Init(self, props)
    self.hovered_ = false
    self.pressed_ = false
end

---@param active boolean
function Key:SetActive(active) self.props.active = active end
---@param text string
function Key:SetText(text) self.props.text = text end
---@param event PointerEvent
function Key:OnPointerEnter(event) self.hovered_ = true end
---@param event PointerEvent
function Key:OnPointerLeave(event)
    self.hovered_ = false
    self.pressed_ = false
end
---@param event PointerEvent
function Key:OnPointerDown(event)
    if event:IsPrimaryAction() then self.pressed_ = true end
end
---@param event PointerEvent
function Key:OnPointerUp(event) self.pressed_ = false end
---@param event PointerEvent
function Key:OnPointerCancel(event) self.pressed_ = false end
---@param event PointerEvent?
function Key:OnClick(event)
    if (not event or event:IsPrimaryAction()) and self.props.onClick then
        self.props.onClick(self, event)
    end
end

---@param vg NVGContextWrapper
function Key:Render(vg)
    local l = self:GetAbsoluteLayout()
    nvgSave(vg)
    Skin.Metal(vg, { x = l.x, y = l.y, w = l.w, h = l.h }, self.pressed_, self.hovered_)
    local color = self.props.active and C.teal or C.secondary
    local icon = self.props.icon
    local cx, cy = l.x + l.w * 0.5, l.y + l.h * 0.40
    local ox = cx - 8
    if icon == "horn" then
        nvgBeginPath(vg)
        nvgMoveTo(vg, ox - 2, cy - 3)
        nvgLineTo(vg, ox + 5, cy - 3)
        nvgLineTo(vg, ox + 12, cy - 8)
        nvgLineTo(vg, ox + 12, cy + 8)
        nvgLineTo(vg, ox + 5, cy + 3)
        nvgLineTo(vg, ox - 2, cy + 3)
        nvgClosePath(vg)
        nvgStrokeColor(vg, Skin.Color(color))
        nvgStrokeWidth(vg, 1.5)
        nvgStroke(vg)
        for i = 1, 2 do
            nvgBeginPath(vg)
            nvgArc(vg, ox + 12, cy, 4 + i * 4, -0.7, 0.7, NVG_CW)
            nvgStroke(vg)
        end
    elseif icon == "pause" then
        Skin.Rect(vg, cx - 6, cy - 6, 3, 12, 0, color)
        Skin.Rect(vg, cx + 3, cy - 6, 3, 12, 0, color)
    elseif icon == "camera" then
        Skin.Rect(vg, cx - 10, cy - 6, 20, 13, 2, color)
        Skin.Rect(vg, cx - 6, cy - 9, 7, 4, 1, color)
        Skin.Circle(vg, cx, cy, 4.5, C.black)
        Skin.Circle(vg, cx, cy, 2.2, C.muted)
    elseif icon == "map" then
        for i = 0, 2 do
            local x = cx - 9 + i * 6
            Skin.Line(vg, x, cy - 7 + i % 2 * 2, x, cy + 7 + i % 2 * 2, color, 1.1)
        end
        Skin.Line(vg, cx - 9, cy - 7, cx - 3, cy - 5, color)
        Skin.Line(vg, cx - 3, cy - 5, cx + 3, cy - 7, color)
        Skin.Line(vg, cx - 9, cy + 7, cx - 3, cy + 9, color)
        Skin.Line(vg, cx - 3, cy + 9, cx + 3, cy + 7, color)
    elseif icon == "up" or icon == "down" then
        local dir = icon == "up" and -1 or 1
        Skin.Line(vg, cx - 5, cy - dir * 2, cx, cy + dir * 3, color, 1.6)
        Skin.Line(vg, cx, cy + dir * 3, cx + 5, cy - dir * 2, color, 1.6)
    else
        Skin.Text(vg, cx, cy, self.props.text or "", 13, color, nil, true)
    end
    if icon and self.props.text then
        Skin.Text(vg, cx, l.y + l.h * 0.77, self.props.text, 10, C.secondary)
    elseif self.props.hint then
        Skin.Text(vg, cx, l.y + l.h * 0.80, self.props.hint, 9, C.muted)
    end
    if self.props.active then
        Skin.Rect(vg, l.x + 7, l.y + l.h - 2.5, l.w - 14, 1.5, 0, C.teal)
    end
    nvgRestore(vg)
end
Cab.Key = Key

---@class CabLeverProps : WidgetProps
---@field kind? string "throttle" 油门 | "brake" 制动
---@field onSelect? fun(notch: integer)
---@field onHold? fun(held: boolean)
---@field onRepeat? fun()

---@class CabLever : Widget
---@overload fun(props?: CabLeverProps): CabLever
---@field props CabLeverProps
---@field notch_ integer
---@field maxNotch_ integer
---@field ratio_ number
---@field kind_ string
---@field pointer_ number|nil
---@field hovered_ boolean
---@field repeatTimer_ number
---@field keyboardHeld_ boolean
local Lever = UI.Widget:Extend("CabLever")

---@param props CabLeverProps?
function Lever:Init(props)
    props = props or {}
    props.width = props.width or 68
    props.height = props.height or 150
    UI.Widget.Init(self, props)
    self.kind_ = props.kind or "throttle"
    self.notch_ = 0
    self.maxNotch_ = 8
    self.ratio_ = 0
    self.pointer_ = nil
    self.hovered_ = false
    self.repeatTimer_ = 0
    self.keyboardHeld_ = false
end

---@param notch integer
---@param maxNotch integer
function Lever:SetNotch(notch, maxNotch)
    self.maxNotch_ = math.max(1, maxNotch)
    self.notch_ = math.max(0, math.min(self.maxNotch_, notch))
end
---@param ratio number
function Lever:SetRatio(ratio) self.ratio_ = math.max(0, math.min(1, ratio)) end

---@param y number
function Lever:SelectAt(y)
    local l = self:GetAbsoluteLayout()
    local top, bottom = l.y + 34, l.y + l.h - 31
    local ratio = math.max(0, math.min(1, (bottom - y) / math.max(1, bottom - top)))
    local notch = math.floor(ratio * self.maxNotch_ + 0.5)
    if self.props.onSelect then self.props.onSelect(notch) end
end

---@param event PointerEvent
function Lever:OnPointerDown(event)
    if self.pointer_ ~= nil or not event:IsPrimaryAction() then return end
    self.pointer_ = event.pointerId
    if self.kind_ == "brake" then
        self.repeatTimer_ = 0.16
        if self.props.onHold then self.props.onHold(true) end
    else
        self:SelectAt(event.y)
    end
end
---@param event PointerEvent
function Lever:OnPointerMove(event)
    if self.pointer_ == event.pointerId and self.kind_ == "throttle" then
        self:SelectAt(event.y)
    end
end
---@param event PointerEvent
function Lever:OnPointerEnter(event) self.hovered_ = true end
---@param event PointerEvent
function Lever:OnPointerLeave(event)
    self.hovered_ = false
    -- 制动是瞬时手柄：离开即结束按住，不锁定。
    -- 油门继续使用框架的按下控件捕获，以支持拖动。
    if self.kind_ == "brake" and self.pointer_ == event.pointerId then self:ReleaseHold() end
end
---@param event PointerEvent
function Lever:OnPointerUp(event)
    if self.pointer_ == event.pointerId then self:ReleaseHold() end
end
---@param event PointerEvent
function Lever:OnPointerCancel(event)
    if self.pointer_ == event.pointerId then self:ReleaseHold() end
end
---@param event PointerEvent?
function Lever:OnClick(event)
    -- 交互全部在按下/移动/抬起完成，避免再次点击导致双触发。
end

function Lever:ReleaseHold()
    local held = self.pointer_ ~= nil
    self.pointer_ = nil
    self.repeatTimer_ = 0
    if held and self.kind_ == "brake" and self.props.onHold then self.props.onHold(false) end
end

---@param dt number
function Lever:Update(dt)
    if self.kind_ ~= "brake" then return end
    self.keyboardHeld_ = input:GetKeyDown(KEY_SPACE)
    if self.pointer_ ~= nil and not UI.Input.GetPointer(self.pointer_) then
        self:ReleaseHold() -- 失焦/丢失触摸时恢复，同时保护旧回调不持续触发
    end
    if self.pointer_ ~= nil and self.props.onRepeat then
        self.repeatTimer_ = self.repeatTimer_ - dt
        if self.repeatTimer_ <= 0 then
            self.repeatTimer_ = 0.16
            self.props.onRepeat()
        end
    end
end

function Lever:Destroy()
    self:ReleaseHold()
    UI.Widget.Destroy(self)
end

---@param vg NVGContextWrapper
function Lever:Render(vg)
    local l = self:GetAbsoluteLayout()
    if l.h < 65 then return end
    local brake = self.kind_ == "brake"
    local held = self.pointer_ ~= nil or self.keyboardHeld_
    local accent = brake and C.orange or C.teal
    local ratio = brake and self.ratio_ or self.notch_ / self.maxNotch_
    local cx = l.x + l.w * 0.59
    local top, bottom = l.y + 34, l.y + l.h - 31
    local hy = bottom - ratio * (bottom - top)
    nvgSave(vg)
    Skin.Rect(vg, l.x + 2, l.y + 25, l.w - 4, l.h - 48, 3, { 9, 17, 22, 218 })
    Skin.Text(vg, l.x + l.w * 0.5, l.y + 12, brake and "制动" or "牵引", 11, C.secondary, nil, true)
    Skin.Rect(vg, cx - 4, top - 6, 8, bottom - top + 12, 3, { 0, 5, 9, 250 })
    Skin.Line(vg, cx + 5, top - 5, cx + 5, bottom + 5, { 119, 142, 149, 55 }, 1)
    local ticks = brake and 4 or self.maxNotch_
    for i = 0, ticks do
        local y = bottom - (bottom - top) * i / ticks
        Skin.Line(vg, cx - 13, y, cx - 7, y, i / ticks <= ratio and accent or C.muted, 0.8)
        Skin.Text(vg, l.x + 12, y, brake and tostring(i * 25) or tostring(i), 8.5, C.muted)
    end
    if ratio > 0 then Skin.Rect(vg, cx - 1, hy, 2, bottom - hy, 0, accent) end
    -- 小金属杆与扁平握柄，不使用默认圆形滑块。
    Skin.Rect(vg, cx - 16, hy - 6 + 2, 32, 14, 2, { 0, 0, 0, 180 })
    nvgBeginPath(vg)
    nvgRoundedRect(vg, cx - 16, hy - 6, 32, 14, 2)
    nvgFillPaint(vg, nvgLinearGradient(vg, cx, hy - 6, cx, hy + 8,
        Skin.Color((held or self.hovered_) and { 119, 143, 146, 255 } or { 80, 97, 106, 255 }),
        Skin.Color({ 29, 42, 49, 255 })))
    nvgFill(vg)
    Skin.Line(vg, cx - 13, hy - 4.5, cx + 13, hy - 4.5, accent, 2)
    for offset = -1, 3, 2 do
        Skin.Line(vg, cx - 10, hy + offset, cx + 10, hy + offset, { 9, 18, 24, 150 }, 1)
    end
    local value = brake and string.format("%d%%", math.floor(ratio * 100 + 0.5))
        or string.format("%d / %d", self.notch_, self.maxNotch_)
    Skin.Text(vg, l.x + l.w * 0.5, l.y + l.h - 12, value, 13, accent, nil, true)
    nvgRestore(vg)
end
Cab.Lever = Lever

---@class CabMapPoint
---@field x number
---@field z number

---@class CabMapStation : CabMapPoint
---@field active? boolean

---@class CabMinimap : Widget
---@overload fun(props?: WidgetProps): CabMinimap
---@field points_ CabMapPoint[]
---@field stations_ CabMapStation[]
---@field bounds_ {minX:number,maxX:number,minZ:number,maxZ:number}
---@field trainX_ number
---@field trainZ_ number
local Minimap = UI.Widget:Extend("CabMinimap")

---@param props WidgetProps?
function Minimap:Init(props)
    props = props or {}
    props.width = props.width or 176
    props.height = props.height or 104
    props.pointerEvents = "none"
    UI.Widget.Init(self, props)
    self.points_ = {}
    self.stations_ = {}
    self.bounds_ = { minX = 0, maxX = 1, minZ = 0, maxZ = 1 }
    self.trainX_ = 0
    self.trainZ_ = 0
end

---@param points CabMapPoint[]
---@param stations CabMapStation[]
function Minimap:SetRoute(points, stations)
    self.points_ = points
    self.stations_ = stations
    local b = { minX = math.huge, maxX = -math.huge, minZ = math.huge, maxZ = -math.huge }
    for _, p in ipairs(points) do
        b.minX, b.maxX = math.min(b.minX, p.x), math.max(b.maxX, p.x)
        b.minZ, b.maxZ = math.min(b.minZ, p.z), math.max(b.maxZ, p.z)
    end
    if #points > 0 then self.bounds_ = b end
end

---@param x number
---@param z number
---@param activeIndex integer?
function Minimap:SetTrain(x, z, activeIndex)
    self.trainX_, self.trainZ_ = x, z
    for i, st in ipairs(self.stations_) do st.active = i == activeIndex end
end

---@param vg NVGContextWrapper
function Minimap:Render(vg)
    local l = self:GetAbsoluteLayout()
    nvgSave(vg)
    Skin.Metal(vg, { x = l.x, y = l.y, w = l.w, h = l.h })
    Skin.Text(vg, l.x + 10, l.y + 13, "线路示意", 10, C.secondary, NVG_ALIGN_LEFT + NVG_ALIGN_MIDDLE)
    if #self.points_ > 0 then
        nvgIntersectScissor(vg, l.x + 7, l.y + 25, l.w - 14, l.h - 31)
        local b = self.bounds_
        local sx, sz = math.max(1, b.maxX - b.minX), math.max(1, b.maxZ - b.minZ)
        local scale = math.min((l.w - 28) / sx, (l.h - 42) / sz)
        local ox = l.x + l.w * 0.5 - (b.minX + sx * 0.5) * scale
        local oy = l.y + (l.h + 21) * 0.5 - (b.minZ + sz * 0.5) * scale
        nvgBeginPath(vg)
        for i, p in ipairs(self.points_) do
            if i == 1 then nvgMoveTo(vg, ox + p.x * scale, oy + p.z * scale)
            else nvgLineTo(vg, ox + p.x * scale, oy + p.z * scale) end
        end
        -- 不合成闭合线段，线路采样已表达实际拓扑。
        nvgStrokeColor(vg, Skin.Color({ 101, 155, 152, 220 }))
        nvgStrokeWidth(vg, 1.6)
        nvgStroke(vg)
        for _, st in ipairs(self.stations_) do
            Skin.Circle(vg, ox + st.x * scale, oy + st.z * scale, st.active and 3.7 or 2.2,
                st.active and C.orange or C.secondary)
        end
        Skin.Circle(vg, ox + self.trainX_ * scale, oy + self.trainZ_ * scale, 4, C.black)
        Skin.Circle(vg, ox + self.trainX_ * scale, oy + self.trainZ_ * scale, 2.6, C.teal)
    end
    nvgRestore(vg)
end
Cab.Minimap = Minimap

return Cab
