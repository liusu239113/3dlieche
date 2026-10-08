-- 主入口集成验收：菜单暂停、停车换车、游戏进度、声源及UI真实回调。
require "main"
local startGame = Start
local Route = require "world.Route"
local Train = require "train.Train"
local Hud = require "ui.Hud"
local Station = require "world.Station"
local TrainCamera = require "train.Camera"
local Game = require "game.Game"
local Audio = require "audio.AudioManager"
local UI = require "urhox-libs/UI"

local frame_ = 0

-- 使用真实触摸命中与浮层分发，不直接调用按钮回调代替交互。
---@param id string
local function tapButton(id)
    UI.Layout()
    local widget = assert(assert(Hud.GetRoot()):FindById(id), "找不到按钮：" .. id)
    local rect = widget:GetAbsoluteLayoutForHitTest()
    assert(rect.w > 0 and rect.h > 0, "按钮没有实际布局：" .. id)
    local x, y = (rect.x + rect.w * 0.5) * UI.GetScale(),
        (rect.y + rect.h * 0.5) * UI.GetScale()
    UI.InputAdapter.HandleTouchBegin(990, x, y, 0.5)
    UI.InputAdapter.HandleTouchEnd(990, x, y)
end

local function step()
    local data = VariantMap()
    data["TimeStep"] = Variant(0.1)
    HandleUpdate("Update", data --[[@as UpdateEventData]])
end

function Start()
    startGame()
    local root = assert(Hud.GetRoot())
    local selector = assert(root:FindById("trainSelector")) --[[@as CabTrainSelector]]
    assert(selector == Hud.GetTrainSelector(), "选择器实例未正确挂载")
    assert(#Train.GetCatalog() == 6, "车型目录不是6项")
    local dimensions = Station.GetDimensions()
    assert(dimensions.maxTrainWidth >= 3.38 and dimensions.sideGap >= .20,
        "站台没有为最大宽度动车保留净空")
    assert(Hud.GetReadings().selectedTrainId == Train.GetSelectedId(), "初始显示车型不一致")
    Train.Reset(Route.GetStations()[1].s - 120)

    local elapsed, s = Game.GetElapsed(), Train.GetS()
    tapButton("openTrainSelector")
    assert(Hud.IsTrainSelectorOpen(), "真实车型按钮未打开选择器")
    assert(Hud.GetReadings().paused, "打开选择器没有暂停")
    step()
    assert(Game.GetElapsed() == elapsed and Train.GetS() == s, "选择器打开后仍推进游戏")
    tapButton("closeTrainSelector")
    assert(not Hud.IsTrainSelectorOpen(), "真实关闭按钮未关闭选择器")
    assert(not Hud.GetReadings().paused, "关闭菜单没有恢复原非暂停状态")
    TogglePause()
    tapButton("openTrainSelector")
    tapButton("cancelTrainSelection")
    assert(Hud.GetReadings().paused, "关闭菜单错误清除了用户暂停")

    local xp, nextStation = Game.GetXp(), Game.GetNextStation().index
    local oldSource = assert(Audio.GetTractionSource())
    assert(audio:GetListener().node == TrainCamera.GetNode(), "3D音效没有绑定当前相机听者")
    local scene = renderer:GetViewport(0).scene
    local oldRoot = assert(scene:GetChild("Train"))
    local chosen = ""
    for _, entry in ipairs(Train.GetCatalog()) do
        if entry.ready and entry.id ~= Train.GetSelectedId() then chosen = entry.id; break end
    end
    assert(chosen ~= "", "没有第二种就绪车型")
    tapButton("openTrainSelector")
    tapButton("selectTrain_" .. chosen)
    assert(selector.pendingId_ == chosen, "真实选择按钮未记录待确认车型")
    tapButton("confirmTrain")
    assert(Train.GetSelectedId() == chosen and not Hud.IsTrainSelectorOpen(), "真实确认回调未成功换车")
    assert(Hud.GetReadings().paused, "换车后错误解除原用户暂停")
    assert(Train.GetS() == s and Game.GetXp() == xp and Game.GetNextStation().index == nextStation,
        "换车改变线路位置/经验/站序")
    assert(Train.GetThrottle() == 0 and Train.GetBrake() == 1, "换车没有收油并制动")
    assert(scene:GetChild("Train") == oldRoot and Audio.GetTractionSource() == oldSource,
        "换车销毁了稳定根或音频声源")
    assert(Audio.GetPowerType() == (Train.GetPowerType() == "diesel" and "diesel" or "electric"),
        "换车没有切换动力音效")
    local lead = assert(Train.GetLeadNode())
    Audio.SetTrainPose(lead.worldPosition, lead.worldRotation)
    assert((oldSource.node.worldPosition - lead.worldPosition):Length() < 4, "声音没有跟随头车")

    local ok = SelectTrain("unknown_train")
    assert(not ok and Train.GetSelectedId() == chosen, "未知车型改变了当前编组")
    Train.SetBrake(0)
    Train.SetThrottle(8)
    Train.Update(1)
    assert(math.abs(Train.GetSpeedKmh()) > 0.1, "无法构造行驶换车拒绝测试")
    local active, movingS = Train.GetSelectedId(), Train.GetS()
    local rejected = SelectTrain("CR400AF")
    assert(not rejected and Train.GetSelectedId() == active and Train.GetS() == movingS,
        "行驶时允许换车或破坏原车")
    Train.Reset(s)
    assert(SelectTrain("CR400AF"), "默认复兴号未能选择")
    assert(Train.GetCarCount() == 8, "复兴号不是8节编组")
    Game.UpdateHud(0)
    Hud.SetTrainSelectorOpen(false)
    Train.Reset(Route.GetStations()[1].s - 35)
    TrainCamera.AddYaw(160) -- 朝站房与种植区一侧，仍由第三人称库和净空射线驱动。
    print("[MainIntegration] 菜单暂停恢复、停车确认、拒绝行驶换车、进度/音频根保留全部通过")
    SubscribeToEvent("Update", "HandleIntegrationUpdate")
    SubscribeToEvent("EndRendering", "HandleIntegrationCapture")
end

---@param eventType string
---@param eventData UpdateEventData
function HandleIntegrationUpdate(eventType, eventData)
    -- main 已订阅Update，验收不能再调用一次而使列车/计时双倍推进。
    -- 测试入口不会自动回调 main 的 PostUpdate，显式驱动相机与流式。
    HandlePostUpdate("PostUpdate", eventData --[[@as PostUpdateEventData]])
    frame_ = frame_ + 1
    if frame_ == 124 then tapButton("openTrainSelector") end
    if frame_ == 127 then
        local selector = assert(Hud.GetTrainSelector())
        for _ = 2, selector:GetPageCount() do
            local before = selector:GetPage()
            tapButton("nextTrainPage")
            assert(selector:GetPage() == before + 1, "下一页按钮没有推进车型页码")
        end
        assert(selector:GetPageCount() >= 3, "车型分页数量不正确")
        tapButton("selectTrain_CRH380A")
        assert(selector.pendingId_ == "CRH380A", "翻页后和谐号选择按钮未命中")
        tapButton("confirmTrain")
        assert(Train.GetSelectedId() == "CRH380A", "和谐号真实确认未切换编组")
        assert(Hud.GetReadings().paused, "翻页选车型解除用户暂停")
        tapButton("openTrainSelector")
        for _ = 2, selector:GetPageCount() do
            local before = selector:GetPage()
            tapButton("nextTrainPage")
            assert(selector:GetPage() == before + 1, "下一页按钮没有推进车型页码")
        end
        print("[MainIntegration] 逐页触摸并选择和谐号通过")
    end
    if frame_ == 130 then
        local vw, vh = UI.GetViewportSize()
        local layout = Hud.GetLayout().trainSelector
        assert(layout.x >= 0 and layout.y >= 0 and layout.w > 200 and layout.h > 180
            and layout.x + layout.w <= vw + 1 and layout.y + layout.h <= vh + 1,
            "车型抽屉超出实际屏幕")
        local readings = Hud.GetReadings()
        local limit = Game.GetSpeedLimit()
        assert(readings.speedLimitKmh == limit and readings.instrumentLimitKmh == limit,
            "速度策略没有同步到实际仪表")
        assert(readings.instrumentMaxKmh >= Train.GetMaxSpeedKmh(), "动车速度表量程仍停留在旧值")
        print("[MainIntegration] 实际屏幕抽屉布局与限速显示通过")
    elseif frame_ == 136 then
        Hud.SetTrainSelectorOpen(false)
    elseif frame_ == 142 then
        Train.Reset(1100)
        TrainCamera.SetMode("side")
        Game.UpdateHud(0)
    elseif frame_ == 169 then
        TrainCamera.SetMode("cab")
    end
end

---@param eventType string
---@param eventData EndRenderingEventData
function HandleIntegrationCapture(eventType, eventData)
    if frame_ == 121 or frame_ == 132 or frame_ == 140 or frame_ == 165 or frame_ == 180 then
        local image = Image()
        assert(graphics:TakeScreenShot(image), "实际帧截图失败")
        local names = {
            [121] = "modern_station", [132] = "train_selector", [140] = "modern_harmony_station",
            [165] = "modern_curve", [180] = "modern_cab",
        }
        local name = assert(names[frame_])
        assert(image:SavePNG("/workspace/screenshots/" .. name .. ".png"), "验收截图未写入")
        image:Dispose()
        print("[MainIntegration] 真实截图: " .. name)
    end
end
