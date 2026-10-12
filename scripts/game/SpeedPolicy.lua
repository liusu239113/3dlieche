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
---@field closed boolean? 缺省true，兼容原闭合线路
---@field activeLength number? 完整编组长度，端点制动保留尾车空间

---@param input RailwaySpeedInput
---@return number limit, string reason
function SpeedPolicy.Calculate(input)
    local length = input.length
    local line = math.min(input.operatingKmh, input.lineKmh)
    if length <= 0 then return line, "区间" end
    if input.dwelling then return 0, "站停" end
    local closed = input.closed ~= false
    local s = closed and input.s % length or math.max(0, math.min(length, input.s))
    local limit, reason = line, "区间"
    local reactionDistance = line / 3.6 * input.reactionSeconds + 30
    local function forward(distance)
        return closed and distance % length or distance
    end
    local function apply(value, label)
        if value < limit then limit, reason = value, label end
    end
    -- 开放线路负距离表示已经驶过；不能再将后方曲线/站场当作前方。
    local function approach(distance, target, label)
        if distance >= 0 then
            apply(SpeedPolicy.ApproachLimit(distance, target, input.deceleration, reactionDistance), label)
        end
    end
    for _, segment in ipairs(input.segments) do
        if segment.type == "arc" then
            local curve = SpeedPolicy.CurveLimit(segment.radius, input.lineKmh)
            if s >= segment.s and s <= segment.s + segment.length then
                apply(curve, "曲线")
            else
                local distance = forward(input.reversing and (s - segment.s - segment.length) or (segment.s - s))
                approach(distance, curve, "前方曲线")
            end
        end
    end
    -- 快速任务可通过小站，但站场本身仍限速；倒车同样应用站场包络。
    for _, station in ipairs(input.stations) do
        local relative = s - station.s
        if closed then relative = (relative + length * 0.5) % length - length * 0.5 end
        if relative >= -450 and relative <= 250 then
            apply(input.stationKmh, "站场")
        else
            local distance = forward(input.reversing and (s - station.s - 250) or (station.s - 450 - s))
            approach(distance, input.stationKmh, "前方站场")
        end
    end
    if input.nextStopS ~= nil then
        local distance = forward(input.reversing and (s - input.nextStopS) or (input.nextStopS - s))
        if distance >= 0 then
            -- 停车点保留10km/h微调；到站仍必须手动收油、停稳。
            apply(math.max(10, SpeedPolicy.ApproachLimit(distance, 0,
                input.deceleration, reactionDistance)), "进站制动")
        end
    end
    if not closed then
        -- 列车s是原头车中心，不因换向改变参考点：倒车最前端是整列尾车。
        -- [0] --20m-- [尾 s-activeLength] ===== [原头 s] --20m-- [L]
        -- 端点安全包络无10km/h保底；可为0，不能让clamp掩盖冲出线路。
        local reserve = input.reversing and math.max(0, input.activeLength or 0) + 20 or 20
        local distance = input.reversing and s - reserve or length - s - reserve
        if distance <= 0 then apply(0, "线路终端")
        else approach(distance, 0, "线路终端制动") end
    end
    return math.max(0, math.floor(limit / 5) * 5), reason
end

return SpeedPolicy
