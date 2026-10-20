-- CPU-only geometry/data regression. No scene, file storage, cloud, build or GPU calls.
local Config=require "config.GameConfig"
local Modes=require "config.GameModes"
local Route=require "world.Route"
local Alignment=require "world.RailwayAlignment"
local Rail=require "world.RailNetwork"
local Relief=require "config.ReliefConfig"
local Mountain=require "world.MountainProfile"
local Landmarks=require "world.Landmarks"
local Normal=require "config.NormalRoute"
local World=require "config.FictionalWorld"
local Validation={}
local function near(a,b,message)
    assert(math.abs(a-b)<.00001,message..": "..tostring(a).." / "..tostring(b))
end
function Validation.Run()
    local mode=Modes.Apply("normal")
    Route.Build()
    local first=Config.MountainTerrain.First
    near(first,33186.57734856853,"旧前缀长度改变")
    assert(mode.routeId==Normal.Id and Route.GetLength()>=85000 and Route.GetLength()<=95000,"普通地图版本/长度错误")
    local stations=Route.GetStations()
    assert(#stations==10,"普通新线不是10站")
    local anchors={829.6644337142133,7016.646862858715,16719.842272904632,23162.909963010643,31859.114254625787}
    local prefix={}
    for i=1,21 do prefix[i]=Config.RouteSegments[i] end
    local old=Alignment.FromLegacySegments(prefix,{start=Vector3.ZERO,startYaw=0,pointStep=10,transitionLength=120})
    for s=0,first,47 do
        local original=old:Sample(s)
        local current=Route.Sample(s)
        assert((original-current):Length()<.00001,"旧平面线路坐标变化")
        near(current.y,0,"旧前缀高程变化")
        near(Route.GradeAt(s),0,"旧前缀出现坡度")
    end
    local maxGrade,high,low=0.0,-math.huge,math.huge
    for s=0,Route.GetLength(),20 do
        maxGrade=math.max(maxGrade,math.abs(Route.GradeAt(s)))
        high,low=math.max(high,Route.HeightAt(s)),math.min(low,Route.HeightAt(s))
    end
    assert(maxGrade>.01 and maxGrade<=.022 and high>=200 and low==0,"普通山地高差/坡度错误")
    for index,station in ipairs(stations) do
        assert(station.id==World.stations[index].id and station.name==World.stations[index].name,"站点身份改变")
        if index<=5 then near(station.s,anchors[index],"旧站点里程变化") end
        local yard=assert(Rail.GetStationRouting(index))
        local lo,hi=math.max(0,math.min(yard.first,station.s-1100)),math.min(Route.GetLength(),yard.up.last)
        for s=lo,hi,20 do near(Route.GradeAt(s),0,"站坪/咽喉/上行绕线不水平") end
    end
    Landmarks.Init()
    local bridges,tunnels=0,0
    for _,definition in ipairs(Landmarks.GetDefinitions()) do
        if definition.first>=first and (definition.kind=="bridge" or definition.kind=="tunnel") then
            if definition.kind=="bridge" then
                bridges=bridges+1
                assert(definition.depth>=68,"新高桥没有真实谷底")
                near(Route.GradeAt(definition.s),0,"高桥不水平")
                assert(Mountain.RelativeAt(definition.s,2.5)<-60,"桥谷地表未下切")
            else
                tunnels=tunnels+1
                assert(definition.last-definition.first>=1400-.001 and definition.innerHalfWidth>=9.5,"新隧道净空/长度错误")
            end
            for _,station in ipairs(stations) do
                assert(definition.last<=station.s-1000 or definition.first>=station.s+1000,"桥隧侵入站区")
            end
        end
    end
    assert(bridges==5 and tunnels==5,"新增高桥/穿岭隧道数量错误")
    assert(not Mountain.IsActiveAt(first-1) and Mountain.IsActiveAt(first+1),"旧新地貌开关错误")
    local normalSegments,normalProfile=Config.RouteSegments,Config.RouteProfile
    local normalNames={}
    for i,station in ipairs(stations) do normalNames[i]=station.name end
    Modes.Apply("rage");Route.Build()
    assert(#Route.GetStations()==5 and Route.GetLength()>100000,"普通扩站污染狂暴独立五站")
    Modes.Apply("normal");Route.Build()
    assert(Config.RouteSegments==normalSegments and Config.RouteProfile==normalProfile,"切回普通地图未恢复缓存")
    for i,station in ipairs(Route.GetStations()) do assert(station.name==normalNames[i],"切回普通后站名变化") end
    assert(#Relief.Structures==17,"旧7工程+新10工程未完整保留")
    print(string.format("[NormalRouteValidation] PASS %.6fkm / 10站 / 5新增高桥+5新增真隧 / 最大坡度%.3f‰ / 旧33km坐标不变",Route.GetLength()/1000,maxGrade*1000))
    return true
end
return Validation
