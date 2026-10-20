-- 真机灯光埋点与集群路径对照：仅切换当前视口的集群开关，不改灯、材质或存档。
-- 不主动上传截图或设备标识；LogMessage回调只缓冲，正常帧中限频输出，避免递归和逐帧刷屏。
local Json=require "cjson"
local Train=require "train.Train"
local Camera=require "train.Camera"
local Night=require "world.NightLighting"
local Environment=require "world.Environment"
local Stream=require "world.WorldStream"
local Diagnostics={}
Diagnostics.Version="LD-20261020-B"
local enabled_,subscribed_=false,false
local clusterSelected_=false -- 本轮真机对照默认走非集群；仅进程内生效，不写玩家设置。
---@type Viewport?
local clusterViewport_=nil
local clusterTrial_,clusterFrames_=0,0
local clusterSettledAt_=0.0
local clusterReason_=""
local elapsed_,nextSnapshot_,lastRequest_=0.0,0.0,-10.0
local settledAt_=0.0
local pending_,lastState_,lastApplication_="", "", ""
local serial_,detailCount_=0,0
local errors_,shaders_={},{}
local errorSeen_,shaderSeen_={},{}
local errorCount_,shaderCount_=0,0
local lastRender_={}
local UNAVAILABLE="unavailable"

-- 诊断包可能运行于旧手机 runtime；可选查询失败记录不可用，而非误报false/0。
local function query(action)
    local ok,value=pcall(action)
    if not ok or value==nil then return UNAVAILABLE end
    return value
end
local function vec(v) return {x=v.x,y=v.y,z=v.z} end
local function emit(kind,data)
    data.version=Diagnostics.Version
    data.serial=serial_
    data.elapsed=math.floor(elapsed_*10)/10
    print("[LIGHT_DIAG] "..kind.." "..Json.encode(data))
end
local function bufferLog(_,data)
    if not enabled_ then return end
    local message=data:GetString("Message")
    if message:find("[LIGHT_DIAG]",1,true) then return end
    local lower=message:lower()
    local relevant=lower:find("shader",1,true) or lower:find("link",1,true)
        or lower:find("cluster",1,true) or lower:find("compute",1,true)
        or lower:find("pbr",1,true) or lower:find("graphics",1,true)
    if not relevant or data:GetInt("Level")<LOG_WARNING then return end
    errorCount_=errorCount_+1
    local key=message:sub(1,400)
    if not errorSeen_[key] and #errors_<16 then
        errorSeen_[key]=true
        errors_[#errors_+1]={level=data:GetInt("Level"),message=message:sub(1,1600)}
    end
end
local function bufferShader(_,data)
    if not enabled_ then return end
    shaderCount_=shaderCount_+1
    local name=data:GetString("Name")
    local status=data:GetInt("Status")
    local shortName=data:GetString("ShortName")
    local key=name..":"..shortName..":"..status
    local lower=(name..shortName):lower()
    local relevant=lower:find("pbr",1,true) or lower:find("cluster",1,true)
        or lower:find("light",1,true) or lower:find("compute",1,true)
    if not shaderSeen_[key] and #shaders_<24 and (relevant or #shaders_<6) then
        shaderSeen_[key]=true
        shaders_[#shaders_+1]={name=name:sub(1,300),shortName=shortName:sub(1,160),statusRaw=status}
    end
end
local function bufferCompute(_,data)
    if not enabled_ then return end
    errorCount_=errorCount_+1
    if #errors_<16 then
        errors_[#errors_+1]={kind="ComputeDispatchFailed",shader=data:GetString("Shader"),
            sequence=data:GetInt("Sequence"),message=data:GetString("Error"):sub(1,1600)}
    end
end

function Diagnostics.Init()
    enabled_=true
    clusterSelected_,clusterViewport_=false,nil
    clusterTrial_,clusterFrames_,clusterSettledAt_,clusterReason_=0,0,0,""
    elapsed_,nextSnapshot_,lastRequest_=0,0,-10
    settledAt_=0
    serial_,detailCount_,pending_,lastState_,lastApplication_=0,0,"boot","",""
    errors_,shaders_,errorSeen_,shaderSeen_={},{},{},{}
    errorCount_,shaderCount_,lastRender_=0,0,{}
    if not subscribed_ then
        SubscribeToEvent("LogMessage",bufferLog)
        SubscribeToEvent("ShaderCompile",bufferShader)
        SubscribeToEvent("ComputeDispatchFailed",bufferCompute)
        subscribed_=true
    end
    emit("BOOT",{platform=query(function() return GetPlatform() end),
        nativePlatform=query(function() return GetNativePlatform() end),
        os=query(function() return GetOSVersion() end),binary=query(function() return GetBinaryVersion() end),
        api=query(function() return graphics:GetApiName() end),
        compute=query(function() return graphics:GetComputeShaderSupport() end),
        deferredSupported=query(function() return graphics:GetDeferredSupport() end),
        width=graphics:GetWidth(),height=graphics:GetHeight(),dpr=graphics:GetDPR(),
        gpuModel="see_host_feedback",clusterEffective="unknown",actualDrawableLightCount="unavailable",
        clusterSelected=clusterSelected_,clusterDefault="B_noncluster",clusterPersistent=false,
        collection="local_runtime_log_only",shaderStatusMeaning="raw_undocumented"})
end

---@param viewport Viewport
---@param reason string
local function applyCluster(viewport,reason)
    clusterViewport_=viewport -- 同一不支持的视口只报一次；显式按钮仍可重试。
    local before=query(function() return viewport:IsViewClusterEnabled() end)
    local ok,message=pcall(function() viewport:SetViewClusterEnabled(clusterSelected_) end)
    local after=query(function() return viewport:IsViewClusterEnabled() end)
    if not ok or after~=clusterSelected_ then
        emit("CLUSTER_SWITCH_FAILED",{reason=reason,requested=clusterSelected_,before=before,after=after,
            message=ok and "getter_mismatch" or tostring(message)})
        return false
    end
    clusterViewport_=viewport
    clusterTrial_=clusterTrial_+1
    clusterFrames_,clusterSettledAt_,clusterReason_=0,elapsed_+3,reason
    pending_="cluster_applied_"..reason
    emit("CLUSTER_SWITCH",{reason=reason,trial=clusterTrial_,before=before,after=after,
        selected=clusterSelected_,path=clusterSelected_ and "A_cluster" or "B_noncluster",
        clusterEffective="unknown",warmupSeconds=3,warmupFrames=12})
    return true
end

---@return boolean
function Diagnostics.GetClusterSelected() return clusterSelected_ end

---@return boolean
function Diagnostics.IsClusterWarmingUp() return clusterSettledAt_>0 end

---@return string
function Diagnostics.GetClusterStatus()
    local viewport=renderer:GetViewport(0)
    if not viewport or viewport~=clusterViewport_ then return "灯光对照：等待驾驶视口" end
    local current=query(function() return viewport:IsViewClusterEnabled() end)
    if type(current)~="boolean" or current~=clusterSelected_ then return "灯光对照：开关未确认" end
    local label=current and "当前 A：集群光照" or "当前 B：非集群光照"
    return label..(clusterSettledAt_>0 and " · 预热中" or " · 预热完成")
end

--- 只操作当前游戏视口；不可用或未成功时不向HUD报告切换成功。
---@param selected boolean
---@return boolean
function Diagnostics.SelectCluster(selected)
    if not enabled_ then return false end
    local viewport=renderer:GetViewport(0)
    if not viewport or viewport.camera~=Camera.GetCamera() then return false end
    local previous=clusterSelected_
    clusterSelected_=selected
    if applyCluster(viewport,"manual") then return true end
    clusterSelected_=previous
    return false
end

---@param reason string
---@return boolean
function Diagnostics.Request(reason)
    if not enabled_ or elapsed_-lastRequest_<2 then return false end
    lastRequest_=elapsed_
    pending_=reason
    return true
end

---@param material Material?
local function materialInfo(material)
    if not material then return {missing=true} end
    local techniques={}
    for index=0,math.min(material:GetNumTechniques(),2)-1 do
        local technique=material:GetTechnique(index)
        if technique then
            local passes={}
            for _,name in ipairs({"base","litbase","light","deferred"}) do
                if technique:HasPass(name) then
                    local pass=technique:GetPass(name)
                    if pass then passes[#passes+1]={name=name,vs=pass.vertexShader,ps=pass.pixelShader,
                        vsDefines=pass.vertexShaderDefines,psDefines=pass.pixelShaderDefines,
                        lightingMode=pass.lightingMode,desktop=pass.desktop} end
                end
            end
            techniques[#techniques+1]={name=technique:GetName(),supported=technique:IsSupported(),
                desktop=technique:IsDesktop(),passes=passes}
        end
    end
    return {name=material:GetName(),techniques=techniques,
        vsDefines=material.vertexShaderDefines,psDefines=material.pixelShaderDefines}
end

---@param light Light
---@param eye Vector3
---@param focus Vector3
local function lightInfo(light,eye,focus)
    local node=light.node
    return {name=node.name,type=light.lightType,enabled=light.enabled,effective=light:IsEnabledEffective(),
        inView=query(function() return light:IsInView() end),brightness=light.brightness,
        color={r=light.color.r,g=light.color.g,b=light.color.b},range=light.range,
        perVertex=light.perVertex,punctual=light.punctualLight,physical=light.usePhysicalValues,
        shadows=light.castShadows,viewMask=light.viewMask,lightMask=light.lightMask,
        position=vec(node.worldPosition),direction=vec(node.worldDirection),
        eyeDistance=(node.worldPosition-eye):Length(),focusDistance=(node.worldPosition-focus):Length(),
        drawDistance=light.drawDistance,fadeDistance=light.fadeDistance,
        fov=light.fov,inner=light.innerConeAngle,outer=light.outerConeAngle}
end

---@param scene Scene
---@param point Vector3
---@param name string
local function receiverInfo(scene,point,name)
    local octree=scene:GetComponent("Octree")
    if not octree then return {name=name,error="no_octree"} end
    local hits=octree:Raycast(Ray(point+Vector3(0,1,0),Vector3.DOWN),RAY_TRIANGLE,40,DRAWABLE_GEOMETRY,2)
    local result={name=name,target=vec(point),hits=#hits,receivers={}}
    for _,hit in ipairs(hits) do
        if #result.receivers>=2 then break end
        local drawable=hit.drawable
        if drawable then
            local geom=hit.node:GetComponent("CustomGeometry")
            local static=hit.node:GetComponent("StaticModel")
            local material=geom and geom:GetMaterial(0) or (static and static:GetMaterial(0) or nil)
            local info={node=hit.node.name,position=vec(hit.position),normal=vec(hit.normal),
                effective=drawable:IsEnabledEffective(),inView=drawable:IsInView(),
                viewMask=drawable.viewMask,lightMask=drawable.lightMask,maxLightsConfigured=drawable.maxLights,
                actualLightCount="unavailable",material=materialInfo(material)}
            result.receivers[#result.receivers+1]=info
        end
    end
    return result
end

---@param scene Scene
local function snapshot(scene,reason)
    serial_=serial_+1
    Diagnostics.SampleLastCompletedFrame()
    local camera=Camera.GetCamera()
    local node=Camera.GetNode()
    if not camera or not node then emit("WAIT",{reason=reason,scene=true,camera=false});return end
    local head=Train.GetHeadlightDiagnostics()
    local night=Night.GetStats()
    local env=Environment.GetStatus()
    local eye,focus=node.worldPosition,Camera.GetLightingFocus()
    local viewport=renderer:GetViewport(0)
    local stream=Stream.GetStats()
    local zoneNode=scene:GetChild("DayLighting")
    local zone=zoneNode and zoneNode:GetComponent("Zone") or nil
    local atmosphere=zone and {ambient={r=zone.ambientColor.r,g=zone.ambientColor.g,b=zone.ambientColor.b},
        ambientSource=zone.ambientSource,autoExposure=zone.autoExposureEnabled,
        bloom=zone.bloomWeight,ssgi=zone.ssgiEnabled,ssr=zone.ssrEnabled,volumetric=zone.volumetricFogEnabled} or {}
    -- GetStats内有Node引用，不能直接送入JSON（原生Node在部分runtime是userdata）。
    stream.root=nil
    emit("STATE",{reason=reason,model=Train.GetSelectedId(),s=Train.GetS(),speed=Train.GetSpeedKmh(),
        headMode=head.mode,headEnabled=head.enabled,headFactor=head.factor,headSpots=head.lights,headFill=head.fillLights,
        reversed=head.reversed,hour=env.hour,weather=env.weather,lampFactor=env.lampFactor,
        camera=Camera.GetMode(),eye=vec(eye),direction=vec(node.worldDirection),focus=vec(focus),
        cameraMask=camera.viewMask,near=camera.nearClip,far=camera.farClip,fov=camera.fov,
        viewportSceneMatches=viewport and viewport.scene==scene or false,
        viewportCameraMatches=viewport and viewport.camera==camera or false,
        viewportCluster=query(function() return assert(viewport):IsViewClusterEnabled() end),
        clusterSelected=clusterSelected_,clusterTrial=clusterTrial_,clusterFrames=clusterFrames_,
        clusterReason=clusterReason_,clusterWarmupPending=clusterSettledAt_>0,
        clusterEffective="unknown",quality=renderer.materialQuality,hdr=renderer.hdrRendering,atmosphere=atmosphere,
        pool=night,stream=stream,render=lastRender_,
        shaderEvents=shaderCount_,graphicsWarnings=errorCount_,
        storedShaderSamples=#shaders_,storedWarningSamples=#errors_})
    for _,warning in ipairs(errors_) do emit("GRAPHICS_MESSAGE",warning) end
    for _,shader in ipairs(shaders_) do emit("SHADER",shader) end
    -- 每次手动取证都含真实挂点/接收面；自动详细取证仅前两次，周期只做摘要。
    if reason~="periodic" or detailCount_<2 then
        detailCount_=detailCount_+1
        if head.node then
            for _,light in ipairs(head.node:GetComponents("Light",true)) do emit("HEAD_LIGHT",lightInfo(light,eye,focus)) end
        end
        local lights=Night.GetLights()
        table.sort(lights,function(a,b)
            return (a.node.worldPosition-focus):LengthSquared()<(b.node.worldPosition-focus):LengthSquared()
        end)
        local samples={station=0,road=0}
        for _,light in ipairs(lights) do
            local kind=light.node.name:match("^(%a+)_") or "road"
            if light.enabled and (samples[kind] or 2)<2 then
                samples[kind]=samples[kind]+1
                local info=lightInfo(light,eye,focus);info.kind=kind
                emit("POOL_LIGHT",info)
            end
        end
        local sign=head.reversed and -1 or 1
        local nose=head.mounts[1] and head.mounts[1].surface.z or 12
        emit("RECEIVER",receiverInfo(scene,Train.GetTrackSample(Train.GetS()+sign*(nose+20)),"track_ahead"))
        for _,light in ipairs(lights) do
            if light.enabled then
                emit("RECEIVER",receiverInfo(scene,light.node.worldPosition-Vector3(0,2,0),"nearest_pool_ground"))
                break
            end
        end
    end
    -- 错误/编译事件保留有界去重历史，手动取证也能携带初载时的问题。
end

---@param dt number
---@param application string
---@param scene Scene?
function Diagnostics.Update(dt,application,scene)
    if not enabled_ then return end
    elapsed_=elapsed_+math.max(0,dt)
    if application~=lastApplication_ then
        lastApplication_=application
        emit("LIFECYCLE",{application=application})
        if application=="playing" then pending_="world_ready";settledAt_=elapsed_+3 end
    end
    if application~="playing" or not scene then
        clusterViewport_=nil;clusterSettledAt_=0
        return
    end
    local viewport=renderer:GetViewport(0)
    if viewport and viewport.scene==scene and viewport.camera==Camera.GetCamera() then
        if viewport~=clusterViewport_ then
            applyCluster(viewport,"viewport_attached")
        else clusterFrames_=clusterFrames_+1 end
    end
    local env=Environment.GetStatus()
    local state=Train.GetSelectedId()..":"..Train.GetHeadlightMode()..":"..Camera.GetMode()
        ..":"..tostring(Train.IsReversing())..":"..tostring((env.lampFactor or 0)>.2)
    if state~=lastState_ then lastState_=state;pending_=pending_~="" and pending_ or "state_change" end
    if clusterSettledAt_>0 and elapsed_>=clusterSettledAt_ and clusterFrames_>=12 then
        if pending_=="" then pending_="cluster_settled_"..clusterReason_ end
        clusterSettledAt_=0;settledAt_=0
    end
    if pending_=="" and settledAt_>0 and elapsed_>=settledAt_ then
        pending_="after_render_warmup";settledAt_=0
    end
    if pending_=="" and elapsed_<nextSnapshot_ then return end
    local reason=pending_~="" and pending_ or "periodic"
    pending_="";nextSnapshot_=elapsed_+30
    local ok,message=xpcall(function() snapshot(scene,reason) end,debug.traceback)
    if not ok then emit("ERROR",{reason=reason,message=tostring(message)}) end
end

-- PostUpdate读取上一次已完成帧的Renderer统计，不把统计灯数冒充GPU实际接收灯数。
function Diagnostics.SampleLastCompletedFrame()
    if not enabled_ then return end
    -- 初载统计查询组合曾触发原生崩溃，pcall无法保护；禁用View灯数查询，仅保留已验证的图形计数。
    lastRender_={sampling="PostUpdate_previous_frame",rendererLightCount="unavailable_unsafe_native_query",
        batches=graphics.numBatches,primitives=graphics.numPrimitives,
        deviceLost=query(function() return graphics:IsDeviceLost() end)}
end
function Diagnostics.Shutdown()
    enabled_=false
    clusterViewport_=nil;clusterSettledAt_=0
    pending_="";lastState_=""
    errors_,shaders_={},{}
end
return Diagnostics
