-- 官方写实植被：完整树皮/叶片材质保留，64米空间分块实例化。
-- 不制造球冠、不改变物理；加载失败留空并报警，不以实体绿块冒充植物。
local Route = require "world.Route"
local Vegetation = {}

---@class RailwayPlantAsset
---@field name string
---@field model Model
---@field materials Material[]
---@field bounds BoundingBox
---@field drawDistance number
---@field shadowDistance number
---@field shadows boolean
---@class RailwayPlantBatch
---@field root Node
---@field groups table<string, StaticModelGroup>
---@field instances integer
local PlantBatch = {}
PlantBatch.__index = PlantBatch

---@type table<string, RailwayPlantAsset>
local assets_ = {}
---@type table<string, boolean>
local attempted_ = {}

-- 源自官方prefab的材质槽顺序（0=树皮，1=叶片）。
-- 叶片原Technique=PBRMetallicRoughDiffNormalSpecMask，alpha test+双面背光，非透明混合。
-- 原始身份：Tree02 A5-k0WtcwwJx9oPve4TL4_Ut / Tree21 DlEq0Z8EBRaG2dESwKS8GVI5。
-- 官方真资源已完整下载为本地MDL/KTX/材质，裸tool_mode不依赖远程UUID resolver。
local definitions = {
    treeA = { name = "Tree02", model = "RailwayVegetation/Environment/Vegetation/Trees/Tree02/Meshes/Tree02.mdl",
        materials = { "RailwayVegetation/Environment/Vegetation/Trees/Shared/Materials/Tree01_Trunk.xml",
            "RailwayVegetation/Environment/Vegetation/Trees/Shared/Materials/Tree01_Leaves.xml" },
        drawDistance = 300, shadowDistance = 95, shadows = true },
    treeB = { name = "Tree21", model = "RailwayVegetation/Environment/Vegetation/Trees/Tree21/Meshes/Tree21.mdl",
        materials = { "RailwayVegetation/Environment/Vegetation/Trees/Shared/Materials/Tree01_Trunk.xml",
            "RailwayVegetation/Environment/Vegetation/Trees/Shared/Materials/Tree19_Leaves.xml" },
        drawDistance = 300, shadowDistance = 95, shadows = true },
    bush = { name = "Bush05", model = "RailwayVegetation/Environment/Vegetation/Bushes/Bush05/Meshes/Bush05.mdl",
        materials = { "RailwayVegetation/Environment/Vegetation/Flowers/Shared/Materials/Flower01.xml" },
        drawDistance = 125, shadowDistance = 45, shadows = true },
    grass = { name = "Grass01", model = "RailwayVegetation/Environment/Vegetation/Grass/Grass01/Meshes/Grass01.mdl",
        materials = { "RailwayVegetation/Environment/Vegetation/Bushes/Shared/Materials/Bush03.xml" },
        drawDistance = 75, shadowDistance = 0, shadows = false },
}

---@param kind string
---@return RailwayPlantAsset|nil
function Vegetation.GetAsset(kind)
    if attempted_[kind] then return assets_[kind] end
    attempted_[kind] = true
    local def = definitions[kind]
    if not def then return nil end
    local model = cache:GetResource("Model", def.model)
    if not model then
        print("[Vegetation] 警告：官方模型不可用，跳过 " .. def.name)
        return nil
    end
    local bounds = model.boundingBox
    local size = bounds.size
    if size.x < .001 or size.y < .001 or size.z < .001 then
        print("[Vegetation] 警告：官方模型包围盒无效，跳过 " .. def.name)
        return nil
    end
    ---@type Material[]
    local materials = {}
    for i, uri in ipairs(def.materials) do
        local original = cache:GetResource("Material", uri)
        if not original then
            print("[Vegetation] 警告：官方材质不可用，跳过 " .. def.name .. " " .. uri)
            return nil
        end
        -- 仅克隆关闭植被遮挡体功能，不改原贴图、UV、alpha裁剪或共享库材质。
        local material = original:Clone()
        material.occlusion = false
        materials[i] = material
    end
    ---@type RailwayPlantAsset
    local asset = { name = def.name, model = model, materials = materials, bounds = bounds,
        drawDistance = def.drawDistance, shadowDistance = def.shadowDistance, shadows = def.shadows }
    assets_[kind] = asset
    print(string.format("[Vegetation] %s 官方MDL %.3f×%.3f×%.3fm，%d材质槽；draw %.0fm/shadow %.0fm",
        def.name,size.x,size.y,size.z,#materials,def.drawDistance,def.shadowDistance))
    return asset
end

---@param root Node
---@return RailwayPlantBatch
function Vegetation.NewBatch(root)
    local self = setmetatable({}, PlantBatch)
    self:Init(root)
    return self
end
function PlantBatch:Init(root)
    self.root = root
    self.groups = {}
    self.instances = 0
end

---@param asset RailwayPlantAsset
---@param height number
---@return number scale, number radius
function Vegetation.Measure(asset, height)
    local scale = height / asset.bounds.size.y
    local size = asset.bounds.size * scale
    return scale, math.sqrt(size.x * size.x + size.z * size.z) / 2
end

-- 净空示意（整条线路XZ，不是物理碰撞）：
-- 铁路 ---- >=30.01米 ---- [冠幅完整外包圆]。先Measure再CanPlaceFootprint再Add。
-- XZ以模型包围盒中心定位，最低Y落在土面；任意yaw仍被同一外包圆包含。
---@param asset RailwayPlantAsset
---@param center Vector3
---@param scale number
---@param yaw number 度
function PlantBatch:Add(asset, center, scale, yaw)
    local key = asset.name .. "_" .. math.floor(center.x / 64) .. "_" .. math.floor(center.z / 64)
    local group = self.groups[key]
    if not group then
        local chunk = self.root:CreateChild(key)
        chunk.position = Vector3(math.floor(center.x/64)*64+32,0,math.floor(center.z/64)*64+32)
        group = chunk:CreateComponent("StaticModelGroup")
        group.model = asset.model
        for i, material in ipairs(asset.materials) do group:SetMaterial(i - 1,material) end
        group.viewMask = 2
        group.castShadows = asset.shadows
        group.drawDistance = asset.drawDistance
        group.shadowDistance = asset.shadowDistance
        group.occluder = false
        self.groups[key] = group
    end
    local instance = self.root:CreateChild(asset.name .. "_Instance")
    local rotation = Quaternion(yaw,Vector3.UP)
    local offset = Vector3(-asset.bounds.center.x,-asset.bounds.min.y,-asset.bounds.center.z) * scale
    instance.position = center + rotation * offset
    instance.rotation = rotation
    instance.scale = Vector3.ONE * scale
    group:AddInstanceNode(instance)
    self.instances = self.instances + 1
end
function PlantBatch:Finish()
    local groups = 0
    for _ in pairs(self.groups) do groups = groups + 1 end
    return self.instances, groups
end

-- 站前只用0.5..0.7米灌木与0.18..0.24米草，不把小模型放大为巨大团块。
-- 全部植物外包圆装入原池内；同一池最多4灌木+4草、共享空间实例批。
---@param root Node
---@param center Vector3
---@param right Vector3
---@param tangent Vector3
---@param width number
---@param depth number
---@param soilY number
---@param stationIndex number
function Vegetation.BuildPlanter(root, center, right, tangent, width, depth, soilY, stationIndex)
    local plants = Vegetation.NewBatch(root:CreateChild("PlanterFoliage"))
    local bush, grass = Vegetation.GetAsset("bush"), Vegetation.GetAsset("grass")
    local accepted = 0
    for i, x in ipairs({-2.9,-.95,.90,2.85}) do
        local asset = i % 2 == 0 and grass or bush
        if asset then
            local height = i % 2 == 0 and .22 or (.58 + stationIndex % 2 * .06)
            local scale, radius = Vegetation.Measure(asset,height)
            local z = (i%2 == 0 and -.34 or .25)
            local position = center + right*x + tangent*z + Vector3(0,soilY,0)
            if math.abs(x)+radius < width/2 and math.abs(z)+radius < depth/2
                and Route.CanPlaceFootprint(position,radius,5) then
                plants:Add(asset,position,scale,(i*71+stationIndex*19)%360)
                accepted = accepted + 1
            end
        end
    end
    local _, groups = plants:Finish()
    print(string.format("[Vegetation] 站前池%d簇/%d实例批，完整枝叶未超池沿",accepted,groups))
end
return Vegetation
