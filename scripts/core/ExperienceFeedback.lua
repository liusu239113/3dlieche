-- 运营事件观察器：只读站序与乘降状态，不推进运营、不修改信号或触发奖励。
---@class AnnouncementSnapshot
---@field state string
---@field nextIndex number|nil
---@field lastArrival number|nil
---@field initialService boolean
---@field service string
---@field journeyId number|string
---@field visits number
---@field reversing boolean
---@field s number
---@field phase string
---@field terminal boolean
---@field terminalStop? boolean
---@field dwelling boolean

---@class RailwayFeedback
---@field emit fun(kind:string,index:number|nil,direction:number)
---@field clear fun()
---@field previous AnnouncementSnapshot|nil
---@field approached string
---@field reminded string
---@field waitAnnounced string
---@field terminalAnnounced string
local Feedback={}
Feedback.__index=Feedback

---@param emit fun(kind:string,index:number|nil,direction:number)
---@param clear fun()
---@return RailwayFeedback
function Feedback.new(emit,clear)
    local self=setmetatable({},Feedback) ---@type RailwayFeedback
    self:init(emit,clear)
    return self
end

---@param emit fun(kind:string,index:number|nil,direction:number)
---@param clear fun()
function Feedback:init(emit,clear)
    self.emit,self.clear=emit,clear
    self.previous=nil
    self.approached,self.reminded,self.waitAnnounced,self.terminalAnnounced="","","",""
end

---@param snapshot? AnnouncementSnapshot
---@param welcome? boolean
function Feedback:Reset(snapshot,welcome)
    self.clear()
    self.previous=snapshot
    self.approached,self.reminded,self.waitAnnounced,self.terminalAnnounced="","","",""
    if snapshot and welcome then self.emit("welcome",snapshot.lastArrival,snapshot.reversing and -1 or 1) end
end

---@param snapshot AnnouncementSnapshot
---@param departure {blocked:boolean, reason?:string, waitSeconds?:number} Read-only subset; full GameDepartureStatus is also accepted
---@param nextS number|nil
function Feedback:Update(snapshot,departure,nextS)
    local previous=self.previous
    if not previous then self:Reset(snapshot,false);return end
    if previous.journeyId~=snapshot.journeyId or previous.service~=snapshot.service
        or previous.reversing~=snapshot.reversing then
        local returnBoarding=previous.journeyId~=snapshot.journeyId
            and snapshot.initialService and snapshot.dwelling and not snapshot.terminalStop
        self:Reset(snapshot,returnBoarding)
        return
    end
    local dir=snapshot.reversing and -1 or 1
    local visit=tostring(snapshot.journeyId)..":"..snapshot.visits..":"..dir
    if snapshot.visits~=previous.visits and snapshot.dwelling then
        self.approached,self.waitAnnounced="",""
        self.emit(snapshot.initialService and "welcome" or "arrival",snapshot.lastArrival,dir)
    end
    if previous.dwelling and not snapshot.dwelling and snapshot.nextIndex then
        self.emit("departure",snapshot.nextIndex,dir)
        self.approached,self.waitAnnounced="",""
    end
    if snapshot.phase=="door_closing" and not snapshot.terminalStop and not snapshot.terminal
        and self.reminded~=visit then
        self.reminded=visit
        self.emit("departure_reminder",snapshot.lastArrival,dir)
    end
    if snapshot.terminal and self.terminalAnnounced~=visit then
        self.terminalAnnounced=visit
        self.emit("terminal",snapshot.lastArrival,dir)
    end
    if snapshot.dwelling and not snapshot.terminal and departure.blocked
        and (departure.waitSeconds or 0)>=15 and self.waitAnnounced~=visit then
        local reason=departure.reason or ""
        if reason=="occupied_ahead" or reason=="opposing_traffic" or reason=="throat_conflict"
            or reason=="signal_stop" or reason=="passing_clearance" or reason=="passing_train"
            or reason=="passing_dispatch" then
            self.waitAnnounced=visit
            self.emit("wait_signal",snapshot.lastArrival,dir)
        end
    end
    if not snapshot.dwelling and snapshot.nextIndex and nextS then
        local distance=(nextS-snapshot.s)*dir
        local key=visit..":"..snapshot.nextIndex
        if distance>=0 and distance<=1200 and self.approached~=key then
            self.approached=key
            self.emit("approach",snapshot.nextIndex,dir)
        end
    end
    self.previous=snapshot
end

return Feedback
