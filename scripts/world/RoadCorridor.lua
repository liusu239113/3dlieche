-- 右行动态国道走廊，沿用scaffold-3d-scene子树所有权。
-- XZ保留区为路边外5m，不依赖流式加载、高度或旧CanPlace。
--       负侧站房-68          铁路0/+5          正侧国道+92（站区+128）
-- 上跨采用闭合农村回环，两座跨轨桥都接回国道，没有断头展示短桥。
-- 梁底>=轨面+9m，[-24,+24]铁路包络内不放墩。
-- 桥面含底/侧面，地形/路基/灯杆均使用Route真实高程；墩基抵达局部河床或土地保底以下。
local Route = require "world.Route"
local World = require "world.WorldMaterials"
local Landmarks = require "world.Landmarks"
local Landscape = require "world.Landscape"
local Config = require "config.CorridorConfig"
local NightLighting = require "world.NightLighting"
local Vehicles = require "world.RoadVehicles"
local Road = {}

---@class CorridorRoadPoint
---@field s number
---@field pos Vector3
---@field right Vector3
---@field lateral number
---@field ground number
---@field foundation number
---@class CorridorRoadEdge
---@field a CorridorRoadPoint
---@field b CorridorRoadPoint
---@field first number
---@field last number
---@field ownerS number
---@field kind string
---@field id string
---@class CorridorRoadChunk
---@field root Node
---@field vertices integer
---@field meshes integer
---@field piers integer
---@field length number
---@field signs integer
---@field cameras integer
---@field markers integer
---@field lamps integer
---@field supports table[]
---@field vehicles integer
---@field vehicleData table[]
---@field first number
---@field last number
---@field ready boolean
---@type Scene?
local scene_ = nil
---@type CorridorRoadPoint[]
local profile_ = {}
---@type CorridorRoadEdge[]
local edges_ = {}
---@type table<string, CorridorRoadEdge[]>
local spatial_ = {}
---@type table<string, CorridorRoadChunk>
local chunks_ = {}
---@type table[]
local loops_ = {}
---@type table[]
local terrainDefinitions_ = {}
---@type table<string, Material>
local materials_ = {}
local initialized_ = false
local maxGrade_ = 0.0
local maxHeight_ = 0.0
local minClearance_ = math.huge
local length_ = 0.0
local bypasses_ = 0
local CELL = 128
---@class CorridorTrafficPlacement
---@field id string
---@field s number
---@field direction number
---@field kind string
---@field speed number
---@field distance number
---@field startS number
---@field lease RailwayRoadVehicleLease?
---@field surface Vector3?
---@field forward Vector3?
---@class CorridorMovingVehiclePlan
---@field id string
---@field first number
---@field last number
---@field startS number
---@field direction number
---@field speed number
---@field kind string
---@type CorridorTrafficPlacement[]
local trafficPlan_ = {}
---@type CorridorMovingVehiclePlan[]
local movingPlan_ = {}
local TRAFFIC_STEP = 155
local TRAFFIC_LIMIT = 64
local TRAFFIC_RANGE = 1100 -- Node绘制950m；对象池在绘制边界之外租借/归还。
local END_MARGIN = 12
---@type RailwayRoadVehiclePool?
local trafficPool_ = nil
local trafficTime_ = 0.0
local trafficUpdates_ = 0
local trafficPlayerS_ = 0.0
local trafficPaused_ = false
local trafficRecycles_ = 0
local trafficMaxActive_ = 0
---@type table<number,CorridorTrafficPlacement[]>
local lanes_ = {}
---@type number[]
local roadDistances_ = {}
local roadLength_ = 0.0
local function smooth(v)
    local t = math.max(0, math.min(1, v))
    return t * t * (3 - 2 * t)
end
local function gap(s, a, b) return math.max(a - s, s - b, 0) end
local function pauseOnce(pause) if pause then pause() end end
local function key(a, b) return string.format("%.6f_%.6f", a, b) end
local function flatDistance(a, b)
    local dx, dz = a.x - b.x, a.z - b.z
    return math.sqrt(dx * dx + dz * dz)
end
local function distanceToEdge(pos, edge)
    local a, b = edge.a.pos, edge.b.pos
    local dx, dz = b.x - a.x, b.z - a.z
    local t = math.max(0, math.min(1, ((pos.x - a.x) * dx + (pos.z - a.z) * dz) / math.max(.000001, dx * dx + dz * dz)))
    return flatDistance(pos, a + (b - a) * t)
end
local function lateralAt(s)
    local lateral = Config.Road.Lateral
    for _, station in ipairs(Route.GetStations()) do
        local d = Route.Distance(s, station.s)
        local blend = 1 - smooth((d - Config.Road.StationPlateau) / Config.Road.StationTransition)
        lateral = math.max(lateral, Config.Road.Lateral + (Config.Road.StationLateral - Config.Road.Lateral) * blend)
    end
    for _, def in ipairs(terrainDefinitions_) do
        if def.kind == "tunnel" then
            -- 每个真山壳有自己的宽度；用最大偏心包络+维护带，而非固定430m。
            -- 相邻洞口过渡用max合并，自然保持整组山外连续绕行。
            local transition=(def.portalTransition or 80)+24
            local blend = 1 - smooth(gap(s, def.first - transition, def.last + transition) / Config.Road.TunnelBypassTransition)
            local target=math.max(Config.Road.TunnelBypassLateral,
                def.lateral+def.halfWidth*1.14+Config.Road.LaneWidth+Config.Road.Shoulder+Config.Road.MountainMaintenanceMargin)
            lateral = math.max(lateral, Config.Road.Lateral + (target - Config.Road.Lateral) * blend)
        end
    end
    for _, def in ipairs(terrainDefinitions_) do
        if def.kind == "mountain" then
            local blend = 1 - smooth((math.abs(s - def.s) - 440) / 520)
            if blend > 0 then
                local origin = Route.SampleOffset(def.s, def.lateral, 0)
                local routePoint = Route.Sample(s)
                local mountainRight = Route.RightAt(def.s)
                local currentRight = Route.RightAt(s)
                local projection = currentRight:DotProduct(mountainRight)
                local base = (routePoint - origin):DotProduct(mountainRight)
                local width = def.halfWidth * 1.28 + 18
                -- 正侧山峰优先从山内侧通过；负侧山峰向正侧躲开。
                -- 在真实山峰坐标系求边界，再在完整山基范围外平滑过渡。
                if def.lateral > 0 and projection > .50 then
                    local target = (-width - base) / projection
                    if target < lateral then lateral = lateral + (math.max(42, target) - lateral) * blend end
                elseif def.lateral < 0 and projection > .50 then
                    local target = (width - base) / projection
                    if target > lateral then lateral = lateral + (target - lateral) * blend end
                end
            end
        end
    end
    return lateral
end
-- 仅规划地表/河床，不查询已加载场景或递归调用CanPlace。
local function terrainAt(s, lateral)
    local pos = Route.SampleOffset(s, lateral, 0)
    -- Terrain.BuildHills对整块80m三角面调用CanPlace(center,r,310)，
    -- 主入口的CorridorExclusion使所有接触路幅的丘陵块退出；绕行因此在
    -- 原Y=0土地保底上通过，不用为了未生成的坡面抬成90m悬空巨坡。
    -- 本规划自身不调用CanPlace，避免被自己的保留区拦截。
    -- ground是相对轨基的设计偏移；foundation是绝对世界Y，不能把非零山地基高丢掉。
    -- SampleOffset第三参仍为竖直偏移，后续只加一次Route真实高程。
    local baseY = Route.Sample(s).y
    local ground, foundation = .004, baseY - .55
    local nearTunnel = false
    for _, def in ipairs(terrainDefinitions_) do
        if def.kind == "tunnel" then
            local ds = gap(s, def.first, def.last)
            if ds <= 80 and math.abs(lateral - def.lateral) < def.halfWidth + 80 then nearTunnel = true end
        elseif def.kind == "bridge" and s >= def.first - 24 and s <= def.last + 24
            and math.abs(lateral - def.lateral) < def.halfWidth then
            -- 墩基允许埋深；按全谷最大深度确保跨块中点也抵达真实河床。
            foundation = math.min(foundation, baseY - def.depth - .85)
        end
    end
    if nearTunnel then ground = .004 end -- 桥隧保留区本身也拒绝丘陵三角面。
    for _, def in ipairs(terrainDefinitions_) do
        if def.kind == "mountain" then
            local origin = Route.SampleOffset(def.s, def.lateral, 0)
            local offset = pos - origin --[[@as Vector3]]
            local along = math.abs(offset:DotProduct(Route.TangentAt(def.s)))
            local across = math.abs(offset:DotProduct(Route.RightAt(def.s)))
            -- 常规正侧92m位于独立山峰内缘之外；若规划不满足则明确拒绝，不能埋路。
            assert(not (along < 370 and across < def.halfWidth * 1.28 + 7),
                "[RoadCorridor] mountain conflicts with planned road near s=" .. s)
        end
    end
    return ground, foundation
end
local function addEdge(a, b, kind, id, ownerS)
    local ownership = ownerS or a.s
    if kind ~= "national" then ownership = Route.ProjectApprox((a.pos + b.pos) * .5) end
    local edge = {a = a, b = b, first = a.s, last = b.s, ownerS = ownership, kind = kind, id = id}
    edges_[#edges_ + 1] = edge
    local margin = Config.Road.LaneWidth + Config.Road.Shoulder + Config.Road.ReservationMargin + 1
    for x = math.floor((math.min(a.pos.x, b.pos.x) - margin) / CELL), math.floor((math.max(a.pos.x, b.pos.x) + margin) / CELL) do
        for z = math.floor((math.min(a.pos.z, b.pos.z) - margin) / CELL), math.floor((math.max(a.pos.z, b.pos.z) + margin) / CELL) do
            local k = x .. "_" .. z
            spatial_[k] = spatial_[k] or {}
            local cell = spatial_[k]
            cell[#cell + 1] = edge
        end
    end
end
local function sampleProfile(s)
    local clamped = math.max(0, math.min(length_, s))
    local i = math.min(#profile_ - 1, math.floor(clamped / Config.Road.ProfileStep) + 1)
    local a, b = assert(profile_[math.max(1, i)]), assert(profile_[math.max(1, i) + 1])
    local t = (clamped - a.s) / math.max(.000001, b.s - a.s)
    local delta = b.pos - a.pos
    local right = a.right * (1-t) + b.right * t --[[@as Vector3]]
    -- 与BuildChunk三角路幅使用相同插值，不在12m接缝突然换车道法线。
    return a.pos + delta * t, right:Normalized(), a.lateral + (b.lateral - a.lateral) * t
end
local function planProfile()
    local step = Config.Road.ProfileStep
    for s = 0, length_, step do
        local lateral = lateralAt(s)
        local ground, foundation = terrainAt(s, lateral)
        local y = math.max(Config.Road.SurfaceY, ground + Config.Overpass.DeckThickness + .18)
        profile_[#profile_ + 1] = {s = s, pos = Route.SampleOffset(s, lateral, y), right = Route.RightAt(s),
            lateral = lateral, ground = Route.Sample(s).y + ground, foundation = foundation}
    end
    if profile_[#profile_].s < length_ then
        local lateral = lateralAt(length_)
        local ground, foundation = terrainAt(length_, lateral)
        profile_[#profile_ + 1] = {s = length_, pos = Route.SampleOffset(length_, lateral,
            math.max(Config.Road.SurfaceY, ground + Config.Overpass.DeckThickness + .18)), right = Route.RightAt(length_),
            lateral = lateral, ground = Route.Sample(length_).y + ground, foundation = foundation}
    end
    -- 双向纵坡包络传播，连续调高而非局部跳变。
    -- 使用世界水平弦长而非铁路ds，适配偏置曲线。
    for i = 2, #profile_ do
        local previous, current = assert(profile_[i - 1]), assert(profile_[i])
        local y = math.max(current.pos.y, previous.pos.y - Config.Road.MaxGrade * flatDistance(current.pos, previous.pos))
        current.pos = Vector3(current.pos.x, y, current.pos.z)
    end
    for i = #profile_ - 1, 1, -1 do
        local current, following = assert(profile_[i]), assert(profile_[i + 1])
        local y = math.max(current.pos.y, following.pos.y - Config.Road.MaxGrade * flatDistance(current.pos, following.pos))
        current.pos = Vector3(current.pos.x, y, current.pos.z)
    end
    for i = 1, #profile_ - 1 do
        local a, b = assert(profile_[i]), assert(profile_[i + 1])
        local delta = b.pos - a.pos
        local forward = Vector3(delta.x, 0, delta.z):Normalized()
        a.right = Vector3(forward.z, 0, -forward.x)
        maxGrade_ = math.max(maxGrade_, math.abs(delta.y) / flatDistance(a.pos, b.pos))
        maxHeight_ = math.max(maxHeight_, a.pos.y, b.pos.y)
        addEdge(a, b, "national", Config.Road.Id)
    end
    profile_[#profile_].right = profile_[#profile_ - 1].right
end
local function planLoop()
    if not Config.Overpass.Enabled then return end
    local spans = {}
    local pending = nil ---@type table?
    for _, seg in ipairs(Route.GetSegments()) do
        if seg.type == "straight" and not seg.landmark then
            if pending then pending.last = seg.s + seg.length
            else pending = {first = seg.s, last = seg.s + seg.length} end
        else
            if pending then spans[#spans + 1] = pending; pending = nil end
        end
    end
    if pending then spans[#spans + 1] = pending end
    for _, span in ipairs(spans) do
        if span.last - span.first >= 1800 then
            print(string.format("[RoadCorridor] 上跨候选直线 %.0f..%.0fm", span.first, span.last))
            local a, b = span.first + 300, span.last - 300
            for _, station in ipairs(Route.GetStations()) do
                local before, after = station.s - Config.Overpass.MinStationDistance - 280, station.s + Config.Overpass.MinStationDistance + 280
                if station.s - span.first < span.last - station.s then a = math.max(a, after)
                else b = math.min(b, before) end
            end
            local safe = b - a >= 260
            for _, station in ipairs(Route.GetStations()) do
                if gap(station.s, a - 30, b + 30) < Config.Overpass.MinStationDistance then safe = false end
            end
            for _, def in ipairs(terrainDefinitions_) do
                if def.kind ~= "mountain" and b + 250 > def.first and a - 250 < def.last then safe = false end
                if def.kind == "mountain" then
                    for s = a - 220, b + 220, 80 do
                        for _, lat in ipairs({-235, 235}) do
                            local delta = Route.SampleOffset(s, lat, 0) - Route.SampleOffset(def.s, def.lateral, 0) --[[@as Vector3]]
                            if math.abs(delta:DotProduct(Route.TangentAt(def.s))) < 380
                                and math.abs(delta:DotProduct(Route.RightAt(def.s))) < def.halfWidth * 1.3 + 10 then safe = false end
                        end
                    end
                end
            end
            -- 山地回环只放在完整平坡直线，不能把6%横向坡再叠加线路纵坡后声称仍满足6%。
            for probe = a - 250, b + 250, 40 do
                if math.abs(Route.GradeAt(probe)) > .0001 then safe = false end
            end
            if safe then
                -- U形农村路两端T接国道，经两座跨轨桥及负侧连接路闭合。
                local loop = {id = "rural_loop_1", first = a, last = b, edges = {}, crossings = {a, b}}
                -- deckY/surface是相对轨基的高度；真正顶面/墩基使用每个采样点的世界Y。
                local deckY = Route.RailHeadHeight + Config.Overpass.RailHeadClearance + Config.Overpass.DeckThickness
                local half = Config.Overpass.SpanHalfLength
                local far = Config.Overpass.EndLateral
                local ramp = far - half
                local function rampBlend(t)
                    local v = math.max(0, math.min(1, t))
                    -- 两端各10%二次竖曲线，中间80%恒坡，在235m平谷内满足<=6%。
                    if v < .1 then return v * v / .18 end
                    if v > .9 then return 1 - (1 - v) * (1 - v) / .18 end
                    return (v - .05) / .9
                end
                local surface = sampleProfile(a).y - Route.Sample(a).y
                assert((deckY - surface) / (ramp * .9) <= .06,
                    "[RoadCorridor] overpass approach needs more horizontal space")
                loop.surfaceOffset = surface
                local function make(s, x)
                    local adjusted = surface + (deckY - surface) * (1 - rampBlend((math.abs(x) - half) / ramp))
                    local baseY = Route.Sample(s).y
                    return {s = s, pos = Route.SampleOffset(s, x, adjusted), right = Route.TangentAt(s), lateral = x,
                        ground = baseY + .004, foundation = baseY - .55}
                end
                -- 正侧连接坡道从国道真实高程接出，不造悬在T口上方的断头桥。
                for j, crossS in ipairs({a, b}) do
                    local national, nationalRight, lat = sampleProfile(crossS)
                    local joinS = crossS + (j == 1 and -ramp or ramp)
                    local positive = {} ---@type CorridorRoadPoint[]
                    local n = math.ceil((ramp + far) / 10)
                    for k = 0, n do
                        local t = k / n
                        local x = lat + (far - lat) * t
                        local s = crossS + (joinS - crossS) * t
                        local nationalOffset = national.y - Route.Sample(crossS).y
                        local y = nationalOffset + (surface - nationalOffset) * smooth(t)
                        local baseY = Route.Sample(s).y
                        positive[#positive + 1] = {s = crossS, pos = Route.SampleOffset(s, x, y), right = nationalRight,
                            lateral = x, ground = baseY + .004, foundation = baseY - .55}
                    end
                    for k = 1, #positive - 1 do
                        addEdge(positive[k], positive[k + 1], "rural", loop.id, crossS)
                        loop.edges[#loop.edges + 1] = edges_[#edges_]
                    end
                    local count = math.ceil(2 * far / 8)
                    for k = 0, count - 1 do
                        local x0, x1 = far - k * 2 * far / count, far - (k + 1) * 2 * far / count
                        local pa, pb = make(joinS, x0), make(joinS, x1)
                        addEdge(pa, pb, "overpass", loop.id, crossS)
                        loop.edges[#loop.edges + 1] = edges_[#edges_]
                    end
                    loop.crossings[j] = joinS
                end
                local s0, s1 = loop.crossings[1], loop.crossings[2]
                for s = s0, s1 - .001, 12 do
                    local finish = math.min(s1, s + 12)
                    local pa, pb = make(s, -far), make(finish, -far)
                    pa.right, pb.right = Route.RightAt(s), Route.RightAt(finish)
                    addEdge(pa, pb, "rural", loop.id, a)
                    loop.edges[#loop.edges + 1] = edges_[#edges_]
                end
                for _, edge in ipairs(loop.edges) do
                    local grade = math.abs(edge.b.pos.y - edge.a.pos.y) / flatDistance(edge.a.pos, edge.b.pos)
                    assert(grade <= .06, "[RoadCorridor] unsafe overpass approach grade")
                    maxGrade_ = math.max(maxGrade_, grade)
                    if edge.kind == "overpass" then
                        for _, p in ipairs({edge.a, edge.b}) do
                            if math.abs(p.lateral) <= 15 then
                                minClearance_ = math.min(minClearance_, p.pos.y - Config.Overpass.DeckThickness
                                    - Route.Sample(p.s).y - Route.RailHeadHeight)
                            end
                        end
                    end
                end
                loops_[#loops_ + 1] = loop
                break
            end
        end
    end
end
-- 公路自己的3D弧长坐标；偏置绕山不能直接把铁路ds当公路m/s。
local function distanceAt(s)
    local clamped=math.max(0,math.min(length_,s))
    local i=math.max(1,math.min(#profile_-1,math.floor(clamped/Config.Road.ProfileStep)+1))
    local a,b=profile_[i],profile_[i+1]
    local t=(clamped-a.s)/math.max(.000001,b.s-a.s)
    return roadDistances_[i]+(roadDistances_[i+1]-roadDistances_[i])*t
end
local function stationAt(distance)
    local clamped=math.max(0,math.min(roadLength_,distance))
    local low,high=1,#roadDistances_-1
    while low<high do
        local middle=math.floor((low+high+1)*.5)
        if roadDistances_[middle]<=clamped then low=middle else high=middle-1 end
    end
    local a,b=profile_[low],profile_[low+1]
    local t=(clamped-roadDistances_[low])/math.max(.000001,roadDistances_[low+1]-roadDistances_[low])
    return a.s+(b.s-a.s)*t
end
-- 全线确定性初始交通，而不是静态摆车：每条车道155m左右间隔，约4%公交。
-- 全局状态只持有轻量数字；仅已完成且实际开启的道路区域租借可动Node。
-- 安全包络（不使用物理体）
--   -3.5m | -1.75m <- [<=2.45m宽] | 黄线0 | [<=2.45m宽] -> +1.75m | +3.5m
--   同向最小净距=9m+1.4秒跟车；前车不足时后车减速，不超车/变道/互穿。
--   开放末端为实体车道终点：可见时排队停车，只有首尾都在视距外才回收。
local function planTraffic()
    roadDistances_={};roadDistances_[1]=0;roadLength_=0.0
    for i=2,#profile_ do
        roadLength_=roadLength_+(profile_[i].pos-profile_[i-1].pos):Length()
        roadDistances_[i]=roadLength_
    end
    local carKinds={"sedan_dark","sedan_white","suv","sedan_white","sedan_dark"}
    for _,direction in ipairs({-1,1}) do
        local lane={} ---@type CorridorTrafficPlacement[]
        lanes_[direction]=lane
        for cell=0,math.ceil(roadLength_/TRAFFIC_STEP) do
            local offset=direction<0 and 42 or 119
            local distance=cell*TRAFFIC_STEP+offset+((cell*37+offset)%19)-9
            if distance>=END_MARGIN and distance<=roadLength_-END_MARGIN then
                local kind=assert(carKinds[(cell+(direction<0 and 0 or 2))%#carKinds+1])
                if (cell+(direction<0 and 11 or 0))%25==24 then kind="bus" end
                local s=stationAt(distance)
                local record={id="road_"..direction.."_"..cell,s=s,startS=s,distance=distance,
                    direction=direction,kind=kind,speed=14.0}
                trafficPlan_[#trafficPlan_+1]=record;lane[#lane+1]=record
            end
        end
    end
    table.sort(trafficPlan_,function(a,b) return a.s<b.s end)
end
-- 旧TrafficVisuals只认此空计划，不再另建4辆固定演示车。
function Road.GetTrafficPlan() return trafficPlan_ end
function Road.GetMovingVehiclePlan() return movingPlan_ end
-- 旧接口保持有限端点语义，但不再承担生产车流。
---@param plan CorridorMovingVehiclePlan
---@param s number
---@param dt number
---@param playerS number
---@return number
function Road.AdvanceMovingVehicle(plan,s,dt,playerS)
    if type(dt)~="number" or dt~=dt or dt<0 or dt==math.huge then return s end
    return math.max(plan.first,math.min(plan.last,s+plan.direction*plan.speed*dt))
end
---@param scene Scene?
---@param options? table
function Road.Init(scene, options)
    Road.Shutdown()
    scene_ = scene
    assert(Route.GetLength() > 0, "[RoadCorridor] build Route before Init")
    length_ = Route.GetLength()
    terrainDefinitions_ = Landmarks.GetDefinitions()
    for _, def in ipairs(terrainDefinitions_) do if def.kind == "tunnel" then bypasses_ = bypasses_ + 1 end end
    planProfile()
    planLoop()
    planTraffic()
    initialized_ = true
    print(string.format("[RoadCorridor] %s %.1fkm右行国道，%d处山外支承绕行、%d个双上跨回环，最大坡度%.2f%%；%d辆双向动态计划，最多%d个可见Node",
        Config.Road.Id, length_ / 1000, bypasses_, #loops_, maxGrade_ * 100,#trafficPlan_,TRAFFIC_LIMIT))
    return true
end
---@param pos Vector3
---@param radius? number
---@param purpose? string
function Road.IsExcluded(pos, radius, purpose)
    if not initialized_ then return false end
    local r = math.max(0, radius or 0)
    local half = Config.Road.LaneWidth + Config.Road.Shoulder + Config.Road.ReservationMargin
    local seen = {} ---@type table<CorridorRoadEdge, boolean>
    for x = math.floor((pos.x - r) / CELL), math.floor((pos.x + r) / CELL) do
        for z = math.floor((pos.z - r) / CELL), math.floor((pos.z + r) / CELL) do
            for _, edge in ipairs(spatial_[x .. "_" .. z] or {}) do
                if not seen[edge] then
                    seen[edge] = true
                    if distanceToEdge(pos, edge) <= half + r then return true end
                end
            end
        end
    end
    return false
end
function Road.GetExclusions() return edges_ end
---@param pos Vector3
---@param maxDistance? number
---@return number
function Road.DistanceTo(pos, maxDistance)
    if not initialized_ then return math.huge end
    local limit = maxDistance or 256
    local best = math.huge
    local seen = {} ---@type table<CorridorRoadEdge, boolean>
    for x = math.floor((pos.x - limit) / CELL), math.floor((pos.x + limit) / CELL) do
        for z = math.floor((pos.z - limit) / CELL), math.floor((pos.z + limit) / CELL) do
            for _, edge in ipairs(spatial_[x .. "_" .. z] or {}) do
                if not seen[edge] then seen[edge] = true; best = math.min(best, distanceToEdge(pos, edge)) end
            end
        end
    end
    return best
end
function Road.GetProfile() return profile_ end
function Road.GetConnections() return loops_ end
function Road.Sample(s) return sampleProfile(s) end
function Road.GetResourcePaths() return Vehicles.GetResourcePaths() end
-- 两轴轮组采样同一真实道路曲面，胎底不是随意加一个车高。
-- direction=+1走正偏车道、-1走负偏车道，右行且不压双黄线/路肩。
---@param s number
---@param direction number
---@param kind? string
---@return Vector3,Vector3
function Road.SampleVehicle(s,direction,kind)
    local def=Vehicles.GetDefinition(kind)
    local axle=def and def.axleHalf or 2.6
    local lane=Config.Road.LaneWidth*.5*direction
    local arc=distanceAt(s)
    local front,frontRight=sampleProfile(stationAt(arc+direction*axle))
    local rear,rearRight=sampleProfile(stationAt(arc-direction*axle))
    local frontContact,rearContact=front+frontRight*lane,rear+rearRight*lane
    -- 胎底基准取两轴路面弦中点；纵坡突变也不按车高悬空。
    return (frontContact+rearContact)*.5+Vector3(0,.018,0),(frontContact-rearContact):Normalized()
end
local function material(name, color, metal)
    if not materials_[name] then materials_[name] = World.Solid(color, metal or 0, .88) end
    return materials_[name]
end
local function newBatch(root, name, color, metal)
    local batch = World.NewBatch(root:CreateChild(name), material(name, color, metal), false, 4)
    batch.geometry.viewMask = 2
    batch.geometry.drawDistance = Config.Road.DrawDistance
    return batch
end
local function strip(batch, a, b, half, raise)
    local up = Vector3(0, raise or 0, 0)
    batch:AddQuad(a.pos - a.right * half + up, b.pos - b.right * half + up,
        b.pos + b.right * half + up, a.pos + a.right * half + up)
end
local function shifted(point, lateral)
    return {pos = point.pos + point.right * lateral, right = point.right}
end
local function support(batch, a, b, data, kind)
    -- <=24m跨度中点有承托；低路段为连续实心路基，高路段为墩帽和埋地基础。
    local center = (a.pos + b.pos) * .5 --[[@as Vector3]]
    local bottom = math.min(a.foundation, b.foundation)
    local top = center.y - Config.Overpass.DeckThickness
    if kind == "overpass" and math.abs((a.lateral + b.lateral) * .5) < 24 then return end
    if top <= bottom then return end
    local d = b.pos - a.pos --[[@as Vector3]]
    local yaw = math.atan(d.x, d.z)
    local width = Config.Road.LaneWidth * 2 + Config.Road.Shoulder * 2
    if center.y - (a.ground + b.ground) * .5 < 1.4
        and (a.ground + b.ground) * .5 - bottom < 1 then
        -- 连续楔形路基逐端跟坡；不能水平盒中心高度把上坡半段悬空/埋进路面。
        local leftA, rightA = a.pos - a.right * (width * .5), a.pos + a.right * (width * .5)
        local leftB, rightB = b.pos - b.right * (width * .5), b.pos + b.right * (width * .5)
        local topA, topB = Vector3(0, -Config.Overpass.DeckThickness, 0), Vector3(0, -Config.Overpass.DeckThickness, 0)
        local al, ar, bl, br = leftA + topA, rightA + topA, leftB + topB, rightB + topB
        local da, db = Vector3(0, a.foundation - a.pos.y, 0), Vector3(0, b.foundation - b.pos.y, 0)
        local dal, dar, dbl, dbr = leftA + da, rightA + da, leftB + db, rightB + db
        batch:AddQuad(al, bl, br, ar)
        batch:AddQuad(dal, dar, dbr, dbl)
        batch:AddQuad(al, dal, dbl, bl)
        batch:AddQuad(ar, br, dbr, dar)
        batch:AddQuad(al, ar, dar, dal)
        batch:AddQuad(bl, dbl, dbr, br)
    else
        batch:AddBox(Vector3(center.x, (top + bottom) * .5, center.z), Vector3(1.5, top - bottom, 1.5), yaw)
        batch:AddBox(Vector3(center.x, bottom + .28, center.z), Vector3(3.3, .56, 3.3), yaw)
        batch:AddBox(Vector3(center.x, top - .20, center.z), Vector3(width, .4, 1.7), yaw)
        data.piers = data.piers + 1
        data.supports[#data.supports + 1] = {pos = center, bottom = bottom, top = top, kind = kind}
    end
end
-- 纯几何G编号/数字，与路牌合批；不是NanoVG/UI叠层，也不逐字建节点。
local digits = {
    ["0"] = "abcedf", ["1"] = "bc", ["2"] = "abged", ["3"] = "abgcd", ["4"] = "fgbc",
    ["5"] = "afgcd", ["6"] = "afgecd", ["7"] = "abc", ["8"] = "abcdefg", ["9"] = "abfgcd", ["G"] = "afedcg",
}
local bars = {a = {0, 1, .62, .11}, g = {0, 0, .62, .11}, d = {0, -1, .62, .11},
    f = {-.34, .5, .11, .84}, e = {-.34, -.5, .11, .84}, b = {.34, .5, .11, .84}, c = {.34, -.5, .11, .84}}
local function lettering(batch, pos, right, text, size, forward)
    local n = #text
    for i = 1, n do
        local char = text:sub(i, i)
        for bar in (digits[char] or ""):gmatch(".") do
            local v = assert(bars[bar])
            local center = pos + right * ((i - (n + 1) * .5) * .9 * size + v[1] * size) + Vector3(0, v[2] * size, 0)
            local rx, uy = right * (v[3] * size * .5), Vector3(0, v[4] * size * .5, 0)
            batch:AddQuad(center - rx - uy, center - rx + uy, center + rx + uy, center + rx - uy)
            batch:AddQuad(center + rx - uy, center + rx + uy, center - rx + uy, center - rx - uy)
        end
    end
end
---@param parent Node
---@param first number
---@param last number
---@param pause? fun()
---@return integer
function Road.BuildChunk(parent, first, last, pause)
    assert(initialized_, "[RoadCorridor] Init required")
    if last <= first then return 0 end
    local k = key(first, last)
    if chunks_[k] then return chunks_[k].vertices end
    local root = parent:CreateChild("国道_" .. k)
    local data = {root = root, vertices = 0, meshes = 0, piers = 0, length = 0, signs = 0, cameras = 0, markers = 0, lamps = 0, supports = {},vehicles=0,vehicleData={},first=first,last=last,ready=false}
    chunks_[k] = data
    -- Traffic的父节点独立于单个chunk；穿过240m接缝不销毁/重建同一辆车。
    if not trafficPool_ then
        local owner=scene_ or parent.scene
        if owner then trafficPool_=Vehicles.NewPool(owner,TRAFFIC_LIMIT) end
    end
    local asphalt = newBatch(root, "公路沥青", Color(.18, .19, .20))
    local concrete = newBatch(root, "公路梁墩与肩", Color(.50, .51, .49))
    local yellow = newBatch(root, "对向黄线", Color(.92, .67, .12))
    local white = newBatch(root, "白边线与字", Color(.88, .89, .84))
    local steel = newBatch(root, "公路护栏监控", Color(.53, .58, .60), .45)
    local green = newBatch(root, "国道绿牌", Color(.04, .26, .13))
    local red = newBatch(root, "警示标志", Color(.65, .08, .06))
    local bulbs = World.NewBatch(root:CreateChild("国道路灯灯芯"), NightLighting.GetBulbMaterial("road"), false, 1)
    bulbs.geometry.viewMask, bulbs.geometry.drawDistance = 2, 1200
    local batches = {asphalt, concrete, yellow, white, steel, green, red, bulbs}
    local width = Config.Road.LaneWidth
    local outer = width + Config.Road.Shoulder
    local function buildEdge(edge, lo, hi)
        local aa, bb = edge.a, edge.b
        local t0, t1 = 0.0, 1.0
        if edge.kind == "national" then
            t0, t1 = (lo - edge.first) / (edge.last - edge.first), (hi - edge.first) / (edge.last - edge.first)
        end
        local function interpolate(t)
            local blendRight = aa.right * (1 - t) + bb.right * t --[[@as Vector3]]
            return {pos = aa.pos + (bb.pos - aa.pos) * t, right = blendRight:Normalized(),
                foundation = aa.foundation + (bb.foundation - aa.foundation) * t,
                ground = aa.ground + (bb.ground - aa.ground) * t,
                lateral = aa.lateral + (bb.lateral - aa.lateral) * t}
        end
        local a, b = interpolate(t0), interpolate(t1)
        if edge.kind ~= "national" then
            local forward = Vector3(b.pos.x - a.pos.x, 0, b.pos.z - a.pos.z):Normalized()
            a.right, b.right = Vector3(forward.z, 0, -forward.x), Vector3(forward.z, 0, -forward.x)
        end
        strip(concrete, a, b, outer, -.025)
        strip(asphalt, a, b, width, 0)
        -- 双黄实线禁止弯道超车；白色路边线与右行语义，不伪造左行箭头。
        for _, side in ipairs({-1, 1}) do
            strip(yellow, shifted(a, side * .11), shifted(b, side * .11), .055, .015)
            strip(white, shifted(a, side * (width - .16)), shifted(b, side * (width - .16)), .065, .015)
            local low = Vector3(0, -Config.Overpass.DeckThickness, 0)
            local ap, bp = a.pos + a.right * (side * outer), b.pos + b.right * (side * outer)
            concrete:AddQuad(ap, bp, bp + low, ap + low)
            concrete:AddQuad(ap + low, bp + low, bp, ap)
            local isJunction = false
            for _, loop in ipairs(loops_) do
                local midpoint = (a.pos + b.pos) * .5
                for _, s in ipairs({loop.first, loop.last}) do
                    local connection = sampleProfile(s)
                    if flatDistance(midpoint, connection) < 15 then isJunction = true end
                end
            end
            local isCorner = false
            for _, loop in ipairs(loops_) do
                for _, stationS in ipairs(loop.crossings) do
                    for _, lateral in ipairs({-Config.Overpass.EndLateral, Config.Overpass.EndLateral}) do
                        local corner = Route.SampleOffset(stationS, lateral, loop.surfaceOffset or 1.034)
                        if flatDistance((a.pos + b.pos) * .5, corner) < 13 then isCorner = true end
                    end
                end
            end
            if not isJunction and not isCorner then
                steel:AddTube(ap + Vector3(0, .76, 0), bp + Vector3(0, .76, 0), .06, 4)
                steel:AddTube(ap + Vector3(0, .42, 0), bp + Vector3(0, .42, 0), .035, 4)
                steel:AddTube(ap, ap + Vector3(0, .86, 0), .045, 4)
            end
        end
        -- 闭合梁底，不做悬空单面路毯。
        local down = Vector3(0, -Config.Overpass.DeckThickness, 0)
        concrete:AddQuad(a.pos + a.right * outer + down, b.pos + b.right * outer + down,
            b.pos - b.right * outer + down, a.pos - a.right * outer + down)
        support(concrete, a, b, data, edge.kind)
        data.length = data.length + flatDistance(a.pos, b.pos)
    end
    for _, edge in ipairs(edges_) do
        if edge.kind == "national" then
            local lo, hi = math.max(first, edge.first), math.min(last, edge.last)
            if hi > lo then buildEdge(edge, lo, hi); pauseOnce(pause) end
        elseif edge.ownerS >= first and edge.ownerS < last then buildEdge(edge, 0, 1); pauseOnce(pause) end
    end
    -- 回环折角有同高程实铺连接面，护栏留口，避免仅中心线相接而路幅缺角。
    for _, loop in ipairs(loops_) do
        for j, s in ipairs(loop.crossings) do
            local owns = Route.ProjectApprox(Route.SampleOffset(s, 0, 0))
            if owns >= first and owns < last then
                for _, lat in ipairs({-Config.Overpass.EndLateral, Config.Overpass.EndLateral}) do
                    local pos = Route.SampleOffset(s, lat, loop.surfaceOffset or 1.034)
                    local _, _, yaw = Route.Sample(s)
                    concrete:AddBox(pos - Vector3(0, .16, 0), Vector3(outer * 2, .32, outer * 2), math.rad(yaw))
                    asphalt:AddBox(pos + Vector3(0, .004, 0), Vector3(width * 2, .008, width * 2), math.rad(yaw))
                end
            end
        end
    end
    local function signAt(s, marker)
        local pos, right = sampleProfile(s)
        local sign = pos + right * (outer + 1.2)
        local forward = Vector3(-right.z, 0, right.x)
        steel:AddTube(sign + Vector3(0, -.10, 0), sign + Vector3(0, 3.65, 0), .065, 6)
        local yaw = math.atan(forward.x, forward.z)
        green:AddBox(sign + Vector3(0, 3.1, 0), Vector3(3.6, 1.45, .13), yaw)
        lettering(white, sign + Vector3(0, 3.10, 0) - forward * .08, right,
            marker and tostring(math.floor(s / Config.Road.MarkerSpacing)) or Config.Road.Id, .48, forward)
        if marker then data.markers = data.markers + 1 else data.signs = data.signs + 1 end
        -- 路牌背面也显示G编号，两方向都可读。
        lettering(white, sign + Vector3(0, 3.10, 0) + forward * .08, right * -1, Config.Road.Id, .48, forward)
    end
    for s = math.ceil(first / Config.Road.SignSpacing) * Config.Road.SignSpacing, math.min(length_, last) - .0001, Config.Road.SignSpacing do signAt(s, false); pauseOnce(pause) end
    for s = math.ceil(first / Config.Road.MarkerSpacing) * Config.Road.MarkerSpacing, math.min(length_, last) - .0001, Config.Road.MarkerSpacing do signAt(s, true); pauseOnce(pause) end
    for s = math.ceil(first / Config.Road.CameraSpacing) * Config.Road.CameraSpacing, math.min(length_, last) - .0001, Config.Road.CameraSpacing do
        local pos, right = sampleProfile(s)
        local mast = pos - right * (outer + 1)
        steel:AddTube(mast, mast + Vector3(0, 5.8, 0), .09, 6)
        steel:AddTube(mast + Vector3(0, 5.5, 0), mast + right * 2.1 + Vector3(0, 5.5, 0), .065, 6)
        local yaw = math.atan(-right.z, right.x)
        white:AddBox(mast + right * 2.0 + Vector3(0, 5.45, 0), Vector3(.28, .23, .62), yaw)
        red:AddBox(mast + Vector3(0, 2.1, 0), Vector3(.7, .7, .10), yaw)
        data.cameras = data.cameras + 1
        pauseOnce(pause)
    end
    -- 两侧50m灯距、纵向错开25m；灯杆在护栏外，不侵入路幅/铁路包络。
    -- 只在当前chunk建合批几何与灯位，实际投光共用固定8盏道路池，不沿全线建Light。
    for _, side in ipairs({-1,1}) do
        local offset = side < 0 and 0 or 25
        local firstLamp = math.ceil((first-offset)/50)*50+offset
        for s = firstLamp, math.min(length_,last)-.0001, 50 do
            local pos, right = sampleProfile(s)
            local mast = pos + right*(side*(outer+1.0))
            local head = mast-right*(side*1.65)+Vector3(0,8.2,0)
            local forward = Vector3(-right.z,0,right.x)
            local yaw = math.atan(forward.x,forward.z)
            steel:AddTube(mast-Vector3(0,.12,0),mast+Vector3(0,8.2,0),.075,8)
            concrete:AddBox(mast+Vector3(0,.15,0),Vector3(.40,.30,.40),yaw)
            steel:AddTube(mast+Vector3(0,8.2,0),head,.055,6)
            steel:AddBox(head,Vector3(.40,.12,.95),yaw)
            bulbs:AddBox(head-Vector3(0,.10,0),Vector3(.44,.10,1.00),yaw)
            NightLighting.Register("road","road:"..k,root,head-Vector3(0,.20,0),
                (Vector3.DOWN-right*(side*.28)):Normalized(),
                {brightness=450,range=38,fov=126,aspect=.85,color=Color(1,.86,.64)})
            data.lamps = data.lamps+1
            pauseOnce(pause)
        end
    end
    -- 生产车流全部由Update驱动，不向道路静态合批加入任何车辆。
    for _, batch in ipairs(batches) do
        local n = batch:Finish()
        data.vertices = data.vertices + n
        if n > 0 then data.meshes = data.meshes + 1 end
        pauseOnce(pause)
    end
    data.ready=true
    return data.vertices
end
-- 流式可见道路的连续覆盖区；协程半成品/被父节点隐藏的区段绝不激活车辆。
local function loadedRanges()
    local ranges={}
    for _,chunk in pairs(chunks_) do
        local visible=chunk.ready
        local node=chunk.root ---@type Node?
        while visible and node do
            if not node.enabled then visible=false;break end
            node=node:GetParent()
        end
        if visible then ranges[#ranges+1]={first=chunk.first,last=chunk.last} end
    end
    table.sort(ranges,function(a,b) return a.first<b.first end)
    local merged={}
    for _,range in ipairs(ranges) do
        local previous=merged[#merged]
        if previous and range.first<=previous.last+.001 then previous.last=math.max(previous.last,range.last)
        else merged[#merged+1]={first=range.first,last=range.last} end
    end
    return merged
end
local function covering(ranges,s,half)
    local lo,hi=stationAt(distanceAt(s)-half),stationAt(distanceAt(s)+half)
    for _,range in ipairs(ranges) do
        if lo>=range.first-.001 and hi<=range.last+.001 then return range end
    end
    return nil
end
local function release(record)
    if record.lease and trafficPool_ then trafficPool_:Release(record.lease) end
    record.lease=nil;record.surface=nil;record.forward=nil
end
-- 曲率/纵坡限速由真实道路几何推导，不引用或修改铁路速度规则。
local function speedAt(s)
    local before=sampleProfile(math.max(0,s-12))
    local here=sampleProfile(s)
    local after=sampleProfile(math.min(length_,s+12))
    local a,b=here-before,after-here
    local na,nb=a:Normalized(),b:Normalized()
    local curvature=math.acos(math.max(-1,math.min(1,na:DotProduct(nb))))/math.max(1,(a:Length()+b:Length())*.5)
    return math.min(14,math.sqrt(1.45/math.max(.001,curvature)))
end
local function advanceLane(lane,direction,dt,playerS,ranges)
    local start,finish,step=#lane,1,-1
    if direction<0 then start,finish,step=1,#lane,1 end
    local leader=nil ---@type CorridorTrafficPlacement?
    for index=start,finish,step do
        local record=lane[index]
        local def=assert(Vehicles.GetDefinition(record.kind))
        local limit=direction>0 and roadLength_-END_MARGIN or END_MARGIN
        -- 已可见Node在尚未加载的道路边界前停车；不驶入空中再凭空消失。
        if record.lease then
            local region=covering(ranges,record.s,def.length*.5+.8)
            if region then
                limit=direction>0 and math.min(limit,distanceAt(region.last)-def.length*.5-1)
                    or math.max(limit,distanceAt(region.first)+def.length*.5+1)
            end
        end
        if leader then
            local frontDef=assert(Vehicles.GetDefinition(leader.kind))
            local clearance=(def.length+frontDef.length)*.5+9+record.speed*1.4
            local follow=leader.distance-direction*clearance
            limit=direction>0 and math.min(limit,follow) or math.max(limit,follow)
        end
        local remaining=math.max(0,(limit-record.distance)*direction)
        local cruise=record.lease and speedAt(record.s) or 14
        local target=math.min(cruise,math.sqrt(5*remaining))
        local velocity=math.max(0,math.min(target,record.speed+1.5*dt))
        record.distance=record.distance+direction*math.min(remaining,velocity*dt)
        record.s=stationAt(record.distance);record.speed=velocity
        leader=record
    end
    -- 开放端点只在全程不可见时回收；不在道路首尾之间做可见瞬移。
    local changed=false
    for _,record in ipairs(lane) do
        local endDistance=direction>0 and roadLength_-END_MARGIN or END_MARGIN
        if math.abs(record.distance-endDistance)<.05 and not record.lease
            and math.abs(record.s-playerS)>TRAFFIC_RANGE+250
            and math.abs((direction>0 and 0 or length_)-playerS)>TRAFFIC_RANGE+250 then
            local entry=direction>0 and END_MARGIN or roadLength_-END_MARGIN
            local safe=true
            for _,other in ipairs(lane) do
                if other~=record and math.abs(other.distance-entry)<65 then safe=false;break end
            end
            if safe then
                record.distance=entry;record.s=stationAt(entry);record.speed=0
                trafficRecycles_=trafficRecycles_+1;changed=true
            end
        end
    end
    if changed then table.sort(lane,function(a,b) return a.distance<b.distance end) end
end
local function syncTraffic(ranges,playerS)
    local pool=trafficPool_
    if not pool then return end
    -- 先归还再租借，窗口转换不临时超预算；同一辆跨chunk车保留Node身份。
    for _,record in ipairs(trafficPlan_) do
        local def=assert(Vehicles.GetDefinition(record.kind))
        if record.lease and (math.abs(record.s-playerS)>TRAFFIC_RANGE
            or not covering(ranges,record.s,def.length*.5+.8)) then release(record) end
    end
    for _,record in ipairs(trafficPlan_) do
        local def=assert(Vehicles.GetDefinition(record.kind))
        if math.abs(record.s-playerS)<=TRAFFIC_RANGE and covering(ranges,record.s,def.length*.5+.8) then
            if not record.lease then record.lease=pool:Acquire(record.id,record.kind) end
            if record.lease then
                local surface,forward=Road.SampleVehicle(record.s,record.direction,record.kind)
                if Vehicles.Pose(record.lease.node,surface,forward,record.kind) then
                    record.surface=surface;record.forward=forward;record.lease.node.enabled=true
                end
            end
        end
    end
    trafficMaxActive_=math.max(trafficMaxActive_,pool.active)
end
-- main每渲染帧在WorldStream.Update后传入已模拟dt，暂停传0。
-- 不订阅独立Update事件，避免菜单暂停/加载期间偷偷推进或双重积分。
---@param dt number
---@param playerS number
function Road.Update(dt,playerS)
    if not initialized_ or type(playerS)~="number" or playerS~=playerS or math.abs(playerS)==math.huge then return end
    trafficPlayerS_=math.max(0,math.min(length_,playerS))
    local valid=type(dt)=="number" and dt==dt and dt>=0 and dt<math.huge
    local delta=valid and math.min(dt,1) or 0
    trafficPaused_=delta==0
    local ranges=loadedRanges()
    -- 分片跟车避免低帧率穿过前车；不会把后台wallDt追偿为一次几十米瞬移。
    local remaining=delta
    while remaining>.000001 do
        local step=math.min(.1,remaining)
        for _,direction in ipairs({-1,1}) do advanceLane(lanes_[direction],direction,step,trafficPlayerS_,ranges) end
        remaining=remaining-step
    end
    trafficTime_=trafficTime_+delta
    if delta>0 then trafficUpdates_=trafficUpdates_+1 end
    syncTraffic(ranges,trafficPlayerS_)
end
function Road.ResetTraffic()
    for _,record in ipairs(trafficPlan_) do release(record) end
    trafficPlan_,lanes_={},{}
    trafficTime_,trafficUpdates_,trafficRecycles_,trafficMaxActive_=0,0,0,0
    if initialized_ then planTraffic() end
end
-- 快照只含副本数字/Vector3和只读观测用Node；调用者不能改变生产record。
---@class CorridorRoadTrafficSnapshot
---@field id string
---@field kind string
---@field s number
---@field direction number
---@field speed number
---@field node Node
---@field position Vector3
---@field surface Vector3?
---@field forward Vector3?
---@field width number
---@field length number
---@field height number
---@field visible boolean
---@return CorridorRoadTrafficSnapshot[]
function Road.GetTrafficVehicles()
    local rows={} ---@type CorridorRoadTrafficSnapshot[]
    for _,record in ipairs(trafficPlan_) do
        if record.lease then
            local def=assert(Vehicles.GetDefinition(record.kind))
            rows[#rows+1]={id=record.id,kind=record.kind,s=record.s,direction=record.direction,
                speed=record.speed,node=record.lease.node,position=record.lease.node.worldPosition,
                surface=record.surface,forward=record.forward,width=def.width,length=def.length,height=def.height,
                visible=record.lease.node.enabled}
        end
    end
    return rows
end
function Road.GetTrafficStats()
    local pool=trafficPool_
    local positive,negative,moving,buses=0,0,0,0
    for _,record in ipairs(trafficPlan_) do
        if record.lease then
            if record.direction>0 then positive=positive+1 else negative=negative+1 end
            if record.speed>.05 then moving=moving+1 end
            if record.kind=="bus" then buses=buses+1 end
        end
    end
    return {mode="dynamic",time=trafficTime_,updates=trafficUpdates_,paused=trafficPaused_,planned=#trafficPlan_,
        active=pool and pool.active or 0,moving=moving,positive=positive,negative=negative,buses=buses,
        poolSize=pool and #pool.leases or 0,poolCreated=pool and pool.created or 0,poolReused=pool and pool.reused or 0,
        maxVehicles=TRAFFIC_LIMIT,maxActive=trafficMaxActive_,recycles=trafficRecycles_,staticVehicles=0,
        playerS=trafficPlayerS_,roadLength=roadLength_,rightHandTraffic=true}
end
function Road.ForgetChunk(first, last)
    local k = key(first, last)
    NightLighting.Forget("road:"..k)
    chunks_[k] = nil -- 几何节点统一由WorldStream拥有和释放。
    local ranges=loadedRanges()
    for _,record in ipairs(trafficPlan_) do
        if record.lease then
            local def=assert(Vehicles.GetDefinition(record.kind))
            if not covering(ranges,record.s,def.length*.5+.8) then release(record) end
        end
    end
end
function Road.GetMeshes()
    local out = {} ---@type CustomGeometry[]
    for _, data in pairs(chunks_) do
        for _, mesh in ipairs(data.root:GetComponents("CustomGeometry", true)) do out[#out + 1] = mesh end
    end
    return out
end
function Road.GetStats()
    local traffic=Road.GetTrafficStats()
    local stats = {initialized = initialized_, routeId = Config.Road.Id, trafficMode = "dynamic", movingVehicles = traffic.moving,
        traffic=traffic,
        crossings = {}, plannedLength = length_, plannedEdges = #edges_, bypasses = bypasses_, connectedLoops = #loops_,
        maxGrade = maxGrade_, maxSurfaceY = maxHeight_, minOverpassClearance = minClearance_ < math.huge and minClearance_ or 0,
        loadedChunks = 0, vehicles=0, vehicleData={}, vertices = 0, meshes = 0, piers = 0, signs = 0, cameras = 0, markers = 0, lamps = 0, length = 0,
        rightHandTraffic = true, mainLateral = Config.Road.Lateral, stationLateral = Config.Road.StationLateral, supports = {}}
    for _, data in pairs(chunks_) do
        stats.loadedChunks = stats.loadedChunks + 1
        stats.vehicles=stats.vehicles+data.vehicles
        for _,record in ipairs(data.vehicleData) do stats.vehicleData[#stats.vehicleData+1]=record end
        for _, field in ipairs({"vertices", "meshes", "piers", "signs", "cameras", "markers", "lamps", "length"}) do stats[field] = stats[field] + data[field] end
        for _, supportData in ipairs(data.supports) do stats.supports[#stats.supports + 1] = supportData end
    end
    stats.vehicleData=Road.GetTrafficVehicles();stats.vehicles=traffic.active
    return stats
end
function Road.Shutdown()
    -- 动态池由本模块独占，先归还引用再释放；道路几何仍由流式父节点释放。
    for _,record in ipairs(trafficPlan_) do release(record) end
    if trafficPool_ then trafficPool_:Dispose();trafficPool_=nil end
    for k in pairs(chunks_) do NightLighting.Forget("road:"..k) end
    scene_ = nil
    profile_, edges_, spatial_, chunks_, loops_, terrainDefinitions_ = {}, {}, {}, {}, {}, {}
    trafficPlan_,movingPlan_,lanes_,roadDistances_={},{},{},{}
    trafficTime_,trafficUpdates_,trafficPlayerS_,trafficRecycles_,trafficMaxActive_,roadLength_=0,0,0,0,0,0
    trafficPaused_=false
    initialized_, maxGrade_, maxHeight_, minClearance_, length_, bypasses_ = false, 0.0, 0.0, math.huge, 0.0, 0
end

-- 隔离受控道口逻辑fixture，不注册高速线，也不生成孤立短铁轨。
-- 输入完整列车占用区间（包含静止尾车），双向/多编组均参与；探测未知则关闭。
local ControlledCrossing = {}
ControlledCrossing.__index = ControlledCrossing
function Road.NewControlledCrossing(options)
    local fixture = setmetatable({}, ControlledCrossing)
    fixture:Init(options)
    return fixture
end
function ControlledCrossing:Init(options)
    self.s = assert(options.s)
    self.config = Config.Crossing
    self.state, self.angle, self.clearTime, self.warningTime = "closed", 0.0, 0.0, 0.0
    self.warning = true
end
function ControlledCrossing:Update(dt, occupancies)
    local validDelta = type(dt) == "number" and dt == dt and dt > 0 and dt < math.huge
    local delta = validDelta and dt or 0
    local occupied = type(occupancies) ~= "table" or not validDelta
    if not occupied then
        for _, train in ipairs(occupancies) do
            if type(train) ~= "table" then occupied = true; break end
            local first, last = train.first or train.rear, train.last or train.front
            if type(first) ~= "number" or type(last) ~= "number" or first ~= first or last ~= last
                or math.abs(first) == math.huge or math.abs(last) == math.huge then occupied = true; break end
            local rawSpeed = train.speed or 0
            if type(rawSpeed) ~= "number" or rawSpeed ~= rawSpeed or math.abs(rawSpeed) == math.huge then occupied = true; break end
            local lo, hi = math.min(first, last), math.max(first, last)
            local speed = math.abs(rawSpeed)
            local approach = math.max(self.config.MinimumApproach, speed * self.config.WarningSeconds)
            if self.s >= lo - approach and self.s <= hi + approach then occupied = true end
        end
    end
    if occupied then
        self.state, self.angle, self.clearTime, self.warningTime, self.warning = "closed", 0.0, 0.0, 0.0, true
    else
        self.clearTime = self.clearTime + delta
        if self.clearTime < self.config.ClearHoldSeconds then
            self.state, self.warning = "holding", true
        else
            self.angle = math.min(90, self.angle + 90 * delta / self.config.OpenSeconds)
            self.state = self.angle >= 90 and "open" or "opening"
            self.warning = self.state ~= "open"
        end
    end
    return self:GetState()
end
function ControlledCrossing:GetState() return {state = self.state, angle = self.angle, warning = self.warning} end
Road.ControlledCrossing = ControlledCrossing
return Road
