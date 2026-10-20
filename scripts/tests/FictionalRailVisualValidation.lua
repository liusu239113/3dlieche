-- 架空铁路真实渲染验收：同一Scene串行八图，不运行时执行全套逻辑，不并行GPU。
-- 主线程统一运行 tests/FictionalRailVisualValidation.lua，建议 -x 1280 -y 720
-- -validate-frames=760 -validate-timeout=600；不用命令行-screenshot（仅八张内部PNG）。
-- 首图>=120真实帧；随后每case>=34帧，队列/捕获最多66帧；readback后hold2真实帧。
-- 64次WorldStream.Update仅验收队列drain，不是生产帧预算/手机性能结论。
_G.FICTIONAL_RAIL_HELPERS_ONLY=true
local V=require "tests.FictionalRailValidation"
_G.FICTIONAL_RAIL_HELPERS_ONLY=nil
local Route=require "world.Route"
local Rail=require "world.RailNetwork"
local Train=require "train.Train"
local Camera=require "train.Camera"
local Game=require "game.Game"
local Passenger=require "game.PassengerService"
local Hud=require "ui.Hud"
local Traffic=require "game.Traffic"
local Stream=require "world.WorldStream"
local Landmarks=require "world.Landmarks"
local Terrain=require "world.Terrain"
local UI=require "urhox-libs/UI"

---@class FictionalVisualCase
---@field name string
---@field s number
---@field mode string
---@field kind string
---@field landmark? RailwayLandmark
---@field small? boolean
---@field eye? Vector3
---@field target? Vector3
---@type FictionalVisualCase[]
local cases_={}
---@type Scene?
local scene_=nil
---@type Node?
local node_=nil
---@type Camera?
local camera_=nil
---@type thread?
local setup_=nil
---@type Image?
local image_=nil
local restoreProbe_=function() end
local frame_,index_,caseStart_,captures_,lastRender_,hold_,captureFrame_,attempts_,drains_=0,0,0,0,-1,0,-1,0,0
local stage_,failed_,complete_,busy_="bootstrap",false,false,false
local OUTPUT="/workspace/screenshots/"
local frozen_={s=0,eye=Vector3.ZERO,direction=Vector3.FORWARD,fov=0,viewMask=7,trainId="",station="",nextStation="",scale=1}
local checksums_={}

local function guard(action)
    if failed_ or complete_ then return end
    local ok,message=xpcall(action,debug.traceback)
    if not ok then
        failed_,busy_=true,false -- 先latch；错误后任何事件都不能截图/打印PASS。
        print(string.format("ALL_FICTIONAL_RAIL_VISUAL_FAILED screenshots=%d/8 case=%d frame=%d stage=%s",captures_,index_,frame_,stage_))
        log:Write(LOG_ERROR,tostring(message));error(message,0)
    end
end
local function vector(p) return string.format("%.4f,%.4f,%.4f",p.x,p.y,p.z) end
local function constructCases()
    ---@type RailwayLandmark[]
    local bridges={}
    ---@type RailwayLandmark[]
    local tunnels={}
    for _,def in ipairs(Landmarks.GetLandmarks()) do
        if def.kind=="bridge" then bridges[#bridges+1]=def
        elseif def.kind=="tunnel" then tunnels[#tunnels+1]=def end
    end
    table.sort(bridges,function(a,b)return a.first<b.first end)
    table.sort(tunnels,function(a,b)return a.first<b.first end)
    V.Check(#bridges==2 and #tunnels==2,"视觉真实地标不是两桥两隧")
    local b1,b2,t1=assert(bridges[1]),assert(bridges[2]),assert(tunnels[1])
    local first=assert(Route.GetStations()[1])
    local ridge=assert(Landmarks.GetLandmarks()[1])
    local ridgeDistance=math.huge
    for _,def in ipairs(Landmarks.GetLandmarks()) do
        if def.kind=="mountain" and math.abs(def.s-36000)<ridgeDistance then
            ridge,ridgeDistance=def,math.abs(def.s-36000)
        end
    end
    V.Check(ridge.kind=="mountain","山林检视没有实际山峰")
    cases_={
        {name="fictional_01_station_boarding",s=first.s+1,mode="platform",kind="passengers",
            eye=Route.SampleOffset(first.s-65,5.9,2.2),target=Route.SampleOffset(first.s-85,1.9,1.8)},
        -- 城市检视要看侧向天际线，不以高空俯视小屋顶冒充高楼效果。
        {name="fictional_02_city_towers",s=first.s+1,mode="distant",kind="city",
            eye=Route.SampleOffset(first.s-145,115,30),target=Route.SampleOffset(first.s,-280,52)},
        {name="fictional_03_river_bridge",s=b1.s,mode="distant",kind="bridge",landmark=b1,
            eye=Route.SampleOffset(b1.s-130,110,42),target=Route.SampleOffset(b1.s,-2.5,-7)},
        {name="fictional_04_tunnel_portal",s=t1.first+50,mode="distant",kind="portal",landmark=t1,
            eye=Route.SampleOffset(t1.first-95,23,15),target=Route.SampleOffset(t1.first+40,-2.5,9)},
        {name="fictional_05_tunnel_inside",s=t1.s,mode="cab",kind="tunnel",landmark=t1,
            eye=Route.SampleOffset(t1.s,0,2.7),target=Route.SampleOffset(t1.s+75,0,2.7)},
        {name="fictional_06_mountain_forest",s=ridge.s,mode="distant",kind="mountain",
            eye=Route.SampleOffset(ridge.s-230,-ridge.lateral*.25,20),
            target=Route.SampleOffset(ridge.s,ridge.lateral,ridge.height*.36)},
        {name="fictional_07_deep_valley_bridge",s=b2.s,mode="distant",kind="bridge",landmark=b2,
            eye=Route.SampleOffset(b2.s-130,125,50),target=Route.SampleOffset(b2.s,-2.5,-10)},
        {name="fictional_08_compact_hud",s=first.s+1,mode="cab",kind="hud",small=true},
    }
    for _,argument in ipairs(GetArguments()) do
        if argument=="-visual-final-only" then
            cases_={cases_[6],cases_[8]}
        end
    end
end

-- 没有动态跟随镜头：激活一次后每post回写冻结的真实Node姿态，hold2身份不漂移。
local function applyFrozenCamera()
    local camera,node=assert(camera_),assert(node_)
    node.worldPosition=frozen_.eye
    node.worldDirection=frozen_.direction
    camera.fov=frozen_.fov
    -- MainPost会更新生产机位的mask；验收冻结眼点时必须同时恢复渲染层。
    -- 隧道前方通道不显示列车/内舱后壁，正常驾驶舱case仍保留其原mask15。
    camera.viewMask=frozen_.viewMask
    local viewport=assert(renderer:GetViewport(0))
    viewport:SetScene(assert(scene_));viewport:SetCamera(camera)
end
local function activate(index)
    V.Check(index==1 or hold_==2,"截图未hold2就切换Scene/case")
    index_,stage_,attempts_,drains_,hold_=index,"setup",0,0,0
    setup_=coroutine.create(function()
        local case=assert(cases_[index])
        Hud.SetCameraSelectorOpen(false)
        Hud.SetRouteExpanded(false);Hud.SetOperationsExpanded(false)
        -- 小屏是明确标记的UI.Scale布局fixture；真实graphics分辨率/DPR保持不变。
        UI.SetScale(case.small and graphics:GetWidth()/640 or UI.Scale.DEFAULT)
        Train.Reset(case.s);Train.EmergencyBrake();V.Yield()
        if index~=1 then Stream.Reset(Train.GetS());V.Yield() end
        Traffic.Reset(Train.GetS());Game.Init();Game.UpdateHud(0)
        if case.kind=="passengers" then
            V.SetPaused(false)
            local trace=V.NewTrace()
            local completed=false
            for step=1,450 do
                local prior=Passenger.GetPassengers()
                for _,person in ipairs(prior) do trace.prior[person.id]=person end
                V.MainStep(.02)
                V.ObservePassengers(trace,.02)
                if trace.completed>0 then completed=true;break end
                if step%8==0 then V.Yield() end
            end
            V.Check(completed,"站台图没有实际逐门走完至少一人")
            local walking=false
            for _,person in ipairs(Passenger.GetPassengers()) do walking=walking or person.walking end
            V.Check(walking,"站台图只spawn静止候车人，没有真实walking pose")
            print(string.format("[架空铁路视觉] WALKING_FIXTURE completed=%d，真实主循环推进后冻结步态，未伪造姿势",trace.completed))
        end
        V.SetPaused(true)
        Passenger.UpdateVisuals(0)
        V.Yield()
        V.Check(Camera.SetMode(case.mode),"真实机位目录不支持："..case.mode)
        Camera.Update(.05,Train.GetS())
        Hud.SetCameraMode(Camera.GetMode(),Camera.GetModeName())
        local camera,node=assert(Camera.GetCamera()),assert(Camera.GetNode())
        camera_,node_=camera,node
        if case.eye and case.target then
            node.worldPosition=case.eye
            node:LookAt(case.target)
            camera.fov=case.kind=="tunnel" and 65 or 54
            -- 隧道内本case使用真实前方通道而非近裁剪车身；列车模型仍在同scene。
            if case.kind=="tunnel" then camera.viewMask=2|4 end
        end
        if case.small then
            V.Tap("toggleOperations")
            V.Check(Hud.GetReadings().operationsExpanded,"小屏截图没有真实展开运营详情")
            V.CheckHudBounds()
        end
        UI.Layout()
        local readings=Hud.GetReadings()
        frozen_={s=Train.GetS(),eye=node.worldPosition,direction=node.worldDirection,fov=camera.fov,viewMask=camera.viewMask,
            trainId=Train.GetSelectedId(),station=readings.stationName,nextStation=readings.nextStation,scale=UI.GetScale()}
        caseStart_,stage_=frame_,"settle"
        print(string.format("[架空铁路视觉] CASE %d/%d %s frame=%d s=%.3f realSize=%dx%d realDPR=%.2f logicalScale=%.3f",
            index,#cases_,case.name,frame_,Train.GetS(),graphics:GetWidth(),graphics:GetHeight(),graphics:GetDPR(),UI.GetScale()))
    end)
end
local function checkIdentity(phase)
    local case=assert(cases_[index_])
    local viewport=assert(renderer:GetViewport(0))
    local camera,node=assert(camera_),assert(node_)
    local readings=Hud.GetReadings()
    V.Check(viewport.scene==scene_ and viewport.camera==camera and Camera.GetNode()==node,"真实截图Scene/Camera跨case")
    V.Point(node.worldPosition,frozen_.eye,.0001,"真实冻结镜头位置漂移")
    V.Point(node.worldDirection,frozen_.direction,.00001,"真实冻结镜头方向漂移")
    V.Near(Train.GetS(),frozen_.s,.00001,"截图锁定后列车位置改变")
    V.Near(camera.fov,frozen_.fov,.0001,"截图锁定FOV改变")
    V.Check(camera.viewMask==frozen_.viewMask,"截图锁定渲染层被生产机位更新覆盖")
    if case.kind=="tunnel" then V.Check(camera.viewMask==6,"隧道通道误显示列车或内舱后壁") end
    V.Check(Train.GetSelectedId()==frozen_.trainId and readings.paused,"截图车型身份/暂停改变")
    V.Check(readings.stationName==frozen_.station and readings.nextStation==frozen_.nextStation,"截图HUD与case位置不一致")
    V.Near(UI.GetScale(),frozen_.scale,.00001,"截图UI比例跨case")
    print(string.format("[架空铁路视觉] IDENTITY %s case=%s frame=%d scene=%s camera=%s eye=%s direction=%s s=%.3f HUD=%s/%s",
        phase,case.name,frame_,tostring(viewport.scene),tostring(camera),vector(node.worldPosition),vector(node.worldDirection),Train.GetS(),readings.stationName,readings.nextStation))
end
local function verifySaved(path,image)
    local file=File(path,FILE_READ)
    V.Check(file:IsOpen() and file:GetSize()>1000,"真实PNG未落盘或为空")
    for _,byte in ipairs({137,80,78,71,13,10,26,10}) do V.Check(file:ReadUByte()==byte,"截图字节并非PNG") end
    local decoded=Image()
    V.Check(decoded:Load(path),"真实PNG回读解码失败")
    V.Check(decoded.width==image.width and decoded.height==image.height and image.width==graphics:GetWidth()
        and image.height==graphics:GetHeight(),"PNG真实像素尺寸不匹配")
    local lo,hi=math.huge,-math.huge
    for y=1,10 do for x=1,14 do
        local pixel=decoded:GetPixel(math.floor(decoded.width*x/15),math.floor(decoded.height*y/11))
        local value=pixel.r*.2126+pixel.g*.7152+pixel.b*.0722
        lo,hi=math.min(lo,value),math.max(hi,value)
    end end
    V.Check(hi-lo>.035 and hi>.08,"真实PNG是全黑/单色空渲染")
    local checksum=tostring(file:GetChecksum())
    V.Check(not checksums_[checksum],"不同case保存了完全相同的旧截图")
    checksums_[checksum]=true
    print(string.format("[架空铁路视觉] PNG_READBACK path=%s bytes=%d checksum=%s",path,file:GetSize(),checksum))
    decoded:Dispose();file:Dispose()
end
local function checkLiveWorld()
    local case=assert(cases_[index_])
    local stats=Stream.GetStats()
    V.Check(stats.pendingTasks==0 and stats.stationChunks<=1 and stats.cityChunks<=1,"截图局部世界未收敛/同时积累多站城市")
    local scenery=Landmarks.GetStats()
    if case.kind=="bridge" then
        V.Check(scenery.bridges>0 and scenery.piers>0 and scenery.bridgeLength>400,"桥截图实际桥面/墩/加载长度缺失")
        local below=false
        for _,g in ipairs(Landmarks.GetMeshes()) do
            if g.node.name:find("实际深谷坡面",1,true) then below=below or g:GetWorldBoundingBox().min.y< -20 end
        end
        V.Check(below,"桥截图只是平地上装饰桥，没有真实深谷mesh")
    elseif case.kind=="portal" or case.kind=="tunnel" then
        V.Check(scenery.tunnels>0 and scenery.tunnelLength>300,"截图没有实际连续隧道内衬")
        if case.kind=="portal" then V.Check(scenery.portals>0,"洞口截图没有真实门户") end
        local lining=false
        for _,g in ipairs(Landmarks.GetMeshes()) do
            if g.node.name:find("连续可见内衬",1,true) then lining=lining or g:GetNumVertices(0)>30 end
        end
        V.Check(lining,"隧道截图无实际CG实体面")
    elseif case.kind=="mountain" then
        V.Check(scenery.mountains>0 and scenery.maxMountainHeight>=170,"山林截图没有实际170米以上山体")
        local terrain=Terrain.GetLandscapeStats()
        local groups,instances=0,0
        for _,group in ipairs(assert(stats.root):GetComponents("StaticModelGroup",true)) do
            if group.node.name:find("ForestLOD_",1,true) then
                V.Check(group.model~=nil and group:GetMaterial(0)~=nil and group:GetMaterial(1)~=nil,
                    "共享森林实例批未绑定实际模型/树皮叶片材质")
                V.Check(group.drawDistance==1600 and not group.castShadows,"远侧林簇未遵守LOD绘制预算")
                groups=groups+1;instances=instances+group.numInstanceNodes
            end
        end
        print(string.format("[架空铁路视觉] FOREST_ACTUAL hillCells=%d hillTrees=%d groups=%d instances=%d height=%.3f",
            terrain.loadedHillCells,terrain.loadedHillTrees,groups,instances,terrain.maxLoadedHillHeight))
        V.Check(terrain.loadedHillTrees>40 and instances==terrain.loadedHillTrees,"山林实际实例不足或统计与真实实体不一致")
    elseif case.kind=="city" then
        V.Check(scenery.highRises>0,"城市截图没有实际高楼建筑")
    elseif case.kind=="passengers" or case.kind=="hud" then
        local passenger=Passenger.GetVisualStats()
        V.Check(passenger.visible>8 and passenger.roots==1 and passenger.npcRigidBodies==0,"客运截图无真实站台乘客或NPC物理无界")
        V.Check(passenger.sharedModels==2 and passenger.sharedPoseFrames==50
            and passenger.geometryBuilds==0 and passenger.offlinePoseGeometries==100
            and passenger.cpuBaked and not passenger.skinned and passenger.bonesPerActor==0,
            "站台NPC未复用离线帧或运行中仍执行蒙皮烘焙")
        V.Check(not Game.CanDepart() and Hud.GetReadings().passenger.doorsOpen,"截图客运状态并非真实未完成登乘")
    end
    V.Check(V.backgroundDraws>30 and V.backgroundAlpha==142,"透明背景只读声明，真实Panel绘制探针从未经过")
    print(string.format("[架空铁路视觉] ACTUAL_RENDER backgroundCalls=%d alpha=%d batches=%d primitives=%d worldChunks=%d bridges=%d tunnels=%d mountains=%d highRises=%d",
        V.backgroundDraws,V.backgroundAlpha,renderer.numBatches,renderer.numPrimitives,stats.loadedChunks,
        scenery.bridges,scenery.tunnels,scenery.mountains,scenery.highRises))
end
local function rendering()
    if busy_ or stage_=="setup" or lastRender_==frame_ then return end
    lastRender_=frame_
    if stage_=="hold" then
        V.Check(frame_>captureFrame_,"readback同帧重复计入hold2")
        checkIdentity("hold_"..(hold_+1));hold_=hold_+1
        if hold_==2 then
            if image_ then image_:Dispose();image_=nil end
            if index_==#cases_ then
                V.Check(captures_==#cases_,"未完成全部串行真实PNG")
                complete_=true
                V.PrintPhases()
                print(string.format("ALL_FICTIONAL_RAIL_VISUAL_PASS screenshots=%d assertions=%d frame=%d backgroundDrawCalls=%d",captures_,V.checks,frame_,V.backgroundDraws))
                print("[架空铁路视觉] 截图仅内部/workspace/screenshots；艺术效果须人工看实际PNG。逻辑全套/人耳听感NOT_RUN，不能框架0断言替代业务结果。")
                -- 恰好八图完成并保持两帧后结束，不让剩余CLI帧空转数分钟。
                engine:Exit()
            else stage_="advance" end
        end
        return
    end
    if stage_~="settle" then return end
    local age=frame_-caseStart_
    local due=index_==1 and frame_>=124 and age>=30 or index_>1 and age>=34
    if not due then return end
    V.Check(frame_>=120,"120真实帧之前截图")
    V.Check(index_==1 and frame_<=170 or index_>1 and age<=66,"case超出有界截图窗口")
    if Stream.GetStats().pendingTasks>0 then return end
    checkLiveWorld();checkIdentity("before_capture")
    busy_=true;attempts_=attempts_+1
    local image=Image();image_=image
    if not graphics:TakeScreenShot(image) then
        image:Dispose();image_=nil;busy_=false
        V.Check(attempts_<4,"四次有界真实readback失败")
        return
    end
    local path=OUTPUT..assert(cases_[index_]).name..".png"
    V.Check(image:SavePNG(path),"真实PNG保存失败")
    verifySaved(path,image);checkIdentity("after_capture")
    captures_,captureFrame_,hold_,stage_,busy_=captures_+1,frame_,0,"hold",false
    print(string.format("[架空铁路视觉] REAL_SCREENSHOT %d/%d %s frame=%d attempt=%d drainCalls=%d",captures_,#cases_,path,frame_,attempts_,drains_))
end
function Start()
    guard(function()
        V.Phase("visual_main_start_only",V.MainStart)
        scene_=assert(renderer:GetViewport(0).scene)
        V.Check(Train.GetSelectedId()=="CR400AF" and Train.GetSelectedName()=="星澜 M35","视觉真实默认车型错误")
        V.SetPaused(true)
        constructCases()
        if not fileSystem:DirExists(OUTPUT) then V.Check(fileSystem:CreateDir(OUTPUT),"内部截图目录不可创建") end
        restoreProbe_=V.InstallBackgroundProbe()
        activate(1)
        SubscribeToEvent("EndRendering","HandleFictionalRailCapture")
        print("[架空铁路视觉] 新逻辑helper已加载，但logicStatus=NOT_RUN；不在frame1同步执行全逻辑。")
    end)
end
---@param eventType string
---@param eventData UpdateEventData
function HandleUpdate(eventType,eventData)
    guard(function()
        frame_=frame_+1
        V.Check(frame_<748,"八图串行视觉未在748真实帧预算完成")
        -- Setup的walking fixture自己逐固定步推进；真实帧不再双重推进/漏掉完成瞬间。
        if stage_~="setup" then V.MainUpdate(eventType,eventData) end
        if stage_=="advance" then activate(index_+1) end
        if stage_=="setup" then
            local ok,message=coroutine.resume(assert(setup_))
            if not ok then error(message,0) end
        end
    end)
end
---@param eventType string
---@param eventData PostUpdateEventData
function HandlePostUpdate(eventType,eventData)
    guard(function()
        V.MainPost(eventType,eventData)
        if stage_=="settle" or stage_=="hold" then
            V.Phase("validation_only_world_drain_64",function()
                for _=1,64 do
                    if Stream.GetStats().pendingTasks==0 then break end
                    Stream.Update(Train.GetS(),0);drains_=drains_+1
                end
            end)
            Passenger.UpdateVisuals(0)
            applyFrozenCamera()
        end
    end)
end
---@param eventType string
---@param eventData EndRenderingEventData
function HandleFictionalRailCapture(eventType,eventData) guard(rendering) end
function Stop()
    restoreProbe_()
    if image_ then image_:Dispose();image_=nil end
    if not complete_ and not failed_ then
        print(string.format("ALL_FICTIONAL_RAIL_VISUAL_NOT_RUN_OR_INCOMPLETE screenshots=%d/8 stage=%s frame=%d",captures_,stage_,frame_))
    end
    if V.MainStop then V.MainStop() end
end
