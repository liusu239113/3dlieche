-- ============================================================================
-- Train - 蓝白长机罩内燃机车与客车编组
-- 纵向自由度 s/v；车体按两转向架支点弦摆放，转向架各自跟随线路。
-- ============================================================================

local GameConfig = require "config.GameConfig"
local GameModes = require "config.GameModes"
local Coach = require "train.Coach"
local Route = require "world.Route"
local Locomotive = require "train.Locomotive"
local RollingStock = require "train.RollingStock"
local Catalog = require "config.TrainCatalog"
local Connections = require "train.EMUConnections"
local RailNetwork = require "world.RailNetwork"
local Accident = require "train.Accident"
local SpeedPolicy = require "game.SpeedPolicy"
local Train = {}
local T = GameConfig.Train
local KMH = 3.6
local RAIL_TOP = 0.34
local WHEEL_R = 0.46

local state_ = {
    s = 0.0, v = 0.0, throttle = 0, brake = 0.0,
    reversing = false, moving = false, distanceTravelled = 0.0,
}

---@class TrainBogie
---@field node Node
---@field z number

---@class TrainCar
---@field node Node
---@field offset number
---@field pivot number
---@field bogies {node:Node,z:number}[]
---@field length number
---@field profile string
---@field reverse boolean
---@field number string
---@field service string
---@field frontEnd RollingStockEndFace|nil
---@field rearEnd RollingStockEndFace|nil
---@field assetNode Node|nil 实际外部MDL节点，不能仅根据profile标签验收。
---@field drawable StaticModel|nil 实际外部MDL组件。

---@type EMUConnection[]
local connections_ = {}
---@type Material|nil
local connectionMaterial_ = nil
---@type Material|nil
local identityMaterial_ = nil

---@type Node|nil
local root_ = nil
---@type TrainCar[]
local cars_ = {}
---@type Vector3[]
local carPositions_ = {}
---@type {node:Node,base:Quaternion}[]
local wheels_ = {}
---@type Node|nil
local headLightNode_ = nil
---@type Node[]
local headlightMarkerNodes_ = {}
---@type Material|nil
local headlightMarkerMaterial_ = nil
---@class TrainLampMount
---@field surface Vector3 头灯支架局部坐标，来自实际LOD0三角形求交
---@field normal Vector3
---@field rim Vector3[]
---@field lens Vector3[] 实际车壳三角形裁切出的灯面，不用跨曲面的扇形弦近似
---@field lensNormals Vector3[]
---@field marker Node?
---@field beam Node?
---@type TrainLampMount[]
local headlightMounts_ = {}
local headlightProfile_, headlightEnd_ = "", 1
---@type table<string, TrainLampMount[]>
local headlightSurveys_ = {}
-- 只有横向/高度是每款成品的灯区种子；纵向位置绝不使用length/2。
-- 尖鼻灯区低于驾驶窗，机车灯区位于端墙。每个种子/灯缘再与已绑定MDL求交。
local LAMP_LAYOUTS = {
    CR400AF_head = {x=.82,y=1.92,rx=.14,ry=.065},
    CRH380A_head = {x=.92,y=2.02,rx=.14,ry=.075},
    DF4D = {x=.82,y=2.12,rx=.12,ry=.10},
    SS9G = {x=.86,y=2.20,rx=.13,ry=.09},
    HXD3D = {x=.90,y=2.14,rx=.13,ry=.09},
    blue_white = {x=.68,y=2.80,rx=.12,ry=.10},
}
local HEADLIGHT_BEAMS = {
    -- 远光轴线在约70m接触轨面；旧-.22在12m就落地，再长range也不是远光。
    {name="FarBeam",brightness=12000,range=180,fov=12,aspect=1.65,target=70},
    {name="NearBeam",brightness=420,range=65,fov=46,aspect=1.40,target=20},
}
local wheelAngle_ = 0.0
---@type TrainCatalogEntry
local selected_ = assert(Catalog.Find(Catalog.FallbackId))
---@type Node|nil
local vehicles_ = nil
local activeLength_ = 0.0
local headlightOn_ = true
local headlightMode_ = "auto"
local headlightFactor_ = 1.0
local drivingMode_ = GameConfig.Gameplay.DrivingMode or "relaxed"
local visualsDirty_ = true
local lastVisualS_ = math.huge
---@type table<string, boolean>
local ready_ = {}
---@type table<string, string>
local readyMessages_ = {}
---@type (fun(id:string,cars:TrainCar[]):boolean,string)?
local selectionValidator_ = nil

--- 业务拥有者可在暂存编组完成、旧编组释放前验证站台/客流；回调不得修改业务状态。
---@param validator? fun(id:string,cars:TrainCar[]):boolean,string
function Train.SetSelectionValidator(validator) selectionValidator_ = validator end

---@param entry TrainCatalogEntry
---@param role string
---@return string, boolean
local function roleProfile(entry, role)
    local roles = entry.roles
    local spec = roles and (role == "head" and roles.head or (role == "tail" and roles.tail or roles.middle))
    if spec then return spec.profile, spec.reverse == true end
    return role == "middle" and assert(entry.middle) or entry.head, role == "tail"
end

---@param entry TrainCatalogEntry
---@return string[]
local function entryProfiles(entry)
    if entry.kind ~= "emu" then
        local profileId = Coach.GetIndependentProfile(entry.id)
        return profileId and {entry.head,profileId} or {entry.head}
    end
    local result = {} ---@type string[]
    local seen = {} ---@type table<string, boolean>
    for _, role in ipairs({"head","middle","tail"}) do
        local id = roleProfile(entry,role)
        if not seen[id] then result[#result+1]=id; seen[id]=true end
    end
    return result
end

local function releaseUnused()
    -- 以实际仍存活的车节保留共享资源。配置修订/失败期间不能只按新目录丢弃旧profile缓存。
    local retained = {} ---@type string[]
    for _, car in ipairs(cars_) do retained[#retained+1] = car.profile end
    local head = cars_[1] and cars_[1].profile or selected_.head
    local middle = selected_.kind == "emu" and cars_[2] and cars_[2].profile or nil
    RollingStock.RetainProfiles(#retained > 0 and retained or entryProfiles(selected_))
    Locomotive.ReleaseExcept(head,middle)
end

---@param entry TrainCatalogEntry
---@return boolean, string
local function prepareEntry(entry)
    if entry.kind ~= "emu" then
        local profileId, reason = Coach.GetIndependentProfile(entry.id)
        if not profileId then
            ready_[entry.id], readyMessages_[entry.id] = false, reason
            return false, reason
        end
    end
    local ok, message = true, "成品可加载"
    for _, id in ipairs(entryProfiles(entry)) do
        ok, message = RollingStock.EnsureBakedAvailable(id)
        if not ok then break end
        if id == "blue_white" then ok, message = Locomotive.Prepare(id)
        else ok, message = RollingStock.Prepare(id) end
        if not ok then break end
    end
    ready_[entry.id], readyMessages_[entry.id] = ok, message
    if ok and entry.kind ~= "emu" then
        ok, message = Coach.Prepare(entry.id)
        ready_[entry.id], readyMessages_[entry.id] = ok, message
    end
    return ok, message
end

--- 验收实际组件/Model/材质和轮轨元数据，而不是车名、节点名或source标签。
--- 成品没有可分离轮组时保留原网格；不加程序轮、不缩放车体修补踏面。
---@param car TrainCar
local function verifyCarBinding(car)
    local asset = assert(Catalog.Assets[car.profile], "编组缺少外部MDL配置")
    local node = assert(car.assetNode, "未创建实际外部MDL节点")
    local drawable = assert(car.drawable, "未绑定实际外部MDL组件")
    assert(drawable.node == node and node.parent == car.node, "MDL组件不属于当前车节")
    local expected, metadata = RollingStock.LoadBakedModel(car.profile)
    assert(drawable.model == expected, "实际绑定MDL不是该车节已交付成品：" .. asset.modelPath)
    assert(drawable.model.name == asset.modelPath, "实际MDL资源路径不匹配")
    assert((node.position - Vector3.ZERO):Length() < .00001
        and (node.scale - Vector3.ONE):Length() < .00001
        and (car.node.scale - Vector3.ONE):Length() < .00001, "成品模型禁止额外平移/缩放破坏轮轨校准")
    local forward = node.rotation * Vector3.FORWARD
    assert((forward - Vector3(0,0,car.reverse and -1 or 1)):Length() < .0001,
        "实际MDL朝向不符合编组头/中间/尾角色")
    for g = 0, expected.numGeometries - 1 do
        local material = assert(drawable:GetMaterial(g), "实际MDL缺少材质")
        assert(material:GetTexture(TU_DIFFUSE) == cache:GetResource("Texture2D",asset.diffusePath)
            and material:GetTexture(TU_NORMAL) == cache:GetResource("Texture2D",asset.normalPath),
            "实际MDL纹理不属于当前车节成品")
    end
    local left, right = metadata.contactLeft, metadata.contactRight
    assert(left and right and math.abs(math.abs(right[1]-left[1])-GameConfig.RailGauge) < .002
        and math.abs(left[2]-RAIL_TOP) < .002 and math.abs(right[2]-RAIL_TOP) < .002,
        "成品左右踏面元数据不满足轨距/轨面安全要求")
end

---@param entry TrainCatalogEntry
---@param cars TrainCar[]
local function verifyFormation(entry, cars)
    assert(#cars == 8, "编组必须完整包含8节")
    local coachProfile = entry.kind ~= "emu" and assert(Coach.GetIndependentProfile(entry.id)) or nil
    for i, car in ipairs(cars) do
        local expected, reverse = entry.head, false
        if entry.kind == "emu" then
            expected, reverse = roleProfile(entry,i == 1 and "head" or (i == 8 and "tail" or "middle"))
        elseif i > 1 then expected = assert(coachProfile) end
        assert(car.profile == expected and car.reverse == reverse, "车节角色与车型配置不一致")
        verifyCarBinding(car)
    end
end

---@param entry TrainCatalogEntry
---@return boolean, string
local function availableEntry(entry)
    if entry.kind ~= "emu" then
        local profile, reason = Coach.GetIndependentProfile(entry.id)
        if not profile then return false, reason end
    end
    local downloaded = true
    for _, id in ipairs(entryProfiles(entry)) do
        if not RollingStock.IsAvailable(id) then return false, "成品缺失或校准无效，暂不可选" end
        local asset = Catalog.Assets[id]
        if not asset then return false, "成品缺少资源配置，暂不可选" end
        for _, path in ipairs({asset.modelPath,asset.metadataPath,asset.diffusePath,asset.normalPath}) do
            local present = cache:Exists(path)
            if not present and not cache:GetResInfo(path) then return false, "成品或贴图未交付，暂不可选" end
            downloaded = downloaded and present
        end
    end
    return true, downloaded and "成品已在本地，确认后装配" or "成品已交付，确认后按需下载"
end

--- 构建暂存子树，成功后才替换旧车辆；Train根及音效组件永不因Select移除。
---@param entry TrainCatalogEntry
---@return boolean, string
local function rebuildVehicles(entry)
    if not root_ then return false, "列车尚未构建" end
    local staging = root_:CreateChild("Vehicles_" .. entry.id)
    local oldCars, oldPositions, oldWheels = cars_, carPositions_, wheels_
    local oldHeadlight = headLightNode_
    local oldMarkers, oldMounts = headlightMarkerNodes_, headlightMounts_
    local oldLampProfile, oldLampEnd = headlightProfile_, headlightEnd_
    local oldConnections, oldConnectionMaterial = connections_, connectionMaterial_
    local oldIdentityMaterial = identityMaterial_
    local oldDirty, oldVisualS, oldLivery = visualsDirty_, lastVisualS_, Coach.GetLiveryId()
    cars_, carPositions_, wheels_, connections_ = {}, {}, {}, {}
    headLightNode_, connectionMaterial_, identityMaterial_ = nil, nil, nil
    headlightMarkerNodes_, headlightMounts_ = {}, {}
    headlightProfile_, headlightEnd_ = "", 1
    -- 正式编组只能使用已交付独立客车，来源与验收不从车队名称推断。
    local independentCoach = entry.kind ~= "emu" and Coach.GetIndependentProfile(entry.id) or nil
    if entry.kind ~= "emu" then Coach.SelectLivery(entry.id) end
    local totalLength = 0.0
    local started = os.clock()
    local ok, message = pcall(function()
        assert(entry.kind == "emu" or independentCoach, "正式车队缺少独立客车，禁止程序化代用")
        local previousLength, previousOffset = 0.0, 0.0
        for i = 1, 8 do
            local isLead, isTail = i == 1, i == 8
            local profileId = isLead and entry.head or (independentCoach or "coach")
            local reverse = false
            if entry.kind == "emu" then
                profileId, reverse = roleProfile(entry,isLead and "head" or (isTail and "tail" or "middle"))
            end
            local profile = Catalog.Profiles[profileId]
            local length = profile and profile.length or (isLead and Locomotive.Length or Coach.Length)
            local gap = i == 2 and entry.gap or ((entry.kind == "emu" or independentCoach) and entry.gap or T.CarGap)
            -- 仅旧程序Coach在body长度外突出0.80米车钩。独立成品profile.length已含完整包络。
            if i == 2 and entry.kind ~= "emu" and not independentCoach and entry.id ~= "blue_white" then gap = gap + .80 end
            local offset = isLead and 0 or previousOffset - previousLength * .5 - length * .5 - gap
            local frontEnd = entry.kind == "emu" and RollingStock.GetConnectionEnd(profileId,"front",reverse) or nil
            local rearEnd = entry.kind == "emu" and RollingStock.GetConnectionEnd(profileId,"rear",reverse) or nil
            local previous = cars_[i-1]
            local connectionGap = entry.connectionGap or entry.gap
            if previous and previous.rearEnd and frontEnd then
                -- 距离从实测端面起算。真实车钩仍在模型中：保留其包络，不能为缩缝把车钩穿进车体。
                local clearance = (previous.rearEnd.center.z+previous.length*.5)
                    + (length*.5-frontEnd.center.z)+entry.gap
                connectionGap = math.max(connectionGap,clearance)
                offset = previous.offset+previous.rearEnd.center.z-frontEnd.center.z-connectionGap
            end
            local node = staging:CreateChild("Car" .. i)
            local bogies = {} ---@type {node:Node,z:number}[]
            local assetNode = nil ---@type Node?
            local drawable = nil ---@type StaticModel?
            if entry.kind == "emu" then
                assetNode, drawable = RollingStock.Build(node, profileId, reverse)
                if isLead then
                    Locomotive.RegisterLead(assert(drawable))
                    Train.BuildHeadlight(node, length, profileId, assert(drawable))
                end
            elseif isLead then
                assetNode = Train.BuildLocomotive(node, entry.head)
                drawable = assetNode:GetComponent("StaticModel")
            else
                local result = Coach.Build(node, i - 1, 1, entry.id)
                assetNode, drawable = result.assetNode, result.drawable
                bogies = result.bogies
                for _, wheel in ipairs(result.wheels) do Train.RegisterWheel(wheel, 1) end
            end
            local identity = entry.formation and entry.formation[i]
            local car = {node=node, offset=offset, pivot=profile and profile.pivot or (isLead and 6.6 or 8.5),
                bogies=bogies, length=length, profile=profileId, reverse=reverse,
                number=identity and identity.number or string.format("%02d",i),
                service=identity and identity.service or (isLead and "motor" or "trailer"),
                frontEnd=frontEnd,rearEnd=rearEnd,assetNode=assetNode,drawable=drawable} --[[@as TrainCar]]
            cars_[i] = car
            if entry.kind == "emu" then
                if not connectionMaterial_ then connectionMaterial_ = Connections.CreateMaterial() end
                if not identityMaterial_ then identityMaterial_ = Connections.CreateIdentityMaterial() end
                Connections.BuildIdentity(car,identityMaterial_)
                if previous and previous.rearEnd and frontEnd then
                    connections_[#connections_+1] = Connections.Create(staging,previous,car,connectionGap,connectionMaterial_)
                elseif previous then
                    print(string.format("[Train] %s %02d-%02d未生成风挡：缺少合法实测平端（资产保留，外观须修复）",entry.id,i-1,i))
                end
            end
            carPositions_[i] = Vector3.ZERO
            previousLength, previousOffset = length, offset
        end
        verifyFormation(entry,cars_)
        local first, last = assert(cars_[1]), assert(cars_[#cars_])
        local front = first.length * .5
        local rear = last.offset - last.length * .5 - ((entry.kind == "emu" or independentCoach) and 0 or .80)
        totalLength = front - rear
        assert(totalLength < Route.PlatformEnd - Route.PlatformStart, "车型编组超过310米站台")
        assert(rear >= Route.PlatformStart and front <= Route.PlatformEnd, "编组不在站台停靠包络内")
        for _, drawable in ipairs(staging:GetComponents("StaticModel", true)) do drawable.viewMask = 1 end
        for _, drawable in ipairs(staging:GetComponents("CustomGeometry", true)) do drawable.viewMask = 1 end
        visualsDirty_ = true
        Train.UpdateVisuals(0)
        if selectionValidator_ then
            local stagedCars, stagedPositions = cars_, carPositions_
            -- 校验显式接收候选，不让GetCars/GetCarPositions暴露未提交编组。
            cars_, carPositions_ = oldCars, oldPositions
            local called, compatible, reason = pcall(selectionValidator_,entry.id,stagedCars)
            cars_, carPositions_ = stagedCars, stagedPositions
            assert(called and compatible, called and (reason or "当前客流/站台不兼容该编组") or tostring(compatible))
        end
    end)
    if not ok then
        staging:Dispose()
        if connectionMaterial_ then connectionMaterial_:Dispose() end
        if identityMaterial_ then identityMaterial_:Dispose() end
        cars_, carPositions_, wheels_, headLightNode_ = oldCars, oldPositions, oldWheels, oldHeadlight
        headlightMarkerNodes_, headlightMounts_ = oldMarkers, oldMounts
        headlightProfile_, headlightEnd_ = oldLampProfile, oldLampEnd
        connections_, connectionMaterial_, identityMaterial_ = oldConnections, oldConnectionMaterial, oldIdentityMaterial
        visualsDirty_, lastVisualS_ = oldDirty, oldVisualS
        Coach.SelectLivery(oldLivery)
        local oldLead = oldCars[1] and oldCars[1].drawable
        if oldLead then Locomotive.RegisterLead(oldLead) end
        print("[Train] 车辆替换失败，保留原编组：" .. tostring(message))
        return false, tostring(message)
    end
    local previousVehicles = vehicles_
    vehicles_ = staging
    if previousVehicles then previousVehicles:Dispose() end
    if oldConnectionMaterial then oldConnectionMaterial:Dispose() end
    if oldIdentityMaterial then oldIdentityMaterial:Dispose() end
    selected_, activeLength_, wheelAngle_ = entry, totalLength, 0
    Train.SetHeadlight(headlightOn_)
    local liveryNote = entry.kind == "emu" and "" or ("；客车队 " .. Coach.GetLiveryName())
    print(string.format("[Train] %s：8节 %s，全长%.3fm，%d独立动画轮（整体MDL轮组未拆分），%.2fs；实际MDL/贴图8节绑定已复核；运营%.0f/构造%.0fkm/h%s",
        entry.id, entry.kind == "emu" and "头+6中间+反向尾"
            or (independentCoach and "1机车+7独立生成客车" or "1机车+7程序化代用客车"),
        totalLength, #wheels_, os.clock() - started, entry.operatingSpeedKmh, entry.maxSpeedKmh, liveryNote))
    return true, "已选择" .. entry.name
end

---@param scene Scene
function Train.Build(scene)
    -- Build只在项目初始化/重建场景调用；同一scene复用Train根，不悬空AudioManager引用。
    if not root_ or root_.scene ~= scene then
        root_ = scene:CreateChild("Train")
        vehicles_ = nil
    end
    local default = assert(Catalog.Find(Catalog.DefaultId))
    local ok, message = prepareEntry(default)
    if ok then ok, message = rebuildVehicles(default) end
    if not ok and default.id ~= Catalog.FallbackId then
        print("[Train] 默认动车确实失败，按需准备蓝白回退：" .. message)
        local fallback = assert(Catalog.Find(Catalog.FallbackId))
        ok, message = prepareEntry(fallback)
        if ok then ok, message = rebuildVehicles(fallback) end
    end
    assert(ok, message)
    releaseUnused()
end

-- 在车灯ROI内读取已绑定模型的LOD0；只在首次装配该车型/端面时执行。
-- 使用三角形XY重心求交而不是BBox，既支持尖鼻也支持不对称成品；不碰共享VB。
---@param drawable StaticModel
---@param profile string
---@param nativeEnd number 模型局部+Z或-Z端，反向尾车的模型本身可能已旋转180度
---@return TrainLampMount[]
local function surveyLamps(drawable, profile, nativeEnd)
    local key = profile .. ":" .. nativeEnd
    if headlightSurveys_[key] then return headlightSurveys_[key] end
    local layout = LAMP_LAYOUTS[profile] or {x=.66,y=2.0,rx=.12,ry=.08}
    local model = assert(drawable.model, "车灯缺少实际车壳")
    local lensVertices,lensNormals = { {},{} },{ {},{} } ---@type Vector3[][],Vector3[][]
    -- 将原壳三角形逐平面裁进椭圆灯区，保留原表面形状；扇形连点会在弯鼻上形成悬空弦。
    ---@param a Vector3
    ---@param b Vector3
    ---@param c Vector3
    ---@param normal Vector3
    local function clipLens(a,b,c,normal)
        for sideIndex, side in ipairs({-1,1}) do
            local polygon = {a,b,c} ---@type Vector3[]
            for edge = 0, 11 do
                if #polygon==0 then break end
                local angle=(edge+.5)*math.pi/6
                local nx,ny=math.cos(angle)/layout.rx,math.sin(angle)/layout.ry
                local boundary=math.cos(math.pi/12)
                local clipped={} ---@type Vector3[]
                for j=1,#polygon do
                    local p,q=polygon[j],polygon[j % #polygon+1]
                    local dp=(p.x-side*layout.x)*nx+(p.y-layout.y)*ny-boundary
                    local dq=(q.x-side*layout.x)*nx+(q.y-layout.y)*ny-boundary
                    if dp<=0 then clipped[#clipped+1]=p end
                    if (dp<=0)~=(dq<=0) then clipped[#clipped+1]=p+(q-p)*(dp/(dp-dq)) end
                end
                polygon=clipped
            end
            for j=2,#polygon-1 do
                for _,p in ipairs({polygon[1],polygon[j],polygon[j+1]}) do
                    lensVertices[sideIndex][#lensVertices[sideIndex]+1]=p
                    lensNormals[sideIndex][#lensNormals[sideIndex]+1]=normal
                end
            end
        end
    end
    local samples = {} ---@type {x:number,y:number,z:number,normal:Vector3}[]
    for _, side in ipairs({-1,1}) do
        samples[#samples+1] = {x=side*layout.x,y=layout.y,z=-math.huge,normal=Vector3.FORWARD}
        for i = 0, 11 do
            local angle = i * math.pi / 6
            samples[#samples+1] = {x=side*layout.x+math.cos(angle)*layout.rx,
                y=layout.y+math.sin(angle)*layout.ry,z=-math.huge,normal=Vector3.FORWARD}
        end
    end
    for g = 0, model.numGeometries - 1 do
        local geometry = model:GetGeometry(g,0)
        if geometry.primitiveType == TRIANGLE_LIST then
            local vb = geometry:GetVertexBuffer(0)
            local data, stride, offset = vb:GetData(), vb.vertexSize, vb:GetElementOffset(SEM_POSITION)
            local positions = {} ---@type table<number,Vector3>
            ---@param index integer
            ---@return Vector3
            local function vertex(index)
                if not positions[index] then
                    data:Seek(index*stride+offset)
                    local p = data:ReadVector3()
                    positions[index] = Vector3(p.x*nativeEnd,p.y,p.z*nativeEnd)
                end
                return positions[index]
            end
            local ib = geometry:GetIndexBuffer()
            local indices = {} ---@type integer[]
            if ib and geometry.indexCount > 0 then
                local indexData = ib:GetData()
                indexData:Seek(geometry.indexStart*ib.indexSize)
                for _ = 1, geometry.indexCount do
                    indices[#indices+1] = ib.indexSize == 2 and indexData:ReadUShort() or indexData:ReadUInt()
                end
            else
                for index = geometry.vertexStart, geometry.vertexStart+geometry.vertexCount-1 do
                    indices[#indices+1] = index
                end
            end
            for i = 1, #indices-2, 3 do
                local a,b,c = vertex(indices[i]),vertex(indices[i+1]),vertex(indices[i+2])
                -- 排除后半车、轮区和不覆盖灯区的三角形，再做精确重心求交。
                if math.max(a.z,b.z,c.z)>0 and math.max(a.y,b.y,c.y)>=layout.y-layout.ry
                    and math.min(a.y,b.y,c.y)<=layout.y+layout.ry then
                    local e,f = b-a,c-a
                    local determinant = e.x*f.y-e.y*f.x
                    if math.abs(determinant)>1e-10 then
                        local faceNormal = e:CrossProduct(f):Normalized()
                        local normal = faceNormal.z < 0 and faceNormal*-1 or faceNormal
                        clipLens(a,b,c,normal)
                        for _, sample in ipairs(samples) do
                            local x,y = sample.x-a.x,sample.y-a.y
                            local u,v = (x*f.y-y*f.x)/determinant,(e.x*y-e.y*x)/determinant
                            if u>=-.000001 and v>=-.000001 and u+v<=1.000001 then
                                local z = a.z+u*e.z+v*f.z
                                if z>sample.z then sample.z,sample.normal=z,normal end
                            end
                        end
                    end
                end
            end
        end
    end
    local mounts = {} ---@type TrainLampMount[]
    for side = 1, 2 do
        -- 裁切可能同时命中内壁/后层；以每个碎片重心做独立深度选择，只保留最前车壳。
        local sourceLens,sourceNormals=assert(lensVertices[side]),assert(lensNormals[side])
        local visible,visibleNormals={},{} ---@type Vector3[],Vector3[]
        for i=1,#sourceLens-2,3 do
            local center=(sourceLens[i]+sourceLens[i+1]+sourceLens[i+2])/3
            local frontZ=-math.huge
            for j=1,#sourceLens-2,3 do
                local a,b,c=assert(sourceLens[j]),assert(sourceLens[j+1]),assert(sourceLens[j+2])
                local e,f=b-a,c-a
                local determinant=e.x*f.y-e.y*f.x
                if math.abs(determinant)>1e-10 then
                    local x,y=center.x-a.x,center.y-a.y
                    local u,v=(x*f.y-y*f.x)/determinant,(e.x*y-e.y*x)/determinant
                    if u>=-.000001 and v>=-.000001 and u+v<=1.000001 then
                        frontZ=math.max(frontZ,a.z+u*e.z+v*f.z)
                    end
                end
            end
            if center.z>=frontZ-.002 then
                for j=i,i+2 do
                    visible[#visible+1]=sourceLens[j]
                    visibleNormals[#visibleNormals+1]=sourceNormals[j]
                end
            end
        end
        lensVertices[side],lensNormals[side]=visible,visibleNormals
        local first = (side-1)*13+1
        local center = samples[first]
        assert(center.z>0 and center.z<math.huge,"车壳灯区射线未命中："..profile)
        local rim = {} ---@type Vector3[]
        for i = first+1, first+12 do
            local p = samples[i]
            assert(p.z>0 and p.z<math.huge,"灯缘不在车壳上："..profile)
            rim[#rim+1] = Vector3(p.x,p.y,p.z)
        end
        assert(#lensVertices[side]>0,"灯区车壳裁切为空："..profile)
        mounts[#mounts+1] = {surface=Vector3(center.x,center.y,center.z),normal=center.normal,rim=rim,
            lens=assert(lensVertices[side]),lensNormals=assert(lensNormals[side])}
    end
    headlightSurveys_[key] = mounts
    print(string.format("[Train] %s端%+d灯区LOD0求交：左(%.3f,%.3f,%.3f) 右(%.3f,%.3f,%.3f)",
        profile,nativeEnd,mounts[1].surface.x,mounts[1].surface.y,mounts[1].surface.z,
        mounts[2].surface.x,mounts[2].surface.y,mounts[2].surface.z))
    return mounts
end

---@param parent Node
---@param mount TrainLampMount
---@return Node
local function buildFlushLens(parent, mount)
    local marker = parent:CreateChild("FlushLens")
    local geometry = marker:CreateComponent("CustomGeometry")
    geometry:BeginGeometry(0,TRIANGLE_LIST)
    -- 灯面不是漂浮球。灯缘每一点均贴合原壳，底座嵌入1cm，只露出4mm发光面。
    ---@param p Vector3
    ---@param normal Vector3
    ---@param depth? number
    local function emit(p, normal, depth)
        geometry:DefineVertex(p+normal*(depth or .004))
        geometry:DefineNormal(normal)
        geometry:DefineTexCoord(Vector2.ZERO)
    end
    for i,p in ipairs(mount.lens) do emit(p,mount.lensNormals[i]) end
    -- 背面同样来自原壳，向内12mm；不连接跨越网格接缝的rim弦，防止出现悬空侧片。
    for i,p in ipairs(mount.lens) do emit(p,mount.lensNormals[i],-.012) end
    geometry:Commit()
    if not headlightMarkerMaterial_ then
        local mat = Material()
        mat:SetTechnique(0,assert(cache:GetResource("Technique","Techniques/NoTextureUnlit.xml")))
        mat:SetShaderParameter("MatDiffColor",Variant(Color(1.0,.92,.73)))
        mat:SetShaderParameter("MatEmissiveColor",Variant(Vector3(2.2,1.85,1.2)))
        mat.cullMode = CULL_NONE
        headlightMarkerMaterial_ = mat
    end
    geometry:SetMaterial(headlightMarkerMaterial_)
    -- 玩家只有两个投光源，照射范围由range限制；不能因外景机位拉远而熄灭。
    geometry.viewMask,geometry.lightMask,geometry.castShadows,geometry.drawDistance=1,1,false,0
    headlightMarkerNodes_[#headlightMarkerNodes_+1] = marker
    return marker
end

---@param node Node
---@param length number 兼容旧测试接口；正式成品不从此值推断挂点
---@param profile? string
---@param drawable? StaticModel
---@param direction? number
---@param reverse? boolean
function Train.BuildHeadlight(node, length, profile, drawable, direction, reverse)
    if headLightNode_ then headLightNode_:Dispose() end
    headlightMarkerNodes_,headlightMounts_ = {},{}
    local lightNode = node:CreateChild("HeadLight")
    headLightNode_ = lightNode
    local endSign = direction or 1
    lightNode.rotation = Quaternion(endSign<0 and 180 or 0,Vector3.UP)
    local source = drawable or node:GetComponent("StaticModel",true)
    headlightProfile_,headlightEnd_ = profile or "fixture",endSign
    if source and source.model then
        local nativeEnd = endSign*(reverse and -1 or 1)
        for _, mount in ipairs(surveyLamps(source,headlightProfile_,nativeEnd)) do
            headlightMounts_[#headlightMounts_+1] = {surface=mount.surface,normal=mount.normal,rim=mount.rim,
                lens=mount.lens,lensNormals=mount.lensNormals}
        end
    else
        -- 只为旧像素fixture保留自由光源；正式编组总是传实际drawable并强制求交。
        for _, x in ipairs({-.66,.66}) do
            headlightMounts_[#headlightMounts_+1] = {surface=Vector3(x,RAIL_TOP+1.9,length*.5),
                normal=Vector3.FORWARD,rim={},lens={},lensNormals={}}
        end
    end
    for i, spec in ipairs(HEADLIGHT_BEAMS) do
        local mount = headlightMounts_[i]
        if #mount.rim>0 then mount.marker=buildFlushLens(lightNode,mount) end
        local origin = lightNode:CreateChild(spec.name)
        origin.position = mount.surface+mount.normal*.06
        origin.direction = Vector3(-mount.surface.x/spec.target,(RAIL_TOP-origin.position.y)/spec.target,1):Normalized()
        mount.beam = origin
        local light = origin:CreateComponent("Light")
        light.lightType,light.perVertex = LIGHT_SPOT,false
        light.color = Color(1.0,.955,.84)
        light.usePhysicalValues = false -- brightness已是当前PBR路径强度，禁止再按流明除光锥立体角。
        light.brightness,light.range,light.fov,light.aspectRatio=spec.brightness,spec.range,spec.fov,spec.aspect
        light.outerConeAngle,light.innerConeAngle=spec.fov*.5,spec.fov*.32
        light.castShadows=false
        light.punctualLight,light.affectVolumetricFog=true,false
        light.specularIntensity=.22
        light.viewMask,light.lightMask=7,7
        light.drawDistance,light.fadeDistance=0,0
        light.enabled=headlightOn_
    end
    -- 近鼻端普通点光补足贴地照明；远近聚光仍负责前方定向照射。
    -- 让轨面在贴近车头时也有实际受光，不把发亮灯面误当成照地效果。
    local fill=lightNode:CreateChild("NearTrackFill")
    local front=headlightMounts_[1].surface
    fill.position=Vector3(0,RAIL_TOP+1.35,front.z+1.0)
    local light=fill:CreateComponent("Light")
    light.lightType=LIGHT_POINT
    light.perVertex,light.usePhysicalValues,light.punctualLight=false,false,true
    light.color=Color(1,.955,.84)
    light.brightness,light.range=55,13
    light.viewMask,light.lightMask=7,7
    light.castShadows,light.affectVolumetricFog=false,false
    light.drawDistance,light.fadeDistance=0,0
    light.enabled=headlightOn_
end

---@param node Node
---@param id? string
---@return Node
function Train.BuildLocomotive(node, id)
    local assetNode = Locomotive.Build(node, id)
    Train.BuildHeadlight(node, Locomotive.GetLength(id), id or "blue_white", assert(assetNode:GetComponent("StaticModel")))
    return assetNode
end

---@param node Node
---@param index integer
---@param forwardSign number
function Train.BuildCoach(node, index, forwardSign)
    local result = Coach.Build(node, index, forwardSign)
    for _, wheel in ipairs(result.wheels) do Train.RegisterWheel(wheel, forwardSign) end
    return result
end

---@param node Node
---@param forwardSign number
function Train.RegisterWheel(node, forwardSign)
    -- 轮轴已烘焙为X；保存实际朝向，不能硬编码Y轴圆柱的旋转。
    wheels_[#wheels_ + 1] = {node = node, base = node.rotation}
end

---@param dt number
---@param maximumS? number 前方闭塞安全界；不从本模块反向引用Traffic
---@param minimumS? number 后方闭塞安全界
function Train.Update(dt, maximumS, minimumS)
    if Accident.IsActive() then
        Accident.Update(dt)
        state_.v = 0
        return
    end
    local velocity = state_.v
    local absVelocity = math.abs(velocity)
    local force = 0.0
    if state_.throttle > 0 then
        local tractionScale = drivingMode_ == "relaxed" and GameConfig.Gameplay.RelaxedTractiveScale or 1
        local powerScale = drivingMode_ == "relaxed" and GameConfig.Gameplay.RelaxedPowerScale or 1
        force = math.min(selected_.maxTractive * tractionScale,
            selected_.powerW * powerScale / math.max(absVelocity, .1))
            * state_.throttle / T.MaxThrottle * (state_.reversing and -1 or 1)
    end
    local rage = GameModes.IsRage()
    if rage and state_.throttle > 0 then
        -- 狂暴使用独立街机牵引，不篡改目录中普通模式的SI车辆参数；无速度钳制。
        local direction = state_.reversing and -1 or 1
        force = force + direction * selected_.mass * 4.0 * state_.throttle / T.MaxThrottle
            / (1 + absVelocity / 160)
    end
    -- 沿每节车的真实坡向分摊重力；正坡去程减速、返程下坡助推。
    -- 用单位3D切线的y分量（sin坡角），不把‰数直接当加速度。
    if GameConfig.RouteProfile and #cars_ > 0 then
        local slope = 0.0
        for _, car in ipairs(cars_) do
            local _, tangent = Train.GetTrackSample(state_.s + car.offset)
            slope = slope + tangent.y
        end
        force = force - selected_.mass * 9.81 * slope / #cars_
    end
    local braking = selected_.maxBrakeForce * state_.brake * (rage and 3.2 or 1)
    -- 每车型全编组SI阻力；不要再把旧机车等效加速度乘动车质量。
    local resistance = (selected_.resistA + selected_.resistB * absVelocity + selected_.resistC * absVelocity * absVelocity)
        * (rage and .25 or 1)
    local net = force
    if absVelocity > 0.01 then
        net = force - (velocity > 0 and 1 or -1) * (braking + resistance)
    elseif math.abs(force) <= braking + resistance then
        net = 0
        velocity = 0
    else
        net = force - (force > 0 and 1 or -1) * (braking + resistance)
    end
    local nextVelocity = velocity + net / selected_.mass * dt
    -- 狂暴模式不设置任何速度上限；场景流式加载必须在后台追赶，不能反向修改驾驶动力。
    -- 近轨/地形缺块由 WorldStream 的扩大预加载窗口解决，不在这里截断速度。
    -- 减速不得跨过零速度变成倒车；只有显式换向并牵引才能反向启动。
    if velocity * nextVelocity < 0 and (state_.throttle == 0 or force * velocity >= 0) then
        nextVelocity = 0
    end
    if math.abs(nextVelocity) < 0.02 and state_.throttle == 0 then nextVelocity = 0 end
    state_.v = nextVelocity -- 不把建议/构造速度当自动限速器，危险由事故系统处理。
    -- 锁存实际行驶经历，推油门但被制动锁住不算移动；停稳后仍可用于接站。
    if math.abs(state_.v) > 0.02 then state_.moving = true end
    local oldS = state_.s
    local _, routeTangent = Train.GetTrackSample(state_.s)
    local mileageScale = GameConfig.RouteProfile and math.sqrt(routeTangent.x*routeTangent.x+routeTangent.z*routeTangent.z) or 1
    local nextS = state_.s + state_.v * dt * mileageScale
    if rage and not Route.IsClosed() then
        -- 开放试验场端点：缓冲器安全停车而非越界倾覆；停稳后R换向继续试验。
        -- [尾车净空 activeLength+20] ==== 可行驶轨道 ==== [车头净空16m]
        -- 两端只钳真实轨道包络，不将构造/曲线/站场建议速度当限速器。
        local minimum, maximum = activeLength_ + 20, Route.GetLength() - 20
        if nextS < minimum or nextS > maximum then
            nextS = math.max(minimum, math.min(maximum, nextS))
            state_.v, state_.throttle, state_.brake = 0, 0, 1
        end
    end
    -- 普通闭塞界仅用于提示；狂暴完全免疫侧向负荷、构造超速与碰撞倾覆。
    state_.s = Route.Wrap(nextS)
    if not rage then
        Accident.Evaluate(dt,state_.v,selected_.maxSpeedKmh,nextS,activeLength_,Train.GetTrackSample,cars_)
    end
    if Accident.IsActive() then
        for _,connection in ipairs(connections_) do connection.node.enabled=false end
    end
    state_.distanceTravelled = state_.distanceTravelled + (Route.IsClosed()
        and math.abs(state_.v) * dt or math.abs(state_.s - oldS))
    RailNetwork.UpdatePlayer(state_.s, activeLength_, state_.reversing)
end

---@param dt number
---@param force boolean? 进路恢复后，即使停车也重新贴合真实股道
function Train.UpdateVisuals(dt,force)
    if not root_ then return end
    if Accident.IsActive() then
        Accident.UpdateVisuals()
        for i,car in ipairs(cars_) do carPositions_[i]=car.node.worldPosition end
        return
    end
    if not force and not visualsDirty_ and math.abs(state_.s - lastVisualS_) < .0001 then return end
    lastVisualS_, visualsDirty_ = state_.s, false
    for i, car in ipairs(cars_) do
        local centerS = state_.s + car.offset
        local front = Train.GetTrackSample(centerS + car.pivot)
        local rear = Train.GetTrackSample(centerS - car.pivot)
        local midpoint = (front + rear) * 0.5
        local chord = front - rear
        local rotation = Quaternion()
        assert(rotation:FromLookRotation(chord, Vector3.UP), "车体支点退化，无法确定坡向")
        car.node.position = midpoint
        car.node.rotation = rotation
        carPositions_[i] = midpoint
        for _, bogie in ipairs(car.bogies) do
            -- 支点在弧线上，车体中心在弦中点：弯道不能只旋转车体而把轮轴放到轨外。
            local bogiePosition = Train.GetTrackSample(centerS + bogie.z)
            local axleFront = Train.GetTrackSample(centerS + bogie.z + 1.2)
            local axleRear = Train.GetTrackSample(centerS + bogie.z - 1.2)
            local axis = axleFront - axleRear
            local bogieRotation = Quaternion()
            assert(bogieRotation:FromLookRotation(axis, Vector3.UP), "转向架轴距退化")
            bogie.node.position = rotation:Inverse() * (bogiePosition - midpoint)
            bogie.node.rotation = rotation:Inverse() * bogieRotation
        end
    end
    for _, connection in ipairs(connections_) do Connections.Update(connection) end
    if dt > 0 and math.abs(state_.v) > 0.01 then Train.SpinWheels(state_.v / WHEEL_R * dt) end
end

---@param delta number
function Train.SpinWheels(delta)
    wheelAngle_ = (wheelAngle_ + delta) % (2 * math.pi)
    local spin = Quaternion(math.deg(wheelAngle_), Vector3.RIGHT)
    for _, wheel in ipairs(wheels_) do wheel.node.rotation = spin * wheel.base end
end

function Train.ThrottleUp()
    if state_.throttle < T.MaxThrottle then
        state_.throttle = state_.throttle + 1
    end
    return state_.throttle
end

function Train.ThrottleDown()
    state_.throttle = math.max(0, state_.throttle - 1)
    return state_.throttle
end

---@param notch integer
function Train.SetThrottle(notch)
    state_.throttle = math.max(0, math.min(T.MaxThrottle, math.floor(notch)))
end

---@param value number
function Train.SetBrake(value) state_.brake = Clamp(value, 0, 1) end
---@param delta number
function Train.AddBrake(delta) Train.SetBrake(state_.brake + delta) end

function Train.EmergencyBrake()
    state_.throttle, state_.brake = 0, 1
end

function Train.ToggleReversing()
    if math.abs(state_.v) > .02 or state_.throttle ~= 0 then return state_.reversing,false,"请先收油停稳再换向" end
    local nextDirection = not state_.reversing
    local ok, message = RailNetwork.RequestDirectionChange(state_.s,activeLength_,nextDirection)
    if not ok then print("[Train] 换向拒绝："..message); return state_.reversing,false,message end
    state_.reversing = nextDirection
    visualsDirty_ = true
    return state_.reversing,true,message
end

---@param s number
function Train.Reset(s)
    Accident.Reset()
    for _,connection in ipairs(connections_) do connection.node.enabled=true end
    state_.s = Route.Wrap(s or 0)
    state_.v, state_.throttle, state_.brake = 0, 0, 0
    state_.reversing, state_.moving = false, false
    visualsDirty_ = true
    RailNetwork.Reset(state_.s, activeLength_, false)
    Train.UpdateVisuals(0)
end

---@param on boolean
function Train.SetHeadlight(on)
    headlightOn_ = on == true
    if not headLightNode_ then return end
    local car = state_.reversing and cars_[#cars_] or cars_[1]
    local direction = state_.reversing and -1 or 1
    if car and (headLightNode_.parent ~= car.node or headlightEnd_ ~= direction or headlightProfile_ ~= car.profile) then
        Train.BuildHeadlight(car.node,car.length,car.profile,assert(car.drawable),direction,car.reverse)
    end
    -- 挂点只在换车/换端时重建；开关灯和昼夜渐变不得再把贴壳灯重置到BBox前方。
    local factor = headlightMode_ == "on" and 1 or math.max(.18,headlightFactor_)
    for index, spec in ipairs(HEADLIGHT_BEAMS) do
        local beam = headLightNode_:GetChild(spec.name)
        local light = beam and beam:GetComponent("Light")
        if light then
            light.enabled,light.brightness = headlightOn_,spec.brightness*factor
            if car then
                -- 坡顶/弯道按真实前方轨面瞄准，不让灯轴永远沿车体弦线射入山坡或天空。
                local mount = headlightMounts_[index]
                local targetS = state_.s+car.offset+direction*(mount.surface.z+spec.target)
                local trackTarget = Train.GetTrackSample(targetS)+Vector3(0,RAIL_TOP,0)
                local delta = headLightNode_:WorldToLocal(trackTarget)-beam.position
                if delta.z>1 then beam.direction=delta:Normalized() end
            end
        end
    end
    local fill=headLightNode_:GetChild("NearTrackFill")
    if fill then
        local light=fill:GetComponent("Light")
        if light then light.enabled,light.brightness=headlightOn_,55*factor end
    end
    for _, marker in ipairs(headlightMarkerNodes_) do marker.enabled = headlightOn_ end
end

---@param mode string
---@return boolean
function Train.SetHeadlightMode(mode)
    if mode ~= "auto" and mode ~= "on" and mode ~= "off" then return false end
    headlightMode_ = mode
    Train.UpdateHeadlight(headlightFactor_)
    print("[Train] 车灯模式 -> " .. mode)
    return true
end

---@param factor number
function Train.UpdateHeadlight(factor)
    headlightFactor_ = math.max(0,math.min(1,factor))
    Train.SetHeadlight(headlightMode_ == "on" or (headlightMode_ == "auto" and headlightFactor_ > .2))
end

---@return string
function Train.GetHeadlightMode() return headlightMode_ end

function Train.GetHeadlightDiagnostics()
    local result = {enabled=headlightOn_,mode=headlightMode_,factor=headlightFactor_,reversed=state_.reversing,
        lights=0,fillLights=0,range=0.0,node=headLightNode_,profile=headlightProfile_,endSign=headlightEnd_,mounts=headlightMounts_}
    if headLightNode_ then
        for _, light in ipairs(headLightNode_:GetComponents("Light",true)) do
            if light.enabled then
                if light.lightType==LIGHT_POINT then result.fillLights=result.fillLights+1
                else result.lights=result.lights+1 end
            end
            result.range=math.max(result.range,light.range)
        end
    end
    return result
end

---@return number
function Train.GetOperatingSpeedKmh() return selected_.operatingSpeedKmh end
---@return number
function Train.GetMaxSpeedKmh()
    if GameModes.IsRage() then return math.max(600, math.ceil(math.abs(state_.v) * KMH / 100) * 100 + 100) end
    return selected_.maxSpeedKmh
end
function Train.IsRageMode() return GameModes.IsRage() end
---@param gradeAdjusted? boolean 速度包络/信号提示使用；缺省仍返回车型标称值。
---@return number
function Train.GetServiceDeceleration(gradeAdjusted)
    local rated=selected_.serviceDeceleration
    local mountain=GameConfig.MountainTerrain
    if not gradeAdjusted or GameModes.IsRage() or not mountain then return rated end
    -- 用山区最大下坡预留全制动距离，避免仅采当前水平站坪而漏掉前方下坡。
    local stopping=state_.v*state_.v/(2*SpeedPolicy.ServiceDeceleration(rated,mountain.MaxGrade or .022))
        +math.abs(state_.v)*2+100
    local ahead=state_.reversing and state_.s or state_.s+stopping
    if ahead<(mountain.First or 0) then return rated end
    return SpeedPolicy.ServiceDeceleration(rated,mountain.MaxGrade or .022)
end

---@return number
function Train.GetSpeedKmh() return state_.v * KMH end
---@return number
function Train.GetSpeedMs() return state_.v end
---@return integer
function Train.GetThrottle() return state_.throttle end
---@return number
function Train.GetBrake() return state_.brake end
---@return boolean
function Train.IsReversing() return state_.reversing end
---@return number 机车中心弧长
function Train.GetS() return state_.s end
---@return boolean
function Train.IsMoving() return state_.moving end
---@return number
function Train.GetDistanceTravelled() return state_.distanceTravelled end
---@return Node|nil
function Train.GetLeadNode() return cars_[1] and cars_[1].node or nil end
---@return Vector3
function Train.GetLeadPosition() return carPositions_[1] or Vector3.ZERO end
---@return integer
function Train.GetCarCount() return #cars_ end
---@return Vector3[]
function Train.GetCarPositions() return carPositions_ end
-- 场景销毁前清除所有借用节点，避免再次开始时访问已Dispose的旧Train根。
function Train.Shutdown()
    selectionValidator_=nil
    Accident.Reset()
    Locomotive.ForgetLead()
    if root_ then root_:Dispose() end
    if connectionMaterial_ then connectionMaterial_:Dispose() end
    if identityMaterial_ then identityMaterial_:Dispose() end
    if headlightMarkerMaterial_ then headlightMarkerMaterial_:Dispose() end
    root_,vehicles_,headLightNode_,connectionMaterial_,identityMaterial_=nil,nil,nil,nil,nil
    headlightMarkerMaterial_,headlightMarkerNodes_=nil,{}
    headlightMounts_,headlightSurveys_={},{}
    headlightProfile_,headlightEnd_="",1
    cars_,carPositions_,wheels_,connections_={},{},{},{}
    activeLength_,visualsDirty_=0,true
end
function Train.ExportState()
    return {id=selected_.id,s=state_.s,v=state_.v,throttle=state_.throttle,brake=state_.brake,
        reversing=state_.reversing,moving=state_.moving,distanceTravelled=state_.distanceTravelled,
        drivingMode=drivingMode_,headlightMode=headlightMode_,derailed=Accident.IsActive(),topology=RailNetwork.ExportTopology()}
end
function Train.RestoreState(data)
    assert(type(data)=="table" and data.id==selected_.id,"存档车型不一致")
    assert(type(data.s)=="number" and data.s>=0 and data.s<=Route.GetLength(),"存档位置无效")
    assert(type(data.v)=="number" and data.v==data.v and math.abs(data.v)<(GameModes.IsRage() and 10000 or 200),"存档速度无效")
    Train.Reset(data.s)
    state_.reversing,state_.moving=data.reversing==true,data.moving==true
    state_.distanceTravelled=math.max(0,tonumber(data.distanceTravelled) or 0)
    drivingMode_=data.drivingMode=="simulation" and "simulation" or "relaxed"
    Train.SetHeadlightMode(data.headlightMode == "on" and "on" or (data.headlightMode == "off" and "off" or "auto"))
    state_.v=data.v
    Train.SetThrottle(math.floor(tonumber(data.throttle) or 0))
    Train.SetBrake(tonumber(data.brake) or 1)
    RailNetwork.RestoreTopology(data.topology,state_.reversing)
    RailNetwork.UpdatePlayer(state_.s,activeLength_,state_.reversing)
    visualsDirty_=true;Train.UpdateVisuals(0)
    -- 事故由入口在客流/运营恢复完成后重建，避免先结束本局再恢复开门队列。
end

---@return TrainCar[]
function Train.GetCars() return cars_ end
---@return EMUConnection[]
function Train.GetConnections() return connections_ end

---@param s number
---@return Vector3, Vector3, number
function Train.GetTrackSample(s)
    return RailNetwork.Sample(s, RailNetwork.GetPlayerLane(s))
end

function Train.GetAccidentStatus() return Accident.GetStatus() end
function Train.IsDerailed() return Accident.IsActive() end
function Train.Derail(reason)
    if GameModes.IsRage() then return false end
    if Accident.Trigger(cars_,state_.v,reason) then
        for _,connection in ipairs(connections_) do connection.node.enabled=false end
    end
end
function Train.GetDrivingMode() return drivingMode_ end
---@param name string
---@return boolean, string
function Train.SetDrivingMode(name)
    if name ~= "relaxed" and name ~= "simulation" then return false, "未知驾驶模式" end
    if math.abs(state_.v) > .02 then return false, "请停稳后切换驾驶模式" end
    drivingMode_ = name
    return true, name == "relaxed" and "休闲牵引：响应更敏捷" or "模拟牵引：原SI动力参数"
end

---@param id? string
---@return boolean, string
function Train.GetAppearanceStatus(id)
    local entry = id and Catalog.Find(id) or selected_
    if not entry then return false, "未知车型" end
    for _, profile in ipairs(entryProfiles(entry)) do
        local report = RollingStock.GetAppearanceReport(profile)
        if not report.accepted then return false, report.message end
    end
    if entry.kind ~= "emu" then
        local status = Coach.GetAssetStatus(entry.id)
        if not status.accepted then return false, "车头可用；" .. status.message end
        return true, status.message
    end
    return true, "动车外观及实测端面已验收"
end
---@return Vector3
function Train.GetHeadPosition()
    local lead = Train.GetLeadNode()
    if lead then return lead:LocalToWorld(Vector3(0, 0, Locomotive.GetLength(selected_.head) * 0.5)) end
    return Vector3.ZERO
end

---@class TrainCatalogItem
---@field id string
---@field name string
---@field kind string
---@field description string
---@field maxSpeedKmh number
---@field ready boolean
---@field readinessMessage string
---@field appearanceReady boolean
---@field appearanceMessage string
---@field coachAssetSource string|nil 客车真实来源；非动车有值，不影响ready可玩状态

---@return TrainCatalogItem[]
function Train.GetCatalog()
    local result = {}
    for _, entry in ipairs(Catalog.Entries) do
        local appearanceReady, appearanceMessage = Train.GetAppearanceStatus(entry.id)
        local coachStatus = entry.kind ~= "emu" and Coach.GetAssetStatus(entry.id) or nil
        local description = entry.description
        if coachStatus and not coachStatus.accepted then
            local note = coachStatus.source == "procedural_placeholder"
                and "客车暂为程序化代用，独立生成待交付。" or (coachStatus.message .. "。")
            description = note .. description
        elseif not appearanceReady then
            description = appearanceMessage .. "。" .. description
        end
        local selectable, readinessMessage = availableEntry(entry)
        result[#result + 1] = {id=entry.id, name=entry.name, kind=entry.kind,
            description=description,
            maxSpeedKmh=entry.maxSpeedKmh, ready=selectable,readinessMessage=readinessMessage,
            appearanceReady=appearanceReady, appearanceMessage=appearanceMessage,
            coachAssetSource=coachStatus and coachStatus.source or nil}
    end
    return result
end

---@return string
function Train.GetSelectedId() return selected_.id end
---@return string
function Train.GetSelectedName() return selected_.name end
---@return string
function Train.GetPowerType()
    if selected_.kind == "emu" then return "emu" end
    return (selected_.id == "SS9G" or selected_.id == "HXD3D") and "electric" or "diesel"
end
---@return number
function Train.GetActiveLength() return activeLength_ end
---@return Vector3
function Train.GetCabOffset()
    local profile = Catalog.Profiles[selected_.head]
    return profile and profile.cab or Vector3(0, 3.35, Locomotive.Length * .5 - 2.2)
end
---@return Quaternion
function Train.GetLeadRotation()
    local lead = Train.GetLeadNode()
    return lead and lead.worldRotation or Quaternion()
end
---@return Node|nil
function Train.GetRoot() return root_ end

--- 验证当前八节真实成品绑定，可供恢复/回归检测；不会修改共享模型。
---@return boolean, string
function Train.ValidateBindings()
    local ok, message = pcall(verifyFormation,selected_,cars_)
    return ok, ok and "八节真实MDL/纹理/轮轨绑定通过" or tostring(message)
end

--- forceRebuild修复同车型实例；只使用当前资源缓存，不执行远端热更新或Dispose共享MDL。
---@param id string
---@param forceRebuild? boolean
---@return boolean, string
function Train.Select(id, forceRebuild)
    if Accident.IsActive() then return false,"事故后请重开本局，再选择车型" end
    if math.abs(state_.v) > .1 then return false, "请先停稳列车再换车（速度须不超过0.1m/s）" end
    local entry = Catalog.Find(id)
    if not entry then return false, "未知车型，请从车队目录选择" end
    if not root_ then return false, "列车尚未构建" end
    local ready, message = prepareEntry(entry)
    if not ready then
        releaseUnused()
        print("[Train] 车型资源准备失败：" .. entry.name .. "：" .. message)
        return false, entry.name .. "资源未准备好，请稍后重试"
    end
    if entry.id ~= selected_.id or forceRebuild == true then
        local ok, result = rebuildVehicles(entry)
        if not ok then
            releaseUnused()
            return false, entry.name .. "装配失败，原列车已保留"
        end
    else
        local valid, reason = Train.ValidateBindings()
        if not valid then
            print("[Train] 同车型实际绑定失效，须强制安全重建：" .. reason)
            releaseUnused()
            return false, "当前车型绑定需修复，请重新加载车型"
        end
    end
    releaseUnused()
    -- 不调用Reset：弧长、行驶经历、站序与XP的拥有者都保留；仅安全锁存驾驶控件。
    state_.v, state_.throttle, state_.brake = 0, 0, 1
    visualsDirty_ = true
    RailNetwork.UpdatePlayer(state_.s, activeLength_, state_.reversing)
    Train.UpdateVisuals(0)
    return true, "已选择" .. entry.name .. "，制动已锁定"
end

return Train
