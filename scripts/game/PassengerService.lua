-- 客运权威状态与真实步行队列，人数由逐人到门完成，禁止固定计时假进度。
-- 场景及网格由 world.Passengers 拥有；其 Update 仅更新姿态，不推进此处队列。
local Train = require "train.Train"
local Route = require "world.Route"
local Station = require "world.Station"
local RailNetwork = require "world.RailNetwork"
local Catalog = require "config.TrainCatalog"
local CoachModels = require "config.CoachModels"
local Config = require "config.GameConfig"
local Visuals = require "world.Passengers"
local PassengerService = {}

---@class RailwayPassenger : PlatformPassengerPose
---@field id integer
---@field appearance integer
---@field kind string boarding|alighting
---@field state string waiting|walking_to_door|boarding|alighting|leaving|onboard|gone
---@field position Vector3 脚底世界位置，不是乘客身体中心
---@field yaw number
---@field visible boolean
---@field walking boolean
---@field walkDistance number
---@field destination integer
---@field doorId integer
---@field completed boolean
---@field speed number
---@field targets Vector3[]
---@field targetIndex integer

---@class PassengerDoor : PlatformDoorPose
---@field id integer
---@field carIndex integer
---@field s number
---@field side integer 车体/世界横向门侧，牵引换向不会翻转车体
---@field position Vector3 门槛脚底位置
---@field inside Vector3
---@field edge Vector3 实际站台边缘及压顶高度
---@field clear Vector3 安全站台步行走廊
---@field source string
---@field forward Vector3
---@field right Vector3
---@field queueDirection number

---@class PassengerDoorPlan
---@field stationIndex integer
---@field lane integer
---@field platformMin number
---@field platformMax number
---@field platformY number
---@field doors PassengerDoor[]
---@field valid boolean
---@field reason string

---@class PassengerStop
---@field station RailwayStation
---@field phase string
---@field initial boolean
---@field terminal boolean
---@field reversing boolean
---@field destinations integer[]
---@field boarded integer
---@field alighted integer
---@field totalBoarding integer
---@field totalAlighting integer
---@field closeTimer number
---@field plan PassengerDoorPlan
---@field signature string
---@field completionTaken boolean

---@class PassengerStatus
---@field phase string
---@field waiting integer
---@field boarded integer
---@field alighted integer
---@field totalBoarding integer
---@field totalAlighting integer
---@field onboard integer
---@field capacity integer
---@field doorsOpen boolean
---@field ready boolean
---@field message string
---@field stationIndex integer
---@field doorCount integer
---@field dwellRemaining number?

---@type PassengerStop?
local stop_ = nil
---@type RailwayPassenger[]
local actors_ = {}
---@type RailwayPassenger[]
local onboard_ = {}
local nextId_, visit_ = 0, 0
local boardedTotal_, alightedTotal_ = 0, 0
local paused_ = false
local initialized_ = false
local lastSpeed_ = 0.0
local comfort_ = 100.0
local comfortPenalty_ = 0.0
local DOOR_CLOSE_SECONDS = 1.6
-- 门边通道是单向连续流：按剩余路径预留0.85米跟随进度，不是候车区实体碰撞。
-- 车内 -> 门槛 -> 台沿 -> 安全走廊；同站仍严格先下后上，最后一人走完才关门。
local DOOR_FOLLOW_DISTANCE = .85

---@param actor RailwayPassenger
---@return number
local function remainingPath(actor)
    local distance=0.0
    local previous=actor.position
    for i=actor.targetIndex,#actor.targets do
        local target=actor.targets[i]
        distance=distance+(target-previous):Length()
        previous=target
    end
    return distance
end

local function blankPlan()
    return {stationIndex=0,lane=0,platformMin=0,platformMax=0,platformY=0,doors={},valid=false,reason="无停靠站"} --[[@as PassengerDoorPlan]]
end

local function independentCoachProfile(id)
    for _, spec in pairs(CoachModels.ByLocomotive) do
        if spec.source=="generated_asset" and spec.reviewConfirmed and spec.profileId==id then return true end
    end
    return false
end

---@param station RailwayStation
---@param candidateCars? TrainCar[] 仅供同步提交前只读验证；不替换当前业务编组。
---@return PassengerDoorPlan
function PassengerService.BuildDoorPlan(station,candidateCars)
    local dimensions = Station.GetDimensions()
    local lane = RailNetwork.GetPlayerLane(Train.GetS())
    local up = lane == RailNetwork.OpposingLane
    local plan = {stationIndex=station.index,lane=lane,
        platformMin=up and dimensions.upPlatformMin or dimensions.islandPlatformMin,
        platformMax=up and dimensions.upPlatformMax or dimensions.islandPlatformMax,platformY=dimensions.platformTopY,
        doors={},valid=false,reason="没有与站台对齐的合法客运车门"} --[[@as PassengerDoorPlan]]
    if Route.Distance(Train.GetS(),station.s) >= Config.Gameplay.StopTolerance then
        plan.reason="列车不在停靠容差内"; return plan
    end
    if lane ~= RailNetwork.MainLane and lane ~= RailNetwork.SidingLane and not up then
        plan.reason="渡线咽喉不能进行乘降"; return plan
    end
    local side = lane == RailNetwork.MainLane and -1 or 1
    local edgeLateral = side == 1 and plan.platformMin or plan.platformMax
    -- Main岛台近缘及上行外台有石压顶；侧线岛台外缘保持原平面。
    local edgeY = plan.platformY + (lane ~= RailNetwork.SidingLane and .05 or 0)
    local corridor = side == 1 and plan.platformMin+1.80 or plan.platformMax-1.80
    -- 俯视：车内 <- 门槛 --<=0.9m--> 岛台边缘 --1.8m--> 候车走廊。
    -- 所有模拟锚也须满足真实站台纵向包络/同股道/门槛高差<=0.35m；
    -- 擦端越界、换侧线跨轨、机车和驾驶鼻端均不生成门，不放宽安全门限。
    for carIndex, car in ipairs(candidateCars or Train.GetCars()) do
        local profile = Catalog.Profiles[car.profile]
        local candidates = {} ---@type {z:number,source:string}[]
        if car.profile == "coach" then
            -- 当前 Coach.Openings 精确范围：[-11.1,-10.2]、[10.2,11.1]，门槛 y=1.50。
            candidates={{z=-10.65,source="Coach.Openings"},{z=10.65,source="Coach.Openings"}}
        elseif profile and independentCoachProfile(car.profile) then
            -- 独立客车不是旧程序coach，也没有门位实测元数据。用已验收完整
            -- 车长两端向内2.1m的模拟玄关，明确不声称这是贴图/网格实测门。
            local z=profile.length*.5-2.1
            candidates={{z=-z,source="simulated_coach_end_vestibule"},
                {z=z,source="simulated_coach_end_vestibule"}}
        elseif profile and profile.endSurvey and (car.frontEnd or car.rearEnd) then
            -- 当前动车资产没有实测客运门元数据。此处明确使用模拟玄关锚点：
            -- 在实测平端向内 2.1 米处取候选，排除驾驶鼻端，不声称门位工程实测。
            if car.rearEnd and car.rearEnd.kind == "flat" then
                candidates[#candidates+1]={z=car.rearEnd.center.z+2.1,source="simulated_flat_end_vestibule"}
            end
            if car.frontEnd and car.frontEnd.kind == "flat" then
                candidates[#candidates+1]={z=car.frontEnd.center.z-2.1,source="simulated_flat_end_vestibule"}
            end
        end -- 机车、驾驶鼻端、未验收车型均不允许客运登乘。
        local centerS = Train.GetS()+car.offset
        local front = Train.GetTrackSample(centerS+car.pivot)
        local rear = Train.GetTrackSample(centerS-car.pivot)
        local midpoint = (front+rear)*.5
        local chord = front-rear
        local rotation = Quaternion(math.deg(math.atan(chord.x,chord.z)),Vector3.UP)
        for _, candidate in ipairs(candidates) do
            local s = centerS+candidate.z
            if s >= station.s+dimensions.platformStart+1.0 and s <= station.s+dimensions.platformEnd-1.0
                and RailNetwork.GetPlayerLane(s) == lane then
                local halfWidth = (profile and profile.width or 3.1)*.5
                local thresholdY = car.profile == "coach" and 1.50 or plan.platformY+.10
                local threshold = midpoint+rotation*Vector3(side*(halfWidth-.035),thresholdY,candidate.z)
                local edge = Route.SampleOffset(s,edgeLateral,edgeY)
                local clear = Route.SampleOffset(s,corridor,plan.platformY+.045)
                -- 不跨另一股道：门槛至站台边缘不超过 0.9 米，高差不超过 0.35 米。
                local dx,dz = threshold.x-edge.x,threshold.z-edge.z
                if dx*dx+dz*dz <= .9*.9 and math.abs(threshold.y-edge.y) <= .35 then
                    local door = {id=#plan.doors+1,carIndex=carIndex,s=s,side=side,position=threshold,
                        inside=threshold-rotation*Vector3(side*.75,0,0),edge=edge,clear=clear,source=candidate.source,
                        forward=rotation*Vector3.FORWARD,right=rotation*Vector3.RIGHT,
                        queueDirection=candidate.z>0 and -1 or 1}
                    plan.doors[#plan.doors+1]=door
                end
            end
        end
    end
    plan.valid = #plan.doors > 0
    if plan.valid then plan.reason="" end
    return plan
end

local function signature()
    return string.format("%s:%.3f:%d",Train.GetSelectedId(),Train.GetS(),RailNetwork.GetPlayerLane(Train.GetS()))
end

---@param kind string
---@param position Vector3
---@param destination integer
---@return RailwayPassenger
local function person(kind,position,destination)
    nextId_ = nextId_+1
    return {id=nextId_,appearance=nextId_%24,kind=kind,state="waiting",position=position,yaw=0,
        visible=true,walking=false,walkDistance=0,destination=destination,doorId=0,completed=false,
        speed=1.02+(nextId_%5)*.115,targets={},targetIndex=1}
end

---@param actor RailwayPassenger
---@param targets Vector3[]
---@param state string
local function path(actor,targets,state)
    actor.targets,actor.targetIndex,actor.state,actor.walking=targets,1,state,#targets>0
end

---@param actor RailwayPassenger
---@param dt number
---@return boolean finished
local function walk(actor,dt)
    local remaining = dt*actor.speed
    local distanceWalked = 0.0
    while remaining>0 and actor.targetIndex<=#actor.targets do
        local target = assert(actor.targets[actor.targetIndex])
        local delta = target-actor.position
        local distance = delta:Length()
        if distance <= .0001 then
            actor.position=target; actor.targetIndex=actor.targetIndex+1
        else
            local moved = math.min(remaining,distance)
            actor.yaw=math.deg(math.atan(delta.x,delta.z))
            actor.position=actor.position+delta*(moved/distance)
            distanceWalked,remaining=distanceWalked+moved,remaining-moved
            if moved>=distance-.000001 then actor.position=target; actor.targetIndex=actor.targetIndex+1 end
        end
    end
    actor.walkDistance=actor.walkDistance+distanceWalked
    actor.walking=actor.targetIndex<=#actor.targets
    return not actor.walking
end

---@param actor RailwayPassenger
---@param station RailwayStation
local function leave(actor,station)
    -- 与StationYard实际桥位一致：长站台的天桥随PlatformEnd后移，不能仍在+83米低空跨轨。
    -- 站台走廊 -> 桥前22米 -> 19米梯道 -> 10.7米桥面 -> 站外26米梯道。
    local dimensions=Station.GetDimensions()
    local y = dimensions.platformTopY+.045
    local bridgeOffset=math.max(83,dimensions.platformEnd-2)
    local bridgeY = 10.7 -- StationYard DECK_Y 10.4 加桥板半厚 0.30 米。
    local at = Route.ProjectApprox(actor.position)
    local origin = Route.Sample(at)
    local lateral = (actor.position-origin):DotProduct(Route.RightAt(at))
    local up=lateral>5
    local stair=up and 10.4 or -5.4
    local approach=up and 9.0 or -7.0
    path(actor,{Route.SampleOffset(station.s+bridgeOffset-22,lateral,y),Route.SampleOffset(station.s+bridgeOffset-22,approach,y),
        Route.SampleOffset(station.s+bridgeOffset-19.4,stair,y),
        Route.SampleOffset(station.s+bridgeOffset,stair,bridgeY),Route.SampleOffset(station.s+bridgeOffset,-44,bridgeY),
        Route.SampleOffset(station.s+bridgeOffset-26,-44,.125),Route.SampleOffset(station.s-55,-44,.125)},"leaving")
end

---@param actor RailwayPassenger
---@param door PassengerDoor
---@return number
local function boardingPathDistance(actor,door)
    return (door.clear-actor.position):Length()+(door.edge-door.clear):Length()
        +(door.position-door.edge):Length()+(door.inside-door.position):Length()
end

---@param actor RailwayPassenger
---@param doors PassengerDoor[]
---@param loads table<number,number> 同阶段门口预计剩余服务秒数
---@return PassengerDoor, number
local function nearestDoor(actor,doors,loads)
    local nearest=math.huge
    for _, door in ipairs(doors) do
        local target=actor.kind=="alighting" and door.position or door.clear
        nearest=math.min(nearest,(target-actor.position):Length())
    end
    local selected=assert(doors[1])
    local bestScore,bestPath=math.huge,math.huge
    for _, door in ipairs(doors) do
        local target=actor.kind=="alighting" and door.position or door.clear
        local distance=(target-actor.position):Length()
        -- 只在最近门再远不超过四米的候选间平衡负担，不能为覆盖率拉去另一节远车门。
        if distance<=nearest+4.0 then
            local pathDistance=actor.kind=="alighting" and ((door.position-actor.position):Length()
                +(door.edge-door.position):Length()+(door.clear-door.edge):Length())
                or boardingPathDistance(actor,door)
            local score=pathDistance/actor.speed+(loads[door.id] or 0)
            if score<bestScore then selected,bestScore,bestPath=door,score,pathDistance end
        end
    end
    loads[selected.id]=(loads[selected.id] or 0)+bestPath/actor.speed
    return selected,bestPath
end

---@param stop PassengerStop
local function bindActors(stop)
    local plan = stop.plan
    if not plan.valid then return end
    local boardingSlot = {} ---@type table<number, integer>
    local firstSlots={boarding=0,alighting=0}
    local boardingLoads,alightingLoads = {}, {} ---@type table<number,number>,table<number,number>
    local rebound,maxReboundDistance=0,0.0
    for _, actor in ipairs(actors_) do
        if not actor.completed and actor.state~="leaving" and actor.state~="gone" then
            local firstBinding = actor.doorId==0
            local door=assert(plan.doors[1])
            if firstBinding then
                -- 按本次乘降序号均匀分门，不能用全局id与目的站数取模共振。
                -- 已有位置的换车重绑仍走nearestDoor，不把乘客瞬移到远门。
                local slot=firstSlots[actor.kind] or 0
                door=assert(plan.doors[slot%#plan.doors+1])
                firstSlots[actor.kind]=slot+1
            else
                local distance
                door,distance=nearestDoor(actor,plan.doors,actor.kind=="alighting" and alightingLoads or boardingLoads)
                rebound,maxReboundDistance=rebound+1,math.max(maxReboundDistance,distance)
            end
            actor.doorId=door.id
            actor.targets,actor.targetIndex,actor.walking={},1,false
            if actor.kind=="alighting" then
                if firstBinding then actor.position=door.inside end
                actor.state="waiting"
            else
                local slot=(boardingSlot[door.id] or 0)+1
                boardingSlot[door.id]=slot
                -- 两端门队列朝本车中部、三列排开，避开车钩处相向交叉和密集重叠。
                if firstBinding then
                    actor.position=door.clear+door.forward*(door.queueDirection*math.floor((slot-1)/3)*.75)
                        +door.right*(door.side*((slot-1)%3)*.65)
                end
                actor.state="waiting"
                actor.yaw=select(3,Route.Sample(door.s))+(door.side==1 and -90 or 90)
            end
        end
    end
    print(string.format("[PassengerService] %s lane%d / %d doors; queues retain %d/%d boarded; near-rebind%d maxPath%.2fm",
        stop.station.name,plan.lane,#plan.doors,stop.boarded,stop.totalBoarding,rebound,maxReboundDistance))
end

function PassengerService.SetVisualQuality(qualityId)
    Visuals.SetQuality(qualityId)
end

function PassengerService.GetCapacity(id)
    local entry = Catalog.Find(id or Train.GetSelectedId())
    return entry and entry.kind=="emu" and 608 or 560 -- 8节动车/7节80座客车，不把可视人物数当载客量。
end
---@param stop PassengerStop
local function enqueueBoarding(stop)
    if #stop.destinations==0 then return end
    local capacity = PassengerService.GetCapacity()
    local remaining = math.max(0,capacity-#onboard_+stop.totalAlighting)
    local demand = math.floor(capacity*(stop.initial and .62 or .24))+(visit_*7+stop.station.index*11)%23
    local count = math.min(remaining,demand)
    for i=1,count do
        local destination=assert(stop.destinations[(i-1)%#stop.destinations+1])
        actors_[#actors_+1]=person("boarding",Route.SampleOffset(stop.station.s-15-i,3.7,stop.plan.platformY+.045),destination)
    end
    stop.totalBoarding=count
end

function PassengerService.Reset()
    stop_,actors_,onboard_,nextId_,visit_=nil,{},{},0,0
    boardedTotal_,alightedTotal_,comfort_,comfortPenalty_,lastSpeed_,paused_=0,0,100,0,Train.GetSpeedMs(),false
    Visuals.Update(nil,{},0)
end

---@param id string
---@param candidateCars TrainCar[]
---@return boolean,string
function PassengerService.ValidateTrainSelection(id,candidateCars)
    local stop=stop_
    local waiting=stop and stop.totalBoarding-stop.boarded or 0
    if #onboard_+waiting>PassengerService.GetCapacity(id) then
        return false,"新编组容量不足，原乘降清单已保留"
    end
    if stop then
        -- Train暂存组装的同步只读校验：不改stop/actors、无事件/异步/视觉更新。
        local plan=PassengerService.BuildDoorPlan(stop.station,candidateCars)
        if not plan.valid then return false,"当前站台不兼容新编组："..plan.reason end
    end
    return true,""
end

---@param scene Scene
function PassengerService.Init(scene)
    Visuals.Init(scene)
    initialized_=true
    PassengerService.Reset()
    Train.SetSelectionValidator(PassengerService.ValidateTrainSelection)
end
function PassengerService.Shutdown()
    Train.SetSelectionValidator(nil)
    Visuals.Shutdown()
    stop_,actors_,onboard_,initialized_=nil,{},{},false
end
---@param paused boolean
function PassengerService.SetPaused(paused) paused_=paused end
function PassengerService.IsPaused() return paused_ end

---@param station RailwayStation
---@param options {initial:boolean?,terminal:boolean?,reversing:boolean?,destinations:integer[]}
---@return boolean
function PassengerService.BeginStop(station,options)
    -- 同一活动站停不能重启，禁止丢弃未完成乘客或绕过关门计时。
    if stop_ then return false end
    visit_=visit_+1
    actors_={}
    local plan=PassengerService.BuildDoorPlan(station)
    stop_={station=station,phase="alighting",initial=options.initial==true,terminal=options.terminal==true,
        reversing=options.reversing==true,destinations=options.destinations,boarded=0,alighted=0,
        totalBoarding=0,totalAlighting=0,closeTimer=DOOR_CLOSE_SECONDS,plan=plan,signature=signature(),completionTaken=false}
    local stop=stop_
    for _, rider in ipairs(onboard_) do
        if stop.terminal or rider.destination==station.index then
            rider.kind,rider.completed,rider.visible,rider.state="alighting",false,true,"waiting"
            rider.doorId,rider.targets,rider.targetIndex=0,{},1
            actors_[#actors_+1]=rider
            stop.totalAlighting=stop.totalAlighting+1
        end
    end
    -- 乘客实际穿过车门至安全线外才从车内清单移除。
    -- 终到只安排全部下车，明确换向后再生成折返登乘队列。
    if not stop.terminal then enqueueBoarding(stop) end
    bindActors(stop)
    print(string.format("[PassengerService] %s visit%d: alight%d board%d%s",station.name,visit_,
        stop.totalAlighting,stop.totalBoarding,stop.initial and " (initial, no reward)" or ""))
    return true
end

---@param destinations integer[]
---@param reversing boolean
---@return boolean
function PassengerService.StartReturn(destinations,reversing)
    local stop=stop_
    if not stop or not stop.terminal or stop.phase~="ready" or #onboard_>0 or #destinations==0 then return false end
    stop.terminal,stop.initial,stop.reversing,stop.destinations=false,true,reversing,destinations
    stop.boarded,stop.totalBoarding,stop.closeTimer,stop.phase=0,0,DOOR_CLOSE_SECONDS,"boarding"
    stop.completionTaken=true -- 折返登乘是新发车准备，不是再次结算到站奖励。
    enqueueBoarding(stop)
    stop.plan,stop.signature=PassengerService.BuildDoorPlan(stop.station),signature()
    bindActors(stop)
    return true
end

---@param destinations integer[]
---@param reversing boolean
function PassengerService.SetDestinations(destinations,reversing)
    local stop=stop_
    if not stop or stop.terminal or #destinations==0 then return end
    stop.destinations,stop.reversing=destinations,reversing
    for _, actor in ipairs(actors_) do
        if actor.kind=="boarding" then actor.destination=destinations[(actor.id-1)%#destinations+1] end
    end
    -- 改快速服务后，已在车内但原目的站被跳过的乘客改至前方终到站。
    for _, rider in ipairs(onboard_) do
        local found=false
        for _, index in ipairs(destinations) do if rider.destination==index then found=true end end
        if not found and rider.kind~="alighting" then rider.destination=destinations[#destinations] end
    end
end

local function removeRider(id)
    for i=#onboard_,1,-1 do if onboard_[i].id==id then table.remove(onboard_,i); return end end
end

function PassengerService.RefreshDoorPlan()
    local stop=stop_
    if not stop then return end
    local changed=signature()
    if changed~=stop.signature then
        stop.signature,stop.plan=changed,PassengerService.BuildDoorPlan(stop.station)
        bindActors(stop)
    end
end

---@param dt number
function PassengerService.Update(dt)
    if paused_ or dt<=0 then return end
    local speed=Train.GetSpeedMs()
    if #onboard_>0 then
        local acceleration=math.abs(speed-lastSpeed_)/dt
        if acceleration>1.05 then
            local loss=math.min(2,acceleration-1.05)*dt*.85
            comfort_,comfortPenalty_=math.max(0,comfort_-loss),comfortPenalty_+loss
        end
    end
    lastSpeed_=speed
    local stop=stop_
    if not stop then
        for _, actor in ipairs(actors_) do
            if actor.state=="leaving" and walk(actor,dt) then actor.state,actor.visible="gone",false end
        end
        return
    end
    PassengerService.RefreshDoorPlan()
    for _, actor in ipairs(actors_) do
        if actor.state=="leaving" and walk(actor,dt) then actor.state,actor.visible="gone",false end
    end
    if math.abs(speed)>.02 or not stop.plan.valid then return end
    if stop.phase=="alighting" or stop.phase=="boarding" then
        local kind=stop.phase=="alighting" and "alighting" or "boarding"
        local preceding={} ---@type table<number,number>
        -- 所有候车人都沿自己的连续路径推进，不再先执行旧队列前移；
        -- 否则换车重绑/旧档waiting会在同一步消费两次步行预算。
        for _, actor in ipairs(actors_) do
            if actor.kind==kind and not actor.completed and actor.doorId>0 then
                local door=stop.plan.doors[actor.doorId]
                if door then
                    if actor.state=="waiting" then
                        if kind=="alighting" then path(actor,{door.position,door.edge,door.clear},"alighting")
                        else path(actor,{door.clear,door.edge,door.position,door.inside},"walking_to_door") end
                    end
                    local remaining=remainingPath(actor)
                    local ahead=preceding[door.id]
                    local allowed=dt*actor.speed
                    if ahead then allowed=math.min(allowed,math.max(0,remaining-ahead-DOOR_FOLLOW_DISTANCE)) end
                    -- 同门多人可连续走动，但不能追越前人或跳过任何门槛路径点。
                    -- 步长来自真实速度和余距，帧率、暂停或存档恢复都不会直接增加人数。
                    local finished=walk(actor,allowed/actor.speed)
                    preceding[door.id]=remainingPath(actor)
                    if finished then
                        actor.completed=true
                        if kind=="alighting" then
                            stop.alighted,alightedTotal_=stop.alighted+1,alightedTotal_+1
                            removeRider(actor.id)
                            leave(actor,stop.station)
                        else
                            actor.state,actor.visible="onboard",false
                            stop.boarded,boardedTotal_=stop.boarded+1,boardedTotal_+1
                            onboard_[#onboard_+1]=actor
                        end
                    end
                end
            end
        end
        if stop.phase=="alighting" and stop.alighted==stop.totalAlighting then stop.phase="boarding"
        elseif stop.phase=="boarding" and stop.boarded==stop.totalBoarding then stop.phase="door_closing" end
    elseif stop.phase=="door_closing" then
        stop.closeTimer=math.max(0,stop.closeTimer-dt)
        if stop.closeTimer<=0 then stop.phase="ready" end
    end
end

function PassengerService.GetStatus()
    local stop=stop_
    if not stop then
        return {phase="ready",waiting=0,boarded=0,alighted=0,totalBoarding=0,totalAlighting=0,
            onboard=#onboard_,capacity=PassengerService.GetCapacity(),doorsOpen=false,ready=true,message="区间运行 · 车门关闭",stationIndex=0,doorCount=0} --[[@as PassengerStatus]]
    end
    local phase=stop.phase
    local message=phase=="alighting" and (stop.alighted<stop.totalAlighting
            and "先下后上 · 乘客正在下车" or "无待下车乘客 · 等待队列上车")
        or phase=="boarding" and "候车队列逐人走向车门"
        or phase=="door_closing" and "乘降完成 · 正在关门" or "乘降完成 · 车门已关闭"
    if not stop.plan.valid then message=stop.plan.reason
    elseif math.abs(Train.GetSpeedMs())>.02 then message="乘降暂停 · 列车必须停稳" end
    local ready=phase=="ready" and stop.plan.valid and math.abs(Train.GetSpeedMs())<=.02
    return {phase=phase,waiting=stop.totalBoarding-stop.boarded,boarded=stop.boarded,alighted=stop.alighted,
        totalBoarding=stop.totalBoarding,totalAlighting=stop.totalAlighting,onboard=#onboard_,capacity=PassengerService.GetCapacity(),
        doorsOpen=phase=="alighting" or phase=="boarding",ready=ready,message=message,
        stationIndex=stop.station.index,doorCount=#stop.plan.doors} --[[@as PassengerStatus]]
end

function PassengerService.IsReady() return PassengerService.GetStatus().ready end
function PassengerService.HasActiveStop() return stop_~=nil end
function PassengerService.FinishStop()
    if not PassengerService.IsReady() then return false end
    stop_=nil
    -- 发车后保留正在离站的人，不能立刻剪掉其站台和天桥步行。
    local remaining={} ---@type RailwayPassenger[]
    for _, actor in ipairs(actors_) do if actor.state=="leaving" then remaining[#remaining+1]=actor end end
    actors_=remaining
    return true
end

function PassengerService.TakeCompletion()
    local stop=stop_
    if not stop or stop.phase~="ready" or stop.completionTaken then return nil end
    stop.completionTaken=true
    return {stationIndex=stop.station.index,initial=stop.initial,terminal=stop.terminal,
        boarded=stop.boarded,alighted=stop.alighted,comfort=comfort_,penalty=comfortPenalty_}
end

---@param dt number?
function PassengerService.UpdateVisuals(dt)
    if not initialized_ then return end
    local near=nil ---@type integer?
    local stop=stop_
    if stop and Route.Distance(Train.GetS(),stop.station.s)<600 then
        Visuals.Update(stop.station.index,actors_,paused_ and 0 or dt,stop.plan.doors,stop.phase)
        return
    else
        for _, station in ipairs(Route.GetStations()) do
            if Route.Distance(Train.GetS(),station.s)<600 then near=station.index; break end
        end
    end
    -- 离站者只在自己的车站渲染，不在下一座城市出现旧站乘客。
    local visibleActors={} ---@type RailwayPassenger[]
    if near then
        local station=Route.GetStations()[near]
        if station then
            for _, actor in ipairs(actors_) do
                if Route.Distance(Route.ProjectApprox(actor.position),station.s)<350 then visibleActors[#visibleActors+1]=actor end
            end
        end
    end
    Visuals.Update(near,visibleActors,paused_ and 0 or dt)
end

function PassengerService.GetVisualStats() return Visuals.GetStats() end
function PassengerService.GetDoorPlan()
    local source=stop_ and stop_.plan or blankPlan()
    local copy={stationIndex=source.stationIndex,lane=source.lane,platformMin=source.platformMin,
        platformMax=source.platformMax,platformY=source.platformY,valid=source.valid,reason=source.reason,doors={}} --[[@as PassengerDoorPlan]]
    for _, door in ipairs(source.doors) do
        copy.doors[#copy.doors+1]={id=door.id,carIndex=door.carIndex,s=door.s,side=door.side,
            position=door.position,inside=door.inside,edge=door.edge,clear=door.clear,source=door.source,
            forward=door.forward,right=door.right,queueDirection=door.queueDirection}
    end
    return copy
end
function PassengerService.GetPassengers()
    local copy={} ---@type RailwayPassenger[]
    for _, actor in ipairs(actors_) do
        local item={id=actor.id,appearance=actor.appearance,kind=actor.kind,state=actor.state,
            position=actor.position,yaw=actor.yaw,visible=actor.visible,walking=actor.walking,
            walkDistance=actor.walkDistance,destination=actor.destination,doorId=actor.doorId,
            completed=actor.completed,speed=actor.speed,targets={},targetIndex=actor.targetIndex}
        for _, target in ipairs(actor.targets) do item.targets[#item.targets+1]=target end
        copy[#copy+1]=item
    end
    return copy
end
function PassengerService.GetStats()
    return {boarded=boardedTotal_,alighted=alightedTotal_,onboard=#onboard_,comfort=comfort_,
        comfortPenalty=comfortPenalty_,visits=visit_}
end
-- 存档只保存业务值，不序列化 Node/Model；恢复时重建门计划并保留每条步行路径。
local function packPerson(actor)
    local targets={}
    for _,v in ipairs(actor.targets) do targets[#targets+1]={v.x,v.y,v.z} end
    return {id=actor.id,appearance=actor.appearance,kind=actor.kind,state=actor.state,
        position={actor.position.x,actor.position.y,actor.position.z},yaw=actor.yaw,visible=actor.visible,
        walking=actor.walking,walkDistance=actor.walkDistance,destination=actor.destination,
        doorId=actor.doorId,completed=actor.completed,speed=actor.speed,targets=targets,targetIndex=actor.targetIndex}
end
local function unpackPerson(data)
    assert(type(data)=="table" and type(data.position)=="table" and type(data.targets)=="table","乘客存档不完整")
    local actor=person(data.kind,Vector3(data.position[1],data.position[2],data.position[3]),data.destination)
    actor.id,actor.appearance,actor.state=data.id,data.appearance,data.state
    actor.yaw,actor.visible,actor.walking=data.yaw,data.visible==true,data.walking==true
    actor.walkDistance,actor.doorId,actor.completed=data.walkDistance,data.doorId,data.completed==true
    actor.speed,actor.targetIndex=data.speed,data.targetIndex
    for _,v in ipairs(data.targets) do actor.targets[#actor.targets+1]=Vector3(v[1],v[2],v[3]) end
    assert(actor.id>0 and actor.speed>0 and actor.speed<3 and actor.targetIndex>=1,"乘客存档数值无效")
    return actor
end
function PassengerService.ExportState()
    local people,riders={},{}
    for _,actor in ipairs(actors_) do people[#people+1]=packPerson(actor) end
    for _,rider in ipairs(onboard_) do riders[#riders+1]=packPerson(rider) end
    local stop=stop_
    local savedStop=stop and {stationIndex=stop.station.index,phase=stop.phase,initial=stop.initial,
        terminal=stop.terminal,reversing=stop.reversing,destinations=stop.destinations,boarded=stop.boarded,
        alighted=stop.alighted,totalBoarding=stop.totalBoarding,totalAlighting=stop.totalAlighting,
        closeTimer=stop.closeTimer,completionTaken=stop.completionTaken} or nil
    return {topologyMode=RailNetwork.GetTopologyMode(),geometryMode=Route.GetGeometryMode(),actors=people,onboard=riders,stop=savedStop,nextId=nextId_,visits=visit_,boarded=boardedTotal_,
        alighted=alightedTotal_,comfort=comfort_,comfortPenalty=comfortPenalty_,lastSpeed=lastSpeed_}
end
function PassengerService.RestoreState(data)
    assert(type(data)=="table" and type(data.actors)=="table" and type(data.onboard)=="table","客流存档不完整")
    assert(#data.onboard<=PassengerService.GetCapacity() and #data.actors<=1300,"客流存档超出容量")
    assert(data.topologyMode==nil or data.topologyMode==RailNetwork.GetTopologyMode(),"客流拓扑未知，拒绝覆盖原进度")
    assert(data.geometryMode==nil or data.geometryMode==Route.GetGeometryMode(),"客流线路几何模式未知，拒绝覆盖原进度")
    local legacy=data.topologyMode==nil
    local legacyGeometry=data.geometryMode==nil
    local function migrate(position)
        local current=legacyGeometry and Route.TransformLegacyPosition(position) or position
        if not legacy then return current end
        local s=Route.ProjectApprox(current)
        local base=Route.Sample(s)
        local right=Route.RightAt(s)
        local lat=(current-base):DotProduct(right)
        -- 老档正岛台迁移到负侧；高架出站路线同步迁移，不镜像站房/全城。
        if lat>0 and lat<12.5 then
            local nextLat=Train.IsReversing() and math.max(7.1,math.min(13.4,lat+5)) or -lat
            return current+right*(nextLat-lat)
        end
        return current
    end
    PassengerService.Reset()
    local byId={} ---@type table<number,RailwayPassenger>
    for _,saved in ipairs(data.actors) do
        local actor=unpackPerson(saved)
        actor.position=migrate(actor.position)
        for i,target in ipairs(actor.targets) do actor.targets[i]=migrate(target) end
        actors_[#actors_+1]=actor;byId[actor.id]=actor
    end
    for _,saved in ipairs(data.onboard) do
        local rider=byId[saved.id]
        if not rider then
            rider=unpackPerson(saved)
            rider.position=migrate(rider.position)
            for i,target in ipairs(rider.targets) do rider.targets[i]=migrate(target) end
        end
        onboard_[#onboard_+1]=rider
    end
    nextId_,visit_=data.nextId,data.visits
    boardedTotal_,alightedTotal_=data.boarded,data.alighted
    comfort_,comfortPenalty_,lastSpeed_=data.comfort,data.comfortPenalty,data.lastSpeed
    if data.stop then
        local saved=data.stop
        local station=assert(Route.GetStations()[saved.stationIndex],"存档车站不存在")
        local plan=PassengerService.BuildDoorPlan(station)
        assert(plan.valid,"存档车门未对齐站台")
        stop_={station=station,phase=saved.phase,initial=saved.initial==true,terminal=saved.terminal==true,
            reversing=saved.reversing==true,destinations=saved.destinations,boarded=saved.boarded,
            alighted=saved.alighted,totalBoarding=saved.totalBoarding,totalAlighting=saved.totalAlighting,
            closeTimer=saved.closeTimer,plan=plan,signature=signature(),completionTaken=saved.completionTaken==true}
        assert(saved.boarded<=saved.totalBoarding and saved.alighted<=saved.totalAlighting,"乘降进度无效")
        if legacy then
            ---@class LegacyPassengerDoorPath
            ---@field id number
            ---@field position number[]
            ---@field targets number[][]
            local savedById={} ---@type table<string,LegacyPassengerDoorPath>
            for _,item in ipairs(data.actors) do savedById[tostring(item.id)]=item end
            for _,actor in ipairs(actors_) do
                local old=savedById[tostring(actor.id)] --[[@as LegacyPassengerDoorPath?]]
                if old and not actor.completed and actor.state~="leaving" and actor.state~="gone" then
                    -- 旧reverse档可能仍在旧正线/侧线，单纯平移或clamp世界横距会把
                    -- 门内锚留在台上。保留身份/完成计数，只将未完成跨门段按实际
                    -- 门计划重绑定；段内进度由旧相邻目标的投影比例迁移。
                    local door=plan.doors[actor.doorId]
                    if not door then
                        door=nearestDoor(actor,plan.doors,{})
                    end
                    actor.doorId=door.id
                    if actor.state=="walking_to_door" or actor.state=="alighting" then
                        local targets=actor.kind=="alighting" and {door.position,door.edge,door.clear}
                            or {door.clear,door.edge,door.position,door.inside}
                        local index=math.max(1,math.min(#targets,actor.targetIndex))
                        ---@param v number[]
                        ---@return Vector3
                        local function oldPoint(v)
                            local px,py,pz=assert(v[1]),assert(v[2]),assert(v[3])
                            local p=Vector3(px,py,pz)
                            return legacyGeometry and Route.TransformLegacyPosition(p) or p
                        end
                        if index>1 and old.targets[index-1] and old.targets[index] then
                            local from,to=oldPoint(old.targets[index-1]),oldPoint(old.targets[index])
                            local delta=to-from
                            local lengthSquared=delta:LengthSquared()
                            local progress=lengthSquared>.000001 and math.max(0,math.min(1,
                                (oldPoint(old.position)-from):DotProduct(delta)/lengthSquared)) or 0
                            local start=assert(targets[index-1])
                            actor.position=start+(assert(targets[index])-start)*progress
                        elseif actor.kind=="alighting" and old.targets[1] and old.targets[2] then
                            local oldDoor,oldEdge=oldPoint(old.targets[1]),oldPoint(old.targets[2])
                            local outward=oldEdge-oldDoor
                            if outward:LengthSquared()>.000001 then
                                local oldInside=oldDoor-outward:Normalized()*.75
                                local delta=oldDoor-oldInside
                                local progress=math.max(0,math.min(1,(oldPoint(old.position)-oldInside):DotProduct(delta)/delta:LengthSquared()))
                                actor.position=door.inside+(door.position-door.inside)*progress
                            end
                        end
                        actor.targets,actor.targetIndex,actor.walking=targets,index,true
                    end
                end
            end
        end
    end
    PassengerService.UpdateVisuals(0)
end
return PassengerService
