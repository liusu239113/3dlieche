-- Explicit offline-only entry. Never required by main.lua.
-- Model:Save(string)/Load(string) was first verified with a source-clone round trip.
local RollingStock = require "train.RollingStock"
local Locomotive = require "train.Locomotive"
local Catalog = require "config.TrainCatalog"
local GameConfig = require "config.GameConfig"
local OUTPUT_ROOT = "/workspace/assets/"
local IDS = {"DF4D", "SS9G", "HXD3D", "CRH380A_head", "CRH380A_middle", "CR400AF_head", "CR400AF_middle", "blue_white"}

---@param expected Model
---@param loaded Model
local function assertRoundTrip(expected, loaded)
    assert(loaded.numGeometries == expected.numGeometries, "geometry count changed")
    for g = 0, expected.numGeometries - 1 do
        assert(loaded:GetNumGeometryLodLevels(g) == expected:GetNumGeometryLodLevels(g), "LOD count changed")
        assert((loaded:GetGeometryCenter(g) - expected:GetGeometryCenter(g)):Length() < .00001, "geometry center changed")
        for lod = 0, expected:GetNumGeometryLodLevels(g) - 1 do
            local a, b = expected:GetGeometry(g, lod), loaded:GetGeometry(g, lod)
            assert(a.indexCount == b.indexCount and a.vertexCount == b.vertexCount, "draw range changed")
            assert(a.indexStart == b.indexStart and a.vertexStart == b.vertexStart, "draw start changed")
            assert(a.primitiveType == b.primitiveType and math.abs(a.lodDistance - b.lodDistance) < .001, "LOD draw settings changed")
            assert(a.numVertexBuffers == b.numVertexBuffers, "stream count changed")
            for stream = 0, a.numVertexBuffers - 1 do
                local av, bv = a:GetVertexBuffer(stream), b:GetVertexBuffer(stream)
                local ad, bd = av:GetData(), bv:GetData()
                assert(av.vertexCount == bv.vertexCount and av.vertexSize == bv.vertexSize, "VB layout changed")
                assert(ad.size > 0 and ad.size == bd.size and ad.checksum == bd.checksum, "VB bytes changed")
            end
            local ai, bi = a:GetIndexBuffer(), b:GetIndexBuffer()
            if ai then
                assert(bi, "IB missing")
                local ad, bd = ai:GetData(), bi:GetData()
                assert(ai.indexSize == bi.indexSize and ad.size == bd.size and ad.checksum == bd.checksum, "IB bytes changed")
            end
        end
    end
    assert((loaded.boundingBox.min - expected.boundingBox.min):Length() < .00001, "min bounds changed")
    assert((loaded.boundingBox.max - expected.boundingBox.max):Length() < .00001, "max bounds changed")
end

---@param v Vector3
---@return number[]
local function vector(v) return {v.x, v.y, v.z} end

---@param id string
local function bake(id)
    local started = os.clock()
    local asset = assert(Catalog.Assets[id])
    local profile = Catalog.Profiles[id]
    local sourcePath = profile and ("model/" .. profile.modelId .. "/Meshes/" .. profile.modelId .. ".mdl")
        or "model/228b03702ab649048d477f0df9bf5feb/Meshes/228b03702ab649048d477f0df9bf5feb.mdl"
    local source = assert(cache:GetResource("Model", sourcePath))
    local sourceFile = assert(cache:GetFile(sourcePath))
    local sourceChecksum, sourceBytes = sourceFile.checksum, sourceFile.size
    sourceFile:Close()
    ---@type RollingStockCalibration|nil
    local calibration = nil
    ---@type Model
    local model
    if id == "blue_white" then model = Locomotive.CalibrateOffline()
    else
        calibration = RollingStock.CalibrateOffline(id)
        model = calibration.model
    end
    assert(source.numGeometries == model.numGeometries, "source geometry discarded")
    for g = 0, source.numGeometries - 1 do
        assert(source:GetNumGeometryLodLevels(g) == model:GetNumGeometryLodLevels(g), "source LOD discarded")
    end
    assert(model:Save(OUTPUT_ROOT .. asset.modelPath), "Model:Save(string) failed")
    local loaded = Model()
    assert(loaded:Load(OUTPUT_ROOT .. asset.modelPath), "Model:Load(string) failed")
    assertRoundTrip(model, loaded)
    local size = loaded.boundingBox.size
    if profile then
        assert(math.abs(size.x - profile.width) < .015, "baked width outside tolerance")
        if profile.roofSource then
            -- 升弓车height是轨面到弓顶；轮缘/排障器按设计允许低于踏面。
            assert(math.abs(loaded.boundingBox.max.y - Catalog.RailTop - profile.height) < .015, "baked roof outside tolerance")
        else
            assert(math.abs(size.y - profile.height) < .015, "baked height outside tolerance")
        end
        assert(math.abs(size.z - profile.length) < .015, "baked length outside tolerance")
        assert(calibration and math.abs(calibration.contactLeft.y - Catalog.RailTop) < .002
            and math.abs(calibration.contactRight.y - Catalog.RailTop) < .002, "baked tread height invalid")
    end
    local metadata = {
        version = 1, id = id, sourcePath = sourcePath, sourceChecksum = sourceChecksum, sourceBytes = sourceBytes,
        railGauge = GameConfig.RailGauge, railTop = Catalog.RailTop,
        boundsMin = vector(loaded.boundingBox.min), boundsMax = vector(loaded.boundingBox.max),
        geometryCount = loaded.numGeometries, lodCount = loaded:GetNumGeometryLodLevels(0),
        width = profile and profile.width or 3.1, height = profile and profile.height or 4.1,
        length = profile and profile.length or 21.0, modelId = profile and profile.modelId or "228b03702ab649048d477f0df9bf5feb",
        yaw = calibration and calibration.yaw or -44.84771127,
        vertices = calibration and calibration.vertices or loaded:GetGeometry(0, 0):GetVertexBuffer(0).vertexCount,
        repairedTangents = calibration and calibration.repairedTangents or 0,
        sourceGauge = calibration and calibration.sourceGauge or 0,
        contactLeft = calibration and vector(calibration.contactLeft) or {-GameConfig.RailGauge * .5, Catalog.RailTop, 0},
        contactRight = calibration and vector(calibration.contactRight) or {GameConfig.RailGauge * .5, Catalog.RailTop, 0},
        calibrationInputs = profile,
        diffusePath = asset.diffusePath, normalPath = asset.normalPath,
        seconds = os.clock() - started, roundTripVerified = true,
    }
    -- profile.cab is a Vector3 userdata/value, not JSON. Store only explicit scalar geometry inputs.
    if profile then
        metadata.calibrationInputs = {forwardSign = profile.forwardSign, underframeTop = profile.underframeTop,
            transitionTop = profile.transitionTop, roofSource = profile.roofSource, roofHeight = profile.roofHeight,
            contactLeft = profile.contactLeft, contactRight = profile.contactRight}
    end
    local file = File(OUTPUT_ROOT .. asset.metadataPath, FILE_WRITE)
    assert(file:IsOpen(), "metadata output unavailable")
    assert(file:WriteLine(cjson.encode(metadata)), "metadata output failed")
    file:Close()
    print(string.format("[Bake] ROUNDTRIP_PASS %s %.3fx%.3fx%.3fm %d LOD %.3fs", id,
        size.x, size.y, size.z, loaded:GetNumGeometryLodLevels(0), os.clock() - started))
    loaded:Dispose()
    -- Only this offline worker owns these clones. Release each before preparing the next model.
    model:Dispose()
    cache:ReleaseResource("Model", sourcePath)
end

function Start()
    local started = os.clock()
    local ok, message = pcall(function()
        for _, id in ipairs(IDS) do
            bake(id)
            collectgarbage("collect")
        end
        print(string.format("[Bake] ALL_8_ROUNDTRIP_PASS %.3fs", os.clock() - started))
    end)
    if not ok then log:Write(LOG_ERROR, "[Bake] " .. tostring(message)) end
    engine:Exit()
end
