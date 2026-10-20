-- Deterministic CPU regressions for real Traffic/Game code, no rendered models.
-- Only external train/route/passenger/UI dependencies are fixtures; authority,
-- locks, AI acceleration/braking, dispatch, tail clearance and Game interlock run unchanged.
---@type RailwayStation[]
local stations = {
    {index=1,name="A",s=2000},{index=2,name="B",s=10000},
    {index=3,name="C",s=20000},{index=4,name="D",s=30000},{index=5,name="E",s=38000},
}
local data = {s=20000.0,speedMs=0.0,length=220.0,reversing=false,throttle=0,brake=1,travel=1000.0}
local routeLength = 40000.0
local passengers = {ready=true,message="客运已完成",phase="ready"}
local paused = false
local route = {
    GetLength=function() return routeLength end,
    GetStations=function() return stations end,
    IsClosed=function() return false end,
    Distance=function(a,b) return math.abs(a-b) end,
    ForwardDistance=function(a,b) return b>=a and b-a or math.huge end,
    GetSegments=function() return {} end,
    Sample=function(s) return Vector3(0,0,s) end,
}
local train = {
    GetS=function() return data.s end,
    GetSpeedMs=function() return data.speedMs end,
    GetSpeedKmh=function() return data.speedMs*3.6 end,
    GetActiveLength=function() return data.length end,
    GetCars=function() return {{length=32}} end,
    IsReversing=function() return data.reversing end,
    GetServiceDeceleration=function() return .65 end,
    GetOperatingSpeedKmh=function() return 200 end,
    GetMaxSpeedKmh=function() return 200 end,
    GetThrottle=function() return data.throttle end,
    GetBrake=function() return data.brake end,
    GetDistanceTravelled=function() return data.travel end,
    IsDerailed=function() return false end,
    GetAccidentStatus=function() return {active=false,risk=0} end,
    IsMoving=function() return true end,
    EmergencyBrake=function() data.throttle,data.brake=0,1 end,
    SetBrake=function(value) data.brake=value end,
    GetDrivingMode=function() return "simulation" end,
}
local visual = {
    Init=function() end,Reset=function() end,Shutdown=function() end,Update=function() end,
    GetStats=function() return {visible=0,maxVisible=3,clonedCars=0} end,
}
local hud = setmetatable({}, {__index=function() return function() end end})
local passenger = {
    Reset=function() end,BeginStop=function() end,Update=function() end,
    RefreshDoorPlan=function() end,TakeCompletion=function() return nil end,
    GetStatus=function() return {ready=passengers.ready,message=passengers.message,phase=passengers.phase} end,
    IsReady=function() return passengers.ready end,IsPaused=function() return paused end,
    SetDestinations=function() end,FinishStop=function() return true end,
    GetStats=function() return {boarded=0,alighted=0,onboard=0,comfort=100,comfortPenalty=0} end,
}
local modules = {
    ["train.Train"]=train,["world.Route"]=route,["game.TrafficVisuals"]=visual,["ui.Hud"]=hud,
    ["audio.AudioManager"]={AnnounceArrival=function() end,AnnounceDeparture=function() end},
    ["game.PassengerService"]=passenger,
}
-- UrhoX's resource loader does not use package.loaded for project require.
-- Evaluate the actual owned modules in an isolated require environment instead.
---@param name string
---@return table
local function loadProject(name)
    if modules[name] then return modules[name] end
    local file=assert(cache:GetFile(name:gsub("%.","/")..".lua"))
    local lines={}
    while not file.eof do lines[#lines+1]=file:ReadLine() end
    file:Close()
    local env=setmetatable({require=loadProject},{__index=_G})
    local chunk=assert(load(table.concat(lines,"\n"),"@"..name,"t",env))
    local value=chunk()
    modules[name]=value
    return value
end
local Rail = loadProject("world.RailNetwork")
local Traffic = loadProject("game.Traffic")
local Game = loadProject("game.Game")
local passed = 0

---@param value any
---@param message string
local function check(value,message) assert(value,"[TrafficDeparture] "..message) end
---@param seconds number
local function advance(seconds)
    for _=1,math.floor(seconds/.02+.5) do Traffic.Update(.02) end
end
---@param id string
---@return table
local function snapshot(id)
    for _,item in ipairs(Traffic.GetTrains()) do if item.id==id then return item end end
    error("Missing train "..id)
end
---@param origin number
---@param s number
---@param reverse boolean
---@param lane integer
local function reset(origin,s,reverse,lane)
    Traffic.Shutdown()
    data.s,data.speedMs,data.length,data.reversing,data.throttle,data.brake=s,0,220,reverse,0,1
    Rail.Reset(s,220,reverse)
    if lane==2 then
        -- Set choice before any hull locks the third yard.
        Rail.Reset(-1000,220,reverse)
        check(Rail.SetStationChoice(3,2,-1000,220),"siding fixture failed")
        Rail.UpdatePlayer(s,220,reverse)
    end
    Traffic.SetPlayerOverride({s=s,speedMs=0,length=220,frontOffset=16,lane=lane,reversing=reverse})
    Traffic.Init(nil)
    Traffic.Reset(origin)
end
---@param name string
---@param fn fun()
local function test(name,fn)
    fn();passed=passed+1
    print("[TrafficDeparture] PASS "..name)
end

local function followingTrainChecks()
    local s=stations[3].s
    reset(s-3000,s,false,0)
    -- L01 starts behind a stopped player and catches up under real braking.
    local before=snapshot("L01")
    check(before.active and before.hi<s-220,"following fixture not behind")
    advance(160)
    local follower=snapshot("L01")
    check(follower.headS>before.headS and follower.speedMs<.03,"follower did not actually catch/stop")
    check(follower.hi<=s-220-80+.02,"following AI breached 80m gap")
    check(not Traffic.GetDepartureStatus(3).blocked,"rear follower/entry lock blocks leader departure")
    check(Traffic.GetSignalAspect(3)~="red","rear follower produces circular red")
    -- Getter must not change trains, signal or locks.
    local head=follower.headS
    for _=1,20 do Traffic.GetDepartureStatus(3) end
    check(snapshot("L01").headS==head,"read-only departure getter moved AI")
end

local function reverseChecks()
    local s=stations[3].s
    reset(s-1200,s,true,0) -- L01 head=s+600 (behind reverse leading tail).
    local rear=snapshot("L01")
    check(rear.lo>s+16,"reverse follower fixture not fully behind")
    check(not Traffic.GetDepartureStatus(3).blocked,"reverse rear train blocks reverse departure")
    reset(s-2450,s,true,0) -- L01 head=s-650 on the reverse exit throat.
    local state=Traffic.GetDepartureStatus(3)
    check(state.blocked and state.aspect=="red","reverse real exit/forward occupancy ignored")
    reset(s-1200,s,false,1) -- Independent lane1 must not read lane0 occupancy.
    check(not Traffic.GetDepartureStatus(3).blocked,"independent parallel track blocks departure")
end

local function frontAndThroatChecks()
    local s=stations[3].s
    reset(s-1400,s,false,2) -- L01 head=station+400, body spans actual exit.
    local status=Traffic.GetDepartureStatus(3)
    check(status.blocked and status.reason=="throat_conflict" and status.blockerName=="L01",
        "actual shared exit must stay red with structured blocker")
    -- A distant downstream train gives caution, not an all-yard exclusivity lock.
    reset(s-500,s,false,0)
    status=Traffic.GetDepartureStatus(3)
    check(not status.blocked and status.aspect=="yellow","downstream train should caution not fake deadlock")
    check(Traffic.GetSignalAspect(-999)=="red","unknown signal must fail closed")
end

local function passingChecks(reverse,queued)
    local s=stations[3].s
    reset(queued and s-3600 or s+5000,s,reverse,2)
    check(Traffic.SetService("passing"),"passing setup failed")
    local progress=assert(Traffic.GetStats().passing)
    local id=progress.trainId
    local initial=snapshot(id)
    if queued then check(not initial.active and initial.state=="queued","dispatch conflict not reproduced") end
    local priorHead=initial.headS
    local dispatched=initial.active
    local sawNose,sawClear=false,false
    for _=1,30000 do
        Traffic.Update(.02)
        progress=assert(Traffic.GetStats().passing)
        local current=snapshot(id)
        check(progress.trainId==id and current.dir==(reverse and -1 or 1) and current.lane==0,"passing identity/route changed")
        if current.active and dispatched then
            local delta=current.dir*(current.headS-priorHead)
            check(delta>=-.001 and delta<=200/3.6*.02+.001,"active passing train teleported")
        end
        if current.active then dispatched=true end
        priorHead=current.headS
        local noseOut=current.dir*(current.headS-progress.exitClearS)>0
        local tailOut=current.dir*(progress.tailS-progress.exitClearS)>0
        if noseOut and not tailOut then sawNose=true end
        if not tailOut then check(Traffic.GetSignalAspect(3)=="red","nose-only/timer clearance released signal") end
        if progress.cleared then
            check(tailOut and current.active,"clear without actual active tail")
            check(not Traffic.GetDepartureStatus(3).blocked,"tail clear retained stale red/lock")
            sawClear=true;break
        end
    end
    check(dispatched and sawNose and sawClear,"passing never safely dispatched/passed/tail-cleared")
end

local function opposingSameTrackChecks()
    local s=stations[3].s
    reset(s+5000,s,false,0)
    -- Reuse the public passing scheduler to create a true -dir lane0 actor.
    Traffic.SetPlayerOverride({s=s+450,speedMs=0,length=220,frontOffset=16,lane=0,reversing=true})
    check(Traffic.SetService("passing"),"opposing lane0 fixture not scheduled")
    local id=assert(Traffic.GetStats().passing).trainId
    check(snapshot(id).active and snapshot(id).dir==-1 and snapshot(id).lane==0,"opposing fixture route invalid")
    check(Traffic.SetService("local"),"cannot release only task metadata")
    Traffic.SetPlayerOverride({s=s,speedMs=0,length=220,frontOffset=16,lane=0,reversing=false})
    local status=Traffic.GetDepartureStatus(3)
    check(status.blocked and status.reason=="opposing_traffic" and status.blockerName==id,
        "same-track opposing traffic falsely treated like parallel line")
    advance(80)
    check(Traffic.GetDepartureStatus(3).blocked,"timeout released actual opposing traffic")
    check(snapshot(id).lo>=s+16+80-.02,"opposing AI drove through player hull")
end

local function cancellationChecks()
    local firstS,secondS,original=stations[1].s,stations[2].s,stations[3].s
    stations[1].s,stations[2].s,stations[3].s=100,800,1600
    reset(200,1600,false,2)
    check(Traffic.SetService("passing"),"cancel fixture setup failed")
    local id=assert(Traffic.GetStats().passing).trainId
    check(not snapshot(id).active,"cancel fixture unexpectedly dispatched")
    advance(.04)
    local progress=assert(Traffic.GetStats().passing)
    check(progress.cancelled and not progress.cleared and not progress.active,"unspawnable request falsely completed")
    check(progress.dispatchReason=="no_dispatch_corridor","cancel reason not geometric")
    -- The ordinary front AI still owns real exit/forward track after cancellation.
    check(Traffic.GetDepartureStatus(3).blocked,"cancelled request bypassed real front obstruction")
    -- Cancellation must not make Game require passingSawRed forever or award training completion.
    Game.Init()
    check(Game.SetService("passing"),"Game cancellation task fixture failed")
    local saved=Game.ExportState()
    saved.state,saved.lastArrival,saved.nextIndex,saved.dwellTimer="dwell",3,3,0
    saved.initialService,saved.rewarded,saved.passingSawRed,saved.passingComplete=false,{},false,false
    Game.RestoreState(saved)
    Traffic.Update(.02)
    check(assert(Traffic.GetStats().passing).cancelled,"Game fixture lost cancelled passing request")
    check(Game.GetDepartureStatus().passingPhase=="cancelled","Game did not surface cancelled signal phase")
    check(not Game.CanDepart(),"Game ignored actual front block after cancelling task")
    for _=1,12000 do
        Traffic.Update(.02);Game.Update(.02)
        if not Game.IsDwelling() then break end
    end
    check(not Game.IsDwelling(),"cancelled task still required passingSawRed and deadlocked")
    check(not Game.ExportState().passingComplete,"cancelled task counted as passing completion")
    stations[1].s,stations[2].s,stations[3].s=firstS,secondS,original
end

local function gameStatusChecks()
    local s=stations[3].s
    reset(s-1400,s,false,0)
    passengers.ready,paused=true,false
    Game.Init()
    local saved=Game.ExportState()
    saved.state,saved.lastArrival,saved.nextIndex,saved.dwellTimer="dwell",3,3,0
    saved.initialService,saved.rewarded=false,{}
    Game.RestoreState(saved)
    Game.Update(.1)
    local first=Game.GetDepartureStatus()
    check(first.blocked and first.signalReason=="throat_conflict","Game did not expose authoritative signal blocker")
    Game.Update(1)
    local later=Game.GetDepartureStatus()
    check(later.waitSeconds>=first.waitSeconds+.99,"Game wait not advanced by simulation dt")
    for _=1,50 do Game.GetDepartureStatus() end
    check(Game.GetDepartureStatus().waitSeconds==later.waitSeconds,"getter call count advanced wait")
    paused=true;Game.Update(100);paused=false
    check(Game.GetDepartureStatus().waitSeconds==later.waitSeconds,"paused wait advanced")
    local allowed,message=Game.CanDepart()
    check(not allowed and message==later.message,"legacy CanDepart diverged from structured status")
    check(Game.GetAnnouncementState().lastArrival==3,"announcement snapshot lost station")
    -- Front clears by actual motion; Game can then depart without changing trailing AI.
    for _=1,10000 do
        Traffic.Update(.02);Game.Update(.02)
        if not Game.IsDwelling() then break end
    end
    check(not Game.IsDwelling() and not Game.GetDepartureStatus().blocked,"Game remains blocked after actual route clears")
    check(Game.GetDepartureStatus().waitSeconds==0,"ready status retained stale waiting timer")
end

function Start()
    local ok,message=xpcall(function()
        test("station_stop_follower_circular_wait",followingTrainChecks)
        test("reverse_and_parallel_tracks",reverseChecks)
        test("real_front_and_shared_throat",frontAndThroatChecks)
        test("forward_passing_actual_tail",function() passingChecks(false,false) end)
        test("reverse_passing_actual_tail",function() passingChecks(true,false) end)
        test("queued_passing_safe_remote_dispatch",function() passingChecks(false,true) end)
        test("same_track_opposing_never_timeout_green",opposingSameTrackChecks)
        test("unspawnable_passing_no_fake_completion",cancellationChecks)
        test("game_reason_wait_pause_and_release",gameStatusChecks)
        print(string.format("[TrafficDeparture] ALL_PASS %d",passed))
    end,debug.traceback)
    Traffic.Shutdown()
    if not ok then log:Write(LOG_ERROR,tostring(message)) end
    -- Validate mode writes its report only after the configured frame budget.
end
