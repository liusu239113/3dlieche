-- 普速电气化双正线及到发线接触网；按开放线路弧长采样、米制合批。
-- 不增加碰撞体；货场静态展示线由StationYard负责，不给运营lane2省略接触线。
local Route = require "world.Route"
local RailNetwork = require "world.RailNetwork"
local World = require "world.WorldMaterials"
local Infrastructure = {}

-- 保持原实际绝对标高，不把轨面0.34再次加到既有6.10/7.05上。
-- 轨上净高=5.76/6.71；承力索跨中弧垂0.22，最低绝对6.83米。
--      门架底7.50  ===================  (+27，-10双外柱)
--      承力索7.05 ~~~~~~ 最低6.83 ~~~~~~   不用低横梁穿弓
--      接触线6.10 -------各股道---------   软吊弦只在接触线之上
--      最大升弓6.10；刚性跨轨结构至少留0.50，悬臂最低6.7175。
-- 站场排除[s-760,s+460]涵盖咽喉/信号/货场；护栏沟槽不截断新股道。
local CONTACT_Y = 6.10
local MESSENGER_Y = 7.05
local PORTAL_BEAM_Y = 7.64
local PORTAL_BEAM_HEIGHT = .28
local MAX_TRAIN_TOP_Y = 6.10
local YARD_START = RailNetwork.YardStart - 60
local YARD_END = RailNetwork.YardEnd + 60
local MAST_LEFT = -9.9
local MAST_RIGHT = 4.9
local PORTAL_LEFT = -10.0
-- 货线从lane2横移到+16.6/+22.4会穿过+14；采用与StationYard信号架相同的+27外柱。
local PORTAL_RIGHT = 27.0
local spanCount_ = 0

local function nearStation(s, margin)
    for _, st in ipairs(Route.GetStations()) do
        local delta = s - st.s
        if delta >= YARD_START - margin and delta <= YARD_END + margin then
            return true
        end
    end
    return false
end

-- 信号架/天桥仅排除柱梁，连续导线照常通过。
local function supportReserved(s)
    for _, st in ipairs(Route.GetStations()) do
        local delta = s - st.s
        for _, along in ipairs({-740,-340,150,430}) do
            if math.abs(delta-along)<2 then return true end
        end
        if math.abs(delta-83)<4 then return true end
    end
    return false
end

-- 任意方向细杆，以完整长方截面生成，不把杆件包围盒当作实体尺寸。
---@param batch RailwayBatch
---@param a Vector3
---@param b Vector3
---@param width number
local function beam(batch, a, b, width)
    local direction = b - a
    if direction:LengthSquared() < 0.000001 then return end
    local axis = direction:Normalized()
    local reference = math.abs(axis.y) > 0.95 and Vector3.RIGHT or Vector3.UP
    local u = axis:CrossProduct(reference):Normalized() * (width * 0.5)
    local v = axis:CrossProduct(u):Normalized() * (width * 0.5)
    local a1, a2, a3, a4 = a - u - v, a + u - v, a + u + v, a - u + v
    local b1, b2, b3, b4 = b - u - v, b + u - v, b + u + v, b - u + v
    -- u×v沿axis；四侧朝外，起端朝-axis，末端朝+axis。仅翻绕序，顶点尺寸/位置不变。
    batch:AddQuad(a1, a2, b2, b1)
    batch:AddQuad(a2, a3, b3, b2)
    batch:AddQuad(a3, a4, b4, b3)
    batch:AddQuad(a4, a1, b1, b4)
    batch:AddQuad(a4, a3, a2, a1)
    batch:AddQuad(b1, b2, b3, b4)
end

---@type Material[]
local materials_ = {}
function Infrastructure.Init()
    -- 开放线路只划分到真实终点，不为不存在的闭合接缝调整奇偶。
    spanCount_ = math.max(1,math.ceil(Route.GetLength()/48))
    if #materials_ == 0 then
        materials_ = {World.Solid(Color(0.39,0.42,0.43),0.72,0.52),
            World.Solid(Color(0.26,0.23,0.19),0.70,0.48),
            World.Solid(Color(0.30,0.23,0.18),0.05,0.61), World.Concrete(),
            World.Solid(Color(0.34,0.39,0.37),0.60,0.67),
            World.Solid(Color(0.21,0.23,0.20),0,0.97),
            World.Solid(Color(0.82,0.82,0.76),0,0.93),
            World.Solid(Color(0.18,0.19,0.17),0,0.93)}
    end
end

-- 接触线采样和钢轨/车辆用同一RailNetwork中心，lane2渐变不另写近似公式。
---@param s number
---@param lane integer
---@param zigzag number
---@param height number
---@return Vector3
local function wirePoint(s,lane,zigzag,height)
    local position,_,yaw=RailNetwork.Sample(s,lane)
    local angle=math.rad(yaw)
    return position+Vector3(math.cos(angle),0,-math.sin(angle))*zigzag+Vector3(0,height,0)
end

---@param poles RailwayBatch
---@param bases RailwayBatch
local function mast(poles,bases,s,lateral,angle,topY)
    local foot=Route.SampleOffset(s,lateral,0)
    bases:AddBox(foot+Vector3(0,.22,0),Vector3(.85,.44,.85),angle)
    poles:AddBox(foot+Vector3(0,(.10+topY)/2,0),Vector3(.24,topY-.10,.24),angle)
end

---@param poles RailwayBatch
---@param insulators RailwayBatch
local function suspension(poles,insulators,s,lane,zigzag,portal,lateral)
    local contact=wirePoint(s,lane,zigzag,CONTACT_Y)
    local messenger=wirePoint(s,lane,zigzag,MESSENGER_Y)
    if portal then
        -- 门架只在承力索以上设绝缘悬挂，不能把刚性杆伸到受电弓扫掠区。
        beam(insulators,wirePoint(s,lane,zigzag,PORTAL_BEAM_Y),messenger,.12)
    else
        local head=wirePoint(s,lane,zigzag,7.20)
        beam(poles,Route.SampleOffset(s,lateral,7.65),head,.075)
        beam(poles,Route.SampleOffset(s,lateral,6.75),head,.065)
        local middle=(Route.SampleOffset(s,lateral,7.50)+head)*.5
        beam(insulators,middle-Vector3(0,.11,0),middle+Vector3(0,.11,0),.14)
        beam(insulators,head,messenger,.12)
    end
    -- 吊弦归导线批次，不生成伸到CONTACT_Y以下的实体定位柱。
    return contact,messenger
end

---@param wires RailwayBatch
---@param first number
---@param last number
---@param spanStart number
---@param step number
---@param lane integer
---@param zigzag number
---@param pause fun()|nil
local function wireSpan(wires,first,last,spanStart,step,lane,zigzag,pause)
    if last<=first then return end
    local count=math.max(1,math.ceil((last-first)/6))
    local t0=(first-spanStart)/step
    local previousContact=wirePoint(first,lane,zigzag*(1-2*t0),CONTACT_Y)
    local previousMessenger=wirePoint(first,lane,zigzag*(1-2*t0),MESSENGER_Y-.22*math.sin(math.pi*t0))
    for j=1,count do
        local at=first+(last-first)*j/count
        local t=(at-spanStart)/step
        local offset=zigzag*(1-2*t)
        local contact=wirePoint(at,lane,offset,CONTACT_Y)
        local messenger=wirePoint(at,lane,offset,MESSENGER_Y-.22*math.sin(math.pi*t))
        beam(wires,previousContact,contact,.022)
        beam(wires,previousMessenger,messenger,.026)
        if j<count and j%2==0 then beam(wires,contact,messenger,.018) end
        previousContact,previousMessenger=contact,messenger
        if pause and j%4==0 then pause() end
    end
end

---@param root Node
---@param rangeStart number
---@param rangeEnd number
---@param pause fun()|nil
local function buildCatenary(root,rangeStart,rangeEnd,pause)
    local length=Route.GetLength()
    if length<=0 or rangeEnd<=rangeStart then return end
    local step=length/spanCount_
    -- 全chunk只建4个材质批次；不再每电杆/每股道创建独立几何节点。
    local poles=World.NewBatch(root:CreateChild("MastsAndPortalBeams"),materials_[1],true)
    local wires=World.NewBatch(root:CreateChild("AllElectrifiedLaneWires"),materials_[2],false)
    local insulators=World.NewBatch(root:CreateChild("CatenaryInsulators"),materials_[3],true)
    local bases=World.NewBatch(root:CreateChild("CatenaryFoundations"),materials_[4],false,1)
    local startIndex=math.max(0,math.floor(rangeStart/step))
    local endIndex=math.min(spanCount_-1,math.ceil((rangeEnd-.000001)/step)-1)
    for i=startIndex,endIndex do
        local s=i*step
        local first,last=math.max(rangeStart,s),math.min(rangeEnd,s+step)
        local zigzag=i%2==0 and -.18 or .18
        if s>=rangeStart-.000001 and s<rangeEnd-.000001 and not supportReserved(s) then
            local _,_,yaw=Route.Sample(s)
            local angle=math.rad(yaw)
            local portal=nearStation(s,0)
            if portal then
                mast(poles,bases,s,PORTAL_LEFT,angle,7.80)
                mast(poles,bases,s,PORTAL_RIGHT,angle,7.80)
                poles:AddBox(Route.SampleOffset(s,(PORTAL_LEFT+PORTAL_RIGHT)/2,PORTAL_BEAM_Y),
                    Vector3(PORTAL_RIGHT-PORTAL_LEFT,PORTAL_BEAM_HEIGHT,.24),angle)
            else
                mast(poles,bases,s,MAST_RIGHT,angle,7.90)
                mast(poles,bases,s,MAST_LEFT,angle,7.90)
            end
            for lane=0,1 do
                local contact,messenger=suspension(poles,insulators,s,lane,zigzag,portal,lane==0 and MAST_RIGHT or MAST_LEFT)
                beam(wires,contact,messenger,.018)
            end
            if RailNetwork.GetYard(s) then
                local contact,messenger=suspension(poles,insulators,s,2,zigzag,true,PORTAL_RIGHT)
                beam(wires,contact,messenger,.018)
            end
        end
        -- 空间合批不改变导线原32m子区间的6m细分和吊弦位置。
        -- 否则一次对128m重分段会少掉边界吊弦，不能称为等量合批。
        for edge=math.floor(first/32)*32,last-.000001,32 do
            local segmentFirst,segmentLast=math.max(first,edge),math.min(last,edge+32)
            for lane=0,1 do wireSpan(wires,segmentFirst,segmentLast,s,step,lane,zigzag,pause) end
            -- 侧线每一跨裁到真实咽喉端点，初/末端与正线同位并连续合流。
            for _,st in ipairs(Route.GetStations()) do
                local a,b=math.max(segmentFirst,st.s+RailNetwork.YardStart),math.min(segmentLast,st.s+RailNetwork.YardEnd)
                if b>a then wireSpan(wires,a,b,s,step,2,zigzag,pause) end
            end
        end
        if pause then pause() end
    end
    poles:Finish(); if pause then pause() end
    wires:Finish(); if pause then pause() end
    insulators:Finish(); if pause then pause() end
    bases:Finish(); if pause then pause() end
end

-- 纵坡电缆槽沿两端标高连成矩形槽，不以水平长盒切入上坡/悬在下坡。
-- 截面仍是原0.38×0.17m、端缝0.05m；竖向偏移保持世界Y，与SampleOffset契约一致。
---@param batch RailwayBatch
---@param a Vector3
---@param b Vector3
---@param right Vector3
local function gradedTrough(batch, a, b, right)
    local halfWidth, halfHeight = right * .19, Vector3(0, .085, 0)
    local a1, a2 = a - halfWidth - halfHeight, a + halfWidth - halfHeight
    local a3, a4 = a + halfWidth + halfHeight, a - halfWidth + halfHeight
    local b1, b2 = b - halfWidth - halfHeight, b + halfWidth - halfHeight
    local b3, b4 = b + halfWidth + halfHeight, b - halfWidth + halfHeight
    batch:AddQuad(a4, b4, b3, a3)
    batch:AddQuad(a1, a2, b2, b1)
    batch:AddQuad(a1, a4, a3, a2)
    batch:AddQuad(b1, b2, b3, b4)
    batch:AddQuad(a1, b1, b4, a4)
    batch:AddQuad(a2, a3, b3, b2)
end

---@param root Node
local function buildCorridor(root,rangeStart,rangeEnd,pause)
    local concrete=World.NewBatch(root:CreateChild("CableTroughsAndPosts"),materials_[4],false,1)
    local fencing=World.NewBatch(root:CreateChild("FenceMesh"),materials_[5],false)
    local drainage=World.NewBatch(root:CreateChild("Drainage"),materials_[6],false)
    local fencePanels=0
    for s=rangeStart,rangeEnd-.000001,4 do
        local nextS=math.min(s+4,rangeEnd)
        if not nearStation(s,0) and not nearStation(nextS,0) then
            local midS=(s+nextS)*.5
            local _,_,yaw=Route.Sample(midS)
            local angle=math.rad(yaw)
            for side=-1,1,2 do
                -- 双正线外侧维护带；负侧先相对lane1=-5偏移，不能沿旧-2.75占两线间。
                local center=side<0 and -5 or 0
                local lateral = center + side * 2.75
                local firstS, lastS = s + .025, nextS - .025
                local firstPoint, lastPoint = Route.SampleOffset(firstS,lateral,.105), Route.SampleOffset(lastS,lateral,.105)
                if math.abs(firstPoint.y-lastPoint.y) < .000001 then
                    -- 普通水平线路仍走原合批形状，原有绝对Y和米制尺寸不变。
                    concrete:AddBox(Route.SampleOffset(midS,lateral,.105),
                        Vector3(.38,.17,math.max(.01,nextS-s-.05)),angle)
                else
                    gradedTrough(concrete,firstPoint,lastPoint,Route.RightAt(midS))
                end
                beam(drainage,Route.SampleOffset(s,center+side*3.55,.022),
                    Route.SampleOffset(nextS,center+side*3.55,.022),.42)
                for _,offset in ipairs({3.29,3.81}) do
                    beam(concrete,Route.SampleOffset(s,center+side*offset,.10),
                        Route.SampleOffset(nextS,center+side*offset,.10),.12)
                end
                local lat=side*14
                concrete:AddBox(Route.SampleOffset(s,lat,1.10),Vector3(.13,2.20,.13),angle)
                for _,y in ipairs({.30,1.05,2.05}) do
                    beam(fencing,Route.SampleOffset(s,lat,y),Route.SampleOffset(nextS,lat,y),.028)
                end
                for j=1,7 do
                    local at=s+(nextS-s)*j/8
                    beam(fencing,Route.SampleOffset(at,lat,.3),Route.SampleOffset(at,lat,2.05),.018)
                end
                fencePanels=fencePanels+1
                if pause then pause() end
            end
        end
    end
    concrete:Finish(); if pause then pause() end
    fencing:Finish(); if pause then pause() end
    drainage:Finish(); if pause then pause() end
    return fencePanels
end

---@param root Node
local function buildMarkers(root, rangeStart, rangeEnd)
    local white = World.NewBatch(root:CreateChild("KilometrePosts"), materials_[7], false)
    local black = World.NewBatch(root:CreateChild("MarkerBases"), materials_[8], false)
    local count = 0
    for s = math.ceil((rangeStart - 0.000001) / 100) * 100, rangeEnd - 0.000001, 100 do
        if not nearStation(s, 0) then
            local _, _, yaw = Route.Sample(s)
            local center = Route.SampleOffset(s, 4.65, 0.55)
            white:AddBox(center, Vector3(0.18, 0.82, 0.36), math.rad(yaw))
            black:AddBox(center - Vector3(0, 0.44, 0), Vector3(0.23, 0.14, 0.41), math.rad(yaw))
            local labelNode = root:CreateChild("HectometreLabel")
            labelNode.position = Route.SampleOffset(s, 4.55, 0.63)
            labelNode.rotation = Quaternion(yaw - 90, Vector3.UP)
            labelNode.scale = Vector3.ONE * 0.36
            local label = labelNode:CreateComponent("Text3D")
            label:SetFont("Fonts/MiSans-Regular.ttf", 36)
            label.text = string.format("%d", math.floor(s / 100))
            label.color = Color(0.08, 0.09, 0.08)
            label.horizontalAlignment = HA_CENTER
            label.verticalAlignment = VA_CENTER
            label.viewMask = 2
            label.drawDistance = 80
            count = count + 1
        end
    end
    white:Finish(); black:Finish()
    return count
end

---@param root Node
---@param first number
---@param last number
---@param pause fun()|nil
function Infrastructure.BuildChunk(root, first, last, pause)
    if #materials_ == 0 or spanCount_ == 0 then Infrastructure.Init() end
    first,last=math.max(0,first),math.min(Route.GetLength(),last)
    if last<=first then return end
    buildCatenary(root, first, last, pause)
    if pause then pause() end
    buildCorridor(root, first, last, pause)
    if pause then pause() end
    buildMarkers(root, first, last)
end

-- 测试入口仅局部，生产入口使用WorldStream队列。
---@param scene Scene
---@param initialS number|nil
function Infrastructure.Build(scene, initialS)
    Infrastructure.Init()
    local root = scene:CreateChild("RailwayInfrastructurePreview")
    local first=math.max(0,(initialS or 0)-96)
    local last=math.min(Route.GetLength(),(initialS or 0)+96)
    for index=math.floor(first/32),math.ceil(last/32)-1 do
        Infrastructure.BuildChunk(root:CreateChild("Infrastructure_"..index),index*32,
            math.min(index*32+32,Route.GetLength()))
    end
    return root
end

function Infrastructure.GetValidationData()
    -- 纯数值、与流式窗口无关；列表对应实际柱位/避让及三股道导线，不建渲染对象。
    local masts,wireSamples,yards={},{},{}
    local halfTrain=3.38/2
    local count=math.max(1,math.ceil(Route.GetLength()/48))
    local step=Route.GetLength()/count
    for _,st in ipairs(Route.GetStations()) do
        yards[#yards+1]={index=st.index,first=st.s+YARD_START,last=st.s+YARD_END,
            electrifiedFirst=st.s+RailNetwork.YardStart,electrifiedLast=st.s+RailNetwork.YardEnd}
        for _,ds in ipairs({-700,-510,-320,0,160,280,400}) do
            local s=st.s+ds
            local point=wirePoint(s,2,0,CONTACT_Y)
            wireSamples[#wireSamples+1]={s=s,lane=2,lateral=RailNetwork.GetLateral(s,2),
                x=point.x,y=point.y,z=point.z}
        end
    end
    for i=0,count-1 do
        local s=i*step
        if not supportReserved(s) then
            local portal=nearStation(s,0)
            for side=-1,1,2 do
                local lateral=portal and (side<0 and PORTAL_LEFT or PORTAL_RIGHT)
                    or (side<0 and MAST_LEFT or MAST_RIGHT)
                local foot=Route.SampleOffset(s,lateral,0)
                local nearest=math.min(math.abs(lateral),math.abs(lateral+5))
                if RailNetwork.GetYard(s) then nearest=math.min(nearest,math.abs(lateral-RailNetwork.GetLateral(s,2))) end
                masts[#masts+1]={s=s,lateral=lateral,x=foot.x,z=foot.z,portal=portal,
                    foundationWidth=.85,mastWidth=.24,nearestOperationalBodyGap=nearest-halfTrain-.425}
            end
        end
    end
    return {
        contactHeight=CONTACT_Y,messengerHeight=MESSENGER_Y,
        railHeadHeight=Route.RailHeadHeight,
        contactHeightAboveRail=CONTACT_Y-Route.RailHeadHeight,
        messengerHeightAboveRail=MESSENGER_Y-Route.RailHeadHeight,
        messengerMinimumHeight=MESSENGER_Y-.22,
        portalBeamMinimumHeight=PORTAL_BEAM_Y-PORTAL_BEAM_HEIGHT/2,
        portalToPantographGap=PORTAL_BEAM_Y-PORTAL_BEAM_HEIGHT/2-MAX_TRAIN_TOP_Y,
        intervalArmMinimumHeight=6.75-.065/2,
        intervalArmToPantographGap=6.75-.065/2-MAX_TRAIN_TOP_Y,
        mainLineLaterals={0,-5},sidingLateral=RailNetwork.SidingOffset,
        electrifiedLanes={0,1,2},wireSamples=wireSamples,
        intervalMastLaterals={MAST_LEFT,MAST_RIGHT},portalMastLaterals={PORTAL_LEFT,PORTAL_RIGHT},
        staticYardLaneLaterals={16.6,22.4},portalToStaticYardBodyGap=PORTAL_RIGHT-22.4-halfTrain-.425,
        corridorExclusionStart=YARD_START,corridorExclusionEnd=YARD_END,yards=yards,
        signalSupportExclusions={-740,-340,150,430},signalSupportExclusionRadius=2,
        footbridgeSupportExclusion=83,footbridgeSupportExclusionRadius=4,
        spans=count,masts=masts,catenaryBatchesPerChunk=4,corridorBatchesPerChunk=3,
    }
end
return Infrastructure
