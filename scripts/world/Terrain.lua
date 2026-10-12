-- 开放约70km线路：站间地理地表/连续农田/远侧林丘；不改轨道高度或站台。
-- 基于3D scene scaffold，LightGroup/Zone归世界入口独占；本模块只建局部地表。
local Route = require "world.Route"
local World = require "world.WorldMaterials"
local Vegetation = require "world.Vegetation"
local Landscape = require "world.Landscape"
local Landmarks = require "world.Landmarks"
local GameConfig = require "config.GameConfig"
local Terrain = {}
---@type table<string, table[]>
local fieldData_ = {}
---@type table<string, Material>
local solidMaterials_ = {}
---@type table<string, table>
local cellData_ = {}
---@type number[]
local bounds_ = {}
---@type table<string, RailwayPlantAsset>
local forestAssets_ = {}
-- 只包装现有树的最低LOD：借用已加载VB/IB及两材质，不Clone整模型/烘焙/上传新顶点。
-- Tree02=999三角，Tree21=429三角；每terrain cell最多16实例，按64m空间分批。
local function getForestAsset(kind)
    if forestAssets_[kind] then return forestAssets_[kind] end
    local asset=Vegetation.GetAsset(kind)
    if not asset then return nil end
    local model=Model()
    model:SetNumGeometries(asset.model.numGeometries)
    local triangles=0
    for slot=0,asset.model.numGeometries-1 do
        local last=asset.model:GetNumGeometryLodLevels(slot)-1
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
    print(string.format("[Terrain] 共享森林最低LOD %s：%.0f三角/2原材质，无阴影/物理，draw=1600m",asset.name,triangles))
    return forest
end

local function solid(color,metallic,roughness)
    local key=string.format("%.3f_%.3f_%.3f_%.3f_%.3f",color.r,color.g,color.b,metallic or 0,roughness or .99)
    if not solidMaterials_[key] then solidMaterials_[key]=World.Solid(color,metallic,roughness) end
    return solidMaterials_[key]
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
    Landmarks.Init()
    Landscape.Init()
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
---@param owner Node
function Terrain.BuildGround(owner)
    local minX,maxX,minZ,maxZ=routeBounds()
    -- 仅铁路谷地挖空保底，其他城市/站场/未加载的远景仍有Y=-.25地面。
    local ground=World.NewBatch(owner:CreateChild("远景土地保底_桥谷真裁切"),solid(Color(.31,.40,.29),0,.99),false,30)
    local pieces=Landmarks.ClipGround({Vector3(minX-3000,-.25,minZ-3000),Vector3(minX-3000,-.25,maxZ+3000),
        Vector3(maxX+3000,-.25,maxZ+3000),Vector3(maxX+3000,-.25,minZ-3000)})
    for _,piece in ipairs(pieces) do
        for i=2,#piece-1 do ground:AddTri(piece[1],piece[i],piece[i+1]) end
    end
    ground:Finish()
    print("[Terrain] 路基/轨面不变；站场/街块Y=0；保底Y=-.25仅对铁路深谷真cut，不盖桥下河流")
end

-- 空间格80m地表：城/工业硬地、北方农田土底、榆岑谷地绿、镜澜砂砾岸。
-- 分区、站场及城市街块统一Y=0，使用XZ子面裁剪去重；空街区回到土色。
-- 过渡色只量化到0.04色阶，避免每80m新建一种材质，单个cell一般1..2种。
local function buildLandCover(owner,cellX,cellZ,size,pause)
    ---@type table<string, RailwayBatch>
    local batches={}
    local data={materials=0,materialBatches=0,vertices=0,landArea=0,hills=0,hillTrees=0,maxHillHeight=0,materialKeys={}}
    cellData_[cellX.."_"..cellZ]=data
    local step=80
    for x=cellX*size,(cellX+1)*size-.001,step do
        for z=cellZ*size,(cellZ+1)*size-.001,step do
            local w,d=math.min(step,(cellX+1)*size-x),math.min(step,(cellZ+1)*size-z)
            local center=Vector3(x+w*.5,0,z+d*.5)
            local distance,s=Route.DistanceTo(center)
            if distance<1300 then
                local pieces=Landscape.ClipUnclaimedGround({Vector3(x,0,z),Vector3(x,0,z+d),Vector3(x+w,0,z+d),Vector3(x+w,0,z)})
                if #pieces>0 then
                    local color=Landscape.InCity(center,0) and Color(.42,.39,.32) or Landscape.GetGroundColor(s)
                    local r,g,b=math.floor(color.r*25+.5)/25,math.floor(color.g*25+.5)/25,math.floor(color.b*25+.5)/25
                    local key=string.format("%.2f_%.2f_%.2f",r,g,b)
                    if not batches[key] then
                        local material=solid(Color(r,g,b),0,.99)
                        batches[key]=World.NewBatch(owner:CreateChild("地理地表_"..key),material,false,16)
                        data.materialKeys[tostring(material)]=true
                    end
                    for _,piece in ipairs(pieces) do
                        for i=2,#piece-1 do
                            batches[key]:AddTri(piece[1],piece[i],piece[i+1])
                            data.landArea=data.landArea+math.abs((piece[i]-piece[1]):CrossProduct(piece[i+1]-piece[1]).y)*.5
                        end
                    end
                end
            end
            pauseOnce(pause)
        end
    end
    for _,batch in pairs(batches) do
        data.vertices=data.vertices+batch:Finish()
        data.materials=data.materials+1; data.materialBatches=data.materialBatches+1
        pauseOnce(pause)
    end
end

-- 林丘净空（XZ）：全股道 -- >=310m平坦谷地 -- 80m网格缓坡 -- 1100m远景渐落。
-- 只在榆岑真实区域起伏；高度按同一世界函数，不再sin(pi*s/800)重复山丘。
-- 城市/灌渠/田地优先；不挖铁路、不碰车高，块边界采样一致。
function Terrain.BuildHills(owner,cellX,cellZ,cellSize,pause)
    local size=cellSize or 160
    local root=owner:CreateChild("榆岑远侧低多边形林丘")
    local function height(x,z)
        local pos=Vector3(x,0,z)
        -- 既有林丘高度也遵守桥隧/大山保留区，不让其任一顶点填入真实隧道或河谷。
        if Landmarks.Reserves(pos,80) then return .004 end
        local distance,s=Route.DistanceTo(pos)
        local region=Landscape.GetRegionAt(s)
        if region.index~=4 then return .004 end
        local cityFade=smooth(Landscape.CityDistance(pos)/130)
        local inner=smooth((distance-310)/210)
        local outer=1-smooth((distance-1060)/190)
        local geographic=smooth((s-region.first)/1500)*(1-smooth((s-region.last+1500)/1500))
        local waves=.58+.25*math.sin(x/280+z/400)+.17*math.sin(x/530-z/220)
        return .004+inner*outer*cityFade*geographic*(58+10*math.sin(s/2300))*waves
    end
    local function normal(x,z)
        return Vector3(height(x-2,z)-height(x+2,z),4,height(x,z-2)-height(x,z+2)):Normalized()
    end
    local batch=World.NewBatch(root:CreateChild("林丘坡面"),solid(Color(.27,.37,.25),0,.99),false,30)
    local step=80
    local hillCells,maxHeight=0,0
    local surfaces={} ---@type table[]
    for x=cellX*size,(cellX+1)*size-.001,step do
        for z=cellZ*size,(cellZ+1)*size-.001,step do
            local w,d=math.min(step,(cellX+1)*size-x),math.min(step,(cellZ+1)*size-z)
            local center=Vector3(x+w*.5,0,z+d*.5)
            local r=math.sqrt(w*w+d*d)*.5
            local distance,s=Route.DistanceTo(center)
            if Landscape.GetRegionAt(s).index==4 and distance>310+r and distance<1230
                and Landscape.CanPlace(center,r,310) and not Landscape.ReservesNature(center,r)
                and not Landscape.FieldAllowed(center,r) then
                local a,b,c,e=Vector3(x,height(x,z),z),Vector3(x,height(x,z+d),z+d),
                    Vector3(x+w,height(x+w,z+d),z+d),Vector3(x+w,height(x+w,z),z)
                local function vertex(p) batch:Vertex(p,Vector2(p.x/30,p.z/30),normal(p.x,p.z)) end
                vertex(a); vertex(b); vertex(c); vertex(a); vertex(c); vertex(e)
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
        data.materialKeys[tostring(solid(Color(.27,.37,.25),0,.99))]=true
    end
    -- 林簇只种在实际提交的80m坡面内；两三角插值与mesh完全一致。
    -- 半开cell拥有树根；每cell最多16棵，冠幅避开田块、灌渠、城市和桥隧保留区。
    local plants=Vegetation.NewBatch(root:CreateChild("共享成簇山林"))
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
                local asset=getForestAsset((cellX+cellZ+j)%3==0 and "treeB" or "treeA")
                if asset then
                    local scale,r=Vegetation.Measure(asset,18+(cellX*7+cellZ*11+j*3)%7)
                    if y>1 and Landscape.CanPlace(groundPos,r,310)
                        and not Landscape.ReservesNature(groundPos,r)
                        and not Landscape.FieldAllowed(groundPos,r) then
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
    return vertices+Landscape.BuildChunk(owner,first,last,pause)
end
function Terrain.ForgetScenery(first,last)
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
    ---@type Material[]
    local materials={
        World.Textured("GeographicCropGreen","Textures/Railway/grass.png",Color(.43,.63,.30),.99),
        solid(Color(.66,.55,.29),0,.99),
        solid(Color(.48,.34,.23),0,.99),
    }
    local soil=solid(Color(.34,.29,.20),0,.99)
    ---@type table<string, {crops:RailwayBatch[],earth:RailwayBatch}>
    local chunks={}
    local size=cellSize or 160
    local minX,maxX,minZ,maxZ=cellX*size,(cellX+1)*size,cellZ*size,(cellZ+1)*size
    local cellFields={}
    fieldData_[cellX.."_"..cellZ]=cellFields
    for ix=math.ceil((minX-FIELD_X*.5)/FIELD_X),math.ceil((maxX-FIELD_X*.5)/FIELD_X)-1 do
        for iz=math.ceil((minZ-FIELD_Z*.5)/FIELD_Z),math.ceil((maxZ-FIELD_Z*.5)/FIELD_Z)-1 do
            local center=Vector3(ix*FIELD_X+FIELD_X*.5,0,iz*FIELD_Z+FIELD_Z*.5)
            if Landscape.FieldAllowed(center,FIELD_R) then
                local key=math.floor(center.x/320).."_"..math.floor(center.z/320)
                if not chunks[key] then
                    local node=root:CreateChild("Fields_"..key)
                    ---@type RailwayBatch[]
                    local crops={}
                    for i=1,3 do crops[i]=World.NewBatch(node:CreateChild("Crop"..i),materials[i],false,8) end
                    chunks[key]={crops=crops,earth=World.NewBatch(node:CreateChild("凸埂垄沟"),soil,false)}
                end
                local batch=chunks[key]
                -- 相邻条带的差异稳定；不是整片同色草地。
                local crop=assert(batch.crops[(ix+math.floor(iz/2)*2)%3+1])
                local x0,x1,z0,z1=center.x-FIELD_W*.5,center.x+FIELD_W*.5,center.z-FIELD_D*.5,center.z+FIELD_D*.5
                crop:AddQuad(Vector3(x0,.022,z0),Vector3(x0,.022,z1),Vector3(x1,.022,z1),Vector3(x1,.022,z0))
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
    for ix=math.floor((pos.x-radius-FIELD_W)/FIELD_X),math.ceil((pos.x+radius+FIELD_W)/FIELD_X) do
        for iz=math.floor((pos.z-radius-FIELD_D)/FIELD_Z),math.ceil((pos.z+radius+FIELD_D)/FIELD_Z) do
            local center=Vector3(ix*FIELD_X+FIELD_X*.5,0,iz*FIELD_Z+FIELD_Z*.5)
            if math.abs(pos.x-center.x)<FIELD_W*.5+1+radius and math.abs(pos.z-center.z)<FIELD_D*.5+1+radius
                and Landscape.FieldAllowed(center,FIELD_R) then return true end
        end
    end
    return false
end
---@param owner Node
---@param first number
---@param last number
---@param pause? fun()
function Terrain.BuildTrees(owner,first,last,pause)
    local plants=Vegetation.NewBatch(owner:CreateChild("近轨低频树"))
    local treeA,treeB=Vegetation.GetAsset("treeA"),Vegetation.GetAsset("treeB")
    local seed=(GameConfig.WorldStream and GameConfig.WorldStream.Seed) or 20261006
    for index=math.ceil((clampS(first)-.000001)/160),math.ceil((clampS(last)-.000001)/160)-1 do
        local asset=index%3==0 and treeB or treeA
        if asset then
            local s=clampS(index*160+45)
            local count=Landmarks.GetEnvironmentAt(s)=="forest" and 4 or 1
            for j=1,count do
                local value=((seed+index*7919+j*104729)*48271%2147483647)/2147483647
                local side=(index+j)%2==0 and 1 or -1
                local pos=Route.SampleOffset(clampS(s+(j-1)*21),side*(49+value*30+(j-1)*9),0)
                local scale,r=Vegetation.Measure(asset,6.5+value*2)
                if Landscape.CanPlace(pos,r,30) and not Landscape.ReservesNature(pos,r) and not hitsField(pos,r) then
                    plants:Add(asset,pos,scale,value*360)
                end
                pauseOnce(pause)
            end
        end
        pauseOnce(pause)
    end
    plants:Finish()
    for _,group in pairs(plants.groups) do group.castShadows=false; group.drawDistance=400 end
end
function Terrain.BuildCell(owner,cellX,cellZ,size,pause)
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
