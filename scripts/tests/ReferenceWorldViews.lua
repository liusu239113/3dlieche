-- 轻量生产实景验收，基于scaffold-3d-scene的Scene/相机生命周期。
-- -view=city|forest|bridge|corridor|corridor_driver|track_detail|platform，每次只Build一个目标。
-- -station=1..10 指定city/platform的真实站点，默认首站；后五站也走同一生产流式装配。
-- 全部镜头使用生产WorldStream，等可见窗口地表/植被完整后截图，不以单cell代替完整地表。
-- 不复制替代几何，不调整生产密度/地图配置。
-- 实拍用运行器-x 960 -y 540设置真实帧缓冲，不调用已禁用的graphics:SetMode。
local Modes=require "config.GameModes"
local Route=require "world.Route"
local Track=require "world.Track"
local RailNetwork=require "world.RailNetwork"
local Terrain=require "world.Terrain"
local Stream=require "world.WorldStream"
local Landscape=require "world.Landscape"
local Landmarks=require "world.Landmarks"
local Environment=require "world.Environment"
local Sky=require "world.Sky"
local Quality=require "config.VisualQuality"
local Config=require "config.GameConfig"
local Json=require "cjson"
---@type Scene|nil
local scene_=nil
---@type Node|nil
local cameraNode_=nil
---@type thread|nil
local work_=nil
local selected_="city"
local stationIndex_=1
local targetS_=0.0
local hour_=12.0
local viewWidth_,viewHeight_=960,540
local startedMs_,builtMs_=0,0
local clockReady_=false
local frames_,warmFrames_,renderFrames_,checks_=0,0,0,0
local built_,done_,discarded_,stopped_,viewportBound_=false,false,false,false,false
local ready_=false
---@type table[]
local critical_={}
local targetTheme_=""
local OUTPUT="/workspace/screenshots/reference_world_"
local originalMode_=Modes.GetId()
local function check(value,message)
    checks_=checks_+1;assert(value,"[ReferenceWorldViews] "..message)
end
-- GetSystemTime是静态tolua绑定，接收Time类表而不是time实例。
-- 与tests.RailPerformanceValidation的真实运行计时路径一致；LSP声明未区分类/实例。
local function systemMs() return Time:GetSystemTime() end
local function elapsed() return clockReady_ and (systemMs()-startedMs_)/1000 or 0 end
local function cleanup()
    if stopped_ then return end
    stopped_=true;work_=nil
    renderer:SetNumViewports(0)
    Environment.Destroy()
    Stream.Shutdown()
    if scene_ then scene_:Dispose();scene_=nil end
    cameraNode_=nil
    Modes.Apply(originalMode_)
end
local function guard(action)
    if done_ then return end
    local ok,err=xpcall(action,debug.traceback)
    if not ok then
        done_=true
        -- 计时初始化/读取本身失败时也能报告首错并退出，不在错误路径二次裸调用计时。
        local timed,seconds=pcall(elapsed)
        print("REFERENCE_WORLD_VIEW_FAIL view="..selected_.." elapsed="..(timed and tostring(seconds) or "unavailable").." "..tostring(err))
        pcall(function() log:Write(LOG_ERROR,tostring(err)) end)
        local cleaned,cleanupError=pcall(cleanup)
        if not cleaned then print("REFERENCE_WORLD_VIEW_CLEANUP_FAIL "..tostring(cleanupError)) end
        engine:Exit()
    end
end
local function chooseTarget()
    local station=assert(Route.GetStations()[stationIndex_],"验收站点索引超出当前线路")
    if selected_=="city" or selected_=="platform" then targetS_=station.s
    elseif selected_=="corridor" or selected_=="corridor_driver" then
        targetS_=assert(Route.GetStations()[2]).s-2800
    elseif selected_=="track_detail" then
        -- 扣件在真实道岔区有净空抑制；选择真实无岔块，避免验收镜头拍不到目标细节。
        local found=false
        for first=120,Route.GetLength()-240,120 do
            local clear=true
            for s=first,first+120,6 do
                if RailNetwork.GetSectionAt(s,0) or RailNetwork.GetSectionAt(s,1) then clear=false end
            end
            for _,cross in ipairs(RailNetwork.GetCrossovers()) do
                if first<cross.last+1 and first+120>cross.first-1 then clear=false end
            end
            for _,structure in ipairs(Route.GetStructureRanges()) do
                if first<structure.last and first+120>structure.first then clear=false end
            end
            if clear then targetS_=first+60;found=true;break end
        end
        check(found,"未找到真实无岔近轨扣件区间")
    elseif selected_=="forest" then
        -- st1+1400仍属urban且朝桥区，不能把出城走廊冒充林海验收。
        -- 选真实forest地理区，整段±960m避开站场、桥谷和隧道预留。
        local found=false
        for _,region in ipairs(Config.RouteRegions or {}) do
            if region.theme=="forest" and not found then
                for s=region.first+1120,region.last-1120,160 do
                    local clear=Landmarks.GetEnvironmentAt(s)=="forest"
                    for _,st in ipairs(Route.GetStations()) do
                        if math.abs(s-st.s)<2900 then clear=false;break end
                    end
                    for _,def in ipairs(Landmarks.GetDefinitions()) do
                        if s+1050>def.first and s-1050<def.last then clear=false;break end
                    end
                    if clear then targetS_=s;found=true;break end
                end
            end
        end
        check(found,"真实forest区域没有满足±960m工程/车站退让的验收窗口")
    elseif selected_=="bridge" then
        local bridge=nil ---@type RailwayLandmark|nil
        for _,definition in ipairs(Landmarks.GetDefinitions()) do
            if definition.kind=="bridge" then bridge=definition;break end
        end
        check(bridge~=nil,"生产线路没有桥梁")
        targetS_=assert(bridge).s
    else error("未知-view参数，仅支持city/forest/bridge/corridor/corridor_driver/track_detail/platform") end
end
local function aim()
    local node=assert(cameraNode_)
    if selected_=="city" then
        node.position=Route.SampleOffset(targetS_-90,148,9.5)
        node:LookAt(Route.SampleOffset(targetS_+210,185,18))
    elseif selected_=="platform" then
        node.position=Route.SampleOffset(targetS_-140,-4.6,3.1)
        node:LookAt(Route.SampleOffset(targetS_-45,-5.6,4.5))
    elseif selected_=="corridor" then
        node.position=Route.SampleOffset(targetS_-45,-16,20)
        node:LookAt(Route.SampleOffset(targetS_+220,0,3))
    elseif selected_=="corridor_driver" then
        node.position=Route.SampleOffset(targetS_,0,3.3)
        node:LookAt(Route.SampleOffset(targetS_+220,0,3.0))
    elseif selected_=="track_detail" then
        -- 真实近轨低机位，检验轨腰/轨顶/扣件接触；不替换几何或增加场景灯。
        node.position=Route.SampleOffset(targetS_-1.6,-1.75,.85)
        node:LookAt(Route.SampleOffset(targetS_+.6,-.65,.18))
    elseif selected_=="forest" then
        -- 22m眼高可同时检查近冠、中林及远林线，而非只看10m树冠内侧。
        node.position=Route.SampleOffset(targetS_-75,-22,22)
        node:LookAt(Route.SampleOffset(targetS_+260,35,13))
    else
        node.position=Route.SampleOffset(targetS_-170,-150,47)
        node:LookAt(Route.SampleOffset(targetS_+75,2.5,-7))
    end
end
local function lighting(scene,preset,bounds)
    -- 与main.CreateLighting/ApplyAtmosphere相同的已有生产日光参数，只有一组Zone。
    local group=scene:CreateChild("DayLighting")
    local zone=group:CreateComponent("Zone")
    zone.boundingBox=bounds;zone.ambientSource=AMBIENT_COLOR
    zone.ambientColor=Color(.34,.40,.48)
    zone.fogColor=preset.fogColor;zone.depthFogStart=preset.fogStart;zone.depthFogEnd=preset.fogEnd
    zone.tonemapMode=TONEMAP_MODE_ACES
    zone.fxaaEnabled=false;zone.vignetteEnabled=false;zone.autoExposureEnabled=false
    zone.bloomWeight=0;zone.ssaoIntensity=0;zone.ssrEnabled=false;zone.ssgiEnabled=false
    zone.motionBlurEnabled=false;zone.volumetricFogEnabled=false
    local sunNode=group:CreateChild("Sun")
    sunNode.direction=Vector3(.45,-1,.55)
    local sun=sunNode:CreateComponent("Light")
    sun.lightType=LIGHT_DIRECTIONAL;sun.color=preset.sunColor;sun.brightness=preset.sunBrightness
    sun.castShadows=preset.shadows;sun.specularIntensity=0
    Sky.Create(scene,preset)
    check(Environment.Init(scene,group,{quality=preset,skyNode=scene:GetChild("Sky"),hour=hour_,
        running=false,weather="clear",rain=false}),"生产日光环境初始化失败")
    print("REFERENCE_WORLD_LIGHTING "..Json.encode({hour=hour_,ambient={zone.ambientColor.r,zone.ambientColor.g,zone.ambientColor.b},
        sun=sun.brightness,depthEnable=tostring(zone.depthFogEnable),depthStart=zone.depthFogStart,depthEnd=zone.depthFogEnd,
        depthDensity=tostring(zone.depthFogDensity),heightEnable=tostring(zone.heightFogEnable),
        heightDensity=tostring(zone.heightFogDensity),height=tostring(zone.heightFogHeight),falloff=tostring(zone.heightFogFalloff),
        legacyDepthDensity=tostring(zone.fogDensity),legacyHeight=tostring(zone.heightFog),legacyHeightLevel=tostring(zone.fogHeight),
        legacyHeightScale=tostring(zone.fogHeightScale)}))
end
local function criticalPlan()
    critical_={}
    local function add(key,kind) critical_[#critical_+1]={key=key,kind=kind} end
    local function window(kind,step,behind,ahead)
        local first=math.floor(math.max(0,targetS_-behind)/step)
        local last=math.ceil((math.min(Route.GetLength(),targetS_+ahead)-.000001)/step)-1
        for index=first,last do add(kind.."_"..index,kind) end
    end
    -- medium生产窗口，不新增任务、不扩半径；等指定块真正交付/启用。
    window("vegetation",80,400,640)
    window("woodland",160,560,800)
    window("forest",160,640,960)
    window("scenery",Config.WorldStream.SceneryChunkLength,720,720)
    window("nearRail",Config.WorldStream.TrackChunkLength,240,240)
    if Config.MountainTerrain and targetS_>(Config.MountainTerrain.First or 0) then
        window("mountainBackdrop",Config.WorldStream.TrackChunkLength,960,1440)
    end
    window("infrastructure",Config.WorldStream.InfrastructureChunkLength,320,320)
    local position=Route.Sample(targetS_)
    local size=Config.WorldStream.TerrainCellSize
    local cx,cz=math.floor(position.x/size),math.floor(position.z/size)
    -- 相机近区必须是连续真实地表，不能只等一格再让树浮在天空里。
    for x=cx-3,cx+3 do for z=cz-3,cz+3 do add("terrain_"..x.."_"..z,"terrain") end end
    local seen={}
    for _,entry in ipairs(critical_) do seen[entry.key]=true end
    for ds=400,1000,120 do
        for _,lateral in ipairs({-300,-150,0,150,300}) do
            local p=Route.SampleOffset(targetS_+ds,lateral,0)
            local key="terrain_"..math.floor(p.x/size).."_"..math.floor(p.z/size)
            if not seen[key] then add(key,"terrain");seen[key]=true end
        end
    end
    if selected_=="city" or selected_=="platform" then
        add("city_"..stationIndex_,"city");add("station_"..stationIndex_,"station")
    end
    targetTheme_=Landscape.ThemeAt(targetS_)
    if selected_=="forest" then check(targetTheme_=="forest","森林验收位置不属于真实forest地理区") end
end
local function viewStats() return Stream.GetStats() end
local function forestCoverage(root)
    -- 在已交付植被块内分层/分侧/分沿线bin检查，排除灌木、街树及隐藏半成品。
    local layers={near=0,middle=0,far=0}
    local bins={}
    for _,chunk in ipairs(root:GetChildren()) do
        if (chunk.name:match("^vegetation_") or chunk.name:match("^woodland_") or chunk.name:match("^forest_")) and chunk.enabled then
            for _,group in ipairs(chunk:GetComponents("StaticModelGroup",true)) do
                local name=group.node.name
                if name:find("Tree",1,true) or name:find("BeltLOD_",1,true) then
                    for index=0,group.numInstanceNodes-1 do
                        local pos=group:GetInstanceNode(index).worldPosition
                        local _,s=Route.DistanceTo(pos)
                        local lateral=(pos-Route.Sample(s)):DotProduct(Route.RightAt(s))
                        local distance=math.abs(lateral)
                        local layer=distance<85 and "near" or (distance<240 and "middle" or "far")
                        layers[layer]=layers[layer]+1
                        local bin=math.floor((s-targetS_+640)/160)
                        if bin>=0 and bin<8 then bins[layer..(lateral<0 and "L" or "R")..bin]=true end
                    end
                end
            end
        end
    end
    local covered={nearL=0,nearR=0,middleL=0,middleR=0,farL=0,farR=0}
    for key in pairs(covered) do for bin=0,7 do if bins[key..bin] then covered[key]=covered[key]+1 end end end
    local ready=layers.near>=32 and layers.middle>=32 and layers.far>=24
    for _,n in pairs(covered) do if n<6 then ready=false end end
    return ready,layers,covered
end
local function categoryReady()
    local stats=viewStats()
    local world=Terrain.GetLandscapeStats()
    local root=stats.root
    local evidence={required=#critical_,completed=0,missing={},layers={},coverage={}}
    if not root then return false,stats,world,evidence end
    for _,entry in ipairs(critical_) do
        local node=root:GetChild(entry.key)
        if node and node.enabled then evidence.completed=evidence.completed+1
        elseif #evidence.missing<12 then evidence.missing[#evidence.missing+1]=entry.key end
    end
    local ready=evidence.completed==evidence.required and stats.vegetationChunks>=8
        and stats.woodlandChunks>=6 and stats.forestChunks>=8
    ready=ready and stats.sceneryChunks>=6
    if selected_=="city" or selected_=="platform" then
        -- 前五站为密集平原城区，山城规划更疏；按指定站的真实交付统计检查，
        -- 不能用首站70栋门槛让已完成的33栋天池山城永远无法ready。
        local stationCityReady=false
        for _,city in ipairs(world.cities or {}) do
            if city.stationIndex==stationIndex_ and city.buildings>0 then stationCityReady=true end
        end
        ready=ready and stats.cityChunks>0 and stats.stationChunks>0 and stationCityReady
            and (stationIndex_>5 or world.loadedBuildings>=70)
    elseif selected_=="forest" then
        local covered,layers,bins=forestCoverage(root)
        evidence.layers,evidence.coverage=layers,bins
        ready=ready and covered
    elseif selected_=="bridge" then
        ready=ready and world.landmarks.loadedBridges>0 and world.landmarks.piers>0
    end
    return ready,stats,world,evidence
end
function Start()
    guard(function()
        startedMs_=systemMs();clockReady_=true
        -- llvmpipe验收期间不逐yield渲染半成品全轨；生产几何及构建切片不变。
        renderer:SetNumViewports(0)
        for _,arg in ipairs(GetArguments()) do
            selected_=arg:match("^%-view=(.+)$") or selected_
            local station=arg:match("^%-station=(.+)$")
            if station then
                local index=tonumber(station)
                check(index~=nil and index>=1 and index%1==0,"-station必须是正整数站点索引")
                stationIndex_=assert(math.tointeger(index))
            end
            local hour=arg:match("^%-hour=(.+)$")
            if hour then hour_=assert(tonumber(hour))%24 end
        end
        Modes.Apply("normal");Route.Build()
        -- GetDefinitions只解析生产桥隧，不生成第二份几何；Stream.Build内部自行Terrain.Init。
        chooseTarget()
        local preset=Quality.Get("medium")
        check(Config.WorldStream.FrameBudgetMs==3,"验收必须保持生产3ms持续流式预算")
        Terrain.SetQuality(preset);Stream.SetQuality(preset)
        scene_=Scene()
        local octree=scene_:CreateComponent("Octree")
        local bounds=BoundingBox()
        for _,point in ipairs(Route.GetPoints()) do
            bounds:Merge(point.pos-Vector3(3000,1000,3000));bounds:Merge(point.pos+Vector3(3000,2000,3000))
        end
        octree:SetSize(bounds,8)
        renderer.hdrRendering=true;renderer.dynamicInstancing=true
        renderer.drawShadows=preset.shadows;renderer.specularLighting=false
        renderer.materialQuality=QUALITY_MEDIUM;renderer.shadowMapSize=preset.shadowMapSize
        lighting(scene_,preset,bounds)
        cameraNode_=scene_:CreateChild("ReferenceWorldCamera")
        local camera=cameraNode_:CreateComponent("Camera")
        camera.nearClip=.12;camera.farClip=preset.farClip;camera.fov=58
        camera.lodBias=preset.lodBias;camera.viewMask=7
        aim();Environment.Update(0,cameraNode_.position)
        -- Camera保留在真实scene中，但Build完成前不交给Renderer。
        local owner=scene_
        work_=coroutine.create(function()
            Stream.Build(owner,targetS_,function() coroutine.yield() end)
        end)
        print(string.format("REFERENCE_WORLD_VIEW_BEGIN view=%s s=%.3f resolution=%dx%d quality=medium budgetMs=3 postFX=off directProductionAssembly=false worldStreamValidated=true",selected_,targetS_,graphics:GetWidth(),graphics:GetHeight()))
        SubscribeToEvent("Update","ReferenceWorldViewsUpdate")
        -- 完整场景在EndRendering仍可能积压GPU提交；到EndFrame再读回，
        -- 不扩大引擎等待上限、不减少生产实例或用截图替换真实画面。
        SubscribeToEvent("EndFrame","ReferenceWorldViewsCapture")
    end)
end
function ReferenceWorldViewsUpdate()
    guard(function()
        frames_=frames_+1
        -- 山区远端首次装配耗时单独计入总上限，不能把它吞进局部预热窗口。
        -- 不改变生产3ms预算、实例数或ready条件；首站原110秒上限保持。
        local totalLimit=stationIndex_>5 and 150 or 110
        check(elapsed()<totalLimit,"实景验收总壁钟上限，终止而非无限等待远景")
        if not built_ then
            -- 启动同步阶段也利用生产pause回调切片，每帧最多3ms，不用高预算暴力预热。
            local begin=os.clock()
            while work_ and os.clock()-begin<.003 do
                local work=work_
                local ok,result=coroutine.resume(work)
                check(ok,"生产Build协程失败 "..tostring(result))
                if coroutine.status(work)=="dead" then
                    work_=nil;built_=true;builtMs_=systemMs()
                    criticalPlan()
                    print(string.format("REFERENCE_WORLD_VIEW_BUILT view=%s elapsed=%.3f pending=%d viewport=off critical=%d theme=%s",selected_,elapsed(),viewStats().pendingTasks,#critical_,targetTheme_))
                end
            end
            return
        end
        Stream.Update(targetS_,1/30) -- 固定站位，保持生产常态预算，不多次Update冒充一帧。
        warmFrames_=warmFrames_+1
        if not viewportBound_ then
            -- 预热也无viewport；完成关键局部窗口后才开始真实渲染帧计数。
            if warmFrames_%15==0 or warmFrames_==1 then
                local isReady,stats,_,evidence=categoryReady();ready_=isReady
                if warmFrames_%120==0 or ready_ then
                    print("REFERENCE_WORLD_VIEW_PENDING "..Json.encode({view=selected_,frames=warmFrames_,
                        pending=stats.pendingTasks,ready=ready_,elapsed=elapsed(),vegetation=stats.vegetationChunks,
                        scenery=stats.sceneryChunks,terrain=stats.terrainChunks,critical=evidence,viewport="off"}))
                end
                if ready_ then
                    local camera=assert(assert(cameraNode_):GetComponent("Camera"))
                    renderer:SetNumViewports(1)
                    local viewport=Viewport:new(assert(scene_),camera)
                    viewWidth_=math.min(960,graphics:GetWidth());viewHeight_=math.min(540,graphics:GetHeight())
                    viewport:SetRect(IntRect(0,0,viewWidth_,viewHeight_))
                    renderer:SetViewport(0,viewport)
                    viewportBound_=true
                    print(string.format("REFERENCE_WORLD_VIEW_READY view=%s elapsed=%.3f warmupSeconds=%.3f pending=%d viewport=bound",selected_,elapsed(),(systemMs()-builtMs_)/1000,stats.pendingTasks))
                end
            end
            local warmupExpired=stationIndex_>5 and (systemMs()-builtMs_)/1000>60
                or stationIndex_<=5 and elapsed()>85
            if not viewportBound_ and warmupExpired then
                local _,stats,_,evidence=categoryReady()
                error("关键窗口在有界预热期限内仍未交付，不拍半成品 pending="..stats.pendingTasks.." evidence="..Json.encode(evidence))
            end
        end
    end)
end
function ReferenceWorldViewsCapture()
    guard(function()
        if not built_ or not ready_ or not viewportBound_ then return end
        renderFrames_=renderFrames_+1
        if renderFrames_<12 then return end
        local image=Image()
        local captureBegin=systemMs()
        local captured=graphics:TakeScreenShot(image)
        print(string.format("REFERENCE_WORLD_READBACK frame=%d success=%s captureMs=%d batches=%d primitives=%d",renderFrames_,tostring(captured),systemMs()-captureBegin,renderer.numBatches,renderer.numPrimitives))
        if not captured then
            image:Dispose();check(renderFrames_<36,"真实帧缓冲第12..36帧读回均失败（最多25次请求）")
            return
        end
        if not discarded_ then discarded_=true;image:Dispose();return end
        check(image.width==graphics:GetWidth() and image.height==graphics:GetHeight(),"读回尺寸不是实际帧缓冲")
        local width,height=viewWidth_,viewHeight_
        local suffix=(stationIndex_~=1 and (selected_=="city" or selected_=="platform")) and "_station"..stationIndex_ or ""
        local path=OUTPUT..selected_..suffix..".png"
        -- 只裁出真实渲染的viewport，不缩放像素或对截图做美化处理。
        local view=image:GetSubimage(IntRect(0,0,width,height))
        check(view~=nil,"真实viewport像素裁取失败")
        check(view:SavePNG(path),"PNG保存失败")
        view:Dispose();image:Dispose()
        local decoded=Image()
        check(decoded:Load(path),"截图PNG回读失败")
        check(decoded.width==width and decoded.height==height,"PNG回读尺寸不符")
        local low,high=1.0,0.0
        for y=1,8 do for x=1,12 do
            local color=decoded:GetPixel(math.floor(width*x/13),math.floor(height*y/9))
            local value=(color.r+color.g+color.b)/3
            low,high=math.min(low,value),math.max(high,value)
        end end
        decoded:Dispose();check(high-low>.06,"真实截图为空/纯色，不接受虚假画面证据")
        local isReady,stats,world,evidence=categoryReady();check(isReady,"读回时目标生产块不再就绪")
        print("REFERENCE_WORLD_VIEW_REAL_FRAME "..Json.encode({view=selected_,path=path,width=width,height=height,
            elapsed=elapsed(),pending=stats.pendingTasks,nearRail=stats.nearRailChunks,scenery=stats.sceneryChunks,
            targetS=targetS_,stationIndex=stationIndex_,theme=targetTheme_,critical=evidence,warmupFrames=warmFrames_,renderFrames=renderFrames_,
            localWindowOnly=true,fullWorldComplete=stats.pendingTasks==0,
            directProductionAssembly=false,worldStreamValidated=true,
            vegetation=stats.vegetationChunks,terrain=stats.terrainChunks,city=stats.cityChunks,
            buildings=world.loadedBuildings,trees=world.loadedTrees,piers=world.landmarks.piers,
            batches=renderer.numBatches,primitives=renderer.numPrimitives,checks=checks_,firstReadbackDiscarded=discarded_,
            budgetMs=3,saveIO=false,visualReviewRequired=true}))
        print("REFERENCE_WORLD_VIEW_CAPTURE_PASS view="..selected_)
        done_=true;cleanup();engine:Exit()
    end)
end
function Stop() cleanup() end
