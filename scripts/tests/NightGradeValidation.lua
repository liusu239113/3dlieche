-- 独立山地灯光/道路回归；不加载main、不读写玩家存档或云，不占用旧NightLightingValidation。
local Modes=require "config.GameModes"
local Route=require "world.Route"
local Road=require "world.RoadCorridor"
local Station=require "world.Station"
local Night=require "world.NightLighting"
local Environment=require "world.Environment"
local VisualQuality=require "config.VisualQuality"
local Config=require "config.CorridorConfig"
---@type Scene?
local scene_=nil
local checks_=0
local function check(v,message) checks_=checks_+1;assert(v,"[NightGrade] "..message) end
local function near(a,b,message,epsilon) check(math.abs(a-b)<(epsilon or .02),message.." actual="..a.." expected="..b) end
local function runMode(mode)
    Modes.Apply(mode);Route.Build();Road.Init(nil)
    local profile=Road.GetProfile()
    local last=profile[1]
    local slopes=0
    for _,p in ipairs(profile) do
        local base=Route.Sample(p.s).y
        check(p.foundation<base and p.foundation>base-250,"道路墩基丢失世界高程 s="..p.s.." foundation="..p.foundation.." base="..base)
        check(p.pos.y>=base+Config.Road.SurfaceY,"道路顶面低于设计路基")
        near(p.ground,base+.004,"道路地面高程重复相加")
        if p~=last then
            local d=p.pos-last.pos
            local grade=math.abs(d.y)/math.sqrt(d.x*d.x+d.z*d.z)
            check(grade<=Config.Road.MaxGrade+.00001,"道路超纵坡")
            if grade>.01 then slopes=slopes+1 end
        end
        last=p
    end
    check(slopes>100,"山地道路未真正跟坡")
    if #Road.GetConnections()>0 then near(Road.GetStats().minOverpassClearance,9,"上跨净空没有扣除山地基高") end
    scene_=Scene();scene_:CreateComponent("Octree")
    local root=scene_:CreateChild("StationGrade")
    Station.Init()
    local stationIndex=mode=="rage" and 4 or 1
    ---@type RailwayStation?
    local st=nil
    for index,station in ipairs(Route.GetStations()) do
        if index==stationIndex then st=station;break end
    end
    assert(st,"验收车站不存在")
    Station.BuildOne(root,st)
    local base=Route.Sample(st.s).y
    local placement=Station.GetPlacementData()[1]
    check(placement~=nil,"缺少真实站房")
    near(placement.y,base,"站房高度丢失/重复")
    near(placement.platformWorldY,base+1.44,"站台worldY诊断不匹配")
    Road.BuildChunk(root,st.s-240,st.s+240)
    local sites=Night.GetSites()
    check(#sites>40,"生产站台/道路未注册灯位")
    for _,site in ipairs(sites) do
        if site.kind=="station" then check(site.position.y>base+4 and site.position.y<base+9,"站台灯未跟站场高程") end
    end
    local camera=Route.SampleOffset(st.s-70,-5,4)
    Night.SetEnvironment(1,"low");Night.Update(camera)
    check(Night.GetStats().poolLights==18,"低档固定池预算错误")
    Night.SetEnvironment(1,"performance");Night.Update(camera)
    check(Night.GetStats().quality==VisualQuality.Normalize("performance"),"真实performance别名没有规范化")
    check(Night.GetStats().poolLights==26,"performance未按真实medium预算")
    for _,light in ipairs(Night.GetLights()) do
        if light.enabled then
            check(light.lightType==LIGHT_POINT,"宽照明仍依赖聚光投影")
            check(light.punctualLight and not light.castShadows,"移动端灯光依赖面积/阴影")
            check(light.viewMask==2 and light.lightMask==2,"灯光mask意外改变")
        end
    end
    root.enabled=false
    for _=1,16 do Night.Update(camera) end
    check(Night.GetStats().activeStation==0 and Night.GetStats().activeRoad==0,"隐藏的流式半成品仍投光")
    root.enabled=true
    for _=1,16 do Night.Update(camera) end
    check(Night.GetStats().activeStation>0,"暂停静止相机没有恢复可见站灯")
    Night.SetEnvironment(0);Night.Update(camera)
    check(Night.GetStats().activeStation==0 and Night.GetStats().activeRoad==0,"昼间池未关闭")
    -- 远机位（鸟瞰/远景）必须按观察焦点选灯，而不是按相机自身位置。
    Night.SetEnvironment(1,"performance")
    local farCamera=Vector3(camera.x+1200,camera.y+420,camera.z+900)
    Night.Update(farCamera,camera)
    check(Night.GetStats().activeStation>0,"远机位观察焦点旁站灯被相机距离裁掉")
    for _,light in ipairs(Night.GetLights()) do
        if light.enabled then
            -- 引擎裁剪距离必须覆盖真实相机到该灯的跨度，否则可见站台仍无投光。
            check(light.drawDistance>(light.node.worldPosition-farCamera).length,
                "远机位下灯被引擎drawDistance裁剪")
        end
    end
    local budget=Night.GetStats().poolLights
    check(budget<=26,"远机位扩灯超出固定预算")
    Night.Update(camera)
    check(Night.GetStats().activeStation>0,"旧接口（无焦点）邻域行为改变")
    Station.Shutdown();Road.Shutdown();Night.Shutdown();scene_:Dispose();scene_=nil
    print(string.format("[NightGrade] mode=%s profile=%d slopes=%d stationBase=%.2f",mode,#profile,slopes,base))
end
function Start()
    local ok,message=xpcall(function()
        runMode("rage");runMode("normal")
        Environment.Init(nil,nil,{visuals=false,hour=23.98,running=true})
        local before=Environment.GetClock().minutes
        Environment.SetPaused(true);Environment.Advance(100)
        near(Environment.GetClock().minutes,before,"暂停推进了夜间时钟",.000001)
        Environment.SetTime(1);Environment.Update(0,Vector3.ZERO)
        check(Environment.GetStatus().lampFactor>.99,"暂停手动调夜间未同步lamp状态")
        Environment.SetPaused(false);Environment.Advance(2)
        check(Environment.GetClock().minutes>60,"恢复后时钟没有继续")
        Environment.Destroy()
        print(string.format("ALL_NIGHT_GRADE_PASS checks=%d realMeshes=true ordinaryPoint=true performanceAlias=true mountainGrades=true saveIO=0 cloudIO=0",checks_))
    end,debug.traceback)
    if not ok then log:Write(LOG_ERROR,tostring(message)) end
    if scene_ then Station.Shutdown();Road.Shutdown();Night.Shutdown();scene_:Dispose() end
    Modes.Apply("normal")
    engine:Exit()
end
