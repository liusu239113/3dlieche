-- 基于3D场景脚手架生命周期；分帧跑真实Train/MDL，不伪造车辆姿态或NPC。
-- 独立CPU验收：UrhoXRuntime tests/IntervalSwitchValidation.lua -tapcode_dir=/workspace
-- -tool_mode -validate -validate-timeout=110 -validate-frames=2400；日志放/home/Maker。
local Route=require "world.Route"
local Rail=require "world.RailNetwork"
local Track=require "world.Track"
local Infrastructure=require "world.RailwayInfrastructure"
local Train=require "train.Train"
local Modes=require "config.GameModes"
---@type Scene?
local scene_=nil
---@type thread?
local runner_=nil
local checks_,drives_,frames_=0,0,0
local complete_=false
local function check(value,message)
    checks_=checks_+1
    assert(value,"[IntervalSwitch] "..message)
end
local function near(a,b,epsilon,message) check(math.abs(a-b)<=epsilon,message) end
local function point(a,b,message) check((a-b):Length()<.035,message) end
local function yieldWork() coroutine.yield() end

local function geometry()
    local intervals={}
    local previous={ [0]=-math.huge,[1]=-math.huge }
    for _,section in ipairs(Rail.GetRoutingSections()) do
        if section.kind=="interval" then
            intervals[#intervals+1]=section
            check(section.index<0 and section.stationIndex==0,"区间被塞入业务站序")
            for _,range in ipairs(Route.GetSwitchProtectionRanges()) do
                check(section.last<=range.first or section.first>=range.last,"区间岔侵入桥隧/站场门户")
            end
        end
        for base=0,1 do
            local path=base==1 and section.up or section
            local lane=base==1 and 5 or 2
            check(path.first>previous[base],"进路重叠，二分查找/交通锁无法唯一判定")
            previous[base]=path.last
            for _,s in ipairs({path.first,path.last}) do
                local p,t=Rail.Sample(s,lane)
                local main,axis=Rail.Sample(s,base)
                point(p,main,"贯通支路端点不接正线")
                check(t:DotProduct(axis)>.99999,"尖端切线不连续")
            end
            for i=0,32 do
                local s=path.first+(path.last-path.first)*i/32
                local p,t=Rail.Sample(s,lane)
                local center=Route.Sample(s)
                near(p.y,center.y,.003,"侧线丢掉真实坡高")
                local up=Rail.UpAt(s,lane)
                near(t:Length(),1,.0001,"切线不是单位向量")
                near(up:Length(),1,.0001,"Up不是单位向量")
                near(up:DotProduct(t),0,.0001,"Up未垂直坡道切线")
                check(up.y>.98,"上方向反转或异常翻滚")
                local earlier=Rail.Sample(s-.5,lane)
                local later=Rail.Sample(s+.5,lane)
                check((later-earlier):Normalized():DotProduct(t)>.999,"解析坡向与真实路径差分不一致")
                local key="section:"..section.index..":siding"
                point(Rail.Sample(s,base,key),p,"NPC固定section路径与玩家钢轨不同")
                point(Rail.Sample(s,base,"main"),Rail.Sample(s,base),"玩家选择污染NPC正线")
            end
        end
        yieldWork()
    end
    check(#Route.GetStations()==5 and #intervals>=20,"狂暴没有大量真实区间选道或污染五站业务")
    check(#Rail.GetConflictZones()==#Rail.GetRoutingSections()*4+#Rail.GetCrossovers(),"入口/出口/端站渡线冲突区缺失")
    print(string.format("[IntervalSwitch] GEOMETRY_PASS interval=%d station=%d",#intervals,#Route.GetStations()))
    return intervals
end

local function restore(s,v,up)
    Train.Reset(s)
    local saved=Train.ExportState()
    saved.s,saved.v,saved.throttle,saved.brake=s,v,0,0
    saved.reversing=up
    saved.topology={mode=Rail.GetTopologyMode(),baseLane=up and 1 or 0}
    Train.RestoreState(saved)
end

-- 包络示意（不新增物理体）：[s-L尾端 ===8节实际支点=== s+16前端]。
-- 检测目的：任一点仍占[first-2,last+2] =>拒改当前岔；最后端清空 =>解锁。
-- 双方向擦边、车头出岔但尾车仍在、低帧高速一步扫过都必须覆盖。
local function drive(section,up,speed)
    local path=up and section.up or section
    local base,lane=up and 1 or 0,up and 5 or 2
    local length=Train.GetActiveLength()
    local start=up and path.last+length+90 or path.first-90
    local finish=up and path.first-40 or path.last+length+40
    restore(start,up and -speed or speed,up)
    local nextSwitch,distance=Rail.GetNextSwitch(start,up)
    check(nextSwitch and nextSwitch.index==section.index and distance>0,"最近合法岔不是目标区间/站场")
    check(Rail.SetPlayerChoice(1,start,length,up),"真实Q/E入口不能预选侧线")
    local record=assert(Rail.GetChoices()[section.index])
    check(record.lane==lane,"预选没有落到本方向外侧股道")
    local locked,mixed,tailLocked,slope=false,false,false,false
    local positions={} ---@type Vector3[]
    for i,p in ipairs(Train.GetCarPositions()) do positions[i]=p end
    for step=1,20000 do
        local oldS=Train.GetS()
        local oldSpeed=math.abs(Train.GetSpeedMs())
        Train.SetBrake(oldSpeed>speed+1 and .12 or 0)
        Train.SetThrottle(oldSpeed<speed and 3 or 0)
        Train.Update(.08)
        Train.UpdateVisuals(.08)
        check(not Train.IsDerailed(),"真实8节过岔意外脱轨")
        local s=Train.GetS()
        local ds=math.abs(s-oldS)
        record=assert(Rail.GetChoices()[section.index])
        if record.locked then
            locked=true
            check(not Rail.SetSectionChoice(section.index,base,s,length),"车下强扳岔造成路径瞬移")
        end
        local headLane,tailLane=-1,-1
        for i,car in ipairs(Train.GetCars()) do
            local at=s+car.offset
            local a=Train.GetTrackSample(at+car.pivot)
            local b=Train.GetTrackSample(at-car.pivot)
            point(car.node.worldPosition,(a+b)*.5,"真实车体没有沿逐车前后支点")
            local axis=(a-b):Normalized()
            check((car.node.worldRotation*Vector3.FORWARD):DotProduct(axis)>.9999,"真实车体没有跟随坡向pitch")
            check((car.node.worldPosition-positions[i]):Length()<ds*1.10+.05,"整列横移/瞬移而非逐车入岔")
            for _,bogie in ipairs(car.bogies) do
                point(bogie.node.worldPosition,Train.GetTrackSample(at+bogie.z),"实际转向架脱离轨道支点")
            end
            positions[i]=car.node.worldPosition
            slope=slope or math.abs(axis.y)>.004
            local actual=Rail.GetPlayerLane(at)
            if i==1 then headLane=actual end
            tailLane=actual
        end
        mixed=mixed or headLane~=tailLane
        if (not up and s>path.last and s-length<=path.last)
            or (up and s-length<path.first and s+16>=path.first) then
            check(record.locked,"车头出岔后尾车未清提前解锁")
            tailLocked=true
        end
        if (up and s<finish) or (not up and s>finish) then break end
        check(step<20000,"真实列车未通过完整支路")
        if step%8==0 then yieldWork() end
    end
    check(locked and mixed and tailLocked,"未覆盖整列逐车进入/清尾锁")
    check(not Rail.GetChoices()[section.index].locked,"整列离开后锁未清")
    check(Rail.GetPlayerLane(Train.GetS())==base,"贯通侧线没有合回正线")
    drives_=drives_+1
    print(string.format("[IntervalSwitch] DRIVE_PASS section=%d kind=%s up=%s speed=%.0f actualCars=%d slope=%s",
        section.index,section.kind,tostring(up),speed,Train.GetCarCount(),tostring(slope)))
    return slope
end

-- 一次连续驾驶跨越三个岔区，交替主/侧线；不Reset偷换每个岔后的车辆历史。
local function consecutive(intervals,up)
    local first,last=intervals[2],intervals[4]
    local length=Train.GetActiveLength()
    local start=up and last.last+length+90 or first.first-90
    local finish=up and first.first-40 or last.last+length+40
    restore(start,up and -240 or 240,up)
    local selected,seen={},{}
    for step=1,10000 do
        local s=Train.GetS()
        local nextSection=Rail.GetNextSwitch(s,up)
        if nextSection and nextSection.index<=first.index and nextSection.index>=last.index
            and not selected[nextSection.index] then
            local side=nextSection.index%2==0
            check(Rail.SetPlayerChoice(side and 1 or -1,s,length,up),"连续驶行不能提前选择下一合法区间岔")
            selected[nextSection.index]=true
        end
        Train.Update(.08);Train.UpdateVisuals(.08)
        for i=2,4 do
            local section=intervals[i]
            local record=Rail.GetChoices()[section.index]
            if record and record.locked then seen[section.index]=true end
        end
        for _,car in ipairs(Train.GetCars()) do
            local at=Train.GetS()+car.offset
            local a=Train.GetTrackSample(at+car.pivot)
            local b=Train.GetTrackSample(at-car.pivot)
            point(car.node.worldPosition,(a+b)*.5,"连续多岔真实车体走错历史路径")
        end
        if (up and Train.GetS()<finish) or (not up and Train.GetS()>finish) then break end
        check(step<10000,"连续多岔未清尾")
        if step%8==0 then yieldWork() end
    end
    for i=2,4 do
        local section=intervals[i]
        check(selected[section.index] and seen[section.index],"连续区间没有实际经过每个预选岔")
        check(not Rail.GetChoices()[section.index].locked,"连续多岔末尾仍锁死")
    end
    print("[IntervalSwitch] CONSECUTIVE_PASS actualCars=8 switches=3 up="..tostring(up))
end

local function mesh(section)
    local root=assert(scene_):CreateChild("IntervalActualMeshes")
    check(root.worldPosition:LengthSquared()<.0001,"mesh父节点不为世界零点，会重复叠加路线高程")
    local first,last=section.first+50,section.first+300
    local count=Track.BuildChunk(root,first,last,true,yieldWork)
    check(count>0,"真实区间轨道网格为空")
    check(root:GetChild("IntervalSwitchMaterial_5")~=nil,"区间没有真实尖轨电机/标志")
    local elevated,outer=false,false
    for _,geom in ipairs(root:GetComponents("CustomGeometry",true)) do
        for index=0,geom:GetNumVertices(0)-1,29 do
            local p=geom:GetVertex(0,index).position
            local at=Route.ProjectApprox(p)
            local ground=Route.Sample(at)
            elevated=elevated or p.y>15
            local lateral=(p-ground):DotProduct(Route.RightAt(at))
            outer=outer or lateral < -2.5 or lateral>7.5
            check(p.y>=ground.y-.10 and p.y<=ground.y+2.1,"坡轨/枕/岔设备悬空或重复父级高程")
        end
        yieldWork()
    end
    check(outer,"实际mesh没有生成外侧支路")
    print(string.format("[IntervalSwitch] MESH_PASS vertices=%d elevated=%s",count,tostring(elevated)))
    root:Dispose()
    local owner=assert(scene_):CreateChild("IntervalOverhead")
    Infrastructure.BuildChunk(owner,first,first+50,yieldWork)
    local data=Infrastructure.GetValidationData()
    check(#data.supports>0,"真实接触网没有支点")
    local branches=0
    for _,support in ipairs(data.supports) do
        if support.s>=section.first and support.s<section.last then
            check(support.mode=="station" and support.left< -10 and support.right>20,"区间柱/基础穿支线模型")
            branches=branches+1
        end
    end
    check(branches>0,"区间岔没有实际外跨接触网支点")
    Infrastructure.ForgetChunk(first,first+50)
    Infrastructure.Shutdown()
    owner:Dispose()
end

local function run()
    Modes.Apply("rage");Route.Build()
    scene_=Scene();scene_:CreateComponent("Octree")
    Train.Build(scene_)
    check(Train.GetCarCount()==8 and Train.ValidateBindings(),"不是实际8节完整MDL编组")
    yieldWork()
    local intervals=geometry()
    local steep=intervals[2]
    local maxGrade=0.0
    for _,section in ipairs(intervals) do
        local grade=math.abs(Route.GradeAt(section.s))
        if grade>maxGrade then steep,maxGrade=section,grade end
    end
    check(maxGrade>.004,"区间选道未覆盖任何坡段")
    local chosen={intervals[2],steep,intervals[#intervals-2]}
    for i,section in ipairs(chosen) do
        local slope=drive(section,false,120+(i-1)*60)
        if section==steep then check(slope,"坡上真实8节完全没有pitch") end
        drive(section,true,120+(i-1)*60)
        yieldWork()
    end
    consecutive(intervals,false);consecutive(intervals,true)
    mesh(steep)
    for _,section in ipairs(chosen) do
        Rail.Reset(section.first-100,Train.GetActiveLength(),false)
        Rail.UpdatePlayer(section.last+Train.GetActiveLength()+100,Train.GetActiveLength(),false)
        check(Rail.GetChoices()[section.index] and not Rail.GetChoices()[section.index].locked,"高速一步跨岔丢历史/永久锁")
    end
    -- 存档只恢复历史不改变当前支点；区间负index可持久化，不引用假车站。
    restore(steep.first-90,120,false)
    check(Rail.SetPlayerChoice(1,Train.GetS(),Train.GetActiveLength(),false),"区间保存前预选失败")
    local saved={}
    for index,choice in pairs(Rail.GetChoices()) do saved[#saved+1]={index=index,lane=choice.lane} end
    Rail.RestoreChoices(saved)
    check(Rail.GetChoices()[steep.index].lane==2,"区间负ID历史读档丢失")
    Train.Shutdown();scene_:Dispose();scene_=nil
    Modes.Apply("normal");Route.Build()
    check(#Rail.GetRoutingSections()==5,"普通模式残留狂暴区间岔")
    near(Route.HeightAt(Route.GetLength()/2),0,.00001,"普通模式残留狂暴高程")
    scene_=Scene();scene_:CreateComponent("Octree");Train.Build(scene_)
    local station=assert(Rail.GetRoutingSection(3))
    drive(station,false,8);drive(station,true,8)
    print(string.format("ALL_INTERVAL_SWITCH_PASS checks=%d realEightCars=true drives=%d intervalCount=%d grade=%.6f normalRegression=true",
        checks_,drives_,#intervals,maxGrade))
end

local function cleanup()
    Train.Shutdown();Infrastructure.Shutdown()
    if scene_ then scene_:Dispose();scene_=nil end
end
function Start()
    runner_=coroutine.create(run)
    SubscribeToEvent("Update","HandleIntervalSwitchUpdate")
end
function HandleIntervalSwitchUpdate()
    if complete_ then return end
    frames_=frames_+1
    local runner=assert(runner_)
    local ok,message=coroutine.resume(runner)
    if not ok then
        complete_=true
        print("ALL_INTERVAL_SWITCH_FAILED frame="..frames_)
        log:Write(LOG_ERROR,tostring(message).."\n"..debug.traceback(runner))
        cleanup();engine:Exit()
    elseif coroutine.status(runner)=="dead" then
        complete_=true;cleanup();engine:Exit()
    end
end
function Stop() cleanup() end
