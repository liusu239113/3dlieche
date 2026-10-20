-- CPU确定性回归：执行实际Traffic/RageEvents，只有外部Train/Route/渲染资源为fixture。
-- 不改变生产模式配置，不写NPC状态，不伪造碰撞计数，不需要完整场景或资产加载。
local data={s=10000.0,speedMs=0.0,length=220.0,reversing=false,derails=0}
local cfg={GameMode="normal",RouteClosed=false,ModeRules={TrafficLogicCount=24,TrafficVisibleCount=8}}
local stations={{index=1,name="A",s=2000},{index=2,name="B",s=10000},
    {index=3,name="C",s=20000},{index=4,name="D",s=30000},{index=5,name="E",s=38000}}
local route={PlatformStart=-225,PlatformEnd=85,GetLength=function() return 40000 end,
    IsClosed=function() return false end,GetStations=function() return stations end,
    CurvatureAt=function() return 0 end,GradeAt=function() return 0 end,
    GetSegments=function() return {} end,GetSwitchProtectionRanges=function() return {} end,
    Sample=function(s) return Vector3(0,0,s),Vector3.FORWARD,0 end,
    SampleExtended=function(s) return Vector3(0,0,s),Vector3.FORWARD,0 end}
local source={{offset=0,length=26.5,pivot=8.75,profile="CRH380A_head"}}
local modules={}
local Train={GetS=function() return data.s end,GetSpeedMs=function() return data.speedMs end,
    GetActiveLength=function() return data.length end,IsReversing=function() return data.reversing end,
    GetCars=function() return source end,GetServiceDeceleration=function() return .65 end,
    GetOperatingSpeedKmh=function() return 300 end,GetSelectedId=function() return "CRH380A" end,
    GetLeadNode=function() return nil end,IsDerailed=function() return false end,
    Derail=function() data.derails=data.derails+1 end}
local Visual={Init=function() end,Reset=function() end,Update=function() end,Shutdown=function() end,
    GetStats=function() return {visible=0,maxVisible=3,clonedCars=0,sharedResources=true,totalClones=0,rebuilds=0,errors=0,error=""} end}
modules["train.Train"],modules["world.Route"],modules["config.GameConfig"]=Train,route,cfg
modules["config.GameModes"]={IsRage=function() return cfg.GameMode=="rage" end}
modules["game.TrafficVisuals"],modules["train.RollingStock"]=Visual,{}
modules["world.Terrain"]={GetGroundHeight=function() return -.25 end}
local function loadProject(name)
    if modules[name] then return modules[name] end
    local file=assert(cache:GetFile(name:gsub("%.","/")..".lua"))
    local lines={}
    while not file.eof do lines[#lines+1]=file:ReadLine() end
    file:Close()
    local env=setmetatable({require=loadProject},{__index=_G})
    local value=assert(load(table.concat(lines,"\n"),"@"..name,"t",env))()
    modules[name]=value
    return value
end
local Rail=loadProject("world.RailNetwork")
Train.GetTrackSample=function(s) return Rail.Sample(s,Rail.GetPlayerLane(s)) end
local Traffic=loadProject("game.Traffic")
local passed=0
local function check(value,message) assert(value,"[RageTrafficValidation] "..message) end
local function test(name,fn)
    fn();passed=passed+1
    print("[RageTrafficValidation] PASS "..name)
end
local function reset(mode,s)
    Traffic.Shutdown()
    cfg.GameMode=mode
    data.s,data.speedMs,data.derails=s or 10000,0,0
    Rail.Reset(data.s,data.length,false)
    Traffic.Init(nil)
    Traffic.CheckPlayerCollision()
end
local function advance(seconds,moving)
    for _=1,math.floor(seconds/.02+.5) do
        Traffic.Update(.02)
        if moving then data.s=data.s+data.speedMs*.02 end
        Rail.UpdatePlayer(data.s,data.length,false)
        Traffic.CheckPlayerCollision()
    end
end

function Start()
    local ok,message=xpcall(function()
        test("normal_isolation_and_same_type_contract",function()
            reset("normal",10000)
            check(Traffic.GetRageStats()==nil and Traffic.ExportRageState()==nil,"ordinary entered rage subsystem")
            check(#Traffic.GetTrains()==6 and Traffic.GetStats().minHeadway==80,"ordinary density/headway changed")
            advance(8,false)
            check(Traffic.GetStats().sharedResources and Traffic.GetStats().maxVisible==3,"ordinary shared selected-type visual contract changed")
            check(#Traffic.GetRageCars()==0 and data.derails==0,"ordinary got flying states")
        end)
        test("normal_departure_throats_up_bypass_and_parallel_isolation",function()
            reset("normal",20000)
            Traffic.SetPlayerOverride({s=20000,speedMs=0,length=220,frontOffset=16,lane=2})
            Traffic.Reset(18600) -- L01真实车体跨越站3出口咽喉。
            local blocked=Traffic.GetDepartureStatus(3)
            check(blocked.blocked and blocked.reason=="throat_conflict","down 0/2 shared exit no longer protected")
            Traffic.SetPlayerOverride({s=21000,speedMs=0,length=220,frontOffset=16,lane=5,reversing=true})
            Traffic.Reset(22000) -- 近场O01/L01在反向玩家后方；下行T班仍不能阻断绕行。
            local bypass=Traffic.GetDepartureStatus(3)
            -- T03是真实上行车，绕行最终汇回lane1后仍须防护；只禁止读取独立下行占用。
            check(bypass.blockerName~="L01" and bypass.blockerName~="T02" and bypass.blockerName~="T04",
                "lane5 misclassified as down main: "..bypass.reason.."/"..tostring(bypass.blockerName))
            check(Traffic.GetBlockSignalAspect(11100,5,-1)~="red","empty up bypass signal rejected lane5")
            check(Traffic.GetBlockSignalAspect(11100,5,1)=="red","wrong-direction bypass granted authority")
            Traffic.SetPlayerOverride({s=20000,speedMs=0,length=220,frontOffset=16,lane=0})
            Traffic.Reset(17000) -- L01从玩家后方追近，不能循环阻塞前车离站。
            advance(130,false)
            local follower=nil ---@type table?
            for _,item in ipairs(Traffic.GetTrains()) do if item.id=="L01" then follower=item end end
            check(follower and follower.hi<=20000-220-80+.02,"normal follower breached80m")
            check(not Traffic.GetDepartureStatus(3).blocked,"rear follower caused circular departure lock")
            Traffic.SetPlayerOverride(nil)
        end)
        test("rage_mixed_density_and_readonly_getters",function()
            reset("rage",10000)
            local stats=assert(Traffic.GetRageStats())
            check(stats.logical==24 and stats.modelTypes==6 and stats.active>=16,"mixed dense fleet missing")
            check(stats.maxVisible==8 and #Traffic.GetRageCars()==192,"complete eight-car bounded pool changed")
            check(Traffic.GetSpeedConstraint()==math.huge and not Traffic.GetDepartureStatus(2).blocked,"rage restricted by normal authority")
            for _=1,30 do Traffic.GetStatus();Traffic.GetRageStats();Traffic.GetRageCars() end
            check(Traffic.GetRageStats().elapsed==0 and Traffic.GetRageStats().impacts==0,"getter changed simulation")
            advance(.04,false)
            check(Traffic.GetRageStats().impacts==0,"birth overlap/parallel-track false collision")
        end)
        test("unattended_180_seconds_no_flight_no_score_safe_order",function()
            reset("rage",10000)
            for frame=1,9000 do
                Traffic.Update(.02);Traffic.CheckPlayerCollision()
                if frame%50==0 then
                    local trains=Traffic.GetTrains()
                    for _,train in ipairs(trains) do
                        check(train.dir==Rail.GetNormalDirection(train.lane),"NPC deliberately reversed")
                        check(train.carCount==8 and train.airborne==0 and train.wrecks==0,"unattended formation fragmented")
                        if train.active then
                            for _,other in ipairs(trains) do
                                if other.active and train.id~=other.id and train.dir==other.dir and train.s<other.s then
                                    check(other.lo-train.hi>=94.95,"same-base following/merge lost headway")
                                end
                            end
                        end
                    end
                    for _,car in ipairs(Traffic.GetRageCars()) do
                        check(car.state=="rail" and math.abs(car.rotation:RollAngle())<.01,"unattended rollover")
                    end
                end
            end
            local stats=Traffic.GetRageStats()
            check(stats.npcImpacts==0 and stats.playerImpacts==0 and stats.score==0 and stats.launches==0,
                "unattended NPC created causal-free score/flight")
            check(#Traffic.GetImpactEvents()==0 and #Traffic.DrainImpactEvents()==0,"safe cruising emitted impact audio")
            check(data.derails==0,"NPC wrote player accident state")
        end)
        test("player_swept_high_speed_contact_and_no_penalty",function()
            reset("rage",10000)
            data.speedMs=155
            advance(4,true)
            local stats=Traffic.GetRageStats()
            check(stats.playerImpacts>0 and stats.launches>0,"actual player motion did not launch NPC")
            check(data.speedMs==155 and data.derails==0,"player was braked/derailed by rage contact")
            local before=stats.impacts
            -- 无时间推进时重复读/检查不得刷同一pair撞击分。
            for _=1,50 do Traffic.CheckPlayerCollision() end
            check(Traffic.GetRageStats().impacts==before,"same pair counted per frame")
        end)
        test("save_statistics_validate_and_restore",function()
            local saved=assert(Traffic.ExportRageState())
            check(saved.score>0 and saved.impacts==saved.playerImpacts+saved.npcImpacts,"save counters invalid")
            reset("rage",10000)
            check(Traffic.RestoreRageState(saved),"valid rage save rejected")
            check(Traffic.GetRageStats().score==saved.score and Traffic.GetRageStats().maxChain==saved.maxChain,"persistent record lost")
            check(Traffic.GetRageStats().airborne==0 and Traffic.GetRageStats().currentChain==0,"saved flying nodes resurrected")
            local old=Traffic.GetRageStats().score
            local bad={}
            for key,value in pairs(saved) do bad[key]=value end
            bad.score=0/0
            check(not Traffic.RestoreRageState(bad) and Traffic.GetRageStats().score==old,"invalid save partially applied")
        end)
        test("teleport_no_sweep_and_deterministic_reset",function()
            reset("rage",10000)
            data.s=16000
            Traffic.CheckPlayerCollision()
            check(Traffic.GetRageStats().playerImpacts==0,"teleport swept through entire world")
            reset("rage",10000)
            advance(3,false)
            local first=Traffic.ExportRageState()
            reset("rage",10000)
            advance(3,false)
            local second=Traffic.ExportRageState()
            check(first.score==second.score and first.impacts==second.impacts and first.seed==second.seed,"deterministic reset diverged")
            reset("normal",10000)
            check(Traffic.GetRageStats()==nil and #Traffic.GetTrains()==6,"rage to normal leaked mixed states")
        end)
        print(string.format("[RageTrafficValidation] ALL_PASS %d",passed))
    end,debug.traceback)
    Traffic.Shutdown()
    if not ok then log:Write(LOG_ERROR,tostring(message)) end
end
