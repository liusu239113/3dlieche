-- 双正线与可到发侧线共用 RailNetwork.Sample；不再独立计算车辆/钢轨路线。
-- 截面（米，Y-up）：轨头0.340 / 轨底0.160 / 枕顶0.160 / 道床0.080。
-- lane0下行正线，lane1上行正线(+5m)，lane2/lane5同向站场及区间外侧贯通支路。
-- 每120m基础4个共享材质批次；区间咽喉近景另合批真实尖轨/设备，枕距0.6m。
local World = require "world.WorldMaterials"
local Route = require "world.Route"
local RailNetwork = require "world.RailNetwork"
local StationYard = require "world.StationYard"
local Landmarks = require "world.Landmarks"
local Track = {}

local GAUGE = 1.435
local HEAD_WIDTH = 0.072
local RAIL_CENTRE = (GAUGE + HEAD_WIDTH) * 0.5
local SLEEPER_STEP = 0.6
local RAIL_STEP = 6.0
local FAR_STEP = 12.0
local CHUNK_LENGTH = 120.0
local BRIDGE_DECK_TOP = -0.18
local BRIDGE_DECK_BOTTOM = -0.52
local BRIDGE_WIDTH = 18.4
local BRIDGE_CENTER = 2.5
local BRIDGE_EDGE = BRIDGE_WIDTH * 0.5
local BRIDGE_PIER_STEP = 80.0

-- 保留真实I形截面；隐藏的轨底底面不提交。6m弦长在现有公里级半径上
-- 弦差小于1mm，不用2m细分；密集0.6m枕木和钢轨曲线细分是两件事。
local PROFILE = {
    {-0.075,0.160}, {0.075,0.160}, {0.075,0.180}, {0.008,0.185},
    {0.008,0.298}, {0.036,0.305}, {0.036,0.340}, {-0.036,0.340},
    {-0.036,0.305}, {-0.008,0.298}, {-0.008,0.185}, {-0.075,0.180},
}
-- 仅近轨新增有限扣件：每10根原枕位抽样，120m双线最多160件/4800顶点，0新增节点/批次。
-- 远轨仍为原1080顶点/120m双线；道床+氧化轨腰+磨光轨顶3批，不增shader变体。
local FASTENER_INTERVAL = 10
---@type Material[]
local materials_ = {}

-- Track私有材质实例；只复用现有Texture/Technique，不注册/修改World的材质缓存。
-- 与World已有纹理采样状态一致，不添加法线贴图、顶点色define或新的shader技术。
---@param path string
---@param tint Color
---@param metallic number
---@param roughness number
---@return Material
local function trackMaterial(path,tint,metallic,roughness)
    local texture = assert(cache:GetResource("Texture2D",path),"[Track] 缺少本地纹理："..path)
    local technique = assert(cache:GetResource("Technique","Techniques/PBR/PBRDiff.xml"),"[Track] 缺少PBRDiff")
    texture:SetSRGB(true)
    texture:SetFilterMode(FILTER_ANISOTROPIC)
    texture:SetAnisotropy(4)
    local material = Material:new()
    material:SetTechnique(0,technique)
    material:SetTexture(TU_DIFFUSE,texture)
    material:SetShaderParameter("MatDiffColor",Variant(tint))
    material:SetShaderParameter("Metallic",Variant(metallic))
    material:SetShaderParameter("Roughness",Variant(roughness))
    return material
end
function Track.Init()
    if #materials_ == 0 then
        materials_ = {World.Ballast(),
            trackMaterial("Textures/Railway/concrete.png",Color(.57,.54,.49),0,.94),
            trackMaterial("Textures/Railway/coach_steel.png",Color(.30,.205,.145),.28,.80),
            trackMaterial("Textures/Railway/coach_steel.png",Color(.60,.63,.65),.94,.30),
            trackMaterial("Textures/Railway/coach_steel.png",Color(.34,.36,.37),.65,.62)} -- 桥栏独立深灰锌钢，不与轨头串色
    end
end

local function frame(s,lane)
    local pos,tangent,yaw = RailNetwork.Sample(s,lane or 0)
    local a = math.rad(yaw)
    local right=Vector3(math.cos(a),0,-math.sin(a))
    return pos,right,yaw,tangent,tangent:CrossProduct(right):Normalized()
end
local function section(s,lateral,lane)
    local pos,right = frame(s,lane)
    local out = {}
    for _,p in ipairs(PROFILE) do
        out[#out+1] = pos + right*(lateral+p[1]) + Vector3(0,p[2],0)
    end
    return out
end

-- 兼容原BuildRail参数；末尾增加lane，仅在明确指定时取不同股道。
---@param body RailwayBatch|GeoBuilder
---@param length number
---@param lateral number
---@param startS number|nil
---@param endS number|nil
---@param heads RailwayBatch|nil
---@param pause fun()|nil
---@param lane integer|nil
function Track.BuildRail(body,length,lateral,startS,endS,heads,pause,lane)
    local first = math.max(0,startS or 0)
    local last = math.min(length,endS or length)
    if last<=first then return end
    local count = math.max(1,math.ceil((last-first)/RAIL_STEP))
    local previous = section(first,lateral,lane)
    for i=1,count do
        local current = section(first+(last-first)*i/count,lateral,lane)
        for j=2,#PROFILE do
            local k = j % #PROFILE + 1
            local target = (j==7 and heads) or body
            target:AddQuad(previous[j],previous[k],current[k],current[j])
        end
        previous = current
        if pause and i % 4==0 then pause() end
    end
end

-- 0/2相邻区合成同一道床截面，避免咽喉碎石顶面重叠闪烁。
-- 站台位于该道床上方；lane1有独立道床，不对站外lane2重复提交。
local function ballastSection(s,lane)
    local pos,right = frame(s,lane)
    local outer,outerRight = pos,right
    if lane==0 then outer,outerRight = frame(s,2) end
    if lane==1 then outer,outerRight = frame(s,5) end
    if lane==0 then
        return {
            outer-outerRight*2.10+Vector3(0,.002,0),
            outer-outerRight*1.60+Vector3(0,.080,0),
            pos+right*1.60+Vector3(0,.080,0),
            pos+right*2.10+Vector3(0,.002,0),
        }
    end
    return {
        pos-right*2.10+Vector3(0,0.002,0),
        pos-right*1.60+Vector3(0,0.080,0),
        outer+outerRight*1.60+Vector3(0,0.080,0),
        outer+outerRight*2.10+Vector3(0,0.002,0),
    }
end
local function buildBallast(target,first,last,lane,pause,step)
    local count = math.max(1,math.ceil((last-first)/step))
    local previous = ballastSection(first,lane)
    for i=1,count do
        local current = ballastSection(first+(last-first)*i/count,lane)
        for j=1,3 do target:AddQuad(previous[j],current[j],current[j+1],previous[j+1]) end
        previous = current
        if pause and i % 8==0 then pause() end
    end
end

-- 枕木省去不可见底面：5面30顶点，而非完整箱体36顶点。
-- 采样网格固定于全线0.6m格点，分块/LOD切换不改变枕木相位。
local function sleeper(target,pos,right,tangent)
    local a = pos-right*1.3-tangent*.12+Vector3(0,.06,0)
    local b = pos+right*1.3-tangent*.12+Vector3(0,.06,0)
    local c = pos+right*1.3+tangent*.12+Vector3(0,.06,0)
    local d = pos-right*1.3+tangent*.12+Vector3(0,.06,0)
    local up = Vector3(0,.10,0)
    target:AddQuad(a+up,d+up,c+up,b+up)
    target:AddQuad(a+up,b+up,b,a)
    target:AddQuad(b+up,c+up,c,b)
    target:AddQuad(c+up,d+up,d,c)
    target:AddQuad(d+up,a+up,a,d)
end
local function buildSleepers(target,first,last,lane,pause)
    local firstIndex = math.ceil((first-.000001)/SLEEPER_STEP)
    local lastIndex = math.ceil((last-.000001)/SLEEPER_STEP)-1
    for index=firstIndex,lastIndex do
        local s = index*SLEEPER_STEP
        if s>=.12 and s<Route.GetLength()-.12 then
            local pos,right,_,tangent = frame(s,lane)
            -- 合流端两线尚未分离时共用正线枕，不叠放一组同位箱体。
            local branch = lane==2 or lane==5
            local mainLane=lane==5 and 1 or 0
            local separation=branch and math.abs(
                RailNetwork.GetLateral(s,lane)-RailNetwork.GetLateral(s,mainLane)
            ) or math.huge
            if not branch or separation>2.60 then
                sleeper(target,pos,right,tangent)
            end
        end
        if pause and index % 16==0 then pause() end
    end
end

-- 有体积的简化压板扣件，不是暗色阴影片：每轨两侧各一件，底面贴枕顶省略。
-- 横断面（相对轨中心，米）    -0.116 -0.062 |轨腰| +0.062 +0.116
-- 0.205 扣件顶                 [压板]             [压板]
-- 0.180 轨底顶                     =====轨底=====
-- 0.160 枕顶                  -----------------------
-- 压板54×100×45mm，顶面压住轨底边缘；最高点距轨面135mm，不侵入轮缘工作区。
-- 只在非喉区正线放置；不改变枕位、不叠加道岔锁闭/尖轨几何，支路不额外加件。
local function fastener(target,pos,right,tangent,lateral)
    local center = pos+right*lateral
    local a = center-right*.027-tangent*.05+Vector3(0,.16,0)
    local b = center+right*.027-tangent*.05+Vector3(0,.16,0)
    local c = center+right*.027+tangent*.05+Vector3(0,.16,0)
    local d = center-right*.027+tangent*.05+Vector3(0,.16,0)
    local up = Vector3(0,.045,0)
    target:AddQuad(a+up,d+up,c+up,b+up)
    target:AddQuad(a+up,b+up,b,a)
    target:AddQuad(b+up,c+up,c,b)
    target:AddQuad(c+up,d+up,d,c)
    target:AddQuad(d+up,a+up,a,d)
end
local function buildFasteners(target,first,last,lane,pause)
    if lane~=0 and lane~=1 then return end
    local step = SLEEPER_STEP*FASTENER_INTERVAL
    local firstIndex = math.ceil((first-.000001)/step)
    local lastIndex = math.ceil((last-.000001)/step)-1
    local crossovers = RailNetwork.GetCrossovers()
    for index=firstIndex,lastIndex do
        local s = index*step
        local clear = s>=.12 and s<Route.GetLength()-.12
            and not RailNetwork.GetSectionAt(s,lane)
        for _,cross in ipairs(crossovers) do
            if s>=cross.first-1 and s<=cross.last+1 then clear=false end
        end
        if clear then
            local pos,right,_,tangent = frame(s,lane)
            for side=-1,1,2 do
                for edge=-1,1,2 do fastener(target,pos,right,tangent,side*RAIL_CENTRE+edge*.089) end
            end
        end
        if pause and index % 4==0 then pause() end
    end
end

-- 中远距离保留轨头与两侧轨腰，双向均可见；只拆材质，不增加原每段18顶点。
local function buildLowRail(body,heads,first,last,lane,pause)
    local count = math.max(1,math.ceil((last-first)/FAR_STEP))
    for i=1,count do
        local s0,s1 = first+(last-first)*(i-1)/count,first+(last-first)*i/count
        local p0,r0 = frame(s0,lane)
        local p1,r1 = frame(s1,lane)
        for side=-1,1,2 do
            local lateral = side*RAIL_CENTRE
            local a = p0+r0*(lateral-HEAD_WIDTH/2)+Vector3(0,.34,0)
            local b = p1+r1*(lateral-HEAD_WIDTH/2)+Vector3(0,.34,0)
            local c = p1+r1*(lateral+HEAD_WIDTH/2)+Vector3(0,.34,0)
            local d = p0+r0*(lateral+HEAD_WIDTH/2)+Vector3(0,.34,0)
            local down = Vector3(0,-.18,0)
            heads:AddQuad(a,b,c,d)
            body:AddQuad(a+down,b+down,b,a)
            body:AddQuad(d,c,c+down,d+down)
        end
        if pause and i % 8==0 then pause() end
    end
end

local function buildElevatedDeck(root,first,last,pause)
    local deckMaterial=World.Concrete() -- 桥面/墩/边梁继续使用原World材质，绝不染成轨枕色
    local steelMaterial=materials_[5]
    local deck=World.NewBatch(root:CreateChild("ElevatedBridgeDeck"),deckMaterial,true,4)
    local edge=World.NewBatch(root:CreateChild("ElevatedBridgeEdgeGirders"),deckMaterial,true,2)
    local railing=World.NewBatch(root:CreateChild("ElevatedBridgeRailings"),steelMaterial,true,2)
    local piers=World.NewBatch(root:CreateChild("ElevatedBridgePiers"),deckMaterial,true,2)
    local hasGeometry=false
    for _,structure in ipairs(Route.GetStructureRanges()) do
        if structure.kind=="bridge" then
            local a,b=math.max(first,structure.first),math.min(last,structure.last)
            if b>a then
                hasGeometry=true
                for s=a,b-.000001,12 do
                    local finish=math.min(b,s+12)
                    local middle=(s+finish)*.5
                    local _,_,yaw=Route.Sample(middle)
                    local span=finish-s+.06
                    deck:AddBox(Route.SampleOffset(middle,BRIDGE_CENTER,(BRIDGE_DECK_TOP+BRIDGE_DECK_BOTTOM)*.5),
                        Vector3(BRIDGE_WIDTH,BRIDGE_DECK_TOP-BRIDGE_DECK_BOTTOM,span),math.rad(yaw))
                    for _,lateral in ipairs({BRIDGE_CENTER-BRIDGE_EDGE+.30,BRIDGE_CENTER+BRIDGE_EDGE-.30}) do
                        edge:AddBox(Route.SampleOffset(middle,lateral,(BRIDGE_DECK_BOTTOM-.12)),
                            Vector3(.60,.80,span),math.rad(yaw))
                        railing:AddBox(Route.SampleOffset(middle,lateral,BRIDGE_DECK_TOP+.78),
                            Vector3(.10,1.56,span),math.rad(yaw))
                    end
                    for at=s,finish-.000001,4 do
                        railing:AddBox(Route.SampleOffset(at,BRIDGE_CENTER-BRIDGE_EDGE+.30,BRIDGE_DECK_TOP+.16),
                            Vector3(.12,.08,.12),math.rad(yaw))
                        railing:AddBox(Route.SampleOffset(at,BRIDGE_CENTER+BRIDGE_EDGE-.30,BRIDGE_DECK_TOP+.16),
                            Vector3(.12,.08,.12),math.rad(yaw))
                    end
                    if pause then pause() end
                end
                local firstPier=math.ceil((a-.000001)/BRIDGE_PIER_STEP)*BRIDGE_PIER_STEP
                for at=firstPier,b-.000001,BRIDGE_PIER_STEP do
                    local _,_,yaw=Route.Sample(at)
                    local bottom=Landmarks.GetValleyY(structure,at,BRIDGE_CENTER)
                    local top=BRIDGE_DECK_BOTTOM-.18
                    local height=top-bottom
                    if height>.5 then
                        for _,lateral in ipairs({-5.5,10.5}) do
                            piers:AddBox(Route.SampleOffset(at,lateral,(bottom+top)*.5),
                                Vector3(1.10,height,1.10),math.rad(yaw))
                        end
                        piers:AddBox(Route.SampleOffset(at,BRIDGE_CENTER,top-.35),
                            Vector3(BRIDGE_WIDTH-.60,.70,1.60),math.rad(yaw))
                    end
                    if pause then pause() end
                end
            end
        end
    end
    if hasGeometry then
        deck:Finish();edge:Finish();railing:Finish();piers:Finish()
    else
        deck.geometry:Dispose();edge.geometry:Dispose();railing.geometry:Dispose();piers.geometry:Dispose()
    end
end


local function branchSeparation(s,lane)
    local branch = RailNetwork.Sample(s,lane)
    local main = RailNetwork.Sample(s,lane==5 and 1 or 0)
    return (branch-main):Length()
end
local function visibleBranchRange(first,last,path,lane)
    local a,b=first,last
    if branchSeparation(a,lane)<.03 then
        local low,high=path.first,path.plateauFirst
        for _=1,24 do
            local mid=(low+high)/2
            if branchSeparation(mid,lane)<.03 then low=mid else high=mid end
        end
        a=math.max(first,(low+high)/2)
    end
    if branchSeparation(b,lane)<.03 then
        local low,high=path.plateauLast,path.last
        for _=1,24 do
            local mid=(low+high)/2
            if branchSeparation(mid,lane)<.03 then high=mid else low=mid end
        end
        b=math.min(last,(low+high)/2)
    end
    return a,b
end

---@class RailwayTrackSpan
---@field first number
---@field last number
---@field lane integer

---@param root Node
---@param first number
---@param last number
---@param detailed boolean
---@param pause fun()|nil
---@return integer
function Track.BuildChunk(root,first,last,detailed,pause)
    Track.Init()
    first,last = math.max(0,first),math.min(Route.GetLength(),last)
    if last<=first then return 0 end
    ---@type RailwayTrackSpan[]
    local spans = {{first=first,last=last,lane=0},{first=first,last=last,lane=1}}
    -- 相交范围覆盖所有站场/区间喉区；只在真实分流范围建2/5，车与轨共采样。
    for _,routing in ipairs(RailNetwork.GetRoutingSections()) do
        for _,lane in ipairs({2,5}) do
            local path=lane==5 and routing.up or routing
            local firstBranch,lastBranch = math.max(first,path.first),math.min(last,path.last)
            if lastBranch>firstBranch then
                -- 合流尖端<3cm共用主轨，不重叠第二组轨头导致z-fighting。
                local a,b=visibleBranchRange(firstBranch,lastBranch,path,lane)
                if b>a then spans[#spans+1] = {first=a,last=b,lane=lane} end
            end
        end
    end
    for _,cross in ipairs(RailNetwork.GetCrossovers()) do
        local a,b=math.max(first,cross.first),math.min(last,cross.last)
        if b>a then spans[#spans+1]={first=a,last=b,lane=cross.lane} end
    end
    local ballast = World.NewBatch(root:CreateChild("SharedSlopedBallast"),materials_[1],false,1)
    for lane=0,1 do buildBallast(ballast,first,last,lane,pause,detailed and RAIL_STEP or FAR_STEP) end
    local vertices = ballast:Finish()
    if pause then pause() end
    buildElevatedDeck(root,first,last,pause)
    if pause then pause() end
    if detailed then
        local sleepers = World.NewBatch(root:CreateChild("SharedConcreteSleepers"),materials_[2],false,1)
        for _,span in ipairs(spans) do buildSleepers(sleepers,span.first,span.last,span.lane,pause) end
        vertices = vertices+sleepers:Finish()
        if pause then pause() end
        local body = World.NewBatch(root:CreateChild("SharedRailISections"),materials_[3],false)
        local heads = World.NewBatch(root:CreateChild("SharedRunningHeads"),materials_[4],false)
        for _,span in ipairs(spans) do
            for side=-1,1,2 do
                Track.BuildRail(body,Route.GetLength(),side*RAIL_CENTRE,span.first,span.last,heads,pause,span.lane)
            end
        end
        for lane=0,1 do buildFasteners(body,first,last,lane,pause) end
        vertices = vertices+body:Finish()
        if pause then pause() end
        vertices = vertices+heads:Finish()
        vertices = vertices+StationYard.BuildIntervalChunk(root,first,last,pause)
    else
        local body = World.NewBatch(root:CreateChild("SharedDistantRailBodies"),materials_[3],false)
        local heads = World.NewBatch(root:CreateChild("SharedDistantRails"),materials_[4],false)
        for _,span in ipairs(spans) do buildLowRail(body,heads,span.first,span.last,span.lane,pause) end
        vertices = vertices+body:Finish()+heads:Finish()
    end
    return vertices
end

-- 保留预览接口，开放线路范围只钳制，绝不从尾部绕回头部。
---@param scene Scene
---@param initialS number|nil
---@return Node
function Track.Build(scene,initialS)
    local root = scene:CreateChild("TrackPreview")
    local s = math.max(0,math.min(Route.GetLength(),initialS or 0))
    local first,last = math.max(0,s-240),math.min(Route.GetLength(),s+360)
    for index=math.floor(first/CHUNK_LENGTH),math.ceil(last/CHUNK_LENGTH)-1 do
        local a = index*CHUNK_LENGTH
        Track.BuildChunk(root:CreateChild("TrackChunk_"..index),a,math.min(a+CHUNK_LENGTH,Route.GetLength()),true)
    end
    return root
end

function Track.GetDimensions()
    return {
        gauge=GAUGE,railCentreOffset=RAIL_CENTRE,headWidth=HEAD_WIDTH,
        railHeadY=.34,footWidth=.15,footY=.16,webWidth=.016,
        sleeperLength=2.6,sleeperSpacing=SLEEPER_STEP,sleeperTopY=.16,
        ballastTopY=.08,ballastTopWidth=3.2,ballastBottomWidth=4.2,chunkLength=CHUNK_LENGTH,
        mainLineCount=2,stationLane=2,upBypassLane=5,upBypassLateral=RailNetwork.UpBypassOffset,
        upLineLateral=5,stationLaneLateral=-10.8,
        topologyMode=RailNetwork.GetTopologyMode(),railMassKgPerM=60,sleeperMaterial="prestressed_concrete",
        detailedBatchesPerChunk=8,distantBatchesPerChunk=3,railStep=RAIL_STEP,
        baseDetailedBatchesPerChunk=4,fastenerSpacing=SLEEPER_STEP*FASTENER_INTERVAL,
        fastenerMaxVerticesPerDoubleLine120m=4800,fastenerAddedBatches=0,fastenerAddedNodes=0,
        elevatedDeckTopY=BRIDGE_DECK_TOP,elevatedDeckBottomY=BRIDGE_DECK_BOTTOM,
        elevatedDeckWidth=BRIDGE_WIDTH,bridgeCenter=BRIDGE_CENTER,pierSpacing=BRIDGE_PIER_STEP,
        approximateDetailVerticesPerLane120m=11400,distantVerticesPerMainLane120m=540,
    }
end
return Track
