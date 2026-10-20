-- 音量弹窗回归：真实 Yoga/overlay hit test + InputAdapter 触摸，不接业务音频/存档/云。
-- 运行尺寸覆盖 480x320 / 844x390；后者附加安全区。截图帧 120 保持在滚动底部。
local UI = require "urhox-libs/UI"
local Hud = require "ui.Hud"
local ViewDrag = require "train.ViewDrag"
local checks_, frame_, failed_ = 0, 0, false
local volumeCalls_, soundCalls_, driveCalls_ = 0, 0, 0
local touchId_ = 751
local values_ = { sound = true, volume = .75, trainVolume = 1, announcementVolume = .85, musicVolume = .35 }
local originalSafe_ = UI.GetSafeAreaInsets
UI.GetSafeAreaInsets = function()
    if graphics:GetWidth() >= 600 then return { left = 24, right = 30, top = 20, bottom = 16 } end
    return originalSafe_()
end
local function check(value, message)
    checks_ = checks_ + 1
    assert(value, "[VolumePanelValidation] " .. message)
end
local function guard(action)
    if failed_ then return end
    local ok, err = xpcall(action, debug.traceback)
    if not ok then failed_ = true; log:Write(LOG_ERROR, tostring(err)) end
end
---@param id string
---@return Widget
local function item(id) return assert(assert(Hud.GetRoot()):FindById(id), id) end
---@return CabVolumePanel
local function panel() return item("volumePanel") --[[@as CabVolumePanel]] end
---@return ScrollView
local function scroll() return item("volumeScroll") --[[@as ScrollView]] end
local function layout()
    UI.Layout()
    scroll():UpdateContentSize()
end
local function tapAt(x, y)
    touchId_ = touchId_ + 1
    local scale = UI.GetScale()
    UI.InputAdapter.HandleTouchBegin(touchId_, x * scale, y * scale, .5)
    UI.InputAdapter.HandleTouchEnd(touchId_, x * scale, y * scale)
end
local function tap(id)
    UI.Layout()
    local widget = item(id)
    local r = widget:GetAbsoluteLayoutForHitTest()
    check(UI.FindWidgetAt(r.x+r.w*.5,r.y+r.h*.5)==widget,"tap hit "..id)
    tapAt(r.x+r.w*.5,r.y+r.h*.5)
end
local function begin(x,y)
    touchId_ = touchId_ + 1
    UI.InputAdapter.HandleTouchBegin(touchId_, x*UI.GetScale(), y*UI.GetScale(), .5)
end
local function move(x,y)
    UI.InputAdapter.HandleTouchMove(touchId_, x*UI.GetScale(), y*UI.GetScale(), .5)
end
local function finish(x,y)
    UI.InputAdapter.HandleTouchEnd(touchId_, x*UI.GetScale(), y*UI.GetScale())
end
local function drag(x,y,dx,dy)
    begin(x,y)
    for i=1,8 do move(x+dx*i/8,y+dy*i/8) end
    finish(x+dx,y+dy)
end
local function settle()
    local view=scroll()
    view.state.velocityX,view.state.velocityY=0,0
    layout()
end
local function scrollValue() local _,y=scroll():GetScroll();return y end
local function maxScroll()
    local _,height=scroll():GetContentSize()
    return math.max(0,height-scroll():GetLayout().h)
end
local function noOverlap(a,b)
    return a.x+a.w<=b.x+.2 or b.x+b.w<=a.x+.2 or a.y+a.h<=b.y+.2 or b.y+b.h<=a.y+.2
end
local function sync() Hud.SyncVolumeSettings(values_) end
local function callback(key)
    return function(value)
        volumeCalls_=volumeCalls_+1;values_[key]=value;sync()
    end
end
function Start()
    guard(function()
        Hud.SetGameMode("rage")
        Hud.Init({ onSoundVolume=callback("volume"),onTrainVolume=callback("trainVolume"),
            onAnnouncementVolume=callback("announcementVolume"),onMusicVolume=callback("musicVolume"),
            onSoundToggle=function(enabled) soundCalls_=soundCalls_+1;values_.sound=enabled;sync() end,
            onSwitch=function() driveCalls_=driveCalls_+1 end,
            onHorn=function() driveCalls_=driveCalls_+1 end })
        ViewDrag.Init(function() return not Hud.IsVolumePanelOpen() end)
        sync()
        SubscribeToEvent("Update","HandleVolumePanelValidation")
    end)
end
local function validate()
    values_={sound=true,volume=.75,trainVolume=1,announcementVolume=.85,musicVolume=.35};sync()
    tap("openVolumePanel");layout()
    check(Hud.IsVolumePanelOpen() and UI.GetTopOverlay()==panel(),"open overlay")
    local r=panel():GetAbsoluteLayoutForHitTest()
    local safe=UI.GetSafeAreaInsets();local w,h=UI.GetViewportSize()
    check(r.x>=safe.left-.2 and r.y>=safe.top-.2 and r.x+r.w<=w-safe.right+.2
        and r.y+r.h<=h-safe.bottom+.2,"safe bounds")
    print(string.format("[VolumePanelValidation] panel=%.3f %.3f %.3f %.3f viewport=%.3f maxScroll=%.3f scale=%.3f",
        r.x,r.y,r.w,r.h,scroll():GetLayout().h,maxScroll(),UI.GetScale()))
    check(r.h<=301.5 and scroll():GetLayout().h>50,"constrained positive viewport")
    check(maxScroll()>50,"content not scrollable")
    local fixedClose=item("closeVolumePanel"):GetAbsoluteLayoutForHitTest()
    check(fixedClose.h>=44-1/UI.GetScale(),"fixed close touch height")
    local music=item("volumeSlider_musicVolume") --[[@as Slider]]
    local last=music:GetAbsoluteLayoutForHitTest()
    check(UI.FindWidgetAt(last.x+last.w*.5,last.y+last.h*.5)~=music,"clipped child hit leaked")
    local view=scroll():GetAbsoluteLayoutForHitTest()
    -- 从总声音按钮按下纵拖，不能误静音；手指滑出 viewport 仍继续滚动。
    local sound=item("volumePanelSound"):GetAbsoluteLayoutForHitTest()
    local soundBefore,volumeBefore=soundCalls_,volumeCalls_
    drag(sound.x+sound.w*.45,sound.y+sound.h*.5,1,-90);settle()
    check(scrollValue()>70,"vertical swipe on sound button did not scroll")
    check(soundCalls_==soundBefore and volumeCalls_==volumeBefore,"scroll toggled sound/changed value")
    check(Hud.IsVolumePanelOpen(),"scroll closed overlay")
    -- 再用内容区域纵拖到底，而不是用 ScrollToBottom。
    for _=1,6 do
        drag(view.x+view.w*.45,view.y+view.h*.8,2,-view.h*.7);settle()
    end
    check(math.abs(scrollValue()-maxScroll())<1,"finger could not reach bottom")
    last=music:GetAbsoluteLayoutForHitTest()
    check(last.y>=view.y-.2 and last.y+last.h<=view.y+view.h+.6,"last slider not fully visible")
    check(UI.FindWidgetAt(last.x+last.w*.5,last.y+last.h*.5)==music,"last slider hit at bottom")
    check(soundCalls_==soundBefore and volumeCalls_==volumeBefore,"vertical swipe submitted audio")
    local closeAfter=item("closeVolumePanel"):GetAbsoluteLayoutForHitTest()
    check(math.abs(closeAfter.y-fixedClose.y)<.1,"close scrolled away")
    -- 轻点音量滑杆仍生效，纵拖不改值，横拖只调整自己的值。
    tapAt(last.x+last.w*.2,last.y+last.h*.5)
    check(volumeCalls_>volumeBefore and values_.musicVolume<.3,"tap music value")
    local before=volumeCalls_;local oldValue=music:GetValue()
    drag(last.x+last.w*.7,last.y+last.h*.5,2,75);settle()
    check(volumeCalls_==before and math.abs(music:GetValue()-oldValue)<.001,"vertical slider drag changed value")
    check(scrollValue()<maxScroll()-50,"slider swallowed vertical pan")
    -- 再拖回底部，横向音量手势不能带动列表。
    for _=1,4 do drag(view.x+view.w*.45,view.y+view.h*.8,0,-view.h*.65);settle() end
    last=music:GetAbsoluteLayoutForHitTest();local beforeScroll=scrollValue()
    before=volumeCalls_
    drag(last.x+last.w*.2,last.y+last.h*.5,last.w*.55,1);settle()
    check(volumeCalls_>before and values_.musicVolume>.65,"horizontal slider adjustment")
    check(math.abs(scrollValue()-beforeScroll)<.2,"horizontal volume drag scrolled")
    -- 所有四个音量入口都从真实手指滚动定位后点击，确认回调没有串行。
    for _,key in ipairs({"volume","trainVolume","announcementVolume","musicVolume"}) do
        local slider=item("volumeSlider_"..key) --[[@as Slider]]
        for _=1,8 do
            local b=slider:GetAbsoluteLayoutForHitTest()
            if b.y>=view.y and b.y+b.h<=view.y+view.h+.6 then break end
            local delta=b.y<view.y and 55 or -55
            drag(view.x+view.w-6,view.y+view.h*.5,0,delta);settle()
        end
        local b=slider:GetAbsoluteLayoutForHitTest()
        check(UI.FindWidgetAt(b.x+b.w*.4,b.y+b.h*.5)==slider,"scroll to slider "..key)
        local count=volumeCalls_;tapAt(b.x+b.w*.4,b.y+b.h*.5)
        check(volumeCalls_>count and math.abs(values_[key]-.4)<.025,"slider callback "..key)
    end
    -- 鼠标仍可点值/拖动，没有全局修改控件或输入管理器。
    local b=music:GetAbsoluteLayoutForHitTest()
    local scale=UI.GetScale();local count=volumeCalls_
    UI.InputAdapter.HandleMouseDown((b.x+b.w*.2)*scale,(b.y+b.h*.5)*scale,UI.PointerEvent.Button.Left)
    UI.InputAdapter.HandleMouseMove((b.x+b.w*.8)*scale,(b.y+b.h*.5)*scale)
    UI.InputAdapter.HandleMouseUp((b.x+b.w*.8)*scale,(b.y+b.h*.5)*scale,UI.PointerEvent.Button.Left)
    check(volumeCalls_>count and values_.musicVolume>.7,"mouse slider regressed")
    -- 自适应高度变大后，旧 scroll offset 必须夹回有效范围。
    for _=1,6 do drag(view.x+view.w*.45,view.y+view.h*.8,0,-view.h*.7);settle() end
    local oldBounds=panel():GetAbsoluteLayoutForHitTest()
    panel():SetBounds(oldBounds.x,oldBounds.y,oldBounds.w,oldBounds.h-30)
    layout()
    for _=1,4 do
        local v=scroll():GetAbsoluteLayoutForHitTest()
        drag(v.x+v.w*.45,v.y+v.h*.8,0,-v.h*.7);settle()
    end
    panel():SetBounds(oldBounds.x,oldBounds.y,oldBounds.w,oldBounds.h)
    layout()
    check(scrollValue()<=maxScroll()+.2,"resize left stale overscroll")
    local camera=ViewDrag.GetStatus()
    check(camera.accepted==0 and camera.moved==0 and not camera.active,"volume gesture dragged camera")
    check(driveCalls_==0,"volume gesture hit driving controls")
    -- 手势中第二根手指关闭；关闭/重开不留下 slider 捕获或旧 overlay。
    last=music:GetAbsoluteLayoutForHitTest()
    begin(last.x+last.w*.3,last.y+last.h*.5)
    local active=touchId_
    local close=item("closeVolumePanel"):GetAbsoluteLayoutForHitTest()
    tapAt(close.x+close.w*.5,close.y+close.h*.5)
    check(not Hud.IsVolumePanelOpen() and UI.GetTopOverlay()~=panel(),"close overlay cleanup")
    UI.InputAdapter.HandleTouchCancel(active)
    check(not music.state.dragging,"close retained slider drag")
    tap("openVolumePanel");layout()
    check(scrollValue()==0,"reopen not at top")
    tap("volumePanelSound")
    check(soundCalls_==soundBefore+1 and not values_.sound,"sound toggle tap broken")
    tap("volumePanelSound")
    check(soundCalls_==soundBefore+2 and values_.sound,"sound reenable tap broken")
    -- 从标签/空隙纵拖也必须滚动；滑过标题和关闭键不得触发关闭。
    local firstLabel=item("volumeLabel_volume"):GetAbsoluteLayoutForHitTest()
    drag(firstLabel.x+firstLabel.w*.45,firstLabel.y+firstLabel.h*.5,0,-view.h);settle()
    check(scrollValue()>0 and Hud.IsVolumePanelOpen(),"label swipe failed/closed")
    -- 关闭后清理hook，再重建整棵 HUD 验证生命周期。
    tap("closeVolumePanel")
    Hud.BuildRoot();UI.Layout();sync();tap("openVolumePanel");layout()
    for _=1,6 do
        local b=scroll():GetAbsoluteLayoutForHitTest()
        drag(b.x+b.w*.45,b.y+b.h*.8,0,-b.h*.7);settle()
    end
    check(math.abs(scrollValue()-maxScroll())<1,"rebuilt finger scroll")
    check(UI.GetTopOverlay()==panel(),"rebuilt overlay priority")
    local hud=Hud.GetLayout()
    check(noOverlap(panel():GetAbsoluteLayoutForHitTest(),hud.controls),"volume overlaps throttle/brake")
    check(driveCalls_==0 and ViewDrag.GetStatus().moved==0,"gesture leaked after rebuild")
    print(string.format("ALL_VOLUME_PANEL_TOUCH_PASS checks=%d physical=%dx%d base=%.1fx%.1f panel=%.1fx%.1f viewport=%.1f content=%.1f scroll=%.1f rendered=%d",
        checks_,graphics:GetWidth(),graphics:GetHeight(),w,h,r.w,r.h,scroll():GetLayout().h,
        select(2,scroll():GetContentSize()),scrollValue(),Hud.GetRenderedFrames()))
end
function HandleVolumePanelValidation()
    guard(function()
        frame_=frame_+1
        if frame_==5 then validate() end
        if frame_==30 then
            -- 再以更密集的 1:1 基准像素测试矮屏，不能只依赖默认缩放放大的虚拟视口。
            panel():Close()
            UI.SetScale(1)
            Hud.BuildRoot();UI.Layout();sync()
            validate()
        end
        if frame_==125 then
            check(Hud.GetRenderedFrames()>0 or graphics:GetWidth()==0,"expected rendered frames")
            print("ALL_VOLUME_PANEL_ACCEPTANCE_COMPLETE checks="..checks_)
        end
    end)
end
function Stop()
    ViewDrag.Shutdown();Hud.Shutdown();UI.GetSafeAreaInsets=originalSafe_
end
