-- ============================================================================
-- Game - 开放线路运营（方向站序 / 到站奖励 / 服务任务 / 安全速度）
-- Traffic依赖Train/Route/RailNetwork，不反向依赖Game；本模块只消费其权威状态。
-- ============================================================================
local GameConfig = require "config.GameConfig"
local Route = require "world.Route"
local RailNetwork = require "world.RailNetwork"
local Train = require "train.Train"
local Traffic = require "game.Traffic"
local Hud = require "ui.Hud"
local AudioManager = require "audio.AudioManager"
local SpeedPolicy = require "game.SpeedPolicy"
local PassengerService = require "game.PassengerService"

local Game = {}
local G = GameConfig.Gameplay
local STATE = { DRIVING = "driving", DWELL = "dwell", TERMINAL = "terminal" }
---@class RailwayService
---@field id string
---@field name string
---@field description string
---@type RailwayService[]
local SERVICES = {
    {id = "local", name = "站站停", description = "依次停靠五站，终到后手动换向折返"},
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
    PassengerService.Reset()
    Traffic.SetService(service().id)
    local bestDist = selectNext()
    -- 生产入口从 firstStation.s+1 开始。初始站真实登乘，不作为到站发经验。
    if stopped() then
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
---@param dt number
function Game.Update(dt)
    if dt<=0 or PassengerService.IsPaused() then return end
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
        passingPrepared_, passingApproachPrepared_ = false, false
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
---@return boolean, string
function Game.CanDepart()
    if Train.IsDerailed() then return false,"事故结束本局 · 请重开" end
    local passenger = PassengerService.GetStatus()
    if not passenger.ready then return false, passenger.message end
    if state_ == STATE.TERMINAL then return false,"终到全部下车 · 请停稳手动换向，再完成折返登乘" end
    if state_ == STATE.DWELL then
        if not lastArrival_ then return false,"无有效停靠站" end
        if needsCorrection_ then return false,"侧线整列净空不足 · 未完成客运队列保留" end
        if math.abs(Train.GetSpeedMs()) > .02 then return false,"请先停稳完成乘降" end
        if dwellTimer_ > 0 then return false,"车门已关闭 · 最低站停剩余 "..math.ceil(dwellTimer_).." 秒" end
        if followingStop(lastArrival_.index,arrivalReversing_) == nil then return false,"终到 · 全部下车后手动换向折返" end
    end
    local arrival = lastArrival_
    -- 只在停站状态检查发车信号；区间信号只提示，不抢玩家牵引与制动。
    if arrival and state_ == STATE.DWELL then
        if isPassingStop(arrival) and not passingClearance(arrival) then return false,"侧线整列未清空咽喉" end
        if not signalOpen(arrival.index) then return false,"发车信号未开放 · 请继续停稳等待" end
        if isPassingStop(arrival) and not passingComplete_ and not passingSawRed_ then
            return false,"侧线待避 · 仍须经历红灯，等待快车通过"
        end
    end
    return true,"乘降完成 · 车门关闭 · 发车条件满足"
end

--- 必须在每个生产 Train.Update 前立即调用，不能只在更新后拦截。
--- 不改 Train，不仅信任 Game.ThrottleUp：直接 Train.SetThrottle 同样强制收油制动。
---@return boolean, string
function Game.EnforceDepartureInterlock()
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
    local permitted = signalOpen(lastArrival_.index)
    local passingReady = not isPassingStop(lastArrival_) or (passingSawRed_ and permitted)
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
    if isPassingStop(lastArrival_) then
        passingComplete_ = true
        print("[Game] "..lastArrival_.name.."侧线待避完成：停稳经历红灯，快车通过后信号放行")
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
    local station = stations_[nextIndex_ or 0]
    local limit, reason = SpeedPolicy.Calculate({
        s = Train.GetS(), length = Route.GetLength(), closed = Route.IsClosed(),
        activeLength = Train.GetActiveLength(),
        operatingKmh = Train.GetOperatingSpeedKmh(), lineKmh = G.SpeedLimitKmh,
        deceleration = Train.GetServiceDeceleration(), reversing = Train.IsReversing(),
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
        local brakingDistance = velocity * velocity / (2 * math.max(0.1, Train.GetServiceDeceleration()))
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
    PassengerService.RefreshDoorPlan()
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
        if state_ == STATE.DWELL then Hud.SetNextStation("停靠中")
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
    if Train.IsDerailed() then return false,"事故结束本局 · 请重开" end
    if not stopped() then
        local message = "请先收油停稳，再选择运营任务"
        Hud.Toast(message, 2)
        return false, message
    end
    local selected = nil ---@type integer?
    for i, item in ipairs(SERVICES) do if item.id == id then selected = i; break end end
    if not selected then return false, "未知运营任务：" .. tostring(id) end
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
function Game.GetServiceName() return service().name end
function Game.GetObjective()
    if Train.IsDerailed() then return "脱轨事故 · 本局结束，重开旅程后恢复运营" end
    if state_ == STATE.TERMINAL then
        return (lastArrival_ and lastArrival_.name or "线路") .. "终到；停稳手动换向折返"
    end
    local station = stations_[nextIndex_ or 0]
    local arrival = lastArrival_
    if state_ == STATE.DWELL and arrival and isPassingStop(arrival) then
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
    local allowed, message = Game.CanDepart()
    status.ready = allowed
    if not allowed then status.message = message end
    status.dwellRemaining = dwellTimer_
    return status
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
function Game.ExportState()
    local rewarded={}
    for index,value in pairs(rewarded_) do if value then rewarded[#rewarded+1]=index end end
    return {serviceIndex=serviceIndex_,state=state_,nextIndex=nextIndex_,dwellTimer=dwellTimer_,elapsed=elapsed_,xp=xp_,
        travelReversing=travelReversing_,lastArrival=lastArrival_ and lastArrival_.index or nil,
        arrivalReversing=arrivalReversing_,rewarded=rewarded,passingSawRed=passingSawRed_,passingComplete=passingComplete_,
        passingPrepared=passingPrepared_,passingApproachPrepared=passingApproachPrepared_,arrivalError=arrivalError_,
        initialService=initialService_,needsCorrection=needsCorrection_,journeyId=journeyId_,completedTrips=completedTrips_,
        rewardedStops=rewardedStops_,passengerPoints=passengerPoints_,tripCompleted=tripCompleted_,tripHadTravel=tripHadTravel_,
        initialDistance=initialDistance_}
end
function Game.RestoreState(data)
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
    Traffic.SetService(service().id)
    hudDirty_=true
    Game.EnforceDepartureInterlock()
    Game.UpdateHud(0)
    if state_=="game_over" then Hud.ShowGameOver(Train.GetAccidentStatus().reason) end
end
return Game