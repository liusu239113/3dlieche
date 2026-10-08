-- 真实主入口运行验收：启动、按需车型、持续驾驶、流式过块与高铁仪表。
-- 在独立Runtime运行；不把离屏结果当作用户浏览器预览通过。
require "main"
local startGame = Start
local Route = require "world.Route"
local Train = require "train.Train"
local Game = require "game.Game"
local Hud = require "ui.Hud"
local Stream = require "world.WorldStream"
local Camera = require "train.Camera"
local UI = require "urhox-libs/UI"

local frame_ = 0
local initialS_ = 0.0
local initialElapsed_ = 0.0
local maxChunks_ = 0

---@param id string
local function tap(id)
    UI.Layout()
    local widget = assert(assert(Hud.GetRoot()):FindById(id), "缺少实际按钮 " .. id)
    local rect = widget:GetAbsoluteLayoutForHitTest()
    assert(rect.w > 0 and rect.h > 0)
    local x = (rect.x + rect.w * .5) * UI.GetScale()
    local y = (rect.y + rect.h * .5) * UI.GetScale()
    UI.InputAdapter.HandleTouchBegin(991, x, y, .5)
    UI.InputAdapter.HandleTouchEnd(991, x, y)
end

function Start()
    local started = os.clock()
    startGame()
    local elapsed = os.clock() - started
    print(string.format("[DrivingValidation] 主入口CPU启动 %.3fs", elapsed))
    assert(elapsed < 10, "主入口同步CPU启动仍超过10秒")
    assert(Route.GetLength() > 90000, "仍是旧小环线")
    assert(Route.GetValidationData().minRadius >= 9000, "未使用大半径曲线")
    assert(Train.GetSelectedId() == "CR400AF", "默认不是复兴号")
    assert(Game.GetSpeedLimit() == 350, "区间仍不是复兴号350")
    assert(Hud.GetReadings().instrumentMaxKmh >= 350, "速度表仍是旧120量程")
    -- 使用真实缓解和W档按钮；不直接调回调代替触控。
    -- 真实按钮缓解，然后连续点击八次牵引+键；下一帧读回权威档位。
    tap("releaseBrake")
    assert(Train.GetBrake() == 0, "实际缓解按钮无效")
    for _ = 1, 8 do tap("throttleUp") end
    assert(Train.GetThrottle() == 8, "实际牵引按钮没有到8档")
    initialS_, initialElapsed_ = Train.GetS(), Game.GetElapsed()
    local stats = Stream.GetStats()
    assert(stats.nearRailChunks > 0 and stats.loadedChunks < 1000,
        "出生点轨道未准备或错误全线生成")
    SubscribeToEvent("PostUpdate", "HandleDrivingValidation")
    SubscribeToEvent("EndRendering", "CaptureDrivingValidation")
end

---@param eventType string
---@param eventData PostUpdateEventData
function HandleDrivingValidation(eventType, eventData)
    -- 测试入口不会自动回调 main 的 PostUpdate，显式驱动相机与流式，避免空跑。
    HandlePostUpdate("PostUpdate", eventData)
    frame_ = frame_ + 1
    local stats = Stream.GetStats()
    maxChunks_ = math.max(maxChunks_, stats.loadedChunks)
    assert(stats.loadedChunks < 1000, "流式节点无限积累")
    if frame_ == 130 then
        assert(Train.GetSpeedKmh() > 0 and Train.GetS() ~= initialS_, "持续更新没有行驶")
        assert(Game.GetElapsed() > initialElapsed_, "游戏计时没有前进")
        print(string.format("[DrivingValidation] 持续驾驶PASS: 速度%.2f, 位移%.2fm, 块%d",
            Train.GetSpeedKmh(), Route.ForwardDistance(initialS_, Train.GetS()), stats.loadedChunks))
        Train.SetThrottle(0)
        Train.EmergencyBrake()
        Train.Reset(Route.GetStations()[1].s + 600)
        Stream.Reset(Train.GetS())
        Game.Init()
        Game.UpdateHud(0)
        tap("openTrainSelector")
        local selector = assert(Hud.GetTrainSelector())
        while selector:GetPage() < selector:GetPageCount() do tap("nextTrainPage") end
        tap("selectTrain_CRH380A")
        tap("confirmTrain")
        assert(Train.GetSelectedId() == "CRH380A", "真实分页确认没有切换和谐号")
        assert(not Hud.IsTrainSelectorOpen(), "确认后菜单没关")
        assert(Game.GetSpeedLimit() == 300, "换和谐号仍没有300区间许可")
        assert(Hud.GetReadings().instrumentMaxKmh >= 380, "和谐号量程不正确")
        print("[DrivingValidation] 和谐号触摸换车与300限速PASS")
    elseif frame_ == 160 then
        Train.Reset(Route.GetLength() - 50)
        Stream.Reset(Train.GetS())
        Game.Init()
        Train.SetBrake(0)
        Train.SetThrottle(8)
        Camera.SetMode("cab")
    elseif frame_ == 210 then
        assert(Stream.GetStats().nearRailChunks > 0, "闭合接缝没有近景轨道")
        print(string.format("[DrivingValidation] 闭合接缝/流式PASS: 常驻峰值%d, 切片峰值%.3fms",
            maxChunks_, Stream.GetStats().maxTaskMs))
        Train.Reset(Route.GetStations()[1].s + 600)
        Stream.Reset(Train.GetS())
        Game.Init()
        assert(SelectTrain("CR400AF"))
        Train.SetBrake(0)
        Train.SetThrottle(8)
        -- CPU按真实动力积分600秒，不直接写速度；跳过站停用于能力验收。
        for _ = 1, 6000 do Train.Update(.1) end
        assert(Train.GetSpeedKmh() >= 349, "复兴号实际动力积分达不到350")
        Train.UpdateVisuals(0)
        Stream.Reset(Train.GetS())
        Game.Init()
        Game.UpdateHud(0)
        Camera.SetMode("chase")
        print(string.format("[DrivingValidation] 复兴号真实动力积分PASS: %.3fkm/h", Train.GetSpeedKmh()))
    elseif frame_ == 270 then
        assert(Stream.GetStats().loadedChunks < 1000)
        print("[DrivingValidation] ALL_CHECKS_PASS")
    end
end

---@param eventType string
---@param eventData EndRenderingEventData
function CaptureDrivingValidation(eventType, eventData)
    if frame_ ~= 125 and frame_ ~= 150 and frame_ ~= 205 and frame_ ~= 265 then return end
    local image = Image()
    assert(graphics:TakeScreenShot(image))
    assert(image:SavePNG("/workspace/screenshots/driving_" .. frame_ .. ".png"))
    image:Dispose()
end
