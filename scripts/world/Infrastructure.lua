-- 普速电气化铁路设施：接触网、封闭护栏、电缆槽、排水沟与公里标。
-- 沿既有闭合线路采样，所有坐标使用米；不增加平交道口或改变车辆物理。
local Route = require "world.Route"
local World = require "world.WorldMaterials"
local Materials = require "config.Materials"
local Infrastructure = {}

local CONTACT_Y = 6.10
local MESSENGER_Y = 7.05
---@type table[]
local mastData_ = {}
local spanCount_ = 0

local function nearStation(s, margin)
    local length = Route.GetLength()
    for _, st in ipairs(Route.GetStations()) do
        local delta = (s - st.s + length * 0.5) % length - length * 0.5
        if delta >= Route.PlatformStart - margin and delta <= Route.PlatformEnd + margin then
            return true
        end
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
    batch:AddQuad(a1, b1, b2, a2)
    batch:AddQuad(a2, b2, b3, a3)
    batch:AddQuad(a3, b3, b4, a4)
    batch:AddQuad(a4, b4, b1, a1)
    batch:AddQuad(a1, a2, a3, a4)
    batch:AddQuad(b1, b4, b3, b2)
end

---@type Material[]
local materials_ = {}
function Infrastructure.Init()
    local count = math.ceil(Route.GetLength() / 48)
    spanCount_ = count + count % 2 -- 拉出值交替，闭合接缝也必须同相。
    mastData_ = {}
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

---@param root Node
local function buildCatenary(root, rangeStart, rangeEnd, pause)
    local length = Route.GetLength()
    local step = length / spanCount_
    local steelMat, wireMat, insulatorMat, concreteMat = materials_[1], materials_[2], materials_[3], materials_[4]
    local startIndex = math.ceil((rangeStart - 0.000001) / step)
    local endIndex = math.min(spanCount_ - 1, math.ceil((rangeEnd - 0.000001) / step) - 1)
    for first = startIndex, endIndex do
        local node = root:CreateChild("CatenaryChunk_" .. first)
        local poles = World.NewBatch(node:CreateChild("MastsAndArms"), steelMat, true)
        local wires = World.NewBatch(node:CreateChild("ContactAndMessenger"), wireMat, false)
        local insulators = World.NewBatch(node:CreateChild("Insulators"), insulatorMat, true)
        local bases = World.NewBatch(node:CreateChild("Foundations"), concreteMat, false, 1)
        for i = first, first do
            local s = i * step
            -- 站内电杆位于雨棚之外，区间电杆位于轨道/排水设施之外。
            local lateral = nearStation(s, 18) and -10.7 or -4.9
            local _, _, yaw = Route.Sample(s)
            local angle = math.rad(yaw)
            local foot = Route.SampleOffset(s, lateral, 0)
            local zigzag = i % 2 == 0 and -0.18 or 0.18
            local top = Route.SampleOffset(s, lateral, 7.65)
            bases:AddBox(foot + Vector3(0, 0.22, 0), Vector3(0.85, 0.44, 0.85), angle)
            poles:AddBox(foot + Vector3(0, 4.0, 0), Vector3(0.24, 7.8, 0.24), angle)
            -- 三角悬臂悬挂承力索和接触线，站内长悬臂也保持在棚顶以上。
            beam(poles, top, Route.SampleOffset(s, zigzag, 7.20), 0.075)
            beam(poles, Route.SampleOffset(s, lateral, 6.75),
                Route.SampleOffset(s, zigzag, 7.20), 0.065)
            beam(insulators, Route.SampleOffset(s, lateral * 0.53, 7.28),
                Route.SampleOffset(s, lateral * 0.53 + 0.5, 7.23), 0.14)
            beam(poles, Route.SampleOffset(s, zigzag, 7.20),
                Route.SampleOffset(s, zigzag, CONTACT_Y), 0.035)
            local previousContact = Route.SampleOffset(s, zigzag, CONTACT_Y)
            local previousMessenger = Route.SampleOffset(s, zigzag, MESSENGER_Y)
            -- 每跨8段顺曲线采样；导线不会在弯道切进车体，吊弦随承力索弧垂。
            for j = 1, 8 do
                local t = j / 8
                local at = s + step * t
                local offset = zigzag * (1 - 2 * t)
                local contact = Route.SampleOffset(at, offset, CONTACT_Y)
                local messenger = Route.SampleOffset(at, offset, MESSENGER_Y - 0.22 * math.sin(math.pi * t))
                beam(wires, previousContact, contact, 0.022)
                beam(wires, previousMessenger, messenger, 0.026)
                if j < 8 and j % 2 == 0 then beam(wires, contact, messenger, 0.018) end
                previousContact, previousMessenger = contact, messenger
                if pause then pause() end
            end
        end
        poles:Finish(); if pause then pause() end
        wires:Finish(); if pause then pause() end
        insulators:Finish(); bases:Finish()
        if pause then pause() end
    end
end

---@param root Node
local function buildCorridor(root, rangeStart, rangeEnd, pause)
    local concreteMat, steelMat, darkMat = materials_[4], materials_[5], materials_[6]
    local fencePanels = 0
    -- 子网格16米封顶，避免Finish切线生成成为不可中断的大帧。
    for first = rangeStart, rangeEnd - 0.000001, 16 do
        local last = math.min(first + 16, rangeEnd)
        local node = root:CreateChild("CorridorChunk_" .. first)
        local concrete = World.NewBatch(node:CreateChild("CableTroughsAndPosts"), concreteMat, false, 1)
        local fencing = World.NewBatch(node:CreateChild("FenceMesh"), steelMat, false)
        local drainage = World.NewBatch(node:CreateChild("Drainage"), darkMat, false)
        for s = first, last - 0.001, 4 do
            local nextS = math.min(s + 4, last)
            if not nearStation(s, 8) and not nearStation(nextS, 8) then
                local midS = (s + nextS) * 0.5
                local _, _, yaw = Route.Sample(midS)
                local angle = math.rad(yaw)
                for side = -1, 1, 2 do
                    concrete:AddBox(Route.SampleOffset(midS, side * 2.75, 0.105),
                        Vector3(0.38, 0.17, nextS - s - 0.05), angle)
                    local p1 = Route.SampleOffset(s, side * 3.55, 0.022)
                    local p2 = Route.SampleOffset(nextS, side * 3.55, 0.022)
                    -- 暗沟底与混凝土侧沿，不挖穿既有平坦线路基准。
                    beam(drainage, p1, p2, 0.42)
                    for _, offset in ipairs({3.29, 3.81}) do
                        beam(concrete, Route.SampleOffset(s, side * offset, 0.10),
                            Route.SampleOffset(nextS, side * offset, 0.10), 0.12)
                    end
                    local lat = side * 14
                    concrete:AddBox(Route.SampleOffset(s, lat, 1.10), Vector3(0.13, 2.20, 0.13), angle)
                    for _, y in ipairs({0.30, 1.05, 2.05}) do
                        beam(fencing, Route.SampleOffset(s, lat, y), Route.SampleOffset(nextS, lat, y), 0.028)
                    end
                    for j = 1, 7 do
                        local at = s + (nextS - s) * j / 8
                        beam(fencing, Route.SampleOffset(at, lat, 0.3), Route.SampleOffset(at, lat, 2.05), 0.018)
                    end
                    fencePanels = fencePanels + 1
                    if pause then pause() end
                end
            end
        end
        concrete:Finish(); if pause then pause() end
        fencing:Finish(); if pause then pause() end
        drainage:Finish(); if pause then pause() end
    end
    return fencePanels
end

---@param root Node
local function buildMarkers(root, rangeStart, rangeEnd)
    local white = World.NewBatch(root:CreateChild("KilometrePosts"), materials_[7], false)
    local black = World.NewBatch(root:CreateChild("MarkerBases"), materials_[8], false)
    local count = 0
    for s = math.ceil((rangeStart - 0.000001) / 100) * 100, rangeEnd - 0.000001, 100 do
        if not nearStation(s, 10) then
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
    local seen = {}
    for at = (initialS or 0) - 96, (initialS or 0) + 96, 32 do
        local index = math.floor(Route.Wrap(at) / 32)
        if not seen[index] then
            seen[index] = true
            Infrastructure.BuildChunk(root:CreateChild("Infrastructure_" .. index), index * 32,
                math.min(index * 32 + 32, Route.GetLength()))
        end
    end
    return root
end

function Infrastructure.GetValidationData()
    -- 数值描述与加载窗口无关，按需计算全线2095跨，无渲染对象。
    local masts = {}
    if spanCount_ > 0 then
        local step = Route.GetLength() / spanCount_
        for i = 0, spanCount_ - 1 do
            local s = i * step
            local lateral = nearStation(s, 18) and -10.7 or -4.9
            local foot = Route.SampleOffset(s, lateral, 0)
            masts[#masts + 1] = {s = s, lateral = lateral, x = foot.x, z = foot.z}
        end
    end
    return {contactHeight = CONTACT_Y, messengerHeight = MESSENGER_Y, spans = spanCount_, masts = masts}
end
return Infrastructure
