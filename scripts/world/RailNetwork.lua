-- 开放线路的双正线与站内到发线；列车和轨道网格共用同一采样。
-- 0 下行正线、1 上行正线、2 站内到发线。站外侧线汇入0，不作横移传送。
local Route = require "world.Route"
local RailNetwork = {}
RailNetwork.MainLane = 0
RailNetwork.OpposingLane = 1
RailNetwork.SidingLane = 2
RailNetwork.YardStart = -700
RailNetwork.YardEnd = 400
RailNetwork.SidingOffset = 10.8

---@class RailwayRouteChoice
---@field lane integer
---@field locked boolean
---@type table<number, RailwayRouteChoice>
local choices_ = {}
local playerS_ = 0.0
local playerLength_ = 220.0
local playerReversing_ = false
local pendingLane_ = 0

---@param s number
---@return table|nil
function RailNetwork.GetYard(s)
    for _, station in ipairs(Route.GetStations()) do
        if s >= station.s + RailNetwork.YardStart and s <= station.s + RailNetwork.YardEnd then
            return station
        end
    end
    return nil
end

local function smooth(t)
    local x = math.max(0, math.min(1, t))
    return x * x * x * (10 + x * (-15 + x * 6))
end

---@param s number
---@param lane? integer
---@return number
function RailNetwork.GetLateral(s, lane)
    if lane == 1 then return -5 end
    if lane ~= 2 then return 0 end
    local station = RailNetwork.GetYard(s)
    if not station then return 0 end
    local relative = s - station.s
    if relative < -320 then return RailNetwork.SidingOffset * smooth((relative + 700) / 380) end
    if relative > 160 then return RailNetwork.SidingOffset * (1 - smooth((relative - 160) / 240)) end
    return RailNetwork.SidingOffset
end

local function center(s)
    if Route.SampleExtended then return Route.SampleExtended(s) end
    return Route.Sample(s)
end

---@param s number
---@param lane integer
---@return Vector3
local function offsetPoint(s, lane)
    local position, _, yaw = center(s)
    local angle = math.rad(yaw)
    return position + Vector3(math.cos(angle), 0, -math.sin(angle)) * RailNetwork.GetLateral(s, lane)
end

---@param s number
---@param lane? integer
---@return Vector3, Vector3, number
function RailNetwork.Sample(s, lane)
    local id = lane or 0
    if id == 0 then return center(s) end
    local position = offsetPoint(s, id)
    local ahead, behind = offsetPoint(s + .25, id), offsetPoint(s - .25, id)
    local tangent = (ahead - behind):Normalized()
    local yaw = math.deg(math.atan(tangent.x, tangent.z))
    return position, tangent, yaw
end

function RailNetwork.GetStations() return Route.GetStations() end

-- 占用示意（纵向包络，不创建Bullet碰撞体）：
--  [整列尾端 s-L] ===== 8节车 ===== [车头 s+16]
--  只要包络与 [站-700,站+400] 相交，就锁定本次进路；所有车按各自s查该进路。
-- 不能车头过岔后再改岔，也不能末节仍在岔区时改变路径。倒车同样保留已锁路径。
---@param s number
---@param length number
---@param reversing boolean
function RailNetwork.UpdatePlayer(s, length, reversing)
    playerS_, playerLength_, playerReversing_ = s, length, reversing
    local rear, front = s - length, s + 16
    for _, station in ipairs(Route.GetStations()) do
        local occupied = front >= station.s - 700 and rear <= station.s + 400
        local choice = choices_[station.index]
        if occupied and not choice then
            choice = {lane = pendingLane_, locked = true}
            choices_[station.index] = choice
            print(string.format("[RailNetwork] %s 进路锁定：%s", station.name,
                choice.lane == 2 and "站内到发线" or "下行正线"))
            pendingLane_ = 0
        elseif choice then
            choice.locked = occupied
        end
    end
end

---@param s number
---@return integer
function RailNetwork.GetPlayerLane(s)
    local station = RailNetwork.GetYard(s)
    local choice = station and choices_[station.index]
    return choice and choice.lane or 0
end

---@param s number
---@param reversing boolean
---@return table|nil, number
function RailNetwork.GetNextSwitch(s, reversing)
    local selected, best = nil, math.huge ---@type table|nil, number
    for _, station in ipairs(Route.GetStations()) do
        local entry = station.s + (reversing and 400 or -700)
        local distance = reversing and (s - entry) or (entry - s)
        if distance >= 0 and distance < best then selected, best = station, distance end
    end
    return selected, best
end

---@param dir number
---@param s number
---@param length number
---@param reversing boolean
---@return boolean, string
function RailNetwork.SetPlayerChoice(dir, s, length, reversing)
    RailNetwork.UpdatePlayer(s, length, reversing)
    local current = RailNetwork.GetYard(s)
    if current then
        local existing = choices_[current.index]
        if existing and existing.locked then return false, "整列未驶离岔区，进路已锁定" end
    end
    local station, distance = RailNetwork.GetNextSwitch(s, reversing)
    if not station then return false, "前方已无道岔；终到停稳后可换向折返" end
    local existing = choices_[station.index]
    if existing and existing.locked then return false, "列车包络已进入岔区，禁止扳动道岔" end
    local lane = dir > 0 and 2 or 0
    choices_[station.index] = {lane = lane, locked = false}
    pendingLane_ = 0
    return true, string.format("%s：%s进路已预选，距入口 %.0f m", station.name,
        lane == 2 and "站内到发线" or "正线", distance)
end

---@param index integer
---@param lane integer
---@param s number
---@param length number
---@return boolean, string
function RailNetwork.SetStationChoice(index, lane, s, length)
    RailNetwork.UpdatePlayer(s, length, playerReversing_)
    local station = Route.GetStations()[index]
    if not station then return false, "未知车站进路" end
    local existing = choices_[index]
    if existing and existing.locked then return false, "岔区占用，不能改变已锁进路" end
    if lane ~= 0 and lane ~= 2 then return false, "进路必须是正线或站内到发线" end
    choices_[index] = {lane = lane, locked = false}
    return true, station.name .. (lane == 2 and "侧线进路已预选" or "正线进路已预选")
end

function RailNetwork.GetStatus()
    local yard = RailNetwork.GetYard(playerS_)
    local choice = yard and choices_[yard.index]
    local nextStation, distance = RailNetwork.GetNextSwitch(playerS_, playerReversing_)
    local nextChoice = nextStation and choices_[nextStation.index]
    return {aspect = "green", text = "进路开放",
        track = RailNetwork.GetPlayerLane(playerS_) == 2 and "站内到发线" or "下行正线",
        switchText = choice and choice.locked and "岔区占用·进路锁定"
            or (nextStation and string.format("%s %s %.0fm", nextStation.name,
                nextChoice and nextChoice.lane == 2 and "侧线" or "正线", distance) or "线路终端"),
        locked = choice ~= nil and choice.locked or false}
end

function RailNetwork.Reset(s, length, reversing)
    choices_, pendingLane_ = {}, 0
    RailNetwork.UpdatePlayer(s, length or 220, reversing == true)
end

function RailNetwork.GetChoices() return choices_ end
function RailNetwork.RestoreChoices(saved)
    choices_={}
    for _,choice in ipairs(saved) do
        assert(Route.GetStations()[choice.index] and (choice.lane==0 or choice.lane==2),"存档进路无效")
        choices_[choice.index]={lane=choice.lane,locked=false}
    end
    RailNetwork.UpdatePlayer(playerS_,playerLength_,playerReversing_)
end
return RailNetwork
