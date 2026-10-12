-- 星汐—云湾开放走廊的铁路地标。仅几何/环境分类，不改线路、股道、信号或车辆。
-- 基于现有WorldMaterials CustomGeometry合批；归WorldStream的scenery协程/节点所有。
-- 净空截面（米；lateral相对Route主线）：
--                     拱冠Y=12.6
--              /-------------------\
-- Y=8.8最小顶 /                     \ Y=8.8
-- 墙x=-12.0 | lane1=-5  lane0/2=0   | 墙x=+7.0
--            |                       |
--            +---原道床/轨面Y不变----+
-- 隧道仅选站外直线：距站点>=1000且避开s-760..s+460站场，站外lane2与lane0重合。
-- 桥：道床底Y=.002 > 桥面Y=-.18 > 下梁/桥墩；全幅谷地切掉平地保底和Terrain地表。
-- 相机仅射线mask4；障碍表面用viewMask6（同时正常相机3可见），非障碍河床用2。
-- 已查实际站外接触网杆顶Y=7.90、基础外缘X=-10.325/+5.325，均在内壁/8.79门户以下。
local Route = require "world.Route"
local World = require "world.WorldMaterials"
local Landmarks = {}
Landmarks.TunnelCenter = -2.5
Landmarks.TunnelHalfWidth = 9.5
Landmarks.TunnelWallHeight = 8.8
Landmarks.TunnelCrownHeight = 12.6
Landmarks.BridgeDeckTop = -.18

---@class RailwayLandmark
---@field id string
---@field kind string
---@field name string
---@field first number
---@field last number
---@field s number
---@field lateral number
---@field halfWidth number
---@field height number
---@field depth number
---@field waterY number
---@field innerHalfWidth? number
---@field wallHeight? number
---@field crownHeight? number
---@field portalHalfWidth? number
---@field portalWallHeight? number
---@field portalCrownHeight? number
---@field stationClearance? number
---@field deckTop? number
---@type RailwayLandmark[]
local definitions_ = {}
---@type RailwayLandmark[]
local bridges_ = {}
---@type RailwayLandmark[]
local tunnels_ = {}
---@type RailwayLandmark[]
local mountains_ = {}
---@type table<string, table>
local chunks_ = {}
---@type table<string, table>
local buildings_ = {}
---@type table<string, Node>
local owners_ = {}
---@type table<string, Material>
local materials_ = {}
---@type table[]
local cuts_ = {}
---@type number
local routeLength_ = -1
local function pauseOnce(pause) if pause then pause() end end
local function smooth(v)
    local t=math.max(0,math.min(1,v))
    return t*t*(3-2*t)
end
local function solid(key,color,metallic,roughness)
    if not materials_[key] then materials_[key]=World.Solid(color,metallic or 0,roughness or .96) end
    return materials_[key]
end
local function textured(key,path,color,roughness)
    if not materials_[key] then
        materials_[key]=World.Textured("Landmarks_"..key,path,color,roughness or .97)
    end
    return materials_[key]
end
local function rockMaterial()
    return textured("weatheredRock","Textures/Railway/ballast.png",Color(.64,.65,.60))
end
local function grassMaterial()
    return textured("slopeGrass","Textures/Railway/grass.png",Color(.82,.87,.76),.98)
end
local function point(s,x,y) return Route.SampleOffset(s,x,y) end
local function add(def)
    definitions_[#definitions_+1]=def
    if def.kind=="bridge" then bridges_[#bridges_+1]=def
    elseif def.kind=="tunnel" then tunnels_[#tunnels_+1]=def
    else mountains_[#mountains_+1]=def end
end
local function stationGap(a,b)
    local nearest=math.huge
    for _,st in ipairs(Route.GetStations()) do
        nearest=math.min(nearest,math.max(a-st.s,st.s-b,0))
        if b>st.s-1000 and a<st.s+1000 then return false,nearest end
        if b>st.s-760 and a<st.s+460 then return false,nearest end
    end
    return true,nearest
end
local function bounds(poly)
    local x0,x1,z0,z1=math.huge,-math.huge,math.huge,-math.huge
    for _,p in ipairs(poly) do x0,x1=math.min(x0,p.x),math.max(x1,p.x); z0,z1=math.min(z0,p.z),math.max(z1,p.z) end
    return x0,x1,z0,z1
end
function Landmarks.Init()
    definitions_,bridges_,tunnels_,mountains_,cuts_,chunks_,buildings_,owners_={},{},{},{},{},{},{},{}
    routeLength_=Route.GetLength()
    local straight=0
    for _,seg in ipairs(Route.GetSegments()) do
        if seg.type=="straight" then
            straight=straight+1
            if seg.landmark=="bridge_a" or seg.landmark=="bridge_b" then
                local first=seg.s+(seg.length-640)*.5
                local last=first+640
                if last-first>=400 and stationGap(first,last) then
                    local def={id="rail_bridge_"..straight,kind="bridge",name=seg.landmark=="bridge_a" and "星汐青川铁路桥" or "镜澜深谷铁路桥",
                        first=first,last=last,s=(first+last)*.5,lateral=-2.5,halfWidth=520,height=0,
                        depth=seg.landmark=="bridge_a" and 38 or 46,waterY=seg.landmark=="bridge_a" and -27 or -34}
                    add(def)
                    local poly={point(first,def.lateral-def.halfWidth,0),point(last,def.lateral-def.halfWidth,0),
                        point(last,def.lateral+def.halfWidth,0),point(first,def.lateral+def.halfWidth,0)}
                    local x0,x1,z0,z1=bounds(poly)
                    cuts_[#cuts_+1]={points=poly,x0=x0,x1=x1,z0=z0,z1=z1}
                end
            elseif seg.landmark=="tunnel_a" or seg.landmark=="tunnel_b" then
                local first=seg.s+600
                local last=seg.s+seg.length-600
                if last-first>=600 and stationGap(first,last) then
                    add({id="rail_tunnel_"..straight,kind="tunnel",name=seg.landmark=="tunnel_a" and "岚港翠岭隧道" or "榆岑云脊隧道",
                        first=first,last=last,s=(first+last)*.5,lateral=-2.5,halfWidth=360,
                        height=seg.landmark=="tunnel_a" and 215 or 265,depth=0,waterY=0})
                end
            end
        end
    end
    -- 单独可见山峰按固定弧长布置，仅规划数十项；不是全线生成顶点。
    -- 椭圆基底半宽230m/半长310m；最内缘距铁路>=190m，两侧无遮挡大山而非几棵树。
    local index=0
    for s=6900,routeLength_-2200,1150 do
        local inTunnel=false
        for _,t in ipairs(tunnels_) do if s>t.first-550 and s<t.last+550 then inTunnel=true end end
        for _,b in ipairs(bridges_) do if s>b.first-500 and s<b.last+500 then inTunnel=true end end
        local nearCity=false
        for _,st in ipairs(Route.GetStations()) do if math.abs(s-st.s)<1600 then nearCity=true end end
        if not inTunnel and not nearCity then
            index=index+1
            local side=index%2==0 and 1 or -1
            add({id="ridge_"..index,kind="mountain",name="翠岭山峰"..index,first=s-310,last=s+310,s=s,
                lateral=side*(440+(index%3)*120),halfWidth=230,height=170+(index*43)%111,depth=0,waterY=0})
        end
    end
    print(string.format("[Landmarks] 已规划%d座铁路桥/%d条双线真隧道/%d座170..280m山峰；轨面保持Y=.34",#bridges_,#tunnels_,#mountains_))
    for _,def in ipairs(definitions_) do
        if def.kind~="mountain" then
            local _,gap=stationGap(def.first,def.last)
            def.stationClearance=gap
            if def.kind=="tunnel" then
                def.innerHalfWidth=9.5; def.wallHeight=8.8; def.crownHeight=12.6
                def.portalHalfWidth=9.48; def.portalWallHeight=8.79; def.portalCrownHeight=12.58
            else def.deckTop=-.18 end
            print(string.format("[Landmarks] %s %.2f..%.2fkm，最近站点净距%.0fm",def.name,def.first/1000,def.last/1000,gap))
        end
    end
end
local function ensure() if routeLength_~=Route.GetLength() then Landmarks.Init() end end
function Landmarks.GetDefinitions() ensure(); return definitions_ end
function Landmarks.GetLandmarks() return Landmarks.GetDefinitions() end
function Landmarks.GetGroundCuts() ensure(); return cuts_ end

-- 精确XZ凸多边形差集。这里只切铁路谷地；Landscape已有站场/街块cut由其继续管理。
local function clip(poly,a,b,positive)
    local out={}
    local function value(p) return (b.x-a.x)*(p.z-a.z)-(b.z-a.z)*(p.x-a.x) end
    local previous=poly[#poly]
    if not previous then return out end
    local pv=value(previous)
    local pi=positive and pv>=-.000001 or (not positive and pv<=.000001)
    for _,current in ipairs(poly) do
        local cv=value(current)
        local ci=positive and cv>=-.000001 or (not positive and cv<=.000001)
        if ci~=pi then out[#out+1]=previous+(current-previous)*(pv/(pv-cv)) end
        if ci then out[#out+1]=current end
        previous,pv,pi=current,cv,ci
    end
    return out
end
function Landmarks.ClipGround(poly)
    ensure()
    local pieces={poly}
    local x0,x1,z0,z1=bounds(poly)
    for _,cut in ipairs(cuts_) do
        if x1>cut.x0 and x0<cut.x1 and z1>cut.z0 and z0<cut.z1 then
            local nextPieces={}
            for _,piece in ipairs(pieces) do
                local remaining=piece
                for i,a in ipairs(cut.points) do
                    local b=assert(cut.points[i%#cut.points+1])
                    local outside=clip(remaining,a,b,true)
                    if #outside>=3 then nextPieces[#nextPieces+1]=outside end
                    remaining=clip(remaining,a,b,false)
                    if #remaining<3 then break end
                end
            end
            pieces=nextPieces
        end
    end
    return pieces
end
---@param pos Vector3
---@param radius? number
function Landmarks.Reserves(pos,radius)
    ensure()
    local r=radius or 0
    local _,s=Route.DistanceTo(pos)
    local lateral=(pos-Route.Sample(s)):DotProduct(Route.RightAt(s))
    for _,def in ipairs(definitions_) do
        if s+r>=def.first and s-r<=def.last and math.abs(lateral-def.lateral)<def.halfWidth+r then return true end
    end
    return false
end
---@param s number
---@return string environment urban/forest/water/tunnel；稳定逻辑分类，不依赖加载/卸载
function Landmarks.GetEnvironmentAt(s)
    ensure()
    local value=Route.Wrap(s)
    for _,t in ipairs(tunnels_) do if value>=t.first and value<t.last then return "tunnel" end end
    for _,b in ipairs(bridges_) do if value>=b.first-220 and value<b.last+220 then return "water" end end
    local stations=Route.GetStations()
    for _,st in ipairs(stations) do
        local radius=st.index==1 and 3300 or (st.index==5 and 4200 or (st.index==2 and 2100 or 1300))
        if math.abs(value-st.s)<radius then return "urban" end
    end
    local st4=stations[4]
    if st4 and value>st4.s+1700 and value<st4.s+4500 then return "water" end
    return "forest"
end
local function batch(owner,name,material,obstacle,tile)
    local result=World.NewBatch(owner:CreateChild(name),material,false,tile or 8)
    result.geometry.viewMask=obstacle and 6 or 2
    result.geometry.drawDistance=2600
    return result
end
-- 显式正反三角形，各面使用自己法线。不能只翻normal而保留被剔除的绕序。
local function doubleQuad(target,a,b,c,d)
    target:AddQuad(a,b,c,d)
    target:AddQuad(d,c,b,a)
end
local function section(yWall,crown,halfWidth)
    local pts={Vector2(-halfWidth,-.15),Vector2(-halfWidth,yWall)}
    for i=1,12 do
        local theta=math.pi-math.pi*i/12
        pts[#pts+1]=Vector2(math.cos(theta)*halfWidth,yWall+math.sin(theta)*(crown-yWall))
    end
    pts[#pts+1]=Vector2(halfWidth,-.15)
    return pts
end
local function worldSection(s,profile)
    local result={}
    for _,v in ipairs(profile) do result[#result+1]=point(s,Landmarks.TunnelCenter+v.x,v.y) end
    return result
end
local function sweep(target,a,b,profile,doubleSided)
    local aa,bb=worldSection(a,profile),worldSection(b,profile)
    for i=1,#profile-1 do
        if doubleSided then doubleQuad(target,aa[i],bb[i],bb[i+1],aa[i+1])
        else target:AddQuad(aa[i],bb[i],bb[i+1],aa[i+1]) end
    end
end
-- 仅外轮廓：偏心岩肩/草坡共享15点拓扑，40m截面和240m块接缝使用同一解析函数。
-- 两侧基脚、端点弧长和最大冠高不变；不调用/修改实际运营内孔的section。
local outerHeights_={0,.22,.42,.58,.77,.91,1,.86,.83,.59,.46,.27,0}
local function outerSection(def,s)
    local t=(s-def.first)/(def.last-def.first)
    local weight=math.sin(math.pi*math.max(0,math.min(1,t)))^.65
    local crown=38+(def.height-38)*weight
    local width=60+(def.halfWidth-60)*weight
    local phase=def.s/700+t*math.pi*2
    local pts={Vector2(-width,-.15),Vector2(-width,4)}
    for i=1,12 do
        local theta=math.pi-math.pi*i/12
        local eccentric=width*math.sin(theta)*(.09*math.sin(phase)+.05*math.sin(theta*3+phase))
        local shoulder=assert(outerHeights_[i+1])*(1-.07*math.sin(theta*3+phase)^2*math.abs(math.cos(theta)))
        pts[#pts+1]=Vector2(math.cos(theta)*width+eccentric,4+(crown-4)*shoulder)
    end
    pts[#pts+1]=Vector2(width,-.15)
    return pts
end
local function shellQuad(rock,grass,index,a,b,c,d)
    -- 草从基脚沿两侧缓坡上行；中间露岩保留实面棱线，不叠加共面贴片。
    local target=(index<=4 or index>=11) and grass or rock
    doubleQuad(target,a,b,c,d)
end
local function portal(owner,def,s,back,data,pause)
    local concrete=batch(owner,"开口混凝土门户_"..s,World.Concrete(),true,3)
    local inner=section(8.79,12.58,9.48)
    local outer=section(9.4,14.0,11.0)
    local aa,bb=worldSection(s,inner),worldSection(s,outer)
    for i=1,#inner-1 do doubleQuad(concrete,aa[i],aa[i+1],bb[i+1],bb[i]) end
    -- 门户厚度沿真实切线；没有跨洞口横梁或实心端盖。
    local finish=s+(back and -3.0 or 3.0)
    sweep(concrete,s,finish,inner,true)
    sweep(concrete,s,finish,outer,true)
    data.vertices=data.vertices+concrete:Finish(); data.meshes=data.meshes+1; data.portals=data.portals+1
    data.minTunnelHalfWidth=math.min(data.minTunnelHalfWidth,9.48)
    data.minTunnelHeight=math.min(data.minTunnelHeight,8.79)
    pauseOnce(pause)
end
local function tunnel(owner,def,a,b,data,pause)
    local lining=batch(owner,def.id.."_连续可见内衬",textured("lining","Textures/Railway/concrete.png",Color(.48,.51,.50),.92),true,5)
    local rock=batch(owner,def.id.."_留洞山体外壳",rockMaterial(),true,12)
    local grass=batch(owner,def.id.."_留洞山体外壳草坡",grassMaterial(),true,16)
    local stripe=batch(owner,def.id.."_反光检修带",solid("reflector",Color(.80,.83,.70),.08,.76),false,8)
    local profile=section(8.8,12.6,9.5)
    -- 全线固定40m采样，跨240m流式块边界连续，无周期洞口/重复门户。
    local first,last=math.max(a,def.first),math.min(b,def.last)
    for s=first,last-.001,40 do
        local finish=math.min(last,s+40)
        sweep(lining,s,finish,profile,true)
        local aa,bb=worldSection(s,outerSection(def,s)),worldSection(finish,outerSection(def,finish))
        for i=1,#aa-1 do shellQuad(rock,grass,i,aa[i],bb[i],bb[i+1],aa[i+1]) end
        for side=-1,1,2 do
            local lat=-2.5+side*9.47
            doubleQuad(stripe,point(s,lat,1.15),point(finish,lat,1.15),point(finish,lat,1.38),point(s,lat,1.38))
        end
        data.tunnelLength=data.tunnelLength+finish-s
        pauseOnce(pause)
    end
    -- 山体端面为内拱到外山壳的环带，洞心绝不提交三角形；独立于门户装饰。
    for _,s in ipairs({def.first,def.last}) do
        local owns=(s==def.first and s>=a and s<b) or (s==def.last and s>a and s<=b)
        if owns then
            local aa,bb=worldSection(s,profile),worldSection(s,outerSection(def,s))
            for i=1,#aa-1 do shellQuad(rock,grass,i,aa[i],aa[i+1],bb[i+1],bb[i]) end
            portal(owner,def,s,s==def.last,data,pause)
        end
    end
    data.vertices=data.vertices+lining:Finish(); pauseOnce(pause)
    data.vertices=data.vertices+rock:Finish(); pauseOnce(pause)
    data.vertices=data.vertices+grass:Finish(); pauseOnce(pause)
    data.vertices=data.vertices+stripe:Finish(); pauseOnce(pause)
    data.meshes=data.meshes+4; data.tunnels[def.id]=true; data.mountains[def.id]=true
    data.maxMountainHeight=math.max(data.maxMountainHeight,def.height)
    data.minTunnelHalfWidth=math.min(data.minTunnelHalfWidth,9.5)
    data.minTunnelHeight=math.min(data.minTunnelHeight,8.8)
end
local function valleyY(def,s,lateral)
    local along=math.sin(math.pi*math.max(0,math.min(1,(s-def.first)/(def.last-def.first))))^.45
    local across=1-smooth((math.abs(lateral-def.lateral)-330)/190)
    return -.25-def.depth*along*across
end
-- 河岸是静态连续条带，不是方形水面上摆一圈独立石头节点。
-- local Vector3 为(lateral,Y,s)，先按块first/last裁切，再转真实Route坐标；UV跨块连续。
local function riverPatch(target,polygon,first,last,def)
    for _,edge in ipairs({{first,true},{last,false}}) do
        local out={}
        local previous=polygon[#polygon]
        if not previous then return end
        local previousInside=edge[2] and previous.z>=edge[1] or (not edge[2] and previous.z<=edge[1])
        for _,current in ipairs(polygon) do
            local inside=edge[2] and current.z>=edge[1] or (not edge[2] and current.z<=edge[1])
            if inside~=previousInside then
                out[#out+1]=previous+(current-previous)*((edge[1]-previous.z)/(current.z-previous.z))
            end
            if inside then out[#out+1]=current end
            previous,previousInside=current,inside
        end
        polygon=out
    end
    local anchor=polygon[1]
    if not anchor then return end
    local function uv(v) return Vector2(v.x/target.tile,(v.z-def.s)/target.tile) end
    for i=2,#polygon-1 do
        local b,c=polygon[i],polygon[i+1]
        target:AddTri(point(anchor.z,anchor.x,anchor.y),point(b.z,b.x,b.y),point(c.z,c.x,c.y),
            uv(anchor),uv(b),uv(c))
    end
end
local function river(owner,def,first,last,earth,water,data,pause)
    -- 河心摆动<=17m、半宽<=59m；两级岸带最大44m，所有新增面低于轨面。
    -- 横向端部收窄并进入原谷坡(x=±400)，没有裸露矩形封边；不动谷cut和桥墩底。
    if last<=def.s-122 or first>=def.s+122 then return end
    local gravel=batch(owner,def.id.."_自然沙砾河岸",textured("riverGravel","Textures/Railway/ballast.png",Color(.83,.79,.66)),false,5)
    local function bank(x,side,level)
        local phase=def.s/700
        local taper=1-smooth((math.abs(x)-300)/100)
        local center=def.s+12*math.sin(x/140+phase)+5*math.sin(x/58-phase)
        local width=(51+8*math.sin(x/115+phase))*taper
        local extra=level==0 and 0 or (level==1 and 18 or 44)*taper
        local s=center+side*(width+extra)
        local lateral=def.lateral+x
        local bed=valleyY(def,s,lateral)
        local height=level==0 and math.max(def.waterY+.06,bed+.025)
            or (level==1 and math.max(def.waterY+.85*taper,bed+.025) or bed+.025)
        return Vector3(lateral,height,s)
    end
    for x=-400,360,40 do
        local lo,hi=bank(x,-1,0),bank(x,1,0)
        local nextLo,nextHi=bank(x+40,-1,0),bank(x+40,1,0)
        riverPatch(water,{Vector3(lo.x,def.waterY,lo.z),Vector3(hi.x,def.waterY,hi.z),
            Vector3(nextHi.x,def.waterY,nextHi.z),Vector3(nextLo.x,def.waterY,nextLo.z)},first,last,def)
        for _,side in ipairs({-1,1}) do
            for level=0,1 do
                local a,b=bank(x,side,level),bank(x,side,level+1)
                local c,d=bank(x+40,side,level+1),bank(x+40,side,level)
                local polygon=side==1 and {a,b,c,d} or {d,c,b,a}
                riverPatch(level==0 and gravel or earth,polygon,first,last,def)
            end
        end
        if x%120==0 then pauseOnce(pause) end
    end
    data.vertices=data.vertices+gravel:Finish(); data.meshes=data.meshes+1; data.water=data.water+1
    pauseOnce(pause)
end
local function bridge(owner,def,a,b,data,pause)
    local deck=batch(owner,def.id.."_轨下桥面梁墩",World.Concrete(),true,4)
    local steel=batch(owner,def.id.."_轨外护栏",solid("bridgeSteel",Color(.25,.37,.40),.35,.60),true,5)
    local earth=batch(owner,def.id.."_实际深谷坡面",grassMaterial(),false,16)
    local water=batch(owner,def.id.."_横穿铁路河流",solid("river",Color(.10,.32,.36),.16,.25),false,36)
    local first,last=math.max(a,def.first),math.min(b,def.last)
    local offsets={-520,-400,-330,-180,0,180,330,400,520}
    for s=first,last-.001,32 do
        local finish=math.min(last,s+32)
        local _,_,yaw=Route.Sample((s+finish)*.5)
        local angle=math.rad(yaw)
        local mid=(s+finish)*.5
        deck:AddBox(point(mid,-2.5,-.68),Vector3(18.4,1.0,finish-s+.02),angle)
        -- 既有线路外侧围栏位于±14m；轨下窄维护踏道承托它，不改Infrastructure。
        for _,lat in ipairs({-14.0,14.0}) do deck:AddBox(point(mid,lat,-.68),Vector3(1.2,1.0,finish-s+.02),angle) end
        for _,lat in ipairs({-7.1,2.1}) do deck:AddBox(point(mid,lat,-2.05),Vector3(1.1,1.75,finish-s+.02),angle) end
        for _,lat in ipairs({-11.2,6.2}) do
            steel:AddBox(point(mid,lat,.82),Vector3(.14,1.35,finish-s+.02),angle)
        end
        for i=1,#offsets-1 do
            local lo,hi=def.lateral+assert(offsets[i]),def.lateral+assert(offsets[i+1])
            earth:AddQuad(point(s,lo,valleyY(def,s,lo)),point(finish,lo,valleyY(def,finish,lo)),
                point(finish,hi,valleyY(def,finish,hi)),point(s,hi,valleyY(def,s,hi)))
        end
        data.bridgeLength=data.bridgeLength+finish-s
        pauseOnce(pause)
    end
    -- 墩位全线固定，块半开所有权唯一；底部抵达实际河床，而不是平地边公路桥。
    for s=def.first+40,def.last-20,80 do
        if s>=a and s<b then
            local bottom=valleyY(def,s,-2.5)-.6
            local top=-1.20
            local pierHeight=math.max(.2,top-bottom)
            local _,_,yaw=Route.Sample(s)
            deck:AddBox(point(s,-2.5,(top+bottom)*.5),Vector3(4.6,pierHeight,3.2),math.rad(yaw))
            deck:AddBox(point(s,-2.5,bottom+.45),Vector3(8.8,.9,6.8),math.rad(yaw))
            deck:AddBox(point(s,-2.5,-1.20),Vector3(14.2,.8,4.2),math.rad(yaw))
            data.piers=data.piers+1
            pauseOnce(pause)
        end
    end
    river(owner,def,first,last,earth,water,data,pause)
    data.vertices=data.vertices+deck:Finish(); pauseOnce(pause)
    data.vertices=data.vertices+steel:Finish(); pauseOnce(pause)
    data.vertices=data.vertices+earth:Finish(); pauseOnce(pause)
    data.vertices=data.vertices+water:Finish(); pauseOnce(pause)
    data.meshes=data.meshes+4; data.bridges[def.id]=true
    data.maxValleyDepth=math.max(data.maxValleyDepth,def.depth)
end
-- 山峰为5层偏心环+非平面窄岩脊盖：基底12点逐字沿用，最大Y仍为def.height。
-- 四层坡面分配草/裸岩而非共面叠加；318顶点/106三角形，仍只有2个合批节点。
local peakRadii_={1,.78,.52,.27,.09}
local peakLevels_={0,.22,.49,.74,.93}
local peakShiftX_={0,.025,-.035,.075,.12}
local peakShiftZ_={0,-.045,.055,.11,.08}
local peakCrest_={.89,.94,.98,1,.93,.90,.92,.96,.94,.90,.86,.87}
local function mountain(owner,def,data,pause)
    local rock=batch(owner,def.id.."_大山",rockMaterial(),false,12)
    local grass=batch(owner,def.id.."_岩脊草坡",grassMaterial(),false,16)
    local origin=point(def.s,def.lateral,0)
    local right,tangent=Route.RightAt(def.s),Route.TangentAt(def.s)
    local function p(ring,i)
        local angle=(i%12)*math.pi/6
        local radius=assert(peakRadii_[ring+1])
        local phase=def.s/700
        local lobe=1+.11*math.sin(angle*3+phase)
        local height=ring==0 and -.26 or def.height*(assert(peakLevels_[ring+1])
            +.045*math.sin(angle*2+phase+ring)*math.sin(ring*math.pi/4))
        if ring==4 then height=def.height*assert(peakCrest_[i%12+1]) end
        local dx=def.halfWidth*(math.cos(angle)*radius*lobe+assert(peakShiftX_[ring+1])*math.sin(phase))
        local dz=310*(math.sin(angle)*radius+assert(peakShiftZ_[ring+1])*math.cos(phase))
        return origin+right*dx+tangent*dz+Vector3(0,height,0)
    end
    for ring=0,3 do
        for i=0,11 do
            local target=(ring==0 or (ring==1 and (i+math.floor(def.s/1150))%4<2)) and grass or rock
            target:AddQuad(p(ring,i),p(ring+1,i),p(ring+1,i+1),p(ring,i+1))
            if i%4==3 then pauseOnce(pause) end
        end
    end
    -- 盖住最后一个有限面积环，不把所有上坡面收敛到同一个顶点。
    local function uv(v)
        local delta=v-origin
        return Vector2(delta:DotProduct(right)/12,delta:DotProduct(tangent)/12)
    end
    local anchor=p(4,0)
    for i=1,10 do
        local b,c=p(4,i),p(4,i+1)
        rock:AddTri(anchor,c,b,uv(anchor),uv(c),uv(b))
    end
    data.vertices=data.vertices+rock:Finish(); pauseOnce(pause)
    data.vertices=data.vertices+grass:Finish(); pauseOnce(pause)
    data.meshes=data.meshes+2; data.mountains[def.id]=true
    data.maxMountainHeight=math.max(data.maxMountainHeight,def.height)
end
---@param owner Node
---@param first number
---@param last number
---@param pause? fun()
function Landmarks.BuildChunk(owner,first,last,pause)
    ensure()
    local key=string.format("%.3f_%.3f",first,last)
    local data={first=first,last=last,bridges={},tunnels={},mountains={},vertices=0,meshes=0,portals=0,piers=0,water=0,
        bridgeLength=0,tunnelLength=0,minTunnelHalfWidth=math.huge,minTunnelHeight=math.huge,maxValleyDepth=0,maxMountainHeight=0}
    chunks_[key]=data
    local root=owner:CreateChild("铁路桥隧与山体")
    owners_[key]=root
    for _,def in ipairs(definitions_) do
        if def.kind=="mountain" then
            if def.s>=first and def.s<last then mountain(root,def,data,pause) end
        elseif def.last>first and def.first<last then
            if def.kind=="tunnel" then tunnel(root,def,first,last,data,pause)
            else bridge(root,def,first,last,data,pause) end
        end
    end
    return data.vertices
end
function Landmarks.ForgetChunk(first,last)
    local key=string.format("%.3f_%.3f",first,last)
    chunks_[key]=nil; owners_[key]=nil
end
-- 原生CustomGeometry引用供测试逐三角形采样；释放由WorldStream负责，不在此Dispose共享物。
---@return CustomGeometry[]
function Landmarks.GetMeshes()
    local result={}
    for _,owner in pairs(owners_) do
        for _,geometry in ipairs(owner:GetComponents("CustomGeometry",true)) do result[#result+1]=geometry end
    end
    return result
end
function Landmarks.GetChunkData() return chunks_ end
function Landmarks.NoteBuildings(key,data) buildings_[key]=data end
function Landmarks.ForgetBuildings(key) buildings_[key]=nil end
function Landmarks.Shutdown()
    definitions_,bridges_,tunnels_,mountains_,cuts_,chunks_,buildings_,owners_={},{},{},{},{},{},{},{}
    routeLength_=-1
end
function Landmarks.GetStats()
    ensure()
    local stats={plannedBridges=#bridges_,plannedTunnels=#tunnels_,plannedMountains=#mountains_+#tunnels_,bridges=0,tunnels=0,
        mountains=0,highRises=0,portals=0,piers=0,bridgeLength=0,tunnelLength=0,vertices=0,meshes=0,loadedChunks=0,
        minTunnelHalfWidth=math.huge,minTunnelHeight=math.huge,tunnelCenter=-2.5,tunnelCrownHeight=12.6,
        bridgeDeckTop=-.18,railHeadY=Route.RailHeadHeight,maxValleyDepth=0,maxMountainHeight=0,definitions=definitions_}
    local bridges,tunnels,mountains={},{},{}
    for _,data in pairs(chunks_) do
        for id in pairs(data.bridges) do bridges[id]=true end
        for id in pairs(data.tunnels) do tunnels[id]=true end
        for id in pairs(data.mountains) do mountains[id]=true end
        stats.portals=stats.portals+data.portals; stats.piers=stats.piers+data.piers
        stats.bridgeLength=stats.bridgeLength+data.bridgeLength; stats.tunnelLength=stats.tunnelLength+data.tunnelLength
        stats.vertices=stats.vertices+data.vertices; stats.meshes=stats.meshes+data.meshes; stats.loadedChunks=stats.loadedChunks+1
        stats.minTunnelHalfWidth=math.min(stats.minTunnelHalfWidth,data.minTunnelHalfWidth)
        stats.minTunnelHeight=math.min(stats.minTunnelHeight,data.minTunnelHeight)
        stats.maxValleyDepth=math.max(stats.maxValleyDepth,data.maxValleyDepth)
        stats.maxMountainHeight=math.max(stats.maxMountainHeight,data.maxMountainHeight)
    end
    for _ in pairs(bridges) do stats.bridges=stats.bridges+1 end
    for _ in pairs(tunnels) do stats.tunnels=stats.tunnels+1 end
    for _ in pairs(mountains) do stats.mountains=stats.mountains+1 end
    for _,data in pairs(buildings_) do stats.highRises=stats.highRises+(data.highRises or 0) end
    local vertices=0
    local meshes=Landmarks.GetMeshes()
    for _,geometry in ipairs(meshes) do
        for i=0,geometry.numGeometries-1 do vertices=vertices+geometry:GetNumVertices(i) end
    end
    stats.vertices=vertices; stats.meshes=#meshes
    stats.loadedBridges,stats.loadedTunnels,stats.loadedMountains,stats.loadedHighRises=stats.bridges,stats.tunnels,stats.mountains,stats.highRises
    if stats.tunnels==0 then stats.minTunnelHalfWidth=0; stats.minTunnelHeight=0 end
    return stats
end
return Landmarks
