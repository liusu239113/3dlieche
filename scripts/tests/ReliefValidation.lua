-- 默认生产地貌隔离回归：不require main/Game/Save/云；不读写任何玩家存档。
-- CPU入口完成即退出；真实像素与WorldStream实体见ReliefVisualValidation。
local Route = require "world.Route"
local Landmarks = require "world.Landmarks"
local Terrain = require "world.Terrain"
local Road = require "world.RoadCorridor"
local Landscape = require "world.Landscape"
local Scenery = require "world.RailwayScenery"
local Infrastructure = require "world.RailwayInfrastructure"
local Relief = require "world.ReliefGeometry"
local Config = require "config.ReliefConfig"
local CorridorConfig = require "config.CorridorConfig"
local GameConfig = require "config.GameConfig"
local Validation = {}
local checks_=0
---@type Scene?
local scene_=nil
local function check(v,message) checks_=checks_+1;assert(v,"[ReliefValidation] "..message) end
local function near(a,b,message,tolerance) check(math.abs(a-b)<(tolerance or .006),message) end
local expectedStations={829.6644337142133,7016.647338506558,16719.84243883246,23162.910109552,31859.114254625787}
local function meshVertices()
    local total=0
    for _,mesh in ipairs(Landmarks.GetMeshes()) do
        for slot=0,mesh.numGeometries-1 do total=total+mesh:GetNumVertices(slot) end
    end
    return total
end
function Validation.RunPlan()
    checks_=0
    Route.Build();Terrain.Init()
    near(Route.GetLength(),33186.57734856853,"默认线路里程改变")
    for i,station in ipairs(Route.GetStations()) do near(station.s,expectedStations[i],"车站里程改变 "..i,.1) end
    check(GameConfig.WorldStream.FrameBudgetMs==3,"不得扩大3ms流式预算")
    for s=0,Route.GetLength(),53.5 do
        near(Route.Sample(s).y,0,"道床基准改变")
        near(Route.GradeAt(s),0,"未适配的纵坡")
        near(Route.CantAt(s),0,"未适配的超高")
    end
    local stats=Landmarks.GetStats()
    check(stats.plannedBridges==4 and stats.plannedTunnels==7,"默认生产工程数量不是4桥7隧")
    check(stats.plannedSlopes==9,"默认近线坡段缺失")
    local bridges,tunnels,totalBridge,totalTunnel=0,0,0,0
    for _,def in ipairs(Landmarks.GetDefinitions()) do
        if def.kind=="bridge" or def.kind=="tunnel" then
            for _,station in ipairs(Route.GetStations()) do
                check(math.max(def.first-station.s,station.s-def.last,0)>=1000,"工程侵入站场缓冲 "..def.id)
            end
            local owner=false
            for _,seg in ipairs(Route.GetSegments()) do
                if seg.type=="straight" and def.first>=seg.s and def.last<=seg.s+seg.length then owner=true end
            end
            check(owner,"桥隧未落完整直线 "..def.id)
            print(string.format("[ReliefValidation] STRUCTURE %s %s first=%.6f last=%.6f length=%.3f",def.kind,def.id,def.first,def.last,def.last-def.first))
            if def.kind=="bridge" then
                bridges=bridges+1;totalBridge=totalBridge+def.last-def.first
                near(Landmarks.GetValleyY(def,def.first,def.lateral),-.25,"桥入口谷坡不接地")
                near(Landmarks.GetValleyY(def,def.last,def.lateral),-.25,"桥出口谷坡不接地")
                near(Landmarks.GetValleyY(def,def.s,def.lateral),-.25-def.depth,"桥墩谷底不真实")
                local poly={Route.SampleOffset(def.s-2,0,0),Route.SampleOffset(def.s+2,0,0),
                    Route.SampleOffset(def.s+2,5,0),Route.SampleOffset(def.s-2,5,0)}
                check(#Landmarks.ClipGround(poly)==0,"桥下保底未真实切掉")
            else
                tunnels=tunnels+1;totalTunnel=totalTunnel+def.last-def.first
                check(def.innerHalfWidth>=9.5 and def.wallHeight>=8.8,"左行双线/接触网净空缩小")
                check(Landmarks.GetEnvironmentAt(def.s)=="tunnel","新增隧道环境分类未接默认")
                for s=def.first,def.last,24 do
                    local _,_,lat=Road.Sample(s)
                    check(lat-CorridorConfig.Road.LaneWidth-CorridorConfig.Road.Shoulder
                        >=def.lateral+def.halfWidth*1.14+15.9,"国道侵入山壳/维护带")
                end
            end
        elseif def.kind=="slope" then
            check(def.toe>=Config.MaintenanceHalfWidth,"近线切坡挤占维护带")
            local aa,ha=Relief.SlopeSection(def,def.first)
            local bb,hb=Relief.SlopeSection(def,def.last)
            near(ha,0,"坡段入口不归零");near(hb,0,"坡段出口不归零")
            near(aa[1].y,-.25,"坡脚悬空");near(bb[#bb].y,-.25,"外坡脚悬空")
            check(Landmarks.Reserves(Route.SampleOffset(def.s,def.lateral,0),0),"山坡不在解析避让表")
            check(not Landscape.FieldAllowed(Route.SampleOffset(def.s,def.lateral,0),8),"田地埋入切坡")
        end
    end
    near(totalBridge,1920,"桥梁总长")
    near(totalTunnel,4190,"隧道总长")
    check(Road.GetStats().bypasses==tunnels,"国道未适配全部新增隧道")
    check(Road.GetStats().connectedLoops==1,"新增地貌破坏既有双上跨回环")
    check(Road.GetStats().maxGrade<=.060001 and Road.GetStats().maxSurfaceY<35,"国道纵坡/悬坡")
    local profile=Road.GetProfile()
    for _,p in ipairs(profile) do
        for _,def in ipairs(Landmarks.GetDefinitions()) do
            if def.kind=="slope" and p.s>=def.first and p.s<=def.last then
                check(p.lateral-CorridorConfig.Road.LaneWidth-CorridorConfig.Road.Shoulder>0,
                    "国道进入负侧近线切坡")
            end
        end
    end
    print(string.format("RELIEF_PLAN_PASS checks=%d bridges=%d tunnels=%d bridgeM=%.3f tunnelM=%.3f budgetMs=%.1f",
        checks_,bridges,tunnels,totalBridge,totalTunnel,GameConfig.WorldStream.FrameBudgetMs))
    return checks_
end
function Validation.RunGeometry()
    scene_=Scene();scene_:CreateComponent("Octree")
    local triangles,totalPiers,maxReliefSliceMs=0,0,0.0
    local maxSlices={bridge=0.0,tunnel=0.0,slope=0.0}
    for _,def in ipairs(Landmarks.GetDefinitions()) do
        if def.kind=="bridge" or def.kind=="tunnel" or def.kind=="slope" then
            local first=math.floor((def.first-80)/240)*240
            local last=math.ceil((def.last+80)/240)*240
            local owner=scene_:CreateChild("地貌验收_"..def.id)
            for s=first,last-.001,240 do
                local work=coroutine.create(function()
                    Landmarks.BuildChunk(owner,s,math.min(last,s+240),function() coroutine.yield() end)
                end)
                repeat
                    local begin=os.clock()
                    local ok,err=coroutine.resume(work)
                    local sliceMs=(os.clock()-begin)*1000
                    maxReliefSliceMs=math.max(maxReliefSliceMs,sliceMs)
                    maxSlices[def.kind]=math.max(maxSlices[def.kind],sliceMs)
                    check(ok,"地貌协程切片失败 "..tostring(err))
                until coroutine.status(work)=="dead"
            end
            local stats=Landmarks.GetStats()
            check(stats.vertices==meshVertices() and stats.vertices>0,"实际网格顶点与统计不同")
            if def.kind=="tunnel" then
                check(stats.portals>=2 and stats.minTunnelHalfWidth>=9.48,"门户/真洞内衬缺失")
                local voidSamples=0
                for _,mesh in ipairs(Landmarks.GetMeshes()) do
                    for slot=0,mesh.numGeometries-1 do
                        local count=mesh:GetNumVertices(slot)
                        triangles=triangles+count/3
                        for index=0,count-3,3 do
                            local a=mesh:GetVertex(slot,index).position
                            local b=mesh:GetVertex(slot,index+1).position
                            local c=mesh:GetVertex(slot,index+2).position
                            local middle=(a+b+c)/3
                            local _,s=Route.DistanceTo(middle)
                            if s>def.first+.02 and s<def.last-.02 then
                                local lateral=(middle-Route.Sample(s)):DotProduct(Route.RightAt(s))
                                check(not (lateral>-.8 and lateral<5.8 and middle.y>.55 and middle.y<7.0),
                                    "真洞通道被三角形填满 "..def.id)
                                voidSamples=voidSamples+1
                            end
                        end
                    end
                end
                check(voidSamples>0,"未检查真实隧道三角形")
            elseif def.kind=="bridge" then
                check(stats.piers>0 and stats.maxValleyDepth>=def.depth,"河谷桥缺真实墩/谷面")
                totalPiers=totalPiers+stats.piers
            else check(stats.slopes>0 and stats.slopeLength>0,"近线切坡无实际实体") end
            for s=first,last-.001,240 do Landmarks.ForgetChunk(s,math.min(last,s+240)) end
            owner:Dispose()
            check(#Landmarks.GetMeshes()==0,"卸载后地貌组件引用泄漏")
        end
    end
    Infrastructure.Init(scene_)
    -- 设施直接依据生产Landmarks计划，新增洞中禁止普通地柱、桥中禁止谷底地柱。
    local suspensions,bridgeSupports=0,0
    for _,support in ipairs(Infrastructure.GetValidationData().supports) do
        for _,def in ipairs(Landmarks.GetDefinitions()) do
            if support.s>=def.first and support.s<def.last then
                if def.kind=="tunnel" then
                    check(support.mode=="tunnel","新增真隧道仍规划普通地柱")
                    suspensions=suspensions+1
                elseif def.kind=="bridge" then
                    check(support.mode=="bridge" and support.baseY==-.18,"新增河谷桥仍规划谷底柱")
                    check(support.left>=-6.7 and support.right<=11.7,"桥柱不落双线桥面")
                    bridgeSupports=bridgeSupports+1
                end
            end
        end
    end
    check(suspensions>70 and bridgeSupports>30,"新增桥隧设施计划不完整")
    print(string.format("RELIEF_GEOMETRY_PASS checks=%d examinedTriangles=%d piers=%d tunnelSupports=%d bridgeSupports=%d reliefMaxSliceMs=%.3f targetMs=3 overTarget=%s",
        checks_,triangles,totalPiers,suspensions,bridgeSupports,maxReliefSliceMs,tostring(maxReliefSliceMs>3)))
    print("RELIEF_SLICE_KINDS "..require("cjson").encode(maxSlices))
    Infrastructure.Shutdown();Scenery.Shutdown();Road.Shutdown();Landscape.Shutdown();Landmarks.Shutdown()
    scene_:Dispose();scene_=nil
    return checks_
end
function Validation.RunStreaming()
    local Stream=require "world.WorldStream"
    scene_=Scene();scene_:CreateComponent("Octree")
    Stream.Build(scene_,8650)
    for _=1,100 do Stream.Update(8650,1/30) end
    local before=Landmarks.GetStats()
    check(before.tunnels>0 and before.vertices>0,"生产WorldStream未加载新增隧道实体")
    Stream.Update(15470,1/30)
    for _=1,200 do Stream.Update(15470,1/30) end
    local after=Landmarks.GetStats()
    local streaming=Stream.GetStats()
    check(after.bridges>0 and after.piers>0 and after.vertices>0,"生产WorldStream未加载新增河谷桥实体")
    check(streaming.disposedChunks>0,"跨地理区移动未卸载旧实体")
    check(after.tunnels==0,"旧洞实体未随窗口卸载")
    print("RELIEF_STREAM_ENTITY_PASS "..require("cjson").encode({
        firstS=8650,lastS=15470,oldTunnelVertices=before.vertices,newBridgeVertices=after.vertices,
        loadedBridges=after.bridges,piers=after.piers,loadedLandmarkChunks=after.loadedChunks,
        loadedSceneryChunks=streaming.sceneryChunks,disposedChunks=streaming.disposedChunks,
        pendingTasks=streaming.pendingTasks,maxTaskMs=streaming.maxTaskMs,lastUpdateMs=streaming.lastUpdateMs,
        frameBudgetMs=GameConfig.WorldStream.FrameBudgetMs,noSave=true,noCloud=true}))
    Stream.Shutdown();scene_:Dispose();scene_=nil
end
function Start()
    local ok,err=xpcall(function() Validation.RunPlan();Validation.RunGeometry();Validation.RunStreaming() end,debug.traceback)
    if not ok then log:Write(LOG_ERROR,tostring(err)) end
    engine:Exit()
end
return Validation
