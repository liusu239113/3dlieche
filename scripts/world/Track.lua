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
    local pos = Route.Sample(s)
    local right = Route.RightAt(s)
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
function Track.BuildRail(body, length, lateral, startS, endS, heads)
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
    end
end

-- 连续带状斜坡碎石道床，不再用重叠平板近似。
-- 3.2 米道床顶面高于地面，车站站台替代靠外的部分边坡。
local function ballastSection(s)
    return {
        Route.SampleOffset(s, -2.10, 0.002),
        Route.SampleOffset(s, -1.60, 0.080),
        Route.SampleOffset(s, 1.60, 0.080),
        Route.SampleOffset(s, 2.10, 0.002),
    }
end
local function buildBallast(batch, first, last)
    local count = math.max(1, math.ceil((last - first) / RAIL_STEP))
    local previous = ballastSection(first)
    for i = 1, count do
        local current = ballastSection(first + (last - first) * i / count)
        for j = 1, 3 do
            batch:AddQuad(previous[j], current[j], current[j + 1], previous[j + 1])
        end
        previous = current
    end
end

---@param scene Scene
---@return Node
function Track.Build(scene)
    local root = scene:CreateChild("Track")
    local length = Route.GetLength()
    if length <= 0 then
        print("[Track] 错误：请先构建线路再构建轨道")
        return root
    end
    local t0 = os.clock()
    local ballast = World.Ballast()
    local concrete = World.Concrete()
    local railBody = World.Solid(Color(0.30, 0.31, 0.32), 0.86, 0.46)
    local railHead = World.Solid(Color(0.62, 0.64, 0.66), 0.94, 0.24)
    local chunks = math.ceil(length / CHUNK_LENGTH)
    local sleepers = 0
    local vertices = 0
    for chunk = 1, chunks do
        local first = (chunk - 1) * CHUNK_LENGTH
        local last = math.min(chunk * CHUNK_LENGTH, length)
        local node = root:CreateChild("TrackChunk_" .. chunk)
        local bb = World.NewBatch(node:CreateChild("SlopedBallast"), ballast, false, 1)
        local sb = World.NewBatch(node:CreateChild("ConcreteSleepers"), concrete, false, 1)
        local rb = World.NewBatch(node:CreateChild("RailISection"), railBody, false)
        local hb = World.NewBatch(node:CreateChild("RunningHeads"), railHead, false)
        buildBallast(bb, first, last)
        -- 全线使用同一 0.6 米枕距网格，不在分块边界重启。
        -- 接缝仅调整最后一根，闭合处不重复添加轨枕。
        local firstIndex = math.ceil((first - 0.000001) / SLEEPER_STEP)
        local lastIndex = math.ceil((last - 0.000001) / SLEEPER_STEP) - 1
        for index = firstIndex, lastIndex do
            local s = index * SLEEPER_STEP
            if s < length - 0.30 then
                local pos, _, yaw = Route.Sample(s)
                sb:AddBox(pos + Vector3(0, 0.110, 0), Vector3(2.60, 0.10, 0.24), math.rad(yaw))
                sleepers = sleepers + 1
            end
        end
        Track.BuildRail(rb, length, -RAIL_CENTRE, first, last, hb)
        Track.BuildRail(rb, length, RAIL_CENTRE, first, last, hb)
        vertices = vertices + bb:Finish() + sb:Finish() + rb:Finish() + hb:Finish()
    end
    print(string.format("[Track] 轨距 %.3f 米，轨面 0.340 米；轨枕 %d 根/枕距 0.6 米；%d 块/%d 网格，%d 顶点，耗时 %.2f 秒",
        GAUGE, sleepers, chunks, chunks * 4, vertices, os.clock() - t0))
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
