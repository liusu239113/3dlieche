-- 中国铁路设施，替代 world.Infrastructure；不绘轨道、不创建物理碰撞体。
-- 所有权：WorldStream拥有parent及几何，Forget在parent Dispose前清掉灯/块引用。
-- 块与离散物件均为[s0,s1)，导线/沟槽只裁切连续曲面，不重复端点物件。
-- 净空截面（m；+S面向前，main左行；opposing反向左行）：
--    外柱-3.6  main0 ----5.0---- opposing+5 外柱+8.6
--    接触6.10 / 承力>=6.83 / 刚性腕臂>=6.86 / 门架>=8.00
--    站场外柱-14.4/+27；岛台[-8.9,-1.9]，上行台[6.9,13.9]
--    桥柱-5.5/+10.5，.50m基座底=-.18，完全落在[-6.7,11.7]桥面
--    隧道：顶部悬挂，无地柱/基础/箱/沟/网/下锚。桥同样无地面附属设施。
-- 不使用玩家当前信号给全线刷绿；每架逐股逐方向询问Traffic，未知/异常=红。
local Route = require "world.Route"
local RailNetwork = require "world.RailNetwork"
local Landmarks = require "world.Landmarks"
local World = require "world.WorldMaterials"
local Standards = require "config.RailwayStandards"
local Infrastructure = {}
local C, T, L = Standards.Catenary, Standards.Topology, Standards.LOD
local EPS = .000001

---@class ChineseRailSignal
---@field s number
---@field lane integer
---@field dir integer
---@field lateral number
---@field aspect string
---@field lamp Node
---@field yaw number
---@class ChineseRailChunk
---@field first number
---@field last number
---@field owner Node
---@field vertices integer
---@field meshes integer
---@field signals ChineseRailSignal[]
---@field objects table[]
---@field supportCount integer
---@field wireLength number
---@field groundLength number
---@field complete boolean
---@class ChineseRailSupport
---@field s number
---@field index integer
---@field mode string
---@field left number
---@field right number
---@field baseY number
---@field roofLeft number
---@field roofRight number
---@type table<string, ChineseRailChunk>
local chunks_ = {}
---@type ChineseRailSupport[]
local supports_ = {}
---@type table[]
local markers_ = {}
---@type table[]
local boundaries_ = {}
---@type Material[]
local materials_ = {}
---@type Material[]
local lampMaterials_ = {}
---@type Scene?
local scene_ = nil
local plannedLength_ = -1.0
local lastS_, lastLane_, lastDirection_ = 0.0, 0, 1
local timer_, maxBuildMs_, maxSliceMs_, maxUpdateMs_ = 0.0, 0.0, 0.0, 0.0
local generatedVertices_, duplicateBuilds_, forgotten_ = 0, 0, 0
local providerErrors_ = 0

local function owns(s,a,b) return s>=a and s<b end
local function key(a,b) return string.format("%.6f_%.6f",a,b) end
local function point(s,x,y) return Route.SampleOffset(s,x,y) end
local function stationAt(s,margin)
    for _,section in ipairs(RailNetwork.GetRoutingSections()) do
        local first=math.min(section.first,section.up.first)-margin
        local last=math.max(section.last,section.up.last)+margin
        if s>=first and s<last then return section end
    end
    return nil
end
local function structureAt(s)
    for _,def in ipairs(Landmarks.GetDefinitions()) do
        if (def.kind=="bridge" or def.kind=="tunnel") and owns(s,def.first,def.last) then return def end
    end
    return nil
end
local function crossoverAt(s,margin)
    if not RailNetwork.GetCrossovers then return nil end
    for _,cross in ipairs(RailNetwork.GetCrossovers()) do
        if s>=cross.first-(margin or 0) and s<cross.last+(margin or 0) then return cross end
    end
    return nil
end
local function modeAt(s)
    local def=structureAt(s)
    if def then return def.kind end
    return (stationAt(s,Standards.Clearance.yardMargin) or crossoverAt(s,Standards.Clearance.yardMargin)) and "station" or "ground"
end
local function overheadReserved(s)
    -- 区间信号与柱都原在50m格点，必须实际错位，不让腕臂柱遮挡灯或共用基础。
    local nearest=math.floor(s/Standards.Signals.interval+.5)*Standards.Signals.interval
    if nearest>0 and math.abs(s-nearest)<4 and modeAt(nearest)=="ground" then return true end
    -- 公里/半公里/百米桩在真实chainage，平移电杆而非伪造里程桩的里程。
    for _,interval in ipairs({Standards.Corridor.stakeInterval,Standards.Markers.halfKilometre}) do
        local at=math.floor(s/interval+.5)*interval
        if at>0 and math.abs(s-at)<1 and modeAt(at)=="ground" then return true end
    end
    for _,st in ipairs(Route.GetStations()) do
        if math.abs(s-st.s-Standards.Clearance.footbridgeAt)<Standards.Clearance.footbridgeMargin then return true end
        for _,ds in ipairs({-740,-340,150,430}) do
            if math.abs(s-st.s-ds)<Standards.Clearance.signalSupportMargin then return true end
        end
    end
    return false
end
local function roofAt(lateral)
    local t=math.max(-1,math.min(1,(lateral-T.tunnelCenter)/T.tunnelHalfWidth))
    return T.tunnelWallHeight+(T.tunnelCrownHeight-T.tunnelWallHeight)*math.sqrt(1-t*t)
end
local function supportAt(s,index)
    local mode=modeAt(s)
    local left,right,baseY=-C.mastOffset,T.opposing+C.mastOffset,0
    if mode=="station" then left,right=T.stationMastLeft,T.stationMastRight
    elseif mode=="bridge" then left,right,baseY=T.bridgeMastLeft,T.bridgeMastRight,T.bridgeDeckTop
    elseif mode=="tunnel" then left,right=T.tunnelCenter-T.tunnelHalfWidth+.6,T.tunnelCenter+T.tunnelHalfWidth-.6 end
    return {s=s,index=index,mode=mode,left=left,right=right,baseY=baseY,
        roofLeft=roofAt(T.main),roofRight=roofAt(T.opposing)}
end
local function addMarker(s,kind,text,dir,lateral,extra)
    if s<0 or s>=Route.GetLength() then return end
    markers_[#markers_+1]={s=s,kind=kind,text=text,dir=dir or 1,
        lateral=lateral or -(Standards.Markers.boundaryOffset),extra=extra or {},id=kind.."_"..string.format("%.4f_%d",s,dir or 1)}
end
local function foulingPosition(st,entering)
    local lo=st.s+(entering and RailNetwork.YardStart or 160)
    local hi=st.s+(entering and -320 or RailNetwork.YardEnd)
    for _=1,35 do
        local mid=(lo+hi)/2
        local separated=math.abs(RailNetwork.GetLateral(mid,2)-RailNetwork.GetLateral(mid,0))>=Standards.Markers.foulingTrackSpacing
        if separated==entering then hi=mid else lo=mid end
    end
    return (lo+hi)/2
end
local function plan()
    supports_,markers_,boundaries_={},{},{}
    plannedLength_=Route.GetLength()
    -- 固定50m格点；仅避让站内天桥/信号架时在±10m内平移，邻跨仍严格40..60m。
    local previous=-C.span
    for i=0,math.ceil(plannedLength_/C.span)-1 do
        local original=i*C.span
        local selected=original
        if overheadReserved(original) then
            for _,delta in ipairs({-8,8,-10,10,-6,6,-4,4}) do
                local candidate=original+delta
                if candidate>=0 and candidate-previous>=C.minimumSpan and candidate-previous<=C.maximumSpan
                    and (i+1)*C.span-candidate>=C.minimumSpan and (i+1)*C.span-candidate<=C.maximumSpan
                    and not overheadReserved(candidate) then selected=candidate;break end
            end
        end
        assert(not overheadReserved(selected),"接触网柱无法避让天桥/信号架")
        assert(i==0 or selected-previous>=C.minimumSpan-EPS and selected-previous<=C.maximumSpan+EPS,"接触网跨距越界")
        supports_[#supports_+1]=supportAt(selected,i)
        previous=selected
    end
    -- 开放线路末端也有实体支点，末端仅1m悬出；不能把最后几十米画成无支承导线。
    local terminal=plannedLength_-1
    local lastSupport=supports_[#supports_]
    local penultimate=supports_[#supports_-1]
    if lastSupport and penultimate and terminal-lastSupport.s>10 then
        if terminal-lastSupport.s<C.minimumSpan then
            local middle=(penultimate.s+terminal)/2
            assert(not overheadReserved(middle),"末端接触网支点避让失败")
            supports_[#supports_]=supportAt(middle,lastSupport.index)
        end
        assert(not overheadReserved(terminal),"末端接触网支点避让失败")
        supports_[#supports_+1]=supportAt(terminal,lastSupport.index+1)
    end
    for s=0,plannedLength_-EPS,Standards.Markers.halfKilometre do
        local km=math.floor(s/1000)
        local whole=s%1000==0
        addMarker(s,whole and "kilometre" or "halfKilometre",whole and ("K"..km) or ("K"..km.."+500"),1,-3.30)
    end
    for s=Standards.Corridor.stakeInterval,plannedLength_-EPS,Standards.Corridor.stakeInterval do
        if s%Standards.Markers.halfKilometre~=0 then addMarker(s,"hectometre",tostring(math.floor(s/100)%10),1,-3.30) end
    end
    for segmentIndex,seg in ipairs(Route.GetSegments()) do
        if seg.type=="arc" then
            local curvature=Route.CurvatureAt((seg.s+seg.s+seg.length)/2)
            local radius=math.abs(curvature)>EPS and 1/math.abs(curvature) or seg.radius
            local alignment=Route.GetEngineeringAlignment() --[[@as RailwayAlignment?]]
            local transition=0
            local source=alignment and alignment:GetSourceSegments()[segmentIndex]
            if source then transition=source.transitionLength or 0 end
            local text=string.format("R%.0f / L%.0f",radius,seg.length)
            local extra={radius=radius,length=seg.length,startS=seg.s,endS=seg.s+seg.length,
                turn=seg.dir,transitionLength=transition,
                ZH=seg.s,HY=seg.s+transition,YH=seg.s+seg.length-transition,HZ=seg.s+seg.length,
                centerCurvature=curvature}
            local endpointBoard=transition>0 and string.format("ZH / R%.0f / Ls%.0f",radius,transition) or text
            addMarker(seg.s,"curve",endpointBoard,1,-3.30,extra)
            addMarker(seg.s+seg.length,"curve",transition>0 and string.format("HZ / R%.0f / Ls%.0f",radius,transition) or text,-1,8.30,extra)
            if transition>0 then
                addMarker(seg.s+transition,"curveTransition","HY / R"..math.floor(radius+.5),1,-3.30,extra)
                addMarker(seg.s+seg.length-transition,"curveTransition","YH / R"..math.floor(radius+.5),-1,8.30,extra)
            end
        end
        -- 解析路线当前强制平坡；不伪造坡度。板上长度是该段实际长度，0‰来自端点高差。
        local a=Route.Sample(seg.s)
        local b=Route.Sample(seg.s+seg.length)
        local grade=(b.y-a.y)/seg.length*1000
        -- 坡度标只在实际变坡点（含线路起点）出现，不在每个平面曲线接头伪造变坡。
        local previous=Route.GetSegments()[segmentIndex-1]
        local oldGrade=math.huge
        if previous then
            local oldA=Route.Sample(previous.s)
            local oldB=Route.Sample(previous.s+previous.length)
            oldGrade=(oldB.y-oldA.y)/previous.length*1000
        end
        if not previous or math.abs(grade-oldGrade)>.001 then
            addMarker(seg.s,"gradient",string.format("%.1f‰ / %.0fm",grade,seg.length),1,-3.45,{permille=grade,length=seg.length})
        end
    end
    for _,def in ipairs(Landmarks.GetDefinitions()) do
        if def.kind=="tunnel" then
            addMarker(def.first-Standards.Markers.whistleLead,"whistle","鸣",1,-3.30,{target=def.first})
            addMarker(def.last+Standards.Markers.whistleLead,"whistle","鸣",-1,8.30,{target=def.last})
        end
    end
    for _,st in ipairs(Route.GetStations()) do
        boundaries_[#boundaries_+1]={station=st.index,first=st.s-740,last=st.s+430,
            forwardEntry=st.s-740,reverseEntry=st.s+430,source="StationYard.entrySignals",board=false}
        for _,entering in ipairs({true,false}) do
            local s=foulingPosition(st,entering)
            local separation=math.abs(RailNetwork.GetLateral(s,2)-RailNetwork.GetLateral(s,0))
            addMarker(s,"fouling","",1,(RailNetwork.GetLateral(s,2)+RailNetwork.GetLateral(s,0))/2,
                {station=st.index,separation=separation,entering=entering})
        end
    end
    table.sort(markers_,function(a,b) return a.s<b.s or a.s==b.s and a.id<b.id end)
end
local function ensurePlan()
    if plannedLength_~=Route.GetLength() then plan() end
end

-- 本模块私有PBRDiff实例：纹理/Technique只读复用已预热资源，不改World/列车缓存。
-- 保留十个合批，不引入法线、额外shader define或材质驱动的光照/阴影变化。
---@param path string
---@param tint Color
---@param metallic number
---@param roughness number
---@return Material
local function facilityMaterial(path,tint,metallic,roughness)
    local texture=assert(cache:GetResource("Texture2D",path),"[RailwayInfrastructure] 缺少本地纹理："..path)
    local technique=assert(cache:GetResource("Technique","Techniques/PBR/PBRDiff.xml"))
    local material=Material:new()
    material:SetTechnique(0,technique)
    material:SetTexture(TU_DIFFUSE,texture)
    material:SetShaderParameter("MatDiffColor",Variant(tint))
    material:SetShaderParameter("Metallic",Variant(metallic))
    material:SetShaderParameter("Roughness",Variant(roughness))
    return material
end

function Infrastructure.Init(scene)
    if scene and scene_ and scene~=scene_ then Infrastructure.Shutdown() end
    scene_=scene or scene_
    ensurePlan()
    if #materials_==0 then
        materials_={facilityMaterial("Textures/Railway/coach_steel.png",Color(.29,.32,.33),.46,.78), -- 1 weathered galvanized steel
            World.Solid(Color(.28,.23,.18),.78,.54), -- 2 copper/return wire, unchanged
            World.Solid(Color(.31,.22,.16),.05,.40), -- 3 ceramic, unchanged
            facilityMaterial("Textures/Railway/concrete.png",Color(.55,.54,.50),0,.96), -- 4 aged footing/covers
            facilityMaterial("Textures/Railway/coach_steel.png",Color(.17,.24,.21),.16,.88), -- 5 painted fence/equipment
            facilityMaterial("Textures/Railway/concrete.png",Color(.14,.17,.15),0,.98), -- 6 damp drainage/recesses
            World.Solid(Color(.88,.89,.82),0,.83), -- 7 sign white, unchanged for legibility
            World.Solid(Color(.045,.055,.055),.10,.88), -- 8 signal hood/black signs, unchanged
            World.Solid(Color(.57,.055,.035),.05,.76), -- 9 warning red, unchanged
            facilityMaterial("Textures/Railway/concrete.png",Color(.39,.38,.31),0,.98)} -- 10 weathered masonry
        for _,color in ipairs({Color(.95,.045,.015),Color(1,.64,.025),Color(.045,.90,.20)}) do
            local material=World.Solid(color,0,.38):Clone()
            material:SetShaderParameter("MatEmissiveColor",Variant(color*Standards.Lighting.signalEmissiveStrength))
            lampMaterials_[#lampMaterials_+1]=material
        end
        print("[RailwayInfrastructure] Init 50m半开分块；左行/桥面专柱/隧顶悬挂；未知闭塞=红")
    end
    return true
end

---@param batch RailwayBatch
---@param a Vector3
---@param b Vector3
---@param width number
local function beam(batch,a,b,width)
    local direction=b-a
    if direction:LengthSquared()<.000000001 then return end
    local axis=direction:Normalized()
    local reference=math.abs(axis.y)>.95 and Vector3.RIGHT or Vector3.UP
    local u=axis:CrossProduct(reference):Normalized()*(width/2)
    local v=axis:CrossProduct(u):Normalized()*(width/2)
    local aa={a-u-v,a+u-v,a+u+v,a-u+v}
    local bb={b-u-v,b+u-v,b+u+v,b-u+v}
    for i=1,4 do local j=i%4+1;batch:AddQuad(aa[i],aa[j],bb[j],bb[i]) end
    batch:AddQuad(aa[4],aa[3],aa[2],aa[1]);batch:AddQuad(bb[1],bb[2],bb[3],bb[4])
end
---@param s number
---@param lane integer
---@param stagger number
---@param height number
---@return Vector3
local function wirePoint(s,lane,stagger,height)
    local position,_,yaw=RailNetwork.Sample(s,lane)
    local angle=math.rad(yaw)
    return position+Vector3(math.cos(angle),0,-math.sin(angle))*stagger+Vector3(0,height,0)
end
---@param batch RailwayBatch
local function boxAt(batch,s,x,y,w,h,d)
    -- 垂直截面+两端真实高程：沟槽、基础、轨旁箱不再用水平长盒跨越纵坡。
    local a=point(s-d/2,x,y)
    local b=point(s+d/2,x,y)
    local right=Route.RightAt(s)*(w/2)
    local up=Vector3(0,h/2,0)
    local a0,a1,a2,a3=a-right-up,a+right-up,a+right+up,a-right+up
    local b0,b1,b2,b3=b-right-up,b+right-up,b+right+up,b-right+up
    batch:AddQuad(a3,b3,b2,a2);batch:AddQuad(a0,a1,b1,b0)
    batch:AddQuad(a0,b0,b3,a3);batch:AddQuad(a1,a2,b2,b1)
    batch:AddQuad(a0,a3,a2,a1);batch:AddQuad(b0,b1,b2,b3)
end
---@param chunk ChineseRailChunk
local function note(chunk,kind,s,x,mode,extra)
    chunk.objects[#chunk.objects+1]={kind=kind,s=s,lateral=x,mode=mode or modeAt(s),extra=extra or {}}
end
---@param chunk ChineseRailChunk
---@param batches RailwayBatch[]
local function buildSupport(chunk,batches,support,pause)
    local s,index,mode=support.s,support.index,support.mode
    local steel,wire,insulator,concrete=batches[1],batches[2],batches[3],batches[4]
    local stagger=index%2==0 and -C.stagger or C.stagger
    if mode~="tunnel" then
        for _,lateral in ipairs({support.left,support.right}) do
            local bridge=mode=="bridge"
            local w=bridge and C.bridgeFoundationWidth or C.foundationWidth
            local base=support.baseY
            boxAt(concrete,s,lateral,base+C.foundationHeight/2,w,C.foundationHeight,w)
            boxAt(steel,s,lateral,(base+C.foundationHeight+C.mastTop)/2,C.mastWidth,C.mastTop-base-C.foundationHeight,C.mastWidth)
            if pause then pause() end
            -- 腹板/横档轮廓；所有柱件保持同材质一次提交。
            for y=1,7 do boxAt(steel,s,lateral,y,.43,.06,.09) end
            note(chunk,bridge and "bridgeMast" or "mast",s,lateral,mode,
                {foundationBottom=base,foundationWidth=w,mastWidth=C.mastWidth,topY=C.mastTop})
        end
        if mode=="station" then
            local middle=(support.left+support.right)/2
            local lower=C.portalBottom+.06
            local upper=C.portalTop-.06
            -- 站场连续门架采用透空桁架：上下弦+规律腹杆，避免参考图中的实心长条横梁。
            beam(steel,point(s,support.left,lower),point(s,support.right,lower),.075)
            beam(steel,point(s,support.left,upper),point(s,support.right,upper),.075)
            for x=support.left,support.right-2,2 do
                local nextX=math.min(support.right,x+2)
                beam(steel,point(s,x,lower),point(s,nextX,upper),.045)
                beam(steel,point(s,x,upper),point(s,nextX,lower),.045)
            end
            beam(steel,point(s,support.left,lower),point(s,support.left,upper),.08)
            beam(steel,point(s,support.right,lower),point(s,support.right,upper),.08)
            note(chunk,"stationPortalTruss",s,middle,mode,
                {left=support.left,right=support.right,lowerY=lower,upperY=upper})
        end
    end
    local lanes={0,1}
    for _,lane in ipairs({2,5}) do
        local base=lane==5 and 5 or 0
        if RailNetwork.GetSectionAt(s,lane) and math.abs(RailNetwork.GetLateral(s,lane)-base)>.05 then lanes[#lanes+1]=lane end
    end
    if RailNetwork.GetCrossovers then
        for _,cross in ipairs(RailNetwork.GetCrossovers()) do
            if owns(s,cross.first,cross.last) then lanes[#lanes+1]=cross.lane end
        end
    end
    for _,lane in ipairs(lanes) do
        local messenger=wirePoint(s,lane,stagger,C.messengerY)
        if mode=="tunnel" then
            local lateral=RailNetwork.GetLateral(s,lane)+stagger
            local roof=roofAt(lateral)-.04
            beam(steel,point(s,lateral,roof),point(s,lateral,8.00),.08)
            beam(insulator,point(s,lateral,8.00),point(s,lateral,7.35),.12)
            beam(steel,point(s,lateral,7.35),messenger,.055)
            note(chunk,"ceilingSuspension",s,lateral,mode,{roofY=roof,rigidMinimum=C.messengerY})
        elseif mode=="station" then
            beam(insulator,wirePoint(s,lane,stagger,C.portalBottom),messenger,.12)
        else
            local lateral=lane==0 and support.left or support.right
            local head=wirePoint(s,lane,stagger,7.25)
            beam(steel,point(s,lateral,7.85),head,.07)
            beam(steel,point(s,lateral,6.90),head,.07)
            local middle=(point(s,lateral,7.85)+head)*.5
            beam(insulator,middle-Vector3(0,.13,0),middle+Vector3(0,.13,0),.13)
            beam(insulator,head,messenger,.12)
        end
        beam(wire,wirePoint(s,lane,stagger,C.contactY),messenger,.016)
        if pause then pause() end
    end
    -- 地面下锚与补偿重锤仅在站外纯路基；桥/隧/咽喉绝不挂地锚或重锤落到水里。
    if mode=="ground" and index>0 and index%math.floor(C.anchorInterval/C.span)==0
        and modeAt(s+C.anchorLongitudinal)=="ground" then
        for _,side in ipairs({-1,1}) do
            local lateral=side<0 and support.left or support.right
            local anchorX=lateral+side*C.anchorOutset
            beam(steel,point(s,lateral,7.7),point(s+C.anchorLongitudinal,anchorX,.36),.045)
            boxAt(concrete,s+C.anchorLongitudinal,anchorX,.18,.62,.36,.62)
            for y=1.20,2.20,.20 do boxAt(concrete,s+.28,lateral+side*.40,y,.36,.14,.36) end
            beam(wire,point(s,lateral,7.90),point(s+.28,lateral+side*.40,2.30),.022)
            note(chunk,"anchor",s,lateral,"ground",{anchorS=s+C.anchorLongitudinal,anchorLateral=anchorX})
        end
    end
    chunk.supportCount=chunk.supportCount+1
end

---@param chunk ChineseRailChunk
---@param batches RailwayBatch[]
local function buildCatenary(chunk,batches,pause)
    local wire=batches[2]
    local crossovers=RailNetwork.GetCrossovers and RailNetwork.GetCrossovers() or {}
    local lanes={0,1,2,5}
    for _,cross in ipairs(crossovers) do lanes[#lanes+1]=cross.lane end
    -- 只遍历相交支跨；665个全线支点不必每个50m块重复扫描。
    local loIndex,hiIndex=1,#supports_
    while loIndex<hiIndex do
        local mid=math.floor((loIndex+hiIndex+1)/2)
        if supports_[mid].s<=chunk.first then loIndex=mid else hiIndex=mid-1 end
    end
    for i=loIndex,#supports_ do
        local support=supports_[i]
        if support.s>=chunk.last then break end
        local nextSupport=supports_[i+1]
        local finish=nextSupport and nextSupport.s or Route.GetLength()
        local start=support.s
        if owns(start,chunk.first,chunk.last) then buildSupport(chunk,batches,support,pause);if pause then pause() end end
        local a,b=math.max(start,chunk.first),math.min(finish,chunk.last)
        if b>a then
            local span=finish-start
            local zig=support.index%2==0 and -C.stagger or C.stagger
            local cuts={a,b}
            for at=math.floor(a/C.wireStep+1)*C.wireStep,b-EPS,C.wireStep do cuts[#cuts+1]=at end
            -- 侧线咽喉准确裁切；端点归导线，不创造站外幽灵侧线。
            for _,section in ipairs(RailNetwork.GetRoutingSections()) do
                for _,path in ipairs({section,section.up}) do
                    for _,at in ipairs({path.first,path.last}) do
                        if at>a and at<b then cuts[#cuts+1]=at end
                    end
                end
            end
            for _,cross in ipairs(crossovers) do
                for _,at in ipairs({cross.first,cross.last}) do if at>a and at<b then cuts[#cuts+1]=at end end
            end
            table.sort(cuts)
            for j=1,#cuts-1 do
                local lo,hi=cuts[j],cuts[j+1]
                local t0,t1=(lo-start)/span,(hi-start)/span
                for _,lane in ipairs(lanes) do
                    local active=lane<2 or ((lane==2 or lane==5) and RailNetwork.GetSectionAt((lo+hi)/2,lane)~=nil)
                    if lane==3 or lane==4 then
                        for _,cross in ipairs(crossovers) do
                            if cross.lane==lane and owns((lo+hi)/2,cross.first,cross.last) then active=true;break end
                        end
                    end
                    if active then
                        local c0=wirePoint(lo,lane,zig*(1-2*t0),C.contactY)
                        local c1=wirePoint(hi,lane,zig*(1-2*t1),C.contactY)
                        local m0=wirePoint(lo,lane,zig*(1-2*t0),C.messengerY-C.sag*math.sin(math.pi*t0))
                        local m1=wirePoint(hi,lane,zig*(1-2*t1),C.messengerY-C.sag*math.sin(math.pi*t1))
                        beam(wire,c0,c1,.018);beam(wire,m0,m1,.022)
                        if owns(lo,chunk.first,chunk.last) and math.abs(lo/C.dropperStep-math.floor(lo/C.dropperStep+.5))<EPS and lo>start+EPS then
                            beam(wire,c0,m0,.013)
                        end
                        chunk.wireLength=chunk.wireLength+hi-lo
                    end
                end
                -- 回流线平面位置随外柱切换，但始终在车顶净空之上。
                for _,side in ipairs({-1,1}) do
                    local x0=side<0 and support.left or support.right
                    local x1=nextSupport and (side<0 and nextSupport.left or nextSupport.right) or x0
                    beam(wire,point(lo,x0+(x1-x0)*t0,C.returnY),point(hi,x0+(x1-x0)*t1,C.returnY),.024)
                end
                if pause and j%4==0 then pause() end
            end
        end
    end
end

-- 真切分区域边界：不因5m格点落在桥前而把沟、网、护坡伸到桥上/洞内。
local function groundIntervals(a,b)
    local cuts={a,b}
    for s=math.floor(a/5+1)*5,b-EPS,5 do cuts[#cuts+1]=s end
    for _,section in ipairs(RailNetwork.GetRoutingSections()) do
        for _,s in ipairs({math.min(section.first,section.up.first)-Standards.Clearance.yardMargin,
            math.max(section.last,section.up.last)+Standards.Clearance.yardMargin}) do
            if s>a and s<b then cuts[#cuts+1]=s end
        end
    end
    for _,cross in ipairs(RailNetwork.GetCrossovers and RailNetwork.GetCrossovers() or {}) do
        for _,s in ipairs({cross.first-Standards.Clearance.yardMargin,cross.last+Standards.Clearance.yardMargin}) do
            if s>a and s<b then cuts[#cuts+1]=s end
        end
    end
    for _,def in ipairs(Landmarks.GetDefinitions()) do
        if def.kind=="bridge" or def.kind=="tunnel" then
            for _,s in ipairs({def.first,def.last}) do if s>a and s<b then cuts[#cuts+1]=s end end
        end
    end
    table.sort(cuts)
    return cuts
end
---@param chunk ChineseRailChunk
---@param batches RailwayBatch[]
local function buildCorridor(chunk,batches,pause)
    local concrete,fence,dark,slope=batches[4],batches[5],batches[6],batches[10]
    local K=Standards.Corridor
    local cuts=groundIntervals(chunk.first,chunk.last)
    for i=1,#cuts-1 do
        local a,b=cuts[i],cuts[i+1]
        if b>a+EPS and modeAt((a+b)/2)=="ground" then
            for _,side in ipairs({-1,1}) do
                local center=side<0 and T.main or T.opposing
                local cableX=center+side*K.cableOffset
                local drainX=center+side*K.drainOffset
                local fenceX=center+side*K.fenceOffset
                local middle=(a+b)/2
                boxAt(concrete,middle,cableX,K.cableTop-.06,K.cableWidth,.12,b-a-.008)
                -- U形排水沟：暗底+.12m混凝土侧壁，不用实心长盒冒充水沟。
                boxAt(dark,middle,drainX,-K.drainDepth,K.drainWidth,.06,b-a)
                for _,edge in ipairs({-.5,.5}) do
                    boxAt(concrete,middle,drainX+edge*K.drainWidth,.01,.10,.26,b-a)
                end
                for _,y in ipairs({.30,1.10,2.08}) do beam(fence,point(a,fenceX,y),point(b,fenceX,y),.025) end
                -- 1m竖丝+横丝合批；固定全线格点，约1m密度降低远景网丝预算。
                for at=math.ceil(a),b-EPS,1 do beam(fence,point(at,fenceX,.30),point(at,fenceX,2.08),.012) end
                local inner,outer=center+side*K.slopeOffset,center+side*K.slopeOuter
                local aa,bb,cc,dd=point(a,inner,.10),point(b,inner,.10),point(b,outer,-.18),point(a,outer,-.18)
                if side>0 then slope:AddQuad(aa,bb,cc,dd) else slope:AddQuad(dd,cc,bb,aa) end
                note(chunk,"groundCorridor",a,cableX,"ground",{last=b,fenceLateral=fenceX,drainLateral=drainX,slopeOuter=outer})
                if pause then pause() end
            end
            chunk.groundLength=chunk.groundLength+b-a
            if pause then pause() end
        end
    end
    for s=math.ceil(chunk.first/K.fencePitch)*K.fencePitch,chunk.last-EPS,K.fencePitch do
        if modeAt(s)=="ground" then
            for _,side in ipairs({-1,1}) do
                local x=(side<0 and T.main or T.opposing)+side*K.fenceOffset
                boxAt(concrete,s,x,K.fenceHeight/2,.12,K.fenceHeight,.12)
                note(chunk,"fencePost",s,x,"ground")
            end
        end
    end
    for s=math.ceil((chunk.first-K.equipmentPhase)/K.equipmentInterval)*K.equipmentInterval+K.equipmentPhase,chunk.last-EPS,K.equipmentInterval do
        if modeAt(s)=="ground" then
            -- 箱盒在维护带外沿，避免压电缆槽/沟，预留双线结构限界。
            for _,side in ipairs({-1,1}) do
                local x=(side<0 and T.main or T.opposing)+side*3.85
                boxAt(concrete,s,x,.16,.90,.32,.82)
                boxAt(fence,s,x,.85,.62,1.06,.44)
                boxAt(batches[1],s,x,1.40,.72,.08,.54)
                boxAt(batches[8],s,x,.82,.04,.08,.46)
                note(chunk,"equipmentCabinet",s,x,"ground",{width=.90})
            end
        end
    end
end

-- 仅地面维护带的小件：仍用原steel/dark批，不添Node/批次，不触碰柱腕臂/导线。
-- 柜门细节位于原柜身外皮±.23m且完全在.90m基础包络内；槽盖接缝厚度6mm，
-- 不增碰撞体/不改净空。固定全线格点与半开所有权，桥/隧/站场一律跳过。
---@param chunk ChineseRailChunk
---@param batches RailwayBatch[]
local function buildCorridorDetails(chunk,batches,pause)
    local K=Standards.Corridor
    local steel,dark=batches[1],batches[6]
    for s=math.ceil((chunk.first-2.5)/5)*5+2.5,chunk.last-EPS,5 do
        if modeAt(s-.015)=="ground" and modeAt(s+.015)=="ground" then
            for _,side in ipairs({-1,1}) do
                local x=(side<0 and T.main or T.opposing)+side*K.cableOffset
                boxAt(dark,s,x,K.cableTop+.001,K.cableWidth-.024,.006,.014)
            end
            if pause then pause() end
        end
    end
    for s=math.ceil((chunk.first-K.equipmentPhase)/K.equipmentInterval)*K.equipmentInterval+K.equipmentPhase,chunk.last-EPS,K.equipmentInterval do
        if modeAt(s)=="ground" then
            for _,side in ipairs({-1,1}) do
                local x=(side<0 and T.main or T.opposing)+side*3.85
                for _,face in ipairs({-.226,.226}) do
                    -- 门边压缝和短百叶属于柜体，不在信号黑罩批里插入装饰。
                    for _,edge in ipairs({-.265,.265}) do boxAt(dark,s+face,x+edge,.85,.012,.90,.012) end
                    for _,y in ipairs({.405,1.295}) do boxAt(dark,s+face,x,y,.53,.012,.012) end
                    for y=1.04,1.20,.08 do boxAt(dark,s+face,x,y,.28,.018,.014) end
                    boxAt(steel,s+face,x+.19,.82,.025,.12,.024)
                    for _,y in ipairs({.53,1.16}) do boxAt(steel,s+face,x-.265,y,.035,.07,.022) end
                end
                if pause then pause() end
            end
        end
    end
end

---@param root Node
local function text(root,s,x,y,dir,value,scale)
    if value=="" then return end
    local _,_,yaw=Route.Sample(s)
    local node=root:CreateChild("工程标识_"..value)
    node.position=point(s-dir*.10,x,y)
    node.rotation=Quaternion(yaw+(dir<0 and 180 or 0),Vector3.UP)
    node.scale=Vector3.ONE*scale
    local label=node:CreateComponent("Text3D")
    label:SetFont("Fonts/MiSans-Regular.ttf",36)
    label.text=value;label.color=Color(.035,.045,.045)
    label.horizontalAlignment=HA_CENTER;label.verticalAlignment=VA_CENTER
    label.viewMask=2;label.drawDistance=L.signTextDistance
end
---@param chunk ChineseRailChunk
---@param batches RailwayBatch[]
local function buildMarkers(chunk,batches)
    for _,marker in ipairs(markers_) do
        if owns(marker.s,chunk.first,chunk.last) then
            local mode=modeAt(marker.s)
            if marker.kind=="fouling" then
                boxAt(batches[7],marker.s,marker.lateral,.29,.16,.58,.16)
                boxAt(batches[9],marker.s,marker.lateral,.38,.175,.12,.175)
                boxAt(batches[9],marker.s,marker.lateral,.55,.175,.06,.175)
                note(chunk,"fouling",marker.s,marker.lateral,mode,marker.extra)
            elseif mode=="ground" then
                local tall=marker.kind=="curve" or marker.kind=="curveTransition" or marker.kind=="gradient" or marker.kind=="whistle"
                local h=tall and 1.55 or .84
                local w=tall and (marker.kind=="whistle" and .48 or 1.35) or .30
                boxAt(batches[7],marker.s,marker.lateral,h,w,tall and .55 or 1.12,.16)
                if tall then boxAt(batches[1],marker.s,marker.lateral,.75,.07,1.50,.07)
                else boxAt(batches[8],marker.s,marker.lateral,.14,.35,.28,.25) end
                text(chunk.owner,marker.s,marker.lateral,tall and h or 1.02,marker.dir,marker.text,tall and .38 or .27)
                note(chunk,marker.kind,marker.s,marker.lateral,mode,marker.extra)
            end
        end
    end
end

---@param chunk ChineseRailChunk
---@param batches RailwayBatch[]
local function addSignal(chunk,batches,s,lane,dir)
    local lateral=RailNetwork.GetLateral(s,lane)-dir*Standards.Signals.lateralClearance
    local H=Standards.Signals.height
    boxAt(batches[4],s,lateral,.20,.65,.40,.65)
    boxAt(batches[1],s,lateral,H/2,.17,H,.17)
    boxAt(batches[8],s,lateral,H,.58,1.35,.28)
    local _,_,yaw=Route.Sample(s)
    for _,dy in ipairs({-Standards.Signals.lensPitch,0,Standards.Signals.lensPitch}) do
        local center=point(s-dir*.19,lateral,H+dy)
        local facing=Route.TangentAt(s)*dir
        batches[8]:AddTube(center-facing*.035,center+facing*.035,Standards.Signals.lensRadius+.035,8)
        -- 遮光罩向来车方向伸出，不穿越线路限界。
        boxAt(batches[8],s-dir*.23,lateral,H+dy+.17,.36,.05,.36)
    end
    local lamp=chunk.owner:CreateChild("闭塞灯_"..lane.."_"..s)
    lamp.position=point(s-dir*.24,lateral,H-Standards.Signals.lensPitch)
    lamp.rotation=Quaternion(yaw+(dir<0 and 180 or 0),Vector3.UP)
    local disk=World.NewBatch(lamp,lampMaterials_[1],false)
    for i=0,11 do
        local a,b=i*math.pi/6,(i+1)*math.pi/6
        disk:AddTri(Vector3.ZERO,Vector3(math.cos(b)*.135,math.sin(b)*.135,0),Vector3(math.cos(a)*.135,math.sin(a)*.135,0))
    end
    disk.geometry.drawDistance=Standards.Signals.drawDistance
    chunk.vertices=chunk.vertices+disk:Finish();chunk.meshes=chunk.meshes+1
    chunk.signals[#chunk.signals+1]={s=s,lane=lane,dir=dir,lateral=lateral,aspect="red",lamp=lamp,yaw=yaw}
    note(chunk,"blockSignal",s,lateral,"ground",{lane=lane,dir=dir,initialAspect="red"})
    text(chunk.owner,s,lateral,3.80,dir,string.format("%s%04d",dir>0 and "下" or "上",math.floor(s/100)),.24)
end

---@param parent Node
---@param s0 number
---@param s1 number
---@param pause? fun()
---@return integer
function Infrastructure.BuildChunk(parent,s0,s1,pause)
    Infrastructure.Init()
    local a,b=math.max(0,s0),math.min(Route.GetLength(),s1)
    if b<=a then return 0 end
    local id=key(a,b)
    if chunks_[id] then duplicateBuilds_=duplicateBuilds_+1;return 0 end
    -- 重叠非同名范围同样拒绝，防止两个流式调度器叠建旧/新设施。
    for _,existing in pairs(chunks_) do
        assert(b<=existing.first+EPS or a>=existing.last-EPS,"RailwayInfrastructure范围重叠；先Forget旧chunk")
    end
    local root=parent:CreateChild("中国铁路设施")
    local chunk={first=a,last=b,owner=root,vertices=0,meshes=0,signals={},objects={},supportCount=0,wireLength=0,groundLength=0,complete=false}
    chunks_[id]=chunk
    local begin,slice=os.clock(),os.clock()
    local function yieldWork()
        maxSliceMs_=math.max(maxSliceMs_,(os.clock()-slice)*1000)
        if pause then pause() end
        slice=os.clock()
    end
    local batches={} ---@type RailwayBatch[]
    local names={"镀锌柱腕臂门架","接触线承力索吊弦回流线","瓷绝缘子","混凝土基础沟槽","防护网设备柜","排水沟暗底","白色工程标","信号遮光罩黑底","警冲红环","路基石砌护坡"}
    for i,material in ipairs(materials_) do
        local batch=World.NewBatch(root:CreateChild(names[i]),material,i==1 or i==3,i==4 and 1 or 2)
        batch.geometry.drawDistance=(i==1 or i==3 or i==4) and L.structureDistance
            or (i==2 and L.wireDistance or L.corridorDistance)
        batches[#batches+1]=batch
    end
    buildCatenary(chunk,batches,yieldWork)
    buildCorridor(chunk,batches,yieldWork)
    buildMarkers(chunk,batches)
    for s=math.ceil(a/Standards.Signals.interval)*Standards.Signals.interval,b-EPS,Standards.Signals.interval do
        if s>0 and modeAt(s)=="ground" then
            addSignal(chunk,batches,s,0,1)
            addSignal(chunk,batches,s,1,-1)
        end
    end
    -- 附属细节最后追加：原所有接触网/基础/信号顶点顺序与形状均保留，便于CPU逐点回归。
    buildCorridorDetails(chunk,batches,yieldWork)
    for _,batch in ipairs(batches) do
        local count=batch:Finish()
        chunk.vertices=chunk.vertices+count
        if count>0 then chunk.meshes=chunk.meshes+1 end
        yieldWork()
    end
    chunk.complete=true
    generatedVertices_=generatedVertices_+chunk.vertices
    maxBuildMs_=math.max(maxBuildMs_,(os.clock()-begin)*1000)
    maxSliceMs_=math.max(maxSliceMs_,(os.clock()-slice)*1000)
    return chunk.vertices
end

---@class ChineseRailTrainSource
---@field s? number
---@field lane? integer
---@field reversing? boolean
---@field GetS? fun():number
---@field GetLane? fun():integer
---@field IsReversing? fun():boolean
---@class ChineseRailSignalProvider
---@field GetBlockSignalAspect? fun(s:number,lane:integer,dir:integer):string
---@param dt number
---@param train? ChineseRailTrainSource
---@param traffic? ChineseRailSignalProvider
function Infrastructure.Update(dt,train,traffic)
    local begin=os.clock()
    if train then
        lastS_=train.GetS and train.GetS() or train.s or lastS_
        lastLane_=train.GetLane and train.GetLane() or train.lane or RailNetwork.GetPlayerLane(lastS_)
        local reversing=train.IsReversing and train.IsReversing() or train.reversing==true
        lastDirection_=reversing and -1 or 1
    end
    timer_=timer_+math.max(0,dt or 0)
    -- 无provider也要立即回红，不保留上一局/上一provider的绿灯。
    if traffic and traffic.GetBlockSignalAspect and timer_<.10 then return end
    timer_=0
    for _,chunk in pairs(chunks_) do
        for _,signal in ipairs(chunk.signals) do
            local aspect="red"
            if traffic and traffic.GetBlockSignalAspect then
                local ok,value=pcall(traffic.GetBlockSignalAspect,signal.s,signal.lane,signal.dir)
                if ok and (value=="green" or value=="yellow" or value=="red") then aspect=value
                elseif not ok then
                    providerErrors_=providerErrors_+1
                    if providerErrors_==1 then print("[RailwayInfrastructure] 闭塞接口异常，安全回红："..tostring(value)) end
                end
            end
            if signal.aspect~=aspect then
                signal.aspect=aspect
                local lampMaterial=aspect=="green" and lampMaterials_[3]
                    or (aspect=="yellow" and lampMaterials_[2] or lampMaterials_[1])
                local y=Standards.Signals.height+(aspect=="green" and 1 or (aspect=="yellow" and 0 or -1))*Standards.Signals.lensPitch
                signal.lamp.position=point(signal.s-signal.dir*.24,signal.lateral,y)
                signal.lamp:GetComponent("CustomGeometry"):SetMaterial(assert(lampMaterial))
            end
        end
    end
    maxUpdateMs_=math.max(maxUpdateMs_,(os.clock()-begin)*1000)
end

-- 只清引用，不二次Dispose调用方拥有的节点；支持构建中的半成品取消。
function Infrastructure.ForgetChunk(s0,s1)
    local id=key(math.max(0,s0),math.min(Route.GetLength(),s1))
    if chunks_[id] then chunks_[id]=nil;forgotten_=forgotten_+1 end
end
function Infrastructure.Forget(s0,s1) Infrastructure.ForgetChunk(s0,s1) end
function Infrastructure.Shutdown()
    chunks_,supports_,markers_,boundaries_={},{},{},{}
    scene_=nil;plannedLength_=-1;timer_=0
    maxBuildMs_,maxSliceMs_,maxUpdateMs_=0,0,0
    generatedVertices_,duplicateBuilds_,forgotten_,providerErrors_=0,0,0,0
    -- 共享材质留给下次Init复用；不Dispose cache/World共享材质。
end
function Infrastructure.GetStats()
    local stats={loadedChunks=0,vertices=0,meshes=0,signals=0,supports=0,wireLength=0,groundLength=0,
        generatedVertices=generatedVertices_,duplicateBuilds=duplicateBuilds_,forgottenChunks=forgotten_,
        maxBuildMs=maxBuildMs_,maxSliceMs=maxSliceMs_,maxUpdateMs=maxUpdateMs_,providerErrors=providerErrors_,
        -- os.clock下CPU实测，软渲染/并行主build可放大；不谎称硬实时预算达标。
        sliceTargetMs=3,overSliceBudget=maxSliceMs_>3,
        lastS=lastS_,lastLane=lastLane_,lastDirection=lastDirection_,pointLights=0,chunkLength=50,
        redSignals=0,yellowSignals=0,greenSignals=0,pendingChunks=0}
    for _,chunk in pairs(chunks_) do
        stats.loadedChunks=stats.loadedChunks+1;stats.vertices=stats.vertices+chunk.vertices;stats.meshes=stats.meshes+chunk.meshes
        stats.signals=stats.signals+#chunk.signals;stats.supports=stats.supports+chunk.supportCount
        stats.wireLength=stats.wireLength+chunk.wireLength;stats.groundLength=stats.groundLength+chunk.groundLength
        if not chunk.complete then stats.pendingChunks=stats.pendingChunks+1 end
        for _,signal in ipairs(chunk.signals) do
            if signal.aspect=="green" then stats.greenSignals=stats.greenSignals+1
            elseif signal.aspect=="yellow" then stats.yellowSignals=stats.yellowSignals+1 else stats.redSignals=stats.redSignals+1 end
        end
    end
    return stats
end
function Infrastructure.GetValidationData()
    ensurePlan()
    local signals,objects,loaded={},{},{}
    for id,chunk in pairs(chunks_) do
        loaded[#loaded+1]={id=id,first=chunk.first,last=chunk.last,vertices=chunk.vertices,meshes=chunk.meshes,complete=chunk.complete}
        for _,signal in ipairs(chunk.signals) do
            signals[#signals+1]={s=signal.s,lane=signal.lane,dir=signal.dir,lateral=signal.lateral,aspect=signal.aspect}
        end
        for _,object in ipairs(chunk.objects) do objects[#objects+1]=object end
    end
    return {standards=Standards,chunkLength=50,ownership="half-open",supports=supports_,markers=markers_,
        stationBoundaries=boundaries_,objects=objects,signals=signals,chunks=loaded,
        mainLineLaterals={T.main,T.opposing},sidingLateral=T.siding,electrifiedLanes={0,1,2},
        contactHeight=C.contactY,contactHeightAboveRail=C.contactY-Route.RailHeadHeight,
        messengerMinimumHeight=C.messengerY-C.sag,rigidArmMinimum=6.90-.035,
        portalMinimum=C.portalBottom,bridgeMastLaterals={T.bridgeMastLeft,T.bridgeMastRight},
        tunnelFloorMasts=0,stationSignalOwner="world.StationYard",stats=Infrastructure.GetStats()}
end
return Infrastructure
