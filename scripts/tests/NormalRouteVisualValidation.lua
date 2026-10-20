-- 普通v2新区真实帧验收。基于templates/scaffold-3d-scene、RageMountainValidation、ReliefVisualValidation。
-- 仅调用生产GameModes/Route/WorldStream/Terrain/Landmarks/Station；不加载Game、Save或cloud。
-- 默认960x540；唯一软件GLES进程串行运行。只写screenshots/normal_v2，不修改生产预算或几何。
local Modes=require "config.GameModes"
local Config=require "config.GameConfig"
local Route=require "world.Route"
local Stream=require "world.WorldStream"
local Terrain=require "world.Terrain"
local Landmarks=require "world.Landmarks"
local Mountain=require "world.MountainProfile"
local Station=require "world.Station"
local Buildings=require "world.StationBuildings"
local Quality=require "config.VisualQuality"
local Json=require "cjson"
local Visual={}
---@type Scene?
local scene_=nil
---@type Node?
local camera_=nil
---@type Camera?
local cameraComponent_=nil
---@type table[]
local cases_={}
local index_,age_,warmFrames_,attempts_=1,0,0,0
local selected_,startCase_,endCase_=0,1,0
local captured_,warmed_,complete_,failed_=false,false,false,false
local currentStreamS_=-1
local evidence_={}
local OUTPUT="/workspace/screenshots/normal_v2/"
for _,argument in ipairs(GetArguments()) do
    local selected=argument:match("^%-normal%-visual%-case=(%d+)$")
    if selected then selected_=math.floor(tonumber(selected) or 0) end
    local startCase=argument:match("^%-normal%-visual%-start=(%d+)$")
    local endCase=argument:match("^%-normal%-visual%-end=(%d+)$")
    if startCase then startCase_=math.floor(tonumber(startCase) or 1) end
    if endCase then endCase_=math.floor(tonumber(endCase) or 0) end
end
local function guard(fn)
    if failed_ or complete_ then return end
    local ok,message=xpcall(fn,debug.traceback)
    if not ok then failed_=true;print("NORMAL_V2_VISUAL_FAIL "..tostring(message));log:Write(LOG_ERROR,tostring(message));engine:Exit() end
end
local function check(value,message) assert(value,"[NormalV2Visual] "..message) end
local function definition(id)
    for _,def in ipairs(Landmarks.GetDefinitions()) do if def.id==id then return def end end
    error("[NormalV2Visual] 缺失生产地标 "..id)
end
local function prepareCases()
    local bridge=definition("normal_high_bridge_2")
    local tunnel=definition("normal_ridge_tunnel_2")
    cases_={
        {name="01_shimen_high_bridge_valley",s=bridge.s,streamS=bridge.s,along=-190,lateral=-230,eye=95,look=30,targetLateral=2.5,targetY=-28},
        {name="02_shimen_bridge_abutment",s=bridge.first-55,streamS=bridge.first,along=0,lateral=-.65,eye=4.1,look=200,targetLateral=-.65,targetY=3.7},
        {name="03_shimen_ridge_portal_driver",s=tunnel.first-90,streamS=tunnel.first,along=0,lateral=-.65,eye=4.1,look=240,targetLateral=-.65,targetY=3.7},
        {name="04_shimen_ridge_portal_mountain",s=tunnel.first,streamS=tunnel.first,along=-80,lateral=-85,eye=38,look=120,targetLateral=2.5,targetY=35},
        {name="05_shimen_tunnel_inside",s=tunnel.first+330,streamS=tunnel.first+330,along=0,lateral=-.65,eye=4.1,look=220,targetLateral=-.65,targetY=3.7},
        {name="06_shimen_tunnel_exit",s=tunnel.last-110,streamS=tunnel.last-110,along=0,lateral=-.65,eye=4.1,look=250,targetLateral=-.65,targetY=3.7},
    }
    for i=6,10 do
        local st=assert(Route.GetStations()[i])
        cases_[#cases_+1]={name=string.format("%02d_station_%s_mountain_city",i+1,st.id),s=st.s,streamS=st.s,
            along=-210,lateral=165,eye=75,look=-40,targetLateral=-85,targetY=7,station=i}
    end
    local st=assert(Route.GetStations()[8])
    cases_[#cases_+1]={name="12_yunji_station_identity",s=st.s,streamS=st.s,along=-63,lateral=-.65,eye=4.2,
        look=-63,targetLateral=-7.2,targetY=4.18,station=8}
    local first=Config.MountainTerrain.First
    cases_[#cases_+1]={name="13_legacy_extension_join",s=first,streamS=first,along=-110,lateral=-90,eye=42,
        look=250,targetLateral=0,targetY=4}
    local cuichuan=assert(Route.GetStations()[6])
    cases_[#cases_+1]={name="14_cuichuan_forecourt_seam",s=cuichuan.s,streamS=cuichuan.s,along=-145,lateral=-12,eye=26,
        look=-55,targetLateral=-68,targetY=1.0,station=6}
end
local function validateStation(st)
    local info=Station.GetSignInfo(st)
    check(info.name==st.name and info.name~="星汐站","新区站名回退星汐")
    check(Buildings.Styles[st.index]~=Buildings.Styles[1] and not Buildings.Styles[st.index].asset,"新区站房回退星汐独立资产")
    local root=assert(scene_):GetChild("WorldStream")
    check(root~=nil,"没有生产WorldStream根")
    local station=root:GetChild("station_"..st.index)
    check(station~=nil and station:GetChild("Station_"..st.name)~=nil,"生产Station.BuildOne实体缺失")
    local labels=station:GetComponents("Text3D",true)
    local ownNames,wrongNames=0,0
    for _,label in ipairs(labels) do
        if label.text:find(st.name,1,true) then ownNames=ownNames+1 end
        if label.text:find("星汐",1,true) then wrongNames=wrongNames+1 end
    end
    check(ownNames>=6 and wrongNames==0,"实际Text3D未使用本站名或混入星汐")
    return {id=st.id,name=st.name,index=st.index,ownNameLabels=ownNames,xingxiLabels=wrongNames,
        archetype=Buildings.Styles[st.index].archetype,previous=info.previousName,following=info.nextName}
end
local function activate()
    local case=assert(cases_[index_])
    if currentStreamS_~=case.streamS then
        Stream.Build(assert(scene_),case.streamS)
        currentStreamS_=case.streamS
        -- 不放大3ms预算：与既有RageMountainValidation相同，离线预热多次生产Update。
        -- 随后仍推进多帧；日志保留排队数，不把尚未加载的画面当作最终证据。
        for _=1,1800 do
            Stream.Update(case.streamS,1/30)
            if Stream.GetStats().pendingTasks==0 then break end
        end
    end
    local node=assert(camera_)
    node.position=Route.SampleOffset(case.s+case.along,case.lateral,case.eye)
    node:LookAt(Route.SampleOffset(case.s+case.look,case.targetLateral,case.targetY))
    age_,warmFrames_,attempts_=0,0,0
    captured_,warmed_=false,false
    print("NORMAL_V2_VISUAL_CASE "..Json.encode({index=index_,name=case.name,s=case.s,streamS=case.streamS,
        railY=Route.HeightAt(case.s),pending=Stream.GetStats().pendingTasks,frameBudgetMs=Config.WorldStream.FrameBudgetMs}))
end
function Start()
    guard(function()
        Modes.Apply("normal");Route.Build()
        check(math.abs(Route.GetLength()-88857.8637465)<.001,"线路不是最终88.8578637465km")
        check(#Route.GetStations()==10,"普通线不是10站")
        check(math.abs(Config.MountainTerrain.First-33186.57734856853)<.00001,"旧33.186577km前缀改变")
        check(not Mountain.IsActiveAt(Config.MountainTerrain.First-1) and Mountain.IsActiveAt(Config.MountainTerrain.First+1),"Mountain.IsActiveAt污染旧区")
        check(Config.WorldStream.FrameBudgetMs==3,"生产流式预算不是3ms")
        Landmarks.Init()
        local bridges,tunnels=0,0
        for _,def in ipairs(Landmarks.GetDefinitions()) do
            if def.first>=Config.MountainTerrain.First then
                if def.kind=="bridge" then bridges=bridges+1 elseif def.kind=="tunnel" then tunnels=tunnels+1 end
            end
        end
        check(bridges==5 and tunnels==5,"新增工程不是5桥5隧")
        prepareCases()
        index_=math.max(1,math.min(#cases_,selected_>0 and selected_ or startCase_))
        endCase_=endCase_>0 and math.max(index_,math.min(#cases_,endCase_)) or #cases_
        scene_=Scene();scene_:CreateComponent("Octree")
        renderer.hdrRendering=true;renderer.drawShadows=false;renderer.specularLighting=false
        local lighting=scene_:CreateChild("LightGroup")
        lighting:LoadXML(assert(cache:GetResource("XMLFile","LightGroup/Daytime.xml")):GetRoot())
        local zone=assert(lighting:GetComponent("Zone",true))
        zone.boundingBox=BoundingBox(Vector3(-150000,-2000,-150000),Vector3(150000,5000,150000))
        zone:SetAttribute("Bloom Enable",Variant(false));zone.depthFogStart=1100;zone.depthFogEnd=2400
        local sun=assert(lighting:GetComponent("Light",true));sun.castShadows=false
        require("world.Sky").Create(scene_,Quality.Get("low"))
        camera_=scene_:CreateChild("普通新区实景验收相机")
        cameraComponent_=camera_:CreateComponent("Camera")
        cameraComponent_.nearClip=.12;cameraComponent_.farClip=2400;cameraComponent_.fov=68;cameraComponent_.viewMask=3
        renderer:SetViewport(0,Viewport:new(scene_,cameraComponent_))
        activate()
        SubscribeToEvent("Update","HandleNormalV2VisualUpdate")
        SubscribeToEvent("EndRendering","HandleNormalV2VisualCapture")
    end)
end
function HandleNormalV2VisualUpdate()
    guard(function()
        age_=age_+1
        Stream.Update(assert(cases_[index_]).streamS,1/30)
        if Stream.GetStats().pendingTasks==0 then warmFrames_=warmFrames_+1 else warmFrames_=0 end
        check(age_<2400,"2400帧后生产流式队列未完成")
    end)
end
function HandleNormalV2VisualCapture()
    guard(function()
        if age_<10 or warmFrames_<4 then return end
        if captured_ then
            if selected_>0 or index_==endCase_ then
                print("NORMAL_V2_REAL_FRAME_EVIDENCE "..Json.encode(evidence_))
                print("NORMAL_V2_REAL_FRAME_CAPTURE_PASS captures="..#evidence_.." visualReviewRequired=true noSave=true noCloud=true")
                complete_=true;engine:Exit()
            else index_=index_+1;activate() end
            return
        end
        local image=Image()
        if not graphics:TakeScreenShot(image) then
            image:Dispose();attempts_=attempts_+1;check(attempts_<6,"真实framebuffer读取失败");return
        end
        if not warmed_ then warmed_=true;image:Dispose();return end
        local case=assert(cases_[index_])
        local path=OUTPUT..case.name..".png"
        check(image:SavePNG(path),"内部验收截图保存失败")
        image:Dispose()
        local stream=Stream.GetStats()
        local relief=Landmarks.GetStats()
        local terrain=Terrain.GetLandscapeStats()
        check(stream.pendingTasks==0 and stream.terrainChunks>=25,"生产地形或流式任务未完成")
        check(stream.mountainBackdropChunks>0,"生产远山几何缺失")
        if not case.station and index_<=6 then check(relief.vertices>0,"桥隧镜头无生产地标几何") end
        local stationEvidence=case.station and validateStation(assert(Route.GetStations()[case.station])) or nil
        local row={name=case.name,path=path,s=case.s,railY=Route.HeightAt(case.s),streamS=case.streamS,
            terrainChunks=stream.terrainChunks,mountainBackdropChunks=stream.mountainBackdropChunks,cityChunks=stream.cityChunks,
            loadedVertices=stream.loadedVertices,landmarkVertices=relief.vertices,loadedHillCells=terrain.loadedHillCells,
            pendingTasks=stream.pendingTasks,maxTaskMs=stream.maxTaskMs,lastUpdateMs=stream.lastUpdateMs,
            frameBudgetMs=Config.WorldStream.FrameBudgetMs,batches=renderer.numBatches,primitives=renderer.numPrimitives,
            actualFrames=age_,station=stationEvidence,noSave=true,noCloud=true}
        evidence_[#evidence_+1]=row
        print("NORMAL_V2_REAL_FRAME "..Json.encode(row));captured_=true
    end)
end
function Stop() Stream.Shutdown() end
return Visual
