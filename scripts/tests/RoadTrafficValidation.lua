-- CPU真实UrhoX Node回归；不require main/SaveStore，不访问玩家存档/云，不创建视口。
-- .cli/UrhoXRuntime tests/RoadTrafficValidation.lua -tapcode_dir=/workspace -tool_mode
local Modes=require "config.GameModes"
local Route=require "world.Route"
local Road=require "world.RoadCorridor"
local Vehicles=require "world.RoadVehicles"
local Validation={}
---@type Scene?
local scene_=nil
local checks_=0
local function check(value,message) checks_=checks_+1;assert(value,"[RoadTraffic] "..message) end
local function near(a,b,tolerance,message) check(math.abs(a-b)<=tolerance,message.." "..a.." / "..b) end
local function snapshot()
    local rows={}
    for _,r in ipairs(Road.GetTrafficPlan()) do rows[#rows+1]=r.id..":"..r.startS..":"..r.kind end
    return table.concat(rows,"|")
end
function Validation.Run()
    checks_=0
    Modes.Apply("normal");Route.Build();Road.Init()
    local plan=Road.GetTrafficPlan()
    local total=Route.GetLength()
    local buses,kinds,ids,previous=0,{},{},{}
    local minGap,maxGap=math.huge,0
    for _,r in ipairs(plan) do
        check(not ids[r.id],"重复车辆ID");ids[r.id]=true
        kinds[r.kind]=(kinds[r.kind] or 0)+1
        check(r.s>0 and r.s<total,"越过开放道路端点")
        check(r.direction==1 or r.direction==-1,"未知行驶方向")
        check(r.speed>5,"生产计划仍是静态车")
        local prev=previous[r.direction]
        if prev then
            local gap=r.distance-prev
            minGap=math.min(minGap,gap);maxGap=math.max(maxGap,gap)
            check(gap>=130 and gap<=180,"真实道路弧长密度失控")
        end
        previous[r.direction]=r.distance
        if r.kind=="bus" then buses=buses+1 end
    end
    check(#plan>500 and #plan<total/45,"双向计划数量异常")
    check(buses/#plan<=.05 and buses>0,"公交比例异常")
    for _,kind in ipairs({"sedan_dark","sedan_white","suv","bus"}) do check((kinds[kind] or 0)>0,"缺少真实车型 "..kind) end
    check(#Road.GetMovingVehiclePlan()==0,"旧4辆演示计划未退役")
    local original=snapshot()
    Road.ResetTraffic();check(snapshot()==original,"重开改变初始车流")
    Road.Shutdown();Road.Init();check(snapshot()==original,"重复Init改变全线计划")
    print(string.format("ROAD_TRAFFIC_PLAN_PASS checks=%d vehicles=%d busRatio=%.4f spacing=%.0f..%.0fm",checks_,#plan,buses/#plan,minGap,maxGap))
    return true
end
---@param scene Scene
function Validation.ValidateAssets(scene)
    check(#Vehicles.GetResourcePaths()==12,"资源清单未保留四款MDL/D/N")
    check(Vehicles.GetAsset()==Vehicles.GetAsset("bus"),"无参公交兼容丢失")
    local samples={4216.65,Route.GetLength()*.48,Route.GetLength()*.80}
    -- 加入真实桥谷/纵坡与绕山段，不只验水平直线。
    local steepest=0
    for _,point in ipairs(Road.GetProfile()) do
        local grade=math.abs(Route.GradeAt(point.s))
        if grade>steepest then steepest=grade;samples[4]=point.s end
    end
    for _,def in ipairs(Vehicles.GetDefinitions()) do
        local asset=assert(Vehicles.GetAsset(def.kind))
        check(cache:Exists(def.mesh) and cache:Exists(def.diffuse) and cache:Exists(def.normal),"缺少本地资源")
        near((asset.bounds.min-def.sourceMin):Length(),0,.00001,"MDL最小bbox变化")
        near((asset.bounds.max-def.sourceMax):Length(),0,.00001,"MDL最大bbox变化")
        near(asset.scale.x*asset.bounds.size.x,def.length,.0001,"车长错误")
        near(asset.scale.y*asset.bounds.size.y,def.height,.0001,"车高错误")
        near(asset.scale.z*asset.bounds.size.z,def.width,.0001,"车宽错误")
        for _,s in ipairs(samples) do
            for _,direction in ipairs({-1,1}) do
                local node=scene:CreateChild("姿态验收_"..def.kind)
                local model=node:CreateComponent("StaticModel")
                Vehicles.ApplyAsset(model,asset)
                for slot=0,asset.model.numGeometries-1 do check(model:GetMaterial(slot)==asset.material,"材质slot未覆盖") end
                local surface,forward=Road.SampleVehicle(s,direction,def.kind)
                check(Vehicles.Pose(node,surface,forward,def.kind),"姿态失败")
                local bottom=node:LocalToWorld(Vector3(asset.bounds.center.x,asset.bounds.min.y,asset.bounds.center.z))
                near((bottom-surface):Length(),0,.04,"胎底未贴实际道路")
                check((node.rotation*def.front):DotProduct(forward)>.9999,"车头逆行/横行")
                local center,right=Road.Sample(s)
                near((surface-center):DotProduct(right),direction*1.75,.04,"右行车道偏移错误")
                check(math.abs((surface-center):DotProduct(right))+def.width*.5<3.5,"侵入对向/路肩")
                node:Dispose()
            end
        end
        print("ROAD_TRAFFIC_ASSET_PASS "..def.kind.." front=+X geometries="..asset.model.numGeometries)
    end
end
---@class RoadTrafficTestSnapshot
---@field id string
---@field kind string
---@field s number
---@field direction number
---@field speed number
---@field node Node
---@field position Vector3
---@field forward Vector3?
---@return table<string,RoadTrafficTestSnapshot>
local function byId()
    local out={} ---@type table<string,RoadTrafficTestSnapshot>
    for _,r in ipairs(Road.GetTrafficVehicles()) do out[r.id]=r end
    return out
end
---@param root Node
---@param first number
---@param count integer
local function build(root,first,count)
    for index=0,count-1 do Road.BuildChunk(root,first+index*240,first+(index+1)*240) end
end
local function checkSafety()
    local previous={}
    for _,r in ipairs(Road.GetTrafficPlan()) do
        -- 全线plan按初始s排；仅检查可见Node的真实路面/车头，跟车按当前距离另排序。
        if r.lease then
            local def=assert(Vehicles.GetDefinition(r.kind))
            check((r.lease.node.rotation*def.front):DotProduct(assert(r.forward))>.999,"移动车头不随运动方向")
            local center,right=Road.Sample(r.s)
            check((assert(r.surface)-center):DotProduct(right)*r.direction>1.6,"移动越过对向黄线")
        end
        local lane=previous[r.direction] or {}
        previous[r.direction]=lane;lane[#lane+1]=r
    end
    for _,lane in pairs(previous) do
        table.sort(lane,function(a,b) return a.distance<b.distance end)
        for i=2,#lane do
            local a,b=lane[i-1],lane[i]
            local da,db=assert(Vehicles.GetDefinition(a.kind)),assert(Vehicles.GetDefinition(b.kind))
            check(b.distance-a.distance>(da.length+db.length)*.5+8.5,"同向车辆穿透/重叠")
        end
    end
end
---@param scene Scene
function Validation.ValidateMotion(scene)
    Road.Shutdown();Road.Init(scene)
    local root=scene:CreateChild("生产道路CPU运动验收")
    build(root,3600,7)
    Road.Update(0,4200)
    local before=byId()
    local stats=Road.GetTrafficStats()
    check(stats.active>=12 and stats.positive>0 and stats.negative>0,"同一区域没有真实双向车辆")
    check(stats.staticVehicles==0 and stats.mode=="dynamic","生产仍用静态车冒充")
    for i=1,100 do Road.Update(.05,4200) end
    local after=byId()
    local counts={[1]=0,[-1]=0}
    local crossChunk=0
    for id,a in pairs(before) do
        local b=after[id]
        if b then
            check(a.node==b.node,"正常行驶更换Node身份")
            local displacement=b.node.worldPosition-a.position --[[@as Vector3]]
            check(displacement:Length()>20,"CPU实际Node未发生可见时间位移")
            check(displacement:DotProduct(assert(a.forward))>20,"Node运动与车身朝向相反")
            check((b.s-a.s)*a.direction>0,"两方向未各自前行")
            check(displacement:Length()<76,"时间积分瞬移")
            if math.floor(a.s/240)~=math.floor(b.s/240) then crossChunk=crossChunk+1 end
            counts[a.direction]=counts[a.direction]+1
        end
    end
    check(counts[1]>=4 and counts[-1]>=4,"双向实际Node位移样本不足")
    check(crossChunk>0,"没有覆盖跨chunk同Node连续行驶")
    checkSafety()
    local paused=byId();local pausedTime=Road.GetTrafficStats().time
    for i=1,20 do Road.Update(0,4200) end
    for id,a in pairs(paused) do
        local b=byId()[id]
        check(b~=nil and b.node==a.node,"暂停重建/丢车")
        near((b.position-a.position):Length(),0,.0001,"暂停Node仍移动")
    end
    near(Road.GetTrafficStats().time,pausedTime,.000001,"暂停仍积时")
    for _,bad in ipairs({-1,math.huge,0/0}) do Road.Update(bad,4200) end
    near(Road.GetTrafficStats().time,pausedTime,.000001,"非法dt推进车流")
    -- 当前道路退出区域时立即归还Node，不等下一帧，不持已Dispose的chunk引用。
    for index=0,6 do Road.ForgetChunk(3600+index*240,3840+index*240) end
    check(Road.GetTrafficStats().active==0,"卸载未即时清理动态Node")
    local created=Road.GetTrafficStats().poolCreated
    root:Dispose()
    root=scene:CreateChild("重载生产道路")
    build(root,3600,7);Road.Update(0,4200)
    check(Road.GetTrafficStats().active>0,"道路重载未激活动态交通")
    check(Road.GetTrafficStats().poolCreated==created,"区域重载没有复用对象池")
    local old=byId()
    Road.ResetTraffic()
    check(Road.GetTrafficStats().active==0 and Road.GetTrafficStats().time==0,"重开未清车辆/时钟")
    Road.Update(0,4200)
    check(Road.GetTrafficStats().poolSize<=64,"对象池超硬预算")
    for _,r in ipairs(Road.GetTrafficVehicles()) do
        local a=old[r.id]
        if a then check(r.s~=a.s,"重开未复位初始车流") end
    end
    -- 半成品协程道路不得在路面Finish以前激活车辆。
    Road.Shutdown();root:Dispose();Road.Init(scene)
    root=scene:CreateChild("协程取消验收")
    local work=coroutine.create(function() Road.BuildChunk(root,4080,4320,function() coroutine.yield() end) end)
    check(coroutine.resume(work),"道路协程首片失败")
    Road.Update(.1,4200);check(Road.GetTrafficStats().active==0,"半成品道路提前激活车辆")
    Road.ForgetChunk(4080,4320);work=nil
    Road.Shutdown();root:Dispose()
    check(#Road.GetTrafficVehicles()==0 and Road.GetTrafficStats().poolSize==0,"Shutdown泄漏旧Node/池")
    Road.Update(.1,4200);check(Road.GetTrafficStats().active==0,"关闭后Update复活车流")
    print(string.format("ROAD_TRAFFIC_REAL_NODE_PASS positive=%d negative=%d crossChunk=%d paused=true pooled=true unload=true restart=true partialCancel=true GLES=NOT_EXECUTED",counts[1],counts[-1],crossChunk))
end
---@param scene Scene
function Validation.ValidateBoundary(scene)
    Road.Init(scene)
    local root=scene:CreateChild("开放端点验收")
    build(root,0,4);Road.Update(0,350)
    local started=byId()
    for i=1,180 do Road.Update(.5,350) end
    for _,r in ipairs(Road.GetTrafficVehicles()) do
        check(r.s>0 and r.s<960,"端点/未加载边界逃逸")
        local a=started[r.id]
        if a then check((r.s-a.s)*r.direction>=0,"端点可见回收瞬移/掉头") end
    end
    check(Road.GetTrafficStats().recycles==0,"开放端点可见时重生到远端")
    checkSafety()
    Road.Shutdown();root:Dispose()
    -- 实际桥谷、隧道绕山和弯道各取生产车辆，推进同一Node，而非静态摆拍。
    for _,centerS in ipairs({3740,9600,19000}) do
        Road.Init(scene)
        root=scene:CreateChild("桥谷弯道实际Node_"..centerS)
        local first=math.floor((centerS-480)/240)*240
        build(root,first,5);Road.Update(0,centerS)
        local origin=byId()
        for i=1,40 do Road.Update(.05,centerS) end
        local directions={[1]=0,[-1]=0}
        for _,r in ipairs(Road.GetTrafficVehicles()) do
            local a=origin[r.id]
            if a and (r.position-a.position):Length()>2 then directions[r.direction]=directions[r.direction]+1 end
            local surface,forward=Road.SampleVehicle(r.s,r.direction,r.kind)
            local actual=r.node.worldPosition --[[@as Vector3]]
            near((actual-r.position):Length(),0,.001,"快照不是实际Node位置")
            local asset=assert(Vehicles.GetAsset(r.kind))
            local contact=r.node:LocalToWorld(Vector3(asset.bounds.center.x,asset.bounds.min.y,asset.bounds.center.z))
            near((contact-surface):Length(),0,.06,"桥谷/弯道胎底脱离实际路面")
            check((r.node.rotation*asset.definition.front):DotProduct(forward)>.999,"弯道车头/运动不一致")
        end
        check(directions[1]>=2 and directions[-1]>=2,"桥谷/弯道缺乏双向真实位移")
        checkSafety()
        Road.Shutdown();root:Dispose()
    end
    -- 另一模式仍使用相同道路/净空，不更改铁路、速度或世界流式配置。
    Modes.Apply("rage");Route.Build();Road.Init(scene)
    root=scene:CreateChild("山地坡道验收")
    build(root,4080,3);Road.Update(0,4400)
    local before=byId()
    for i=1,20 do Road.Update(.05,4400) end
    local moved=0
    for _,r in ipairs(Road.GetTrafficVehicles()) do
        local a=before[r.id]
        if a and (r.position-a.position):Length()>3 then moved=moved+1 end
    end
    check(moved>=2,"山地模式双向车辆未实际移动")
    Validation.ValidateAssets(scene)
    Road.Shutdown();root:Dispose();Modes.Apply("normal")
    print("ROAD_TRAFFIC_BOUNDARY_PASS openEnds=true noVisibleRecycle=true following=true mountain=true")
end
local function cleanup()
    Road.Shutdown()
    if scene_ then scene_:Dispose();scene_=nil end
end
function Start()
    local ok,err=xpcall(function()
        Validation.Run()
        scene_=Scene();scene_:CreateComponent("Octree")
        Validation.ValidateAssets(scene_)
        Validation.ValidateMotion(scene_)
        Validation.ValidateBoundary(scene_)
        print("ALL_ROAD_TRAFFIC_CPU_PASS checks="..checks_.." realEngineNode=true graphics=NOT_EXECUTED noSaveIO=true noCloudIO=true")
    end,debug.traceback)
    if not ok then log:Write(LOG_ERROR,"ROAD_TRAFFIC_FAIL "..tostring(err)) end
    cleanup();engine:Exit()
end
function Stop() cleanup() end
return Validation
