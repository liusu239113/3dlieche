-- 隔离走廊验收：只加载静态世界模块，不加载main/Game/Save/云API，不写玩家存档。
-- 运行入口 tests/CorridorValidation.lua；报告由引擎-validate-output写入.tmp。
local Route = require "world.Route"
local Landscape = require "world.Landscape"
local Landmarks = require "world.Landmarks"
local Road = require "world.RoadCorridor"
local Scenery = require "world.RailwayScenery"
local Config = require "config.CorridorConfig"
local Validation = {}
---@type Scene?
local scene_ = nil
local checks_ = 0
local function check(value, message)
    checks_ = checks_ + 1
    assert(value, "[CorridorValidation] " .. message)
end
local function close(a, b, message) check(math.abs(a - b) < .0001, message) end
local function signature()
    local parts = {}
    for _, plot in ipairs(Scenery.GetExclusions()) do parts[#parts + 1] = string.format("%s:%.3f:%.3f:%.3f", plot.kind, plot.s, plot.lateral, plot.radius) end
    return table.concat(parts, "|")
end
local function meshCount(meshes)
    local count = 0
    for _, geometry in ipairs(meshes) do
        for slot = 0, geometry.numGeometries - 1 do
            local n = geometry:GetNumVertices(slot)
            check(n % 3 == 0, "三角形顶点数")
            for v = 0, n - 1 do
                local p = geometry:GetVertex(slot, v).position
                check(p.x == p.x and p.y == p.y and p.z == p.z, "网格NaN")
                check(math.abs(p.x) < 1000000 and math.abs(p.z) < 1000000 and p.y > -100 and p.y < 200, "网格越界")
            end
            count = count + n
        end
    end
    return count
end
local function fixture()
    check(#Road.GetStats().crossings == 0 and #Config.Crossing.Definitions == 0, "高速干线不得注册平交")
    local c = Road.NewControlledCrossing({s = 1000})
    check(c:Update(.1, nil).state == "closed", "探测未知必须关闭")
    for _ = 1, 150 do c:Update(.1, {}) end
    check(c:GetState().state == "open", "全线净空后开放fixture")
    check(c:Update(.1, {{first = 700, last = 950, speed = 0}}).state == "closed", "静止编组尾部占用不能开放")
    check(c:Update(.1, {{first = 1200, last = 1500, speed = -20}}).state == "closed", "反向接近检测")
    check(c:Update(.1, {{first = 5000, last = 5200, speed = 0}, {first = 1050, last = 1250, speed = 0}}).state == "closed", "多列车完整占用检测")
    check(c:Update(.1, {{first = 0 / 0, last = 900, speed = 0}}).state == "closed", "异常探测fail closed")
    check(c:Update(.1, {{first = 4000, last = 4100, speed = 0 / 0}}).state == "closed", "NaN速度fail closed")
    check(c:Update(.1, {{first = 4000, last = math.huge, speed = 0}}).state == "closed", "无穷区间fail closed")
    check(c:Update(.1, {false}).state == "closed", "坏记录fail closed")
end
function Validation.Run()
    checks_ = 0
    Route.Build()
    Landmarks.Init()
    Landscape.Init()
    scene_ = Scene()
    scene_:CreateComponent("Octree")
    Road.Init(scene_)
    Scenery.Init(scene_)
    local roadStats = Road.GetStats()
    check(roadStats.maxGrade <= .06 + .000001, "国道/上跨坡度上限")
    local tunnelCount=0
    for _,def in ipairs(Landmarks.GetDefinitions()) do if def.kind=="tunnel" then tunnelCount=tunnelCount+1 end end
    check(roadStats.bypasses == tunnelCount and tunnelCount>=7, "全部真实隧道均有山外连续绕行")
    print(string.format("[CorridorValidation] maxSurfaceY=%.3f", roadStats.maxSurfaceY))
    check(roadStats.maxSurfaceY < 35, "禁止巨高绕山悬坡")
    check(roadStats.movingVehicles == 0 and roadStats.trafficMode == "dynamic"
        and Road.GetTrafficStats().poolSize == 0, "未加载道路前不得激活动态车辆")
    check(#Road.GetProfile() > 1000, "解析全线道路规划")
    local oldCallback = function(pos, r, purpose) return Road.IsExcluded(pos, r, purpose) or Scenery.IsExcluded(pos, r, purpose) end
    Landscape.SetCorridorExclusion(oldCallback)
    for _, station in ipairs(Route.GetStations()) do
        local pos, _, lat = Road.Sample(station.s)
        close(lat, 128, "站区国道应正侧128")
        check(Road.IsExcluded(pos, 0, "legacy"), "未加载站区道路保留")
        check(not Road.IsExcluded(Route.SampleOffset(station.s, -68, 0), 5, "legacy"), "站房负68不得被镜像国道吞掉")
    end
    local profile = Road.GetProfile()
    for i = 1, #profile - 1 do
        local a, b = profile[i], profile[i + 1]
        local delta = b.pos - a.pos
        local horizontal = math.sqrt(delta.x * delta.x + delta.z * delta.z)
        check(horizontal > 0 and math.abs(delta.y) / horizontal <= .060001, "道路实顶点坡度")
        check(a.pos.y - Config.Overpass.DeckThickness >= a.ground + .15, "路梁底不得埋入地表保守包络")
        check(Road.IsExcluded((a.pos + b.pos) * .5, 0, "legacy"), "未加载道路保留不能漏段")
    end
    local definitions = Landmarks.GetDefinitions()
    for _, def in ipairs(definitions) do
        if def.kind == "tunnel" then
            for s = def.first, def.last, 24 do
                local _, _, lat = Road.Sample(s)
                check(lat - (Config.Road.LaneWidth + Config.Road.Shoulder) > def.lateral + def.halfWidth * 1.14, "绕行与山壳最大偏心包络净空")
            end
        end
    end
    -- 整块与任意切片的顶点边界必须落在同一个解析路面上。
    for s = 123.25, 32000, 517.75 do
        local point, right = Road.Sample(s)
        check(Road.IsExcluded(point + right * 4.6, .2, "legacy"), "道路完整肩部保留")
        check(Road.DistanceTo(point) < .01, "距离接口不是实际中心线（原生float容差1cm）")
    end
    local planned = signature()
    local stats = Scenery.GetStats()
    for _, kind in ipairs({"village", "greenhouse", "field", "pond", "factory", "mine", "power", "telecom"}) do
        check((stats.plannedKinds[kind] or 0) > 0, "缺少乡野种类：" .. kind)
    end
    for _, plot in ipairs(Scenery.GetExclusions()) do
        check(Scenery.IsExcluded(plot.pos, 0, "legacy"), "未加载景观保留")
        check(not Road.IsExcluded(plot.pos, plot.radius, "scenery"), "新景观压路")
        check(Route.DistanceTo(plot.pos) - plot.radius >= 32, "全股道建筑限界")
        check(not Landscape.InCity(plot.pos, plot.radius), "旧城市冲突")
        check(not Landmarks.Reserves(plot.pos, plot.radius), "旧桥隧/山体冲突")
    end
    -- 闭合农村路的每个端点必须接另一条边或国道，实查几何而非自报连续。
    check(roadStats.connectedLoops == 1, "当前线路应生成一个完整上跨回环")
    close(roadStats.minOverpassClearance, 9, "上跨梁底距轨面9米")
    for _, loop in ipairs(Road.GetConnections()) do
        for _, edge in ipairs(loop.edges) do
            for _, p in ipairs({edge.a, edge.b}) do
                local connections = 0
                for _, other in ipairs(loop.edges) do
                    if other ~= edge then
                        local start=other.a.pos --[[@as Vector3]]
                        local finish=other.b.pos --[[@as Vector3]]
                        local position=p.pos --[[@as Vector3]]
                        if (start-position):Length() < .01 or (finish-position):Length() < .01 then connections = connections + 1 end
                    end
                end
                if connections == 0 then
                    local onNational = false
                    for _, s in ipairs({loop.first, loop.last}) do if (Road.Sample(s) - p.pos):Length() < .01 then onNational = true end end
                    check(onNational, "上跨农村路存在断头端点")
                end
            end
        end
        local loopStart, loopEnd = loop.first - 240, loop.last + 240
        Road.BuildChunk(scene_, loopStart, loopEnd)
        local actual = Road.GetStats()
        check(actual.piers > 0, "真实上跨支承未生成")
        for _, support in ipairs(actual.supports) do
            check(support.bottom <= -.50, "墩基未落地")
            local _, s = Route.DistanceTo(support.pos)
            local lateral = (support.pos - Route.Sample(s)):DotProduct(Route.RightAt(s))
            check(math.abs(lateral) >= 23, "上跨桥墩侵入铁路限界")
        end
        check(meshCount(Road.GetMeshes()) == actual.vertices, "上跨实顶点计数")
        Road.ForgetChunk(loopStart, loopEnd)
    end
    -- 跨谷真实梁墩：基础抵达负38/46m河床以下，不允许以低桥面冒充填河土墙。
    for _, def in ipairs(definitions) do
        if def.kind == "bridge" then
            local a, b = def.s - 60, def.s + 60
            local owner = scene_:CreateChild("跨谷测试自有父节点")
            Road.BuildChunk(owner, a, b)
            local supports = Road.GetStats().supports
            check(#supports > 0, "跨谷无真实桥墩")
            for _, support in ipairs(supports) do check(support.bottom <= -def.depth, "跨谷墩底悬空") end
            Road.ForgetChunk(a, b)
            owner:Dispose()
        end
    end
    -- 切块接缝、重复构建、卸载及重建；所有测试根节点自有。
    local first, last = 3000.0, 3240.0
    local count = Road.BuildChunk(scene_, first, last)
    check(count > 0, "公路网格未生成")
    close(Road.BuildChunk(scene_, first, last), count, "重复构建必须幂等")
    check(meshCount(Road.GetMeshes()) == count, "公路返回顶点数必须等于实际几何")
    local testPlot = Scenery.GetExclusions()[1]
    check(testPlot ~= nil, "景观空规划")
    local a = math.floor(testPlot.s / 240) * 240
    local rural = Scenery.BuildChunk(scene_, a, a + 240)
    check(rural > 0 and meshCount(Scenery.GetMeshes()) == rural, "景观真实网格/返回数")
    Road.ForgetChunk(first, last)
    Scenery.ForgetChunk(a, a + 240)
    check(Road.GetStats().vertices == 0 and Scenery.GetStats().vertices == 0, "卸载统计释放")
    check(Road.IsExcluded(Road.Sample(first), 0, "legacy"), "卸载不可撤销道路保留")
    check(signature() == planned, "卸载不可撤销景观保留")
    close(Road.BuildChunk(scene_, first, last), count, "重建顶点数不确定")
    Road.ForgetChunk(first, last)
    -- 全种类实际生成，再直接检查每一个提交的三角形顶点，不只验证计数器。
    local built = {} ---@type table<string, boolean>
    for _, plot in ipairs(Scenery.GetExclusions()) do
        if not built[plot.kind] then
            local start = math.floor(plot.s / 240) * 240
            Scenery.BuildChunk(scene_, start, start + 240)
            built[plot.kind] = true
        end
    end
    check(meshCount(Scenery.GetMeshes()) == Scenery.GetStats().vertices, "所有乡野种类实际顶点计数")
    fixture()
    Scenery.Init(scene_)
    check(signature() == planned, "相同种子/加载顺序规划不确定")
    Landscape.SetCorridorExclusion(nil)
    Scenery.Shutdown()
    Road.Shutdown()
    check(not Road.GetStats().initialized and not Scenery.GetStats().initialized, "Shutdown不得偷偷重初始化")
    scene_:Dispose()
    scene_ = nil
    print(string.format("[CorridorValidation] PASS %d checks; 没有加载main/Save/云API", checks_))
    return checks_
end
function Start() Validation.Run() end
return Validation
