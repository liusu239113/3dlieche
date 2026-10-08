-- ============================================================================
-- 整线路验收：真实主入口、全编组、站场净空、弯道转向架与仪表
-- 由 run-lua-validate 执行，非游戏入口。截图写入 screenshots，仅供内部验收。
-- ============================================================================
require "main"
local startGame = Start
local postUpdateGame = HandlePostUpdate
local Route = require "world.Route"
local Track = require "world.Track"
local Station = require "world.Station"
local Terrain = require "world.Terrain"
local Train = require "train.Train"
local TrainCamera = require "train.Camera"
local Hud = require "ui.Hud"
local UI = require "urhox-libs/UI"
local MeshUtils = require "core.MeshUtils"
local Materials = require "config.Materials"
local Game = require "game.Game"
local GameConfig = require "config.GameConfig"

---@type Node|nil
local obstacle_ = nil
local originalSight_ = 0.0
local releasedPressure_ = 0.0

---@param widget Widget
---@return Widget|nil
local function findRelease(widget)
    if widget.props.text == "缓解" then return widget end
    for _, child in ipairs(widget:GetChildren()) do
        local match = findRelease(child)
        if match then return match end
    end
    return nil
end

---@param id string
---@return number, number
local function controlCenter(id)
    local root = assert(Hud.GetRoot())
    local widget = assert(root:FindById(id))
    local layout = widget:GetAbsoluteLayout()
    return (layout.x + layout.w * 0.5) * UI.GetScale(),
        (layout.y + layout.h * 0.5) * UI.GetScale()
end

-- 走真实InputAdapter链，验证main持续制动状态不被键盘读取覆盖。
---@param frame integer
local function checkInput(frame)
    local root = assert(Hud.GetRoot())
    local throttle = assert(root:FindById("throttleHandle")) --[[@as CabLever]]
    if frame == 10 then
        Train.Reset(Route.GetStations()[1].s - 250)
        TogglePause()
        local l = throttle:GetAbsoluteLayout()
        UI.InputAdapter.HandleTouchBegin(900, (l.x + l.w * 0.59) * UI.GetScale(),
            (l.y + 34) * UI.GetScale(), 0.5)
    elseif frame == 12 then
        assert(Train.GetThrottle() == 8, "触摸油门顶部没有切到8档")
        local l = throttle:GetAbsoluteLayout()
        UI.InputAdapter.HandleTouchMove(900, (l.x + l.w * 0.59) * UI.GetScale(),
            (l.y + l.h * 0.5 + 1.5) * UI.GetScale(), 0.5)
    elseif frame == 14 then
        assert(Train.GetThrottle() == 4, "拖动油门到中间没有切到4档")
        local l = throttle:GetAbsoluteLayout()
        UI.InputAdapter.HandleTouchMove(900, (l.x + l.w * 0.59) * UI.GetScale(),
            (l.y + l.h - 31) * UI.GetScale(), 0.5)
    elseif frame == 16 then
        local notch = Train.GetThrottle()
        local tx, ty = controlCenter("throttleHandle")
        UI.InputAdapter.HandleTouchEnd(900, tx, ty)
        assert(notch == 0, "拖动油门到底部没有回到0档")
        assert(throttle.pointer_ == nil, "油门拖动结束没有释放指针")
        local x, y = controlCenter("brakeHandle")
        UI.InputAdapter.HandleTouchBegin(901, x, y, 0.5)
    elseif frame == 20 then
        local held = Hud.GetReadings().brakeHeld
        releasedPressure_ = Train.GetBrake()
        local x, y = controlCenter("brakeHandle")
        UI.InputAdapter.HandleTouchEnd(901, x, y)
        assert(held and releasedPressure_ > 0.25, "触摸按住没有持续制动")
    elseif frame == 22 then
        assert(not Hud.GetReadings().brakeHeld, "触摸松开后仍持续制动")
        assert(math.abs(Train.GetBrake() - releasedPressure_) < 0.001, "松开错误地清零制动力")
        local x, y = controlCenter("brakeHandle")
        UI.InputAdapter.HandleTouchBegin(902, x, y, 0.5)
    elseif frame == 24 then
        UI.InputAdapter.HandleTouchCancel(902)
    elseif frame == 26 then
        assert(not Hud.GetReadings().brakeHeld, "触摸取消后仍持续制动")
        local release = assert(findRelease(root), "缓解按钮未创建")
        local l = release:GetAbsoluteLayout()
        UI.InputAdapter.HandleTouchBegin(903, (l.x + l.w / 2) * UI.GetScale(),
            (l.y + l.h / 2) * UI.GetScale(), 0.5)
        UI.InputAdapter.HandleTouchEnd(903, (l.x + l.w / 2) * UI.GetScale(),
            (l.y + l.h / 2) * UI.GetScale())
    elseif frame == 28 then
        assert(Train.GetBrake() == 0, "缓解按钮没有释放制动力")
        TogglePause()
        Train.Reset(Route.GetStations()[1].s - 55)
        Hud.SetNextStation("55 m")
        Hud.SetThrottle(0, 8)
        Hud.SetBrake(0)
        print("[RailwayValidation] 真实触摸拖动8/4/0档、持续制动/松手/取消、缓解通过")
    end
end

local frame_ = 0

local function checkLayout()
    local vw, vh = UI.GetViewportSize()
    local layout = Hud.GetLayout()
    for _, key in ipairs({"speedometer", "controls", "station", "actions"}) do
        local rect = layout[key]
        assert(rect.w > 0 and rect.h > 0, "仪表尺寸无效：" .. key)
        assert(rect.x >= 0 and rect.y >= 0 and rect.x + rect.w <= vw + 1
            and rect.y + rect.h <= vh + 1, "仪表超出屏幕：" .. key)
    end
    local a, b = layout.speedometer, layout.controls
    assert(a.x + a.w <= b.x or b.x + b.w <= a.x or a.y + a.h <= b.y
        or b.y + b.h <= a.y, "速度表与手柄重叠")
    print(string.format("[RailwayValidation] 实际仪表布局%.0fx%.0f、边界与重叠检查通过", vw, vh))
end

local cases_ = {}
local current_ = 0
---@type Scene|nil
local scene_ = nil

local function cross(ax, az, bx, bz) return ax * bz - az * bx end
local function checkRoute()
    local samples = {}
    local count = math.ceil(Route.GetLength() / 20)
    for i = 1, count do
        local p = Route.Sample((i - 1) * Route.GetLength() / count)
        assert(math.abs(p.y) < 0.00001, "线路地面基准不一致")
        samples[i] = p
    end
    for i = 1, count do
        local a, b = samples[i], samples[i % count + 1]
        local rx, rz = b.x - a.x, b.z - a.z
        for j = i + 2, count do
            if not (i == 1 and j == count) then
                local c, d = samples[j], samples[j % count + 1]
                local sx, sz = d.x - c.x, d.z - c.z
                local denominator = cross(rx, rz, sx, sz)
                if math.abs(denominator) > 0.000001 then
                    local qx, qz = c.x - a.x, c.z - a.z
                    local t, u = cross(qx, qz, sx, sz) / denominator, cross(qx, qz, rx, rz) / denominator
                    assert(not (t > 0 and t < 1 and u > 0 and u < 1), "非相邻线路出现无道岔平交")
                end
            end
        end
    end
    local nearEnd, tangentEnd = Route.Sample(Route.GetLength() - 0.0001)
    local beginning, tangentStart = Route.Sample(0)
    assert((nearEnd - beginning):Length() < 0.001, "闭合端位置不连续")
    assert((tangentEnd - tangentStart):Length() < 0.001, "闭合端朝向不连续")
    local track = Track.GetDimensions()
    assert(math.abs(track.gauge - 1.435) < 0.00001 and math.abs(track.railHeadY - 0.34) < 0.00001,
        "轨距或轨面高度错误")
    assert(math.abs(track.sleeperSpacing - 0.6) < 0.00001, "轨枕间距错误")
end

local function checkWorld()
    local dimensions = Station.GetDimensions()
    assert(dimensions.sideGap >= 0.19 and dimensions.canopyInner > 2.15, "站台或雨棚侵入列车净空")
    local stations = Route.GetStations()
    assert(#stations == 5, "车站数量错误")
    for i, st in ipairs(stations) do
        local nextStation = stations[i % #stations + 1]
        assert(Route.ForwardDistance(st.s, nextStation.s) >= 350, "相邻站台重叠")
        local _, startTangent = Route.Sample(st.s + Route.PlatformStart)
        local _, endTangent = Route.Sample(st.s + Route.PlatformEnd)
        assert((startTangent - endTangent):Length() < 0.00001, "长站台跨越曲线")
    end
    for _, placements in ipairs({ Station.GetPlacementData(), Terrain.GetPlacementData() }) do
        for _, building in ipairs(placements) do
            local distance = Route.DistanceTo(Vector3(building.x, 0, building.z))
            assert(distance - building.radius >= 25, "建筑压住铁路走廊：" .. building.name)
        end
    end
end

local function checkTrainPose(s)
    Train.Reset(s)
    assert(Train.GetCarCount() == 8, "编组数量错误")
    for i, car in ipairs(Train.GetCars()) do
        assert(math.abs(car.node.position.y) < 0.00001, "车体钻地或悬空")
        if i > 1 then
            assert(#car.bogies == 2, "客车缺少两组转向架")
            for _, bogie in ipairs(car.bogies) do
                local desired = Route.Sample(s + car.offset + bogie.z)
                assert((bogie.node.worldPosition - desired):Length() < 0.001, "转向架支点脱轨")
                -- 不依赖名称索引：返回的bogie中轮节点名称可以有序号。
                local wheelCount = 0
                for _, node in ipairs(bogie.node:GetChildren(true)) do
                    if node.name:find("Wheel") then
                        wheelCount = wheelCount + 1
                        assert(math.abs(node.worldPosition.y - 0.80) < 0.015, "客车车轮接触高度错误")
                    end
                end
                assert(wheelCount >= 4, "双轴转向架缺轮")
            end
        end
    end
end

local function checkGameplay()
    local first = assert(Route.GetStations()[1])
    Train.Reset(first.s - 55)
    Game.Init()
    Game.ThrottleUp()
    Train.Update(1 / 60)
    Game.Update(1 / 60)
    assert(not Game.IsDwelling() and Game.GetXp() == 0, "启动推油门被错误判到站")

    Train.Reset(first.s - 55)
    Game.Init()
    Game.EmergencyBrake()
    Game.ThrottleUp()
    Game.ThrottleDown()
    Train.Update(1 / 60)
    Game.Update(1 / 60)
    assert(not Train.IsMoving() and Game.GetXp() == 0, "未实际行驶却获得到站奖励")

    for _, offset in ipairs({-20, 20, -55, 55}) do
        Train.Reset(first.s - 250)
        Game.Init()
        Train.Reset(first.s + offset)
        Train.SetThrottle(8)
        Train.Update(0.1)
        Game.Update(0.1)
        assert(not Game.IsDwelling(), "低速带油门通过被错误判到站")
        Train.SetThrottle(0)
        Train.SetBrake(1)
        Train.Update(0.1)
        Game.Update(0.1)
        local gained = GameConfig.Gameplay.XpPerStation
        if math.abs(offset) < GameConfig.Gameplay.StopTolerance * 0.35 then
            gained = gained + GameConfig.Gameplay.XpSpeedBonus
        end
        assert(Game.IsDwelling() and Game.GetXp() == gained, "停车点前后停稳没有正确接站/奖励")
        Game.ThrottleUp()
        Game.Brake(0.25)
        assert(Train.GetThrottle() == 0 and Train.GetBrake() == 1, "站停期间操作突破了制动保护")
        Game.Update(GameConfig.Gameplay.DwellTime + 0.1)
        assert(not Game.IsDwelling() and Game.GetNextStation().index == Route.GetStations()[2].index
            and Game.GetXp() == gained, "站停结束没有只推进一次车站")
        Game.ThrottleUp()
        Train.Update(0.1)
        assert(Train.GetSpeedMs() > 0, "站停结束无法重新发车")
    end
    Train.Reset(first.s - 55)
    Game.Init()
    Game.UpdateHud(0)
    Hud.HideBanner()
    print("[RailwayValidation] 启动不误到站、前后停车对位、一次奖励、站停保护与重新发车通过")
end

function Start()
    startGame()
    TogglePause()
    scene_ = renderer:GetViewport(0).scene
    checkRoute()
    checkWorld()
    -- 不只验证初始摆位：每25米摆一次全编组，覆盖曲线与闭合端。
    local poses = math.ceil(Route.GetLength() / 25)
    for i = 1, poses do checkTrainPose((i - 1) * Route.GetLength() / poses) end
    Train.Reset(100)
    Train.SetThrottle(8)
    for _ = 1, 100 do Train.Update(0.1) end
    assert(Train.GetSpeedMs() > 0, "牵引未生效")
    Train.EmergencyBrake()
    for _ = 1, 500 do Train.Update(0.1) end
    assert(Train.GetSpeedMs() == 0, "持续制动后没有停稳或出现反向溜车")
    checkGameplay()
    local stations = Route.GetStations()
    cases_ = {
        {name = "station_entry", s = stations[1].s - 55, mode = "chase"},
        {name = "station_exit", s = stations[1].s + 140, mode = "chase"},
        {name = "curve", s = 1100, mode = "side"},
        {name = "old_lowland", s = Route.GetLength() * 0.58, mode = "chase"},
        {name = "cab", s = stations[3].s - 30, mode = "cab"},
        {name = "closure", s = 4, mode = "chase"},
        {name = "coach_detail", s = stations[1].s + 140, mode = "chase"},
        {name = "station_house", s = stations[1].s - 55, mode = "chase"},
    }
    current_ = 1
    Train.Reset(cases_[1].s)
    TrainCamera.SetMode(cases_[1].mode)
    Hud.SetStationName(stations[1].name)
    Hud.SetNextStation("55 m")
    Hud.SetSpeed(0, 80)
    Hud.SetThrottle(0, 8)
    Hud.SetBrake(0)
    local readings = Hud.GetReadings()
    assert(readings.speedLimitKmh == 80 and readings.instrumentLimitKmh == 80, "仪表实际限速没有显示80")
    local uiRoot = assert(Hud.GetRoot(), "驾驶仪表树不存在")
    assert(uiRoot:FindById("speedInstrument"), "圆形速度仪表未创建")
    assert(uiRoot:FindById("throttleHandle") and uiRoot:FindById("brakeHandle"), "油门/制动手柄未创建")
    SubscribeToEvent("Update", "HandleRailwayValidationUpdate")
    SubscribeToEvent("EndRendering", "HandleRailwayValidationCapture")
    print(string.format("[RailwayValidation] 全线路%d个编组摆位、线路不自交、5站净空、轨距/轨面、牵引/制动全部通过", poses))
end

---@param eventType string
---@param eventData UpdateEventData
function HandleRailwayValidationUpdate(eventType, eventData)
    -- 全局同事件订阅会替换主入口的处理器；显式链入真实游戏更新，不能只测试UI。
    HandleUpdate(eventType, eventData)
    frame_ = frame_ + 1
    if frame_ >= 16 and frame_ <= 28 then
        local root = assert(Hud.GetRoot())
        local brake = assert(root:FindById("brakeHandle")) --[[@as CabLever]]
        print(string.format("[InputValidation] 帧%d 压力=%.3f 按住=%s 指针=%s 暂停=%s", frame_,
            Train.GetBrake(), tostring(Hud.GetReadings().brakeHeld), tostring(brake.pointer_),
            tostring(Hud.GetReadings().paused)))
    end
    checkInput(frame_)
    if frame_ == 30 then checkLayout() end
    -- 人工放一个环境遮挡体到视线中途，验证射线保护真的缩距，而非只换站位。
    if frame_ == 35 and scene_ then
        local cameraNode = assert(TrainCamera.GetNode())
        local aim = Train.GetLeadPosition() + Vector3(0, 2.6, 0)
        originalSight_ = (cameraNode.position - aim):Length()
        obstacle_ = MeshUtils.BoxPart(scene_, "ValidationOccluder", (aim + cameraNode.position) * 0.5,
            Vector3(3, 3, 3), Materials.Solid(Color(0.3, 0.3, 0.3), 0, 1))
        local drawable = assert(obstacle_:GetComponent("StaticModel"))
        drawable.viewMask = 2
    elseif frame_ == 40 then
        assert(TrainCamera.GetSightDistance() < originalSight_ * 0.7, "相机没有避让实际环境障碍")
        if obstacle_ then obstacle_:Remove() end
        obstacle_ = nil
        print("[RailwayValidation] 实际环境网格遮挡缩距通过")
    end
    local index = math.min(#cases_, math.max(1, math.floor((frame_ - 120) / 30) + 1))
    if index ~= current_ then
        current_ = index
        local case = cases_[index]
        Train.Reset(case.s)
        TrainCamera.SetMode(case.mode)
        Hud.SetStationName("线路验收")
        Hud.SetNextStation(case.name)
    end
    Hud.Update(1 / 60)
end

---@param eventType string
---@param eventData PostUpdateEventData
function HandlePostUpdate(eventType, eventData)
    postUpdateGame(eventType, eventData)
    local case = cases_[current_]
    if not case then return end
    local cameraNode = assert(TrainCamera.GetNode())
    local camera = assert(TrainCamera.GetCamera())
    -- 仅在验收附加近景中固定镜头，前六个场景继续走真实游戏相机。
    if case.name == "coach_detail" then
        local coach = assert(Train.GetCars()[2])
        cameraNode.position = coach.node:LocalToWorld(Vector3(-19, 6.0, 13))
        cameraNode:LookAt(coach.node:LocalToWorld(Vector3(0, 1.9, 0)))
        camera.fov = 58
    elseif case.name == "station_house" and scene_ then
        local first = assert(Route.GetStations()[1])
        local stationRoot = assert(scene_:GetChild("Stations"))
        local stationNode = assert(stationRoot:GetChild("Station_" .. first.name))
        local house = assert(stationNode:GetChild("StationHouse"))
        cameraNode.position = house:LocalToWorld(Vector3(32, 12, 27))
        cameraNode:LookAt(house:LocalToWorld(Vector3(0, 4.2, 0)))
        camera.fov = 65
    end
end

---@param eventType string
---@param eventData EndRenderingEventData
function HandleRailwayValidationCapture(eventType, eventData)
    if frame_ >= 149 and (frame_ - 149) % 30 == 0 and current_ <= #cases_ then
        local case = cases_[current_]
        local image = Image()
        assert(graphics:TakeScreenShot(image), "实际帧截图失败")
        assert(image:SavePNG("/workspace/screenshots/railway_" .. case.name .. ".png"), "验收截图未落盘")
        print("[RailwayValidation] 已截图：" .. case.name)
    end
end
