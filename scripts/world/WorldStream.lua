-- 单机世界局部流式：解析全线常驻，渲染节点与任务拥有明确生命周期。
-- 近景120m完整轨道、100m设施空间批；远景轨头/道床连续到farClip之外。
-- 设施协程按内部小段让出，取消时先清灯引用再释放块节点。
local Route = require "world.Route"
local Track = require "world.Track"
local Infrastructure = require "world.RailwayInfrastructure"
local Terrain = require "world.Terrain"
local Mountain = require "world.MountainProfile"
local StreamGround = require "world.StreamGround"
---@class RailwayStreamStationModule
---@field BuildOne fun(root:Node, st:table, pause:fun()|nil)
---@field Init fun()
---@field Forget fun(index:number)
---@field Shutdown fun()
local Station = require "world.Station"
local StationYard = require "world.StationYard"
local GameConfig = require "config.GameConfig"
local WorldStream = {}

---@class RailwayStreamEntry
---@field key string
---@field kind string
---@field index number|string
---@field first number
---@field last number
---@field x number
---@field z number
---@field priority number
---@field wanted boolean
---@field ready boolean
---@field node Node|nil
---@field work thread|nil
---@field vertices number
---@field meshes integer
---@field shown boolean
---@field permanent? boolean
---@field generation integer
---@field requestedFrame integer
---@field startedFrame? integer
---@field readyFrame? integer
---@field platformMeshes? CustomGeometry[]
---@field platformVertices? integer
---@field uploadedVertices? integer
---@type Scene|nil
local scene_ = nil
---@type Node|nil
local root_ = nil
---@type table<string, RailwayStreamEntry>
local entries_ = {}
---@type table<string,RailwayStreamEntry>
local coreGround_ = {}
local lastS_ = 0.0
local refresh_ = 0.0
local targetS_ = 0.0
---@type RailwayStreamEntry[]
local queue_ = {}
local queueIndex_ = 1
local maxTaskMs_ = 0.0
local lastUpdateMs_ = 0.0
local generatedVertices_ = 0
local disposedChunks_ = 0
local startupMs_ = 0.0
local maxInitialTaskMs_ = 0.0
---@type table
local config_ = {}
local qualityConfig_ = nil
local forceRefresh_ = false
local velocity_ = 0.0
---@type RailwayStreamEntry[]
local groundQueue_ = {}
local groundQueueIndex_ = 1
local groundSlices_ = 0
---@type RailwayStreamEntry[]
local stationQueue_ = {}
local generation_,frame_,stationSlices_ = 0,0,0
local building_ = false
local direction_ = 1

local function option(name, fallback) return config_[name] or fallback end
local function delta(from,to) return to-from end

-- 狂暴模式只扩大渲染预取，不改变列车速度；近轨、路基和前方地形优先完成。
-- 开放线路半开窗口；两端截断，绝不绕到另一端加载尾/头块。
---@param s number
---@param behind number
---@param ahead number
---@param step number
---@param visit fun(index:integer,start:number,finish:number,ordinal:integer,total:integer)
local function ranges(s,behind,ahead,step,visit)
    local length=Route.GetLength()
    if length<=0 then return end
    local first,finish=math.max(0,s-behind),math.min(length,s+ahead)
    if finish<=first then return end
    local firstIndex=math.floor(first/step)
    local lastIndex=math.ceil((finish-0.000001)/step)-1
    local total=math.max(1,lastIndex-firstIndex+1)
    local ordinal=0
    for index=firstIndex,lastIndex do
        ordinal=ordinal+1
        local start=index*step
        visit(index,start,math.min(start+step,length),ordinal,total)
    end
end

-- CustomGeometry缓冲属于Component；实例组/实例节点也在chunk内。
-- 先释放component，再子节点，最后父节点；不会Dispose共享cache模型/材质。
---@param node Node
local function disposeNode(node)
    for _, child in ipairs(node:GetChildren()) do disposeNode(child) end
    node:RemoveAllComponents()
    node:Dispose()
end
local function removeEntry(entry)
    -- 队列可能仍持有取消前的entry；绝不能让旧任务注销同key的新站/新灯引用。
    if entries_[entry.key]~=entry then return end
    entry.ready=false
    entry.platformMeshes=nil
    -- 精细块先恢复基础面，再销毁；不能在LOD切换的这一帧透出天空。
    if entry.kind=="terrain" then
        local ground=entries_["ground_"..entry.index]
        if ground and ground.ready and ground.node then
            ground.node:SetEnabledRecursive(true);ground.shown=true
        end
    end
    entry.work=nil -- 先取消协程，不能让旧任务再访问已Dispose对象。
    if entry.kind=="infrastructure" then Infrastructure.ForgetChunk(entry.first,entry.last) end
    if entry.kind=="scenery" then Terrain.ForgetScenery(entry.first,entry.last) end
    if entry.kind=="vegetation" then Terrain.ForgetTrees(entry.first,entry.last,"near") end
    if entry.kind=="woodland" then Terrain.ForgetTrees(entry.first,entry.last,"middle") end
    if entry.kind=="forest" then Terrain.ForgetTrees(entry.first,entry.last,"distant") end
    if entry.kind=="station" then StationYard.Forget(entry.index); Station.Forget(entry.index) end
    if entry.node then disposeNode(entry.node); entry.node=nil end
    if entry.kind=="terrain" then Terrain.ForgetCell(entry.x,entry.z) end
    if entry.kind=="city" then Terrain.ForgetStation(entry.index) end
    entries_[entry.key]=nil
    disposedChunks_=disposedChunks_+1
end
local function request(kind,index,first,last,priority,x,z)
    local key=kind.."_"..index
    local entry=entries_[key] or coreGround_[key]
    if not entry then
        entry={key=key,kind=kind,index=index,first=first or 0,last=last or 0,
            x=x or 0,z=z or 0,priority=priority,wanted=true,ready=false,node=nil,work=nil,vertices=0,meshes=0,shown=false,
            generation=generation_,requestedFrame=frame_}
        entries_[key]=entry
    end
    entry.wanted=true
    entry.priority=priority
    return entry
end

local function countVertices(node)
    local vertices=0
    for _, geom in ipairs(node:GetComponents("CustomGeometry",true)) do
        for i=0,geom.numGeometries-1 do vertices=vertices+geom:GetNumVertices(i) end
    end
    return vertices
end
local function buildEntry(entry,pause)
    local node=assert(entry.node)
    if entry.kind=="nearRail" or entry.kind=="farRail" then
        return Track.BuildChunk(node,entry.first,entry.last,entry.kind=="nearRail",pause)
    elseif entry.kind=="mountainBackdrop" then
        return Terrain.BuildMountainBackdrop(node,entry.first,entry.last,pause)
    elseif entry.kind=="infrastructure" then
        Infrastructure.BuildChunk(node,entry.first,entry.last,pause)
    elseif entry.kind=="vegetation" then
        Terrain.BuildTrees(node,entry.first,entry.last,pause,"near")
    elseif entry.kind=="woodland" then
        Terrain.BuildTrees(node,entry.first,entry.last,pause,"middle")
    elseif entry.kind=="forest" then
        Terrain.BuildTrees(node,entry.first,entry.last,pause,"distant")
    elseif entry.kind=="scenery" then
        Terrain.BuildScenery(node,entry.first,entry.last,pause)
    elseif entry.kind=="ground" then
        return StreamGround.BuildCell(node,entry.x,entry.z,option("TerrainCellSize",160),pause,entry.permanent)
    elseif entry.kind=="terrain" then
        Terrain.BuildCell(node,entry.x,entry.z,option("TerrainCellSize",160),pause)
    elseif entry.kind=="station" then
        local st=Route.GetStations()[entry.index]
        if st then
            Station.BuildOne(node,st,pause)
            StationYard.Build(node,st,pause)
        end
    elseif entry.kind=="city" then
        local st=Route.GetStations()[entry.index]
        if st then Terrain.BuildCity(node,st,pause) end
    end
    return countVertices(node)
end
local function assertCurrent(entry)
    assert(entry.generation==generation_ and entries_[entry.key]==entry and root_ and entry.node
        and entry.node.parent==root_,"[WorldStream] 已取消的构建不可恢复："..entry.key)
end
local function startEntry(entry)
    assert(entry.generation==generation_ and entries_[entry.key]==entry)
    local owner=assert(root_)
    entry.startedFrame=frame_
    entry.node=owner:CreateChild(entry.key,LOCAL)
    entry.node:SetEnabledRecursive(false)
    entry.work=coroutine.create(function()
        assertCurrent(entry)
        return buildEntry(entry,function()
            assertCurrent(entry)
            -- 新子节点不能假定继承父enabled；每次yield前隐藏新生成的子树。
            assert(entry.node):SetEnabledRecursive(false)
            coroutine.yield()
            -- Shutdown/Reset后即使外部误resume旧协程，也在接触几何之前终止。
            assertCurrent(entry)
        end)
    end)
end
local function show(entry,visible)
    if entry.node and entry.shown~=visible then
        entry.node:SetEnabledRecursive(visible)
        entry.shown=visible
    end
end
-- 只在事务提交时验证三座台体，不把空root、排队数或未Commit的CPU顶点当ready。
local function commitStation(entry)
    local node=assert(entry.node)
    local meshes={} ---@type CustomGeometry[]
    local vertices,uploaded=0,0
    for _,name in ipairs({"WeatheredConcretePlatforms","UpPlatformConcrete"}) do
        local child=assert(node:GetChild(name,true),"[WorldStream] 缺少真实台体："..name)
        local mesh=assert(child:GetComponent("CustomGeometry"))
        local count=mesh:GetNumVertices(0)
        assert(count>0,"[WorldStream] 台体无顶点："..name)
        -- FillModel读Commit后的绘制缓冲；只查两批共108顶点，不拷贝全站装饰。
        local model=Model()
        local ok=mesh:FillModel(model)
        local geometry=ok and model:GetGeometry(0,0) or nil
        local buffer=geometry and geometry:GetVertexBuffer(0) or nil
        local submitted=geometry and buffer and math.min(geometry.vertexCount,buffer.vertexCount) or 0
        model:Dispose()
        assert(submitted==count,"[WorldStream] 台体尚未完整提交："..name)
        meshes[#meshes+1]=mesh
        vertices=vertices+count;uploaded=uploaded+submitted
    end
    entry.platformMeshes=meshes
    entry.platformVertices=vertices
    entry.uploadedVertices=uploaded
end
local function complete(entry,vertices)
    assertCurrent(entry)
    if entry.kind=="station" then commitStation(entry) end
    entry.work=nil
    entry.vertices=vertices or 0
    if entry.node then entry.meshes=#entry.node:GetComponents("CustomGeometry",true) end
    generatedVertices_=generatedVertices_+entry.vertices
    -- 原子提交：最后一次yield已结束且台体/站场Finish通过，才一起启用并发布ready。
    show(entry,true)
    entry.readyFrame=frame_
    entry.ready=true
    -- 基础面保持在精细面下4cm；细节裁切区的谷底/站基不能随fine一起隐藏。
    if entry.kind=="nearRail" then
        local far=entries_["farRail_"..entry.index]
        if far then show(far,false) end
    elseif entry.kind=="farRail" then
        local near=entries_["nearRail_"..entry.index]
        if near and near.ready then
            show(near,near.wanted)
            show(entry,not near.shown)
        end
    end
end
local function synchronous(entry,pause)
    -- 首载/Reset也走相同隐藏、取消与提交路径；不能覆盖已有node而让旧node占key。
    assert(not entry.node and not entry.work and not entry.ready,"[WorldStream] 重复启动："..entry.key)
    startEntry(entry)
    while entry.work do
        assertCurrent(entry)
        local work=assert(entry.work)
        local begin=os.clock()
        local ok,value=coroutine.resume(work)
        maxInitialTaskMs_=math.max(maxInitialTaskMs_,(os.clock()-begin)*1000)
        if not ok then removeEntry(entry);error("[WorldStream] 初始块失败："..tostring(value)) end
        if coroutine.status(work)=="dead" then complete(entry,value)
        elseif pause then pause() end
        assertCurrent(entry)
    end
end

local function refreshTargets(s)
    local begin=os.clock()
    local margin=option("UnloadMargin",720)
    local pos=Route.Sample(s)
    for _, entry in pairs(entries_) do entry.wanted=entry.permanent==true end
    local railStep=option("TrackChunkLength",120)
    local rage=GameConfig.GameMode=="rage"
    local viewAhead=option(rage and "RageViewAhead" or "ViewAhead",3000)
    local detailAhead=option(rage and "RageDetailAhead" or "DetailAhead",480)
    local infrastructureAhead=option(rage and "RageInfrastructureAhead" or "InfrastructureAhead",1500)
    local sceneryAhead=option(rage and "RageSceneryAhead" or "SceneryAhead",1600)
    local terrainRadius=option(rage and "RageTerrainRadius" or "TerrainRadius",1120)
    ranges(s,option("ViewBehind",2800),viewAhead,railStep,function(i,a,b)
        request("farRail",i,a,b,30+math.abs(delta(s,(a+b)/2))/100)
        if not rage and Mountain.IsActiveAt(b) then request("mountainBackdrop",i,a,b,31+math.abs(delta(s,(a+b)/2))/100) end
    end)
    ranges(s,option("DetailBehind",360),detailAhead,railStep,function(i,a,b)
        request("nearRail",i,a,b,1+math.abs(delta(s,(a+b)/2))/100)
    end)
    ranges(s,option("InfrastructureBehind",1100),infrastructureAhead,
        option("InfrastructureChunkLength",100),function(i,a,b)
            request("infrastructure",i,a,b,math.abs(delta(s,(a+b)/2))<480 and 19+math.abs(delta(s,(a+b)/2))/100 or 40+math.abs(delta(s,(a+b)/2))/100)
        end)
    ranges(s,option("SceneryBehind",1200),sceneryAhead,
        option("SceneryChunkLength",240),function(i,a,b)
            local distance=math.abs(delta(s,(a+b)/2))
            -- 近处国道/乡野先于远轨和远处接触网完成；否则队首长任务会让
            -- 玩家身边已有解析规划的地块长期空白，暂停观察时也不能补齐。
            local priority=distance<=480 and 12+distance/100 or 55+distance/100
            request("scenery",i,a,b,priority)
        end)
    -- 113km/h=31.4m/s：前方800..1400m提前25..44秒进入队列。
    -- 独立层任务不再让近草等完远林；前向预取先于后方缓存/远侧设施。
    local vegetationRadius=option("VegetationRadius",640)
    local function plantingTargets(kind,behind,ahead,base,step)
        ranges(s,behind,ahead,step,function(i,a,b)
            local ds=(a+b)*.5-s
            local distance=math.abs(ds)
            local priority=base+distance/200+(ds< -160 and 18 or 0)
            if distance>800 then priority=priority+15 end
            request(kind,i,a,b,priority)
        end)
    end
    plantingTargets("vegetation",math.min(vegetationRadius,480),math.max(800,vegetationRadius),14,80)
    plantingTargets("woodland",math.min(vegetationRadius,640),math.max(1120,vegetationRadius),16,160)
    plantingTargets("forest",math.min(vegetationRadius,800),math.max(1440,vegetationRadius),18,160)
    -- 每方向只预取紧邻的下一站，不同步全线；station独立通道保证静止/高速都能推进。
    -- 速度只用于准备时间，不改变物理/速度上限。反向行驶同样提前请求上一站。
    local nextStation=nil ---@type table?
    local nextDistance=math.huge
    for _,st in ipairs(Route.GetStations()) do
        local along=(st.s-s)*direction_
        if along>math.max(1,Route.PlatformEnd) and along<nextDistance then
            nextStation,nextDistance=st,along
        end
    end
    local stationRadius=option("StationRadius",2800)
    for _, st in ipairs(Route.GetStations()) do
        local distance=math.abs(delta(s,st.s))
        local along=(st.s-s)*direction_
        if distance<stationRadius or st==nextStation then
            local arrivalTime=distance/math.max(1,math.abs(velocity_))
            request("station",st.index,st.s,st.s,arrivalTime+(along< -Route.PlatformEnd and stationRadius or 0))
            if distance<option("CityRadius",2100) then
                request("city",st.index,st.s,st.s,24+distance/200)
            end
        end
    end
    local size=option("TerrainCellSize",160)
    local radius=terrainRadius
    local extent=math.ceil(radius/size)
    local cx,cz=math.floor(pos.x/size),math.floor(pos.z/size)
    local tangent=Route.TangentAt(s)
    for x=cx-extent,cx+extent do
        for z=cz-extent,cz+extent do
            local dx,dz=(x+.5)*size-pos.x,(z+.5)*size-pos.z
            local distance=math.sqrt(dx*dx+dz*dz)
            if distance<radius+size*.71 then
                local priority=85+distance/80
                local along=dx*tangent.x+dz*tangent.z
                local lateral=math.abs(dx*tangent.z-dz*tangent.x)
                -- 先交付驾驶前方和林带脚下地表，旧priority85会一直输给设施40。
                -- 仍按既定圆形半径请求全格，城市/田块/桥谷裁切由Terrain负责。
                if along>=-200 and along<=1120 and lateral<=560 then
                    priority=13+distance/200
                elseif distance<=560 then priority=27+distance/160
                elseif Mountain.IsActiveAt(s) and distance<=640 then priority=35+distance/80 end
                local index=x.."_"..z
                if rage then
                    request("ground",index,0,0,priority,x,z)
                    if distance<=option("RageFineTerrainRadius",480)+size*.71 then
                        request("terrain",index,0,0,priority+12,x,z)
                    end
                else request("terrain",index,0,0,priority,x,z) end
            end
        end
    end
    if rage and math.abs(velocity_)>1 then
        -- 前瞻按实际位移估速，保持8秒准备时间；只扩沿线带，不扩整个精细地表圆。
        local direction=velocity_>=0 and 1 or -1
        local look=math.min(option("RageMaxGroundLookAhead",12000),math.max(terrainRadius,math.abs(velocity_)*8))
        local width=option("RageGroundLookWidth",640)
        for ahead=0,look,size do
            local future=Route.Sample(Route.Wrap(s+ahead*direction))
            local fx,fz=math.floor(future.x/size),math.floor(future.z/size)
            local reach=math.ceil(width/size)
            for x=fx-reach,fx+reach do for z=fz-reach,fz+reach do
                local dx,dz=(x+.5)*size-future.x,(z+.5)*size-future.z
                if dx*dx+dz*dz<=(width+size*.71)^2 then
                    local priority=8+ahead/500+math.sqrt(dx*dx+dz*dz)/300
                    local existing=entries_["ground_"..x.."_"..z]
                    if not existing or not existing.wanted or priority<existing.priority then
                        request("ground",x.."_"..z,0,0,priority,x,z)
                    end
                end
            end end
        end
    end
    -- 滞回只保留已启动/完成块，尚未建的无效排队任务立即取消。
    local remove={}
    for _, entry in pairs(entries_) do
        if not entry.wanted then
            local keep=false
            if entry.ready or entry.work then
                if entry.kind=="terrain" or entry.kind=="ground" then
                    local dx,dz=(entry.x+.5)*size-pos.x,(entry.z+.5)*size-pos.z
                    local keepRadius=rage and entry.kind=="terrain" and option("RageFineTerrainRadius",480) or radius
                    keep=dx*dx+dz*dz<(keepRadius+margin+size)^2
                else
                    local distance=delta(s,(entry.first+entry.last)/2)
                    local half=(entry.last-entry.first)/2
                    local behind,ahead=option("ViewBehind",2800),option("ViewAhead",3000)
                    if entry.kind=="nearRail" then behind,ahead=option("DetailBehind",360),option("DetailAhead",480) end
                    if entry.kind=="infrastructure" then behind,ahead=option("InfrastructureBehind",1100),option("InfrastructureAhead",1500) end
                    if entry.kind=="station" then behind,ahead=option("StationRadius",2800),option("StationRadius",2800) end
                    if entry.kind=="city" then behind,ahead=option("CityRadius",2100),option("CityRadius",2100) end
                    if entry.kind=="scenery" then behind,ahead=option("SceneryBehind",1200),option("SceneryAhead",1600) end
                    if entry.kind=="vegetation" then behind,ahead=math.min(option("VegetationRadius",640),480),math.max(800,option("VegetationRadius",640)) end
                    if entry.kind=="woodland" then behind,ahead=math.min(option("VegetationRadius",640),640),math.max(1120,option("VegetationRadius",640)) end
                    if entry.kind=="forest" then behind,ahead=math.min(option("VegetationRadius",640),800),math.max(1440,option("VegetationRadius",640)) end
                    keep=distance>=-behind-margin-half and distance<=ahead+margin+half
                end
            end
            if not keep then remove[#remove+1]=entry end
        end
    end
    for _, entry in ipairs(remove) do removeEntry(entry) end
    -- 卸载滞回保留近轨缓存，但离开详细窗口即显示远轨，不能让+720m滞回
    -- 继续绘制真枕木。若远轨尚未ready则暂保近轨，任何一帧都没有空轨道。
    for _,entry in pairs(entries_) do
        if entry.kind=="nearRail" and entry.ready then
            local far=entries_["farRail_"..entry.index]
            show(entry,entry.wanted or not (far and far.ready))
        end
    end
    for _,entry in pairs(entries_) do
        if entry.kind=="farRail" and entry.ready and entry.node then
            local near=entries_["nearRail_"..entry.index]
            show(entry,not (near and near.ready and near.shown))
        end
    end
    -- 同一目标窗口只排序一次；切片直接推进队首，不再每片扫描全部地形entries。
    queue_={};groundQueue_={};stationQueue_={}
    queueIndex_=1;groundQueueIndex_=1
    for _,entry in pairs(entries_) do
        if entry.wanted and not entry.ready then
            local target=entry.kind=="ground" and groundQueue_ or (entry.kind=="station" and stationQueue_ or queue_)
            target[#target+1]=entry
        end
    end
    local function order(a,b)
        return a.priority<b.priority or (a.priority==b.priority and a.key<b.key)
    end
    table.sort(queue_,order);table.sort(groundQueue_,order);table.sort(stationQueue_,order)
    targetS_=s
    lastUpdateMs_=(os.clock()-begin)*1000
end

function WorldStream.SetQuality(preset)
    qualityConfig_ = preset
    if config_ and next(config_) then
        forceRefresh_ = true
    end
end

---@param scene Scene
---@param initialS number|nil
---@return Node
---@param pause? fun(ratio?:number)
function WorldStream.Build(scene,initialS,pause)
    -- Build/Reset均可在已有世界上调用；先取消协程/灯引用/站场注册再释放根。
    -- 否则旧yards_仍登记同站，新Build会触发同站重复断言并泄漏旧整棵流式世界。
    if root_ then WorldStream.Shutdown() end
    generation_=generation_+1
    local generation=generation_
    building_=true
    if pause then
        local notify=pause
        pause=function(ratio)
            assert(generation==generation_,"[WorldStream] 加载已取消")
            notify(ratio)
            assert(generation==generation_,"[WorldStream] 加载已取消")
        end
    end
    local begin=os.clock()
    -- 分阶段进度：把 0..1 的局部构建进度交给加载页，避免整段停在同一个百分比。
    ---@type fun(ratio:number)|nil
    local onStage=pause
    if GameConfig.GameMode=="rage" and pause then
        onStage=function(ratio) pause(.18+.82*ratio) end
    end
    local STAGE_WEIGHT = { farRail=22, nearRail=8, infrastructure=4, station=20, city=18, scenery=18, vegetation=5, terrain=10 }
    local stageTotal=0
    for _, weight in pairs(STAGE_WEIGHT) do stageTotal=stageTotal+weight end
    local stageDone=0
    ---@param key string
    ---@return fun(fraction:number?)
    local function stage(key)
        local weight=STAGE_WEIGHT[key] or 0
        local base=stageDone
        stageDone=stageDone+weight
        return function(fraction)
            if not onStage then return end
            local f=math.max(0,math.min(1,fraction or 0))
            onStage(math.min(1,(base+weight*f)/stageTotal))
        end
    end
    scene_=scene
    config_=GameConfig.WorldStream or {}
    if qualityConfig_ then
        config_.ViewAhead=qualityConfig_.viewAhead or config_.ViewAhead
        config_.ViewBehind=qualityConfig_.viewBehind or config_.ViewBehind
        config_.SceneryAhead=qualityConfig_.sceneryAhead or config_.SceneryAhead
        config_.SceneryBehind=qualityConfig_.sceneryBehind or config_.SceneryBehind
        config_.TerrainRadius=qualityConfig_.terrainRadius or config_.TerrainRadius
        config_.VegetationRadius=qualityConfig_.vegetationRadius or config_.VegetationRadius
    end
    forceRefresh_=false
    if Route.GetLength()<=0 then Route.Build() end
    assert(Route.GetLength()>0,"[WorldStream] 无有效解析线路")
    root_=scene:CreateChild("WorldStream",LOCAL)
    Terrain.Init(); Station.Init(); StationYard.Init(); Track.Init(); Infrastructure.Init(scene)
    Terrain.BuildGround(root_)
    StreamGround.Clear();velocity_=0;groundSlices_=0
    if GameConfig.GameMode=="rage" and GameConfig.MountainTerrain then
        -- 只把全线窄核心基础地面放在加载页；不预建全线装饰/枕木/城市。
        -- 世界格去重，回头弯不重叠；任何速度/倒车/瞬移都不会跑出轨旁基础面。
        local size=option("TerrainCellSize",160)
        local width=option("RageCoreGroundWidth",160)
        local reach=math.ceil(width/size)
        local length=Route.GetLength()
        for at=0,length+size*.5,size*.5 do
            local pos=Route.Sample(math.min(at,length))
            local cx,cz=math.floor(pos.x/size),math.floor(pos.z/size)
            for x=cx-reach,cx+reach do for z=cz-reach,cz+reach do
                local dx,dz=(x+.5)*size-pos.x,(z+.5)*size-pos.z
                local key=x.."_"..z
                if dx*dx+dz*dz<=(width+size*.71)^2 and not coreGround_["ground_"..key] then
                    local entry=request("ground",key,0,0,0,x,z)
                    entry.permanent=true
                    -- 不能在单格内部吃完所有yield；加载页预算也必须覆盖每一行基础面。
                    synchronous(entry,pause and function() pause(math.min(1,at/length)*.18) end)
                    coreGround_[entry.key]=entry
                    entries_[entry.key]=nil
                end
            end end
            -- 每80m让出加载协程，进度持续更新；此阶段不会降低列车行驶速度。
            if pause then pause(math.min(1,at/length)*.18) end
        end
        print("[WorldStream] 狂暴全线核心地表已就绪，行驶不依赖细节队列追赶")
    end
    lastS_=Route.Wrap(initialS or 0)
    -- 远景连续轨道很轻；同步保底避免出生时只看见几百米断头轨道。
    local step=option("TrackChunkLength",120)
    local farStage=stage("farRail")
    ranges(lastS_,option("ViewBehind",2800),option("ViewAhead",3000),step,function(i,a,b,ordinal,total)
        synchronous(request("farRail",i,a,b,30),farStage)
        if GameConfig.GameMode~="rage" and Mountain.IsActiveAt(b) then synchronous(request("mountainBackdrop",i,a,b,31),farStage) end
        farStage(ordinal/total)
    end)
    local nearStage=stage("nearRail")
    ranges(lastS_,option("InitialDetailBehind",240),option("InitialDetailAhead",240),step,function(i,a,b,ordinal,total)
        synchronous(request("nearRail",i,a,b,1),nearStage)
        nearStage(ordinal/total)
    end)
    local infraStage=stage("infrastructure")
    local initial=option("InitialInfrastructureRadius",150)
    ranges(lastS_,initial,initial,option("InfrastructureChunkLength",100),function(i,a,b,ordinal,total)
        synchronous(request("infrastructure",i,a,b,40),infraStage)
        infraStage(ordinal/total)
    end)
    -- 最多一个附近车站；不把五站/全线农田放回Start。
    local nearest=nil ---@type table|nil
    local distance=1000
    for _, st in ipairs(Route.GetStations()) do
        local d=math.abs(delta(lastS_,st.s))
        if d<distance then nearest,distance=st,d end
    end
    if nearest then
        synchronous(request("station",nearest.index,nearest.s,nearest.s,20),stage("station"))
        -- 初次站内展示需要街区而非空白背景；只同步当前这一站。
        synchronous(request("city",nearest.index,nearest.s,nearest.s,24),stage("city"))
    end
    local sceneryStage=stage("scenery")
    local sceneryInitial=option("InitialSceneryRadius",240)
    ranges(lastS_,sceneryInitial,sceneryInitial,option("SceneryChunkLength",240),function(i,a,b,ordinal,total)
        synchronous(request("scenery",i,a,b,55),sceneryStage)
        sceneryStage(ordinal/total)
    end)
    local vegetationStage=stage("vegetation")
    -- 首屏只同步近线80m小块和当前两层背景，不把全窗口挪回Start。
    ranges(lastS_,160,240,80,function(i,a,b,ordinal,total)
        synchronous(request("vegetation",i,a,b,14),vegetationStage)
        vegetationStage(ordinal/total*.6)
    end)
    for index,kind in ipairs({"woodland","forest"}) do
        ranges(lastS_,160,320,160,function(i,a,b)
            synchronous(request(kind,i,a,b,16+index),vegetationStage)
        end)
        vegetationStage(.6+index*.2)
    end
    local pos=Route.Sample(lastS_)
    local size=option("TerrainCellSize",160)
    local x,z=math.floor(pos.x/size),math.floor(pos.z/size)
    local terrainStage=stage("terrain")
    if Mountain.IsActiveAt(lastS_) then
        -- 山地先交付800m×800m邻域（5×5个160m cell），而非出生点单格平片。
        -- 不改3ms持续预算/半径；仍只在当前站位局部同步，进度回调可yield。
        local radius=2
        local total=(radius*2+1)^2
        local ordinal=0
        for ix=x-radius,x+radius do
            for iz=z-radius,z+radius do
                ordinal=ordinal+1
                synchronous(request("terrain",ix.."_"..iz,0,0,35,ix,iz),terrainStage)
                terrainStage(ordinal/total)
            end
        end
    else
        -- 同步贴近出生点的3×3，不再只有铁路脚下一格，草带无地表延迟。
        local ordinal=0
        for ix=x-1,x+1 do for iz=z-1,z+1 do
            ordinal=ordinal+1
            synchronous(request("terrain",ix.."_"..iz,0,0,13,ix,iz),terrainStage)
            terrainStage(ordinal/9)
        end end
    end
    refreshTargets(lastS_)
    if GameConfig.GameMode=="rage" then
        -- 首发视野先交付完整基础地面，不能让玩家开车后再等2400m圆形窗口补齐。
        local total=#groundQueue_
        for i,entry in ipairs(groundQueue_) do
            -- 首屏非核心基础面也逐行交还加载预算，ready仍只在完整Commit后发布。
            synchronous(entry,pause and function() pause(.97+.03*(i-1)/math.max(1,total)) end)
            if pause then pause(.97+.03*i/math.max(1,total)) end
        end
        groundQueue_={};groundQueueIndex_=1
    end
    refresh_=0
    startupMs_=(os.clock()-begin)*1000
    assert(generation==generation_,"[WorldStream] 加载已取消")
    if nearest then assert(WorldStream.IsStationReady(nearest.index),"[WorldStream] 当前站台未完整提交") end
    building_=false
    print(string.format("[WorldStream] 局部启动 %.3fs，线路 %.2fkm；不整线建枕木/农田",startupMs_/1000,Route.GetLength()/1000))
    return assert(root_)
end

---@param s number
---@param dt number
function WorldStream.Update(s,dt)
    if not root_ or building_ then return end
    frame_=frame_+1
    local begin=os.clock()
    local previousS=lastS_
    local nextS=Route.Wrap(s)
    velocity_=delta(previousS,nextS)/math.max(dt or .001,.001)
    if math.abs(velocity_)>1 then direction_=velocity_>=0 and 1 or -1 end
    refresh_=refresh_+math.max(0,dt or 0)
    -- 累计相对上次目标刷新的移动量（不是上一帧）。静止时包括队列已清空
    -- 均不重排；移动2m后按0.2s刷新，大跨度移动立即取消旧窗口任务。
    local moved=math.abs(delta(targetS_,nextS))
    if moved>60 or forceRefresh_ or (refresh_>=option("RefreshInterval",.20) and moved>=2) then
        refreshTargets(nextS)
        refresh_=0
        forceRefresh_=false
    end
    lastS_=nextS
    local highSpeed=GameConfig.GameMode=="rage"
    local baseBudgetMs=option(highSpeed and "HighSpeedFrameBudgetMs" or "FrameBudgetMs",highSpeed and 6 or 3)
    local baseSlices=option(highSpeed and "HighSpeedMaxTaskSlices" or "MaxTaskSlices",highSpeed and 64 or 32)
    -- 地图是设备端实时生成的：每帧预算固定时，车速一高，生成吞吐就跟不上前进速度，
    -- 表现为轨道/接触网/两侧植被一直掉在车后、慢慢冒出来。按实际车速把每帧预算
    -- 放大到最多 2.5 倍（有上限），停车/低速时回落到基线，避免无谓开销。
    local speedScale=math.min(1,math.abs(velocity_)/110.0) -- 110 m/s ≈ 396 km/h
    local budgetMs=baseBudgetMs*(1+speedScale*1.5)
    local budget=budgetMs/1000
    local deadline=begin+budget
    local maxSlices=math.floor(baseSlices*(1+speedScale))
    local slices=0
    -- 站台是运营必需物，不与无限新增的近轨/草/地形争队首。独立40%份额，
    -- 预计20秒内接近时提升到70%，仍给地面独立通道/轨道保留余量；
    -- 空闲份额归还普通队列；同帧轮转站任务，最近/临近到站者先取得一片。
    -- 与ground共享同一deadline/切片上限，不增加3ms配置，也不drain整站。
    local stationBegin=os.clock()
    local urgent=false
    for _,entry in ipairs(stationQueue_) do
        if entry.wanted and not entry.ready and math.abs(entry.first-nextS)/math.max(1,math.abs(velocity_))<20 then urgent=true;break end
    end
    local stationShare=urgent and .7 or .4
    local stationDeadline=stationBegin+math.max(0,deadline-stationBegin)*stationShare
    local stationLimit=math.max(1,math.floor(maxSlices*stationShare))
    local stationRound=0
    repeat
        local progressed=false
        for _,best in ipairs(stationQueue_) do
            if entries_[best.key]==best and best.wanted and not best.ready then
                if slices>0 and (os.clock()>=stationDeadline or slices>=stationLimit) then break end
                if not best.work then startEntry(best) end
                local work=assert(best.work)
                local start=os.clock()
                local ok,value=coroutine.resume(work)
                maxTaskMs_=math.max(maxTaskMs_,(os.clock()-start)*1000)
                slices=slices+1;stationSlices_=stationSlices_+1
                progressed=true
                if not ok then removeEntry(best);error("[WorldStream] 站台构建失败："..tostring(value)) end
                if coroutine.status(work)=="dead" then complete(best,value) end
            end
        end
        stationRound=stationRound+1
        if not progressed then break end
    until os.clock()>=stationDeadline or slices>=stationLimit or stationRound>=stationLimit
    local groundBegin=os.clock()
    local groundBudget=GameConfig.GameMode=="rage" and math.max(0,deadline-groundBegin)*.5 or 0
    local groundMaxSlices=slices+math.floor((maxSlices-slices)*.5)
    -- 基础地面拥有独立份额，不再被不断新增的近轨/设施任务永久挤出。
    while os.clock()-groundBegin<groundBudget and slices<groundMaxSlices do
        local best=groundQueue_[groundQueueIndex_]
        while best and (entries_[best.key]~=best or not best.wanted or best.ready) do
            groundQueueIndex_=groundQueueIndex_+1;best=groundQueue_[groundQueueIndex_]
        end
        if not best then break end
        if not best.work then startEntry(best) end
        local start=os.clock()
        local ok,value=coroutine.resume(assert(best.work))
        maxTaskMs_=math.max(maxTaskMs_,(os.clock()-start)*1000)
        slices=slices+1;groundSlices_=groundSlices_+1
        if not ok then removeEntry(best);error("[WorldStream] 基础地表构建失败："..tostring(value)) end
        if coroutine.status(assert(best.work))=="dead" then complete(best,value) end
    end
    while os.clock()<deadline and slices<maxSlices do
        local best=queue_[queueIndex_]
        while best and (entries_[best.key]~=best or not best.wanted or best.ready) do
            queueIndex_=queueIndex_+1
            best=queue_[queueIndex_]
        end
        if not best then
            if #queue_>0 then queue_={}; queueIndex_=1 end
            break
        end
        if not best.work then startEntry(best) end
        local start=os.clock()
        local ok,value=coroutine.resume(assert(best.work))
        maxTaskMs_=math.max(maxTaskMs_,(os.clock()-start)*1000)
        slices=slices+1
        if not ok then
            print("[WorldStream] 局部任务失败 "..best.key..": "..tostring(value))
            removeEntry(best)
            error("[WorldStream] 无法构建局部世界："..tostring(value))
        elseif coroutine.status(assert(best.work))=="dead" then complete(best,value) end
    end
    lastUpdateMs_=(os.clock()-begin)*1000
end

---@param initialS number|nil
---@param pause? fun(ratio?:number)
---@return Node|nil
function WorldStream.Reset(initialS,pause)
    local scene=scene_
    local s=initialS or lastS_
    if scene then return WorldStream.Build(scene,s,pause) end
    return nil
end
---@param index number
---@return boolean
function WorldStream.IsStationReady(index)
    local entry=entries_["station_"..index]
    if not entry or entry.generation~=generation_ or not entry.ready or not entry.shown
        or not entry.node or entry.node.parent~=root_ or not entry.node.enabled
        or not entry.platformMeshes or #entry.platformMeshes~=2
        or not entry.uploadedVertices or entry.uploadedVertices<=0 then return false end
    for _,mesh in ipairs(entry.platformMeshes) do
        if not mesh.enabledEffective or not mesh.node.enabled or mesh:GetNumVertices(0)<=0 then return false end
    end
    return true
end
---@param index number
function WorldStream.GetStationStatus(index)
    local entry=entries_["station_"..index]
    return {ready=WorldStream.IsStationReady(index),requested=entry~=nil,
        building=entry~=nil and entry.work~=nil,wanted=entry~=nil and entry.wanted,
        generation=generation_,frame=frame_,requestedFrame=entry and entry.requestedFrame,
        startedFrame=entry and entry.startedFrame,readyFrame=entry and entry.readyFrame,
        platformVertices=entry and entry.platformVertices or 0,uploadedVertices=entry and entry.uploadedVertices or 0}
end
function WorldStream.Shutdown()
    generation_=generation_+1
    building_=false
    for _, entry in pairs(entries_) do entry.work=nil;entry.ready=false;entry.platformMeshes=nil end
    StationYard.Shutdown() -- 先忘记lamp组件引用，再释放站根及取消中的半成品。
    Infrastructure.Shutdown()
    Terrain.Shutdown() -- 道路/景物也先清组件引用，所有几何仍由root统一释放。
    Station.Shutdown()
    if root_ then disposeNode(root_) end
    entries_={};coreGround_={}
    queue_={}; queueIndex_=1; targetS_=0
    groundQueue_={};groundQueueIndex_=1;velocity_=0;groundSlices_=0
    stationQueue_={};frame_=0;stationSlices_=0;direction_=1
    StreamGround.Clear()
    root_,scene_=nil,nil
    lastS_,refresh_,maxTaskMs_,lastUpdateMs_,generatedVertices_,disposedChunks_=0,0,0,0,0,0
    startupMs_,maxInitialTaskMs_=0,0
end
function WorldStream.GetStats()
    local stats={root=root_,loadedChunks=0,nearRailChunks=0,farRailChunks=0,infrastructureChunks=0,
        stationChunks=0,stationSlices=stationSlices_,frame=frame_,generation=generation_,building=building_,terrainChunks=0,groundChunks=0,permanentGroundChunks=0,groundSlices=groundSlices_,mountainBackdropChunks=0,mountainBackdropVertices=0,vegetationChunks=0,woodlandChunks=0,forestChunks=0,cityChunks=0,sceneryChunks=0,pendingTasks=0,
        maxTaskMs=maxTaskMs_,startupMs=startupMs_,maxInitialTaskMs=maxInitialTaskMs_,
        lastUpdateMs=lastUpdateMs_,generatedVertices=generatedVertices_,loadedVertices=0,
        shownVertices=0,hiddenVertices=0,nearRailMeshCount=0,farRailMeshCount=0,shownNearRailChunks=0,
        disposedChunks=disposedChunks_,routeLength=root_ and Route.GetLength() or 0,lastS=lastS_}
    local fields={nearRail="nearRailChunks",farRail="farRailChunks",infrastructure="infrastructureChunks",
        station="stationChunks",terrain="terrainChunks",ground="groundChunks",mountainBackdrop="mountainBackdropChunks",vegetation="vegetationChunks",woodland="woodlandChunks",forest="forestChunks",city="cityChunks",scenery="sceneryChunks"}
    for _, entry in pairs(entries_) do
        if entry.ready then
            stats.loadedChunks=stats.loadedChunks+1
            if entry.permanent then stats.permanentGroundChunks=stats.permanentGroundChunks+1 end
            stats.loadedVertices=stats.loadedVertices+entry.vertices
            if entry.shown then stats.shownVertices=stats.shownVertices+entry.vertices
            else stats.hiddenVertices=stats.hiddenVertices+entry.vertices end
            if entry.kind=="nearRail" then
                stats.nearRailMeshCount=stats.nearRailMeshCount+entry.meshes
                if entry.shown then stats.shownNearRailChunks=stats.shownNearRailChunks+1 end
            elseif entry.kind=="farRail" then stats.farRailMeshCount=stats.farRailMeshCount+entry.meshes end
            if entry.kind=="mountainBackdrop" then stats.mountainBackdropVertices=stats.mountainBackdropVertices+entry.vertices end
            local field=fields[entry.kind]
            if field then stats[field]=stats[field]+1 end
        else stats.pendingTasks=stats.pendingTasks+1 end
    end
    for _,entry in pairs(coreGround_) do
        stats.permanentGroundChunks=stats.permanentGroundChunks+1
        stats.groundChunks=stats.groundChunks+1
        stats.loadedChunks=stats.loadedChunks+1
        stats.loadedVertices=stats.loadedVertices+entry.vertices
        stats.shownVertices=stats.shownVertices+entry.vertices
    end
    return stats
end
return WorldStream
