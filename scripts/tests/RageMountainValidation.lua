-- 真实引擎隔离验收：生产Route/Terrain/Landmarks/WorldStream，不加载Game/Save/cloud。
-- 基于scaffold-3d-scene与既有ReliefVisualValidation；默认CPU/真实网格，-mountain-visual真帧截图。
local Modes=require "config.GameModes"
local Config=require "config.GameConfig"
local Route=require "world.Route"
local Terrain=require "world.Terrain"
local Landmarks=require "world.Landmarks"
local Quality=require "config.VisualQuality"
local Validation={}
---@type Scene?
local scene_=nil
---@type Node?
local camera_=nil
local visual_,failed_,warm_,streamOnly_=false,false,false,false
local selectedCase_=0
local checks_,age_,caseIndex_,captured_=0,0,1,false
local cases_={}
local evidence_={}
local function check(value,message) checks_=checks_+1;assert(value,"[RageMountain] "..message) end
local function near(a,b,tolerance,message) check(math.abs(a-b)<tolerance,message) end
for _,argument in ipairs(GetArguments()) do
    if argument=="-mountain-visual" then visual_=true end
    if argument=="-mountain-stream-only" then streamOnly_=true end
    local index=argument:match("^%-mountain%-case=(%d+)$")
    if index then selectedCase_=tonumber(index) or 0 end
end
local function guard(fn)
    local ok,message=xpcall(fn,debug.traceback)
    if not ok then failed_=true;log:Write(LOG_ERROR,tostring(message));engine:Exit() end
end
function Validation.RunPlan()
    Modes.Apply("normal");Route.Build()
    local original={}
    for s=0,Route.GetLength(),137 do original[#original+1]={s=s,pos=Route.Sample(s)} end
    local normalLength=Route.GetLength()
    local originalSegments=Config.RouteSegments
    Modes.Apply("rage");Route.Build()
    local length=Route.GetLength()
    check(length>100000 and length<140000,"新线不是100..140km")
    check(Config.RouteId=="rage_mountain_corridor_v2","地图独立routeId缺失")
    local positive,negative,maxGrade,minY,maxY=0,0,0,math.huge,-math.huge
    for s=0,length,37 do
        local p,t=Route.Sample(s)
        local grade=Route.GetGrade(s)
        near(p.y,Route.HeightAt(s),.001,"HeightAt与Sample不同源")
        near(t:Length(),1,.00001,"坡道切线不是单位向量")
        near(t.y/math.sqrt(t.x*t.x+t.z*t.z),grade,.00001,"切线丢失纵坡")
        if s>2 and s<length-2 then near((Route.HeightAt(s+1)-Route.HeightAt(s-1))*.5,grade,.0002,"高程导数不等于纵坡") end
        near(Route.SampleOffset(s,7,2).y,p.y+2,.001,"Offset未沿同一高程")
        maxGrade=math.max(maxGrade,math.abs(grade));minY=math.min(minY,p.y);maxY=math.max(maxY,p.y)
        if grade>.01 then positive=positive+1 elseif grade<-.01 then negative=negative+1 end
    end
    check(maxY>1100 and minY==0 and positive>600 and negative>250,"缺真实爬坡/落坡")
    check(maxGrade<=.045001,"坡度超过45‰")
    local heights={0,260,580,990,840}
    for i,station in ipairs(Route.GetStations()) do
        for offset=-1600,1000,20 do
            near(Route.GetGrade(station.s+offset),0,1e-12,"站场/咽喉不水平")
            near(Route.GetHeight(station.s+offset),heights[i],.001,"站场不是同一绝对基高")
        end
    end
    local curves,turn=0,0
    for _,seg in ipairs(Route.GetSegments()) do if seg.type=="arc" then curves=curves+1;turn=turn+math.abs(seg.angle or 0) end end
    check(curves>=16 and turn>=2300,"山地展线转弯数量/总角不足")
    Terrain.Init()
    local bridges,tunnels=0,0
    for _,def in ipairs(Landmarks.GetDefinitions()) do
        if def.kind=="bridge" then
            bridges=bridges+1
            near(Route.GetGrade(def.first),0,1e-12,"桥梁入口不水平")
            near(Route.GetGrade(def.last),0,1e-12,"桥梁出口不水平")
            local p=Route.SampleOffset(def.s,def.lateral,0)
            check(Terrain.GetGroundHeight(p.x,p.z)<p.y-30,"高桥下面没有真实深谷")
            for _,edge in ipairs({def.first,def.last}) do
                for _,side in ipairs({-450,450}) do
                    local before=Route.SampleOffset(edge-.01,def.lateral+side,0)
                    local after=Route.SampleOffset(edge+.01,def.lateral+side,0)
                    near(Terrain.GetGroundHeight(before.x,before.z),Terrain.GetGroundHeight(after.x,after.z),.4,
                        "桥谷端部山坡高程硬断口")
                end
            end
        elseif def.kind=="tunnel" then tunnels=tunnels+1 end
    end
    check(bridges>=5 and tunnels>=4,"高桥/穿岭隧道不足")
    near(Config.WorldStream.FrameBudgetMs,3,1e-12,"扩大了WorldStream预算")
    print("RAGE_MOUNTAIN_PLAN "..require("cjson").encode({length=length,maxY=maxY,minY=minY,maxGrade=maxGrade,
        uphillSamples=positive,downhillSamples=negative,curves=curves,totalTurn=turn,bridges=bridges,tunnels=tunnels,checks=checks_}))
    Terrain.Shutdown();Route.Clear();Modes.Apply("normal");Route.Build()
    check(Config.RouteSegments==originalSegments,"模式返回未恢复普通原表")
    near(Route.GetLength(),normalLength,1e-9,"普通长度漂移")
    for _,p in ipairs(original) do check((Route.Sample(p.s)-p.pos):Length()==0,"普通图坐标发生漂移") end
    check(Config.RouteProfile~=nil and Config.MountainTerrain~=nil
        and Config.RouteId==Modes.Get("normal").routeId,"切回普通丢失自身纵断面或残留狂暴版本")
    Modes.Apply("rage");Route.Build();Terrain.Init()
    return checks_
end
function Validation.RunGeometry()
    scene_=Scene();scene_:CreateComponent("Octree")
    local total=0
    for _,s in ipairs({7200,45000,78000,109000}) do
        local p=Route.SampleOffset(s,-180,0)
        local owner=scene_:CreateChild("真实山坡cell")
        Terrain.BuildCell(owner,math.floor(p.x/160),math.floor(p.z/160),160)
        local count=0
        for _,mesh in ipairs(owner:GetComponents("CustomGeometry",true)) do
            for slot=0,mesh.numGeometries-1 do
                for index=0,mesh:GetNumVertices(slot)-1 do
                    local v=mesh:GetVertex(slot,index).position
                    near(Terrain.GetGroundHeight(v.x,v.z),v.y,.15,"山坡实际顶点不落同源高程")
                    count=count+1
                end
            end
        end
        check(count>0,"山坡没有实际引擎三角形")
        total=total+count
        Terrain.ForgetCell(math.floor(p.x/160),math.floor(p.z/160));owner:Dispose()
    end
    local structureVertices=0
    for _,def in ipairs(Landmarks.GetDefinitions()) do
        if def.kind=="bridge" or def.kind=="tunnel" then
            local owner=scene_:CreateChild("桥隧真实几何")
            local a=math.floor(def.s/240)*240
            Landmarks.BuildChunk(owner,a,a+240)
            for _,mesh in ipairs(owner:GetComponents("CustomGeometry",true)) do
                for slot=0,mesh.numGeometries-1 do structureVertices=structureVertices+mesh:GetNumVertices(slot) end
            end
            Landmarks.ForgetChunk(a,a+240);owner:Dispose()
            check(#Landmarks.GetMeshes()==0,"卸载后残留桥隧网格引用")
        end
    end
    check(structureVertices>10000,"桥隧实际几何缺失")
    print("RAGE_MOUNTAIN_GEOMETRY_PASS "..require("cjson").encode({terrainVertices=total,structureVertices=structureVertices,checks=checks_,noSave=true,noCloud=true}))
    Terrain.Shutdown();scene_:Dispose();scene_=nil
end
function Validation.RunBackdropGeometry()
    scene_=Scene();scene_:CreateComponent("Octree")
    local owner=scene_:CreateChild("远地形接缝验收")
    local vertices=0
    for _,a in ipairs({6960,7080}) do
        Terrain.BuildMountainBackdrop(owner:CreateChild("Backdrop_"..a),a,a+120)
    end
    local seen={}
    for _,mesh in ipairs(owner:GetComponents("CustomGeometry",true)) do
        for slot=0,mesh.numGeometries-1 do
            for i=0,mesh:GetNumVertices(slot)-3,3 do
                local a,b,c=mesh:GetVertex(slot,i).position,mesh:GetVertex(slot,i+1).position,mesh:GetVertex(slot,i+2).position
                for _,v in ipairs({a,b,c}) do
                    near(Terrain.GetGroundHeight(v.x,v.z)-.04,v.y,.15,"远近地表非同一高程网格")
                end
                local center=(a+b+c)/3
                local key=string.format("%.2f_%.2f",center.x,center.z)
                check(not seen[key],"相邻远地形块重复提交同一三角形")
                seen[key]=true;vertices=vertices+3
            end
        end
    end
    check(vertices>1000,"远景山体没有实际几何")
    print("MOUNTAIN_BACKDROP_GEOMETRY_PASS vertices="..vertices.." checks="..checks_)
    owner:Dispose();scene_:Dispose();scene_=nil
end
local function activate()
    local Stream=require "world.WorldStream"
    local case=cases_[caseIndex_]
    Stream.Build(assert(scene_),case.s,function(ratio) print("MOUNTAIN_VISUAL_BUILD_STAGE ratio="..tostring(ratio).." cpu="..os.clock()) end)
    -- 先以相同生产3ms调度推进资源队列，再渲染少量真实帧；不让450帧软件GPU拖慢验收。
    for _=1,900 do Stream.Update(case.s,1/30) end
    age_,warm_,captured_=0,false,false
    local node=assert(camera_)
    node.position=Route.SampleOffset(case.s+case.along,case.lateral,case.eye)
    node:LookAt(Route.SampleOffset(case.s+case.look,case.targetLateral or 0,case.targetY or 2))
    print("RAGE_MOUNTAIN_VISUAL_CASE "..case.name.." s="..case.s.." railBaseY="..Route.HeightAt(case.s))
end
local function startVisual()
    local bridge=assert((function() for _,def in ipairs(Landmarks.GetDefinitions()) do if def.id=="rage_gorge_2" then return def end end end)())
    cases_={
        {name="01_real_climbing_hairpin",s=7000,along=-180,lateral=100,eye=48,look=650,targetLateral=-25,targetY=18},
        {name="02_high_gorge_bridge",s=bridge.s,along=-340,lateral=-240,eye=125,look=30,targetLateral=2.5,targetY=-35},
        {name="03_highland_summit_descent",s=108000,along=-140,lateral=80,eye=30,look=600,targetY=2},
    }
    if selectedCase_>0 then caseIndex_=math.min(#cases_,selectedCase_) end
    scene_=Scene();scene_:CreateComponent("Octree")
    renderer.hdrRendering=true;renderer.drawShadows=false;renderer.specularLighting=false
    local lighting=scene_:CreateChild("LightGroup")
    lighting:LoadXML(assert(cache:GetResource("XMLFile","LightGroup/Daytime.xml")):GetRoot())
    local zone=assert(lighting:GetComponent("Zone",true))
    zone.boundingBox=BoundingBox(Vector3(-100000,-2000,-100000),Vector3(100000,5000,100000))
    zone:SetAttribute("Bloom Enable",Variant(false));zone.depthFogStart=1100;zone.depthFogEnd=2200
    require("world.Sky").Create(scene_,Quality.Get("low"))
    camera_=scene_:CreateChild("山地图验收相机")
    local camera=camera_:CreateComponent("Camera");camera.nearClip=.12;camera.farClip=2300;camera.fov=68;camera.viewMask=3
    renderer:SetViewport(0,Viewport:new(scene_,camera))
    activate()
    SubscribeToEvent("Update","HandleRageMountainUpdate")
    SubscribeToEvent("EndRendering","HandleRageMountainCapture")
end
function Start()
    guard(function()
        if visual_ then
            Modes.Apply("rage");Route.Build();Terrain.Init();startVisual()
        elseif streamOnly_ then
            Modes.Apply("rage");Route.Build()
            scene_=Scene();scene_:CreateComponent("Octree")
            local began=os.clock()
            local stageAge=began
            require("world.WorldStream").Build(scene_,7000,function(ratio)
                local now=os.clock()
                if now-stageAge>.5 then print("MOUNTAIN_STREAM_STAGE ratio="..tostring(ratio).." cpu="..(now-began));stageAge=now end
            end)
            print("MOUNTAIN_STREAM_BUILD_COMPLETE cpu="..(os.clock()-began))
            local initial=require("world.WorldStream").GetStats()
            check(initial.terrainChunks>=25,"狂暴初载没有25个真实地形cell")
            print("MOUNTAIN_STREAM_INITIAL "..require("cjson").encode({terrainChunks=initial.terrainChunks,nearMeshes=initial.nearRailMeshCount,
                vertices=initial.loadedVertices,startupMs=initial.startupMs,maxInitialTaskMs=initial.maxInitialTaskMs}))
            for _=1,450 do require("world.WorldStream").Update(7000,1/30) end
            print("MOUNTAIN_STREAM_CPU_PASS "..require("cjson").encode(require("world.WorldStream").GetStats()))
            require("world.WorldStream").Shutdown();engine:Exit()
        else
            Validation.RunPlan();Validation.RunGeometry()
            Terrain.Init();Validation.RunBackdropGeometry();Terrain.Shutdown()
            print("ALL_RAGE_MOUNTAIN_PASS checks="..checks_);engine:Exit()
        end
    end)
end
function HandleRageMountainUpdate()
    if failed_ then return end
    guard(function()
        age_=age_+1
        require("world.WorldStream").Update(cases_[caseIndex_].s,1/30)
    end)
end
function HandleRageMountainCapture()
    if failed_ or age_<8 then return end
    guard(function()
        if captured_ then
            if caseIndex_==#cases_ or selectedCase_>0 then
                print("RAGE_MOUNTAIN_REAL_FRAME_PASS "..require("cjson").encode(evidence_));engine:Exit()
            else caseIndex_=caseIndex_+1;activate() end
            return
        end
        local image=Image()
        if not graphics:TakeScreenShot(image) then image:Dispose();return end
        if not warm_ then warm_=true;image:Dispose();return end
        local case=cases_[caseIndex_]
        local path="/workspace/screenshots/rage_mountain/"..case.name..".png"
        check(image:SavePNG(path),"真实截图无法保存")
        image:Dispose()
        local stream=require("world.WorldStream").GetStats()
        local stats=Terrain.GetLandscapeStats()
        check(stats.loadedHillCells>0,"实景没有真实山体网格")
        local row={name=case.name,path=path,s=case.s,railBaseY=Route.HeightAt(case.s),terrainCells=stream.terrainChunks,
            terrainQuads=stats.loadedHillCells,maxRelief=stats.maxLoadedHillHeight,loadedVertices=stream.loadedVertices,
            batches=renderer.numBatches,primitives=renderer.numPrimitives,maxTaskMs=stream.maxTaskMs,pending=stream.pendingTasks,noSave=true,noCloud=true}
        evidence_[#evidence_+1]=row;print("RAGE_MOUNTAIN_REAL_FRAME "..require("cjson").encode(row))
        captured_=true
    end)
end
function Stop()
    if visual_ then require("world.WorldStream").Shutdown() else Terrain.Shutdown() end
end
return Validation
