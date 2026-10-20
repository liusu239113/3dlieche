-- 真实Runtime / 真实Route、RailNetwork、Train、六车型MDL；不加载main、不碰存档、不调用云。
-- 复用scaffold-3d-scene持有Scene/Camera的生命周期；逻辑按实际0.02s小步推进。
-- -rage-order-seconds=180 默认无人操作180秒；-rage-order-capture允许EndRendering截图。
local Modes=require "config.GameModes"
local Route=require "world.Route"
local Rail=require "world.RailNetwork"
local Train=require "train.Train"
local Catalog=require "config.TrainCatalog"
local Traffic=require "game.Traffic"
local Rage=require "game.RageEvents"
---@type Scene?
local scene_=nil
---@type Node?
local cameraNode_=nil
local checks_,frame_,seconds_=0,0,180
local done_,capture_=false,false
local stage_="starting"
local fixtureS_=0.0
local modelSeen_={} ---@type table<string,boolean>
local previousSequence_=0
local collisionObserved_,rotated_,landed_,secondary_=false,false,false,false
local maxAirborne_,maxWrecks_,gradeSamples_=0,0,0
local startedAt_=os.clock()
local PREFIX="[RageOrderValidation] "
for _,argument in ipairs(GetArguments()) do
    local value=argument:match("^%-rage%-order%-seconds=(%d+)$")
    if value then seconds_=math.max(60,math.min(180,tonumber(value) or 180)) end
    if argument=="-rage-order-capture" then capture_=true end
end
local function check(value,message) checks_=checks_+1;assert(value,PREFIX..message) end
local function guard(action)
    if done_ then return end
    local ok,message=xpcall(action,debug.traceback)
    if not ok then done_=true;log:Write(LOG_ERROR,tostring(message));engine:Exit() end
end
local function positionCamera(s)
    local p,t=Rail.Sample(s,0)
    cameraNode_.position=p-t*110+Vector3(-54,30,0)
    cameraNode_:LookAt(p+t*240+Vector3(0,3,0))
end
local function tick()
    Train.Update(.02)
    Rail.UpdatePlayer(Train.GetS(),Train.GetActiveLength(),Train.IsReversing())
    Traffic.Update(.02)
    Traffic.CheckPlayerCollision()
end
local function verifyBindings()
    local bindings=Rage.GetVisualBindings()
    local cars={} ---@type table<string,table>
    for _,car in ipairs(Traffic.GetRageCars()) do cars[car.id]=car end
    for _,item in ipairs(bindings) do
        local asset=assert(Catalog.Assets[item.profile])
        check(item.bound and item.geometries>0 and item.modelPath==asset.modelPath,"not actual catalog MDL "..item.profile.."/"..item.modelPath)
        local car=cars[item.vehicleId..":"..item.index]
        check(car~=nil,"pool car has no logical owner")
        if car and car.state=="rail" then
            local facing=item.rotation*Vector3.FORWARD
            local expected=car.rotation*Vector3.FORWARD*(car.reverse and -1 or 1)
            check(facing:DotProduct(expected)>.9999,"actual MDL head/tail facing wrong "..item.profile)
            local base=car.position-car.rotation*Vector3(0,car.height*.5,0)
            check((item.position-base):Length()<.015,"MDL pivot detached from rail car")
        end
    end
    local types={} ---@type table<string,boolean>
    for _,train in ipairs(Traffic.GetTrains()) do
        if train.visible then types[train.id]=true;modelSeen_[train.modelId]=true end
    end
    return bindings,types
end
local function verifyOrder()
    local trains=Traffic.GetTrains()
    local owners={} ---@type table<string,table>
    local stats=assert(Traffic.GetRageStats())
    check(stats.score==0 and stats.impacts==0 and stats.launches==0 and stats.airborne==0 and stats.landings==0,
        "unattended cruise produced flying/score")
    check(#Traffic.GetImpactEvents()==0,"safe cruise emitted audio event")
    for _,train in ipairs(trains) do
        owners[train.id]=train
        if train.active then
            check(train.carCount==8 and train.airborne==0 and train.wrecks==0,"not intact eight-car formation")
            check(train.dir==Rail.GetNormalDirection(train.lane),"NPC wrong-way dispatch")
            check(train.lo>=0 and train.hi<=Route.GetLength(),"NPC escaped open route endpoint")
            for _,other in ipairs(trains) do
                if other.active and train.id~=other.id and train.dir==other.dir and train.s<other.s then
                    check(other.lo-train.hi>=94.94,"following/merge violated95m "..train.id.."/"..other.id)
                end
            end
        end
    end
    for _,car in ipairs(Traffic.GetRageCars()) do
        local train=owners[car.vehicleId]
        if car.active then
            check(car.state=="rail" and car.chain==0 and car.launches==0,"cruise car fragmented")
            local front=Rail.Sample(car.railS+train.dir*car.pivot,train.lane,train.pathKey)
            local rear=Rail.Sample(car.railS-train.dir*car.pivot,train.lane,train.pathKey)
            local chord=(front-rear):Normalized()
            local facing=car.rotation*Vector3.FORWARD
            check(facing:DotProduct(chord)>.9999,"car axis does not match real graded tangent")
            local base=car.position-car.rotation*Vector3(0,car.height*.5,0)
            check((base-(front+rear)*.5):Length()<.02,"car floats above real support chord")
            check(math.abs((car.rotation*Vector3.RIGHT).y)<.0001,"in-rail car rolls sideways")
            if math.abs(chord.y)>.003 then gradeSamples_=gradeSamples_+1 end
        end
    end
    -- 喉区完整占用互斥，不以逻辑lane2与lane0标签不同逃避合流。
    for _,zone in ipairs(Rail.GetConflictZones()) do
        local count=0
        for _,train in ipairs(trains) do
            local base=(train.lane==1 or train.lane==5) and 1 or 0
            if train.active and (zone.baseLane<0 or zone.baseLane==base)
                and train.hi>=zone.first and train.lo<=zone.last then count=count+1 end
        end
        check(count<=1,"multiple formations occupy throat "..zone.key)
    end
end
local function observeImpacts()
    local stats=Traffic.GetRageStats()
    maxAirborne_=math.max(maxAirborne_,stats.airborne)
    for _,car in ipairs(Traffic.GetRageCars()) do
        if car.state=="flying" and car.position.y-car.floor>3 then collisionObserved_=true end
        if car.state=="flying" and math.abs(car.rotation:RollAngle())>12 then rotated_=true end
        if car.state=="wreck" then landed_=true end
    end
    local wrecks=0
    for _,train in ipairs(Traffic.GetTrains()) do wrecks=wrecks+train.wrecks end
    maxWrecks_=math.max(maxWrecks_,wrecks)
    if stats.npcImpacts>0 and stats.chains>0 then secondary_=true end
    local events=Traffic.DrainImpactEvents(8)
    for _,value in ipairs(events) do
        check(value.sequence>previousSequence_,"event sequence reused/not monotonic")
        check(value.strength>0 and value.strength<=140,"invalid impact strength")
        check(value.position.x==value.position.x and value.position.y==value.position.y,"invalid impact world position")
        previousSequence_=value.sequence
    end
end
function Start()
    guard(function()
        Modes.Apply("rage");Route.Build()
        scene_=Scene();scene_:CreateComponent("Octree")
        cameraNode_=scene_:CreateChild("OrderCamera")
        local camera=cameraNode_:CreateComponent("Camera")
        camera.nearClip,camera.farClip,camera.fov=.1,4500,65
        camera.viewMask=3
        renderer:SetViewport(0,Viewport:new(scene_,camera))
        Train.Build(scene_)
        check(Train.ValidateBindings(),"actual player eight-car MDL binding failed")
        fixtureS_=Route.GetStations()[2].s
        Train.Reset(fixtureS_);Rail.Reset(fixtureS_,Train.GetActiveLength(),false)
        Traffic.Init(scene_)
        Traffic.CheckPlayerCollision()
        positionCamera(fixtureS_+440)
        stage_="bind"
        SubscribeToEvent("Update","RageOrderUpdate")
        if capture_ then SubscribeToEvent("EndRendering","RageOrderCapture") end
        print(PREFIX.."START realRuntime=true realMDL=true noMain=true saveAccess=0 cloudCalls=0")
    end)
end
function RageOrderUpdate()
    guard(function()
        frame_=frame_+1
        if stage_=="bind" then
            Traffic.UpdateVisuals(.02)
            if frame_>=100 then
                local bindings=verifyBindings()
                check(#bindings>=32,"real MDL pool did not become ready")
                -- 访问每种车型可见位置只用于资源验收，不推进物理/不碰撞/不改NPC状态。
                for _,target in ipairs(Traffic.GetTrains()) do
                    if not modelSeen_[target.modelId] then
                        Traffic.SetPlayerOverride({s=target.s,speedMs=0,length=Train.GetActiveLength(),lane=0})
                        Traffic.Update(.000001)
                        for _=1,110 do Traffic.UpdateVisuals(.02) end
                        verifyBindings()
                    end
                end
                Traffic.SetPlayerOverride(nil)
                Train.Reset(fixtureS_);Rail.Reset(fixtureS_,Train.GetActiveLength(),false);Traffic.Reset(fixtureS_)
                local types=0;for _ in pairs(modelSeen_) do types=types+1 end
                check(types==6,"six catalog train types did not bind actual pool MDL")
                stage_,frame_="unattended",0
                print(PREFIX.."BOUND sixTypes=6 intactCarsPerTrain=8")
            end
        elseif stage_=="unattended" then
            for _=1,50 do tick() end
            Traffic.UpdateVisuals(.02)
            verifyOrder()
            if frame_>=seconds_ then
                verifyBindings()
                check(gradeSamples_>0,"real map test did not encounter actual longitudinal grade")
                print(PREFIX.."UNATTENDED_PASS seconds="..seconds_.." score=0 launches=0 impacts=0 gradeSamples="..gradeSamples_)
                Train.Reset(fixtureS_);Rail.Reset(fixtureS_,Train.GetActiveLength(),false);Traffic.Reset(fixtureS_)
                Train.RestoreState({id=Train.GetSelectedId(),s=fixtureS_,v=155,throttle=0,brake=0,reversing=false,moving=true})
                Traffic.CheckPlayerCollision()
                stage_,frame_="collision",0
            end
        elseif stage_=="collision" then
            for _=1,5 do tick();observeImpacts() end
            Train.UpdateVisuals(.02);Traffic.UpdateVisuals(.02)
            if frame_>=60 then
                local stats=Traffic.GetRageStats()
                check(stats.playerImpacts>0 and stats.score>0 and stats.launches>0,"real player movement did not strike/launch NPC")
                check(collisionObserved_ and rotated_,"no actual ballistic flight/rotation")
                -- 停车后只允许已有抛体真实二次接触，不能新增玩家动能。
                Train.RestoreState({id=Train.GetSelectedId(),s=Train.GetS(),v=0,throttle=0,brake=1,reversing=false,moving=false})
                stage_,frame_="settle",0
            end
        elseif stage_=="settle" then
            for _=1,10 do tick();observeImpacts() end
            Traffic.UpdateVisuals(.02)
            if frame_>=120 then
                local stats=Traffic.GetRageStats()
                check(landed_ and stats.landings>0,"real impacts did not land")
                check(secondary_,"player-originated projectile did not cause secondary chain")
                check(stats.airborne==0,"projectiles never settled/cleared")
                for _,train in ipairs(Traffic.GetTrains()) do check(train.wrecks==0,"wreck persisted after bounded cleanup") end
                check(stats.clearedCars>0,"wreck cleanup did not recycle car states")
                check(stats.poolSlots<=8 and stats.clonedCars<=64 and stats.errors==0,"pool leaked or model bind failed")
                check(not Train.IsDerailed(),"rage collision changed player accident state")
                print(string.format(PREFIX.."ALL_PASS checks=%d unattendedSeconds=%d realMDLTypes=6 playerImpacts=%d secondary=%d launches=%d landings=%d peakAirborne=%d peakWrecks=%d cleared=%d elapsedCpu=%.2f",
                    checks_,seconds_,stats.playerImpacts,stats.npcImpacts,stats.launches,stats.landings,maxAirborne_,maxWrecks_,stats.clearedCars,os.clock()-startedAt_))
                stage_,done_="complete",true
                if not capture_ then engine:Exit() end
            end
        end
    end)
end
function RageOrderCapture()
    if stage_~="unattended" or frame_~=60 then return end
    local image=Image()
    if graphics:TakeScreenShot(image) then image:SavePNG("/home/Maker/rage-order-cruise.png") end
    image:Dispose()
end
function Stop()
    Traffic.Shutdown();Train.Shutdown()
    if scene_ then scene_:Dispose();scene_=nil end
    Route.Clear()
end
