-- 凌岳天路：独立合成山地展线，不复刻京张或青藏的真实地理。
-- s是水平工程里程；平面缓和曲线+抛物线竖曲线；所有站场/桥梁直线为零坡。
-- 线路以大回头和多组反向S弯绕山爬升，绝不通过缩放普通线路或堆旁山伪造纵坡。
local RageRoute = {}
RageRoute.Id = "rage_mountain_corridor_v2"
RageRoute.Name = "凌岳天路"
RageRoute.Seed = 20261019

local function copy(value)
    if type(value)~="table" then return value end
    local out={}
    for key,item in pairs(value) do out[key]=copy(item) end
    return out
end

-- 山腰大回头：每组从-50°经+120°/−40°/+95°回到−50°；
-- 170°山腰展线、160°反向回头以及135°/145°S弯之间留独立桥谷/山口。
-- 每组末尾5000m完整站场，不在曲线/竖曲线内放站台、咽喉或终端渡线。
local RADII={{1600,1800,1500,2100},{1750,1550,1650,2250},{1550,2000,1450,2000},{1850,1750,1700,2300}}
local HEIGHTS={{140,140,285,235,205,260,260,260},
    {420,420,550,545,510,580,580,580},
    {725,725,900,970,925,925,990,990},
    {1120,1120,1010,970,910,840,840,840}}
local LEG_NAMES={"赤壁回头展线","双峡高桥与石门岭","云脊长坡与雪线山口","高原湖盆与天路落坡"}

local function design()
    local segments={{type="straight",length=5000,station=1,endY=0}}
    for leg,r in ipairs(RADII) do
        local h=HEIGHTS[leg]
        local defs={
            {type="arc",radius=r[1],angle=170,dir=1,endY=h[1]},
            {type="straight",length=2200,endY=h[2],landmark=leg==1 and "bridge_a" or nil},
            {type="arc",radius=r[2],angle=160,dir=-1,endY=h[3]},
            {type="straight",length=3600,endY=h[4],landmark=leg==1 and "tunnel_a" or (leg==3 and "tunnel_b" or nil)},
            {type="arc",radius=r[3],angle=135,dir=1,endY=h[5]},
            {type="straight",length=2200,endY=h[6],landmark=leg==3 and "bridge_b" or nil},
            {type="arc",radius=r[4],angle=145,dir=-1,endY=h[7]},
            {type="straight",length=5000,endY=h[8],station=leg+1},
        }
        for _,def in ipairs(defs) do def.region=leg;segments[#segments+1]=def end
    end
    return segments
end

function RageRoute.GetLength()
    local length=0.0
    for _,seg in ipairs(design()) do length=length+(seg.type=="arc" and seg.radius*math.rad(seg.angle) or seg.length) end
    return length
end

--- 每段高程变化以700m以上抛物线进/出坡，不允许坡度折角。
--- 桥谷直线与全站场保持零坡；隧道沿同一纵断面穿山。
function RageRoute.Create(stationNames)
    local segments,stations,profile,regions={},{},{},{}
    local structures,slopes={},{}
    local length,y,maxGrade=0.0,0.0,0.0
    local function profileTo(distance,target)
        local delta=target-y
        if math.abs(delta)<1e-9 then profile[#profile+1]={type="grade",length=distance,grade=0}
        else
            local transition=math.min(1000,distance*.25)
            local grade=delta/(distance-transition)
            assert(math.abs(grade)<=.045,"[RageRoute] 合成山区纵坡不得超过45‰")
            maxGrade=math.max(maxGrade,math.abs(grade))
            profile[#profile+1]={type="verticalCurve",length=transition,endGrade=grade}
            profile[#profile+1]={type="grade",length=distance-2*transition,grade=grade}
            profile[#profile+1]={type="verticalCurve",length=transition,endGrade=0}
        end
        y=target
    end
    local definitions=design()
    for i,source in ipairs(definitions) do
        local def=copy(source)
        local size=def.type=="arc" and def.radius*math.rad(def.angle) or def.length
        segments[i]=def
        if def.station then
            stations[def.station]={name=assert(stationNames[def.station]),at=(length+size*.5)/RageRoute.GetLength()}
        end
        profileTo(size,def.endY)
        -- 每个山地组声明完整直线内的附加峡谷/山岭；不与既有landmark重叠。
        if i>1 then
            local leg=source.region
            local ordinal=(i-2)%8+1
            if ordinal==2 and leg~=1 then
                structures[#structures+1]={id="rage_gorge_"..leg,kind="bridge",name="凌岳第"..leg.."高峡桥",
                    first=length+420,last=length+1780,halfWidth=520,depth=105+leg*12,waterY=-55-leg*5}
            elseif ordinal==4 and leg~=1 and leg~=3 then
                structures[#structures+1]={id="rage_ridge_bore_"..leg,kind="tunnel",name="凌岳第"..leg.."穿岭隧道",
                    first=length+600,last=length+3000,halfWidth=330,height=285+leg*30}
            end
            if source.type=="arc" then
                slopes[#slopes+1]={id="rage_cut_"..i,name=LEG_NAMES[leg].."岩壁",first=length+300,last=length+size-300,
                    side=-1,toe=60,crest=250,outer=740,height=180+leg*35}
            end
            if ordinal==1 then regions[leg]={first=length,last=0,name=LEG_NAMES[leg],stationIndex=leg+1} end
            if ordinal==8 then regions[leg].last=length+size end
        end
        length=length+size
    end
    assert(length>=100000 and length<=140000,"[RageRoute] 天路长度必须在100..140km")
    return {id=RageRoute.Id,name=RageRoute.Name,length=length,segments=segments,stations=stations,
        start={x=-12000,y=0,z=-6000},startYaw=-50,transitionLength=180,
        profile={startY=0,startGrade=0,segments=profile},maxGrade=maxGrade,regions=regions,
        stationLayout={PlatformStart=-430,PlatformEnd=120,ApproachClearance=1000,DepartureClearance=600},
        mountain={Version="lingyue_mountain_v2",BenchHalfWidth=28,GridStep=20,DrawDistance=2400,MaxGrade=maxGrade},
        relief={Version="rage_mountain_relief_v2",PortalTransition=120,MaintenanceHalfWidth=28,
            Structures=structures,Slopes=slopes,Peaks={}},
    }
end
return RageRoute
