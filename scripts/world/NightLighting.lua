-- 夜间投光池：灯位属于流式站点/道路，Light组件只属于本模块的固定预算池。
-- 宽照明使用普通点光，不依赖聚光投影/面积光；远处保留可见灯芯，不造透明光锥。
local NightLighting = {}
local VisualQuality = require "config.VisualQuality"

---@class NightLampSite
---@field owner string
---@field kind string
---@field position Vector3
---@field direction Vector3
---@field color Color
---@field brightness number
---@field range number
---@field fov number
---@field aspect number
---@field innerAngle number
---@field outerAngle number
---@field localPosition Vector3 灯位存为源节点局部坐标，站点整体平移/旋转后仍随灯具
---@field localDirection Vector3
---@field source Node
---@class NightLampSlot
---@field light Light
---@field node Node
---@field site NightLampSite?
---@class NightLampCandidate
---@field site NightLampSite
---@field distance number 到相机/焦点邻域的最近距离，用于选灯淡出
---@field priority number 焦点稍优先，但仍保留相机近景候选
---@field order integer 同距离时沿用注册顺序，避免排序抖动

---@type Scene?
local scene_ = nil
---@type Node?
local root_ = nil
---@type NightLampSite[]
local sites_ = {}
---@type table<string, Material>
local bulbMaterials_ = {}
---@type table<string, NightLampSlot[]>
local pools_ = {station = {}, road = {}}
---@type Vector3?
local camera_ = nil
---@type Vector3?
local focus_ = nil
local factor_, materialFactor_, quality_, dirty_ = 0.0, 0.0, "medium", true
local refreshes_, maxRefreshMs_, tick_ = 0, 0.0, 0
local BUDGETS = {
    low = {station = 12, road = 6},
    medium = {station = 18, road = 8},
    high = {station = 20, road = 8},
}
local DISTANCES = {station = 180.0, road = 240.0}

local function clamp(v) return math.max(0.0, math.min(1.0, v)) end

---@param source Node
---@return boolean
local function sourceVisible(source)
    -- Node:IsEnabled()只反映节点本身；协程常禁用其父chunk而不逐个禁用子节点。
    -- 池里的Light不属于该父树，必须自己沿父链检查，否则半成品/已隐藏站仍漏光。
    -- 已从场景移除的源节点也不能继续借用池灯；正常卸载仍须先Forget再Dispose。
    if source.scene ~= scene_ then return false end
    local current = source --[[@as Node?]]
    while current do
        if not current:IsEnabled() then return false end
        current = current.parent
    end
    return true
end

--- 幂等绑定，不清除先于Environment.Init注册的流式灯位。
---@param scene Scene
function NightLighting.Attach(scene)
    if scene_ == scene and root_ then return end
    NightLighting.Shutdown()
    scene_ = scene
    root_ = scene:CreateChild("NightLightingPool", LOCAL)
    print("[NightLighting] 固定预算普通点光池已绑定；灯芯独立可见，无阴影/面积光依赖")
end

---@param kind string station/road
---@param owner string 流式卸载所有权
---@param source Node 几何所在节点；半成品未启用时绝不投光
---@param position Vector3 世界坐标
---@param direction Vector3 世界方向
---@param options? table
function NightLighting.Register(kind, owner, source, position, direction, options)
    local scene = source.scene
    if not scene then return end
    NightLighting.Attach(scene)
    options = options or {}
    assert(pools_[kind],"未知夜灯类型："..tostring(kind))
    local fov = math.max(1.0, math.min(160.0, options.fov or 100.0))
    local outer = fov * .5
    local aim = direction:LengthSquared()>.000001 and direction:Normalized() or Vector3.DOWN
    sites_[#sites_ + 1] = {
        kind = kind, owner = owner, source = source, position = position,
        localPosition=source:WorldToLocal(position),localDirection=source.worldRotation:Inverse()*aim,
        direction = aim, color = options.color or Color(1.0, .91, .75),
        brightness = options.brightness or (kind == "station" and 260.0 or 450.0), range = options.range or 30.0,
        fov = fov, aspect = options.aspect or 1.0,
        -- 保留灯位原始配光描述，供诊断读取；宽照明池使用点光，不依赖锥角。
        innerAngle = outer * .65, outerAngle = outer,
    }
    dirty_ = true
end

--- 必须先于WorldStream释放几何父节点，池中已借用该灯位的光立即关闭。
---@param owner string
function NightLighting.Forget(owner)
    for _, pool in pairs(pools_) do
        for _, slot in ipairs(pool) do
            if slot.site and slot.site.owner == owner then
                slot.light.enabled, slot.site = false, nil
            end
        end
    end
    for i = #sites_, 1, -1 do
        if sites_[i].owner == owner then table.remove(sites_, i) end
    end
    dirty_ = true
end

local function resizePools()
    if not root_ then return end
    local budget = BUDGETS[quality_] or BUDGETS.medium
    for kind, pool in pairs(pools_) do
        local count = budget[kind]
        while #pool > count do
            local slot = table.remove(pool)
            slot.node:Dispose()
        end
        while #pool < count do
            local node = root_:CreateChild(kind .. "_" .. (#pool + 1), LOCAL)
            local light = node:CreateComponent("Light")
            light.lightType = LIGHT_POINT
            light.perVertex,light.usePhysicalValues = false,false
            light.castShadows = false
            light.punctualLight = true
            light.specularIntensity = .12
            light.affectVolumetricFog = false
            light.viewMask, light.lightMask = 2, 2
            light.enabled = false
            pool[#pool + 1] = {node = node, light = light}
        end
    end
end

---@param kind string
---@return Material
function NightLighting.GetBulbMaterial(kind)
    if not bulbMaterials_[kind] then
        local material = Material()
        material:SetTechnique(0, assert(cache:GetResource("Technique", "Techniques/NoTextureUnlit.xml")))
        material:SetShaderParameter("MatDiffColor", Variant(Color(.10+factor_*2.3,.11+factor_*1.94,.12+factor_*1.42)))
        material.cullMode = CULL_NONE
        bulbMaterials_[kind] = material
    end
    return bulbMaterials_[kind]
end

---@param factor number
---@param quality? string
function NightLighting.SetEnvironment(factor, quality)
    local nextFactor = clamp(factor)
    if math.abs(nextFactor - factor_) > .002 then dirty_ = true end
    if math.abs(nextFactor - materialFactor_) > .002 then
        materialFactor_ = nextFactor
        for _, material in pairs(bulbMaterials_) do
            material:SetShaderParameter("MatDiffColor", Variant(Color(.10+nextFactor*2.3,.11+nextFactor*1.94,.12+nextFactor*1.42)))
        end
    end
    factor_ = nextFactor
    if quality then
        local normalized = VisualQuality.Normalize(quality)
        if normalized ~= quality_ then quality_, dirty_ = normalized, true end
    end
end

--- 不按全线查场景，仅扫描当前已加载灯位；相机/观察焦点移动4m或灯位/昼夜变化才重选。
--- source父链有效状态排除协程半成品。昼间不创建池、不排序、不做额外pass。
---@param cameraPos? Vector3 真实渲染相机，决定Light的引擎裁剪距离
---@param focusPos? Vector3 当前观察目标；省略时保持旧接口的相机邻域行为
function NightLighting.Update(cameraPos, focusPos)
    if not root_ or not cameraPos then return end
    local focus = focusPos or cameraPos
    tick_ = tick_ + 1
    local moved = not camera_ or (cameraPos - camera_).length >= 4.0
        or not focus_ or (focus - focus_).length >= 4.0
    -- 静止相机每15次Update复查半成品是否已显现，不依赖游戏dt（暂停仍流式加载）。
    if not moved and not dirty_ and tick_ % 15 ~= 0 then return end
    local begin = os.clock()
    camera_, focus_, dirty_ = cameraPos, focus, false
    if factor_ <= .015 then
        for _, pool in pairs(pools_) do
            for _, slot in ipairs(pool) do slot.light.enabled, slot.site = false, nil end
        end
        return
    end
    resizePools()
    for kind, pool in pairs(pools_) do
        ---@type NightLampCandidate[]
        local candidates = {}
        local radius = DISTANCES[kind]
        for order, site in ipairs(sites_) do
            if site.kind == kind and sourceVisible(site.source) then
                site.position=site.source:LocalToWorld(site.localPosition)
                site.direction=(site.source.worldRotation*site.localDirection):Normalized()
                local cameraDistance = (site.position - cameraPos).length
                local focusDistance = (site.position - focus).length
                local distance = math.min(cameraDistance, focusDistance)
                -- 不扩大180/240m邻域或池预算。鸟瞰按实际观察目标选灯；
                -- 相机附近仍可入选，焦点以轻微权重优先，避免机位周边吞掉目标的灯。
                if distance < radius then
                    candidates[#candidates + 1] = {site = site, distance = distance,
                        priority = math.min(focusDistance, cameraDistance * 1.15), order = order}
                end
            end
        end
        table.sort(candidates, function(a, b)
            if a.priority == b.priority then return a.order < b.order end
            return a.priority < b.priority
        end)
        ---@type table<NightLampSite, number>
        local wanted = {}
        for i = 1, math.min(#pool, #candidates) do
            local candidate = candidates[i]
            wanted[candidate.site] = candidate.distance
        end
        -- 保留已选灯位的slot，避免每次排序把全部池灯搬动。
        for _, slot in ipairs(pool) do
            if slot.site and not wanted[slot.site] then slot.site = nil end
        end
        for _, slot in ipairs(pool) do
            if slot.site then wanted[slot.site] = -wanted[slot.site] - 1 end
        end
        for _, slot in ipairs(pool) do
            if not slot.site then
                for site, distance in pairs(wanted) do
                    if distance >= 0 then
                        slot.site = site
                        wanted[site] = -distance - 1
                        slot.node.worldPosition = site.position
                        slot.node:SetWorldDirection(site.direction)
                        slot.light.color = site.color
                        slot.light.range, slot.light.fov, slot.light.aspectRatio = site.range, site.fov, site.aspect
                        slot.light.innerConeAngle, slot.light.outerConeAngle = site.innerAngle, site.outerAngle
                        break
                    end
                end
            end
            local site = slot.site
            slot.light.enabled = site ~= nil
            if site then
                slot.node.worldPosition=site.position
                slot.node:SetWorldDirection(site.direction)
                -- 引擎按真实相机距离裁剪/淡出，不能沿用焦点的180/240m半径。
                -- 保留slot也必须更新；45m余量覆盖4m重选阈值和光锥中心偏移。
                local cameraDistance = (site.position - cameraPos).length
                local fadeDistance = math.max(radius or 240.0, cameraDistance + site.range + 45.0)
                slot.light.drawDistance, slot.light.fadeDistance = fadeDistance + site.range, fadeDistance
                local distance = -wanted[site] - 1
                local fade = clamp((radius - distance) / 45.0)
                slot.light.brightness = site.brightness * factor_ * fade
            end
        end
    end
    refreshes_ = refreshes_ + 1
    maxRefreshMs_ = math.max(maxRefreshMs_, (os.clock() - begin) * 1000)
end

function NightLighting.GetStats()
    local budget = BUDGETS[quality_] or BUDGETS.medium
    local stats = {sites = #sites_, stationSites = 0, roadSites = 0, activeStation = 0, activeRoad = 0,
        poolLights = 0, factor = factor_, quality = quality_, refreshes = refreshes_, maxRefreshMs = maxRefreshMs_,
        budgetStation = budget.station, budgetRoad = budget.road, ordinarySpot = false, ordinaryPoint = true,
        viewMask = 2, lightMask = 2, coneAnglesExplicit = true}
    for _, site in ipairs(sites_) do
        if site.kind == "station" then stats.stationSites = stats.stationSites + 1
        else stats.roadSites = stats.roadSites + 1 end
    end
    for kind, pool in pairs(pools_) do
        stats.poolLights = stats.poolLights + #pool
        for _, slot in ipairs(pool) do
            if slot.light.enabled then
                if kind == "station" then stats.activeStation = stats.activeStation + 1
                else stats.activeRoad = stats.activeRoad + 1 end
            end
        end
    end
    return stats
end

function NightLighting.GetFactor() return factor_ end
function NightLighting.GetDiagnostics() return NightLighting.GetStats() end
function NightLighting.GetSites() return sites_ end
function NightLighting.GetLights()
    local lights = {} ---@type Light[]
    for _, pool in pairs(pools_) do
        for _, slot in ipairs(pool) do lights[#lights+1] = slot.light end
    end
    return lights
end

--- 只释放自己创建的Light池，先丢借用灯位，不Dispose任何流式/调用者节点。
function NightLighting.Shutdown()
    sites_, pools_ = {}, {station = {}, road = {}}
    if root_ then root_:Dispose() end
    scene_, root_, camera_, focus_ = nil, nil, nil, nil
    for _, material in pairs(bulbMaterials_) do
        material:SetShaderParameter("MatDiffColor", Variant(Color(.10,.11,.12)))
    end
    factor_, materialFactor_, dirty_, refreshes_, maxRefreshMs_, tick_ = 0.0, 0.0, true, 0, 0.0, 0
end

return NightLighting
