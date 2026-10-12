-- 快速恢复验收：直接用已存在的自动存档进入旅程，验证存档往返与暂停确认。
require "main"
local mainStart,mainUpdate,mainPost,mainStop=Start,HandleUpdate,HandlePostUpdate,Stop
local UI=require "urhox-libs/UI"
local Menu=require "ui.Menu"
local Hud=require "ui.Hud"
local Train=require "train.Train"
local Camera=require "train.Camera"
local Passenger=require "game.PassengerService"
local Save=require "game.SaveStore"
local Game=require "game.Game"
local stage_,frames_,checks_,startFrame_="menu",0,0,0
local failed_,complete_=false,false
local expected_={} ---@type table
local hudFrames_=0
local function check(value,message) checks_=checks_+1;assert(value,"[RestoreValidation] "..message) end
local function guard(action)
    if failed_ or complete_ then return end
    local ok,message=xpcall(action,debug.traceback)
    if not ok then failed_=true;log:Write(LOG_ERROR,tostring(message)) end
end
local function tap(root,id)
    UI.Layout()
    local control=assert(root:FindById(id),"缺少控件："..id)
    local r=control:GetAbsoluteLayoutForHitTest()
    check(r.w>0 and r.h>0,"按钮实际布局缺失："..id)
    local x,y=(r.x+r.w*.5)*UI.GetScale(),(r.y+r.h*.5)*UI.GetScale()
    UI.InputAdapter.HandleTouchBegin(901,x,y,.5)
    UI.InputAdapter.HandleTouchEnd(901,x,y)
end
function Start()
    guard(function()
        mainStart()
        check(GetApplicationState()=="menu","未从主菜单启动")
        check(GetGameScene()==nil and renderer.numViewports==0,"开始前已经创建游戏世界")
        local saved=Save.Get()
        check(saved and saved.journey,"没有可恢复的自动存档")
        expected_.s=saved.journey.train.s
        expected_.camera=saved.journey.camera
        expected_.id=saved.journey.train.id
        expected_.xp=saved.journey.game and saved.journey.game.xp or 0
    end)
end
---@param eventType string
---@param eventData UpdateEventData
function HandleUpdate(eventType,eventData)
    guard(function()
        frames_=frames_+1
        mainUpdate(eventType,eventData)
        if stage_=="menu" and frames_==4 then
            tap(assert(Menu.GetRoot()),"continueGame")
            check(GetApplicationState()=="loading","继续旅程没有进入加载页")
            stage_="restoring";startFrame_=frames_
        elseif stage_=="restoring" then
            if frames_%40==0 then
                log:Write(LOG_WARNING,string.format("[RestoreValidation] heartbeat frames=%d state=%s",frames_,GetApplicationState()))
            end
            check(frames_-startFrame_<1600,"恢复超时")
            check(GetApplicationState()~="error","恢复旅程进入错误页")
            if GetApplicationState()=="playing" then
                check(math.abs(Train.GetS()-expected_.s)<.001,"存档位置改变："..Train.GetS().." vs "..expected_.s)
                check(Train.GetSelectedId()==expected_.id,"存档车型丢失")
                check(Camera.GetMode()==expected_.camera,"存档机位丢失："..Camera.GetMode())
                check(Hud.GetReadings().paused,"恢复时未暂停供玩家确认")
                check(Game.GetXp()==expected_.xp,"运营经验丢失")
                check(Train.GetCarCount()==8,"恢复后编组不是八节")
                stage_="confirm";startFrame_=frames_
            end
        elseif stage_=="confirm" then
            -- 渲染发生在 NanoVGRender 事件，比切换到 playing 晚；留几帧再确认界面确实出图。
            if frames_-startFrame_>=6 then
                check(UI.GetNVGContext()~=nil,"恢复后 UI 上下文丢失")
                hudFrames_=Hud.GetRenderedFrames()
                check(hudFrames_>0,"恢复后驾驶界面未渲染")
                ReturnToMainMenu()
                check(GetGameScene()==nil and renderer.numViewports==0,"返回菜单没有释放世界")
                check(GetApplicationState()=="menu","返回菜单后状态错误")
                stage_="backToMenu";startFrame_=frames_
            end
        elseif stage_=="backToMenu" then
            if frames_-startFrame_>=6 then
                check(UI.GetNVGContext()~=nil,"返回菜单后 UI 上下文被关闭")
                check(Menu.GetRoot()~=nil,"返回菜单后没有菜单控件树")
                check(Menu.GetPage()=="menu","返回菜单后不是菜单页")
                complete_=true
                print(string.format("ALL_RESTORE_VALIDATION_PASS checks=%d frames=%d s=%.2f camera=%s hudFrames=%d menuReleasedScene=true",
                    checks_,frames_,expected_.s,expected_.camera,hudFrames_))
            end
        end
    end)
end
---@param eventType string
---@param eventData PostUpdateEventData
function HandlePostUpdate(eventType,eventData) guard(function() mainPost(eventType,eventData) end) end
function Stop() mainStop() end
