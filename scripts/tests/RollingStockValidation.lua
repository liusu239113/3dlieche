-- 独立验证入口：无需场景环境/UI；tests下不参与main导入。
-- 主线程可用Run()/ViewProfile(id,"front"|"side"|"nose")/ViewConsist(id)调用。
-- 默认Start测全部profile和Select事务，然后显示CR400AF完整编组。
local Catalog = require "config.TrainCatalog"
local GameConfig = require "config.GameConfig"
local RollingStock = require "train.RollingStock"
local Train = require "train.Train"
local Locomotive = require "train.Locomotive"
local Route = require "world.Route"
local Connections = require "train.EMUConnections"
local Validation = {}
---@type string[]
local failures_ = {}

---@param label string
---@param test fun()
local function checkCase(label, test)
    local ok, message = pcall(test)
    if not ok then
        failures_[#failures_+1] = label .. ": " .. tostring(message)
        print("[RollingStockValidation] FAIL " .. failures_[#failures_])
    else print("[RollingStockValidation] PASS " .. label) end
    return ok
end

---@type Scene|nil
local scene_ = nil
---@type Node|nil
local cameraNode_ = nil
---@type Node|nil
local preview_ = nil
---@type Node[]
local rails_ = {}
local captureFrame_ = 0
local SHOTS = {
    { frame=120, id="CR400AF_head", view="nose", name="rolling_CR400AF_head" },
    { frame=145, id="CR400AF_middle_v2", view="side", name="rolling_CR400AF_middle_v2" },
    { frame=170, id="CRH380A_head", view="nose", name="rolling_CRH380A_head" },
    { frame=195, id="CRH380A_middle", view="side", name="rolling_CRH380A_middle" },
    { frame=220, id="CR400AF", view="consist", name="rolling_CR400AF_consist" },
    { frame=320, id="CR400AF", view="connection_straight", name="rolling_CR400AF_gangway_straight" },
    { frame=345, id="CR400AF", view="connection_curve", name="rolling_CR400AF_gangway_curve" },
    { frame=370, id="CR400AF", view="connection_middle", name="rolling_CR400AF_middle_to_middle" },
    { frame=245, id="DF4D", view="nose", name="rolling_DF4D" },
    { frame=270, id="SS9G", view="nose", name="rolling_SS9G" },
    { frame=295, id="HXD3D", view="nose", name="rolling_HXD3D" },
}

local function expectNear(actual, expected, tolerance, label)
    assert(math.abs(actual - expected) <= tolerance,
        string.format("%s actual %.6f expected %.6f tolerance %.6f", label, actual, expected, tolerance))
end

local function ensureScene()
    if scene_ then return end
    scene_ = Scene()
    scene_:CreateComponent("Octree")
    local zone = scene_:CreateComponent("Zone")
    zone.boundingBox = BoundingBox(Vector3(-60000,-1000,-60000), Vector3(60000,1000,60000))
    zone.ambientSource = AMBIENT_COLOR
    zone.ambientColor = Color(.42,.42,.44)
    zone.fogColor = Color(.18,.21,.25)
    zone.fogStart, zone.fogEnd = 700, 800
    zone.tonemapMode = TONEMAP_MODE_ACES
    local sunNode = scene_:CreateChild("ProbeSun")
    sunNode.direction = Vector3(.35,-.8,.45)
    local sun = sunNode:CreateComponent("Light")
    sun.lightType = LIGHT_DIRECTIONAL
    sun.color, sun.brightness = Color(1,.96,.90), 1.1
    cameraNode_ = scene_:CreateChild("ProbeCamera")
    local camera = cameraNode_:CreateComponent("Camera")
    camera.farClip, camera.nearClip, camera.fov = 800, .1, 45
    renderer:SetViewport(0, Viewport:new(scene_, camera))
    renderer.hdrRendering = true
    -- 仅铺两根轨头，便于看踏面；无环境模型和整world开销。
    local steel = Material:new()
    steel:SetTechnique(0, assert(cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml")))
    steel:SetShaderParameter("MatDiffColor", Variant(Color(.5,.5,.52)))
    for _, side in ipairs({-1,1}) do
        local rail = scene_:CreateChild("ProbeRail")
        rails_[#rails_ + 1] = rail
        rail.position = Vector3(side*GameConfig.RailGauge*.5, Catalog.RailTop-.04, -105)
        rail.scale = Vector3(.09,.08,280)
        local model = rail:CreateComponent("StaticModel")
        model.model = assert(cache:GetResource("Model", "Models/Box.mdl"))
        model.material = steel
    end
end

--- 风挡世界锚点与实际上传CustomGeometry端环逐点对齐；全程不扫描源mesh。
function Validation.CheckConnections()
    local cars = Train.GetCars()
    assert(#Train.GetConnections()==#cars-1,"EMU未得到全部7组合法端面连接")
    for _, connection in ipairs(Train.GetConnections()) do
        assert(connection.valid,connection.message)
        assert(connection.geometry.viewMask==1 and connection.node:IsChildOf(assert(Train.GetRoot())),"连接误入world相机层")
        local rear, front = assert(connection.lead.rearEnd),assert(connection.following.frontEnd)
        expectNear((connection.centerA-Connections.EndCenter(connection.lead,rear)):Length(),0,.002,"rear anchor")
        expectNear((connection.centerB-Connections.EndCenter(connection.following,front)):Length(),0,.002,"front anchor")
        local expectedA,expectedB = Connections.EndRing(connection.lead,rear),Connections.EndRing(connection.following,front)
        for k=1,4 do
            expectNear((connection.ringA[k]-expectedA[k]):Length(),0,.002,"ringA")
            expectNear((connection.ringB[k]-expectedB[k]):Length(),0,.002,"ringB")
        end
        assert(connection.geometry:GetNumVertices(0)==Connections.FoldSegments*4*6,"风挡折叠拓扑不完整")
        -- 每个geometry首/末环至少有一个真实上传顶点吻合，防止只更新验收记录但未更新mesh。
        for _, endRing in ipairs({expectedA,expectedB}) do
            for _, point in ipairs(endRing) do
                local closest = math.huge
                local localPoint=connection.node:WorldToLocal(point)
                for v=0,connection.geometry:GetNumVertices(0)-1 do
                    local actual = connection.geometry:GetVertex(0,v).position
                    closest = math.min(closest,(actual-localPoint):Length())
                end
                assert(closest<.003,string.format("GPU局部风挡端环与车体锚点分离 %.6fm s=%.3f",closest,Train.GetS()))
            end
        end
        local a,b = connection.lead,connection.following
        local clearance = a.offset-a.length*.5-(b.offset+b.length*.5)
        assert(clearance>=.24,"突出端门/车钩BBox互穿")
        -- 曲线也按世界包络投影检测分离，不能只用弧长offset净距代替车体外沿净距。
        local axis = (a.node.worldPosition-b.node.worldPosition):Normalized()
        local lowerA,upperB = math.huge,-math.huge
        for _, sx in ipairs({-1,1}) do
            for _, sz in ipairs({-1,1}) do
                local pa=a.node:LocalToWorld(Vector3(sx*Catalog.Profiles[a.profile].width*.5,0,sz*a.length*.5))
                local pb=b.node:LocalToWorld(Vector3(sx*Catalog.Profiles[b.profile].width*.5,0,sz*b.length*.5))
                lowerA=math.min(lowerA,pa:DotProduct(axis))
                upperB=math.max(upperB,pb:DotProduct(axis))
            end
        end
        assert(lowerA-upperB>.01,"曲线车体包络/突出门互穿")
        if connection.yawDegrees<.001 then expectNear(connection.length,connection.gap,.025,"straight face gap") end
    end
end

--- 仅用户显式调用时做全mesh实测，默认Start不做离线扫描。
---@param id string
function Validation.MeasureProfileOffline(id)
    local measured = RollingStock.MeasureEndsOffline(id)
    local profile = assert(Catalog.Profiles[id])
    local survey = assert(profile.endSurvey)
    for _, side in ipairs({"front","rear"}) do
        local face = measured[side] --[[@as RollingStockEndFace]]
        local recorded = survey[side] --[[@as RollingStockEndFace?]]
        print(string.format("[RollingStockValidation] MEASURE %s %s center=(%.6f,%.6f,%.6f) width=%.6f height=%.6f samples=%d",
            id,side,face.center.x,face.center.y,face.center.z,face.width,face.height,face.samples))
        if recorded and recorded.kind=="flat" then
            expectNear((face.center-recorded.center):Length(),0,.015,"offline face center")
            expectNear(face.width,recorded.width,.015,"offline face width")
            expectNear(face.height,recorded.height,.015,"offline face height")
        end
    end
    return measured
end

-- Local CPU triangle rays only; caller runs this after the shared build.
--    -X observer --> new patch --> interior --> original far +X shell
-- Holes must hit the near patch. Cab door/window probes must not hit any patch.
-- This verifies geometry, not rendered artistic quality or unresolved E32 holes.
---@param model Model
---@param ray Ray
---@return number
local function shellHitDistance(model, ray)
    local geometry = model:GetGeometry(0, 0)
    local vb, ib = geometry:GetVertexBuffer(0), geometry:GetIndexBuffer()
    local vertices, indices = vb:GetData(), ib:GetData()
    indices:Seek(geometry.indexStart * ib.indexSize)
    local nearest = math.huge
    for _ = 1, geometry.indexCount//3 do
        local points = {} ---@type Vector3[]
        for k = 1, 3 do
            local index = ib.indexSize == 2 and indices:ReadUShort() or indices:ReadUInt()
            vertices:Seek(index * vb.vertexSize + vb:GetElementOffset(SEM_POSITION))
            points[k] = vertices:ReadVector3()
        end
        local a, b, c = assert(points[1]), assert(points[2]), assert(points[3])
        local edge1, edge2 = b-a, c-a
        local h = ray.direction:CrossProduct(edge2)
        local determinant = edge1:DotProduct(h)
        if math.abs(determinant) > 1e-10 then
            local offset = ray.origin-a
            local u = offset:DotProduct(h)/determinant
            local q = offset:CrossProduct(edge1)
            local v = ray.direction:DotProduct(q)/determinant
            local distance = edge2:DotProduct(q)/determinant
            if u >= -1e-7 and v >= -1e-7 and u+v <= 1+1e-7 and distance >= 0 then
                nearest = math.min(nearest,distance)
            end
        end
    end
    return nearest
end

function Validation.CheckBodyShellRepairs()
    local Repairs = require "train.BodyShellRepairs"
    local patchModel = assert(Repairs.GetModel("DF4D"))
    local original = RollingStock.LoadBakedModel("DF4D")
    -- Local projections of proven D18_nose pixels (430,327)/(525,330).
    for _, p in ipairs({Vector3(-2,3.69741631,7.09757905), Vector3(-2,3.48778806,4.70795235),
        Vector3(-2,3.8,4.5)}) do
        local ray = Ray(p, Vector3.RIGHT)
        assert(shellHitDistance(original,ray)>2, "已证洞点意外已有近侧面；重新核对patch")
        assert(shellHitDistance(patchModel,ray)<1.0, "局部射线未命中新近侧补壳")
    end
    for _, p in ipairs({Vector3(-2,3.7,-.5), Vector3(-2,3.6,8.0), Vector3(-2,2.8,7.97),
        Vector3(-2,3.7,-7.7), Vector3(-2,2.5,4.5)}) do
        assert(shellHitDistance(patchModel,Ray(p,Vector3.RIGHT))>10, "补壳覆盖门窗或越出局部ROI")
    end
    local e32=assert(Repairs.GetModel("HXD3D"))
    for _,p in ipairs({Vector3(2,3.3,-4),Vector3(2,3.1,0),Vector3(2,2.8,2)}) do
        assert(shellHitDistance(e32,Ray(p,-Vector3.RIGHT))<1,"E32近侧缺面未补齐")
    end
    for _,p in ipairs({Vector3(2,3.1,4.0),Vector3(2,3.0,7.8),Vector3(2,3.0,-8.2)}) do
        assert(shellHitDistance(e32,Ray(p,-Vector3.RIGHT))>10,"E32补片覆盖现存凸门/驾驶室")
    end
    local fixture = Scene()
    for _,id in ipairs({"DF4D","HXD3D"}) do
        local sharedModel=assert(Repairs.GetModel(id))
        local node,drawable=RollingStock.Build(fixture,id)
        local patch=assert(node:GetChild("BodyShellRepair"))
        local patchDraw=assert(patch:GetComponent("StaticModel"))
        local material=Repairs.GetMaterial(id,drawable.material)
        assert(patchDraw.model==sharedModel and patchDraw.material==material and patchDraw.viewMask==1,
            "补壳共享模型/材质身份不一致："..id)
        drawable.enabled=false
        assert(not patch.enabled,"驾驶舱隐藏原壳但未同步补壳："..id)
        drawable.enabled=true
        assert(patch.enabled,"外景未恢复补壳："..id)
        local clone=node:Clone(LOCAL)
        local cloneDraw=assert(clone:GetComponent("StaticModel"))
        -- 对齐生产AI的shareDrawables：无名派生材质不能由Clone按资源名恢复。
        cloneDraw.model=drawable.model
        cloneDraw:SetMaterial(0,drawable.material)
        Repairs.RestoreClone(clone)
        local clonePatch=assert(clone:GetChild("BodyShellRepair"))
        local cloned=assert(clonePatch:GetComponent("StaticModel"))
        assert(cloned.model==sharedModel and cloned.material==material,"AI克隆未重绑共享补壳："..id)
        cloneDraw.enabled=false
        assert(not clonePatch.enabled and patch.enabled,"AI克隆隐藏状态串到原车或未同步："..id)
        print("[RollingStockValidation] 独立共享克隆/材质/驾驶舱隐藏 PASS："..id)
    end
    fixture:Dispose() -- 不释放cache及补壳模块持有的共享资源。
    print("[RollingStockValidation] D18/E32局部射线/门窗排除/共享克隆/舱内隐藏 PASS；不是全车型原创美术验收")
end

---@return boolean
function Validation.Run()
    ensureScene()
    local started = os.clock()
    checkCase("partial DF4D body shell", Validation.CheckBodyShellRepairs)
    for id, profile in pairs(Catalog.Profiles) do
        checkCase("profile " .. id, function()
        local ok, message = RollingStock.Prepare(id)
        assert(ok, id .. " " .. message)
        local data = assert(RollingStock.GetCalibration(id))
        expectNear(data.bounds.size.x, profile.width, .025, id .. " width")
        expectNear(data.bounds.size.y, profile.height, .10, id .. " height")
        expectNear(data.bounds.size.z, profile.length, .01, id .. " length")
        expectNear(data.bounds.center.z, 0, .001, id .. " centeredZ")
        expectNear(math.abs(data.contactRight.x - data.contactLeft.x), GameConfig.RailGauge, .001, id .. " gauge")
        expectNear(data.contactLeft.y, Catalog.RailTop, .001, id .. " leftTread")
        expectNear(data.contactRight.y, Catalog.RailTop, .001, id .. " rightTread")
        assert(data.model:GetNumGeometryLodLevels(0) >= 1)
        assert(cache:Exists(data.diffusePath) and cache:Exists(data.normalPath))
        RollingStock.VerifyResourceType(data.model,"Model",Catalog.Assets[id].modelPath)
        for _, material in ipairs(data.materials) do
            assert(material:GetTypeName()=="Material")
            assert(material:GetTexture(TU_DIFFUSE):GetTypeName()=="Texture2D")
            assert(material:GetTexture(TU_NORMAL):GetTypeName()=="Texture2D")
        end
        local appearance = RollingStock.GetAppearanceReport(id)
        if id=="CR400AF_middle_v2" then
            local metadata=RollingStock.ReadMetadata(id)
            local alignment=metadata.appearanceTextureAlignment
            if alignment then
                if metadata.diffusePath~=Catalog.Assets[id].diffusePath then
                    local file=assert(cache:GetFile("FictionalLiveries/liveries.json"))
                    local lines={}
                    while not file.eof do lines[#lines+1]=file:ReadLine() end
                    file:Close()
                    local manifest=cjson.decode(table.concat(lines,"\n"))
                    local traced=false
                    for _,texture in ipairs(manifest.textures) do
                        if texture.diffuse==Catalog.Assets[id].diffusePath then
                            traced=texture.source==metadata.diffusePath
                        end
                    end
                    assert(traced,"架空派生D未溯源到已对齐腰线原图")
                end
                for _, side in ipairs(alignment.sideReports) do
                    expectNear(side.after_mean_y,side.head_target_y,.012,"left/right texture stripe world Y")
                end
                print("[RollingStockValidation] 红腰线局部派生贴图双侧世界Y匹配PASS，几何与轮轨未改")
            end
        end
        if profile.appearanceStatus == "rejected" then
            assert(not appearance.accepted and appearance.message ~= "", "错误旧资产被静默宣称外观通过")
            print("[RollingStockValidation] EXPECTED_REJECT " .. id .. " " .. appearance.message)
        elseif profile.expectedShape then
            assert(appearance.accepted,appearance.message)
        end
        print("[RollingStockValidation] profile PASS " .. id)
        end)
    end
    Route.Build()
    Train.Build(assert(scene_))
    Train.Reset(450)
    local root = assert(Train.GetRoot())
    local audioSentinel = root:CreateChild("AudioReferenceSentinel")
    local preservedS = Train.GetS()
    local original = Train.GetSelectedId()
    for _, item in ipairs(Train.GetCatalog()) do
        checkCase("Select " .. item.id,function()
        Train.Reset(preservedS)
        assert(item.ready, item.id .. "未ready")
        local ok, message = Train.Select(item.id)
        assert(ok, message)
        assert(Train.GetRoot() == root and audioSentinel.parent == root, "Select悬空了Train根引用")
        expectNear(Train.GetS(), preservedS, .000001, "Select preserves S")
        assert(Train.GetSpeedMs() == 0 and Train.GetThrottle() == 0 and Train.GetBrake() == 1)
        assert(Train.GetCarCount() == 8 and Train.GetActiveLength() < 310)
        local cars = Train.GetCars()
        if item.kind == "emu" then
            assert(cars[1].profile ~= cars[2].profile)
            assert(cars[8].profile == cars[1].profile and cars[8].reverse)
            for i = 2, 7 do assert(cars[i].profile == cars[2].profile) end
        end
        for i = 2, #cars do assert(cars[i].offset < cars[i-1].offset) end
        if item.kind == "emu" then
            Validation.CheckConnections()
            local entry = assert(Catalog.Find(item.id))
            for i, car in ipairs(cars) do
                assert(car.number==string.format("%02d",i),"车号重复或顺序错误")
                assert(car.node:GetVar("CarNumber"):GetString()==car.number)
                assert(car.node:GetVar("ServiceType"):GetString()==car.service)
                if entry.formation then assert(car.service==entry.formation[i].service) end
            end
            -- 不改变Route配置；确定性扫直线/进弯/弯心/出弯/闭合接缝。
            for _, s in ipairs({0,450,1100}) do Train.Reset(s); Validation.CheckConnections() end
            for _, seg in ipairs(Route.GetSegments()) do
                if seg.type=="arc" then
                    for _, s in ipairs({seg.s+5,seg.s+100,seg.s+seg.length*.5,seg.s+seg.length+100}) do
                        Train.Reset(s); Validation.CheckConnections()
                    end
                end
            end
            Train.Reset(preservedS)
        end
        print(string.format("[RollingStockValidation] Select PASS %s length %.3f", item.id, Train.GetActiveLength()))
        end)
    end
    local selected = Train.GetSelectedId()
    local bad = Train.Select("not_a_train")
    assert(not bad and Train.GetSelectedId() == selected)
    Train.SetBrake(0)
    Train.SetThrottle(8)
    Train.Update(.5)
    assert(math.abs(Train.GetSpeedMs()) > .1)
    local movingSelect = Train.Select("blue_white")
    assert(not movingSelect and Train.GetSelectedId() == selected, "允许了移动换车")
    Train.EmergencyBrake()
    for _ = 1, 100 do Train.Update(.1) end
    assert(Train.Select(original))
    -- 司机视角换车不重置隐藏状态：只隐藏新首车壳，不禁用中间或尾车。
    Locomotive.SetCabView(true)
    for _, id in ipairs({"CR400AF", "DF4D", "CRH380A"}) do
        assert(Train.Select(id))
        local lead = assert(Train.GetLeadNode())
        local leadDrawable = assert(lead:GetComponent("StaticModel", true))
        assert(not leadDrawable.enabled, "司机换车后新车壳遮住视野")
        local cars = Train.GetCars()
        for i = 2, #cars do
            for _, drawable in ipairs(cars[i].node:GetComponents("StaticModel", true)) do
                assert(drawable.enabled, "司机视角隐藏了中间或尾车")
            end
        end
    end
    Locomotive.SetCabView(false)
    local visibleLead = assert(Train.GetLeadNode()):GetComponent("StaticModel", true)
    assert(visibleLead and visibleLead.enabled, "第三人称未恢复新首车壳")
    assert(Train.Select(original))
    print("[RollingStockValidation] Cab selection visibility PASS")
    print(string.format("[RollingStockValidation] %s %.2fs failures=%d",#failures_==0 and "ALL PASS" or "FAILED",os.clock()-started,#failures_))
    return #failures_==0
end

---@param id string
---@param view? string
function Validation.ViewProfile(id, view)
    ensureScene()
    if preview_ then preview_:Remove() end
    local trainRoot = Train.GetRoot()
    if trainRoot then
        trainRoot:SetEnabledRecursive(false)
        for _, drawable in ipairs(trainRoot:GetComponents("StaticModel", true)) do
            assert(not drawable.node.enabled, "预览隔离失败，列车子网格仍启用")
        end
    end
    for i, rail in ipairs(rails_) do
        rail.position = Vector3((i == 1 and -1 or 1)*GameConfig.RailGauge*.5, Catalog.RailTop-.04, 0)
        rail.rotation = Quaternion()
        rail.scale = Vector3(.09,.08,65)
    end
    preview_ = assert(scene_):CreateChild("ProfilePreview")
    RollingStock.Build(preview_, id)
    local profile = assert(Catalog.Profiles[id])
    local target = Vector3(0, profile.height*.45, 0)
    local camera = assert(cameraNode_)
    if view == "front" then
        camera.position = Vector3(0, profile.height*.4, profile.length*.5+12)
    elseif view == "nose" then
        target = Vector3(0, profile.height*.5, profile.length*.28)
        camera.position = Vector3(profile.width*2, profile.height*.8, profile.length*.5+11)
    else
        camera.position = Vector3(profile.length*1.2, profile.height*.60, 0)
    end
    camera:LookAt(target)
end

---@param id string
function Validation.ViewConsist(id)
    ensureScene()
    if preview_ then preview_:Remove(); preview_=nil end
    Route.Build()
    if Train.GetCarCount() == 0 then Train.Build(assert(scene_)) end
    local root = assert(Train.GetRoot())
    root:SetEnabledRecursive(true)
    Train.EmergencyBrake()
    Train.Reset(450)
    assert(Train.Select(id))
    root:SetEnabledRecursive(true)
    local length = Train.GetActiveLength()
    local lead = Train.GetLeadPosition()
    local rotation = Train.GetLeadRotation()
    local target = lead + rotation * Vector3(0,2,-length*.45)
    for i, rail in ipairs(rails_) do
        rail.position = lead + rotation * Vector3((i == 1 and -1 or 1)*GameConfig.RailGauge*.5,
            Catalog.RailTop-.04, -length*.45)
        rail.rotation = rotation
        rail.scale = Vector3(.09,.08,length+50)
    end
    local camera = assert(cameraNode_)
    camera.position = target + rotation * Vector3(length*.70,65,length*.07)
    camera:LookAt(target)
end

---@param id string
---@param curve? boolean
---@param index? integer
function Validation.ViewConnection(id, curve, index)
    Validation.ViewConsist(id)
    local positionS = 450
    if curve then
        for _, seg in ipairs(Route.GetSegments()) do
            if seg.type=="arc" then positionS=seg.s+seg.length*.5;break end
        end
    end
    Train.Reset(positionS)
    Validation.CheckConnections()
    local connection = assert(Train.GetConnections()[index or 1])
    local target = (connection.centerA+connection.centerB)*.5
    local rotation = connection.lead.node.worldRotation
    local camera = assert(cameraNode_)
    camera.position = target+rotation*Vector3(7,1.2,3)
    camera:LookAt(target)
    for i,rail in ipairs(rails_) do
        rail.position = connection.lead.node.worldPosition+rotation*Vector3((i==1 and -1 or 1)*GameConfig.RailGauge*.5,Catalog.RailTop-.04,-15)
        rail.rotation,rail.scale=rotation,Vector3(.09,.08,80)
    end
end

function Start()
    failures_ = {}
    local mode = ""
    for _, argument in ipairs(GetArguments()) do
        if argument=="-rolling-body-shell-only" then
            local ok, message = pcall(Validation.CheckBodyShellRepairs)
            if not ok then log:Write(LOG_ERROR,"[RollingStockValidation] " .. tostring(message)) end
            engine:Exit()
            return
        elseif argument=="-rolling-offline-ends" then
            local ok, message = pcall(Validation.MeasureProfileOffline,"CR400AF_middle_v2")
            if not ok then log:Write(LOG_ERROR,"[RollingStockValidation] " .. tostring(message)) end
            engine:Exit()
            return
        elseif argument=="-rolling-straight" then mode="straight"
        elseif argument=="-rolling-curve" then mode="curve"
        elseif argument=="-rolling-middle" then mode="middle"
        elseif argument=="-rolling-pair" then mode="pair" end
    end
    if mode~="" then
        Validation.ViewConnection("CR400AF",mode=="curve",mode=="middle" and 4 or 1)
        if mode=="pair" then
            local first,second=Train.GetCars()[1],Train.GetCars()[2]
            local target=(first.node.worldPosition+second.node.worldPosition)*.5+Vector3(0,2.4,0)
            local camera=assert(cameraNode_)
            camera.position=target+first.node.worldRotation*Vector3(68,.2,0)
            camera:LookAt(target)
        end
        return
    end
    local ok, message = pcall(Validation.Run)
    if not ok then print("[RollingStockValidation] FAIL " .. tostring(message)) end
    local viewOK, viewMessage = pcall(Validation.ViewConsist,"CR400AF")
    if not viewOK then print("[RollingStockValidation] 预览不可用：" .. tostring(viewMessage)) end
    captureFrame_ = 0
    SubscribeToEvent("Update", "HandleRollingStockProbeUpdate")
    SubscribeToEvent("EndRendering", "HandleRollingStockProbeCapture")
end

---@param eventType string
---@param eventData UpdateEventData
function HandleRollingStockProbeUpdate(eventType, eventData)
    captureFrame_ = captureFrame_ + 1
    for _, shot in ipairs(SHOTS) do
        if captureFrame_ == shot.frame - 15 then
            if shot.view == "consist" then Validation.ViewConsist(shot.id)
            elseif shot.view == "connection_straight" or shot.view == "connection_curve" or shot.view == "connection_middle" then
                Validation.ViewConnection(shot.id,shot.view=="connection_curve",shot.view=="connection_middle" and 4 or 1)
            else Validation.ViewProfile(shot.id, shot.view) end
        end
    end
end

---@param eventType string
---@param eventData EndRenderingEventData
function HandleRollingStockProbeCapture(eventType, eventData)
    for _, shot in ipairs(SHOTS) do
        if captureFrame_ == shot.frame then
            local image = Image()
            assert(graphics:TakeScreenShot(image), "车型实际帧截图失败")
            assert(image:SavePNG("/workspace/screenshots/" .. shot.name .. ".png"), "车型截图未落盘")
            image:Dispose()
            print("[RollingStockValidation] Screenshot " .. shot.name)
        end
    end
end

function Stop()
    UnsubscribeFromEvent("Update")
    UnsubscribeFromEvent("EndRendering")
    if scene_ then scene_:Dispose(); scene_=nil end
    cameraNode_, preview_ = nil, nil
end

return Validation
