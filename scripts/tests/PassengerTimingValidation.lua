-- 第二站停站耗时回归：真实列车、客流、交通和发车联锁；不读写存档、不访问云。
local Route=require "world.Route"
local Train=require "train.Train"
local Traffic=require "game.Traffic"
local Passenger=require "game.PassengerService"
local Game=require "game.Game"
local Environment=require "world.Environment"
local Catalog=require "config.TrainCatalog"
---@type Scene?
local scene_=nil
local checks_=0
local strict_=false
local selected_=Catalog.DefaultId
local drive_=false
local offset_=0
local swap_=""
local legacyWaiting_=false
local function readOptions()
    for _,arg in ipairs(GetArguments()) do
        if arg=="-passenger-strict" then strict_=true end
        if arg=="-passenger-drive" then drive_=true end
        if arg=="-passenger-legacy-waiting" then legacyWaiting_=true end
        swap_=arg:match("^%-passenger%-swap=(.+)$") or swap_
        offset_=tonumber(arg:match("^%-passenger%-offset=(.+)$")) or offset_
        selected_=arg:match("^%-passenger%-train=(.+)$") or selected_
    end
    print(string.format("[PassengerTiming] OPTIONS train=%s offset=%.1f drive=%s strict=%s",selected_,offset_,tostring(drive_),tostring(strict_)))
end
local function check(value,message)
    checks_=checks_+1;assert(value,"[PassengerTiming] "..message)
end
local function step()
    Game.EnforceDepartureInterlock()
    Traffic.Update(.02)
    Train.Update(.02)
    Traffic.CheckPlayerCollision()
    Environment.Advance(.02)
    Game.Update(.02)
end
local function finishStop(label)
    local elapsed,phases,phase=0.0,{},Passenger.GetStatus().phase
    local phaseStarted=0.0
    local initial=Passenger.GetStatus()
    local used={}
    for _,actor in ipairs(Passenger.GetPassengers()) do
        if actor.kind=="alighting" then used[actor.doorId]=true end
    end
    local usedCount=0;for _ in pairs(used) do usedCount=usedCount+1 end
    if strict_ and initial.totalAlighting>0 then
        check(usedCount==math.min(initial.doorCount,initial.totalAlighting),"下客未均匀使用全部合法门")
    end
    local boardedBefore=Passenger.GetStats().boarded
    local alightedBefore=Passenger.GetStats().alighted
    local prior=Passenger.GetPassengers()
    local function remaining(actor)
        local result,previous=0.0,actor.position
        for i=actor.targetIndex,#actor.targets do
            local target=actor.targets[i]
            result=result+(target-previous):Length();previous=target
        end
        return result
    end
    for tick=1,45000 do
        if tick==31 and label=="origin" and (swap_~="" or legacyWaiting_) then
            local before=Passenger.GetPassengers()
            if swap_~="" then
                check(Train.Select(swap_),"中途换车失败")
                Passenger.RefreshDoorPlan()
                local rebound=Passenger.GetPassengers()
                for i,actor in ipairs(rebound) do
                    check(actor.id==before[i].id and (actor.position-before[i].position):Length()<.001,
                        "中途换车改变身份或传送乘客")
                end
            else
                -- 合成旧串行活动队列：保留位置/人数，只恢复waiting和旧的不均门号。
                local saved=Passenger.ExportState()
                local doorCount=#Passenger.GetDoorPlan().doors
                for _,actor in ipairs(saved.actors) do
                    if not actor.completed then
                        actor.state,actor.walking,actor.targets,actor.targetIndex="waiting",false,{},1
                        actor.doorId=(actor.id-1)%doorCount+1
                    end
                end
                Passenger.RestoreState(saved)
            end
            local rebound=Passenger.GetPassengers()
            Passenger.Update(.02)
            local after=Passenger.GetPassengers()
            for i,actor in ipairs(after) do
                check(actor.walkDistance-rebound[i].walkDistance<=actor.speed*.02+.00001,
                    "重绑或旧队列恢复后同一步消费两次步行预算")
            end
            prior=after
        end
        step();elapsed=elapsed+.02
        local status=Passenger.GetStatus()
        if tick%10==0 and Passenger.HasActiveStop() then
            local current=Passenger.GetPassengers()
            local leaders={}
            for i,actor in ipairs(current) do
                local before=prior[i]
                check(before and actor.id==before.id,"乘降过程中乘客身份改变")
                -- 世界坐标约九公里，Vector3单精度差分允许3毫米舍入，不放宽步速。
                check((actor.position-before.position):Length()<=actor.speed*.2+.003,
                    string.format("乘客步行瞬移 id%d %s→%s dist%.4f allowed%.4f tick%d",actor.id,before.state,actor.state,
                        (actor.position-before.position):Length(),actor.speed*.201,tick))
                if not actor.completed and #actor.targets>0 and actor.kind==status.phase then
                    local distance=remaining(actor)
                    local ahead=leaders[actor.doorId]
                    if ahead and (actor.position-before.position):Length()>.0001 then
                        check(distance>=ahead+.849,"同门乘客追越前人")
                    end
                    leaders[actor.doorId]=distance
                end
            end
            prior=current
        end
        if tick==30 then
            local before=cjson.encode(Passenger.ExportState())
            Passenger.SetPaused(true);Passenger.Update(100);Passenger.SetPaused(false)
            check(cjson.encode(Passenger.ExportState())==before,"暂停推进乘降")
            local saved=Passenger.ExportState()
            Passenger.RestoreState(cjson.decode(cjson.encode(saved)))
            local restored=Passenger.ExportState()
            check(restored.boarded==saved.boarded and restored.alighted==saved.alighted
                and #restored.actors==#saved.actors and #restored.onboard==#saved.onboard,"中途读档丢失人数")
            for i,actor in ipairs(saved.actors) do
                local retained=restored.actors[i]
                check(retained.id==actor.id and retained.targetIndex==actor.targetIndex
                    and math.abs(retained.walkDistance-actor.walkDistance)<.00001,"中途读档改变真实路径进度")
            end
            prior=Passenger.GetPassengers()
        end
        if status.phase~=phase then
            phases[phase]=(phases[phase] or 0)+elapsed-phaseStarted
            phase,phaseStarted=status.phase,elapsed
        end
        if not Game.IsDwelling() then break end
    end
    phases[phase]=(phases[phase] or 0)+elapsed-phaseStarted
    local departure=Game.GetDepartureStatus()
    print("PASSENGER_TIMING "..cjson.encode({train=selected_,stop=label,seconds=elapsed,
        phases=phases,doors=initial.doorCount,alightingDoors=usedCount,
        alighting=initial.totalAlighting,boarding=initial.totalBoarding,
        blocked=departure.blocked,reason=departure.reason,signalReason=departure.signalReason,
        traffic=Traffic.GetTrains()}))
    check(not Game.IsDwelling(),label.."900模拟秒后仍不能发车："..tostring(departure.message))
    check(not Train.IsDerailed(),label.."停站时发生碰撞")
    check(Passenger.GetStats().boarded-boardedBefore==initial.totalBoarding,label.."登乘清单数量不守恒")
    check(Passenger.GetStats().alighted-alightedBefore==initial.totalAlighting,label.."下车清单数量不守恒")
    if strict_ then check(elapsed<=(label=="origin" and 65 or 60),label.."站停超过体验上限") end
    return elapsed
end
function Start()
    local ok,message=xpcall(function()
        readOptions()
        check(Environment.Init(nil,nil,{visuals=false,hour=12,running=true}),"时钟初始化失败")
        Route.Build()
        scene_=Scene();scene_:CreateComponent("Octree")
        Train.Build(scene_)
        if selected_~=Train.GetSelectedId() then check(Train.Select(selected_),"车型加载失败") end
        Train.Reset(assert(Route.GetStations()[1]).s+1)
        Traffic.Init(scene_);Passenger.Init(scene_);Game.Init()
        finishStop("origin")
        -- 起站后真实牵引十二秒，再将真实车列放入第二站；不是全程驾驶墙钟性能测试。
        Train.SetBrake(0);for _=1,8 do Game.ThrottleUp() end
        for _=1,600 do step() end
        check(Train.GetSpeedMs()>0,"列车未实际驶离始发站")
        local second=assert(Game.GetNextStation())
        check(second.index==2,"下一站并非第二站")
        if drive_ then
            local arrived=false
            for _=1,60000 do
                local distance=second.s-Train.GetS()
                local speed=Train.GetSpeedMs()
                local braking=speed*speed/(2*Train.GetServiceDeceleration())
                local limit=math.min(Game.GetSpeedLimit()/3.6,math.sqrt(math.max(0,2*Train.GetServiceDeceleration()*(distance-5))))
                if distance<math.max(8,braking+4) or speed>limit+.3 then
                    Train.SetThrottle(0);Train.SetBrake(1)
                else
                    Train.SetBrake(0);Train.SetThrottle(speed<limit-.5 and 6 or 0)
                end
                step()
                check(not Train.IsDerailed(),"真实行驶途中发生交通冲突")
                if Game.IsDwelling() then arrived=true;break end
                check(Train.GetS()<second.s+60,"自动驾驶验收越站")
            end
            check(arrived,"1200模拟秒仍未真实行驶至第二站")
        else
            local positioned=Train.ExportState()
            positioned.s,positioned.v,positioned.throttle,positioned.brake,positioned.moving=second.s+offset_,0,0,1,true
            Train.RestoreState(positioned)
            step()
        end
        check(Game.IsDwelling() and Passenger.GetStatus().stationIndex==2,"第二站未由生产到站检测触发")
        finishStop("second")
        check(Passenger.GetStats().alighted>0,"第二站没有真实下客")
        local departureS=Train.GetS()
        Train.SetBrake(0);for _=1,8 do Game.ThrottleUp() end
        for _=1,150 do step() end
        check(Train.GetS()>departureS+1 and Train.GetSpeedMs()>0,"第二站仅显示准发但不能实际牵引驶离")
        print("ALL_PASSENGER_TIMING_PASS checks="..checks_)
    end,debug.traceback)
    Passenger.Shutdown();Traffic.Shutdown();Train.Shutdown();Environment.Destroy()
    if scene_ then scene_:Dispose();scene_=nil end
    if not ok then print("PASSENGER_TIMING_FAIL "..tostring(message));log:Write(LOG_ERROR,tostring(message)) end
    engine:Exit()
end
