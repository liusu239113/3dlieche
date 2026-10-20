-- ============================================================================
-- StationBuildings - 各城市站房原型
-- 五座车站使用不同建筑原型、体量与材质，不再共用同一栋楼。
-- 局部坐标：+X 朝站台方向，Z 沿线路；建筑最低点 Y=0。
-- ============================================================================

local World = require "world.WorldMaterials"
local Materials = require "config.Materials"

local StationBuildings = {}

---@type table<string, Material>
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
---@field asset? boolean 使用独立站房资产

local STATION_MODEL="model/91331fcb-7232-52b8-860e-4d22a5a15592/Meshes/c18152abfa1547eabe3c54bb8fae7f09.mdl"
local CANOPY_MODEL="model/ea12c55a04ce49e7a62e1e952b2b85d0/Meshes/ea12c55a04ce49e7a62e1e952b2b85d0.mdl"
local CANOPY_DIFFUSE="model/ea12c55a04ce49e7a62e1e952b2b85d0/Textures/ea12c55a04ce49e7a62e1e952b2b85d0_00_D.jpg"
local CANOPY_NORMAL="model/ea12c55a04ce49e7a62e1e952b2b85d0/Textures/ea12c55a04ce49e7a62e1e952b2b85d0_00_N.png"
---@type Material?
local stationMaterial_=nil
---@type Material?
local canopyMaterial_=nil
---@return Material
local function stationMaterial()
    if not stationMaterial_ then
        local mat=Material()
        mat:SetTechnique(0,assert(cache:GetResource("Technique","Techniques/PBR/PBRDiffNormal.xml")))
        mat:SetTexture(TU_DIFFUSE,assert(cache:GetResource("Texture2D","model/91331fcb-7232-52b8-860e-4d22a5a15592/Textures/c18152abfa1547eabe3c54bb8fae7f09_00_D.jpg")))
        mat:SetTexture(TU_NORMAL,assert(cache:GetResource("Texture2D","model/91331fcb-7232-52b8-860e-4d22a5a15592/Textures/c18152abfa1547eabe3c54bb8fae7f09_00_N.jpg")))
        mat:SetShaderParameter("Metallic",Variant(.03))
        mat:SetShaderParameter("Roughness",Variant(.9))
        stationMaterial_=mat
    end
    return assert(stationMaterial_)
end

---@return Material
local function canopyMaterial()
    if not canopyMaterial_ then
        local mat=Material()
        mat:SetTechnique(0,assert(cache:GetResource("Technique","Techniques/PBR/PBRDiffNormal.xml")))
        local diffuse=assert(cache:GetResource("Texture2D",CANOPY_DIFFUSE))
        local normal=assert(cache:GetResource("Texture2D",CANOPY_NORMAL))
        diffuse:SetSRGB(true);normal:SetSRGB(false)
        diffuse:SetFilterMode(FILTER_ANISOTROPIC);normal:SetFilterMode(FILTER_ANISOTROPIC)
        diffuse:SetAnisotropy(4);normal:SetAnisotropy(4)
        mat:SetTexture(TU_DIFFUSE,diffuse);mat:SetTexture(TU_NORMAL,normal)
        mat:SetShaderParameter("Metallic",Variant(.42))
        mat:SetShaderParameter("Roughness",Variant(.68))
        canopyMaterial_=mat
    end
    return assert(canopyMaterial_)
end

---@return Model,Vector3
local function canopyAsset()
    local mesh=assert(cache:GetResource("Model",CANOPY_MODEL),"缺少原创站台雨棚模型")
    local size=mesh.boundingBox.size
    assert(size.x>.1 and size.y>.1 and size.z>.1,"雨棚包围盒无效")
    return mesh, size
end

---@return Model,number,Vector3
local function stationAsset()
    local mesh=assert(cache:GetResource("Model",STATION_MODEL),"缺少星汐独立站房模型")
    local size=mesh.boundingBox.size
    assert(size.x>.1 and size.y>.1 and size.z>.1,"站房包围盒无效")
    -- 统一缩放而非拉伸楼层/钟面；占地最长边32米，含门廊/屋檐的真实模型包络。
    return mesh,32/math.max(size.x,size.z),size
end

--- 每座城市一套原型；体量、材质、屋顶形态都不同。
---@type StationStyle[]
StationBuildings.Styles = {
    [1] = { archetype = "palace", asset = false, D = 17.0, L = 62.0, H = 8.6,
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
    [6] = { archetype="palace",D=14,L=42,H=6.6,
        body=Color(.73,.66,.48),trim=Color(.88,.86,.72),roof=Color(.24,.34,.29),accent=Color(.49,.59,.33) },
    [7] = { archetype="gate",D=17,L=46,H=7.6,
        body=Color(.49,.51,.48),trim=Color(.77,.76,.68),roof=Color(.21,.25,.24),accent=Color(.63,.54,.37) },
    [8] = { archetype="tower",D=14,L=44,H=8.8,
        body=Color(.67,.57,.40),trim=Color(.86,.82,.69),roof=Color(.20,.34,.29),accent=Color(.44,.62,.50) },
    [9] = { archetype="block",D=15,L=50,H=8.0,
        body=Color(.70,.69,.59),trim=Color(.86,.86,.78),roof=Color(.28,.33,.31),accent=Color(.45,.56,.42) },
    [10] = { archetype="terminal",D=22,L=58,H=9.2,
        body=Color(.48,.57,.59),trim=Color(.85,.88,.85),roof=Color(.20,.31,.37),accent=Color(.35,.66,.70) },
}

---@param style StationStyle
---@return number radius 完整外包圆半径（含屋檐/门廊）
function StationBuildings.FootprintRadius(style)
    if style.asset then
        local _,scale,size=stationAsset()
        return math.sqrt(size.x^2+size.z^2)*scale*.5+.15
    end
    local overX = style.archetype == "terminal" and 3.4 or 2.2
    local overZ = style.archetype == "palace" and 1.8 or (style.archetype == "terminal" and 1.3 or 1.2)
    return math.sqrt((style.D * 0.5 + overX) ^ 2 + (style.L * 0.5 + overZ) ^ 2)
end

-- ---------------------------------------------------------------------------
-- 星汐：红墙大屋顶，正面柱廊
-- ---------------------------------------------------------------------------
---@param node Node
---@param s StationStyle
---@param pause fun()|nil
local function buildPalace(node, s, pause)
    local body = batch(node, "PalaceBody", World.Textured("XingxiStationBrick","Textures/Railway/brick.png",s.body,.92), true, 1.5)
    local trim = batch(node, "PalaceTrim", solid(s.trim, 0, 0.9), true)
    local roof = batch(node, "PalaceRoof", solid(s.roof, 0.04, 0.9), true)
    local accent = batch(node, "PalaceRidge", solid(s.accent, 0.30, 0.62), true)
    local openings = batch(node,"PalaceDoorWindows",solid(Color(.17,.19,.16),0,.86),false)
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
    -- 门廊前沿距墙1.35米，位于原2.2米挑檐之内，不扩大站房净空包络。
    for dz=-24,24,6 do
        body:AddBox(Vector3(D/2+1.35,H/2,dz),Vector3(.42,H,.42))
        trim:AddBox(Vector3(D/2+1.35,.30,dz),Vector3(.68,.60,.68))
        accent:AddBox(Vector3(D/2+1.35,H-.9,dz),Vector3(.70,.26,.90))
        openings:AddBox(Vector3(D/2+.03,3.20,dz),Vector3(.06,3.80,3.40))
        for _,offset in ipairs({-1.5,1.5}) do
            trim:AddBox(Vector3(D/2+.09,3.20,dz+offset),Vector3(.12,4.0,.14))
        end
        if pause then pause() end
    end
    body:AddBox(Vector3(D/2+1.35,H-.54,0),Vector3(.45,.72,L-3))
    roof:AddBox(Vector3(D/2+1.10,H-.14,0),Vector3(2.20,.18,L-1))
    -- 中央入口加宽，与红砖广场中央进站轴衔接。
    openings:AddBox(Vector3(D/2+.06,2.45,0),Vector3(.12,4.2,6.0))
    trim:AddBox(Vector3(D/2+1.1,.18,0),Vector3(1.6,.36,8))
    for _, b in ipairs({body,trim,roof,accent,openings}) do b:Finish(); if pause then pause() end end
end

-- ---------------------------------------------------------------------------
-- 岚港：钟楼 + 坡顶大厅，竖向构图
-- ---------------------------------------------------------------------------
---@param node Node
---@param s StationStyle
---@param pause fun()|nil
local function buildTower(node, s, pause)
    local body = batch(node, "TowerBody", solid(s.body, 0, 0.93), true, 1.0)
    local trim = batch(node, "TowerTrim", solid(s.trim, 0, 0.9), true)
    local roof = batch(node, "TowerRoof", solid(s.roof, 0.06, 0.88), true)
    local accent = batch(node, "TowerClock", solid(s.accent, 0.10, 0.5), true)
    local dark = batch(node,"ClockHandsAndHallWindows",solid(Color(.13,.20,.25),.08,.82),false)
    local D, L, H = s.D, s.L, s.H
    body:AddBox(Vector3(0, H / 2, 0), Vector3(D, H, L))
    trim:AddBox(Vector3(0, 0.3, 0), Vector3(D + 0.6, 0.6, L + 0.6))
    -- 大厅坡顶
    local hx, hz = D / 2 + 0.6, L / 2 + 0.6
    roof:AddQuad(Vector3(-hx, H, -hz), Vector3(-hx, H, hz), Vector3(0, H + 1.5, hz), Vector3(0, H + 1.5, -hz))
    roof:AddQuad(Vector3(0, H + 1.5, -hz), Vector3(0, H + 1.5, hz), Vector3(hx, H, hz), Vector3(hx, H, -hz))
    body:AddTri(Vector3(-D / 2, H, -L / 2), Vector3(0, H + 1.4, -L / 2), Vector3(D / 2, H, -L / 2))
    body:AddTri(Vector3(-D / 2, H, L / 2), Vector3(D / 2, H, L / 2), Vector3(0, H + 1.4, L / 2))
    -- 中央钟楼从大厅顶升起，四侧设置圆形钟面。
    local th = 7.2
    body:AddBox(Vector3(0, H + th / 2, 0), Vector3(6.4, th, 6.4))
    trim:AddBox(Vector3(0, H + th + 0.2, 0), Vector3(7.4, 0.4, 7.4))
    -- 四面钟：圆形浅钟面与可辨识的时标/指针，共享两批几何而非额外模型。
    local clockY=H+4.6
    for face=1,4 do
        local a=math.pi*(face-1)/2
        local normal=Vector3(math.cos(a),0,math.sin(a))
        local horizontal=Vector3(-math.sin(a),0,math.cos(a))
        local center=normal*3.24+Vector3(0,clockY,0)
        local front=normal*.045
        for i=1,24 do
            local t0,t1=(i-1)*math.pi/12,i*math.pi/12
            accent:AddTri(center,center+horizontal*(1.10*math.cos(t1))+Vector3(0,1.10*math.sin(t1),0),center+horizontal*(1.10*math.cos(t0))+Vector3(0,1.10*math.sin(t0),0))
        end
        for i=1,12 do
            local t=i*math.pi/6
            local u=center+front+horizontal*(.86*math.sin(t))+Vector3(0,.86*math.cos(t),0)
            local v=center+front+horizontal*(1.00*math.sin(t))+Vector3(0,1.00*math.cos(t),0)
            local width=horizontal*(.025*math.cos(t))+Vector3(0,-.025*math.sin(t),0)
            dark:AddQuad(u-width,v-width,v+width,u+width)
        end
        dark:AddQuad(center+front-horizontal*.035,center+front-horizontal*.035+Vector3(0,.74,0),center+front+horizontal*.035+Vector3(0,.74,0),center+front+horizontal*.035)
        dark:AddQuad(center+front+Vector3(0,-.035,0),center+front+Vector3(0,.035,0),center+front+horizontal*.55+Vector3(0,.035,0),center+front+horizontal*.55+Vector3(0,-.035,0))
    end
    for dz=-18,18,6 do
        dark:AddBox(Vector3(D/2+.04,3.9,dz),Vector3(.08,3.2,2.6))
        trim:AddBox(Vector3(D/2+.10,5.62,dz),Vector3(.12,.25,3.0))
    end
    -- 四坡尖顶
    local apex = H + th + 3.4
    local bx, bz = 3.7, 3.7
    roof:AddTri(Vector3(-bx, H + th + 0.4, -bz), Vector3(0, apex, 0), Vector3(bx, H + th + 0.4, -bz))
    roof:AddTri(Vector3(bx, H + th + 0.4, -bz), Vector3(0, apex, 0), Vector3(bx, H + th + 0.4, bz))
    roof:AddTri(Vector3(bx, H + th + 0.4, bz), Vector3(0, apex, 0), Vector3(-bx, H + th + 0.4, bz))
    roof:AddTri(Vector3(-bx, H + th + 0.4, bz), Vector3(0, apex, 0), Vector3(-bx, H + th + 0.4, -bz))
    -- 正门雨罩与钟楼保持独立竖向轮廓。
    roof:AddBox(Vector3(D/2+.9,3.4,0),Vector3(2.0,.18,9))
    for _, b in ipairs({body,trim,roof,accent,dark}) do b:Finish(); if pause then pause() end end
end

-- ---------------------------------------------------------------------------
-- 榆岑：灰石站房与真实连续拱廊，中央门洞不以实心牌面封堵。
-- ---------------------------------------------------------------------------
---@param node Node
---@param s StationStyle
---@param pause fun()|nil
local function buildGate(node, s, pause)
    local body=batch(node,"GateStoneWalls",World.Textured("YucenStationStone","Textures/Railway/concrete.png",s.body,.96),true,2.0)
    local trim=batch(node,"GateArcadeStone",solid(s.trim,0,.94),true)
    local roof=batch(node,"GateRoof",solid(s.roof,.04,.89),true)
    local accent=batch(node,"GateArchCourses",solid(Color(.52,.55,.49),0,.95),true)
    local D,L,H=s.D,s.L,s.H
    -- 站房本体在门洞两侧，+X前沿2米深拱廊；所有拱脚由真实空间围合。
    -- 立面 Z：墙翼 | 4.2米拱 | 柱 | 4.2米拱 | 中央6米门洞 | 对称重复
    local opening=6.0
    local wing=(L-opening)/2
    for side=-1,1,2 do
        body:AddBox(Vector3(-.40,H/2,side*(opening/2+wing/2)),Vector3(D-.8,H,wing))
        trim:AddBox(Vector3(-.40,.28,side*(opening/2+wing/2)),Vector3(D-.4,.56,wing))
    end
    -- 中央贯通门洞过梁只在6米高以上，拱腹不再用阶梯实心板假装。
    body:AddBox(Vector3(-.4,H-.7,0),Vector3(D-.8,1.4,opening))
    local front=D/2+1.12
    local depth=1.7
    for dz=-24,24,6 do
        if math.abs(dz)>=6 then
            trim:AddBox(Vector3(front,1.60,dz),Vector3(depth,3.2,.60))
        end
    end
    for _,centerZ in ipairs({-21,-15,-9,0,9,15,21}) do
        local r=centerZ==0 and 3.0 or 2.7
        local spring=centerZ==0 and 3.50 or 3.20
        local outer=r+.34
        for i=1,12 do
            local a,b=(i-1)*math.pi/12,i*math.pi/12
            local z0,z1=centerZ+r*math.cos(a),centerZ+r*math.cos(b)
            local y0,y1=spring+r*math.sin(a),spring+r*math.sin(b)
            local zo0,zo1=centerZ+outer*math.cos(a),centerZ+outer*math.cos(b)
            local yo0,yo1=spring+outer*math.sin(a),spring+outer*math.sin(b)
            local x0,x1=front-depth/2,front+depth/2
            trim:AddQuad(Vector3(x1,y0,z0),Vector3(x1,y1,z1),Vector3(x1,yo1,zo1),Vector3(x1,yo0,zo0))
            trim:AddQuad(Vector3(x0,yo0,zo0),Vector3(x0,yo1,zo1),Vector3(x0,y1,z1),Vector3(x0,y0,z0))
            accent:AddQuad(Vector3(x0,y0,z0),Vector3(x1,y0,z0),Vector3(x1,y1,z1),Vector3(x0,y1,z1))
            trim:AddQuad(Vector3(x0,yo1,zo1),Vector3(x1,yo1,zo1),Vector3(x1,yo0,zo0),Vector3(x0,yo0,zo0))
        end
        if pause then pause() end
    end
    -- 连续外廊檐盖只在站房包络内；中央门洞拱脚独立于两翼。
    for _,dz in ipairs({-3.30,3.30}) do
        trim:AddBox(Vector3(front,1.75,dz),Vector3(depth,3.5,.60))
    end
    roof:AddBox(Vector3(0,H+.22,0),Vector3(D+1.4,.44,L+1.4))
    trim:AddBox(Vector3(front,H-.44,0),Vector3(depth,.72,L-1.2))
    for _,b in ipairs({body,trim,roof,accent}) do b:Finish(); if pause then pause() end end
end

-- ---------------------------------------------------------------------------
-- 镜澜：宽体三层候车楼、水平窗带与白色单坡入口檐。
-- ---------------------------------------------------------------------------
---@param node Node
---@param s StationStyle
---@param pause fun()|nil
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
    -- 宽厅入口不是凸出的实心门箱：玻璃入口与跨面宽白色斜顶呼应站台。
    glass:AddBox(Vector3(D/2+.15,1.90,0),Vector3(.16,3.6,16))
    local ix,ox=D/2+.14,D/2+2.12
    trim:AddQuad(Vector3(ix,4.80,-L*.43),Vector3(ix,4.80,L*.43),Vector3(ox,4.12,L*.43),Vector3(ox,4.12,-L*.43))
    trim:AddQuad(Vector3(ox,4.04,-L*.43),Vector3(ox,4.04,L*.43),Vector3(ix,4.72,L*.43),Vector3(ix,4.72,-L*.43))
    for dz=-24,24,12 do
        trim:AddBox(Vector3(ox-.14,2.0,dz),Vector3(.16,4.0,.16))
    end
    for _, b in ipairs({ body, trim, glass, roof, accent }) do b:Finish(); if pause then pause() end end
end

-- ---------------------------------------------------------------------------
-- 云湾：现代玻璃枢纽，大跨度雨棚
-- ---------------------------------------------------------------------------
---@param node Node
---@param s StationStyle
---@param pause fun()|nil
local function buildTerminal(node, s, pause)
    local body = batch(node, "TerminalBody", solid(s.body, 0.02, 0.86), true, 1.0)
    local trim = batch(node, "TerminalTrim", solid(s.trim, 0.10, 0.8), true)
    local glass = batch(node, "TerminalGlazing", Materials.Glass(Color(.31,.49,.56,.60)), false)
    local roof = batch(node, "TerminalCanopy", solid(s.roof, 0.16, 0.72), true)
    local accent = batch(node, "TerminalBand", solid(s.accent, 0.26, 0.5), true)
    local D, L, H = s.D, s.L, s.H
    -- 结构核退至玻璃后方2米，前厅玻璃非贴在实心外墙上的深色条带。
    body:AddBox(Vector3(-1.0,H/2,0),Vector3(D-2.0,H,L))
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
    -- 后部金属盖与2.6米连续透光挑檐分开；不是旧版整片实心大盖板。
    local cd=L+2.6
    roof:AddBox(Vector3(-1.0,H+.46,0),Vector3(D+2.0,.20,cd))
    glass:AddBox(Vector3(D/2+2.00,H+.42,0),Vector3(2.60,.10,cd))
    trim:AddBox(Vector3(D/2+3.30,H+.34,0),Vector3(.18,.26,cd))
    for dz=-L/2+2,L/2-2,7 do
        trim:AddBox(Vector3(D/2+2.90,H/2,dz),Vector3(.24,H+.4,.24))
        trim:AddBox(Vector3(D/2+2.00,H+.30,dz),Vector3(2.60,.14,.14))
        if pause then pause() end
    end
    -- 前厅两端玻璃返回面，保持与公共交通接驳雨棚相同的轻盈材料语言。
    for side=-1,1,2 do
        glass:AddBox(Vector3(D/2-.85,H/2+.2,side*(L/2+.045)),Vector3(1.8,H-1.8,.09))
    end
    for _, b in ipairs({ body, trim, glass, roof, accent }) do b:Finish(); if pause then pause() end end
end

-- Glazed platform-facing gallery shares the existing building envelope. Historic roof,
-- clock tower and arcade remain visible behind it; central entrances stay genuinely open.
-- Front +X is limited to D/2+2.10 (within FootprintRadius's existing 2.2m overhang).
---@param node Node
---@param s StationStyle
---@param pause? fun()
local function buildReferenceGallery(node,s,pause)
    local glass = batch(node,"ReferenceStationGlazedGallery",Materials.Glass(Color(.39,.55,.60,.42)),false)
    local frame = batch(node,"ReferenceStationGlazingMullions",solid(Color(.74,.78,.79),.48,.48),true)
    local interior = batch(node,"ReferenceGalleryInterior",solid(Color(.35,.39,.40),.16,.82),false)
    local ceiling = batch(node,"ReferenceGalleryMetalSoffit",solid(Color(.58,.62,.63),.48,.61),true)
    local front,back = s.D/2+2.10,s.D/2+.24
    local low,high = .25,math.min(s.H-.8,6.8)
    local half = s.L/2-1.6
    -- Three-metre panels, two horizontal rails, real return glazing, door mullions.
    -- Exclude middle ±4m: no glass panel seals palace/arcade/terminal entrances.
    for side=-1,1,2 do
        local first,last = side<0 and -half or 4.2,side<0 and -4.2 or half
        local count = math.max(1,math.ceil((last-first)/3))
        local step = (last-first)/count
        for i=1,count do
            local z0,z1 = first+(i-1)*step,first+i*step
            for row=1,3 do
                local y0,y1 = low+(row-1)*(high-low)/3,low+row*(high-low)/3
                glass:AddBox(Vector3(front-.035,(y0+y1)/2,(z0+z1)/2),Vector3(.035,y1-y0-.08,z1-z0-.08))
            end
            frame:AddBox(Vector3(front,(low+high)/2,z0),Vector3(.085,high-low,.085))
            -- Narrow interior bench and handrail visible through the glass, behind outer plane.
            if i%2==0 then
                interior:AddBox(Vector3(back+.50,.61,(z0+z1)/2),Vector3(.56,.09,step-.5))
                for _,dz in ipairs({-.70,.70}) do
                    frame:AddBox(Vector3(back+.50,.33,(z0+z1)/2+dz),Vector3(.35,.52,.045))
                end
            end
        end
        frame:AddBox(Vector3(front,(low+high)/2,last),Vector3(.085,high-low,.085))
        for row=0,3 do
            frame:AddBox(Vector3(front,low+row*(high-low)/3,(first+last)/2),Vector3(.085,.085,last-first))
        end
        for _,z in ipairs({first,last}) do
            glass:AddBox(Vector3((front+back)/2,(low+high)/2,z),Vector3(front-back,high-low,.035))
            frame:AddBox(Vector3(back,(low+high)/2,z),Vector3(.085,high-low,.085))
        end
        ceiling:AddBox(Vector3((front+back)/2,high+.10,(first+last)/2),Vector3(front-back+.12,.12,last-first+.10))
        interior:AddBox(Vector3((front+back)/2,.13,(first+last)/2),Vector3(front-back,.26,last-first))
        for z=first,last,.32 do
            frame:AddBox(Vector3((front+back)/2,high+.025,z),Vector3(front-back,.025,.022))
        end
        if pause then pause() end
    end
    for _,target in ipairs({glass,frame,interior,ceiling}) do
        target:Finish();target.geometry.drawDistance=600
        target.geometry.shadowDistance=100
        if pause then pause() end
    end
end

-- Secondary platform-facing waiting wings. Eight-metre depth, twelve-metre bays:
-- +X is rail-facing; the near face +4.6 never substitutes for the historic main house.
-- Real open arcade/glazed recess, with the city's existing roof/stone/brick vocabulary.
---@param node Node
---@param style StationStyle
---@param pause? fun()
function StationBuildings.BuildPlatformWing(node,style,pause)
    local masonry=batch(node,"NearLineWingMasonry",World.Textured("NearLineWingWall_"..style.archetype,
        style.archetype=="palace" and "Textures/Railway/brick.png" or "Textures/Railway/concrete.png",style.body,.94),true,1.4)
    local trim=batch(node,"NearLineWingPiersAndLintels",solid(style.trim,.06,.87),true)
    local roof=batch(node,"NearLineWingRoof",solid(style.roof,.16,.76),true)
    local recess=batch(node,"NearLineWingRecess",solid(Color(.12,.18,.20),.14,.75),false)
    local glass=batch(node,"NearLineWingGlazing",Materials.Glass(Color(.40,.55,.57,.48)),false)
    local high=style.archetype=="block" and 8.8 or 7.6
    -- Opaque backing is 2.4m behind the facade; no glass pasted onto an outer solid box.
    masonry:AddBox(Vector3(-1.30,high/2,0),Vector3(5.4,high,12))
    trim:AddBox(Vector3(0,.16,0),Vector3(8,.32,12))
    recess:AddBox(Vector3(1.43,3.15,0),Vector3(.06,5.7,10.8))
    for _,z in ipairs({-5.70,0,5.70}) do
        masonry:AddBox(Vector3(3.88,high/2,z),Vector3(.64,high,.52))
        trim:AddBox(Vector3(3.88,.36,z),Vector3(.80,.72,.76))
        trim:AddBox(Vector3(3.88,high-.45,z),Vector3(.86,.36,.82))
    end
    if style.archetype=="gate" then
        -- Hollow two-bay stone arches; no rectangular fake door slab fills the opening.
        for _,cz in ipairs({-2.85,2.85}) do
            for segment=1,12 do
                local a,b=(segment-1)*math.pi/12,segment*math.pi/12
                local inner,outer=2.57,2.88
                local i0=Vector3(4.24,3.6+inner*math.sin(a),cz+inner*math.cos(a))
                local i1=Vector3(4.24,3.6+inner*math.sin(b),cz+inner*math.cos(b))
                local o0=Vector3(4.24,3.6+outer*math.sin(a),cz+outer*math.cos(a))
                local o1=Vector3(4.24,3.6+outer*math.sin(b),cz+outer*math.cos(b))
                trim:AddQuad(i0,i1,o1,o0)
                local back=Vector3(-.55,0,0)
                trim:AddQuad(i0+back,o0+back,o1+back,i1+back)
                trim:AddQuad(i0+back,i1+back,i1,i0)
            end
        end
    else
        -- Two distinct facade scales: high clerestory / recessed full-height waiting windows.
        for _,z in ipairs({-2.85,2.85}) do
            glass:AddBox(Vector3(4.18,3.28,z),Vector3(.035,5.25,5.05))
            for _,dz in ipairs({-1.68,0,1.68}) do
                trim:AddBox(Vector3(4.22,3.28,z+dz),Vector3(.10,5.30,.075))
            end
        end
        for _,y in ipairs({.68,3.82,5.93}) do
            trim:AddBox(Vector3(4.23,y,0),Vector3(.14,.14,11.45))
        end
    end
    trim:AddBox(Vector3(3.90,high-.34,0),Vector3(.80,.56,12))
    if style.archetype=="palace" or style.archetype=="tower" then
        local ridge=high+(style.archetype=="palace" and 1.50 or 1.10)
        roof:AddQuad(Vector3(-4.6,high,-6.12),Vector3(-4.6,high,6.12),Vector3(0,ridge,6.12),Vector3(0,ridge,-6.12))
        roof:AddQuad(Vector3(0,ridge,-6.12),Vector3(0,ridge,6.12),Vector3(4.6,high,6.12),Vector3(4.6,high,-6.12))
        for side=-1,1,2 do
            local z=side*6.02
            if side<0 then masonry:AddTri(Vector3(-4,high,z),Vector3(0,ridge-.08,z),Vector3(4,high,z))
            else masonry:AddTri(Vector3(4,high,z),Vector3(0,ridge-.08,z),Vector3(-4,high,z)) end
        end
        trim:AddBox(Vector3(0,ridge+.04,0),Vector3(.24,.14,12.3))
    elseif style.archetype=="terminal" then
        -- Raised clerestory plus light projecting metal cap, not the palace gable.
        glass:AddBox(Vector3(4.18,6.82,0),Vector3(.045,.82,11.4))
        roof:AddBox(Vector3(-.20,high+.10,0),Vector3(8.8,.18,12.3))
        trim:AddBox(Vector3(4.40,high-.22,0),Vector3(.18,.42,12.3))
    else
        roof:AddBox(Vector3(0,high+.10,0),Vector3(8.6,.20,12.3))
        trim:AddBox(Vector3(4.24,high+.32,0),Vector3(.22,.44,12.3))
        if style.archetype=="block" then
            glass:AddBox(Vector3(4.19,7.12,0),Vector3(.05,1.16,11.4))
            trim:AddBox(Vector3(4.24,7.88,0),Vector3(.15,.16,11.7))
        end
    end
    -- Return glazing is important in approach/oblique views; all materials remain shared.
    for side=-1,1,2 do
        glass:AddBox(Vector3(2.85,3.1,side*5.98),Vector3(2.5,4.8,.035))
    end
    for _,target in ipairs({masonry,trim,roof,recess,glass}) do
        target:Finish();target.geometry.drawDistance=720;target.geometry.shadowDistance=120
        if pause then pause() end
    end
end

---@type table<string, fun(node: Node, style: StationStyle, pause: (fun()|nil))>
local BUILDERS = {
    palace = buildPalace,
    tower = buildTower,
    gate = buildGate,
    block = buildBlock,
    terminal = buildTerminal,
}

---@param parent Node
---@param target Vector3
---@param yaw number
---@param targetLength number
---@param name string
---@return Node
function StationBuildings.BuildCanopyModule(parent,target,yaw,targetLength,name)
    local mesh,size=canopyAsset()
    local box=mesh.boundingBox
    local horizontal=math.max(size.x,size.z)
    local scale=targetLength/math.max(.1,horizontal)
    local rotation=Quaternion(yaw,Vector3.UP)
    local node=parent:CreateChild(name)
    node.position=target-rotation*Vector3(box.center.x*scale,box.min.y*scale,box.center.z*scale)
    node.rotation=rotation
    node.scale=Vector3.ONE*scale
    local drawable=node:CreateComponent("StaticModel")
    drawable.model=mesh
    drawable:SetMaterial(0,canopyMaterial())
    drawable.viewMask,drawable.castShadows,drawable.shadowDistance,drawable.drawDistance=2,true,140,900
    return node
end

--- 在已定位/旋转的节点内构建对应原型的站房几何。
---@param node Node
---@param style StationStyle
---@param pause fun()|nil
function StationBuildings.Build(node, style, pause)
    if style.asset then
        local mesh,scale=stationAsset()
        local box=mesh.boundingBox
        local center=box.center
        local house=node:CreateChild("DetailedStationHouse")
        -- 资产正立面原始-Z，旋转-90°后朝本地+X站台。
        local rotation=Quaternion(-90,Vector3.UP)
        house.scale,house.rotation=Vector3.ONE*scale,rotation
        house.position=Vector3(0,-box.min.y*scale,0)-rotation*Vector3(center.x*scale,0,center.z*scale)
        local drawable=house:CreateComponent("StaticModel")
        drawable.model=mesh
        drawable:SetMaterial(0,stationMaterial())
        drawable.viewMask,drawable.castShadows,drawable.shadowDistance,drawable.drawDistance=2,true,180,1400
        -- 模型自带四级 LOD，缓存共享；只有近站一栋，不沿全线复制高面数建筑。
        print("[StationBuildings] 星汐红砖钟楼独立站房接入，旧实心大厅/方柱/拼装屋顶不再构建")
        if pause then pause() end
        return
    end
    local builder = BUILDERS[style.archetype] or buildPalace
    builder(node, style, pause)
    buildReferenceGallery(node,style,pause)
end

---@param style StationStyle
---@return Vector3
function StationBuildings.GetSignPosition(style)
    if style.asset then
        local _,scale,size=stationAsset()
        return Vector3(size.z*scale*.5+.12,6.5,0)
    end
    local overhang=style.archetype=="terminal" and 3.45 or 2.15
    return Vector3(style.D/2+overhang,style.H*.86,0)
end

return StationBuildings
