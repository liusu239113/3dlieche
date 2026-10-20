-- 狂暴交通独立模拟；普通Traffic/TrafficVisuals完全不进入本模块的更新路径。
-- 基于既有3D scene scaffold的生命周期与共享MDL池；不创建整列Bullet刚体。
--
-- 安全设计（米/秒；先设计后实现）：
--   正向0/2: [尾|8节完整编组|头] --> 95m净空 --> [前车尾|...]
--   反向1/5: <-- [头|8节完整编组|尾]，绝不随机逆行或车下换岔。
-- 同方向main/siding共享纵向保守区段预约；合流前就按全编组包络排队，
-- 每个尖轨入口/出口另记录排他占用，最后一节清尾才释放。不同方向物理双线隔离。
-- NPC追随玩家/停车残编组，巡航不进入NPC撞击处理；玩家真实接触才建立因果族。
-- 碰撞OBB：+Z [尾|===== 长L/宽W/高H =====|头]，质心旋转；前后支点弦含真实纵坡，
-- 轨上yaw+pitch/roll=0。15轴连续SAT避免高速对穿/旁线误撞；静止/分离接触不刷分。
-- 玩家触发抛体 -> 真实二次接触 -> 有界连锁；地形接触最多两次反弹，8s残骸清理。
-- 每代pair锁存20s、最多192节、32条音频事件、8组共享MDL池，不会凭空累分或无限陈尸。
local Train = require "train.Train"
local Route = require "world.Route"
local RailNetwork = require "world.RailNetwork"
local Catalog = require "config.TrainCatalog"
local GameConfig = require "config.GameConfig"
local RollingStock = require "train.RollingStock"
local NightLighting = require "world.NightLighting"
local Terrain = require "world.Terrain"
local Rage = {}

local STEP, COUNT, CAR_COUNT, MAX_VISIBLE = .02, 8, 8, 3
local RANGE, COLLISION_RANGE, RECYCLE_RANGE = 1850, 2300, 4200
local CHAIN_WINDOW, MAX_CHAIN, GRAVITY = 8, 192, 9.81
local GAP, BRAKE, ACCEL = 95, .85, .55
local WRECK_LIFE, DAMAGE_LIFE, MAX_EVENTS = 8, 16, 32

---@class RageCar
---@field id string
---@field profile string
---@field reverse boolean
---@field offset number
---@field length number
---@field width number
---@field height number
---@field pivot number
---@field state string rail|flying|wreck|cleared
---@field position Vector3 质心
---@field previous Vector3
---@field rotation Quaternion
---@field velocity Vector3
---@field angular Vector3 degrees/sec
---@field half Vector3
---@field axes Vector3[]
---@field floor number
---@field age number
---@field bounces integer
---@field launches integer
---@field chain integer
---@field generation integer
---@field railS number
---@class RageVehicle
---@field id string
---@field entry TrainCatalogEntry
---@field dir number
---@field lane integer
---@field pathKey string
---@field s number 头车中心
---@field previousS number
---@field speedMs number unsigned
---@field cruiseMs number
---@field length number
---@field cars RageCar[]
---@field active boolean
---@field visible boolean
---@field generation integer
---@field retireAge number
---@field damagedAt number
---@field held boolean
---@field move number
---@field nextSpeed number
---@field lo number
---@field hi number
---@class RagePoolSlot
---@field root Node
---@field nodes Node[]
---@field drawables StaticModel[]
---@field vehicle string
---@field entry string
---@field ready boolean
---@field age number
---@field lamp Node?
---@field bulbs Node[]?
---@field light Light?
---@class RageResource
---@field model Model
---@field materials Material[]
---@class RageChain
---@field size integer
---@field last number
---@field members table<string,boolean>
---@field player boolean
---@class RageImpactEvent
---@field sequence integer
---@field position Vector3
---@field strength number 相对接触/落地法向速度 m/s
---@field kind string head_on|rear_end|merge|air_strike|landing
---@field time number
---@class RageConflictZone
---@field key string
---@field first number
---@field last number
---@field baseLane integer
---@field owner string?

---@type RageVehicle[]
local vehicles_ = {}
---@type RagePoolSlot[]
local pool_ = {}
---@type table<string,RageResource>
local resources_ = {}
---@type table<number,RageChain>
local chains_ = {}
---@type table<string,number>
local contacts_ = {}
---@type table<string,RageCar>
local playerHistory_ = {}
---@type RageImpactEvent[]
local impactEvents_ = {}
---@type RageConflictZone[]
local zones_ = {}
local impactSequence_, droppedEvents_, clearedCars_ = 0, 0, 0
---@type TrafficPlayerInput
local playerInput_ = {s=0,speedMs=0,length=220}
---@type Node?
local root_ = nil
---@type Material?
local blueMaterial_ = nil
local elapsed_, accumulator_, refresh_, sequence_, seed_ = 0, 0, 0, 0, 8941
local playerS_, playerVelocity_ = 0.0, 0.0
local playerLength_, lastPlayerS_, lastPlayerTime_ = 220.0, 0.0, 0.0
local initialized_, visibleLimit_ = false, MAX_VISIBLE
local modelBinds_, errors_, lastError_ = 0, 0, ""
local lastCleanup_ = 0.0
local stats_ = {score=0,impacts=0,playerImpacts=0,npcImpacts=0,chains=0,maxChain=0,
    currentChain=0,diversity=0,airborne=0,launches=0,landings=0,lastEvent="",
    eventText="狂暴交通上线 · 高密度混合车队",lastImpactStrength=0.0,lastImpactAt=-100.0}
---@type table<string,boolean>
local kinds_ = {}

local function clamp(v,lo,hi) return math.max(lo,math.min(hi,v)) end
local function random()
    seed_ = (seed_*48271)%2147483647
    return seed_/2147483647
end
local function finite(v) return type(v)=="number" and v==v and math.abs(v)<1e15 end

---@param car RageCar
local function axes(car)
    car.axes = {car.rotation*Vector3.RIGHT,car.rotation*Vector3.UP,car.rotation*Vector3.FORWARD}
end

---@param s number
---@param lane integer
---@param path string?
---@return Vector3,Vector3,number
local function sample(s,lane,path)
    return RailNetwork.Sample(s,lane,path)
end

---@param entry TrainCatalogEntry
---@param index integer
---@return string,boolean
local function profileFor(entry,index)
    if entry.kind~="emu" then return index==1 and entry.head or entry.id.."_coach",false end
    local role=index==1 and "head" or (index==CAR_COUNT and "tail" or "middle")
    local spec=entry.roles and entry.roles[role]
    return spec and spec.profile or (index==1 and entry.head or assert(entry.middle)),spec and spec.reverse==true or false
end

---@param car RageCar
---@param vehicle RageVehicle
local function railPose(car,vehicle)
    local center=vehicle.s+vehicle.dir*car.offset
    local front=sample(center+vehicle.dir*car.pivot,vehicle.lane,vehicle.pathKey)
    local rear=sample(center-vehicle.dir*car.pivot,vehicle.lane,vehicle.pathKey)
    local chord=front-rear
    local horizontal=math.sqrt(chord.x*chord.x+chord.z*chord.z)
    local rotation=Quaternion(-math.deg(math.atan(chord.y,horizontal)),math.deg(math.atan(chord.x,chord.z)),0)
    local base=(front+rear)*.5
    car.position=base+rotation*Vector3(0,car.height*.5,0)
    car.rotation,car.railS,car.floor=rotation,center,base.y
    car.velocity=chord:Normalized()*(vehicle.speedMs)
    axes(car)
end

---@param vehicle RageVehicle
local function updateHull(vehicle)
    local first,last=vehicle.cars[1],vehicle.cars[#vehicle.cars]
    local front=vehicle.s+vehicle.dir*first.length*.5
    local rear=vehicle.s+vehicle.dir*(last.offset-last.length*.5)
    vehicle.lo,vehicle.hi=math.min(front,rear),math.max(front,rear)
end

---@param entry TrainCatalogEntry
---@param id string
---@return RageVehicle
local function makeVehicle(entry,id)
    local vehicle={id=id,entry=entry,dir=1,lane=0,pathKey="main",s=0,previousS=0,
        speedMs=0,cruiseMs=0,length=0,cars={},active=false,visible=false,generation=0,
        retireAge=0,damagedAt=-1,held=false,move=0,nextSpeed=0,lo=0,hi=0} --[[@as RageVehicle]]
    local offset,previousLength=0.0,0.0
    for index=1,CAR_COUNT do
        local profile,reverse=profileFor(entry,index)
        local spec=Catalog.Profiles[profile]
        -- blue_white的21m尺寸来自现有专用Locomotive；其他尺寸一律来自成品目录。
        local length=spec and spec.length or 21.0
        local width=spec and spec.width or 3.10
        local height=spec and spec.height or 4.10
        if index>1 then offset=offset-previousLength*.5-length*.5-entry.gap end
        local car={id=id..":"..index,profile=profile,reverse=reverse,offset=offset,
            length=length,width=width,height=height,pivot=spec and spec.pivot or 6.6,
            state="rail",position=Vector3.ZERO,previous=Vector3.ZERO,rotation=Quaternion(),
            velocity=Vector3.ZERO,angular=Vector3.ZERO,half=Vector3(width*.48,height*.5,length*.495),
            axes={Vector3.RIGHT,Vector3.UP,Vector3.FORWARD},floor=0,age=0,bounces=0,launches=0,
            chain=0,generation=0,railS=0} --[[@as RageCar]]
        vehicle.cars[#vehicle.cars+1]=car
        previousLength=length
    end
    vehicle.length=vehicle.cars[1].length*.5-offset+previousLength*.5
    return vehicle
end

---@param car RageCar
---@param axis Vector3
local function extent(car,axis)
    return math.abs(car.axes[1]:DotProduct(axis))*car.half.x
        +math.abs(car.axes[2]:DotProduct(axis))*car.half.y
        +math.abs(car.axes[3]:DotProduct(axis))*car.half.z
end

-- 连续SAT：在所有分离轴上求公共进入/离开时间，t∈[0,1]。
-- 不是单帧包围盒重叠，更不是宽度26m的球；平行5m双线保持物理隔离。
---@param a RageCar
---@param b RageCar
---@return boolean,number
local function swept(a,b)
    local delta0=b.previous-a.previous
    local delta1=b.position-a.position
    local move=delta1-delta0
    -- 廉价扫掠AABB筛选，窄相仅对少数真正相邻车节做15轴。
    for _,axis in ipairs({Vector3.RIGHT,Vector3.UP,Vector3.FORWARD}) do
        local radius=extent(a,axis)+extent(b,axis)+.02
        local p,q=delta0:DotProduct(axis),delta1:DotProduct(axis)
        if math.min(p,q)>radius or math.max(p,q)<-radius then return false,1 end
    end
    local tests={a.axes[1],a.axes[2],a.axes[3],b.axes[1],b.axes[2],b.axes[3]}
    for _,left in ipairs(a.axes) do
        for _,right in ipairs(b.axes) do
            local axis=left:CrossProduct(right)
            if axis:LengthSquared()>.000001 then tests[#tests+1]=axis:Normalized() end
        end
    end
    local enter,leave=0.0,1.0
    for _,axis in ipairs(tests) do
        local radius=extent(a,axis)+extent(b,axis)+.02
        local position,velocity=delta0:DotProduct(axis),move:DotProduct(axis)
        if math.abs(velocity)<.0000001 then
            if math.abs(position)>radius then return false,1 end
        else
            local low,high=(-radius-position)/velocity,(radius-position)/velocity
            if low>high then low,high=high,low end
            enter,leave=math.max(enter,low),math.min(leave,high)
            if enter>leave then return false,1 end
        end
    end
    return true,enter
end

local EVENT_TEXT={head_on="高速迎面撞击",rear_end="追尾抛飞",merge="道岔汇流碰撞",
    chain="冲量连锁传播",air_strike="腾空车体二次撞击",landing="车体反弹落地"}
local function kind(name)
    if not kinds_[name] then kinds_[name]=true;stats_.diversity=stats_.diversity+1 end
end
local function event(name,text)
    kind(name)
    stats_.lastEvent,stats_.eventText=name,text or EVENT_TEXT[name] or name
end

local function emitImpact(name,position,strength)
    impactSequence_=impactSequence_+1
    if #impactEvents_>=MAX_EVENTS then table.remove(impactEvents_,1);droppedEvents_=droppedEvents_+1 end
    impactEvents_[#impactEvents_+1]={sequence=impactSequence_,position=position,
        strength=clamp(strength,0,140),kind=name,time=elapsed_}
end

---@param id integer
---@param car RageCar
local function chainMember(id,car)
    local chain=chains_[id]
    if not chain then return end
    local key=car.id.."@"..car.generation
    if not chain.members[key] then
        chain.members[key]=true
        chain.size=math.min(MAX_CHAIN,chain.size+1)
    end
    chain.last=elapsed_
    stats_.maxChain=math.max(stats_.maxChain,chain.size)
    stats_.currentChain=chain.size
end

---@param car RageCar
---@param impulse Vector3
---@param strength number
---@param chain integer
---@return boolean
local function launch(car,impulse,strength,chain)
    if car.state~="rail" or car.launches>=1 then return false end
    car.state,car.age,car.bounces="flying",0,0
    car.launches,car.chain=car.launches+1,chain
    local sign=random()<.5 and -1 or 1
    local side=car.axes[1]*sign
    -- 一代只抛飞一次，残骸不复活；强度有上限，不把高速动能变成数百米散射。
    local carry=car.velocity*.18+impulse*.25
    local horizontal=Vector3(carry.x,0,carry.z)
    if horizontal:Length()>42 then horizontal=horizontal:Normalized()*42 end
    car.velocity=horizontal+side*clamp(2.5+strength*.035,2.5,7)
        +Vector3(0,clamp(4+strength*.07,4.5,14),0)
    car.angular=Vector3((random()-.5)*95,(random()-.5)*70,sign*(42+random()*55))
    stats_.launches=stats_.launches+1
    chainMember(chain,car)
    return true
end

---@param a RageCar
---@param b RageCar
---@param player boolean
---@param merge boolean
---@param toi number?
local function impact(a,b,player,merge,toi)
    if a.state=="cleared" or b.state=="cleared" or a.state=="wreck" or b.state=="wreck" then return end
    -- 因果门：正常NPC之间即使算法误差重叠，也绝不能凭空创建连锁/计分。
    local inherited=0
    for _,car in ipairs({a,b}) do
        local family=chains_[car.chain]
        if car.state=="flying" and family and family.player and elapsed_-family.last<=CHAIN_WINDOW then
            inherited=car.chain;break
        end
    end
    if not player and inherited==0 then return end
    if player and a.velocity:Length()<3 then return end
    if a.state~="rail" and b.state~="rail" then return end
    local keyA=a.id.."@"..a.generation
    local keyB=b.id.."@"..b.generation
    local key=keyA<keyB and keyA.."|"..keyB or keyB.."|"..keyA
    if contacts_[key] and contacts_[key]>elapsed_ then return end
    local relative=a.velocity-b.velocity
    local strength=clamp(relative:Length(),0,140)
    if strength<3 then return end
    local delta=b.previous-a.previous
    -- 分离中的重叠不计；在轨跟车/旁线不会因为并行切线有夹角而自爆。
    if delta:LengthSquared()>.01 and delta:DotProduct(relative)<=.01 then return end
    contacts_[key]=elapsed_+20
    local chain=inherited
    if chain==0 then
        if not player then return end
        sequence_=sequence_+1
        chain=sequence_
        chains_[chain]={size=0,last=elapsed_,members={},player=true}
    end
    local airborne=a.state=="flying" or b.state=="flying"
    local alignment=a.velocity:DotProduct(b.velocity)
    local name=airborne and "air_strike" or (merge and "merge" or (alignment<0 and "head_on" or "rear_end"))
    local velocityA,velocityB=a.velocity,b.velocity
    local launched=launch(b,velocityA,strength,chain)
    if not player then launched=launch(a,velocityB,strength,chain) or launched end
    if not launched then return end
    if a.chain~=0 then chainMember(chain,a) end
    if b.chain~=0 then chainMember(chain,b) end
    stats_.impacts=stats_.impacts+1
    if player then stats_.playerImpacts=stats_.playerImpacts+1 else stats_.npcImpacts=stats_.npcImpacts+1 end
    if inherited~=0 then stats_.chains=stats_.chains+1;kind("chain") end
    local count=chains_[chain].size
    local points=math.floor(strength*4)*(1+math.min(8,math.max(0,count-1)))
    stats_.score=stats_.score+points
    stats_.lastImpactStrength,stats_.lastImpactAt=strength,elapsed_
    local t=toi or 1
    local pointA=a.previous+(a.position-a.previous)*t
    local pointB=b.previous+(b.position-b.previous)*t
    emitImpact(name,(pointA+pointB)*.5,strength)
    event(name,string.format("%s · %d节连锁 · +%d分",EVENT_TEXT[name],count,points))
    if stats_.impacts<=12 or stats_.impacts%20==0 then
        print(string.format("[RageTraffic] playerCausal %s %s/%s %.1fm/s chain=%d size=%d score=%d",
            name,a.id,b.id,strength,chain,count,stats_.score))
    end
end

local function baseLane(lane) return (lane==1 or lane==5) and 1 or 0 end
local function playerLane(s) return playerInput_.lane or RailNetwork.GetPlayerLane(s) end

-- 统一几何元数据；旧线回归无GetConflictZones时只构造站场等价尖轨区。
local function refreshZones()
    zones_={}
    if RailNetwork.GetConflictZones then
        for _,zone in ipairs(RailNetwork.GetConflictZones()) do
            zones_[#zones_+1]={key=zone.key,first=zone.first,last=zone.last,baseLane=zone.baseLane}
        end
    else
        for _,station in ipairs(Route.GetStations()) do
            local routing=RailNetwork.GetStationRouting(station.index)
            if routing then
                for _,base in ipairs({0,1}) do
                    local span=base==1 and routing.up or routing
                    for _,side in ipairs({"entry","exit"}) do
                        zones_[#zones_+1]={key=station.index..":"..base..":"..side,baseLane=base,
                            first=side=="entry" and span.first or span.plateauLast,
                            last=side=="entry" and span.plateauFirst or span.last}
                    end
                end
            end
        end
    end
end
local function overlaps(lo,hi,first,last) return hi>=first and lo<=last end

---@param vehicle RageVehicle
---@param at number
---@param ordinal integer
---@return boolean
local function dispatch(vehicle,at,ordinal)
    local length=Route.GetLength()
    if length<vehicle.length*4 then return false end
    local paths=RailNetwork.GetOperatingPaths()
    local path=paths[(ordinal-1)%#paths+1]
    local lane,dir=path.lane,path.dir
    local first=vehicle.length+45
    local last=length-vehicle.length-45
    for attempt=1,32 do
        local shift=attempt==1 and 0 or (attempt%2==0 and -1 or 1)*math.ceil((attempt-1)/2)*420
        local s=clamp(at+shift,first,last)
        vehicle.s,vehicle.dir,vehicle.lane,vehicle.pathKey=s,dir,lane,path.key or "main"
        updateHull(vehicle)
        -- 出库只在无全编组占用处；共享同向干线即便此处侧线分开仍保留预约。
        local safe=not overlaps(vehicle.lo,vehicle.hi,playerS_-playerLength_-120,playerS_+140)
        if elapsed_>0 and math.max(0,vehicle.lo-playerS_,playerS_-vehicle.hi)<RANGE+150 then safe=false end
        for _,other in ipairs(vehicles_) do
            if other~=vehicle and other.active then
                if baseLane(other.lane)==baseLane(lane) and overlaps(vehicle.lo-GAP,vehicle.hi+GAP,other.lo,other.hi) then safe=false;break end
                for _,zone in ipairs(zones_) do
                    if (zone.baseLane<0 or (zone.baseLane==baseLane(lane) and zone.baseLane==baseLane(other.lane)))
                        and overlaps(vehicle.lo,vehicle.hi,zone.first,zone.last)
                        and overlaps(other.lo,other.hi,zone.first,zone.last) then safe=false;break end
                end
            end
        end
        if safe then
            vehicle.generation=vehicle.generation+1
            vehicle.previousS=s
            vehicle.cruiseMs=clamp(vehicle.entry.operatingSpeedKmh/3.6*(.70+random()*.18),21,85)
            -- 站场/岔区速度另受调度控制；起步使用0防出生位置违反制动包络。
            vehicle.speedMs,vehicle.nextSpeed,vehicle.move=0,0,0
            vehicle.active,vehicle.visible,vehicle.retireAge,vehicle.damagedAt=true,false,0,-1
            for _,car in ipairs(vehicle.cars) do
                car.state,car.age,car.bounces,car.launches,car.chain="rail",0,0,0,0
                car.generation=vehicle.generation
                railPose(car,vehicle);car.previous=car.position
            end
            return true
        end
    end
    vehicle.active=false
    return false
end

-- 两阶段确定性调度：先按行车方向从前到后算命令，再统一写位置，不依赖数组顺序。
-- 侧线不承担危险超车：全同向干线预留纵向槽，岔前排队即可保证任何下游合流安全。
local function schedule(dt)
    local running={} ---@type RageVehicle[]
    for _,zone in ipairs(zones_) do zone.owner=nil end
    for _,vehicle in ipairs(vehicles_) do
        vehicle.move,vehicle.nextSpeed=0,vehicle.speedMs
        if vehicle.active then
            local intact=true
            for _,car in ipairs(vehicle.cars) do if car.state~="rail" then intact=false end end
            if not intact and vehicle.damagedAt<0 then vehicle.damagedAt=elapsed_ end
            if vehicle.damagedAt>=0 then vehicle.speedMs,vehicle.nextSpeed=0,0 end
            running[#running+1]=vehicle
            for _,zone in ipairs(zones_) do
                if (zone.baseLane<0 or zone.baseLane==baseLane(vehicle.lane))
                    and overlaps(vehicle.lo,vehicle.hi,zone.first,zone.last) then zone.owner=vehicle.id end
            end
        end
    end
    local playerLo,playerHi=playerS_-playerLength_,playerS_+(playerInput_.frontOffset or 16)
    for _,zone in ipairs(zones_) do
        if overlaps(playerLo,playerHi,zone.first,zone.last)
            and (zone.baseLane<0 or zone.baseLane==baseLane(playerLane((zone.first+zone.last)*.5))) then zone.owner="player" end
    end
    table.sort(running,function(a,b)
        if a.dir~=b.dir then return a.dir>b.dir end
        if a.s==b.s then return a.id<b.id end
        return a.dir*a.s>b.dir*b.s
    end)
    for _,vehicle in ipairs(running) do
        local dir=vehicle.dir
        local nose=dir>0 and vehicle.hi or vehicle.lo
        local remaining=dir>0 and Route.GetLength()-25-nose or nose-25
        local leadSpeed=0.0
        for _,other in ipairs(running) do
            if other~=vehicle and baseLane(other.lane)==baseLane(vehicle.lane) then
                local rear=dir>0 and other.lo or other.hi
                local gap=dir*(rear-nose)-GAP
                if dir*(other.s-vehicle.s)>0 and gap<remaining then
                    remaining,leadSpeed=gap,other.nextSpeed
                    -- 已计算前车未来移动，允许队列同步前行但仍不能越过安全尾距。
                    remaining=remaining+other.move
                end
            end
        end
        local playerRear=dir>0 and playerLo or playerHi
        local gap=dir*(playerRear-nose)-GAP
        if dir*(playerS_-vehicle.s)>0 and gap<remaining
            and baseLane(playerLane(nose))==baseLane(vehicle.lane) then
            remaining,leadSpeed=gap,math.max(0,dir*playerVelocity_)
        end
        -- 预约冲突喉区：当前占用者独占直到清尾。无占用时优先前车请求。
        for _,zone in ipairs(zones_) do
            if zone.baseLane<0 or zone.baseLane==baseLane(vehicle.lane) then
                local edge=dir>0 and zone.first or zone.last
                local distance=dir*(edge-nose)
                if distance>=0 and distance<vehicle.speedMs*vehicle.speedMs/(2*BRAKE)+GAP+80 then
                    if zone.owner and zone.owner~=vehicle.id then
                        local holder=nil ---@type RageVehicle?
                        for _,other in ipairs(running) do if other.id==zone.owner then holder=other;break end end
                        -- 若持有人就在后方不能倒锁前车；前方持有人则等其完整清尾。
                        if not holder or dir*(holder.s-vehicle.s)>0 or holder.dir~=dir then
                            if distance-15<remaining then remaining,leadSpeed=distance-15,0 end
                        end
                    else zone.owner=vehicle.id end
                end
            end
        end
        local target=vehicle.cruiseMs
        for _,car in ipairs(vehicle.cars) do
            if RailNetwork.GetPathLane(car.railS,vehicle.lane,vehicle.pathKey)~=baseLane(vehicle.lane) then target=math.min(target,15) end
        end
        local margin=math.max(0,remaining-vehicle.speedMs*.7)
        target=math.min(target,math.sqrt(math.max(0,leadSpeed*leadSpeed+2*BRAKE*margin)))
        if vehicle.damagedAt>=0 then target=0 end
        local speed=vehicle.speedMs
        local nextSpeed=target<speed and math.max(target,speed-BRAKE*dt) or math.min(target,speed+ACCEL*dt)
        local _,tangent=sample(vehicle.s,vehicle.lane,vehicle.pathKey)
        local horizontalFactor=math.sqrt(tangent.x*tangent.x+tangent.z*tangent.z)
        local movement=math.min(math.max(0,remaining),math.max(0,(speed+nextSpeed)*.5*dt*horizontalFactor))
        if movement+1e-6<(speed+nextSpeed)*.5*dt*horizontalFactor then nextSpeed=0 end
        vehicle.nextSpeed,vehicle.move,vehicle.held=nextSpeed,movement,target<.1
    end
end

---@param car RageCar
---@param dt number
local function ballistic(car,dt)
    car.age=car.age+dt
    if car.state=="wreck" then
        if car.age>=WRECK_LIFE then car.state="cleared";clearedCars_=clearedCars_+1 end
        return
    end
    if car.state~="flying" then return end
    car.position=car.position+car.velocity*dt+Vector3(0,-GRAVITY*.5*dt*dt,0)
    car.velocity=car.velocity+Vector3(0,-GRAVITY*dt,0)
    car.rotation=Quaternion(car.angular.x*dt,car.angular.y*dt,car.angular.z*dt)*car.rotation
    axes(car)
    -- 使用实际地形高度：桥上被抛离后落向桥谷，不能悬停在出生轨基平面。
    if Terrain.GetGroundHeight then car.floor=Terrain.GetGroundHeight(car.position.x,car.position.z)
    elseif Route.ProjectApprox then
        local s=Route.ProjectApprox(car.position)
        car.floor=sample(s,0).y-.25
    end
    local support=extent(car,Vector3.UP)
    if car.position.y-support<=car.floor and car.velocity.y<0 then
        local pos=car.position
        car.position=Vector3(pos.x,car.floor+support,pos.z)
        car.bounces=car.bounces+1
        stats_.landings=stats_.landings+1
        kind("landing")
        local velocity=car.velocity
        emitImpact("landing",Vector3(pos.x,car.floor,pos.z),-velocity.y)
        car.velocity=Vector3(velocity.x*.42,-velocity.y*.20,velocity.z*.42)
        car.angular=car.angular*.40
        if car.bounces>=2 or car.velocity.y<1.8 then
            car.state,car.age="wreck",0
            car.velocity,car.angular=Vector3.ZERO,Vector3.ZERO
        end
    elseif car.age>9 then
        -- 深谷/离开有效地形也必须有界回收；超时不是接触，不发音效/分数。
        car.state,car.age="cleared",0
        car.velocity,car.angular=Vector3.ZERO,Vector3.ZERO
        clearedCars_=clearedCars_+1
    end
end

local function updateStats()
    local airborne,current=0,0
    for _,vehicle in ipairs(vehicles_) do
        if vehicle.active then
            for _,car in ipairs(vehicle.cars) do if car.state=="flying" then airborne=airborne+1 end end
        end
    end
    for _,chain in pairs(chains_) do
        if elapsed_-chain.last<=CHAIN_WINDOW then current=math.max(current,chain.size) end
    end
    stats_.airborne,stats_.currentChain=airborne,current
end

---@param dt number
local function step(dt)
    elapsed_=elapsed_+dt
    schedule(dt)
    local near={} ---@type {car:RageCar,vehicle:RageVehicle}[]
    for index,vehicle in ipairs(vehicles_) do
        if vehicle.active then
            vehicle.previousS=vehicle.s
            vehicle.s=vehicle.s+vehicle.dir*vehicle.move
            vehicle.speedMs=vehicle.nextSpeed
            local hasRail,hasFlying=false,false
            for _,car in ipairs(vehicle.cars) do
                car.previous=car.position
                if car.state=="rail" then hasRail=true;railPose(car,vehicle) else ballistic(car,dt) end
                if car.state=="flying" then hasFlying=true end
                if car.state~="cleared" and car.state~="wreck"
                    and (math.abs(vehicle.s-playerS_)<=COLLISION_RANGE or car.state=="flying") then
                    near[#near+1]={car=car,vehicle=vehicle}
                end
            end
            updateHull(vehicle)
            if not hasRail and not hasFlying then vehicle.retireAge=vehicle.retireAge+dt else vehicle.retireAge=0 end
            local distance=math.max(0,vehicle.lo-playerS_,playerS_-vehicle.hi)
            -- 残编组不永久卡住线路：停止保护后有界淡出，绝不在原地重生。
            if vehicle.damagedAt>=0 and elapsed_-vehicle.damagedAt>DAMAGE_LIFE and not hasFlying then
                for _,car in ipairs(vehicle.cars) do
                    if car.state~="cleared" then car.state="cleared";clearedCars_=clearedCars_+1 end
                end
                vehicle.active=false
            elseif not vehicle.visible and (distance>RECYCLE_RANGE
                or (vehicle.speedMs==0 and distance>RANGE+500)) then vehicle.active=false end
        else
            -- 只在视距外安全出库，不把残骸闪回玩家面前；端点无自动逆行。
            local direction=playerVelocity_<-.01 and -1 or 1
            local ahead=playerS_+direction*(RANGE+700+(index%6)*410)
            if ahead>vehicle.length+45 and ahead<Route.GetLength()-vehicle.length-45 then dispatch(vehicle,ahead,index) end
        end
    end
    -- 只用玩家因果抛体做二次碰撞。正常轨上车对完全跳过，既安全也避免192²无效SAT。
    if stats_.airborne>0 then
        for i=1,#near do
            local a=near[i]
            for j=i+1,#near do
                local b=near[j]
                if (a.car.state=="flying" or b.car.state=="flying")
                    and (a.car.state=="rail" or b.car.state=="rail")
                    and (a.car.position-b.car.position):LengthSquared()<70*70 then
                    local contact,toi=swept(a.car,b.car)
                    if contact then impact(a.car,b.car,false,a.vehicle.lane~=b.vehicle.lane,toi) end
                end
            end
        end
    end
    if elapsed_-lastCleanup_>5 then
        lastCleanup_=elapsed_
        for key,expiry in pairs(contacts_) do if expiry<elapsed_ then contacts_[key]=nil end end
        for key,chain in pairs(chains_) do if elapsed_-chain.last>30 then chains_[key]=nil end end
    end
    updateStats()
end

---@param scene Scene?
function Rage.Init(scene)
    Rage.Shutdown()
    if scene then root_=scene:CreateChild("RageTraffic",LOCAL) end
    initialized_=true
end

---@param s number
---@param length number?
function Rage.Reset(s,length)
    vehicles_,contacts_,chains_,playerHistory_,impactEvents_={},{},{},{},{}
    droppedEvents_,clearedCars_=0,0
    elapsed_,accumulator_,refresh_,sequence_,seed_,lastCleanup_=0,0,0,0,8941,0
    playerS_,lastPlayerS_,playerLength_,lastPlayerTime_=s,s,length or 220,0
    playerInput_={s=s,speedMs=0,length=length or 220}
    refreshZones()
    kinds_={}
    stats_={score=0,impacts=0,playerImpacts=0,npcImpacts=0,chains=0,maxChain=0,
        currentChain=0,diversity=0,airborne=0,launches=0,landings=0,lastEvent="",
        eventText="狂暴交通上线 · 少量高速目标 · 玩家因果碰撞",lastImpactStrength=0,lastImpactAt=-100}
    local rules=GameConfig.ModeRules or {}
    local count=math.floor(clamp(rules.TrafficLogicCount or COUNT,4,COUNT))
    visibleLimit_=math.floor(clamp(rules.TrafficVisibleCount or MAX_VISIBLE,1,MAX_VISIBLE))
    for _,slot in ipairs(pool_) do slot.root.enabled=false;slot.vehicle="" end
    for index=1,count do
        local entry=assert(Catalog.Entries[(index-1)%#Catalog.Entries+1])
        local vehicle=makeVehicle(entry,"R"..string.format("%02d",index))
        vehicles_[#vehicles_+1]=vehicle
        local band=math.floor((index-1)/4)
        local offset=440+band*680+((index-1)%4)*190
        if index%6==0 then offset=-offset end
        dispatch(vehicle,s+offset,index)
    end
    print(string.format("[RageTraffic] %d列少量高速逻辑列车 / 每列%d节 / 最多%d组近场池，普通交通隔离",count,CAR_COUNT,visibleLimit_))
end

---@param dt number
---@param data TrafficPlayerInput
function Rage.Update(dt,data)
    if not initialized_ or not finite(dt) or dt<=0 then return end
    playerInput_=data
    playerS_,playerVelocity_,playerLength_=data.s,data.speedMs or data.speed or 0,data.length or 220
    accumulator_=accumulator_+math.min(dt,1)
    local count=math.min(50,math.floor((accumulator_+.00000001)/STEP))
    for _=1,count do step(STEP) end
    accumulator_=math.max(0,accumulator_-count*STEP)
end

-- 玩家只提供只读姿态，绝不调用Derail/EmergencyBrake/SetThrottle/写car.node。
---@param data TrafficPlayerInput
function Rage.CheckPlayerCollision(data)
    if not initialized_ then return end
    local dt=math.max(STEP,elapsed_-lastPlayerTime_)
    local velocity=data.speedMs or data.speed or 0
    local teleported=math.abs(data.s-lastPlayerS_)>math.max(50,math.abs(velocity)*dt*4+10)
    local selected=Train.GetSelectedId()
    for index,source in ipairs(Train.GetCars()) do
        local id="player:"..selected..":"..index
        local s=data.s+(source.offset or 0)
        local pivot=source.pivot or 6.6
        -- 生产逐支点查玩家锁存路径；data.lane仅SetPlayerOverride测试夹具可显式提供。
        -- 中心/yaw不等于真实弯道车体弦，碰撞与Train.UpdateVisuals保持同一支点算法。
        local front=Train.GetTrackSample(s+pivot)
        local rear=Train.GetTrackSample(s-pivot)
        if data.lane~=nil then front,rear=sample(s+pivot,data.lane),sample(s-pivot,data.lane) end
        local position=(front+rear)*.5
        local chord=front-rear
        local yaw=math.deg(math.atan(chord.x,chord.z))
        local pitch=-math.deg(math.atan(chord.y,math.sqrt(chord.x*chord.x+chord.z*chord.z)))
        local rotation=Quaternion(pitch,yaw,0)
        local height=(Catalog.Profiles[source.profile] and Catalog.Profiles[source.profile].height) or 4.1
        local width=(Catalog.Profiles[source.profile] and Catalog.Profiles[source.profile].width) or 3.2
        local center=position+rotation*Vector3(0,height*.5,0)
        local previous=playerHistory_[id]
        local car={id=id,profile=source.profile or selected,reverse=false,offset=source.offset or 0,
            length=source.length,width=width,height=height,pivot=source.pivot or 6.6,state="rail",
            position=center,previous=not teleported and previous and previous.position or center,
            rotation=rotation,velocity=Vector3.ZERO,angular=Vector3.ZERO,
            half=Vector3(width*.48,height*.5,source.length*.495),axes={},floor=position.y,
            age=0,bounces=0,launches=0,chain=0,generation=0,railS=s} --[[@as RageCar]]
        axes(car)
        car.velocity=(car.rotation*Vector3.FORWARD)*velocity
        if not teleported then
            for _,vehicle in ipairs(vehicles_) do
                if vehicle.active and math.abs(vehicle.s-data.s)<COLLISION_RANGE then
                    for _,other in ipairs(vehicle.cars) do
                        if other.state=="rail" and (car.position-other.position):LengthSquared()<180*180 then
                            local contact,toi=swept(car,other)
                            if contact then impact(car,other,true,false,toi) end
                        end
                    end
                end
            end
        end
        playerHistory_[id]=car
    end
    lastPlayerS_,lastPlayerTime_=data.s,elapsed_
    updateStats()
end

-- 资源只读、共享引用；不用Locomotive.Build（它会覆盖玩家驾驶室外壳登记）。
---@param id string
---@return RageResource
local function resource(id)
    if resources_[id] then return resources_[id] end
    local result=nil ---@type RageResource?
    if id=="blue_white" then
        local asset=assert(Catalog.Assets[id])
        local model=RollingStock.LoadBakedModel(id)
        local material=Material:new()
        material:SetTechnique(0,assert(cache:GetResource("Technique","Techniques/PBR/PBRDiffNormal.xml")))
        material:SetTexture(TU_DIFFUSE,assert(cache:GetResource("Texture2D",asset.diffusePath)))
        material:SetTexture(TU_NORMAL,assert(cache:GetResource("Texture2D",asset.normalPath)))
        material:SetShaderParameter("Metallic",Variant(.12))
        material:SetShaderParameter("Roughness",Variant(.62))
        blueMaterial_=material
        result={model=model,materials={material}}
    else
        local ok,message=RollingStock.Prepare(id)
        assert(ok,message)
        local prepared=assert(RollingStock.GetCalibration(id))
        result={model=prepared.model,materials=prepared.materials}
    end
    resources_[id]=result
    return result
end

---@param slot RagePoolSlot
---@param vehicle RageVehicle
---@param index integer
local function bindCar(slot,vehicle,index)
    local car=vehicle.cars[index]
    local res=resource(car.profile)
    local node=slot.nodes[index]
    local drawable=slot.drawables[index]
    if not node then
        node=slot.root:CreateChild("Car"..index,LOCAL)
        drawable=node:CreateComponent("StaticModel")
        slot.nodes[index],slot.drawables[index]=node,drawable
    end
    drawable.model=res.model
    for g=0,res.model.numGeometries-1 do drawable:SetMaterial(g,assert(res.materials[g+1])) end
    drawable.castShadows,drawable.viewMask,drawable.drawDistance=false,1,RANGE+200
    drawable.lodBias=.16
    modelBinds_=modelBinds_+1
end

---@param slot RagePoolSlot
local function createLamps(slot)
    if slot.lamp then return end
    local lamp=slot.root:CreateChild("TrafficHeadlight",LOCAL)
    local light=lamp:CreateComponent("Light")
    light.lightType,light.color=LIGHT_SPOT,Color(1,.88,.66)
    light.brightness,light.range,light.fov,light.aspectRatio=350,90,26,1.3
    light.outerConeAngle,light.innerConeAngle=13,7.8
    light.castShadows,light.affectVolumetricFog=false,false
    light.lightMask,light.viewMask=2,3
    light.enabled=false
    local bulbs={} ---@type Node[]
    local model=assert(cache:GetResource("Model","Models/Sphere.mdl")) -- 文档实测直径1m
    for _=1,2 do
        local bulb=slot.root:CreateChild("TrafficWarmMarker",LOCAL)
        bulb.scale=Vector3(.18,.18,.10)
        local drawable=bulb:CreateComponent("StaticModel")
        drawable.model=model
        drawable:SetMaterial(NightLighting.GetBulbMaterial("rage_traffic"))
        drawable.castShadows,drawable.viewMask,drawable.drawDistance=false,3,RANGE
        bulbs[#bulbs+1]=bulb
    end
    slot.lamp,slot.light,slot.bulbs=lamp,light,bulbs
end

---@param dt number
function Rage.UpdateVisuals(dt)
    if not root_ then return end
    refresh_=refresh_+math.max(0,dt)
    if refresh_>=.15 or #pool_==0 then
        refresh_=0
        local candidates={} ---@type {vehicle:RageVehicle,distance:number}[]
        for _,vehicle in ipairs(vehicles_) do
            vehicle.visible=false
            if vehicle.active then
                local distance=math.max(0,vehicle.lo-playerS_,playerS_-vehicle.hi)
                if distance<=RANGE then
                    for _,car in ipairs(vehicle.cars) do if car.state=="flying" then distance=distance-500;break end end
                    candidates[#candidates+1]={vehicle=vehicle,distance=distance}
                end
            end
        end
        table.sort(candidates,function(a,b) return a.distance<b.distance end)
        local wanted={} ---@type table<string,boolean>
        for i=1,math.min(visibleLimit_,#candidates) do wanted[candidates[i].vehicle.id]=true end
        for _,slot in ipairs(pool_) do
            if not wanted[slot.vehicle] then slot.root.enabled=false;slot.vehicle="" end
        end
        for i=1,math.min(visibleLimit_,#candidates) do
            local vehicle=candidates[i].vehicle
            local selected=nil ---@type RagePoolSlot?
            for _,slot in ipairs(pool_) do if slot.vehicle==vehicle.id then selected=slot;break end end
            if not selected then
                for _,slot in ipairs(pool_) do if slot.vehicle=="" then selected=slot;break end end
                if not selected and #pool_<visibleLimit_ then
                    selected={root=root_:CreateChild("Pool"..(#pool_+1),LOCAL),nodes={},drawables={},
                        vehicle="",entry="",ready=false,age=0}
                    pool_[#pool_+1]=selected
                end
                if selected then
                    selected.vehicle,selected.age=vehicle.id,0
                    if selected.entry~=vehicle.entry.id then selected.entry="";selected.ready=false end
                end
            end
        end
    end
    -- 每渲染帧最多绑定一节；稳定运行复用最多8*4个节点，不反复Clone八节子树。
    local built=false
    local spotCount=0
    local lampFactor=NightLighting.GetFactor()
    for _,slot in ipairs(pool_) do
        if slot.light then slot.light.enabled=false end
        local vehicle=nil ---@type RageVehicle?
        for _,v in ipairs(vehicles_) do if v.id==slot.vehicle then vehicle=v;break end end
        if vehicle and vehicle.active then
            if not slot.ready and not built then
                local index=math.floor(slot.age)+1
                local ok,message=pcall(bindCar,slot,vehicle,index)
                built=true
                if ok then
                    slot.age=index
                    if index==#vehicle.cars then slot.entry,slot.ready=vehicle.entry.id,true end
                else
                    errors_,lastError_=errors_+1,tostring(message)
                    if errors_<=3 then print("[RageTraffic] 池绑定失败："..lastError_) end
                    slot.vehicle="";slot.root.enabled=false
                end
            end
            if slot.ready then
                local distance=math.abs(vehicle.s-playerS_)
                for index,car in ipairs(vehicle.cars) do
                    local node=slot.nodes[index]
                    local rotation=car.reverse and car.rotation*Quaternion(180,Vector3.UP) or car.rotation
                    node.enabled=car.state~="cleared"
                    node.position=car.position-car.rotation*Vector3(0,car.height*.5,0)
                    node.rotation=rotation
                    slot.drawables[index].lodBias=distance<350 and .5 or .16
                end
                slot.root.enabled=true
                vehicle.visible=true
                createLamps(slot)
                -- railPose已经把+Z朝向实际行进方向，负dir编组的头车仍是第1节。
                -- 不再叠一次dir翻转，否则逆向车灯会错误照向车尾。
                local lead=vehicle.cars[1]
                local facing=lead.rotation*Vector3(0,-.06,1)
                local origin=lead.position+lead.rotation*Vector3(0,2.45-lead.height*.5,lead.length*.5-.3)
                local lamp=assert(slot.lamp)
                lamp.position,lamp.direction=origin,facing
                for marker,bulb in ipairs(slot.bulbs or {}) do
                    bulb.position=origin+lead.rotation*Vector3(marker==1 and -.65 or .65,-.2,.35)
                    bulb.rotation=lead.rotation
                    bulb.enabled=lead.state=="rail" and lampFactor>.05
                end
                local light=assert(slot.light)
                light.enabled=lead.state=="rail" and lampFactor>.05 and distance<500 and spotCount<2
                light.brightness=350*lampFactor
                if light.enabled then spotCount=spotCount+1 end
            else slot.root.enabled=false end
        else slot.root.enabled=false end
    end
end

function Rage.GetStats()
    local out={}
    for key,value in pairs(stats_) do out[key]=value end
    local active,visible,cars,rail=0,0,0,0
    local models={} ---@type table<string,boolean>
    for _,vehicle in ipairs(vehicles_) do
        if vehicle.active then
            active=active+1;models[vehicle.entry.id]=true
            for _,car in ipairs(vehicle.cars) do if car.state=="rail" then rail=rail+1 end end
        end
        if vehicle.visible then visible=visible+1 end
    end
    local types=0
    for _ in pairs(models) do types=types+1 end
    for _,slot in ipairs(pool_) do cars=cars+#slot.nodes end
    out.enabled,out.logical,out.active,out.visible,out.maxVisible=true,#vehicles_,active,visible,visibleLimit_
    out.modelTypes,out.railCars,out.clonedCars,out.poolSlots=types,rail,cars,#pool_
    out.totalClones,out.rebuilds,out.sharedResources=modelBinds_,0,true
    local spots=0
    for _,slot in ipairs(pool_) do if slot.light and slot.light.enabled then spots=spots+1 end end
    out.headlightSpots,out.maxHeadlightSpots=spots,2
    out.errors,out.error,out.elapsed,out.logicSteps=errors_,lastError_,elapsed_,math.floor(elapsed_/STEP+.5)
    out.impactPulse=clamp(1-(elapsed_-stats_.lastImpactAt)/.5,0,1)
    out.pendingImpactEvents,out.droppedImpactEvents,out.clearedCars=#impactEvents_,droppedEvents_,clearedCars_
    out.minHeadway,out.formationCars,out.playerCausalOnly=GAP,CAR_COUNT,true
    local locks={}
    for _,zone in ipairs(zones_) do
        locks[#locks+1]={key=zone.key,first=zone.first,last=zone.last,baseLane=zone.baseLane,owner=zone.owner}
    end
    out.locks=locks
    return out
end

function Rage.GetTrains()
    local out={}
    for _,vehicle in ipairs(vehicles_) do
        local flying,wreck=0,0
        for _,car in ipairs(vehicle.cars) do
            if car.state=="flying" then flying=flying+1 elseif car.state=="wreck" then wreck=wreck+1 end
        end
        out[#out+1]={id=vehicle.id,type="rage",modelId=vehicle.entry.id,name=vehicle.entry.name,
            dir=vehicle.dir,lane=vehicle.lane,pathKey=vehicle.pathKey,s=vehicle.s,
            headS=vehicle.s+vehicle.dir*vehicle.cars[1].length*.5,speedMs=vehicle.speedMs,
            speedKmh=vehicle.speedMs*3.6,length=vehicle.length,lo=vehicle.lo,hi=vehicle.hi,
            active=vehicle.active,visible=vehicle.visible,held=vehicle.held,damagedAt=vehicle.damagedAt,
            state=flying>0 and "flying" or (wreck>0 and "wreck" or "running"),
            airborne=flying,wrecks=wreck,carCount=#vehicle.cars,generation=vehicle.generation}
    end
    return out
end

-- 测试/诊断只读车节快照；不暴露Node、内部表或可写物理状态。
function Rage.GetCars()
    local out={}
    for _,vehicle in ipairs(vehicles_) do
        for _,car in ipairs(vehicle.cars) do
            out[#out+1]={id=car.id,vehicleId=vehicle.id,active=vehicle.active,profile=car.profile,reverse=car.reverse,
                offset=car.offset,length=car.length,height=car.height,pivot=car.pivot,railS=car.railS,
                state=car.state,position=car.position,
                rotation=Quaternion(car.rotation),velocity=car.velocity,chain=car.chain,age=car.age,floor=car.floor,
                generation=car.generation,launches=car.launches}
        end
    end
    return out
end

-- 实际池MDL绑定诊断快照；不暴露Node或可改模型引用。
function Rage.GetVisualBindings()
    local out={}
    for _,slot in ipairs(pool_) do
        if slot.ready and slot.root.enabled then
            for _,vehicle in ipairs(vehicles_) do
                if vehicle.id==slot.vehicle then
                    for index,car in ipairs(vehicle.cars) do
                        local model=slot.drawables[index].model
                        local res=resources_[car.profile]
                        out[#out+1]={vehicleId=vehicle.id,index=index,profile=car.profile,reverse=car.reverse,
                            modelPath=model and model.name or "",bound=res~=nil and model==res.model,
                            geometries=model and model.numGeometries or 0,enabled=slot.nodes[index].enabled,
                            position=slot.nodes[index].position,rotation=Quaternion(slot.nodes[index].rotation)}
                    end
                    break
                end
            end
        end
    end
    return out
end

-- 音频只消费快照，不返回内部引用；sequence跨Reset/Shutdown单调，getter无副作用。
---@return RageImpactEvent[]
function Rage.GetImpactEvents()
    local out={} ---@type RageImpactEvent[]
    for _,value in ipairs(impactEvents_) do
        out[#out+1]={sequence=value.sequence,position=value.position,strength=value.strength,kind=value.kind,time=value.time}
    end
    return out
end
---@param maxCount number?
---@return RageImpactEvent[]
function Rage.DrainImpactEvents(maxCount)
    local count=math.floor(clamp(maxCount or 8,0,MAX_EVENTS))
    local snapshot=Rage.GetImpactEvents()
    local out={} ---@type RageImpactEvent[]
    for _=1,math.min(count,#snapshot) do out[#out+1]=table.remove(snapshot,1);table.remove(impactEvents_,1) end
    return out
end

function Rage.ExportState()
    local out={version=1,seed=seed_,kinds={}}
    for _,key in ipairs({"score","impacts","playerImpacts","npcImpacts","chains","maxChain","launches","landings"}) do out[key]=stats_[key] end
    for name in pairs(kinds_) do out.kinds[#out.kinds+1]=name end
    table.sort(out.kinds)
    return out
end

function Rage.RestoreState(data)
    if type(data)~="table" or data.version~=1 or type(data.kinds)~="table" then return false,"狂暴统计版本无效" end
    for _,key in ipairs({"score","impacts","playerImpacts","npcImpacts","chains","maxChain","launches","landings"}) do
        if not finite(data[key]) or data[key]<0 or data[key]~=math.floor(data[key]) then return false,"狂暴统计数值无效："..key end
    end
    if data.maxChain>MAX_CHAIN or data.playerImpacts+data.npcImpacts~=data.impacts then return false,"狂暴统计计数不一致" end
    local restored={} ---@type table<string,boolean>
    for _,name in ipairs(data.kinds) do if not EVENT_TEXT[name] then return false,"狂暴事件种类无效" end;restored[name]=true end
    for _,key in ipairs({"score","impacts","playerImpacts","npcImpacts","chains","maxChain","launches","landings"}) do stats_[key]=data[key] end
    kinds_=restored
    stats_.diversity=0
    for _ in pairs(kinds_) do stats_.diversity=stats_.diversity+1 end
    stats_.currentChain,stats_.airborne,stats_.lastEvent=0,0,""
    stats_.eventText="狂暴连锁记录已接续 · 交通重新安全调度"
    if finite(data.seed) then seed_=math.floor(clamp(data.seed,1,2147483646)) end
    return true,"狂暴统计已恢复"
end

function Rage.Shutdown()
    if root_ then root_:Dispose() end
    if blueMaterial_ then blueMaterial_:Dispose() end
    root_,blueMaterial_,vehicles_,pool_,resources_,contacts_,chains_,playerHistory_=nil,nil,{},{},{},{},{},{}
    impactEvents_,zones_={},{}
    initialized_=false
    modelBinds_,errors_,lastError_=0,0,""
end

return Rage
