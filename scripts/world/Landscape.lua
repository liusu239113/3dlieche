-- 开放长线路的地理分区，不循环轮播主题；基于3D场景脚手架，入口独占光照/Zone。
-- 净空示意（XZ整包络，地面铺装不是障碍物）：
-- 站侧线2=-10.8 | 岛台-8.9..-1.9 | 股道0=0 | 股道1=+5 | 上行台6.9..13.9
-- 景观外包圆到主线>=30m，故到任一上述股道>=19.2m（超过要求的16m）。
-- 站场硬地低于道床/月台；普通景观守包络，铁路桥隧交由Landmarks按真实沿线净空实现。
-- 保留区由全线解析投影和规划计算，不依赖流式加载/卸载顺序。
local Route = require "world.Route"
local World = require "world.WorldMaterials"
local Vegetation = require "world.Vegetation"
local Planting = require "world.CorridorPlanting"
local Landmarks = require "world.Landmarks"
local GameConfig = require "config.GameConfig"
local Mountain = require "world.MountainProfile"
local Landscape = {}
Landscape.TransitionLength = 1000
Landscape.ThemeLength = Landscape.TransitionLength -- 兼容旧字段：现在是过渡宽度，绝不是主题周期。
Landscape.SampleLength = 80 -- 仅几何块所有权步长，与地理分区无关。
Landscape.BatchCellSize = 320
Landscape.RailClearance = 30

---@class RailwayGeographicRegion
---@field index number
---@field first number
---@field last number
---@field name string
---@field theme string
---@field stationIndex number
---@field ground Color
---@type RailwayGeographicRegion[]
local regions_ = {}
---@class RailwayGroundCut
---@field points Vector3[]
---@field x0 number
---@field x1 number
---@field z0 number
---@field z1 number
---@type RailwayGroundCut[]
local groundCuts_ = {}
---@type table<number, number>
local industrySides_ = {}

---@class RailwayLandscapeAssetDefinition
---@field model string
---@field materials? string[]
---@field diffuse? string
---@field normal? string
---@class RailwayLandscapeAsset
---@field key string
---@field model Model
---@field materials Material[]
---@field bounds BoundingBox
---@class RailwayLandscapePlot
---@field along number
---@field lateral number
---@field width number
---@field depth number
---@field height number
---@field kind string
---@field variant number
---@field district string
---@field pitched boolean
---@class RailwayCityPlan
---@field station table
---@field origin Vector3
---@field tangent Vector3
---@field right Vector3
---@field yaw number
---@field plots RailwayLandscapePlot[]
---@field zones table[]
---@field style string
---@field ground Color
---@field groundZones table[]
---@field roads table[]
---@type RailwayCityPlan[]
local cities_ = {}
---@type table<number, table>
local cityData_ = {}
---@type table<string, table>
local chunkData_ = {}
---@type table<string, Material>
local solidMaterials_ = {}
---@type table<string, RailwayLandscapeAsset>
local assets_ = {}
---@type table<string, boolean>
local attempted_ = {}
---@type table<string, boolean>
local logged_ = {}
---@type table<string, RailwayLandscapeAssetDefinition>
local definitions_ = {
    residential = {
        model = "model/53b7b1c43a014392b3160d16892893c2/Meshes/53b7b1c43a014392b3160d16892893c2.mdl",
        materials = {"model/53b7b1c43a014392b3160d16892893c2/Materials/53b7b1c43a014392b3160d16892893c2_00_tripo_material_52daec93-fbdb-4de2-8907-f1ed02a39747.xml"},
        diffuse = "model/53b7b1c43a014392b3160d16892893c2/Textures/53b7b1c43a014392b3160d16892893c2_00_D.jpg",
        normal = "model/53b7b1c43a014392b3160d16892893c2/Textures/53b7b1c43a014392b3160d16892893c2_00_N.png",
    },
    warehouse = {
        model = "model/3b9e3d894594475abed30d7f58e67003/Meshes/3b9e3d894594475abed30d7f58e67003.mdl",
        materials = {"model/3b9e3d894594475abed30d7f58e67003/Materials/3b9e3d894594475abed30d7f58e67003_00_tripo_material_b92361d4-cf88-426b-82e7-e1b90ee51bfc.xml"},
        diffuse = "model/3b9e3d894594475abed30d7f58e67003/Textures/3b9e3d894594475abed30d7f58e67003_00_D.jpg",
        normal = "model/3b9e3d894594475abed30d7f58e67003/Textures/3b9e3d894594475abed30d7f58e67003_00_N.png",
    },
    residentialTower = {
        model = "model/4a6814a7-dedd-5062-b1c3-cefdd17665aa/Meshes/35a410a32def4781ab882d4bb83e9d57.mdl",
        diffuse = "model/4a6814a7-dedd-5062-b1c3-cefdd17665aa/Textures/35a410a32def4781ab882d4bb83e9d57_00_D.jpg",
        normal = "model/4a6814a7-dedd-5062-b1c3-cefdd17665aa/Textures/35a410a32def4781ab882d4bb83e9d57_00_N.jpg",
    },
    villa = {
        model = "model/2f05a71e-54ed-5b6c-9aac-68b5d08d53e5/Meshes/190292b84fa245ba95a803c04c592a0d.mdl",
        diffuse = "model/2f05a71e-54ed-5b6c-9aac-68b5d08d53e5/Textures/190292b84fa245ba95a803c04c592a0d_00_D.jpg",
        normal = "model/2f05a71e-54ed-5b6c-9aac-68b5d08d53e5/Textures/190292b84fa245ba95a803c04c592a0d_00_N.jpg",
    },
}
local themeNames_ = {urban="城市铁路走廊",village="乡村丘陵",forest="远侧林丘",fields="连续农田灌渠村",industry="工业仓储",water="江岸公路桥区"}
local styleNames_ = {"星汐：红砖老城、玻璃高楼与阶梯出城带", "岚港：青灰港务楼、长仓库与装卸街网", "榆岑：绿谷村落、低密山城街网", "镜澜：滨水白墙、青蓝商务天际线", "云湾：高密街区、百米高层与梯级入城带",
    "翠川：山麓田园与低层青瓦街坊","石门：灰石镇屋与岩岭门户","云脊：林业山城与木色坡顶","松岚：高地民居与观景街网","天池：湖盆终点城与临水客运枢纽"}
local displayNames_ = {"星汐总站","岚港站","榆岑站","镜澜站","云湾总站","翠川站","石门站","云脊站","松岚站","天池总站"}
local regionDefinitions_ = {
    {name="星汐城区铁路走廊",theme="urban",stationIndex=1,ground=Color(.35,.43,.34)},
    {name="翠川连续农田灌渠村",theme="fields",stationIndex=1,ground=Color(.35,.47,.27)},
    {name="岚港工业与仓储带",theme="industry",stationIndex=2,ground=Color(.36,.42,.38)},
    {name="榆岑乡村谷地与林丘",theme="village",stationIndex=3,ground=Color(.29,.44,.28)},
    {name="镜澜河岸与铁路深谷",theme="water",stationIndex=4,ground=Color(.35,.47,.39)},
    {name="云湾高密城市铁路走廊",theme="urban",stationIndex=5,ground=Color(.34,.41,.38)},
}

local function clampS(s) return math.max(0,math.min(Route.GetLength(),s)) end
local function smooth(v)
    local t=math.max(0,math.min(1,v))
    return t*t*(3-2*t)
end
local function makeRegions()
    local stations=Route.GetStations()
    local length=Route.GetLength()
    local s1=stations[1] and stations[1].s or length*.025
    local s2=stations[2] and stations[2].s or length*.270
    local s3=stations[3] and stations[3].s or length*.540
    local s4=stations[4] and stations[4].s or length*.735
    local s5=stations[5] and stations[5].s or length*.960
    -- 两个北方分区占完整站间，而不是五个800m小景的排列。
    local prefixEnd=GameConfig.MountainTerrain and GameConfig.MountainTerrain.First
    local ends={s1+(s2-s1)*.30,s2-(s2-s1)*.18,s2+(s3-s2)*.45,
        s3+(s4-s3)*.52,s4+(s5-s4)*.48,prefixEnd or length}
    regions_={}
    local first=0
    for i,definition in ipairs(regionDefinitions_) do
        local last=math.max(first,math.min(length,ends[i]))
        local mountainNames={"山麓门户与赤壁展线","青岚石门峡谷","双峡高桥与山腰回头","云脊长坡与雪线山口","高原湖盆与天路落坡","凌岳高原终点城"}
        local allMountain=GameConfig.MountainTerrain and not prefixEnd
        local name=allMountain and mountainNames[i] or definition.name
        local theme=allMountain and "forest" or definition.theme
        regions_[i]={index=i,first=first,last=last,name=name,theme=theme,
            stationIndex=definition.stationIndex,ground=definition.ground}
        first=last
    end
    if prefixEnd then
        for _,definition in ipairs(GameConfig.RouteRegions or {}) do
            assert(math.abs(definition.first-first)<.001,"[Landscape] 延伸地理区间不连续")
            regions_[#regions_+1]={index=#regions_+1,first=first,last=definition.last,
                name=definition.name,theme=definition.theme or "forest",stationIndex=definition.stationIndex,
                ground=Color(.29,.43,.31)}
            first=definition.last
        end
    end
end

local function hash(index, salt)
    local seed = (GameConfig.WorldStream and GameConfig.WorldStream.Seed) or 20261006
    return ((index * 7919 + salt * 104729 + seed) * 48271 % 2147483647) / 2147483647
end
local function solid(color, metallic, roughness)
    local key = string.format("%.3f_%.3f_%.3f_%.3f_%.3f",color.r,color.g,color.b,metallic or 0,roughness or .8)
    if not solidMaterials_[key] then solidMaterials_[key]=World.Solid(color,metallic,roughness) end
    return solidMaterials_[key]
end
local function pauseOnce(pause) if pause then pause() end end
local function at(city, along, lateral)
    return city.origin + city.tangent * along + city.right * lateral
end
local function radius(w,d,extra) return math.sqrt(w*w+d*d)*.5+(extra or 0) end

---@param s number
---@return RailwayGeographicRegion
function Landscape.GetRegionAt(s)
    if #regions_==0 then makeRegions() end
    local clamped=clampS(s)
    for _,region in ipairs(regions_) do if clamped<region.last then return region end end
    return assert(regions_[#regions_])
end
---@param s number
---@return string, number
function Landscape.ThemeAt(s)
    local region=Landscape.GetRegionAt(s)
    return region.theme,region.index
end
function Landscape.GetThemeAt(s) return Landscape.ThemeAt(s) end
-- 渐变只发生在相邻真实区域交界处，各1km；主题查询仍稳定返回区域主类型。
function Landscape.GetGroundColor(s)
    local region=Landscape.GetRegionAt(s)
    local half=Landscape.TransitionLength*.5
    for i=1,#regions_-1 do
        local left,right=assert(regions_[i]),assert(regions_[i+1])
        local edge=left.last
        if math.abs(clampS(s)-edge)<half then
            local t=smooth((clampS(s)-edge+half)/(2*half))
            return Color(left.ground.r*(1-t)+right.ground.r*t,left.ground.g*(1-t)+right.ground.g*t,left.ground.b*(1-t)+right.ground.b*t)
        end
    end
    return region.ground
end
-- 到主线30m保守覆盖两主股道和全站侧线：最差到-10.8仍19.2m。
-- 这比只对当前加载RailNetwork段检测可靠；邻近曲线/另一站也参与全线最近距离。
---@type fun(pos:Vector3,radius:number,purpose:string):boolean|nil
local corridorExclusion_ = nil

--- 由世界入口注入解析走廊保留区，避免模块循环依赖及流式先后影响占位。
---@param callback fun(pos:Vector3,radius:number,purpose:string):boolean|nil
function Landscape.SetCorridorExclusion(callback)
    corridorExclusion_=callback
    if #cities_>0 then Landscape.RefreshGroundCuts() end
end

---@param pos Vector3
---@param r number
---@param clearance? number
function Landscape.CanPlace(pos,r,clearance)
    return Route.CanPlaceFootprint(pos,r,math.max(30,clearance or 30))
        and not Landmarks.Reserves(pos,r)
        and not (corridorExclusion_ and corridorExclusion_(pos,r,"legacy"))
end
---@param pos Vector3
---@param r number
function Landscape.InStationYard(pos,r)
    local _,s=Route.DistanceTo(pos)
    for _,city in ipairs(cities_) do
        if s+r>city.station.s-760 and s-r<city.station.s+460 then
            local track=Route.Sample(s)
            if GameConfig.MountainTerrain then
                local dx,dz=pos.x-track.x,pos.z-track.z
                if dx*dx+dz*dz<(105+r)^2 then return true end
            elseif (pos-track):Length()<105+r then return true end
        end
    end
    return false
end

-- 城市包络分侧保留，不用巨圆吞掉两侧轨道；城市规划在Init仅计算约400地块，无造景。
---@param pos Vector3
---@param r number
function Landscape.InCity(pos,r)
    for _, city in ipairs(cities_) do
        local offset=pos-city.origin
        local along,lateral=offset:DotProduct(city.tangent),offset:DotProduct(city.right)
        for _, zone in ipairs(city.zones) do
            if along+r>zone.a and along-r<zone.b and lateral+r>zone.lo and lateral-r<zone.hi then return true end
        end
    end
    return false
end
---@param pos Vector3
---@return number
function Landscape.CityDistance(pos)
    local best=math.huge
    for _, city in ipairs(cities_) do
        local offset=pos-city.origin
        local along,lateral=offset:DotProduct(city.tangent),offset:DotProduct(city.right)
        for _, zone in ipairs(city.zones) do
            local da,dl=math.max(zone.a-along,0,along-zone.b),math.max(zone.lo-lateral,0,lateral-zone.hi)
            best=math.min(best,math.sqrt(da*da+dl*dl))
        end
    end
    return best
end

-- 村落是低频成簇、工业带连片、江湾连续；80m仅是块归属，不是景观周期。
local function feature(index)
    local s=index*Landscape.SampleLength+40
    local theme,region=Landscape.ThemeAt(s)
    local cluster=math.floor(index/16)
    ---@type number
    local side=hash(cluster,8)>.52 and 1 or -1
    local phase=index%16
    local active=true
    local lateral,r=154.0,31.0
    if theme=="fields" or theme=="village" then
        active=phase<3+math.floor(hash(cluster,2)*3) and hash(cluster,3)>.18
        lateral=142+hash(cluster,4)*55
    elseif theme=="industry" then
        active=index%3==0 or (index%3==1 and hash(cluster,5)>.6)
        side=industrySides_[index] or (math.floor(index/3)%2==0 and -1 or 1)
        lateral,r=185+hash(cluster,6)*65,52
    elseif theme=="water" then
        side,lateral,r=1,350+math.sin(s/1700)*42,104
    elseif theme=="urban" then
        side=index%2==0 and -1 or 1
        lateral,r=region==6 and 110+hash(index,7)*105 or 120+hash(index,7)*120,34
        active=region==6 or index%2==0
    end
    -- 山地图乡野由连续山体承担；不把旧平原农庄/灌渠/江湾模板撒在山壁上。
    if Mountain.IsActiveAt(s) then active=false end
    return Route.SampleOffset(clampS(s),side*lateral,0),r,theme,s,side,active
end
---@param pos Vector3
---@param r number
function Landscape.ReservesNature(pos,r)
    if Landmarks.Reserves(pos,r) or not Landscape.CanPlace(pos,r,30) or Landscape.InCity(pos,r) or Landscape.InStationYard(pos,r) then return true end
    local _,s=Route.DistanceTo(pos)
    local theme=Landscape.ThemeAt(s)
    local origin=Route.Sample(s)
    local lateral=(pos-origin):DotProduct(Route.RightAt(s))
    -- 江湾与护岸/平行公路连续保留；水面只在铁路正侧，不横跨铁路。
    if theme=="water" and lateral+r>190 and lateral-r<510 then return true end
    -- 两段乡野的灌渠永久保留，避免田块先加载占掉水渠。
    if (theme=="fields" or theme=="village") and math.abs(math.abs(lateral)-310)<10+r then return true end
    local base=math.floor(s/Landscape.SampleLength)
    local reach=math.ceil((r+150)/Landscape.SampleLength)+1
    local last=math.ceil(Route.GetLength()/Landscape.SampleLength)-1
    for i=math.max(0,base-reach),math.min(last,base+reach) do
        local candidate,rr,kind,sampleS,side,active=feature(i)
        if active and kind~="water" then
            local dx,dz=pos.x-candidate.x,pos.z-candidate.z
            if dx*dx+dz*dz<(rr+r+4)^2 then return true end
            if kind=="industry" or kind=="fields" or kind=="village" or kind=="urban" then
                local road=Route.SampleOffset(sampleS,side*82,0)
                local rx,rz=pos.x-road.x,pos.z-road.z
                if rx*rx+rz*rz<(radius(7,80)+r+2)^2 then return true end
            end
        end
    end
    return false
end
-- 农田保留连续耕作区，同时在外缘留真正的防护林廊；不是把所有
-- FieldAllowed(小树半径)当成已提交田面，也不是为了种树取消整个农田主题。
---@param pos Vector3
---@param r number
function Landscape.InWoodlandBelt(pos,r)
    local distance,s=Route.DistanceTo(pos)
    if Mountain.IsActiveAt(s) then return false end
    local theme=Landscape.ThemeAt(s)
    local lo,hi=theme=="fields" and 390 or 335,theme=="fields" and 454 or 435
    return (theme=="fields" or theme=="village") and distance+r>lo and distance-r<hi
end
---@param pos Vector3
---@param r number
function Landscape.FieldAllowed(pos,r)
    local distance,s=Route.DistanceTo(pos)
    local theme=Landscape.ThemeAt(s)
    local maxDistance=theme=="village" and 310 or 820
    return distance<maxDistance and (theme=="fields" or theme=="village")
        and not Mountain.IsActiveAt(s) and not Landscape.InWoodlandBelt(pos,r)
        and Landscape.CanPlace(pos,r,30) and not Landscape.ReservesNature(pos,r)
end
-- 植被专用、可诊断的解析排除。保留建筑/城市/田地/站场和桥隧原有优先权；
-- 唯一收紧的是旧80m沿线小路的外接圆：圆会吃掉道路内侧40余米宽草带，
-- 实际路宽7m，改用沿线矩形全冠幅测试；不更动其他调用者的保守ReservesNature。
---@param pos Vector3
---@param r number
---@return string?
function Landscape.PlantingBlockReason(pos,r)
    if not Route.CanPlaceFootprint(pos,r,30) then return "rail" end
    if Landmarks.Reserves(pos,r) then return "structure" end
    if Landscape.InStationYard(pos,r) then return "yard" end
    if Landscape.InCity(pos,r) then return "city" end
    if corridorExclusion_ and corridorExclusion_(pos,r,"vegetation") then return "corridor" end
    local _,s=Route.DistanceTo(pos)
    local lateral=(pos-Route.Sample(s)):DotProduct(Route.RightAt(s))
    local theme=Landscape.ThemeAt(s)
    if theme=="water" and lateral+r>190 and lateral-r<510 then return "water" end
    if (theme=="fields" or theme=="village") and math.abs(math.abs(lateral)-310)<10+r then return "canal" end
    local base=math.floor(s/Landscape.SampleLength)
    local reach=math.ceil((r+150)/Landscape.SampleLength)+1
    for i=math.max(0,base-reach),math.min(math.ceil(Route.GetLength()/Landscape.SampleLength)-1,base+reach) do
        local candidate,rr,kind,sampleS,side,active=feature(i)
        if active and kind~="water" then
            local dx,dz=pos.x-candidate.x,pos.z-candidate.z
            if dx*dx+dz*dz<(rr+r+4)^2 then return "feature" end
            if math.abs(s-sampleS)<40+r+2 and math.abs(lateral-side*82)<3.5+r+2 then return "access" end
        end
    end
    return nil
end

---@param kind string villa/residential/warehouse/courtyard/tower
---@param definition RailwayLandscapeAssetDefinition
function Landscape.SetBuildingAsset(kind,definition)
    assert(type(definition.model)=="string" and definition.model~="","建筑资源必须提供MDL路径")
    definitions_[kind]=definition
    attempted_[kind],assets_[kind]=nil,nil
end
---@param kind string
---@return RailwayLandscapeAsset|nil
local function getAsset(kind)
    if attempted_[kind] then return assets_[kind] end
    attempted_[kind]=true
    local def=definitions_[kind]
    if not def then return nil end
    local model=cache:GetResource("Model",def.model)
    if not model then print("[Landscape] 建筑MDL缺失，保留差异化合批建筑："..def.model); return nil end
    local bounds=model.boundingBox
    local size=bounds.size
    if size.x<.001 or size.y<.001 or size.z<.001 then
        print("[Landscape] 建筑包围盒无效："..kind); return nil
    end
    ---@type Material[]
    local materials={}
    if def.materials and #def.materials>0 then
        for i,path in ipairs(def.materials) do
            local material=cache:GetResource("Material",path)
            if not material then print("[Landscape] 建筑完整材质缺失："..path); return nil end
            materials[i]=material:Clone()
        end
        -- 生成材质原XML通过uuid引用纹理；保留完整材质槽，但显式绑定本地交付贴图。
        -- 裸tool_mode及离线预览也可用，不修改缓存共享材质。
        if def.diffuse and def.normal and materials[1] then
            local diffuse=cache:GetResource("Texture2D",def.diffuse)
            local normal=cache:GetResource("Texture2D",def.normal)
            if not diffuse or not normal then print("[Landscape] 本地建筑贴图缺失："..kind); return nil end
            diffuse:SetSRGB(true); normal:SetSRGB(false)
            diffuse:SetFilterMode(FILTER_ANISOTROPIC); normal:SetFilterMode(FILTER_ANISOTROPIC)
            diffuse:SetAnisotropy(4); normal:SetAnisotropy(4)
            materials[1]:SetTexture(TU_DIFFUSE,diffuse); materials[1]:SetTexture(TU_NORMAL,normal)
            materials[1]:SetShaderParameter("Metallic",Variant(0.0))
            materials[1]:SetShaderParameter("Roughness",Variant(.85))
        end
    elseif def.diffuse and def.normal then
        local diffuse=cache:GetResource("Texture2D",def.diffuse)
        local normal=cache:GetResource("Texture2D",def.normal)
        local technique=cache:GetResource("Technique","Techniques/PBR/PBRDiffNormal.xml")
        if not diffuse or not normal or not technique then return nil end
        local material=Material:new()
        material:SetTechnique(0,technique)
        diffuse:SetSRGB(true); normal:SetSRGB(false)
        diffuse:SetFilterMode(FILTER_ANISOTROPIC); normal:SetFilterMode(FILTER_ANISOTROPIC)
        diffuse:SetAnisotropy(4); normal:SetAnisotropy(4)
        material:SetTexture(TU_DIFFUSE,diffuse); material:SetTexture(TU_NORMAL,normal)
        material:SetShaderParameter("Metallic",Variant(0.0)); material:SetShaderParameter("Roughness",Variant(.85))
        materials[1]=material
    else return nil end
    ---@type RailwayLandscapeAsset
    local asset={key=kind,model=model,materials=materials,bounds=bounds}
    assets_[kind]=asset
    print(string.format("[Landscape] %s完整MDL包围盒 %.2f×%.2f×%.2fm，保留%d材质槽",kind,size.x,size.y,size.z,#materials))
    return asset
end

-- 每材质/320m空间格一批；同一MDL资源+格合组（不是每座楼一批）。
---@class RailwayLandscapeBuilder
---@field root Node
---@field batches table<string, RailwayBatch>
---@field models table<string, StaticModelGroup>
---@field materialKeys table<string, boolean>
---@field modelBatches number
local Builder={}
Builder.__index=Builder
---@param root Node
---@return RailwayLandscapeBuilder
local function newBuilder(root)
    local self=setmetatable({},Builder)
    self:Init(root)
    return self
end
function Builder:Init(root)
    self.root=root
    self.batches={}
    self.models={}
    self.materialKeys={}
    self.modelBatches=0
end
---@param pos Vector3
---@param key string
---@param material Material
---@param shadows? boolean
---@param tile? number
---@return RailwayBatch
function Builder:Batch(pos,key,material,shadows,tile)
    local size=Landscape.BatchCellSize
    local cell=math.floor(pos.x/size).."_"..math.floor(pos.z/size)
    local id=cell.."_"..key
    self.materialKeys[tostring(material)]=true
    local batch=self.batches[id]
    if not batch then
        batch=World.NewBatch(self.root:CreateChild(id),material,shadows,tile)
        batch.geometry.drawDistance=2300
        batch.geometry.shadowDistance=160
        self.batches[id]=batch
    end
    return batch
end
---@param asset RailwayLandscapeAsset
---@param pos Vector3
---@param scale number
---@param yaw number
function Builder:Model(asset,pos,scale,yaw)
    local size=Landscape.BatchCellSize
    local cell=math.floor(pos.x/size).."_"..math.floor(pos.z/size)
    local key=asset.model.name.."_"..cell
    local group=self.models[key]
    if not group then
        local node=self.root:CreateChild("完整建筑_"..asset.key.."_"..cell)
        node.position=Vector3(math.floor(pos.x/size)*size+size*.5,0,math.floor(pos.z/size)*size+size*.5)
        group=node:CreateComponent("StaticModelGroup")
        group.model=asset.model
        for i,material in ipairs(asset.materials) do
            group:SetMaterial(i-1,material)
            self.materialKeys[tostring(material)]=true
        end
        group.castShadows=true; group.viewMask=6; group.drawDistance=2200; group.shadowDistance=220
        self.models[key]=group
        self.modelBatches=self.modelBatches+#asset.materials
    end
    local node=self.root:CreateChild("建筑实例_"..asset.key)
    local rotation=Quaternion(yaw,Vector3.UP)
    local bounds=asset.bounds
    node.position=pos+rotation*(Vector3(-bounds.center.x,-bounds.min.y,-bounds.center.z)*scale)
    node.rotation=rotation; node.scale=Vector3.ONE*scale
    group:AddInstanceNode(node)
end
function Builder:Finish(pause)
    local meshes,vertices=0,0
    for _,batch in pairs(self.batches) do
        local n=batch:Finish()
        if n>0 then meshes=meshes+1; vertices=vertices+n end
        pauseOnce(pause)
    end
    for _ in pairs(self.models) do meshes=meshes+1 end
    local materials=0
    for _ in pairs(self.materialKeys) do materials=materials+1 end
    return meshes,vertices,materials,self.modelBatches
end

local function wallMaterial(plot,cityIndex)
    if plot.kind=="courtyard" or (cityIndex==1 and plot.variant%3==0) then return World.Brick(),"砖墙" end
    if plot.kind=="tower" then
        local color=cityIndex==1 and Color(.34,.47,.52) or (cityIndex==4 and Color(.43,.57,.58) or Color(.36,.45,.54))
        return solid(color,.12,.58),"高楼立面_"..cityIndex
    end
    if plot.kind=="warehouse" then return solid(Color(.53,.57,.59),.08,.75),"冷灰墙" end
    return solid(Color(.70,.68,.61),0,.92),"暖灰墙"
end

---@param builder RailwayLandscapeBuilder
---@param pos Vector3
---@param plot RailwayLandscapePlot
---@param yaw number
---@param cityIndex number
---@param pause? fun()
---@return table
local function building(builder,pos,plot,yaw,cityIndex,pause)
    local w,d,h=plot.width,plot.depth,plot.height
    -- 住宅新资产仅用于适合的中层地块，近层小院/现代高楼保持自己的体量与屋顶。
    local useResidential=plot.kind=="slab" and plot.variant%3~=1
    local assetKind=plot.kind=="warehouse" and "warehouse" or
        (plot.kind=="courtyard" and "courtyard" or (plot.kind=="tower" and "tower" or "residential"))
    -- 阳台住宅只替换云湾适配的部分中高层，不冒充港务楼/商务塔、不统一复制全城。
    -- 百米天际线保留；源模型高宽比实测2.42，缩放必须同时满足地块宽/深/高度。
    local detailedTower=cityIndex==5 and plot.kind=="tower" and h<=90 and plot.variant%2==0
    if detailedTower then assetKind="residentialTower" end
    local asset=(plot.kind=="warehouse" or plot.kind=="courtyard" or plot.kind=="tower" or useResidential) and getAsset(assetKind) or nil
    if not asset and plot.kind=="villa" and plot.variant%3==0 then asset=getAsset("villa") end
    if asset then
        local size=asset.bounds.size
        -- 新住宅长轴Z是真面宽：旋转90度后按X地块宽/Z地块深检查，不能把狭轴X当面宽。
        local turn=asset.key=="residential" and 90 or 0
        local sx,sz=turn==90 and size.z or size.x,turn==90 and size.x or size.z
        local scale=math.min(h/size.y,(w-1)/sx,(d-1)/sz)
        if size.y*scale>=math.min(h*.55,4.0) then
            builder:Model(asset,pos,scale,yaw+turn)
            return {kind="textured_mdl",buildingKind=plot.kind,width=sx*scale,depth=sz*scale,
                height=size.y*scale,radius=radius(w,d,3),scale=scale,asset=asset.key}
        end
    end
    local angle=math.rad(yaw)
    local co,si=math.cos(angle),math.sin(angle)
    local function p(x,y,z) return Vector3(pos.x+x*co+z*si,pos.y+y,pos.z-x*si+z*co) end
    local mat,key=wallMaterial(plot,cityIndex)
    local near=math.abs(plot.lateral)<280
    local walls=builder:Batch(pos,key,mat,near,2)
    local trim=builder:Batch(pos,"楼收边",World.Concrete(),near,2)
    local roof=builder:Batch(pos,"屋面",solid(Color(.33,.36,.37),.05,.86),near,1.5)
    local glass=builder:Batch(pos,"窗门",solid(Color(.18,.27,.31),.17,.32),false)
    walls.geometry.viewMask=6; trim.geometry.viewMask=6; roof.geometry.viewMask=6; glass.geometry.viewMask=6
    local doors=roof -- 门/机房/屋面共用深灰，避免每格再增一材质批。
    -- 四面窗带有正确外法线；每扇窗为六顶点而非扁盒的36顶点。
    local function frontWindow(x,y,z,width,height,side)
        local a,b,c,d=p(x-width*.5,y-height*.5,z),p(x-width*.5,y+height*.5,z),
            p(x+width*.5,y+height*.5,z),p(x+width*.5,y-height*.5,z)
        if side<0 then glass:AddQuad(a,b,c,d) else glass:AddQuad(d,c,b,a) end
    end
    local function sideWindow(x,y,z,width,height,side)
        local a,b,c,d=p(x,y-height*.5,z-width*.5),p(x,y+height*.5,z-width*.5),
            p(x,y+height*.5,z+width*.5),p(x,y-height*.5,z+width*.5)
        if side>0 then glass:AddQuad(a,b,c,d) else glass:AddQuad(d,c,b,a) end
    end
    -- 院落为真实U形三翼，中间保持露天，非一个封闭大方块。
    if plot.kind=="courtyard" then
        walls:AddBox(p(0,h*.5,d*.32),Vector3(w,h,d*.36),angle)
        for side=-1,1,2 do walls:AddBox(p(side*w*.36,h*.44,-d*.09),Vector3(w*.28,h*.88,d*.52),angle) end
        trim:AddBox(p(0,.06,-d*.1),Vector3(w*.44,.12,d*.47),angle)
        for _,z in ipairs({-d*.5,d*.5}) do walls:AddBox(p(0,.6,z),Vector3(w+1,1.2,.22),angle) end
        for side=-1,1,2 do
            roof:AddBox(p(side*w*.36,h*.88+.08,-d*.09),Vector3(w*.31,.16,d*.55),angle)
            glass:AddBox(p(side*w*.21,1.7,0),Vector3(.04,1.1,1.4),angle)
            for _,z in ipairs({-d*.24,d*.08,d*.32}) do
                glass:AddBox(p(side*(w*.5+.025),1.7,z),Vector3(.04,1.1,1.4),angle)
            end
        end
        roof:AddBox(p(0,h+.07,d*.32),Vector3(w+1,.14,d*.4),angle)
        doors:AddBox(p(0,1.1,-d*.5-.02),Vector3(1.8,2.2,.06),angle)
    else
        walls:AddBox(p(0,h*.5,0),Vector3(w,h,d),angle)
        trim:AddBox(p(0,.18,0),Vector3(w+.4,.36,d+.4),angle)
        -- 近中层按真实3.2m层高，远层>=5.8m；窗用立面quad而非每窗36顶点箱体。
        local floors=math.max(1,math.min(plot.kind=="tower" and 34 or 12,math.floor(h/(near and 3.2 or 5.8))))
        -- 中高楼使用窗带+竖向分缝，低楼独立窗；远轮廓降低几何数量，不每扇窗造节点。
        for floor=1,floors do
            local y=(floor-.48)*h/floors
            if plot.kind=="tower" or plot.kind=="slab" or h>22 then
                for side=-1,1,2 do
                    frontWindow(0,y,side*(d*.5+.028),w-.7,plot.kind=="tower" and 1.9 or 1.4,side)
                    sideWindow(side*(w*.5+.028),y,0,d-.7,plot.kind=="tower" and 1.9 or 1.4,side)
                end
                if floor%3==0 then trim:AddBox(p(0,floor*h/floors,0),Vector3(w+.15,.10,d+.15),angle) end
            elseif plot.kind~="warehouse" then
                for side=-1,1,2 do
                    for x=-w*.5+2,w*.5-1.5,3.6 do
                        glass:AddBox(p(x,y,side*(d*.5+.025)),Vector3(1.5,1.35,.04),angle)
                        trim:AddBox(p(x,y-.72,side*(d*.5+.07)),Vector3(1.7,.12,.16),angle)
                    end
                    -- 低层住宅两侧同样有窗，不让横向观景只看到整面白墙。
                    for z=-d*.5+2.4,d*.5-1.8,4.2 do
                        glass:AddBox(p(side*(w*.5+.025),y,z),Vector3(.04,1.35,1.55),angle)
                        trim:AddBox(p(side*(w*.5+.07),y-.72,z),Vector3(.16,.12,1.75),angle)
                    end
                end
            end
            if floor%3==0 then pauseOnce(pause) end
        end
        if plot.kind=="warehouse" then
            for x=-w*.5+4,w*.5-3,8 do
                doors:AddBox(p(x,2.2,-d*.5-.04),Vector3(4,4.4,.08),angle)
                trim:AddBox(p(x,.15,-d*.5-1),Vector3(4.5,.3,2),angle)
                glass:AddBox(p(x,h-1.5,d*.5+.02),Vector3(4,.85,.04),angle)
            end
            for z=-d*.5+3,d*.5-2,6 do roof:AddBox(p(0,h+.25,z),Vector3(w*.65,.18,.7),angle) end
        else
            doors:AddBox(p(0,1.15,-d*.5-.04),Vector3(1.6,2.3,.08),angle)
            trim:AddBox(p(0,2.55,-d*.5-.6),Vector3(2.4,.12,1.3),angle)
        end
        if plot.pitched then
            local ridge=h+math.min(2.4,w*.14)
            roof:AddQuad(p(-w*.5-.4,h,-d*.5-.4),p(-w*.5-.4,h,d*.5+.4),p(0,ridge,d*.5+.4),p(0,ridge,-d*.5-.4))
            roof:AddQuad(p(0,ridge,-d*.5-.4),p(0,ridge,d*.5+.4),p(w*.5+.4,h,d*.5+.4),p(w*.5+.4,h,-d*.5-.4))
        else
            roof:AddBox(p(0,h+.13,0),Vector3(w+.3,.26,d+.3),angle)
            if plot.kind=="tower" then
                -- 退台/不同高度机房改变天际线，禁止每栋相同平顶。
                walls:AddBox(p(w*.08,h+1.5,-d*.08),Vector3(w*.58,3,d*.60),angle)
                roof:AddBox(p(w*.08,h+3.05,-d*.08),Vector3(w*.59,.10,d*.61),angle)
                for side=-1,1,2 do
                    for x=-w*.5+2,w*.5-1,4.6 do
                        trim:AddBox(p(x,h*.5,side*(d*.5+.065)),Vector3(.16,h,.14),angle)
                    end
                    for z=-d*.5+2,d*.5-1,5.4 do
                        trim:AddBox(p(side*(w*.5+.065),h*.5,z),Vector3(.14,h,.16),angle)
                    end
                end
            end
        end
        if plot.kind=="slab" and plot.variant%2==0 then
            for floor=2,math.min(floors,6) do
                trim:AddBox(p(0,(floor-1)*3.1,-d*.5-.8),Vector3(w*.8,.16,1.5),angle)
            end
        end
    end
    return {kind="procedural",buildingKind=plot.kind,width=w,depth=d,height=h+(plot.kind=="tower" and 3.1 or (plot.pitched and 2.4 or .3)),radius=radius(w,d,3),scale=1}
end

local function addPlot(city,along,lateral,w,d,h,kind,variant,district,pitched)
    city.plots[#city.plots+1]={along=along,lateral=lateral,width=w,depth=d,height=h,kind=kind,
        variant=variant,district=district,pitched=pitched==true}
end
function Landscape.Init()
    cities_,cityData_,chunkData_,logged_={},{},{},{}
    makeRegions()
    industrySides_={}
    local industrialRegion=regions_[3]
    if industrialRegion then
        local ordinal=0
        for index=math.ceil((industrialRegion.first-40)/80),math.ceil((industrialRegion.last-40)/80)-1 do
            local cluster=math.floor(index/16)
            if index%3==0 or (index%3==1 and hash(cluster,5)>.6) then
                industrySides_[index]=ordinal%2==0 and -1 or 1
                ordinal=ordinal+1
            end
        end
    end
    -- stationIndex固定街网/密度/体量/底色，不从周期或随机数选城市风格。
    local profiles={
        {rows={-134,-205,-278,-358,-450,-550},columns=17,spacing=58,opposite={174,248,335,435},oppColumns=15,ground=Color(.49,.47,.43)},
        {rows={-174,-286,-398,-510},columns=12,spacing=94,opposite={200,310,425},oppColumns=10,ground=Color(.38,.41,.42)},
        {rows={-134,-214,-300,-395,-495},columns=12,spacing=68,opposite={174,260},oppColumns=9,ground=Color(.44,.47,.35)},
        {rows={-136,-211,-290,-375,-470,-570},columns=15,spacing=64,opposite={},oppColumns=0,ground=Color(.52,.52,.46)},
        {rows={-136,-208,-282,-360,-450,-550},columns=20,spacing=56,opposite={174,250,335,435},oppColumns=17,ground=Color(.36,.40,.43)},
        {rows={-134,-224},columns=7,spacing=86,opposite={136},oppColumns=5,ground=Color(.44,.48,.35)},
        {rows={-140,-245},columns=7,spacing=90,opposite={140},oppColumns=5,ground=Color(.48,.47,.42)},
        {rows={-138,-235,-330},columns=7,spacing=94,opposite={140},oppColumns=5,ground=Color(.40,.46,.37)},
        {rows={-138,-240},columns=8,spacing=91,opposite={140},oppColumns=5,ground=Color(.45,.47,.40)},
        {rows={-138,-240,-340},columns=9,spacing=90,opposite={140,245},oppColumns=6,ground=Color(.46,.49,.47)},
    }
    for _,station in ipairs(Route.GetStations()) do
        local origin,tangent,yaw=Route.Sample(station.s)
        local index=station.index
        local profile=profiles[index] or profiles[3]
        ---@type RailwayCityPlan
        local city={station=station,origin=origin,tangent=tangent,right=Route.RightAt(station.s),yaw=yaw,
            plots={},roads={},zones={},groundZones={},style=styleNames_[index] or "城郊街区"}
        city.ground=profile.ground
        local extent=profile.columns*profile.spacing*.5+35
        for row,lateral in ipairs(profile.rows) do
            for col=1,profile.columns do
                local along=(col-(profile.columns+1)*.5)*profile.spacing+(row%2)*10-45
                local v=col+row*19+index*43
                local w,d,h,kind,pitched,district=24.0,28.0,9.0,"villa",true,"城市住宅"
                if index==1 then
                    if row==1 then w,d,h,kind,pitched,district=25,30,4.6+v%2,"courtyard",false,"红灰院落"
                    elseif row==2 then w,d,h,kind,pitched,district=30,36,17+v%5*3.1,"slab",false,"连续中层街坊"
                    else w,d,h,kind,pitched,district=32,38,52+v%7*9,"tower",false,"星汐玻璃商务高楼" end
                elseif index==2 then
                    w,d,h,kind,pitched,district=50+v%3*8,64,8+v%3*2,"warehouse",true,"长仓库与装卸院"
                    if row==1 and col%3==0 then w,d,h,kind,pitched,district=25,32,13+v%3*3,"slab",false,"厂区宿舍" end
                    if row==3 and col%3==0 then w,d,h,kind,pitched,district=28,36,43+v%4*5,"tower",false,"岚港港务调度楼" end
                elseif index==3 then
                    if row>=2 and col%3==0 then goto continue end
                    w,d,h,kind,pitched,district=18+v%3*2,25,5.8+v%3*2.6,"villa",true,"谷地村落"
                    if row==3 then h,kind,pitched,district=14+v%3*3,"slab",false,"小镇外围" end
                elseif index==4 then
                    w,d,h,kind,pitched,district=26+v%3*3,34,12+v%5*3.1,"slab",false,"滨江街坊"
                    if row==3 and col%3==0 then h,kind,district=64+v%4*10,"tower","镜澜青蓝岸外商务楼" end
                elseif index==5 then
                    w,d,h,kind,pitched,district=27+v%3*3,36,76+((v*7)%13)*4.8,"tower",false,"云湾百米高层组团"
                    if row==1 then h,kind,district=15+v%5*3.1,"slab","近轨商业住宅" end
                else
                    -- 新山城以水平站坪上的低层街坊为主，不复制云湾百米高楼模板。
                    w,d,h,kind,pitched,district=20+v%3*2,26,6+(v%3)*2.5,"villa",true,"山城坡顶民居"
                    if index==7 then h,kind,pitched,district=10+v%3*3,"slab",false,"石门灰石街坊" end
                    if index==8 then district="云脊林业街坊" end
                    if index==9 then h,district=7+v%3*3,"松岚高地民居" end
                    if index==10 then
                        h,kind,pitched,district=16+v%4*5,"slab",false,"天池湖岸街坊"
                        if row==3 and col%3==0 then h,kind,district=42+v%3*5,"tower","天池客运商务楼" end
                    end
                end
                local plotLateral=lateral
                -- 首排已有楼集中在站前观景范围；不增楼、不把大仓库推入保留区。
                if row==1 then
                    along=(col-(profile.columns+1)*.5)*(index==2 and 134 or 44)-80
                    if index==2 then
                        if kind=="slab" then along=(col/3-2)*66-80; plotLateral=-135 else plotLateral=-190 end
                    end
                end
                addPlot(city,along,plotLateral,w,d,h,kind,v,district,pitched)
                ::continue::
            end
        end
        for row,lateral in ipairs(profile.opposite) do
            for col=1,profile.oppColumns do
                local v=col+row*13+index*59
                local kind=index==2 and "warehouse" or (index==5 and "tower" or "slab")
                if index==3 then kind="villa" end
                local h=index==5 and 68+v%11*6 or (index==2 and 10 or 7+v%4*3.1)
                local oppositeAlong=(col-(profile.oppColumns+1)*.5)*(row==1 and index~=2 and 44 or (index==2 and 148 or profile.spacing))-80
                addPlot(city,oppositeAlong,lateral,
                    kind=="warehouse" and 58 or 26,kind=="warehouse" and 62 or 32,h,kind,v,"对侧街区",kind=="villa" or kind=="warehouse")
            end
        end
        local outer=math.abs(profile.rows[#profile.rows])+60
        city.zones={{a=-extent-45,b=extent-45,lo=-outer,hi=-112}}
        if #profile.opposite>0 then
            city.zones[#city.zones+1]={a=-extent-45,b=extent-45,lo=124,hi=profile.opposite[#profile.opposite]+60}
        end
        -- 纵路在排与排之间；横路只在同侧地块列之间，绝无横轨平交。
        for i=1,#profile.rows-1 do
            local lat=(profile.rows[i]+profile.rows[i+1])*.5
            for a=-extent,extent-1,64 do city.roads[#city.roads+1]={along=a-45+32,lateral=lat,w=index==2 and 11 or 8,d=64} end
        end
        for i=1,#profile.opposite-1 do
            local lat=(profile.opposite[i]+profile.opposite[i+1])*.5
            for a=-extent,extent-1,64 do city.roads[#city.roads+1]={along=a-45+32,lateral=lat,w=index==2 and 11 or 7,d=64} end
        end
        for col=2,profile.columns-1,(index==3 and 3 or 4) do
            local along=(col-profile.columns*.5)*profile.spacing-45
            for lat=-outer+32,-145,64 do city.roads[#city.roads+1]={along=along,lateral=lat,w=64,d=index==2 and 10 or 7} end
        end
        cities_[index]=city
    end
    Landscape.RefreshGroundCuts()
    for _,region in ipairs(regions_) do
        print(string.format("[Landscape] 地理区%d %.2f..%.2fkm %s（开放端点，无主题轮播）",region.index,region.first/1000,region.last/1000,region.name))
    end
end

local function overlapsPlot(city,along,lateral,w,d,extra)
    for _,plot in ipairs(city.plots) do
        if math.abs(along-plot.along)<(d+plot.depth)*.5+(extra or 0)
            and math.abs(lateral-plot.lateral)<(w+plot.width)*.5+(extra or 0) then return true end
    end
    return false
end

-- XZ凸四边形裁剪，保证接管地面仅一个可见表面；不依赖节点加载先后。
local function cutPolygon(poly,a,b,positive)
    local out={}
    local function value(p) return (b.x-a.x)*(p.z-a.z)-(b.z-a.z)*(p.x-a.x) end
    local previous=poly[#poly]
    if not previous then return out end
    local prevValue=value(previous)
    local prevInside=positive and prevValue>=-.000001 or (not positive and prevValue<=.000001)
    for _,current in ipairs(poly) do
        local currentValue=value(current)
        local inside=positive and currentValue>=-.000001 or (not positive and currentValue<=.000001)
        if inside~=prevInside then
            local t=prevValue/(prevValue-currentValue)
            out[#out+1]=previous+(current-previous)*t
        end
        if inside then out[#out+1]=current end
        previous,prevValue,prevInside=current,currentValue,inside
    end
    return out
end
local function subtractGround(poly,cut)
    local remaining=poly
    local outside={}
    for i,a in ipairs(cut) do
        local b=assert(cut[i%#cut+1])
        local piece=cutPolygon(remaining,a,b,true)
        if #piece>=3 then outside[#outside+1]=piece end
        remaining=cutPolygon(remaining,a,b,false)
        if #remaining<3 then break end
    end
    return outside
end
local function polygonBounds(poly)
    local x0,x1,z0,z1=math.huge,-math.huge,math.huge,-math.huge
    for _,p in ipairs(poly) do x0,x1=math.min(x0,p.x),math.max(x1,p.x); z0,z1=math.min(z0,p.z),math.max(z1,p.z) end
    return x0,x1,z0,z1
end
local function cityQuad(city,zone,y)
    return {at(city,zone.a,zone.lo)+Vector3(0,y,0),at(city,zone.b,zone.lo)+Vector3(0,y,0),
        at(city,zone.b,zone.hi)+Vector3(0,y,0),at(city,zone.a,zone.hi)+Vector3(0,y,0)}
end
local function addGroundCut(poly)
    local x0,x1,z0,z1=polygonBounds(poly)
    groundCuts_[#groundCuts_+1]={points=poly,x0=x0,x1=x1,z0=z0,z1=z1}
end
-- 把站场以及实际街块登记给Terrain，Terrain对子面做精确裁剪而不是抬高覆盖。
function Landscape.RefreshGroundCuts()
    groundCuts_={}
    for _,city in ipairs(cities_) do
        city.groundZones={}
        local a,b=clampS(city.station.s-760),clampS(city.station.s+460)
        for first=a,b-.001,64 do
            local last=math.min(b,first+64)
            addGroundCut({Route.SampleOffset(first,-100,0),Route.SampleOffset(last,-100,0),
                Route.SampleOffset(last,105,0),Route.SampleOffset(first,105,0)})
        end
        -- 首排整段紧凑街块，外排仅各楼小院，空街区仍是土底，不铺满巨矩形。
        local rows={}
        for _,plot in ipairs(city.plots) do
            local pos=at(city,plot.along,plot.lateral)
            if Landscape.CanPlace(pos,radius(plot.width,plot.depth,3),30) and not Landscape.InStationYard(pos,radius(plot.width,plot.depth,3)) then
                local key=tostring(plot.lateral)
                local zone=rows[key]
                local margin=math.abs(plot.lateral)<150 and 5 or 2
                local candidate={a=plot.along-plot.depth*.5-margin,b=plot.along+plot.depth*.5+margin,
                    lo=plot.lateral-plot.width*.5-margin,hi=plot.lateral+plot.width*.5+margin}
                if math.abs(plot.lateral)<150 then
                    if zone then
                        zone.a=math.min(zone.a,candidate.a); zone.b=math.max(zone.b,candidate.b)
                        zone.lo=math.min(zone.lo,candidate.lo); zone.hi=math.max(zone.hi,candidate.hi)
                    else rows[key]=candidate end
                else city.groundZones[#city.groundZones+1]=candidate end
            end
        end
        for _,zone in pairs(rows) do city.groundZones[#city.groundZones+1]=zone end
        for _,zone in ipairs(city.groundZones) do addGroundCut(cityQuad(city,zone,0)) end
        for _,road in ipairs(city.roads) do
            local pos=at(city,road.along,road.lateral)
            local r=radius(road.w,road.d)
            if Landscape.CanPlace(pos,r,30) and not Landscape.InStationYard(pos,r)
                and not overlapsPlot(city,road.along,road.lateral,road.w,road.d,2) then
                addGroundCut(cityQuad(city,{a=road.along-road.d*.5,b=road.along+road.d*.5,
                    lo=road.lateral-road.w*.5,hi=road.lateral+road.w*.5},0))
            end
        end
    end
end
---@param poly Vector3[]
---@return Vector3[][]
function Landscape.ClipUnclaimedGround(poly)
    local pieces=Landmarks.ClipGround(poly)
    local x0,x1,z0,z1=polygonBounds(poly)
    for _,cut in ipairs(groundCuts_) do
        if x1>cut.x0 and x0<cut.x1 and z1>cut.z0 and z0<cut.z1 then
            local nextPieces={}
            for _,piece in ipairs(pieces) do
                for _,part in ipairs(subtractGround(piece,cut.points)) do nextPieces[#nextPieces+1]=part end
            end
            pieces=nextPieces
            if #pieces==0 then break end
        end
    end
    return pieces
end

-- 站场保持轨道硬地[-22,+22]，外围为维护土面；不全幅抬高，不覆盖已有月台/路基。
-- 站场地面改用纹理材质（混凝土/土面），消除大面积纯色平板。
local function stationGround(builder,city,data,pause)
    local a,b=clampS(city.station.s-760),clampS(city.station.s+460)
    local hard=World.UrbanGround()
    local earth=World.Grassland()
    for first=a,b-.001,64 do
        local last=math.min(b,first+64)
        local center=Route.Sample((first+last)*.5)
        for _,band in ipairs({{lo=-100,hi=-22,hard=false},{lo=-22,hi=22,hard=true},{lo=22,hi=105,hard=false}}) do
            local batch=builder:Batch(center,band.hard and "硬化站场" or "站场维护土",band.hard and hard or earth,false,band.hard and 8 or 7)
            local poly={Route.SampleOffset(first,band.lo,0),Route.SampleOffset(last,band.lo,0),
                Route.SampleOffset(last,band.hi,0),Route.SampleOffset(first,band.hi,0)}
            -- 平地入口沿用旧裁切，Y=-.25保底负责未铺砖的边角；山地没有该保底。
            -- 山地必须保留站基Y处完整土底（Terrain已让出整段站场），否则站房两侧透天空。
            -- Station铺砖底Y=0、顶Y=.05，地基不与可见铺砖顶面共面，也不改变轨道/月台高度。
            ---@type Vector3[][]
            local pieces={poly}
            if not Mountain.IsActiveAt(city.station.s) then
                local forecourt={a=-120,b=10,lo=-90,hi=-19.9}
                pieces=subtractGround(poly,cityQuad(city,forecourt,0))
            end
            for _,piece in ipairs(pieces) do
                for i=2,#piece-1 do batch:AddTriPlanar(piece[1],piece[i],piece[i+1],band.hard and 8 or 7) end
            end
            if band.hard then data.yardArea=data.yardArea+(last-first)*44 end
        end
        pauseOnce(pause)
    end
    -- 街块下面不再叠城市大面和门前小面，单表面分色；空地由Terrain土面显示。
    for _,zone in ipairs(city.groundZones) do
        local pos=at(city,(zone.a+zone.b)*.5,(zone.lo+zone.hi)*.5)
        local batch=builder:Batch(pos,"城市基底",World.UrbanGround(),false,8)
        local pieces={cityQuad(city,zone,0)}
        for _,road in ipairs(city.roads) do
            local roadPos=at(city,road.along,road.lateral)
            local r=radius(road.w,road.d)
            if Landscape.CanPlace(roadPos,r,30) and not Landscape.InStationYard(roadPos,r)
                and not overlapsPlot(city,road.along,road.lateral,road.w,road.d,2) then
                local cut=cityQuad(city,{a=road.along-road.d*.5,b=road.along+road.d*.5,
                    lo=road.lateral-road.w*.5,hi=road.lateral+road.w*.5},0)
                local nextPieces={}
                for _,piece in ipairs(pieces) do
                    for _,part in ipairs(subtractGround(piece,cut)) do nextPieces[#nextPieces+1]=part end
                end
                pieces=nextPieces
            end
        end
        for _,piece in ipairs(pieces) do
            for i=2,#piece-1 do batch:AddTriPlanar(piece[1],piece[i],piece[i+1],8) end
        end
        data.pavedArea=data.pavedArea+(zone.b-zone.a)*(zone.hi-zone.lo)
        data.paving=data.paving+1
        pauseOnce(pause)
    end
end

local function overlapsRoad(city,along,lateral,r)
    for _,road in ipairs(city.roads) do
        if math.abs(along-road.along)<road.d*.5+r+1
            and math.abs(lateral-road.lateral)<road.w*.5+r+1 then return true end
    end
    return false
end

---@param owner Node
---@param station table
---@param pause? fun()
function Landscape.BuildCity(owner,station,pause)
    local city=cities_[station.index]
    if not city then return end
    local root=owner:CreateChild("分区城区_"..station.index)
    local builder=newBuilder(root)
    local data={stationIndex=station.index,name=displayNames_[station.index] or "城镇站",style=city.style,placements={},paths={},districts={},
        rejected=0,buildings=0,highRises=0,textured=0,trees=0,minHeight=math.huge,maxHeight=0,minClearance=math.huge,meshes=0,vertices=0,
        paving=0,pavedArea=0,yardArea=0,pavingData={},streetTrees=0,treeData={},materialCount=0,materialBatches=0}
    cityData_[station.index]=data -- yield中取消任务时ForgetStation也能清掉部分统计。
    Landmarks.NoteBuildings("city_"..station.index,data)
    stationGround(builder,city,data,pause)
    local roadMaterial=solid(Color(.27,.29,.30),0,.98)
    for _,road in ipairs(city.roads) do
        local pos=at(city,road.along,road.lateral)
        local r=radius(road.w,road.d)
        if Landscape.CanPlace(pos,r,30) and not Landscape.InStationYard(pos,r)
            and not overlapsPlot(city,road.along,road.lateral,road.w,road.d,2.0) then
            builder:Batch(pos,"道路",roadMaterial,false):AddBox(pos+Vector3(0,.022,0),Vector3(road.w,.044,road.d),math.rad(city.yaw))
            data.paths[#data.paths+1]={x=pos.x,z=pos.z,radius=r,stationIndex=station.index}
        end
        pauseOnce(pause)
    end
    for _,plot in ipairs(city.plots) do
        local pos=at(city,plot.along,plot.lateral)
        local r=radius(plot.width,plot.depth,3)
        if Landscape.CanPlace(pos,r,30) and not Landscape.InStationYard(pos,r) then
            local record=building(builder,pos,plot,city.yaw,station.index,pause)
            record.x,record.z,record.stationIndex=pos.x,pos.z,station.index
            record.name=data.name.."_"..plot.district.."_"..plot.variant
            record.district=plot.district
            record.clearance=Route.DistanceTo(pos)-r
            data.placements[#data.placements+1]=record
            data.buildings=data.buildings+1
            if record.height>=40 then data.highRises=data.highRises+1 end
            data.textured=data.textured+(record.kind=="textured_mdl" and 1 or 0)
            data.districts[plot.district]=(data.districts[plot.district] or 0)+1
            data.minHeight=math.min(data.minHeight,record.height); data.maxHeight=math.max(data.maxHeight,record.height)
            data.minClearance=math.min(data.minClearance,record.clearance)
        else data.rejected=data.rejected+1 end
        pauseOnce(pause)
    end
    ---@type RailwayPlantBatch
    local plants=Vegetation.NewBatch(root:CreateChild("城市行道树"))
    local treeA,treeB=Vegetation.GetAsset("treeA"),Vegetation.GetAsset("treeB")
    local parkLat=(city.zones[1] and city.zones[1].lo or -550)-26
    -- 行道树固定在建筑末排之外/对侧林带，无农田水面进入保留城市。
    for i=-8,8 do
        local asset=i%3==0 and treeB or treeA
        if asset then
            local pos=at(city,i*31-45,parkLat)
            local scale,r=Vegetation.Measure(asset,7.5+(i+19)%3)
            if Landscape.CanPlace(pos,r,30) and not Landscape.InStationYard(pos,r) then
                plants:Add(asset,pos,scale,(i*71)%360); data.trees=data.trees+1
            end
        end
        pauseOnce(pause)
    end
    if station.index==3 or station.index==4 then
        for i=-7,7 do
            local asset=i%2==0 and treeB or treeA
            if asset then
                local along=i*34-70
                local lateral=station.index==3 and 365 or parkLat-28
                local pos=at(city,along,lateral)
                local scale,r=Vegetation.Measure(asset,8+(i+16)%4)
                if Landscape.CanPlace(pos,r,30) and not Landscape.InStationYard(pos,r)
                    and not overlapsPlot(city,along,lateral,r*2,r*2,2) then
                    plants:Add(asset,pos,scale,(i*43)%360); data.trees=data.trees+1
                end
            end
            pauseOnce(pause)
        end
    end
    -- 两条楼间行道树带：在既有道路侧边，不侵入建筑/院墙包络或道路面。
    -- 每站最多20棵，冠幅先按真实bbox测量；新树仍归当前城市节点和统计所有。
    -- 从实际纵路中心取树带，按真实冠幅退到路缘外；不能用猜测横距把所有树压在道路里。
    local streets,seenStreets={},{}
    for _,road in ipairs(city.roads) do
        if road.lateral<0 and road.d==64 and road.w<20 and not seenStreets[road.lateral] then
            seenStreets[road.lateral]=true
            streets[#streets+1]={lateral=road.lateral,width=road.w}
        end
    end
    table.sort(streets,function(a,b) return a.lateral>b.lateral end)
    for row=1,math.min(2,#streets) do
        local street=streets[row]
        for i=-4,5 do
            local asset=(i+row)%3==0 and treeB or treeA
            if asset then
                local along=i*94-70
                local scale,r=Vegetation.Measure(asset,6.8+(i+row+6)%3*.6)
                -- 两侧择一，完整冠幅不跨道路，不挤进楼体或院墙；每个样点最多放一棵。
                for _,side in ipairs({1,-1}) do
                    local lat=street.lateral+side*(street.width*.5+r+2)
                    local pos=at(city,along,lat)
                    if Landscape.CanPlace(pos,r,30) and not Landscape.InStationYard(pos,r)
                        and not overlapsPlot(city,along,lat,r*2,r*2,2)
                        and not overlapsRoad(city,along,lat,r) then
                        plants:Add(asset,pos,scale,(i*71+row*43)%360)
                        data.trees=data.trees+1; data.streetTrees=data.streetTrees+1
                        data.treeData[#data.treeData+1]={x=pos.x,z=pos.z,radius=r,clearance=Route.DistanceTo(pos)-r,
                            stationIndex=station.index,kind="楼间行道树"}
                        break
                    end
                end
            end
            pauseOnce(pause)
        end
    end
    local addedTrees,hedges,plantGroups,plantBatches,plantMaterials=Planting.BuildCity(root,city,function(pos,r)
        return Landscape.CanPlace(pos,r,30) and not Landscape.InStationYard(pos,r)
    end,function(along,lateral,r)
        return overlapsPlot(city,along,lateral,r*2,r*2,1)
    end,function(along,lateral,r)
        return overlapsRoad(city,along,lateral,r)
    end,pause)
    data.trees=data.trees+addedTrees;data.streetTrees=data.streetTrees+addedTrees;data.hedges=hedges
    local _,treeGroups=plants:Finish()
    for _,group in pairs(plants.groups) do group.drawDistance=1050; group.castShadows=false end
    local modelBatches=0
    data.meshes,data.vertices,data.materialCount,modelBatches=builder:Finish(pause)
    local modelGroups=0
    for _ in pairs(builder.models) do modelGroups=modelGroups+1 end
    data.materialBatches=data.meshes-modelGroups+modelBatches+treeGroups*2+plantBatches
    data.meshes=data.meshes+plantGroups+treeGroups
    data.materialKeys=builder.materialKeys
    for material in pairs(plantMaterials) do data.materialKeys[material]=true end
    for _,group in pairs(plants.groups) do
        for slot=0,group.numGeometries-1 do data.materialKeys[tostring(group:GetMaterial(slot))]=true end
    end
    data.materialCount=0
    for _ in pairs(data.materialKeys) do data.materialCount=data.materialCount+1 end
    if not logged_["city"..station.index] then
        logged_["city"..station.index]=true
        print(string.format("[Landscape] %s：%s；%d栋/完整MDL%d，%.1f..%.1fm，%d树/%d道路段；%d材质/%d材料批，站场硬地%.0fm²；净空>=%.1fm，拒绝%d地块",
            data.name,city.style,data.buildings,data.textured,data.minHeight,data.maxHeight,data.trees,#data.paths,
            data.materialCount,data.materialBatches,data.yardArea,data.minClearance,data.rejected))
    end
end

-- 曲线带状地表按同一弧长端点拼接；不掩埋道床，不造横轨道路。
local function strip(builder,key,material,a,b,lo,hi,y)
    local center=Route.SampleOffset((a+b)*.5,(lo+hi)*.5,0)
    local r=radius(hi-lo,b-a)+1
    if Landmarks.Reserves(center,r) or not Landscape.CanPlace(center,r,30) then return false end
    builder:Batch(center,key,material,false,12):AddQuad(Route.SampleOffset(a,lo,y),Route.SampleOffset(b,lo,y),
        Route.SampleOffset(b,hi,y),Route.SampleOffset(a,hi,y))
    return true
end
local function countrysideCanal(builder,a,b,theme,data)
    if theme~="fields" and theme~="village" then return end
    local water=World.Water()
    local bank=World.DryEarth()
    for side=-1,1,2 do
        local center=Route.SampleOffset((a+b)*.5,side*310,0)
        if not Landscape.InCity(center,45) and not Landscape.InStationYard(center,45) then
            local lo,hi=side*310-4,side*310+4
            if strip(builder,"灌渠水",water,a,b,lo,hi,.025) then
                strip(builder,"田埂土",bank,a,b,lo-2,lo,.040)
                strip(builder,"田埂土",bank,a,b,hi,hi+2,.040)
                data.canals=data.canals+1
            end
        end
    end
end
local function riverSegment(builder,a,b,data)
    local s=(a+b)*.5
    local ca,cb=350+math.sin(a/1700)*42,350+math.sin(b/1700)*42
    local center=Route.SampleOffset(s,(ca+cb)*.5,0)
    if Landmarks.Reserves(center,112) or Landscape.InStationYard(center,105) then return end
    if not Landscape.CanPlace(center,112,30) then data.rejected=data.rejected+1; return end
    local water=builder:Batch(center,"江湾水",World.Water(),false,24)
    local bank=builder:Batch(center,"河岸",World.DryEarth(),false,8)
    water:AddQuad(Route.SampleOffset(a,ca-76,.027),Route.SampleOffset(b,cb-76,.027),
        Route.SampleOffset(b,cb+76,.027),Route.SampleOffset(a,ca+76,.027))
    for side=-1,1,2 do
        local loA,hiA=ca+side*76,ca+side*94
        local loB,hiB=cb+side*76,cb+side*94
        if side<0 then loA,hiA=hiA,loA; loB,hiB=hiB,loB end
        bank:AddQuad(Route.SampleOffset(a,loA,.036),Route.SampleOffset(b,loB,.036),Route.SampleOffset(b,hiB,.036),Route.SampleOffset(a,hiA,.036))
    end
    -- 路桥区沿岸公路始终在河道靠铁路侧，但离铁路至少140m。
    strip(builder,"道路",solid(Color(.27,.29,.30),0,.98),a,b,math.min(ca,cb)-113,math.min(ca,cb)-105,.052)
    data.water=data.water+1
    data.placements[#data.placements+1]={x=center.x,z=center.z,s=s,theme="water",kind="river",radius=112,clearance=Route.DistanceTo(center)-112}
end

-- 独立公路桥截面：坡道->桥台(-94)->8m桥面->桥墩(-38/+38)->桥台(+94)->坡道。
-- 所有lateral相对河湾中心，最内侧坡脚仍>140m；绝不是铁路桥，不移动轨道。
local function roadBridge(builder,s,data)
    local origin,tangent,yaw=Route.Sample(s)
    local right=Route.RightAt(s)
    local lateral=350+math.sin(s/1700)*42
    local center=origin+right*lateral
    if Landmarks.Reserves(center,170) or not Landscape.CanPlace(center,170,30) or Landscape.InCity(center,170) or Landscape.InStationYard(center,170) then return end
    local concrete=builder:Batch(center,"桥体混凝土",World.Concrete(),false,4)
    local asphalt=builder:Batch(center,"道路",solid(Color(.27,.29,.30),0,.98),false)
    local steel=builder:Batch(center,"桥栏",solid(Color(.49,.54,.56),.35,.7),false)
    local angle=math.rad(yaw)
    local function p(x,y,z) return center+right*x+tangent*z+Vector3(0,y,0) end
    concrete:AddBox(p(0,7.45,0),Vector3(220,1.1,10),angle)
    asphalt:AddBox(p(0,8.025,0),Vector3(220,.05,8.4),angle)
    for _,x in ipairs({-94,-38,38,94}) do
        concrete:AddBox(p(x,3.5,0),Vector3((x==-94 or x==94) and 9 or 5,7,8),angle)
        concrete:AddBox(p(x,.3,0),Vector3(12,.6,11),angle)
    end
    for _,z in ipairs({-4.6,4.6}) do steel:AddBox(p(0,8.7,z),Vector3(222,.85,.20),angle) end
    for side=-1,1,2 do
        concrete:AddBox(p(side*108,4,0),Vector3(8,8,11),angle)
        local x0,x1=side*110,side*166
        local a,b,c,d=p(x0,8,-5),p(x0,8,5),p(x1,.05,5),p(x1,.05,-5)
        if side<0 then a,b,c,d=d,c,b,a end
        asphalt:AddQuad(a,b,c,d)
        concrete:AddQuad(a,d,p(x1,0,-5),p(x0,0,-5))
        concrete:AddQuad(b,p(x0,0,5),p(x1,0,5),c)
    end
    data.bridges=data.bridges+1
    data.placements[#data.placements+1]={x=center.x,z=center.z,s=s,theme="water",kind="road_bridge_not_rail",radius=170,clearance=Route.DistanceTo(center)-170}
end

---@param owner Node
---@param first number 半开开放弧长区间；越界部分裁掉，禁止终点复刻起点景观。
---@param last number
---@param pause? fun()
function Landscape.BuildChunk(owner,first,last,pause)
    local key=string.format("%.3f_%.3f",first,last)
    local root=owner:CreateChild("沿线地理")
    local builder=newBuilder(root)
    ---@type RailwayPlantBatch
    local plants=Vegetation.NewBatch(root:CreateChild("低频植被"))
    local treeA,treeB=Vegetation.GetAsset("treeA"),Vegetation.GetAsset("treeB")
    local data={first=first,last=last,placements={},themes={},regions={},buildings=0,highRises=0,trees=0,grass=0,water=0,roads=0,canals=0,bridges=0,
        rejected=0,meshes=0,vertices=0,materialCount=0,materialBatches=0,groundArea=0}
    chunkData_[key]=data
    Landmarks.NoteBuildings("scenery_"..key,data)
    local a,b=clampS(first),clampS(last)
    for i=math.ceil((a-.000001)/80),math.ceil((b-.000001)/80)-1 do
        local start,finish=i*80,math.min((i+1)*80,Route.GetLength())
        local pos,r,theme,s,side,active=feature(i)
        if s>Route.GetLength() then s=(start+finish)*.5 end
        local region=Landscape.GetRegionAt(s)
        data.themes[theme]=(data.themes[theme] or 0)+1
        data.regions[region.index]=(data.regions[region.index] or 0)+1
        -- 大面积分区地表交给Terrain空间块，实际面积见terrainLandArea。
        countrysideCanal(builder,start,finish,theme,data)
        if theme=="water" then
            riverSegment(builder,start,finish,data)
            if i%43==21 then roadBridge(builder,s,data) end
        end
        local _,_,yaw=Route.Sample(s)
        local safe=active and not Landmarks.Reserves(pos,r) and Landscape.CanPlace(pos,r,30) and not Landscape.InCity(pos,r) and not Landscape.InStationYard(pos,r)
        if safe and theme~="water" then
            local warehouse=theme=="industry"
            local urban=theme=="urban"
            local cityS=Route.GetStations()[region.stationIndex].s
            local urbanWeight=1-smooth((math.abs(s-cityS)-900)/(region.index==6 and 5200 or 4700))
            local skylineHeight=22+urbanWeight*(region.index==6 and 105 or 76)+i%4*5
            ---@type RailwayLandscapePlot
            local plot={along=0,lateral=side*(pos-Route.Sample(s)):Length(),width=warehouse and 48 or (urban and 29 or 18+i%3*2),
                depth=warehouse and 58 or (urban and 38 or 25),height=warehouse and 12+i%3 or (urban and skylineHeight or 5.8+i%3*2.5),
                kind=warehouse and "warehouse" or (urban and (skylineHeight>=40 and "tower" or "slab") or "villa"),variant=i,district=region.name,pitched=not urban}
            local actualRadius=radius(plot.width,plot.depth,3)
            if Landscape.CanPlace(pos,actualRadius,30) then
                local record=building(builder,pos,plot,yaw,region.stationIndex,pause)
                -- 工业院坪按真实MDL体量每边留4m，不再用48×58规划地块铺满大院。
                -- 城市BuildCity仓库高度及铺面规划不受该沿线分支影响。
                local apronWidth=warehouse and record.width+8 or plot.width+4
                local apronDepth=warehouse and record.depth+8 or plot.depth+4
                local apronRadius=radius(apronWidth,apronDepth)
                record.radius=math.max(record.radius,apronRadius)
                record.x,record.z,record.s,record.theme,record.region=pos.x,pos.z,s,theme,region.index
                record.clearance=Route.DistanceTo(pos)-record.radius
                assert(Landscape.CanPlace(pos,record.radius,30),"[Landscape] 实际建筑/院坪包络越过铁路净空")
                data.placements[#data.placements+1]=record; data.buildings=data.buildings+1
                if record.height>=40 then data.highRises=data.highRises+1 end
                strip(builder,"道路",solid(Color(.27,.29,.30),0,.98),start,finish,side*82-3.5,side*82+3.5,.044)
                data.roads=data.roads+1
                local apron=builder:Batch(pos,"混凝土",World.Concrete(),false,8)
                apron:AddBox(pos+Vector3(0,.014,0),Vector3(apronWidth,.024,apronDepth),math.rad(yaw))
                if warehouse then record.apronWidth,record.apronDepth=apronWidth,apronDepth end
            end
        elseif active and not safe then data.rejected=data.rejected+1 end
        -- 林丘主要用Terrain低多边形坡面；近景树低频，田面内不种树。
        local count=theme=="village" and (i%3==0 and 1 or 0) or (theme=="water" and (i%4==0 and 1 or 0) or (i%5==0 and 1 or 0))
        for j=1,count do
            local asset=(i+j)%3==0 and treeB or treeA
            if asset then
                local treeSide=j%2==0 and 1 or -1
                local lat=theme=="village" and 58+hash(i,j)*16 or (theme=="water" and -130-hash(i,j)*55 or 52+hash(i,j)*18)
                local treePos=Route.SampleOffset(clampS(start+10+hash(i,j+20)*60),treeSide*math.abs(lat),0)
                if theme=="water" then treePos=Route.SampleOffset(clampS(start+20),lat,0) end
                if GameConfig.MountainTerrain then
                    treePos=Vector3(treePos.x,Mountain.GetGroundHeight(treePos.x,treePos.z),treePos.z)
                end
                local scale,rr=Vegetation.Measure(asset,7+hash(i,j+40)*3)
                if Landscape.CanPlace(treePos,rr,30) and not Landscape.ReservesNature(treePos,rr) and not Landscape.FieldAllowed(treePos,rr+20) then
                    plants:Add(asset,treePos,scale,hash(i,j+70)*360); data.trees=data.trees+1
                end
            end
            pauseOnce(pause)
        end
        pauseOnce(pause)
    end
    local _,treeGroups=plants:Finish()
    for _,group in pairs(plants.groups) do group.drawDistance=580; group.castShadows=false end
    local modelBatches=0
    data.meshes,data.vertices,data.materialCount,modelBatches=builder:Finish(pause)
    local modelGroups=0
    for _ in pairs(builder.models) do modelGroups=modelGroups+1 end
    data.materialBatches=data.meshes-modelGroups+modelBatches+treeGroups*2
    data.materialKeys=builder.materialKeys
    for _,group in pairs(plants.groups) do
        for slot=0,group.numGeometries-1 do data.materialKeys[tostring(group:GetMaterial(slot))]=true end
    end
    data.materialCount=0
    for _ in pairs(data.materialKeys) do data.materialCount=data.materialCount+1 end
    for regionIndex in pairs(data.regions) do
        if not logged_["region"..regionIndex] then
            logged_["region"..regionIndex]=true
            print(string.format("[Landscape] %s 局部%.0f..%.0fm：%d楼/%d树/%d连续江湾/%d灌渠/%d公路桥；%d材质/%d材料批",
                assert(regions_[regionIndex]).name,first,last,data.buildings,data.trees,data.water,data.canals,data.bridges,data.materialCount,data.materialBatches))
        end
    end
    return data.vertices
end
function Landscape.ForgetStation(index)
    cityData_[index]=nil
    Landmarks.ForgetBuildings("city_"..index)
end
function Landscape.ForgetChunk(first,last)
    local key=string.format("%.3f_%.3f",first,last)
    chunkData_[key]=nil
    Landmarks.ForgetBuildings("scenery_"..key)
end
function Landscape.Shutdown()
    corridorExclusion_=nil
    cities_,cityData_,chunkData_,logged_,regions_,groundCuts_,industrySides_={},{},{},{},{},{},{}
end
function Landscape.GetPlacementData()
    local result={}
    for _,data in pairs(cityData_) do for _,item in ipairs(data.placements) do result[#result+1]=item end end
    return result
end
function Landscape.GetPathData()
    local result={}
    for _,data in pairs(cityData_) do for _,item in ipairs(data.paths) do result[#result+1]=item end end
    return result
end
function Landscape.GetStats()
    local stats={cities={},chunks={},loadedBuildings=0,loadedHighRises=0,loadedTrees=0,loadedWater=0,loadedChunks=0,themes={},plannedCities={},
        regions={},loadedCanals=0,loadedRoadBridges=0,loadedMaterialBatches=0,loadedMaterialCount=0,batchCellSize=Landscape.BatchCellSize,
        stationYardArea=0,railClearance=Landscape.RailClearance,themeCycle=false}
    local materials={}
    for _,region in ipairs(regions_) do stats.regions[#stats.regions+1]=region end
    for _,city in ipairs(cities_) do
        local minH,maxH=math.huge,0
        for _,plot in ipairs(city.plots) do minH=math.min(minH,plot.height); maxH=math.max(maxH,plot.height) end
        stats.plannedCities[#stats.plannedCities+1]={stationIndex=city.station.index,name=displayNames_[city.station.index] or "城镇站",style=city.style,
            buildings=#city.plots,minHeight=minH,maxHeight=maxH,streetSegments=#city.roads,ground=city.ground}
    end
    local function addMaterials(data)
        stats.loadedHighRises=stats.loadedHighRises+(data.highRises or 0)
        stats.loadedMaterialBatches=stats.loadedMaterialBatches+(data.materialBatches or 0)
        for key in pairs(data.materialKeys or {}) do materials[key]=true end
    end
    for _,data in pairs(cityData_) do
        stats.cities[#stats.cities+1]=data; stats.loadedBuildings=stats.loadedBuildings+data.buildings; stats.loadedTrees=stats.loadedTrees+data.trees
        stats.stationYardArea=stats.stationYardArea+data.yardArea
        addMaterials(data)
    end
    for _,data in pairs(chunkData_) do
        stats.chunks[#stats.chunks+1]=data; stats.loadedBuildings=stats.loadedBuildings+data.buildings; stats.loadedTrees=stats.loadedTrees+data.trees
        stats.loadedWater=stats.loadedWater+data.water; stats.loadedChunks=stats.loadedChunks+1
        stats.loadedCanals=stats.loadedCanals+data.canals; stats.loadedRoadBridges=stats.loadedRoadBridges+data.bridges
        for theme,n in pairs(data.themes) do stats.themes[theme]=(stats.themes[theme] or 0)+n end
        addMaterials(data)
    end
    for _ in pairs(materials) do stats.loadedMaterialCount=stats.loadedMaterialCount+1 end
    return stats
end
return Landscape
