-- 真入口回归：菜单真实触摸、分阶段加载、拖动/UI隔离、存档往返与骨骼姿态。
require "main"
local mainStart,mainUpdate,mainPost,mainStop=Start,HandleUpdate,HandlePostUpdate,Stop
local UI=require "urhox-libs/UI"
local Menu=require "ui.Menu"
local Hud=require "ui.Hud"
local Train=require "train.Train"
local Camera=require "train.Camera"
local Passenger=require "game.PassengerService"
local Audio=require "audio.AudioManager"
local Save=require "game.SaveStore"
local UiAudio=require "audio.UiAudio"
local stage_,frames_,checks_,startFrame_="menu",0,0,0
local failed_,complete_=false,false
local baseline_={} ---@type table
local CameraYaw0_=0
local function check(value,message) checks_=checks_+1;assert(value,"[ApplicationValidation] "..message) end
local function guard(action)
    if failed_ or complete_ then return end
    local ok,message=xpcall(action,debug.traceback)
    if not ok then failed_=true;log:Write(LOG_ERROR,tostring(message)) end
end
local function tap(root,id)
    UI.Layout()
    local control=assert(root:FindById(id))
    local r=control:GetAbsoluteLayoutForHitTest()
    check(r.w>0 and r.h>0,"按钮实际布局缺失："..id)
    local x,y=(r.x+r.w*.5)*UI.GetScale(),(r.y+r.h*.5)*UI.GetScale()
    UI.InputAdapter.HandleTouchBegin(901,x,y,.5)
    UI.InputAdapter.HandleTouchEnd(901,x,y)
end
local function capture(name)
    local image=Image()
    check(graphics:TakeScreenShot(image),"截图失败")
    check(image:SavePNG("/workspace/screenshots/"..name..".png"),"截图保存失败")
    image:Dispose()
end
function Start()
    guard(function()
        mainStart()
        baseline_.uiContext=UI.GetNVGContext()
        check(GetApplicationState()=="menu","未从主菜单启动")
        check(GetGameScene()==nil and renderer.numViewports==0,"开始前已经创建游戏世界")
        SubscribeToEvent("EndRendering","ApplicationValidationCapture")
    end)
end
function ApplicationValidationCapture()
    if failed_ or complete_ then return end
    if frames_==2 then capture("application_menu_oct11") end
    if stage_=="playing" and frames_==startFrame_+8 then capture("application_station_oct11") end
end
---@param eventType string
---@param eventData UpdateEventData
function HandleUpdate(eventType,eventData)
    guard(function()
        frames_=frames_+1
        mainUpdate(eventType,eventData)
        if stage_=="menu" and frames_==4 then
            tap(assert(Menu.GetRoot()),"startGame")
            check(GetApplicationState()=="loading","开始按钮没有进入加载页")
            stage_="loading";startFrame_=frames_
        elseif stage_=="loading" then
            check(frames_-startFrame_<1200,"场景加载超时")
            if GetApplicationState()=="error" then error("真实场景加载进入错误页") end
            if GetApplicationState()=="playing" then
                stage_="playing";startFrame_=frames_
                check(UI.GetNVGContext()==baseline_.uiContext,"加载结束重建了 UI 上下文")
                check(GetGameScene()~=nil and Train.GetCarCount()==8,"场景/八节车未加载")
                check(Passenger.GetVisualStats().skinned,"未加载骨骼人物")
                check(Passenger.GetStatus().totalBoarding>300,"真实始发队列丢失")
                check(Audio.GetDiagnostics().ownedSoundCount>=3,"运行声与环境未准备好")
                Camera.SetMode("side");Camera.Update(0,Train.GetS())
                CameraYaw0_=Camera.GetDiagnostics().yaw
            end
        elseif stage_=="playing" then
            if frames_==startFrame_+12 then
                check(Hud.GetRenderedFrames()>0,"HUD 从未收到实际渲染调用")
                local root=assert(UI.GetRoot())
                for _,id in ipairs({"speedInstrument","throttleHandle","brakeHandle","openCameraSelector","openTrainSelector","pauseGame"}) do
                    local control=assert(root:FindById(id),"驾驶控件缺失："..id)
                    local r=control:GetAbsoluteLayout()
                    check(r.w>0 and r.h>0,"驾驶控件不可见："..id)
                end
                local paused=Hud.GetReadings().paused
                tap(root,"pauseGame")
                check(Hud.GetReadings().paused~=paused,"真实触摸暂停按钮无效")
                tap(root,"pauseGame")
                check(Hud.GetReadings().paused==paused,"再次触摸未恢复暂停状态")
                local before=assert(Camera.GetNode()).worldPosition
                UI.Layout()
                local x,y=graphics:GetWidth()*.5,graphics:GetHeight()*.5
                check(UI.FindWidgetAt(x/UI.GetScale(),y/UI.GetScale())==nil,"测试空白处被HUD挡住")
                UI.InputAdapter.HandleTouchBegin(905,x,y,.5)
                local drag=require("train.ViewDrag").GetStatus()
                check(drag.active,"世界指针未接管："..drag.rejected.." / accepted="..drag.accepted)
                UI.InputAdapter.HandleTouchMove(905,x+80,y+12,.5)
                UI.InputAdapter.HandleTouchEnd(905,x+80,y+12)
                Camera.Update(.2,Train.GetS())
                local view=Camera.GetDiagnostics()
                log:Write(LOG_WARNING,string.format("[ApplicationValidation] 拖动 mode=%s yaw=%.2f pitch=%.2f 位置变化=%.3f 净空=%.3f moved=%d",
                    view.mode,view.yaw,view.pitch,(assert(Camera.GetNode()).worldPosition-before):Length(),Camera.GetSightDistance(),
                    require("train.ViewDrag").GetStatus().moved))
                local delta=assert(Camera.GetNode()).worldPosition-before
                check(math.abs(view.yaw-CameraYaw0_)>.5 or delta:Length()>.5,"触摸拖动没有改变真实视角")
                baseline_={s=Train.GetS(),count=Passenger.GetStatus().onboard,waiting=Passenger.GetStatus().waiting,
                    camera=Camera.GetMode(),xp=require("game.Game").GetXp()}
                check(SaveJourneyNow(),"自动存档文件写入失败")
                check(Save.Get() and Save.Get().journey,"存档无旅程状态")
                ReturnToMainMenu()
                check(GetGameScene()==nil and renderer.numViewports==0,"返回菜单没有释放世界")
                tap(assert(Menu.GetRoot()),"continueGame")
                stage_="restoring";startFrame_=frames_
            end
        elseif stage_=="restoring" then
            check(frames_-startFrame_<1200,"恢复超时")
            check(GetApplicationState()~="error","恢复旅程失败")
            if GetApplicationState()=="playing" then
                check(math.abs(Train.GetS()-baseline_.s)<.001,"存档位置改变")
                check(Passenger.GetStatus().onboard==baseline_.count and Passenger.GetStatus().waiting==baseline_.waiting,"存档乘降清单丢失")
                check(Camera.GetMode()==baseline_.camera,"存档机位丢失")
                check(Hud.GetReadings().paused,"恢复时未暂停供玩家确认")
                check(require("game.Game").GetXp()==baseline_.xp,"运营经验丢失")
                check(UiAudio.GetStatus().language=="both","默认双语广播未设置")
                complete_=true
                print(string.format("ALL_APPLICATION_VALIDATION_PASS checks=%d frames=%d menuNoScene=true realTouch=true savedPassengers=true",checks_,frames_))
            end
        end
    end)
end
---@param eventType string
---@param eventData PostUpdateEventData
function HandlePostUpdate(eventType,eventData) guard(function() mainPost(eventType,eventData) end) end
function Stop() mainStop() end
