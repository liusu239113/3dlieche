-- 专项仅加载路线/设施，不require Game/main/Save/Cloud，不接触用户本地或云存档。
local Route=require "world.Route"
local Landmarks=require "world.Landmarks"
local Infrastructure=require "world.RailwayInfrastructure"
local Standards=require "config.RailwayStandards"
local RailNetwork=require "world.RailNetwork"
---@type Scene?
local scene_=nil
local checks_=0
local function check(value,message) checks_=checks_+1;assert(value,"[ChineseRailValidation] "..message) end
local function near(a,b) return math.abs(a-b)<.0001 end
local function build(a,b)
    local owner=assert(scene_):CreateChild("Fixture_"..a)
    local yielded=0
    local n=Infrastructure.BuildChunk(owner,a,b,function() yielded=yielded+1 end)
    check(n>0,"empty fixture chunk")
    check(yielded>5,"missing cooperative yield points")
    return owner,n
end
local function count(owner)
    local n=0
    for _,geom in ipairs(owner:GetComponents("CustomGeometry",true)) do
        for i=0,geom.numGeometries-1 do n=n+geom:GetNumVertices(i) end
    end
    return n
end
local function clear(a,b,owner)
    Infrastructure.ForgetChunk(a,b)
    owner:Dispose()
end
local function run()
    Route.Build()
    Landmarks.Init()
    scene_=Scene();scene_:CreateComponent("Octree")
    Infrastructure.Init(scene_)
    local plan=Infrastructure.GetValidationData()
    check(near(Standards.Track.gauge,1.435),"1435mm gauge metadata")
    check(Standards.Track.railMassKgPerM==60 and Standards.Track.sleeperMaterial=="prestressed_concrete","60kg rail/concrete sleeper standard")
    check(plan.ownership=="half-open" and plan.chunkLength==50,"50m half-open API")
    check(plan.mainLineLaterals[1]==0 and plan.mainLineLaterals[2]==5 and plan.sidingLateral==-10.8,"new left-running topology")
    check(plan.rigidArmMinimum>=Standards.Clearance.rigidOverheadMinimum,"arm pantograph clearance")
    check(plan.messengerMinimumHeight>plan.contactHeight+.5,"messenger/contact clearance")
    for i,support in ipairs(plan.supports) do
        if i>1 then
            local span=support.s-plan.supports[i-1].s
            check(span>=40-.0001 and span<=60+.0001,"support span outside 40..60m")
        end
        if support.mode=="bridge" then
            for _,x in ipairs({support.left,support.right}) do
                check(x-Standards.Catenary.bridgeFoundationWidth/2>=-6.7 and x+Standards.Catenary.bridgeFoundationWidth/2<=11.7,"bridge mast not on real deck")
                check(math.min(math.abs(x),math.abs(x-5))-.25>2.2,"bridge mast track clearance")
            end
            check(near(support.baseY,-.18),"bridge footing floats above/below deck")
        elseif support.mode=="station" then
            check(support.left+.39<-10.8-2.2 and support.right-.39>22.4+1.7,"station/freight portal column clearance")
        elseif support.mode=="tunnel" then check(support.roofLeft>8 and support.roofRight>8,"tunnel roof unavailable")
        end
    end
    local kinds={}
    for _,marker in ipairs(plan.markers) do
        kinds[marker.kind]=(kinds[marker.kind] or 0)+1
        if marker.kind=="fouling" then check(near(marker.extra.separation,4),"fouling marker not at actual4m separation") end
        if marker.kind=="gradient" then check(near(marker.extra.permille,0),"fake grade on flat analytic route") end
        if marker.kind=="whistle" then check(near(math.abs(marker.s-marker.extra.target),600),"whistle lead not600m") end
        if marker.kind=="curve" or marker.kind=="curveTransition" then
            local e=marker.extra
            check(near(1/e.radius,math.abs(Route.CurvatureAt((e.startS+e.endS)/2))),"curve marker uses legacy radius instead of engineering curvature")
            if e.transitionLength>0 then
                check(near(e.HY-e.ZH,e.transitionLength) and near(e.HZ-e.YH,e.transitionLength),"transition limits missing")
                check(math.abs(Route.CurvatureAt(e.ZH))<.000001 and math.abs(Route.CurvatureAt(e.HZ))<.000001,"ZH/HZ not zero-curvature limits")
            end
        end
    end
    for _,kind in ipairs({"kilometre","halfKilometre","curve","gradient","whistle","fouling"}) do check((kinds[kind] or 0)>0,"missing marker "..kind) end
    check(#plan.stationBoundaries==#Route.GetStations(),"station boundary data missing")
    for _,boundary in ipairs(plan.stationBoundaries) do check(boundary.source=="StationYard.entrySignals" and not boundary.board,"duplicate false station boundary sign") end

    -- 相邻50m与相同块幂等；几何实际顶点数和返回值必须完全一致。
    local chosen=0
    for s=1600,Route.GetLength()-100,1600 do
        local inStation=false
        for _,st in ipairs(Route.GetStations()) do if s>st.s-1300 and s<st.s+600 then inStation=true end end
        local inStructure=false
        for _,def in ipairs(Landmarks.GetDefinitions()) do if def.kind~="mountain" and s>def.first-100 and s<def.last+100 then inStructure=true end end
        -- 实际扩展后的routing可超出旧st.s±1300；以生产范围（含yardMargin）选地面。
        for _,section in ipairs(RailNetwork.GetRoutingSections()) do
            if s>=math.min(section.first,section.up.first)-Standards.Clearance.yardMargin
                and s<math.max(section.last,section.up.last)+Standards.Clearance.yardMargin then inStation=true end
        end
        -- 终端渡线也使用站场门架、禁止区间信号；fixture必须是真正无渡线的地面。
        for _,cross in ipairs(RailNetwork.GetCrossovers()) do
            if s>=cross.first-Standards.Clearance.yardMargin and s<cross.last+Standards.Clearance.yardMargin then inStation=true end
        end
        if not inStation and not inStructure then chosen=s;break end
    end
    check(chosen>0,"no interval signal fixture")
    local a,b=chosen,chosen+50
    local owner,n=build(a,b)
    check(count(owner)==n,"BuildChunk vertex count differs from native geometry")
    check(n<24000,"50m infrastructure vertex budget >24k")
    local before=#owner:GetChildren(true)
    check(Infrastructure.BuildChunk(owner,a,b)==0 and #owner:GetChildren(true)==before,"duplicate BuildChunk emits geometry")
    local second,n2=build(b,b+50)
    check(count(second)==n2,"adjacent native count mismatch")
    local data=Infrastructure.GetValidationData()
    local ids={}
    for _,o in ipairs(data.objects) do
        if o.kind~="groundCorridor" then
            local id=o.kind..string.format("_%.5f_%.3f",o.s,o.lateral)
            check(not ids[id],"half-open duplicate "..id);ids[id]=true
        end
    end
    check(#data.signals==2,"expected exactly2 interval signals")
    for _,signal in ipairs(data.signals) do
        check((signal.lateral-RailNetwork.GetLateral(signal.s,signal.lane))*signal.dir<0,"signal is not on direction-relative left")
        check(signal.aspect=="red","unknown authority must start red")
        for _,support in ipairs(data.supports) do check(math.abs(support.s-signal.s)>=4,"mast overlaps signal") end
    end
    local calls={}
    local provider={GetBlockSignalAspect=function(s,lane,dir)
        calls[#calls+1]={s=s,lane=lane,dir=dir}
        return lane==0 and "green" or "yellow"
    end}
    Infrastructure.Update(.11,{s=chosen-30,lane=0,reversing=false},provider)
    check(#calls==2,"provider not queried per individual signal")
    local status=Infrastructure.GetStats()
    check(status.greenSignals==1 and status.yellowSignals==1,"all signals incorrectly inherit player aspect")
    Infrastructure.Update(.11,{s=chosen+30,lane=1,reversing=true},{GetBlockSignalAspect=function() return "unknown" end})
    check(Infrastructure.GetStats().redSignals==2,"unknown result not fail-safe red")
    Infrastructure.Update(.11,nil,provider)
    Infrastructure.Update(0,nil,nil)
    check(Infrastructure.GetStats().redSignals==2,"provider disappearance retained stale green")
    Infrastructure.Update(.11,{GetS=function() return chosen end,IsReversing=function() return true end},provider)
    check(Infrastructure.GetStats().lastDirection==-1,"Train module interface unsupported")
    clear(a,b,owner);clear(b,b+50,second)
    check(Infrastructure.GetStats().loadedChunks==0 and Infrastructure.GetStats().signals==0,"Forget retains lamp references")

    -- 每座桥/每条隧道实际分块；检查加载对象，不仅检查配置常量。
    for _,def in ipairs(Landmarks.GetDefinitions()) do
        if def.kind=="bridge" or def.kind=="tunnel" then
            local first=math.floor(def.s/50)*50
            local root,vertices=build(first,first+50)
            local snapshot=Infrastructure.GetValidationData()
            local masts,ceiling=0,0
            for _,object in ipairs(snapshot.objects) do
                check(object.kind~="groundCorridor" and object.kind~="equipmentCabinet" and object.kind~="anchor" and object.kind~="fencePost","ground object inside bridge/tunnel")
                if object.kind=="bridgeMast" then
                    masts=masts+1;check(near(object.extra.foundationBottom,-.18),"actual footing not on deck")
                elseif object.kind=="ceilingSuspension" then ceiling=ceiling+1 end
                if def.kind=="tunnel" then check(object.kind~="mast" and object.kind~="bridgeMast","floor mast inside tunnel") end
            end
            if def.kind=="bridge" then check(masts==2,"bridge lacks two dedicated deck masts") else check(ceiling==2,"tunnel not roof-suspended") end
            check(vertices==count(root),"bridge/tunnel actual count mismatch")
            clear(first,first+50,root)
        end
    end
    -- 进入/离开桥隧的非格点真实边界，路基附件不能越界。
    for _,def in ipairs(Landmarks.GetDefinitions()) do
        if def.kind=="bridge" or def.kind=="tunnel" then
            for _,edge in ipairs({def.first,def.last}) do
                local first=math.floor(edge/50)*50
                local root=build(first,first+50)
                for _,object in ipairs(Infrastructure.GetValidationData().objects) do
                    if object.kind=="groundCorridor" then
                        check(object.extra.last<=def.first+.0001 or object.s>=def.last-.0001,"corridor crosses exact structure boundary")
                    end
                end
                clear(first,first+50,root)
            end
        end
    end
    -- 连续渡线的独立导线和门架，不在岔心塞普通地柱/箱/信号。
    for _,cross in ipairs(RailNetwork.GetCrossovers()) do
        local first=math.floor(((cross.first+cross.last)/2)/50)*50
        local root=build(first,first+50)
        local portalCount=0
        for _,object in ipairs(Infrastructure.GetValidationData().objects) do
            check(object.kind~="groundCorridor" and object.kind~="equipmentCabinet" and object.kind~="blockSignal","ground fixture inside crossover")
            if object.kind=="mast" then
                portalCount=portalCount+1
                check(object.mode=="station" and (object.lateral==-14.4 or object.lateral==27),"crossover uses trackside obstruction")
            end
        end
        check(portalCount==2,"crossover lacks outboard portal")
        check(Infrastructure.GetStats().wireLength>=(cross.lane==3 and 3 or 4)*50-.001,"crossover electrification missing")
        clear(first,first+50,root)
    end
    -- 桥柱实网格底边，不只信元数据：原生顶点的foundation bottom必须真实贴-.18。
    for _,def in ipairs(Landmarks.GetDefinitions()) do
        if def.kind=="bridge" then
            local first=math.floor(def.s/50)*50
            local owner=build(first,first+50)
            local infrastructure=assert(owner:GetChild("中国铁路设施"))
            local foundations=assert(infrastructure:GetChild("混凝土基础沟槽")):GetComponent("CustomGeometry")
            local minimum=math.huge
            for i=0,foundations:GetNumVertices(0)-1 do minimum=math.min(minimum,foundations:GetVertex(0,i).position.y) end
            check(near(minimum,-.18),"native foundation mesh is not physically on bridge deck")
            clear(first,first+50,owner)
        end
    end
    -- 千米桩附近的柱/柜不能占同一实物位置。
    local markerOwner=build(2000,2050)
    local markerData=Infrastructure.GetValidationData()
    for _,object in ipairs(markerData.objects) do
        if object.kind=="kilometre" then
            for _,other in ipairs(markerData.objects) do
                if other.kind=="mast" or other.kind=="equipmentCabinet" then
                    check(math.abs(other.s-object.s)>2,"kilometre marker blocked by mast/cabinet")
                end
            end
        end
    end
    clear(2000,2050,markerOwner)
    -- 湖岸石块使用真实Route坐标，且相邻块不能各造一份整段石岸。
    for _,def in ipairs(Landmarks.GetDefinitions()) do
        if def.kind=="bridge" then
            local left,right=def.s-260,def.s+260
            local function stoneCenters(first,last)
                local owner=assert(scene_):CreateChild("湖岸坐标回归")
                Landmarks.BuildChunk(owner,first,last)
                local centers={}
                for _,node in ipairs(owner:GetChildren(true)) do
                    if node.name==def.id.."_湖岸石块" then
                        local geometry=assert(node:GetComponent("CustomGeometry"))
                        local count=geometry:GetNumVertices(0)
                        check(count%36==0,"lake rock mesh is not made of complete boxes")
                        for i=0,count-1,36 do
                            local bounds=BoundingBox()
                            for j=i,i+35 do bounds:Merge(geometry:GetVertex(0,j).position) end
                            local center=bounds.center
                            local _,s=Route.DistanceTo(center)
                            local lateral=(center-Route.Sample(s)):DotProduct(Route.RightAt(s))
                            check(s>=first-.03 and s<last+.03,"rock assigned outside its half-open route chunk")
                            check(math.abs(lateral-def.lateral)<420,"lake rock uses local lateral as world X")
                            centers[#centers+1]=center
                        end
                    end
                end
                Landmarks.ForgetChunk(first,last)
                owner:Dispose()
                return centers
            end
            local whole=stoneCenters(left,right)
            local firstHalf=stoneCenters(left,def.s)
            local secondHalf=stoneCenters(def.s,right)
            check(#whole>0,"lake rock regression generated no real mesh")
            check(#whole==#firstHalf+#secondHalf,"adjacent chunks duplicate or lose lake rocks")
            for _,set in ipairs({firstHalf,secondHalf}) do
                for _,center in ipairs(set) do
                    local actualCenter=center --[[@as Vector3]]
                    local matches=0
                    for _,expected in ipairs(whole) do
                        if (actualCenter-expected):Length()<.01 then matches=matches+1 end
                    end
                    check(matches==1,"split rock position differs from whole-bank mesh")
                end
            end
        end
    end
    -- 有yield的构建中取消：先Forget，调用方丢协程再Dispose，不会留下灯引用。
    local root=assert(scene_):CreateChild("Cancelled")
    local worker=coroutine.create(function() Infrastructure.BuildChunk(root,chosen,chosen+50,function() coroutine.yield() end) end)
    check(coroutine.resume(worker),"cancel fixture resume")
    Infrastructure.Forget(chosen,chosen+50);root:Dispose()
    check(Infrastructure.GetStats().loadedChunks==0,"half-built chunk survives Forget")
    local stats=Infrastructure.GetStats()
    local budget={checks=checks_,supportPlan=#plan.supports,markerPlan=#plan.markers,
        ground50Vertices=n,generatedVertices=stats.generatedVertices,maxSliceMs=stats.maxSliceMs,
        maxBuildMs=stats.maxBuildMs,maxUpdateMs=stats.maxUpdateMs,
        sliceTargetMs=stats.sliceTargetMs,overSliceBudget=stats.overSliceBudget,
        pointLights=stats.pointLights,vertexBudgetPer50m=24000,passed=true}
    -- 测试报告走stdout，由调用者落到screenshots；不用File沙箱写玩家savedata。
    print("CHINESE_RAIL_BUDGET "..require("cjson").encode(budget))
    print(string.format("CHINESE_RAIL_STATE_PASS checks=%d supports=%d markers=%d maxSliceMs=%.3f maxBuildMs=%.3f ground50Vertices=%d generated=%d",
        checks_,#plan.supports,#plan.markers,stats.maxSliceMs,stats.maxBuildMs,n,stats.generatedVertices))
    Infrastructure.Shutdown()
    check(Infrastructure.GetStats().loadedChunks==0,"Shutdown retained chunks")
end
function Start()
    local ok,err=xpcall(run,debug.traceback)
    if not ok then log:Write(LOG_ERROR,tostring(err)) end
    engine:Exit()
end
function Stop() Infrastructure.Shutdown() end
