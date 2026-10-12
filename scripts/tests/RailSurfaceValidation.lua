-- Five bounded rail-surface isolation captures. Authoring does not run Runtime/build.
-- Coordinator: tests/RailSurfaceValidation.lua, -validate-frames=200, real graphics,
-- -x 640 -y 360; no command-line screenshot flag (five internal PNGs only).
-- First 120 frames drain the existing local world, then keep one paused first-station
-- birdseye scene. Each case waits eight distinct EndRendering frames, captures there,
-- and retains its Image/material/enabled state for two additional rendered frames.
-- PASS means isolation protocol/restoration passed, NOT that white points disappeared.
require "main"
local startGame,updateGame,postUpdateGame,stopGame=Start,HandleUpdate,HandlePostUpdate,Stop
-- Import assertion/census helpers without running their Start entry.
local V=require "tests.RailOperationsValidation"
local Train=require "train.Train"
local Route=require "world.Route"
local Camera=require "train.Camera"
local Hud=require "ui.Hud"
local Game=require "game.Game"
local Stream=require "world.WorldStream"
local Traffic=require "game.Traffic"
local UI=require "urhox-libs/UI"

---@class RailSurfaceRecord
---@field geometry CustomGeometry
---@field node Node
---@field kind string
---@field enabled boolean
---@field nodeEnabled boolean
---@field effective boolean
---@field materials Material[]
---@field vertices integer
---@field localBounds BoundingBox
---@field worldBounds BoundingBox
---@class RailSurfaceCase
---@field name string
---@field sleepers boolean
---@field ballast boolean
---@field unlit boolean
---@type RailSurfaceCase[]
local cases_={
    {name="rail_surface_01_original",sleepers=true,ballast=true,unlit=false},
    {name="rail_surface_02_no_sleepers",sleepers=false,ballast=true,unlit=false},
    {name="rail_surface_03_no_ballast",sleepers=true,ballast=false,unlit=false},
    {name="rail_surface_04_no_sleepers_no_ballast",sleepers=false,ballast=false,unlit=false},
    {name="rail_surface_05_all_track_unlit",sleepers=true,ballast=true,unlit=true},
}
local SELECTED_NAMES={SharedConcreteSleepers="sleepers",SharedSlopedBallast="ballast",
    SharedRailISections="steel",SharedRunningHeads="steel",SharedDistantRails="steel"}
---@type RailSurfaceRecord[]
local records_={}
---@type table<number, RailSurfaceRecord>
local selected_={}
---@type Scene?
local scene_=nil
---@type Node?
local cameraNode_=nil
---@type Camera?
local camera_=nil
---@type Material?
local unlit_=nil
---@type Image?
local pendingImage_=nil
local baseline_={s=0,eye=Vector3.ZERO,direction=Vector3.FORWARD,fov=0,nearClip=0,farClip=0,
    mask=0,width=0,height=0,dpr=0,trafficElapsed=0,simulation=0,gameElapsed=0,
    station="",distance="",quality="",nodes=0,mesh="",renderer="",trainId="",trainRoot=0}
local stage_="bootstrap"
local frame_,lastRenderingFrame_,caseIndex_,rendered_,captures_,attempts_,holdFrames_,captureFrame_=0,-1,0,0,0,0,0,-1
local drainCalls_,restoreRendered_=0,0
local failed_,complete_,busy_,snapshotted_=false,false,false,false
local OUTPUT="/workspace/screenshots/"

local function rendererIdentity()
    return table.concat({GetRenderQuality(),tostring(renderer.drawShadows),tostring(renderer.specularLighting),
        tostring(renderer.materialQuality),tostring(renderer.dynamicInstancing),tostring(renderer.shadowMapSize)},"|")
end
local function vectorText(p)
    return string.format("%.6f,%.6f,%.6f",p.x,p.y,p.z)
end
local function boundsText(box) return vectorText(box.min).."/"..vectorText(box.max) end
local function vertices(geometry)
    local count=0
    for slot=0,geometry.numGeometries-1 do count=count+geometry:GetNumVertices(slot) end
    return count
end
local function isTrackOwned(node)
    local current=node.parent
    while current and current~=scene_ do
        if current.name:match("^nearRail_%d+$") or current.name:match("^farRail_%d+$") then return true end
        current=current.parent
    end
    return false
end

-- Signature permits only the selected CG enabled/material fields to change.
-- All vertex counts, node transforms/bounds, other scene meshes and their materials
-- stay identical. Include hidden meshes so isolation cannot hide an unrelated subtree.
local function meshSignature()
    local scene=assert(scene_)
    local rows={}
    local function row(drawable)
        local node=drawable.node
        return table.concat({tostring(drawable.ID),tostring(node.ID),node.name,tostring(node.enabled),
            vectorText(node.worldPosition),vectorText(node.worldDirection),vectorText(node.worldScale),
            boundsText(drawable:GetWorldBoundingBox()),tostring(drawable.viewMask),
            tostring(drawable.lodBias),tostring(drawable.drawDistance),tostring(drawable.castShadows)},"|")
    end
    for _,geometry in ipairs(scene:GetComponents("CustomGeometry",true)) do
        local parts={row(geometry),"CG",tostring(geometry.numGeometries)}
        for slot=0,geometry.numGeometries-1 do
            parts[#parts+1]=tostring(geometry:GetNumVertices(slot))
            if not selected_[geometry.ID] then parts[#parts+1]=tostring(geometry:GetMaterial(slot)) end
        end
        if not selected_[geometry.ID] then parts[#parts+1]=tostring(geometry.enabled) end
        rows[#rows+1]=table.concat(parts,"|")
    end
    for _,model in ipairs(scene:GetComponents("StaticModel",true)) do
        rows[#rows+1]=table.concat({row(model),"SM",tostring(model.model),tostring(model.enabled),
            tostring(model:GetMaterial())},"|")
    end
    for _,group in ipairs(scene:GetComponents("StaticModelGroup",true)) do
        local parts={row(group),"SMG",tostring(group.model),tostring(group.enabled),tostring(group:GetMaterial()),
            tostring(group.numInstanceNodes)}
        for slot=0,group.numInstanceNodes-1 do
            local node=assert(group:GetInstanceNode(slot))
            parts[#parts+1]=tostring(node.ID)..":"..vectorText(node.worldPosition)..":"..vectorText(node.worldScale)
        end
        rows[#rows+1]=table.concat(parts,"|")
    end
    table.sort(rows)
    return table.concat(rows,"\n"),#scene:GetChildren(true)+1
end

local function restore()
    if not snapshotted_ then return end
    for _,record in ipairs(records_) do
        for slot=0,#record.materials-1 do record.geometry:SetMaterial(slot,record.materials[slot+1]) end
        record.geometry:SetEnabled(record.enabled)
        record.node:SetEnabled(record.nodeEnabled)
    end
end
---@param action fun()
local function guarded(action)
    if failed_ or complete_ then return end
    local ok,message=xpcall(action,debug.traceback)
    if not ok then
        failed_,busy_=true,false -- Latch BEFORE cleanup; no later event may capture/print PASS.
        local restored,restoreError=pcall(restore)
        if pendingImage_ then pendingImage_:Dispose();pendingImage_=nil end
        print(string.format("[RailSurface] FAILED stage=%s frame=%d screenshots=%d/5 restored=%s",
            stage_,frame_,captures_,tostring(restored)))
        if not restored then print("[RailSurface] RESTORE_ERROR "..tostring(restoreError)) end
        log:Write(LOG_ERROR,tostring(message))
        error(message,0)
    end
end

local function snapshot()
    local scene=assert(scene_)
    for _,geometry in ipairs(scene:GetComponents("CustomGeometry",true)) do
        local kind=SELECTED_NAMES[geometry.node.name]
        if kind and isTrackOwned(geometry.node) then
            local originalMaterials={} ---@type Material[]
            for slot=0,geometry.numGeometries-1 do
                originalMaterials[slot+1]=assert(geometry:GetMaterial(slot),"轨道原材质缺失")
            end
            V.Check(#originalMaterials>0 and vertices(geometry)>0,"匹配到空轨道CG")
            local record={geometry=geometry,node=geometry.node,kind=kind,enabled=geometry.enabled,
                nodeEnabled=geometry.node.enabled,effective=geometry.enabledEffective,materials=originalMaterials,
                vertices=vertices(geometry),localBounds=BoundingBox(geometry:GetBoundingBox()),
                worldBounds=BoundingBox(geometry:GetWorldBoundingBox())} --[[@as RailSurfaceRecord]]
            records_[#records_+1]=record;selected_[geometry.ID]=record
        end
    end
    local counts={sleepers=0,ballast=0,steel=0}
    for _,record in ipairs(records_) do
        if record.effective then counts[record.kind]=counts[record.kind]+1 end
    end
    V.Check(counts.sleepers>0 and counts.ballast>0 and counts.steel>0,
        "白点隔离未匹配实际可见枕木/道床/钢轨CG")
    snapshotted_=true
    local technique=assert(cache:GetResource("Technique","Techniques/NoTextureUnlit.xml"),"隔离Unlit技术缺失")
    unlit_=Material()
    unlit_:SetTechnique(0,technique)
    unlit_:SetShaderParameter("MatDiffColor",Variant(Color(.42,.42,.42,1)))
    local camera,node=assert(Camera.GetCamera()),assert(Camera.GetNode())
    camera_,cameraNode_=camera,node
    local readings=Hud.GetReadings()
    local mesh,nodes=meshSignature()
    baseline_={s=Train.GetS(),eye=node.worldPosition,direction=node.worldDirection,fov=camera.fov,
        nearClip=camera.nearClip,farClip=camera.farClip,mask=camera.viewMask,width=graphics:GetWidth(),
        height=graphics:GetHeight(),dpr=graphics:GetDPR(),trafficElapsed=Traffic.GetStats().elapsed,
        simulation=GetFrameSimulationStats().total,gameElapsed=Game.GetElapsed(),station=readings.stationName,
        distance=readings.nextStation,quality=GetRenderQuality(),nodes=nodes,mesh=mesh,renderer=rendererIdentity(),
        trainId=Train.GetSelectedId(),trainRoot=assert(Train.GetRoot()).ID}
    V.Census(scene,"surface_isolation_baseline")
    print(string.format("[RailSurface] SAVED meshes=%d effectiveSleepers=%d effectiveBallast=%d effectiveSteel=%d drainCalls=%d",
        #records_,counts.sleepers,counts.ballast,counts.steel,drainCalls_))
end

local function checkIdentity()
    local viewport=assert(renderer:GetViewport(0))
    local camera,node=assert(camera_),assert(cameraNode_)
    local readings=Hud.GetReadings()
    V.Check(viewport.scene==scene_ and viewport.camera==camera and Camera.GetCamera()==camera
        and Camera.GetNode()==node,"白点隔离更换scene/camera身份")
    V.Check(Camera.GetMode()=="birdseye" and readings.selectedCameraId=="birdseye" and readings.paused,
        "白点隔离不再是暂停首站birdseye")
    V.Near(Train.GetS(),baseline_.s,.0001,"白点隔离改变列车位置")
    V.Check(Train.GetSelectedId()==baseline_.trainId and assert(Train.GetRoot()).ID==baseline_.trainRoot,
        "白点隔离替换真实车型/列车")
    V.Point(node.worldPosition,baseline_.eye,.002,"白点隔离相机位置漂移")
    V.Point(node.worldDirection,baseline_.direction,.00002,"白点隔离相机方向漂移")
    V.Near(camera.fov,baseline_.fov,.0001,"白点隔离FOV变化")
    V.Near(camera.nearClip,baseline_.nearClip,.00001,"白点隔离nearClip变化")
    V.Near(camera.farClip,baseline_.farClip,.00001,"白点隔离farClip变化")
    V.Check(camera.viewMask==baseline_.mask and graphics:GetWidth()==baseline_.width
        and graphics:GetHeight()==baseline_.height,"白点隔离viewMask/实际分辨率变化")
    V.Near(graphics:GetDPR(),baseline_.dpr,.00001,"白点隔离DPR变化")
    V.Check(readings.stationName==baseline_.station and readings.nextStation==baseline_.distance,
        "白点隔离HUD站名/距离变化")
    V.Near(Traffic.GetStats().elapsed,baseline_.trafficElapsed,.00001,"白点隔离推进AI逻辑")
    V.Near(GetFrameSimulationStats().total,baseline_.simulation,.00001,"白点隔离推进main模拟")
    V.Near(Game.GetElapsed(),baseline_.gameElapsed,.00001,"白点隔离推进运营时间")
    V.Check(rendererIdentity()==baseline_.renderer,"白点隔离改变画质/阴影/镜面/实例化")
    V.Check(Stream.GetStats().pendingTasks==0,"白点隔离重新积欠流式队列")
    local mesh,nodes=meshSignature()
    V.Check(mesh==baseline_.mesh and nodes==baseline_.nodes,
        "白点隔离删改其他mesh/节点/材质/姿态/包围盒")
    local active=cases_[caseIndex_]
    for _,record in ipairs(records_) do
        local visible=record.enabled
        if active and stage_~="restore_hold" then
            if record.kind=="sleepers" and not active.sleepers then visible=false end
            if record.kind=="ballast" and not active.ballast then visible=false end
        end
        V.Check(record.geometry.enabled==visible and record.node.enabled==record.nodeEnabled,
            "白点隔离CG enabled变化超出当前case："..record.node.name)
        for slot=0,#record.materials-1 do
            local expected=active and active.unlit and stage_~="restore_hold" and unlit_ or record.materials[slot+1]
            V.Check(record.geometry:GetMaterial(slot)==expected,"隔离原材质/Unlit引用未按case保持")
        end
    end
end

local function printCase(phase)
    local counts={sleepers=0,ballast=0,steel=0}
    local totalVertices=0
    local bounds=BoundingBox()
    for _,record in ipairs(records_) do
        local g=record.geometry
        if g.enabledEffective then
            counts[record.kind]=counts[record.kind]+1
            totalVertices=totalVertices+record.vertices
            bounds:Merge(g:GetWorldBoundingBox())
        end
    end
    local eye=assert(cameraNode_).worldPosition
    local active=cases_[caseIndex_]
    print(string.format("[RailSurface] IDENTITY phase=%s case=%d name=%s frame=%d scene=%s camera=%s trainRoot=%d s=%.6f eye=%s direction=%s fov=%.3f near=%.3f far=%.3f mask=%d size=%dx%d DPR=%.3f HUD=%s/%s quality=%s",
        phase,caseIndex_,active and active.name or "restored",frame_,tostring(scene_),tostring(camera_),
        baseline_.trainRoot,Train.GetS(),vectorText(eye),vectorText(assert(cameraNode_).worldDirection),
        assert(camera_).fov,assert(camera_).nearClip,assert(camera_).farClip,assert(camera_).viewMask,
        graphics:GetWidth(),graphics:GetHeight(),graphics:GetDPR(),baseline_.station,baseline_.distance,GetRenderQuality()))
    print(string.format("[RailSurface] RENDERER batches=%d primitives=%d shadowMaps=%d shadows=%s specular=%s materialQuality=%d instancing=%s meshes=%d enabledSleepers=%d enabledBallast=%d enabledSteel=%d enabledVertices=%d bbox=%s",
        renderer.numBatches,renderer.numPrimitives,renderer:GetNumShadowMaps(true),tostring(renderer.drawShadows),
        tostring(renderer.specularLighting),renderer.materialQuality,tostring(renderer.dynamicInstancing),#records_,
        counts.sleepers,counts.ballast,counts.steel,totalVertices,boundsText(bounds)))
    for _,record in ipairs(records_) do
        local g=record.geometry
        local mats={}
        for slot=0,g.numGeometries-1 do mats[#mats+1]=tostring(g:GetMaterial(slot)) end
        print(string.format("[RailSurface] MESH cg=%d node=%d name=%s kind=%s enabled=%s effective=%s inView=%s vertices=%d nodeWorld=%s localBBox=%s worldBBox=%s originalMaterial=%s currentMaterial=%s",
            g.ID,record.node.ID,record.node.name,record.kind,tostring(g.enabled),tostring(g.enabledEffective),
            tostring(g.inView),record.vertices,vectorText(record.node.worldPosition),boundsText(record.localBounds),
            boundsText(g:GetWorldBoundingBox()),tostring(record.materials[1]),table.concat(mats,",")))
    end
end

local function activate(index)
    V.Check(frame_>=120 and (index==1 or holdFrames_==2),"隔离case提前或未完成hold2")
    restore() -- Every case starts from the saved ORIGINAL, never accumulates prior masks/materials.
    caseIndex_,rendered_,attempts_,holdFrames_=index,0,0,0
    local active=assert(cases_[index])
    for _,record in ipairs(records_) do
        if record.kind=="sleepers" and not active.sleepers or record.kind=="ballast" and not active.ballast then
            record.geometry:SetEnabled(false)
        end
        if active.unlit then
            local material=assert(unlit_)
            for slot=0,#record.materials-1 do record.geometry:SetMaterial(slot,material) end
        end
    end
    stage_="settle"
    checkIdentity();printCase("activated")
end

local function verifyPNG(path,image)
    local file=File(path,FILE_READ)
    V.Check(file:IsOpen() and file:GetSize()>256,"白点隔离PNG不可读/为空")
    for _,byte in ipairs({137,80,78,71,13,10,26,10}) do V.Check(file:ReadUByte()==byte,"隔离文件不是PNG") end
    local decoded=Image()
    V.Check(decoded:Load(path),"隔离PNG回读解码失败")
    V.Check(decoded.width==baseline_.width and decoded.height==baseline_.height
        and image.width==decoded.width and image.height==decoded.height,"隔离PNG不是实际渲染尺寸")
    print(string.format("[RailSurface] PNG_CHECK path=%s bytes=%d checksum=%s",path,file:GetSize(),tostring(file:GetChecksum())))
    decoded:Dispose();file:Dispose()
end

local function capture()
    V.Check(frame_>=120 and rendered_>=8 and captures_<5 and not pendingImage_,"隔离截图提前/重复/超过五张")
    busy_=true
    checkIdentity();printCase("before_capture")
    local image=Image()
    pendingImage_=image
    attempts_=attempts_+1
    if not graphics:TakeScreenShot(image) then
        image:Dispose();pendingImage_=nil;busy_=false
        V.Check(attempts_<4,"隔离四次有界EndRendering截图失败")
        return
    end
    local path=OUTPUT..assert(cases_[caseIndex_]).name..".png"
    V.Check(image:SavePNG(path),"隔离截图PNG未保存")
    verifyPNG(path,image)
    checkIdentity();printCase("after_capture")
    captures_,captureFrame_,holdFrames_=captures_+1,frame_,0
    stage_,busy_="hold",false
    print(string.format("[RailSurface] REAL_SCREENSHOT %d/5 %s frame=%d settleRenderingFrames=%d attempt=%d",
        captures_,path,frame_,rendered_,attempts_))
end

function Start()
    guarded(function()
        V.Phase("surface_main_start",startGame)
        scene_=assert(renderer:GetViewport(0).scene)
        V.Check(graphics:GetWidth()==640 and graphics:GetHeight()==360,"白点隔离要求真实640x360启动尺寸")
        V.Near(Train.GetS(),Route.GetStations()[1].s+1,.001,"白点隔离不在真实首站")
        V.Check(Train.GetCarCount()==8,"白点隔离实际编组不是八车")
        V.Check(not Hud.GetReadings().paused,"隔离入口意外已暂停，不能盲Toggle")
        TogglePause()
        V.Check(Camera.SetMode("birdseye"),"隔离真实birdseye不可用")
        Camera.Update(.05,Train.GetS())
        Hud.SetCameraMode(Camera.GetMode(),Camera.GetModeName())
        Game.UpdateHud(0);UI.Layout()
        if not fileSystem:DirExists(OUTPUT) then V.Check(fileSystem:CreateDir(OUTPUT),"隔离内部截图目录不可创建") end
        SubscribeToEvent("EndRendering","HandleRailSurfaceRendering")
        print("[RailSurface] Five isolated real framesets; only Track-owned named CGs may change. PASS is not an art-quality claim.")
    end)
end

---@param eventType string
---@param eventData UpdateEventData
function HandleUpdate(eventType,eventData)
    guarded(function()
        frame_=frame_+1
        V.Check(frame_<=198,"白点隔离未在200帧预算内完成五截图和恢复")
        updateGame(eventType,eventData)
    end)
end
---@param eventType string
---@param eventData PostUpdateEventData
function HandlePostUpdate(eventType,eventData)
    guarded(function()
        postUpdateGame(eventType,eventData)
        if stage_=="bootstrap" and frame_<120 then
            V.Phase("surface_bounded_stream_drain",function()
                for _=1,64 do
                    if Stream.GetStats().pendingTasks==0 then break end
                    Stream.Update(Train.GetS(),0);drainCalls_=drainCalls_+1
                end
            end)
        elseif stage_=="activate" then activate(caseIndex_+1)
        elseif stage_=="restore" then
            restore();stage_="restore_hold";restoreRendered_=0
            checkIdentity();printCase("restored_original")
        end
    end)
end

local function rendering()
    if busy_ or lastRenderingFrame_==frame_ then return end
    lastRenderingFrame_=frame_
    if stage_=="bootstrap" then
        if frame_<120 then return end
        V.Check(frame_==120 and Stream.GetStats().pendingTasks==0,"120帧前有界流式未收敛")
        local traffic=Traffic.GetStats()
        V.Check((traffic.errors or 0)==0,"白点隔离AI资源失败")
        snapshot();stage_="activate"
        return
    end
    if stage_=="activate" or stage_=="restore" then return end
    checkIdentity()
    if stage_=="settle" then
        rendered_=rendered_+1
        if rendered_>=8 then capture() end
    elseif stage_=="hold" then
        V.Check(frame_>captureFrame_,"成功截图同帧重复计入hold2")
        holdFrames_=holdFrames_+1
        printCase("capture_hold_"..holdFrames_)
        if holdFrames_==2 then
            verifyPNG(OUTPUT..assert(cases_[caseIndex_]).name..".png",assert(pendingImage_))
            pendingImage_:Dispose();pendingImage_=nil
            stage_=caseIndex_==#cases_ and "restore" or "activate"
        end
    elseif stage_=="restore_hold" then
        restoreRendered_=restoreRendered_+1
        if restoreRendered_==2 then
            V.Check(captures_==5,"白点隔离没有恰好五张内部截图")
            printCase("restore_hold2")
            if unlit_ then unlit_:Dispose();unlit_=nil end
            complete_=true
            print(string.format("ALL_RAIL_SURFACE_PROTOCOL_PASS screenshots=5 restored=true frame=%d assertions=%d drainCalls=%d",
                frame_,V.checks,drainCalls_))
            print("[RailSurface] Inspect all five PNGs for white-point sources; no claim of removal, no mobile FPS claim.")
        end
    end
end
---@param eventType string
---@param eventData EndRenderingEventData
function HandleRailSurfaceRendering(eventType,eventData) guarded(rendering) end
function Stop()
    restore()
    if pendingImage_ then pendingImage_:Dispose();pendingImage_=nil end
    if unlit_ then unlit_:Dispose();unlit_=nil end
    snapshotted_=false
    if stopGame then stopGame() end
end
