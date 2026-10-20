-- 仅世界使用的工程材质、流式合并网格及米制 UV。
-- 不修改共享材质工厂，避免干扰同时编辑的列车和界面模块。
local BaseMaterials = require "config.Materials"
local MeshUtils = require "core.MeshUtils"
local WorldMaterials = {}
---@type table<string, Material?>
local materials_ = {}
-- 仅指定草地/农田/土底采用统一的米制密度；桥谷、洞壳的SlopeGrass仍保留原UV。
---@type table<Material, number>
local surfaceTiles_ = {}

---@param key string
---@param texturePath string
---@param color Color
---@param roughness number
---@param metallic number|nil
---@return Material
function WorldMaterials.Textured(key, texturePath, color, roughness, metallic)
    if materials_[key] then return materials_[key] end
    local texture = cache:GetResource("Texture2D", texturePath)
    local technique = cache:GetResource("Technique", "Techniques/PBR/PBRDiff.xml")
    if not texture or not technique then
        print("[WorldMaterials] 警告：工程纹理或技术缺失：" .. texturePath .. "；回退到非木纹纯色")
        materials_[key] = BaseMaterials.Solid(color, metallic or 0, roughness)
        return materials_[key]
    end
    texture:SetSRGB(true)
    texture:SetFilterMode(FILTER_ANISOTROPIC)
    texture:SetAnisotropy(4)
    local material = Material:new()
    material:SetTechnique(0, technique)
    material:SetTexture(TU_DIFFUSE, texture)
    material:SetShaderParameter("MatDiffColor", Variant(color))
    material:SetShaderParameter("Metallic", Variant(metallic or 0))
    material:SetShaderParameter("Roughness", Variant(roughness))
    materials_[key] = material
    print("[WorldMaterials] 已加载本地工程纹理：" .. texturePath)
    return material
end

-- 混凝土、碎石、草地及砖墙均使用可验收的本地工程纹理。
-- 旧站台材质曾显示木纹，本轮不访问未经验证的远端 UUID。
function WorldMaterials.Concrete()
    return WorldMaterials.Textured("Concrete", "Textures/Railway/concrete.png", Color(0.91, 0.92, 0.92), 0.92)
end
function WorldMaterials.Ballast()
    return WorldMaterials.Textured("Ballast", "Textures/Railway/ballast.png", Color(0.90, 0.91, 0.92), 0.97)
end
function WorldMaterials.Grass()
    return WorldMaterials.Textured("Grass", "Textures/Railway/grass.png", Color(0.86, 0.88, 0.82), 0.98)
end
function WorldMaterials.Brick()
    return WorldMaterials.Textured("Brick", "Textures/Railway/brick.png", Color(0.92, 0.90, 0.86), 0.88)
end

-- ---------------------------------------------------------------------------
-- 地表纹理材质（PBRDiffNormal + 法线贴图 + 平面投影 UV）
-- 用于大面积地面/农田/山坡：法线贴图让地表在阳光下产生细微起伏感，
-- 平面投影 UV 让纹理沿世界坐标连续平铺，彻底消除"纯色块"观感。
-- ---------------------------------------------------------------------------
---@param key string
---@param texturePath string
---@param normalPath string
---@param tint Color
---@param roughness number
---@param tileMeters number 每次平铺对应的米数
---@return Material
function WorldMaterials.Terrain(key, texturePath, normalPath, tint, roughness, tileMeters)
    if materials_[key] then return materials_[key] end
    local diffuse = cache:GetResource("Texture2D", texturePath)
    local normal = normalPath and cache:GetResource("Texture2D", normalPath) or nil
    if normal and not MeshUtils.SupportsTangents() then normal = nil end
    local technique = cache:GetResource("Technique",
        normal and "Techniques/PBR/PBRDiffNormal.xml" or "Techniques/PBR/PBRDiff.xml")
    if not diffuse or not technique then
        print("[WorldMaterials] 警告：地表纹理缺失 " .. texturePath .. "；回退纯色")
        materials_[key] = BaseMaterials.Solid(tint, 0, roughness)
        return materials_[key]
    end
    diffuse:SetSRGB(true)
    diffuse:SetFilterMode(FILTER_ANISOTROPIC)
    diffuse:SetAnisotropy(8)
    if normal then
        normal:SetSRGB(false)
        normal:SetFilterMode(FILTER_ANISOTROPIC)
        normal:SetAnisotropy(8)
    end
    local material = Material:new()
    material:SetTechnique(0, technique)
    material:SetTexture(TU_DIFFUSE, diffuse)
    if normal then material:SetTexture(TU_NORMAL, normal) end
    material:SetShaderParameter("MatDiffColor", Variant(tint))
    material:SetShaderParameter("Metallic", Variant(0.0))
    material:SetShaderParameter("Roughness", Variant(roughness))
    -- UV 由几何顶点按世界坐标写入，材质侧保持 1:1，避免双重缩放。
    material:SetUVTiling(Vector2(1, 1))
    materials_[key] = material
    print(string.format("[WorldMaterials] 地表纹理 %s tile=%.1fm normal=%s", texturePath, tileMeters, normal and "有" or "无"))
    return material
end

-- 地表专用离线烘焙：复用grass.png的微纹理，草茎/草簇/露土斑分布在同一51.2m周期。
-- 三图同相位；土肩与草地在原面裁分，绝不生成透明盖片或新shader变体。
-- SlopeGrass/桥谷/洞壳仍保留原资源/UV，混凝土/道床/列车完全不在此表内。
local function groundSurface(key,path,tint)
    local material=WorldMaterials.Terrain(key,path,nil,tint,.98,51.2)
    surfaceTiles_[material]=51.2
    return material
end
function WorldMaterials.Grassland()
    return groundSurface("Grassland","Textures/Railway/ground_meadow.png",Color(.92,.94,.87))
end
function WorldMaterials.Cropland()
    return groundSurface("Cropland","Textures/Railway/ground_meadow.png",Color(.98,.92,.74))
end
function WorldMaterials.DryEarth()
    return groundSurface("DryEarth","Textures/Railway/ground_earth.png",Color(.94,.92,.86))
end
function WorldMaterials.GroundEarth()
    return groundSurface("GroundEarth","Textures/Railway/ground_earth.png",Color(.94,.92,.86))
end
function WorldMaterials.GroundVerge()
    return groundSurface("GroundVerge","Textures/Railway/ground_verge.png",Color(.94,.94,.87))
end
---@param material Material
---@return number?
function WorldMaterials.GetSurfaceTile(material) return surfaceTiles_[material] end
function WorldMaterials.UrbanGround()
    return WorldMaterials.Terrain("UrbanGround", "Textures/Railway/concrete.png",
        nil, Color(0.52, 0.53, 0.52), 0.94, 8.0)
end

-- 水面：低粗糙度 + 高金属度，配合 SSR 产生镜面反射与天空倒影。
-- 比旧纯色水更接近参考图里"能看见天空反光"的水面。
function WorldMaterials.Water()
    if materials_["Water"] then return materials_["Water"] end
    local material = Material:new()
    material:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
    material:SetShaderParameter("MatDiffColor", Variant(Color(0.10, 0.28, 0.33, 0.86)))
    material:SetShaderParameter("Metallic", Variant(0.55))
    material:SetShaderParameter("Roughness", Variant(0.06))
    materials_["Water"] = material
    return material
end
function WorldMaterials.Solid(color, metallic, roughness)
    return BaseMaterials.Solid(color, metallic or 0, roughness or 0.8)
end

---@class RailwayBatch
---@field geometry CustomGeometry
---@field tile number
---@field surfaceTile number?
---@field vertices integer
---@field needsTangents boolean
local Batch = {}
Batch.__index = Batch

---@param node Node
---@param material Material
---@param shadows boolean|nil
---@param tile number|nil 每次纹理平铺对应的米数
---@return RailwayBatch
function WorldMaterials.NewBatch(node, material, shadows, tile)
    local batch = setmetatable({}, Batch)
    batch:Init(node, material, shadows, tile)
    return batch
end
function Batch:Init(node, material, shadows, tile)
    self.geometry = node:CreateComponent("CustomGeometry")
    self.geometry.viewMask = 2 -- 环境射线使用掩码 2，相机显示掩码 3
    self.geometry.castShadows = shadows == true
    self.geometry:BeginGeometry(0, TRIANGLE_LIST)
    self.geometry:SetMaterial(material)
    self.tile = surfaceTiles_[material] or tile or 1
    self.surfaceTile = surfaceTiles_[material]
    self.vertices = 0
    -- 切线能力不可用时，材质已退回无法线技术，这里也不会再触发 GenerateTangents。
    self.needsTangents = material:GetTexture(TU_NORMAL) ~= nil and MeshUtils.SupportsTangents()
end

---@param p Vector3
---@param uv Vector2
---@param normal Vector3
function Batch:Vertex(p, uv, normal)
    self.geometry:DefineVertex(p)
    self.geometry:DefineNormal(normal)
    self.geometry:DefineTexCoord(uv)
    self.vertices = self.vertices + 1
end

---@param a Vector3
---@param b Vector3
---@param c Vector3
---@param ua Vector2|nil
---@param ub Vector2|nil
---@param uc Vector2|nil
function Batch:AddTri(a, b, c, ua, ub, uc)
    local cross = (b - a):CrossProduct(c - a)
    if cross:LengthSquared() < 0.000000001 then return end
    local normal = cross:Normalized()
    self:Vertex(a, ua or Vector2(0, 0), normal)
    self:Vertex(b, ub or Vector2(1, 0), normal)
    self:Vertex(c, uc or Vector2(0, 1), normal)
end

-- 世界空间平面投影 UV（XZ 平面）：大范围地表必须用它，
-- 否则每个三角形各自拉伸整张贴图，纹理完全糊成色块。
---@param a Vector3
---@param b Vector3
---@param c Vector3
---@param scale number 每次平铺对应的米数
function Batch:AddTriPlanar(a, b, c, scale)
    local s = 1.0 / (self.surfaceTile or scale or self.tile)
    self:AddTri(a, b, c,
        Vector2(a.x * s, a.z * s), Vector2(b.x * s, b.z * s), Vector2(c.x * s, c.z * s))
end

-- 四边形两三角形共享连续 UV。旧工具每个三角形都重置 UV，
-- 导致站台纹理沿对角线扭曲；这里用实际边长确定纹理密度。
---@param a Vector3
---@param b Vector3
---@param c Vector3
---@param d Vector3
---@param uvOrigin? Vector2 纹理原点偏移；复用同批材质打散相邻石板的重复采样
function Batch:AddQuad(a, b, c, d, uvOrigin)
    local u = (d - a):Length() / self.tile
    local v = (b - a):Length() / self.tile
    local origin = uvOrigin or Vector2(0, 0)
    self:AddTri(a, b, c, origin, origin + Vector2(0, v), origin + Vector2(u, v))
    self:AddTri(a, c, d, origin, origin + Vector2(u, v), origin + Vector2(u, 0))
end

---@param center Vector3
---@param size Vector3
---@param yaw number|nil 弧度
function Batch:AddBox(center, size, yaw)
    local hx, hy, hz = size.x / 2, size.y / 2, size.z / 2
    local co, si = math.cos(yaw or 0), math.sin(yaw or 0)
    local function p(x, y, z)
        return Vector3(center.x + x * co + z * si, center.y + y, center.z - x * si + z * co)
    end
    local a, b, c, d = p(-hx, -hy, -hz), p(hx, -hy, -hz), p(hx, hy, -hz), p(-hx, hy, -hz)
    local e, f, g, h = p(-hx, -hy, hz), p(hx, -hy, hz), p(hx, hy, hz), p(-hx, hy, hz)
    self:AddQuad(d, h, g, c) -- 顶面
    self:AddQuad(a, b, f, e) -- 底面
    self:AddQuad(a, d, c, b)
    self:AddQuad(e, f, g, h)
    self:AddQuad(a, e, h, d)
    self:AddQuad(b, c, g, f)
end

-- 合批圆管：端点已经过线路变换，不能用每根一个 StaticModel 增加节点/批次。
-- 侧面使用径向平滑法线；封口独立法线，适用于钢柱、斜撑和弯管分段。
---@param a Vector3
---@param b Vector3
---@param radius number
---@param segments? integer
function Batch:AddTube(a, b, radius, segments)
    local delta = b - a
    local length = delta:Length()
    if length < .00001 or radius <= 0 then return end
    local axis = delta / length
    local reference = math.abs(axis.y) < .9 and Vector3.UP or Vector3.RIGHT
    local u = axis:CrossProduct(reference):Normalized()
    local v = axis:CrossProduct(u):Normalized()
    local count = segments or 8
    for i = 1, count do
        local t0, t1 = (i - 1) * math.pi * 2 / count, i * math.pi * 2 / count
        local n0 = u * math.cos(t0) + v * math.sin(t0)
        local n1 = u * math.cos(t1) + v * math.sin(t1)
        local p0, p1 = a + n0 * radius, a + n1 * radius
        local q0, q1 = b + n0 * radius, b + n1 * radius
        local s0, s1 = (i - 1) / count, i / count
        self:Vertex(p0, Vector2(s0, 0), n0)
        self:Vertex(p1, Vector2(s1, 0), n1)
        self:Vertex(q1, Vector2(s1, length / self.tile), n1)
        self:Vertex(p0, Vector2(s0, 0), n0)
        self:Vertex(q1, Vector2(s1, length / self.tile), n1)
        self:Vertex(q0, Vector2(s0, length / self.tile), n0)
        self:AddTri(a, p1, p0)
        self:AddTri(b, q0, q1)
    end
end

-- 非对称椭球树冠，轻微方位扰动打破玩具轮廓。
-- 不生成大锥体或球头圆柱人；树冠法线平滑，保持自然低饱和颜色。
---@param center Vector3
---@param radii Vector3
---@param phase number
function Batch:AddCrown(center, radii, phase)
    local segments, rings = 12, 8
    local function point(ring, segment)
        local phi = math.pi * ring / rings
        local theta = 2 * math.pi * segment / segments
        local lobe = 1 + 0.09 * math.sin(3 * theta + phase) * math.sin(phi)
        local dx, dy, dz = math.sin(phi) * math.cos(theta), math.cos(phi), math.sin(phi) * math.sin(theta)
        local p = Vector3(center.x + radii.x * dx * lobe, center.y + radii.y * dy,
            center.z + radii.z * dz * lobe)
        local n = Vector3(dx / radii.x, dy / radii.y, dz / radii.z):Normalized()
        return p, n, Vector2(segment / segments, ring / rings)
    end
    for ring = 1, rings do
        for segment = 1, segments do
            local a, na, ua = point(ring - 1, segment - 1)
            local b, nb, ub = point(ring, segment - 1)
            local c, nc, uc = point(ring, segment)
            local d, nd, ud = point(ring - 1, segment)
            if ring > 1 then
                self:Vertex(a, ua, na); self:Vertex(d, ud, nd); self:Vertex(c, uc, nc)
            end
            if ring < rings then
                self:Vertex(a, ua, na); self:Vertex(c, uc, nc); self:Vertex(b, ub, nb)
            end
        end
    end
end

---@return integer
function Batch:Finish()
    if self.vertices > 0 then
        -- 某些运行时虽然暴露了 GenerateTangents 名称，但调用仍会抛出 nil method。
        -- 世界几何不能因可选的法线切线失败而中断加载；失败时保留顶点法线并提交。
        if self.needsTangents then
            local generateTangents = self.geometry.GenerateTangents
            if type(generateTangents) == "function" then
                pcall(generateTangents,self.geometry)
            end
        end
        self.geometry:Commit()
    else
        -- 空批次不能 Dispose：调用方在 Finish 之后仍会写 geometry.viewMask 等属性，
        -- 已释放对象会让 tolua 抛 "invalid 'self'"。改为停用，渲染开销为零。
        self.geometry.enabled = false
    end
    return self.vertices
end
return WorldMaterials
