-- Simulation timetable, not surveyed railway timings or a real published train service.
-- Clock ownership stays with Environment. All times below are absolute WORLD MINUTES.
-- This pure model never advances a second clock, touches files, passengers, or train controls.
-- Timetables consume the Environment clock and Route station records unchanged.
-- Keep these public timetable names as aliases, not competing nominal record classes.
---@alias TimetableClock EnvironmentClock
---@alias TimetableStation RailwayStation

---@class TimetableRow
---@field stationIndex integer
---@field name string
---@field s number
---@field trip integer
---@field origin boolean
---@field terminal boolean
---@field plannedArrival? number
---@field plannedDeparture? number
---@field actualArrival? number
---@field actualDeparture? number
---@field runSeconds number Modelled running time from the preceding stop
---@field dwellMinutes number
---@field phase string pending/arrived/departed/cancelled/missed
---@field arrivalRevision? number
---@field departureRevision? number
---@field calibratedRevision? number
---@field expectedArrival? number Snapshot only, never persisted as an actual
---@field expectedDeparture? number
---@field delayMinutes? number Positive = late, negative = early
---@field delayKind? string actual arrival/departure or prediction

---@class TimetableSegment
---@field s number
---@field length number
---@field radius? number
---@field type? string

---@class TimetableOptions
---@field s number
---@field reversing boolean
---@field service string
---@field journeyId integer
---@field originIndex? integer Only when actually stopped at a station
---@field operatingKmh number
---@field lineKmh number
---@field stationKmh number
---@field deceleration number
---@field acceleration? number
---@field segments TimetableSegment[]
---@field closed? boolean
---@field length? number

---@class TimetableMotion
---@field s number
---@field speedMs number
---@field operatingKmh number
---@field deceleration number
---@field dwelling boolean
---@field terminal boolean
---@field gameOver? boolean
---@field minimumDwellSeconds number
---@field passengerReady boolean
---@field departureBlocked boolean
---@field departureReason? string

---@class TimetableStatus
---@field version integer
---@field minutes number
---@field running boolean
---@field paused boolean
---@field trip integer
---@field service string
---@field reversing boolean
---@field rows TimetableRow[]
---@field next? TimetableRow
---@field departure? TimetableRow
---@field notice string
---@field condition string
---@field migrated boolean

---@class TimetableSnapshot
---@field version integer
---@field rows TimetableRow[]
---@field options TimetableOptions
---@field trip integer
---@field service string
---@field reversing boolean
---@field revision number
---@field lastMinutes number
---@field notice string
---@field migrated boolean
---@field berthIndex? integer
---@field berthS? number

---@class RailwayTimetable
---@field rows TimetableRow[]
---@field stations TimetableStation[]
---@field options TimetableOptions
---@field clock TimetableClock
---@field trip integer
---@field service string
---@field reversing boolean
---@field revision number
---@field lastMinutes number
---@field notice string
---@field migrated boolean
---@field berthIndex? integer
---@field berthS? number
---@type RailwayTimetable
local Timetable = {}
Timetable.__index = Timetable

---@param value any
local function finite(value)
    return type(value)=="number" and value==value and value>-math.huge and value<math.huge
end
---@generic T
---@param value T
---@return T
local function copy(value)
    if type(value)~="table" then return value end
    local result={}
    for key,item in pairs(value) do result[key]=copy(item) end
    return result
end
local function required(index,count,service)
    return service~="express" or index==1 or index==3 or index==count
end
local function clockValid(clock)
    return type(clock)=="table" and finite(clock.minutes) and clock.minutes>=0
        and finite(clock.rate) and clock.rate>0 and finite(clock.revision)
        and type(clock.running)=="boolean" and type(clock.paused)=="boolean"
end

--- Integrate a bounded speed envelope over real route metres. Station throats and curves
--- constrain the whole estimate, not just the instantaneous limit at the current train.
--- Forward acceleration + backward braking prevent distance/currentSpeed ETA near a stop.
---@param fromS number
---@param toS number
---@param speedMs number
---@param options TimetableOptions
---@param stations TimetableStation[]
---@return number?
function Timetable.EstimateRun(fromS,toS,speedMs,options,stations)
    local length=options.length or 0
    local sign=options.reversing and -1 or 1
    local distance=(toS-fromS)*sign
    if options.closed and length>0 then distance=distance%length end
    if distance < -.001 then return nil end
    if distance<=.001 then return 0 end
    local cap=math.max(1,math.min(options.operatingKmh,options.lineKmh))/3.6
    local count=math.max(1,math.min(384,math.ceil(distance/80)))
    local dx=distance/count
    local acceleration=math.max(.15,options.acceleration or .38)
    local deceleration=math.max(.1,options.deceleration)
    local velocities={} ---@type number[]
    for i=1,count+1 do
        local s=fromS+sign*(i-1)*dx
        if options.closed and length>0 then s=s%length end
        local limit=cap
        for _,segment in ipairs(options.segments) do
            if s>=segment.s and s<=segment.s+segment.length and segment.radius and segment.radius>0 then
                limit=math.min(limit,math.max(10,math.floor(math.sqrt(.95*segment.radius)*3.6/10)*10)/3.6)
            end
        end
        for _,station in ipairs(stations) do
            local relative=s-station.s
            if options.closed and length>0 then relative=(relative+length*.5)%length-length*.5 end
            if relative>=-450 and relative<=250 then limit=math.min(limit,options.stationKmh/3.6) end
        end
        velocities[i]=limit
    end
    velocities[1]=math.min(velocities[1],math.max(0,math.abs(speedMs)))
    velocities[count+1]=0
    for i=2,count+1 do velocities[i]=math.min(velocities[i],math.sqrt(velocities[i-1]^2+2*acceleration*dx)) end
    for i=count,1,-1 do velocities[i]=math.min(velocities[i],math.sqrt(velocities[i+1]^2+2*deceleration*dx)) end
    local seconds=0
    for i=1,count do
        local sum=velocities[i]+velocities[i+1]
        -- One very short interval can have both endpoints stopped: triangular profile.
        seconds=seconds+(sum>.001 and 2*dx/sum or math.sqrt(2*dx/acceleration)+math.sqrt(2*dx/deceleration))
    end
    return seconds
end

---@param clock TimetableClock
---@param stations TimetableStation[]
---@param options TimetableOptions
---@return RailwayTimetable
function Timetable.new(clock,stations,options)
    local self=setmetatable({},Timetable) ---@type RailwayTimetable
    self:Init(clock,stations,options)
    return self
end
---@param clock TimetableClock
---@param stations TimetableStation[]
---@param options TimetableOptions
function Timetable:Init(clock,stations,options)
    assert(clockValid(clock),"时刻表需要有效Environment世界时钟")
    self.rows,self.stations,self.options={},copy(stations),copy(options)
    self.clock=copy(clock)
    self.trip,self.service,self.reversing=options.journeyId,options.service,options.reversing
    self.revision,self.lastMinutes=clock.revision,clock.minutes
    self.notice,self.migrated="模拟运行图 · 非真实班次",false
    self.berthIndex,self.berthS=nil,nil
    self:BuildPlan(options.originIndex)
end

---@param originIndex integer?
function Timetable:BuildPlan(originIndex)
    local cursorS=self.options.s
    local cursorTime=self.clock.minutes
    local direction=self.reversing and -1 or 1
    local first=self.reversing and #self.stations or 1
    local last=self.reversing and 1 or #self.stations
    local planned={} ---@type TimetableRow[]
    for i=first,last,direction do
        local station=self.stations[i]
        local ahead=(station.s-cursorS)*direction
        if required(station.index,#self.stations,self.service) and (ahead>=0 or station.index==originIndex) then
            local origin=station.index==originIndex
            local seconds=origin and 0 or Timetable.EstimateRun(cursorS,station.s,0,self.options,self.stations)
            if seconds then
                local arrival=nil ---@type number?
                if not origin then arrival=math.ceil(cursorTime+seconds*self.clock.rate) end
                -- Simulated dwell budget covers door paths; it is not a claim of measured station data.
                local dwell=math.max(1,(origin and 80 or (self.service=="passing" and i==3 and 90 or 45))*self.clock.rate)
                local departure=math.ceil((arrival or cursorTime)+dwell)
                planned[#planned+1]={stationIndex=station.index,name=station.name,s=station.s,trip=self.trip,
                    origin=origin,terminal=false,plannedArrival=arrival,plannedDeparture=departure,
                    runSeconds=seconds,dwellMinutes=dwell,phase=origin and "arrived" or "pending"}
                cursorS,cursorTime=station.s,departure
            end
        end
    end
    if #planned>0 then
        local terminal=planned[#planned]
        terminal.terminal,terminal.plannedDeparture=true,nil
        -- An origin alone at the end is not a new fictitious arrival.
        for _,row in ipairs(planned) do self.rows[#self.rows+1]=row end
    end
    if originIndex then self.berthIndex,self.berthS=originIndex,self.options.s end
end

--- Explicit environment edits are not punitive fast-forward. Move only unexecuted
--- plan fields by the clock delta; measured actuals and their issued plan stay unchanged.
---@param clock TimetableClock
function Timetable:SyncClock(clock)
    assert(clockValid(clock),"世界时钟无效")
    if clock.revision~=self.revision then
        local delta=clock.minutes-self.lastMinutes
        for _,row in ipairs(self.rows) do
            if row.trip==self.trip and (row.phase=="pending" or row.phase=="arrived") then
                if not row.actualArrival and row.plannedArrival then row.plannedArrival=math.max(0,row.plannedArrival+delta) end
                if not row.actualDeparture and row.plannedDeparture then row.plannedDeparture=math.max(0,row.plannedDeparture+delta) end
                row.calibratedRevision=clock.revision
            end
        end
        self.notice="世界时刻已调整 · 未执行计划同步平移，实际记录保留"
    end
    self.clock,self.revision,self.lastMinutes=copy(clock),clock.revision,clock.minutes
end

---@param index integer
---@param origin? boolean Initial / return boarding is NOT a measured arrival
---@param berthS? number Actual stopped position, not the nominal station marker
function Timetable:Arrive(index,origin,berthS)
    for _,row in ipairs(self.rows) do
        if row.trip==self.trip and row.stationIndex==index and row.phase=="pending" then
            row.actualArrival=not origin and self.clock.minutes or nil
            row.arrivalRevision=self.clock.revision
            row.phase="arrived"
            self.berthIndex,self.berthS=index,berthS or row.s
            return true
        end
    end
    return false
end

---@param motion TimetableMotion
function Timetable:Observe(motion)
    -- Game.Depart merely grants readiness. Actual departure requires physical motion away.
    if self.berthIndex and self.berthS and not motion.dwelling and math.abs(motion.speedMs)>.02
        and math.abs(motion.s-self.berthS)>2 then
        for _,row in ipairs(self.rows) do
            if row.trip==self.trip and row.stationIndex==self.berthIndex and row.phase=="arrived" and not row.terminal then
                row.actualDeparture,row.phase=self.clock.minutes,"departed"
                row.departureRevision=self.clock.revision
                break
            end
        end
        self.berthIndex,self.berthS=nil,nil
    end
    if not self.clock.running or self.clock.paused then return end
    for _,row in ipairs(self.rows) do
        if row.trip==self.trip and row.phase=="pending" then
            local passed=(motion.s-row.s)*(self.reversing and -1 or 1)
            if passed>60 and not self.options.closed then row.phase="missed" end
        end
    end
end

--- Reissue only when the player changes the route/service or starts a return trip.
--- A train change never calls this: issued plans stay fixed, predictions adapt to the new stock.
---@param options TimetableOptions
function Timetable:Replan(options)
    for _,row in ipairs(self.rows) do
        if row.trip==self.trip and (row.phase=="pending" or (row.phase=="arrived" and not row.actualDeparture)) then
            row.phase="cancelled"
        end
    end
    self.trip,self.service,self.reversing=options.journeyId,options.service,options.reversing
    self.options=copy(options)
    self.berthIndex,self.berthS=nil,nil
    self:BuildPlan(options.originIndex)
    self.notice="变更后的模拟运行图 · 已发生记录保留"
    -- Bounded history: keep the current plus recent trips; completed records are never relabelled actual.
    while #self.rows>40 do table.remove(self.rows,1) end
end

---@param motion TimetableMotion
---@return TimetableStatus
function Timetable:GetStatus(motion)
    local rows=copy(self.rows) --[[@as TimetableRow[] ]]
    local currentOptions=copy(self.options) --[[@as TimetableOptions]]
    currentOptions.operatingKmh,currentOptions.deceleration=motion.operatingKmh,motion.deceleration
    local nextRow=nil ---@type TimetableRow?
    local departure=nil ---@type TimetableRow?
    local cursorS,cursorTime=motion.s,self.clock.minutes
    local initialSpeed=math.abs(motion.speedMs)
    for _,row in ipairs(rows) do
        if row.trip==self.trip and row.phase=="arrived" then
            departure=row
            if not row.terminal and not motion.gameOver then
                local remaining=math.max(0,motion.minimumDwellSeconds)
                -- Remaining walking/queue paths are not deterministic to the timetable. Show
                -- a conditional earliest departure, not a fake exact dispatch prediction.
                if not motion.passengerReady then remaining=math.max(remaining,15) end
                row.expectedDeparture=self.clock.minutes+remaining*self.clock.rate
                cursorTime,cursorS,initialSpeed=row.expectedDeparture,row.s,0
            end
        elseif row.trip==self.trip and row.phase=="pending" and not motion.gameOver then
            local seconds=Timetable.EstimateRun(cursorS,row.s,initialSpeed,currentOptions,self.stations)
            if seconds then
                row.expectedArrival=cursorTime+seconds*self.clock.rate
                row.expectedDeparture=not row.terminal and row.expectedArrival+row.dwellMinutes or nil
                cursorTime,cursorS,initialSpeed=row.expectedDeparture or row.expectedArrival,row.s,0
                nextRow=nextRow or row
            end
        end
        if row.actualDeparture and row.plannedDeparture then
            row.delayMinutes,row.delayKind=row.actualDeparture-row.plannedDeparture,"实际发车"
        elseif row.actualArrival and row.plannedArrival then
            row.delayMinutes,row.delayKind=row.actualArrival-row.plannedArrival,"实际到达"
        elseif row.expectedArrival and row.plannedArrival then
            row.delayMinutes,row.delayKind=row.expectedArrival-row.plannedArrival,"预计到达"
        elseif row.expectedDeparture and row.plannedDeparture then
            row.delayMinutes,row.delayKind=row.expectedDeparture-row.plannedDeparture,"预计发车"
        end
    end
    local frozen=not self.clock.running or self.clock.paused
    local condition=motion.gameOver and "事故结束 · 无到站预测"
        or frozen and (self.clock.paused and "世界时钟暂停" or "世界时钟停止 · 预计时刻仅供恢复后参考")
        or motion.departureBlocked and motion.departureReason~="terminal" and "预测以乘降完成、信号放行为条件"
        or "预测依据距离、车型与线路许可速度"
    return {version=1,minutes=self.clock.minutes,running=self.clock.running,paused=self.clock.paused,
        trip=self.trip,service=self.service,reversing=self.reversing,rows=rows,next=nextRow,departure=departure,
        notice=self.notice,condition=condition,migrated=self.migrated}
end

--- Read-only world-clock preview, including a not-yet-committed clock-edit calibration.
---@param clock TimetableClock
---@param motion TimetableMotion
---@return TimetableStatus
function Timetable:Preview(clock,motion)
    local shadow=setmetatable({rows=copy(self.rows),stations=self.stations,options=self.options,clock=self.clock,
        trip=self.trip,service=self.service,reversing=self.reversing,revision=self.revision,lastMinutes=self.lastMinutes,
        notice=self.notice,migrated=self.migrated,berthIndex=self.berthIndex,berthS=self.berthS},Timetable)
    shadow:SyncClock(clock)
    return shadow:GetStatus(motion)
end

---@return TimetableSnapshot
function Timetable:Export()
    return {version=1,rows=copy(self.rows),options=copy(self.options),trip=self.trip,service=self.service,
        reversing=self.reversing,revision=self.revision,lastMinutes=self.lastMinutes,notice=self.notice,
        migrated=self.migrated,berthIndex=self.berthIndex,berthS=self.berthS}
end

--- Validate everything before mutating the live timetable / Game progress.
---@param saved table
---@param stations? TimetableStation[] Omit for pre-world SaveStore validation
---@return boolean,string
function Timetable.Validate(saved,stations)
    if type(saved)~="table" or saved.version~=1 then return false,"不支持的时刻表存档版本" end
    if type(saved.rows)~="table" or #saved.rows>40 or type(saved.options)~="table" then return false,"时刻表结构无效" end
    if not finite(saved.trip) or saved.trip<1 or saved.trip%1~=0 or type(saved.reversing)~="boolean"
        or (saved.service~="local" and saved.service~="express" and saved.service~="passing")
        or not finite(saved.lastMinutes) or not finite(saved.revision) then return false,"时刻表状态无效" end
    local options=saved.options
    for _,key in ipairs({"s","operatingKmh","lineKmh","stationKmh","deceleration","journeyId"}) do
        if not finite(options[key]) then return false,"时刻表运行参数无效" end
    end
    if options.operatingKmh<=0 or options.lineKmh<=0 or options.stationKmh<=0 or options.deceleration<=0
        or type(options.segments)~="table" or type(options.reversing)~="boolean"
        or (options.closed~=nil and type(options.closed)~="boolean")
        or (options.length~=nil and (not finite(options.length) or options.length<=0))
        or (options.acceleration~=nil and (not finite(options.acceleration) or options.acceleration<=0))
        or options.service~=saved.service or options.journeyId~=saved.trip or options.reversing~=saved.reversing then
        return false,"时刻表速度约束无效"
    end
    for _,segment in ipairs(options.segments) do
        if type(segment)~="table" or not finite(segment.s) or not finite(segment.length) or segment.length<0
            or (segment.radius~=nil and (not finite(segment.radius) or segment.radius<0)) then
            return false,"时刻表线路约束无效"
        end
    end
    for key in pairs(saved.rows) do
        if type(key)~="number" or key%1~=0 or key<1 or key>#saved.rows then return false,"时刻表行索引无效" end
    end
    for _,row in ipairs(saved.rows) do
        if type(row)~="table" or not finite(row.stationIndex) or row.stationIndex%1~=0 then return false,"时刻表站点无效" end
        local station=stations and stations[row.stationIndex] or nil
        if row.stationIndex<1 or (stations and (not station or station.index~=row.stationIndex or not finite(row.s) or math.abs(row.s-station.s)>.001))
            or type(row.name)~="string" or not finite(row.s)
            or not finite(row.trip) or type(row.origin)~="boolean" or type(row.terminal)~="boolean"
            or not finite(row.runSeconds) or row.runSeconds<0 or not finite(row.dwellMinutes) or row.dwellMinutes<0 then
            return false,"时刻表站点与线路不匹配"
        end
        if row.phase~="pending" and row.phase~="arrived" and row.phase~="departed"
            and row.phase~="cancelled" and row.phase~="missed" then return false,"未知时刻表状态" end
        for _,field in ipairs({"plannedArrival","plannedDeparture","actualArrival","actualDeparture"}) do
            local value=row[field]
            if value~=nil and (not finite(value) or value<0) then return false,"时刻表时间无效" end
        end
        for _,field in ipairs({"arrivalRevision","departureRevision","calibratedRevision"}) do
            if row[field]~=nil and (not finite(row[field]) or row[field]<0 or row[field]%1~=0) then return false,"调时时钟版本无效" end
        end
        if row.origin and row.actualArrival~=nil then return false,"始发不能伪造实际到达" end
        if not row.origin and row.plannedArrival==nil then return false,"非始发缺少计划到达" end
        if row.phase=="pending" and (row.actualArrival or row.actualDeparture) then return false,"未到站已有实际记录" end
        if row.phase=="departed" and not row.actualDeparture then return false,"已发车缺少实际发车" end
        if row.actualDeparture and row.actualArrival and row.actualDeparture<row.actualArrival
            and (row.arrivalRevision or 0)==(row.departureRevision or 0) then return false,"实际到发顺序错误" end
        if row.phase=="arrived" and not row.origin and not row.actualArrival then return false,"已到站缺少实际到达" end
        if row.terminal and (row.actualDeparture or row.plannedDeparture) then return false,"终到不能有发车记录" end
        if row.plannedArrival and row.plannedDeparture and row.plannedDeparture<row.plannedArrival
            and row.calibratedRevision==nil then return false,"计划到发顺序错误" end
    end
    if saved.berthIndex~=nil and (not finite(saved.berthIndex) or saved.berthIndex%1~=0 or saved.berthIndex<1
        or (stations and not stations[saved.berthIndex]) or not finite(saved.berthS)) then return false,"停靠时刻表无效" end
    return true,""
end

--- Pre-world validation for SaveStore. Absence is a supported legacy save; unknown schema is not.
---@param saved any
---@return boolean,string
function Timetable.ValidateSnapshot(saved)
    if saved==nil then return true,"旧档将在当前世界时刻建立计划，不伪造历史实际" end
    return Timetable.Validate(saved)
end

---@param saved table
---@return boolean,string
function Timetable:Restore(saved)
    local ok,message=Timetable.Validate(saved,self.stations)
    if not ok then return false,message end
    self.rows,self.options=copy(saved.rows),copy(saved.options)
    self.trip,self.service,self.reversing=saved.trip,saved.service,saved.reversing
    self.revision,self.lastMinutes=saved.revision,saved.lastMinutes
    self.notice,self.migrated=saved.notice or "模拟运行图 · 非真实班次",saved.migrated==true
    self.berthIndex,self.berthS=saved.berthIndex,saved.berthS
    return true,""
end

---@param minutes number?
---@return string
function Timetable.FormatTime(minutes)
    if not finite(minutes) then return "—" end
    local total=math.floor(math.max(0,minutes)+.000001)
    local day=math.floor(total/1440)
    local clock=string.format("%02d:%02d",math.floor(total%1440/60),total%60)
    return day>0 and string.format("%s(+%d日)",clock,day) or clock
end
---@param minutes number?
function Timetable.FormatDelay(minutes)
    if not finite(minutes) then return "未有记录" end
    if math.abs(minutes)<1 then return "准点 ±1分" end
    return (minutes>0 and "晚" or "早")..math.floor(math.abs(minutes)).."分"
end
return Timetable
