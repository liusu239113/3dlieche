-- 速度单位 km/h，距离单位米；牵引能力、线路许可与进站制动曲线分别计算。
-- 横向加速度和服务制动留有余量，是驾驶模拟调校，不代表真实线路认证。
local SpeedPolicy = {}

---@param radius number
---@param lineLimit number
---@return number
function SpeedPolicy.CurveLimit(radius, lineLimit)
    if radius <= 0 then return lineLimit end
    return math.min(lineLimit, math.floor(math.sqrt(0.95 * radius) * 3.6 / 10) * 10)
end

---@param distance number
---@param targetKmh number
---@param deceleration number
---@param reactionDistance number
---@return number
function SpeedPolicy.ApproachLimit(distance, targetKmh, deceleration, reactionDistance)
    local available = math.max(0, distance - reactionDistance)
    local target = targetKmh / 3.6
    return math.sqrt(target * target + 2 * math.max(0.1, deceleration) * available) * 3.6
end

---@class RailwaySpeedInput
---@field s number
---@field length number
---@field operatingKmh number
---@field lineKmh number
---@field deceleration number
---@field reversing boolean
---@field segments RailwayRouteSegment[]
---@field stations table[]
---@field nextStopS number?
---@field dwelling boolean
---@field stationKmh number
---@field reactionSeconds number

---@param input RailwaySpeedInput
---@return number limit, string reason
function SpeedPolicy.Calculate(input)
    local length = input.length
    local line = math.min(input.operatingKmh, input.lineKmh)
    if length <= 0 then return line, "区间" end
    if input.dwelling then return 0, "站停" end
    local s = input.s % length
    local limit, reason = line, "区间"
    local reactionDistance = line / 3.6 * input.reactionSeconds + 30
    local function apply(value, label)
        if value < limit then limit, reason = value, label end
    end
    for _, segment in ipairs(input.segments) do
        if segment.type == "arc" then
            local curve = SpeedPolicy.CurveLimit(segment.radius, input.lineKmh)
            if s >= segment.s and s < segment.s + segment.length then
                apply(curve, "曲线")
            else
                local distance = input.reversing
                    and (s - segment.s - segment.length) % length
                    or (segment.s - s) % length
                apply(SpeedPolicy.ApproachLimit(distance, curve,
                    input.deceleration, reactionDistance), "前方曲线")
            end
        end
    end
    -- 所有站场都有限速，不能换车或倒车绕过；区间绝不统一限速60/80。
    for _, station in ipairs(input.stations) do
        local relative = (s - station.s + length * 0.5) % length - length * 0.5
        if relative >= -450 and relative <= 250 then
            apply(input.stationKmh, "站场")
        else
            local distance = input.reversing and (s - station.s - 250) % length
                or (station.s - 450 - s) % length
            apply(SpeedPolicy.ApproachLimit(distance, input.stationKmh,
                input.deceleration, reactionDistance), "前方站场")
        end
    end
    if input.nextStopS then
        local distance = input.reversing and (s - input.nextStopS) % length
            or (input.nextStopS - s) % length
        -- 停车点保留10km/h微调，实际到站仍须停稳、收油；不强行自动停车。
        apply(math.max(10, SpeedPolicy.ApproachLimit(distance, 0,
            input.deceleration, reactionDistance)), "进站制动")
    end
    return math.max(0, math.floor(limit / 5) * 5), reason
end

return SpeedPolicy
