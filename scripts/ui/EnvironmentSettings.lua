-- 设置页环境控件：只投影 main 提供的状态，不保存世界时间/天气真源。
local UI = require "urhox-libs/UI"
local Skin = require "ui.CabStyle"
local C = Skin.Colors

---@class RailwayEnvironmentSettings : Panel
---@overload fun(props?: PanelProps): RailwayEnvironmentSettings
---@field getEnvironment_ fun(): table?
---@field requestEnvironment_ fun(patch: table)
---@field hour_ Label
---@field slider_ Slider
---@field running_ Button
---@field weather_ table<string, Button>
---@field presets_ Button[]
---@field syncTimer_ number
---@field syncing_ boolean
---@field signature_ string
local Settings = UI.Panel:Extend("RailwayEnvironmentSettings")

---@param props PanelProps?
function Settings:Init(props)
    UI.Panel.Init(self, props or {})
    -- Yoga在小屏缩放下对子项分别取整，自动高度留出累计2px量化余量。
    self:SetStyle({ paddingBottom = 4 })
    self.getEnvironment_ = function() return nil end
    self.requestEnvironment_ = function() end
    self.syncTimer_, self.syncing_, self.signature_ = 0, false, ""
    self.weather_, self.presets_ = {}, {}
end

--- buttonFactory 沿用 Menu 的金属按钮与点击声，不引入另一套主题。
---@param getter fun(): table?
---@param request fun(patch: table)
---@param buttonFactory fun(id:string,text:string,action:fun(),primary:boolean): Button
function Settings:Configure(getter, request, buttonFactory)
    self.getEnvironment_, self.requestEnvironment_ = getter, request
    self.hour_ = UI.Label { id = "environmentHour", text = "世界时刻 · 待同步", fontSize = 11,
        fontColor = C.text, minWidth = 0, maxLines = 1 }
    self.slider_ = UI.Slider { id = "settingsWorldHour", min = 0, max = 23, step = 1,
        value = 12, height = 48, width = "100%", thumbSize = 22,
        trackFillColor = C.teal, thumbColor = C.orange, disabled = true,
        onChange = function(_, value)
            if not self.syncing_ then
                self.hour_:SetText(string.format("调整世界时刻 · %02d:00（松手应用）", math.floor(value)))
            end
        end,
        onChangeEnd = function(_, value) self:Request({ hour = math.floor(value) }) end }
    local presets = UI.Panel { width = "100%", flexDirection = "row", gap = 6, pointerEvents = "box-none" }
    for _, preset in ipairs({ { id = "Day", text = "日间", hour = 12 },
        { id = "Dusk", text = "黄昏", hour = 18 }, { id = "Night", text = "夜间", hour = 22 } }) do
        local b = buttonFactory("settingsTime" .. preset.id, preset.text,
            function() self:Request({ hour = preset.hour }) end, false)
        b:SetStyle({ width = 0, flexGrow = 1, flexBasis = 0, flexShrink = 1, minWidth = 48,
            paddingHorizontal = 4 })
        self.presets_[#self.presets_ + 1] = b
        presets:AddChild(b)
    end
    self.running_ = buttonFactory("settingsTimeRunning", "时间流动 · 待同步", function()
        local current = self.getEnvironment_()
        if current then self:Request({ running = current.running ~= true }) end
    end, false)
    local weather = UI.Panel { id = "environmentWeatherOptions", width = "100%", minWidth = 0,
        flexDirection = "row", gap = 6, pointerEvents = "box-none" }
    for _, option in ipairs({ { id = "clear", text = "晴天" }, { id = "cloudy", text = "阴天" },
        { id = "rain", text = "雨天" }, { id = "fog", text = "雾天" } }) do
        local b = buttonFactory("settingsWeather_" .. option.id, option.text,
            function() self:Request({ weather = option.id }) end, false)
        b:SetStyle({ width = 0, flexGrow = 1, flexBasis = 0, flexShrink = 1, minWidth = 44,
            height = 48, minHeight = 48, paddingHorizontal = 4 })
        self.weather_[option.id] = b
        weather:AddChild(b)
    end
    self:AddChild(UI.Label { text = "世界时间与天气", fontSize = 11, fontColor = C.orange })
    self:AddChild(self.hour_)
    self:AddChild(self.slider_)
    self:AddChild(presets)
    self:AddChild(self.running_)
    self:AddChild(weather)
    self:AddChild(UI.Label { text = "天气仅改变视觉氛围，不改变制动性能。世界时刻与旅程累计计时独立。",
        fontSize = 9, fontColor = C.secondary, whiteSpace = "normal", maxLines = 3,
        lineHeight = 1.2, minWidth = 0 })
    self:Sync()
end

---@param patch table
function Settings:Request(patch)
    if not self.getEnvironment_() then return end
    self.requestEnvironment_(patch)
    self.signature_ = ""
    self:Sync() -- 回读已接受的真实状态；不把请求当世界状态。
end

function Settings:Sync()
    local current = self.getEnvironment_()
    local signature = current and table.concat({ tostring(current.hour), tostring(current.minute),
        tostring(current.running), tostring(current.weather) }, "/") or "unavailable"
    if signature == self.signature_ then return end
    -- 缓存的只是显示签名；拖动期间不锁定签名，松手后仍回读 main 真源。
    if not self.slider_.state.dragging then self.signature_ = signature end
    local enabled = current ~= nil
    self.slider_:SetDisabled(not enabled)
    self.running_:SetDisabled(not enabled)
    for _, b in ipairs(self.presets_) do b:SetDisabled(not enabled) end
    for id, b in pairs(self.weather_) do
        b:SetDisabled(not enabled)
        local selected = current and current.weather == id
        b:SetStyle({ borderColor = selected and C.teal or C.edge,
            textColor = selected and C.teal or C.text })
    end
    if not current then return end
    local hour = tonumber(current.hour) or 12
    if hour ~= hour or hour == math.huge or hour == -math.huge then hour = 12 end
    local minutes = math.floor((hour % 24) * 60) % 1440
    if current.minute ~= nil then minutes = (minutes // 60) * 60 + math.floor(tonumber(current.minute) or 0) % 60 end
    if not self.slider_.state.dragging then
        self.hour_:SetText(string.format("世界时刻 · %02d:%02d", minutes // 60, minutes % 60))
        self.syncing_ = true
        self.slider_:SetValue(math.floor(hour % 24))
        self.syncing_ = false
    end
    self.running_:SetText(current.running == true and "时间流动 · 开启" or "时间流动 · 暂停")
end

---@param dt number
function Settings:Update(dt)
    self.syncTimer_ = self.syncTimer_ - dt
    if self.syncTimer_ <= 0 and self.slider_ then
        self.syncTimer_ = .25
        self:Sync()
    end
end

return Settings
