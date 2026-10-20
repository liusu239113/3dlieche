-- 城市街道与近轨绿篱：只使用本地带枝叶的真实MDL，空间实例组由城市/流式块持有。
local Vegetation = require "world.Vegetation"
local Mountain = require "world.MountainProfile"
local Route = require "world.Route"
local Config = require "config.GameConfig"
local Planting = {}
---@class RailwayCorridorPlantOptions
---@field density number
---@field treeDistance number
---@field shadows boolean
---@field ground fun(x:number,z:number):number
---@field blocked fun(pos:Vector3,radius:number):string?
---@field forest fun(kind:string):RailwayPlantAsset?
---@type table<string, table>
local corridorData_={}
local loggedLayers_={}
local function corridorKey(first,last,layer) return string.format("%.3f_%.3f_%s",first,last,layer or "all") end
-- 宽林带只保留缓慢起伏的地貌形态，具体实例另做稳定散布；不按每行重新播种。
local function beltWander(s,phase)
    return math.sin(s/83+phase)*7+math.sin(s/193+phase*1.7)*5
end
-- 有限的本地种组：每个约192m生境只含主/辅两形，跨生境平滑换组。
-- 实图LOD0/2对照确认B/F源树形稀枝，不适合作普通连片林；保留七种目录，
-- 本走廊只种五种适宜主形，B/F占比0（低于近层8%上限），不提高LOD或面数。
---@type string[][]
local communities={
    {"treeA","treeD"},{"treeA","treeC"},{"treeG","treeE"},
    {"treeA","treeG"},{"treeC","treeD"},{"treeG","treeA"},{"treeG","treeE"},
}
local stature={treeA=1,treeB=.93,treeC=.80,treeD=1.13,treeE=.68,treeF=1.18,treeG=.81}
local function communityAt(s,side,layerIndex)
    local cell=math.floor(s/192)
    local index=(cell+layerIndex*2)%#communities+1
    return communities[index],cell
end
function Planting.ResetCorridor() corridorData_,loggedLayers_={},{} end
function Planting.ForgetCorridor(first,last,layer) corridorData_[corridorKey(first,last,layer)]=nil end
function Planting.GetCorridorStats()
    local out={chunks={},layers={},accepted=0,attempted=0,rejected={}}
    for _,data in pairs(corridorData_) do
        out.chunks[#out.chunks+1]=data
        out.accepted=out.accepted+data.accepted;out.attempted=out.attempted+data.attempted
        for reason,count in pairs(data.rejected) do out.rejected[reason]=(out.rejected[reason] or 0)+count end
        for layer,count in pairs(data.layers) do out.layers[layer]=(out.layers[layer] or 0)+count end
    end
    return out
end
-- 净空设计（XZ，米，所有完整冠幅仍离主线>=30）：
-- rails 0/+5 | fence | maintenance 0..32 | grass 33..39 | shrubs 38..46
--             | clustered trees 48..78 | mixed copses 114..240 | shelter forest 398..450
-- 保留区不是物理；每株先查全线解析包络，再采实际地表。桥/隧/田/城不让步。
-- 一簇只用一种树（跨64m/簇换种），沿向交错+两三排有景深，不是随机孤立单排。
---@param owner Node
---@param first number
---@param last number
---@param options RailwayCorridorPlantOptions
---@param pause? fun()
---@param layer? string
function Planting.BuildCorridor(owner,first,last,options,pause,layer)
    local key=corridorKey(first,last,layer)
    local root=owner:CreateChild("沿线植被_"..(layer or "all"))
    local data={first=first,last=last,layer=layer or "all",accepted=0,attempted=0,rejected={},layers={},records={},groups=0,species={},sides={left=0,right=0}}
    corridorData_[key]=data
    local density=math.sqrt(math.max(.35,options.density))
    local seed=(Config.WorldStream and Config.WorldStream.Seed) or 20261006
    -- 混合索引和行号后再取小数，避免线性同余的相邻值形成固定树高/间距条纹。
    local function random(i,salt)
        local value=math.sin(i*127.1+salt*311.7+seed*.017)*43758.5453
        return value-math.floor(value)
    end
    local yieldCounter=0
    local function yield()
        yieldCounter=yieldCounter+1
        -- 每四株让出一次，仍保持小切片；逐株yield使32slice上限先于3ms耗尽，
        -- 真实草带会无谓拖成数秒。非实例大任务的暂停策略保持原状。
        if pause and yieldCounter%4==0 then pause() end
    end
    local function rejection(reason) data.rejected[reason]=(data.rejected[reason] or 0)+1 end
    local safeLowCells={} ---@type table<string,boolean>
    local function lowBlocked(raw,r)
        -- 只缓存完整4m格+最大冠幅均安全的正结果；失败格仍逐株精查，
        -- 不是把地块中心安全误当整块安全。连续草带共享判定减少重复BVH/保留区投影。
        local x,z=math.floor(raw.x/4),math.floor(raw.z/4)
        local radius=math.ceil(r*2)*.5
        local key=x.."_"..z.."_"..radius
        if safeLowCells[key] then return nil end
        local broad=options.blocked(Vector3(x*4+2,0,z*4+2),radius+math.sqrt(8))
        if not broad then safeLowCells[key]=true;return nil end
        return options.blocked(raw,r)
    end
    local function add(batch,asset,s,lat,height,yaw,identity,low,species)
        data.attempted=data.attempted+1
        if not asset then rejection("asset");return false end
        local scale,r=Vegetation.Measure(asset,height)
        local raw=Route.SampleOffset(s,lat,0)
        local reason=nil ---@type string?
        if low then reason=lowBlocked(raw,r) else reason=options.blocked(raw,r) end
        if reason then rejection(reason);return false end
        local y=options.ground(raw.x,raw.z)
        -- 低植被包围盒底贴合坡面的最低点，允许几厘米根部埋土，不把整团草悬在坡上。
        if low then
            local dx,dz=Route.RightAt(s)*r*.65,Route.TangentAt(s)*r*.65
            local a,b=options.ground(raw.x+dx.x,raw.z+dx.z),options.ground(raw.x-dx.x,raw.z-dx.z)
            local c,d=options.ground(raw.x+dz.x,raw.z+dz.z),options.ground(raw.x-dz.x,raw.z-dz.z)
            if math.max(y,a,b,c,d)-math.min(y,a,b,c,d)>height*.75+.12 then rejection("slope");return false end
            y=math.min(y,a,b,c,d)-.025
        end
        batch:Add(asset,Vector3(raw.x,y,raw.z),scale,yaw)
        data.accepted=data.accepted+1;data.layers[identity]=(data.layers[identity] or 0)+1
        local plantKind=species or identity
        data.species[plantKind]=(data.species[plantKind] or 0)+1
        local side=lat<0 and "left" or "right"
        data.sides[side]=data.sides[side]+1
        data.records[#data.records+1]={s=s,lateral=lat,x=raw.x,y=y,z=raw.z,radius=r,kind=identity,height=height,species=plantKind,yaw=yaw}
        return true
    end
    local function finish(batch,draw,shadows)
        local _,groups=batch:Finish();data.groups=data.groups+groups
        for _,group in pairs(batch.groups) do
            group.drawDistance=draw;group.castShadows=shadows
            group.shadowDistance=shadows and 100 or 0;group.lodBias=.65
        end
        yield()
    end
    -- 地表负责连续底色，真草/灌木只承担近景体积。不用四行密铺到370m，
    -- 以8..20m的草丛斑块、林缘矮灌、维护缺口替代等距两条绿墙。
    if not layer or layer=="near" then
        local grasses=Vegetation.NewBatch(root:CreateChild("近线自然草丛"))
        local bushes=Vegetation.NewBatch(root:CreateChild("林缘低灌丛"))
        local bush,grass=Vegetation.GetAsset("bush"),Vegetation.GetAsset("grass")
        local pitch=math.max(1.4,2.15/density)
        for row=1,4 do
            for i=math.floor(first/pitch)-1,math.ceil(last/pitch) do
                for _,side in ipairs({-1,1}) do
                    local noise=random(i,row*17+side)
                    local s=i*pitch+(.18+row*.11+(noise-.5)*.58)*pitch
                    if s>=first and s<last then
                        local patch=random(math.floor(s/13),row*3+side*11)
                        if patch>.16 and noise>.08 then
                            local lat=32.6+(row-1)*1.85+noise*1.55
                                +math.sin(s/17+side+row)*.8
                            local height=.21+random(i,row*31+side)*.095
                            add(grasses,grass,s,side*lat,height,noise*360,"grass",true)
                        end
                        yield()
                        if row>=3 and patch>.28 and noise>.18 then
                            local lat=38.8+(row-3)*2.1+noise*1.3+math.sin(s/23+side)*.75
                            add(bushes,bush,s,side*lat,.50+random(i,row*41+side)*.36,noise*233,"bush",true)
                            yield()
                        end
                    end
                end
            end
        end
        finish(grasses,180,false)
        finish(bushes,240,false)
    end
    local layers={
        {name="near",pitch=15,rows=3,offset=43,width=10,height=5.9,variation=3.7,draw=math.max(650,options.treeDistance),lod=false},
        {name="middle",pitch=15,rows=3,offset=122,width=17,height=10.5,variation=5,draw=1250,lod=true},
        {name="distant",pitch=11,rows=4,offset=398,width=14,height=15,variation=5.5,draw=1800,lod=true},
    }
    for layerIndex,definition in ipairs(layers) do
        if not layer or definition.name==layer then
            local trees=Vegetation.NewBatch(root:CreateChild("成组真实林_"..definition.name))
            local pitch=definition.pitch/math.min(1.3,density)
            local layerAssets={} ---@type table<string,RailwayPlantAsset>
            local function treeAsset(kind)
                if layerAssets[kind] then return layerAssets[kind] end
                local source=definition.lod and options.forest(kind) or Vegetation.GetAsset(kind)
                if not source then return nil end
                local asset={name=(definition.lod and "BeltLOD_" or "Belt_")..kind,
                    model=source.model,materials=source.materials,bounds=source.bounds,
                    drawDistance=definition.draw,shadowDistance=source.shadowDistance,
                    shadows=source.shadows,batchSize=256}
                layerAssets[kind]=asset
                return asset
            end
            for i=math.floor(first/pitch)-1,math.ceil(last/pitch) do
                for _,side in ipairs({-1,1}) do
                    for row=1,definition.rows do
                        local v=random(i,layerIndex*19+row*7+side)
                        local s=i*pitch+(row-1)*pitch/definition.rows+(v-.5)*pitch*.92
                        if s>=first and s<last then
                            local community,cell=communityAt(s,side,layerIndex)
                            -- 后排主树与前排伴生幼树，局部仅两种，64m内复用实例批。
                            local kind=community[row==1 and 2 or 1]
                            local cluster=random(math.floor(s/37),layerIndex*29+side)
                            local clearing=random(math.floor(s/23),layerIndex*47+side)
                            -- 一侧林窗不镜像复制到对侧；保留远层背景，近林缘留出空隙。
                            if clearing>(definition.name=="distant" and .08 or .18) then
                                local asset=treeAsset(kind)
                                local lat=definition.offset+(row-1)*definition.width+(v-.5)*definition.width*1.6+cluster*5
                                local wander=beltWander(s,layerIndex*1.3+side*.7)
                                if definition.name=="near" then lat=math.max(40.5,lat+wander*.6)
                                else lat=lat+wander end
                                local age=random(i,row*13+side+71)
                                local height=(definition.height+age*definition.variation+(row-1)*1.25)
                                    *stature[kind]*(.94+random(cell,side+layerIndex)*.12)
                                for trial=0,2 do
                                    if add(trees,asset,s,side*(lat+trial*7),height,v*360,definition.name,false,kind) then break end
                                    yield()
                                end
                            end
                            yield()
                        end
                    end
                end
            end
            finish(trees,definition.draw,definition.name=="near" and options.shadows)
        end
    end
    local identity=layer or "all"
    if not loggedLayers_[identity] then
        loggedLayers_[identity]=true
        print(string.format("[CorridorPlanting] %s %.0f..%.0fm accepted=%d/%d grass=%d bush=%d tree=%d/%d/%d fieldRejected=%d structureRejected=%d cityRejected=%d groups=%d",
            identity,first,last,data.accepted,data.attempted,data.layers.grass or 0,data.layers.bush or 0,
            data.layers.near or 0,data.layers.middle or 0,data.layers.distant or 0,
            data.rejected.field or 0,data.rejected.structure or 0,data.rejected.city or 0,data.groups))
    end
    return 0
end

-- 所有候选都先校验完整bbox外包圆；树冠不能侵入楼体、道路、站场或多线铁路。
-- 树带使用64m实例批、原生网格LOD；灌木短视距，不生成球冠或绿盒。
---@param root Node
---@param city RailwayCityPlan
---@param canPlace fun(pos:Vector3,r:number):boolean
---@param hitsPlot fun(along:number,lateral:number,r:number):boolean
---@param hitsRoad fun(along:number,lateral:number,r:number):boolean
---@param pause? fun()
function Planting.BuildCity(root,city,canPlace,hitsPlot,hitsRoad,pause)
    local plants=Vegetation.NewBatch(root:CreateChild("城市连续绿篱与街树"))
    local bushes=Vegetation.NewBatch(root:CreateChild("城市低灌木实例"))
    local bush=Vegetation.GetAsset("bush")
    local streets,seen={},{}
    local trees,hedges=0,0
    local function at(along,lateral)
        local pos=city.origin+city.tangent*along+city.right*lateral
        -- 车站附近水平城市平台优先；山城远端按实际地表贴地。
        if Mountain.IsActiveAt(city.station.s) then
            return Vector3(pos.x,Mountain.GetGroundHeight(pos.x,pos.z),pos.z)
        end
        return pos
    end
    for _,road in ipairs(city.roads) do
        if road.d==64 and road.w<20 and not seen[road.lateral] then
            seen[road.lateral]=true
            streets[#streets+1]={lateral=road.lateral,width=road.w}
        end
    end
    table.sort(streets,function(a,b) return math.abs(a.lateral)<math.abs(b.lateral) end)
    for row=1,math.min(3,#streets) do
        local street=streets[row]
        -- 24m街树间距，街区密度不是只在末排外放17棵树。
        for along=-336,336,24 do
            -- 城市仍保留原街树坑/道路净空，只在街段内用同一主树种和自然树龄。
            local community=communityAt(along+384,row%2==0 and 1 or -1,row)
            local kind=community[1]
            local asset=Vegetation.GetAsset(kind)
            if asset then
                local variation=(math.sin(along*1.37+row*19.1)*43758.5453)%1
                local scale,r=Vegetation.Measure(asset,(5.8+variation*2.5)*stature[kind])
                for _,side in ipairs({-1,1}) do
                    local lat=street.lateral+side*(street.width*.5+r+1.2)
                    local pos=at(along,lat)
                    if canPlace(pos,r) and not hitsPlot(along,lat,r) and not hitsRoad(along,lat,r) then
                        plants:Add(asset,pos,scale,(along*7+row*41)%360);trees=trees+1
                    end
                end
            end
            if pause then pause() end
        end
        if bush then
            local scale,r=Vegetation.Measure(bush,.7)
            -- 每组8m连贯绿篱，中间留4m开口；真实叶片而非实体方形围墙。
            local spacing=math.max(1.35,r*1.4)
            for along=-300,300,spacing do
                if along%12<8 then
                    local lat=street.lateral+street.width*.5+r+1.15
                    local pos=at(along,lat)
                    if canPlace(pos,r) and not hitsPlot(along,lat,r) and not hitsRoad(along,lat,r) then
                        bushes:Add(bush,pos,scale,(along*31)%360);hedges=hedges+1
                    end
                end
                if pause then pause() end
            end
        end
    end
    for _,group in pairs(plants.groups) do
        group.drawDistance=1050;group.shadowDistance=100;group.castShadows=true;group.lodBias=.6
    end
    for _,group in pairs(bushes.groups) do
        group.drawDistance=210;group.castShadows=false;group.lodBias=.6
    end
    local materials={} ---@type table<string,boolean>
    local groups,batches=0,0
    for _,collection in ipairs({plants.groups,bushes.groups}) do
        for _,group in pairs(collection) do
            groups=groups+1;batches=batches+group.numGeometries
            for slot=0,group.numGeometries-1 do materials[tostring(group:GetMaterial(slot))]=true end
        end
    end
    return trees,hedges,groups,batches,materials
end
return Planting
