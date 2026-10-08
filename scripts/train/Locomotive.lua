-- ============================================================================
-- Locomotive - 已验收蓝白机车资产的加载、米制尺寸与轮轨校准
-- ============================================================================

local GameConfig = require "config.GameConfig"
local RollingStock = require "train.RollingStock"
local Catalog = require "config.TrainCatalog"

local Locomotive = {}

local MODEL_PATH = "model/228b03702ab649048d477f0df9bf5feb/Meshes/228b03702ab649048d477f0df9bf5feb.mdl"
local DIFFUSE_PATH = "model/228b03702ab649048d477f0df9bf5feb/Textures/228b03702ab649048d477f0df9bf5feb_00_D.jpg"
local NORMAL_PATH = "model/228b03702ab649048d477f0df9bf5feb/Textures/228b03702ab649048d477f0df9bf5feb_00_N.png"

Locomotive.Length = 21.0
local WIDTH = 3.1
local HEIGHT = 4.1
local RAIL_TOP = 0.34
-- 根据交付顶点主轴和引擎侧视复核，旋转后白色驾驶室朝 +Z。
local SOURCE_YAW = -44.84771127

---@type Model|nil
local calibratedModel_ = nil
---@type Material|nil
local material_ = nil
---@type StaticModel|nil
local drawable_ = nil
local cabView_ = false

local function median(values)
    assert(#values > 0, "机车轮轨校准未找到踏面顶点")
    table.sort(values)
    local mid = math.floor((#values + 1) * 0.5)
    if #values % 2 == 0 then return (values[mid] + values[mid + 1]) * 0.5 end
    return values[mid]
end

--- 从相邻三角形的 UV 推导零切线的手性，保留镜像 UV 的符号。
---@param geometry Geometry
---@return table<number, Vector3>
local function getBitangents(geometry)
    local vb = geometry:GetVertexBuffer(0)
    local data = vb:GetData()
    local stride = vb.vertexSize
    local posOffset = vb:GetElementOffset(SEM_POSITION)
    local uvOffset = vb:GetElementOffset(SEM_TEXCOORD)
    local indices = geometry:GetIndexBuffer()
    local indexData = indices:GetData()
    indexData:Seek(geometry.indexStart * indices.indexSize)
    local bitangents = {}
    local function readVertex(index)
        data:Seek(index * stride + posOffset)
        local p = data:ReadVector3()
        data:Seek(index * stride + uvOffset)
        return p, data:ReadVector2()
    end
    for _ = 1, math.floor(geometry.indexCount / 3) do
        local a, b, c
        if indices.indexSize == 2 then
            a, b, c = indexData:ReadUShort(), indexData:ReadUShort(), indexData:ReadUShort()
        else
            a, b, c = indexData:ReadUInt(), indexData:ReadUInt(), indexData:ReadUInt()
        end
        local p0, uv0 = readVertex(a)
        local p1, uv1 = readVertex(b)
        local p2, uv2 = readVertex(c)
        local d1, d2 = uv1 - uv0, uv2 - uv0
        local determinant = d1.x * d2.y - d1.y * d2.x
        if math.abs(determinant) > 0.00000001 then
            local bitangent = ((p2 - p0) * d1.x - (p1 - p0) * d2.x) / determinant
            for _, index in ipairs({ a, b, c }) do
                bitangents[index] = (bitangents[index] or Vector3.ZERO) + bitangent
            end
        end
    end
    return bitangents
end

--- 从实际顶点获取正向尺寸，不能按未旋转的方形包围盒猜车长。
---@param source Model
---@return Model
local function calibrateModel(source)
    local rotation = Quaternion(SOURCE_YAW, Vector3.UP)
    local bounds = BoundingBox()
    local geometry = source:GetGeometry(0, 0)
    local buffer = geometry:GetVertexBuffer(0)
    local data = buffer:GetData()
    local stride = buffer.vertexSize
    local positionOffset = buffer:GetElementOffset(SEM_POSITION)
    local positions = {}

    for i = 0, buffer.vertexCount - 1 do
        data:Seek(i * stride + positionOffset)
        local position = rotation * data:ReadVector3()
        positions[#positions + 1] = position
        bounds:Merge(position)
    end

    local size = bounds.size
    local center = bounds.center
    assert(size.x > 0.001 and size.y > 0.001 and size.z > 0.001, "机车模型尺寸无效")

    -- 轮轨接触设计（这里只校准视觉网格，不新建碰撞体）：
    --       宽车体 / 底架
    --      ┌───────────┐
    --      └─┐       ┌─┘   两组转向架在纵向分离
    --        O       O     低位踏面中心对应两根钢轨
    --        ═       ═     横距 = RailGauge，踏面最低点 = RAIL_TOP
    -- 排障器和车钩可能低于轮缘，不能把整个模型最低点当作车轮接触点。
    local leftTreads, rightTreads = {}, {}
    local wheelBottom = math.huge
    for _, position in ipairs(positions) do
        local longitudinal = math.abs((position.z - center.z) / size.z)
        local lateral = position.x - center.x
        local inBogie = longitudinal > 0.11 and longitudinal < 0.41
        if inBogie and math.abs(lateral) > size.x * 0.18
            and position.y < bounds.min.y + size.y * 0.16 then
            wheelBottom = math.min(wheelBottom, position.y)
            if position.y < bounds.min.y + size.y * 0.075 then
                if lateral < 0 then
                    leftTreads[#leftTreads + 1] = position.x
                else
                    rightTreads[#rightTreads + 1] = position.x
                end
            end
        end
    end

    local leftCenter, rightCenter = median(leftTreads), median(rightTreads)
    local wheelCenter = (leftCenter + rightCenter) * 0.5
    local sourceGauge = rightCenter - leftCenter
    assert(sourceGauge > 0.001 and wheelBottom < math.huge, "机车轮距测量无效")

    local sx, sy, sz = WIDTH / size.x, HEIGHT / size.y, Locomotive.Length / size.z
    local wheelScaleX = GameConfig.RailGauge / sourceGauge
    local model = source:Clone("CalibratedBlueWhiteLocomotive")
    local finalBounds = BoundingBox()
    local seenBuffers = {}

    -- 保留所有 LOD、UV、索引和切线；只校准模型自身，不改变轨道或客车尺寸。
    for g = 0, model.numGeometries - 1 do
        for lod = 0, model:GetNumGeometryLodLevels(g) - 1 do
            local geom = model:GetGeometry(g, lod)
            local vb = geom:GetVertexBuffer(0)
            if not seenBuffers[vb] then
                seenBuffers[vb] = true
                local sourceData = vb:GetData()
                local output = VectorBuffer()
                output:Write(sourceData)
                local vertexStride = vb.vertexSize
                local posOffset = vb:GetElementOffset(SEM_POSITION)
                local normalOffset = vb:GetElementOffset(SEM_NORMAL)
                local tangentOffset = vb:GetElementOffset(SEM_TANGENT)
                local sourceBitangents = getBitangents(geom)
                local repairedTangents = 0

                for i = 0, vb.vertexCount - 1 do
                    local base = i * vertexStride
                    sourceData:Seek(base + posOffset)
                    local position = rotation * sourceData:ReadVector3()
                    local lowWeight = Clamp((bounds.min.y + size.y * 0.40 - position.y)
                        / (size.y * 0.16), 0.0, 1.0)
                    local upperX = (position.x - center.x) * sx
                    local lowerX = (position.x - wheelCenter) * wheelScaleX
                    local fitted = Vector3(Lerp(upperX, lowerX, lowWeight),
                        (position.y - wheelBottom) * sy + RAIL_TOP,
                        (position.z - center.z) * sz)
                    finalBounds:Merge(fitted)
                    output:Seek(base + posOffset)
                    output:WriteVector3(fitted)

                    local localScaleX = Lerp(sx, wheelScaleX, lowWeight)
                    local shear = 0.0
                    if lowWeight > 0 and lowWeight < 1 then
                        shear = -(lowerX - upperX) / (size.y * 0.16)
                    end
                    sourceData:Seek(base + normalOffset)
                    local normal = rotation * sourceData:ReadVector3()
                    local fittedNormal = Vector3(normal.x / localScaleX,
                        (normal.y - shear * normal.x / localScaleX) / sy,
                        normal.z / sz):Normalized()
                    output:Seek(base + normalOffset)
                    output:WriteVector3(fittedNormal)

                    sourceData:Seek(base + tangentOffset)
                    local tangent = sourceData:ReadVector4()
                    local direction = rotation * Vector3(tangent.x, tangent.y, tangent.z)
                    local fittedDirection = Vector3(direction.x * localScaleX + direction.y * shear,
                        direction.y * sy, direction.z * sz)
                    local orthogonal = (fittedDirection - fittedNormal
                        * fittedNormal:DotProduct(fittedDirection)):Normalized()
                    local handedness = tangent.w < 0 and -1.0 or 1.0
                    if math.abs(tangent.w) < 0.000001 then
                        local sourceBitangent = sourceBitangents[i]
                        if sourceBitangent then
                            local bitangent = rotation * sourceBitangent
                            local fittedBitangent = Vector3(bitangent.x * localScaleX + bitangent.y * shear,
                                bitangent.y * sy, bitangent.z * sz)
                            handedness = fittedNormal:CrossProduct(orthogonal):DotProduct(fittedBitangent)
                                < 0 and -1.0 or 1.0
                        end
                    end
                    if math.abs(math.abs(tangent.w) - 1.0) > 0.001 then
                        repairedTangents = repairedTangents + 1
                    end
                    output:Seek(base + tangentOffset)
                    output:WriteVector4(Vector4(orthogonal.x, orthogonal.y, orthogonal.z, handedness))
                end
                assert(vb:SetData(output), "机车校准顶点上传失败")
                if repairedTangents > 0 then
                    print(string.format("[Locomotive] LOD %d 修正 %d 个异常切线手性值", lod, repairedTangents))
                end
            end
            geom.lodDistance = ({ 0.0, 45.0, 110.0, 220.0 })[lod + 1] or 220.0
            model:SetGeometryCenter(g, Vector3(0, HEIGHT * 0.5 + RAIL_TOP, 0))
        end
    end
    model.boundingBox = finalBounds
    print(string.format("[Locomotive] 原始正向尺寸 %.4f × %.4f × %.4f；踏面横距 %.4f",
        size.x, size.y, size.z, sourceGauge))
    print(string.format("[Locomotive] 米制尺寸 %.2f × %.2f × %.2f；轮距 %.3f；轨面 %.2f；LOD %d",
        finalBounds.size.x, finalBounds.size.y, finalBounds.size.z,
        GameConfig.RailGauge, RAIL_TOP, model:GetNumGeometryLodLevels(0)))
    return model
end

--- 仅显式离线烘焙调用；正常Prepare不应调用此全网格算法。
---@return Model
function Locomotive.CalibrateOffline()
    local source = assert(cache:GetResource("Model", MODEL_PATH), "离线蓝白源模型缺失")
    assert(source.numGeometries == 1, "蓝白源结构改变")
    return calibrateModel(source)
end

---@param id? string
---@return boolean, string
function Locomotive.Prepare(id)
    if id and id ~= "blue_white" then return RollingStock.Prepare(id) end
    if calibratedModel_ then return true, "原蓝白资产已校准" end
    local ok, message = pcall(function()
        local model = RollingStock.LoadBakedModel("blue_white")
        assert(model.numGeometries == 1, "原蓝白烘焙网格结构不一致")
        local material = Material:new()
        material:SetTechnique(0, assert(cache:GetResource("Technique", "Techniques/PBR/PBRDiffNormal.xml")))
        material:SetTexture(TU_DIFFUSE, assert(cache:GetResource("Texture2D", DIFFUSE_PATH)))
        material:SetTexture(TU_NORMAL, assert(cache:GetResource("Texture2D", NORMAL_PATH)))
        material:SetShaderParameter("Metallic", Variant(0.12))
        material:SetShaderParameter("Roughness", Variant(0.62))
        calibratedModel_, material_ = model, material
    end)
    if not ok then return false, tostring(message) end
    return true, "原蓝白资产已校准"
end

---@param parent Node
---@param id? string
---@return Node
function Locomotive.Build(parent, id)
    local ok, message = Locomotive.Prepare(id)
    assert(ok, message)
    if id and id ~= "blue_white" then
        local node, drawable = RollingStock.Build(parent, id)
        drawable_ = drawable
        drawable_.enabled = not cabView_
        return node
    end
    local node = parent:CreateChild("LocomotiveModel")
    drawable_ = node:CreateComponent("StaticModel")
    drawable_.model = assert(calibratedModel_)
    drawable_:SetMaterial(assert(material_))
    drawable_.castShadows = true
    drawable_.enabled = not cabView_
    print("[Locomotive] 原蓝白机车使用原专用校准，未套中国车型profile")
    return node
end

---@param head string
---@param middle? string
function Locomotive.ReleaseExcept(head, middle)
    RollingStock.ReleaseExcept(head, middle)
    if head ~= "blue_white" and calibratedModel_ then
        -- 旧drawable已移除并重新登记，释放模块强引用后让cache回收无用户资源。
        calibratedModel_, material_ = nil, nil
        local asset = assert(Catalog.Assets.blue_white)
        cache:ReleaseResource("Model", asset.modelPath)
        cache:ReleaseResource("Texture2D", DIFFUSE_PATH)
        cache:ReleaseResource("Texture2D", NORMAL_PATH)
    end
end

--- 为动车头车登记驾驶视角外壳，不触碰中间车和反向尾车。
---@param drawable StaticModel
function Locomotive.RegisterLead(drawable)
    drawable_ = drawable
    drawable.enabled = not cabView_
end

---@param id? string
---@return number
function Locomotive.GetLength(id)
    local profile = id and Catalog.Profiles[id]
    return profile and profile.length or Locomotive.Length
end

--- 司机视角不渲染自己的外壳，避免生成资产的不透明玻璃遮住前方线路。
---@param enabled boolean
function Locomotive.SetCabView(enabled)
    cabView_ = enabled
    if drawable_ then drawable_.enabled = not enabled end
end

return Locomotive
