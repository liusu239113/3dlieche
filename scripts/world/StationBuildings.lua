-- ============================================================================
-- StationBuildings - 各城市站房原型
-- 五座车站使用不同建筑原型、体量与材质，不再共用同一栋楼。
-- 局部坐标：+X 朝站台方向，Z 沿线路；建筑最低点 Y=0。
-- ============================================================================

local World = require "world.WorldMaterials"

local StationBuildings = {}

local solidMaterials_ = {}
---@param color Color
---@param metallic number
---@param roughness number
---@return Material
local function solid(color, metallic, roughness)
    local key = string.format("%.4f_%.4f_%.4f_%.4f_%.4f", color.r, color.g, color.b, metallic or 0, roughness or .8)
    if not solidMaterials_[key] then solidMaterials_[key] = World.Solid(color, metallic, roughness) end
    return solidMaterials_[key]
end

---@param root Node
---@param name string
---@param material Material
---@param shadows boolean
---@param tile? number
---@return RailwayBatch
local function batch(root, name, material, shadows, tile)
    return World.NewBatch(root:CreateChild(name), material, shadows, tile)
end

---@class StationStyle
---@field archetype string 建筑原型
---@field D number 进深（局部 X）
---@field L number 面宽（局部 Z）
---@field H number 檐高
---@field body Color 主体墙色
---@field trim Color 线脚/台基色
---@field roof Color 屋顶色
---@field accent Color 点缀色（钟面/檐带/雨棚）

--- 每座城市一套原型；体量、材质、屋顶形态都不同。
---@type table<integer, StationStyle>
StationBuildings.Styles = {
    [1] = { archetype = "palace", D = 17.0, L = 62.0, H = 8.6,
        body = Color(0.64, 0.29, 0.23), trim = Color(0.90, 0.86, 0.76),
        roof = Color(0.29, 0.19, 0.16), accent = Color(0.86, 0.71, 0.29) },
    [2] = { archetype = "tower", D = 15.0, L = 48.0, H = 7.8,
        body = Color(0.73, 0.69, 0.58), trim = Color(0.86, 0.82, 0.70),
        roof = Color(0.26, 0.31, 0.35), accent = Color(0.93, 0.91, 0.86) },
    [3] = { archetype = "gate", D = 19.0, L = 56.0, H = 8.0,
        body = Color(0.62, 0.60, 0.55), trim = Color(0.80, 0.78, 0.70),
        roof = Color(0.24, 0.26, 0.24), accent = Color(0.72, 0.61, 0.35) },
    [4] = { archetype = "block", D = 15.0, L = 68.0, H = 10.4,
        body = Color(0.56, 0.59, 0.61), trim = Color(0.79, 0.81, 0.83),
        roof = Color(0.20, 0.24, 0.28), accent = Color(0.58, 0.70, 0.79) },
    [5] = { archetype = "terminal", D = 23.0, L = 54.0, H = 8.2,
        body = Color(0.33, 0.37, 0.41), trim = Color(0.75, 0.79, 0.81),
        roof = Color(0.16, 0.20, 0.24), accent = Color(0.32, 0.59, 0.71) },
}

---@param style StationStyle
---@return number radius 完整外包圆半径（含屋檐/门廊）
function StationBuildings.FootprintRadius(style)
    local overX = style.archetype == "terminal" and 2.4 or 2.2
    local overZ = style.archetype == "palace" and 1.8 or 1.2
    return math.sqrt((style.D * 0.5 + overX) ^ 2 + (style.L * 0.5 + overZ) ^ 2)
end

-- ---------------------------------------------------------------------------
-- 北京：红墙大屋顶，正面柱廊
-- ---------------------------------------------------------------------------
local function buildPalace(node, s, pause)
    local body = batch(node, "PalaceBody", solid(s.body, 0, 0.92), true, 1.0)
    local trim = batch(node, "PalaceTrim", solid(s.trim, 0, 0.9), true)
    local roof = batch(node, "PalaceRoof", solid(s.roof, 0.04, 0.9), true)
    local accent = batch(node, "PalaceRidge", solid(s.accent, 0.30, 0.62), true)
    local D, L, H = s.D, s.L, s.H
    body:AddBox(Vector3(0, H / 2, 0), Vector3(D, H, L))
    trim:AddBox(Vector3(0, 0.35, 0), Vector3(D + 0.7, 0.7, L + 0.7))
    trim:AddBox(Vector3(0, H - 0.14, 0), Vector3(D + 0.5, 0.28, L + 0.5))
    -- 大挑檐：脊高 H+2.6，檐口外挑至 ±(D/2+2.2)。
    local x, z, ridge = D / 2 + 2.2, L / 2 + 1.8, H + 2.6
    roof:AddQuad(Vector3(-x, H + 0.14, -z), Vector3(-x, H + 0.14, z), Vector3(0, ridge, z), Vector3(0, ridge, -z))
    roof:AddQuad(Vector3(0, ridge, -z), Vector3(0, ridge, z), Vector3(x, H + 0.14, z), Vector3(x, H + 0.14, -z))
    body:AddTri(Vector3(-D / 2, H, -L / 2), Vector3(0, ridge - 0.12, -L / 2), Vector3(D / 2, H, -L / 2))
    body:AddTri(Vector3(-D / 2, H, L / 2), Vector3(D / 2, H, L / 2), Vector3(0, ridge - 0.12, L / 2))
    accent:AddBox(Vector3(0, ridge + 0.06, 0), Vector3(0.7, 0.24, L + 1.2))
    -- 正面柱廊：红柱与额枋，形成进深感。
    for _, dz in ipairs({ -20, -12, -4, 4, 12, 20 }) do
        trim:AddBox(Vector3(D / 2 + 0.42, H / 2, dz), Vector3(0.42, H, 0.42))
        if pause then pause() end
    end
    trim:AddBox(Vector3(D / 2 + 0.42, H - 0.5, 0), Vector3(0.5, 0.7, L - 3))
    -- 门前石阶
    trim:AddBox(Vector3(D / 2 + 1.1, 0.18, 0), Vector3(1.6, 0.36, 8))
    for _, b in ipairs({ body, trim, roof, accent }) do b:Finish(); if pause then pause() end end
end

-- ---------------------------------------------------------------------------
-- 天津：钟楼 + 坡顶大厅，竖向构图
-- ---------------------------------------------------------------------------
local function buildTower(node, s, pause)
    local body = batch(node, "TowerBody", solid(s.body, 0, 0.93), true, 1.0)
    local trim = batch(node, "TowerTrim", solid(s.trim, 0, 0.9), true)
    local roof = batch(node, "TowerRoof", solid(s.roof, 0.06, 0.88), true)
    local accent = batch(node, "TowerClock", solid(s.accent, 0.10, 0.5), true)
    local D, L, H = s.D, s.L, s.H
    body:AddBox(Vector3(0, H / 2, 0), Vector3(D, H, L))
    trim:AddBox(Vector3(0, 0.3, 0), Vector3(D + 0.6, 0.6, L + 0.6))
    -- 大厅坡顶
    local hx, hz = D / 2 + 0.6, L / 2 + 0.6
    roof:AddQuad(Vector3(-hx, H, -hz), Vector3(-hx, H, hz), Vector3(0, H + 1.5, hz), Vector3(0, H + 1.5, -hz))
    roof:AddQuad(Vector3(0, H + 1.5, -hz), Vector3(0, H + 1.5, hz), Vector3(hx, H, hz), Vector3(hx, H, -hz))
    body:AddTri(Vector3(-D / 2, H, -L / 2), Vector3(0, H + 1.4, -L / 2), Vector3(D / 2, H, -L / 2))
    body:AddTri(Vector3(-D / 2, H, L / 2), Vector3(D / 2, H, L / 2), Vector3(0, H + 1.4, L / 2))
    -- 中央钟楼：从大厅顶升起，正面方形钟面
    local th = 7.2
    body:AddBox(Vector3(0, H + th / 2, 0), Vector3(6.4, th, 6.4))
    trim:AddBox(Vector3(0, H + th + 0.2, 0), Vector3(7.4, 0.4, 7.4))
    accent:AddBox(Vector3(3.28, H + 4.6, 0), Vector3(0.24, 2.2, 2.2))
    accent:AddBox(Vector3(0, H + 4.6, 3.28), Vector3(2.2, 2.2, 0.24))
    -- 四坡尖顶
    local apex = H + th + 3.4
    local bx, bz = 3.7, 3.7
    roof:AddTri(Vector3(-bx, H + th + 0.4, -bz), Vector3(0, apex, 0), Vector3(bx, H + th + 0.4, -bz))
    roof:AddTri(Vector3(bx, H + th + 0.4, -bz), Vector3(0, apex, 0), Vector3(bx, H + th + 0.4, bz))
    roof:AddTri(Vector3(bx, H + th + 0.4, bz), Vector3(0, apex, 0), Vector3(-bx, H + th + 0.4, bz))
    roof:AddTri(Vector3(-bx, H + th + 0.4, bz), Vector3(0, apex, 0), Vector3(-bx, H + th + 0.4, -bz))
    -- 正门雨罩
    trim:AddBox(Vector3(D / 2 + 0.9, 3.4, 0), Vector3(2.0, 0.28, 9))
    for _, b in ipairs({ body, trim, roof, accent }) do b:Finish(); if pause then pause() end end
end

-- ---------------------------------------------------------------------------
-- 济南：拱门式站房，中央贯通门洞
-- ---------------------------------------------------------------------------
local function buildGate(node, s, pause)
    local body = batch(node, "GateBody", solid(s.body, 0, 0.93), true, 1.0)
    local trim = batch(node, "GateTrim", solid(s.trim, 0, 0.9), true)
    local roof = batch(node, "GateRoof", solid(s.roof, 0.05, 0.89), true)
    local accent = batch(node, "GateArch", solid(s.accent, 0.12, 0.66), true)
    local D, L, H = s.D, s.L, s.H
    local wing = 16.0            -- 两侧实体宽度
    local opening = L - wing * 2 -- 中央门洞净宽
    for _, side in ipairs({ -1, 1 }) do
        local z = side * (opening / 2 + wing / 2)
        body:AddBox(Vector3(0, H / 2, z), Vector3(D, H, wing))
    end
    -- 门洞上方过梁
    body:AddBox(Vector3(0, H - 2.4, 0), Vector3(D, 4.8, opening))
    trim:AddBox(Vector3(0, 0.3, 0), Vector3(D + 0.6, 0.6, L + 0.6))
    -- 拱腹：阶梯式内收，近似拱形
    for i = 1, 3 do
        local w = opening - i * 2.6
        accent:AddBox(Vector3(0, H - 2.4 - i * 0.85, 0), Vector3(D - 0.2, 0.9, w))
    end
    accent:AddBox(Vector3(D / 2 + 0.05, H - 4.9, 0), Vector3(0.2, 4.8, opening))
    -- 平顶檐口
    roof:AddBox(Vector3(0, H + 0.35, 0), Vector3(D + 1.4, 0.7, L + 1.4))
    trim:AddBox(Vector3(D / 2 + 0.5, H - 0.4, 0), Vector3(0.5, 0.6, L + 0.8))
    -- 门洞两侧壁柱
    for _, side in ipairs({ -1, 1 }) do
        local z = side * (opening / 2 + 0.5)
        trim:AddBox(Vector3(D / 2 + 0.28, H / 2 - 1, z), Vector3(0.56, H - 2, 0.9))
    end
    for _, b in ipairs({ body, trim, roof, accent }) do b:Finish(); if pause then pause() end end
end

-- ---------------------------------------------------------------------------
-- 南京：现代多层候车楼，水平窗带
-- ---------------------------------------------------------------------------
local function buildBlock(node, s, pause)
    local body = batch(node, "BlockBody", solid(s.body, 0, 0.9), true, 1.0)
    local trim = batch(node, "BlockTrim", solid(s.trim, 0, 0.86), true)
    local glass = batch(node, "BlockWindows", solid(Color(0.16, 0.24, 0.29), 0.24, 0.24), false)
    local roof = batch(node, "BlockParapet", solid(s.roof, 0.05, 0.9), true)
    local accent = batch(node, "BlockBand", solid(s.accent, 0.20, 0.55), true)
    local D, L, H = s.D, s.L, s.H
    local floors = 3
    local fh = H / floors
    body:AddBox(Vector3(0, H / 2, 0), Vector3(D, H, L))
    trim:AddBox(Vector3(0, 0.3, 0), Vector3(D + 0.5, 0.6, L + 0.5))
    for f = 1, floors do
        local y = (f - 0.5) * fh
        -- 正立面水平窗带
        glass:AddBox(Vector3(D / 2 + 0.04, y + 0.25, 0), Vector3(0.10, fh - 1.5, L - 2.4))
        trim:AddBox(Vector3(D / 2 + 0.08, y + 0.25 + (fh - 1.5) / 2 + 0.35, 0), Vector3(0.16, 0.22, L - 2.0))
        trim:AddBox(Vector3(D / 2 + 0.08, y + 0.25 - (fh - 1.5) / 2 - 0.35, 0), Vector3(0.16, 0.22, L - 2.0))
        -- 竖挺
        for dz = -L / 2 + 3, L / 2 - 3, 4.2 do
            trim:AddBox(Vector3(D / 2 + 0.09, y + 0.25, dz), Vector3(0.12, fh - 1.4, 0.16))
        end
        accent:AddBox(Vector3(D / 2 + 0.05, y + fh / 2 - 0.15, 0), Vector3(0.14, 0.18, L + 0.2))
        if pause then pause() end
    end
    -- 侧面窄窗
    for _, side in ipairs({ -1, 1 }) do
        glass:AddBox(Vector3(0, H * 0.5, side * (L / 2 + 0.04)), Vector3(D - 3, H - 3, 0.10))
    end
    -- 女儿墙
    roof:AddBox(Vector3(0, H + 0.35, 0), Vector3(D + 0.6, 0.7, L + 0.6))
    roof:AddBox(Vector3(0, H + 0.35, 0), Vector3(D - 0.4, 0.7, L - 0.4))
    -- 入口门厅
    trim:AddBox(Vector3(D / 2 + 1.0, 1.9, 0), Vector3(2.2, 3.8, 12))
    glass:AddBox(Vector3(D / 2 + 2.05, 1.8, 0), Vector3(0.12, 3.2, 10))
    for _, b in ipairs({ body, trim, glass, roof, accent }) do b:Finish(); if pause then pause() end end
end

-- ---------------------------------------------------------------------------
-- 上海：现代玻璃枢纽，大跨度雨棚
-- ---------------------------------------------------------------------------
local function buildTerminal(node, s, pause)
    local body = batch(node, "TerminalBody", solid(s.body, 0.02, 0.86), true, 1.0)
    local trim = batch(node, "TerminalTrim", solid(s.trim, 0.10, 0.8), true)
    local glass = batch(node, "TerminalGlazing", solid(Color(0.20, 0.30, 0.36), 0.30, 0.18), false)
    local roof = batch(node, "TerminalCanopy", solid(s.roof, 0.16, 0.72), true)
    local accent = batch(node, "TerminalBand", solid(s.accent, 0.26, 0.5), true)
    local D, L, H = s.D, s.L, s.H
    body:AddBox(Vector3(0, H / 2, 0), Vector3(D, H, L))
    trim:AddBox(Vector3(0, 0.25, 0), Vector3(D + 0.5, 0.5, L + 0.5))
    -- 正面整片玻璃幕墙（分格）
    glass:AddBox(Vector3(D / 2 + 0.06, H / 2 + 0.2, 0), Vector3(0.12, H - 1.8, L - 2.0))
    for dz = -L / 2 + 2, L / 2 - 2, 3.6 do
        trim:AddBox(Vector3(D / 2 + 0.12, H / 2 + 0.2, dz), Vector3(0.16, H - 1.6, 0.18))
        if pause then pause() end
    end
    for _, y in ipairs({ H * 0.35, H * 0.68 }) do
        trim:AddBox(Vector3(D / 2 + 0.12, y, 0), Vector3(0.16, 0.20, L - 1.8))
    end
    -- 横向色带
    accent:AddBox(Vector3(D / 2 + 0.10, H - 0.7, 0), Vector3(0.2, 0.5, L + 0.4))
    -- 大跨度雨棚：整片挑檐 + 前缘封边 + 支撑柱
    local cw, cd = D + 4.8, L + 2.6
    roof:AddBox(Vector3(-0.8, H + 0.5, 0), Vector3(cw, 0.42, cd))
    trim:AddBox(Vector3(D / 2 + 3.0, H + 0.34, 0), Vector3(0.6, 0.5, cd))
    for dz = -L / 2 + 2, L / 2 - 2, 7.0 do
        trim:AddBox(Vector3(D / 2 + 2.6, H / 2, dz), Vector3(0.34, H + 0.4, 0.34))
        if pause then pause() end
    end
    for _, b in ipairs({ body, trim, glass, roof, accent }) do b:Finish(); if pause then pause() end end
end

local BUILDERS = {
    palace = buildPalace,
    tower = buildTower,
    gate = buildGate,
    block = buildBlock,
    terminal = buildTerminal,
}

--- 在已定位/旋转的节点内构建对应原型的站房几何。
---@param node Node
---@param style StationStyle
---@param pause fun()|nil
function StationBuildings.Build(node, style, pause)
    local builder = BUILDERS[style.archetype] or buildPalace
    builder(node, style, pause)
end

return StationBuildings
