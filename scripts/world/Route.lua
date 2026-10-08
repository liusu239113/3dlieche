-- 按米计算的解析圆角闭合环线；线路基准始终为 Y=0，轨面另建于 Y=0.34。
-- 在本模块关闭正弦高低起伏，不修改共享配置。
local GameConfig = require "config.GameConfig"
local Route = {}

---@class RailwayRoutePoint
---@field s number
---@field pos Vector3
---@field tangent Vector3
---@field right Vector3
---@field yaw number
---@class RailwayRouteSegment
---@field type string
---@field s number
---@field length number
---@field pos Vector3
---@field yaw number
---@field radius number
---@field dir number
---@field center Vector3
---@type RailwayRoutePoint[]
local points_ = {}
---@type RailwayRouteSegment[]
local segments_ = {}
local length_ = 0.0
local baseY_ = 0.0
---@type table[]
local stations_ = {}
---@type table
local validation_ = {}

-- 共享站台包络：310 米可覆盖停靠点后方的八节编组。
Route.PlatformStart = -225.0
Route.PlatformEnd = 85.0
Route.RailHeadHeight = 0.34
Route.BuildingClearance = 25.0

local function rightAtYaw(yaw)
    local a = math.rad(yaw)
    return Vector3(math.cos(a), 0, -math.sin(a))
end

---@param seg RailwayRouteSegment
---@param ds number
---@return Vector3, Vector3, number
local function sampleSegment(seg, ds)
    local yaw = seg.yaw
    if seg.type == "arc" then
        yaw = yaw + seg.dir * math.deg(ds / seg.radius)
        local p = seg.center - rightAtYaw(yaw) * (seg.radius * seg.dir)
        local a = math.rad(yaw)
        return Vector3(p.x, baseY_, p.z), Vector3(math.sin(a), 0, math.cos(a)), yaw
    end
    local a = math.rad(yaw)
    local t = Vector3(math.sin(a), 0, math.cos(a))
    return seg.pos + t * ds, t, yaw
end

local function construct(definitions)
    segments_ = {}
    length_ = 0.0
    local start = GameConfig.RouteStart or Vector3.ZERO
    local pos = Vector3(start.x, baseY_, start.z)
    local yaw = (GameConfig.RouteStartYaw or 0) * 1.0
    for _, def in ipairs(definitions) do
        local radius = def.radius or 0
        if def.type ~= "straight" and def.type ~= "arc" then return false end
        if def.type == "arc" and ((def.angle or 0) <= 0 or (def.angle or 0) > 360) then return false end
        local segLength = def.type == "arc" and radius * math.rad(def.angle or 0) or (def.length or 0)
        if segLength <= 0 or (def.type == "arc" and radius <= 0) then
            return false
        end
        local dir = (def.dir or 1) >= 0 and 1 or -1
        local seg = {
            type = def.type, s = length_, length = segLength,
            pos = pos, yaw = yaw, radius = radius, dir = dir,
            center = pos + rightAtYaw(yaw) * (radius * dir),
        }
        segments_[#segments_ + 1] = seg
        local endPos, _, endYaw = sampleSegment(seg, segLength)
        pos, yaw = endPos, endYaw
        length_ = length_ + segLength
    end
    -- 拒绝用斜向回接钢轨掩盖未闭合的线路配置。
    return length_ > 0 and (pos - Vector3(start.x, baseY_, start.z)):Length() < 0.01
        and math.abs((yaw - (GameConfig.RouteStartYaw or 0) + 180) % 360 - 180) < 0.001
end

--- 保留既有接口；负弧长也沿同一条轨道反向采样。
function Route.Build()
    baseY_ = 0.0
    if not construct(GameConfig.RouteSegments or {}) then
        Route.Clear()
        error("[Route] 线路段无效或位置/切线未闭合；拒绝静默回退到小半径线路")
    end
    points_ = {}
    local step = math.max(0.5, math.min(50, GameConfig.RouteStep or 10.0))
    for _, seg in ipairs(segments_) do
        local count = math.max(1, math.ceil(seg.length / step))
        for i = 1, count do
            local ds = (i - 1) * seg.length / count
            local pos, tangent, yaw = sampleSegment(seg, ds)
            points_[#points_ + 1] = {
                s = seg.s + ds, pos = pos, tangent = tangent,
                right = rightAtYaw(yaw), yaw = yaw,
            }
        end
    end
    stations_ = Route.AssignStations()
    local first = segments_[1]
    local last = segments_[#segments_]
    if first and last then
        local endPos, endTangent, endYaw = sampleSegment(last, last.length)
        local _, startTangent = sampleSegment(first, 0)
        local minSpacing = math.huge
        for i, st in ipairs(stations_) do
            local nextStation = stations_[i % #stations_ + 1]
            if nextStation then
                minSpacing = math.min(minSpacing, Route.ForwardDistance(st.s, nextStation.s))
            end
        end
        validation_ = {
            length = length_, pointCount = #points_, baseY = baseY_,
            closureError = (endPos - first.pos):Length(),
            tangentDot = endTangent:DotProduct(startTangent), totalYaw = endYaw - first.yaw,
            minStationSpacing = minSpacing, requiredStationSpacing = 350,
            minRadius = (function()
                local radius = math.huge
                for _, seg in ipairs(segments_) do
                    if seg.type == "arc" then radius = math.min(radius, seg.radius) end
                end
                return radius
            end)(), railHeadY = Route.RailHeadHeight,
        }
        if minSpacing < 350 then print("[Route] 错误：站点间距不足 350 米") end
    end
    print(string.format("[Route] 闭合单线 %.3f 米，%d 个唯一采样点；地面基准=0，轨面=0.34 米",
        length_, #points_))
    for _, st in ipairs(Route.GetStations()) do
        print(string.format("[Route] %s 停靠点 %.2f 米，直线站台 %.2f..%.2f 米",
            st.name, st.s, st.s + Route.PlatformStart, st.s + Route.PlatformEnd))
    end
    return length_
end

--- 兼容接口：强制平坦，不再读取起伏幅度和波数。
function Route.ApplyTerrain()
    for _, p in ipairs(points_) do
        p.pos = Vector3(p.pos.x, baseY_, p.pos.z)
    end
end

function Route.GetLength() return length_ end
function Route.GetPointCount() return #points_ end
---@return RailwayRoutePoint[]
function Route.GetPoints() return points_ end

---@param s number
---@return number
function Route.Wrap(s)
    return length_ > 0 and s % length_ or 0
end
function Route.ForwardDistance(from, to) return Route.Wrap(to - from) end

---@param s number
---@return Vector3, Vector3, number
function Route.Sample(s)
    if #segments_ == 0 then return Vector3.ZERO, Vector3.FORWARD, 0 end
    local wrapped = Route.Wrap(s)
    for _, seg in ipairs(segments_) do
        if wrapped < seg.s + seg.length then
            return sampleSegment(seg, wrapped - seg.s)
        end
    end
    local first = segments_[1]
    if first then return sampleSegment(first, 0) end
    return Vector3.ZERO, Vector3.FORWARD, 0
end

function Route.SampleOffset(s, lateral, up)
    local pos, _, yaw = Route.Sample(s)
    return pos + rightAtYaw(yaw) * lateral + Vector3(0, up or 0, 0)
end
function Route.RightAt(s)
    local _, _, yaw = Route.Sample(s)
    return rightAtYaw(yaw)
end
function Route.TangentAt(s)
    local _, tangent = Route.Sample(s)
    return tangent
end

-- 解析整条线路的最近点：直线投影、有限圆弧径向投影及端点。
-- 与可见分块完全无关，闭合另一侧/接缝也参与净空；不再扫十万米采样弦。
---@param worldPos Vector3
---@return number distance, number s
function Route.DistanceTo(worldPos)
    local bestD2, bestS = math.huge, 0.0
    local function consider(seg, ds)
        local position = sampleSegment(seg, ds)
        local dx, dz = worldPos.x - position.x, worldPos.z - position.z
        local d2 = dx * dx + dz * dz
        if d2 < bestD2 then
            bestD2, bestS = d2, Route.Wrap(seg.s + ds)
        end
    end
    for _, seg in ipairs(segments_) do
        if seg.type == "straight" then
            local a = math.rad(seg.yaw)
            local ds = (worldPos.x - seg.pos.x) * math.sin(a) + (worldPos.z - seg.pos.z) * math.cos(a)
            consider(seg, math.max(0, math.min(seg.length, ds)))
        else
            consider(seg, 0)
            consider(seg, seg.length)
            local dx, dz = worldPos.x - seg.center.x, worldPos.z - seg.center.z
            if dx * dx + dz * dz > 0.000000001 then
                -- 径向向量 = -dir*right(yaw)，atan(y,x)支持完整象限。
                local yaw = math.atan(seg.dir * dz, -seg.dir * dx)
                local turn = (seg.dir * (yaw - math.rad(seg.yaw))) % (2 * math.pi)
                local sweep = seg.length / seg.radius
                if turn <= sweep + 0.000000001 then
                    consider(seg, math.min(seg.length, turn * seg.radius))
                end
            end
        end
    end
    return math.sqrt(bestD2), bestS
end
function Route.ProjectApprox(worldPos)
    local _, s = Route.DistanceTo(worldPos)
    return s
end
function Route.CanPlaceFootprint(center, radius, clearance)
    local distance = Route.DistanceTo(center)
    return distance - radius >= (clearance or Route.BuildingClearance) + 0.01
end

---@return table[]
function Route.AssignStations()
    local out = {}
    for i, st in ipairs(GameConfig.Stations) do
        assert(type(st.at) == "number" and st.at >= 0 and st.at < 1,
            "[Route] 站点比例必须位于[0,1)：" .. tostring(st.name))
        local target = Route.Wrap(st.at * length_)
        local bestS, bestDelta = target, math.huge
        -- 保留名称/index/顺序；完整站台必须落在同一直线，两端留10米。
        -- target±L保证跨闭合接缝仍找真正最近的合法停靠点。
        for _, seg in ipairs(segments_) do
            if seg.type == "straight" and seg.length >= Route.PlatformEnd - Route.PlatformStart + 20 then
                local first = seg.s - Route.PlatformStart + 10
                local last = seg.s + seg.length - Route.PlatformEnd - 10
                for wrap = -1, 1 do
                    local unwrapped = target + wrap * length_
                    local candidate = math.max(first, math.min(last, unwrapped))
                    local delta = math.abs(candidate - unwrapped)
                    if delta < bestDelta then bestS, bestDelta = candidate, delta end
                end
            end
        end
        assert(bestDelta < math.huge, "[Route] 找不到完整直线站台：" .. tostring(st.name))
        out[#out + 1] = { name = st.name, s = Route.Wrap(bestS), index = i }
    end
    -- 按配置顺序仅允许一圈递增；重叠/倒序不能只打印后继续运行。
    local travel = 0.0
    if #out > 1 then
        for i, st in ipairs(out) do
            local following = out[i % #out + 1]
            if following then
                local distance = Route.ForwardDistance(st.s, following.s)
                assert(distance >= 350, "[Route] 站点重叠或间距不足350米：" .. st.name)
                travel = travel + distance
            end
        end
        assert(math.abs(travel - length_) < 0.01, "[Route] 分配后的站点顺序不是单圈递增")
    end
    return out
end

function Route.GetStations() return stations_ end
function Route.GetValidationData() return validation_ end
---@return RailwayRouteSegment[]
function Route.GetSegments() return segments_ end

function Route.Clear()
    points_, segments_, stations_, validation_, length_ = {}, {}, {}, {}, 0.0
end
return Route
