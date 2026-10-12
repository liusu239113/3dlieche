-- 客运只读小状态条。权威乘降/车门/许可均来自 Game，不推进计时或操作列车。
local UI = require "urhox-libs/UI"
local Skin = require "ui.CabStyle"
local C = Skin.Colors
local Passenger = {}

---@class CabPassengerStatus
---@field phase string
---@field waiting integer
---@field boarded integer
---@field alighted integer
---@field totalBoarding integer
---@field totalAlighting integer
---@field onboard integer
---@field capacity integer
---@field doorsOpen boolean
---@field ready boolean
---@field message string

---@param value number|string|nil
---@return integer
local function Count(value)
    local n = tonumber(value)
    if not n or n ~= n or n == math.huge or n == -math.huge then return 0 end
    return math.max(0, math.floor(n))
end

---@param status table?
---@return CabPassengerStatus
function Passenger.Snapshot(status)
    local source = status or {}
    return {
        phase = type(source.phase) == "string" and source.phase or "",
        waiting = Count(source.waiting), boarded = Count(source.boarded), alighted = Count(source.alighted),
        totalBoarding = Count(source.totalBoarding), totalAlighting = Count(source.totalAlighting),
        onboard = Count(source.onboard), capacity = Count(source.capacity), doorsOpen = source.doorsOpen == true,
        ready = source.ready == true, message = type(source.message) == "string" and source.message or "",
    } --[[@as CabPassengerStatus]]
end

---@class CabPassengerStrip : Panel
---@overload fun(props?: PanelProps): CabPassengerStrip
---@field counts_ Label
---@field permission_ Label
---@field status_ CabPassengerStatus
---@field readyColor_ boolean?
local Strip = UI.Panel:Extend("CabPassengerStrip")

---@param props PanelProps?
function Strip:Init(props)
    props = props or {}
    props.id = props.id or "passengerStatus"
    props.height, props.gap = 34, 0
    props.pointerEvents = "none"
    UI.Panel.Init(self, props)
    self.status_ = Passenger.Snapshot(nil)
    self.counts_ = UI.Label { id = "passengerCounts", text = "", height = 17,
        fontSize = 9, fontColor = C.text, maxLines = 1, minWidth = 0, flexShrink = 1 }
    self.permission_ = UI.Label { id = "passengerPermission", text = "", height = 17,
        fontSize = 9, fontWeight = "bold", fontColor = C.orange, maxLines = 1,
        minWidth = 0, flexShrink = 1 }
    self:AddChild(self.counts_)
    self:AddChild(self.permission_)
end

---@param status CabPassengerStatus
function Strip:SetStatus(status)
    self.status_ = Passenger.Snapshot(status)
    local s = self.status_
    local counts = string.format("载客 %d/%d · 上 %d/%d · 下 %d/%d",
        s.onboard, s.capacity, s.boarded, s.totalBoarding, s.alighted, s.totalAlighting)
    if self.counts_:GetText() ~= counts then self.counts_:SetText(counts) end
    -- ready 仍原样保存用于验收；门开时绝不把矛盾快照显示为允许发车。
    local mayDepart = s.ready and not s.doorsOpen
    local permission = (s.doorsOpen and "门：已开" or "门：已闭")
        .. (mayDepart and " · 许可：可发车" or " · 许可：请等待")
    if s.message ~= "" then permission = permission .. " · " .. s.message end
    if self.permission_:GetText() ~= permission then self.permission_:SetText(permission) end
    if self.readyColor_ ~= mayDepart then
        self.readyColor_ = mayDepart
        self.permission_:SetFontColor(mayDepart and C.teal or C.orange)
    end
end

Passenger.Strip = Strip
return Passenger
