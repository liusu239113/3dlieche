-- Pure model tests plus REAL Game/Train/Passenger/Traffic integration. No main, files,
-- cloud, autosave, downloads, installed runtime, or test doubles of gameplay modules.
local Timetable=require "game.Timetable"
local Environment=require "world.Environment"
local Route=require "world.Route"
local Train=require "train.Train"
local Traffic=require "game.Traffic"
local Passenger=require "game.PassengerService"
local Game=require "game.Game"
local checks_=0
---@type Scene?
local scene_=nil
local function check(value,message) checks_=checks_+1;assert(value,"[TimetableValidation] "..message) end
local function equal(a,b,message) check(math.abs(a-b)<.00001,message) end
local function clone(value) return cjson.decode(cjson.encode(value)) end
local function modelTests()
    local stations={}
    for i=1,5 do stations[i]={index=i,name="测试站"..i,s=1000+(i-1)*7000} end
    local clock={minutes=1438,rate=.4,running=true,paused=false,revision=0}
    local options={s=1001,reversing=false,service="local",journeyId=1,originIndex=1,
        operatingKmh=120,lineKmh=350,stationKmh=60,deceleration=.7,segments={},length=32000,closed=false}
    local motion={s=1001,speedMs=0,operatingKmh=120,deceleration=.7,dwelling=true,terminal=false,
        minimumDwellSeconds=12,passengerReady=false,departureBlocked=true,departureReason="passengers"}
    local model=Timetable.new(clock,stations,options)
    local status=model:GetStatus(motion)
    check(#status.rows==5,"初始五站运行图缺失")
    check(status.rows[1].plannedArrival==nil and status.rows[1].actualArrival==nil,"始发伪造到站")
    check(status.rows[5].plannedDeparture==nil,"终到伪造计划发车")
    check(status.rows[2].plannedArrival>1440,"计划未跨午夜")
    check(Timetable.FormatTime(status.rows[2].plannedArrival):find("+1日",1,true),"跨日标签缺失")
    local previous=0
    for _,row in ipairs(status.rows) do
        local time=row.plannedArrival or row.plannedDeparture
        check(time>=previous,"计划到发时间逆序")
        previous=row.plannedDeparture or time
        check(row.actualArrival==nil and row.actualDeparture==nil,"未到先显示假实际")
    end
    local plan=status.rows[2].plannedArrival
    local fast=Timetable.EstimateRun(1001,8000,0,options,stations)
    options.operatingKmh=60
    local slow=Timetable.EstimateRun(1001,8000,0,options,stations)
    check(slow>fast and fast>6999/(120/3.6),"ETA忽略加减速/运营速度")
    local frozen=model:Export()
    motion.operatingKmh=60
    check(model:GetStatus(motion).rows[2].expectedArrival>status.rows[2].expectedArrival,"换车未改变ETA")
    equal(model:Export().rows[2].plannedArrival,plan,"换车重写计划")
    motion.dwelling=false;motion.passengerReady=true;motion.departureBlocked=false
    model:Observe(motion)
    check(model:Export().rows[1].actualDeparture==nil,"许可松闸被冒充实际发车")
    clock.minutes=1439;model:SyncClock(clock)
    motion.s=1004;motion.speedMs=.5;model:Observe(motion)
    equal(model:Export().rows[1].actualDeparture,1439,"真实移动没有实际发车")
    clock.minutes=1490;model:SyncClock(clock);model:Arrive(2)
    equal(model:Export().rows[2].actualArrival,1490,"真实到站没记录实际")
    local prior=model:Export()
    clock.minutes=1610;clock.revision=1;model:SyncClock(clock)
    local edited=model:Export()
    equal(edited.rows[2].actualArrival,1490,"调时改了实际到达")
    equal(edited.rows[2].plannedArrival,prior.rows[2].plannedArrival,"调时改了已执行计划到达")
    equal(edited.rows[3].plannedArrival,prior.rows[3].plannedArrival+120,"调时没有平移未来计划")
    check(model:Restore(clone(edited)),"JSON往返恢复失败")
    local bad=clone(edited);bad.version=999
    check(not model:Restore(bad),"接受未来版本")
    equal(model:Export().rows[2].actualArrival,1490,"失败恢复改变原进度")
    bad=clone(edited);bad.rows[3].phase="future_state"
    check(not Timetable.ValidateSnapshot(bad),"接受未知运营状态")
    bad=clone(edited);bad.rows[3].actualArrival=1
    check(not Timetable.ValidateSnapshot(bad),"未到站假实际通过校验")
    check(Timetable.ValidateSnapshot(nil),"旧档不兼容")
    check(Timetable.ValidateSnapshot(frozen),"合法计划校验失败")
    options.s=29000;options.originIndex=5;options.reversing=true;options.journeyId=2
    model:Replan(options)
    status=model:GetStatus(motion)
    local current={}
    for _,row in ipairs(status.rows) do if row.trip==2 then current[#current+1]=row end end
    check(#current==5 and current[1].stationIndex==5 and current[5].stationIndex==1,"折返站序错误")
    check(current[1].actualArrival==nil,"折返始发伪造实际到达")
end
local function step(seconds,moving)
    for _=1,math.floor(seconds/.02) do
        if moving then Train.Update(.02) end
        Environment.Advance(.02)
        Game.Update(.02)
    end
end
local function integrationTests()
    check(Environment.Init(nil,nil,{visuals=false,hour=12,running=true}),"Environment状态测试初始化失败")
    Route.Build()
    scene_=Scene();scene_:CreateComponent("Octree")
    Train.Build(scene_)
    Train.Reset(assert(Route.GetStations()[1]).s+1)
    Traffic.Init(scene_)
    Passenger.Init(scene_)
    Game.Init()
    local initial=Game.GetTimetableStatus()
    check(#initial.rows==5,"Game没建立五站计划")
    check(initial.rows[1].origin and not initial.rows[1].actualArrival,"Game初始站是假实际")
    local planned=initial.rows[2].plannedArrival
    step(1,false)
    check(Game.GetTimetableStatus().minutes>initial.minutes,"Game未读Environment真源")
    local elapsed=Game.GetElapsed()
    local minute=Environment.GetClock().minutes
    Environment.SetPaused(true);Passenger.SetPaused(true);step(2,false)
    equal(Game.GetElapsed(),elapsed,"暂停推进游戏计时")
    equal(Environment.GetClock().minutes,minute,"暂停推进世界时刻")
    Passenger.SetPaused(false);Environment.SetPaused(false)
    Environment.SetTimeRunning(false);step(1,false)
    equal(Environment.GetClock().minutes,minute,"停时仍推进世界时刻")
    check(Game.GetTimetableStatus().condition:find("停止",1,true),"停时没有明确预测条件")
    Environment.SetTimeRunning(true)
    local before=Game.ExportState()
    check(Train.Select("DF4D"),"真实换车失败")
    Game.UpdateHud(0)
    equal(Game.ExportState().timetable.rows[2].plannedArrival,planned,"真实换车重置旅程计划")
    local roundtrip=clone(before)
    Game.RestoreState(roundtrip)
    equal(Game.ExportState().timetable.rows[2].plannedArrival,planned,"真实Game JSON恢复计划丢失")
    local bad=clone(Game.ExportState());bad.timetable.version=999
    local xp=Game.GetXp()
    check(not pcall(Game.RestoreState,bad),"真实Game接受未知时刻表schema")
    equal(Game.GetXp(),xp,"未知schema改变原运营进度")
    local legacy=clone(before);legacy.timetable=nil
    Game.RestoreState(legacy)
    check(Game.GetTimetableStatus().migrated,"旧档没有迁移说明")
    check(Game.GetTimetableStatus().rows[1].actualArrival==nil,"旧档迁移伪造历史")
    Game.RestoreState(roundtrip)
    -- Let the production queue finish. No fake IsReady or mocked departure methods.
    step(180,false)
    check(Passenger.IsReady() and not Game.IsDwelling(),"真实乘降完成后未放行")
    check(Game.ExportState().timetable.rows[1].actualDeparture==nil,"Game.Depart冒充实际发车")
    Train.SetBrake(0)
    for _=1,8 do Game.ThrottleUp() end
    step(12,true)
    check(Train.GetS()>Route.GetStations()[1].s+3,"真实列车没有驶离")
    check(Game.ExportState().timetable.rows[1].actualDeparture~=nil,"真实Game移动未记发车")
    local actual=Game.ExportState().timetable.rows[1].actualDeparture
    Game.UpdateHud(0);Game.UpdateHud(0)
    equal(Game.ExportState().timetable.rows[1].actualDeparture,actual,"HUD刷新篡改实际发车")
    check(Timetable.Validate(Game.ExportState().timetable,Route.GetStations()),"实际Game输出校验失败")
    -- Restore a real Train position at the next platform, then let the PRODUCTION
    -- Game.CheckArrival detect the stopped, previously-moving train (not Game.Arrive shortcut).
    local nextStop=assert(Game.GetNextStation())
    local positioned=Train.ExportState()
    positioned.s,positioned.v,positioned.throttle,positioned.brake,positioned.moving=nextStop.s,0,0,1,true
    Train.RestoreState(positioned)
    Environment.Advance(.02);Game.Update(.02)
    local atStation=Game.ExportState().timetable.rows[2]
    check(Game.IsDwelling() and atStation.actualArrival~=nil,"真实CheckArrival未记录实际到达")
    equal(atStation.actualArrival,Environment.GetClock().minutes,"实际到达不来自Environment")
    check(atStation.actualDeparture==nil,"到站就伪造离站")
    local arrived=clone(Game.ExportState())
    Game.RestoreState(arrived)
    equal(Game.ExportState().timetable.rows[2].actualArrival,atStation.actualArrival,"JSON恢复实际到达丢失")
    Passenger.Shutdown();Traffic.Shutdown();Train.Shutdown();Environment.Destroy()
    scene_:Dispose();scene_=nil
end
function Start()
    local ok,message=xpcall(function() modelTests();integrationTests() end,debug.traceback)
    if ok then print("ALL_TIMETABLE_VALIDATION_PASS checks="..checks_)
    else print("TIMETABLE_VALIDATION_FAIL "..tostring(message));log:Write(LOG_ERROR,tostring(message)) end
    engine:Exit()
end
