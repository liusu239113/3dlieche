-- 真实尺度直线站台、薄钢结构雨棚及单侧站房。
local Route = require "world.Route"
local World = require "world.WorldMaterials"
local Station = {}

-- 净空截面：3.1 米车体占 [-1.55,+1.55]，站台从 +/-1.75 开始，
-- 单侧间隙 0.20 米，不能把轨距当作车宽；雨棚内边 +/-2.25，柱在 +/-7.65。
-- 站房连同屋檐对完整闭合线路检测净空，不只对所在站的局部线路。
--    站房 >=25米 | 7米站台 | .20间隙 | 列车 | .20间隙 | 7米站台
-- 站台绝对顶面=0.34+1.10=1.44 米，基座底面=-0.02 米。
-- 完整站台处于直线内，覆盖 [停靠点-225,停靠点+85] 及八节编组尾部。
local INNER = 1.75
local WIDTH = 7.0
local PLATFORM_Y = 1.44
local CANOPY_INNER = 2.25
local CANOPY_OUTER = 8.65
local CANOPY_Y = PLATFORM_Y + 4.60
---@type table[]
local placementData_ = {}

local function point(st, along, lateral, y)
    return Route.SampleOffset(st.s + along, lateral, y)
end
local function batch(root, name, material, shadows, tile)
    return World.NewBatch(root:CreateChild(name), material, shadows, tile)
end

---@param scene Scene
function Station.Build(scene)
    local root = scene:CreateChild("Stations")
    placementData_ = {}
    local t0 = os.clock()
    for _, st in ipairs(Route.GetStations()) do
        local node = root:CreateChild("Station_" .. st.name)
        local _, _, yaw = Route.Sample(st.s)
        local angle = math.rad(yaw)
        local platform = batch(node, "ConcretePlatforms", World.Concrete(), false, 1)
        local coping = batch(node, "PaleCoping", World.Solid(Color(0.77, 0.78, 0.75), 0, 0.92), false)
        local safety = batch(node, "SafetyLines", World.Solid(Color(0.80, 0.68, 0.24), 0, 0.88), false)
        local roof = batch(node, "ThinBlueCanopies", World.Solid(Color(0.18, 0.36, 0.48), 0.40, 0.58), true)
        local frame = batch(node, "CanopySteel", World.Solid(Color(0.51, 0.54, 0.55), 0.72, 0.43), true)
        local first, last = Route.PlatformStart, Route.PlatformEnd
        local middle, span = (first + last) / 2, last - first
        for side = -1, 1, 2 do
            platform:AddBox(point(st, middle, side * (INNER + WIDTH / 2), (PLATFORM_Y - 0.02) / 2),
                Vector3(WIDTH, PLATFORM_Y + 0.02, span), angle)
            coping:AddBox(point(st, middle, side * (INNER + 0.19), PLATFORM_Y + 0.025),
                Vector3(0.38, 0.05, span), angle)
            safety:AddBox(point(st, middle, side * (INNER + 0.80), PLATFORM_Y + 0.053),
                Vector3(0.16, 0.016, span), angle)
            -- 170 米长薄钢雨棚退让出列车限界，厚度仅 0.12 米。
            -- 铁路正上方保持开敞，不使用巨大不透明块体。
            local canopyMiddle, canopySpan = -55.0, 170.0
            roof:AddBox(point(st, canopyMiddle, side * ((CANOPY_INNER + CANOPY_OUTER) / 2), CANOPY_Y),
                Vector3(CANOPY_OUTER - CANOPY_INNER, 0.12, canopySpan), angle)
            for ds = -139, 29, 12 do
                frame:AddBox(point(st, ds, side * 7.65, PLATFORM_Y + 2.25), Vector3(0.16, 4.50, 0.16), angle)
                frame:AddBox(point(st, ds, side * 5.45, CANOPY_Y - 0.19), Vector3(6.4, 0.16, 0.10), angle)
            end
            for _, lat in ipairs({ 2.35, 8.55 }) do
                frame:AddBox(point(st, canopyMiddle, side * lat, CANOPY_Y - 0.18), Vector3(0.08, 0.16, canopySpan), angle)
            end
        end
        platform:Finish(); coping:Finish(); safety:Finish(); roof:Finish(); frame:Finish()
        Station.BuildPlatformSigns(node, st)
        Station.BuildBuilding(node, st)
        Station.BuildProps(node, st, nil, PLATFORM_Y)
        print(string.format("[Station] %s：站台 310 米，内边 1.75 米/间隙 0.20 米，顶面 1.44 米，雨棚内边 2.25 米",
            st.name))
    end
    print(string.format("[Station] 五站构建完成，取消几何玩具行人，耗时 %.2f 秒", os.clock() - t0))
    return root
end

function Station.BuildPlatformSigns(root, st)
    local steel = batch(root, "SignPosts", World.Solid(Color(0.40, 0.43, 0.44), 0.7, 0.48), true)
    local boards = batch(root, "BlueNameBoards", World.Solid(Color(0.09, 0.22, 0.33), 0.1, 0.75), false)
    local _, _, yaw = Route.Sample(st.s)
    for side = -1, 1, 2 do
        for _, ds in ipairs({ -175, -60, 65 }) do
            local position = point(st, ds, side * 7.2, PLATFORM_Y)
            steel:AddBox(position + Vector3(0, 1.3, 0), Vector3(0.07, 2.6, 0.07), math.rad(yaw))
            boards:AddBox(position + Vector3(0, 2.50, 0), Vector3(0.10, 0.70, 3.0), math.rad(yaw))
            local label = root:CreateChild("StationName")
            label.position = point(st, ds, side * 7.12, PLATFORM_Y + 2.5)
            label.rotation = Quaternion(yaw + (side < 0 and 90 or -90), Vector3.UP)
            Station.MakeWorldSign(label, st.name, 0.28)
        end
    end
    steel:Finish(); boards:Finish()
end

-- 每站仅建一座 14×54 米适中站房，退让出相机摆动空间。
-- 窗格、窗框、窗台、墙基及坡屋顶按材质合并，不为每个部件创建绘制调用。
function Station.BuildBuilding(root, st, matBrick, matCream, matGlass)
    local D, L, H = 14.0, 54.0, 7.4
    local radius = math.sqrt(10.2 * 10.2 + 28.0 * 28.0) -- 完整包括屋顶、门廊和基座
    local center = point(st, -55, -68, 0)
    local clearance = Route.DistanceTo(center) - radius
    if not Route.CanPlaceFootprint(center, radius, Route.BuildingClearance) then
        print("[Station] 错误：已拒绝不满足净空的站房：" .. st.name)
        return
    end
    local node = root:CreateChild("StationHouse")
    node.position = center
    local _, _, yaw = Route.Sample(st.s)
    node.rotation = Quaternion(yaw, Vector3.UP)
    local brick = batch(node, "BrickWalls", matBrick or World.Brick(), true, 1.0)
    local trim = batch(node, "PlinthLintelsFrames", matCream or World.Concrete(), true, 1)
    -- 用不透明暗色玻璃避免与后方墙面发生透明排序冲突。
    local glass = batch(node, "WindowPanes", matGlass or World.Solid(Color(0.16, 0.23, 0.27), 0.22, 0.23), false)
    local metal = batch(node, "WindowMuntins", World.Solid(Color(0.56, 0.56, 0.51), 0.35, 0.6), true)
    local roof = batch(node, "PitchedRoof", World.Solid(Color(0.32, 0.23, 0.20), 0.05, 0.93), true)
    brick:AddBox(Vector3(0, H / 2, 0), Vector3(D, H, L))
    trim:AddBox(Vector3(0, 0.3, 0), Vector3(D + 0.5, 0.6, L + 0.5))
    trim:AddBox(Vector3(0, 3.8, 0), Vector3(D + 0.12, 0.12, L + 0.12))
    trim:AddBox(Vector3(0, H - 0.12, 0), Vector3(D + 0.32, 0.24, L + 0.32))
    for side = -1, 1, 2 do
        local x = side * (D / 2 + 0.035)
        for row = 1, 2 do
            local y = row == 1 and 2.15 or 5.5
            for z = -23, 23, 4.6 do
                if not (side == 1 and row == 1 and math.abs(z) < 4) then
                    glass:AddBox(Vector3(x, y, z), Vector3(0.04, 1.65, 2.1))
                    for _, dy in ipairs({ -0.9, 0.9 }) do
                        trim:AddBox(Vector3(x + side * 0.04, y + dy, z), Vector3(0.14, 0.12, 2.34))
                    end
                    for _, dz in ipairs({ -1.10, 1.10 }) do
                        trim:AddBox(Vector3(x + side * 0.045, y, z + dz), Vector3(0.12, 1.9, 0.10))
                    end
                    metal:AddBox(Vector3(x + side * 0.075, y, z), Vector3(0.05, 1.65, 0.045))
                    metal:AddBox(Vector3(x + side * 0.075, y + 0.1, z), Vector3(0.05, 0.045, 2.1))
                end
            end
        end
    end
    -- 入口面朝局部 +X，也就是内侧站台方向。
    glass:AddBox(Vector3(7.065, 1.7, 0), Vector3(0.10, 3.4, 4.2))
    metal:AddBox(Vector3(7.13, 1.7, 0), Vector3(0.06, 3.4, 0.10))
    trim:AddBox(Vector3(8.5, 3.8, 0), Vector3(3.0, 0.16, 6.0))
    for _, z in ipairs({ -2.7, 2.7 }) do
        metal:AddBox(Vector3(9.8, 1.9, z), Vector3(0.10, 3.8, 0.10))
    end
    local x, z, eave, ridge = 7.6, 27.6, H + 0.05, H + 1.85
    roof:AddQuad(Vector3(-x, eave, -z), Vector3(-x, eave, z), Vector3(0, ridge, z), Vector3(0, ridge, -z))
    roof:AddQuad(Vector3(0, ridge, -z), Vector3(0, ridge, z), Vector3(x, eave, z), Vector3(x, eave, -z))
    -- 屋檐薄封边，不用巨大方块伪装屋顶。
    trim:AddBox(Vector3(-x, eave - 0.05, 0), Vector3(0.10, 0.12, z * 2))
    trim:AddBox(Vector3(x, eave - 0.05, 0), Vector3(0.10, 0.12, z * 2))
    brick:AddTri(Vector3(-7, H, -27), Vector3(0, ridge - 0.10, -27), Vector3(7, H, -27))
    brick:AddTri(Vector3(-7, H, 27), Vector3(7, H, 27), Vector3(0, ridge - 0.10, 27))
    brick:Finish(); trim:Finish(); glass:Finish(); metal:Finish(); roof:Finish()
    local sign = node:CreateChild("HouseName")
    sign.position = Vector3(7.22, 6.90, 0)
    sign.rotation = Quaternion(90, Vector3.UP)
    Station.MakeWorldSign(sign, st.name, 0.64)
    placementData_[#placementData_ + 1] = {
        name = st.name, x = center.x, z = center.z, radius = radius, clearance = clearance,
        s = st.s, platformStart = st.s + Route.PlatformStart, platformEnd = st.s + Route.PlatformEnd,
    }
    print(string.format("[Station] %s 站房完整包络净空 %.2f 米（要求至少 25 米）", st.name, clearance))
end

-- 每站仅六张金属长椅和小型矩形灯具。
-- 取消圆柱球头行人、巨大行李块及过多站台杂物。
function Station.BuildProps(root, st, _matLamp, _baseY)
    local steel = batch(root, "Furniture", World.Solid(Color(0.40, 0.44, 0.45), 0.65, 0.54), true)
    local _, _, yaw = Route.Sample(st.s)
    local angle = math.rad(yaw)
    for side = -1, 1, 2 do
        for _, ds in ipairs({ -125, -65, 15 }) do
            local center = point(st, ds, side * 6.2, PLATFORM_Y)
            steel:AddBox(center + Vector3(0, 0.46, 0), Vector3(0.58, 0.08, 2.4), angle)
            steel:AddBox(point(st, ds, side * 6.43, PLATFORM_Y + 0.76), Vector3(0.06, 0.56, 2.4), angle)
            for _, along in ipairs({ -0.85, 0.85 }) do
                steel:AddBox(point(st, ds + along, side * 6.2, PLATFORM_Y + 0.22), Vector3(0.42, 0.44, 0.07), angle)
            end
        end
        for ds = -115, 5, 24 do
            steel:AddBox(point(st, ds, side * 5.7, CANOPY_Y - 0.30), Vector3(0.16, 0.05, 1.2), angle)
        end
    end
    steel:Finish()
end

---@param parent Node
---@param text string
---@param size number
function Station.MakeWorldSign(parent, text, size)
    local node = parent:CreateChild("WorldSign")
    -- 字体字号是像素，不是米；采用清晰的 48 像素字形，按默认 128 像素/米换算。
    node.scale = Vector3.ONE * (size * 128 / 48)
    local label = node:CreateComponent("Text3D")
    label.viewMask = 2
    if not label:SetFont("Fonts/MiSans-Bold.ttf", 48) then
        print("[Station] 警告：站名牌字体不可用")
    end
    label.text = text
    label.textAlignment = HA_CENTER
    label.horizontalAlignment = HA_CENTER
    label.verticalAlignment = VA_CENTER
    label.color = Color(0.93, 0.94, 0.92)
    return node
end
function Station.MakeSignText(parent, text, size)
    return Station.MakeWorldSign(parent, text, size)
end
function Station.GetPlacementData() return placementData_ end
function Station.GetDimensions()
    return {
        platformInner = INNER, platformWidth = WIDTH, platformTopY = PLATFORM_Y,
        trainWidth = 3.1, sideGap = INNER - 3.1 / 2,
        canopyInner = CANOPY_INNER, canopyOuter = CANOPY_OUTER,
        canopyTopY = CANOPY_Y + 0.06, columnInner = 7.57,
        platformStart = Route.PlatformStart, platformEnd = Route.PlatformEnd,
        buildingClearance = Route.BuildingClearance,
    }
end
return Station
