-- 确定种子的乡野走廊，沿用scaffold-3d-scene子树所有权与共享合批。
-- 不创建灯光，不调用云/存档，不污染全局随机序列；先解析规划全线再加载几何。
-- XZ米制包络：主线0/对向+5/侧线-10.8，新景观完整足迹到Route至少32m。
-- 农田/池塘土埂/村屋/塔全部按最大外包圆保留；卸载不撤销解析保留区。
-- 最大横距285m位于地形平谷内，桥隧/城市/灌渠/旧feature优先。
-- 模块内部不调用会被自身排除的Landscape.CanPlace。
local Route = require "world.Route"
local World = require "world.WorldMaterials"
local Landscape = require "world.Landscape"
local Landmarks = require "world.Landmarks"
local Road = require "world.RoadCorridor"
local Config = require "config.CorridorConfig"
local GameConfig = require "config.GameConfig"
local Vegetation = require "world.Vegetation"
local Mountain = require "world.MountainProfile"
local Scenery = {}

---@class CorridorSceneryPlot
---@field id string
---@field kind string
---@field s number
---@field lateral number
---@field pos Vector3
---@field radius number
---@field width number
---@field depth number
---@field height number
---@field yaw number
---@field variant integer
---@field groundDrop number 平整地块台基高差（仅山地，最大0.30m，不是桥柱）
---@class CorridorSceneryChunk
---@field root Node
---@field vertices integer
---@field meshes integer
---@field counts table<string, number>
---@field hedges integer
---@field drains integer
---@type CorridorSceneryPlot[]
local plots_ = {}
---@type table<string, CorridorSceneryPlot[]>
local spatial_ = {}
---@type table<string, CorridorSceneryChunk>
local chunks_ = {}
---@type table<string, Material>
local materials_ = {}
---@type Scene?
local scene_ = nil
local initialized_ = false
local rejected_ = 0
local CELL = 128
local function pauseOnce(pause) if pause then pause() end end
local function chunkKey(a, b) return string.format("%.6f_%.6f", a, b) end
local function hash(i, salt)
    return ((Config.Seed + i * 7919 + salt * 104729) * 48271 % 2147483647) / 2147483647
end
local function oldHash(i, salt)
    local seed = GameConfig.WorldStream and GameConfig.WorldStream.Seed or 20261006
    return ((i * 7919 + salt * 104729 + seed) * 48271 % 2147483647) / 2147483647
end
-- 只复用旧feature解析公式，不调用生成几何或CanPlace/ReservesNature回调。
-- purpose=legacy能排除这些景观，本模块规划自身不会递归进入排除。
local function oldFeature(i)
    local s = i * Landscape.SampleLength + 40
    local theme, region = Landscape.ThemeAt(s)
    local cluster, phase = math.floor(i / 16), i % 16
    local side = oldHash(cluster, 8) > .52 and 1 or -1
    local active, lateral, r = true, 154.0, 31.0
    if theme == "fields" or theme == "village" then
        active = phase < 3 + math.floor(oldHash(cluster, 2) * 3) and oldHash(cluster, 3) > .18
        lateral = 142 + oldHash(cluster, 4) * 55
    elseif theme == "industry" then
        active = i % 3 == 0 or (i % 3 == 1 and oldHash(cluster, 5) > .6)
        -- 工业区按有效序号交替；这里保守保留两侧，不依赖私有industrySides。
        side, lateral, r = 0, 185 + oldHash(cluster, 6) * 65, 52
    elseif theme == "water" then side, lateral, r = 1, 350 + math.sin(s / 1700) * 42, 104
    elseif theme == "urban" then
        side = i % 2 == 0 and -1 or 1
        lateral, r = region == 6 and 110 + oldHash(i, 7) * 105 or 120 + oldHash(i, 7) * 120, 34
        active = region == 6 or i % 2 == 0
    end
    return s, theme, side, lateral, r, active
end
local function legacyReserved(pos, radius)
    if Landscape.InCity(pos, radius) or Landscape.InStationYard(pos, radius) or Landmarks.Reserves(pos, radius) then return true end
    local distance, s = Route.DistanceTo(pos)
    if distance - radius < Config.Scenery.RailClearance then return true end
    local lateral = (pos - Route.Sample(s)):DotProduct(Route.RightAt(s))
    if math.abs(lateral) + radius > Config.Scenery.MaxGroundLateral then return true end
    local theme = Landscape.ThemeAt(s)
    if theme == "water" and lateral + radius > 190 and lateral - radius < 510 then return true end
    if (theme == "fields" or theme == "village") and math.abs(math.abs(lateral) - 310) < 10 + radius then return true end
    local base = math.floor(s / Landscape.SampleLength)
    local reach = math.ceil((radius + 150) / Landscape.SampleLength) + 1
    for i = math.max(0, base - reach), math.min(math.ceil(Route.GetLength() / Landscape.SampleLength) - 1, base + reach) do
        local sampleS, kind, side, lat, r, active = oldFeature(i)
        if active and kind ~= "water" then
            for _, sign in ipairs(side == 0 and {-1, 1} or {side}) do
                local feature = Route.SampleOffset(sampleS, sign * lat, 0)
                local dx, dz = feature.x - pos.x, feature.z - pos.z
                if dx * dx + dz * dz < (r + radius + 4) ^ 2 then return true end
                local access = Route.SampleOffset(sampleS, sign * 82, 0)
                local rx, rz = pos.x - access.x, pos.z - access.z
                if rx * rx + rz * rz < (40.2 + radius + 2) ^ 2 then return true end
            end
        end
    end
    return false
end
local function conflictsOwn(pos, radius)
    for x = math.floor((pos.x - radius) / CELL), math.floor((pos.x + radius) / CELL) do
        for z = math.floor((pos.z - radius) / CELL), math.floor((pos.z + radius) / CELL) do
            for _, plot in ipairs(spatial_[x .. "_" .. z] or {}) do
                local dx, dz = pos.x - plot.pos.x, pos.z - plot.pos.z
                if dx * dx + dz * dz < (radius + plot.radius + 3) ^ 2 then return true end
            end
        end
    end
    return false
end
-- 地块/建筑保持竖直；远轨200m的真实山坡不能用轨基Y冒充地表。
-- 仅接受整块高差<=0.30m的自然缓平台，密采样含边角；小台基补平而非拉长桥柱。
-- Terrain依赖本模块，故在Init后的候选规划时延迟require，避免模块载入环。
local function groundPlot(pos, yaw, width, depth)
    if not GameConfig.MountainTerrain then return pos, 0 end
    local Terrain = require "world.Terrain"
    local a = math.rad(yaw)
    local nx, nz = math.max(2,math.ceil(width/8)), math.max(2,math.ceil(depth/8))
    local low, high = math.huge, -math.huge
    for i=0,nx do for j=0,nz do
        local x, z = width*(i/nx-.5), depth*(j/nz-.5)
        local groundY = Terrain.GetGroundHeight(pos.x+x*math.cos(a)+z*math.sin(a),pos.z-x*math.sin(a)+z*math.cos(a))
        low, high = math.min(low,groundY), math.max(high,groundY)
    end end
    if high-low>.30 then return nil, 0 end
    return Vector3(pos.x,high,pos.z), high-low
end
local function candidate(kind, s, lateral, width, depth, height, variant)
    local radius = math.sqrt(width * width + depth * depth) * .5 + 2
    local pos = Route.SampleOffset(s, lateral, 0)
    if legacyReserved(pos, radius) or Road.IsExcluded(pos, radius, "scenery") or conflictsOwn(pos, radius) then
        rejected_ = rejected_ + 1
        return false
    end
    local _, _, yaw = Route.Sample(s)
    local grounded, groundDrop = groundPlot(pos,yaw,width,depth)
    if not grounded then rejected_=rejected_+1; return false end
    local plot = {id = kind .. "_" .. string.format("%.3f", s) .. "_" .. lateral, kind = kind, s = s, lateral = lateral,
        pos = grounded, radius = radius, width = width, depth = depth, height = height, yaw = yaw, variant = variant, groundDrop = groundDrop}
    plots_[#plots_ + 1] = plot
    for x = math.floor((pos.x - radius - 1) / CELL), math.floor((pos.x + radius + 1) / CELL) do
        for z = math.floor((pos.z - radius - 1) / CELL), math.floor((pos.z + radius + 1) / CELL) do
            local k = x .. "_" .. z
            spatial_[k] = spatial_[k] or {}
            local cell = spatial_[k]
            cell[#cell + 1] = plot
        end
    end
    return true
end
---@param scene Scene?
---@param options? table
function Scenery.Init(scene, options)
    Scenery.Shutdown()
    scene_ = scene
    assert(Route.GetLength() > 0, "[RailwayScenery] Route.Build required")
    local count = math.ceil(Route.GetLength() / Config.Scenery.SampleLength)
    for i = 0, count - 1 do
        local s = i * Config.Scenery.SampleLength + Config.Scenery.SampleLength * .5
        if s < Route.GetLength() - 80 then
            local kindIndex = i % 8
            local kind = ({"field", "greenhouse", "village", "field", "pond", "factory", "field", "mine"})[kindIndex + 1]
            local theme = Landscape.ThemeAt(s)
            if theme == "urban" then kind = "telecom" end
            for _, side in ipairs({-1, 1}) do
                local lateral = side * (205 + hash(i, side + 3) * 26)
                local width, depth, height = 36.0, 64.0, .15
                if kind == "village" then width, depth, height = 42, 70, 6.5
                elseif kind == "greenhouse" then width, depth, height = 28, 58, 3.8
                elseif kind == "pond" then width, depth, height = 36, 58, .72
                elseif kind == "factory" then width, depth, height = 44, 60, 9
                elseif kind == "mine" then width, depth, height = 40, 54, 12
                elseif kind == "telecom" then width, depth, height = 7, 7, 31 end
                candidate(kind, s, lateral, width, depth, height, i % 5)
            end
            if i % 6 == 0 then
                for _, side in ipairs({-1, 1}) do candidate("power", s + 80, side * 260, 12, 12, 34, i % 3) end
            elseif i % 6 == 3 then candidate("telecom", s + 75, -264, 7, 7, 31, i % 3) end
        end
    end
    initialized_ = true
    print(string.format("[RailwayScenery] 种子%d，全线解析规划%d项（拒绝%d处冲突），不调用云/存档/CanPlace回调", Config.Seed, #plots_, rejected_))
    return true
end
function Scenery.GetExclusions() return plots_ end
---@param pos Vector3
---@param radius? number
---@param purpose? string
function Scenery.IsExcluded(pos, radius, purpose)
    if not initialized_ then return false end
    return conflictsOwn(pos, math.max(0, radius or 0))
end
local function material(name, color, metal, rough)
    if not materials_[name] then materials_[name] = World.Solid(color, metal or 0, rough or .91) end
    return materials_[name]
end
local function localPoint(plot, x, y, z)
    local a = math.rad(plot.yaw)
    return plot.pos + Vector3(x * math.cos(a) + z * math.sin(a), y, -x * math.sin(a) + z * math.cos(a))
end
local function box(batch, plot, x, y, z, w, h, d)
    batch:AddBox(localPoint(plot, x, y, z), Vector3(w, h, d), math.rad(plot.yaw))
end
local function tube(batch, plot, ax, ay, az, bx, by, bz, r)
    batch:AddTube(localPoint(plot, ax, ay, az), localPoint(plot, bx, by, bz), r, 5)
end
local function roof(batch, plot, x, z, width, depth, eave, ridge)
    local a, b = localPoint(plot, x - width / 2, eave, z - depth / 2), localPoint(plot, x - width / 2, eave, z + depth / 2)
    local c, d = localPoint(plot, x, ridge, z + depth / 2), localPoint(plot, x, ridge, z - depth / 2)
    batch:AddQuad(a, b, c, d)
    batch:AddQuad(d, c, localPoint(plot, x + width / 2, eave, z + depth / 2), localPoint(plot, x + width / 2, eave, z - depth / 2))
    batch:AddTri(a, d, localPoint(plot, x + width / 2, eave, z - depth / 2))
    batch:AddTri(b, localPoint(plot, x + width / 2, eave, z + depth / 2), c)
end
local function house(wall, roofBatch, details, plot, x, z, width, depth, height)
    box(wall, plot, x, height / 2, z, width, height, depth)
    roof(roofBatch, plot, x, z, width + .7, depth + .7, height, height + 1.6)
    box(details, plot, x, 1.1, z - depth / 2 - .025, 1.3, 2.2, .05)
    for _, side in ipairs({-1, 1}) do
        for dx = -width / 2 + 1.4, width / 2 - 1, 2.7 do
            box(details, plot, x + dx, height - 1.5, z + side * (depth / 2 + .025), 1.2, 1.1, .05)
        end
    end
end
local function buildVillage(plot, b)
    box(b.soil, plot, 0, .04, 0, plot.width, .08, plot.depth)
    -- 两排小院与中央村道，避免复制孤立的无门窗方块。
    for row = -1, 1, 2 do
        for col = -1, 1 do
            local x, z = row * 13, col * 20
            house(b.wall, b.roof, b.dark, plot, x, z, 10, 12, 4.8 + (plot.variant + col + 2) % 3 * .65)
            box(b.concrete, plot, x, .10, z - 7.5, 10, .12, 2.6)
        end
    end
    box(b.concrete, plot, 0, .10, 0, 6, .12, plot.depth)
    for _, side in ipairs({-1, 1}) do
        box(b.wall, plot, side * (plot.width / 2 - .25), .65, 0, .35, 1.3, plot.depth)
    end
end
local function buildField(plot, b)
    box(b.soil, plot, 0, .06, 0, plot.width, .12, plot.depth)
    for row = -plot.width / 2 + 1, plot.width / 2 - 1, 3 do
        box(plot.variant % 2 == 0 and b.crop or b.gold, plot, row, .16, 0, 2.3, .18, plot.depth - 2)
    end
    for _, side in ipairs({-1, 1}) do
        box(b.soil, plot, side * plot.width / 2, .18, 0, .65, .36, plot.depth + .6)
        box(b.soil, plot, 0, .18, side * plot.depth / 2, plot.width, .36, .65)
    end
end
local function buildGreenhouse(plot, b)
    box(b.soil, plot, 0, .04, 0, plot.width, .08, plot.depth)
    for _, x in ipairs({-9, 0, 9}) do
        -- 浅色不透明拱膜避免透明排序伪影，合批肋架保证大棚轮廓可读。
        local function arc(z, theta)
            return localPoint(plot, x + math.cos(theta) * 3.5, .15 + math.sin(theta) * 3.7, z)
        end
        for j = 0, 7 do
            local t0, t1 = math.pi * j / 8, math.pi * (j + 1) / 8
            b.film:AddQuad(arc(-26, t0), arc(26, t0), arc(26, t1), arc(-26, t1))
            b.film:AddQuad(arc(-26, t1), arc(26, t1), arc(26, t0), arc(-26, t0))
            b.film:AddTri(localPoint(plot, x, .15, -26), arc(-26, t1), arc(-26, t0))
            b.film:AddTri(localPoint(plot, x, .15, 26), arc(26, t0), arc(26, t1))
            for z = -26, 26, 13 do b.steel:AddTube(arc(z, t0), arc(z, t1), .025, 4) end
        end
        box(b.dark, plot, x, 1.0, -26.025, 1.3, 1.8, .04)
    end
end
local function buildPond(plot, b)
    -- 土埂围合的抬高蓄水塘：原地面低于池底，不假装已挖掉地形。
    box(b.soil, plot, 0, .12, 0, plot.width, .24, plot.depth)
    for _, side in ipairs({-1, 1}) do
        box(b.soil, plot, side * (plot.width / 2 - 1.25), .36, 0, 2.5, .72, plot.depth)
        box(b.soil, plot, 0, .36, side * (plot.depth / 2 - 1.25), plot.width, .72, 2.5)
    end
    box(b.water, plot, 0, .41, 0, plot.width - 5, .025, plot.depth - 5)
    house(b.wall, b.roof, b.dark, plot, plot.width / 2 - 5, plot.depth / 2 - 6, 5, 6, 2.9)
end
local function buildFactory(plot, b, mine)
    box(b.concrete, plot, 0, .06, 0, plot.width, .12, plot.depth)
    house(b.wall, b.roof, b.dark, plot, -5, 5, mine and 20 or 28, mine and 24 or 36, mine and 8 or 9)
    for z = -18, 18, 12 do
        box(b.dark, plot, -5, 2.1, z - 9, 4.5, 4.2, .08)
    end
    if mine then
        -- 可见料堆与落地支承输送带，不伪造运营支线或跨主线悬空运输设施。
        for j = 1, 3 do roof(b.soil, plot, 12, -20 + j * 12, 10, 10, .1, 3 + j * .3) end
        for z = -18, 18, 12 do
            tube(b.steel, plot, 14, 0, z, 14, 6, z, .13)
            tube(b.steel, plot, 10, 0, z, 14, 6, z, .10)
        end
        box(b.dark, plot, 14, 6, 0, 1.9, .40, 40)
    else
        for x = 12, 17, 5 do
            tube(b.steel, plot, x, .12, 18, x, 11, 18, 1.55)
            box(b.roof, plot, x, 11.2, 18, 3.4, .4, 3.4)
        end
    end
end
local function buildTower(plot, b, power)
    local h, base = plot.height, power and 4.7 or 2.3
    for _, x in ipairs({-1, 1}) do
        for _, z in ipairs({-1, 1}) do
            box(b.concrete, plot, x * base, .16, z * base, 1.1, .32, 1.1)
            tube(b.steel, plot, x * base, .16, z * base, x * .65, h, z * .65, .10)
        end
    end
    for y = 2, h - 2, 4 do
        local lo = base + (.65 - base) * y / h
        local hi = base + (.65 - base) * (y + 4) / h
        for _, side in ipairs({-1, 1}) do
            tube(b.steel, plot, -lo, y, side * lo, hi, y + 4, side * hi, .055)
            tube(b.steel, plot, lo, y, side * lo, -hi, y + 4, side * hi, .055)
            tube(b.steel, plot, side * lo, y, -lo, side * hi, y + 4, hi, .055)
            tube(b.steel, plot, side * lo, y, lo, side * hi, y + 4, -hi, .055)
        end
    end
    if power then
        for _, y in ipairs({h - 5, h - 1}) do
            tube(b.steel, plot, -5, y, 0, 5, y, 0, .10)
            for _, x in ipairs({-4.3, 4.3}) do tube(b.film, plot, x, y - 1.1, 0, x, y, 0, .13) end
        end
    else
        for j = 0, 2 do
            local a = j * math.pi * 2 / 3
            local x, z = math.cos(a) * 1.1, math.sin(a) * 1.1
            box(b.film, plot, x, h - 1.5, z, .48, 2.5, .30)
        end
        box(b.wall, plot, 0, 1.3, -2, 3.0, 2.6, 2.1)
    end
end
-- 近轨横截面（XZ净空，不添加物理）：
-- 主股道0/+5 / 站场保留105m -> 35m外排水浅槽 -> 42m外真实低灌木。
-- 沟渠是地面上的浅U形预制槽：底+.025、壁顶+.28，绝不画被Terrain盖住的地下洞。
-- 站场/桥谷/道路/农田/建筑整包络拒绝；纵向8m小段先各点量高，避免坡上悬空。
local function buildVerge(root,b,first,last,data,pause)
    local plants=Vegetation.NewBatch(root:CreateChild("近轨真实绿篱"))
    local bush=Vegetation.GetAsset("bush")
    for s=math.ceil(first/8)*8,last-.001,8 do
        local finish=math.min(last,s+8)
        for _,side in ipairs({-1,1}) do
            local center=Route.SampleOffset((s+finish)*.5,side*35,0)
            local r=math.sqrt((finish-s)^2+1.4^2)*.5
            if Landscape.CanPlace(center,r,30) and not Landscape.ReservesNature(center,r)
                and not Landmarks.InWater(center,r) then
                local function ground(atS,lat,raise)
                    local pos=Route.SampleOffset(atS,lat,0)
                    return Vector3(pos.x,Mountain.GetGroundHeight(pos.x,pos.z)+raise,pos.z)
                end
                local lo,hi=side*35-.6,side*35+.6
                local a,c=ground(s,lo,.025),ground(finish,lo,.025)
                local d,e=ground(finish,hi,.025),ground(s,hi,.025)
                b.concrete:AddQuad(a,c,d,e)
                b.concrete:AddQuad(e,d,c,a)
                for _,lat in ipairs({lo,hi}) do
                    local aa,bb=ground(s,lat,.025),ground(finish,lat,.025)
                    b.concrete:AddQuad(aa,bb,bb+Vector3(0,.26,0),aa+Vector3(0,.26,0))
                    b.concrete:AddQuad(aa+Vector3(0,.26,0),bb+Vector3(0,.26,0),bb,aa)
                end
                data.drains=data.drains+1
            end
        end
        pauseOnce(pause)
    end
    if bush then
        local scale,r=Vegetation.Measure(bush,.78)
        local step=math.max(2.8,r*1.55)
        for s=math.ceil(first/step)*step,last-.001,step do
            for _,side in ipairs({-1,1}) do
                local pos=Route.SampleOffset(s,side*43,0)
                local grounded=Vector3(pos.x,Mountain.GetGroundHeight(pos.x,pos.z),pos.z)
                if Landscape.CanPlace(grounded,r,30) and not Landscape.ReservesNature(grounded,r)
                    and not Landmarks.InWater(grounded,r) then
                    plants:Add(bush,grounded,scale,(s*31+side*73)%360);data.hedges=data.hedges+1
                end
            end
            pauseOnce(pause)
        end
    end
    for _,group in pairs(plants.groups) do group.drawDistance=230;group.castShadows=false;group.lodBias=.55 end
end
---@param parent Node
---@param first number
---@param last number
---@param pause? fun()
---@return integer
function Scenery.BuildChunk(parent, first, last, pause)
    assert(initialized_, "[RailwayScenery] Init required")
    if last <= first then return 0 end
    local k = chunkKey(first, last)
    if chunks_[k] then return chunks_[k].vertices end
    local root = parent:CreateChild("乡野沿线_" .. k)
    local data = {root = root, vertices = 0, meshes = 0, counts = {},hedges=0,drains=0}
    chunks_[k] = data
    local b = {} ---@type table<string, RailwayBatch>
    local colors = {soil = Color(.39, .31, .20), crop = Color(.35, .47, .20), gold = Color(.62, .54, .27),
        wall = Color(.63, .59, .48), roof = Color(.29, .32, .32), dark = Color(.14, .20, .22),
        concrete = Color(.50, .51, .47), film = Color(.64, .73, .67), steel = Color(.34, .39, .39), water = Color(.12, .29, .26)}
    local function batch(name)
        if not b[name] then
            local materialValue = name == "water" and World.Water() or material(name, colors[name], name == "steel" and .4 or 0)
            b[name] = World.NewBatch(root:CreateChild("合批_" .. name), materialValue, false, 5)
            b[name].geometry.viewMask = (name == "wall" or name == "roof" or name == "steel") and 6 or 2
            b[name].geometry.drawDistance = Config.Scenery.DrawDistance
        end
        return b[name]
    end
    -- 每块固定小材质集合，房屋/棚肋共享合批，不逐件建立节点。
    for name in pairs(colors) do batch(name) end
    for _, plot in ipairs(plots_) do
        if plot.s >= first and plot.s < last then
            if plot.groundDrop > .0001 then
                box(b.concrete,plot,0,-(plot.groundDrop+.025)*.5,0,plot.width,plot.groundDrop+.025,plot.depth)
            end
            if plot.kind == "village" then buildVillage(plot, b)
            elseif plot.kind == "field" then buildField(plot, b)
            elseif plot.kind == "greenhouse" then buildGreenhouse(plot, b)
            elseif plot.kind == "pond" then buildPond(plot, b)
            elseif plot.kind == "factory" then buildFactory(plot, b, false)
            elseif plot.kind == "mine" then buildFactory(plot, b, true)
            else buildTower(plot, b, plot.kind == "power") end
            data.counts[plot.kind] = (data.counts[plot.kind] or 0) + 1
            pauseOnce(pause)
        end
    end
    buildVerge(root,b,first,last,data,pause)
    for _, target in pairs(b) do
        local n = target:Finish()
        data.vertices = data.vertices + n
        if n > 0 then data.meshes = data.meshes + 1 end
        pauseOnce(pause)
    end
    return data.vertices
end
function Scenery.Update(dt, trainOccupancies)
    -- 静态乡野资产，不虚称隐形作物/工厂仿真。
end
function Scenery.ForgetChunk(first, last)
    local k = chunkKey(first, last)
    chunks_[k] = nil -- 几何节点统一由WorldStream拥有和释放。
end
function Scenery.GetMeshes()
    local out = {} ---@type CustomGeometry[]
    for _, data in pairs(chunks_) do
        for _, mesh in ipairs(data.root:GetComponents("CustomGeometry", true)) do out[#out + 1] = mesh end
    end
    return out
end
function Scenery.GetStats()
    local stats = {initialized = initialized_, seed = Config.Seed, planned = #plots_, rejected = rejected_,
        loadedChunks = 0, hedges=0, drains=0, meshes = 0, vertices = 0, plannedKinds = {}, loadedKinds = {}, railClearance = Config.Scenery.RailClearance}
    for _, plot in ipairs(plots_) do stats.plannedKinds[plot.kind] = (stats.plannedKinds[plot.kind] or 0) + 1 end
    for _, data in pairs(chunks_) do
        stats.loadedChunks = stats.loadedChunks + 1
        stats.hedges=stats.hedges+data.hedges;stats.drains=stats.drains+data.drains
        stats.meshes, stats.vertices = stats.meshes + data.meshes, stats.vertices + data.vertices
        for name, count in pairs(data.counts) do stats.loadedKinds[name] = (stats.loadedKinds[name] or 0) + count end
    end
    return stats
end
function Scenery.Shutdown()
    -- 只清模块引用；场景/流式父节点由调用者释放。
    scene_, plots_, spatial_, chunks_, initialized_, rejected_ = nil, {}, {}, {}, false, 0
end
return Scenery
