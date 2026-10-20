-- 复用 PassengerStationValidation 的正式 main 生命周期与存档隔离脚手架。
-- 每帧只调用一次生产 PostUpdate；位置夹具仅提供驾驶输入，不代建站台、不清空流式队列。
local Save=require "game.SaveStore"
local original_={Load=Save.Load,Get=Save.Get,Write=Save.Write,ReadCloud=Save.ReadCloud,SetCloud=Save.SetCloud}
local fixture_={version=1,settings={quality="low",sound=false,music=false,cloud=false,
    environment={hour=12,running=false,weather="clear"}},journeys={}}
local writes_=0
Save.Load=function() return fixture_ end
Save.Get=function() return fixture_ end
Save.Write=function(value) writes_=writes_+1;fixture_=value;return true end
Save.ReadCloud=function(callback) callback(nil) end
Save.SetCloud=function() end
require "main"
local mainStart,mainUpdate,mainPost,mainStop=Start,HandleUpdate,HandlePostUpdate,Stop
local Train=require "train.Train"
local Game=require "game.Game"
local Passenger=require "game.PassengerService"
local Stream=require "world.WorldStream"
local Route=require "world.Route"
local Camera=require "train.Camera"
local UI=require "urhox-libs/UI"
local Hud=require "ui.Hud"
local mode_,capture_="normal",false
for _,arg in ipairs(GetArguments()) do
    mode_=arg:match("^%-lifecycle%-mode=(.+)$") or mode_
    if arg=="-lifecycle-capture" then capture_=true end
end
assert(mode_=="normal" or mode_=="rage","未知生命周期模式")
local stage_,frames_,since_,checks_,approach_="initial",0,0,0,0
local done_,stopped_,warmed_=false,false,false
local captureName_,captureFrames_="",0
local beforeWrites_,beforeElapsed_=0,0
---@type Viewport?
local loadingViewport_=nil
---@type Viewport?
local betweenShotsViewport_=nil
local function check(value,message)
    checks_=checks_+1;assert(value,"[StationLifecycle] "..message)
end
local function transition(stage)
    stage_,since_=stage,frames_
    print(string.format("[StationLifecycle] mode=%s stage=%s frame=%d",mode_,stage,frames_))
end
local function cleanup()
    if stopped_ then return end
    stopped_=true;pcall(mainStop)
    Save.Load,Save.Get,Save.Write=original_.Load,original_.Get,original_.Write
    Save.ReadCloud,Save.SetCloud=original_.ReadCloud,original_.SetCloud
end
local function guard(action)
    if done_ then return end
    local ok,message=xpcall(action,debug.traceback)
    if not ok then
        done_=true;print("STATION_LIFECYCLE_FAILED "..tostring(message))
        log:Write(LOG_ERROR,tostring(message));cleanup();engine:Exit()
    end
end
local function ready(index)
    local status=Stream.GetStationStatus(index)
    check(Stream.IsStationReady(index),"可玩状态站台实体未就绪 index="..index)
    check(status.platformVertices>0 and status.uploadedVertices>0,"站台未提交实际几何 index="..index)
    local root=assert(Stream.GetStats().root)
    local node=assert(root:GetChild("station_"..index))
    check(node.enabled,"站台根仍禁用")
    print(string.format("[StationLifecycle] READY station=%d vertices=%d uploaded=%d frame=%d",index,
        status.platformVertices,status.uploadedVertices,frames_))
end
local function pose(s,v)
    local snapshot=Train.ExportState()
    snapshot.s,snapshot.v,snapshot.throttle,snapshot.brake=s,v,0,1
    snapshot.derailed,snapshot.reversing,snapshot.topology=false,false,nil
    Train.RestoreState(snapshot)
end
local function restart()
    -- 走正式事故重开按钮和触摸分发，而非把 main 的局部函数改成测试入口。
    Hud.ShowGameOver("车站恢复生命周期验收")
    UI.Layout()
    local button=assert(assert(Hud.GetRoot()):FindById("restartJourney"))
    local bounds=button:GetAbsoluteLayoutForHitTest()
    check(UI.FindWidgetAt(bounds.x+bounds.w*.5,bounds.y+bounds.h*.5)==button,"重开按钮触摸未命中")
    local x,y=(bounds.x+bounds.w*.5)*UI.GetScale(),(bounds.y+bounds.h*.5)*UI.GetScale()
    UI.InputAdapter.HandleTouchBegin(991,x,y,.5)
    UI.InputAdapter.HandleTouchEnd(991,x,y)
    UI.Update(.01)
end
local function shot(name)
    if not capture_ then return end
    captureName_,captureFrames_,warmed_=name,0,false
end
function Start()
    guard(function()
        mainStart();BeginJourney(false,mode_)
        SubscribeToEvent("EndFrame","HandleStationLifecycleCapture")
    end)
end
function HandleUpdate(eventType,eventData)
    guard(function()
        frames_=frames_+1
        local event=VariantMap();event["TimeStep"]=Variant(.05)
        if captureName_~="" then return end
        -- llvmpipe 只在取图阶段绘制；Update/PostUpdate 仍逐真实帧执行。
        -- 在任何生产回调前归还视口，不能改变重开取得视口的前置条件。
        if betweenShotsViewport_ then
            renderer:SetNumViewports(1);renderer:SetViewport(0,betweenShotsViewport_)
            betweenShotsViewport_=nil
        end
        if stage_=="approach" then
            approach_=approach_+1
            local second=assert(Route.GetStations()[2])
            local distance=math.max(0,3000-approach_*5)
            pose(second.s-distance,distance>0 and 70 or 0)
        end
        mainUpdate(eventType,event --[[@as UpdateEventData]])
        -- 只抑制初载半成品的绘制；进入 playing 时必须还原保活的视口，
        -- 否则会把测试制造的黑屏误当成生产重开失败。
        if GetApplicationState()=="loading" then
            loadingViewport_=loadingViewport_ or renderer:GetViewport(0)
            renderer:SetNumViewports(0)
        elseif GetApplicationState()=="playing" and loadingViewport_ then
            renderer:SetNumViewports(1);renderer:SetViewport(0,loadingViewport_)
            loadingViewport_=nil
        end
        check(GetApplicationState()~="error","正式 main 加载失败")
        check(frames_-since_<5000,"生命周期阶段超时 "..stage_)
        if stage_=="initial" and GetApplicationState()=="playing" then
            ready(1);shot("initial");transition("prepare")
        elseif stage_=="prepare" then
            Passenger.Reset()
            local state=Game.ExportState()
            state.state,state.nextIndex,state.dwellTimer="driving",2,0
            state.lastArrival,state.initialService=nil,false
            Game.RestoreState(state)
            pose(assert(Route.GetStations()[2]).s-3000,70)
            transition("approach")
        elseif stage_=="approach" and approach_>=600 then
            ready(2)
            if mode_=="normal" then
                check(Passenger.HasActiveStop(),"真实到站未进入客运站停")
            end
            shot("next_station");transition("restart_begin")
        elseif stage_=="restart_begin" then
            if mode_=="normal" then
                Train.Derail("生命周期验收事故夹具")
                check(Train.IsDerailed(),"普通模式事故夹具未产生真实事故")
            end
            beforeWrites_,beforeElapsed_=writes_,Game.GetElapsed()
            restart()
            check(GetApplicationState()=="loading","重开没有进入实体恢复屏障")
            check(renderer:GetNumViewports()==0,"重开仍展示半成品世界")
            SaveJourneyNow()
            check(writes_==beforeWrites_,"恢复中保存了新列车与旧客流混合状态")
            transition("restart_wait")
        elseif stage_=="restart_wait" then
            if GetApplicationState()=="loading" then
                check(Game.GetElapsed()==beforeElapsed_,"恢复屏障期间仍推进运营")
            elseif GetApplicationState()=="playing" then
                ready(1)
                check(math.abs(Train.GetS()-assert(Route.GetStations()[1]).s-1)<.1,"重开未回始发站")
                check(not Train.IsDerailed(),"重开未清事故")
                check(renderer:GetNumViewports()==1,"重开未恢复视口")
                if mode_=="normal" then check(Passenger.HasActiveStop(),"站台恢复后未重建登乘") end
                shot("restart");transition("cancel_begin")
            end
        elseif stage_=="cancel_begin" then
            restart()
            check(GetApplicationState()=="loading","第二次重开未进入加载")
            ReturnToMainMenu()
            check(GetApplicationState()=="menu" and GetGameScene()==nil,"取消未释放世界")
            transition("cancel_wait")
        elseif stage_=="cancel_wait" and frames_-since_>=24 then
            check(GetApplicationState()=="menu" and GetGameScene()==nil,"旧协程复活了已取消的世界")
            print(string.format("ALL_STATION_LIFECYCLE_PASS mode=%s checks=%d frames=%d noPlayerSaveIO=true noCloudIO=true",
                mode_,checks_,frames_))
            done_=true;cleanup();engine:Exit()
        end
    end)
end
function HandlePostUpdate(eventType,eventData)
    guard(function()
        local event=VariantMap();event["TimeStep"]=Variant(.05)
        mainPost(eventType,event --[[@as PostUpdateEventData]])
        if captureName_~="" and GetApplicationState()=="playing" then
            local station=assert(Route.GetStations()[1])
            if captureName_=="next_station" then station=assert(Route.GetStations()[2]) end
            local eye=assert(Camera.GetNode())
            eye.worldPosition=Route.SampleOffset(station.s+18,4,6.4)
            eye:LookAt(Route.SampleOffset(station.s-145,6,2))
        elseif capture_ and GetApplicationState()=="playing" then
            betweenShotsViewport_=renderer:GetViewport(0)
            renderer:SetNumViewports(0)
        end
    end)
end
function HandleStationLifecycleCapture()
    guard(function()
        if captureName_=="" then return end
        captureFrames_=captureFrames_+1
        if captureFrames_<16 then return end
        local image=Image()
        check(graphics:TakeScreenShot(image),"真实渲染读回失败")
        if not warmed_ then warmed_=true;image:Dispose();return end
        local path="/workspace/screenshots/station_lifecycle_"..mode_.."_"..captureName_..".png"
        check(image:SavePNG(path),"截图保存失败");image:Dispose()
        local decoded=Image();check(decoded:Load(path),"截图回读失败")
        local low,high=1.0,0.0
        for y=1,8 do for x=1,12 do
            local pixel=decoded:GetPixel(math.floor(decoded.width*x/13),math.floor(decoded.height*y/9))
            local value=(pixel.r+pixel.g+pixel.b)/3
            low,high=math.min(low,value),math.max(high,value)
        end end
        decoded:Dispose();check(high-low>.06,"截图为空白")
        print("STATION_LIFECYCLE_CAPTURE "..path)
        captureName_=""
    end)
end
function Stop() cleanup() end
