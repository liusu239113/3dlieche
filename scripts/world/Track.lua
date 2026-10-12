-- 双正线与可到发侧线共用 RailNetwork.Sample；不再独立计算车辆/钢轨路线。
-- 截面（米，Y-up）：轨头0.340 / 轨底0.160 / 枕顶0.160 / 道床0.080。
-- lane0下行正线，lane1上行正线(-5m)，lane2站内到发线(+10.8m)。
-- 每120m最多4个共享材质批次，不再递归30m产生16次提交；近景枕距仍0.6m。
local World = require "world.WorldMaterials"
local Route = require "world.Route"
local RailNetwork = require "world.RailNetwork"
local Track = {}

local GAUGE = 1.435
local HEAD_WIDTH = 0.072
local RAIL_CENTRE = (GAUGE + HEAD_WIDTH) * 0.5
local SLEEPER_STEP = 0.6
local RAIL_STEP = 6.0
local FAR_STEP = 12.0
local CHUNK_LENGTH = 120.0

-- 保留真实I形截面；隐藏的轨底底面不提交。6m弦长在现有公里级半径上
-- 弦差小于1mm，不用2m细分；密集0.6m枕木和钢轨曲线细分是两件事。
local PROFILE = {
    {-0.075,0.160}, {0.075,0.160}, {0.075,0.180}, {0.008,0.185},
    {0.008,0.298}, {0.036,0.305}, {0.036,0.340}, {-0.036,0.340},
    {-0.036,0.305}, {-0.008,0.298}, {-0.008,0.185}, {-0.075,0.180},
}
---@type Material[]
local materials_ = {}

---@param s number
---@param lane? integer
local function frame(s,lane)
    local pos,_,yaw = RailNetwork.Sample(s,lane or 0)
    local a = math.rad(yaw)
    return pos,Vector3(math.cos(a),0,-math.sin(a)),yaw
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
local function sleeper(target,pos,right,yaw)
    local tangent = Vector3(math.sin(math.rad(yaw)),0,math.cos(math.rad(yaw)))
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
            local pos,right,yaw = frame(s,lane)
            -- 合流端两线尚未分离时共用正线枕，不叠放一组同位箱体。
            local main = lane==2 and RailNetwork.Sample(s,0) or pos
            if lane~=2 or (pos-main):LengthSquared()>2.60^2 then
                sleeper(target,pos,right,yaw)
            end
        end
        if pause and index % 16==0 then pause() end
    end
end

-- 中远距离保留轨头与两侧轨腰，双向均可见；不是只能俯视的单面色带。
local function buildLowRail(target,first,last,lane,pause)
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
            target:AddQuad(a,b,c,d)
            target:AddQuad(a+down,b+down,b,a)
            target:AddQuad(d,c,c+down,d+down)
        end
        if pause and i % 8==0 then pause() end
    end
end

function Track.Init()
    if #materials_==0 then
        materials_ = {World.Ballast(),World.Concrete(),
            World.Solid(Color(.30,.31,.32),.86,.46),World.Solid(Color(.62,.64,.66),.78,.60)}
    end
end

local function branchSeparation(s)
    local branch = RailNetwork.Sample(s,2)
    local main = RailNetwork.Sample(s,0)
    return (branch-main):Length()
end
local function visibleBranchRange(first,last,stationS)
    local a,b=first,last
    if branchSeparation(a)<.03 then
        local low,high=stationS-700,stationS-320
        for _=1,24 do
            local mid=(low+high)/2
            if branchSeparation(mid)<.03 then low=mid else high=mid end
        end
        a=math.max(first,(low+high)/2)
    end
    if branchSeparation(b)<.03 then
        local low,high=stationS+160,stationS+400
        for _=1,24 do
            local mid=(low+high)/2
            if branchSeparation(mid)<.03 then high=mid else low=mid end
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
    -- 相交范围也覆盖站点不在本120m块内的咽喉；仅站内实际分流区建lane2。
    for _,st in ipairs(RailNetwork.GetStations()) do
        local firstBranch,lastBranch = math.max(first,st.s-700),math.min(last,st.s+400)
        if lastBranch>firstBranch then
            -- 合流尖端<3cm共用主轨，不重叠第二组轨头导致z-fighting。
            local a,b=visibleBranchRange(firstBranch,lastBranch,st.s)
            if b>a then spans[#spans+1] = {first=a,last=b,lane=2} end
        end
    end
    local ballast = World.NewBatch(root:CreateChild("SharedSlopedBallast"),materials_[1],false,1)
    for lane=0,1 do buildBallast(ballast,first,last,lane,pause,detailed and RAIL_STEP or FAR_STEP) end
    local vertices = ballast:Finish()
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
        vertices = vertices+body:Finish()
        if pause then pause() end
        vertices = vertices+heads:Finish()
    else
        local steel = World.NewBatch(root:CreateChild("SharedDistantRails"),materials_[4],false)
        for _,span in ipairs(spans) do buildLowRail(steel,span.first,span.last,span.lane,pause) end
        vertices = vertices+steel:Finish()
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
        mainLineCount=2,stationLane=2,upLineLateral=-5,stationLaneLateral=10.8,
        detailedBatchesPerChunk=4,distantBatchesPerChunk=2,railStep=RAIL_STEP,
        approximateDetailVerticesPerLane120m=9000,distantVerticesPerMainLane120m=540,
    }
end
return Track
