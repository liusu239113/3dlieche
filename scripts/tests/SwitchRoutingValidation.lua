-- 双模式、双方向真实道岔回归。源文件可直接由UrhoXRuntime无头执行；不读写存档。
local Route=require "world.Route"
local Rail=require "world.RailNetwork"
local Track=require "world.Track"
local Yard=require "world.StationYard"
local Train=require "train.Train"
local Modes=require "config.GameModes"
---@type Scene?
local scene_=nil
local checks_=0
local function check(value,message)
    checks_=checks_+1
    assert(value,"[SwitchRouting] "..message)
end
local function point(a,b,message)
    check((a-b):Length()<.025,message)
end

local function geometry(st,lane)
    local data=assert(Rail.GetStationRouting(st.index))
    local path=lane==5 and data.up or data
    local base=lane==5 and 1 or 0
    check(path.first<path.plateauFirst and path.plateauFirst<path.plateauLast and path.plateauLast<path.last,
        "路径没有严格递增的分流/平行/合流段")
    check(path.first>=0 and path.last<Route.GetLength(),"支线越界成为死胡同")
    for _,s in ipairs({path.first,path.last}) do
        local p,t=Rail.Sample(s,lane)
        local main,axis=Rail.Sample(s,base)
        point(p,main,"支线端点没有汇入真实正线")
        check(t:DotProduct(axis)>.99999,"入口/出口切线不连续")
    end
    local previous=Rail.Sample(path.first,lane)
    local sawDifferent=false
    for s=path.first+1,path.last,1 do
        local p,t=Rail.Sample(s,lane)
        check((p-previous):Length()<1.03,"曲线跳变而非按米连续前进")
        check(math.abs(t:Length()-1)<.001,"切线没有归一化")
        if (p-Rail.Sample(s,base)):Length()>8 then sawDifferent=true end
        previous=p
    end
    check(sawDifferent,"支线只是正线标签，没有实际分离")
    if lane==5 then
        point(Rail.Sample(st.s,5),Rail.Sample(st.s,1),"上行绕线破坏原客运站台停靠")
        check(path.first>st.s+Route.PlatformEnd+250,"上行支路未在平台前完整汇回")
    else
        check(path.plateauFirst<=st.s+Route.PlatformStart and path.plateauLast>=st.s+Route.PlatformEnd,
            "下行平行到发线不能覆盖完整客运站台")
    end
    local mid=(path.plateauFirst+path.plateauLast)/2
    local key="yard:"..st.index..":siding"
    point(Rail.Sample(mid,base,key),Rail.Sample(mid,lane),"NPC单站独立路径未沿相同钢轨")
    point(Rail.Sample(mid,base,"main"),Rail.Sample(mid,base),"NPC主线路径被玩家预选污染")
    check(Rail.GetPathLane(path.first-20,lane)==base and Rail.GetPathLane(path.last+20,lane)==base,
        "支线端点之外未归入对应方向正线")
    return path
end

-- 使用实际Train.Update/UpdateVisuals，不复制一套车辆位姿实现来假装接入成功。
local function drive(st,lane)
    local data=assert(Rail.GetStationRouting(st.index))
    local path=lane==5 and data.up or data
    local up=lane==5
    local base=up and 1 or 0
    -- 本fixture只预选这一个站场。lane2/5已是全局所有支路的几何通道，
    -- 邻接区间未选时必须仍走main；独立oracle用稳定yard key限定范围，不能
    -- 用GetPlayerLane自证正确，也不能在车下强选邻接区间来掩盖错误。
    local pathKey="yard:"..st.index..":siding"
    local function expected(s) return Rail.Sample(s,base,pathKey) end
    local length=Train.GetActiveLength()
    local startS=up and path.last+length+80 or path.first-100
    local endS=up and path.first-40 or path.last+length+40
    Train.Reset(startS)
    local saved=Train.ExportState()
    saved.s,saved.v,saved.brake,saved.throttle=startS,up and -8 or 8,0,0
    saved.reversing=up
    saved.topology={mode=Rail.GetTopologyMode(),baseLane=up and 1 or 0}
    Train.RestoreState(saved)
    check(Rail.SetPlayerChoice(1,startS,length,up),"真实列车不能预选当前方向贯通支路")
    check(Rail.GetChoices()[st.index].lane==lane,"预选没有选择当前方向支线")
    local positions={} ---@type Vector3[]
    for i,p in ipairs(Train.GetCarPositions()) do positions[i]=p end
    local locked,tailLocked,mixed=false,false,false
    for step=1,12000 do
        local oldS=Train.GetS()
        local speed=math.abs(Train.GetSpeedMs())
        Train.SetThrottle(speed<8 and 4 or 0)
        Train.SetBrake(speed>9 and .18 or 0)
        Train.Update(.1)
        Train.UpdateVisuals(.1)
        check(not Train.IsDerailed(),"8m/s真实过岔发生脱轨")
        local s=Train.GetS()
        local ds=math.abs(s-oldS)
        local record=assert(Rail.GetChoices()[st.index])
        if record.locked then
            locked=true
            check(not Rail.SetStationChoice(st.index,up and 1 or 0,s,length),"整列未清尾却允许扳岔")
            check(Rail.GetStatus().locked,"HUD诊断漏掉整列锁岔")
        end
        local leadLane,tailLane=-1,-1
        for i,car in ipairs(Train.GetCars()) do
            local center=s+car.offset
            local front=expected(center+car.pivot)
            local rear=expected(center-car.pivot)
            point(car.node.worldPosition,(front+rear)*.5,"车节未按各自位置沿同一路径："..i)
            point(Train.GetTrackSample(center),expected(center),"车节历史路径被机车lane覆盖")
            check((car.node.worldPosition-positions[i]):Length()<ds*1.05+.04,"整列视觉横移而非逐节入岔")
            for _,bogie in ipairs(car.bogies) do
                point(bogie.node.worldPosition,expected(center+bogie.z),"转向架没有沿自己的实际支点运行")
            end
            positions[i]=car.node.worldPosition
            local actual=Rail.GetPlayerLane(center)
            if i==1 then leadLane=actual end
            tailLane=actual
        end
        mixed=mixed or leadLane~=tailLane
        if (not up and s>path.last and s-length<=path.last)
            or (up and s-length<path.first and s+16>=path.first) then
            check(record.locked,"先出岔的车头/领行尾端导致提前解锁")
            tailLocked=true
        end
        if (up and s<endS) or (not up and s>endS) then break end
        check(step<12000,"列车卡在支路未能重新汇入正线")
    end
    check(locked and mixed and tailLocked,"没有覆盖逐节入岔/清尾锁定")
    check(not Rail.GetChoices()[st.index].locked,"整列清尾后永久锁岔")
    check(Rail.GetPlayerLane(Train.GetS())==(up and 1 or 0),"支路没有完整贯通回主线")
    print(string.format("[SwitchRouting] DRIVE_PASS mode=%s lane=%d actualCars=%d",Modes.GetId(),lane,Train.GetCarCount()))
end

local function mesh(st)
    local routing=assert(Rail.GetStationRouting(st.index))
    local root=assert(scene_):CreateChild("SwitchMeshValidation")
    local middle=(routing.up.plateauFirst+routing.up.plateauLast)/2
    local vertices=Track.BuildChunk(root,middle-30,middle+30,true)
    check(vertices>0 and #root:GetComponents("CustomGeometry",true)==4,"真实上行支路线网格没有生成")
    local sawBranch=false
    for _,geometry in ipairs(root:GetComponents("CustomGeometry",true)) do
        local count=geometry:GetNumVertices(0)
        for index=0,count-1,17 do
            local position=geometry:GetVertex(0,index).position
            local s=Route.ProjectApprox(position)
            if (position-Rail.Sample(s,1)):Length()>8 then sawBranch=true;break end
        end
    end
    check(sawBranch,"网格只有两条正线，没有实际可见上行支路")
    local entry=Yard.Build(root,st)
    check(entry.ready and entry.vertices>0,"StationYard真实尖轨构建失败")
    Yard.Forget(st.index)
    root:Dispose()
end

function Start()
    local ok,message=xpcall(function()
        scene_=Scene()
        scene_:CreateComponent("Octree")
        for _,mode in ipairs({"normal","rage"}) do
            Modes.Apply(mode)
            Route.Build()
            if Train.GetCarCount()==0 then Train.Build(scene_) end
            local stations=Route.GetStations()
            for _,st in ipairs(stations) do geometry(st,2);geometry(st,5) end
            local st=stations[3]
            drive(st,2)
            drive(st,5)
            mesh(st)
            -- 默认主线历史不会被一步越岔漏掉，也不导致永远锁定。
            local path=assert(Rail.GetStationRouting(st.index))
            Rail.Reset(path.first-100,220,false)
            Rail.UpdatePlayer(path.last+300,220,false)
            check(Rail.GetChoices()[st.index] and Rail.GetChoices()[st.index].lane==0
                and not Rail.GetChoices()[st.index].locked,"高速扫掠丢失默认路径或锁死")
            if mode=="rage" then
                Rail.Reset(Route.GetLength()-20,220,false)
                local before=Rail.Sample(Route.GetLength()-20,Rail.GetPlayerLane(Route.GetLength()-20))
                check(Rail.RequestDirectionChange(Route.GetLength()-20,220,true),"狂暴缓冲终端不能原股道折返")
                point(Rail.Sample(Route.GetLength()-20,Rail.GetPlayerLane(Route.GetLength()-20)),before,
                    "狂暴换向瞬移到另一股道")
            else
                Rail.Reset(st.s,220,false)
                check(not Rail.RequestDirectionChange(st.s,220,true),"普通区间逆行限制被狂暴污染")
            end
        end
        print("SWITCH_ROUTING_ALL_PASS checks="..checks_)
    end,debug.traceback)
    Train.Shutdown()
    Yard.Shutdown()
    if scene_ then scene_:Dispose();scene_=nil end
    if not ok then log:Write(LOG_ERROR,tostring(message)) end
    engine:Exit()
end
