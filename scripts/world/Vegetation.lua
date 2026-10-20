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
---@field batchSize? number 有界XZ分块；默认64m，沿线乔木可用128m避免混种批碎片

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
---@type table<string,Material>
local plantMaterials_ = {}
-- 三档有限的叶色身份按树种共享，而非每株Clone。只调原有MatDiffColor，
-- 不添加defines/法线/阴影变体；原alpha test、双面背光、纹理与Technique均保留。
---@type table<string,integer>
local leafTone = { treeA=1,treeB=2,treeC=3,treeD=2,treeE=3,treeF=2,treeG=1 }
---@type number[][]
local leafColors = { {.43,.49,.28}, {.32,.42,.25}, {.47,.50,.34} }

-- 源自官方prefab的材质槽顺序（0=树皮，1=叶片）。
-- 叶片原Technique=PBRMetallicRoughDiffNormalSpecMask，alpha test+双面背光，非透明混合。
-- 原始身份：Tree02 A5-k0WtcwwJx9oPve4TL4_Ut / Tree21 DlEq0Z8EBRaG2dESwKS8GVI5。
-- 官方真资源已完整下载为本地MDL/KTX/材质，裸tool_mode不依赖远程UUID resolver。
-- 七种乔木共享同一套树皮/叶片材质，形态各异，用于形成有层次的混交林。
local SHARED = "RailwayVegetation/Environment/Vegetation/Trees/Shared/Materials/"
local definitions = {
    treeA = { name = "Tree02", model = "RailwayVegetation/Environment/Vegetation/Trees/Tree02/Meshes/Tree02.mdl",
        materials = { SHARED .. "Tree01_Trunk.xml", SHARED .. "Tree01_Leaves.xml" },
        drawDistance = 320, shadowDistance = 95, shadows = true },
    treeB = { name = "Tree21", model = "RailwayVegetation/Environment/Vegetation/Trees/Tree21/Meshes/Tree21.mdl",
        materials = { SHARED .. "Tree01_Trunk.xml", SHARED .. "Tree19_Leaves.xml" },
        drawDistance = 320, shadowDistance = 95, shadows = true },
    treeC = { name = "Tree14", model = "RailwayVegetation/Environment/Vegetation/Trees/Tree14/Meshes/Tree14.mdl",
        materials = { SHARED .. "Tree01_Trunk.xml", SHARED .. "Tree01_Leaves.xml" },
        drawDistance = 340, shadowDistance = 95, shadows = true },
    treeD = { name = "Tree17", model = "RailwayVegetation/Environment/Vegetation/Trees/Tree17/Meshes/Tree17.mdl",
        materials = { SHARED .. "Tree01_Trunk.xml", SHARED .. "Tree19_Leaves.xml" },
        drawDistance = 340, shadowDistance = 95, shadows = true },
    treeE = { name = "Tree24", model = "RailwayVegetation/Environment/Vegetation/Trees/Tree24/Meshes/Tree24.mdl",
        materials = { SHARED .. "Tree01_Trunk.xml", SHARED .. "Tree01_Leaves.xml" },
        drawDistance = 300, shadowDistance = 90, shadows = true },
    treeF = { name = "Tree20", model = "RailwayVegetation/Environment/Vegetation/Trees/Tree20/Meshes/Tree20.mdl",
        materials = { SHARED .. "Tree01_Trunk.xml", SHARED .. "Tree19_Leaves.xml" },
        drawDistance = 340, shadowDistance = 95, shadows = true },
    treeG = { name = "Tree09", model = "RailwayVegetation/Environment/Vegetation/Trees/Tree09/Meshes/Tree09.mdl",
        materials = { SHARED .. "Tree01_Trunk.xml", SHARED .. "Tree01_Leaves.xml" },
        drawDistance = 300, shadowDistance = 90, shadows = true },
    bush = { name = "Bush05", model = "RailwayVegetation/Environment/Vegetation/Bushes/Bush05/Meshes/Bush05.mdl",
        materials = { "RailwayVegetation/Environment/Vegetation/Flowers/Shared/Materials/Flower01.xml" },
        drawDistance = 125, shadowDistance = 45, shadows = true },
    grass = { name = "Grass01", model = "RailwayVegetation/Environment/Vegetation/Grass/Grass01/Meshes/Grass01.mdl",
        materials = { "RailwayVegetation/Environment/Vegetation/Bushes/Shared/Materials/Bush03.xml" },
        drawDistance = 75, shadowDistance = 0, shadows = false },
}

-- 供地形按索引选树种，避免"同一棵树复制满山"。
---@type string[]
Vegetation.TreeKinds = { "treeA", "treeB", "treeC", "treeD", "treeE", "treeF", "treeG" }

-- 预热门控需要明确列举纹理源，不只MDL/XML；构建后的KTX由资源路由映射，
-- 本地真实源文件为TGA，不虚构不存在的.ktx路径或依赖uuid联网解析。
function Vegetation.GetResourcePaths()
    local paths,seen={},{}
    local function add(path) if not seen[path] then paths[#paths+1]=path;seen[path]=true end end
    for _,definition in pairs(definitions) do
        add(definition.model)
        for _,path in ipairs(definition.materials) do add(path) end
    end
    local root="RailwayVegetation/Environment/Vegetation/"
    for _,entry in ipairs({
        {"Trees/Shared/Textures/Tree01_Trunk_",{"BaseColor","Normal","Mix"}},
        {"Trees/Shared/Textures/Tree01_Leaves_",{"BaseColor","Mix"}},
        {"Bushes/Shared/Textures/Bush03_",{"BaseColor","Normal","Mix"}},
        {"Flowers/Shared/Textures/Flower01_",{"BaseColor","Normal","Mix"}},
    }) do
        for _,suffix in ipairs(entry[2]) do add(root..entry[1]..suffix..".tga") end
    end
    add("RailwayVegetation/Common/Textures/Default_Normal.tga")
    return paths
end

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
        local tone=i==2 and leafTone[kind] or nil
        local materialKey=tone and (uri.."_tone_"..tone) or uri
        local material=plantMaterials_[materialKey]
        if not material then
            -- 相同树形/叶色始终复用同一身份；绝不写cache共享原材质。
            material=original:Clone()
            material.occlusion=false
            if tone then
                local color=leafColors[tone]
                material:SetShaderParameter("MatDiffColor",Variant(Color(color[1] or .43,color[2] or .49,color[3] or .28,1)))
            end
            plantMaterials_[materialKey]=material
        end
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
    local self = setmetatable({}, PlantBatch) --[[@as RailwayPlantBatch]]
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
    local cellSize=asset.batchSize or 64
    local key = asset.name .. "_" .. math.floor(center.x / cellSize) .. "_" .. math.floor(center.z / cellSize)
    local group = self.groups[key]
    if not group then
        local chunk = self.root:CreateChild(key)
        chunk.position = Vector3(math.floor(center.x/cellSize)*cellSize+cellSize/2,0,math.floor(center.z/cellSize)*cellSize+cellSize/2)
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
