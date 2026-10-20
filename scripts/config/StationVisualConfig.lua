-- 车站视觉合同：站点主题、质量预算与进入驾驶前必须准备的环境资源。
-- 视觉合同只描述资产与预算，不改变线路、站台净空和运营逻辑。
local Config = {}

---@class StationVisualQualityBudget
---@field stationNearDensity number
---@field cityMidDensity number
---@field farProxyDensity number
---@field vegetationScale number
---@field treeDistance number
---@field farClip number
---@field terrainRadius number
---@field viewAhead number
---@field viewBehind number
---@field sceneryAhead number
---@field sceneryBehind number
---@field vegetationRadius number
---@field trafficMaxFormations integer
---@field trafficRange number
---@field passengerMaxVisible integer
---@field passengerBackground integer
---@field trafficProxyEnabled boolean
---@field pedestrianProxyEnabled boolean
local QUALITY = {
    low = {
        stationNearDensity = .55, cityMidDensity = .42, farProxyDensity = .30,
        vegetationScale = .55, treeDistance = 300, farClip = 2200, terrainRadius = 880,
        viewAhead = 1800, viewBehind = 1400, sceneryAhead = 1100, sceneryBehind = 900,
        vegetationRadius = 640, trafficMaxFormations = 1, trafficRange = 1300,
        passengerMaxVisible = 16, passengerBackground = 4,
        trafficProxyEnabled = true, pedestrianProxyEnabled = false,
    },
    medium = {
        stationNearDensity = 1.0, cityMidDensity = .72, farProxyDensity = .55,
        vegetationScale = 1.0, treeDistance = 430, farClip = 3400, terrainRadius = 1200,
        viewAhead = 2800, viewBehind = 2200, sceneryAhead = 1600, sceneryBehind = 1200,
        vegetationRadius = 800, trafficMaxFormations = 3, trafficRange = 2400,
        passengerMaxVisible = 36, passengerBackground = 12,
        trafficProxyEnabled = true, pedestrianProxyEnabled = true,
    },
    high = {
        stationNearDensity = 1.35, cityMidDensity = 1.0, farProxyDensity = .85,
        vegetationScale = 1.7, treeDistance = 680, farClip = 4600, terrainRadius = 1520,
        viewAhead = 4000, viewBehind = 3200, sceneryAhead = 2400, sceneryBehind = 1800,
        vegetationRadius = 1120, trafficMaxFormations = 4, trafficRange = 3600,
        passengerMaxVisible = 52, passengerBackground = 20,
        trafficProxyEnabled = true, pedestrianProxyEnabled = true,
    },
}

-- 站点差异首先来自空间原型、灯光和远景语义；颜色不能单独作为差异化。
---@type table<integer, table>
Config.Stations = {
    [1] = { key = "xingxi_terminal", archetype = "palace", canopy = "reference_metal_palace", district = "urban_terminal", hero = true },
    [2] = { key = "langang", archetype = "tower", canopy = "reference_metal_harbour", district = "industrial_harbour", hero = false },
    [3] = { key = "yucen", archetype = "gate", canopy = "reference_metal_arcade", district = "village_valley", hero = false },
    [4] = { key = "jinglan", archetype = "block", canopy = "reference_metal_lakefront", district = "lakefront", hero = false },
    [5] = { key = "yunwan_terminal", archetype = "terminal", canopy = "reference_metal_interchange", district = "dense_interchange", hero = false },
    [6] = { key = "cuichuan", archetype = "gate", canopy = "garden_arch", district = "farmland_foothill", hero = false },
    [7] = { key = "shimen", archetype = "tower", canopy = "stone_segmented", district = "rock_gate", hero = false },
    [8] = { key = "yunjix", archetype = "palace", canopy = "wood_double_slope", district = "forest_highland", hero = false },
    [9] = { key = "songlan", archetype = "block", canopy = "highland_slope", district = "forest_ridge", hero = false },
    [10] = { key = "tianchi_terminal", archetype = "terminal", canopy = "lake_transparent", district = "plateau_lake", hero = false },
}

-- 同城同结构：普通10站和狂暴沿用站名的5站按稳定station.index取原型。
-- spans在可用棚长内归一化；只改变遮雨覆盖，不缩短三座实体站台或改停靠点。
-- grade/finish不是换牌：控制实建棚段、截面、支撑体系、铺装尺度与家具数量。
local PLATFORM_PROFILES = {
    { tier="metropolitan_terminal", shape="gable", frame="lattice", finish="zinc",
        spans={{0,1}}, rise=.96, columnStep=15, ribStep=.80, signs=4, waiting=3, adverts=3, screens=true, benches=5, bins=3, slab=1.8, courses=6 },
    { tier="industrial_port", shape="mono", frame="lattice", finish="marine_steel",
        spans={{.12,.48},{.55,.94}}, rise=.78, columnStep=16, ribStep=1.05, signs=3, waiting=2, adverts=1, screens=true, benches=3, bins=2, slab=2.8, courses=4 },
    { tier="village_valley", shape="gable", frame="timber", finish="warm_timber",
        spans={{.40,.84}}, rise=1.35, columnStep=12, ribStep=1.25, signs=1, waiting=1, adverts=0, screens=false, benches=1, bins=1, slab=3.5, courses=4 },
    { tier="waterfront_city", shape="mono", frame="portal", finish="lake_steel",
        spans={{.22,.53},{.62,.96}}, rise=1.10, columnStep=15, ribStep=1.10, signs=2, waiting=2, adverts=1, screens=true, benches=2, bins=2, slab=2.8, courses=4 },
    { tier="regional_interchange", shape="gable", frame="lattice", finish="graphite",
        spans={{.04,.57},{.62,1}}, rise=1.22, columnStep=15, ribStep=.90, signs=4, waiting=3, adverts=2, screens=true, benches=4, bins=3, slab=1.8, courses=6 },
    { tier="foothill_village", shape="gable", frame="timber", finish="ochre_timber",
        spans={{.43,.78}}, rise=1.15, columnStep=12, ribStep=1.35, signs=1, waiting=1, adverts=0, screens=false, benches=1, bins=1, slab=3.5, courses=4 },
    { tier="mountain_gate", shape="mono", frame="masonry", finish="stone_pier",
        spans={{.32,.55},{.65,.88}}, rise=.90, columnStep=12, ribStep=1.30, signs=2, waiting=1, adverts=0, screens=false, benches=1, bins=1, slab=3.5, courses=4 },
    { tier="forest_highland", shape="gable", frame="timber", finish="forest_timber",
        spans={{.25,.61},{.69,.94}}, rise=1.50, columnStep=12, ribStep=1.20, signs=2, waiting=2, adverts=0, screens=true, benches=2, bins=2, slab=2.8, courses=4 },
    { tier="ridge_halt", shape="mono", frame="portal", finish="ridge_steel",
        spans={{.48,.86}}, rise=.82, columnStep=12, ribStep=1.40, signs=1, waiting=1, adverts=0, screens=false, benches=1, bins=1, slab=3.5, courses=4 },
    { tier="lake_terminal", shape="gable", frame="portal", finish="lake_terminal",
        spans={{.10,.58},{.65,1}}, rise=1.08, columnStep=15, ribStep=1.05, signs=3, waiting=2, adverts=1, screens=true, benches=3, bins=2, slab=2.8, courses=4 },
}

-- 实体安全合同（米）：棚边退入站台0.30米，家具行不变，任何原型不占乘客走廊。
---@class ReferenceRoofSegment
---@field first number
---@field last number
---@class ReferenceStationArchitecture
---@field roofFirst number
---@field roofLast number
---@field roofSegments ReferenceRoofSegment[]
---@field roofShape string
---@field frameStyle string
---@field finish string
---@field serviceTier string
---@field coveredLength number
---@field coverageRatio number
---@field eaveY number
---@field ridgeY number
---@field columnStep number
---@field roofRibStep number
---@field roofSampleStep number
---@field platformTop number
---@field platformCenters number[]
---@field columnCenters number[]
---@field roofHalfWidth number
---@field columnWidth number
---@field columnDepth number
---@field trussBottomY number
---@field edgeTrussDepth number
---@field waitingOffsets number[]
---@field signOffsets number[]
---@field advertOffsets number[]
---@field benchOffsets number[]
---@field binOffsets number[]
---@field waitingScreens boolean
---@field pavingSlabLength number
---@field pavingCourses integer
---@field maxBatches integer
---@field maxVertices integer
---@field maxTextLabels integer
---@field identity string
Config.ReferenceArchitecture = {
    version = "graded-platform-structure-v3",
    eaveY = 7.10, ridgeY = 8.06, columnStep = 15.0,
    roofRibStep = .80, roofSampleStep = 12.0, platformTop = 1.44,
    platformCenters = {-16.4,-5.4,10.4}, columnCenters = {-18.65,-7.65,12.65},
    columnWidth = .36, columnDepth = .44, trussBottomY = 6.56, edgeTrussDepth = .74,
    roofHalfWidth = 3.20, maxBatches = 20, maxVertices = 180000, maxTextLabels = 84,
}

---@param index integer
---@param platformStart number
---@param platformEnd number
---@return ReferenceStationArchitecture
function Config.GetReferenceArchitecture(index, platformStart, platformEnd)
    local base = Config.ReferenceArchitecture
    local profile = PLATFORM_PROFILES[index] or PLATFORM_PROFILES[1]
    local first,last = platformStart+6,math.min(platformEnd-28,57)
    local usable = last-first
    local segments = {} ---@type ReferenceRoofSegment[]
    local covered = 0
    for _,span in ipairs(profile.spans) do
        local a,b=first+usable*span[1],first+usable*span[2]
        local segment = {first=a,last=b} ---@type ReferenceRoofSegment
        segments[#segments+1]=segment;covered=covered+b-a
    end
    -- Locate real bay centres inside an actual roof segment. No hanging sign in an
    -- open gap, no furniture at the forecourt stair(-49)/ramp(-37) mouths.
    local function offsets(count,phase)
        local result = {}
        for i=1,count do
            local distance=covered*(i-1+phase)/count
            for _,segment in ipairs(segments) do
                local length=segment.last-segment.first
                if distance<=length then
                    local bays=math.max(1,math.ceil((length-4)/profile.columnStep))
                    local step=(length-4)/bays
                    local nominal=segment.first+2+(math.floor((distance-2)/step)+.5)*step
                    local ds=math.max(segment.first+4,math.min(segment.last-4,nominal))
                    if ds>-57 and ds<-29 then
                        ds=segment.first+4<=-63 and -63 or -23
                    end
                    result[#result+1]=ds;break
                end
                distance=distance-length
            end
        end
        return result
    end
    return {
        version=base.version,roofFirst=segments[1].first,roofLast=segments[#segments].last,
        roofSegments=segments,roofShape=profile.shape,frameStyle=profile.frame,finish=profile.finish,
        serviceTier=profile.tier,coveredLength=covered,coverageRatio=covered/(platformEnd-platformStart),
        eaveY=base.eaveY,ridgeY=base.eaveY+profile.rise,columnStep=profile.columnStep,
        roofRibStep=profile.ribStep,roofSampleStep=base.roofSampleStep,
        platformTop=base.platformTop,platformCenters=base.platformCenters,
        columnCenters=base.columnCenters,roofHalfWidth=base.roofHalfWidth,
        columnWidth=base.columnWidth,columnDepth=base.columnDepth,
        trussBottomY=base.trussBottomY,edgeTrussDepth=base.edgeTrussDepth,
        waitingOffsets=offsets(profile.waiting,.50),signOffsets=offsets(profile.signs,.40),
        advertOffsets=offsets(profile.adverts,.15),benchOffsets=offsets(profile.benches,.70),binOffsets=offsets(profile.bins,.90),
        waitingScreens=profile.screens,pavingSlabLength=profile.slab,pavingCourses=profile.courses,
        maxBatches=base.maxBatches,
        maxVertices=math.ceil(base.maxVertices*math.max(1,(platformEnd-platformStart)/310)),
        maxTextLabels=base.maxTextLabels,identity=tostring(Config.GetStation(index).key),
    }
end

-- 这些是当前样板站和全线环境会直接读取的本地资源；路径必须保持完整字面量，
-- 便于构建引用和运行时下载门禁同时发现它们。
local COMMON_RESOURCES = {
    "Textures/Railway/grass.png", "Textures/Railway/brick.png",
    "Textures/Railway/concrete.png", "Textures/Railway/ballast.png",
    "Textures/Railway/coach_steel.png", "Textures/Railway/coach_paint.png",
    "Textures/Skybox.xml", "Textures/Skybox.ktx",
    "RailwayVegetation/Environment/Vegetation/Trees/Tree02/Meshes/Tree02.mdl",
    "RailwayVegetation/Environment/Vegetation/Trees/Tree21/Meshes/Tree21.mdl",
    "RailwayVegetation/Environment/Vegetation/Trees/Tree14/Meshes/Tree14.mdl",
    "RailwayVegetation/Environment/Vegetation/Trees/Tree17/Meshes/Tree17.mdl",
    "RailwayVegetation/Environment/Vegetation/Trees/Tree24/Meshes/Tree24.mdl",
    "RailwayVegetation/Environment/Vegetation/Trees/Tree20/Meshes/Tree20.mdl",
    "RailwayVegetation/Environment/Vegetation/Trees/Tree09/Meshes/Tree09.mdl",
    "RailwayVegetation/Environment/Vegetation/Trees/Shared/Materials/Tree01_Trunk.xml",
    "RailwayVegetation/Environment/Vegetation/Trees/Shared/Materials/Tree01_Leaves.xml",
    "RailwayVegetation/Environment/Vegetation/Trees/Shared/Materials/Tree19_Leaves.xml",
    "RailwayVegetation/Environment/Vegetation/Bushes/Bush05/Meshes/Bush05.mdl",
    "RailwayVegetation/Environment/Vegetation/Grass/Grass01/Meshes/Grass01.mdl",
    "RailwayVegetation/Environment/Vegetation/Bushes/Shared/Materials/Bush03.xml",
    "RailwayVegetation/Environment/Vegetation/Flowers/Shared/Materials/Flower01.xml",
}

local TRAFFIC_RESOURCES = {
    "model/971f8f1b-a231-5c7f-b9d9-505fbdc1c029/Meshes/3474fff4d8aa4823ac0c3dba89fd6f0f.mdl",
    "model/971f8f1b-a231-5c7f-b9d9-505fbdc1c029/Textures/3474fff4d8aa4823ac0c3dba89fd6f0f_00_D.jpg",
    "model/971f8f1b-a231-5c7f-b9d9-505fbdc1c029/Textures/3474fff4d8aa4823ac0c3dba89fd6f0f_00_N.jpg",
}

local NPC_RESOURCES = {
    "model/1327bd4517494f618b98f9cbd7dd6d14/Meshes/rig-1-abb7fccb-4c30-41bb-87c6-2041221288d0.mdl",
    "model/dc91a901-3f95-58cd-8f9b-3b4f45ddd16a/Meshes/rig-1-d508011a-048f-4b5d-b63f-253a09217cff.mdl",
    "Animations/Passengers/male_walk.ani",
    "Animations/Passengers/female_walk.ani",
    "model/1327bd4517494f618b98f9cbd7dd6d14/Textures/rig-1-abb7fccb-4c30-41bb-87c6-2041221288d0_00_D.jpg",
    "model/1327bd4517494f618b98f9cbd7dd6d14/Textures/rig-1-abb7fccb-4c30-41bb-87c6-2041221288d0_00_N.png",
    "model/dc91a901-3f95-58cd-8f9b-3b4f45ddd16a/Textures/rig-1-d508011a-048f-4b5d-b63f-253a09217cff_00_D.jpg",
    "model/dc91a901-3f95-58cd-8f9b-3b4f45ddd16a/Textures/rig-1-d508011a-048f-4b5d-b63f-253a09217cff_00_N.jpg",
}

local CITY_RESOURCES = {
    "model/53b7b1c43a014392b3160d16892893c2/Meshes/53b7b1c43a014392b3160d16892893c2.mdl",
    "model/53b7b1c43a014392b3160d16892893c2/Materials/53b7b1c43a014392b3160d16892893c2_00_tripo_material_52daec93-fbdb-4de2-8907-f1ed02a39747.xml",
    "model/53b7b1c43a014392b3160d16892893c2/Textures/53b7b1c43a014392b3160d16892893c2_00_D.jpg",
    "model/53b7b1c43a014392b3160d16892893c2/Textures/53b7b1c43a014392b3160d16892893c2_00_N.png",
    "model/3b9e3d894594475abed30d7f58e67003/Meshes/3b9e3d894594475abed30d7f58e67003.mdl",
    "model/3b9e3d894594475abed30d7f58e67003/Materials/3b9e3d894594475abed30d7f58e67003_00_tripo_material_b92361d4-cf88-426b-82e7-e1b90ee51bfc.xml",
    "model/3b9e3d894594475abed30d7f58e67003/Textures/3b9e3d894594475abed30d7f58e67003_00_D.jpg",
    "model/3b9e3d894594475abed30d7f58e67003/Textures/3b9e3d894594475abed30d7f58e67003_00_N.png",
    "model/4a6814a7-dedd-5062-b1c3-cefdd17665aa/Meshes/35a410a32def4781ab882d4bb83e9d57.mdl",
    "model/4a6814a7-dedd-5062-b1c3-cefdd17665aa/Materials/35a410a32def4781ab882d4bb83e9d57_00_tripo_material_6c608a38-01aa-41d8-8a33-8570215da74d.xml",
    "model/4a6814a7-dedd-5062-b1c3-cefdd17665aa/Textures/35a410a32def4781ab882d4bb83e9d57_00_D.jpg",
    "model/4a6814a7-dedd-5062-b1c3-cefdd17665aa/Textures/35a410a32def4781ab882d4bb83e9d57_00_N.jpg",
    "model/2f05a71e-54ed-5b6c-9aac-68b5d08d53e5/Meshes/190292b84fa245ba95a803c04c592a0d.mdl",
    "model/2f05a71e-54ed-5b6c-9aac-68b5d08d53e5/Materials/190292b84fa245ba95a803c04c592a0d_00_tripo_material_2e3db796-fa61-495d-86f6-645931aaaeda.xml",
    "model/2f05a71e-54ed-5b6c-9aac-68b5d08d53e5/Textures/190292b84fa245ba95a803c04c592a0d_00_D.jpg",
    "model/2f05a71e-54ed-5b6c-9aac-68b5d08d53e5/Textures/190292b84fa245ba95a803c04c592a0d_00_N.jpg",
}

local HERO_RESOURCES = {
    "model/91331fcb-7232-52b8-860e-4d22a5a15592/Meshes/c18152abfa1547eabe3c54bb8fae7f09.mdl",
    "model/91331fcb-7232-52b8-860e-4d22a5a15592/Materials/c18152abfa1547eabe3c54bb8fae7f09_00_tripo_material_a1fb1559-1882-4a0c-85c8-0c182061dff5.xml",
    "model/91331fcb-7232-52b8-860e-4d22a5a15592/Textures/c18152abfa1547eabe3c54bb8fae7f09_00_D.jpg",
    "model/91331fcb-7232-52b8-860e-4d22a5a15592/Textures/c18152abfa1547eabe3c54bb8fae7f09_00_N.jpg",
    "model/ea12c55a04ce49e7a62e1e952b2b85d0/Meshes/ea12c55a04ce49e7a62e1e952b2b85d0.mdl",
    "model/ea12c55a04ce49e7a62e1e952b2b85d0/Materials/ea12c55a04ce49e7a62e1e952b2b85d0_00_tripo_material_0c2865ef-2546-4809-bf47-24f0b98a798d.xml",
    "model/ea12c55a04ce49e7a62e1e952b2b85d0/Textures/ea12c55a04ce49e7a62e1e952b2b85d0_00_D.jpg",
    "model/ea12c55a04ce49e7a62e1e952b2b85d0/Textures/ea12c55a04ce49e7a62e1e952b2b85d0_00_N.png",
}

---@param id string|nil
---@return string
function Config.NormalizeQuality(id)
    if QUALITY[id or ""] then return id --[[@as string]] end
    if id == "performance" then return "medium" end
    if id == "detailed" then return "high" end
    return "medium"
end

---@param id string|nil
---@return StationVisualQualityBudget
function Config.GetQuality(id)
    return QUALITY[Config.NormalizeQuality(id)]
end

---@param index integer
---@return table
function Config.GetStation(index)
    return Config.Stations[index] or Config.Stations[1]
end

---@param stationIndex integer
---@param qualityId string|nil
---@return string[]
function Config.GetRequiredResources(stationIndex, qualityId)
    local paths = {}
    local seen = {}
    local function add(path)
        if not seen[path] then seen[path] = true; paths[#paths + 1] = path end
    end
    local quality = Config.GetQuality(qualityId)
    for _, path in ipairs(COMMON_RESOURCES) do add(path) end
    for _, path in ipairs(CITY_RESOURCES) do add(path) end
    for _, path in ipairs(HERO_RESOURCES) do add(path) end
    local station = Config.GetStation(stationIndex)
    if quality.trafficProxyEnabled then
        for _, path in ipairs(TRAFFIC_RESOURCES) do add(path) end
    end
    if quality.pedestrianProxyEnabled then
        for _, path in ipairs(NPC_RESOURCES) do add(path) end
    end
    print(string.format("[StationVisualConfig] %s 资源合同：%d项，画质=%s，站台近景×%.2f",
        station.key, #paths, Config.NormalizeQuality(qualityId), quality.stationNearDensity))
    return paths
end

return Config
