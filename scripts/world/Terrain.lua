-- 中国普速铁路环境意象：平坦铁路基准、缓丘、低饱和农田与分层聚落。
-- 不复刻真实城市；所有景观检查完整闭合线路，铁路/站台净空保持原值。
local Route = require "world.Route"
local World = require "world.WorldMaterials"
local Vegetation = require "world.Vegetation"
local Terrain = {}
local GameConfig = require "config.GameConfig"
---@type Node|nil
local scene_ = nil
---@type table[]
local reservations_ = {}
---@type table<string, table[]>
local fieldData_ = {}
---@type table<string, Material>
local solidMaterials_ = {}
local function solid(color, metallic, roughness)
    local key = string.format("%.4f_%.4f_%.4f_%.4f_%.4f", color.r,color.g,color.b,metallic or 0,roughness or .8)
    if not solidMaterials_[key] then solidMaterials_[key] = World.Solid(color,metallic,roughness) end
    return solidMaterials_[key]
end
---@type table[]
local placementData_ = {}
---@type table[]
local fields_ = {}
---@type table[]
local paths_ = {}
local seed_ = 20261006
local function random()
    seed_ = (seed_ * 48271) % 2147483647
    return seed_ / 2147483647
end
local function range(a, b) return a + (b - a) * random() end

---@type number[]
local bounds_ = {}
local function routeBounds()
    if #bounds_ == 4 then return bounds_[1],bounds_[2],bounds_[3],bounds_[4] end
    local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
    for _, p in ipairs(Route.GetPoints()) do
        minX, maxX = math.min(minX, p.pos.x), math.max(maxX, p.pos.x)
        minZ, maxZ = math.min(minZ, p.pos.z), math.max(maxZ, p.pos.z)
    end
    if minX == math.huge then return 0, 0, 0, 0 end
    bounds_ = {minX,maxX,minZ,maxZ}
    return minX, maxX, minZ, maxZ
end

---@param pos Vector3
---@param radius? number
local function inStationYard(pos, radius)
    local r = radius or 0
    for _, st in ipairs(Route.GetStations()) do
        local origin, tangent = Route.Sample(st.s)
        local offset = pos - origin
        local along = offset:DotProduct(tangent)
        local lateral = offset:DotProduct(Route.RightAt(st.s))
        if along > Route.PlatformStart - 35 - r and along < Route.PlatformEnd + 35 + r
            and math.abs(lateral) < 100 + r then return true end
    end
    return false
end

---@param pos Vector3
---@param radius number
local function nearSettlement(pos, radius)
    for _, item in ipairs(reservations_) do
        local dx, dz = pos.x - item.x, pos.z - item.z
        if dx * dx + dz * dz < (item.radius + radius + 3)^2 then return true end
    end
    return false
end

-- 小型逻辑保留区独立于可见房屋，不会因为卸载城市使农田侵入街巷。
function Terrain.Init()
    bounds_ = {}
    placementData_, fields_, paths_, reservations_, fieldData_ = {}, {}, {}, {}, {}
    for _, st in ipairs(Route.GetStations()) do
        for along = -198, 126, 12 do
            local p = Route.SampleOffset(st.s + along, -153, 0)
            reservations_[#reservations_ + 1] = {x=p.x,z=p.z,radius=24,kind="lane"}
        end
        for _, lateral in ipairs({-128,-178}) do
            for _, along in ipairs({-180,-125,-70,-15,40,95,108}) do
                local p = Route.SampleOffset(st.s + along, lateral, 0)
                reservations_[#reservations_ + 1] = {x=p.x,z=p.z,radius=25,kind="building"}
            end
        end
    end
end

-- 兼容局部测试入口，不扫全线/全包围矩形。
---@param scene Scene
---@param initialS number|nil
function Terrain.Build(scene, initialS)
    Terrain.Init()
    local root = scene:CreateChild("TerrainPreview")
    Terrain.BuildGround(root)
    local pos = Route.Sample(initialS or 0)
    Terrain.BuildCell(root:CreateChild("InitialCell"), math.floor(pos.x/160), math.floor(pos.z/160), 160)
    return root
end

---@param owner Node|nil
function Terrain.BuildGround(owner)
    if owner then scene_ = owner end
    if not scene_ then return end
    local minX, maxX, minZ, maxZ = routeBounds()
    local margin = 3000
    -- 保留原草地贴图，用中尺度14米平铺和明确各向异性过滤压低近景颗粒闪烁。
    local texture = cache:GetResource("Texture2D", "Textures/Railway/grass.png")
    if texture then
        texture:SetFilterMode(FILTER_ANISOTROPIC)
        texture:SetAnisotropy(4)
    end
    local material = World.Textured("GroundMutedGrass", "Textures/Railway/grass.png", Color(.75,.79,.70), .99)
    local ground = World.NewBatch(scene_:CreateChild("Ground"), material, false, 14.0)
    ground:AddQuad(Vector3(minX - margin, -0.006, minZ - margin), Vector3(minX - margin, -0.006, maxZ + margin),
        Vector3(maxX + margin, -0.006, maxZ + margin), Vector3(maxX + margin, -0.006, minZ - margin))
    ground:Finish()
    print("[Terrain] 草地Y=-0.006，道床坡脚Y=+0.002；保留平坦铁路走廊")
end

-- 山体净空（XZ，不是车辆物理）：
-- [全闭合铁路包围矩形] -- 至少160米净空 -- [80米网格缓坡]
-- 每个网格完整外包圆经CanPlaceFootprint检测；未通过的网格不提交。
-- 高度是连续的宽频正弦叠加，不是圆锥/金字塔；内外缘均平缓降到地面以下。
-- 平滑法线按同一高度函数求导，320米分块之间位置和法线完全一致。
function Terrain.BuildHills(owner, cellX, cellZ, cellSize, pause)
    if owner then scene_ = owner end
    if not scene_ or cellX == nil or cellZ == nil then return end
    local root = scene_:CreateChild("DistantHills")
    local minX, maxX, minZ, maxZ = routeBounds()
    local function outside(x, z)
        local dx = math.max(minX - x, 0, x - maxX)
        local dz = math.max(minZ - z, 0, z - maxZ)
        return math.sqrt(dx * dx + dz * dz)
    end
    local function smooth(v)
        local t = math.max(0, math.min(1, v))
        return t * t * (3 - 2 * t)
    end
    local function height(x, z)
        local distance = outside(x, z)
        local inner = smooth((distance - 380) / 380)
        local outer = 1 - smooth((distance - 920) / 250)
        local waves = 86 + 27 * math.sin(x / 245 + z / 390)
            + 19 * math.sin(x / 430 - z / 210 + 1.4)
            + 8 * math.sin(x / 125 + z / 165 + 0.6)
        return -0.025 + inner * outer * waves
    end
    local function normal(x, z)
        return Vector3(height(x - 1, z) - height(x + 1, z), 2,
            height(x, z - 1) - height(x, z + 1)):Normalized()
    end
    ---@type table<string, RailwayBatch>
    local chunks = {}
    local material = solid(Color(0.31, 0.37, 0.32), 0, 0.98)
    local cells, rejected = 0, 0
    local step = 80
    local size = cellSize or 160
    for x = cellX * size, (cellX + 1) * size - 0.001, step do
        for z = cellZ * size, (cellZ + 1) * size - 0.001, step do
            local centre = Vector3(x + step / 2, 0, z + step / 2)
            -- 包围矩形预筛减少全线投影次数；最终仍检查完整80米单元。
            local distance = outside(centre.x, centre.z)
            if distance > 200 and distance < 1200 then
                if Route.CanPlaceFootprint(centre, step * math.sqrt(0.5), 160) then
                    local key = math.floor(x / 320) .. "_" .. math.floor(z / 320)
                    local b = chunks[key]
                    if not b then
                        b = World.NewBatch(root:CreateChild("Ridge_" .. key), material, false, 80)
                        chunks[key] = b
                    end
                    local a = Vector3(x, height(x, z), z)
                    local c = Vector3(x, height(x, z + step), z + step)
                    local d = Vector3(x + step, height(x + step, z + step), z + step)
                    local e = Vector3(x + step, height(x + step, z), z)
                    local function vertex(p)
                        b:Vertex(p, Vector2(p.x / 80, p.z / 80), normal(p.x, p.z))
                    end
                    vertex(a); vertex(c); vertex(d)
                    vertex(a); vertex(d); vertex(e)
                    cells = cells + 1
                else rejected = rejected + 1 end
            end
        end
    end
    local meshes = 0
    for _, b in pairs(chunks) do b:Finish(); meshes = meshes + 1; if pause then pause() end end
end

---@type Model|nil
local buildingModel_ = nil
---@type Material|nil
local buildingMaterial_ = nil

-- 聚落仅出现在站场外侧，两排错落住宅与一条沿线小路构成连续街巷。
-- 每栋完整外包圆包括屋檐和矮院墙；各段小路也独立检测，拒绝穿线。
function Terrain.BuildCity(owner, station, pause)
    if owner then scene_ = owner end
    if not scene_ or not station then return end
    local root = scene_:CreateChild("City")
    -- 只替换部分后排地块，保留程序化建筑的体量变化，不把同一资产铺满全线。
    -- 完整MDL包含屋檐/门廊/台阶，以其真实包围盒统一缩放，不拆材质重建外壳。
    local assetRoot = "model/2f05a71e-54ed-5b6c-9aac-68b5d08d53e5/"
    local assetName = "190292b84fa245ba95a803c04c592a0d"
    local buildingModel = buildingModel_ or cache:GetResource("Model", assetRoot .. "Meshes/" .. assetName .. ".mdl")
    local diffuse = cache:GetResource("Texture2D", assetRoot .. "Textures/" .. assetName .. "_00_D.jpg")
    local normal = cache:GetResource("Texture2D", assetRoot .. "Textures/" .. assetName .. "_00_N.jpg")
    local technique = cache:GetResource("Technique", "Techniques/PBR/PBRDiffNormal.xml")
    ---@type Material|nil
    local buildingMaterial = buildingMaterial_
    local assetScale, assetWidth, assetDepth, assetRadius = 0.0, 0.0, 0.0, 0.0
    local assetOrigin = Vector3.ZERO
    if buildingModel and diffuse and normal and technique then
        local bounds = buildingModel.boundingBox
        local size = bounds.size
        assert(size.x > 0.0001 and size.y > 0.0001 and size.z > 0.0001, "聚落建筑包围盒无效")
        assetScale = 10.0 / size.y
        assetWidth, assetDepth = size.x * assetScale, size.z * assetScale
        assetRadius = math.sqrt(assetWidth * assetWidth + assetDepth * assetDepth) * 0.5
        -- 模型的XZ包围盒中心落在地块中心，最低点严格落Y=0。
        assetOrigin = Vector3(-bounds.center.x, -bounds.min.y, -bounds.center.z) * assetScale
        if not buildingMaterial then
        buildingMaterial = Material:new()
        buildingMaterial:SetTechnique(0, technique)
        diffuse:SetSRGB(true)
        normal:SetSRGB(false)
        diffuse:SetFilterMode(FILTER_ANISOTROPIC)
        normal:SetFilterMode(FILTER_ANISOTROPIC)
        diffuse:SetAnisotropy(4)
        normal:SetAnisotropy(4)
        buildingMaterial:SetTexture(TU_DIFFUSE, diffuse)
        buildingMaterial:SetTexture(TU_NORMAL, normal)
        buildingMaterial:SetShaderParameter("Metallic", Variant(0.0))
        buildingMaterial:SetShaderParameter("Roughness", Variant(0.85))
        buildingModel_, buildingMaterial_ = buildingModel, buildingMaterial
        end
        print(string.format("[Terrain] 贴图建筑统一缩放%.5f，完整尺寸%.2f×10.00×%.2fm，XZ外包圆%.3fm",
            assetScale, assetWidth, assetDepth, assetRadius))
    else
        print("[Terrain] 警告：贴图建筑/配套贴图/Technique缺失，保留原程序化聚落，不叠加占位外壳")
    end
    ---@type table<string, Node>
    local assetChunks = {}
    local wallMaterials = {
        World.Brick(), solid(Color(0.67, 0.65, 0.59), 0, 0.94),
        solid(Color(0.74, 0.73, 0.68), 0, 0.94),
    }
    local trimMaterial = World.Concrete()
    local roofMaterial = solid(Color(0.30, 0.29, 0.27), 0.03, 0.92)
    local glassMaterial = solid(Color(0.19, 0.25, 0.27), 0.12, 0.32)
    local laneMaterial = solid(Color(0.43, 0.41, 0.36), 0, 0.98)
    ---@type table<string, {walls:RailwayBatch[],trim:RailwayBatch,roof:RailwayBatch,glass:RailwayBatch,lane:RailwayBatch}>
    local chunks = {}
    local function groupAt(pos)
        local key = math.floor(pos.x / 160) .. "_" .. math.floor(pos.z / 160)
        if not chunks[key] then
            local node = root:CreateChild("Settlement_" .. key)
            chunks[key] = {
                walls = {
                    World.NewBatch(node:CreateChild("Brick"), wallMaterials[1], true, 1),
                    World.NewBatch(node:CreateChild("PlasterWarm"), wallMaterials[2], true),
                    World.NewBatch(node:CreateChild("PlasterPale"), wallMaterials[3], true),
                },
                trim = World.NewBatch(node:CreateChild("FramesPlinths"), trimMaterial, true, 1),
                roof = World.NewBatch(node:CreateChild("PitchedRoofs"), roofMaterial, true),
                glass = World.NewBatch(node:CreateChild("PanesDoors"), glassMaterial, false),
                lane = World.NewBatch(node:CreateChild("VillageLanes"), laneMaterial, false),
            }
        end
        return chunks[key]
    end
    local rejected, lanes, texturedBuildings = 0, 0, 0
    for _, st in ipairs({station}) do
        local _, _, yaw = Route.Sample(st.s)
        local angle = math.rad(yaw)
        local co, si = math.cos(angle), math.sin(angle)
        local origin, tangent = Route.Sample(st.s)
        local right = Route.RightAt(st.s)
        local function at(along, lateral)
            return origin + tangent * along + right * lateral
        end
        local function lane(center, width, length)
            local radius = math.sqrt(width * width + length * length) * 0.5
            if not Route.CanPlaceFootprint(center, radius, 25) then return end
            groupAt(center).lane:AddBox(center + Vector3(0, 0.025, 0), Vector3(width, 0.05, length), angle)
            paths_[#paths_ + 1] = { x = center.x, z = center.z, radius = radius, stationIndex=st.index }
            lanes = lanes + 1
        end
        for along = -198, 114, 12 do lane(at(along, -153), 4.5, 12) end
        for row = 1, 2 do
            for i, alongBase in ipairs({ -180, -125, -70, -15, 40, 95 }) do
                local along = alongBase + (row == 2 and 13 or 0)
                local lateral = row == 1 and -128 or -178
                local centre = at(along, lateral)
                local w, d = 9 + (i % 3) * 1.5, 13 + (i % 2) * 3
                local floors = (i + row + st.index) % 3 == 0 and 3 or ((i + row) % 2 + 1)
                local h = floors * 3.0 + 0.25
                -- 后排每站最多两栋，位置交错；完整资产必须容纳于24×36m宽地块。
                -- 其他地块仍生成原住宅，替换分支绝不提交原墙/窗/院墙/坡顶。
                local useAsset = buildingModel ~= nil and buildingMaterial ~= nil and row == 2
                    and (i + st.index) % 3 == 0 and assetWidth + 4 <= 24 and assetDepth + 4 <= 36
                local footprintWidth = useAsset and assetWidth or w
                local radius = useAsset and assetRadius or math.sqrt((w / 2 + 2)^2 + (d / 2 + 2)^2)
                local safe = Route.CanPlaceFootprint(centre, radius)
                if safe then
                    local b = groupAt(centre)
                    local walls = assert(b.walls[(i + row) % 3 + 1])
                    local function p(x, y, z)
                        return Vector3(centre.x + x * co + z * si, y, centre.z - x * si + z * co)
                    end
                    if useAsset then
                        local key = math.floor(centre.x / 160) .. "_" .. math.floor(centre.z / 160)
                        local assetChunk = assetChunks[key]
                        if not assetChunk then
                            assetChunk = root:CreateChild("TexturedSettlement_" .. key)
                            assetChunks[key] = assetChunk
                        end
                        local building = assetChunk:CreateChild("Building_" .. st.index .. "_" .. i)
                        local rotation = Quaternion(yaw, Vector3.UP)
                        building.position = centre + rotation * assetOrigin
                        building.rotation = rotation
                        building.scale = Vector3.ONE * assetScale
                        local drawable = building:CreateComponent("StaticModel")
                        drawable.model = buildingModel
                        drawable:SetMaterial(buildingMaterial)
                        drawable.castShadows = true
                        drawable.viewMask = 2
                        texturedBuildings = texturedBuildings + 1
                    else
                    walls:AddBox(p(0, h / 2, 0), Vector3(w, h, d), angle)
                    b.trim:AddBox(p(0, 0.21, 0), Vector3(w + 0.25, 0.42, d + 0.25), angle)
                    for floor = 1, floors do
                        local y = (floor - 1) * 3 + 1.95
                        for side = -1, 1, 2 do
                            for z = -d / 2 + 2.4, d / 2 - 1.8, 4.0 do
                                local x = side * (w / 2 + 0.03)
                                b.glass:AddBox(p(x, y, z), Vector3(0.04, 1.35, 1.65), angle)
                                for _, dy in ipairs({ -0.72, 0.72 }) do
                                    b.trim:AddBox(p(x + side * 0.045, y + dy, z), Vector3(0.12, 0.09, 1.85), angle)
                                end
                                for _, dz in ipairs({ -0.86, 0.86 }) do
                                    b.trim:AddBox(p(x + side * 0.04, y, z + dz), Vector3(0.10, 1.45, 0.08), angle)
                                end
                                b.trim:AddBox(p(x + side * 0.055, y, z), Vector3(0.08, 1.35, 0.045), angle)
                            end
                        end
                        b.trim:AddBox(p(0, floor * 3.0, 0), Vector3(w + 0.16, 0.09, d + 0.16), angle)
                    end
                    local x, z, ridge = w / 2 + 0.55, d / 2 + 0.55, h + 1.5
                    b.roof:AddQuad(p(-x, h, -z), p(-x, h, z), p(0, ridge, z), p(0, ridge, -z))
                    b.roof:AddQuad(p(0, ridge, -z), p(0, ridge, z), p(x, h, z), p(x, h, -z))
                    walls:AddTri(p(-w/2,h,-d/2),p(0,ridge,-d/2),p(w/2,h,-d/2))
                    walls:AddTri(p(-w/2,h,d/2),p(w/2,h,d/2),p(0,ridge,d/2))
                    for side = -1, 1, 2 do
                        b.trim:AddBox(p(side*x,h-.05,0),Vector3(.12,.15,z*2),angle)
                    end
                    b.roof:AddBox(p(0,ridge,0),Vector3(.16,.14,z*2),angle)
                    local entranceSide = row == 1 and -1 or 1
                    b.glass:AddBox(p(entranceSide*(w/2+.04),1.10,0),Vector3(.06,2.20,1.35),angle)
                    b.trim:AddBox(p(entranceSide*(w/2+.48),2.40,0),Vector3(1.05,.10,1.90),angle)
                    -- 小院两端矮墙，不封住朝向小路的门。
                    for _, dz in ipairs({-d/2-1.5,d/2+1.5}) do
                        walls:AddBox(p(0,.48,dz),Vector3(w+3,.96,.18),angle)
                        b.trim:AddBox(p(0,.99,dz),Vector3(w+3.15,.08,.28),angle)
                    end
                    end
                    local entranceSide = row == 1 and -1 or 1
                    local pathStart = lateral + entranceSide*(footprintWidth/2+.5)
                    local length = math.abs(-153 - pathStart)
                    -- 连接街巷的支路横跨局部X，长边沿X烘焙；不越过既有街巷中心。
                    local pathCentre = at(along, (pathStart-153)*.5)
                    local pathRadius = math.sqrt(length*length+2.0*2.0)*.5
                    if Route.CanPlaceFootprint(pathCentre,pathRadius,25) then
                        b.lane:AddBox(pathCentre+Vector3(0,.031,0),Vector3(length,.062,2),angle)
                        paths_[#paths_+1] = {x=pathCentre.x,z=pathCentre.z,radius=pathRadius,stationIndex=st.index}
                        lanes = lanes + 1
                    end
                    placementData_[#placementData_+1] = {name=st.name.."_Village_"..row.."_"..i,
                        x=centre.x,z=centre.z,radius=radius,clearance=Route.DistanceTo(centre)-radius,
                        stationIndex=st.index, kind=useAsset and "textured_mdl" or "procedural",
                        width=footprintWidth,depth=useAsset and assetDepth or d,
                        height=useAsset and 10.0 or (h+1.5),scale=useAsset and assetScale or 1.0}
                else rejected = rejected + 1 end
                if pause then pause() end
            end
        end
    end
    local meshes = 0
    for _, b in pairs(chunks) do
        for _, wall in ipairs(b.walls) do if wall:Finish()>0 then meshes=meshes+1 end; if pause then pause() end end
        for _, item in ipairs({b.trim,b.roof,b.glass,b.lane}) do
            if item:Finish()>0 then meshes=meshes+1 end
            if pause then pause() end
        end
    end
    print(string.format("[Terrain] 聚落%d栋（完整贴图MDL替换%d栋，其余保留程序化）/拒绝%d栋；安全巷道%d段，%d合批网格；全包络净空>=25米",
        #placementData_,texturedBuildings,rejected,lanes,meshes))
end

-- 农田每块连同田埂完整检查，不能只检测四角（对弯道/闭合另一边不安全）。
-- 田面、垄沟与田埂分层，不修改铁路基准地面。80..160米空间块共享四种作物色。
local function fieldAllowed(centre, radius)
    return Route.CanPlaceFootprint(centre,radius,30) and not inStationYard(centre,radius)
        and not nearSettlement(centre,radius)
end

function Terrain.BuildFields(owner, cellX, cellZ, cellSize, pause)
    if owner then scene_ = owner end
    if not scene_ or cellX == nil or cellZ == nil then return end
    local root = scene_:CreateChild("Farmland")
    local palette = {Color(.43,.47,.31),Color(.53,.50,.35),Color(.36,.43,.31),Color(.47,.43,.34)}
    ---@type Material[]
    local materials = {}
    for i, color in ipairs(palette) do
        materials[i] = World.Textured("FieldCrop"..i,"Textures/Railway/grass.png",color,.99)
    end
    local soil = solid(Color(.38,.35,.27),0,.99)
    ---@type table<string, {crops:RailwayBatch[],earth:RailwayBatch}>
    local chunks = {}
    local size = cellSize or 160
    local minX,maxX,minZ,maxZ = cellX*size,(cellX+1)*size,cellZ*size,(cellZ+1)*size
    local accepted,rejected = 0,0
    local cellFields = {}
    for ix=math.ceil((minX-34)/68),math.ceil((maxX-34)/68)-1 do
        for iz=math.ceil((minZ-43)/86),math.ceil((maxZ-43)/86)-1 do
            local centre=Vector3(ix*68+34,0,iz*86+43)
            local w,d=54.0,72.0
            local radius=math.sqrt((w/2+.65)^2+(d/2+.65)^2)
            if fieldAllowed(centre,radius) then
                local key=math.floor(centre.x/160).."_"..math.floor(centre.z/160)
                if not chunks[key] then
                    local node=root:CreateChild("Fields_"..key)
                    ---@type RailwayBatch[]
                    local crops={}
                    for i=1,4 do crops[i]=World.NewBatch(node:CreateChild("Crop"..i),materials[i],false,6) end
                    chunks[key]={crops=crops,earth=World.NewBatch(node:CreateChild("BundsFurrows"),soil,false)}
                end
                local b=chunks[key]
                local crop=assert(b.crops[(ix+iz*3)%4+1])
                local x0,x1,z0,z1=centre.x-w/2,centre.x+w/2,centre.z-d/2,centre.z+d/2
                crop:AddQuad(Vector3(x0,.018,z0),Vector3(x0,.018,z1),Vector3(x1,.018,z1),Vector3(x1,.018,z0))
                -- 田埂顶宽0.4米、高0.10米；远观清晰，近观不夸张成围墙。
                for _, x in ipairs({x0-.25,x1+.25}) do b.earth:AddBox(Vector3(x,.05,centre.z),Vector3(.50,.10,d+1)) end
                for _, z in ipairs({z0-.25,z1+.25}) do b.earth:AddBox(Vector3(centre.x,.05,z),Vector3(w,.10,.50)) end
                for x=x0+3,x1-1,4 do
                    b.earth:AddQuad(Vector3(x,.023,z0+.5),Vector3(x,.023,z1-.5),
                        Vector3(x+.12,.023,z1-.5),Vector3(x+.12,.023,z0+.5))
                end
                cellFields[#cellFields+1]={x=centre.x,z=centre.z,halfX=w/2+.5,halfZ=d/2+.5,
                    radius=radius,clearance=Route.DistanceTo(centre)-radius}
                accepted=accepted+1
            else rejected=rejected+1 end
            if pause then pause() end
        end
    end
    fieldData_[cellX.."_"..cellZ] = cellFields
    local meshes=0
    for _, b in pairs(chunks) do
        for _, crop in ipairs(b.crops) do if crop:Finish()>0 then meshes=meshes+1 end; if pause then pause() end end
        if b.earth:Finish()>0 then meshes=meshes+1 end
        if pause then pause() end
    end
end

-- 植被使用全局候选号确定随机数，卸载/逆向重载不改变树种或位置。
-- 外包圆对全解析线路/站场/保留街巷/附近真实农田候选检测。
local function hitsField(pos, radius)
    local fieldRadius = math.sqrt(27.65^2 + 36.65^2)
    for ix=math.floor((pos.x-radius-62)/68),math.ceil((pos.x+radius+62)/68) do
        for iz=math.floor((pos.z-radius-78)/86),math.ceil((pos.z+radius+78)/86) do
            local center = Vector3(ix*68+34,0,iz*86+43)
            if math.abs(pos.x-center.x)<27.5+radius and math.abs(pos.z-center.z)<36.5+radius
                and fieldAllowed(center,fieldRadius) then return true end
        end
    end
    return false
end

---@param owner Node
---@param first number
---@param last number
---@param pause fun()|nil
function Terrain.BuildTrees(owner, first, last, pause)
    local root = owner:CreateChild("Forest")
    local plants = Vegetation.NewBatch(root)
    local treeA, treeB = Vegetation.GetAsset("treeA"), Vegetation.GetAsset("treeB")
    local bush, grass = Vegetation.GetAsset("bush"), Vegetation.GetAsset("grass")
    local function clear(pos,radius)
        return Route.CanPlaceFootprint(pos,radius,30) and not inStationYard(pos,radius)
            and not nearSettlement(pos,radius) and not hitsField(pos,radius)
    end
    local baseSeed = (GameConfig.WorldStream and GameConfig.WorldStream.Seed) or 20261006
    for index=math.ceil((first-0.000001)/80),math.ceil((last-0.000001)/80)-1 do
        seed_ = (baseSeed + index*7919) % 2147483646 + 1
        local asset = index%3==0 and treeB or treeA
        if not asset then asset=treeA or treeB end
        if asset then
            local s = index*80 + 28
            local side = index%3==0 and 1 or -1
            local pos = Route.SampleOffset(s,side*range(42,175),0)
            local scale,radius = Vegetation.Measure(asset,range(7.2,10.2))
            if clear(pos,radius) then
                plants:Add(asset,pos,scale,range(0,360))
                for j=1,2 do
                    local small = j==1 and bush or grass
                    if small then
                        local smallScale,smallRadius = Vegetation.Measure(small,j==1 and range(.55,.80) or range(.22,.35))
                        local angle = range(0,math.pi*2)
                        local distance = radius+smallRadius+2.4
                        local nearby = Vector3(pos.x+math.cos(angle)*distance,0,pos.z+math.sin(angle)*distance)
                        if clear(nearby,smallRadius) then plants:Add(small,nearby,smallScale,range(0,360)) end
                    end
                end
            end
        end
        if pause then pause() end
    end
    plants:Finish()
end

---@param owner Node
---@param cellX number
---@param cellZ number
---@param size number
---@param pause fun()|nil
function Terrain.BuildCell(owner,cellX,cellZ,size,pause)
    Terrain.BuildFields(owner,cellX,cellZ,size,pause)
    if pause then pause() end
    Terrain.BuildHills(owner,cellX,cellZ,size,pause)
end

function Terrain.ForgetCell(cellX,cellZ)
    fieldData_[cellX.."_"..cellZ] = nil
end
function Terrain.ForgetStation(index)
    for i=#placementData_,1,-1 do
        if placementData_[i].stationIndex==index then table.remove(placementData_,i) end
    end
    for i=#paths_,1,-1 do
        if paths_[i].stationIndex==index then table.remove(paths_,i) end
    end
end
function Terrain.Shutdown()
    scene_ = nil
    placementData_,fields_,paths_,reservations_,fieldData_ = {},{},{},{},{}
end
function Terrain.GetPlacementData() return placementData_ end
function Terrain.GetFieldData()
    local out = {}
    for _, list in pairs(fieldData_) do for _, item in ipairs(list) do out[#out+1]=item end end
    return out
end
function Terrain.GetPathData() return paths_ end
return Terrain
