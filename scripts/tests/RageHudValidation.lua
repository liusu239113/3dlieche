-- 狂暴HUD定向回归：UI真实控件、触摸道岔、状态切换、重建和无虚假计分。
local UI = require "urhox-libs/UI"
local Hud = require "ui.Hud"
local checks_, frame_, switches_ = 0, 0, 0
local failed_ = false
local function check(value, message)
    checks_ = checks_ + 1
    assert(value, "[RageHudValidation] " .. message)
end
local function guard(action)
    if failed_ then return end
    local ok, err = xpcall(action, debug.traceback)
    if not ok then failed_ = true; log:Write(LOG_ERROR, tostring(err)) end
end
---@param id string
---@return Widget
local function widget(id) return assert(assert(Hud.GetRoot()):FindById(id), "missing " .. id) end
---@param id string
---@return string
local function text(id) return (widget(id) --[[@as Label]]):GetText() end
---@param id string
local function tap(id)
    UI.Layout()
    local item = widget(id)
    local r = item:GetAbsoluteLayoutForHitTest()
    print(string.format("[RageHudValidation] TAP %s rect=%.3f %.3f %.3f %.3f",id,r.x,r.y,r.w,r.h))
    check(r.w >= 43.5 and r.h >= 43.5, "按钮触摸区不足 " .. id) -- DPR像素吸附容差
    check(UI.FindWidgetAt(r.x + r.w * .5, r.y + r.h * .5) == item, "按钮被遮挡 " .. id)
    local scale = UI.GetScale()
    UI.InputAdapter.HandleTouchBegin(984, (r.x+r.w*.5)*scale, (r.y+r.h*.5)*scale, .5)
    UI.InputAdapter.HandleTouchEnd(984, (r.x+r.w*.5)*scale, (r.y+r.h*.5)*scale)
end
local function callbacks()
    return { onSwitch = function(dir) switches_ = switches_ + dir end,
        onService = function() error("狂暴不应触发客运任务") end,
        onDrivingMode = function() error("狂暴不应触发驾驶模式") end }
end
local function railway(locked)
    Hud.SetRailwayStatus({ locked = locked, aspect = "green", text = "前方畅通",
        switchText = "预选主线 · 前方道岔", track = "下行正线", objective = "狂暴试验场" })
end
local function noOverlap(a, b)
    return a.x+a.w <= b.x+.1 or b.x+b.w <= a.x+.1 or a.y+a.h <= b.y+.1 or b.y+b.h <= a.y+.1
end
function Start()
    guard(function()
        Hud.SetGameMode("rage") -- Init之前调用，不依赖UI已初始化。
        Hud.Init(callbacks())
        Hud.SetGameMode("rage")
        Hud.SetSpeed(340, 1e9)
        Hud.SetPassengerStatus({ onboard = 0, capacity = 0, ready = true, doorsOpen = false })
        Hud.SetDepartureStatus({ blocked = true, reason = "boarding", waitSeconds = 9 })
        railway(false)
        SubscribeToEvent("Update", "HandleRageHudValidation")
    end)
end
---@param eventType string
---@param eventData UpdateEventData
function HandleRageHudValidation(eventType, eventData)
    guard(function()
        frame_ = frame_ + 1
        if frame_ == 3 then
            local initial = Hud.GetReadings()
            check(initial.gameMode == "rage" and initial.instrumentUnlimited, "模式/仪表未同步")
            check(initial.instrumentLimitText == "不限速", "仪表显示哨兵999999/1e9")
            check(initial.runningState ~= "超速", "狂暴仍有超速状态")
            check(initial.rageStats.score == 0 and initial.rageStats.impacts == 0, "空场发生假事件")
            check(not widget("passengerStatus"):IsVisible(), "狂暴显示客运条")
            check(not initial.departureBlocked, "狂暴继续等待乘降")
            check((widget("nextService") --[[@as Button]]):IsDisabled(), "狂暴客运任务可用")
            check(text("rageRules"):find("不限速 / 不侧翻",1,true), "玩法规则不清楚")
            check(text("rageEvent"):find("尚未发生",1,true), "无事件显示虚假摘要")
            local root = Hud.GetRoot()
            local sample = { score = 870, impacts = 7, playerImpacts = 2, npcImpacts = 5, chains = 3,
                currentChain = 4, maxChain = 6, diversity = 3, airborne = 2,
                lastEvent = "chain", eventText = "连锁追撞 · 4车节传播" }
            Hud.SetRageStats(sample)
            sample.score = 9999
            for _ = 1,30 do Hud.SetGameMode("rage") end
            check(Hud.GetRoot() == root, "重复同步重建UI")
            check(Hud.GetReadings().rageStats.score == 870, "快照被外部修改/重复同步清零")
            check(text("rageScore"):find("870",1,true) and text("rageScore"):find("当前 4",1,true), "真实分/当前连锁丢失")
            check(text("rageChain"):find("最大连锁 6",1,true) and text("rageChain"):find("事件种类 3",1,true), "最大连锁/多样性丢失")
            check(text("rageEvent"):find("连锁追撞",1,true), "真实事件未投影")
            check(text("rageDetails"):find("二次传播 3",1,true) and text("rageDetails"):find("腾空车节 2",1,true), "传播/当前腾空语义错误")
            tap("switchMainline"); tap("switchSiding")
            check(switches_ == 0, "道岔Q/E未各发送一次真实回调")
            railway(true)
            check((widget("switchMainline") --[[@as Button]]):IsDisabled(), "整列通过时道岔没锁")
            check(text("switchHint"):find("整列通过锁定",1,true), "锁定原因不清楚")
            railway(false)
            local before = switches_; tap("switchSiding")
            check(switches_ == before+1, "解锁后侧线入口不可点")
            UI.Layout()
            local layout = Hud.GetLayout()
            check(noOverlap(layout.switchStrip,layout.controls) and noOverlap(layout.switchStrip,layout.speedometer), "道岔遮挡牵引/制动仪表")
            check(noOverlap(layout.switchStrip,layout.station), "道岔遮挡信息卡")
            Hud.BuildRoot(); UI.Layout()
            check(Hud.GetReadings().instrumentUnlimited and text("rageScore"):find("870",1,true), "设置返回重建丢模式/真实分")
            railway(false); tap("switchMainline")
            Hud.SetGameMode("normal")
            Hud.SetSpeed(120,80)
            check(not Hud.GetReadings().instrumentUnlimited and Hud.GetReadings().instrumentLimitText == "限速 80", "普通限速未恢复")
            check(Hud.GetReadings().runningState == "超速", "普通超速警告改变")
            check(assert(Hud.GetRoot()):FindById("rageRules") == nil, "普通残留狂暴文案")
            Hud.SetPassengerStatus({ onboard = 20, capacity = 100, ready = true, doorsOpen = false })
            check(widget("passengerStatus"):IsVisible(), "普通乘降条无法恢复")
            Hud.SetGameMode("rage"); Hud.SetSpeed(340,80); railway(false)
            check(Hud.GetReadings().rageStats.score == 0 and Hud.GetReadings().rageStats.impacts == 0, "真实换模式没清统计")
            check(Hud.GetReadings().runningState ~= "超速", "狂暴用旧普通限速警告")
            Hud.SetRageStats({score=222,impacts=2,currentChain=2,maxChain=2,diversity=1,eventText="迎面相撞 · 2车节"})
            Hud.SetOperationsExpanded(true)
            UI.Layout()
            tap("switchSiding") -- 运营展开也不能盖住常驻道岔。
        elseif frame_ == 15 then
            print(string.format("ALL_RAGE_HUD_VALIDATION_PASS checks=%d viewport=%dx%d rendered=%d",
                checks_,graphics:GetWidth(),graphics:GetHeight(),Hud.GetRenderedFrames()))
        end
    end)
end
function Stop() Hud.Shutdown() end
