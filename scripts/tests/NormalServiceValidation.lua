-- 独立 CPU 业务回归：基于 PassengerTimingValidation、TimetableValidation，
-- 结合 FictionalRailValidation 的短距离真实牵引到站脚手架。
-- 运行：.cli/UrhoXRuntime tests/NormalServiceValidation.lua -tapcode_dir=/workspace
--      -tool_mode -graphicsheadless -validate -validate-frames=2 -validate-timeout=110
-- 不加载 main/SaveStore/云，不写文件、不截图、不初始化 UI/音频，不替换业务模块。
-- 长区间使用内存 Train 检查点跳过巡航；牵引、CheckArrival、真实车门几何、
-- 逐人步行、奖励结算与时刻表均调用生产实现。
local Modes=require "config.GameModes"
local Config=require "config.GameConfig"
local World=require "config.FictionalWorld"
local Route=require "world.Route"
local Rail=require "world.RailNetwork"
local Train=require "train.Train"
local Traffic=require "game.Traffic"
local Passenger=require "game.PassengerService"
-- Timetable 同时导出实例形状与静态校验入口，此处只标注静态边界，
-- 不替换、不包装生产模块的运行逻辑。
---@class NormalServiceTimetableApi
---@field Validate fun(saved:table,stations:RailwayStation[]):boolean,string
local Timetable=require("game.Timetable") --[[@as NormalServiceTimetableApi]]
local Game=require "game.Game"
local Environment=require "world.Environment"

---@type Scene?
local scene_=nil
local checks_,cases_,ticks_=0,0,0
local maxStation_,maxDestination_=0,0
local localStops_,expressStops_={},{}
local DT=.5

local function check(value,message)
    checks_=checks_+1
    assert(value,"[NormalService] "..message)
end
local function near(a,b,message)
    check(a==a and b==b and math.abs(a-b)<.00001,message..": "..tostring(a).." / "..tostring(b))
end
local function pass(label)
    cases_=cases_+1
    print("NORMAL_SERVICE_CASE_PASS "..label)
end
local function clone(value) return cjson.decode(cjson.encode(value)) end
local function sequence(actual,expected,label)
    check(#actual==#expected,label.." length "..#actual.." / "..#expected)
    for i,value in ipairs(expected) do check(actual[i]==value,label.." index "..i) end
end
local function indices(first,last)
    local result={}
    for i=first,last,first>last and -1 or 1 do result[#result+1]=i end
    return result
end
local function validIndex(index,label)
    check(type(index)=="number" and index%1==0 and index>=1 and index<=10,label.." out of bounds: "..tostring(index))
    check(Route.GetStations()[index]~=nil,label.." missing route record")
end

-- 检查生产导出的全部客流记录，包括下车后仍保留的离站人物。
-- actor/onboard 两个清单可共享同一人物 ID，但各清单内部不能重复。
local function auditPassengers(label)
    local saved=Passenger.ExportState()
    local stats=Passenger.GetStats()
    check(saved.geometryMode==Route.GetGeometryMode(),label.." wrong geometry mode")
    near(stats.boarded-stats.alighted,stats.onboard,label.." passenger conservation")
    check(stats.onboard>=0 and stats.onboard<=Passenger.GetCapacity(),label.." capacity overflow")
    for _,people in ipairs({saved.actors,saved.onboard}) do
        local seen={}
        for _,actor in ipairs(people) do
            check(actor.id>0 and actor.id<=saved.nextId and not seen[actor.id],label.." duplicate/invalid passenger id")
            seen[actor.id]=true
            validIndex(actor.destination,label.." passenger destination")
            maxDestination_=math.max(maxDestination_,actor.destination)
            check(actor.targetIndex>=1 and actor.targetIndex<=#actor.targets+1,label.." path cursor out of bounds")
            check(#actor.position==3 and actor.position[1]==actor.position[1],label.." invalid passenger position")
        end
    end
    if saved.stop then
        validIndex(saved.stop.stationIndex,label.." stop station")
        maxStation_=math.max(maxStation_,saved.stop.stationIndex)
        local doors=Passenger.GetDoorPlan()
        check(doors.valid and doors.stationIndex==saved.stop.stationIndex and #doors.doors>0,label.." invalid real door plan")
        for _,actor in ipairs(saved.actors) do
            if not actor.completed and actor.state~="leaving" and actor.state~="gone" then
                check(actor.doorId>=1 and actor.doorId<=#doors.doors,label.." door index out of bounds")
            end
        end
        local seen={}
        for _,index in ipairs(saved.stop.destinations) do
            validIndex(index,label.." stop destination")
            check(not seen[index],label.." duplicate stop destination")
            seen[index]=true
        end
        check(saved.stop.boarded<=saved.stop.totalBoarding and saved.stop.alighted<=saved.stop.totalAlighting,
            label.." completion exceeds demand")
    end
    return saved
end

---@return TimetableRow[]
local function activeRows()
    local status=assert(Game.GetTimetableStatus(),"normal timetable absent")
    local rows={} ---@type TimetableRow[]
    for _,row in ipairs(status.rows) do
        validIndex(row.stationIndex,"timetable station")
        local station=assert(Route.GetStations()[row.stationIndex])
        near(row.s,station.s,"timetable route kilometre")
        check(row.name==station.name,"timetable name differs from route")
        if row.trip==status.trip and row.phase~="cancelled" then rows[#rows+1]=row end
    end
    local saved=Game.ExportState()
    local valid,message=Timetable.Validate(assert(saved.timetable),Route.GetStations())
    check(valid,"real Game timetable rejected: "..tostring(message))
    for _,index in ipairs(saved.rewarded) do validIndex(index,"reward station") end
    if saved.nextIndex then validIndex(saved.nextIndex,"Game next station") end
    if saved.lastArrival then validIndex(saved.lastArrival,"Game last arrival") end
    return rows
end
local function checkPlan(expected,label)
    local actual={}
    local previous=-math.huge
    local rows=activeRows()
    for _,row in ipairs(rows) do
        actual[#actual+1]=row.stationIndex
        local arrival=assert(row.plannedArrival or row.plannedDeparture,label.." missing plan time")
        check(arrival>=previous,label.." nonmonotone plan")
        previous=row.plannedDeparture or arrival
    end
    sequence(actual,expected,label)
    check(rows[#rows].terminal and rows[#rows].plannedDeparture==nil,label.." terminal has departure")
    return rows
end
local function rowFor(index,trip)
    for _,row in ipairs(activeRows()) do
        if row.stationIndex==index and (not trip or row.trip==trip) then return row end
    end
    error("[NormalService] missing active timetable row "..index)
end

local function step()
    Game.EnforceDepartureInterlock()
    Traffic.Update(DT)
    Train.Update(DT)
    Traffic.CheckPlayerCollision()
    Environment.Advance(DT)
    Game.Update(DT)
    ticks_=ticks_+1
    check(not Train.IsDerailed(),"unexpected collision/derailment at s="..Train.GetS())
end

local function setup(service)
    Traffic.Shutdown()
    Train.Reset(assert(Route.GetStations()[1]).s+1)
    -- nil 是生产 Traffic 的纯逻辑模式，不创建交通视觉资源，也不伪造交通模块。
    Traffic.Init(nil)
    Game.Init()
    if service~="local" then check(Game.SetService(service),"cannot select "..service) end
    check(Game.IsDwelling() and Passenger.GetStatus().stationIndex==1,"origin did not start real boarding")
end

-- 每个目标站都必须有生产生成的真实候车人，不由测试拼造乘客清单。
local function checkDestinations(expected,label)
    local saved=auditPassengers(label)
    local stop=assert(saved.stop)
    sequence(stop.destinations,expected,label.." destination list")
    local allowed,seen={},{}
    for _,index in ipairs(expected) do allowed[index]=true end
    for _,actor in ipairs(saved.actors) do
        if actor.kind=="boarding" then
            check(allowed[actor.destination],label.." boarding passenger assigned skipped/backward station")
            seen[actor.destination]=true
        end
    end
    for _,rider in ipairs(saved.onboard) do
        if rider.kind~="alighting" then check(allowed[rider.destination],label.." onboard passenger assigned skipped/backward station") end
    end
    for _,index in ipairs(expected) do check(seen[index],label.." no real passenger for destination "..index) end
end

local function finishStop(label,terminal,roundtrip)
    local initial=Passenger.GetStatus()
    local stats=Passenger.GetStats()
    local lastPhase=initial.phase
    local usedPhases={[lastPhase]=true}
    local elapsed=0.0
    local restored=false
    for tick=1,6000 do
        step();elapsed=elapsed+DT
        local status=Passenger.GetStatus()
        usedPhases[status.phase]=true
        if status.phase~=lastPhase or tick%20==0 then auditPassengers(label);lastPhase=status.phase end
        if roundtrip and tick==5 then
            local before=auditPassengers(label.." before in-memory roundtrip")
            Passenger.RestoreState(clone(before))
            local after=auditPassengers(label.." after in-memory roundtrip")
            for _,key in ipairs({"nextId","visits","boarded","alighted"}) do
                check(before[key]==after[key],label.." JSON roundtrip changed counter "..key)
            end
            check(#before.actors==#after.actors and #before.onboard==#after.onboard,label.." JSON roundtrip lost people")
            for i,actor in ipairs(before.actors) do
                local retained=assert(after.actors[i])
                for _,key in ipairs({"id","kind","state","destination","doorId","targetIndex","completed"}) do
                    check(actor[key]==retained[key],label.." JSON roundtrip changed passenger "..key)
                end
                near(actor.walkDistance,retained.walkDistance,label.." JSON roundtrip changed walking progress")
                for axis=1,3 do near(actor.position[axis],retained.position[axis],label.." JSON roundtrip moved passenger") end
            end
            restored=true
        end
        if terminal and Game.IsTerminal() then break end
        if not terminal and not Game.IsDwelling() then break end
        check(tick<6000,label.." failed to finish in 600 simulated seconds: "..Game.GetDepartureStatus().message)
    end
    local final=Passenger.GetStats()
    near(final.boarded-stats.boarded,initial.totalBoarding-initial.boarded,label.." boarding count mismatch")
    near(final.alighted-stats.alighted,initial.totalAlighting-initial.alighted,label.." alighting count mismatch")
    check(usedPhases.door_closing,label.." skipped real door close phase")
    check(not roundtrip or restored,label.." roundtrip not exercised")
    check(Passenger.IsReady(),label.." not passenger-ready")
    if terminal then
        check(Game.IsTerminal() and Passenger.HasActiveStop(),label.." terminal stop lost")
        check(final.onboard==0,label.." terminal retained passengers")
    else check(not Game.IsDwelling() and not Passenger.HasActiveStop(),label.." departure did not finish stop") end
    auditPassengers(label.." completed")
    print(string.format("NORMAL_SERVICE_STOP_PASS %s station=%d alight=%d board=%d onboard=%d simulatedSeconds=%.1f",
        label,initial.stationIndex,initial.totalAlighting,initial.totalBoarding,final.onboard,elapsed))
end

local function departPhysically(index)
    local beforeS=Train.GetS()
    local reverse=Train.IsReversing()
    check(rowFor(index).actualDeparture==nil,"permission alone fabricated actual departure")
    Train.SetBrake(0)
    for _=1,8 do Game.ThrottleUp() end
    for tick=1,200 do
        step()
        if math.abs(Train.GetS()-beforeS)>4 and math.abs(Train.GetSpeedMs())>.02 then break end
        check(tick<200,"real traction failed to depart "..index)
    end
    check((Train.GetS()-beforeS)*(reverse and -1 or 1)>4,"traction went in wrong direction")
    check(rowFor(index).actualDeparture~=nil,"real displacement did not record departure")
    Train.EmergencyBrake()
    for tick=1,200 do
        step()
        if math.abs(Train.GetSpeedMs())<=.02 then break end
        check(tick<200,"could not stop for checkpoint fixture")
    end
end

local function approach(index)
    local station=assert(Route.GetStations()[index])
    check(assert(Game.GetNextStation()).index==index,"Game selected wrong next stop "..index)
    check(not Passenger.HasActiveStop(),"approach attempted with unfinished queue")
    -- 仅跳过长区间巡航：保留真实清单、累计距离、方向/拓扑及 Game/Timetable
    -- 状态；不伪造 moving=true，必须再次由真实牵引产生有效到站。
    local positioned=Train.ExportState()
    positioned.s=station.s+(Train.IsReversing() and 80 or -80)
    positioned.v,positioned.throttle,positioned.brake,positioned.moving=0,0,1,false
    Train.RestoreState(positioned)
    Traffic.Reset(Train.GetS())
    local startS,startDistance=Train.GetS(),Train.GetDistanceTravelled()
    for tick=1,2400 do
        local distance=(Train.IsReversing() and -1 or 1)*(station.s-Train.GetS())
        local speed=math.abs(Train.GetSpeedMs())
        if distance<.5 then Train.EmergencyBrake()
        else
            local desired=math.min(5,math.sqrt(.8*math.max(0,distance-2)))
            if speed>desired+.12 then Train.SetThrottle(0);Train.SetBrake(.5)
            elseif speed<desired-.12 then Train.SetBrake(0);Train.SetThrottle(4)
            else Train.SetThrottle(0);Train.SetBrake(0) end
        end
        step()
        if Game.IsDwelling() then break end
        check(tick<2400,"real short approach failed at "..index)
    end
    check(Game.IsDwelling() and Passenger.GetStatus().stationIndex==index,"CheckArrival did not produce stop "..index)
    check(math.abs(Train.GetS()-startS)>50 and Train.GetDistanceTravelled()-startDistance>50,
        "arrival not preceded by real Train physics travel")
    check(rowFor(index).actualArrival~=nil,"CheckArrival missing timetable actual "..index)
    near(rowFor(index).actualArrival,Environment.GetClock().minutes,"arrival clock ownership")
    check(rowFor(index).actualDeparture==nil,"arrival fabricated departure "..index)
    auditPassengers("arrival "..index)
end

local function configurationChecks()
    local normal=Modes.Apply("normal")
    Route.Build()
    check(normal.routeId=="normal_corridor_v2","wrong normal map version")
    near(Route.GetLength(),88857.86374650331,"normal route final length")
    check(#World.stations==10 and #Route.GetStations()==10,"world/route must have ten station records")
    local anchors={829.6644337142133,7016.646862858715,16719.842272904632,23162.909963010643,31859.114254625787}
    local names={"星汐总站","岚港站","榆岑站","镜澜站","云湾总站","翠川站","石门站","云脊站","松岚站","天池总站"}
    for index,station in ipairs(Route.GetStations()) do
        check(station.index==index and station.name==names[index] and station.id==assert(World.stations[index]).id,
            "station identity/index mismatch "..index)
        if anchors[index] then near(station.s,anchors[index],"legacy station shifted "..index) end
        check(station.s>0 and station.s<Route.GetLength(),"station outside open route")
    end
    near(Config.MountainTerrain.First,33186.57734856853,"legacy prefix length")
    Modes.Apply("rage");Route.Build()
    check(#Route.GetStations()==5 and #World.stations==10,"ten world records polluted independent five-station rage map")
    Modes.Apply("normal");Route.Build()
    near(Route.GetLength(),88857.86374650331,"switch-back changed normal length")
    pass("normal_v2_exact_length_legacy_five_anchors_world10_rage5")
end

local function localJourney()
    setup("local")
    checkPlan(indices(1,10),"local outbound ten-stop timetable")
    checkDestinations(indices(2,10),"origin all nine destinations")
    local origin=Passenger.GetStatus()
    check(origin.totalBoarding>0 and origin.totalAlighting==0,"origin missing real passengers")
    near(Train.GetServiceDeceleration(true),Train.GetServiceDeceleration(),"old flat prefix braking hint changed")
    finishStop("local_origin",false,false)
    check(Game.GetXp()==0,"origin boarding received arrival reward")
    localStops_[1]=1
    for index=2,10 do
        departPhysically(index-1)
        approach(index)
        localStops_[#localStops_+1]=index
        local status=Passenger.GetStatus()
        check(status.totalAlighting>0,"no real destination passengers alight at "..index)
        if index<10 then
            check(status.totalBoarding>0,"new intermediate station has no boarding "..index)
            checkDestinations(indices(index+1,10),"local station "..index)
        else
            check(status.totalBoarding==0,"station 10 terminal illegally boards before reversing")
            checkDestinations({},"terminal station 10")
        end
        if index==6 then
            check(Train.GetServiceDeceleration(true)>0 and Train.GetServiceDeceleration(true)<Train.GetServiceDeceleration(),
                "mountain braking hint not downhill-safe")
        end
        local xp=Game.GetXp()
        finishStop("local_"..index,index==10,index==6)
        check(Game.GetXp()>xp,"real passenger stop got no reward "..index)
        check(Game.GetOperatingStats().rewards==index-1,"arrival reward count does not match completed real stops")
    end
    sequence(localStops_,indices(1,10),"actual local stop order")
    check(Game.GetNextStation()==nil and not Game.CanDepart(),"station 10 terminal wraps/permits departure")
    local outbound=rowFor(10)
    check(outbound.terminal and outbound.actualArrival~=nil and outbound.actualDeparture==nil,"terminal actual record invalid")
    check(Game.GetOperatingStats().completedTrips==1,"ten-stop real trip not completed")
    local xp,journey=Game.GetXp(),Game.GetOperatingStats().journeyId
    for _=1,10 do step() end
    check(Game.GetXp()==xp and Game.GetOperatingStats().completedTrips==1,"terminal idle repeats reward/completion")
    local reversed,allowed,message=Train.ToggleReversing()
    -- 真实交通可能占用端站渡线；只推进生产交通并等待，不跳过安全校验。
    for retry=1,240 do
        if allowed then break end
        for _=1,10 do step() end
        reversed,allowed,message=Train.ToggleReversing()
        check(retry<240 or allowed,"terminal turnback blocked after real traffic wait: "..tostring(message))
    end
    check(reversed and allowed,"real terminal turnback rejected: "..tostring(message))
    step()
    check(not Game.IsTerminal() and Game.IsDwelling() and not Game.CanDepart(),"return skipped new boarding")
    check(Game.GetOperatingStats().journeyId==journey+1,"return did not start one new trip")
    checkDestinations(indices(9,1),"return origin reverse destinations")
    local rows=checkPlan(indices(10,1),"return ten-stop timetable")
    check(assert(rows[1]).origin and assert(rows[1]).actualArrival==nil,"return origin fabricates arrival")
    check(Passenger.GetStatus().totalBoarding>0,"return origin missing new passengers")
    finishStop("return_origin_10",false,false)
    check(Game.GetXp()==xp,"return origin rewarded station 10 again")
    check(assert(Game.GetNextStation()).index==9,"return station is not 9")
    departPhysically(10)
    approach(9)
    checkDestinations(indices(8,1),"return station 9")
    check(Passenger.GetStatus().totalAlighting>0,"return station 9 has no real alighting")
    finishStop("return_9",false,false)
    check(Game.GetXp()>xp and Game.GetOperatingStats().completedTrips==1,"return station 9 reward/trip counter wrong")
    check(assert(Game.GetNextStation()).index==8,"return station 9 did not select station 8")
    checkPlan(indices(10,1),"return timetable preserved after station 9")
    print(string.format("NORMAL_SERVICE_LOCAL_PASS outbound=1,2,3,4,5,6,7,8,9,10 return=10,9 completedTrips=%d rewards=%d maxStation=%d maxDestination=%d",
        Game.GetOperatingStats().completedTrips,Game.GetOperatingStats().rewards,maxStation_,maxDestination_))
    pass("real_local_ten_stops_terminal10_return9_manifest_indices_and_memory_roundtrip")
end

local function expressJourney()
    setup("express")
    local rows=checkPlan({1,3,10},"express three-stop timetable")
    check(assert(rows[1]).origin and assert(rows[1]).actualArrival==nil,"express origin invalid")
    checkDestinations({3,10},"express origin")
    finishStop("express_origin",false,false)
    expressStops_[1]=1
    departPhysically(1)
    -- 复用已经真实移动过的 Train 检查点；快速任务在站 2 停稳时不能触发
    -- 普通客流队列或伪造实际到站记录。
    local skipped=Train.ExportState()
    skipped.s=assert(Route.GetStations()[2]).s
    Train.RestoreState(skipped);Traffic.Reset(Train.GetS());step()
    check(not Game.IsDwelling() and not Passenger.HasActiveStop(),"express illegally stopped at station 2")
    check(assert(Game.GetNextStation()).index==3,"express skipped wrong next station")
    for _,index in ipairs({3,10}) do
        approach(index)
        expressStops_[#expressStops_+1]=index
        checkDestinations(index==3 and {10} or {},"express station "..index)
        check(Passenger.GetStatus().totalAlighting>0,"express required stop missing alighters")
        check(index==10 and Passenger.GetStatus().totalBoarding==0 or index==3 and Passenger.GetStatus().totalBoarding>0,
            "express terminal/intermediate boarding")
        finishStop("express_"..index,index==10,false)
        if index==3 then
            check(assert(Game.GetNextStation()).index==10,"express still uses old station 5 terminal")
            departPhysically(3)
        end
    end
    sequence(expressStops_,{1,3,10},"actual express stop order")
    rows=checkPlan({1,3,10},"express final timetable")
    for _,row in ipairs(rows) do
        if row.stationIndex~=1 then check(row.actualArrival~=nil,"express missing actual arrival") end
        if not row.terminal then check(row.actualDeparture~=nil,"express missing actual departure") end
    end
    check(Game.IsTerminal() and Passenger.GetStats().onboard==0,"express did not terminate at 10")
    print("NORMAL_SERVICE_EXPRESS_PASS gameStops=1,3,10 timetableStops=1,3,10 skippedStation2=true")
    pass("real_express_game_passenger_timetable_three_stop_consistency")
end

local function passingChecks()
    setup("passing")
    checkPlan(indices(1,10),"passing is still all-stop timetable")
    checkDestinations(indices(2,10),"passing destinations")
    check(Game.GetObjective():find(assert(Route.GetStations()[3]).name,1,true)~=nil,"passing target moved away from station 3")
    local third=Traffic.GetDepartureStatus(3)
    check(third.passingPhase~=nil,"real Traffic did not schedule passing at station 3")
    for _,index in ipairs({2,5,6,10}) do
        check(Traffic.GetDepartureStatus(index).passingPhase==nil,"passing task attached to wrong station "..index)
    end
    local choices=Rail.GetChoices()
    check(choices[3] and choices[3].lane==2,"production Game did not preselect station 3 siding")
    check(Game.GetService()=="passing","passing service not committed")
    pass("passing_remains_station3_with_ten_stop_timetable")
end

function Start()
    local started=os.clock()
    local ok,message=xpcall(function()
        configurationChecks()
        check(Environment.Init(nil,nil,{visuals=false,hour=12,running=true}),"clock initialization failed")
        scene_=Scene();scene_:CreateComponent("Octree")
        Train.Build(scene_)
        Passenger.Init(scene_)
        local section="all"
        for _,argument in ipairs(GetArguments()) do section=argument:match("^%-normal%-service=(.+)$") or section end
        check(section=="all" or section=="local" or section=="express" or section=="passing","unknown regression section")
        if section=="all" or section=="local" then localJourney() end
        if section=="all" or section=="express" then expressJourney() end
        if section=="all" or section=="passing" then passingChecks() end
        check(maxStation_==10 and maxDestination_==10 or section=="passing","extended station/destination coverage absent")
        print(string.format("NORMAL_SERVICE_SECTION_PASS section=%s checks=%d cases=%d",section,checks_,cases_))
        print(string.format("%s checks=%d cases=%d physicsTicks=%d cpuSeconds=%.3f routeLength=%.11f maxStation=%d maxDestination=%d",
            section=="all" and "ALL_NORMAL_SERVICE_VALIDATION_PASS" or ("NORMAL_SERVICE_VALIDATION_PASS section="..section),
            checks_,cases_,ticks_,os.clock()-started,Route.GetLength(),maxStation_,maxDestination_))
        print("NORMAL_SERVICE_SCOPE CPU business only; dt=0.5s (not production fixed-step physics certification); long cruise checkpointed; GPU/real-player-save/cloud/audio-listening NOT_RUN; new five station voiceovers are known subtitle/chime fallback, not a failure")
    end,debug.traceback)
    Passenger.Shutdown();Traffic.Shutdown();Train.Shutdown();Environment.Destroy()
    if scene_ then scene_:Dispose();scene_=nil end
    if not ok then
        print("NORMAL_SERVICE_VALIDATION_FAIL "..tostring(message))
        log:Write(LOG_ERROR,tostring(message))
    end
    engine:Exit()
end
