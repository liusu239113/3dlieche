-- 平坦铁路基准、低饱和草地、稀疏树丛及规划式小聚落。
-- 不再创建锥体山、横穿铁路的道路或随机高塔。
local Route = require "world.Route"
local World = require "world.WorldMaterials"
local Terrain = {}
---@type Scene|nil
local scene_ = nil
---@type table[]
local placementData_ = {}
local seed_ = 20261006
local function random()
    seed_ = (seed_ * 48271) % 2147483647 -- 确定性整数伪随机，保证每次布局一致
    return seed_ / 2147483647
end
local function range(a, b) return a + (b - a) * random() end

---@param pos Vector3
local function inStationYard(pos)
    for _, st in ipairs(Route.GetStations()) do
        local origin, tangent = Route.Sample(st.s)
        local right = Route.RightAt(st.s)
        local offset = pos - origin
        local along = offset:DotProduct(tangent)
        local lateral = offset:DotProduct(right)
        if along > Route.PlatformStart - 35 and along < Route.PlatformEnd + 35
            and math.abs(lateral) < 95 then return true end
    end
    return false
end

---@param scene Scene
function Terrain.Build(scene)
    scene_ = scene
    seed_ = 20261006
    placementData_ = {}
    local t0 = os.clock()
    Terrain.BuildGround()
    Terrain.BuildHills()
    Terrain.BuildCity()
    Terrain.BuildTrees()
    print(string.format("[Terrain] 平坦铁路环境构建完成，耗时 %.2f 秒", os.clock() - t0))
end

function Terrain.BuildGround()
    if not scene_ then return end
    local minX, maxX, minZ, maxZ = 0.0, 0.0, 0.0, 0.0
    for _, p in ipairs(Route.GetPoints()) do
        minX, maxX = math.min(minX, p.pos.x), math.max(maxX, p.pos.x)
        minZ, maxZ = math.min(minZ, p.pos.z), math.max(maxZ, p.pos.z)
    end
    -- 覆盖相机 2600 米远裁剪范围，不再按全线长度随意偏移地面。
    -- 草地 Y=-0.006，道床坡脚 Y=+0.002，避免共面闪烁。
    -- 草地 7 米平铺，降低近处噪点及重复方格感。
    local margin = 3000
    minX, maxX, minZ, maxZ = minX - margin, maxX + margin, minZ - margin, maxZ + margin
    local ground = World.NewBatch(scene_:CreateChild("Ground"), World.Grass(), false, 7.0)
    ground:AddQuad(Vector3(minX, -0.006, minZ), Vector3(minX, -0.006, maxZ),
        Vector3(maxX, -0.006, maxZ), Vector3(maxX, -0.006, minZ))
    ground:Finish()
    print(string.format("[Terrain] 地面 Y=-0.006，边界 X=%.0f..%.0f、Z=%.0f..%.0f", minX, maxX, minZ, maxZ))
end

-- 保留接口；本次平坦基准模式不创建突出地面的山体。
function Terrain.BuildHills()
    print("[Terrain] 平坦基准模式：已取消锥体山")
end

-- 每站外侧规划四栋小建筑，不在环线内侧堆随机楼房。
-- 完整屋檐外包圆到整条闭合线路任意部分必须至少 25.01 米，否则拒绝。
function Terrain.BuildCity()
    if not scene_ then return end
    local root = scene_:CreateChild("City")
    local walls = World.NewBatch(root:CreateChild("SettlementWalls"), World.Brick(), true, 1)
    local plinth = World.NewBatch(root:CreateChild("SettlementTrim"), World.Concrete(), true, 1)
    local roofs = World.NewBatch(root:CreateChild("SettlementRoofs"), World.Solid(Color(0.32, 0.29, 0.26), 0, 0.92), true)
    local glass = World.NewBatch(root:CreateChild("SettlementWindows"), World.Solid(Color(0.20, 0.28, 0.32), 0.12, 0.28), false)
    local rejected = 0
    for _, st in ipairs(Route.GetStations()) do
        local _, _, yaw = Route.Sample(st.s)
        local angle = math.rad(yaw)
        local co, si = math.cos(angle), math.sin(angle)
        for i, along in ipairs({ -170, -115, 20, 70 }) do
            local center = Route.SampleOffset(st.s + along, -128, 0)
            local w, d, h = 12.0, 16.0, (i % 2 == 0 and 7.0 or 5.0)
            local radius = math.sqrt((w / 2 + 0.6)^2 + (d / 2 + 0.6)^2)
            local clearance = Route.DistanceTo(center) - radius
            if Route.CanPlaceFootprint(center, radius) then
                walls:AddBox(center + Vector3(0, h / 2, 0), Vector3(w, h, d), angle)
                plinth:AddBox(center + Vector3(0, 0.25, 0), Vector3(w + 0.3, 0.5, d + 0.3), angle)
                roofs:AddBox(center + Vector3(0, h + 0.08, 0), Vector3(w + 1.0, 0.16, d + 1.0), angle)
                local function world(x, y, z)
                    return Vector3(center.x + x * co + z * si, y, center.z - x * si + z * co)
                end
                for side = -1, 1, 2 do
                    for _, z in ipairs({ -5, 0, 5 }) do
                        glass:AddBox(world(side * (w / 2 + 0.025), 2.55, z), Vector3(0.04, 1.55, 1.8), angle)
                        plinth:AddBox(world(side * (w / 2 + 0.06), 3.38, z), Vector3(0.10, 0.12, 2.0), angle)
                    end
                end
                placementData_[#placementData_ + 1] = {
                    name = st.name .. "_House_" .. i, x = center.x, z = center.z,
                    radius = radius, clearance = clearance,
                }
            else rejected = rejected + 1 end
        end
    end
    walls:Finish(); plinth:Finish(); roofs:Finish(); glass:Finish()
    print(string.format("[Terrain] 规划小建筑 %d 栋，拒绝不安全布局 %d 栋；全线路净空至少 25 米", #placementData_, rejected))
end

function Terrain.BuildTrees()
    if not scene_ then return end
    local root = scene_:CreateChild("Forest")
    local trunkMat = World.Solid(Color(0.29, 0.25, 0.20), 0, 0.95)
    local leafMat = {
        World.Solid(Color(0.25, 0.34, 0.23), 0, 0.98),
        World.Solid(Color(0.31, 0.38, 0.27), 0, 0.98),
    }
    -- 160 米空间分块合并，不为每棵树创建独立绘制调用。
    -- 细锥度树干加两组非对称椭球树冠，避免大锥体玩具轮廓。
    ---@type table<string, {trunk: RailwayBatch, leaves: RailwayBatch[]}>
    local chunks = {}
    ---@type table[]
    local occupied = {}
    local accepted, rejected = 0, 0
    for i = 1, 230 do
        local s = (i - 0.5) / 230 * Route.GetLength()
        local side = i % 3 == 0 and 1 or -1
        local pos = Route.SampleOffset(s, side * range(42, 190), 0)
        local crownWidth = range(3.0, 4.4)
        local radius = crownWidth * 1.30
        local safe = Route.CanPlaceFootprint(pos, radius, 30) and not inStationYard(pos)
        for _, building in ipairs(placementData_) do
            local dx, dz = pos.x - building.x, pos.z - building.z
            if dx * dx + dz * dz < (building.radius + radius + 6)^2 then safe = false end
        end
        for _, other in ipairs(occupied) do
            local dx, dz = pos.x - other.x, pos.z - other.z
            if dx * dx + dz * dz < 11^2 then safe = false end
        end
        if safe then
            local key = math.floor(pos.x / 160) .. "_" .. math.floor(pos.z / 160)
            local group = chunks[key]
            if not group then
                local node = root:CreateChild("Grove_" .. key)
                group = {
                    trunk = World.NewBatch(node:CreateChild("Trunks"), trunkMat, true),
                    leaves = {
                        World.NewBatch(node:CreateChild("LeavesA"), leafMat[1], true),
                        World.NewBatch(node:CreateChild("LeavesB"), leafMat[2], true),
                    },
                }
                chunks[key] = group
            end
            local height = range(7.5, 11.5)
            local trunkH = height * 0.57
            -- 八边形细锥度树干，全部使用实际米制尺寸。
            for sector = 1, 8 do
                local a, b = 2 * math.pi * (sector - 1) / 8, 2 * math.pi * sector / 8
                local r0, r1 = 0.23, 0.12
                group.trunk:AddQuad(
                    pos + Vector3(math.cos(a) * r0, 0, math.sin(a) * r0),
                    pos + Vector3(math.cos(a) * r1, trunkH, math.sin(a) * r1),
                    pos + Vector3(math.cos(b) * r1, trunkH, math.sin(b) * r1),
                    pos + Vector3(math.cos(b) * r0, 0, math.sin(b) * r0))
            end
            local leaves = group.leaves[i % 2 + 1]
            if leaves then
                leaves:AddCrown(pos + Vector3(0, height * 0.69, 0),
                    Vector3(crownWidth, height * 0.32, crownWidth * 0.85), range(0, 6.28))
                leaves:AddCrown(pos + Vector3(crownWidth * 0.35, height * 0.65, crownWidth * 0.17),
                    Vector3(crownWidth * 0.72, height * 0.25, crownWidth * 0.63), range(0, 6.28))
            end
            accepted = accepted + 1
            occupied[#occupied + 1] = { x = pos.x, z = pos.z }
        else rejected = rejected + 1 end
    end
    local meshes = 0
    for _, group in pairs(chunks) do
        if group.trunk:Finish() > 0 then meshes = meshes + 1 end
        for _, leaves in ipairs(group.leaves) do
            if leaves:Finish() > 0 then meshes = meshes + 1 end
        end
    end
    print(string.format("[Terrain] 树木 %d 棵/拒绝 %d 棵，%d 个空间网格；完整树冠净空至少 30 米", accepted, rejected, meshes))
end

function Terrain.GetPlacementData() return placementData_ end
return Terrain
