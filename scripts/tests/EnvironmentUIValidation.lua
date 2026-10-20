-- 纯 UI 回归：沿用项目真实触摸验收范式，不创建列车/世界、不修改环境真源。
local UI = require "urhox-libs/UI"
local Hud = require "ui.Hud"
local Menu = require "ui.Menu"
local environment_ = { hour = 12.5, running = true, weather = "clear" }
local requests_, checks_, frame_ = 0, 0, 0
local failed_ = false
local cancelled_ = 0
local completed_ = false
local function capture(stage)
    local image = Image()
    assert(graphics:TakeScreenShot(image),"UI截图读取失败")
    assert(image:SavePNG(string.format("/workspace/screenshots/environment_fog_ui_%dx%d_%s.png",
        graphics:GetWidth(),graphics:GetHeight(),stage)),"UI截图保存失败")
    image:Dispose()
end
local function check(value, message)
    checks_ = checks_ + 1
    assert(value, "[EnvironmentUIValidation] " .. message)
end
local function guard(action)
    if failed_ then return end
    local ok, message = xpcall(action, debug.traceback)
    if not ok then failed_ = true; log:Write(LOG_ERROR, tostring(message)) end
end
---@param root Panel
---@param id string
local function tap(root,id)
    UI.Layout()
    local target = assert(root:FindById(id), "missing " .. id)
    local rect = target:GetAbsoluteLayoutForHitTest()
    check(rect.w >= 44 and rect.h >= 44, "触摸区域小于44px " .. id)
    local x,y = (rect.x+rect.w*.5)*UI.GetScale(), (rect.y+rect.h*.5)*UI.GetScale()
    UI.InputAdapter.HandleTouchBegin(993,x,y,.5)
    UI.InputAdapter.HandleTouchEnd(993,x,y)
end
function Start()
    guard(function()
        Menu.Init({ onEnvironmentChanged = function(patch)
            requests_ = requests_ + 1
            for key,value in pairs(patch) do environment_[key] = value end
        end }, { sensitivity = .2, quality = "balanced", volume = .75 }, {
            getEnvironmentState = function() return environment_ end,
        })
        Menu.Settings()
        UI.Layout()
        SubscribeToEvent("Update","HandleUpdate")
        SubscribeToEvent("EndRendering","CaptureEnvironmentUI")
    end)
end
---@param eventType string
---@param eventData UpdateEventData
function HandleUpdate(eventType,eventData)
    guard(function()
        frame_ = frame_ + 1
        if frame_ == 3 then
            local root = assert(Menu.GetRoot())
            -- 先验证程序性同步不产生环境写回。
            check(requests_ == 0, "初始化触发环境写回")
            local panel = assert(root:FindById("environmentSettings")) --[[@as RailwayEnvironmentSettings]]
            local hour = assert(root:FindById("environmentHour")) --[[@as Label]]
            check(hour:GetText():find("12:30",1,true), "世界小时小数未投影为分钟")
            -- 环境区在长设置表单内；真实滚动定位后再经 InputAdapter 触摸。
            local scroll = assert(root:FindById("menuScroll")) --[[@as ScrollView]]
            local function reveal(id)
                UI.Layout()
                local item = assert(root:FindById(id))
                local r, viewport = item:GetAbsoluteLayoutForHitTest(),scroll:GetAbsoluteLayoutForHitTest()
                local _,y = scroll:GetScroll()
                scroll:SetScroll(0, math.max(0,y+r.y-viewport.y-10))
                UI.Layout()
            end
            reveal("settingsTimeNight"); tap(root,"settingsTimeNight")
            check(environment_.hour == 22 and requests_ == 1, "夜间预设未通过回调")
            reveal("settingsTimeRunning"); tap(root,"settingsTimeRunning")
            check(not environment_.running and requests_ == 2, "时间开关未通过回调")
            reveal("settingsWeather_rain"); tap(root,"settingsWeather_rain")
            check(environment_.weather == "rain" and requests_ == 3, "雨天选择未通过回调")
            local weatherBounds = assert(root:FindById("environmentWeatherOptions")):GetAbsoluteLayoutForHitTest()
            local previousRight = weatherBounds.x
            for _, id in ipairs({"clear","cloudy","rain","fog"}) do
                local b = assert(root:FindById("settingsWeather_" .. id)) --[[@as Button]]
                local rect = b:GetAbsoluteLayoutForHitTest()
                check(rect.w >= 44 and rect.h >= 44, "四天气按钮小于44px " .. id)
                check(rect.x >= previousRight-.1 and rect.x+rect.w <= weatherBounds.x+weatherBounds.w+.1,
                    "四天气按钮横向溢出/重叠 " .. id)
                local metrics = UI.MeasureTextFit(b.props.text,{fontSize=UI.Theme.FontSize(b.props.fontSize or 10.5),
                    fontFace=UI.Theme.FontFace("sans","bold"),width=rect.w-10,minFontSize=UI.Theme.FontSize(10.5)})
                check(metrics.width <= rect.w-8, "天气按钮文字溢出 " .. id)
                previousRight = rect.x+rect.w
            end
            reveal("settingsWeather_fog"); tap(root,"settingsWeather_fog")
            check(environment_.weather == "fog" and requests_ == 4, "雾天选择未通过真实触摸回调")
            environment_.hour, environment_.weather = 6.25,"cloudy"
            panel:Sync()
            check(hour:GetText():find("06:15",1,true), "外部状态改变未回读")
            check(requests_ == 4, "状态回读错误触发写回")
            -- 回调拒绝时 UI 必须恢复真源，不能留下乐观时间。
            Menu.Init({ onEnvironmentChanged = function() end }, { sensitivity = .2 }, {
                getEnvironmentState = function() return environment_ end })
            Menu.Settings()
            local deniedRoot = assert(Menu.GetRoot())
            local denied = assert(deniedRoot:FindById("environmentSettings")) --[[@as RailwayEnvironmentSettings]]
            denied:Request({ hour = 18, weather = "rain" })
            local deniedHour = assert(deniedRoot:FindById("environmentHour")) --[[@as Label]]
            check(deniedHour:GetText():find("06:15",1,true) and environment_.weather == "cloudy",
                "拒绝请求后UI保存了自己的真源")
            Hud.Init({})
            Hud.SetEnvironment({ hour = 23.999, weather = "rain", running = false })
            Hud.SetTime(125)
            Hud.SetDepartureStatus({ blocked = true, reason = "signal", message = "前方区间占用", waitSeconds = 8 })
            Hud.SetVersion("功能版 2026.10 · 环境与反馈")
            Hud.SetAnnouncement("即将到达星汐站，请准备下车。",false,"approach-1")
            local feedback = require "ui.HudFeedback"
            feedback.Update(7)
            Hud.SetAnnouncement("即将到达星汐站，请准备下车。",false,"approach-1")
            feedback.Update(1)
            check(not Hud.GetReadings().announcementVisible,"同一字幕轮询错误延长显示")
            Hud.SetAnnouncement("即将到达星汐站，请准备下车。",false,"approach-2")
            check(Hud.GetReadings().announcementVisible,"新事件key不能刷新同文字幕")
            Hud.SetTrainLoading(true,.4,"下载列车资源",function() cancelled_ = cancelled_ + 1 end)
            UI.Layout()
            local hudRoot = assert(Hud.GetRoot())
            local world = assert(hudRoot:FindById("worldEnvironment")) --[[@as Label]]
            local station = assert(hudRoot:FindById("departureStatus")) --[[@as Label]]
            local elapsed = assert(hudRoot:FindById("journeyElapsed")) --[[@as Label]]
            check(world:GetText():find("23:59",1,true) and world:GetText():find("雨天",1,true), "HUD时刻天气错误")
            check(station:GetText():find("00:08",1,true), "站停等待未显示本站秒数")
            check(not station:GetText():find("02:05",1,true) and elapsed:GetText() == "旅程 02:05", "本站等待混用旅程累计")
            tap(hudRoot,"cancelTrainLoading")
            check(cancelled_ == 1, "下载取消按钮无回调")
            Hud.SetTrainLoading(false,1,"完成")
            Hud.SetDepartureStatus({ blocked = false, reason = "ready", waitSeconds = 0 })
            check(not assert(hudRoot:FindById("trainLoading")):IsVisible(), "完成后未隐藏下载条")
            check(not station:IsVisible(), "发车后未清除本站等待")
            Hud.SetDepartureStatus({ blocked = true, reason = "boarding", waitSeconds = 2 })
            check(station:GetText():find("00:02",1,true), "新站继续旧站等待")
            local count = hudRoot:GetNumChildren()
            for _ = 1,60 do
                Hud.SetEnvironment({ hour = 8, weather = "clear", running = true })
                Hud.SetDepartureStatus({ blocked = true, reason = "boarding", waitSeconds = 2 })
            end
            check(Hud.GetRoot() == hudRoot and hudRoot:GetNumChildren() == count, "状态更新重建HUD树")
            local readings = Hud.GetReadings()
            check(readings.departureWaitSeconds == 2 and not readings.trainLoading, "反馈诊断不匹配")
            Hud.SetEnvironment({ hour = 22, weather = "fog", running = false })
            check(Hud.GetReadings().environmentText:find("雾天",1,true),"HUD缺少雾天天气映射")
            Hud.SetTrainLoading(true,.62,"正在下载列车模型",function() cancelled_=cancelled_+1 end)
            Hud.SetRouteExpanded(true)
            UI.Layout()
            check(assert(hudRoot:FindById("featureVersion")):IsVisible(), "版本信息未挂载")
            check(Hud.GetRenderedFrames() == 0, "测试前HUD渲染计数状态异常")
        elseif frame_ == 20 then
            check(Hud.GetRenderedFrames() > 0,"HUD没有收到真实渲染")
            Hud.SetTrainLoading(false,1,"完成")
            local welcome = assert(require("config.AnnouncementCatalog").Get("welcome")).text
            Hud.SetAnnouncement(welcome,false,"capture-final")
            Hud.SetDepartureStatus({blocked=true,reason="signal",message="前方区间占用",waitSeconds=8})
            Hud.SetPassengerStatus({onboard=120,capacity=608,ready=false,doorsOpen=true})
            Hud.SetRouteExpanded(false)
            UI.Layout()
            local root = assert(Hud.GetRoot())
            local route,controls = assert(root:FindById("routeInfo")):GetAbsoluteLayout(),Hud.GetLayout().controls
            check(route.x+route.w <= controls.x or route.y+route.h <= controls.y,
                "新增反馈覆盖牵引/制动")
            check(UI.FindWidgetAt(UI.GetViewportSize()*.5,250) == nil,"HUD反馈遮挡世界空白交互")
            local caption = assert(root:FindById("announcementCaption")) --[[@as Label]]
            local shown = caption:GetText()
            local first,second = shown:match("^([^\n]+)\n([^\n]+)$")
            check(first and second and second:sub(-3) == "…","长欢迎字幕不是两行省略摘要")
            check(Hud.GetReadings().announcementText == welcome,"摘要错误覆盖完整广播真源")
            local metrics = UI.MeasureTextFit(shown,{fontSize=UI.Theme.FontSize(9),
                fontFace=UI.Theme.FontFace("sans","normal"),width=caption:GetAbsoluteLayout().w,
                lineHeight=1.25,multiline=true,minFontSize=UI.Theme.FontSize(9)})
            print(string.format("[EnvironmentUIValidation] caption box=%.1fx%.1f measured=%.1fx%.1f text=%s",
                caption:GetAbsoluteLayout().w,caption:GetAbsoluteLayout().h,metrics.width,metrics.height,shown))
            check(metrics.height <= caption:GetAbsoluteLayout().h-6,"两行欢迎字幕超出内容高度，可能出现半行")
            completed_ = true
            print(string.format("ALL_ENVIRONMENT_UI_VALIDATION_PASS checks=%d requests=%d",checks_,requests_))
        elseif frame_ == 100 then
            check(completed_,"UI验收未到达完成状态")
        end
    end)
end
function CaptureEnvironmentUI()
    guard(function()
        if frame_ == 2 then
            local root = assert(Menu.GetRoot())
            local scroll = assert(root:FindById("menuScroll")) --[[@as ScrollView]]
            local item = assert(root:FindById("environmentSettings"))
            local r, viewport = item:GetAbsoluteLayoutForHitTest(),scroll:GetAbsoluteLayoutForHitTest()
            local _,y = scroll:GetScroll()
            scroll:SetScroll(0, math.max(0,y+r.y-viewport.y-10))
            UI.Layout()
            capture("settings")
        end
        if frame_ == 12 then capture("loading") end
        if frame_ == 30 then capture("hud") end
    end)
end
function Stop() Hud.Shutdown() end
