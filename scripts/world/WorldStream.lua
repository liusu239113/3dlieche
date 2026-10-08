-- 单机世界局部流式：解析全线常驻，渲染节点与任务拥有明确生命周期。
-- 近景120m完整轨道、32m设施任务；远景轨头/道床连续到farClip之外。
local Route = require "world.Route"
local Track = require "world.Track"
local Infrastructure = require "world.Infrastructure"
local Terrain = require "world.Terrain"
local Station = require "world.Station"
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
---@field shown boolean
---@type Scene|nil
local scene_ = nil
---@type Node|nil
local root_ = nil
---@type table<string, RailwayStreamEntry>
local entries_ = {}
local lastS_ = 0.0
local refresh_ = 0.0
local maxTaskMs_ = 0.0
local lastUpdateMs_ = 0.0
local generatedVertices_ = 0
local disposedChunks_ = 0
local startupMs_ = 0.0
local maxInitialTaskMs_ = 0.0
---@type table
local config_ = {}

local function option(name, fallback) return config_[name] or fallback end
local function delta(from,to)
    local length=Route.GetLength()
    return (to-from+length/2)%length-length/2
end

-- 半开弧长窗口拆成最多两个物理区间；最后短块与0接缝不会被整数模漏掉。
local function ranges(s,behind,ahead,step,visit)
    local length=Route.GetLength()
    if length<=0 then return end
    local total=math.min(length,behind+ahead)
    local first=Route.Wrap(s-behind)
    local remaining=total
    while remaining>0.000001 do
        local finish=math.min(length,first+remaining)
        for index=math.floor(first/step),math.ceil((finish-0.000001)/step)-1 do
            local start=index*step
            visit(index,start,math.min(start+step,length))
        end
        remaining=remaining-(finish-first)
        first=0
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
    entry.work=nil -- 先取消协程，不能让旧任务再访问已Dispose对象。
    if entry.node then disposeNode(entry.node); entry.node=nil end
    if entry.kind=="terrain" then Terrain.ForgetCell(entry.x,entry.z) end
    if entry.kind=="station" then Station.Forget(entry.index) end
    if entry.kind=="city" then Terrain.ForgetStation(entry.index) end
    entries_[entry.key]=nil
    disposedChunks_=disposedChunks_+1
end
local function request(kind,index,first,last,priority,x,z)
    local key=kind.."_"..index
    local entry=entries_[key]
    if not entry then
        entry={key=key,kind=kind,index=index,first=first or 0,last=last or 0,
            x=x or 0,z=z or 0,priority=priority,wanted=true,ready=false,node=nil,work=nil,vertices=0,shown=false}
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
    elseif entry.kind=="infrastructure" then
        Infrastructure.BuildChunk(node,entry.first,entry.last,pause)
    elseif entry.kind=="vegetation" then
        Terrain.BuildTrees(node,entry.first,entry.last,pause)
    elseif entry.kind=="terrain" then
        Terrain.BuildCell(node,entry.x,entry.z,option("TerrainCellSize",160),pause)
    elseif entry.kind=="station" then
        local st=Route.GetStations()[entry.index]
        if st then Station.BuildOne(node,st,pause) end
    elseif entry.kind=="city" then
        local st=Route.GetStations()[entry.index]
        if st then Terrain.BuildCity(node,st,pause) end
    end
    return countVertices(node)
end
local function startEntry(entry)
    local owner=assert(root_)
    entry.node=owner:CreateChild(entry.key,LOCAL)
    entry.node:SetEnabledRecursive(false)
    entry.work=coroutine.create(function()
        return buildEntry(entry,function()
            -- 新子节点不能假定继承父enabled；每次yield前隐藏新生成的子树。
            if entry.node then entry.node:SetEnabledRecursive(false) end
            coroutine.yield()
        end)
    end)
end
local function show(entry,visible)
    if entry.node and entry.shown~=visible then
        entry.node:SetEnabledRecursive(visible)
        entry.shown=visible
    end
end
local function complete(entry,vertices)
    entry.work=nil
    entry.ready=true
    entry.vertices=vertices or 0
    generatedVertices_=generatedVertices_+entry.vertices
    show(entry,true)
    if entry.kind=="nearRail" then
        local far=entries_["farRail_"..entry.index]
        if far then show(far,false) end
    elseif entry.kind=="farRail" then
        local near=entries_["nearRail_"..entry.index]
        if near and near.ready then show(entry,false) end
    end
end
local function synchronous(entry)
    local owner=assert(root_)
    entry.node=owner:CreateChild(entry.key,LOCAL)
    local begin=os.clock()
    local vertices=buildEntry(entry,nil)
    maxInitialTaskMs_=math.max(maxInitialTaskMs_,(os.clock()-begin)*1000)
    complete(entry,vertices)
end

local function refreshTargets(s)
    local begin=os.clock()
    local margin=option("UnloadMargin",720)
    local pos=Route.Sample(s)
    for _, entry in pairs(entries_) do entry.wanted=false end
    local railStep=option("TrackChunkLength",120)
    ranges(s,option("ViewBehind",2800),option("ViewAhead",3000),railStep,function(i,a,b)
        request("farRail",i,a,b,30+math.abs(delta(s,(a+b)/2))/100)
    end)
    ranges(s,option("DetailBehind",600),option("DetailAhead",960),railStep,function(i,a,b)
        request("nearRail",i,a,b,1+math.abs(delta(s,(a+b)/2))/100)
    end)
    ranges(s,option("InfrastructureBehind",1100),option("InfrastructureAhead",1500),
        option("InfrastructureChunkLength",32),function(i,a,b)
            request("infrastructure",i,a,b,40+math.abs(delta(s,(a+b)/2))/100)
        end)
    ranges(s,option("VegetationRadius",360)+160,option("VegetationRadius",360)+160,160,function(i,a,b)
        request("vegetation",i,a,b,75+math.abs(delta(s,(a+b)/2))/100)
    end)
    for _, st in ipairs(Route.GetStations()) do
        local distance=math.abs(delta(s,st.s))
        if distance<option("StationRadius",2800) then
            request("station",st.index,st.s,st.s,20+distance/300)
            if distance<option("TerrainRadius",1120)+300 then
                request("city",st.index,st.s,st.s,80+distance/100)
            end
        end
    end
    local size=option("TerrainCellSize",160)
    local radius=option("TerrainRadius",1120)
    local extent=math.ceil(radius/size)
    local cx,cz=math.floor(pos.x/size),math.floor(pos.z/size)
    for x=cx-extent,cx+extent do
        for z=cz-extent,cz+extent do
            local dx,dz=(x+.5)*size-pos.x,(z+.5)*size-pos.z
            local distance=math.sqrt(dx*dx+dz*dz)
            if distance<radius+size*.71 then
                request("terrain",x.."_"..z,0,0,85+distance/80,x,z)
            end
        end
    end
    -- 滞回只保留已启动/完成块，尚未建的无效排队任务立即取消。
    local remove={}
    for _, entry in pairs(entries_) do
        if not entry.wanted then
            local keep=false
            if entry.ready or entry.work then
                if entry.kind=="terrain" then
                    local dx,dz=(entry.x+.5)*size-pos.x,(entry.z+.5)*size-pos.z
                    keep=dx*dx+dz*dz<(radius+margin+size)^2
                else
                    local distance=delta(s,(entry.first+entry.last)/2)
                    local half=(entry.last-entry.first)/2
                    local behind,ahead=option("ViewBehind",2800),option("ViewAhead",3000)
                    if entry.kind=="nearRail" then behind,ahead=option("DetailBehind",600),option("DetailAhead",960) end
                    if entry.kind=="infrastructure" then behind,ahead=option("InfrastructureBehind",1100),option("InfrastructureAhead",1500) end
                    if entry.kind=="station" then behind,ahead=option("StationRadius",2800),option("StationRadius",2800) end
                    if entry.kind=="city" then behind,ahead=radius+300,radius+300 end
                    if entry.kind=="vegetation" then behind,ahead=option("VegetationRadius",360)+160,option("VegetationRadius",360)+160 end
                    keep=distance>=-behind-margin-half and distance<=ahead+margin+half
                end
            end
            if not keep then remove[#remove+1]=entry end
        end
    end
    for _, entry in ipairs(remove) do removeEntry(entry) end
    -- 远景只在完整近景ready时隐藏，升级/卸载任何一帧都没有空轨道。
    for _, entry in pairs(entries_) do
        if entry.kind=="farRail" and entry.ready and entry.node then
            local near=entries_["nearRail_"..entry.index]
            show(entry,not (near and near.ready))
        end
    end
    lastUpdateMs_=(os.clock()-begin)*1000
end

---@param scene Scene
---@param initialS number|nil
---@return Node
function WorldStream.Build(scene,initialS)
    WorldStream.Shutdown()
    local begin=os.clock()
    scene_=scene
    config_=GameConfig.WorldStream or {}
    if Route.GetLength()<=0 then Route.Build() end
    assert(Route.GetLength()>0,"[WorldStream] 无有效解析线路")
    root_=scene:CreateChild("WorldStream",LOCAL)
    Terrain.Init(); Station.Init(); Track.Init(); Infrastructure.Init()
    Terrain.BuildGround(root_)
    lastS_=Route.Wrap(initialS or 0)
    -- 远景连续轨道很轻；同步保底避免出生时只看见几百米断头轨道。
    local step=option("TrackChunkLength",120)
    ranges(lastS_,option("ViewBehind",2800),option("ViewAhead",3000),step,function(i,a,b)
        synchronous(request("farRail",i,a,b,30))
    end)
    ranges(lastS_,option("InitialDetailBehind",240),option("InitialDetailAhead",240),step,function(i,a,b)
        synchronous(request("nearRail",i,a,b,1))
    end)
    local initial=option("InitialInfrastructureRadius",96)
    ranges(lastS_,initial,initial,option("InfrastructureChunkLength",32),function(i,a,b)
        synchronous(request("infrastructure",i,a,b,40))
    end)
    -- 最多一个附近车站；不把五站/全线农田放回Start。
    local nearest=nil ---@type table|nil
    local distance=1000
    for _, st in ipairs(Route.GetStations()) do
        local d=math.abs(delta(lastS_,st.s))
        if d<distance then nearest,distance=st,d end
    end
    if nearest then synchronous(request("station",nearest.index,nearest.s,nearest.s,20)) end
    local pos=Route.Sample(lastS_)
    local size=option("TerrainCellSize",160)
    local x,z=math.floor(pos.x/size),math.floor(pos.z/size)
    synchronous(request("terrain",x.."_"..z,0,0,85,x,z))
    refreshTargets(lastS_)
    refresh_=0
    startupMs_=(os.clock()-begin)*1000
    print(string.format("[WorldStream] 局部启动 %.3fs，线路 %.2fkm；不整线建枕木/农田",startupMs_/1000,Route.GetLength()/1000))
    return assert(root_)
end

---@param s number
---@param dt number
function WorldStream.Update(s,dt)
    if not root_ then return end
    local begin=os.clock()
    local nextS=Route.Wrap(s)
    refresh_=refresh_+math.max(0,dt or 0)
    if refresh_>=option("RefreshInterval",.20) or math.abs(delta(lastS_,nextS))>60 then
        refreshTargets(nextS)
        refresh_=0
    end
    lastS_=nextS
    local budget=option("FrameBudgetMs",3)/1000
    local slices=0
    while os.clock()-begin<budget and slices<option("MaxTaskSlices",32) do
        local best=nil ---@type RailwayStreamEntry|nil
        for _, entry in pairs(entries_) do
            if entry.wanted and not entry.ready and (not best or entry.priority<best.priority
                or (entry.priority==best.priority and entry.key<best.key)) then best=entry end
        end
        if not best then break end
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
---@return Node|nil
function WorldStream.Reset(initialS)
    local scene=scene_
    local s=initialS or lastS_
    if scene then return WorldStream.Build(scene,s) end
    return nil
end
function WorldStream.Shutdown()
    for _, entry in pairs(entries_) do entry.work=nil end
    if root_ then disposeNode(root_) end
    entries_={}
    root_,scene_=nil,nil
    Terrain.Shutdown(); Station.Shutdown()
    lastS_,refresh_,maxTaskMs_,lastUpdateMs_,generatedVertices_,disposedChunks_=0,0,0,0,0,0
    startupMs_,maxInitialTaskMs_=0,0
end
function WorldStream.GetStats()
    local stats={root=root_,loadedChunks=0,nearRailChunks=0,farRailChunks=0,infrastructureChunks=0,
        stationChunks=0,terrainChunks=0,vegetationChunks=0,cityChunks=0,pendingTasks=0,
        maxTaskMs=maxTaskMs_,startupMs=startupMs_,maxInitialTaskMs=maxInitialTaskMs_,
        lastUpdateMs=lastUpdateMs_,generatedVertices=generatedVertices_,loadedVertices=0,
        disposedChunks=disposedChunks_,routeLength=root_ and Route.GetLength() or 0,lastS=lastS_}
    local fields={nearRail="nearRailChunks",farRail="farRailChunks",infrastructure="infrastructureChunks",
        station="stationChunks",terrain="terrainChunks",vegetation="vegetationChunks",city="cityChunks"}
    for _, entry in pairs(entries_) do
        if entry.ready then
            stats.loadedChunks=stats.loadedChunks+1
            stats.loadedVertices=stats.loadedVertices+entry.vertices
            local field=fields[entry.kind]
            if field then stats[field]=stats[field]+1 end
        else stats.pendingTasks=stats.pendingTasks+1 end
    end
    return stats
end
return WorldStream
