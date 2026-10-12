-- 本轮回归：真实始发队列、骨骼人物、常驻按钮、手动超速、轨外倾覆及重开。
-- 基于现有主入口验收脚手架；所有截图仅供内部视觉检查。
require "main"
local mainStart,mainUpdate,mainPost = Start,HandleUpdate,HandlePostUpdate
local Train=require "train.Train"
local Route=require "world.Route"
local Game=require "game.Game"
local Passenger=require "game.PassengerService"
local Hud=require "ui.Hud"
local UI=require "urhox-libs/UI"
local Camera=require "train.Camera"
local Traffic=require "game.Traffic"
local Accident=require "train.Accident"
local Audio=require "audio.AudioManager"
local Landmarks=require "world.Landmarks"
local frames_,stage_,checks_ = 0,"boarding",0
local failed_,capture_,walkingSeen_ = false,false,false
local initial_ = 0
local baseline_ = Vector3.ZERO
local function check(condition,message)
    checks_=checks_+1
    assert(condition,"[Experience] "..message)
end
local function guard(action)
    if failed_ then return end
    local ok,message=xpcall(action,debug.traceback)
    if not ok then failed_=true;log:Write(LOG_ERROR,tostring(message));engine:Exit() end
end
local function tap(id)
    UI.Layout()
    local control=assert(assert(Hud.GetRoot()):FindById(id))
    local r=control:GetAbsoluteLayoutForHitTest()
    check(r.w>0 and r.h>0,"实际按钮布局缺失："..id)
    UI.InputAdapter.HandleTouchBegin(886,(r.x+r.w*.5)*UI.GetScale(),(r.y+r.h*.5)*UI.GetScale(),.5)
    UI.InputAdapter.HandleTouchEnd(886,(r.x+r.w*.5)*UI.GetScale(),(r.y+r.h*.5)*UI.GetScale())
end
local function screenshot(name)
    local image=Image()
    check(graphics:TakeScreenShot(image),"无法读取真实渲染")
    check(image:SavePNG("/workspace/screenshots/"..name..".png"),"真实截图保存失败")
    image:Dispose()
    print("[Experience] REAL_SCREENSHOT "..name)
end
function Start()
    guard(function()
        mainStart()
        initial_=Passenger.GetStatus().totalBoarding
        check(initial_>300 and initial_<=Passenger.GetCapacity(),"始发不是合理数百人")
        check(Passenger.GetCapacity()==608,"默认8节容量错误")
        check(#Route.GetSegments()==21,"线路未更新为多段交替曲线")
        local bridges,tunnels=0,0
        for _,d in ipairs(Landmarks.GetDefinitions()) do
            if d.kind=="bridge" then bridges=bridges+1 elseif d.kind=="tunnel" then tunnels=tunnels+1 end
        end
        check(bridges==2 and tunnels==2,"新线路丢失桥隧")
        tap("openTrainSelector")
        check(Hud.IsTrainSelectorOpen(),"常驻换车真实触摸未打开")
        tap("closeTrainSelector")
        check(not Hud.IsTrainSelectorOpen(),"车型菜单未关闭")
        tap("toggleSound")
        check(not Audio.IsEnabled(),"常驻静音按钮未生效")
        tap("toggleSound")
        check(Audio.IsEnabled(),"常驻声音按钮无法恢复")
        TogglePause()
        Passenger.SetPaused(false)
        Camera.SetMode("platform")
        SubscribeToEvent("EndRendering","ExperienceCapture")
        print("[Experience] 初始化检查通过；394人逐门真实登乘")
    end)
end
---@param eventType string
---@param eventData UpdateEventData
function HandleUpdate(eventType,eventData)
    guard(function()
        frames_=frames_+1
        if stage_=="boarding" then
            -- 保留跨门中间姿态给真实截图，再以相同固定步完整推进，不伪造清单。
            local steps=frames_<32 and 10 or 150
            for _=1,steps do Passenger.Update(.02) end
            Passenger.UpdateVisuals(.02)
            local stats=Passenger.GetVisualStats()
            walkingSeen_=walkingSeen_ or stats.walking>0
            if frames_==32 then
                check(stats.allocated<=36 and stats.created<=36,"人物池不断分配骨骼模型")
                check(stats.skinned and stats.bonesPerActor==41 and stats.visible<=36,"仍是程序方块人")
                check(walkingSeen_,"未见真实行走演员")
                capture_=true
            end
            if Passenger.IsReady() and frames_>40 then
                check(stats.created<=36 and stats.reused>0,"数百人登乘仍不断创建骨骼模型")
                print(string.format("[Experience] 人物池created=%d reused=%d allocated=%d",stats.created,stats.reused,stats.allocated))
                check(Passenger.GetStatus().onboard==initial_,"登乘人数与实际清单不一致")
                check(Passenger.GetStatus().boarded==initial_,"乘客未走到门却被计数")
                check(Game.GetXp()==0,"始发刷奖励")
                for _=1,650 do Game.Update(.02) end
                check(not Game.IsDwelling(),"完成乘降后无法发车")
                stage_="manual"
                print("[Experience] 数百人真实乘降完成；开始自主驾驶检查")
            end
        elseif stage_=="manual" then
            local straight=Route.GetSegments()[1]
            Train.Reset(straight.s+straight.length-100)
            Train.SetBrake(0);Train.SetThrottle(8)
            for _=1,120 do Train.Update(.02) end
            -- 传入非常近的旧movementLimit，验证不会再钳位置/抢制动。
            local before=Train.GetS()
            Train.Update(.1,before+.001,nil)
            check(Train.GetS()>before+.001 and Train.GetThrottle()==8 and Train.GetBrake()==0,
                "仍强制运动界停车或抢控制权")
            TogglePause()
            for _=1,30 do mainUpdate(eventType,eventData) end
            check(Train.GetThrottle()==8 and Train.GetBrake()==0 and not Train.IsDerailed(),"主入口仍自动收油或制动")
            TogglePause();Passenger.SetPaused(false)
            local cars=Train.GetCars()
            Train.UpdateVisuals(0)
            baseline_=cars[1].node.worldPosition
            local seg=Route.GetSegments()[2]
            -- 与生产完全同一曲率风险判定，70m/s对应约3.06m/s²，持续后确实触发。
            Accident.Reset()
            for _=1,30 do Accident.Evaluate(.02,70,350,seg.s+200,Train.GetActiveLength(),Train.GetTrackSample,cars) end
            check(Train.IsDerailed(),"真实曲线高侧向负荷没有脱轨")
            Game.Update(.02)
            check(assert(Hud.GetRoot()):FindById("gameOver").props.visible,"事故未结束本局")
            tap("openTrainSelector")
            check(not Hud.IsTrainSelectorOpen(),"事故模态遮罩未阻断底层换车按钮")
            check(not Game.SetService("express"),"事故后还能切换运营任务")
            check(not Game.ToggleDrivingMode(),"事故后还能切换驾驶模式")
            Camera.SetMode("front_chase")
            stage_="derail"
            print("[Experience] 手动油门/制动保留，曲线事故触发")
        elseif stage_=="derail" then
            for _=1,5 do Train.Update(.02) end
            Train.UpdateVisuals(0)
            if Train.GetAccidentStatus().age>3 then
                check((assert(Train.GetLeadNode()).worldPosition-baseline_):Length()>5,"事故仅文案，列车没离轨")
                local up=Train.GetLeadRotation()*Vector3.UP
                check(math.abs(up.y)<.3,"车体没有实际倾覆")
                stage_="restart";capture_=true
            end
        elseif stage_=="restart" and not capture_ then
            tap("restartJourney")
            check(not Train.IsDerailed(),"真实重开按钮未清理事故")
            check(not Hud.IsTrainSelectorOpen() and GetFrameSimulationStats().debt==0,"重开遗留暂停菜单或积欠时间")
            check(Passenger.GetVisualStats().created<=36,"重开重新分配人物池")
            check(Passenger.HasActiveStop() and Passenger.GetStatus().onboard==0,"重开没有恢复始发登乘")
            local oncoming,leader=nil,nil ---@type table?,table?
            for _,train in ipairs(Traffic.GetTrains()) do
                if train.active and train.type=="opposing" and not oncoming then oncoming=train end
                if train.active and train.type=="local" then leader=train end
            end
            check(oncoming~=nil and leader~=nil,"碰撞测试缺少实际来往班次")
            Train.Reset(assert(oncoming).headS+20)
            Traffic.CheckPlayerCollision()
            check(not Train.IsDerailed(),"相邻平行股道会车被误判撞车")
            Train.Reset(assert(leader).headS-50)
            Traffic.CheckPlayerCollision()
            check(Train.IsDerailed(),"实际同股道车体重叠没有触发事故")
            Train.Reset(Route.GetLength()-5)
            Train.Update(.02)
            check(Train.IsDerailed() and Train.GetAccidentStatus().reason:find("终端",1,true),"线路端点仍静默钳位置而非事故")
            Train.Reset(1000)
            for _=1,55 do Accident.Evaluate(.02,160,350,1000,Train.GetActiveLength(),Train.GetTrackSample,Train.GetCars()) end
            check(Train.IsDerailed() and Train.GetAccidentStatus().reason:find("结构",1,true),"结构超速没有触发事故")
            Game.Update(.02)
            tap("restartJourney")
            check(not Train.IsDerailed() and Passenger.GetStatus().onboard==0,"多类事故后无法恢复始发")
            print(string.format("ALL_EXPERIENCE_PASS checks=%d boarded=%d walking=%s frames=%d",checks_,initial_,tostring(walkingSeen_),frames_))
            engine:Exit()
        end
        check(frames_<400,"回归步骤超出有界帧预算")
    end)
end
---@param eventType string
---@param eventData PostUpdateEventData
function HandlePostUpdate(eventType,eventData)
    guard(function()
        mainPost(eventType,eventData)
        Game.UpdateHud(0)
        Passenger.UpdateVisuals(.02)
        if stage_=="boarding" then
            local station=Route.GetStations()[1]
            local node=assert(Camera.GetNode())
            node.worldPosition=Route.SampleOffset(station.s-115,7.4,2.1)
            node:LookAt(Route.SampleOffset(station.s-108,1.8,2.1))
        end
    end)
end
function ExperienceCapture()
    guard(function()
        if capture_ then screenshot(stage_=="boarding" and "experience_boarding" or "experience_derail");capture_=false end
    end)
end
