-- 中国双线左行；线路里程与五站顺序保持不变。所有车体/钢轨共用采样。
-- 横距：到发2=-10.8 | 岛台[-8.9,-1.9] | 下行0=0 (+S) | 上行1=+5 (-S)。
-- 上行5为站前外侧贯通绕线(+16.6)，进站前回到1，保留原客运站台。
local Route = require "world.Route"
local Config = require "config.GameConfig"
local RailNetwork = {}
RailNetwork.MainLane, RailNetwork.OpposingLane, RailNetwork.SidingLane = 0, 1, 2
RailNetwork.ReturnCrossoverLane, RailNetwork.OutboundCrossoverLane = 3, 4
RailNetwork.UpBypassLane = 5
RailNetwork.YardStart, RailNetwork.YardEnd = -700, 400
RailNetwork.SidingOffset, RailNetwork.UpBypassOffset = -10.8, 16.6
-- 统一几何元数据：轨道网格、逐车采样、交通占用均读取这里，不能各自猜咽喉。
---@class RailwayRoutingSpan
---@field first number
---@field plateauFirst number
---@field plateauLast number
---@field last number
---@field entryStart number
---@field entryEnd number
---@field exitStart number
---@field exitEnd number
---@class RailwayStationRouting : RailwayRoutingSpan
---@field stationIndex integer
---@field up RailwayRoutingSpan
---@field station RailwayStation
---@field platformStart number
---@field platformEnd number
---@field routeLength number
---@field index integer
---@field s number
---@field name string
---@field kind string
---@field branchOffset? number
---@field upOffset? number
---@class RailwayRoutingSection : RailwayStationRouting
---@type table<number, RailwayStationRouting>
local routingCache_ = {}
---@type RailwayRoutingSection[]
local sections_ = {}
---@type table<number, RailwayRoutingSection>
local sectionByIndex_ = {}
---@type RailwayStation[]?
local plannedStations_ = nil
local plannedMode_,plannedLength_,plannedPlatform_ = "",-1,-1
local function routingOffsets()
    local extended = Route.PlatformStart < -225 or Route.PlatformEnd > 85
    if extended then return -1000,-525,220,600,650,1000,1450,1850 end
    return -700,-320,160,400,450,800,1250,1650
end
local function span(stationS,first,plateauFirst,plateauLast,last)
    return {first=stationS+first,plateauFirst=stationS+plateauFirst,
        plateauLast=stationS+plateauLast,last=stationS+last,
        entryStart=stationS+first,entryEnd=stationS+plateauFirst,
        exitStart=stationS+plateauLast,exitEnd=stationS+last}
end
---@param index integer
---@return RailwayStationRouting?
function RailNetwork.GetStationRouting(index)
    local station = Route.GetStations()[index]
    if not station then return nil end
    local cached = routingCache_[index]
    if cached and cached.station==station and cached.platformStart==Route.PlatformStart
        and cached.platformEnd==Route.PlatformEnd and cached.routeLength==Route.GetLength() then return cached end
    local a,b,c,d,u,v,w,x = routingOffsets()
    RailNetwork.YardStart,RailNetwork.YardEnd = a,d
    local result = span(station.s,a,b,c,d) --[[@as RailwayStationRouting]]
    result.stationIndex = index
    result.index,result.s,result.name,result.kind = index,station.s,station.name,"station"
    -- 上行绕行在高里程进站方向外侧，先合回上行再停靠原站台；无尽头线。
    local upLast = math.min(station.s+x,Route.GetLength()-30)
    local upFirst = station.s+u
    local scale = math.max(0,(upLast-upFirst)/(x-u))
    result.up = span(station.s,u,u+(v-u)*scale,u+(w-u)*scale,upLast-station.s)
    result.station,result.platformStart,result.platformEnd,result.routeLength = station,Route.PlatformStart,Route.PlatformEnd,Route.GetLength()
    routingCache_[index] = result
    return result
end
function RailNetwork.GetYardBounds()
    local a,b,c,d = routingOffsets()
    RailNetwork.YardStart,RailNetwork.YardEnd = a,d
    return a,b,c,d
end
-- 区间侧线是真实贯通支路，不占业务站序：两个外向分支从各自正线分出再合回。
-- 禁岔范围 = 站场(含上行绕线)+桥隧门户；任何新路线都按接口重算，不依赖段数。
local function planSections()
    local stations=Route.GetStations()
    if plannedStations_==stations and plannedLength_==Route.GetLength()
        and plannedMode_==Config.GameMode and plannedPlatform_==Route.PlatformStart then return end
    sections_,sectionByIndex_ = {},{}
    plannedStations_,plannedLength_,plannedMode_,plannedPlatform_=stations,Route.GetLength(),Config.GameMode,Route.PlatformStart
    local protected={}
    for _,station in ipairs(stations) do
        local routing=assert(RailNetwork.GetStationRouting(station.index)) --[[@as RailwayRoutingSection]]
        sections_[#sections_+1]=routing;sectionByIndex_[routing.index]=routing
        protected[#protected+1]={first=math.min(routing.first,routing.up.first)-160,
            last=math.max(routing.last,routing.up.last)+160}
    end
    if Config.GameMode=="rage" then
        -- Route拥有桥隧范围；尚未初始化地标时也能规划，避免循环require Landmarks。
        if Route.GetSwitchProtectionRanges then
            for _,range in ipairs(Route.GetSwitchProtectionRanges()) do
                protected[#protected+1]={first=range.first-80,last=range.last+80}
            end
        else
            for _,seg in ipairs(Route.GetSegments()) do
                if seg.landmark=="bridge" or seg.landmark=="tunnel" then
                    protected[#protected+1]={first=seg.s-160,last=seg.s+seg.length+160}
                end
            end
        end
        table.sort(protected,function(a,b)return a.first<b.first end)
        local free={}
        local cursor=240.0
        for _,range in ipairs(protected) do
            if range.first>cursor then free[#free+1]={first=cursor,last=math.min(range.first,plannedLength_-240)} end
            cursor=math.max(cursor,range.last)
        end
        if cursor<plannedLength_-240 then free[#free+1]={first=cursor,last=plannedLength_-240} end
        local count=0
        for _,window in ipairs(free) do
            local first=window.first+30
            while first+1260<=window.last do
                local last=first+1260
                local safe=true
                for s=first,last,90 do
                    -- 纵断面缓坡可设岔；陡坡、强竖曲线、过小曲率区不强塞分流。
                    if math.abs(Route.GradeAt(s))>.045
                        or math.abs(Route.GradeAt(s+25)-Route.GradeAt(s-25))>.008
                        or math.abs(Route.CurvatureAt(s))>1/500 then safe=false;break end
                end
                if safe then
                    count=count+1
                    local section=span(0,first,first+420,first+840,last) --[[@as RailwayRoutingSection]]
                    section.index,section.stationIndex,section.s=-count,0,(first+last)/2
                    section.kind,section.name="interval",string.format("区间选道 %02d",count)
                    section.up=span(0,first,first+420,first+840,last)
                    -- 两条始终在正线外侧的同向支路，净空不交叉反向正线。
                    section.branchOffset=-(count%3==0 and 10.8 or (count%3==1 and 6.0 or 8.2))
                    section.upOffset=5-section.branchOffset
                    section.routeLength=plannedLength_
                    sections_[#sections_+1]=section;sectionByIndex_[section.index]=section
                    first=first+2100+(count%3-1)*180
                else first=first+180 end
            end
        end
        print(string.format("[RailNetwork] 统一进路：%d站场 + %d区间外向支路；桥隧/站场保护，不修改客运站序",#stations,count))
    end
    table.sort(sections_,function(a,b)return a.first<b.first end)
end
---@return RailwayRoutingSection[]
function RailNetwork.GetRoutingSections() planSections();return sections_ end
---@param index integer
---@return RailwayRoutingSection?
function RailNetwork.GetRoutingSection(index) planSections();return sectionByIndex_[index] end
---@param s number
---@param lane? integer
---@return RailwayRoutingSection?
function RailNetwork.GetSectionAt(s,lane)
    local sections=RailNetwork.GetRoutingSections()
    local up=lane==1 or lane==5
    local low,high=1,#sections
    while low<=high do
        local mid=math.floor((low+high)/2)
        local section=sections[mid]
        local path=up and section.up or section
        if s<path.first then high=mid-1
        elseif s>path.last then low=mid+1
        else return section end
    end
    return nil
end
-- 显式冲突域给交通owner：同向main/branch仅在入口、出口喉区互斥。
function RailNetwork.GetConflictZones()
    local result={}
    for _,section in ipairs(RailNetwork.GetRoutingSections()) do
        for base=0,1 do
            local path=base==1 and section.up or section
            for _,entry in ipairs({true,false}) do
                result[#result+1]={key="section:"..section.index..":"..base..(entry and ":entry" or ":exit"),
                    sectionIndex=section.index,index=section.index,baseLane=base,lanes={base,base==1 and 5 or 2},
                    first=(entry and path.first or path.plateauLast)-4,
                    last=(entry and path.plateauFirst or path.last)+4}
            end
        end
    end
    for _,cross in ipairs(RailNetwork.GetCrossovers()) do
        result[#result+1]={key="crossover:"..cross.lane,sectionIndex=cross.stationIndex,
            index=cross.stationIndex,baseLane=-1,lanes={0,1,cross.lane},
            first=cross.first-4,last=cross.last+4}
    end
    return result
end
function RailNetwork.GetOperatingPaths()
    return {{lane=0,dir=1,baseLane=0,key="main"},{lane=1,dir=-1,baseLane=1,key="main"},
        {lane=2,dir=1,baseLane=0,key="siding"},{lane=5,dir=-1,baseLane=1,key="siding"}}
end
local MODE = "cn_left_v1"
---@class RailwayRouteChoice
---@field lane integer
---@field locked boolean
---@class RailwayTurnback
---@field stationIndex integer
---@field lane integer
---@field fromLane integer
---@field toLane integer
---@field first number
---@field last number
---@field dir number
---@type table<number, RailwayRouteChoice>
local choices_ = {}
---@type RailwayTurnback?
local turnback_ = nil
local playerS_, playerLength_, playerReversing_, baseLane_ = 0.0, 220.0, false, 0
---@type (fun(cross:RailwayTurnback,s:number,length:number):boolean,string)?
local turnbackValidator_ = nil
---@type (fun(stationIndex:integer,lane:integer,s:number,length:number):boolean,string)?
local routeChoiceValidator_ = nil
function RailNetwork.SetRouteChoiceValidator(validator) routeChoiceValidator_=validator end
function RailNetwork.SetSectionChoiceValidator(validator) routeChoiceValidator_=validator end
function RailNetwork.SetTurnbackValidator(validator) turnbackValidator_=validator end

local function smooth(t)
    local x = math.max(0, math.min(1, t))
    return x*x*x*(10+x*(-15+x*6))
end
function RailNetwork.GetTopologyMode() return MODE end
---@param lane integer
---@return integer
function RailNetwork.GetNormalDirection(lane) return (lane == 1 or lane == 5) and -1 or 1 end
---@param s number
---@param lane? integer 省略时查询下行站场；5查询上行站前绕行
---@return RailwayStation?
function RailNetwork.GetYard(s,lane)
    for _, station in ipairs(Route.GetStations()) do
        local routing = assert(RailNetwork.GetStationRouting(station.index))
        local path = lane==5 and routing.up or routing
        if s >= path.first and s <= path.last then return station end
    end
    return nil
end
---@param s number
---@param baseLane integer
---@param pathKey? string
---@return integer
function RailNetwork.GetPathLane(s,baseLane,pathKey)
    local base = (baseLane==1 or baseLane==5) and 1 or 0
    if baseLane==3 or baseLane==4 then return baseLane end
    local branch = base==1 and 5 or 2
    local section = RailNetwork.GetSectionAt(s,branch)
    if not section or pathKey=="main" then return base end
    if pathKey=="siding" or pathKey=="section:"..section.index..":siding"
        or (section.kind=="station" and pathKey=="yard:"..section.stationIndex..":siding") then return branch end
    if pathKey then return base end
    return (baseLane==2 or baseLane==5) and branch or base
end
---@return RailwayTurnback[]
function RailNetwork.GetCrossovers()
    if Route.IsClosed() then return {} end
    local stations = Route.GetStations()
    local first, last = stations[1], stations[#stations]
    if not first or not last then return {} end
    -- 渡线只在站台外咽喉，净空与既有站台/站序兼容。
    local yard = assert(RailNetwork.GetStationRouting(last.index))
    local firstYard = assert(RailNetwork.GetStationRouting(first.index))
    return {
        {stationIndex=last.index,lane=3,fromLane=0,toLane=1,first=yard.first-400,last=yard.first-60,dir=-1},
        {stationIndex=first.index,lane=4,fromLane=1,toLane=0,first=firstYard.plateauLast,last=firstYard.last,dir=1},
    }
end
---@param s number
---@param lane? integer
---@return number
function RailNetwork.GetLateral(s,lane)
    if lane == 1 then return 5 end
    if lane == 3 or lane == 4 then
        for _, cross in ipairs(RailNetwork.GetCrossovers()) do
            if cross.lane == lane then
                -- 西端：低里程接上行，高里程接下行；东端同样高里程接下行。
                return 5*(1-smooth((s-cross.first)/(cross.last-cross.first)))
            end
        end
        return 0
    end
    if lane ~= 2 and lane ~= 5 then return 0 end
    local base = lane==5 and 5 or 0
    local routing = RailNetwork.GetSectionAt(s,lane)
    if not routing then return base end
    local path = lane==5 and routing.up or routing
    local offset=lane==5 and (routing.upOffset or RailNetwork.UpBypassOffset)
        or (routing.branchOffset or RailNetwork.SidingOffset)
    local amount = offset-base
    if s < path.plateauFirst then return base+amount*smooth((s-path.first)/(path.plateauFirst-path.first)) end
    if s > path.plateauLast then return base+amount*(1-smooth((s-path.plateauLast)/(path.last-path.plateauLast))) end
    return base+amount
end
local function center(s)
    if Route.SampleExtended then return Route.SampleExtended(s) end
    return Route.Sample(s)
end
---@param s number
---@param lane? integer
---@param pathKey? string NPC固定路径，独立于玩家预选；不得在占用期间更换
---@return Vector3, Vector3, number
function RailNetwork.Sample(s,lane,pathKey)
    local id = pathKey and RailNetwork.GetPathLane(s,lane or 0,pathKey) or (lane or 0)
    if id == 0 then return center(s) end
    local position,axis,yaw = center(s)
    local angle=math.rad(yaw)
    local right=Vector3(math.cos(angle),0,-math.sin(angle))
    local lateral=RailNetwork.GetLateral(s,id)
    local derivative=(RailNetwork.GetLateral(s+.05,id)-RailNetwork.GetLateral(s-.05,id))/.1
    -- 不对几万米世界坐标做小差分，float32消减会使直线端点出现假切线跳变。
    -- d(P+R*l)/ds = T*(1-k*l)+R*l'，曲率取真实路线，不是视觉转向角。
    local curvature=(s>=0 and s<=Route.GetLength()) and Route.CurvatureAt(s) or 0
    -- s为平面设计里程，不能将单位3D轴整体乘曲率修正，否则纵坡也被错误压缩。
    local horizontal=math.sqrt(axis.x*axis.x+axis.z*axis.z)
    local grade=horizontal>1e-8 and axis.y/horizontal or 0
    local planar=Vector3(math.sin(angle),0,math.cos(angle))
    local tangent=(planar*(1-curvature*lateral)+Vector3(0,grade,0)+right*derivative):Normalized()
    return position+right*lateral,tangent,math.deg(math.atan(tangent.x,tangent.z))
end
---@param s number
---@param lane? integer
---@param pathKey? string
---@return Vector3
function RailNetwork.UpAt(s,lane,pathKey)
    local _,tangent,yaw=RailNetwork.Sample(s,lane,pathKey)
    local a=math.rad(yaw)
    return tangent:CrossProduct(Vector3(math.cos(a),0,-math.sin(a))):Normalized()
end
function RailNetwork.GetStations() return Route.GetStations() end
-- 整列包络[s-L,s+16]锁岔；渡线须最后一个支点/尾端清空后才能提交新baseLane。
---@param s number
---@param length number
---@param reversing boolean
function RailNetwork.UpdatePlayer(s,length,reversing)
    local previousS,previousLength = playerS_,playerLength_
    playerS_,playerLength_,playerReversing_ = s,length,reversing
    local rear,front = s-length,s+16
    -- 扫掠包络也记录一步跨越的道岔；高速/低FPS不可漏掉默认路径历史。
    local sweptRear = math.min(rear,previousS-previousLength)
    local sweptFront = math.max(front,previousS+16)
    local crossing = turnback_
    if crossing and ((crossing.dir < 0 and front < crossing.first-2)
        or (crossing.dir > 0 and rear > crossing.last+2)) then
        baseLane_,turnback_ = crossing.toLane,nil
        print("[RailNetwork] 端站连续渡线整列清空，归入"..(baseLane_==1 and "上行左行正线" or "下行左行正线"))
    end
    for _,routing in ipairs(RailNetwork.GetRoutingSections()) do
        local path = baseLane_==1 and routing.up or routing
        local occupied = front >= path.first-2 and rear <= path.last+2
        local crossed = sweptFront >= path.first and sweptRear <= path.last
        local choice = choices_[routing.index]
        if crossed and not choice then
            choices_[routing.index] = {lane=baseLane_,locked=occupied}
        elseif choice then choice.locked=occupied end
    end
end
---@param s number
---@return integer
function RailNetwork.GetPlayerLane(s)
    local crossing = turnback_
    if crossing then
        if crossing.dir < 0 then
            if s <= crossing.first then return crossing.toLane end
            if s < crossing.last then return crossing.lane end
        else
            if s >= crossing.last then return crossing.toLane end
            if s > crossing.first then return crossing.lane end
        end
        local station=RailNetwork.GetSectionAt(s)
        local choice=station and choices_[station.index]
        return crossing.fromLane==0 and choice and choice.lane==2 and 2 or crossing.fromLane
    end
    if baseLane_==1 then
        local station=RailNetwork.GetSectionAt(s,5)
        local choice=station and choices_[station.index]
        return choice and choice.lane==5 and 5 or 1
    end
    local station=RailNetwork.GetSectionAt(s)
    local choice=station and choices_[station.index]
    return choice and choice.lane==2 and 2 or 0
end
---@param s number
---@param length number
---@param reversing boolean new direction, only when stationary
---@return boolean,string
function RailNetwork.RequestDirectionChange(s,length,reversing)
    if Config.GameMode=="rage" then
        -- 自由驾驶允许原股道反向，绝不以换向为由瞬移到另一正线。
        -- 已选侧线历史及锁保持不变，倒车时各节仍采样同一条真实曲线。
        playerReversing_=reversing
        return true,"狂暴自由折返：保持当前股道与锁定路径，收油停稳后反向牵引"
    end
    if Route.IsClosed() then return false,"双线运营请在开放端站折返" end
    if turnback_ then return false,"整列仍在折返进路内，请先通过渡线清空" end
    local dir=reversing and -1 or 1
    for _,cross in ipairs(RailNetwork.GetCrossovers()) do
        local station=Route.GetStations()[cross.stationIndex]
        if station and cross.dir==dir and cross.fromLane==baseLane_ and math.abs(s-station.s)<=60 then
            -- 候选整列必须尚未跨到渡线，以免换向一刻改变任何车节位置。
            if (dir<0 and s-length<=cross.last+2) or (dir>0 and s+16>=cross.first-2) then
                return false,"编组未完整停在端站渡线内方，请对标停稳"
            end
            if turnbackValidator_ then
                local safe,reason=turnbackValidator_(cross,s,length)
                if not safe then return false,reason end
            end
            turnback_=cross
            playerReversing_=reversing
            print("[RailNetwork] 端站折返：保持原位，经真实渡线连续驶入目标左行正线")
            return true,"端站渡线折返已锁定，道岔40km/h，清尾后归正常左行"
        end
    end
    return false,"双线左行禁止区间同股逆行，请在终端站停稳折返"
end
function RailNetwork.GetTurnback() return turnback_ end
function RailNetwork.GetBaseLane() return baseLane_ end
---@param s number
---@param reversing boolean
---@return RailwayRoutingSection?,number
function RailNetwork.GetNextSwitch(s,reversing)
    local selected,best=nil,math.huge ---@type RailwayRoutingSection?,number
    for _,section in ipairs(RailNetwork.GetRoutingSections()) do
        local path=baseLane_==1 and section.up or section
        local entry=reversing and path.last or path.first
        local leader=reversing and s-playerLength_ or s+16
        local distance=reversing and leader-entry or entry-leader
        if distance>=-2 and distance<best then selected,best=section,math.max(0,distance) end
    end
    return selected,best
end
---@param index integer
---@param lane integer
---@param s number
---@param length number
---@return boolean,string
function RailNetwork.SetSectionChoice(index,lane,s,length)
    RailNetwork.UpdatePlayer(s,length,playerReversing_)
    local station=RailNetwork.GetRoutingSection(index)
    if not station then return false,"未知铁路进路" end
    if turnback_ then return false,"折返渡线整列未清空，不能改变进路" end
    local existing=choices_[index]
    if existing and existing.locked then return false,"岔区占用，不能改变已锁进路" end
    local branch=baseLane_==1 and 5 or 2
    if lane~=baseLane_ and lane~=branch then return false,"进路不连接当前方向的正线" end
    if routeChoiceValidator_ then
        local safe,reason=routeChoiceValidator_(index,lane,s,length)
        if not safe then return false,reason end
    end
    choices_[index]={lane=lane,locked=false}
    return true,station.name..(lane==branch and "贯通侧线进路已预选" or "正线进路已预选")
end
function RailNetwork.SetStationChoice(index,lane,s,length)
    return RailNetwork.SetSectionChoice(index,lane,s,length)
end
function RailNetwork.SetPlayerChoice(dir,s,length,reversing)
    RailNetwork.UpdatePlayer(s,length,reversing)
    local station,distance=RailNetwork.GetNextSwitch(s,reversing)
    if not station then return false,"前方无道岔，请在端站对标折返" end
    -- 当前区段占用不妨碍预选下一个未占用区段；只拒绝车下这一个进路。
    local branch=baseLane_==1 and 5 or 2
    local ok,message=RailNetwork.SetStationChoice(station.index,dir>0 and branch or baseLane_,s,length)
    return ok,ok and string.format("%s，距入口%.0fm",message,distance) or message
end
function RailNetwork.GetStatus()
    local lane=RailNetwork.GetPlayerLane(playerS_)
    local anyLocked=false
    for _,record in pairs(choices_) do anyLocked=anyLocked or record.locked end
    local nextStation,distance=RailNetwork.GetNextSwitch(playerS_,playerReversing_)
    local nextChoice=nextStation and choices_[nextStation.index]
    local branch=baseLane_==1 and 5 or 2
    local nextSwitch=nextStation and {index=nextStation.index,name=nextStation.name,kind=nextStation.kind,
        distance=distance,locked=turnback_~=nil or (nextChoice and nextChoice.locked==true or false),
        selected=nextChoice and nextChoice.lane==branch and "siding" or "main",
        lane=nextChoice and nextChoice.lane or baseLane_,baseLane=baseLane_,branchLane=branch} or false
    local current=RailNetwork.GetSectionAt(playerS_,lane)
    return {aspect="green",text="左行进路开放",nextSwitch=nextSwitch,hasNextSwitch=nextStation~=nil,
        track=turnback_ and "端站渡线折返"
        or (lane==5 and "上行贯通绕线" or (lane==1 and "上行正线 · 左行" or (lane==2
            and (current and current.kind=="interval" and "区间贯通侧线" or "站内到发线") or "下行正线 · 左行"))),
        switchText=turnback_ and "连续渡线锁定 · 整列清尾归正线"
            or (anyLocked and "岔区占用·整列清尾前锁定"
            or (nextStation and string.format("%s %s %.0fm",nextStation.name,
                nextChoice and (nextChoice.lane==2 or nextChoice.lane==5) and "侧线" or "正线",distance) or "线路终端")),
        locked=turnback_~=nil or anyLocked}
end
function RailNetwork.Reset(s,length,reversing)
    choices_,turnback_,baseLane_={},nil,reversing and 1 or 0
    playerS_,playerLength_ = s,length or 220
    RailNetwork.GetYardBounds()
    RailNetwork.UpdatePlayer(s,length or 220,reversing==true)
end
function RailNetwork.GetChoices() return choices_ end
function RailNetwork.RestoreChoices(saved)
    choices_={}
    for _,choice in ipairs(saved) do
        assert(RailNetwork.GetRoutingSection(choice.index) and (choice.lane==0 or choice.lane==1 or choice.lane==2 or choice.lane==5),"存档进路无效")
        choices_[choice.index]={lane=choice.lane,locked=false}
    end
    RailNetwork.UpdatePlayer(playerS_,playerLength_,playerReversing_)
end
function RailNetwork.ExportTopology()
    return {mode=MODE,baseLane=baseLane_,turnbackLane=turnback_ and turnback_.lane or nil}
end
function RailNetwork.RestoreTopology(saved,reversing)
    assert(not saved or saved.mode==MODE,"未知存档拓扑模式，拒绝覆盖原存档")
    baseLane_=saved and saved.baseLane or (reversing and 1 or 0)
    assert(baseLane_==0 or baseLane_==1,"存档基础股道无效")
    turnback_=nil
    if saved and saved.turnbackLane then
        for _,cross in ipairs(RailNetwork.GetCrossovers()) do if cross.lane==saved.turnbackLane then turnback_=cross end end
        assert(turnback_,"存档折返进路不存在")
    end
end
return RailNetwork
