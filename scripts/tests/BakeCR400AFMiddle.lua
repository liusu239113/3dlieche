-- 显式离线烘焙入口：只处理本次确认的复兴号中间车，保留旧资产。
local RollingStock = require "train.RollingStock"
local Catalog = require "config.TrainCatalog"
local GameConfig = require "config.GameConfig"
local ID = "CR400AF_middle_v2"
local ROOT = "/workspace/assets/"

---@param v Vector3
---@return number[]
local function vector(v) return {v.x, v.y, v.z} end

function Start()
    local ok, message = pcall(function()
        local profile = assert(Catalog.Profiles[ID])
        local asset = assert(Catalog.Assets[ID])
        local sourcePath = "model/" .. profile.modelId .. "/Meshes/" .. profile.modelId .. ".mdl"
        local sourceFile = assert(cache:GetFile(sourcePath))
        local sourceChecksum, sourceBytes = sourceFile.checksum, sourceFile.size
        sourceFile:Close()
        local result = RollingStock.CalibrateOffline(ID)
        local model = result.model
        assert(model:Save(ROOT .. asset.modelPath), "中间车MDL保存失败")
        local loaded = Model()
        assert(loaded:Load(ROOT .. asset.modelPath), "中间车MDL重新载入失败")
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
        assert((loaded.boundingBox.min-model.boundingBox.min):Length() < .00001
            and (loaded.boundingBox.max-model.boundingBox.max):Length() < .00001, "保存后包络变化")
        assert(math.abs(result.contactLeft.y-Catalog.RailTop) < .002
            and math.abs(result.contactRight.y-Catalog.RailTop) < .002, "踏面没有落在轨面")
        local metadata = {
            version=1,id=ID,modelId=profile.modelId,sourcePath=sourcePath,sourceChecksum=sourceChecksum,sourceBytes=sourceBytes,
            railGauge=GameConfig.RailGauge,railTop=Catalog.RailTop,width=profile.width,height=profile.height,length=profile.length,
            boundsMin=vector(loaded.boundingBox.min),boundsMax=vector(loaded.boundingBox.max),
            geometryCount=loaded.numGeometries,lodCount=loaded:GetNumGeometryLodLevels(0),
            yaw=result.yaw,vertices=result.vertices,repairedTangents=result.repairedTangents,sourceGauge=result.sourceGauge,
            contactLeft=vector(result.contactLeft),contactRight=vector(result.contactRight),
            diffusePath=asset.diffusePath,normalPath=asset.normalPath,roundTripVerified=true,
            calibrationInputs={forwardSign=profile.forwardSign,underframeTop=profile.underframeTop,
                transitionTop=profile.transitionTop,roofSource=profile.roofSource,roofHeight=profile.roofHeight,
                contactLeft=profile.contactLeft,contactRight=profile.contactRight},
        }
        local file = File(ROOT .. asset.metadataPath, FILE_WRITE)
        assert(file:IsOpen(), "中间车元数据无法写入")
        assert(file:WriteLine(cjson.encode(metadata)), "中间车元数据写入失败")
        file:Close()
        print("[BakeCR400AFMiddle] 保存/载入、完整LOD、踏面全部通过：" .. asset.modelPath)
        loaded:Dispose()
        model:Dispose()
    end)
    if not ok then log:Write(LOG_ERROR, "[BakeCR400AFMiddle] " .. tostring(message)) end
    engine:Exit()
end
