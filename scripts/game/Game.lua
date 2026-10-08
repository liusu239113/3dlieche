-- ============================================================================
-- Game - 玩法逻辑（到站判定 / 经验 / 播报 / 状态机）
-- ============================================================================

local GameConfig = require "config.GameConfig"
local Route = require "world.Route"
local Train = require "train.Train"
local Hud = require "ui.Hud"
local AudioManager = require "audio.AudioManager"
local SpeedPolicy = require "game.SpeedPolicy"

local Game = {}

local G = GameConfig.Gameplay

local STATE = {
    DRIVING = "driving",
    DWELL = "dwell",
}

local state_ = STATE.DRIVING
local stations_ = {}        -- { name, s, index }
local nextIndex_ = 1        -- 下一个待停靠站（stations_ 下标）
local dwellTimer_ = 0
local elapsed_ = 0
local xp_ = 0
local overspeedWarned_ = false
local travelReversing_ = false
local brakeWarned_ = false
local switchPos_ = 0.0
local lastArrival_ = nil

-- ============================================================================
-- 初始化
-- ============================================================================

function Game.Init()
    stations_ = Route.GetStations()
    table.sort(stations_, function(a, b) return a.s < b.s end)

    -- 找到列车前方第一个站
    local s = Train.GetS()
    nextIndex_ = 1
    local bestDist = math.huge
    for i, st in ipairs(stations_) do
        local d = Train.IsReversing() and Route.ForwardDistance(st.s, s)
            or Route.ForwardDistance(s, st.s)
        if d < bestDist then
            bestDist = d
            nextIndex_ = i
        end
    end

    state_ = STATE.DRIVING
    dwellTimer_ = 0
    elapsed_ = 0
    xp_ = 0
    travelReversing_ = Train.IsReversing()
    overspeedWarned_, brakeWarned_ = false, false

    -- 小地图数据
    local marks = {}
    for _, st in ipairs(stations_) do
        local pos = Route.Sample(st.s)
        marks[#marks + 1] = { x = pos.x, z = pos.z, active = false }
    end
    -- 小地图独立低密度采样，线路延长不复制十万米级路线点。
    local samples = {} ---@type CabRouteSample[]
    local count = 360
    for i = 1, count do
        local pos = Route.Sample((i - 1) * Route.GetLength() / count)
        samples[#samples + 1] = { pos = pos }
    end
    Hud.BuildMinimap(samples, marks)

    print(string.format("[Game] 初始化完成, 下一站: %s (距离 %.0f 米)",
        stations_[nextIndex_].name,
        Route.ForwardDistance(Train.GetS(), stations_[nextIndex_].s)))
end

-- ============================================================================
-- 每帧更新
-- ============================================================================

---@param dt number
function Game.Update(dt)
    elapsed_ = elapsed_ + dt
    local reversing = Train.IsReversing()
    if state_ ~= STATE.DWELL and reversing ~= travelReversing_ then
        travelReversing_ = reversing
        local best = math.huge
        for i, station in ipairs(stations_) do
            local distance = reversing and Route.ForwardDistance(station.s, Train.GetS())
                or Route.ForwardDistance(Train.GetS(), station.s)
            if distance < best then best, nextIndex_ = distance, i end
        end
        overspeedWarned_, brakeWarned_ = false, false
    end

    if state_ == STATE.DWELL then
        dwellTimer_ = dwellTimer_ - dt
        if dwellTimer_ <= 0 then
            Game.Depart()
        end
    else
        Game.CheckArrival()
        Game.CheckSpeedLimit()
    end

    Game.UpdateHud(dt)
end

-- ---------------------------------------------------------------------------
-- 到站判定
-- ---------------------------------------------------------------------------
function Game.CheckArrival()
    if #stations_ == 0 then return end
    local st = stations_[nextIndex_]
    if not st then return end

    local s = Train.GetS()
    local dist = Route.ForwardDistance(s, st.s)
    local errorDist = math.min(dist, Route.GetLength() - dist)
    local stopped = math.abs(Train.GetSpeedMs()) <= 0.02

    -- 容差同时覆盖停车点前后；需实际行驶、收油并停稳，不能推油门即接站。
    if errorDist < G.StopTolerance and stopped and Train.GetThrottle() == 0 and Train.IsMoving() then
        Game.Arrive(st, errorDist)
    end
end

---@param st table
---@param errorDist number
function Game.Arrive(st, errorDist)
    state_ = STATE.DWELL
    dwellTimer_ = G.DwellTime
    lastArrival_ = st

    -- 经验：基础 + 精准停车奖励
    local gained = G.XpPerStation
    local precise = errorDist < G.StopTolerance * 0.35
    if precise then gained = gained + G.XpSpeedBonus end
    xp_ = xp_ + gained

    -- 停稳
    Train.EmergencyBrake()

    Hud.ShowBanner("到达 " .. st.name, precise and "精准停车  +" .. gained .. " 经验"
        or ("停车 +" .. gained .. " 经验"))
    Hud.Toast("停稳中… " .. G.DwellTime .. " 秒后发车", 3.0)
    AudioManager.AnnounceArrival(st.index)

    print(string.format("[Game] 到达 %s, 停车误差 %.1f 米, 经验 +%d (总计 %d)",
        st.name, errorDist, gained, xp_))
end

--- 发车
function Game.Depart()
    state_ = STATE.DRIVING
    Train.SetBrake(0.0)
    Hud.HideBanner()

    -- 下一个站
    nextIndex_ = (nextIndex_ - 1 + (Train.IsReversing() and -1 or 1)) % #stations_ + 1
    travelReversing_ = Train.IsReversing()
    overspeedWarned_, brakeWarned_ = false, false

    local nxt = stations_[nextIndex_]
    Hud.SetStationName(stations_[nextIndex_].name)
    Hud.Toast("发车，下一站 " .. nxt.name, 3.0)
    AudioManager.AnnounceDeparture(nxt.index)
    print("[Game] 发车, 下一站 " .. nxt.name)
end

-- ---------------------------------------------------------------------------
-- 限速
-- ---------------------------------------------------------------------------
function Game.GetSpeedLimit()
    local station = stations_[nextIndex_]
    return SpeedPolicy.Calculate({
        s = Train.GetS(), length = Route.GetLength(),
        operatingKmh = Train.GetOperatingSpeedKmh(), lineKmh = G.SpeedLimitKmh,
        deceleration = Train.GetServiceDeceleration(), reversing = Train.IsReversing(),
        segments = Route.GetSegments(), stations = stations_,
        nextStopS = station and station.s or nil, dwelling = state_ == STATE.DWELL,
        stationKmh = G.StationSpeedKmh, reactionSeconds = G.BrakeReactionSeconds,
    })
end

function Game.CheckSpeedLimit()
    local speed = math.abs(Train.GetSpeedKmh())
    local limit, reason = Game.GetSpeedLimit()
    if speed > limit + 5.0 then
        if not overspeedWarned_ then
            overspeedWarned_ = true
            Hud.Toast(reason .. "限速 " .. limit .. " km/h，请收油制动", 3.0)
        end
    else
        overspeedWarned_ = false
    end
    local station = stations_[nextIndex_]
    if station then
        local distance = Train.IsReversing() and Route.ForwardDistance(station.s, Train.GetS())
            or Route.ForwardDistance(Train.GetS(), station.s)
        local velocity = speed / 3.6
        local brakingDistance = velocity * velocity / (2 * Train.GetServiceDeceleration())
            + velocity * G.BrakeReactionSeconds + 100
        if speed > 30 and distance <= brakingDistance and not brakeWarned_ then
            brakeWarned_ = true
            Hud.Toast("准备进站：收油并制动，剩余 " .. math.floor(distance) .. " m", 3)
        elseif distance > brakingDistance + 200 then brakeWarned_ = false end
    end
end

-- ---------------------------------------------------------------------------
-- HUD 刷新
-- ---------------------------------------------------------------------------
---@param dt number
function Game.UpdateHud(dt)
    local st = stations_[nextIndex_]
    if st then
        Hud.SetStationName(st.name)
        local dist = Train.IsReversing() and Route.ForwardDistance(st.s, Train.GetS())
            or Route.ForwardDistance(Train.GetS(), st.s)
        if state_ == STATE.DWELL then
            Hud.SetNextStation("停靠中")
        else
            if dist > 1000 then
                Hud.SetNextStation(string.format("%.1f km", dist / 1000))
            else
                Hud.SetNextStation(string.format("%d m", math.floor(dist)))
            end
        end
    end

    Hud.SetSpeedRange(Train.GetMaxSpeedKmh())
    Hud.SetSpeed(Train.GetSpeedKmh(), Game.GetSpeedLimit())
    Hud.SetReversing(Train.IsReversing())
    Hud.SetThrottle(Train.GetThrottle(), GameConfig.Train.MaxThrottle)
    Hud.SetBrake(Train.GetBrake())
    Hud.SetTime(elapsed_)
    Hud.SetXp(xp_)
    Hud.SetSwitch(switchPos_)
    Hud.Update(dt)

    -- 小地图列车位置
    local pos = Route.Sample(Train.GetS())
    Hud.SetMinimapTrain(pos.x, pos.z, state_ == STATE.DWELL and nextIndex_ or nil)
end

-- ============================================================================
-- 操作接口
-- ============================================================================

function Game.ThrottleUp()
    if state_ == STATE.DWELL then return end
    local notch = Train.ThrottleUp()
    if notch > 0 then
        Hud.Toast("油门 " .. notch .. " 档", 1.0)
    end
end

function Game.ThrottleDown()
    if state_ == STATE.DWELL then return end
    Train.ThrottleDown()
end

--- 刹车按钮：按住持续制动（点击时施加一档）
function Game.Brake(strength)
    if state_ == STATE.DWELL then return end
    Train.AddBrake(strength or 0.2)
    if Train.GetThrottle() > 0 then
        Train.SetThrottle(0)
    end
end

function Game.EmergencyBrake()
    Train.EmergencyBrake()
    Hud.Toast("紧急制动!", 2.0)
    AudioManager.PlayBrake(1.0)
end

function Game.Horn()
    if AudioManager.PlayHorn() then
        Hud.Toast("呜——", 1.2)
    else
        Hud.Toast("呜——（未找到汽笛音效）", 1.2)
    end
end

--- 道岔：左 / 右
---@param dir number
function Game.SetSwitch(dir)
    -- 当前为单一闭合正线，不把一个UI变量伪装成真实可切换道岔。
    Hud.Toast("当前线路为单线正线，没有可操作道岔", 1.5)
end

function Game.IsDwelling() return state_ == STATE.DWELL end
function Game.GetXp() return xp_ end
function Game.GetElapsed() return elapsed_ end
function Game.GetNextStation()
    return stations_[nextIndex_]
end

--- 距最近车站的距离（米，用于站台环境音淡入）
---@return number
function Game.GetNearestStationDistance()
    local s = Train.GetS()
    local best = math.huge
    for i = 1, #stations_ do
        local d = math.abs(Route.ForwardDistance(s, stations_[i].s))
        if d > Route.GetLength() * 0.5 then
            d = Route.GetLength() - d
        end
        if d < best then best = d end
    end
    return best
end

return Game
