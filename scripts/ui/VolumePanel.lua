-- 驾驶界面音量弹窗：汽笛键右侧的常驻入口，点开后可调总音量/列车/广播/音乐。
-- 与 CameraSelector 相同的低饱和金属面板；滑杆回调转发给 main，面板本身不改设置。
local UI = require "urhox-libs/UI"
local Skin = require "ui.CabStyle"
local C = Skin.Colors

-- 仅本弹窗使用方向仲裁：内置 Slider 会在按下时改值，并认领所有方向的 pan。
-- 触摸先等手势方向：纵拖交给父 ScrollView，横拖/轻点才调整音量；鼠标保持原行为。
---@class CabVolumeSlider : Slider
---@overload fun(props?: SliderProps): CabVolumeSlider
---@field touchPointer_ number?
---@field pendingTouch_ boolean
local VolumeSlider = UI.Slider:Extend("CabVolumeSlider")

function VolumeSlider:Init(props)
    UI.Slider.Init(self, props)
    self.pendingTouch_ = false
end

function VolumeSlider:OnPointerDown(event)
    if event.pointerType ~= "touch" then return UI.Slider.OnPointerDown(self, event) end
    if self.props.disabled or self.touchPointer_ then return end
    UI.Widget.OnPointerDown(self, event)
    self.touchPointer_, self.pendingTouch_ = event.pointerId, true
end

---@param event GestureEvent
---@return boolean
function VolumeSlider:OnPanStart(event)
    if event.pointerType ~= "touch" then return false end
    if self.props.disabled or self.touchPointer_ ~= event.pointerId then return false end
    if math.abs(event.totalDeltaY) >= math.abs(event.totalDeltaX) then
        self.pendingTouch_ = false
        self:SetState({ dragging = false })
        return false -- ScrollView 接管，并取消原按压，绝不提交音量。
    end
    self.pendingTouch_ = false
    return UI.Slider.OnPanStart(self, event)
end

function VolumeSlider:OnPointerMove(event)
    if event.pointerType == "touch" and self.touchPointer_ ~= event.pointerId then return end
    UI.Slider.OnPointerMove(self, event)
end

function VolumeSlider:OnPointerUp(event)
    if event.pointerType ~= "touch" then return UI.Slider.OnPointerUp(self, event) end
    if self.touchPointer_ ~= event.pointerId then return end
    if self.pendingTouch_ and not self.props.disabled then
        self:UpdateValueFromPosition(event.x)
        self:SetState({ dragging = true }) -- 轻点也沿用原生 changeEnd 契约。
    end
    self.touchPointer_, self.pendingTouch_ = nil, false
    UI.Slider.OnPointerUp(self, event)
end

function VolumeSlider:OnPanEnd(event)
    UI.Slider.OnPanEnd(self, event)
    self.touchPointer_, self.pendingTouch_ = nil, false
end

function VolumeSlider:OnPointerCancel(event)
    self.touchPointer_, self.pendingTouch_ = nil, false
    self:SetState({ dragging = false })
    UI.Widget.OnPointerCancel(self, event)
end

---@class CabVolumePanelCallbacks
---@field onVolume? fun(value:number) 总音量
---@field onTrainVolume? fun(value:number)
---@field onAnnouncementVolume? fun(value:number)
---@field onMusicVolume? fun(value:number)
---@field onSoundToggle? fun(enabled:boolean)
---@field onOpen? fun(open:boolean)

---@class CabVolumeRowRefs
---@field slider CabVolumeSlider
---@field label Label

---@class CabVolumePanel : Panel
---@overload fun(props?: PanelProps): CabVolumePanel
---@field callbacks_ CabVolumePanelCallbacks
---@field rows_ table<string, CabVolumeRowRefs>
---@field soundButton_ Button
---@field scroll_ ScrollView
---@field pointerHook_ number?
---@field open_ boolean
local Panel = UI.Panel:Extend("CabVolumePanel")

-- 滑杆在拖动时也会触发 onChange；同步外部状态时用它屏蔽回写，避免抖动。
local syncing_ = false

---@param props PanelProps?
function Panel:Init(props)
    props = props or {}
    props.id = props.id or "volumePanel"
    self.id = props.id
    props.position = "absolute"
    props.width, props.height = 316, 300
    props.visible, props.zIndex = false, 910
    props.padding, props.gap = 8, 6
    props.backgroundColor, props.borderColor = C.black, C.edge
    props.borderWidth, props.borderRadius = 1, 6
    props.overflow = "hidden"
    props.onClick = function() end
    UI.Panel.Init(self, props)
    self.callbacks_, self.rows_ = {}, {}
    self.open_ = false

    self:AddChild(UI.Panel { height = 44, flexShrink = 0, flexDirection = "row", alignItems = "center", gap = 6,
        pointerEvents = "box-none", children = {
            UI.Label { text = "声音 · 上下滑动", fontSize = 12, fontWeight = "bold", fontColor = C.text,
                flexGrow = 1, flexShrink = 1, minWidth = 0, maxLines = 1 },
            UI.Button { id = "closeVolumePanel", text = "关闭", width = 48, height = 44,
                paddingHorizontal = 3, variant = "secondary", onClick = function() self:Close() end },
        } })

    -- 固定标题下只给 viewport 分配剩余高度，内容保持自然高度，不靠 hidden 裁掉最后一行。
    self.scroll_ = UI.ScrollView { id = "volumeScroll", width = "100%",
        flexGrow = 1, flexBasis = 0, flexShrink = 1, minHeight = 0,
        scrollX = false, scrollY = true, bounces = false, showScrollbar = true,
        scrollbarInteractive = false, gap = 6, paddingRight = 12 }
    self:AddChild(self.scroll_)
    self.soundButton_ = UI.Button { id = "volumePanelSound", text = "总声音 · 开启", height = 44,
        width = "100%", paddingHorizontal = 3, variant = "secondary",
        onClick = function()
            if not self.callbacks_.onSoundToggle then return end
            self.callbacks_.onSoundToggle(not self:IsSoundEnabled())
        end }
    self.scroll_:AddChild(self.soundButton_)

    self:AddRow("volume", "总音量 · 影响全部声音", 0.75)
    self:AddRow("trainVolume", "列车音量 · 机组 / 轮轨 / 汽笛", 1.0)
    self:AddRow("announcementVolume", "到站广播 · 车长播报", 0.85)
    self:AddRow("musicVolume", "音乐音量 · 背景音乐", 0.35)
end

---@param key string
---@param text string
---@param initial number
function Panel:AddRow(key, text, initial)
    local label = UI.Label { id = "volumeLabel_" .. key, text = text, fontSize = 9, fontColor = C.secondary,
        height = 18, flexShrink = 0, maxLines = 1 }
    local slider = VolumeSlider { id = "volumeSlider_" .. key, min = 0, max = 1, value = initial,
        height = 44, flexShrink = 0, width = "100%",
        onChange = function(_, value)
            if syncing_ then return end
            local handler = self.callbacks_["on" .. string.upper(string.sub(key, 1, 1)) .. string.sub(key, 2)]
            if handler then handler(value) end
        end }
    self.rows_[key] = { slider = slider, label = label }
    self.scroll_:AddChild(UI.Panel { height = 64, flexShrink = 0, width = "100%", gap = 2,
        pointerEvents = "box-none", children = { label, slider } })
end

---@param callbacks CabVolumePanelCallbacks?
function Panel:SetCallbacks(callbacks)
    self.callbacks_ = callbacks or {}
end

---@return boolean
function Panel:IsSoundEnabled()
    return self.soundEnabled_ ~= false
end

--- 同步外部真实状态；拖动中不覆盖用户当前拖动的值。
---@param values table
function Panel:Sync(values)
    syncing_ = true
    for key, row in pairs(self.rows_) do
        local value = tonumber(values[key])
        if value then
            if row.slider:GetValue() ~= value then row.slider:SetValue(value) end
        end
        row.slider:SetDisabled(not self.callbacks_["on" .. string.upper(string.sub(key, 1, 1)) .. string.sub(key, 2)])
    end
    syncing_ = false
    if values.sound ~= nil then
        self.soundEnabled_ = values.sound == true
        self.soundButton_:SetText(self.soundEnabled_ and "总声音 · 开启" or "总声音 · 静音")
        self.soundButton_:SetDisabled(not self.callbacks_.onSoundToggle)
    end
end

---@param left number
---@param top number
---@param width number
---@param height number
function Panel:SetBounds(left, top, width, height)
    self:SetStyle({ left = left, top = top, width = math.min(width, 316),
        height = math.min(height, 300) })
    if self.open_ then
        UI.Layout()
        self.scroll_:UpdateContentSize()
        local x, y = self.scroll_:GetScroll()
        self.scroll_:SetScroll(x, y) -- 转屏/安全区变化后重新夹取，避免尾部留空。
    end
end

function Panel:Open()
    if self.open_ then return end
    self.open_ = true
    self:Show()
    UI.PushOverlay(self)
    -- InputAdapter 先通知手势模块、后做 UI hit test；只为本弹窗补上按下目标，
    -- 让手指滑出 viewport/经过其他滑杆时仍由起点控件处理，不在移动位置重新命中。
    self.pointerHook_ = UI.Input.On("PointerDown", function(event)
        local scale = UI.GetScale()
        local x, y = event.x / scale, event.y / scale
        if event.pointerType == "touch" and self:HitTest(x, y) then
            event.target = UI.FindWidgetAt(x, y)
        end
    end, 1)
    self.scroll_.state.velocityX, self.scroll_.state.velocityY = 0, 0
    self.scroll_:ScrollToTop()
    if self.callbacks_.onOpen then self.callbacks_.onOpen(true) end
end

function Panel:Close()
    if not self.open_ then return end
    self.open_ = false
    if self.pointerHook_ then UI.Input.Off("PointerDown", self.pointerHook_); self.pointerHook_ = nil end
    for _, row in pairs(self.rows_) do
        if row.slider.touchPointer_ then UI.CancelPointer(row.slider.touchPointer_, "touch") end
        row.slider.touchPointer_, row.slider.pendingTouch_ = nil, false
        row.slider:SetState({ dragging = false })
    end
    self.scroll_.state.isDragging = false
    self.scroll_.state.velocityX, self.scroll_.state.velocityY = 0, 0
    UI.PopOverlay(self)
    self:Hide()
    if self.callbacks_.onOpen then self.callbacks_.onOpen(false) end
end

---@return boolean
function Panel:IsOpen() return self.open_ end

---@param dt number
function Panel:Update(dt)
    if self.open_ and input:GetKeyPress(KEY_ESCAPE) then self:Close() end
end

function Panel:Destroy()
    self:Close()
    UI.Panel.Destroy(self)
end

return Panel
