-- ============================================================================
-- Game - 开放线路运营（方向站序 / 到站奖励 / 服务任务 / 安全速度）
-- Traffic依赖Train/Route/RailNetwork，不反向依赖Game；本模块只消费其权威状态。
-- ============================================================================
local GameConfig = require "config.GameConfig"
local GameModes = require "config.GameModes"
local Route = require "world.Route"
local RailNetwork = require "world.RailNetwork"
local Train = require "train.Train"
local Traffic = require "game.Traffic"
local Hud = require "ui.Hud"
local AudioManager = require "audio.AudioManager"
local SpeedPolicy = require "game.SpeedPolicy"
local PassengerService = require "game.PassengerService"
local Environment = require "world.Environment"
local Timetable = require "game.Timetable"

local Game = {}
local G = GameConfig.Gameplay
local STATE = { DRIVING = "driving", DWELL = "dwell", TERMINAL = "terminal" }
---@class RailwayService
---@field id string
---@field name string
---@field description string
---@type RailwayService[]
local SERVICES = {
    {id = "local", name = "站站停", description = "依次停靠沿线各站，终到后手动换向折返"},
    {id = "express", name = "快速大站停", description = "停首站、中间枢纽与总站；其余车站限速通过"},
    {id = "passing", name = "侧线待避训练", description = "站站停；中间枢纽侧线停稳，待快车通过、信号放行"},
}
local serviceIndex_ = 1
local state_ = STATE.DRIVING
local stations_ = {} ---@type RailwayStation[]
local nextIndex_ = nil ---@type integer?
local dwellTimer_ = 0.0
local elapsed_ = 0.0
local xp_ = 0
local overspeedWarned_, brakeWarned_ = false, false
local travelReversing_ = false
local switchPos_ = 0.0
local lastArrival_ = nil ---@type RailwayStation?
local arrivalReversing_ = false
-- 到站奖励在本运营区间内锁存，换车/换任务/原地换向均不清空；终到折返开启新趟。
local rewarded_ = {} ---@type table<number, boolean>
local passingSawRed_, passingComplete_ = false, false
local passingPrepared_, passingApproachPrepared_ = false, false
local waitingNotified_, wrongLaneWarned_, clearanceWarned_ = false, false, false
local hudTimer_ = 0.0
local hudDirty_ = true
local lastNotch_ = 0
local arrivalError_ = 0.0
local initialService_ = false
local needsCorrection_ = false
local journeyId_, completedTrips_, rewardedStops_, passengerPoints_ = 1, 0, 0, 0
local tripCompleted_ = false
local tripHadTravel_ = false
local lastPassengerPhase_ = ""
local initialDistance_ = 0.0
---@type number?
local departureBlockedSince_ = nil
local lastDepartureReason_ = ""
---@type RailwayTimetable?
local timetable_ = nil
local timetableCache_ = {} ---@type table
local timetableCacheKey_ = ""
local timetableCacheElapsed_ = -math.huge
local timetableCacheMinutes_,timetableCacheS_ = -math.huge,-math.huge

---@return TimetableOptions
local function timetableOptions()
    local segments={}
    for _,segment in ipairs(Route.GetSegments()) do
        segments[#segments+1]={s=segment.s,length=segment.length,radius=segment.radius,type=segment.type}
    end
    return {s=Train.GetS(),reversing=Train.IsReversing(),service=SERVICES[serviceIndex_].id,
        journeyId=journeyId_,originIndex=state_~=STATE.DRIVING and lastArrival_ and lastArrival_.index or nil,
        operatingKmh=Train.GetOperatingSpeedKmh(),lineKmh=G.SpeedLimitKmh,stationKmh=G.StationSpeedKmh,
        deceleration=Train.GetServiceDeceleration(true),segments=segments,closed=Route.IsClosed(),length=Route.GetLength()}
end

local function replanTimetable()
    if timetable_ then
        timetable_:SyncClock(Environment.GetClock())
        timetable_:Replan(timetableOptions())
        timetableCacheKey_=""
    end
end

---@return TimetableMotion
local function timetableMotion()
    local passenger=PassengerService.GetStatus()
    local departure=Game.GetDepartureStatus()
    return {s=Train.GetS(),speedMs=Train.GetSpeedMs(),operatingKmh=Train.GetOperatingSpeedKmh(),
        deceleration=Train.GetServiceDeceleration(true),dwelling=state_~=STATE.DRIVING,terminal=state_==STATE.TERMINAL,
        gameOver=state_=="game_over",minimumDwellSeconds=dwellTimer_,passengerReady=passenger.ready,
        departureBlocked=departure.blocked,departureReason=departure.reason}
end

---@class GameDepartureStatus
---@field blocked boolean
---@field reason string
---@field message string
---@field waitSeconds number simulated seconds, paused with the game
---@field signalReason string?
---@field blockerName string?
---@field blockerDistance number?
---@field stationIndex number?
---@field aspect string?
---@field passingPhase string?
---@field dwellRemaining number

---@return RailwayService
local function service() return (assert(SERVICES[serviceIndex_])) end
local function stopped() return math.abs(Train.GetSpeedMs()) <= 0.02 and Train.GetThrottle() == 0 end
---@param station RailwayStation
local function isRequired(station)
    return service().id ~= "express" or station.index == 1 or station.index == 3 or station.index == #stations_
end
local function distanceAhead(targetS)
    return Train.IsReversing() and Route.ForwardDistance(targetS, Train.GetS())
        or Route.ForwardDistance(Train.GetS(), targetS)
end
---@param station RailwayStation?
local function isPassingStop(station)
    return service().id == "passing" and station ~= nil and station.index == 3
end
---@param station RailwayStation
local function passingClearance(station)
    -- 和Traffic的80m咽喉净空同口径；换车变长后必须重新检查。
    return RailNetwork.GetPlayerLane(Train.GetS()) == 2
        and Train.GetS() - Train.GetActiveLength() >= station.s - 240
        and Train.GetS() + 16 <= station.s + 80
end
local function signalOpen(index)
    local aspect = Traffic.GetSignalAspect(index)
    return aspect == "green" or aspect == "yellow"
end

--- 查找当前方向的下一必停站，不用循环索引补回首站。
--- 刚停过的站只在驶离容差区后重新允许选择，避免原地重复接站。
local function selectNext()
    local best, selected = math.huge, nil ---@type number, integer?
    for i, station in ipairs(stations_) do
        local justArrived = lastArrival_ and station.index == lastArrival_.index
            and Route.Distance(Train.GetS(), station.s) <= G.StopTolerance
        if isRequired(station) and not justArrived then
            local distance = distanceAhead(station.s)
            if distance < best then best, selected = distance, i end
        end
    end
    nextIndex_ = selected
    overspeedWarned_, brakeWarned_ = false, false
    hudDirty_ = true
    return best
end

---@param index integer
---@param reversing boolean?
---@return integer?
local function followingStop(index, reversing)
    local reverse = reversing
    if reverse == nil then reverse = Train.IsReversing() end
    local step = reverse and -1 or 1
    local candidate = index + step ---@type integer
    while candidate >= 1 and candidate <= #stations_ do
        if isRequired(assert(stations_[candidate])) then return candidate end
        candidate = candidate + step
    end
    -- 保留旧闭合配置兼容；开放线路绝不首尾相接。
    if Route.IsClosed() then
        candidate = step > 0 and 1 or #stations_
        while candidate ~= index do
            if isRequired(assert(stations_[candidate])) then return candidate end
            candidate = candidate + step
        end
    end
    return nil
end

---@param index integer
---@param reversing boolean?
---@return integer[]
local function destinations(index, reversing)
    local result = {} ---@type integer[]
    local cursor = followingStop(index, reversing)
    while cursor and #result < #stations_ do
        result[#result+1] = cursor
        cursor = followingStop(cursor, reversing)
        if cursor == index then break end
    end
    return result
end

--- 全体乘客真实路径与关门完成后才提交奖励。
local function completePassengerStop()
    local completion = PassengerService.TakeCompletion()
    local station = lastArrival_
    if not completion or not station then return end
    if completion.terminal and tripHadTravel_ and not tripCompleted_ then
        completedTrips_, tripCompleted_ = completedTrips_+1, true
    end
    if completion.initial or rewarded_[station.index] then return end
    local precise = arrivalError_ < G.StopTolerance*.35
    local passengerReward = (completion.boarded+completion.alighted)*2
    local comfortPenalty = math.min(G.XpPerStation,math.floor((100-completion.comfort)*1.5))
    local gained = math.max(0,G.XpPerStation+(precise and G.XpSpeedBonus or 0)+passengerReward-comfortPenalty)
    rewarded_[station.index], xp_ = true, xp_+gained
    rewardedStops_, passengerPoints_ = rewardedStops_+1, passengerPoints_+passengerReward
    Hud.Toast(string.format("%s乘降完成 · %d上车/%d下车 · 舒适%.0f · +%d经验",
        station.name,completion.boarded,completion.alighted,completion.comfort,gained),3)
    print(string.format("[Game] %s passenger stop complete: XP+%d, boarded%d/alighted%d, comfort %.1f",
        station.name,gained,completion.boarded,completion.alighted,completion.comfort))
    hudDirty_ = true
end

--- 待避进路针对第三站，不把最近的第二站道岔误当作训练站。
local function preparePassing(approaching)
    if service().id ~= "passing" or passingComplete_ then return end
    local station = stations_[3]
    if not station then return end
    local distance = distanceAhead(station.s)
    if distance == math.huge then return end
    if approaching then
        if distance > 5000 or passingApproachPrepared_ then return end
        passingApproachPrepared_ = true
    elseif passingPrepared_ then return
    else passingPrepared_ = true end
    local ok, message = RailNetwork.SetStationChoice(station.index, 2, Train.GetS(), Train.GetActiveLength())
    if not ok and RailNetwork.GetPlayerLane(station.s) == 2 then return end
    Hud.Toast(ok and ("待避训练：" .. message .. "，请在侧线停稳")
        or ("待避训练进路未设置：" .. message .. "，请驶离岔区后再选侧线"), 4)
    hudDirty_ = true
end

-- ============================================================================
-- 初始化，兼容原main调用Init及新入口Setup
-- ============================================================================
function Game.Setup()
    stations_ = {}
    for _, station in ipairs(Route.GetStations()) do stations_[#stations_ + 1] = station end
    table.sort(stations_, function(a, b) return a.s < b.s end)
    state_, dwellTimer_, elapsed_, xp_ = STATE.DRIVING, 0, 0, 0
    lastArrival_, rewarded_, arrivalReversing_ = nil, {}, Train.IsReversing()
    serviceIndex_ = 1
    travelReversing_ = Train.IsReversing()
    overspeedWarned_, brakeWarned_ = false, false
    passingSawRed_, passingComplete_, passingPrepared_, passingApproachPrepared_ = false, false, false, false
    waitingNotified_, wrongLaneWarned_, clearanceWarned_ = false, false, false
    hudTimer_, hudDirty_, lastNotch_ = 0, true, Train.GetThrottle()
    switchPos_ = 0
    arrivalError_, initialService_, needsCorrection_ = 0, false, false
    journeyId_, completedTrips_, rewardedStops_, passengerPoints_ = 1, 0, 0, 0
    tripCompleted_, tripHadTravel_, lastPassengerPhase_ = false, false, ""
    initialDistance_ = Train.GetDistanceTravelled()
    departureBlockedSince_,lastDepartureReason_ = nil,""
    PassengerService.Reset()
    Traffic.SetService(service().id)
    local bestDist = selectNext()
    -- 生产入口从 firstStation.s+1 开始。初始站真实登乘，不作为到站发经验。
    if stopped() and not GameModes.IsRage() then
        for _, station in ipairs(stations_) do
            if Route.Distance(Train.GetS(),station.s) < G.StopTolerance then
                lastArrival_, arrivalReversing_, nextIndex_ = station, Train.IsReversing(), station.index
                state_, dwellTimer_, initialService_ = STATE.DWELL, G.DwellTime, true
                rewarded_[station.index] = true
                PassengerService.BeginStop(station,{initial=true,terminal=followingStop(station.index)==nil,
                    reversing=Train.IsReversing(),destinations=destinations(station.index)})
                Train.EmergencyBrake()
                Hud.HideBanner()
                Hud.Toast("始发候车 · "..station.name.."：乘客逐人登乘后才能发车",3)
                break
            end
        end
    end

    if GameModes.IsRage() then
        Train.SetBrake(0)
        Hud.Toast("狂暴试验场：不限速、不侧翻 · Q/E提前选道，交会与撞击触发连锁",5)
    end
    timetable_ = Timetable.new(Environment.GetClock(),stations_,timetableOptions())
    timetableCacheKey_=""
    local marks = {}
    for _, station in ipairs(stations_) do
        local pos = Route.Sample(station.s)
        marks[#marks + 1] = {x = pos.x, z = pos.z, active = false}
    end
    -- 示意图低密度采样，开放线路包含最后端点，不能在末站画回首站。
    local samples = {} ---@type CabRouteSample[]
    local count = 360
    local denominator = Route.IsClosed() and count or count - 1
    for i = 1, count do
        local pos = Route.Sample((i - 1) * Route.GetLength() / denominator)
        samples[#samples + 1] = {pos = pos}
    end
    Hud.BuildMinimap(samples, marks)
    preparePassing(false)
    local nextStation = stations_[nextIndex_ or 0]
    print(string.format("[Game] %s初始化：%s，下一站 %s，距离 %.0f m",
        Route.IsClosed() and "闭合线路" or "开放线路", service().id,
        nextStation and nextStation.name or "无（停稳换向）", bestDist))
end
function Game.Init() Game.Setup() end

-- ============================================================================
-- 固定模拟步更新：安全判定每步，HUD最多常规10Hz，操作/状态变化强制刷新。
-- ============================================================================
-- 狂暴的车站是可高速穿越的实验路标，不搬用普通客运开门/红灯联锁。
-- 玩家改变道岔与到达时间，Traffic负责从真实车流碰撞产生后续事件。
local function updateRage(dt)
    elapsed_=elapsed_+dt
    hudTimer_=hudTimer_+dt
    local reversing=Train.IsReversing()
    if reversing~=travelReversing_ then
        travelReversing_=reversing
        rewarded_={}
        journeyId_=journeyId_+1
        selectNext()
    end
    local station=stations_[nextIndex_ or 0]
    if station then
        local passed=reversing and Train.GetS()<=station.s or (not reversing and Train.GetS()>=station.s)
        if passed then
            if not rewarded_[station.index] then
                rewarded_[station.index]=true
                rewardedStops_,xp_=rewardedStops_+1,xp_+100
                Hud.Toast(station.name.."试验路标通过 · 继续选道，观察混合车流的连锁变化",2.5)
                print(string.format("[Game] 狂暴路标 %s，方向%d，位置%.1f",station.name,reversing and -1 or 1,Train.GetS()))
            end
            lastArrival_=station
            nextIndex_=followingStop(station.index,reversing)
            hudDirty_=true
        end
    end
    if not station and stopped() then hudDirty_=true end
    state_=STATE.DRIVING
    if hudDirty_ or hudTimer_>=.1 then Game.UpdateHud(hudTimer_) end
end

---@param dt number
function Game.Update(dt)
    if dt<=0 or PassengerService.IsPaused() then return end
    if GameModes.IsRage() then updateRage(dt);return end
    if timetable_ then timetable_:SyncClock(Environment.GetClock()) end
    local accident=Train.GetAccidentStatus()
    if accident.active then
        if state_~="game_over" then
            state_="game_over"
            Hud.HideBanner()
            Hud.ShowGameOver(accident.reason)
            print("[Game] 本局结束，运营奖励和客流不再推进")
        end
        Game.UpdateHud(0)
        return
    end
    elapsed_ = elapsed_ + dt
    hudTimer_ = hudTimer_ + dt
    local reversing = Train.IsReversing()
    if reversing ~= travelReversing_ then
        travelReversing_ = reversing
        if state_ == STATE.DRIVING then selectNext()
        elseif lastArrival_ and state_ ~= STATE.TERMINAL then
            PassengerService.SetDestinations(destinations(lastArrival_.index,reversing),reversing)
        end
        if reversing and service().id=="passing" then
            -- 上行没有穿越岛台的侧线；折返沿上行正常站停，不能调度逆股快车。
            serviceIndex_=1
            Traffic.SetService("local")
            Hud.Toast("上行折返使用左行正线；侧线待避训练仅下行可用",3)
        end
        passingPrepared_, passingApproachPrepared_ = false, false
        if state_~=STATE.TERMINAL then replanTimetable() end
        hudDirty_ = true
    end
    tripHadTravel_ = tripHadTravel_ or Train.GetDistanceTravelled()-initialDistance_ > G.StopTolerance*2
    PassengerService.Update(dt)
    local passengerPhase = PassengerService.GetStatus().phase
    if passengerPhase ~= lastPassengerPhase_ then lastPassengerPhase_,hudDirty_ = passengerPhase,true end
    completePassengerStop()
    if state_ == STATE.TERMINAL then
        if stopped() and lastArrival_ and PassengerService.IsReady() then
            local nextStop = followingStop(lastArrival_.index)
            if nextStop and Train.IsReversing() ~= arrivalReversing_ then
                -- 终到明确换向后开启新登乘队列，不能直接跳到牵引发车。
                if PassengerService.StartReturn(destinations(lastArrival_.index),Train.IsReversing()) then
                    rewarded_ = {[lastArrival_.index] = true}
                    journeyId_, tripCompleted_, tripHadTravel_ = journeyId_+1, false, false
                    initialDistance_ = Train.GetDistanceTravelled()
                    arrivalReversing_, initialService_ = Train.IsReversing(), true
                    passingSawRed_, passingComplete_ = false, false
                    passingPrepared_, passingApproachPrepared_ = false, false
                    state_, dwellTimer_, nextIndex_ = STATE.DWELL,G.DwellTime,lastArrival_.index
                    replanTimetable()
                    Traffic.SetService(service().id)
                    preparePassing(false)
                    Train.EmergencyBrake()
                    Hud.HideBanner()
                    Hud.Toast("折返登乘 · "..lastArrival_.name.."：新候车队列登乘后再发车",3)
                    hudDirty_ = true
                end
            end
        end
    elseif state_ == STATE.DWELL then
        if lastArrival_ and isPassingStop(lastArrival_) and not passingClearance(lastArrival_) then
            -- 安全修正期间绝不取消乘客清单或把未到门队列标为完成。
            needsCorrection_ = true
            Train.EmergencyBrake()
            if not clearanceWarned_ then
                clearanceWarned_ = true
                Hud.Toast("待避净空不足：乘客队列保留，请换回可在侧线净空段停靠的编组",4)
                hudDirty_ = true
            end
        else
            needsCorrection_ = false
            if stopped() then dwellTimer_ = math.max(0,dwellTimer_-dt) end
            if lastArrival_ and isPassingStop(lastArrival_) and Traffic.GetSignalAspect(lastArrival_.index)=="red" then
                passingSawRed_ = true
            end
            if dwellTimer_ <= 0 then Game.Depart() end
        end
    else
        preparePassing(true)
        Game.CheckArrival()
    end
    Game.EnforceDepartureInterlock()
    local departure = Game.GetDepartureStatus()
    if departure.blocked and state_ == STATE.DWELL then
        if not departureBlockedSince_ then departureBlockedSince_ = elapsed_ end
    else departureBlockedSince_ = nil end
    if departure.reason ~= lastDepartureReason_ then
        lastDepartureReason_ = departure.reason
        print(string.format("[Game] 离站条件 %s：%s（等待%.1fs，阻塞%s）",departure.reason,departure.message,
            departure.waitSeconds,departure.blockerName or "无"))
        hudDirty_ = true
    end
    if timetable_ then timetable_:Observe(timetableMotion()) end
    Game.CheckSpeedLimit()
    local notch = Train.GetThrottle()
    if notch ~= lastNotch_ then lastNotch_, hudDirty_ = notch, true end
    if hudDirty_ or hudTimer_ >= 0.1 then Game.UpdateHud(hudTimer_) end
end

function Game.CheckArrival()
    if state_ ~= STATE.DRIVING then return end
    local station = stations_[nextIndex_ or 0]
    if not station then return end
    local errorDist = Route.Distance(Train.GetS(), station.s)
    -- 需实际行驶、收油、停稳；停车误差取绝对距离，末端绝不减去线路长度。
    if errorDist < G.StopTolerance and stopped() and Train.IsMoving() then
        if isPassingStop(station) then
            if RailNetwork.GetPlayerLane(Train.GetS()) ~= 2 then
                if not wrongLaneWarned_ then
                    wrongLaneWarned_ = true
                    Hud.Toast("待避任务未完成："..station.name.."须在侧线停车；锁定进路不可在车下扳动", 4)
                    hudDirty_ = true
                end
                return
            end
            -- 必须整列驶离入站岔、且不侵入出站岔（和Traffic的80m净空同口径）。
            -- [st-320]--80m--[尾 s-L]====[头 s+16]--80m--[st+160]
            if not passingClearance(station) then
                if not clearanceWarned_ then
                    clearanceWarned_ = true
                    Hud.Toast("待避停车尚未清空岔区：请低速微调，使整列停在侧线净空段", 4)
                    hudDirty_ = true
                end
                return
            end
        end
        Game.Arrive(station, errorDist)
    end
end

---@param station RailwayStation
---@param errorDist number
function Game.Arrive(station, errorDist)
    if state_ ~= STATE.DRIVING then return end
    local target = stations_[nextIndex_ or 0]
    if not target or target.index ~= station.index then return end
    state_, dwellTimer_, lastArrival_ = STATE.DWELL, G.DwellTime, station
    if timetable_ then
        timetable_:SyncClock(Environment.GetClock())
        timetable_:Arrive(station.index,false,Train.GetS())
    end
    arrivalReversing_, arrivalError_, initialService_, needsCorrection_ = Train.IsReversing(),errorDist,false,false
    waitingNotified_, wrongLaneWarned_, clearanceWarned_ = false, false, false
    PassengerService.BeginStop(station,{initial=false,terminal=followingStop(station.index,arrivalReversing_)==nil,
        reversing=arrivalReversing_,destinations=destinations(station.index,arrivalReversing_)})
    if isPassingStop(station) then
        passingSawRed_ = Traffic.GetSignalAspect(station.index) == "red"
    end
    Train.EmergencyBrake()
    Hud.HideBanner()
    Hud.Toast("到达 "..station.name.." · 先下后上，完成乘降后结算经验",3)
    Hud.Toast(isPassingStop(station) and "侧线停稳：乘降与待避同时进行，信号开放后再发车"
        or "乘客正在乘降；完成队列、关门与最低站停后才能发车",3)
    AudioManager.AnnounceArrival(station.index)
    hudDirty_ = true
    print(string.format("[Game] %s到达%s，误差%.1fm；XP待真实乘降完成结算",service().id,station.name,errorDist))
end

--- 客运准备好只是必要条件，还须同时满足信号、最低站停和终到约束。
--- getter只读，不按调用次数推进等待；CanDepart和HUD消费同一个判定。
---@return GameDepartureStatus
function Game.GetDepartureStatus()
    if GameModes.IsRage() then
        return {blocked=false,reason="rage_free",message="狂暴自由驾驶 · 不限速 / 不侧翻 / 车门关闭",
            waitSeconds=0,dwellRemaining=0} --[[@as GameDepartureStatus]]
    end
    local result = {blocked=false,reason="ready",message="乘降完成 · 车门关闭 · 发车条件满足",
        waitSeconds=0,dwellRemaining=dwellTimer_,stationIndex=lastArrival_ and lastArrival_.index or nil}
        --[[@as GameDepartureStatus]]
    local function block(reason,message)
        result.blocked,result.reason,result.message = true,reason,message
        result.waitSeconds = departureBlockedSince_ and math.max(0,elapsed_-departureBlockedSince_) or 0
        return result
    end
    if Train.IsDerailed() then return block("accident","事故结束本局 · 请重开") end
    local passenger = PassengerService.GetStatus()
    if not passenger.ready then return block("passengers",passenger.message) end
    if state_ == STATE.TERMINAL then return block("terminal","终到全部下车 · 请停稳手动换向，再完成折返登乘") end
    if state_ == STATE.DWELL then
        if not lastArrival_ then return block("no_route","无有效停靠站") end
        if needsCorrection_ then return block("siding_clearance","侧线整列净空不足 · 未完成客运队列保留") end
        if math.abs(Train.GetSpeedMs()) > .02 then return block("not_stopped","请先停稳完成乘降") end
        if dwellTimer_ > 0 then return block("minimum_dwell","车门已关闭 · 最低站停剩余 "..math.ceil(dwellTimer_).." 秒") end
        if followingStop(lastArrival_.index,arrivalReversing_) == nil then return block("terminal","终到 · 全部下车后手动换向折返") end
    end
    local arrival = lastArrival_
    -- 只在停站状态检查发车信号；区间信号只提示，不抢玩家牵引与制动。
    if arrival and state_ == STATE.DWELL then
        if isPassingStop(arrival) and not passingClearance(arrival) then return block("siding_clearance","侧线整列未清空咽喉") end
        local signal = Traffic.GetDepartureStatus(arrival.index)
        result.signalReason,result.blockerName,result.blockerDistance = signal.signalReason,signal.blockerName,signal.blockerDistance
        result.aspect,result.passingPhase = signal.aspect,signal.passingPhase
        if signal.blocked then return block(signal.reason,signal.message.." · 请继续停稳等待") end
        if isPassingStop(arrival) and signal.passingPhase == "cancelled" then
            result.reason,result.message = "passing_cancelled","待避班次未发出，本次训练取消；实际进路开放，可离站"
        elseif isPassingStop(arrival) and not passingComplete_ and not passingSawRed_ then
            return block("passing_clearance","侧线待避 · 仍须经历红灯，等待快车通过")
        end
    end
    return result
end

---@return boolean, string
function Game.CanDepart()
    local status = Game.GetDepartureStatus()
    return not status.blocked,status.message
end

--- 必须在每个生产 Train.Update 前立即调用，不能只在更新后拦截。
--- 不改 Train，不仅信任 Game.ThrottleUp：直接 Train.SetThrottle 同样强制收油制动。
---@return boolean, string
function Game.EnforceDepartureInterlock()
    if GameModes.IsRage() then return true,"狂暴自由驾驶" end
    if Train.IsDerailed() then return false,"事故结束本局" end
    PassengerService.RefreshDoorPlan()
    local allowed, message = Game.CanDepart()
    if not allowed or state_ ~= STATE.DRIVING then
        Train.EmergencyBrake()
        if allowed then return false,"发车准备尚未提交 · 请等待下一运营步" end
    end
    return allowed, message
end

--- 到站后只松开制动，不自动牵引；终到保持制动等待手动换向。
function Game.Depart()
    if state_ ~= STATE.DWELL or not lastArrival_ or dwellTimer_ > 0 or not stopped()
        or not PassengerService.IsReady() then return end
    local terminalArrival = followingStop(lastArrival_.index, arrivalReversing_) == nil
    local nextStop = followingStop(lastArrival_.index)
    if terminalArrival then
        state_, nextIndex_ = STATE.TERMINAL, nil
        Train.EmergencyBrake()
        Hud.HideBanner()
        Hud.Toast(lastArrival_.name.."终到：全部下车后请停稳手动换向折返",4)
        hudDirty_ = true
        return
    end
    if not nextStop then
        selectNext()
        nextStop = nextIndex_
        if not nextStop then return end
    end
    local signal = Traffic.GetDepartureStatus(lastArrival_.index)
    local permitted = not signal.blocked
    local passingCancelled = signal.passingPhase == "cancelled"
    local passingReady = not isPassingStop(lastArrival_) or passingCancelled or (passingSawRed_ and permitted)
    if not permitted or not passingReady then
        Train.EmergencyBrake()
        if not waitingNotified_ then
            waitingNotified_ = true
            Hud.Toast(isPassingStop(lastArrival_) and "侧线待避：继续停稳，等快车通过、信号放行"
                or "发车信号未开放，请继续停稳等待", 4)
            hudDirty_ = true
        end
        return
    end
    if isPassingStop(lastArrival_) and not passingCancelled then
        passingComplete_ = true
        print("[Game] "..lastArrival_.name.."侧线待避完成：停稳经历红灯，快车通过后信号放行")
    elseif isPassingStop(lastArrival_) then
        Hud.Toast("本次待避班次无法安全发出，训练已取消；按实际开放进路离站，不计待避完成",4)
        print("[Game] 待避班次未发出：本次训练取消，未标完成；真实发车进路开放")
    end
    local allowed = Game.CanDepart()
    if not allowed then Train.EmergencyBrake(); return end
    if not PassengerService.FinishStop() then return end
    state_, nextIndex_ = STATE.DRIVING, nextStop
    Train.SetBrake(0)
    Hud.HideBanner()
    overspeedWarned_, brakeWarned_, waitingNotified_ = false, false, false
    local station = assert(stations_[nextStop])
    Hud.Toast("发车，下一站 " .. station.name .. "；请手动牵引", 3)
    AudioManager.AnnounceDeparture(station.index)
    hudDirty_ = true
    print("[Game] 发车，下一站 " .. station.name)
end

-- ============================================================================
-- 限速：车型/线路/曲线/站场/必停站/物理终端与Traffic信号占用取最小值。
-- ============================================================================
function Game.GetSpeedLimit()
    if GameModes.IsRage() then return 1e9,"不限速" end
    local station = stations_[nextIndex_ or 0]
    local limit, reason = SpeedPolicy.Calculate({
        s = Train.GetS(), length = Route.GetLength(), closed = Route.IsClosed(),
        activeLength = Train.GetActiveLength(),
        operatingKmh = Train.GetOperatingSpeedKmh(), lineKmh = G.SpeedLimitKmh,
        deceleration = Train.GetServiceDeceleration(true), reversing = Train.IsReversing(),
        segments = Route.GetSegments(), stations = stations_,
        nextStopS = station and station.s or nil, dwelling = state_ ~= STATE.DRIVING,
        stationKmh = G.StationSpeedKmh, reactionSeconds = G.BrakeReactionSeconds,
    })
    local trafficLimit, trafficReason = Traffic.GetSpeedConstraint()
    if trafficLimit ~= nil and trafficLimit < limit then
        return math.max(0, trafficLimit), trafficReason or "信号防护"
    end
    return limit, reason
end

function Game.CheckSpeedLimit()
    if GameModes.IsRage() then return end
    local speed = math.abs(Train.GetSpeedKmh())
    local limit, reason = Game.GetSpeedLimit()
    if speed > limit + 5 then
        if not overspeedWarned_ then
            overspeedWarned_ = true
            Hud.Toast(reason .. "限速 " .. math.floor(limit) .. " km/h，请收油制动", 3)
            hudDirty_ = true
        end
    else overspeedWarned_ = false end
    local station = stations_[nextIndex_ or 0]
    if station and state_ == STATE.DRIVING then
        local distance = distanceAhead(station.s)
        local velocity = speed / 3.6
        local brakingDistance = velocity * velocity / (2 * math.max(0.1, Train.GetServiceDeceleration(true)))
            + velocity * G.BrakeReactionSeconds + 100
        if distance ~= math.huge and speed > 30 and distance <= brakingDistance and not brakeWarned_ then
            brakeWarned_ = true
            Hud.Toast("准备进站：收油并制动，剩余 " .. math.floor(distance) .. " m", 3)
            hudDirty_ = true
        elseif distance > brakingDistance + 200 then brakeWarned_ = false end
    end
end

-- ============================================================================
-- HUD：常规调用由Update限流；main换车/操作可用UpdateHud(0)立即同步。
-- ============================================================================
---@param dt number
function Game.UpdateHud(dt)
    if not GameModes.IsRage() then PassengerService.RefreshDoorPlan() end
    Hud.SetGameMode(GameModes.GetId())
    if GameModes.IsRage() then Hud.SetRageStats(Traffic.GetRageStats()) end
    local station = stations_[nextIndex_ or 0]
    if state_=="game_over" then
        Hud.SetStationName("本局结束")
        Hud.SetNextStation("脱轨事故")
    elseif state_ == STATE.TERMINAL then
        Hud.SetStationName(lastArrival_ and lastArrival_.name or "线路终端")
        Hud.SetNextStation("终到·手动换向")
    elseif station then
        Hud.SetStationName(station.name)
        local distance = distanceAhead(station.s)
        if GameModes.IsRage() then
            Hud.SetNextStation(distance>1000 and string.format("路标 %.1f km",distance/1000)
                or string.format("路标 %d m",math.floor(distance)))
        elseif state_ == STATE.DWELL then Hud.SetNextStation("停靠中")
        elseif distance == math.huge then Hud.SetNextStation("已越站·换向修正")
        elseif distance > 1000 then Hud.SetNextStation(string.format("%.1f km", distance / 1000))
        else Hud.SetNextStation(string.format("%d m", math.floor(distance))) end
    else
        Hud.SetStationName("前方无待停站")
        Hud.SetNextStation("停稳换向折返")
    end
    Hud.SetSpeedRange(Train.GetMaxSpeedKmh())
    Hud.SetSpeed(Train.GetSpeedKmh(), Game.GetSpeedLimit())
    Hud.SetReversing(Train.IsReversing())
    Hud.SetThrottle(Train.GetThrottle(), GameConfig.Train.MaxThrottle)
    Hud.SetBrake(Train.GetBrake())
    Hud.SetTime(elapsed_)
    Hud.SetXp(xp_)
    Hud.SetSwitch(switchPos_)
    Hud.SetDrivingMode(Train.GetDrivingMode() == "simulation" and "模拟驾驶" or "休闲驾驶")
    -- 不改Traffic的缓存快照：运营objective由Game拥有并覆盖。
    local railwayStatus = {}
    for key, value in pairs(Traffic.GetStatus()) do railwayStatus[key] = value end
    railwayStatus.objective = Game.GetObjective()
    local accident=Train.GetAccidentStatus()
    if not accident.active and accident.risk>=.55 then
        railwayStatus.text=string.format("弯道侧向负荷 %.0f%% · 自主控制，持续过载会脱轨",accident.risk*100)
    end
    Hud.SetRailwayStatus(railwayStatus)
    Hud.SetServiceName(Game.GetServiceName())
    Hud.SetPassengerStatus(Game.GetPassengerStatus())
    Hud.SetTimetable(Game.GetTimetableStatus())
    Hud.Update(dt)
    local pos = Route.Sample(Train.GetS())
    local active = state_ == STATE.DWELL and nextIndex_ or nil
    Hud.SetMinimapTrain(pos.x, pos.z, active)
    hudTimer_, hudDirty_ = 0, false
end

-- ============================================================================
-- 操作接口（不重置Train、站序、经验或选择器状态）
-- ============================================================================
function Game.ThrottleUp()
    local allowed, message = Game.CanDepart()
    if not allowed or state_ ~= STATE.DRIVING then
        Game.EnforceDepartureInterlock()
        Hud.Toast(message,2)
        hudDirty_ = true
        return false, message
    end
    local notch = Train.ThrottleUp()
    if notch > 0 then Hud.Toast("油门 " .. notch .. " 档", 1) end
    hudDirty_ = true
end
function Game.ThrottleDown()
    if state_ ~= STATE.DRIVING then return end
    Train.ThrottleDown()
    hudDirty_ = true
end
---@param strength number?
function Game.Brake(strength)
    if state_ ~= STATE.DRIVING then return end
    Train.AddBrake(strength or 0.2)
    if Train.GetThrottle() > 0 then Train.SetThrottle(0) end
    hudDirty_ = true
end
function Game.EmergencyBrake()
    if Train.IsDerailed() then return end
    Train.EmergencyBrake()
    Hud.Toast("紧急制动!", 2)
    AudioManager.PlayBrake(1)
    hudDirty_ = true
end
function Game.Horn()
    Hud.Toast(AudioManager.PlayHorn() and "呜——" or "呜——（未找到汽笛音效）", 1.2)
end
---@param dir number
---@return boolean, string
function Game.SetSwitch(dir)
    if Train.IsDerailed() then return false,"事故结束本局 · 请重开" end
    local ok, message = RailNetwork.SetPlayerChoice(dir, Train.GetS(), Train.GetActiveLength(), Train.IsReversing())
    if ok then switchPos_ = dir > 0 and 1 or -1 end
    Hud.Toast(message, ok and 2.5 or 3)
    hudDirty_ = true
    Game.UpdateHud(0)
    return ok, message
end
---@return boolean, string
function Game.ToggleDrivingMode()
    if GameModes.IsRage() then return false,"狂暴模式使用独立街机牵引；普通模式可选休闲/模拟驾驶" end
    if Train.IsDerailed() then return false,"事故结束本局 · 请重开" end
    if not stopped() then
        local message = "请先收油停稳，再切换驾驶模式"
        Hud.Toast(message, 2)
        return false, message
    end
    local mode = Train.GetDrivingMode() == "relaxed" and "simulation" or "relaxed"
    Train.SetDrivingMode(mode)
    local name = mode == "simulation" and "模拟驾驶" or "休闲驾驶"
    Hud.SetDrivingMode(name)
    Hud.Toast("已切换：" .. name .. "；位置、站序和经验保留", 2.5)
    Game.UpdateHud(0)
    return true, name
end
---@param id string
---@return boolean, string
function Game.SetService(id)
    if GameModes.IsRage() then return false,"狂暴试验场为自由驾驶，不启用客运任务" end
    if Train.IsDerailed() then return false,"事故结束本局 · 请重开" end
    if not stopped() then
        local message = "请先收油停稳，再选择运营任务"
        Hud.Toast(message, 2)
        return false, message
    end
    local selected = nil ---@type integer?
    for i, item in ipairs(SERVICES) do if item.id == id then selected = i; break end end
    if not selected then return false, "未知运营任务：" .. tostring(id) end
    if id=="passing" and Train.IsReversing() then return false,"侧线待避仅下行可用，上行不能横穿双线岛台" end
    if selected == serviceIndex_ then return true, service().id end
    serviceIndex_ = selected
    passingSawRed_, passingComplete_, passingPrepared_, passingApproachPrepared_ = false, false, false, false
    waitingNotified_, wrongLaneWarned_, clearanceWarned_ = false, false, false
    Traffic.SetService(service().id)
    -- 已停靠站的站停时间和奖励锁存继续保留，绝不通过任务切换跳过站停。
    if state_ == STATE.DRIVING then selectNext() end
    local arrival = lastArrival_
    if state_ == STATE.DWELL and arrival and isPassingStop(arrival) then
        needsCorrection_ = not passingClearance(arrival)
        passingSawRed_ = Traffic.GetSignalAspect(arrival.index) == "red"
    end
    if arrival and state_ ~= STATE.TERMINAL then
        PassengerService.SetDestinations(destinations(arrival.index),Train.IsReversing())
    end
    replanTimetable()
    Hud.Toast("任务：" .. service().name .. "；" .. service().description, 4)
    preparePassing(false)
    Game.UpdateHud(0)
    print("[Game] 切换运营任务：" .. service().id .. "，保留站序/经验/位置")
    return true, service().id
end

---@return boolean, string
function Game.CycleService()
    return Game.SetService(assert(SERVICES[serviceIndex_ % #SERVICES + 1]).id)
end
---@return RailwayService[]
function Game.GetServices()
    local result = {} ---@type RailwayService[]
    for _, item in ipairs(SERVICES) do
        result[#result + 1] = {id = item.id, name = item.name, description = item.description}
    end
    return result
end
function Game.GetService() return service().id end
function Game.GetServiceId() return service().id end
function Game.GetServiceName() return GameModes.IsRage() and "狂暴试验场" or service().name end
function Game.GetObjective()
    if GameModes.IsRage() then
        if not Route.IsClosed() and (Train.GetS()<=Train.GetActiveLength()+21 or Train.GetS()>=Route.GetLength()-21) then
            return "轨道尽头安全缓冲 · 收油停稳后按 R 换向，继续连锁试验"
        end
        return "Q/E提前选道 → 改变交会 → 撞击传播；车流互动涌现不同连锁，不限速、不侧翻"
    end
    if Train.IsDerailed() then return "脱轨事故 · 本局结束，重开旅程后恢复运营" end
    if state_ == STATE.TERMINAL then
        return (lastArrival_ and lastArrival_.name or "线路") .. "终到；停稳手动换向折返"
    end
    local station = stations_[nextIndex_ or 0]
    local arrival = lastArrival_
    if state_ == STATE.DWELL and arrival and isPassingStop(arrival) then
        local departure = Game.GetDepartureStatus()
        if departure.passingPhase == "cancelled" then
            return "本次待避班次未发出，训练取消；"..(departure.blocked and departure.message or "按实际开放进路离站")
        end
        if not passingSawRed_ or not signalOpen(arrival.index) then
            return arrival.name.."侧线待避：保持停稳，等快车通过、信号放行"
        end
        return "待避信号已开放；完成站停后手动牵引发车"
    end
    if service().id == "passing" and not passingComplete_ then
        local training = stations_[3]
        if training and distanceAhead(training.s) < math.huge then
            return "待避训练："..training.name.."选侧线停稳，等快车通过；当前下一站 "..(station and station.name or "无")
        end
    end
    if state_ == STATE.DWELL then return Game.GetPassengerStatus().message end
    if not station then return "前方无待停站；请停稳后手动换向折返" end
    if distanceAhead(station.s) == math.huge then return station.name .. "已越站；停稳换向修正，不能环回接站" end
    return service().name .. "：" .. (Train.IsReversing() and "折返" or "前往") .. station.name
end
function Game.GetPassengerStatus()
    local status = PassengerService.GetStatus()
    if GameModes.IsRage() then
        status.ready,status.doorsOpen,status.dwellRemaining=true,false,0
        status.message="封闭试验场 · 空载自由驾驶 / 无强制站停"
        return status
    end
    local allowed, message = Game.CanDepart()
    status.ready = allowed
    if not allowed then status.message = message end
    status.dwellRemaining = dwellTimer_
    return status
end
function Game.GetAnnouncementState()
    return {state=state_,nextIndex=nextIndex_,lastArrival=lastArrival_ and lastArrival_.index or nil,
        initialService=initialService_,service=service().id,journeyId=journeyId_}
end
function Game.GetOperatingStats()
    local passengers = PassengerService.GetStats()
    return {journeyId=journeyId_,completedTrips=completedTrips_,rewards=rewardedStops_,xp=xp_,
        passengerPoints=passengerPoints_,boarded=passengers.boarded,alighted=passengers.alighted,
        onboard=passengers.onboard,comfort=passengers.comfort,comfortPenalty=passengers.comfortPenalty,
        initialService=initialService_,tripCompleted=tripCompleted_,service=service().id,
        elapsed=elapsed_,distance=Train.GetDistanceTravelled()}
end
function Game.IsTerminal() return state_ == STATE.TERMINAL end
function Game.IsDwelling() return state_ ~= STATE.DRIVING end
function Game.GetXp() return xp_ end
function Game.GetElapsed() return elapsed_ end
function Game.GetNextStation() return stations_[nextIndex_ or 0] end
---@return number
function Game.GetNearestStationDistance()
    local best = math.huge
    for _, station in ipairs(stations_) do best = math.min(best, Route.Distance(Train.GetS(), station.s)) end
    return best
end
--- Display prediction uses a copied model so a read/HUD refresh cannot advance or rewrite plans.
function Game.GetTimetableStatus()
    if GameModes.IsRage() then return nil end
    if not timetable_ then return nil end
    local clock=Environment.GetClock()
    local departure=Game.GetDepartureStatus()
    local key=table.concat({state_,serviceIndex_,journeyId_,tostring(Train.IsReversing()),Train.GetSelectedId(),
        clock.revision,tostring(clock.running),tostring(clock.paused),departure.reason,
        tostring(nextIndex_),tostring(lastArrival_ and lastArrival_.index),tostring(PassengerService.IsReady())},"|")
    if key~=timetableCacheKey_ or elapsed_-timetableCacheElapsed_>=1
        or math.abs(clock.minutes-timetableCacheMinutes_)>=1 or math.abs(Train.GetS()-timetableCacheS_)>250 then
        timetableCache_=timetable_:Preview(clock,timetableMotion())
        timetableCacheKey_,timetableCacheElapsed_=key,elapsed_
        timetableCacheMinutes_,timetableCacheS_=clock.minutes,Train.GetS()
    end
    return timetableCache_
end
function Game.ValidateTimetableState(data)
    if type(data)~="table" then return false,"运营存档不是对象" end
    return Timetable.ValidateSnapshot(data.timetable)
end
function Game.ExportState()
    if timetable_ then timetable_:SyncClock(Environment.GetClock()) end
    local rewarded={}
    for index,value in pairs(rewarded_) do if value then rewarded[#rewarded+1]=index end end
    return {mode=GameModes.GetId(),rageStats=GameModes.IsRage() and Traffic.ExportRageState() or nil,
        serviceIndex=serviceIndex_,state=state_,nextIndex=nextIndex_,dwellTimer=dwellTimer_,elapsed=elapsed_,xp=xp_,
        travelReversing=travelReversing_,lastArrival=lastArrival_ and lastArrival_.index or nil,
        arrivalReversing=arrivalReversing_,rewarded=rewarded,passingSawRed=passingSawRed_,passingComplete=passingComplete_,
        passingPrepared=passingPrepared_,passingApproachPrepared=passingApproachPrepared_,arrivalError=arrivalError_,
        initialService=initialService_,needsCorrection=needsCorrection_,journeyId=journeyId_,completedTrips=completedTrips_,
        rewardedStops=rewardedStops_,passengerPoints=passengerPoints_,tripCompleted=tripCompleted_,tripHadTravel=tripHadTravel_,
        initialDistance=initialDistance_,timetable=not GameModes.IsRage() and timetable_ and timetable_:Export() or nil}
end
-- 地图版本迁移只接续累计值，不恢复旧坐标、站序奖励或旧线路时刻表。
---@param data table?
function Game.RestoreRouteProgress(data)
    if type(data)~="table" then return false end
    local function count(value)
        local n=tonumber(value) or 0
        return n==n and n<math.huge and math.max(0,math.floor(n)) or 0
    end
    xp_,elapsed_=count(data.xp),count(data.elapsed)
    completedTrips_,rewardedStops_=count(data.completedTrips),count(data.rewardedStops)
    passengerPoints_=count(data.passengerPoints)
    if GameModes.IsRage() and data.rageStats then
        assert(Traffic.RestoreRageState(data.rageStats),"旧狂暴累计成绩无效，原档保留")
    end
    hudDirty_=true
    print(string.format("[Game] 新地图接续累计 XP=%d / 驾驶秒=%d；旧站序与进路不套用",xp_,elapsed_))
    return true
end

-- 兼容既有狂暴迁移与验收入口，新普通线路使用同一累计值迁移规则。
function Game.RestoreMountainProgress(data)
    return GameModes.IsRage() and Game.RestoreRouteProgress(data) or false
end

function Game.RestoreState(data)
    assert(type(data)=="table" and (data.mode or "normal")==GameModes.GetId(),"运营存档模式与地图不一致")
    local validTimetable,message=Game.ValidateTimetableState(data)
    assert(validTimetable,message)
    if data.timetable then
        local matches,reason=Timetable.Validate(data.timetable,stations_)
        assert(matches,reason)
    end
    assert(type(data)=="table" and type(data.rewarded)=="table","运营存档不完整")
    assert(data.state==STATE.DRIVING or data.state==STATE.DWELL or data.state==STATE.TERMINAL or data.state=="game_over","运营状态无效")
    assert(SERVICES[data.serviceIndex] and data.xp>=0 and data.elapsed>=0,"运营数值无效")
    serviceIndex_,state_,nextIndex_=data.serviceIndex,data.state,data.nextIndex
    dwellTimer_,elapsed_,xp_=data.dwellTimer,data.elapsed,data.xp
    travelReversing_,arrivalReversing_=data.travelReversing,data.arrivalReversing
    lastArrival_=data.lastArrival and assert(stations_[data.lastArrival]) or nil
    rewarded_={}
    for _,index in ipairs(data.rewarded) do rewarded_[index]=true end
    passingSawRed_,passingComplete_=data.passingSawRed,data.passingComplete
    passingPrepared_,passingApproachPrepared_=data.passingPrepared,data.passingApproachPrepared
    arrivalError_,initialService_,needsCorrection_=data.arrivalError,data.initialService,data.needsCorrection
    journeyId_,completedTrips_,rewardedStops_,passengerPoints_=data.journeyId,data.completedTrips,data.rewardedStops,data.passengerPoints
    tripCompleted_,tripHadTravel_,initialDistance_=data.tripCompleted,data.tripHadTravel,data.initialDistance
    timetable_=Timetable.new(Environment.GetClock(),stations_,timetableOptions())
    timetableCacheKey_=""
    if data.timetable then
        assert(timetable_:Restore(data.timetable))
        timetable_:SyncClock(Environment.GetClock())
    else
        timetable_.migrated=true
        timetable_.notice="旧档接续 · 从当前世界时刻编排，历史实际未记录"
    end
    departureBlockedSince_,lastDepartureReason_ = nil,""
    Traffic.SetService(service().id)
    if GameModes.IsRage() then
        assert(Traffic.RestoreRageState(data.rageStats))
        state_,dwellTimer_=STATE.DRIVING,0
    end
    hudDirty_=true
    Game.EnforceDepartureInterlock()
    Game.UpdateHud(0)
    if state_=="game_over" then Hud.ShowGameOver(Train.GetAccidentStatus().reason) end
end
return Game