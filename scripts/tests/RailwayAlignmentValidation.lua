-- 独立CPU工程回归，只读GameConfig，不创建场景、玩家，不访问网络、云或存档。
-- 通过UrhoXRuntime离线运行；所有断言完成后退出。
local Alignment = require "world.RailwayAlignment"
local GameConfig = require "config.GameConfig"
local assertions = 0

local function check(ok,message)
    assertions=assertions+1
    assert(ok,"[AlignmentValidation] " .. message)
end

local function near(a,b,tolerance,message)
    check(math.abs(a-b)<=tolerance,string.format("%s actual=%.12g expected=%.12g tolerance=%.3g",message,a,b,tolerance))
end

local function vectorNear(a,b,tolerance,message)
    near(a.x,b.x,tolerance,message .. ".x")
    near(a.y,b.y,tolerance,message .. ".y")
    near(a.z,b.z,tolerance,message .. ".z")
end

local function rejects(fn,message)
    local ok,err=pcall(fn)
    check(not ok,message .. " accepted")
    check(tostring(err):find("Alignment",1,true)~=nil,message .. " did not produce a contextual validation error")
end

-- 独立高密度复合辛普森参考积分，不复用生产模块的积分单元。
local function referenceIntegral(heading,k0,k1,length,ds)
    local n=math.max(2,2*math.ceil(ds/0.2/2))
    local h=ds/n
    local x,z=0.0,0.0
    for i=0,n do
        local u=i*h
        local theta=heading+k0*u+0.5*(k1-k0)/length*u*u
        local weight=(i==0 or i==n) and 1 or (i%2==0 and 2 or 4)
        x,z=x+weight*math.sin(theta),z+weight*math.cos(theta)
    end
    return x*h/3,z*h/3
end

local function basicGeometry()
    local straight=Alignment.fromSegments({{type="straight",length=200}},{start={x=10,y=7,z=20},startYaw=90})
    local p,t,yaw=straight:Sample(100)
    vectorNear(p,Vector3(110,7,20),1e-5,"left-handed straight")
    vectorNear(t,Vector3.RIGHT,1e-6,"tangent")
    near(yaw,90,1e-12,"degree yaw")
    vectorNear(straight:RightAt(100),Vector3(0,0,-1),1e-6,"right handedness")
    vectorNear(straight:SampleOffset(100,4,3),Vector3(110,10,16),1e-5,"Route compatible offset")
    near(straight:GradeAt(100),0,0,"default grade")
    near(straight:CantAt(100),0,0,"default cant")
    vectorNear(straight:Sample(-100),straight:Sample(0),0,"start clamp")
    vectorNear(straight:Sample(1000),straight:Sample(200),0,"finish clamp")
    near(straight:GetPoints()[#straight:GetPoints()].s,200,0,"point cache includes final endpoint")
    local distance,s=straight:DistanceTo(Vector3(70,9000,26))
    near(distance,6,1e-8,"XZ projection ignores elevation")
    near(s,60,1e-8,"straight chainage")
    local before,bs=straight:DistanceTo(Vector3(-5,0,20))
    near(before,15,1e-8,"before-start distance")
    near(bs,0,0,"before-start clamp")
    local after,as=straight:DistanceTo(Vector3(250,0,20))
    near(after,40,1e-8,"after-end distance")
    near(as,200,0,"after-end clamp")
    check(straight:CanPlaceFootprint(Vector3(60,0,50),2,25),"safe footprint rejected")
    check(not straight:CanPlaceFootprint(Vector3(60,0,46),2,25),"unsafe footprint allowed")
    check(not straight:CanPlaceFootprint(Vector3(60,0,47),2,25),"uncertain exact clearance must be conservative")
    for _,dir in ipairs({-1,1}) do
        local arc=Alignment.FromSegments({{type="arc",radius=300,angle=90,dir=dir}})
        local ap,at,ay=arc:Sample(arc:GetLength())
        vectorNear(ap,Vector3(dir*300,0,300),4e-5,"analytic quarter-circle endpoint")
        vectorNear(at,Vector3(dir,0,0),1e-6,"quarter-circle tangent")
        near(ay,90*dir,1e-10,"quarter-circle angle")
        for _,fraction in ipairs({0,0.1,0.5,0.9,1}) do
            local target=arc:GetLength()*fraction
            local q=arc:SampleOffset(target,-20,1000)
            local d,atS=arc:DistanceTo(q)
            near(d,20,5e-5,"circle nearest offset")
            near(atS,target,8e-5,"circle nearest chainage")
        end
    end
    local tiny=Alignment.FromSegments({{type="arc",length=100,curvature=1e-12}})
    local tp=tiny:Sample(100)
    near(tp.x,5e-9,1e-13,"stable tiny-curvature integration")
    near(tp.z,100,1e-6,"tiny-curvature straight limit")
    local td,ts=tiny:DistanceTo({x=3,y=0,z=50})
    near(td,3,1e-7,"tiny-curvature projection distance")
    near(ts,50,1e-6,"tiny-curvature projection chainage")
    for _,dir in ipairs({-1,1}) do
        local full=Alignment.FromSegments({{type="arc",radius=100,angle=360,dir=dir}})
        vectorNear(full:Sample(full:GetLength()),Vector3.ZERO,1e-5,"full circle endpoint")
        local fd,fs=full:DistanceTo(full:SampleOffset(100,7,0))
        near(fd,7,2e-5,"full circle offset distance")
        near(fs,100,3e-5,"full circle nearest chainage")
    end
    print("[AlignmentValidation] 基础几何通过 BASIC_GEOMETRY_PASS")
end

local function integrationAndContinuity()
    local curves={
        {type="transition",length=240,k0=0,k1=1/600},
        {type="transition",length=240,k0=1/600,k1=-1/600},
        {type="transition",length=240,k0=-1/600,k1=0},
    }
    local route=Alignment.FromSegments(curves,{startYaw=23,integrationTolerance=1e-7,pointStep=7})
    local rx,rz,heading=0.0,0.0,math.rad(23)
    for i,seg in ipairs(route:GetSegments()) do
        near(seg.x,rx,1e-7,"integrated start x")
        near(seg.z,rz,1e-7,"integrated start z")
        for _,fraction in ipairs({0.013,0.25,0.731,0.99999,1}) do
            local ds=seg.length*fraction
            local dx,dz=referenceIntegral(heading,seg.k0,seg.k1,seg.length,ds)
            local pos=route:Sample(seg.s+ds)
            -- Vector3输出可能为单精度；数值积分界在下方用双精度字段单测。
            near(pos.x,rx+dx,5e-5,"reference sample x")
            near(pos.z,rz+dz,8e-5,"reference sample z")
        end
        local dx,dz=referenceIntegral(heading,seg.k0,seg.k1,seg.length,seg.length)
        rx,rz=rx+dx,rz+dz
        heading=heading+0.5*(seg.k0+seg.k1)*seg.length
        if i<#route:GetSegments() then
            local nextSeg=route:GetSegments()[i+1]
            near(nextSeg.x,rx,1e-7,"double integral error x")
            near(nextSeg.z,rz,1e-7,"double integral error z")
            near(nextSeg.heading,heading,1e-12,"analytic heading accumulation")
        end
    end
    near(route:GetValidationData().endX,rx,1e-7,"bounded accumulated integration x")
    near(route:GetValidationData().endZ,rz,1e-7,"bounded accumulated integration z")
    near(route:GetValidationData().maxCurvatureJump,0,1e-15,"explicit matching transitions")
    for _,seg in ipairs(route:GetSegments()) do
        if seg.s>0 then
            local epsilon=0.001
            local left,lt,ly=route:Sample(seg.s-epsilon)
            local right,rt,ry=route:Sample(seg.s+epsilon)
            check((right-left):Length()<0.0022,"position seam")
            check((rt-lt):Length()<0.00001,"tangent seam")
            check(math.abs(ry-ly)<0.001,"heading seam")
            check(math.abs(route:CurvatureAt(seg.s-epsilon)-route:CurvatureAt(seg.s+epsilon))<2e-8,"curvature seam")
        end
    end
    local constant=Alignment.FromSegments({{type="transition",length=100,k0=0.001,k1=0.001}})
    near(constant:GetValidationData().totalYaw,math.deg(0.1),1e-12,"constant-curvature transition")
    local zero=Alignment.FromSegments({{type="transition",length=100,k0=0,k1=0}})
    vectorNear(zero:Sample(100),Vector3(0,0,100),1e-5,"zero transition is straight")
    print("[AlignmentValidation] 有界积分与G2连续通过 BOUNDED_INTEGRATION_AND_G2_CONTINUITY_PASS")
end

local function legacyConservation()
    local oldDefs=GameConfig.RouteSegments
    local route=Alignment.FromLegacySegments(oldDefs,{start=GameConfig.RouteStart,startYaw=GameConfig.RouteStartYaw,
        pointStep=GameConfig.RouteStep,transitionLength=120})
    local parents,elements=route:GetSourceSegments(),route:GetSegments()
    check(#parents==#oldDefs,"parent segment count changed")
    check(#parents==21,"five-station corridor expected 21 parents")
    local chainage,totalAngle=0.0,0.0
    for i,def in ipairs(oldDefs) do
        local p=parents[i]
        local length=def.type=="arc" and def.radius*math.rad(def.angle) or def.length
        check(p.type==def.type and p.landmark==def.landmark,"parent metadata changed")
        near(p.length,length,1e-10,"per-source length")
        near(p.s,chainage,1e-8,"parent chainage")
        vectorNear(p.pos,route:Sample(p.s),0,"parent actual start position")
        near(p.yaw,select(3,route:Sample(p.s)),1e-10,"parent actual yaw")
        if def.type=="arc" then
            check(p.composite and p.radius<def.radius,"compensated peak radius missing")
            near(p.sourceRadius,def.radius,0,"original radius metadata")
            local entry,middle,exit=elements[p.firstElement],elements[p.firstElement+1],elements[p.lastElement]
            near(entry.length,exit.length,0,"symmetric transition lengths")
            near(entry.k0,0,0,"entry zero curvature")
            near(exit.k1,0,0,"exit zero curvature")
            near(entry.k1,middle.k0,0,"entry/middle curvature")
            near(middle.k1,exit.k0,0,"middle/exit curvature")
            local signedAngle=math.rad(def.angle)*def.dir
            near(0.5*(entry.k0+entry.k1)*entry.length+middle.k0*middle.length+
                0.5*(exit.k0+exit.k1)*exit.length,signedAngle,1e-12,"per-source turn preserved")
            near(p.endYaw-p.yaw,def.angle*def.dir,1e-10,"actual per-source turn")
            totalAngle=totalAngle+def.angle*def.dir
        else check(p.firstElement==p.lastElement,"straight subdivided unexpectedly") end
        chainage=chainage+length
    end
    near(route:GetLength(),chainage,1e-8,"whole corridor length")
    near(route:GetValidationData().totalYaw,totalAngle,1e-10,"whole corridor signed turn")
    near(route:GetValidationData().maxCurvatureJump,0,1e-12,"legacy G2 joins")
    for _,def in ipairs(oldDefs) do check(def.sourceIndex==nil and def.k0==nil,"input mutated") end
    -- 原站点比例目标与合法直线包络均不变，因此停靠s及站序保持不变。
    local previous=-1.0
    for _,station in ipairs(GameConfig.Stations) do
        local target=station.at*chainage
        local best,delta=0.0,math.huge
        for _,parent in ipairs(parents) do
            if parent.type=="straight" and not parent.landmark then
                local first=math.max(parent.s+710,previous+350)
                local last=parent.s+parent.length-410
                if first<=last then
                    local candidate=math.max(first,math.min(last,target))
                    if math.abs(candidate-target)<delta then best,delta=candidate,math.abs(candidate-target) end
                end
            end
        end
        check(delta<math.huge and best>previous,"station order/envelope not preserved")
        near(route:CurvatureAt(best),0,0,"station stays on tangent")
        near(route:GradeAt(best),0,0,"station default flat")
        previous=best
    end
    print(string.format("[AlignmentValidation] 原线段长度总角与站序保持通过 LEGACY_CONSERVATION_PASS length=%.9f angle=%.6f parents=%d elements=%d points=%d index=%d",
        route:GetLength(),route:GetValidationData().totalYaw,#parents,#elements,#route:GetPoints(),route:GetValidationData().indexPieces))
    return route
end

local function verticalAndCant()
    local template=Alignment.EngineeringTemplate()
    local route=Alignment.Build(template)
    local p0=route:Sample(0)
    local pm=route:Sample(700)
    local pf=route:Sample(1400)
    near(p0.y,12,1e-6,"explicit starting elevation")
    near(pm.y,13.5,1e-6,"vertical curve midpoint elevation")
    near(pf.y,15,1e-6,"explicit final elevation")
    near(route:GradeAt(550),0.005,1e-12,"linear rising grade")
    near(route:GradeAt(850),0.005,1e-12,"linear falling grade")
    near(route:GradeAt(700),0.01,1e-12,"crest grade continuity")
    for _,s in ipairs({400,700,1000}) do
        near(route:GradeAt(s-1e-5),route:GradeAt(s+1e-5),1e-8,"vertical grade join")
        local a,b=route:Sample(s-0.01),route:Sample(s+0.01)
        near((b.y-a.y)/0.02,route:GradeAt(s),0.0001,"height derivative matches grade")
    end
    near(route:CantAt(460),0.05,1e-12,"cant entry interpolation")
    near(route:CantAt(940),0.05,1e-12,"cant exit interpolation")
    near(route:CantAt(-100),0,0,"cant start clamp")
    for _,s in ipairs({0,400,460,700,940,1000,1400}) do
        local tangent,right=route:TangentAt(s),route:RightAt(s)
        near(tangent:Length(),1,1e-6,"graded tangent unit length")
        near(right:Length(),1,1e-6,"banked right unit length")
        near(tangent:DotProduct(right),0,1e-6,"banked frame orthogonal")
        local left=route:SampleOffset(s,-0.7175,0)
        local rightRail=route:SampleOffset(s,0.7175,0)
        near(left.y-rightRail.y,route:CantAt(s),2e-6,"cant is exact left-minus-right height metres")
        near((left-rightRail):Length(),1.435,1e-4,"banked reference gauge")
        local withY=route:SampleOffset(s,3,2)
        local withoutY=route:SampleOffset(s,3,0)
        near(withY.y-withoutY.y,2,2e-6,"offset y remains world vertical")
    end
    template.start.x=999
    template.profile.segments[1].length=1
    template.cant[3].cant=-0.2
    near(route:Sample(0).x,0,0,"input start copied")
    near(route:Sample(400).y,12,1e-6,"profile copied")
    near(route:CantAt(520),0.1,1e-12,"cant copied")
    print("[AlignmentValidation] 显式纵断面与超高通过 EXPLICIT_VERTICAL_PROFILE_AND_CANT_PASS")
end

local function nearestPointAndPerformance(route)
    -- 净空设计和边界情形：XZ圆形占地包络，不创建物理碰撞体。
    -- 左侧偏移 -------- 线路中心(s) -------- 右侧偏移
    -- 覆盖两侧、每个缓和段和接缝、首尾端点、靠近其他线路分支的情形。
    local maxLeaves,maxEvaluations,maxDistanceError=0,0,0.0
    local start=os.clock()
    local count=0
    for _,seg in ipairs(route:GetSegments()) do
        for _,fraction in ipairs({0.001,0.19,0.5,0.81,0.999}) do
            local s=seg.s+fraction*seg.length
            for _,offset in ipairs({-50,-5,0,5,50}) do
                local query=route:SampleOffset(s,offset,2000)
                local distance,projected=route:DistanceTo(query)
                local epsilon=math.abs(distance-math.abs(offset))
                maxDistanceError=math.max(maxDistanceError,epsilon)
                near(distance,math.abs(offset),0.006,"global XZ nearest/offset consistency")
                near(projected,s,1.0,"nearest chainage in broad corridor")
                local stats=route:GetValidationData()
                maxLeaves=math.max(maxLeaves,stats.lastQueryLeaves)
                maxEvaluations=math.max(maxEvaluations,stats.lastQueryEvaluations)
                count=count+1
            end
        end
    end
    local seconds=os.clock()-start
    check(maxLeaves<24,"nearest query scans too many index pieces")
    check(maxEvaluations<250,"nearest query refinement budget too large")
    -- 最近点不一定在先遇到的线路分支上；折返线路靠近去程，
    -- 验证BVH确实搜索全局，而非只从最近缓存采样点附近寻找。
    local folded=Alignment.FromSegments({{type="straight",length=500},
        {type="arc",radius=20,angle=180,dir=1},{type="straight",length=500}},{pointStep=100})
    local distance,s=folded:DistanceTo(Vector3(37,5000,250))
    near(distance,3,1e-5,"global return-branch clearance")
    near(s,500+20*math.pi+250,1e-6,"global return-branch chainage")
    -- 与密集采样及独立无导数极小值求解交叉验证距离精度。
    local transition=Alignment.FromSegments({{type="transition",length=400,k0=-0.002,k1=0.003}},
        {integrationTolerance=1e-7,distanceTolerance=0.0001,pointStep=100})
    for i=1,30 do
        local q={x=-100+i*11,y=500,z=-100+i*19}
        local function d2(at)
            local dx,dz=referenceIntegral(0,-0.002,0.003,400,at)
            return (dx-q.x)^2+(dz-q.z)^2
        end
        local best,at=math.huge,0.0
        for j=0,400 do local d=d2(j); if d<best then best,at=d,j end end
        local lo,hi=math.max(0,at-1),math.min(400,at+1)
        for _=1,45 do
            local a,b=lo+(hi-lo)/3,hi-(hi-lo)/3
            if d2(a)<d2(b) then hi=b else lo=a end
        end
        local expected=math.sqrt(d2((lo+hi)/2))
        local actual=transition:DistanceTo(q)
        near(actual,expected,0.000101,"independent global minimum")
    end
    print(string.format("[AlignmentValidation] 全线XZ最近点与BVH性能通过 XZ_NEAREST_BVH_PASS queries=%d seconds=%.4f maxLeaves=%d maxEvaluations=%d maxOffsetError=%.6f",
        count,seconds,maxLeaves,maxEvaluations,maxDistanceError))
end

local function invalidInputs()
    local nan=0/0
    for _,v in ipairs({nan,math.huge,-math.huge,"10",false}) do
        rejects(function() Alignment.FromSegments({{type="straight",length=v}}) end,"bad length")
        rejects(function() Alignment.FromSegments({{type="arc",radius=300,angle=v}}) end,"bad angle")
        rejects(function() Alignment.FromSegments({{type="transition",length=100,k0=0,k1=v}}) end,"bad curvature")
    end
    rejects(function() Alignment.Build({segments={}}) end,"empty geometry")
    rejects(function() Alignment.Build({segments={[2]={type="straight",length=10}}}) end,"sparse geometry")
    rejects(function() Alignment.FromSegments({{type="spiral",length=10}}) end,"unknown type")
    rejects(function() Alignment.FromSegments({{type="straight",length=0}}) end,"zero length")
    rejects(function() Alignment.FromSegments({{type="straight",length=-10}}) end,"negative length")
    rejects(function() Alignment.FromSegments({{type="arc",radius=-100,angle=30}}) end,"negative radius")
    rejects(function() Alignment.FromSegments({{type="arc",radius=100,angle=30,dir=0}}) end,"invalid direction")
    rejects(function() Alignment.FromSegments({{type="arc",radius=100,angle=30,length=10}}) end,"inconsistent arc length")
    rejects(function() Alignment.SymmetricCurve(100,20,50,1) end,"zero circular middle")
    rejects(function() Alignment.FromLegacySegments({{type="arc",radius=100,angle=20}},{transitionLength=nan}) end,"NaN transition option")
    rejects(function() Alignment.FromSegments({{type="straight",length=100}},{start={x=nan,y=0,z=0}}) end,"NaN start")
    rejects(function() Alignment.FromSegments({{type="straight",length=100}},{startYaw=math.huge}) end,"infinite yaw")
    rejects(function() Alignment.FromSegments({{type="straight",length=100}},{pointStep=0}) end,"zero sample step")
    rejects(function() Alignment.FromSegments({{type="straight",length=100}},
        {integrationTolerance=0.01,distanceTolerance=0.001}) end,"incompatible precision budgets")
    rejects(function() Alignment.FromSegments({{type="straight",length=100}},
        {gauge=0.1,cant={{s=0,cant=0.2}}}) end,"cant greater than gauge")
    rejects(function() Alignment.FromSegments({{type="straight",length=100}},{profile={segments={
        {type="grade",length=50,grade=0}}}}) end,"short profile")
    rejects(function() Alignment.FromSegments({{type="straight",length=100}},{profile={segments={
        {type="grade",length=100,grade=0.01}}}}) end,"unsmoothed grade jump")
    rejects(function() Alignment.FromSegments({{type="straight",length=100}},{profile={segments={
        {type="verticalCurve",length=100,endGrade=0.01,endY=9}}}}) end,"inconsistent elevation")
    rejects(function() Alignment.FromSegments({{type="straight",length=100}},{profile={segments={
        {type="verticalCurve",length=100,endGrade=nan}}}}) end,"NaN grade")
    rejects(function() Alignment.FromSegments({{type="straight",length=100}},{cant={{s=50,cant=0},{s=40,cant=0}}}) end,"unordered cant")
    rejects(function() Alignment.FromSegments({{type="straight",length=100}},{cant={{s=10,cant=nan}}}) end,"NaN cant")
    rejects(function() Alignment.FromSegments({{type="straight",length=100}},{cant={{s=101,cant=0}}}) end,"cant beyond endpoint")
    local valid=Alignment.FromSegments({{type="straight",length=100}})
    for _,v in ipairs({nan,math.huge,-math.huge,"10"}) do
        rejects(function() valid:Sample(v) end,"invalid query s")
        rejects(function() valid:SampleOffset(10,v,0) end,"invalid offset")
        rejects(function() valid:DistanceTo({x=v,y=0,z=10}) end,"invalid projection")
    end
    near(valid:GetLength(),100,0,"failed builds do not mutate valid instance")
    print("[AlignmentValidation] 非法数值输入与实例隔离通过 NAN_INVALID_AND_ISOLATION_PASS")
end

function Start()
    local ok,err=pcall(function()
        basicGeometry()
        integrationAndContinuity()
        local route=legacyConservation()
        verticalAndCant()
        nearestPointAndPerformance(route)
        invalidInputs()
        print(string.format("[AlignmentValidation] 铁路工程专项全部通过 ALL_RAILWAY_ALIGNMENT_PASS assertions=%d",assertions))
    end)
    if not ok then log:Write(LOG_ERROR,"[AlignmentValidation] 专项失败 FAIL " .. tostring(err)) end
    engine:Exit()
end
