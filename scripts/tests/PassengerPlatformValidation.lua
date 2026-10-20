-- CPU regression derived from scaffold-3d-scene Scene ownership and the existing
-- GroundSurfaceValidation triangle witness. Only production Station/Yard/Train/
-- PassengerService/Passengers are executed; no viewport, main, SaveStore or cloud.
-- .cli/UrhoXRuntime tests/PassengerPlatformValidation.lua -tapcode_dir=/workspace -tool_mode
-- Optional: -passenger-mode=normal|rage|all -passenger-section=background|service|all
--           -passenger-lane=main|siding|up|long|all
local Modes=require "config.GameModes"
local Route=require "world.Route"
local Rail=require "world.RailNetwork"
local Station=require "world.Station"
local Yard=require "world.StationYard"
local Visuals=require "world.Passengers"
local Passenger=require "game.PassengerService"
local Train=require "train.Train"
local Config=require "config.GameConfig"
local Quality=require "config.StationVisualConfig"
---@type Scene?
local scene_=nil
---@type Node?
local stationRoot_=nil
---@class PassengerSupportTriangle
---@field ax number
---@field az number
---@field ay number
---@field bx number
---@field bz number
---@field by number
---@field cx number
---@field cz number
---@field cy number
---@field det number
---@field name string
---@type table<string,PassengerSupportTriangle[]>
local surfaces_={}
local checks_,samples_,cases_,backgroundCases_,serviceCases_=0,0,0,0,0
local seamSamples_,maxSeamMeters_=0,0.0
local activeIndex_=0
local originalMode_=Modes.GetId()
local initializedService_=false
local started_=0.0
local function check(ok,message)
    checks_=checks_+1
    assert(ok,"[PassengerPlatform] "..message)
end
local function budget()
    check(os.clock()-started_<94,"CPU time limit exceeded; split using mode/section/lane arguments")
end
local function unload()
    Visuals.Update(nil,{},0)
    if activeIndex_>0 then Station.Forget(activeIndex_);Yard.Forget(activeIndex_) end
    if stationRoot_ then stationRoot_:Dispose();stationRoot_=nil end
    activeIndex_,surfaces_=0,{}
end
-- Footprint design (no character collision bodies are created):
-- platform CG top -> island/up stair CG treads -> bridge CG deck -> outside
-- stair CG treads -> actual yard approach CG -> actual forecourt CG.
-- Every query uses committed world-space triangles, not expected coordinate boxes.
-- A 24cm vertical tolerance covers <=18cm real stair risers plus 4.5cm foot offset;
-- it cannot accept rail ballast/ground 1.4m below, a roof, or a misplaced bridge.
local function collectSurfaces()
    local selected={WeatheredConcretePlatforms=true,UpPlatformConcrete=true,
        BridgeObstacle_1=true,BridgeObstacle_8=true,YardMaterial_1=true,
        ForecourtPaving=true,ForecourtStepsKerbs=true}
    local count=0
    for _,g in ipairs(assert(stationRoot_):GetComponents("CustomGeometry",true)) do
        local name=g.node.name
        if selected[name] then
            local transform=g.node.worldTransform
            for i=0,g:GetNumVertices(0)-1,3 do
                local a=transform*g:GetVertex(0,i).position
                local b=transform*g:GetVertex(0,i+1).position
                local c=transform*g:GetVertex(0,i+2).position
                local cross=(b-a):CrossProduct(c-a)
                if cross.y>.000001 then
                    local t={ax=a.x,az=a.z,ay=a.y,bx=b.x-a.x,bz=b.z-a.z,by=b.y-a.y,
                        cx=c.x-a.x,cz=c.z-a.z,cy=c.y-a.y,
                        det=(b.x-a.x)*(c.z-a.z)-(b.z-a.z)*(c.x-a.x),name=name}
                    for x=math.floor(math.min(a.x,b.x,c.x)/8),math.floor(math.max(a.x,b.x,c.x)/8) do
                        for z=math.floor(math.min(a.z,b.z,c.z)/8),math.floor(math.max(a.z,b.z,c.z)/8) do
                            local key=x..":"..z
                            if not surfaces_[key] then surfaces_[key]={} end
                            local bucket=surfaces_[key]
                            bucket[#bucket+1]=t
                        end
                    end
                    count=count+1
                end
            end
        end
    end
    check(count>300,"production platform/bridge/step CG triangles missing")
end
---@param station RailwayStation
local function activate(station)
    unload()
    stationRoot_=assert(scene_):CreateChild("PassengerPlatformWitness")
    activeIndex_=station.index
    Station.BuildOne(stationRoot_,station)
    Yard.Build(stationRoot_,station)
    collectSurfaces()
    budget()
end
---@param feet Vector3
---@return string?,number
local function supportAt(feet)
    local nearest,name=math.huge,nil ---@type number,string?
    local bucket=surfaces_[math.floor(feet.x/8)..":"..math.floor(feet.z/8)] or {}
    for _,t in ipairs(bucket) do
        local px,pz=feet.x-t.ax,feet.z-t.az
        local u=(px*t.cz-pz*t.cx)/t.det
        local v=(t.bx*pz-t.bz*px)/t.det
        if u>=-.00001 and v>=-.00001 and u+v<=1.00001 then
            local gap=math.abs(feet.y-(t.ay+u*t.by+v*t.cy))
            if gap<nearest then nearest,name=gap,t.name end
        end
    end
    return nearest<=.24 and name or nil,nearest
end
---@param feet Vector3
---@param label string
local function requireSupport(feet,label)
    local name,gap=supportAt(feet)
    if not name then
        -- Stair boxes are independently rounded to float32 world coordinates.
        -- Exact measured failure at ds70.213/lat-44 was a sub-millimetre gap.
        -- Permit only <=2mm distance to an ACTUAL tread triangle edge, never a
        -- configuration rectangle, and retain the same <=24cm vertical gate.
        local bucket=surfaces_[math.floor(feet.x/8)..":"..math.floor(feet.z/8)] or {}
        local bestEdge=math.huge
        for _,t in ipairs(bucket) do
            if t.name=="BridgeObstacle_8" and math.abs(feet.y-t.ay)<=.24 then
                local vertices={{t.ax,t.az},{t.ax+t.bx,t.az+t.bz},{t.ax+t.cx,t.az+t.cz}}
                for i=1,3 do
                    local a,b=vertices[i],vertices[i%3+1]
                    local dx,dz=b[1]-a[1],b[2]-a[2]
                    local f=math.max(0,math.min(1,((feet.x-a[1])*dx+(feet.z-a[2])*dz)/math.max(1e-12,dx*dx+dz*dz)))
                    local distance=math.sqrt((feet.x-a[1]-f*dx)^2+(feet.z-a[2]-f*dz)^2)
                    if distance<=.002 and distance<bestEdge then
                        name,gap,bestEdge=t.name,math.abs(feet.y-t.ay),distance
                    end
                end
            end
        end
        if name then seamSamples_=seamSamples_+1;maxSeamMeters_=math.max(maxSeamMeters_,bestEdge) end
    end
    if not name then
        local station=assert(Route.GetStations()[activeIndex_])
        local base=Route.Sample(station.s)
        local right,tangent=Route.RightAt(station.s),Route.TangentAt(station.s)
        print(string.format("PASSENGER_SUPPORT_DIAG %s ds=%.6f lat=%.6f y=%.6f",label,
            (feet-base):DotProduct(tangent),(feet-base):DotProduct(right),feet.y-base.y))
        for _,dx in ipairs({-.002,0,.002}) do for _,dz in ipairs({-.002,0,.002}) do
            local nearby,nearGap=supportAt(feet+Vector3(dx,0,dz))
            print(string.format("PASSENGER_SUPPORT_NEIGHBOR dx=%.4f dz=%.4f support=%s gap=%.6f",dx,dz,tostring(nearby),nearGap))
        end end
        local nearest=math.huge
        local best=nil ---@type PassengerSupportTriangle?
        for _,bucket in pairs(surfaces_) do for _,t in ipairs(bucket) do
            if t.name=="BridgeObstacle_8" then
                local cx,cz=t.ax+(t.bx+t.cx)/3,t.az+(t.bz+t.cz)/3
                local distance=(feet.x-cx)^2+(feet.z-cz)^2
                if distance<nearest then nearest,best=distance,t end
            end
        end end
        if best then
            local t=best
            print(string.format("PASSENGER_SUPPORT_TRIANGLE A=(%.9f,%.9f,%.9f) B=(%.9f,%.9f,%.9f) C=(%.9f,%.9f,%.9f)",
                t.ax,t.ay,t.az,t.ax+t.bx,t.ay+t.by,t.az+t.bz,t.ax+t.cx,t.ay+t.cy,t.az+t.cz))
        end
    end
    check(name~=nil,string.format("%s no real walking CG under feet world=(%.3f,%.3f,%.3f) nearestGap=%.3f",
        label,feet.x,feet.y,feet.z,gap))
    samples_=samples_+1
    return name
end
---@return Node[]
local function visibleNodes()
    local result={}
    local root=assert(scene_):GetChild("PlatformPassengers")
    if root and root:IsEnabled() then
        for _,node in ipairs(root:GetChildren()) do
            if node:IsEnabled() then result[#result+1]=node end
        end
    end
    return result
end
---@param label string
---@param expected integer
local function auditBackground(label,expected)
    local found,last=0,false
    for _,node in ipairs(visibleNodes()) do
        local id=tonumber(node.name:match("^Passenger_(%-?%d+)$"))
        check(id~=nil and id<0,label.." unexpected service actor")
        local name=requireSupport(node.worldPosition,label.." "..node.name)
        check(name=="UpPlatformConcrete",label.." background is not on the actual up platform")
        found=found+1
        if id==-activeIndex_*100-expected then last=true end
    end
    check(found==expected and last,label.." background count/last actor missing")
end
local function backgroundCase(mode,station)
    activate(station)
    -- Force every quality while the station is active, including high->low->high.
    for _,quality in ipairs({"low","medium","high","low","high"}) do
        local count=Quality.GetQuality(quality).passengerBackground
        Visuals.SetQuality(quality)
        Visuals.Update(station.index,{},0)
        auditBackground(mode.." station"..station.index.." "..quality.." switch-dt0",count)
        -- clock*.55 modulo24: 4/.55 seconds samples all three actor phases at
        -- exact turning points, while six full periods expose accumulated drift.
        for tick=1,12 do
            Visuals.Update(station.index,{},4/.55)
            auditBackground(mode.." station"..station.index.." "..quality.." turn"..tick,count)
        end
        Visuals.Update(station.index,{},24/.55*6)
        auditBackground(mode.." station"..station.index.." "..quality.." six-periods",count)
        local before={}
        for _,node in ipairs(visibleNodes()) do before[node.name]=node.worldPosition end
        Visuals.Update(station.index,{},0)
        for _,node in ipairs(visibleNodes()) do check((node.worldPosition-before[node.name]):Length()<.001,"dt0 moves background") end
    end
    Visuals.Update(nil,{},0)
    check(#visibleNodes()==0,"unloaded visual root retains enabled actors")
    -- Destroy/rebuild the real station, not merely reset an expected bounds table.
    activate(station)
    Visuals.Update(station.index,{},0)
    auditBackground(mode.." station"..station.index.." reload-dt0",Quality.GetQuality("high").passengerBackground)
    backgroundCases_=backgroundCases_+1;cases_=cases_+1
    print(string.format("PASSENGER_PLATFORM_BACKGROUND_PASS mode=%s station=%d qualities=low,medium,high turns=12 periods=8 lastActor=true reload=true",mode,station.index))
end
---@param p Vector3
---@param a Vector3
---@param b Vector3
local function segmentDistance(p,a,b)
    local delta=b-a
    local fraction=math.max(0,math.min(1,(p-a):DotProduct(delta)/math.max(.000001,delta:LengthSquared())))
    return (p-(a+delta*fraction)):Length()
end
---@param feet Vector3
---@param actor RailwayPassenger
---@param plan PassengerDoorPlan
local function legalDoorSegment(feet,actor,plan)
    local door=plan.doors[actor.doorId]
    if not door then return false end
    -- Cross-platform travel never receives this exception: exactly the assigned
    -- inside/threshold/edge/clear 3D polyline, including world Y, must match.
    return segmentDistance(feet,door.inside,door.position)<.025
        or segmentDistance(feet,door.position,door.edge)<.025
        or segmentDistance(feet,door.edge,door.clear)<.025
end
---@param station RailwayStation
---@param label string
---@param stats table
---@param forceAll? boolean
local function auditService(station,label,stats,forceAll)
    local people=Passenger.GetPassengers()
    local plan=Passenger.GetDoorPlan()
    local byId={} ---@type table<number,RailwayPassenger>
    for _,actor in ipairs(people) do byId[actor.id]=actor end
    -- Audits use actual production visual Nodes. Chunking the *real* poses is
    -- solely to witness every initial waiter despite the production visual cap;
    -- no actor, target, clock, speed, state or queue is fabricated or replaced.
    local batches={} ---@type RailwayPassenger[][]
    if forceAll then
        for _,actor in ipairs(people) do
            if actor.visible then
                if #batches==0 or #batches[#batches]>=28 then batches[#batches+1]={} end
                local batch=batches[#batches];batch[#batch+1]=actor
            end
        end
    else
        Passenger.UpdateVisuals(0)
        batches[1]={}
    end
    for _,batch in ipairs(batches) do
        if forceAll then Visuals.Update(station.index,batch,0,plan.doors,Passenger.GetStatus().phase) end
        for _,node in ipairs(visibleNodes()) do
            local id=tonumber(node.name:match("^Passenger_(%-?%d+)$")) or 0
            if id>0 then
                local actor=assert(byId[id],"visual actor lacks real service record")
                local feet=node.worldPosition
                check((feet-actor.position):Length()<.004,label.." visual root differs from authoritative feet")
                local name=supportAt(feet)
                if actor.kind=="boarding" and actor.state=="waiting" then
                    name=requireSupport(feet,label.." waiter"..id)
                    check(name=="WeatheredConcretePlatforms" or name=="UpPlatformConcrete",label.." waiter not on real platform")
                    stats.waiting=stats.waiting+1
                elseif actor.state=="leaving" then
                    name=requireSupport(feet,label.." leaving"..id)
                    stats.leaving=stats.leaving+1
                    if name=="BridgeObstacle_8" then stats.stairs=stats.stairs+1 end
                    if name=="BridgeObstacle_1" then stats.bridge=stats.bridge+1 end
                    if name=="YardMaterial_1" or name=="ForecourtPaving" then stats.ground=stats.ground+1 end
                    -- A lateral crossing of an operational track must be on the
                    -- real 10.7m bridge, never a low-altitude interpolation.
                    local base=Route.Sample(station.s)
                    local lateral=(feet-base):DotProduct(Route.RightAt(station.s))
                    for _,track in ipairs({-10.8,0,5}) do
                        if math.abs(lateral-track)<1.6 then
                            check(name=="BridgeObstacle_1" and feet.y-base.y>10.4,label.." low crossing of operational track")
                            stats.overTrack=stats.overTrack+1
                        end
                    end
                elseif not name then
                    check((actor.state=="walking_to_door" or actor.state=="alighting" or
                        (actor.kind=="alighting" and actor.state=="waiting")) and legalDoorSegment(feet,actor,plan),
                        label.." off-platform actor outside assigned legal 3D door segment id="..id.." state="..actor.state)
                    stats.door=stats.door+1
                end
                samples_=samples_+1
            end
        end
    end
end
local function statsRecord() return {waiting=0,leaving=0,stairs=0,bridge=0,ground=0,overTrack=0,door=0} end
---@param station RailwayStation
---@param label string
---@param stats table
local function advanceStop(station,label,stats)
    local initial=Passenger.GetStatus()
    check(initial.doorCount>0,label.." no production passenger doors")
    auditService(station,label.." initial",stats,true)
    local phases={}
    for tick=1,2400 do
        Passenger.Update(.5)
        local status=Passenger.GetStatus()
        phases[status.phase]=true
        if tick%3==0 or status.ready then auditService(station,label,stats) end
        if status.ready then
            check(status.boarded==initial.totalBoarding and status.alighted==initial.totalAlighting,label.." incomplete real passenger counts")
            check(phases.door_closing,label.." skipped closing")
            check(Passenger.FinishStop(),label.." cannot finish completed stop")
            return
        end
        if tick%200==0 then budget() end
    end
    error("[PassengerPlatform] unfinished real BeginStop "..label)
end
local function positionTrain(station,lane)
    local state=Train.ExportState()
    state.s,state.v,state.throttle,state.brake=station.s,0,0,1
    state.reversing=lane==Rail.OpposingLane
    state.topology={mode=Rail.GetTopologyMode(),baseLane=state.reversing and 1 or 0}
    Train.RestoreState(state)
    if lane==Rail.SidingLane then Rail.RestoreChoices({{index=station.index,lane=lane}}) end
    Train.UpdateVisuals(0)
    check(Rail.GetPlayerLane(station.s)==lane,"real Train lane fixture wrong")
end
local function serviceCase(label,lane,long)
    Passenger.Reset()
    if long then
        -- Explicit in-memory extended-platform fixture on the real normal map;
        -- Route.Build/Station/Yard/Passenger all receive it, never fake CG or poses.
        Config.StationLayout={PlatformStart=-430,PlatformEnd=120,ApproachClearance=700,DepartureClearance=400}
        Route.Build()
    end
    local stations=Route.GetStations()
    local origin=assert(stations[1])
    if lane==Rail.OpposingLane then origin=assert(stations[3]) end
    local destination=assert(stations[2])
    local stats=statsRecord()
    activate(origin);positionTrain(origin,lane)
    Visuals.SetQuality("high")
    check(Passenger.BeginStop(origin,{initial=true,reversing=lane==Rail.OpposingLane,destinations={destination.index}}),label.." origin BeginStop rejected")
    local initial=Passenger.GetStatus()
    check(initial.totalBoarding>0 and initial.totalAlighting==0,label.." production boarding absent")
    advanceStop(origin,label.." boarding",stats)
    local onboard=Passenger.GetStats().onboard
    check(onboard==initial.totalBoarding,label.." real onboard manifest missing")
    activate(destination);positionTrain(destination,lane)
    check(Passenger.BeginStop(destination,{terminal=true,reversing=lane==Rail.OpposingLane,destinations={}}),label.." terminal BeginStop rejected")
    check(Passenger.GetStatus().totalAlighting==onboard,label.." terminal manifest not real origin riders")
    advanceStop(destination,label.." alighting",stats)
    local gone=false
    for tick=1,2400 do
        Passenger.Update(.5)
        if tick%3==0 then auditService(destination,label.." egress",stats) end
        local remaining=false
        for _,actor in ipairs(Passenger.GetPassengers()) do if actor.visible then remaining=true;break end end
        if not remaining then gone=true;break end
        if tick%200==0 then budget() end
    end
    check(gone and Passenger.GetStats().onboard==0,label.." not all real riders completed egress")
    check(stats.waiting>0 and stats.door>0 and stats.stairs>0 and stats.bridge>0 and stats.ground>0
        and stats.overTrack>0,label.." missing measured queue/door/stair/bridge/ground/overtrack coverage")
    serviceCases_=serviceCases_+1;cases_=cases_+1
    print(string.format("PASSENGER_PLATFORM_SERVICE_PASS lane=%s PlatformEnd=%.1f realRiders=%d waiting=%d door=%d stairs=%d bridge=%d ground=%d overTrack=%d allGone=true",
        label,Route.PlatformEnd,onboard,stats.waiting,stats.door,stats.stairs,stats.bridge,stats.ground,stats.overTrack))
    unload();Passenger.Reset()
    if long then Modes.Apply("normal");Route.Build() end
end
function Start()
    started_=os.clock()
    local ok,err=xpcall(function()
        local mode,section,lane="all","all","all"
        for _,arg in ipairs(GetArguments()) do
            mode=arg:match("^%-passenger%-mode=(.+)$") or mode
            section=arg:match("^%-passenger%-section=(.+)$") or section
            lane=arg:match("^%-passenger%-lane=(.+)$") or lane
        end
        check(mode=="all" or mode=="normal" or mode=="rage","unknown mode")
        check(section=="all" or section=="background" or section=="service","unknown section")
        check(lane=="all" or lane=="main" or lane=="siding" or lane=="up" or lane=="long","unknown lane")
        scene_=Scene();scene_:CreateComponent("Octree")
        Visuals.Init(scene_)
        if section~="service" then
            for _,id in ipairs({"normal","rage"}) do
                if mode=="all" or mode==id then
                    unload();Modes.Apply(id);Route.Build();Station.Init();Yard.Shutdown()
                    for _,station in ipairs(Route.GetStations()) do backgroundCase(id,station) end
                end
            end
        end
        if section~="background" and mode~="rage" then
            unload();Visuals.Shutdown();Modes.Apply("normal");Route.Build();Station.Init();Yard.Shutdown()
            Train.Build(scene_);Passenger.Init(scene_);initializedService_=true
            for _,spec in ipairs({{id="main",lane=Rail.MainLane},{id="siding",lane=Rail.SidingLane},
                {id="up",lane=Rail.OpposingLane},{id="long",lane=Rail.OpposingLane,long=true}}) do
                if lane=="all" or lane==spec.id then serviceCase(spec.id,spec.lane,spec.long) end
            end
        end
        budget()
        print(string.format("ALL_PASSENGER_PLATFORM_CPU_PASS mode=%s section=%s checks=%d cases=%d backgroundStations=%d serviceCases=%d samples=%d stairSeamSamples=%d maxSeamMm=%.6f cpuSeconds=%.3f saveIO=NONE GLES=NONE",
            mode,section,checks_,cases_,backgroundCases_,serviceCases_,samples_,seamSamples_,maxSeamMeters_*1000,os.clock()-started_))
    end,debug.traceback)
    unload()
    if initializedService_ then Passenger.Shutdown();Train.Shutdown() else Visuals.Shutdown() end
    Station.Shutdown();Yard.Shutdown()
    if scene_ then scene_:Dispose();scene_=nil end
    Modes.Apply(originalMode_)
    if not ok then print("PASSENGER_PLATFORM_CPU_FAIL "..tostring(err));log:Write(LOG_ERROR,tostring(err)) end
    engine:Exit()
end
