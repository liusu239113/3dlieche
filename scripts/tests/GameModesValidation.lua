-- 模式/地图隔离CPU回归，不require main/Game/Save，不读写或覆盖玩家旅程。
local Modes=require "config.GameModes"
local Config=require "config.GameConfig"
local Relief=require "config.ReliefConfig"
local Route=require "world.Route"
local Landmarks=require "world.Landmarks"
local Landscape=require "world.Landscape"
local Road=require "world.RoadCorridor"
local Validation={}
local checks_=0
local function check(value,message)
    checks_=checks_+1
    assert(value,"[GameModesValidation] "..message)
end
local function near(a,b,message,tolerance) check(math.abs(a-b)<(tolerance or .01),message) end
function Validation.Run()
    checks_=0
    Modes.Apply("normal")
    local originalSegments,originalStations=Config.RouteSegments,Config.Stations
    local originalStructures,originalSlopes,originalPeaks=Relief.Structures,Relief.Slopes,Relief.Peaks
    local originalSeed=Config.WorldStream.Seed
    local originalQuality=Config.RenderQuality
    local originalProfile,originalMountain,originalRegions=Config.RouteProfile,Config.MountainTerrain,Config.RouteRegions
    local originalLength=Route.Build()
    near(originalLength,88857.86374650331,"普通十站延伸线长度错误",.00001)
    check(#Route.GetStations()==10,"普通十站未完整应用")
    local normalSamples={}
    for s=0,originalLength,137 do
        local pos,tangent,yaw=Route.Sample(s)
        normalSamples[#normalSamples+1]={s=s,pos=pos,tangent=tangent,yaw=yaw}
    end
    local stationS,stationPositions={},{}
    for i,st in ipairs(Route.GetStations()) do stationS[i]=st.s;stationPositions[i]=Route.Sample(st.s) end
    local normalPoint=Route.Sample(originalLength*.4)
    near(Route.PlatformEnd-Route.PlatformStart,310,"普通站台长度改变")
    check(Modes.GetId()=="normal" and not Modes.IsRage(),"普通模式状态错误")
    check(not Config.ModeRules.IgnoreLineSpeedLimits and not Config.ModeRules.ChainCollisions,"普通模式规则串线")
    Landmarks.Init()
    check(Landmarks.GetStats().plannedBridges==9 and Landmarks.GetStats().plannedTunnels==12,"普通原桥隧+新增山地桥隧不完整")
    Landmarks.Shutdown()

    Modes.Apply("rage")
    check(Config.GameMode=="rage" and Modes.IsRage(),"狂暴模式状态错误")
    check(Config.RouteSegments~=originalSegments and Config.Stations~=originalStations,"新地图复用原配置表")
    check(Config.ModeRules.FreeDrive and Config.ModeRules.IgnoreLineSpeedLimits
        and Config.ModeRules.DisableDerailment and Config.ModeRules.ChainCollisions
        and Config.ModeRules.MixedTraffic,"狂暴必要规则缺失")
    check(Config.ModeRules.TrafficLogicCount>=24 and Config.ModeRules.TrafficVisibleCount<=8,"逻辑密度/渲染上限错误")
    local rageLength=Route.Build()
    near(rageLength,133589.41090064118,"狂暴v2地图里程错误",.00001)
    check(Config.RouteId=="rage_mountain_corridor_v2"
        and Modes.Get("rage").routeId==Config.RouteId,"狂暴v2独立routeId缺失")
    check(rageLength>=100000 and rageLength<=140000 and rageLength>33186.57734856853*3
        and rageLength>=originalLength*1.5,"狂暴原规模或与普通延伸线比例错误")
    check(Config.RouteProfile~=nil and Config.MountainTerrain~=nil,"真实纵断面/山体配置缺失")
    check(not Route.IsClosed() and #Route.GetStations()==5,"长廊不是五站独立开放线")
    near(Route.PlatformStart,-430,"狂暴站台起点未应用")
    near(Route.PlatformEnd,120,"狂暴站台终点未应用")
    near(Route.StationApproachClearance,1000,"站前保护不足")
    near(Route.StationDepartureClearance,600,"站后保护不足")
    local longestStraight,minRadius,curves,totalTurn=0,math.huge,0,0
    for _,seg in ipairs(Route.GetSegments()) do
        if seg.type=="straight" then longestStraight=math.max(longestStraight,seg.length)
        else
            -- 父曲线radius是缓和曲线补偿后的峰值半径，sourceRadius才是v2地图设计半径。
            minRadius=math.min(minRadius,seg.sourceRadius or seg.radius)
            curves=curves+1;totalTurn=totalTurn+math.abs(seg.angle or 0)
        end
    end
    check(longestStraight>=5000 and minRadius>=1400 and minRadius<=1600,"站场直线/山地小半径弯缺失")
    check(curves>=16 and totalTurn>=2300,"山地多组反向回头展线缺失")
    local minY,maxY,maxGrade,uphill,downhill,backwards=math.huge,-math.huge,0,0,0,0
    for s=0,rageLength,37.5 do
        local pos,tangent=Route.Sample(s)
        local grade=Route.GetGrade(s)
        near(pos.y,Route.GetHeight(s),"线路高程不同源",.001)
        near(tangent:Length(),1,"线路切线非单位",.00001)
        near(tangent.y/math.sqrt(tangent.x*tangent.x+tangent.z*tangent.z),grade,"切线pitch未包含真实纵坡",.00001)
        if s>1 and s<rageLength-1 then
            near((Route.HeightAt(s+1)-Route.HeightAt(s-1))*.5,grade,"高程导数不等于真实grade",.0002)
        end
        minY=math.min(minY,pos.y);maxY=math.max(maxY,pos.y);maxGrade=math.max(maxGrade,math.abs(grade))
        if grade>.01 then uphill=uphill+1 elseif grade<-.01 then downhill=downhill+1 end
        if tangent.z<-.2 then backwards=backwards+1 end
    end
    check(minY==0 and maxY>=1119.99 and uphill>600 and downhill>250,"缺少真实高差及连续爬坡/落坡")
    check(maxGrade>.04 and maxGrade<=.045001,"山地图纵坡不在40..45‰设计范围")
    check(backwards>300,"山地回头段不存在，仍然是单向Z长廊")
    local stationHeights={0,260,580,990,840}
    for i,st in ipairs(Route.GetStations()) do
        local owner=false
        for _,seg in ipairs(Route.GetSegments()) do
            if seg.type=="straight" and not seg.landmark and st.s-1400>seg.s and st.s+600<seg.s+seg.length then owner=true end
        end
        check(owner,"车站或端站渡线未完整放在直线 "..i)
        check((Route.Sample(st.s)-stationPositions[i]):Length()>1000,"新车站仍在旧世界坐标 "..i)
        for ds=-1600,1000,20 do
            near(Route.CurvatureAt(st.s+ds),0,"站台/道岔区有曲率",1e-12)
            near(Route.GetGrade(st.s+ds),0,"站场/咽喉不水平",1e-12)
            near(Route.HeightAt(st.s+ds),stationHeights[i],"车站不在独立绝对基高",.00001)
        end
    end
    local d,s=Route.DistanceTo(Route.Sample(rageLength*.37))
    near(d,0,"新线反投影偏离",.02);near(s,rageLength*.37,"新线里程反投影错误",.1)
    near(Route.Sample(-100).z,Route.Sample(0).z,"开放线路起点绕回")
    near(Route.Sample(rageLength+100).z,Route.Sample(rageLength).z,"开放线路终点绕回")

    Landmarks.Init();Landscape.Init();Road.Init()
    local stats=Landmarks.GetStats()
    check(stats.plannedBridges==5 and stats.plannedTunnels==4,"新图独立桥隧未应用")
    check(stats.plannedSlopes==16,"新图连续近线山地缺失")
    for _,def in ipairs(Landmarks.GetDefinitions()) do
        if def.kind=="tunnel" or def.kind=="bridge" then
            local owner=false
            for _,seg in ipairs(Route.GetSegments()) do
                if seg.type=="straight" and def.first>=seg.s and def.last<=seg.s+seg.length then owner=true end
            end
            check(owner,"桥隧跨出所属直线 "..def.id)
        end
        if def.kind~="mountain" then
            for _,st in ipairs(Route.GetStations()) do
                check(math.max(def.first-st.s,st.s-def.last,0)>=1000,"地貌进入站场 "..def.id)
            end
        end
    end
    check(Road.GetStats().maxGrade<=.060001,"新地貌导致国道纵坡失控")
    check(Config.WorldStream.FrameBudgetMs==3,"新地图扩大了流式单帧预算")
    Road.Shutdown();Landscape.Shutdown();Landmarks.Shutdown()

    Modes.Apply("normal");Route.Build()
    check(Config.RouteSegments==originalSegments and Config.Stations==originalStations,"普通原表引用未恢复")
    check(Relief.Structures==originalStructures and Relief.Slopes==originalSlopes and Relief.Peaks==originalPeaks,"普通地貌未精确恢复")
    check(Config.WorldStream.Seed==originalSeed and Config.RenderQuality==originalQuality,"模式切换污染种子/画质")
    check(Config.RouteProfile==originalProfile and Config.MountainTerrain==originalMountain
        and Config.RouteRegions==originalRegions,"山地图纵断面/地形/分区未精确恢复")
    check(Route.GetLength()==originalLength,"返回普通后长度非精确恢复")
    for _,sample in ipairs(normalSamples) do
        local pos,tangent,yaw=Route.Sample(sample.s)
        check((pos-sample.pos):Length()==0,"返回普通后采样坐标非精确恢复")
        check((tangent-sample.tangent):Length()==0 and yaw==sample.yaw,"返回普通后切线/yaw非精确恢复")
    end
    near(Route.GetLength(),originalLength,"返回普通后长度变化")
    near((Route.Sample(originalLength*.4)-normalPoint):Length(),0,"返回普通后世界几何变化")
    for i,st in ipairs(Route.GetStations()) do near(st.s,stationS[i],"返回普通后站点里程变化") end
    near(Route.PlatformEnd-Route.PlatformStart,310,"加长站台遗留在普通模式")
    near(Route.StationApproachClearance,700,"长咽喉遗留在普通模式")
    check(not pcall(Modes.Apply,"unknown"),"未知模式被静默加载")
    check(Modes.GetId()=="normal","拒绝未知模式后污染当前模式")
    print(string.format("GAME_MODES_PASS checks=%d normalM=%.6f rageM=%.6f ratio=%.4f platforms=310/550 noSave=true noCloud=true",
        checks_,originalLength,rageLength,rageLength/originalLength))
    return checks_
end
function Start()
    local ok,err=xpcall(Validation.Run,debug.traceback)
    if not ok then log:Write(LOG_ERROR,tostring(err)) end
    engine:Exit()
end
return Validation
