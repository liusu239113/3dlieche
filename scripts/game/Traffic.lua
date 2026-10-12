-- 单机玩法级交通保护；不是现实CTCS或联锁认证实现。
-- 内部单位米/秒，GetSpeedConstraint对外使用km/h；逻辑和可见性独立，
-- 全部在调用者线程更新，不创建并发任务。
--
-- 纵向占用与道岔检测设计（不创建Bullet列车碰撞体）
-- +dir: [尾端=head-length] ===== 八节真实车体 ===== [鼻端head] -->
-- -dir: <-- [鼻端head] ===== 八节真实车体 ===== [尾端=head+length]
-- 玩家GetS为头车中心，保守整列包络[s-activeLength,s+16]。
--
-- station s:    -700          -320                 +160          +400
-- lane 2         \=========== 站侧线 ============== /                (+10.8m)
-- lane 0  --------\---------- 下行正线 ------------/-------------    (0m)
-- lane 1  ======================================================    (-5m)
--                  入口咽喉                         出口咽喉
-- lane0/lane2咽喉按完整编组锁定；中央平行股道不是同一个排他锁，
-- 可以真实待避。纵向跟车保留鼻端至前车尾端80m，并计算制动包络。
-- 贴边、停稳、反向尾端领行、跨入/出口和低FPS逐步位移都参与检查。
-- AI也受玩家整列尾端占用约束，lane1相向车与lane0物理分离。
-- 端点循环仅作远端不可见的离线调度；玩家附近不折返横移或传送。
local Train = require "train.Train"
local Route = require "world.Route"
local RailNetwork = require "world.RailNetwork"
local GameConfig = require "config.GameConfig"
local Visuals = require "game.TrafficVisuals"
local Traffic = {}

local GAP = 80.0
local AI_LENGTH = 260.0 -- 所有当前八节车型的保守包络，不随换车缩短安全占用
local AI_BRAKE = .65
local AI_ACCEL = .45
local SWITCH_KMH = 40
local STEP = .02
local REMOTE = 3600
local SIGNAL_BLOCK = 1600

---@class TrafficVehicle
---@field id string
---@field type string local|express|opposing|passing
---@field dir number 1 or -1; speedMs is unsigned
---@field lane integer
---@field headS number actual leading nose, NOT lead-car centre
---@field s number lead-car centre in current formation direction
---@field frontOffset number
---@field length number
---@field speedMs number
---@field cruiseMs number
---@field lo number
---@field hi number
---@field active boolean
---@field visible boolean
---@field state string
---@field holdReason string
---@field dwell number
---@field turnWait number
---@field lastStop number
---@field limitMs number
---@field movement number
---@field nextSpeed number
---@field nextMovement number
---@class TrafficPlayerInput
---@field s number
---@field speedMs number?
---@field speed number? alias for signed m/s
---@field length number?
---@field frontOffset number?
---@field reversing boolean?
---@field lane integer? constant perception lane; lane2 merges outside yards
---@field deceleration number?
---@field operatingKmh number?
---@class TrafficActor
---@field id string
---@field dir number
---@field headS number
---@field lo number
---@field hi number
---@field speedMs number
---@field lane integer
---@field player boolean
---@field length number
---@class TrafficThroat
---@field id string
---@field stationIndex number
---@field name string
---@field side string
---@field lo number
---@field hi number
---@field owner string?
---@field occupied boolean
---@class TrafficPassing
---@field stationIndex number
---@field stationS number
---@field trainId string
---@field phase string
---@field cleared boolean
---@field sidingReady boolean
---@field committed boolean
---@field exitClearS number
---@field dir number
---@field startS number

---@type TrafficVehicle[]
local trains_ = {}
---@type TrafficThroat[]
local throats_ = {}
---@type table[]
local stations_ = {}
---@type TrafficPlayerInput|nil
local override_ = nil
---@type TrafficPassing|nil
local passing_ = nil
local service_ = "local"
local initialized_ = false
local elapsed_ = 0.0
local accumulator_ = 0.0
local logicSteps_ = 0
local remoteDispatches_ = 0
local safeStops_ = 0
local sourceLength_ = AI_LENGTH
local sourceFront_ = 16.0
local lastAspect_ = ""
local lastConstraint_ = ""

---@param value number
---@param low number
---@param high number
local function clamp(value, low, high) return math.max(low,math.min(high,value)) end

---@return boolean
local function closed()
    return Route.IsClosed and Route.IsClosed() or GameConfig.RouteClosed ~= false
end

---@return number
local function lineLength() return math.max(0,Route.GetLength()) end

---@return TrafficPlayerInput
local function input()
    if override_ then return override_ end
    return {s=Train.GetS(),speedMs=Train.GetSpeedMs(),length=Train.GetActiveLength(),
        reversing=Train.IsReversing(),deceleration=Train.GetServiceDeceleration(),
        operatingKmh=Train.GetOperatingSpeedKmh()}
end

---@param s number
---@return table|nil
local function yard(s) return RailNetwork.GetYard(s) end

---@param s number
---@return integer
local function playerLane(s)
    if override_ and override_.lane ~= nil then
        if override_.lane == 2 and not yard(s) then return 0 end
        return override_.lane
    end
    return RailNetwork.GetPlayerLane(s)
end

---@param direction? number
---@return TrafficActor
local function playerActor(direction)
    local data = input()
    local velocity = data.speedMs or data.speed or 0
    local dir = direction or (velocity < -.02 and -1 or (velocity > .02 and 1 or (data.reversing and -1 or 1)))
    local length = math.max(1,data.length or sourceLength_)
    local lo, hi = data.s - length, data.s + (data.frontOffset or 16)
    return {id="player",dir=dir,headS=dir > 0 and hi or lo,lo=lo,hi=hi,
        speedMs=math.abs(velocity),lane=playerLane(data.s),player=true,length=hi-lo}
end

---@param train TrafficVehicle
local function hull(train)
    train.lo = train.dir > 0 and train.headS - train.length or train.headS
    train.hi = train.dir > 0 and train.headS or train.headS + train.length
    train.s = train.headS - train.dir * train.frontOffset
end

---@param train TrafficVehicle
---@return TrafficActor
local function actor(train)
    return {id=train.id,dir=train.dir,headS=train.headS,lo=train.lo,hi=train.hi,
        speedMs=train.speedMs,lane=train.lane,player=false,length=train.length}
end

---@param id string
---@return TrafficVehicle|nil
local function findTrain(id)
    for _, train in ipairs(trains_) do if train.id == id then return train end end
    return nil
end

---@param id string
---@return TrafficActor|nil
local function findActor(id)
    if id == "player" then return playerActor() end
    local train = findTrain(id)
    return train and train.active and actor(train) or nil
end

---@param a TrafficActor
---@param s number
---@return integer
local function laneAt(a,s)
    if a.player then return playerLane(s) end
    if a.lane == 2 and not yard(s) then return 0 end
    return a.lane
end

---@param a TrafficActor
---@param b TrafficActor
---@param s number
---@return boolean
local function sharesTrack(a,b,s)
    local left, right = laneAt(a,s),laneAt(b,s)
    if left == right then return true end
    if left == 1 or right == 1 then return false end
    local station = yard(s)
    if not station then return true end
    local relative = s-station.s
    -- 全扇区视为共享咽喉，不能仅因鼻端已经分流就允许
    -- 车身仍处在低横向间隔处与另一整列相互穿透。
    return relative <= -320+10 or relative >= 160-10
end

---@param a TrafficActor
---@param throat TrafficThroat
---@return boolean
local function usesThroat(a,throat)
    return laneAt(a,(throat.lo+throat.hi)*.5) ~= 1
end

---@param a TrafficActor
---@param lo number
---@param hi number
---@param guard? number
local function overlaps(a,lo,hi,guard)
    local margin = guard or 0
    return a.hi+margin >= lo and a.lo-margin <= hi
end

---@param a TrafficActor
---@param lo number
---@param hi number
---@return number
local function entryDistance(a,lo,hi)
    return a.dir > 0 and lo-a.headS or a.headS-hi
end

---@param a TrafficActor
---@param b TrafficActor
---@return number gap, number frontSpeed
local function followingGap(a,b)
    -- 已完全位于后方的整列不作为前向障碍；中央侧线平行
    -- 会车不制造纵向冲突，但跨入口/出口的车身仍参与检查。
    if (a.dir > 0 and b.hi < a.headS) or (a.dir < 0 and b.lo > a.headS) then return math.huge,0 end
    local cuts = {b.lo,b.hi} ---@type number[]
    for _, station in ipairs(stations_) do
        for _, offset in ipairs({-710,-310,150,410}) do
            local point = station.s+offset
            if point > b.lo and point < b.hi then cuts[#cuts+1] = point end
        end
    end
    table.sort(cuts)
    local best = math.huge
    for i = 1,#cuts-1 do
        local first,last = cuts[i],cuts[i+1]
        if sharesTrack(a,b,(first+last)*.5) then
            if (a.dir > 0 and last >= a.headS) or (a.dir < 0 and first <= a.headS) then
                local distance = a.dir > 0 and first-a.headS or a.headS-last
                best = math.min(best,math.max(0,distance-GAP))
            end
        end
    end
    return best,b.dir == a.dir and b.speedMs or 0
end

---@return TrafficActor[]
local function actors()
    local result = {playerActor()} ---@type TrafficActor[]
    for _, train in ipairs(trains_) do if train.active then result[#result+1] = actor(train) end end
    return result
end

---@param a TrafficActor
---@param deceleration number
---@return number
local function approachHorizon(a,deceleration)
    return a.speedMs*a.speedMs/(2*deceleration)+a.speedMs*2+250
end

---@param a TrafficActor
---@param throat TrafficThroat
---@return boolean
local function clearedThroat(a,throat)
    -- 已进入侧线中央独立股道的整列可清掉入口锁；与入口扇区保留
    -- 10m隔离。80m纵向跟车界另算，不能把它变成站内停车死锁。
    local margin = laneAt(a,(a.lo+a.hi)*.5) == 2 and 10 or GAP
    return a.dir > 0 and a.lo > throat.hi+margin or a.dir < 0 and a.hi < throat.lo-margin
end

local function updateLocks()
    local all = actors()
    for _, throat in ipairs(throats_) do
        local owner = throat.owner and findActor(throat.owner) or nil
        local passingExit = passing_ and not passing_.cleared and throat.stationIndex == 3
            and throat.side == (passing_.dir > 0 and "exit" or "entry")
        if owner and owner.player and passingExit and not overlaps(owner,throat.lo,throat.hi,0) then
            throat.owner,throat.occupied,owner = nil,false,nil
        end
        if owner then
            local distance = entryDistance(owner,throat.lo,throat.hi)
            if not usesThroat(owner,throat) or clearedThroat(owner,throat)
                or (not overlaps(owner,throat.lo,throat.hi,GAP)
                    and distance > approachHorizon(owner,AI_BRAKE)+1000) then
                throat.owner,throat.occupied = nil,false
                owner = nil
            end
        end
        if not owner then
            local selected = nil ---@type TrafficActor|nil
            local score = math.huge
            -- 已有整列物理占用优先，其次按接近距离/到达估计分配。
            -- 待避时让侧线玩家优先完成入口，后追快车不得先占
            -- 它自己必须等待的玩家分流入口。
            for _, candidate in ipairs(all) do
                if usesThroat(candidate,throat) then
                    local distance = entryDistance(candidate,throat.lo,throat.hi)
                    local physical = overlaps(candidate,throat.lo,throat.hi,0)
                    if (physical or (distance >= 0 and distance <= approachHorizon(candidate,AI_BRAKE)))
                        and not (passingExit and candidate.player and not physical) then
                        local priority = physical and -100000-math.min(candidate.hi-throat.lo,throat.hi-candidate.lo)
                            or distance/math.max(3,candidate.speedMs)
                        if passing_ and not passing_.cleared and throat.stationIndex == 3 then
                            local entrance = passing_.dir > 0 and "entry" or "exit"
                            if throat.side == entrance and candidate.player and laneAt(candidate,throat.lo+1) == 2 then
                                priority = priority-10000
                            elseif throat.side ~= entrance and candidate.id == passing_.trainId then
                                priority = priority-10000
                            end
                        end
                        if priority < score then score,selected = priority,candidate end
                    end
                end
            end
            if selected then throat.owner = selected.id; owner = selected end
        end
        throat.occupied = owner ~= nil and overlaps(owner,throat.lo,throat.hi,0) or false
    end
end

---@param a TrafficActor
---@param acceleration number
---@return number speedMs, string reason, number hardDistance
local function authority(a,acceleration)
    local limit,reason,hard = math.huge,"区间畅通",math.huge
    local function apply(value,label,distance)
        if value < limit then limit,reason = value,label end
        if distance then hard = math.min(hard,math.max(0,distance)) end
    end
    for _, other in ipairs(actors()) do
        if other.id ~= a.id then
            local gap,frontSpeed = followingGap(a,other)
            if gap < math.huge then
                -- 相对速度制动包络保留反应距离，硬位移界仍是
                -- 完整80m鼻端至前车尾端，不与普通限速混淆。
                local usable = math.max(0,gap-a.speedMs*1.5)
                apply(math.sqrt(2*acceleration*usable)+frontSpeed,
                    other.player and "前方玩家列车占用" or "前车占用·保持80m间隔",gap)
            end
        end
    end
    for _, throat in ipairs(throats_) do
        if usesThroat(a,throat) and throat.owner and throat.owner ~= a.id then
            local distance = entryDistance(a,throat.lo,throat.hi)-GAP
            if distance >= -GAP or overlaps(a,throat.lo,throat.hi,0) then
                apply(math.sqrt(2*acceleration*math.max(0,distance-a.speedMs*1.5)),
                    throat.name .. "·" .. (throat.side == "entry" and "进站" or "出站") .. "咽喉占用",distance)
            end
        end
    end
    if a.player then
        -- 整列通过道岔才解除40km/h；下一已预选的侧线也提前
        -- 计算高速制动包络，不能等鼻端进岔才突然限速。
        for _, station in ipairs(stations_) do
            local entry = station.s-700
            local exit = station.s+400
            if playerLane(station.s) == 2 then
                if overlaps(a,entry,exit,0) then
                    apply(SWITCH_KMH/3.6,"侧线道岔40km/h",nil)
                else
                    local distance = entryDistance(a,entry,exit)
                    if distance >= 0 then
                        local target = SWITCH_KMH/3.6
                        apply(math.sqrt(target*target+2*acceleration*math.max(0,distance-a.speedMs*1.5-30)),
                            "前方侧线道岔40km/h",nil)
                    end
                end
            end
        end
        if passing_ and not passing_.cleared and service_ == "passing" and a.dir == passing_.dir
            and playerLane(passing_.stationS) == 2 then
            -- 待避停车界位于出站汇合扇区之前，不阻止合法进入站台。
            local stop = passing_.stationS+(a.dir > 0 and 160-GAP or -320+GAP)
            local distance = a.dir*(stop-a.headS)
            if distance >= -GAP or overlaps(a,passing_.stationS-320,passing_.stationS+400,0) then
                apply(math.sqrt(2*acceleration*math.max(0,distance-a.speedMs*1.5)),
                    "待避快车·出站红灯",distance)
            end
        end
    elseif passing_ and a.id == passing_.trainId and not passing_.committed and not passing_.cleared then
        local stop = passing_.stationS+(a.dir > 0 and -700-GAP or 400+GAP)
        local distance = a.dir*(stop-a.headS)
        apply(math.sqrt(2*acceleration*math.max(0,distance-a.speedMs*1.5)),
            "等待玩家整列入侧线并停稳",distance)
    end
    if not closed() and lineLength() > 0 then
        local endpoint = a.dir > 0 and lineLength()-20-a.headS or a.headS-20
        -- 倒车时真正的领行端是末车尾，不是头车中心；终端
        -- 制动必须给整列留空间，避免末车驶出开放线路。
        apply(math.sqrt(2*acceleration*math.max(0,endpoint-a.speedMs*1.5)),"线路终端停车",endpoint)
    end
    return math.max(0,limit),reason,hard
end

local function updatePassing()
    if not passing_ or passing_.cleared or service_ ~= "passing" then return end
    local express = findTrain(passing_.trainId)
    if not express then return end
    local player = playerActor()
    local s = passing_.stationS
    -- 与Game待避任务保持相同的两端80m净空和停稳契约。
    passing_.sidingReady = playerLane(s) == 2 and player.lo >= s-320+GAP
        and player.hi <= s+160-GAP and player.speedMs <= .02
    if passing_.sidingReady and not passing_.committed then
        passing_.committed,passing_.phase = true,"passing"
        -- 玩家入口锁保留到整列驶离；仅接近但未实际进入的
        -- 出口预约不会抢占快车所需的正线出口。
        print("[Traffic] 站3玩家整列入侧线并停稳，快车获准实际通过；出口仍为红灯")
    elseif not passing_.committed then passing_.phase = "waiting" end
    local tail = passing_.dir > 0 and express.lo or express.hi
    if passing_.committed and express.active and passing_.dir*(tail-passing_.exitClearS) > 0 then
        passing_.cleared,passing_.phase = true,"cleared"
        print(string.format("[Traffic] 站3快车尾端%.1fm已越出口清空点%.1fm：出站红->绿",tail,passing_.exitClearS))
    end
end

---@param id string
---@param kind string
---@param head number
---@param dir number
---@param lane integer
---@param cruiseKmh number
---@param initialKmh number
---@return TrafficVehicle
local function newTrain(id,kind,head,dir,lane,cruiseKmh,initialKmh)
    local train = {id=id,type=kind,headS=head,dir=dir,lane=lane,frontOffset=sourceFront_,
        s=head-dir*sourceFront_,length=sourceLength_,speedMs=initialKmh/3.6,cruiseMs=cruiseKmh/3.6,
        lo=0,hi=0,active=true,visible=false,state="running",holdReason="",dwell=0,turnWait=0,
        lastStop=-1,limitMs=cruiseKmh/3.6,movement=math.huge,nextSpeed=0,nextMovement=0}
        --[[@as TrafficVehicle]]
    hull(train)
    trains_[#trains_+1] = train
    return train
end

---@param train TrafficVehicle
---@param dt number
local function terminal(train,dt)
    if closed() or lineLength() <= 0 then return end
    local atEnd = train.dir > 0 and train.headS >= lineLength()-20-.1 or train.dir < 0 and train.headS <= 20+.1
    if train.active and atEnd and train.speedMs <= .05 then
        train.state,train.speedMs = "terminal",0
        train.turnWait = train.turnWait+dt
        local player = playerActor()
        local distance = math.max(0,train.lo-player.hi,player.lo-train.hi)
        -- lane0/lane1相隔5m；玩家附近不直接换轨折返。
        -- 仅远端整列不可见且有安全净空时重新离线调度出库。
        if distance > REMOTE and not train.visible and train.turnWait >= 20
            and (not passing_ or passing_.trainId ~= train.id or passing_.cleared) then
            train.active,train.state,train.speedMs = false,"remote_dispatch",0
            train.turnWait = 0
        end
    elseif not train.active and train.state == "remote_dispatch" then
        train.turnWait = train.turnWait+dt
        if train.turnWait < 15 then return end
        local oldDir = train.dir
        local nextHead = oldDir > 0 and lineLength()-20-train.length or 20+train.length
        local nextDir = -oldDir
        local nextLane = nextDir > 0 and 0 or 1
        local candidate = {id=train.id,dir=nextDir,headS=nextHead,
            lo=nextDir > 0 and nextHead-train.length or nextHead,
            hi=nextDir > 0 and nextHead or nextHead+train.length,
            speedMs=0,lane=nextLane,player=false,length=train.length} --[[@as TrafficActor]]
        local safe = not overlaps(playerActor(),candidate.lo,candidate.hi,REMOTE)
        for _, other in ipairs(actors()) do
            if other.id ~= train.id and sharesTrack(candidate,other,nextHead)
                and overlaps(other,candidate.lo,candidate.hi,GAP) then safe = false end
        end
        if safe then
            train.dir,train.lane,train.headS = nextDir,nextLane,nextHead
            train.active,train.state,train.turnWait = true,"running",0
            train.lastStop = -1
            hull(train)
            remoteDispatches_ = remoteDispatches_+1
            print("[Traffic] 远端离线调度重新出库 " .. train.id .. "（不在玩家附近折返/传送）")
        end
    end
end

---@param train TrafficVehicle
---@param dt number
local function localStop(train,dt)
    if train.type ~= "local" then return end
    if train.dwell > 0 then
        train.dwell = math.max(0,train.dwell-dt)
        train.limitMs,train.state,train.holdReason = 0,"station_stop","AI正常站停"
        if train.dwell == 0 then train.state = "running" end
        return
    end
    for _, station in ipairs(stations_) do
        local target = station.s+train.dir*train.frontOffset
        local distance = train.dir*(target-train.headS)
        if station.index ~= train.lastStop and distance >= -.15 then
            local permitted = math.sqrt(2*AI_BRAKE*math.max(0,distance-train.speedMs*1.2))
            if permitted < train.limitMs then
                train.limitMs,train.holdReason = permitted,"AI进站停车"
                train.movement = math.min(train.movement,math.max(0,distance))
            end
            if distance <= .15 and train.speedMs < .1 then
                train.dwell,train.lastStop,train.limitMs,train.state = 12,station.index,0,"station_stop"
                print("[Traffic] " .. train.id .. " 站停 " .. station.name)
            end
        end
    end
end

---@param dt number
local function step(dt)
    elapsed_,logicSteps_ = elapsed_+dt,logicSteps_+1
    updatePassing()
    updateLocks()
    for _, train in ipairs(trains_) do
        if train.state == "queued" then
            local player = playerActor()
            local head = train.dir > 0 and 20+train.length or lineLength()-20-train.length
            local candidate = {id=train.id,dir=train.dir,headS=head,
                lo=train.dir > 0 and head-train.length or head,
                hi=train.dir > 0 and head or head+train.length,
                speedMs=0,lane=train.lane,player=false,length=train.length} --[[@as TrafficActor]]
            local safe = train.dir > 0 and player.lo >= candidate.hi+GAP+400
                or train.dir < 0 and player.hi <= candidate.lo-GAP-400
            for _, other in ipairs(actors()) do
                if other.id ~= train.id and sharesTrack(candidate,other,head)
                    and overlaps(other,candidate.lo,candidate.hi,GAP) then safe = false end
            end
            if safe then
                train.headS,train.speedMs,train.active,train.state = head,0,true,"running"
                hull(train)
            end
        end
        if train.active then
            local permitted,reason,distance = authority(actor(train),AI_BRAKE)
            train.limitMs,train.holdReason,train.movement = math.min(train.cruiseMs,permitted),reason,distance
            localStop(train,dt)
            local speed = train.speedMs
            local nextSpeed = speed < train.limitMs and math.min(train.limitMs,speed+AI_ACCEL*dt)
                or math.max(train.limitMs,speed-AI_BRAKE*dt)
            local movement = (speed+nextSpeed)*.5*dt
            if movement > train.movement then
                movement,nextSpeed = train.movement,0
                if speed > .1 then safeStops_ = safeStops_+1 end
            end
            train.nextSpeed,train.nextMovement = nextSpeed,movement
        else train.nextSpeed,train.nextMovement = 0,0 end
    end
    -- 双方各自的硬界不能同时吃掉同一段间隔：相向AI在同轨时
    -- 合计纵向位移至多等于剩余80m净间隔，按本步位移比例分配。
    for i = 1,#trains_ do
        local a = trains_[i]
        if a.active then
            for j = i+1,#trains_ do
                local b = trains_[j]
                if b.active and a.dir ~= b.dir then
                    local forward = a.dir > 0 and a or b
                    local reverse = a.dir > 0 and b or a
                    local gap = reverse.lo-forward.hi-GAP
                    if gap >= 0 and sharesTrack(actor(a),actor(b),(forward.hi+reverse.lo)*.5) then
                        local movement = a.nextMovement+b.nextMovement
                        if movement > gap and movement > 0 then
                            local scale = gap/movement
                            a.nextMovement,b.nextMovement = a.nextMovement*scale,b.nextMovement*scale
                            a.nextSpeed,b.nextSpeed = 0,0
                            safeStops_ = safeStops_+1
                        end
                    end
                end
            end
        end
    end
    for _, train in ipairs(trains_) do
        if train.active then
            train.headS = train.headS+train.dir*train.nextMovement
            train.speedMs = train.nextSpeed
            if train.dwell <= 0 then train.state = train.speedMs <= .02 and "held" or "running" end
            hull(train)
        end
        terminal(train,dt)
    end
    updatePassing()
    -- 当步位移和真实尾车清空完成后再同步锁；不能让已清空的
    -- 待避快车保留上一小步咽喉owner，使HUD/发车读到过期红灯。
    updateLocks()
end

---@param s? number only AI schedule origin; never writes the player's train
function Traffic.Reset(s)
    Visuals.Reset()
    trains_,throats_,stations_ = {},{},Route.GetStations()
    elapsed_,accumulator_,logicSteps_,remoteDispatches_,safeStops_ = 0,0,0,0,0
    passing_,lastAspect_,lastConstraint_ = nil,"",""
    sourceLength_ = math.max(AI_LENGTH,Train.GetActiveLength()+16)
    local first = Train.GetCars()[1]
    sourceFront_ = first and first.length*.5 or 16
    for _, station in ipairs(stations_) do
        throats_[#throats_+1] = {id=tostring(station.index).."_entry",stationIndex=station.index,
            name=station.name,side="entry",lo=station.s-700,hi=station.s-320,occupied=false}
        throats_[#throats_+1] = {id=tostring(station.index).."_exit",stationIndex=station.index,
            name=station.name,side="exit",lo=station.s+160,hi=station.s+400,occupied=false}
    end
    local origin = s or input().s
    local length = lineLength()
    local function spawn(id,kind,at,dir,lane,cruise,initial)
        if length <= sourceLength_*3 then return end
        local head = clamp(at,sourceLength_+100,length-sourceLength_-100)
        local proposed = newTrain(id,kind,head,dir,lane,cruise,initial)
        for _, other in ipairs(actors()) do
            if other.id ~= id and sharesTrack(actor(proposed),other,head)
                and overlaps(other,proposed.lo,proposed.hi,GAP) then
                proposed.active,proposed.state,proposed.speedMs = false,"not_dispatched",0
            end
        end
    end
    spawn("O01","opposing",origin+1200,-1,1,135,95)
    spawn("L01","local",origin+1800,1,0,90,45)
    -- 全线共6个少量班次，不生成数百个运行时资产任务。
    -- 若出生包络与其他整列冲突则不发出，禁止传送穿车。
    for i = 1,4 do
        local at = length*(.17+i*.16)
        local dir = i%2 == 0 and -1 or 1
        spawn("T0"..tostring(i+1),dir > 0 and "express" or "opposing",at,dir,
            dir > 0 and 0 or 1,dir > 0 and 165 or 145,dir > 0 and 110 or 100)
    end
    local service = service_
    service_ = "local"
    if service ~= "local" then Traffic.SetService(service) end
    updateLocks()
    print(string.format("[Traffic] 重置：%d个全线逻辑班次，最多3个可见8节编组；最小尾距80m",#trains_))
end

---@param scene Scene|nil nil: logic-only mode, no engine scene or assets created
function Traffic.Init(scene)
    Visuals.Init(scene)
    initialized_ = true
    Traffic.Reset()
end

---@param dt number
function Traffic.Update(dt)
    if not initialized_ or dt <= 0 or dt ~= dt then return end
    -- 大卡顿最多推进1秒/50个确定性小步，丢弃多余墙钟时间
    -- 而不是跳跃大量位移跨过玩家或咽喉。
    accumulator_ = accumulator_+math.min(dt,1)
    local count = math.min(50,math.floor((accumulator_+.00000001)/STEP))
    for _ = 1,count do step(STEP) end
    accumulator_ = math.max(0,accumulator_-count*STEP)
end

---@param dt number
function Traffic.UpdateVisuals(dt)
    if not initialized_ then return end
    -- 换车时Train显式Dispose的identity/gangway已从克隆移除；
    -- 剩余模型/材质为普通共享引用，不会误释放玩家cache资源。
    local first = Train.GetCars()[1]
    sourceFront_ = first and first.length*.5 or sourceFront_
    local length = math.max(AI_LENGTH,Train.GetActiveLength()+16)
    for _, train in ipairs(trains_) do
        train.frontOffset = sourceFront_
        train.length = math.max(train.length,length) -- 换车绝不缩短既有安全占用
        hull(train)
    end
    Visuals.Update(dt,trains_ --[[@as TrafficVisualVehicle [] ]],input().s)
end

function Traffic.Shutdown()
    Visuals.Shutdown()
    initialized_,trains_,throats_,stations_,passing_,override_ = false,{},{},{},nil,nil
    service_,accumulator_ = "local",0
end

---@return number km/h
---@return string
function Traffic.GetSpeedConstraint()
    if not initialized_ then return math.huge,"交通未初始化" end
    local data = input()
    local limit,reason = authority(playerActor(),math.max(.1,data.deceleration or .65))
    local kmh = limit*3.6
    if reason ~= lastConstraint_ and kmh < (data.operatingKmh or 350) then
        lastConstraint_ = reason
        print(string.format("[Traffic] 玩家保护：%s，许可%.1fkm/h",reason,kmh))
    end
    return kmh,reason
end

---@return number metres to leading nose/tail HARD boundary, math.huge if none
---@return string
function Traffic.GetSafetyDistance()
    if not initialized_ then return math.huge,"交通未初始化" end
    local data = input()
    local _,reason,distance = authority(playerActor(),math.max(.1,data.deceleration or .65))
    return distance,reason
end

---@return number|nil maxS safe forward lead-car CENTRE bound
---@return number|nil minS safe reverse lead-car CENTRE bound
function Traffic.GetMovementLimit()
    if not initialized_ then return nil,nil end
    local data = input()
    local direction = playerActor().dir
    local distance = Traffic.GetSafetyDistance()
    if distance == math.huge then return nil,nil end
    -- 旧接口保留只读建议界；主循环不再以此钳位置、收油或自动制动。
    if direction > 0 then return data.s+math.max(0,distance),nil end
    return nil,data.s-math.max(0,distance)
end

---@param stationIndex number
---@return string red|yellow|green
function Traffic.GetSignalAspect(stationIndex)
    if not initialized_ then return "green" end
    local station = nil ---@type table|nil
    for _, item in ipairs(stations_) do if item.index == stationIndex then station = item;break end end
    if not station then return "red" end -- 未知信号采取安全侧禁止放行
    if passing_ and service_ == "passing" and stationIndex == passing_.stationIndex and not passing_.cleared then return "red" end
    local player = playerActor()
    local lane = playerLane(station.s)
    local passOpen = passing_ and passing_.cleared and service_ == "passing" and stationIndex == 3
    for _, train in ipairs(trains_) do
        if train.active and train.lane ~= 1 then
            local blockStart = station.s-700
            local blockEnd = station.s+400+GAP
            if train.hi >= blockStart and train.lo <= blockEnd then
                -- 中央平行股道可以会车，入/出口扇区仍按真实
                -- 包络冲突显示红灯，不能全站默认永久绿灯。
                if lane == 0 or train.hi >= station.s+150 or train.lo <= station.s-310 then return "red" end
                if lane == 2 then return "yellow" end
            end
        end
    end
    for _, throat in ipairs(throats_) do
        if throat.stationIndex == stationIndex and throat.owner and throat.owner ~= "player" then return "red" end
    end
    for _, train in ipairs(trains_) do
        if train.active and train.lane ~= 1 then
            local downstream = player.dir > 0 and train.lo-(station.s+400) or station.s-700-train.hi
            if downstream >= 0 and downstream <= SIGNAL_BLOCK
                and (not passOpen or not passing_ or train.id ~= passing_.trainId) then return "yellow" end
        end
    end
    return passOpen and "green" or (lane == 2 and "yellow" or "green")
end

---@return table {aspect,text,track,switchText,locked,objective?}
function Traffic.GetStatus()
    local base = RailNetwork.GetStatus()
    local player = playerActor()
    local _,reason,hard = authority(player,math.max(.1,input().deceleration or .65))
    local aspect = "green"
    if hard <= GAP or (passing_ and not passing_.cleared and service_ == "passing"
        and math.abs(input().s-passing_.stationS) <= 1100) then aspect = "red"
    elseif hard <= SIGNAL_BLOCK or reason:find("40km/h",1,true) then aspect = "yellow" end
    local locked = base.locked
    for _, throat in ipairs(throats_) do
        if overlaps(player,throat.lo,throat.hi,0) and usesThroat(player,throat) then locked = true end
    end
    local objective = nil ---@type string|nil
    if passing_ and service_ == "passing" then
        objective = passing_.cleared and "快车整列驶离出口，出站进路已开放"
            or (passing_.committed and "侧线待避：快车通过中，等尾车驶离出口"
                or "站3整列进侧线并停稳，等待快车通过")
    end
    if aspect ~= lastAspect_ then
        lastAspect_ = aspect
        print("[Traffic] 车载交通提示 " .. aspect .. " · " .. reason)
    end
    return {aspect=aspect,text=aspect == "green" and "前方进路开放" or reason,
        track=player.lane == 1 and "上行正线" or (player.lane == 2 and "站内到发线" or "下行正线"),
        switchText=base.switchText,locked=locked,objective=objective}
end

---@param service string local|express|passing
---@return boolean, string
function Traffic.SetService(service)
    if service ~= "local" and service ~= "express" and service ~= "passing" then return false,"未知运营任务" end
    service_ = service
    if service ~= "passing" then
        -- 更换任务不能删除或传送已经发出的快车。
        if passing_ then
            local train = findTrain(passing_.trainId)
            if train then train.type = "express" end
            passing_ = nil
        end
        return true,service == "local" and "普通站停任务" or "快速运行任务"
    end
    local player = playerActor()
    if passing_ then
        if player.dir == passing_.dir or not passing_.cleared then return true,"站3待避班次已安排" end
        -- 只有完成后明确终到换向再选任务才重新调度；中途换向不
        -- 凭计时清除仍在站内的快车或无穷重开训练。
        local old = findTrain(passing_.trainId)
        if old then old.type = "express" end
        passing_ = nil
    end
    local station = nil ---@type table|nil
    for _, item in ipairs(stations_) do if item.index == 3 then station = item;break end end
    if not station then return false,"线路没有第3站" end
    local id = "P03"
    local existing = findTrain(id)
    if existing then id = "P03_"..tostring(logicSteps_) end
    local head = player.dir > 0 and math.min(player.lo-1200,station.s-1800)
        or math.max(player.hi+1200,station.s+1800)
    local train = newTrain(id,"passing",clamp(head,20+sourceLength_,lineLength()-20-sourceLength_),
        player.dir,0,200,70)
    if head < 20+sourceLength_ or head > lineLength()-20-sourceLength_ then
        train.active,train.state,train.speedMs = false,"queued",0
    end
    -- 出生处已被实际列车占用则离线排队，后续再次检查；
    -- 不能为加快完成待避而重排一列车穿过其他整列。
    if train.active then
        for _, other in ipairs(actors()) do
            if other.id ~= id and sharesTrack(actor(train),other,train.headS)
                and overlaps(other,train.lo,train.hi,GAP) then
                train.active,train.state,train.speedMs = false,"queued",0
            end
        end
    end
    passing_ = {stationIndex=3,stationS=station.s,trainId=id,phase="approach",cleared=false,
        sidingReady=false,committed=false,exitClearS=station.s+(player.dir > 0 and 400+GAP or -700-GAP),
        dir=player.dir,startS=player.headS}
    print(string.format("[Traffic] 站3待避：后方快车%s已安排，出口需真实尾端>%.1fm才放行",id,passing_.exitClearS))
    return true,"站3待避快车已安排；请预选侧线，整列停稳后等红变绿"
end

--- 可选的感知输入适配：复制快照但不改变Train/道岔/得分/物理
--- 或AI位置；传nil恢复真实感知，供确定性逻辑测试而非玩家作弊。
---@param snapshot TrafficPlayerInput|nil
function Traffic.SetPlayerOverride(snapshot)
    if not snapshot then override_ = nil;return end
    assert(type(snapshot.s) == "number" and snapshot.s == snapshot.s,"玩家感知需要有效弧长")
    override_ = {s=snapshot.s,speedMs=snapshot.speedMs or snapshot.speed or 0,
        length=snapshot.length,frontOffset=snapshot.frontOffset,reversing=snapshot.reversing,
        lane=snapshot.lane,deceleration=snapshot.deceleration,operatingKmh=snapshot.operatingKmh}
end

-- 实际车体包络相交才判撞车，不把80m建议间隔当碰撞或自动停车线。
function Traffic.CheckPlayerCollision()
    if not initialized_ or Train.IsDerailed() then return end
    local playerCars=Train.GetCars()
    for _,train in ipairs(trains_) do
        if train.active then
            for _,car in ipairs(playerCars) do
                local center=Train.GetS()+car.offset
                local lo,hi=center-car.length*.5,center+car.length*.5
                local overlapLo,overlapHi=math.max(lo,train.lo),math.min(hi,train.hi)
                if overlapHi>overlapLo then
                    local s=(overlapLo+overlapHi)*.5
                    local lateral=RailNetwork.GetLateral(s,RailNetwork.GetPlayerLane(s))
                    local other=RailNetwork.GetLateral(s,train.lane)
                    if math.abs(lateral-other)<3.4 then
                        Train.Derail("车体与来往列车相撞，脱轨翻车")
                        return
                    end
                end
            end
        end
    end
end
---@return table[] 只读快照，不返回内部对象
function Traffic.GetTrains()
    local out = {}
    for _, train in ipairs(trains_) do
        out[#out+1] = {id=train.id,type=train.type,dir=train.dir,lane=train.lane,headS=train.headS,s=train.s,
            speedMs=train.speedMs,speedKmh=train.speedMs*3.6,length=train.length,
            lo=train.lo,hi=train.hi,active=train.active,visible=train.visible,state=train.state,
            holdReason=train.holdReason,carCount=8}
    end
    return out
end

---@return table
function Traffic.GetStats()
    local visual = Visuals.GetStats()
    local active,held,occupied,locks = 0,0,0,{}
    for _, train in ipairs(trains_) do
        if train.active then active=active+1 end
        if train.active and train.speedMs <= .02 then held=held+1 end
    end
    for _, throat in ipairs(throats_) do
        if throat.occupied then occupied=occupied+1 end
        locks[#locks+1] = {id=throat.id,stationIndex=throat.stationIndex,side=throat.side,
            lo=throat.lo,hi=throat.hi,owner=throat.owner,occupied=throat.occupied}
    end
    local pass = nil ---@type table|nil
    if passing_ then
        local train = findTrain(passing_.trainId)
        pass = {stationIndex=3,trainId=passing_.trainId,phase=passing_.phase,
            cleared=passing_.cleared,sidingReady=passing_.sidingReady,committed=passing_.committed,
            tailS=train and (passing_.dir > 0 and train.lo or train.hi) or nil,
            headS=train and train.headS or nil,exitClearS=passing_.exitClearS,dir=passing_.dir}
    end
    return {initialized=initialized_,service=service_,logical=#trains_,active=active,held=held,
        visible=visual.visible,maxVisible=visual.maxVisible,clonedCars=visual.clonedCars,
        sharedResources=visual.sharedResources,totalClones=visual.totalClones,rebuilds=visual.rebuilds,
        errors=visual.errors,error=visual.error,
        elapsed=elapsed_,logicSteps=logicSteps_,occupiedThroats=occupied,locks=locks,
        remoteDispatches=remoteDispatches_,hardSafetyStops=safeStops_,minHeadway=GAP,passing=pass}
end

return Traffic
