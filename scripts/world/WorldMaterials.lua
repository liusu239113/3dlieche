-- 仅世界使用的工程材质、流式合并网格及米制 UV。
-- 不修改共享材质工厂，避免干扰同时编辑的列车和界面模块。
local BaseMaterials = require "config.Materials"
local WorldMaterials = {}
---@type table<string, Material?>
local materials_ = {}

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
function WorldMaterials.Solid(color, metallic, roughness)
    return BaseMaterials.Solid(color, metallic or 0, roughness or 0.8)
end

---@class RailwayBatch
---@field geometry CustomGeometry
---@field tile number
---@field vertices integer
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
    self.tile = tile or 1
    self.vertices = 0
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

-- 四边形两三角形共享连续 UV。旧工具每个三角形都重置 UV，
-- 导致站台纹理沿对角线扭曲；这里用实际边长确定纹理密度。
---@param a Vector3
---@param b Vector3
---@param c Vector3
---@param d Vector3
function Batch:AddQuad(a, b, c, d)
    local u = (d - a):Length() / self.tile
    local v = (b - a):Length() / self.tile
    self:AddTri(a, b, c, Vector2(0, 0), Vector2(0, v), Vector2(u, v))
    self:AddTri(a, c, d, Vector2(0, 0), Vector2(u, v), Vector2(u, 0))
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
        self.geometry:GenerateTangents()
        self.geometry:Commit()
    else
        self.geometry:Dispose()
    end
    return self.vertices
end
return WorldMaterials
