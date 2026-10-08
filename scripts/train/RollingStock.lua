-- ============================================================================
-- RollingStock - 正常运行按需加载独立MDL缓存，不处理源网格。
-- PCA/轮轨/Jacobian/切线算法仅由显式CalibrateOffline离线入口使用。
-- ============================================================================
local GameConfig = require "config.GameConfig"
local Catalog = require "config.TrainCatalog"
local RollingStock = {}

---@class RollingStockCalibration
---@field profile RollingStockProfile
---@field model Model
---@field materials Material[]
---@field sourceBounds BoundingBox
---@field bounds BoundingBox
---@field yaw number
---@field contactLeft Vector3
---@field contactRight Vector3
---@field sourceGauge number
---@field vertices integer
---@field repairedTangents integer
---@field diffusePath string
---@field normalPath string

---@class RollingStockMetadata
---@field version integer
---@field id string
---@field modelId string
---@field railGauge number
---@field railTop number
---@field width number
---@field height number
---@field length number
---@field geometryCount integer
---@field lodCount integer
---@field yaw number
---@field vertices integer
---@field repairedTangents integer
---@field sourceGauge number
---@field boundsMin number[]
---@field boundsMax number[]
---@field contactLeft number[]
---@field contactRight number[]
---@field calibrationInputs {forwardSign:number,underframeTop:number,transitionTop:number,roofSource:number?,roofHeight:number?,contactLeft:RollingStockContactBox,contactRight:RollingStockContactBox}?
---@field roundTripVerified boolean

local calibrated_ = {} ---@type table<string, RollingStockCalibration>
---@type table<string, string>
local errors_ = {}
---@type table<string, boolean>
local downloading_ = {}

---@param values number[]
---@param fraction number
---@return number
local function quantile(values, fraction)
    assert(#values > 0, "踏面采样为空，不能把排障器最低点当作轨面")
    table.sort(values)
    return assert(values[math.max(1, math.min(#values, math.floor((#values - 1) * fraction) + 1))])
end

---@param geometry Geometry
---@return integer[]
local function readIndices(geometry)
    local indices = geometry:GetIndexBuffer()
    local result = {}
    if not indices or geometry.indexCount == 0 then
        for i = geometry.vertexStart, geometry.vertexStart + geometry.vertexCount - 1 do
            result[#result + 1] = i
        end
        return result
    end
    local data = indices:GetData()
    data:Seek(geometry.indexStart * indices.indexSize)
    for _ = 1, geometry.indexCount do
        result[#result + 1] = indices.indexSize == 2 and data:ReadUShort() or data:ReadUInt()
    end
    return result
end

---@param source Model
---@return Vector3[], Vector3[]
local function readLodZero(source)
    ---@type Vector3[]
    local positions = {}
    ---@type Vector3[]
    local normals = {}
    ---@type table<VertexBuffer, table<number, boolean>>
    local seen = {}
    for g = 0, source.numGeometries - 1 do
        local geom = source:GetGeometry(g, 0)
        for b = 0, geom.numVertexBuffers - 1 do
            local vb = geom:GetVertexBuffer(b)
            if vb:HasElement(SEM_POSITION) then
                local used = seen[vb] or {}
                seen[vb] = used
                local data = vb:GetData()
                local po = vb:GetElementOffset(SEM_POSITION)
                local no = vb:HasElement(SEM_NORMAL) and vb:GetElementOffset(SEM_NORMAL) or -1
                for _, index in ipairs(readIndices(geom)) do
                    assert(index >= 0 and index < vb.vertexCount, "MDL索引越界")
                    if not used[index] then
                        used[index] = true
                        data:Seek(index * vb.vertexSize + po)
                        positions[#positions + 1] = data:ReadVector3()
                        if no >= 0 then
                            data:Seek(index * vb.vertexSize + no)
                            normals[#normals + 1] = data:ReadVector3()
                        else
                            normals[#normals + 1] = Vector3.DOWN
                        end
                    end
                end
            end
        end
    end
    assert(#positions >= 16, "LOD0有效顶点不足")
    return positions, normals
end

--- XZ协方差最大特征向量，先固定源Z非负；鼻端符号只来自资产实测profile。
---@param positions Vector3[]
---@return number
local function principalYaw(positions)
    local mx, mz = 0.0, 0.0
    for _, p in ipairs(positions) do mx, mz = mx + p.x, mz + p.z end
    mx, mz = mx / #positions, mz / #positions
    local xx, xz, zz = 0.0, 0.0, 0.0
    for _, p in ipairs(positions) do
        local x, z = p.x - mx, p.z - mz
        xx, xz, zz = xx + x * x, xz + x * z, zz + z * z
    end
    local lambda = (xx + zz + math.sqrt((xx - zz)^2 + 4 * xz * xz)) * .5
    assert(lambda > .000001, "PCA主轴退化")
    local x, z = xz, lambda - xx
    if math.abs(x) + math.abs(z) < .00000001 then x, z = 1, 0 end
    if z < 0 then x, z = -x, -z end
    return -math.deg(math.atan(x, z))
end

--- 明确的资产轮区ROI + 朝下法线，排除车钩/排障器；不使用全模型minY。
---@param positions Vector3[]
---@param normals Vector3[]
---@param box RollingStockContactBox
---@return Vector3
local function measureContact(positions, normals, box)
    local ys = {}
    ---@type Vector3[]
    local samples = {}
    for i, p in ipairs(positions) do
        if p.x >= box.x0 and p.x <= box.x1 and p.y >= box.y0 and p.y <= box.y1
            and p.z >= box.z0 and p.z <= box.z1 and normals[i].y < -.55 then
            samples[#samples + 1] = p
            ys[#ys + 1] = p.y
        end
    end
    assert(#samples >= 8, "实测踏面ROI无足够朝下顶点")
    local bottom = quantile(ys, .05)
    local xs, zs = {}, {}
    for _, p in ipairs(samples) do
        if p.y <= bottom + .003 then xs[#xs + 1], zs[#zs + 1] = p.x, p.z end
    end
    return Vector3(quantile(xs, .5), bottom, quantile(zs, .5))
end

--- 汇总同一VB所有LOD/geometry的UV导数，不能只用第一个geometry修复共享切线。
---@param model Model
---@return table<VertexBuffer, {t:table<number,Vector3>,b:table<number,Vector3>}>
local function uvDirections(model)
    local result = {}
    for g = 0, model.numGeometries - 1 do
        for lod = 0, model:GetNumGeometryLodLevels(g) - 1 do
            local geom = model:GetGeometry(g, lod)
            if geom.primitiveType == TRIANGLE_LIST then
                for stream = 0, geom.numVertexBuffers - 1 do
                    local vb = geom:GetVertexBuffer(stream)
                    if vb:HasElement(SEM_POSITION) and vb:HasElement(SEM_TEXCOORD) then
                        local sums = result[vb] or { t = {}, b = {} }
                        result[vb] = sums
                        local data, stride = vb:GetData(), vb.vertexSize
                        local po, uo = vb:GetElementOffset(SEM_POSITION), vb:GetElementOffset(SEM_TEXCOORD)
                        local function vertex(index)
                            data:Seek(index * stride + po)
                            local p = data:ReadVector3()
                            data:Seek(index * stride + uo)
                            return p, data:ReadVector2()
                        end
                        local indices = readIndices(geom)
                        for i = 1, #indices - 2, 3 do
                            local ia, ib, ic = indices[i], indices[i + 1], indices[i + 2]
                            local p0, u0 = vertex(ia)
                            local p1, u1 = vertex(ib)
                            local p2, u2 = vertex(ic)
                            local d1, d2 = u1 - u0, u2 - u0
                            local det = d1.x * d2.y - d1.y * d2.x
                            if math.abs(det) > 1e-10 then
                                local tangent = ((p1 - p0) * d2.y - (p2 - p0) * d1.y) / det
                                local bitangent = ((p2 - p0) * d1.x - (p1 - p0) * d2.x) / det
                                for _, index in ipairs({ia, ib, ic}) do
                                    sums.t[index] = (sums.t[index] or Vector3.ZERO) + tangent
                                    sums.b[index] = (sums.b[index] or Vector3.ZERO) + bitangent
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return result
end

---@param profile RollingStockProfile
---@return RollingStockCalibration
local function calibrate(profile)
    assert(profile.verified, "车型方向/踏面尚未实测")
    local path = "model/" .. profile.modelId .. "/Meshes/" .. profile.modelId .. ".mdl"
    assert(cache:Exists(path), "模型尚未准备好：" .. path)
    local source = assert(cache:GetResource("Model", path), "MDL加载失败")
    local positions, normals = readLodZero(source)
    local yaw = principalYaw(positions)
    local rotation = Quaternion(yaw, Vector3.UP)
    local bounds = BoundingBox()
    for i, p in ipairs(positions) do
        local point = rotation * p
        positions[i] = point
        normals[i] = rotation * assert(normals[i])
        bounds:Merge(point)
    end
    local left = measureContact(positions, normals, profile.contactLeft)
    local right = measureContact(positions, normals, profile.contactRight)
    local gauge = right.x - left.x
    assert(gauge > .005, "实测左右踏面顺序或轮距无效")
    local wheelCenter = (left.x + right.x) * .5
    local wheelY = (left.y + right.y) * .5
    local wheelSlope = (right.y - left.y) / gauge
    local size, center = bounds.size, bounds.center
    assert(size.x > .001 and size.y > .001 and size.z > .001, "模型包络无效")
    assert(profile.transitionTop > profile.underframeTop, "轮区到车体过渡区无效")
    local wheelScale = GameConfig.RailGauge / gauge
    local sz = profile.length / size.z
    local sign = profile.forwardSign
    local sy = profile.height / size.y
    if profile.roofSource and profile.roofHeight then
        sy = profile.roofHeight / (profile.roofSource - wheelY)
    end
    local yNormalize = 1.0

    --      车顶/受电弓            上部按实际车宽；升弓区独立映射到接触线
    --     ┌────────┐
    --     └────────┘  transitionTop
    --       O    O    underframeTop以下只按本资产实测踏面中心拟合标准轨距
    --       =    =    左右踏面均落在RailTop；排障器/轮缘允许低于轨头
    -- 仅视觉校准，无物理碰撞；低位到车宽使用连续映射，法线/切线用同一Jacobian。
    ---@param p Vector3
    ---@param bodyScale number
    ---@return Vector3, number, number, number, number
    local function fit(p, bodyScale)
        local interval = profile.transitionTop - profile.underframeTop
        local weight = Clamp((profile.transitionTop - p.y) / interval, 0, 1)
        local derivative = weight > 0 and weight < 1 and -1 / interval or 0
        local upper = (p.x - center.x) * bodyScale
        local lower = (p.x - wheelCenter) * wheelScale
        local ax = (1 - weight) * bodyScale + weight * wheelScale
        local bx = derivative * (lower - upper)
        local adjusted = p.y - wheelY - weight * wheelSlope * (p.x - wheelCenter)
        local slope = sy
        local fy = adjusted * sy
        if profile.roofSource and profile.roofHeight and p.y > profile.roofSource then
            slope = (Catalog.RailTop + profile.height - (Catalog.RailTop + profile.roofHeight))
                / (bounds.max.y - profile.roofSource)
            fy = profile.roofHeight + (p.y - profile.roofSource) * slope
        end
        local cy = -weight * wheelSlope * slope * yNormalize
        local dy = (1 - derivative * wheelSlope * (p.x - wheelCenter)) * slope * yNormalize
        return Vector3(sign * Lerp(upper, lower, weight),
            Catalog.RailTop + fy * yNormalize, sign * (p.z - center.z) * sz), ax, bx, cy, dy
    end

    -- 轮区映射不能再用全体Scale改轮距；仅搜索车体sx使最终真实顶点横向包络精确。
    local loScale, hiScale = 0.0, profile.width / size.x * 3
    for _ = 1, 24 do
        local candidate = (loScale + hiScale) * .5
        local probe = BoundingBox()
        for _, p in ipairs(positions) do
            local weight = Clamp((profile.transitionTop - p.y)
                / (profile.transitionTop - profile.underframeTop), 0, 1)
            local x = Lerp((p.x - center.x) * candidate, (p.x - wheelCenter) * wheelScale, weight)
            probe:Merge(Vector3(x, 0, 0))
        end
        if probe.size.x > profile.width then hiScale = candidate else loScale = candidate end
    end
    local sx = (loScale + hiScale) * .5
    local probe = BoundingBox()
    for _, p in ipairs(positions) do
        local fitted = fit(p, sx)
        probe:Merge(fitted)
    end
    if not profile.roofSource then yNormalize = profile.height / probe.size.y end
    local model = source:Clone("RollingStock_" .. profile.id)
    local directions = uvDirections(model)
    local finalBounds = BoundingBox()
    local seen, repaired = {}, 0
    for g = 0, model.numGeometries - 1 do
        for lod = 0, model:GetNumGeometryLodLevels(g) - 1 do
            local geom = model:GetGeometry(g, lod)
            for stream = 0, geom.numVertexBuffers - 1 do
                local vb = geom:GetVertexBuffer(stream)
                if vb:HasElement(SEM_POSITION) and not seen[vb] then
                    seen[vb] = true
                    local input, output = vb:GetData(), VectorBuffer()
                    output:Write(input)
                    local po = vb:GetElementOffset(SEM_POSITION)
                    local no = vb:HasElement(SEM_NORMAL) and vb:GetElementOffset(SEM_NORMAL) or -1
                    local to = vb:HasElement(SEM_TANGENT) and vb:GetElementOffset(SEM_TANGENT) or -1
                    local sums = directions[vb]
                    for i = 0, vb.vertexCount - 1 do
                        local base = i * vb.vertexSize
                        input:Seek(base + po)
                        local p = rotation * input:ReadVector3()
                        local fitted, ax, bx, cy, dy = fit(p, sx)
                        local det = ax * dy - bx * cy
                        assert(math.abs(det) > 1e-7, "轮轨拟合Jacobian退化")
                        output:Seek(base + po)
                        output:WriteVector3(fitted)
                        if lod == 0 then finalBounds:Merge(fitted) end
                        local normal = Vector3.UP
                        if no >= 0 then
                            input:Seek(base + no)
                            local n = rotation * input:ReadVector3()
                            normal = Vector3(sign * (dy * n.x - cy * n.y) / det,
                                (-bx * n.x + ax * n.y) / det, sign * n.z / sz):Normalized()
                            output:Seek(base + no)
                            output:WriteVector3(normal)
                        end
                        if to >= 0 then
                            input:Seek(base + to)
                            local tangent = input:ReadVector4()
                            local direction = rotation * Vector3(tangent.x, tangent.y, tangent.z)
                            if direction:LengthSquared() < 1e-10 and sums and sums.t[i] then
                                direction = rotation * sums.t[i]
                            end
                            local td = Vector3(sign * (ax * direction.x + bx * direction.y),
                                cy * direction.x + dy * direction.y, sign * direction.z * sz)
                            local tangentNormal = td - normal * normal:DotProduct(td)
                            if tangentNormal:LengthSquared() < 1e-10 then
                                local reference = math.abs(normal.y) < .9 and Vector3.UP or Vector3.RIGHT
                                tangentNormal = normal:CrossProduct(reference)
                            end
                            local orthogonal = tangentNormal:Normalized()
                            local hand = tangent.w < 0 and -1.0 or 1.0
                            if math.abs(tangent.w) < .000001 and sums and sums.b[i] then
                                local b = rotation * sums.b[i]
                                local bd = Vector3(sign * (ax * b.x + bx * b.y),
                                    cy * b.x + dy * b.y, sign * b.z * sz)
                                hand = normal:CrossProduct(orthogonal):DotProduct(bd) < 0 and -1.0 or 1.0
                            end
                            if math.abs(math.abs(tangent.w) - 1) > .001 then repaired = repaired + 1 end
                            output:Seek(base + to)
                            output:WriteVector4(Vector4(orthogonal.x, orthogonal.y, orthogonal.z, hand))
                        end
                    end
                    assert(vb:SetData(output), "校准顶点上传失败")
                end
            end
            -- LOD保留全部；原LOD距离以源归一化尺寸生成，修正为米制距离。
            geom.lodDistance = ({0.0, 50.0, 125.0, 260.0})[lod + 1] or (260.0 + lod * 60)
        end
        model:SetGeometryCenter(g, Vector3(0, profile.height * .5 + Catalog.RailTop, 0))
    end
    model.boundingBox = finalBounds
    -- 离线校准仅处理模型，不创建材质、不解码或上传纹理。
    local materials = {}
    local diffusePath, normalPath = "", ""
    local contactLeft = fit(left, sx)
    local contactRight = fit(right, sx)
    print(string.format("[RollingStock] %s PCA yaw=%.6f° noseSign=%+.0f，LOD0=%d，源包络=%.5fx%.5fx%.5f",
        profile.id, yaw, sign, #positions, size.x, size.y, size.z))
    print(string.format("[RollingStock] %s 米制包络=%.3fx%.3fx%.3f，Z中心=%.5f；源踏面横距=%.5f -> %.3f，踏面Y=%.4f/%.4f；几何=%d LOD=%d 手性修正=%d",
        profile.id, finalBounds.size.x, finalBounds.size.y, finalBounds.size.z, finalBounds.center.z,
        gauge, GameConfig.RailGauge, contactLeft.y, contactRight.y,
        model.numGeometries, model:GetNumGeometryLodLevels(0), repaired))
    return {profile=profile, model=model, materials=materials, sourceBounds=bounds, bounds=finalBounds,
        yaw=yaw, contactLeft=contactLeft, contactRight=contactRight, sourceGauge=gauge,
        vertices=#positions, repairedTangents=repaired, diffusePath=diffusePath, normalPath=normalPath}
end

--- 离线专用：不加载Texture2D，不进入正常车辆缓存；由tests/BakeRollingStock显式调用。
---@param id string
---@return RollingStockCalibration
function RollingStock.CalibrateOffline(id)
    return calibrate(assert(Catalog.Profiles[id], "未知离线profile"))
end

---@param values number[]
---@return Vector3
local function fromVector(values)
    assert(#values == 3, "烘焙向量格式无效")
    return Vector3(values[1], values[2], values[3])
end

--- 只读小JSON，不载入模型/贴图；元数据与MDL是blocking资源。
---@param id string
---@return RollingStockMetadata
function RollingStock.ReadMetadata(id)
    local asset = assert(Catalog.Assets[id], "未知烘焙车型")
    local file = assert(cache:GetFile(asset.metadataPath), "缺少离线校准元数据：" .. asset.metadataPath)
    local text = file:ReadLine()
    file:Close()
    local metadata = cjson.decode(text) --[[@as RollingStockMetadata]]
    assert(metadata.version == 1 and metadata.id == id and metadata.roundTripVerified, "烘焙版本/验收标记无效")
    assert(math.abs(metadata.railGauge - GameConfig.RailGauge) < .00001
        and math.abs(metadata.railTop - Catalog.RailTop) < .00001, "轨距/轨面改变，请离线重新烘焙")
    local profile = Catalog.Profiles[id]
    if profile then
        local inputs = metadata.calibrationInputs
        assert(inputs and inputs.forwardSign == profile.forwardSign and inputs.underframeTop == profile.underframeTop
            and inputs.transitionTop == profile.transitionTop and inputs.roofSource == profile.roofSource
            and inputs.roofHeight == profile.roofHeight, "校准输入改变，请离线重新烘焙")
        for _, side in ipairs({"contactLeft", "contactRight"}) do
            for _, axis in ipairs({"x0", "x1", "y0", "y1", "z0", "z1"}) do
                assert(inputs[side][axis] == profile[side][axis], "踏面ROI改变，请重新烘焙")
            end
        end
        assert(metadata.modelId == profile.modelId and math.abs(metadata.length - profile.length) < .00001
            and math.abs(metadata.width - profile.width) < .00001 and math.abs(metadata.height - profile.height) < .00001,
            "车型尺寸或源模型已变更，请重新烘焙")
    end
    return metadata
end

---@param id string
---@return boolean
function RollingStock.IsAvailable(id)
    if not Catalog.Assets[id] then return false end
    -- 不要求D/N已下载；菜单就绪表示已交付，可以点击按需加载。
    local asset = Catalog.Assets[id]
    if not cache:Exists(asset.metadataPath) then
        -- 清单里已交付但未下载：可点击Select发起下载，不把它当作“未提供”。
        return cache:GetResInfo(asset.metadataPath) ~= nil and cache:GetResInfo(asset.modelPath) ~= nil
    end
    local ok = pcall(RollingStock.ReadMetadata, id)
    return ok and (cache:Exists(asset.modelPath) or cache:GetResInfo(asset.modelPath) ~= nil)
end

--- 非默认车型若尚未下载blocking成品，发起一次下载并返回可重试状态。
---@param id string
---@return boolean, string
function RollingStock.EnsureBakedAvailable(id)
    local asset = Catalog.Assets[id]
    if not asset then return false, "未知烘焙车型" end
    if cache:Exists(asset.modelPath) and cache:Exists(asset.metadataPath) then return true, "成品可加载" end
    if downloading_[id] then return false, "车型成品正在下载，请稍后重试" end
    if not cache:GetResInfo(asset.modelPath) or not cache:GetResInfo(asset.metadataPath) then
        return false, "车型成品未包含在发布包，请重新构建"
    end
    downloading_[id] = true
    cache:DownloadResources({asset.modelPath, asset.metadataPath}, function(success, failedCount)
        downloading_[id] = nil
        errors_[id] = success and nil or ("下载失败：" .. tostring(failedCount) .. "项")
        print("[RollingStock] " .. id .. (success and "成品下载完成，可重试选择" or "成品下载失败，可重试"))
    end)
    return false, "车型成品正在下载，请稍后重试"
end

---@param id string
---@return Model, RollingStockMetadata
function RollingStock.LoadBakedModel(id)
    local metadata = RollingStock.ReadMetadata(id)
    local asset = assert(Catalog.Assets[id])
    assert(cache:Exists(asset.modelPath), "缺少已烘焙MDL：" .. asset.modelPath .. "，禁止运行时重新校准")
    local model = assert(cache:GetResource("Model", asset.modelPath), "烘焙MDL载入失败")
    assert(model.numGeometries == metadata.geometryCount and model.numGeometries > 0, "烘焙模型未完整加载")
    assert(model:GetNumGeometryLodLevels(0) == metadata.lodCount, "烘焙LOD不完整")
    assert((model.boundingBox.min - fromVector(metadata.boundsMin)):Length() < .002
        and (model.boundingBox.max - fromVector(metadata.boundsMax)):Length() < .002, "烘焙包络与元数据不符")
    return model, metadata
end

--- 正常路径只读成品；绝不Clone、GetData或执行顶点校准。
---@param id string
---@return boolean, string
function RollingStock.Prepare(id)
    if calibrated_[id] then return true, "离线资源已加载" end
    local profile = Catalog.Profiles[id]
    if not profile then return false, "未知车辆profile：" .. tostring(id) end
    local ok, result = pcall(function()
        local model, metadata = RollingStock.LoadBakedModel(id)
        local asset = assert(Catalog.Assets[id])
        assert(model.numGeometries == 1, "当前已交付涂装应为单geometry；多材质须显式列出")
        local mat = Material:new()
        mat:SetTechnique(0, assert(cache:GetResource("Technique", "Techniques/PBR/PBRDiffNormal.xml")))
        -- Texture2D会自动DWP，不能先用Exists拒绝尚未下载的媒体。
        local diffuse = assert(cache:GetResource("Texture2D", asset.diffusePath), "涂装资源无法加载")
        local normal = assert(cache:GetResource("Texture2D", asset.normalPath), "法线资源无法加载")
        diffuse:SetSRGB(true)
        normal:SetSRGB(false)
        mat:SetTexture(TU_DIFFUSE, diffuse)
        mat:SetTexture(TU_NORMAL, normal)
        mat:SetShaderParameter("MatDiffColor", Variant(Color(1, 1, 1, 1)))
        mat:SetShaderParameter("Metallic", Variant(.12))
        mat:SetShaderParameter("Roughness", Variant(.58))
        return {profile=profile, model=model, materials={mat}, sourceBounds=model.boundingBox, bounds=model.boundingBox,
            yaw=metadata.yaw, contactLeft=fromVector(metadata.contactLeft), contactRight=fromVector(metadata.contactRight),
            sourceGauge=metadata.sourceGauge, vertices=metadata.vertices, repairedTangents=metadata.repairedTangents,
            diffusePath=asset.diffusePath, normalPath=asset.normalPath} --[[@as RollingStockCalibration]]
    end)
    if not ok then
        errors_[id] = tostring(result)
        print("[RollingStock] " .. id .. "未就绪：" .. tostring(result))
        return false, errors_[id]
    end
    calibrated_[id] = result
    errors_[id] = nil
    print("[RollingStock] 按需加载离线MDL " .. id .. "，无运行时顶点处理")
    return true, "离线资源已加载"
end

--- 调用者先移除旧车辆；仅释放不再使用车型的引用，保留所选头/中间车共享资源。
---@param head string
---@param middle? string
function RollingStock.ReleaseExcept(head, middle)
    for id in pairs(calibrated_) do
        if id ~= head and id ~= middle then
            calibrated_[id] = nil
            local asset = assert(Catalog.Assets[id])
            cache:ReleaseResource("Model", asset.modelPath)
            cache:ReleaseResource("Texture2D", asset.diffusePath)
            cache:ReleaseResource("Texture2D", asset.normalPath)
        end
    end
end

---@param id string
---@return boolean
function RollingStock.IsReady(id)
    return calibrated_[id] ~= nil
end

---@param parent Node
---@param id string
---@param reverse? boolean
---@return Node, StaticModel
function RollingStock.Build(parent, id, reverse)
    local ok, message = RollingStock.Prepare(id)
    assert(ok, message)
    local data = assert(calibrated_[id])
    local node = parent:CreateChild("RollingStock_" .. id)
    if reverse then node.rotation = Quaternion(180, Vector3.UP) end
    local drawable = node:CreateComponent("StaticModel")
    drawable.model = data.model
    for g = 0, data.model.numGeometries - 1 do drawable:SetMaterial(g, data.materials[g + 1]) end
    drawable.castShadows, drawable.viewMask = true, 1
    return node, drawable
end

---@param id string
---@return RollingStockCalibration|nil
function RollingStock.GetCalibration(id) return calibrated_[id] end

return RollingStock
