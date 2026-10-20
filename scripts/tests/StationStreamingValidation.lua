-- CPU-only regression derived from scaffold-3d-scene Scene ownership and the
-- real Station/WorldMaterials triangle witnesses. No main, save, cloud or GLES.
-- Each HandleUpdate resumes one test frame: exactly ONE production Stream.Update
-- at the unchanged 3ms budget. Loading yields separately; no stationary queue drain.
-- .cli/UrhoXRuntime tests/StationStreamingValidation.lua -tapcode_dir=/workspace
--   -tool_mode -graphicsheadless -nosound -station-mode=normal|rage|all
local Modes=require "config.GameModes"
local Config=require "config.GameConfig"
local Route=require "world.Route"
local Stream=require "world.WorldStream"
local Reference=require "world.ReferenceStation"
local Night=require "world.NightLighting"
local Ground=require "world.StreamGround"
---@type Scene?
local scene_=nil
---@type thread?
local work_=nil
local checks_,frames_,calls_,loadingFrames_,cases_=0,0,0,0,0
local maxUpdateMs_,maxSliceMs_,refreshPeakMs_=0.0,0.0,0.0
local mode_="all"
local finished_=false
local loading_=false
local updates_={} ---@type number[]
local originalBudget_=Config.WorldStream.HighSpeedFrameBudgetMs
local originalMode_=Modes.GetId()
local originalGroundBuild_=Ground.BuildCell
local coreLoadCells_,viewLoadCells_=0,0
for _,arg in ipairs(GetArguments()) do
    local selected=arg:match("^%-station%-mode=(.+)$")
    if selected then mode_=selected end
end
local function check(value,message)
    checks_=checks_+1
    assert(value,"[StationStreaming] "..message)
end
local function tick(s)
    check(not loading_,"stream update during loading")
    local begin=os.clock()
    Stream.Update(s,1/30)
    local elapsed=(os.clock()-begin)*1000
    calls_=calls_+1
    updates_[#updates_+1]=elapsed
    maxUpdateMs_=math.max(maxUpdateMs_,elapsed)
    local stats=Stream.GetStats()
    maxSliceMs_=math.max(maxSliceMs_,stats.maxTaskMs)
    refreshPeakMs_=math.max(refreshPeakMs_,stats.lastUpdateMs)
    coroutine.yield()
end
-- Actual triangles must cover all THREE operational platforms at their top
-- height. A root node, platform counter, design box or uncommitted CPU data is
-- insufficient. FillModel additionally reads the committed drawing buffers.
local function witness(index,label)
    local status=Stream.GetStationStatus(index)
    check(status.ready and Stream.IsStationReady(index),label.." station not ready")
    local root=assert(Stream.GetStats().root)
    local owner=assert(root:GetChild("station_"..index))
    local st=assert(Route.GetStations()[index])
    local triangleCount,vertexCount=0,0
    local meshes={} ---@type CustomGeometry[]
    for _,name in ipairs({"WeatheredConcretePlatforms","UpPlatformConcrete"}) do
        local node=assert(owner:GetChild(name,true))
        local mesh=assert(node:GetComponent("CustomGeometry"))
        check(node.enabled and mesh.enabledEffective,label.." disabled platform "..name)
        check(mesh:GetNumVertices(0)>0,label.." empty platform "..name)
        local model=Model()
        check(mesh:FillModel(model),label.." no committed drawing buffer "..name)
        local geometry=assert(model:GetGeometry(0,0))
        local buffer=assert(geometry:GetVertexBuffer(0))
        check(geometry.vertexCount==mesh:GetNumVertices(0) and buffer.vertexCount>=geometry.vertexCount,
            label.." incomplete buffer "..name)
        vertexCount=vertexCount+geometry.vertexCount
        model:Dispose()
        meshes[#meshes+1]=mesh
    end
    for _,lateral in ipairs({-16.4,-5.4,10.4}) do
        for _,ds in ipairs({Route.PlatformStart+5,(Route.PlatformStart+Route.PlatformEnd)/2,Route.PlatformEnd-5}) do
            local target=Route.SampleOffset(st.s+ds,lateral,1.44)
            local found=false
            for _,mesh in ipairs(meshes) do
                local transform=mesh.node.worldTransform
                for i=0,mesh:GetNumVertices(0)-3,3 do
                    local a=transform*mesh:GetVertex(0,i).position
                    local b=transform*mesh:GetVertex(0,i+1).position
                    local c=transform*mesh:GetVertex(0,i+2).position
                    local cross=(b-a):CrossProduct(c-a)
                    if cross.y>.00001 then
                        local det=(b.x-a.x)*(c.z-a.z)-(b.z-a.z)*(c.x-a.x)
                        local px,pz=target.x-a.x,target.z-a.z
                        local u=(px*(c.z-a.z)-pz*(c.x-a.x))/det
                        local v=((b.x-a.x)*pz-(b.z-a.z)*px)/det
                        if u>=-.0001 and v>=-.0001 and u+v<=1.0001
                            and math.abs(a.y+u*(b.y-a.y)+v*(c.y-a.y)-target.y)<.025 then
                            found=true;triangleCount=triangleCount+1
                        end
                    end
                end
            end
            check(found,label.." no real platform top lateral="..lateral.." ds="..ds)
        end
    end
    check(status.platformVertices==vertexCount and status.uploadedVertices==vertexCount,
        label.." cached commit evidence disagrees with actual buffers")
    cases_=cases_+1
    print(string.format("STATION_GEOMETRY_PASS mode=%s case=%s index=%d vertices=%d topHits=%d request=%s start=%s ready=%s frame=%d",
        Modes.GetId(),label,index,vertexCount,triangleCount,tostring(status.requestedFrame),
        tostring(status.startedFrame),tostring(status.readyFrame),status.frame))
end
local function loadingPause()
    loadingFrames_=loadingFrames_+1
    coroutine.yield()
end
-- 包装真实BuildCell，只观察其每次内部pause是否传到了生产加载页。
-- 没有伪造几何/ready、没有多次Stream.Update，也不降低全线常驻覆盖。
Ground.BuildCell=function(owner,x,z,size,pause,core)
    if not loading_ then return originalGroundBuild_(owner,x,z,size,pause,core) end
    local rows=0
    local vertices=originalGroundBuild_(owner,x,z,size,function()
        local before=loadingFrames_
        if pause then pause() end
        check(loadingFrames_>before,"single ground cell swallowed loading yield core="..tostring(core))
        rows=rows+1
    end,core)
    check(rows>1 and vertices>0,"loading ground cell did not build real multi-row mesh")
    if core then coreLoadCells_=coreLoadCells_+1 else viewLoadCells_=viewLoadCells_+1 end
    return vertices
end
local function buildAt(s,label,reset)
    loading_=true
    local before=loadingFrames_
    local firstEngineFrame=frames_
    local begin=os.clock()
    if reset then check(Stream.Reset(s,loadingPause)~=nil,label.." reset failed")
    else Stream.Build(assert(scene_),s,loadingPause) end
    loading_=false
    local stats=Stream.GetStats()
    print(string.format("STATION_LOADING_BOUNDARY mode=%s case=%s frames=%d yields=%d cpuMs=%.3f maxSliceMs=%.3f stations=%d pending=%d coreGround=%d",
        Modes.GetId(),label,frames_-firstEngineFrame,loadingFrames_-before,(os.clock()-begin)*1000,stats.maxInitialTaskMs,
        stats.stationChunks,stats.pendingTasks,stats.permanentGroundChunks))
    check(not stats.building,label.." loading transaction remains open")
    local roots=0
    for _,node in ipairs(assert(scene_):GetChildren()) do if node.name=="WorldStream" then roots=roots+1 end end
    check(roots==1,label.." duplicate stream root after reset")
end
-- Moving on EVERY frame, including after unload/re-entry. The ready boundary is
-- measured before approach, not inferred from having driven into an empty root.
local function approach(index,startS,kmh,label)
    local st=assert(Route.GetStations()[index])
    local sign=st.s>=startS and 1 or -1
    local speed=kmh/3.6
    local distance=math.abs(st.s-startS)
    local count=math.floor((distance-10)/(speed/30))
    local firstReady=nil ---@type integer?
    local firstDistance=0.0
    local approachStationSlices=Stream.GetStats().stationSlices
    local approachGroundSlices=Stream.GetStats().groundSlices
    local startFrame=Stream.GetStats().frame
    for frame=1,count do
        local s=startS+sign*speed*frame/30
        tick(s)
        if not firstReady and Stream.IsStationReady(index) then
            firstReady=frame;firstDistance=math.abs(st.s-s)
            witness(index,label.."_before_approach")
        end
        -- Actual station must be ready before entering its platform extent.
        if math.abs(st.s-s)<=math.max(math.abs(Route.PlatformStart),math.abs(Route.PlatformEnd))+80 then
            check(Stream.IsStationReady(index),label.." reached platform before commit")
        end
    end
    check(firstReady~=nil,label.." starved while continuously moving")
    witness(index,label.."_arrival")
    print(string.format("STATION_APPROACH_PASS mode=%s case=%s kmh=%.0f frames=%d firstReadyFrame=%d startFrame=%d distanceAtReady=%.3f stationSlices=%d groundSlices=%d noDrain=true updatesPerFrame=1 budgetMs=3",
        Modes.GetId(),label,kmh,count,assert(firstReady),startFrame,firstDistance,
        Stream.GetStats().stationSlices-approachStationSlices,Stream.GetStats().groundSlices-approachGroundSlices))
end
local function noOldRegistration(index,label)
    check(not Stream.GetStationStatus(index).requested,label.." old station key survives unload")
    check(Reference.GetStats(index)==nil,label.." old reference station registration survives")
    for _,site in ipairs(Night.GetSites()) do
        check(site.owner~="station:"..index,label.." cancelled lamp owner survives")
    end
end
local function modeRun(mode)
    Stream.Shutdown()
    if scene_ then scene_:Dispose() end
    Modes.Apply(mode);Route.Build()
    -- Rage normally has 6ms; this regression deliberately uses the ORIGINAL
    -- normal 3ms limit for BOTH modes, not an enlarged high-speed allowance.
    check(Config.WorldStream.FrameBudgetMs==3,"production normal budget changed")
    Config.WorldStream.HighSpeedFrameBudgetMs=3
    scene_=Scene();scene_:CreateComponent("Octree")
    local first=assert(Route.GetStations()[1])
    local second=assert(Route.GetStations()[2])
    local far=assert(Route.GetStations()[#Route.GetStations()-1])
    buildAt(first.s+1,"initial",false)
    witness(1,"initial_current_station")
    check(Stream.GetStats().stationChunks==1,"startup synchronously built more than current station")
    check(Stream.GetStationStatus(2).requested,"next station not prefetched at departure")
    check(not Stream.IsStationReady(2),"next station unexpectedly synchronously built")
    local core=Stream.GetStats().permanentGroundChunks
    if mode=="rage" then check(core>1000,"rage permanent ground removed") end
    -- Start at the production forward-view boundary. At 1223km/h rage gives
    -- only 15 seconds while near-rail/scenery/ground targets continually churn.
    -- Real departure prefetch starts even earlier, at the previous station.
    approach(2,second.s-(mode=="rage" and Config.WorldStream.RageViewAhead or 2200),
        mode=="rage" and 1223 or 350,"forward_contention")
    if mode=="rage" then
        check(Stream.GetStats().permanentGroundChunks==core,"station scheduling evicted permanent ground")
        check(Stream.GetStats().groundSlices>0,"rage independent ground channel starved")
    end
    -- Far teleport starts a real station task without pre-drain. Leave while it
    -- is suspended; both partial node and side-effect registries must be gone.
    tick(far.s-900)
    local partial=Stream.GetStationStatus(far.index)
    check(partial.building and not partial.ready,"far jump did not start hidden partial station")
    local partialOwner=assert(assert(Stream.GetStats().root):GetChild("station_"..far.index))
    for _,mesh in ipairs(partialOwner:GetComponents("CustomGeometry",true)) do
        check(not mesh.enabledEffective,"unfinished station leaked enabled geometry")
    end
    noOldRegistration(2,"unload_second")
    tick(first.s+1)
    noOldRegistration(far.index,"cancel_far_jump")
    -- Re-enter the previously completed second station without Reset. Departure
    -- already re-requests it; only the removed old entry must not occupy the key.
    approach(2,second.s+(mode=="rage" and Config.WorldStream.RageViewAhead or 2400),
        mode=="rage" and 936 or 320,"reverse_reentry")
    -- Reset while another station is unfinished; rebuild the current station
    -- through the production loading callback, not runtime budget draining.
    tick(far.s-900)
    check(Stream.GetStationStatus(far.index).building,"missing suspended task before reset")
    buildAt(first.s+1,"reset_during_station_build",true)
    witness(1,"reset_current_station")
    noOldRegistration(far.index,"reset_cancelled_far")
    buildAt(first.s+1,"repeat_reset_same_key",true)
    witness(1,"repeat_reset_station")
    -- Cancel an actual loading coroutine after station construction has begun,
    -- then intentionally resume it after a new world exists. Generation guard
    -- must reject before old locals can touch disposed nodes or the new key.
    loading_=true
    local abandoned=coroutine.create(function() Stream.Reset(first.s+1,loadingPause) end)
    local entered=false
    for _=1,5000 do
        local ok,message=coroutine.resume(abandoned)
        check(ok,"cancel setup failed: "..tostring(message))
        local root=Stream.GetStats().root
        if root and root:GetChild("station_1") then entered=true;break end
        check(coroutine.status(abandoned)~="dead","loading completed before cancellation boundary")
        coroutine.yield()
    end
    check(entered,"did not reach suspended initial station build")
    Stream.Shutdown()
    loading_=false
    check(Stream.GetStats().root==nil,"shutdown retains root")
    noOldRegistration(1,"shutdown_partial_initial")
    buildAt(first.s+1,"build_after_loading_cancel",false)
    witness(1,"post_cancel_station")
    local generation=Stream.GetStats().generation
    local ok,message=coroutine.resume(abandoned)
    check(not ok and tostring(message):find("已取消",1,true)~=nil,"abandoned loading coroutine resumed into new world")
    check(Stream.GetStats().generation==generation,"old loading callback mutated new generation")
    witness(1,"old_coroutine_rejected")
    local stats=Stream.GetStats()
    print(string.format("STATION_MODE_PASS mode=%s cases=%d frames=%d calls=%d stationSlices=%d groundSlices=%d permanentGround=%d budgetMs=3 saveIO=NONE GLES=NONE",
        mode,cases_,frames_,calls_,stats.stationSlices,stats.groundSlices,stats.permanentGroundChunks))
end
local function run()
    check(mode_=="all" or mode_=="normal" or mode_=="rage","invalid -station-mode")
    for _,mode in ipairs({"normal","rage"}) do if mode_=="all" or mode_==mode then modeRun(mode) end end
    table.sort(updates_)
    local p95=updates_[math.max(1,math.ceil(#updates_*.95))] or 0
    print(string.format("ALL_STATION_STREAMING_PASS checks=%d cases=%d engineFrames=%d calls=%d loadingYields=%d maxUpdateMs=%.3f p95UpdateMs=%.3f maxSliceMs=%.3f maxRecordedUpdateMs=%.3f budgetMs=3 updatesPerFrame=1 noDrain=true saveIO=NONE GLES=NONE",
        checks_,cases_,frames_,calls_,loadingFrames_,maxUpdateMs_,p95,maxSliceMs_,refreshPeakMs_))
end
local function cleanup()
    Stream.Shutdown()
    if scene_ then scene_:Dispose();scene_=nil end
    Config.WorldStream.HighSpeedFrameBudgetMs=originalBudget_
    Modes.Apply(originalMode_)
end
function Start()
    work_=coroutine.create(run)
    SubscribeToEvent("Update","HandleStationStreamingValidation")
end
function HandleStationStreamingValidation()
    if finished_ then return end
    frames_=frames_+1
    local begin=os.clock()
    local ok,message=true,nil
    local before=calls_
    -- Loading page follows main's bounded resume policy. Runtime updates NEVER
    -- use this loop: stop as soon as tick has made its single call for the frame.
    for _=1,64 do
        ok,message=coroutine.resume(assert(work_))
        if not ok or coroutine.status(assert(work_))=="dead" or calls_~=before
            or not loading_ or os.clock()-begin>=.006 then break end
    end
    check(calls_-before<=1,"more than one Stream.Update in one engine frame")
    if not ok or coroutine.status(assert(work_))=="dead" then
        finished_=true
        cleanup()
        if not ok then log:Write(LOG_ERROR,tostring(message)) end
        engine:Exit()
    end
end
function Stop() if not finished_ then finished_=true;cleanup() end end
