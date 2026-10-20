-- 实际中国左行拓扑/渡线/真实MDL/客流门计划回归；独立入口，不读写设备存档或云。
local Route=require "world.Route"
local Rail=require "world.RailNetwork"
local Track=require "world.Track"
local Station=require "world.Station"
local Yard=require "world.StationYard"
local Train=require "train.Train"
local Passenger=require "game.PassengerService"
local Traffic=require "game.Traffic"
local Catalog=require "config.TrainCatalog"
---@type Scene?
local scene_=nil
local checks_=0
local function check(value,message)
    checks_=checks_+1
    assert(value,"[ChineseTopology] "..message)
end
local function near(a,b,eps) return math.abs(a-b)<(eps or .0001) end
local function lateral(pos,s) return (pos-Route.Sample(s)):DotProduct(Route.RightAt(s)) end
local function turnbackChecks()
    local stations=Route.GetStations()
    local last=stations[#stations]
    local length=Train.GetActiveLength()
    Train.Reset(last.s)
    local before={}
    for i,p in ipairs(Train.GetCarPositions()) do before[i]=p end
    check(Train.ToggleReversing(),"last station reverse denied")
    Train.UpdateVisuals(0)
    for i,p in ipairs(Train.GetCarPositions()) do check((p-before[i]):Length()<.0001,"direction change teleported a car") end
    local cross=assert(Rail.GetTurnback())
    check(cross.lane==3 and cross.toLane==1,"return crossover topology")
    local previous=Train.GetTrackSample(last.s)
    local sawMid=false
    for s=last.s-.5,cross.first-length-30,-.5 do
        local current=Train.GetTrackSample(s)
        check((current-previous):Length()<.52,"crossover path discontinuity")
        local lat=lateral(current,s)
        if lat>.5 and lat<4.5 then sawMid=true end
        previous=current
    end
    check(sawMid,"return was a lane teleport, not a continuous crossover")
    local saved=Train.ExportState()
    Train.RestoreState(saved)
    check(Rail.GetTurnback() and Rail.GetTurnback().lane==3,"active turnback not saved")
    Rail.UpdatePlayer(cross.first-30,length,true)
    check(Rail.GetBaseLane()==1 and not Rail.GetTurnback(),"tail clearance failed to settle onto up line")
    check(Rail.GetPlayerLane(stations[3].s)==1,"return uses wrong same track")
    local first=stations[1]
    Rail.UpdatePlayer(first.s,length,true)
    local ok=Rail.RequestDirectionChange(first.s,length,false)
    check(ok,"first terminal outbound reverse denied")
    local east=assert(Rail.GetTurnback())
    local prev=Rail.Sample(east.first,4)
    for s=east.first+.5,east.last,.5 do
        local p=Rail.Sample(s,4)
        check((p-prev):Length()<.52,"outbound crossover discontinuity")
        prev=p
    end
    Rail.UpdatePlayer(east.last+length+10,length,false)
    check(Rail.GetBaseLane()==0 and not Rail.GetTurnback(),"outbound clear did not settle main")
    Rail.Reset(stations[3].s,length,false)
    check(not Rail.RequestDirectionChange(stations[3].s,length,true),"midline wrong-way reverse permitted")
end
local function doorChecks()
    local st=Route.GetStations()[3]
    local bindings=0
    for _,entry in ipairs(Catalog.Entries) do
        check(Train.Select(entry.id),"cannot select actual fleet "..entry.id)
        Train.Reset(st.s)
        local valid=Train.ValidateBindings()
        check(valid,"actual eight MDL bindings lost "..entry.id)
        bindings=bindings+#Train.GetCars()
        for _,lane in ipairs({0,1,2}) do
            Rail.Reset(st.s,Train.GetActiveLength(),lane==1)
            if lane==2 then
                Rail.Reset(0,Train.GetActiveLength(),false)
                check(Rail.SetStationChoice(3,2,0,Train.GetActiveLength()),"cannot preselect siding")
                Rail.UpdatePlayer(st.s,Train.GetActiveLength(),false)
            end
            local plan=Passenger.BuildDoorPlan(st)
            check(plan.valid,"door plan invalid "..entry.id.." lane"..lane.." "..plan.reason)
            if entry.kind~="emu" then
                check(#plan.doors==14,"four locomotive sets must retain 14 simulated coach doors")
                for _,door in ipairs(plan.doors) do
                    check(door.carIndex>1 and door.source=="simulated_coach_end_vestibule","locomotive exposed as passenger door")
                end
            end
            for _,door in ipairs(plan.doors) do
                local edge=lateral(door.edge,door.s)
                check(edge>=plan.platformMin-.01 and edge<=plan.platformMax+.01,"door crosses another track")
                check(door.side==(lane==0 and -1 or 1),"wrong platform door side")
            end
        end
    end
    check(bindings==48,"expected 48 actual MDL bindings")
    print("[ChineseTopology] actualFleetBindings="..bindings)
end
local function trafficChecks()
    local st=Route.GetStations()[3]
    Train.Reset(st.s)
    Rail.Reset(st.s,Train.GetActiveLength(),false)
    Traffic.Init(nil)
    for _,t in ipairs(Traffic.GetTrains()) do
        if t.active then check(t.lane==(t.dir>0 and 0 or 1),"AI wrong normal running track") end
    end
    check(Traffic.GetBlockSignalAspect(st.s,0,-1)=="red","unreserved wrong-direction green")
    check(Traffic.GetBlockSignalAspect(st.s,1,1)=="red","up opposite direction green")
    check(Traffic.GetBlockSignalAspect(st.s,99,1)=="red","unknown lane not red")
    check(Traffic.GetBlockSignalAspect(-1,0,1)=="red","unknown position not red")
    check(Traffic.GetBlockSignalAspect(st.s-800,0,1)=="red","occupied player block not red")
    check(Traffic.GetBlockSignalAspect(st.s-800,1,-1)~="red","separate up block incorrectly inherits main red")
    local before=Traffic.GetTrains()
    for _=1,20 do Traffic.GetBlockSignalAspect(st.s,0,1) end
    local after=Traffic.GetTrains()
    check(before[1].headS==after[1].headS,"signal getter advances AI")
    Traffic.Shutdown()
end
local function crossoverBlockChecks()
    local last=Route.GetStations()[#Route.GetStations()]
    Train.Reset(last.s)
    check(Train.ToggleReversing(),"crossover occupancy fixture turnback denied")
    local cross=assert(Rail.GetTurnback())
    Traffic.Init(nil);Traffic.Reset(0)
    local saved=Train.ExportState()
    saved.s=cross.first+120;saved.v=0
    Train.RestoreState(saved)
    check(Rail.GetPlayerLane(saved.s)==3 and Rail.GetPlayerLane(saved.s-Train.GetActiveLength())==1,
        "fixture does not straddle crossover/up end")
    check(Traffic.GetBlockSignalAspect(cross.first+10,0,1)=="red",
        "main block missed train end while most of its envelope was on up side")
    saved.s=cross.last+50
    Train.RestoreState(saved)
    check(Rail.GetPlayerLane(saved.s)==0 and Rail.GetPlayerLane(saved.s-Train.GetActiveLength())==3,
        "fixture does not straddle old-main/crossover end")
    check(Traffic.GetBlockSignalAspect(cross.last+150,1,-1)=="red",
        "up block missed crossover end while envelope midpoint was on main")
    Traffic.Shutdown();Train.Reset(Route.GetStations()[1].s)
    print("[ChineseTopology] CROSSOVER_BOTH_BLOCKS_OCCUPIED_PASS")
end
local function reservationChecks()
    local stations=Route.GetStations()
    local last=stations[#stations]
    Train.Reset(last.s)
    Traffic.Init(nil);Traffic.Reset(last.s-1300)
    local before=Traffic.GetTrains()
    local reverse,changed=Train.ToggleReversing()
    check(not reverse and not changed and not Rail.GetTurnback(),"occupied up terminal route accepted")
    local after=Traffic.GetTrains()
    for i,t in ipairs(before) do check(t.headS==after[i].headS and t.active==after[i].active,
        "rejected turnback cleared AI by teleport/despawn") end
    Traffic.Shutdown()
    local first=stations[1]
    Train.Reset(first.s)
    local saved=Train.ExportState();saved.reversing=true;saved.topology={mode=Rail.GetTopologyMode(),baseLane=1}
    Train.RestoreState(saved)
    Traffic.Init(nil);Traffic.Reset(0)
    local stillReverse,stillChanged=Train.ToggleReversing()
    check(stillReverse and not stillChanged and not Rail.GetTurnback(),"occupied first-terminal crossing accepted")
    Traffic.Shutdown()
    Train.Reset(Route.GetLength()*.81)
    local resumed=Train.ExportState();resumed.reversing=true;resumed.topology={mode=Rail.GetTopologyMode(),baseLane=1}
    Train.RestoreState(resumed);Traffic.Init(nil)
    local playerLo,playerHi=Train.GetS()-Train.GetActiveLength(),Train.GetS()+16
    for _,t in ipairs(Traffic.GetTrains()) do
        check(not(t.active and t.lane==1 and t.hi+80>=playerLo and t.lo-80<=playerHi),
            "resumed up-line saved train overlaps newly spawned T05")
    end
    Traffic.Shutdown();Train.Reset(first.s)
    print("[ChineseTopology] OCCUPIED_TERMINAL_RESERVATION_PASS")
end
-- 旧圆曲线脚点/目标先按里程迁移，再迁移旧正岛台；不接触SaveStore或云。
local function passengerMigrationChecks()
    local Alignment=require "world.RailwayAlignment"
    local Config=require "config.GameConfig"
    local old=Alignment.FromSegments(Config.RouteSegments,{
        start=Config.RouteStart or Vector3.ZERO,startYaw=Config.RouteStartYaw or 0,
        pointStep=Config.RouteStep or 10})
    local st=Route.GetStations()[3]
    Train.Reset(st.s);Passenger.Reset()
    local function packed(id,s,lat)
        local p=old:SampleOffset(s,lat,1.5)
        local target=old:SampleOffset(s+20,lat+1,1.5)
        return {id=id,appearance=1,kind="boarding",state="queued",position={p.x,p.y,p.z},
            yaw=12,visible=true,walking=true,walkDistance=12.3,destination=4,
            doorId="saved-door",completed=false,speed=1.2,targets={{target.x,target.y,target.z}},targetIndex=1}
    end
    local data=Passenger.ExportState()
    data.topologyMode,data.geometryMode=nil,nil
    data.actors={packed(11,st.s,4.5)}
    data.onboard={packed(12,st.s+30,6)}
    data.nextId,data.visits,data.boarded,data.alighted=20,7,17,9
    Passenger.RestoreState(data)
    local restored=Passenger.ExportState()
    local actor=restored.actors[1]
    local rider=restored.onboard[1]
    check(actor.id==11 and rider.id==12 and restored.nextId==20,"legacy passenger identities lost")
    check(restored.visits==7 and restored.boarded==17 and restored.alighted==9,"legacy partial counters reset")
    check(actor.targetIndex==1 and actor.walkDistance==12.3 and not actor.completed,"legacy walking progress reset")
    local function pos(v) return Vector3(v[1],v[2],v[3]) end
    check((pos(actor.position)-Route.SampleOffset(st.s,-4.5,1.5)):Length()<.15,"old feet not geometry/topology migrated")
    check((pos(actor.targets[1])-Route.SampleOffset(st.s+20,-5.5,1.5)):Length()<.15,"old path target not migrated")
    check((pos(rider.position)-Route.SampleOffset(st.s+30,-6,1.5)):Length()<.15,"independent onboard actor not migrated")
    Passenger.RestoreState(restored)
    local roundtrip=Passenger.ExportState()
    check((pos(roundtrip.actors[1].position)-pos(actor.position)):Length()<.0001,"new save migrated twice")
    check(roundtrip.boarded==17 and roundtrip.onboard[1].id==12,"new save lost partial queue")
    -- 已有左行拓扑、尚未有geometryMode的中间存档只迁移XZ，不能再次换边。
    local geometryOnly=Passenger.ExportState()
    geometryOnly.geometryMode=nil
    geometryOnly.actors={packed(13,st.s,-5.4)};geometryOnly.onboard={}
    Passenger.RestoreState(geometryOnly)
    check((pos(Passenger.ExportState().actors[1].position)-Route.SampleOffset(st.s,-5.4,1.5)):Length()<.15,
        "missing geometry mode with current topology was not migrated independently")
    local invalid=Passenger.ExportState();invalid.topologyMode="unknown_future_topology"
    check(not pcall(Passenger.RestoreState,invalid),"unknown topology silently accepted")
    check(Passenger.ExportState().actors[1].id==13,"rejected migration overwrote live passenger progress")
    Passenger.Reset()
    print("[ChineseTopology] LEGACY_PASSENGER_MIGRATION_PASS")
end
local function legacyReverseDoorChecks()
    local st=Route.GetStations()[3]
    Train.Reset(st.s)
    local train=Train.ExportState();train.reversing=true;train.topology={mode=Rail.GetTopologyMode(),baseLane=1}
    Train.RestoreState(train)
    local plan=Passenger.BuildDoorPlan(st)
    local door=plan.doors[1]
    local width=lateral(door.position,door.s)-5
    local function pack(p) return {p.x,p.y,p.z} end
    for _,oldLane in ipairs({0,2}) do
        Passenger.Reset()
        local side=oldLane==0 and 1 or -1
        local center=oldLane==0 and 0 or 10.8
        local oldDoor=center+side*width
        local oldEdge=oldLane==0 and 1.9 or 8.9
        local oldClear=oldEdge+side*1.8
        local oldInside=oldDoor-side*.75
        local anchors={oldClear,oldEdge,oldDoor,oldInside}
        local targets={}
        for _,lat in ipairs(anchors) do targets[#targets+1]=pack(Route.SampleOffset(door.s,lat,door.edge.y-Route.Sample(door.s).y)) end
        local position=Route.SampleOffset(door.s,(oldClear+oldEdge)/2,door.edge.y-Route.Sample(door.s).y)
        local data=Passenger.ExportState();data.topologyMode=nil
        data.actors={{id=41,appearance=1,kind="boarding",state="walking_to_door",position=pack(position),
            yaw=0,visible=true,walking=true,walkDistance=22,destination=4,doorId=door.id,completed=false,
            speed=1.2,targets=targets,targetIndex=2}}
        data.nextId,data.visits,data.boarded=42,3,17
        data.stop={stationIndex=st.index,phase="boarding",initial=false,terminal=false,reversing=true,
            destinations={4},boarded=17,alighted=0,totalBoarding=18,totalAlighting=0,closeTimer=1,completionTaken=false}
        Passenger.RestoreState(data)
        local restored=Passenger.GetPassengers()[1]
        check(restored.id==41 and restored.targetIndex==2 and restored.walkDistance==22,"legacy reverse actor progress reset")
        check((restored.position-(door.clear+door.edge)/2):Length()<.03,"legacy reverse active segment not reanchored")
        check((restored.targets[3]-door.position):Length()<.001 and (restored.targets[4]-door.inside):Length()<.001,
            "legacy reverse door/inside targets remained clamped on platform")
        check(Passenger.GetStatus().boarded==17,"legacy reverse restore fabricated boarded passenger")
        for _=1,500 do Passenger.Update(.02);if Passenger.GetStatus().boarded==18 then break end end
        local final=Passenger.GetPassengers()[1]
        check(Passenger.GetStatus().boarded==18 and final.completed,"legacy reverse real crossing did not finish")
        check((final.position-door.inside):Length()<.001,"counted legacy reverse passenger before entering actual train")
    end
    Passenger.Reset();Train.Reset(st.s)
    print("[ChineseTopology] LEGACY_REVERSE_MAIN_SIDING_ACTIVE_DOOR_PASS")
end
-- 只替换无头测试的展示/音频，不替换Game/Train/Passenger/Traffic实际运营代码。
local function loadGame()
    local file=assert(cache:GetFile("game/Game.lua"))
    local lines={}
    while not file.eof do lines[#lines+1]=file:ReadLine() end
    file:Dispose()
    local empty=setmetatable({},{__index=function() return function() end end})
    local env=setmetatable({require=function(name)
        if name=="ui.Hud" or name=="audio.AudioManager" then return empty end
        return require(name)
    end},{__index=_G})
    return assert(load(table.concat(lines,"\n"),"@game/Game.lua","t",env))()
end
local function operatingTurnbackChecks()
    local Game=loadGame()
    Passenger.Reset();Traffic.Shutdown()
    local stations=Route.GetStations()
    local st=stations[#stations]
    Train.Reset(st.s-100)
    Traffic.Init(nil);Traffic.Reset(0)
    Game.Init()
    local game=Game.ExportState()
    game.state,game.nextIndex,game.lastArrival="driving",#stations,nil
    Game.RestoreState(game)
    local saved=Train.ExportState()
    saved.s,saved.v,saved.brake,saved.throttle,saved.moving=st.s-10,1,1,0,true
    Train.RestoreState(saved)
    for _=1,2000 do
        Train.Update(.02);Traffic.Update(.02);Game.Update(.02)
        if Game.IsTerminal() then break end
    end
    check(Game.IsTerminal(),"actual Game terminal arrival/closed-door transition failed")
    local reverse,changed=Train.ToggleReversing()
    check(reverse and changed,"actual terminal reverse denied")
    check(Rail.GetPlayerLane(Train.GetS())==0,"turnback boarding prematurely jumped to up platform")
    Game.Update(.02)
    check(Passenger.HasActiveStop() and Passenger.GetStatus().totalBoarding>0,"Game did not start real return boarding")
    local planned=Passenger.GetStatus().totalBoarding
    for _=1,60000 do
        Traffic.Update(.02);Game.Update(.02)
        if not Game.IsDwelling() then break end
    end
    check(not Game.IsDwelling(),"return passenger/departure interlock permanently red")
    check(Passenger.GetStats().onboard==planned,"return boarding fabricated/lost passenger count")
    local sawCrossover,sawUp=false,false
    for _=1,60000 do
        Game.EnforceDepartureInterlock()
        Train.SetThrottle(math.abs(Train.GetSpeedMs())<8 and 2 or 0)
        Train.SetBrake(math.abs(Train.GetSpeedMs())>9 and .25 or 0)
        Train.Update(.02);Traffic.Update(.02);Game.Update(.02)
        check(not Train.IsDerailed(),"physical return traversal derailed")
        sawCrossover=sawCrossover or Rail.GetPlayerLane(Train.GetS())==3
        if Rail.GetBaseLane()==1 and not Rail.GetTurnback() then sawUp=true;break end
    end
    check(sawCrossover and sawUp,"actual Train integration never traversed and cleared onto up line")
    check(Game.GetNextStation().index==#stations-1,"return changed saved station sequence")
    print("[ChineseTopology] GAME_RETURN_PASS actualBoarded="..planned.." upLane="..Rail.GetBaseLane())
    Traffic.Shutdown();Passenger.Reset();Train.Reset(stations[1].s)
end
function Start()
    local ok,message=xpcall(function()
        Route.Build()
        scene_=Scene();scene_:CreateComponent("Octree")
        Train.Build(scene_)
        Passenger.Init(scene_)
        local d=Station.GetDimensions()
        check(d.islandPlatformMin==-8.9 and d.islandPlatformMax==-1.9,"island bounds")
        check(d.upPlatformMin==6.9 and d.upPlatformMax==13.9,"up platform bounds")
        check(d.negativePlatformMin==-19.9 and d.negativePlatformMax==-12.9,"preserved old exterior platform")
        check(d.positivePlatformMin==d.islandPlatformMin,"historical API incompatible")
        local dims=Track.GetDimensions()
        check(dims.upLineLateral==5 and dims.stationLaneLateral==-10.8,"Track topology mismatch")
        for _,st in ipairs(Route.GetStations()) do
            check(Rail.GetLateral(st.s,0)==0 and Rail.GetLateral(st.s,1)==5 and Rail.GetLateral(st.s,2)==-10.8,"wrong lane coordinates")
            for s=st.s-640,st.s+210,2 do
                local _,x=Yard.SampleService(st,s,1)
                check(x>=5-.001,"yard spur cuts across both mains")
            end
        end
        turnbackChecks()
        doorChecks()
        trafficChecks()
        crossoverBlockChecks()
        reservationChecks()
        passengerMigrationChecks()
        legacyReverseDoorChecks()
        operatingTurnbackChecks()
        print("CHINESE_TOPOLOGY_ALL_PASS checks="..checks_)
    end,debug.traceback)
    Passenger.Shutdown();Train.Shutdown();Traffic.Shutdown()
    if scene_ then scene_:Dispose();scene_=nil end
    if not ok then log:Write(LOG_ERROR,tostring(message)) end
end
