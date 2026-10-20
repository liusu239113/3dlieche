-- 普通模式延伸线：原33.186577km/五站为不可变前缀，追加五座山地车站。
-- s为水平工程里程（米）；不复制狂暴地图、规则或45‰纵坡。
-- 纯数据构造，不读取GameConfig/Route/存档，方便菜单在建图前查询。
local World = require "config.FictionalWorld"
local NormalRoute = {}
NormalRoute.Id = "normal_corridor_v2"
NormalRoute.Name = "星汐—天池山海干线"
local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key,item in pairs(value) do result[key] = copy(item) end
    return result
end
local function size(segment)
    return segment.type == "arc" and segment.radius * math.rad(segment.angle) or segment.length
end
---@return table[]
local function extension()
    -- 云湾原终端变中间站后，上行绕行线延至s+1650；接续段保留600m水平缓冲。
    local segments = {{type="straight",length=600,leg=1,stage="connector"}}
    for leg = 1,5 do
        -- 对称反向曲线回到原来的前进方位，不采用山腰回头或急弯堆叠。
        local defs = {
            {type="arc",radius=2200,angle=50,dir=1,leg=leg,stage="climb_a"},
            {type="straight",length=1600,leg=leg,stage="bridge"},
            {type="arc",radius=2400,angle=50,dir=-1,leg=leg,stage="climb_b"},
            {type="straight",length=1800,leg=leg,stage="tunnel"},
            {type="straight",length=3600,leg=leg,stage="station",station=leg+5},
        }
        for _,segment in ipairs(defs) do segments[#segments+1] = segment end
    end
    return segments
end
function NormalRoute.GetLength(legacySegments)
    local length = 0.0
    for _,segment in ipairs(legacySegments) do length = length + size(segment) end
    for _,segment in ipairs(extension()) do length = length + size(segment) end
    return length
end

--- Mirror v1's exact station snapping, before the total length changes.
local function legacyAnchors(segments,stations,length)
    local result = {}
    local previous = -math.huge
    for index,station in ipairs(stations) do
        local target,best,delta = station.at*length,0.0,math.huge
        local cursor = 0.0
        for _,segment in ipairs(segments) do
            local distance = size(segment)
            if segment.type == "straight" and not segment.landmark and distance >= 1120 then
                local first,last = math.max(cursor+710,previous+350),cursor+distance-410
                if first <= last then
                    local candidate = math.max(first,math.min(last,target))
                    if math.abs(candidate-target) < delta then best,delta = candidate,math.abs(candidate-target) end
                end
            end
            cursor = cursor + distance
        end
        assert(delta < math.huge,"[NormalRoute] 原线路站场锚点无效")
        result[index],previous = best,best
    end
    return result
end

--- @param legacySegments table[] Unmodified v1 source segments.
--- @param legacyStations table[] Unmodified v1 station definitions.
--- @param legacyRelief table Unmodified v1 relief data.
function NormalRoute.Create(legacySegments,legacyStations,legacyRelief)
    assert(#legacyStations==5,"[NormalRoute] 必须注入原五站，不可把新站重复追加")
    local prefixLength = 0.0
    for _,segment in ipairs(legacySegments) do prefixLength = prefixLength + size(segment) end
    local total = NormalRoute.GetLength(legacySegments)
    local segments,stations = copy(legacySegments),{}
    local anchors = legacyAnchors(legacySegments,legacyStations,prefixLength)
    for index,station in ipairs(legacyStations) do
        local identity = assert(World.stations[index])
        stations[index] = {id=identity.id,name=station.name,s=anchors[index],at=anchors[index]/total}
    end
    local relief = copy(legacyRelief)
    relief.Version = "normal_mountain_relief_v3"
    relief.Structures,relief.Slopes,relief.Peaks = relief.Structures or {},relief.Slopes or {},relief.Peaks or {}
    local profile = {{type="grade",length=prefixLength,grade=0}}
    local regions = {}
    local levels = {50,110,165,210,150} --[[@as table<number, number> ]]
    local cursor,y,maxGrade = prefixLength,0.0,0.0
    local function rise(distance,target)
        local delta = target-y
        if math.abs(delta)<1e-9 then
            profile[#profile+1] = {type="grade",length=distance,grade=0}
        else
            local transition = math.min(700,distance*.25)
            local grade = delta/(distance-transition)
            assert(math.abs(grade)<=.022,"[NormalRoute] 普通山区纵坡超过22‰")
            maxGrade = math.max(maxGrade,math.abs(grade))
            profile[#profile+1] = {type="verticalCurve",length=transition,endGrade=grade}
            profile[#profile+1] = {type="grade",length=distance-2*transition,grade=grade}
            profile[#profile+1] = {type="verticalCurve",length=transition,endGrade=0}
        end
        y = target
    end
    for _,source in ipairs(extension()) do
        local def,distance = copy(source),size(source)
        local leg = source.leg
        local previous = leg==1 and 0 or levels[leg-1]
        if source.stage=="climb_a" then
            regions[leg] = {first=leg==1 and prefixLength or cursor,last=0,name=({"翠川山麓与溪谷","石门岩岭与高桥","云脊林海与长隧","松岚高地与河谷","天池湖盆与山城"})[leg],
                theme=leg==5 and "water" or (leg==1 and "village" or "forest"),stationIndex=leg+5}
            rise(distance,(previous+levels[leg])*.5)
        elseif source.stage=="climb_b" then rise(distance,levels[leg])
        else rise(distance,y) end
        segments[#segments+1] = def
        if source.stage=="bridge" then
            relief.Structures[#relief.Structures+1] = {id="normal_high_bridge_"..leg,kind="bridge",
                name=assert(World.stations[leg+5]).shortName.."高谷铁路桥",first=cursor+200,last=cursor+1400,
                halfWidth=520,depth=60+leg*8,waterY=-25-leg*3}
        elseif source.stage=="tunnel" then
            relief.Structures[#relief.Structures+1] = {id="normal_ridge_tunnel_"..leg,kind="tunnel",
                name=assert(World.stations[leg+5]).shortName.."穿岭隧道",first=cursor+200,last=cursor+1600,
                halfWidth=300,height=150+leg*14}
        elseif source.stage=="station" then
            local identity = assert(World.stations[source.station])
            local s = cursor+1650
            stations[source.station] = {id=identity.id,name=identity.name,s=s,at=s/total}
            regions[leg].last = cursor+distance
        end
        cursor = cursor+distance
    end
    assert(math.abs(cursor-total)<1e-7 and total>=85000 and total<=95000,"[NormalRoute] 延伸线长度无效")
    return {id=NormalRoute.Id,name=NormalRoute.Name,length=total,segments=segments,stations=stations,
        start={x=0,y=0,z=0},startYaw=0,transitionLength=120,
        profile={startY=0,startGrade=0,segments=profile},maxGrade=maxGrade,
        mountain={Version="normal_mountain_v1",First=prefixLength,GridStep=20,DrawDistance=2400,MaxGrade=maxGrade},
        regions=regions,stationLayout={PlatformStart=-225,PlatformEnd=85,ApproachClearance=700,DepartureClearance=400},
        relief=relief,legacyLength=prefixLength}
end
return NormalRoute
