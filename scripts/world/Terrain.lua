-- 开放五站线路：站间地理地表/连续农田/远侧林丘；不改轨道高度或站台。
-- 基于3D scene scaffold，LightGroup/Zone归世界入口独占；本模块只建局部地表。
local Route = require "world.Route"
local World = require "world.WorldMaterials"
local GroundSurface = require "world.GroundSurface"
local Vegetation = require "world.Vegetation"
local Planting = require "world.CorridorPlanting"
local Landscape = require "world.Landscape"
local Landmarks = require "world.Landmarks"
local RoadCorridor = require "world.RoadCorridor"
local RailwayScenery = require "world.RailwayScenery"
local GameConfig = require "config.GameConfig"
local Mountain = require "world.MountainProfile"
local Terrain = {}
---@type table<string, table[]>
local fieldData_ = {}
---@type table<string, table>
local cellData_ = {}
---@type number[]
local bounds_ = {}
---@type table<string, RailwayPlantAsset>
local forestAssets_ = {}
-- 画质档下发的密度系数（1.0 = 标准）。由 main.SetRenderQuality 写入。
local quality_ = { vegetationScale = 1.0, treeDistance = 430.0, hillAmp = 1.0, treeShadows = true }
---@type table<string, number[]|boolean>
local hillSurfaceCache_={}
local hillCacheCount_=0

---@param preset VisualQualityPreset
function Terrain.SetQuality(preset)
    quality_.vegetationScale = preset.vegetationScale
    quality_.treeDistance = preset.treeDistance
    quality_.hillAmp = preset.hillAmp
    quality_.treeShadows = preset.shadows
    hillSurfaceCache_,hillCacheCount_={},0
    print(string.format("[Terrain] 画质密度 植被×%.2f 树距%.0fm 山丘×%.2f 树影%s",
        quality_.vegetationScale, quality_.treeDistance, quality_.hillAmp,
        quality_.treeShadows and "开" or "关"))
end
function Terrain.GetHillAmplitude() return quality_.hillAmp end
function Terrain.GetVegetationScale() return quality_.vegetationScale end
function Terrain.GetTreeDistance() return quality_.treeDistance end
function Terrain.GetTreeShadows() return quality_.treeShadows end
-- 只包装现有树的低LOD：借用已加载VB/IB及两材质，不Clone整模型/烘焙/上传新顶点。
-- 倒数第二级保留冠叶面积，按64m空间分批；丘陵cell仍最多16实例。
local function getForestAsset(kind)
    if forestAssets_[kind] then return forestAssets_[kind] end
    local asset=Vegetation.GetAsset(kind)
    if not asset then return nil end
    local model=Model()
    model:SetNumGeometries(asset.model.numGeometries)
    local triangles=0
    for slot=0,asset.model.numGeometries-1 do
        -- 倒数第二LOD保留成片叶卡。最低LOD虽有叶槽，但400m掠视时冠叶过稀，
        -- 叠加稀冠树形会读成枯树。仍只借用源VB/IB，不复制/上传顶点。
        local last=math.max(0,asset.model:GetNumGeometryLodLevels(slot)-2)
        local source=asset.model:GetGeometry(slot,last)
        local vertexBuffer,indexBuffer=source:GetVertexBuffer(0),source:GetIndexBuffer()
        -- Geometry强持有原VB/IB，不调用无法从Lua table转换的SetVertexBuffers。
        local geometry=Geometry()
        geometry:SetVertexBuffer(0,vertexBuffer); geometry:SetIndexBuffer(indexBuffer)
        geometry:SetDrawRange(source.primitiveType,source.indexStart,source.indexCount,source.vertexStart,source.vertexCount)
        model:SetGeometry(slot,0,geometry)
        model:SetGeometryCenter(slot,asset.model:GetGeometryCenter(slot))
        triangles=triangles+source.indexCount/3
    end
    model.boundingBox=asset.bounds
    ---@type RailwayPlantAsset
    local forest={name="ForestLOD_"..asset.name,model=model,materials=asset.materials,bounds=asset.bounds,
        drawDistance=1600,shadowDistance=0,shadows=false}
    forestAssets_[kind]=forest
    print(string.format("[Terrain] 共享森林低LOD(冠叶保留) %s：%.0f三角/2原材质，无阴影/物理，draw=1600m",asset.name,triangles))
    return forest
end

local function pauseOnce(pause) if pause then pause() end end
local function clampS(s) return math.max(0,math.min(Route.GetLength(),s)) end
local function smooth(v)
    local t=math.max(0,math.min(1,v))
    return t*t*(3-2*t)
end
local function routeBounds()
    if #bounds_==4 then return bounds_[1],bounds_[2],bounds_[3],bounds_[4] end
    local minX,maxX,minZ,maxZ=math.huge,-math.huge,math.huge,-math.huge
    for _,p in ipairs(Route.GetPoints()) do
        minX,maxX=math.min(minX,p.pos.x),math.max(maxX,p.pos.x)
        minZ,maxZ=math.min(minZ,p.pos.z),math.max(maxZ,p.pos.z)
    end
    if minX==math.huge then return 0,0,0,0 end
    bounds_={minX,maxX,minZ,maxZ}
    return minX,maxX,minZ,maxZ
end
function Terrain.Init()
    bounds_,fieldData_,cellData_={},{},{}
    hillSurfaceCache_,hillCacheCount_={},0
    Planting.ResetCorridor()
    Landmarks.Init()
    Landscape.SetCorridorExclusion(nil)
    Landscape.Init()
    RoadCorridor.Init()
    RailwayScenery.Init()
    Landscape.SetCorridorExclusion(function(pos,radius,purpose)
        return RoadCorridor.IsExcluded(pos,radius,purpose) or RailwayScenery.IsExcluded(pos,radius,purpose)
    end)
end
---@param scene Scene
---@param initialS? number
function Terrain.Build(scene,initialS)
    Terrain.Init()
    local root=scene:CreateChild("TerrainPreview")
    Terrain.BuildGround(root)
    local pos=Route.Sample(initialS or 0)
    Terrain.BuildCell(root:CreateChild("InitialCell"),math.floor(pos.x/160),math.floor(pos.z/160),160)
    return root
end
---@type table<number, number>
local REGION_HILL_SCALE = { 0.62, 0.48, 0.55, 1.0, 0.70, 0.52 }
local function hillHeight(x,z)
    local pos=Vector3(x,0,z)
    if Landmarks.Reserves(pos,80) then return .004 end
    local distance,s=Route.DistanceTo(pos)
    local region=Landscape.GetRegionAt(s)
    local scale=REGION_HILL_SCALE[region.index] or .3
    local cityFade=smooth(Landscape.CityDistance(pos)/130)
    local roadFade=smooth((RoadCorridor.DistanceTo(pos)-20)/160)
    local inner=smooth((distance-310)/210)
    local outer=1-smooth((distance-1060)/190)
    local geographic=smooth((s-region.first)/1500)*(1-smooth((s-region.last+1500)/1500))
    local waves=.58+.25*math.sin(x/280+z/400)+.17*math.sin(x/530-z/220)
    return .004+inner*outer*cityFade*roadFade*geographic*(58+10*math.sin(s/2300))*scale*waves*Terrain.GetHillAmplitude()
end
local function hillAllowed(x,z,w,d)
    local center=Vector3(x+w*.5,0,z+d*.5)
    local r=math.sqrt(w*w+d*d)*.5
    local distance,s=Route.DistanceTo(center)
    return not Mountain.IsActiveAt(s) and (REGION_HILL_SCALE[Landscape.GetRegionAt(s).index] or 0)>0
        and distance>310+r and distance<1230 and Landscape.CanPlace(center,r,310)
        and not Landscape.ReservesNature(center,r) and not Landscape.FieldAllowed(center,r)
end
---@param x number
---@param z number
---@return number
function Terrain.GetGroundHeight(x,z)
    local pos=Vector3(x,0,z)
    local distance,s=Route.DistanceTo(pos)
    if Mountain.IsActiveAt(s) then return Mountain.GetGroundHeight(x,z) end
    if distance<=310 then return 0 end
    -- 与BuildHills完全相同的80m世界网格/三角划分，绝不把远林种在坡面下的Y=0。
    local x0,z0=math.floor(x/80)*80,math.floor(z/80)*80
    local key=x0.."_"..z0
    if hillSurfaceCache_[key]==nil then
        if hillCacheCount_>=4096 then hillSurfaceCache_,hillCacheCount_={},0 end
        hillSurfaceCache_[key]=hillAllowed(x0,z0,80,80) and
            {hillHeight(x0,z0),hillHeight(x0,z0+80),hillHeight(x0+80,z0+80),hillHeight(x0+80,z0)} or false
        hillCacheCount_=hillCacheCount_+1
    end
    local heights=hillSurfaceCache_[key]
    if type(heights)~="table" then return 0 end
    local u,v=(x-x0)/80,(z-z0)/80
    return v>=u and heights[1]*(1-v)+heights[2]*(v-u)+heights[3]*u
        or heights[1]*(1-u)+heights[3]*v+heights[4]*(u-v)
end
Terrain.GetHeight=Terrain.GetGroundHeight

function Terrain.BuildGround(owner)
    if GameConfig.MountainTerrain and not GameConfig.MountainTerrain.First then
        -- 全山地图没有覆盖全图的Y=0巨平面。
        print("[Terrain] 山地地表由20m连续高程网格按空间cell流式加载")
        return
    end
    local minX,maxX,minZ,maxZ=routeBounds()
    local prefixEnd=GameConfig.MountainTerrain and GameConfig.MountainTerrain.First
    if prefixEnd then
        minX,maxX,minZ,maxZ=math.huge,-math.huge,math.huge,-math.huge
        for _,p in ipairs(Route.GetPoints()) do
            if p.s<=prefixEnd then
                minX,maxX=math.min(minX,p.pos.x),math.max(maxX,p.pos.x)
                minZ,maxZ=math.min(minZ,p.pos.z),math.max(maxZ,p.pos.z)
            end
        end
    end
    -- 仅铁路谷地挖空保底，其他城市/站场/未加载的远景仍有Y=-.25地面。
    -- 远景保底也贴草地纹理（大 tile），让地平线外的地面不出现纯色平板。
    local ground=World.NewBatch(owner:CreateChild("远景土地保底_桥谷真裁切"),
        World.Grassland(),false,10)
    local pieces=Landmarks.ClipGround({Vector3(minX-3000,-.25,minZ-3000),Vector3(minX-3000,-.25,maxZ+3000),
        Vector3(maxX+3000,-.25,maxZ+3000),Vector3(maxX+3000,-.25,minZ-3000)})
    for _,piece in ipairs(pieces) do
        for i=2,#piece-1 do ground:AddTriPlanar(piece[1],piece[i],piece[i+1],10) end
    end
    ground:Finish()
    print("[Terrain] 路基/轨面不变；站场/街块Y=0；保底Y=-.25仅对铁路深谷真cut，不盖桥下河流")
end

-- 地貌分区 -> 地表纹理材质 + 平铺密度（米/次）。纹理沿世界坐标连续平铺，
-- 取代旧的量化纯色，消除"每 80m 一块纯色"的色块观感。
-- 铁路走廊两侧以草地为主（贴近参考图），只有真正落在城市街块内的地面才用硬地。
---@param center Vector3
---@param s number
---@return Material, number
local function groundMaterial(center, s)
    local region = Landscape.GetRegionAt(s)
    local theme = region.theme
    -- 仅城市街块内部铺硬地；街区外的空地仍是草/土，避免大面积灰色。
    if theme == "urban" or theme == "industry" then
        if Landscape.InCity(center, 0) then return World.UrbanGround(), 14.0 end
        return World.Grassland(), 16.0
    end
    if theme == "fields" then return World.Cropland(), 26.0 end
    if theme == "water" then return World.Grassland(), 20.0 end
    if theme == "village" then return World.Grassland(), 18.0 end
    return World.Grassland(), 18.0
end

-- 空间格80m地表：城/工业硬地、北方农田土底、榆岑谷地绿、镜澜砂砾岸。
-- 分区、站场及城市街块统一Y=0，使用XZ子面裁剪去重；空街区回到土色。
-- 地表材质按地貌分区选择，UV 走世界空间平面投影，纹理密度稳定不随格变化。
local function buildLandCover(owner,cellX,cellZ,size,pause)
    local surface=GroundSurface.New(owner,World.Grassland())
    local data={materials=0,materialBatches=0,vertices=0,landArea=0,hills=0,hillTrees=0,maxHillHeight=0,materialKeys={}}
    cellData_[cellX.."_"..cellZ]=data
    local step=80
    for x=cellX*size,(cellX+1)*size-.001,step do
        for z=cellZ*size,(cellZ+1)*size-.001,step do
            local w,d=math.min(step,(cellX+1)*size-x),math.min(step,(cellZ+1)*size-z)
            local center=Vector3(x+w*.5,0,z+d*.5)
            local distance,s=Route.DistanceTo(center)
            if distance<1300 and not Mountain.IsActiveAt(s) then
                local pieces=Landscape.ClipUnclaimedGround({Vector3(x,0,z),Vector3(x,0,z+d),Vector3(x+w,0,z+d),Vector3(x+w,0,z)})
                if #pieces>0 then
                    local material,tile=groundMaterial(center,s)
                    surface:SetBase(material,tile)
                    data.materialKeys[tostring(material)]=true
                    for _,piece in ipairs(pieces) do
                        for i=2,#piece-1 do
                            surface:AddTri(piece[1],piece[i],piece[i+1],material~=World.UrbanGround(),pause)
                            local origin=assert(piece[1])
                            local nextPoint=assert(piece[i])
                            local lastPoint=assert(piece[i+1])
                            local edge=nextPoint-origin
                            data.landArea=data.landArea+math.abs(edge:CrossProduct(lastPoint-origin).y)*.5
                        end
                    end
                end
            end
            pauseOnce(pause)
        end
    end
    local vertices,batches=surface:Finish(pause)
    data.vertices=data.vertices+vertices
    data.materials=data.materials+batches;data.materialBatches=data.materialBatches+batches
end

-- 丘陵起伏：全股道 -- >=310m平坦谷地 -- 80m网格缓坡 -- 1100m远景渐落。
-- 榆岑谷地起伏最大（真实山林），其余分区给较缓的滚动丘陵，
-- 让地平线有层次、不再是一条平直的地面线。城市/灌渠/田地优先。
-- 高度按同一世界函数，块边界采样一致；amp 由画质档下发。
-- 每个分区独立的高度尺度：index 4（榆岑）为大山，其余为缓丘。
-- 参考图铁路两侧有明显起伏，缓丘尺度不能太小，否则读成大平原。
function Terrain.BuildHills(owner,cellX,cellZ,cellSize,pause)
    local size=cellSize or 160
    local root=owner:CreateChild("远侧丘陵与山林")
    local height=hillHeight
    local hillsMaterial=World.Grassland()
    local batch=World.NewBatch(root:CreateChild("丘陵坡面"),hillsMaterial,false,7)
    local step=80
    local hillCells,maxHeight=0,0
    local surfaces={} ---@type table[]
    for x=cellX*size,(cellX+1)*size-.001,step do
        for z=cellZ*size,(cellZ+1)*size-.001,step do
            local w,d=math.min(step,(cellX+1)*size-x),math.min(step,(cellZ+1)*size-z)
            local center=Vector3(x+w*.5,0,z+d*.5)
            local r=math.sqrt(w*w+d*d)*.5
            local distance,s=Route.DistanceTo(center)
            if hillAllowed(x,z,w,d) then
                local a,b,c,e=Vector3(x,height(x,z),z),Vector3(x,height(x,z+d),z+d),
                    Vector3(x+w,height(x+w,z+d),z+d),Vector3(x+w,height(x+w,z),z)
                -- 平面投影 UV：山坡纹理沿世界坐标连续，不随坡度拉伸。
                batch:AddTriPlanar(a,b,c,7)
                batch:AddTriPlanar(a,c,e,7)
                surfaces[#surfaces+1]={x=x,z=z,w=w,d=d,a=a.y,b=b.y,c=c.y,e=e.y}
                hillCells=hillCells+1
                maxHeight=math.max(maxHeight,a.y,b.y,c.y,e.y)
            end
            pauseOnce(pause)
        end
    end
    local vertices=batch:Finish()
    local data=cellData_[cellX.."_"..cellZ]
    if data and vertices>0 then
        data.vertices=data.vertices+vertices; data.materialBatches=data.materialBatches+1; data.materials=data.materials+1; data.hills=hillCells
        data.maxHillHeight=maxHeight
        data.materialKeys[tostring(hillsMaterial)]=true
    end
    -- 林簇只种在实际提交的80m坡面内；两三角插值与mesh完全一致。
    -- 半开cell拥有树根；每cell最多16棵，冠幅避开田块、灌渠、城市和桥隧保留区。
    ---@type RailwayPlantBatch
    local plants=Vegetation.NewBatch(root:CreateChild("共享成簇山林"))
    ---@type string[]
    local hillKinds={"treeA","treeA","treeA","treeB"}
    local planted=0
    for _,surface in ipairs(surfaces) do
        for j=1,4 do
            if planted<16 then
                local u=(j-1)%2==0 and .35 or .60
                local v=j<=2 and .34 or .59
                local x,z=surface.x+surface.w*u,surface.z+surface.d*v
                local y=v>=u and surface.a*(1-v)+surface.b*(v-u)+surface.c*u
                    or surface.a*(1-u)+surface.c*v+surface.e*(u-v)
                local groundPos=Vector3(x,0,z)
                local asset=getForestAsset(hillKinds[(cellX*3+cellZ*5+j)%#hillKinds+1])
                if asset then
                    local scale,r=Vegetation.Measure(asset,18+(cellX*7+cellZ*11+j*3)%7)
                    if y>1 and Landscape.CanPlace(groundPos,r,310)
                        and not Landscape.ReservesNature(groundPos,r)
                        and not Landscape.FieldAllowed(groundPos,r)
                        and not Landmarks.InWater(groundPos,r) then
                        plants:Add(asset,Vector3(x,y,z),scale,(cellX*71+cellZ*43+j*59)%360)
                        planted=planted+1
                    end
                end
            end
            pauseOnce(pause)
        end
    end
    local count,groups=plants:Finish()
    if data then
        data.hillTrees=data.hillTrees+count
        data.materialBatches=data.materialBatches+groups*2
    end
    pauseOnce(pause)
end
---@param owner Node
---@param station table
---@param pause? fun()
function Terrain.BuildCity(owner,station,pause) Landscape.BuildCity(owner,station,pause) end
---@param kind string
---@param definition RailwayLandscapeAssetDefinition
function Terrain.SetBuildingAsset(kind,definition) Landscape.SetBuildingAsset(kind,definition) end
---@param owner Node
---@param first number
---@param last number
---@param pause? fun()
function Terrain.BuildScenery(owner,first,last,pause)
    local vertices=Landmarks.BuildChunk(owner,first,last,pause)
    vertices=vertices+RoadCorridor.BuildChunk(owner,first,last,pause)
    vertices=vertices+RailwayScenery.BuildChunk(owner,first,last,pause)
    return vertices+Landscape.BuildChunk(owner,first,last,pause)
end
--- 世界格唯一所有权的局部远地表，按最近真实线路投影决定高程，禁止回头弯叠层地毯。
--- 20m与near地形使用同一角点/对角线，仅降0.04m避免共面；每120m块1材质批。
function Terrain.BuildMountainBackdrop(owner,first,last,pause)
    if not Mountain.IsActiveAt(last) then return 0 end
    first=math.max(first,GameConfig.MountainTerrain.First or 0)
    local grass=World.NewBatch(owner:CreateChild("山地视野连续地表"),World.Grassland(),false,10)
    grass.geometry.viewMask=6;grass.geometry.drawDistance=2600
    local a,b=Route.Sample(first),Route.Sample(last)
    local middle=Route.Sample((first+last)*.5)
    local axis=Route.TangentAt((first+last)*.5)
    local tangent=Vector3(axis.x,0,axis.z):Normalized()
    local minX,maxX=math.min(a.x,b.x)-1450,math.max(a.x,b.x)+1450
    local minZ,maxZ=math.min(a.z,b.z)-1450,math.max(a.z,b.z)+1450
    local step=20
    local heights={}
    local function p(x,z)
        local key=x.."_"..z
        if heights[key]==nil then heights[key]=Mountain.DesignHeight(x,z)-.04 end
        return Vector3(x,heights[key],z)
    end
    -- 先用局部切线带宽排除远离本120m段的候选，再BVH精确投影；不是全图扫描。
    -- 最大曲率/横向1400m引起的沿程偏移由220m保守余量覆盖。
    local margin=(last-first)*.5+220
    for x=math.floor(minX/step)*step,maxX,step do
        local rowFirst,rowLast=minZ,maxZ
        if math.abs(tangent.z)>.08 then
            local dx=(x+step*.5-middle.x)*tangent.x
            local za,zb=middle.z+(-margin-dx)/tangent.z,middle.z+(margin-dx)/tangent.z
            rowFirst=math.max(minZ,math.min(za,zb)-step)
            rowLast=math.min(maxZ,math.max(za,zb)+step)
        end
        for z=math.floor(rowFirst/step)*step,rowLast,step do
            local center=Vector3(x+step*.5,0,z+step*.5)
            local along=(center-middle):DotProduct(tangent)
            if math.abs(along)<margin then
                local distance,s=Route.DistanceTo(center)
                -- 使用全线最近点的世界格归属，发夹内侧另一段不同高程也不会重复建面。
                if s>=first and s<last and distance<=1400 then
                    local aa,bb,cc,dd=p(x,z),p(x,z+step),p(x+step,z+step),p(x+step,z)
                    for _,tri in ipairs({{aa,bb,cc},{aa,cc,dd}}) do
                        for _,piece in ipairs(Landscape.ClipUnclaimedGround(tri)) do
                            for i=2,#piece-1 do grass:AddTriPlanar(piece[1],piece[i],piece[i+1],10) end
                        end
                    end
                end
            end
        end
        pauseOnce(pause)
    end
    return grass:Finish()
end

function Terrain.ForgetScenery(first,last)
    RoadCorridor.ForgetChunk(first,last)
    RailwayScenery.ForgetChunk(first,last)
    Landscape.ForgetChunk(first,last)
    Landmarks.ForgetChunk(first,last)
end
function Terrain.GetLandmarks() return Landmarks.GetDefinitions() end
function Terrain.GetEnvironmentAt(s) return Landmarks.GetEnvironmentAt(s) end
function Terrain.IsReserved(pos,radius) return Landscape.ReservesNature(pos,radius or 0) end
function Terrain.InStationYard(pos,radius) return Landscape.InStationYard(pos,radius or 0) end
function Terrain.GetThemeAt(s) return Landscape.ThemeAt(s) end

-- 全局田块网格：112x144m候选，100x130m真实田面+凸起埂+纵向垄沟。
-- 归属cell由中心半开边界唯一决定；较大格让远景读成连续农田而不是碎绿贴纸。
local FIELD_X,FIELD_Z,FIELD_W,FIELD_D=112,144,100.0,130.0
local FIELD_R=math.sqrt((FIELD_W*.5+1)^2+(FIELD_D*.5+1)^2)
function Terrain.BuildFields(owner,cellX,cellZ,cellSize,pause)
    local root=owner:CreateChild("连续农田田块")
    -- 三种作物条带用草地纹理染色：颜色差异保留"田垄分条"观感，
    -- 同时获得纹理细节，不再是三块纯色矩形。
    local grassTexture="Textures/Railway/grass.png"
    local grassNormal=nil
    ---@type Material[]
    local materials={
        World.Terrain("CropGreen",grassTexture,grassNormal,Color(.52,.68,.34),.97,9.0),
        World.Terrain("CropGold",grassTexture,grassNormal,Color(.74,.64,.34),.97,9.0),
        World.Terrain("CropBrown",grassTexture,grassNormal,Color(.56,.44,.28),.97,9.0),
    }
    local soil=World.Terrain("FieldSoil",grassTexture,grassNormal,Color(.40,.34,.24),.98,7.0)
    ---@type table<string, {crops:RailwayBatch[],earth:RailwayBatch}>
    local chunks={}
    local size=cellSize or 160
    local minX,maxX,minZ,maxZ=cellX*size,(cellX+1)*size,cellZ*size,(cellZ+1)*size
    local cellFields={}
    fieldData_[cellX.."_"..cellZ]=cellFields
    for ix=math.ceil((minX-FIELD_X*.5)/FIELD_X),math.ceil((maxX-FIELD_X*.5)/FIELD_X)-1 do
        for iz=math.ceil((minZ-FIELD_Z*.5)/FIELD_Z),math.ceil((maxZ-FIELD_Z*.5)/FIELD_Z)-1 do
            local center=Vector3(ix*FIELD_X+FIELD_X*.5,0,iz*FIELD_Z+FIELD_Z*.5)
            if Landscape.FieldAllowed(center,FIELD_R) and not Landmarks.InWater(center,FIELD_R) then
                local key=math.floor(center.x/320).."_"..math.floor(center.z/320)
                if not chunks[key] then
                    local node=root:CreateChild("Fields_"..key)
                    ---@type RailwayBatch[]
                    local crops={}
                    for i=1,3 do crops[i]=World.NewBatch(node:CreateChild("Crop"..i),materials[i],false,8) end
                    chunks[key]={crops=crops,earth=World.NewBatch(node:CreateChild("凸埂垄沟"),soil,false,7)}
                end
                local batch=chunks[key]
                -- 相邻条带的差异稳定；不是整片同色草地。
                local crop=assert(batch.crops[(ix+math.floor(iz/2)*2)%3+1])
                local x0,x1,z0,z1=center.x-FIELD_W*.5,center.x+FIELD_W*.5,center.z-FIELD_D*.5,center.z+FIELD_D*.5
                -- 世界空间平面投影 UV：田面纹理与相邻田块无缝衔接。
                local a,b,c,d=Vector3(x0,.022,z0),Vector3(x0,.022,z1),Vector3(x1,.022,z1),Vector3(x1,.022,z0)
                crop:AddTriPlanar(a,b,c,9); crop:AddTriPlanar(a,c,d,9)
                for _,x in ipairs({x0-.4,x1+.4}) do batch.earth:AddBox(Vector3(x,.08,center.z),Vector3(.8,.16,FIELD_D+1.6)) end
                for _,z in ipairs({z0-.4,z1+.4}) do batch.earth:AddBox(Vector3(center.x,.08,z),Vector3(FIELD_W,.16,.8)) end
                for x=x0+4,x1-2,7 do
                    batch.earth:AddQuad(Vector3(x,.028,z0+.8),Vector3(x,.028,z1-.8),Vector3(x+.32,.028,z1-.8),Vector3(x+.32,.028,z0+.8))
                end
                cellFields[#cellFields+1]={x=center.x,z=center.z,halfX=FIELD_W*.5+1,halfZ=FIELD_D*.5+1,radius=FIELD_R,clearance=Route.DistanceTo(center)-FIELD_R}
            end
            pauseOnce(pause)
        end
    end
    local data=cellData_[cellX.."_"..cellZ]
    for _,batch in pairs(chunks) do
        for i,crop in ipairs(batch.crops) do
            local n=crop:Finish()
            if data and n>0 then
                data.vertices=data.vertices+n; data.materialBatches=data.materialBatches+1; data.materials=data.materials+1
                data.materialKeys[tostring(materials[i])]=true
            end
            pauseOnce(pause)
        end
        local n=batch.earth:Finish()
        if data and n>0 then
            data.vertices=data.vertices+n; data.materialBatches=data.materialBatches+1; data.materials=data.materials+1
            data.materialKeys[tostring(soil)]=true
        end
        pauseOnce(pause)
    end
end
local function hitsField(pos,radius)
    local halfX,halfZ=FIELD_W*.5+1,FIELD_D*.5+1
    for ix=math.ceil((pos.x-radius-halfX-FIELD_X*.5)/FIELD_X),math.floor((pos.x+radius+halfX-FIELD_X*.5)/FIELD_X) do
        for iz=math.ceil((pos.z-radius-halfZ-FIELD_Z*.5)/FIELD_Z),math.floor((pos.z+radius+halfZ-FIELD_Z*.5)/FIELD_Z) do
            local center=Vector3(ix*FIELD_X+FIELD_X*.5,0,iz*FIELD_Z+FIELD_Z*.5)
            if Landscape.FieldAllowed(center,FIELD_R) then return true end
        end
    end
    return false
end
-- 同一解析判据供近线、背景林和CPU验收，拒绝原因不再被一个boolean吞掉。
function Terrain.GetPlantingBlockReason(pos,radius)
    local reason=Landscape.PlantingBlockReason(pos,radius)
    if reason then return reason end
    if hitsField(pos,radius) then return "field" end
    if Landmarks.InWater(pos,radius) then return "water" end
    return nil
end
---@param owner Node
---@param first number
---@param last number
---@param pause? fun()
---@param layer? string near/middle/distant；nil保留旧整块调用接口。
function Terrain.BuildTrees(owner,first,last,pause,layer)
    return Planting.BuildCorridor(owner,clampS(first),clampS(last),{
        density=Terrain.GetVegetationScale(),treeDistance=Terrain.GetTreeDistance(),
        shadows=Terrain.GetTreeShadows(),ground=Terrain.GetGroundHeight,
        blocked=Terrain.GetPlantingBlockReason,forest=getForestAsset,
    },pause,layer)
end
function Terrain.ForgetTrees(first,last,layer) Planting.ForgetCorridor(first,last,layer) end
function Terrain.GetPlantingStats() return Planting.GetCorridorStats() end
--- 山地图唯一流式地表；固定20m世界格，边界与GetGroundHeight使用同一三角划分。
local function buildMountainCell(owner,cellX,cellZ,size,pause)
    local data=cellData_[cellX.."_"..cellZ] or {materials=0,materialBatches=0,vertices=0,landArea=0,hills=0,hillTrees=0,maxHillHeight=0,materialKeys={}}
    data.materials=data.materials+1;data.materialBatches=data.materialBatches+1
    cellData_[cellX.."_"..cellZ]=data
    local grassMaterial=World.Grassland()
    local grass=GroundSurface.New(owner:CreateChild("凌岳高原连续山地"),grassMaterial)
    data.materialKeys[tostring(grassMaterial)]=true
    local step=GameConfig.MountainTerrain.GridStep or 20
    local heights={}
    local function point(x,z)
        local key=x.."_"..z
        if heights[key]==nil then heights[key]=Mountain.DesignHeight(x,z) end
        return Vector3(x,heights[key],z)
    end
    for x=cellX*size,(cellX+1)*size-.001,step do
        for z=cellZ*size,(cellZ+1)*size-.001,step do
            local finishX,finishZ=math.min((cellX+1)*size,x+step),math.min((cellZ+1)*size,z+step)
            local a,b,c,d=point(x,z),point(x,finishZ),point(finishX,finishZ),point(finishX,z)
            local center=(a+c)*.5
            local _,s=Route.DistanceTo(center)
            local relief=math.max(a.y,b.y,c.y,d.y)-Route.HeightAt(s)
            local target=grass -- 连续统一材质避免离散格阈值在山腰形成锯齿分界。
            -- 精确裁去站场/街块/桥谷，非共面覆盖；保留原20m对角线以匹配地面采样。
            if Mountain.IsActiveAt(s) then
                for _,tri in ipairs({{a,b,c},{a,c,d}}) do
                    for _,piece in ipairs(Landscape.ClipUnclaimedGround(tri)) do
                        for i=2,#piece-1 do target:AddTri(piece[1],piece[i],piece[i+1],true,pause) end
                    end
                end
            end
            data.landArea=data.landArea+(finishX-x)*(finishZ-z)
            data.hills=data.hills+1
            data.maxHillHeight=math.max(data.maxHillHeight,relief)
            pauseOnce(pause)
        end
    end
    local vertices,batches=grass:Finish(pause)
    for _,batch in pairs(grass.batches) do batch.geometry.viewMask=6;batch.geometry.drawDistance=2400 end
    data.vertices=data.vertices+vertices
    data.materials=data.materials+batches-1;data.materialBatches=data.materialBatches+batches-1
    pauseOnce(pause)
end

function Terrain.BuildCell(owner,cellX,cellZ,size,pause)
    local cellSize=size or 160
    if GameConfig.MountainTerrain then
        local _,s=Route.DistanceTo(Vector3((cellX+.5)*cellSize,0,(cellZ+.5)*cellSize))
        local boundary=GameConfig.MountainTerrain.First
        if not boundary or s>boundary+cellSize*2 then
            buildMountainCell(owner,cellX,cellZ,cellSize,pause)
            return
        elseif s>boundary-cellSize*2 then
            -- 接续带cell同时按20/80m子格归属，避免一格中心决定整块地形。
            buildLandCover(owner,cellX,cellZ,cellSize,pause)
            buildMountainCell(owner,cellX,cellZ,cellSize,pause)
            return
        end
    end
    buildLandCover(owner,cellX,cellZ,size or 160,pause)
    Terrain.BuildFields(owner,cellX,cellZ,size,pause)
    Terrain.BuildHills(owner,cellX,cellZ,size,pause)
end
function Terrain.ForgetCell(cellX,cellZ)
    fieldData_[cellX.."_"..cellZ]=nil; cellData_[cellX.."_"..cellZ]=nil
end
function Terrain.ForgetStation(index) Landscape.ForgetStation(index) end
function Terrain.Shutdown()
    fieldData_,bounds_,cellData_={},{},{}
    hillSurfaceCache_,hillCacheCount_={},0
    Planting.ResetCorridor()
    RoadCorridor.Shutdown()
    RailwayScenery.Shutdown()
    Landscape.Shutdown()
    Landmarks.Shutdown()
end
function Terrain.GetPlacementData() return Landscape.GetPlacementData() end
function Terrain.GetPathData() return Landscape.GetPathData() end
function Terrain.GetFieldData()
    local result={}
    for _,items in pairs(fieldData_) do for _,item in ipairs(items) do result[#result+1]=item end end
    return result
end
function Terrain.GetLandscapeStats()
    local stats=Landscape.GetStats()
    stats.landmarks=Landmarks.GetStats()
    stats.roadCorridor=RoadCorridor.GetStats()
    stats.railwayScenery=RailwayScenery.GetStats()
    stats.planting=Terrain.GetPlantingStats()
    stats.loadedFields,stats.loadedCells,stats.loadedHillCells,stats.terrainMaterialBatches,stats.terrainLandArea=0,0,0,0,0
    stats.loadedHillTrees,stats.maxLoadedHillHeight=0,0
    for _,items in pairs(fieldData_) do stats.loadedFields=stats.loadedFields+#items; stats.loadedCells=stats.loadedCells+1 end
    for _,data in pairs(cellData_) do
        stats.loadedHillCells=stats.loadedHillCells+data.hills
        stats.loadedHillTrees=stats.loadedHillTrees+data.hillTrees
        stats.maxLoadedHillHeight=math.max(stats.maxLoadedHillHeight,data.maxHillHeight)
        stats.terrainMaterialBatches=stats.terrainMaterialBatches+data.materialBatches
        stats.terrainLandArea=stats.terrainLandArea+data.landArea
    end
    return stats
end
return Terrain
