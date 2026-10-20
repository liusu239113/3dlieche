-- 显式离线烘焙入口：只处理本轮确认的四款独立客车，保留旧资产。
local RollingStock = require "train.RollingStock"
local Catalog = require "config.TrainCatalog"
local GameConfig = require "config.GameConfig"
local IDS = {"blue_white_coach", "DF4D_coach", "SS9G_coach", "HXD3D_coach"}
local ROOT = "/workspace/assets/"

---@param v Vector3
---@return number[]
local function vector(v) return {v.x, v.y, v.z} end

---@param id string
local function bake(id)
    local profile = assert(Catalog.Profiles[id], "缺少客车profile：" .. id)
    local asset = assert(Catalog.Assets[id], "缺少客车资源登记：" .. id)
    local sourcePath = "model/" .. profile.modelId .. "/Meshes/" .. profile.modelId .. ".mdl"
    local sourceFile = assert(cache:GetFile(sourcePath), "源模型未就绪：" .. sourcePath)
    local sourceChecksum, sourceBytes = sourceFile.checksum, sourceFile.size
    sourceFile:Close()
    local result = RollingStock.CalibrateOffline(id)
    local model = result.model
    assert(model:Save(ROOT .. asset.modelPath), "客车MDL保存失败：" .. asset.modelPath)
    local loaded = Model()
    assert(loaded:Load(ROOT .. asset.modelPath), "客车MDL重新载入失败")
    assert(loaded.numGeometries == model.numGeometries, "保存后丢失几何")
    for g = 0, model.numGeometries - 1 do
        assert(loaded:GetNumGeometryLodLevels(g) == model:GetNumGeometryLodLevels(g), "保存后丢失LOD")
        for lod = 0, model:GetNumGeometryLodLevels(g) - 1 do
            local before, after = model:GetGeometry(g, lod), loaded:GetGeometry(g, lod)
            assert(before.indexCount == after.indexCount and before.vertexCount == after.vertexCount,
                "保存后顶点或索引数量变化")
            for stream = 0, before.numVertexBuffers - 1 do
                assert(before:GetVertexBuffer(stream):GetData().checksum == after:GetVertexBuffer(stream):GetData().checksum,
                    "保存后顶点数据变化")
            end
            assert(before:GetIndexBuffer():GetData().checksum == after:GetIndexBuffer():GetData().checksum,
                "保存后索引数据变化")
        end
    end
    assert((loaded.boundingBox.min - model.boundingBox.min):Length() < .00001
        and (loaded.boundingBox.max - model.boundingBox.max):Length() < .00001, "保存后包络变化")
    assert(math.abs(result.contactLeft.y - Catalog.RailTop) < .002
        and math.abs(result.contactRight.y - Catalog.RailTop) < .002, "踏面没有落在轨面")
    local metadata = {
        version = 1, id = id, modelId = profile.modelId, sourcePath = sourcePath,
        sourceChecksum = sourceChecksum, sourceBytes = sourceBytes,
        railGauge = GameConfig.RailGauge, railTop = Catalog.RailTop,
        width = profile.width, height = profile.height, length = profile.length,
        boundsMin = vector(loaded.boundingBox.min), boundsMax = vector(loaded.boundingBox.max),
        geometryCount = loaded.numGeometries, lodCount = loaded:GetNumGeometryLodLevels(0),
        yaw = result.yaw, vertices = result.vertices, repairedTangents = result.repairedTangents,
        sourceGauge = result.sourceGauge,
        contactLeft = vector(result.contactLeft), contactRight = vector(result.contactRight),
        diffusePath = asset.diffusePath, normalPath = asset.normalPath, roundTripVerified = true,
        calibrationInputs = {forwardSign = profile.forwardSign, underframeTop = profile.underframeTop,
            transitionTop = profile.transitionTop, roofSource = profile.roofSource, roofHeight = profile.roofHeight,
            contactLeft = profile.contactLeft, contactRight = profile.contactRight},
    }
    local file = File(ROOT .. asset.metadataPath, FILE_WRITE)
    assert(file:IsOpen(), "客车元数据无法写入")
    assert(file:WriteLine(cjson.encode(metadata)), "客车元数据写入失败")
    file:Close()
    print(string.format("[BakeCoach] %s 保存/载入/完整LOD/踏面通过 %.3fx%.3fx%.3fm，源踏面横距=%.5f",
        id, loaded.boundingBox.size.x, loaded.boundingBox.size.y, loaded.boundingBox.size.z, result.sourceGauge))
    loaded:Dispose()
    model:Dispose()
end

function Start()
    local ok, message = pcall(function()
        for _, id in ipairs(IDS) do
            bake(id)
            collectgarbage("collect")
        end
        print("[BakeCoach] ALL_4_INDEPENDENT_COACH_ROUNDTRIP_PASS")
    end)
    if not ok then log:Write(LOG_ERROR, "[BakeCoach] " .. tostring(message)) end
    engine:Exit()
end
