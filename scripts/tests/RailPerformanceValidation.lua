-- Real 640x360 quality A/B validation; authoring never runs Runtime/build.
-- Coordinator invocation after LSP/build (serial GPU use):
-- LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe EGL_PLATFORM=surfaceless
-- /workspace/.cli/UrhoXRuntime tests/RailPerformanceValidation.lua -tapcode_dir=/workspace
-- -tool_mode -graphicssurfaceless -validate -validate-frames=220 -validate-timeout=600
-- -x 640 -y 360；保持默认100ms尖峰阈值，框架失败不得当作性能达标。
-- Two internal screenshots only; do not add a command-line screenshot flag.
require "main"
local startGame,updateGame,postUpdateGame=Start,HandleUpdate,HandlePostUpdate
local getQuality,setQuality=GetRenderQuality,SetRenderQuality
-- Static tolua binding checks its first Lua argument as the Time class table.
-- Use Time:GetSystemTime() (equivalent to Time.GetSystemTime(Time)), not the
-- `time` instance. Timer.d.lua currently loses this static receiver distinction.
local function systemTime() return Time:GetSystemTime() end
-- GetElapsedTime IS an instance method (documented examples/UI library use it).
-- Import helpers only: this module defines Start but does not execute it.
local V=require "tests.RailOperationsValidation"
local Train=require "train.Train"
local Route=require "world.Route"
local Camera=require "train.Camera"
local Hud=require "ui.Hud"
local Game=require "game.Game"
local Stream=require "world.WorldStream"
local Traffic=require "game.Traffic"
local UI=require "urhox-libs/UI"

-- 原入口保留逐帧完整mesh核对；独立连续采样入口在采样前后核对相同内容。
-- 两种模式都保留默认100ms框架阈值，绝不从wallFrameMs里扣掉检查耗时伪造FPS。
local boundaryAudit_ = rawget(_G, "RailPerformanceContinuousSampling") == true
local fullAudits_ = 0

---@class RailPerformanceSample
---@field frame integer
---@field elapsed number
---@field elapsedDelta number
---@field wallFrameMs number
---@field timeStep number
---@field batches integer
---@field primitives integer
---@field shadowMaps integer
---@field updateMs number
---@field postUpdateMs number
---@field validationMs number
---@class RailPerformanceRecord
---@field quality string
---@field samples RailPerformanceSample[]
local records_={
    performance={quality="performance",samples={}},
    detailed={quality="detailed",samples={}},
} --[[@as table<string,RailPerformanceRecord>]]
---@type Scene?
local scene_=nil
---@type Camera?
local camera_=nil
---@type Node?
local cameraNode_=nil
---@type Image?
local pendingImage_=nil
---@class RailMeshDiagnostic
---@field key string
---@field kind string
---@field drawableId integer
---@field nodeId integer
---@field path string
---@field values table<string,string>
---@field order string[]
---@field refs table<string,any>
---@type table<string,RailMeshDiagnostic>
local baselineMeshDetails_={}
---@type table<number,string>
local baselineNodeNames_={}
local baseline_={s=0,width=0,height=0,dpr=0,eye=Vector3.ZERO,direction=Vector3.FORWARD,
    fov=0,nearClip=0,farClip=0,viewMask=0,mesh="",nodes=0,station="",distance="",trafficElapsed=0}
local stage_,quality_="bootstrap","performance"
local frame_,lastRenderingFrame_,stageStart_,captures_,attempts_,captureFrame_,holdFrames_=0,-1,0,0,0,-1,0
local failed_,complete_,captureBusy_=false,false,false
local previousElapsed_,previousWall_,timeStep_,updateMs_,postUpdateMs_,drainSlices_=0,0,0,0,0,0
local bootstrap_={frames=0,sumDt=0,maxDt=0,sumWallMs=0,maxWallMs=0}
local OUTPUT="/workspace/screenshots/"

---@param action fun()
local function guarded(action)
    if failed_ or complete_ then return end
    local ok,message=xpcall(action,debug.traceback)
    if not ok then
        failed_,captureBusy_=true,false
        if pendingImage_ then pendingImage_:Dispose();pendingImage_=nil end
        print(string.format("[RailPerformance] FAILED stage=%s frame=%d screenshots=%d/2",stage_,frame_,captures_))
        log:Write(LOG_ERROR,tostring(message))
        error(message,0) -- First failure stays a validation failure; later handlers cannot print PASS.
    end
end

---@param quality string
local function checkQuality(quality)
    local detailed=quality=="detailed"
    local readings=Hud.GetReadings()
    V.Check(getQuality()==quality and readings.renderQuality==(detailed and "细致" or "流畅"),
        "真实画质状态与HUD不一致："..quality)
    V.Check(renderer.drawShadows==detailed and renderer.specularLighting==detailed,
        "画质只有文字变化，没有改变实时阴影/镜面开关："..quality)
    V.Check(renderer.materialQuality==(detailed and QUALITY_HIGH or QUALITY_MEDIUM),
        "实际材质质量档没有切换："..quality)
    V.Check(renderer.dynamicInstancing and renderer.shadowMapSize==1024,
        "画质对照改变了实例化/阴影贴图既定设置")
    V.Near(assert(Camera.GetCamera()).lodBias,1,.00001,"画质切换降低了玩家相机LOD")
end

-- Mesh census includes actual resource identities, all model LOD draw ranges,
-- procedural vertex counts, drawable visibility/LOD and world poses. Quality
-- cannot get a false win by disposing/hiding/replacing geometry between samples.
-- Engine geometry slots are 0-based API indices, not Lua array indices.
---@return string, integer, table<string,RailMeshDiagnostic>, table<number,string>
local function meshSignature()
    local scene=assert(scene_)
    local rows={}
    local details={} ---@type table<string,RailMeshDiagnostic>
    local nodeNames={} ---@type table<number,string>
    local seen={} ---@type table<number,boolean>
    ---@param node Node
    local function nodePath(node)
        local names={node.name.."#"..tostring(node.ID)}
        local parent=node.parent
        while parent do
            names[#names+1]=parent.name.."#"..tostring(parent.ID)
            parent=parent.parent
        end
        return table.concat(names," <- ")
    end
    nodeNames[scene.ID]=nodePath(scene)
    for _,node in ipairs(scene:GetChildren(true)) do nodeNames[node.ID]=nodePath(node) end
    ---@param entry RailMeshDiagnostic
    ---@param field string
    ---@param value any
    local function add(entry,field,value)
        entry.order[#entry.order+1]=field
        entry.values[field]=tostring(value)
    end
    local function newEntry(drawable,kind)
        local entry={key=kind..":"..tostring(drawable.ID),kind=kind,drawableId=drawable.ID,
            nodeId=drawable.node.ID,path=nodePath(drawable.node),values={},order={},refs={}}
            --[[@as RailMeshDiagnostic]]
        details[entry.key]=entry
        return entry
    end
    local function drawableRow(drawable,entry)
        local node=drawable.node
        local p,d,s=node.worldPosition,node.worldDirection,node.worldScale
        add(entry,"enabled",drawable.enabled);add(entry,"enabledEffective",drawable.enabledEffective)
        add(entry,"viewMask",drawable.viewMask);add(entry,"lodBias",string.format("%.6f",drawable.lodBias))
        add(entry,"drawDistance",string.format("%.3f",drawable.drawDistance))
        add(entry,"shadowDistance",string.format("%.3f",drawable.shadowDistance));add(entry,"castShadows",drawable.castShadows)
        for _,axis in ipairs({"x","y","z"}) do
            add(entry,"worldPosition."..axis,string.format("%.6f",p[axis]))
            add(entry,"worldDirection."..axis,string.format("%.6f",d[axis]))
            add(entry,"worldScale."..axis,string.format("%.6f",s[axis]))
        end
        return string.format("%d:%d:%s:%s:%d:%.6f:%.3f:%.3f:%s:%.6f,%.6f,%.6f:%.6f,%.6f,%.6f:%.6f,%.6f,%.6f",
            drawable.ID,node.ID,tostring(drawable.enabled),tostring(drawable.enabledEffective),drawable.viewMask,
            drawable.lodBias,drawable.drawDistance,drawable.shadowDistance,tostring(drawable.castShadows),
            p.x,p.y,p.z,d.x,d.y,d.z,s.x,s.y,s.z)
    end
    local function modelRow(drawable)
        if seen[drawable.ID] then return end
        seen[drawable.ID]=true
        local model=assert(drawable.model,"实际StaticModel没有模型")
        local entry=newEntry(drawable,"model")
        local parts={drawableRow(drawable,entry),tostring(model),tostring(model.numGeometries)}
        entry.refs.model=model
        add(entry,"model.identity",tostring(model));add(entry,"model.name",model.name)
        add(entry,"model.numGeometries",model.numGeometries)
        for slot=0,model.numGeometries-1 do
            local levels=model:GetNumGeometryLodLevels(slot)
            parts[#parts+1]=tostring(levels)
            add(entry,"slot["..slot.."].lodLevels",levels)
            for lod=0,levels-1 do
                local geometry=assert(model:GetGeometry(slot,lod))
                local prefix="slot["..slot.."].lod["..lod.."]"
                entry.refs[prefix..".geometry"]=geometry
                add(entry,prefix..".geometry",tostring(geometry));add(entry,prefix..".vertexCount",geometry.vertexCount)
                add(entry,prefix..".indexCount",geometry.indexCount)
                add(entry,prefix..".lodDistance",string.format("%.5f",geometry.lodDistance))
                parts[#parts+1]=string.format("%s:%d:%d:%.5f",tostring(geometry),
                    geometry.vertexCount,geometry.indexCount,geometry.lodDistance)
            end
        end
        rows[#rows+1]=table.concat(parts,"|")
    end
    for _,drawable in ipairs(scene:GetComponents("StaticModel",true)) do modelRow(drawable) end
    for _,group in ipairs(scene:GetComponents("StaticModelGroup",true)) do
        modelRow(group)
        local entry=newEntry(group,"instances")
        add(entry,"instanceCount",group.numInstanceNodes)
        local instances={"instances",tostring(group.ID),tostring(group.numInstanceNodes)}
        for index=0,group.numInstanceNodes-1 do
            local node=assert(group:GetInstanceNode(index))
            local p,s=node.worldPosition,node.worldScale
            local prefix="instance["..index.."]"
            add(entry,prefix..".nodeId",node.ID);add(entry,prefix..".path",nodePath(node))
            for _,axis in ipairs({"x","y","z"}) do
                add(entry,prefix..".worldPosition."..axis,string.format("%.6f",p[axis]))
                add(entry,prefix..".worldScale."..axis,string.format("%.6f",s[axis]))
            end
            instances[#instances+1]=string.format("%d:%.6f,%.6f,%.6f:%.6f,%.6f,%.6f",
                node.ID,p.x,p.y,p.z,s.x,s.y,s.z)
        end
        rows[#rows+1]=table.concat(instances,"|")
    end
    for _,geometry in ipairs(scene:GetComponents("CustomGeometry",true)) do
        local entry=newEntry(geometry,"procedural")
        local parts={drawableRow(geometry,entry),"procedural",tostring(geometry.numGeometries)}
        add(entry,"numGeometries",geometry.numGeometries)
        for slot=0,geometry.numGeometries-1 do
            local vertices=geometry:GetNumVertices(slot)
            parts[#parts+1]=tostring(vertices)
            add(entry,"slot["..slot.."].vertices",vertices)
        end
        rows[#rows+1]=table.concat(parts,"|")
    end
    table.sort(rows)
    return table.concat(rows,"\n"),#scene:GetChildren(true)+1,details,nodeNames
end

-- Diagnostics do not normalize identities, skip groups or relax mesh equality.
-- The first bounded field diff distinguishes actual motion/visibility from a
-- Model/Geometry wrapper identity change while retaining the original failure.
---@param mesh string
---@param nodes integer
---@param details table<string,RailMeshDiagnostic>
---@param nodeNames table<number,string>
local function printMeshDiff(mesh,nodes,details,nodeNames)
    print(string.format("[RailPerformance] MESH_DIFF frame=%d nodes=%d->%d meshEqual=%s bytes=%d->%d trafficElapsed=%.9f->%.9f",
        frame_,baseline_.nodes,nodes,tostring(mesh==baseline_.mesh),#baseline_.mesh,#mesh,
        baseline_.trafficElapsed,Traffic.GetStats().elapsed))
    local nodeChanges=0
    for id,path in pairs(baselineNodeNames_) do
        if not nodeNames[id] and nodeChanges<4 then
            print(string.format("[RailPerformance] NODE_REMOVED id=%d path=%s",id,path));nodeChanges=nodeChanges+1
        end
    end
    for id,path in pairs(nodeNames) do
        if not baselineNodeNames_[id] and nodeChanges<4 then
            print(string.format("[RailPerformance] NODE_ADDED id=%d path=%s",id,path));nodeChanges=nodeChanges+1
        end
    end
    local oldRows,newRows={},{}
    for row in baseline_.mesh:gmatch("[^\n]+") do oldRows[#oldRows+1]=row end
    for row in mesh:gmatch("[^\n]+") do newRows[#newRows+1]=row end
    local firstKey=""
    for index=1,math.max(#oldRows,#newRows) do
        if oldRows[index]~=newRows[index] then
            local row=oldRows[index] or newRows[index] or ""
            local instanceId=row:match("^instances|(%d+)|")
            local drawableId=row:match("^(%d+):")
            if instanceId then firstKey="instances:"..instanceId
            elseif drawableId then
                firstKey=(row:find("|procedural|",1,true) and "procedural:" or "model:")..drawableId
            end
            print(string.format("[RailPerformance] FIRST_ROW index=%d key=%s before=%s after=%s",index,firstKey,
                (oldRows[index] or "<missing>"):sub(1,900),(newRows[index] or "<missing>"):sub(1,900)))
            break
        end
    end
    local keys,seen={},{}
    if firstKey~="" then keys[#keys+1]=firstKey;seen[firstKey]=true end
    for key in pairs(baselineMeshDetails_) do if not seen[key] then keys[#keys+1]=key;seen[key]=true end end
    for key in pairs(details) do if not seen[key] then keys[#keys+1]=key;seen[key]=true end end
    table.sort(keys,function(a,b)
        if a==firstKey then return b~=firstKey end
        if b==firstKey then return false end
        return a<b
    end)
    local printed=0
    for _,key in ipairs(keys) do
        local before,after=baselineMeshDetails_[key],details[key]
        if not before or not after then
            local entry=assert(before or after)
            print(string.format("[RailPerformance] DRAWABLE_DIFF key=%s kind=%s id=%d node=%d path=%s status=%s",
                key,entry.kind,entry.drawableId,entry.nodeId,entry.path,before and "removed" or "added"))
            printed=printed+1
        else
            for _,field in ipairs(before.order) do
                if before.values[field]~=after.values[field] then
                    local refsEqual="n/a"
                    if before.refs[field] or after.refs[field] then refsEqual=tostring(before.refs[field]==after.refs[field]) end
                    if field=="model.identity" then refsEqual=tostring(before.refs.model==after.refs.model) end
                    print(string.format("[RailPerformance] FIELD_DIFF key=%s kind=%s id=%d node=%d path=%s field=%s before=%s after=%s refsEqual=%s",
                        key,before.kind,before.drawableId,before.nodeId,before.path,field,
                        before.values[field] or "<missing>",after.values[field] or "<missing>",refsEqual))
                    printed=printed+1
                    if printed>=8 then return end
                end
            end
        end
        if printed>=8 then return end
    end
end

local function establishBaseline()
    local camera,node=assert(Camera.GetCamera()),assert(Camera.GetNode())
    camera_,cameraNode_=camera,node
    local mesh,nodes,details,nodeNames=meshSignature()
    baselineMeshDetails_,baselineNodeNames_=details,nodeNames
    local readings=Hud.GetReadings()
    baseline_={s=Train.GetS(),width=graphics:GetWidth(),height=graphics:GetHeight(),dpr=graphics:GetDPR(),
        eye=node.worldPosition,direction=node.worldDirection,fov=camera.fov,nearClip=camera.nearClip,
        farClip=camera.farClip,viewMask=camera.viewMask,mesh=mesh,nodes=nodes,
        station=readings.stationName,distance=readings.nextStation,trafficElapsed=Traffic.GetStats().elapsed}
    V.Census(assert(scene_),"quality_ab_baseline")
    print(string.format("[RailPerformance] BASELINE s=%.3f scene=%s camera=%s nodes=%d size=%dx%d DPR=%.3f drainSlices=%d",
        baseline_.s,tostring(scene_),tostring(camera_),nodes,baseline_.width,baseline_.height,baseline_.dpr,drainSlices_))
end

---@param fullAudit? boolean
local function checkIdentity(fullAudit)
    local viewport=assert(renderer:GetViewport(0))
    local camera,node=assert(camera_),assert(cameraNode_)
    local readings=Hud.GetReadings()
    V.Check(viewport.scene==scene_ and viewport.camera==camera and Camera.GetCamera()==camera
        and Camera.GetNode()==node,"性能对照更换了实际场景/相机实体")
    V.Check(Camera.GetMode()=="birdseye" and readings.selectedCameraId=="birdseye" and readings.paused,
        "性能对照离开首站鸟瞰暂停机位")
    V.Near(Train.GetS(),baseline_.s,.0001,"画质对照改变运营位置")
    V.Check(graphics:GetWidth()==baseline_.width and graphics:GetHeight()==baseline_.height,
        "性能对照期间实际分辨率变化")
    V.Near(graphics:GetDPR(),baseline_.dpr,.00001,"性能对照期间DPR变化")
    V.Point(node.worldPosition,baseline_.eye,.002,"性能对照相机位置变化")
    V.Point(node.worldDirection,baseline_.direction,.00002,"性能对照相机方向变化")
    V.Near(camera.fov,baseline_.fov,.0001,"性能对照FOV变化")
    V.Near(camera.nearClip,baseline_.nearClip,.00001,"性能对照nearClip变化")
    V.Near(camera.farClip,baseline_.farClip,.00001,"性能对照farClip变化")
    V.Check(camera.viewMask==baseline_.viewMask,"画质对照改变了实际相机可见层")
    V.Check(readings.stationName==baseline_.station and readings.nextStation==baseline_.distance,
        "性能截图HUD站名/距离发生跨场景变化")
    V.Check(Stream.GetStats().pendingTasks==0,"性能连续采样期间流式队列重新积欠")
    V.Near(Traffic.GetStats().elapsed,baseline_.trafficElapsed,.00001,"暂停对照仍推进AI逻辑")
    if not boundaryAudit_ or fullAudit then
        local auditStarted=os.clock()
        local mesh,nodes,details,nodeNames=meshSignature()
        if nodes~=baseline_.nodes or mesh~=baseline_.mesh then printMeshDiff(mesh,nodes,details,nodeNames) end
        V.Check(nodes==baseline_.nodes and mesh==baseline_.mesh,
            "画质对照删改/隐藏/替换了实际mesh或改变drawable姿态/LOD")
        fullAudits_=fullAudits_+1
        if boundaryAudit_ then
            print(string.format("[RailPerformance] FULL_AUDIT count=%d frame=%d stage=%s cpuMs=%.3f equal=true",
                fullAudits_,frame_,stage_,(os.clock()-auditStarted)*1000))
        end
    end
    checkQuality(quality_)
end

---@param phase string
local function printIdentity(phase)
    local readings=Hud.GetReadings()
    local eye=assert(cameraNode_).worldPosition
    print(string.format("[RailPerformance] IDENTITY phase=%s quality=%s frame=%d scene=%s camera=%s s=%.3f eye=(%.3f,%.3f,%.3f) HUD=%s/%s qualityLabel=%s shadows=%s specular=%s materialQuality=%d size=%dx%d DPR=%.3f",
        phase,getQuality(),frame_,tostring(scene_),tostring(camera_),Train.GetS(),eye.x,eye.y,eye.z,
        readings.stationName,readings.nextStation,readings.renderQuality,tostring(renderer.drawShadows),
        tostring(renderer.specularLighting),renderer.materialQuality,graphics:GetWidth(),graphics:GetHeight(),graphics:GetDPR()))
end

---@param path string
---@param image Image
local function verifyPNG(path,image)
    local file=File(path,FILE_READ)
    V.Check(file:IsOpen() and file:GetSize()>256,"性能真实PNG不可读/为空")
    for _,byte in ipairs({137,80,78,71,13,10,26,10}) do V.Check(file:ReadUByte()==byte,"性能落盘文件不是PNG") end
    local decoded=Image()
    V.Check(decoded:Load(path),"性能真实PNG解码失败")
    V.Check(decoded.width==baseline_.width and decoded.height==baseline_.height
        and image.width==decoded.width and image.height==decoded.height,"性能PNG不是实际640对照尺寸")
    local darkest,brightest=math.huge,-math.huge
    for y=1,6 do
        for x=1,10 do
            local pixel=decoded:GetPixel(math.floor(decoded.width*x/11),math.floor(decoded.height*y/7))
            local value=pixel.r*.2126+pixel.g*.7152+pixel.b*.0722
            darkest,brightest=math.min(darkest,value),math.max(brightest,value)
        end
    end
    V.Check(brightest-darkest>.035 and brightest>.08,"性能截图为空黑/单色帧")
    print(string.format("[RailPerformance] PNG_CHECK path=%s bytes=%d checksum=%s",path,file:GetSize(),tostring(file:GetChecksum())))
    decoded:Dispose();file:Dispose()
end

local function capture()
    V.Check(frame_>=120 and captures_<2 and not pendingImage_,"性能截图提前/重复或超过两张上限")
    captureBusy_=true
    printIdentity("before_capture")
    local image=Image()
    pendingImage_=image
    attempts_=attempts_+1
    if not graphics:TakeScreenShot(image) then
        image:Dispose();pendingImage_=nil;captureBusy_=false
        V.Check(attempts_<4,"性能真实截图四次有界读回失败")
        return
    end
    V.Check(image.width==baseline_.width and image.height==baseline_.height,"性能截图实际尺寸不一致")
    local path=OUTPUT.."rail_performance_"..quality_..".png"
    V.Check(image:SavePNG(path),"性能真实PNG保存失败")
    verifyPNG(path,image)
    checkIdentity(true);printIdentity("after_capture")
    captures_,captureFrame_,holdFrames_=captures_+1,frame_,0
    stage_,captureBusy_="capture_hold",false
    print(string.format("[RailPerformance] REAL_SCREENSHOT %d/2 %s frame=%d attempt=%d",captures_,path,frame_,attempts_))
    -- Retain this Image and the same scene/quality through two distinct rendered frames.
end

---@param quality string
local function printSummary(quality)
    local record=assert(records_[quality])
    local fields={"timeStep","elapsedDelta","wallFrameMs","batches","primitives","shadowMaps","updateMs","postUpdateMs","validationMs"}
    V.Check(#record.samples>=20,"性能档位没有20个连续稳定真实渲染样本："..quality)
    print(string.format("[RailPerformance] SUMMARY quality=%s frames=%d first=%d last=%d",
        quality,#record.samples,record.samples[1].frame,record.samples[#record.samples].frame))
    for _,field in ipairs(fields) do
        local sum,lowest,highest=0,math.huge,-math.huge
        for _,sample in ipairs(record.samples) do
            local value=sample[field]
            sum,lowest,highest=sum+value,math.min(lowest,value),math.max(highest,value)
        end
        print(string.format("[RailPerformance] STAT quality=%s field=%s mean=%.6f min=%.6f max=%.6f",quality,field,sum/#record.samples,lowest,highest))
    end
end

function Start()
    guarded(function()
        local startedCpu,startedWall=os.clock(),systemTime()
        V.Phase("performance_main_start",startGame)
        print(string.format("[RailPerformance] INITIALIZATION mainStartCpuMs=%.3f mainStartWallMs=%.3f separateFromStableSamples=true",
            (os.clock()-startedCpu)*1000,systemTime()-startedWall))
        scene_=assert(renderer:GetViewport(0).scene)
        V.Check(graphics:GetWidth()==640 and graphics:GetHeight()==360,
            "性能对照必须由启动参数提供真实640x360；禁止SetMode/缩图伪造")
        V.Check(graphics:GetDPR()>0,"性能对照DPR无效")
        V.Check(Train.GetSelectedId()=="CR400AF" and Train.GetCarCount()==8,"性能对照不是原八车EMU")
        V.Near(Train.GetS(),Route.GetStations()[1].s+1,.001,"性能对照主入口未位于真实首站")
        TogglePause()
        V.Check(Camera.SetMode("birdseye"),"性能对照真实鸟瞰机位不可用")
        Camera.Update(.05,Train.GetS())
        Hud.SetCameraMode(Camera.GetMode(),Camera.GetModeName())
        V.Check(setQuality("performance"),"性能默认档不能真实设置")
        Game.UpdateHud(0);UI.Layout()
        checkQuality("performance")
        if not fileSystem:DirExists(OUTPUT) then V.Check(fileSystem:CreateDir(OUTPUT),"性能内部截图目录不可创建") end
        previousElapsed_,previousWall_=time:GetElapsedTime(),systemTime()
        SubscribeToEvent("EndRendering","HandleRailPerformanceRendering")
        print("[RailPerformance] Real software-render A/B observations only; no phone FPS claim and no required speedup threshold.")
        print("[RailPerformance] meshAuditMode="..(boundaryAudit_ and "sample_boundaries" or "every_frame").."；连续模式不保证发现帧内临时改动，严格入口仍逐帧核对。")
    end)
end

---@param eventType string
---@param eventData UpdateEventData
function HandleUpdate(eventType,eventData)
    guarded(function()
        frame_=frame_+1
        V.Check(frame_<=218,"性能对照未在220帧预算内取得两档20稳定帧/两张真实截图")
        timeStep_=eventData:GetFloat("TimeStep")
        V.Check(timeStep_==timeStep_ and timeStep_>0 and timeStep_<math.huge,"性能真实TimeStep无效")
        local started=os.clock()
        updateGame(eventType,eventData)
        updateMs_=(os.clock()-started)*1000
    end)
end

---@param eventType string
---@param eventData PostUpdateEventData
function HandlePostUpdate(eventType,eventData)
    guarded(function()
        if stage_=="switch_detailed" or stage_=="restore_performance" then
            quality_=stage_=="switch_detailed" and "detailed" or "performance"
            V.Phase("real_quality_touch",function()
                if not Hud.GetReadings().operationsExpanded then V.Tap("toggleOperations");UI.Layout() end
                V.Tap("renderQuality")
            end)
            checkQuality(quality_)
            stage_,stageStart_=quality_=="detailed" and "shader_warm" or "restore_hold",frame_
            printIdentity("real_touch_switch")
        end
        local started=os.clock()
        postUpdateGame(eventType,eventData)
        postUpdateMs_=(os.clock()-started)*1000
        if stage_=="bootstrap" then
            V.Phase("performance_bounded_stream_drain",function()
                for _=1,64 do
                    if Stream.GetStats().pendingTasks==0 then break end
                    Stream.Update(Train.GetS(),0);drainSlices_=drainSlices_+1
                end
            end)
        end
    end)
end

local function rendering()
    if captureBusy_ or lastRenderingFrame_==frame_ then return end
    lastRenderingFrame_=frame_
    local elapsed,wall=time:GetElapsedTime(),systemTime()
    V.Check(graphics:GetWidth()==640 and graphics:GetHeight()==360,
        "性能真实640x360尺寸在初始化/采样期间改变")
    local elapsedDelta,wallDelta=elapsed-previousElapsed_,wall-previousWall_
    previousElapsed_,previousWall_=elapsed,wall
    if stage_=="bootstrap" then
        bootstrap_.frames=bootstrap_.frames+1
        bootstrap_.sumDt,bootstrap_.maxDt=bootstrap_.sumDt+timeStep_,math.max(bootstrap_.maxDt,timeStep_)
        bootstrap_.sumWallMs,bootstrap_.maxWallMs=bootstrap_.sumWallMs+wallDelta,math.max(bootstrap_.maxWallMs,wallDelta)
        if frame_<=4 then
            print(string.format("[RailPerformance] STARTUP_FRAME frame=%d elapsed=%.6f wallMs=%.3f dt=%.6f excludedFromStableSamples=true",
                frame_,elapsed,wallDelta,timeStep_))
        end
        if frame_<120 then return end
        print(string.format("[RailPerformance] BOOTSTRAP frames=%d meanDt=%.6f maxDt=%.6f meanWallMs=%.3f maxWallMs=%.3f externalSpikeThreshold=runtime_default",
            bootstrap_.frames,bootstrap_.sumDt/bootstrap_.frames,bootstrap_.maxDt,
            bootstrap_.sumWallMs/bootstrap_.frames,bootstrap_.maxWallMs))
        local stats=Stream.GetStats()
        V.Check(stats.pendingTasks==0 and stats.stationChunks<=1 and stats.cityChunks<=1,
            "120帧前局部流式未有界收敛或累积多站城市")
        local traffic=Traffic.GetStats()
        V.Check((traffic.errors or 0)==0 and traffic.visible>0 and traffic.clonedCars==traffic.visible*8,
            "性能对照真实AI八车克隆尚未补齐/资源失败")
        establishBaseline()
        stage_,stageStart_=boundaryAudit_ and "baseline_hold" or "measure",frame_
        return
    end
    local started=os.clock()
    checkIdentity()
    local validationMs=(os.clock()-started)*1000
    V.Check(elapsed==elapsed and elapsedDelta>=0 and wallDelta>=0,"性能真实帧计时倒退/无效")
    if stage_=="baseline_hold" or stage_=="shader_warm" then
        local warmFrames=stage_=="baseline_hold" and 3 or 10
        if frame_-stageStart_>=warmFrames then
            if boundaryAudit_ then
                checkIdentity(true)
                stage_,stageStart_="audit_hold",frame_
            else stage_,stageStart_="measure",frame_ end
        end
        return
    end
    if stage_=="audit_hold" then
        -- 完整核对后保留两个真实渲染帧，不让其开销落入第一个连续样本。
        if frame_-stageStart_>=2 then stage_,stageStart_="measure",frame_ end
        return
    end
    if stage_=="measure" then
        local record=assert(records_[quality_])
        local previous=record.samples[#record.samples]
        V.Check(not previous or frame_==previous.frame+1,"性能统计不是连续稳定真实渲染帧")
        local sample={frame=frame_,elapsed=elapsed,elapsedDelta=elapsedDelta,wallFrameMs=wallDelta,timeStep=timeStep_,
            batches=renderer.numBatches,primitives=renderer.numPrimitives,shadowMaps=renderer:GetNumShadowMaps(true),
            updateMs=updateMs_,postUpdateMs=postUpdateMs_,validationMs=validationMs} --[[@as RailPerformanceSample]]
        V.Check(sample.batches>0 and sample.primitives>0 and sample.shadowMaps>=0,"性能统计没有真实渲染工作量")
        record.samples[#record.samples+1]=sample
        print(string.format("[RailPerformance] FRAME quality=%s frame=%d elapsed=%.6f elapsedDelta=%.6f wallMs=%.3f dt=%.6f batches=%d primitives=%d shadowMaps=%d updateMs=%.3f postMs=%.3f validationMs=%.3f",
            quality_,frame_,elapsed,elapsedDelta,wallDelta,timeStep_,sample.batches,sample.primitives,sample.shadowMaps,
            updateMs_,postUpdateMs_,validationMs))
        if #record.samples==20 then stage_,attempts_="capture",0 end
    elseif stage_=="capture" then
        capture()
    elseif stage_=="capture_hold" then
        V.Check(frame_>captureFrame_,"性能成功截图同帧重复计为锁存帧")
        holdFrames_=holdFrames_+1;printIdentity("hold")
        if holdFrames_>=2 then
            local image=assert(pendingImage_)
            verifyPNG(OUTPUT.."rail_performance_"..quality_..".png",image)
            image:Dispose();pendingImage_=nil
            stage_=quality_=="performance" and "switch_detailed" or "restore_performance"
        end
    elseif stage_=="restore_hold" and frame_-stageStart_>=2 then
        V.Check(captures_==2,"性能对照缺少两张真实截图")
        checkIdentity(true)
        if boundaryAudit_ then V.Check(fullAudits_>=5,"连续采样缺少前后完整几何核对") end
        printSummary("performance");printSummary("detailed");V.PrintPhases()
        printIdentity("restored_performance")
        complete_=true
        local marker=boundaryAudit_ and "ALL_RAIL_CONTINUOUS_PASS" or "ALL_RAIL_PERFORMANCE_PASS"
        print(string.format("%s samples=20+20 screenshots=2 restored=performance frame=%d assertions=%d audits=%d",marker,frame_,V.checks,fullAudits_))
        print("[RailPerformance] No guaranteed FPS improvement; software/GPU/validation overhead statistics are not phone FPS measurements.")
    end
end

---@param eventType string
---@param eventData EndRenderingEventData
function HandleRailPerformanceRendering(eventType,eventData)
    guarded(rendering)
end
