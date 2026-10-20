-- 站场：负侧到发线-10.8/岛台[-8.9,-1.9]；main0=0、up1=+5。
-- 上行外台[6.9,13.9]；货线16.6/22.4仅从up1外方分出，不横穿双线岛台。
-- 天桥底10.1m，楼梯仅在各站台中央-16.4/-5.4/+10.4及站外-44/+28。
-- 道岔几何与可运营逐车采样完全共用；不宣称现实联锁认证。
-- 上行1/5绕线在平台高里程外侧先分后合，不穿货场或客运站台。
local World = require "world.WorldMaterials"
local Route = require "world.Route"
local RailNetwork = require "world.RailNetwork"
local Materials = require "config.Materials"
local StationYard = {}

local RAIL_CENTRE = (1.435+.072)/2
local PLATFORM_Y = 1.44
local DECK_Y = 10.4
---@type Material[]
local materials_ = {}
---@type Material[]
local lampMaterials_ = {}
---@class RailwayYardSignal
---@field s number
---@field lane integer
---@field dir number
---@field aspect string
---@field lamps CustomGeometry[]
---@class RailwayYardEntry
---@field root Node
---@field stationIndex number
---@field vertices integer
---@field batches integer
---@field signals integer
---@field aspect string
---@field ready boolean
---@field lamps CustomGeometry[]
---@field signalHeads RailwayYardSignal[]
---@type table<number, RailwayYardEntry>
local yards_ = {}

---@param s number
---@param lane? integer
local function frame(s,lane)
    local pos,tangent,yaw = RailNetwork.Sample(s,lane or 0)
    local a = math.rad(yaw)
    return pos,tangent,Vector3(math.cos(a),0,-math.sin(a)),yaw
end
local function point(s,lateral,y)
    local pos,_,right = frame(s,0)
    return pos+right*lateral+Vector3(0,y or 0,0)
end
---@param target RailwayBatch
---@param a Vector3
---@param b Vector3
---@param width number
local function beam(target,a,b,width)
    local direction = b-a
    if direction:LengthSquared()<.00000001 then return end
    local axis = direction:Normalized()
    local reference = math.abs(axis.y)>.95 and Vector3.RIGHT or Vector3.UP
    local u = axis:CrossProduct(reference):Normalized()*(width/2)
    local v = axis:CrossProduct(u):Normalized()*(width/2)
    local a1,a2,a3,a4 = a-u-v,a+u-v,a+u+v,a-u+v
    local b1,b2,b3,b4 = b-u-v,b+u-v,b+u+v,b-u+v
    target:AddQuad(a1,a2,b2,b1); target:AddQuad(a2,a3,b3,b2)
    target:AddQuad(a3,a4,b4,b3); target:AddQuad(a4,a1,b1,b4)
    target:AddQuad(a4,a3,a2,a1); target:AddQuad(b1,b2,b3,b4)
end
local function smooth(t)
    local u = math.max(0,math.min(1,t))
    return u*u*u*(10+u*(-15+6*u))
end

-- 站场私有材质；只复用已预热纹理，不污染World.Concrete或Track/列车材质源。
-- 3/4严格沿用生产Track的氧化轨腰/窄磨光顶参数；7为独立站场结构钢，
-- 天桥/信号门架/货棚不能随着轨腰一起变成铁锈色。原八批与截面保持不变。
---@param path string
---@param tint Color
---@param metallic number
---@param roughness number
---@return Material
local function yardMaterial(path,tint,metallic,roughness)
    local texture=assert(cache:GetResource("Texture2D",path),"[StationYard] 缺少本地纹理："..path)
    local technique=assert(cache:GetResource("Technique","Techniques/PBR/PBRDiff.xml"))
    local material=Material:new()
    material:SetTechnique(0,technique)
    material:SetTexture(TU_DIFFUSE,texture)
    material:SetShaderParameter("MatDiffColor",Variant(tint))
    material:SetShaderParameter("Metallic",Variant(metallic))
    material:SetShaderParameter("Roughness",Variant(roughness))
    return material
end

function StationYard.Init()
    if #materials_>0 then return end
    materials_ = {yardMaterial("Textures/Railway/concrete.png",Color(.64,.63,.59),0,.96),World.Ballast(),
        yardMaterial("Textures/Railway/coach_steel.png",Color(.30,.205,.145),.28,.80),
        yardMaterial("Textures/Railway/coach_steel.png",Color(.60,.63,.65),.94,.30),
        World.Solid(Color(.12,.14,.14),.18,.87),World.Solid(Color(.74,.62,.22),.08,.91),
        yardMaterial("Textures/Railway/coach_steel.png",Color(.43,.48,.49),.24,.80),
        yardMaterial("Textures/Railway/concrete.png",Color(.59,.60,.57),0,.96)}
    -- Clone保留World材质Builder，避免修改与灯未亮/其他模块共享的缓存材质。
    for i,color in ipairs({Color(.95,.10,.06),Color(.95,.65,.04),Color(.10,.88,.24)}) do
        local material = World.Solid(color,0,.45):Clone()
        material:SetShaderParameter("MatEmissiveColor",Variant(Color(color.r*1.8,color.g*1.8,color.b*1.8)))
        lampMaterials_[i] = material
    end
end

-- 在实际RailNetwork样本上寻找股道分离值，弯道/平滑策略变化不使辙叉飘走。
local function separation(s,lane)
    local main = RailNetwork.Sample(s,lane==5 and 1 or 0)
    local branch = RailNetwork.Sample(s,lane)
    return (branch-main):Length()
end
local function findSeparation(first,last,wanted,increasing,lane)
    for _=1,24 do
        local mid = (first+last)/2
        if (separation(mid,lane)<wanted)==increasing then first=mid else last=mid end
    end
    return (first+last)/2
end
local function railPoint(s,lane,lateral,y)
    local p,_,right = frame(s,lane)
    return p+right*lateral+Vector3(0,y or .32,0)
end
local function shortRail(target,first,last,lane,lateral,width)
    local count = math.max(1,math.ceil((last-first)/3))
    for i=1,count do
        local a,b = first+(last-first)*(i-1)/count,first+(last-first)*i/count
        beam(target,railPoint(a,lane,lateral,.29),railPoint(b,lane,lateral,.29),width or .04)
    end
end
-- 轨旁小设备及岔枕以真实纵向切线组盒，底部不会在坡上悬空或削进轨底。
local function slopedBox(target,s,lane,lateral,height,size)
    local p,t,r=frame(s,lane)
    local center=p+r*lateral+Vector3(0,height,0)
    local x,y,z=r*(size.x/2),Vector3(0,size.y/2,0),t*(size.z/2)
    local a,b,c,d=center-x-y-z,center+x-y-z,center+x-y+z,center-x-y+z
    target:AddQuad(a+y*2,d+y*2,c+y*2,b+y*2)
    target:AddQuad(a,b,b+y*2,a+y*2);target:AddQuad(b,c,c+y*2,b+y*2)
    target:AddQuad(c,d,d+y*2,c+y*2);target:AddQuad(d,a,a+y*2,d+y*2)
end
local function buildTurnout(batches,first,last,increasing,pause,lane,clipFirst,clipLast)
    lane=lane or 2
    if clipFirst and (last<=clipFirst or first>=clipLast) then return end
    local function rail(target,a,b,id,lateral,width)
        local lo,hi=math.max(a,clipFirst or a),math.min(b,clipLast or b)
        if hi>lo then shortRail(target,lo,hi,id,lateral,width) end
    end
    local function owns(s) return not clipFirst or (s>=clipFirst and s<clipLast) end
    local mainLane,side=lane==5 and 1 or 0,lane==5 and 1 or -1
    if last-first<50 or separation(increasing and last or first,lane)<RAIL_CENTRE*2 then return end
    local tip = findSeparation(first,last,.08,increasing,lane)
    local heel = findSeparation(first,last,.46,increasing,lane)
    local frog = findSeparation(first,last,RAIL_CENTRE*2,increasing,lane)
    local a,b = math.min(tip,heel),math.max(tip,heel)
    -- 两侧道岔的尖轨/护轨严格镜像；设备留在铁路包络之外。
    rail(batches[4],a,b,lane,-side*(RAIL_CENTRE-.055),.025)
    rail(batches[4],a,b,mainLane,side*(RAIL_CENTRE-.055),.025)
    local switchS = tip+(increasing and 10 or -10)
    local p,_,right,yaw = frame(switchS,lane)
    if owns(switchS) then
        slopedBox(batches[5],switchS,lane,side*2.75,.21,Vector3(.65,.32,1.15))
        beam(batches[3],p+right*(side*.68)+Vector3(0,.10,0),p+right*(side*2.65)+Vector3(0,.10,0),.035)
        -- 实体方向标在设备侧，不越过走行限界；分流/合流双向均可辨。
        slopedBox(batches[6],switchS,lane,side*3.25,.72,Vector3(.24,1.10,.12))
        slopedBox(batches[4],switchS,lane,side*3.25,1.18,Vector3(.56,.20,.10))
    end
    local frogFirst,frogLast = math.max(first,frog-4),math.min(last,frog+4)
    rail(batches[4],frogFirst,frogLast,mainLane,side*(RAIL_CENTRE+.10),.048)
    rail(batches[4],frogFirst,frogLast,lane,-side*(RAIL_CENTRE+.10),.048)
    rail(batches[3],frogFirst-1,frogLast+1,mainLane,-side*(RAIL_CENTRE-.16),.05)
    rail(batches[3],frogFirst-1,frogLast+1,lane,side*(RAIL_CENTRE-.16),.05)
    -- 咽喉宽长枕在轨底下方；与Track共用的正常枕不叠在相同高度。
    for s=frogFirst-3,frogLast+3,.6 do
        if owns(s) then
            local main = RailNetwork.Sample(s,mainLane)
            local branch = RailNetwork.Sample(s,lane)
            local gap = (branch-main):Length()
            slopedBox(batches[1],s,mainLane,side*gap/2,.038,Vector3(gap+2.6,.055,.25))
        end
    end
    if pause then pause() end
end

-- 新增非运营货场/检修尽头线，入口在平台之前分流；不能借此替代lane2。
-- 沿主线采样并在站外侧插值横距；终端止于缓冲器，不画草地上的悬空平板。
local function servicePoint(st,s,line)
    local start = st.s-640
    local connected = RailNetwork.Sample(start,1)
    local base,_,r = frame(start,0)
    local lateral = (connected-base):DotProduct(r)
    local firstLateral = lateral+(16.6-lateral)*smooth((s-start)/280)
    local offset = line==1 and firstLateral or firstLateral+5.8*smooth((s-(st.s-430))/150)
    return point(s,offset,0),offset
end
local function buildServices(st,batches,pause)
    for line=1,2 do
        local first = math.max(0,st.s+(line==1 and -640 or -430))
        local last = math.min(Route.GetLength(),st.s+(line==1 and 250 or 210))
        if last>first then
            local count = math.max(1,math.ceil((last-first)/12))
            for i=1,count do
                local a,b = first+(last-first)*(i-1)/count,first+(last-first)*i/count
                local pa,la = servicePoint(st,a,line)
                local pb,lb = servicePoint(st,b,line)
                local heading = math.atan(pb.x-pa.x,pb.z-pa.z)
                local right = Vector3(math.cos(heading),0,-math.sin(heading))
                for side=-1,1,2 do
                    local offset = side*RAIL_CENTRE
                    local v0 = pa+right*(offset-.036)+Vector3(0,.34,0)
                    local v1 = pb+right*(offset-.036)+Vector3(0,.34,0)
                    local v2 = pb+right*(offset+.036)+Vector3(0,.34,0)
                    local v3 = pa+right*(offset+.036)+Vector3(0,.34,0)
                    local down = Vector3(0,-.18,0)
                    batches[4]:AddQuad(v0,v1,v2,v3)
                    batches[3]:AddQuad(v0+down,v1+down,v1,v0)
                    batches[3]:AddQuad(v3,v2,v2+down,v3+down)
                end
                -- 可见枕顶遵守0.6m；外侧装饰线不生成完整箱体或高细分I形轨。
                for s=math.ceil(a/.6)*.6,b-.00001,.6 do
                    local p,lat = servicePoint(st,s,line)
                    local separated = line==1 and lat-5 or lat-select(2,servicePoint(st,s,1))
                    if separated>2.6 then
                        local t = Vector3(math.sin(heading),0,math.cos(heading))
                        local u = p-right*1.3-t*.12+Vector3(0,.16,0)
                        local v = p+right*1.3-t*.12+Vector3(0,.16,0)
                        local w = p+right*1.3+t*.12+Vector3(0,.16,0)
                        local x = p-right*1.3+t*.12+Vector3(0,.16,0)
                        batches[1]:AddQuad(u,x,w,v)
                    end
                end
                if pause and i % 4==0 then pause() end
            end
            local p = servicePoint(st,last-1.2,line)
            local _,_,_,yaw = frame(last,0)
            for side=-1,1,2 do
                batches[3]:AddBox(p+Route.RightAt(last)*(side*.77)+Vector3(0,.56,0),Vector3(.16,.85,.30),math.rad(yaw))
            end
            batches[5]:AddBox(p+Vector3(0,.92,0),Vector3(2.5,.32,.24),math.rad(yaw))
            batches[6]:AddBox(p+Vector3(0,.94,-.14),Vector3(2.2,.16,.025),math.rad(yaw))
        end
    end
end

local function buildHardstand(st,batches,pause)
    local routing=assert(RailNetwork.GetStationRouting(st.index))
    local first,last = math.max(0,routing.first),math.min(Route.GetLength(),routing.last)
    -- 双线/咽喉硬化底部低于道床；不横穿岛台添加家具。
    for s=first,last-.00001,24 do
        local finish = math.min(last,s+24)
        batches[1]:AddQuad(point(s,-8,.006),point(finish,-8,.006),point(finish,14,.006),point(s,14,.006))
        if pause then pause() end
    end
    for s=math.max(0,st.s-650),math.min(Route.GetLength(),st.s+270)-.00001,24 do
        local finish = math.min(Route.GetLength(),st.s+270,s+24)
        batches[2]:AddQuad(point(s,13.4,.075),point(finish,13.4,.075),point(finish,25.6,.075),point(s,25.6,.075))
        batches[1]:AddQuad(point(s,25.6,.025),point(finish,25.6,.025),point(finish,39,.025),point(s,39,.025))
        if pause then pause() end
    end
    local angle = math.rad(select(4,frame(st.s,0)))
    for _,ds in ipairs({-380,-260,110}) do
        local s = st.s+ds
        -- 装卸月台/检修棚完全在最外股道22.4+车宽/净空之外。
        batches[1]:AddBox(point(s,31.3,.48),Vector3(7.4,.96,44),angle)
        batches[7]:AddBox(point(s,31.8,5.8),Vector3(6.8,.16,42),angle)
        for _,along in ipairs({-18,18}) do
            for _,lat in ipairs({28.7,34.9}) do
                batches[7]:AddBox(point(s+along,lat,2.9),Vector3(.18,5.8,.18),angle)
            end
        end
        for j=1,3 do
            batches[7]:AddBox(point(s-12+j*6,32.8,1.9),Vector3(3.4,1.8,4),angle)
        end
        if pause then pause() end
    end
    -- 检修工具柜/仓储货架只在硬化货台，远离走行轮廓。
    batches[5]:AddBox(point(st.s+168,31,.9),Vector3(1.2,1.8,2.4),angle)
    batches[7]:AddBox(point(st.s+165,32.5,1.6),Vector3(4,3.2,9),angle)
end

local function buildBridge(st,batches,pause,ground,glazing)
    -- 原轨腰批曾同时装天桥栏杆/梁柱；仅重映射到已存在的结构钢批，顶点不变。
    local structureBatches={}
    for i,target in ipairs(batches) do structureBatches[i]=target end
    structureBatches[3]=batches[7]
    batches=structureBatches
    local bridgeOffset=math.max(83,Route.PlatformEnd-2)
    local s = st.s+bridgeOffset
    local angle = math.rad(select(4,frame(s,0)))
    -- 连续跨越两正线/到发股道/货场线；中柱只落岛台中央，不落任一铁路。
    batches[1]:AddBox(point(s,1,DECK_Y),Vector3(54,.60,3),angle)
    batches[1]:AddBox(point(s,-39,DECK_Y),Vector3(26,.60,3),angle)
    for _,lat in ipairs({-26,-16.4,-5.4,10.4,28,-51}) do
        batches[3]:AddBox(point(s,lat,5.05),Vector3(.28,10.1,.28),angle)
    end
    batches[7]:AddBox(point(s,1,13.4),Vector3(54,.16,3.4),angle)
    batches[7]:AddBox(point(s,-39,13.4),Vector3(26,.16,3.4),angle)
    for _,edge in ipairs({-1.42,1.42}) do
        for lat=-51,28,3.8 do
            local inOpening=math.abs(lat+44)<1.35 or math.abs(lat+16.4)<1.35
                or math.abs(lat+5.4)<1.35 or math.abs(lat-10.4)<1.35 or lat>26.65
            if edge>0 or not inOpening then
                batches[3]:AddBox(point(s+edge,lat,11.2),Vector3(.055,1.1,.055),angle)
            end
        end
        -- 近侧护栏为四个梯口留空，不能用连续横杆把楼梯出口封死。
        local sections=edge<0 and {{-52,-45.35},{-42.65,-17.75},{-15.05,-6.75},{-4.05,9.05},{11.75,26.65}}
            or {{-52,28}}
        for _,range in ipairs(sections) do
            beam(batches[3],point(s+edge,range[1],11.76),point(s+edge,range[2],11.76),.065)
            beam(batches[3],point(s+edge,range[1],10.92),point(s+edge,range[2],10.92),.045)
        end
    end
    -- Reference-station enclosed bridge: fine silver mullions, glass clerestory,
    -- triangulated side truss and ribbed metal roof. Deck and stair coordinates stay unchanged.
    -- All webs/glass start above handrail: no new wall across a real stair mouth.
    for _,edge in ipairs({-1.42,1.42}) do
        beam(batches[3],point(s+edge,-52,13.23),point(s+edge,28,13.23),.075)
        local railSections=edge<0 and {{-52,-45.4},{-42.6,-17.8},{-15.0,-6.8},{-4.0,9.0},{11.8,26.6}} or {{-52,28}}
        for _,range in ipairs(railSections) do
            beam(batches[3],point(s+edge,range[1],11.88),point(s+edge,range[2],11.88),.075)
        end
        for lat=-51,26,3.8 do
            local endLat=math.min(28,lat+3.8)
            local stairOpening=false
            if edge<0 then
                for _,mouth in ipairs({-44,-16.4,-5.4,10.4,28}) do
                    if lat<mouth+1.40 and endLat>mouth-1.40 then stairOpening=true end
                end
            end
            if not stairOpening then
                beam(batches[3],point(s+edge,lat,11.88),point(s+edge,lat,13.29),.065)
                beam(batches[3],point(s+edge,lat,11.94),point(s+edge,endLat,13.21),.045)
                glazing:AddQuad(point(s+edge,lat+.08,11.96),point(s+edge,endLat-.08,11.96),
                    point(s+edge,endLat-.08,13.14),point(s+edge,lat+.08,13.14))
                glazing:AddQuad(point(s+edge,lat+.08,13.14),point(s+edge,endLat-.08,13.14),
                    point(s+edge,endLat-.08,11.96),point(s+edge,lat+.08,11.96))
            end
        end
    end
    for lat=-51.8,27.8,.30 do
        beam(batches[7],point(s-1.65,lat,13.50),point(s+1.65,lat,13.50),.018,.035)
    end
    -- 岛台梯道位于+64..+83，避开连续雨棚(+57)、柱/台上已有家具。
    -- 54级：每级0.17m上下、0.35m进深；坡道/电梯未实现，不能称全无障碍。
    for _,lat in ipairs({-5.4,10.4,-16.4,-44,28}) do
        local onPlatform=lat==-5.4 or lat==10.4 or lat==-16.4
        local lower = onPlatform and PLATFORM_Y or .05
        local run = onPlatform and 19 or 26
        local steps = onPlatform and 54 or 61
        for i=1,steps do
            local fraction = i/steps
            local y = lower+(DECK_Y+.30-lower)*fraction
            local at = s-run+(i-.5)*run/steps
            batches[8]:AddBox(point(at,lat,y-.075),Vector3(2.5,.15,run/steps),angle)
            if pause and i % 18==0 then pause() end
        end
        for _,side in ipairs({-1.22,1.22}) do
            local p0,p1 = point(s-run,lat+side,lower+.95),point(s,lat+side,DECK_Y+1.25)
            beam(batches[3],p0,p1,.06)
            for j=0,8 do
                local t = j/8
                local y = lower+(DECK_Y+.30-lower)*t
                batches[3]:AddBox(point(s-run+run*t,lat+side,y+.46),Vector3(.055,.92,.055),angle)
            end
        end
    end
    -- 站房侧高架候车连接/下到广场，不在铁路两股间造平交通路。
    -- 地面出入口接到既有站房广场(ds=-55)，不是桥梯落在孤立草地上。
    local approachEnd=bridgeOffset-26
    for ds=-60,approachEnd-.00001,12 do
        local finish=math.min(approachEnd,ds+12)
        ground:AddQuad(point(st.s+ds,-45.5,.062),point(st.s+finish,-45.5,.062),
            point(st.s+finish,-42.5,.062),point(st.s+ds,-42.5,.062))
    end
    batches[7]:AddBox(point(s,-44,13.4),Vector3(14,.18,7),angle)
    batches[6]:AddBox(point(s,-43,11.5),Vector3(.05,.55,3.8),angle)
    if pause then pause() end
end

local function disc(target,center,right,up,radius,direction)
    for i=1,10 do
        local a,b = (i-1)*math.pi/5,i*math.pi/5
        local p = center+right*(radius*math.cos(a))+up*(radius*math.sin(a))
        local q = center+right*(radius*math.cos(b))+up*(radius*math.sin(b))
        if direction>0 then target:AddTri(center,q,p) else target:AddTri(center,p,q) end
    end
end
local function applyAspect(head,aspect)
    if head.aspect==aspect then return end
    head.aspect=aspect
    for i,name in ipairs({"red","yellow","green"}) do
        head.lamps[i]:SetMaterial(aspect==name and lampMaterials_[i] or materials_[5])
    end
end
local function buildSignals(entry,st,batches,pause)
    -- 每个股道/方向独立灯面，全部方向左侧偏置；架柱在铁路/平台外侧。
    local routing=assert(RailNetwork.GetStationRouting(st.index))
    for _,spec in ipairs({{ds=routing.first-st.s-40,direction=1,lanes={0,1}},
            {ds=routing.plateauFirst-st.s-20,direction=-1,lanes={0,1,2}},
            {ds=routing.plateauLast-st.s-10,direction=1,lanes={0,1,2}},
            {ds=routing.last-st.s+30,direction=-1,lanes={0,1}},
            {ds=routing.up.last-st.s+30,direction=-1,lanes={1}},
            {ds=routing.up.first-st.s-30,direction=-1,lanes={1}}}) do
        local s=st.s+spec.ds
        if s>0 and s<Route.GetLength() then
            local angle=math.rad(select(4,frame(s,0)))
            for _,lat in ipairs({-23,27}) do
                batches[1]:AddBox(point(s,lat,.23),Vector3(.85,.46,.85),angle)
                batches[7]:AddBox(point(s,lat,4.7),Vector3(.24,9.0,.24),angle)
            end
            batches[7]:AddBox(point(s,2,9.2),Vector3(50,.34,.28),angle)
            for _,lane in ipairs(spec.lanes) do
                local p,tangent,right,yaw=frame(s,lane)
                local headPosition=p-right*(spec.direction*1.05)
                local heading=math.rad(yaw)
                batches[5]:AddBox(headPosition+Vector3(0,8,0),Vector3(.46,1.55,.24),heading)
                beam(batches[7],headPosition+Vector3(0,8.78,0),headPosition+Vector3(0,9.1,0),.06)
                local head={s=s,lane=lane,dir=spec.direction,aspect="",lamps={}} --[[@as RailwayYardSignal]]
                for i=1,3 do
                    local lens=World.NewBatch(entry.root:CreateChild("Signal_"..entry.signals.."_"..i),materials_[5],false)
                    local center=headPosition+Vector3(0,8.5-(i-1)*.5,0)-tangent*(spec.direction*.135)
                    disc(lens,center,right,Vector3.UP,.155,spec.direction)
                    entry.vertices=entry.vertices+lens:Finish()
                    entry.batches=entry.batches+1
                    head.lamps[i]=lens.geometry
                    batches[5]:AddBox(center+Vector3(0,.19,0)-tangent*(spec.direction*.07),Vector3(.42,.045,.19),heading)
                end
                applyAspect(head,"red")
                entry.signalHeads[#entry.signalHeads+1]=head
                entry.signals=entry.signals+1
                if pause then pause() end
            end
        end
    end
end

---@param root Node 站entry根，所有新增对象由该root统一释放
---@param station table
---@param pause fun()|nil
---@return RailwayYardEntry
function StationYard.Build(root,station,pause)
    if #materials_==0 then StationYard.Init() end
    local existing = yards_[station.index]
    if existing and existing.root.parent==root then return existing end
    assert(not existing,"[StationYard] 同站重复Build前必须Forget旧站场")
    local owner = root:CreateChild("StationYard_"..station.index,LOCAL)
    ---@type RailwayYardEntry
    local entry = {root=owner,stationIndex=station.index,vertices=0,batches=0,signals=0,aspect="",ready=false,lamps={},signalHeads={}}
    yards_[station.index] = entry -- 在第一次yield前登记，取消半成品也能Forget引用。
    local batches = {}
    for i,mat in ipairs(materials_) do
        batches[i] = World.NewBatch(owner:CreateChild("YardMaterial_"..i),mat,false,i<=2 and 2 or 1)
    end
    -- 构建中的灯面尚未Commit，UpdateSignals在ready前跳过。
    buildHardstand(station,batches,pause)
    local routing=assert(RailNetwork.GetStationRouting(station.index))
    buildTurnout(batches,routing.first,routing.plateauFirst,true,pause,2)
    buildTurnout(batches,routing.plateauLast,routing.last,false,pause,2)
    buildTurnout(batches,routing.up.first,routing.up.plateauFirst,true,pause,5)
    buildTurnout(batches,routing.up.plateauLast,routing.up.last,false,pause,5)
    buildServices(station,batches,pause)
    -- 相机遮挡只命中天桥桥板/顶棚/梯道；地坪/细柱/轨道不能参与mask4。
    local bridgeBatches={}
    for i,target in ipairs(batches) do bridgeBatches[i]=target end
    ---@type integer[]
    local bridgeMaterialIndices={1,7,8}
    for _,i in ipairs(bridgeMaterialIndices) do
        bridgeBatches[i]=World.NewBatch(owner:CreateChild("BridgeObstacle_"..i),materials_[i],false)
        bridgeBatches[i].geometry.viewMask=2
    end
    local bridgeGlass=World.NewBatch(owner:CreateChild("ReferenceBridgeGlazing"),Materials.Glass(Color(.42,.57,.62,.34)),false)
    bridgeGlass.geometry.drawDistance=700
    buildBridge(station,bridgeBatches,pause,batches[1],bridgeGlass)
    entry.vertices=entry.vertices+bridgeGlass:Finish()
    entry.batches=entry.batches+1
    for _,i in ipairs({1,7,8}) do
        entry.vertices=entry.vertices+bridgeBatches[i]:Finish()
        entry.batches=entry.batches+1
        if pause then pause() end
    end
    buildSignals(entry,station,batches,pause)
    for _,target in ipairs(batches) do
        entry.vertices = entry.vertices+target:Finish()
        if target.vertices>0 then entry.batches=entry.batches+1 end
        if pause then pause() end
    end
    entry.ready=true
    print(string.format("[StationYard] %s：下行0/2到发线、上行1/5贯通绕线共4处真实曲线道岔；2条非运营货场线；%d灯头/%d批/%d顶点",station.name,entry.signals,entry.batches,entry.vertices))
    return entry
end

-- Track流块拥有区间岔设备，半开裁切防止相邻120m块重复建尖轨/电机/标志。
---@param root Node
---@param first number
---@param last number
---@param pause? fun()
---@return integer
function StationYard.BuildIntervalChunk(root,first,last,pause)
    local relevant={}
    for _,section in ipairs(RailNetwork.GetRoutingSections()) do
        if section.kind=="interval" and ((last>section.first and first<section.plateauFirst)
            or (last>section.plateauLast and first<section.last)) then
            relevant[#relevant+1]=section
        end
    end
    if #relevant==0 then return 0 end
    StationYard.Init()
    local batches={}
    for i=1,6 do batches[i]=World.NewBatch(root:CreateChild("IntervalSwitchMaterial_"..i),materials_[i],false) end
    for _,section in ipairs(relevant) do
        for _,lane in ipairs({2,5}) do
            local path=lane==5 and section.up or section
            buildTurnout(batches,path.first,path.plateauFirst,true,pause,lane,first,last)
            buildTurnout(batches,path.plateauLast,path.last,false,pause,lane,first,last)
        end
    end
    local vertices=0
    for _,target in ipairs(batches) do vertices=vertices+target:Finish();if pause then pause() end end
    return vertices
end

-- 信号getter只读；未初始化/未知权限一律红灯，不再整站共用玩家发车色。
---@param state table|nil
function StationYard.UpdateSignals(state)
    for _,entry in pairs(yards_) do
        if entry.ready then
            for _,head in ipairs(entry.signalHeads) do
                local aspect=state and type(state.GetBlockSignalAspect)=="function"
                    and state.GetBlockSignalAspect(head.s,head.lane,head.dir) or "red"
                if aspect~="green" and aspect~="yellow" then aspect="red" end
                applyAspect(head,aspect)
            end
        end
    end
end
function StationYard.GetSignalHeads()
    local result={}
    for _,entry in pairs(yards_) do
        for _,head in ipairs(entry.signalHeads) do
            result[#result+1]={s=head.s,lane=head.lane,dir=head.dir,aspect=head.aspect,
                lateral=RailNetwork.GetLateral(head.s,head.lane)-head.dir*1.05}
        end
    end
    return result
end
function StationYard.SampleService(st,s,line) return servicePoint(st,s,line) end
function StationYard.Forget(stationIndex) yards_[stationIndex]=nil end
function StationYard.Shutdown() yards_={} end
function StationYard.GetStats()
    local out = {stationCount=0,signals=0,batches=0,vertices=0}
    for _,entry in pairs(yards_) do
        out.stationCount=out.stationCount+1; out.signals=out.signals+entry.signals
        out.batches=out.batches+entry.batches; out.vertices=out.vertices+entry.vertices
    end
    return out
end
return StationYard
