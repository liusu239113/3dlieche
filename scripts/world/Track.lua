-- 一条可双向运行、双向可见的物理单线路。
-- 截面（单位米，Y 向上，地面基准为 0）：
--       抛光轨头 ----------------------- Y=0.340
--           I 型轨腰                     Y=0.180..0.305
--        轨底 / 混凝土轨枕顶面           Y=0.160
--      ____ 2.6 米混凝土轨枕 ____         Y=0.060..0.160
--     /      碎石道床边坡         \       Y=0.080
-- ___/___________________________\___    Y=0.000
-- 标准轨距 1.435 米指两条钢轨轨头内侧面间距，不是钢轨中心间距。
local World = require "world.WorldMaterials"
local Route = require "world.Route"
local Track = {}

local GAUGE = 1.435
local HEAD_WIDTH = 0.072
local RAIL_CENTRE = (GAUGE + HEAD_WIDTH) * 0.5
local SLEEPER_STEP = 0.6
local RAIL_STEP = 2.0
local CHUNK_LENGTH = 120.0

-- 局部 XY 平面逆时针截面，沿局部 +Z 拉伸。
local PROFILE = {
    { -0.075, 0.160 }, { 0.075, 0.160 }, { 0.075, 0.180 },
    { 0.008, 0.185 }, { 0.008, 0.298 }, { 0.036, 0.305 },
    { 0.036, 0.340 }, { -0.036, 0.340 }, { -0.036, 0.305 },
    { -0.008, 0.298 }, { -0.008, 0.185 }, { -0.075, 0.180 },
}

local function section(s, lateral)
    local pos, _, yaw = Route.Sample(s)
    local a = math.rad(yaw)
    local right = Vector3(math.cos(a), 0, -math.sin(a))
    local out = {}
    for _, p in ipairs(PROFILE) do
        out[#out + 1] = pos + right * (lateral + p[1]) + Vector3(0, p[2], 0)
    end
    return out
end

-- 保留公开接口，可选起止弧长限制分块范围。
-- 轨头顶面单独批次，呈现抛光走行面。
---@param body RailwayBatch|GeoBuilder
---@param length number
---@param lateral number
---@param startS number|nil
---@param endS number|nil
---@param heads RailwayBatch|nil
---@param pause fun()|nil
function Track.BuildRail(body, length, lateral, startS, endS, heads, pause)
    local first, last = startS or 0, endS or length
    local count = math.max(1, math.ceil((last - first) / RAIL_STEP))
    local previous = section(first, lateral)
    for i = 1, count do
        local current = section(first + (last - first) * i / count, lateral)
        for j = 1, #PROFILE do
            local k = j % #PROFILE + 1
            local batch = (j == 7 and heads) or body
            batch:AddQuad(previous[j], previous[k], current[k], current[j])
        end
        previous = current
        if pause and i % 4 == 0 then pause() end
    end
end

-- 连续带状斜坡碎石道床，不再用重叠平板近似。
-- 3.2 米道床顶面高于地面，车站站台替代靠外的部分边坡。
local function ballastSection(s)
    local pos, _, yaw = Route.Sample(s)
    local a = math.rad(yaw)
    local right = Vector3(math.cos(a), 0, -math.sin(a))
    return {
        pos - right * 2.10 + Vector3(0, 0.002, 0),
        pos - right * 1.60 + Vector3(0, 0.080, 0),
        pos + right * 1.60 + Vector3(0, 0.080, 0),
        pos + right * 2.10 + Vector3(0, 0.002, 0),
    }
end
local function buildBallast(batch, first, last, pause, step)
    local count = math.max(1, math.ceil((last - first) / (step or RAIL_STEP)))
    local previous = ballastSection(first)
    for i = 1, count do
        local current = ballastSection(first + (last - first) * i / count)
        for j = 1, 3 do
            batch:AddQuad(previous[j], current[j], current[j + 1], previous[j + 1])
        end
        previous = current
        if pause and i % 12 == 0 then pause() end
    end
end

---@type Material[]
local materials_ = {}
function Track.Init()
    if #materials_ == 0 then
        materials_ = {World.Ballast(), World.Concrete(),
            World.Solid(Color(0.30, 0.31, 0.32), 0.86, 0.46),
            World.Solid(Color(0.62, 0.64, 0.66), 0.94, 0.24)}
    end
end

-- 每个范围独占根节点。调用方可传协程yield，半成品由WorldStream隐藏。
-- 近景保留I形轨/真实枕距；远景仅简化不可辨认的轨腰，轨头高与轨距不变。
---@param root Node
---@param first number
---@param last number
---@param detailed boolean
---@param pause fun()|nil
---@return integer
function Track.BuildChunk(root, first, last, detailed, pause)
    Track.Init()
    -- 管理块120米，但不可中断的Finish只提交至多30米网格。
    if detailed and last-first>30.000001 then
        local total=0
        for at=first,last-0.000001,30 do
            total=total+Track.BuildChunk(root:CreateChild("Detail_"..at),at,math.min(at+30,last),true,pause)
            if pause then pause() end
        end
        return total
    end
    local bb = World.NewBatch(root:CreateChild("SlopedBallast"), materials_[1], false, 1)
    buildBallast(bb, first, last, pause, detailed and 2 or 12)
    local vertices = bb:Finish()
    if pause then pause() end
    if detailed then
        local sb = World.NewBatch(root:CreateChild("ConcreteSleepers"), materials_[2], false, 1)
        local firstIndex = math.ceil((first - 0.000001) / SLEEPER_STEP)
        local lastIndex = math.ceil((last - 0.000001) / SLEEPER_STEP) - 1
        for index = firstIndex, lastIndex do
            local s = index * SLEEPER_STEP
            if s < Route.GetLength() - 0.30 then
                local pos, _, yaw = Route.Sample(s)
                sb:AddBox(pos + Vector3(0, 0.110, 0), Vector3(2.60, 0.10, 0.24), math.rad(yaw))
            end
            if pause and index % 12 == 0 then pause() end
        end
        vertices = vertices + sb:Finish()
        if pause then pause() end
        local rb = World.NewBatch(root:CreateChild("RailISection"), materials_[3], false)
        local hb = World.NewBatch(root:CreateChild("RunningHeads"), materials_[4], false)
        Track.BuildRail(rb, Route.GetLength(), -RAIL_CENTRE, first, last, hb, pause)
        Track.BuildRail(rb, Route.GetLength(), RAIL_CENTRE, first, last, hb, pause)
        vertices = vertices + rb:Finish()
        if pause then pause() end
        vertices = vertices + hb:Finish()
    else
        local heads = World.NewBatch(root:CreateChild("DistantRunningHeads"), materials_[4], false)
        local count = math.max(1, math.ceil((last - first) / 12))
        for i = 1, count do
            local s0, s1 = first + (last - first) * (i - 1) / count, first + (last - first) * i / count
            for side = -1, 1, 2 do
                local lateral = side * RAIL_CENTRE
                heads:AddQuad(Route.SampleOffset(s0, lateral - HEAD_WIDTH / 2, 0.34),
                    Route.SampleOffset(s1, lateral - HEAD_WIDTH / 2, 0.34),
                    Route.SampleOffset(s1, lateral + HEAD_WIDTH / 2, 0.34),
                    Route.SampleOffset(s0, lateral + HEAD_WIDTH / 2, 0.34))
            end
        end
        vertices = vertices + heads:Finish()
    end
    return vertices
end

-- 保留测试入口但默认只建首站附近，不意外同步构建100公里。
---@param scene Scene
---@param initialS number|nil
---@return Node
function Track.Build(scene, initialS)
    local root = scene:CreateChild("TrackPreview")
    local s = initialS or 0
    local count = math.ceil(Route.GetLength() / CHUNK_LENGTH)
    local seen = {}
    for at = s - 240, s + 360, CHUNK_LENGTH do
        local index = math.min(count - 1, math.floor(Route.Wrap(at) / CHUNK_LENGTH))
        if not seen[index] then
            seen[index] = true
            local first = index * CHUNK_LENGTH
            Track.BuildChunk(root:CreateChild("TrackChunk_" .. index), first,
                math.min(first + CHUNK_LENGTH, Route.GetLength()), true)
        end
    end
    return root
end

-- 提供数值验收数据，主线程无需反查渲染网格。
function Track.GetDimensions()
    return {
        gauge = GAUGE, railCentreOffset = RAIL_CENTRE, headWidth = HEAD_WIDTH,
        railHeadY = 0.34, footWidth = 0.15, footY = 0.16, webWidth = 0.016,
        sleeperLength = 2.6, sleeperSpacing = SLEEPER_STEP, sleeperTopY = 0.16,
        ballastTopY = 0.08, ballastTopWidth = 3.2, ballastBottomWidth = 4.2,
        chunkLength = CHUNK_LENGTH,
    }
end
return Track
