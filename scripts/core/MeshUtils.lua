-- ============================================================================
-- MeshUtils - 建模工具
-- 用程序化几何体 API（three.js 兼容）搭出火车 / 站台 / 建筑等
-- GeoBuilder：把大量小部件（枕木、栏杆）合并进单个 CustomGeometry，
--             避免上千个 draw call
-- ============================================================================

local Materials = require "config.Materials"

local MeshUtils = {}

-- 几何缓存：同参数几何只建一份 Model，多节点复用
local _modelCache = {}

local function cacheKey(...)
    local parts = {}
    for i = 1, select("#", ...) do
        local v = select(i, ...)
        if type(v) == "number" then
            parts[i] = string.format("%.4f", v)
        else
            parts[i] = tostring(v)
        end
    end
    return table.concat(parts, "_")
end

--- 取（或创建）一个缓存过的 Model
---@param key string
---@param factory fun():Model
---@return Model
function MeshUtils.GetModel(key, factory)
    local m = _modelCache[key]
    if m then return m end
    m = factory()
    _modelCache[key] = m
    return m
end

--- 缓存的 Box Model
---@param w number
---@param h number
---@param d number
---@return Model
function MeshUtils.Box(w, h, d)
    return MeshUtils.GetModel("box_" .. cacheKey(w, h, d), function()
        return BoxGeometry(w, h, d):ToModel()
    end)
end

--- 缓存的 Cylinder Model
function MeshUtils.Cylinder(rt, rb, h, seg)
    seg = seg or 16
    return MeshUtils.GetModel("cyl_" .. cacheKey(rt, rb, h, seg), function()
        return CylinderGeometry(rt, rb, h, seg):ToModel()
    end)
end

--- 缓存的 Sphere Model
function MeshUtils.Sphere(r, seg)
    seg = seg or 16
    return MeshUtils.GetModel("sph_" .. cacheKey(r, seg), function()
        return SphereGeometry(r, seg, math.max(4, math.floor(seg / 2))):ToModel()
    end)
end

--- 缓存的圆锥 Model（apex 在 +h/2，底面在 -h/2）
function MeshUtils.Cone(r, h, seg)
    seg = seg or 12
    return MeshUtils.GetModel("cone_" .. cacheKey(r, h, seg), function()
        return ConeGeometry(r, h, seg):ToModel()
    end)
end

-- ---------------------------------------------------------------------------
-- 部件创建（每个部件一个节点）
-- ---------------------------------------------------------------------------

--- 创建一个立方体部件
---@param parent Node
---@param name string
---@param pos Vector3 相对父节点位置
---@param size Vector3 尺寸
---@param material Material
---@param rotY number|nil 绕 Y 轴旋转（度）
---@return Node
function MeshUtils.BoxPart(parent, name, pos, size, material, rotY)
    local node = parent:CreateChild(name)
    node.position = pos
    if rotY and rotY ~= 0 then
        node.rotation = Quaternion(rotY, Vector3.UP)
    end
    local sm = node:CreateComponent("StaticModel")
    sm.model = MeshUtils.Box(size.x, size.y, size.z)
    sm:SetMaterial(material)
    sm.castShadows = true
    return node
end

--- 创建一个圆柱部件（默认轴向 Y）
function MeshUtils.CylPart(parent, name, pos, radius, height, material, rotAxis, rotAngle)
    local node = parent:CreateChild(name)
    node.position = pos
    if rotAxis and rotAngle and rotAngle ~= 0 then
        node.rotation = Quaternion(rotAngle, rotAxis)
    end
    local sm = node:CreateComponent("StaticModel")
    sm.model = MeshUtils.Cylinder(radius, radius, height, 16)
    sm:SetMaterial(material)
    sm.castShadows = true
    return node
end

--- 创建一个球体部件
function MeshUtils.SpherePart(parent, name, pos, radius, material)
    local node = parent:CreateChild(name)
    node.position = pos
    local sm = node:CreateComponent("StaticModel")
    sm.model = MeshUtils.Sphere(radius, 14)
    sm:SetMaterial(material)
    sm.castShadows = true
    return node
end

--- 由顶点表创建部件
---@param parent Node
---@param name string
---@param pos Vector3
---@param verts Vector3[] 每 3 个一组构成三角形
---@param material Material
---@return Node
function MeshUtils.TriPart(parent, name, pos, verts, material)
    local node = parent:CreateChild(name)
    node.position = pos
    local cg = node:CreateComponent("CustomGeometry")
    cg:BeginGeometry(0, TRIANGLE_LIST)
    for i = 1, #verts, 3 do
        ---@type Vector3
        local p1 = verts[i]
        ---@type Vector3
        local p2 = verts[i + 1]
        ---@type Vector3
        local p3 = verts[i + 2]
        ---@type Vector3
        local n = (p2 - p1):CrossProduct(p3 - p1)
        if n:LengthSquared() > 0.0000001 then n = n:Normalized() else n = Vector3.UP end
        cg:DefineVertex(p1); cg:DefineNormal(n); cg:DefineTexCoord(Vector2(0, 0))
        cg:DefineVertex(p2); cg:DefineNormal(n); cg:DefineTexCoord(Vector2(1, 0))
        cg:DefineVertex(p3); cg:DefineNormal(n); cg:DefineTexCoord(Vector2(0, 1))
    end
    cg:Commit()
    cg:SetMaterial(material)
    return node
end

-- ---------------------------------------------------------------------------
-- GeoBuilder：把大量部件合并成单个 mesh
-- ---------------------------------------------------------------------------

---@class GeoBuilder
---@field verts Vector3[]
---@field norms Vector3[]
---@field uvs Vector2[]
local GeoBuilder = {}
GeoBuilder.__index = GeoBuilder

---@return GeoBuilder
function MeshUtils.NewBuilder()
    return setmetatable({ verts = {}, norms = {}, uvs = {}, _n = 0 }, GeoBuilder)
end

--- 追加一个三角形（逆时针 = 正面朝外）
---@param p1 Vector3
---@param p2 Vector3
---@param p3 Vector3
function GeoBuilder:AddTri(p1, p2, p3)
    local n = (p2 - p1):CrossProduct(p3 - p1)
    if n:LengthSquared() > 0.0000001 then
        n = n:Normalized()
    else
        n = Vector3.UP
    end
    local i = self._n
    self.verts[i + 1] = p1
    self.verts[i + 2] = p2
    self.verts[i + 3] = p3
    self.norms[i + 1] = n
    self.norms[i + 2] = n
    self.norms[i + 3] = n
    self.uvs[i + 1] = Vector2(0, 0)
    self.uvs[i + 2] = Vector2(1, 0)
    self.uvs[i + 3] = Vector2(0, 1)
    self._n = i + 3
end

--- 追加一个四边形（p1→p2→p3→p4 逆时针）
function GeoBuilder:AddQuad(p1, p2, p3, p4)
    self:AddTri(p1, p2, p3)
    self:AddTri(p1, p3, p4)
end

--- 追加一个轴对齐（可绕 Y 旋转）的长方体
---@param center Vector3
---@param size Vector3
---@param yawRad number|nil
function GeoBuilder:AddBox(center, size, yawRad)
    local hx, hy, hz = size.x * 0.5, size.y * 0.5, size.z * 0.5
    local c, s = 1.0, 0.0
    if yawRad and yawRad ~= 0 then
        c, s = math.cos(yawRad), math.sin(yawRad)
    end

    -- 局部角点 → 世界（绕 Y 旋转 + 平移）
    local function corner(lx, ly, lz)
        return Vector3(
            center.x + lx * c + lz * s,
            center.y + ly,
            center.z - lx * s + lz * c
        )
    end

    local p000 = corner(-hx, -hy, -hz)
    local p100 = corner(hx, -hy, -hz)
    local p110 = corner(hx, hy, -hz)
    local p010 = corner(-hx, hy, -hz)
    local p001 = corner(-hx, -hy, hz)
    local p101 = corner(hx, -hy, hz)
    local p111 = corner(hx, hy, hz)
    local p011 = corner(-hx, hy, hz)

    -- 顶 (+y)
    self:AddQuad(p010, p011, p111, p110)
    -- 底 (-y)
    self:AddQuad(p000, p100, p101, p001)
    -- 前 (-z)
    self:AddQuad(p000, p010, p110, p100)
    -- 后 (+z)
    self:AddQuad(p001, p101, p111, p011)
    -- 左 (-x)
    self:AddQuad(p000, p001, p011, p010)
    -- 右 (+x)
    self:AddQuad(p100, p110, p111, p101)
end

--- 把累积的几何提交到一个节点
---@param node Node
---@param material Material
---@return integer 顶点数
function GeoBuilder:CommitTo(node, material)
    local cg = node:CreateComponent("CustomGeometry")
    cg:BeginGeometry(0, TRIANGLE_LIST)
    for i = 1, self._n do
        cg:DefineVertex(self.verts[i])
        cg:DefineNormal(self.norms[i])
        cg:DefineTexCoord(self.uvs[i])
    end
    cg:GenerateTangents()
    cg:Commit()
    cg:SetMaterial(material)
    local count = self._n
    self.verts, self.norms, self.uvs, self._n = {}, {}, {}, 0
    return count
end

---@return integer 已累积顶点数
function GeoBuilder:Count()
    return self._n
end

--- 清空几何缓存（场景重建时调用）
function MeshUtils.ClearCache()
    _modelCache = {}
end

return MeshUtils
