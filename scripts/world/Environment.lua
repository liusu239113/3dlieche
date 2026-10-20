-- ============================================================================
-- Environment - 唯一时间/天气真源，接管已有 Zone / 主光 / Skybox，不新建 Zone。
-- 基于 examples/29-procedural-sky、30-pelican-bike/atmosphere 的昼夜与降水结构，
-- 降级到现有移动/GLES 已用的 DiffSkybox + AMBIENT_COLOR，不启用新后效。
-- main 在旧 ApplyAtmosphere 后调用 SetQuality；暂停调用 SetPaused；cab 调 SetSheltered。
-- Export/Restore 只含 JSON 可序列化标量；画质和运行期暂停不写入旅程天气存档。
-- ============================================================================
local Config = require "config.EnvironmentConfig"
local VisualQuality = require "config.VisualQuality"
local NightLighting = require "world.NightLighting"
local Environment = {}

---@class EnvironmentOptions
---@field hour? number
---@field time? number Alias of hour
---@field running? boolean
---@field timeRunning? boolean Alias of running
---@field weather? string clear/cloudy/rain/fog
---@field dayLength? number Real seconds per game day
---@field quality? VisualQualityPreset|string
---@field skyNode? Node
---@field visuals? boolean False permits deterministic state-only tests
---@field rain? boolean False disables near-camera precipitation only

---@class EnvironmentPatch
---@field hour? number
---@field running? boolean
---@field weather? string
---@field dayLength? number

---@class EnvironmentSnapshot
---@field version integer
---@field hour number
---@field running boolean
---@field weather string Target preset, not a guessed nearest current preset
---@field dayLength number
---@field cloud number
---@field rain number
---@field sunScale number
---@field fogScale number
---@field fog? number Independent near-fog blend; absent in pre-fog v1 snapshots
---@field overcastSky? boolean Persist sky-mode hysteresis during a weather transition
---@field minutes? number 跨日绝对世界分钟；旧v1档缺省为hour*60
---@field revision? integer 手动调时序号，供运行计划识别调时而非自然晚点

---@class EnvironmentClock
---@field minutes number 自然推进跨日不回绕
---@field rate number 每模拟秒推进的世界分钟
---@field running boolean
---@field paused boolean
---@field revision integer

---@class EnvironmentStatus
---@field hour number Continuous hours in [0,24)
---@field minute integer
---@field weather string Target preset: clear/cloudy/rain/fog
---@field weatherLabel string
---@field clockText string
---@field running boolean Clock enabled (independent of pause)
---@field paused boolean
---@field lampFactor number Platform/ambient lamps [0,1]
---@field lamps number Alias of lampFactor
---@field headlightFactor number Headlights [0,1]
---@field signalFactor number Signal emission multiplier, never below daytime visibility
---@field rainIntensity number Smoothed actual rain [0,1], even if sheltered
---@field cloudCover number Smoothed actual clouds [0,1]
---@field fogIntensity number Smoothed independent near-fog blend [0,1]
---@field dayMix number
---@field nightMix number
---@field sheltered boolean
---@field quality string
---@field fogStart number
---@field fogEnd number
---@field skyReady boolean
---@field rainReady boolean

---@class EnvironmentSkyPixel
---@field x integer
---@field y integer
---@field elevation number
---@field gradient number
---@field cloud number

---@type Scene|nil
local scene_ = nil
---@type Zone|nil
local zone_ = nil
---@type Light|nil
local sun_ = nil
---@type Skybox|nil
local skybox_ = nil
---@type Material|nil
local originalSkyMaterial_ = nil
---@type Material|nil
local skyMaterial_ = nil
---@type TextureCube|nil
local skyTexture_ = nil
---@type Texture|nil
local realisticTexture_ = nil
---@type Image[]
local skyImages_ = {}
---@type EnvironmentSkyPixel[][]
local skyPixels_ = {}
---@type Node|nil
local rainNode_ = nil
---@type ParticleEmitter|nil
local rainEmitter_ = nil
---@type ParticleEffect|nil
local rainEffect_ = nil
---@type Material|nil
local rainMaterial_ = nil
---@type Texture2D|nil
local rainTexture_ = nil
---@type Vector3|nil
local lastCamera_ = nil
---@type Vector3|nil
local lastFocus_ = nil

local initialized_, paused_, sheltered_ = false, false, false
local visuals_, rainAllowed_ = true, true
local hour_, running_, dayLength_ = Config.DefaultHour, true, Config.DayLength
local minutes_, revision_ = Config.DefaultHour * 60.0, 0
local visualDirty_ = false
local weather_, cloud_, rain_, sunScale_, fogScale_ = "clear", 0.0, 0.0, 1.0, 1.0
local fog_ = 0.0
local quality_ = VisualQuality.Get(nil)
local skyElapsed_, skyDirty_ = 0.0, true
local lastEmission_ = -1.0
local overcastSky_ = false
local day_, night_, golden_, elevation_ = 1.0, 0.0, 0.0, 1.0
local lamps_, fogStart_, fogEnd_ = 0.0, quality_.fogStart, quality_.fogEnd
local zenith_, horizon_, ground_ = Color(0.19, 0.42, 0.78), quality_.fogColor, Color(0.30, 0.35, 0.28)

---@param value any
---@return boolean
local function finite(value)
    return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

---@param value number
---@param low number
---@param high number
---@return number
local function clamp(value, low, high) return math.max(low, math.min(high, value)) end

---@param a number
---@param b number
---@param t number
---@return number
local function lerp(a, b, t) return a + (b - a) * t end

---@param a number
---@param b number
---@param x number
---@return number
local function smoothstep(a, b, x)
    local t = clamp((x - a) / (b - a), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)
end

---@param a Color
---@param b Color
---@param t number
---@return Color
local function colorLerp(a, b, t)
    return Color(lerp(a.r, b.r, t), lerp(a.g, b.g, t), lerp(a.b, b.b, t), 1.0)
end

local function calculate()
    -- 迟滞只切换贴图模式，cloud/rain/光照和雾仍为连续值；不承诺云层无缝形变。
    local previousOvercast = overcastSky_
    if cloud_ >= 0.35 then overcastSky_ = true
    elseif cloud_ <= 0.20 then overcastSky_ = false end
    if previousOvercast ~= overcastSky_ then skyDirty_ = true end
    local angle = (hour_ - 6.0) / 12.0 * math.pi
    elevation_ = math.sin(angle)
    day_ = smoothstep(-0.12, 0.30, elevation_)
    night_ = 1.0 - smoothstep(-0.20, -0.02, elevation_)
    golden_ = math.exp(-((elevation_ - 0.02) / 0.16) ^ 2)
    lamps_ = math.max(1.0 - smoothstep(-0.06, 0.16, elevation_), rain_ * 0.72, cloud_ * 0.22, fog_ * 0.82)

    local clearTop = colorLerp(Color(0.026, 0.043, 0.095), Color(0.19, 0.42, 0.78), day_)
    local clearHorizon = colorLerp(Color(0.065, 0.087, 0.145), quality_.fogColor, day_)
    local duskTop = colorLerp(clearTop, Color(0.24, 0.22, 0.38), golden_ * 0.50)
    local duskHorizon = colorLerp(clearHorizon, Color(0.76, 0.48, 0.34), golden_ * 0.76)
    local grey = 0.075 + day_ * 0.52 + golden_ * 0.08
    zenith_ = colorLerp(duskTop, Color(grey * 0.72, grey * 0.79, grey * 0.88), cloud_ * 0.90)
    horizon_ = colorLerp(duskHorizon, Color(grey * 0.96, grey, grey * 1.04), cloud_ * 0.92)
    ground_ = colorLerp(Color(0.025, 0.035, 0.052), Color(0.30, 0.35, 0.28), day_)
    if realisticTexture_ and quality_.sky == "realistic" and not overcastSky_ then
        -- 保留2048²照片云纹；晴朗中高档同一RGB乘数同时驱动天空与雾。
        -- 阴雨超过迟滞阈值后改用原位更新的CPU灰云天空，不把蓝空照片硬染成雨天。
        local brightness = (0.035 + 1.115 * day_) * (1.0 - cloud_ * 0.42)
        local dusk = golden_ * 0.65
        local red, green, blue = brightness * (1.0 + dusk * 0.65), brightness * (1.0 - dusk * 0.15), brightness * (1.0 - dusk * 0.55)
        horizon_ = Color(quality_.fogColor.r * red / 1.15, quality_.fogColor.g * green / 1.15, quality_.fogColor.b * blue / 1.15)
    end
    -- 灰雾色跟昼夜变化，近雾独立于 cloud/rain，不能把阴天误判成浓雾。
    local fogGrey = 0.075 + 0.53 * day_ + 0.035 * golden_
    local fogColor = Color(fogGrey * 0.97, fogGrey, fogGrey * 1.025)
    horizon_ = colorLerp(horizon_, fogColor, fog_)
    zenith_ = colorLerp(zenith_, fogColor, fog_ * 0.86)
    ground_ = colorLerp(ground_, fogColor, fog_ * 0.85)
    -- 晴/阴/雨保留原铁路视距底限；独立平滑权重才收近到80..700m。
    -- 不随目标 weather 字符串瞬切，暂停/反向切换/读档/画质切换均继续同一权重。
    local nightScale = lerp(1.0, 0.76, night_)
    local baseStart = math.max(180.0, quality_.fogStart * fogScale_ * nightScale)
    local baseEnd = math.max(baseStart + 500.0, quality_.fogEnd * fogScale_ * nightScale)
    fogStart_ = lerp(baseStart, Config.FogStart, fog_)
    fogEnd_ = lerp(baseEnd, Config.FogEnd, fog_)
end

-- CPU cubemap 始终用同一贴图/六张 Image。方向映射沿用 SkyUtils，所有面边缘连续。
-- 只预计算方向权重和廉价云斑，不读回官方压缩 cubemap，不引入新着色器。
local function createSky()
    if not skybox_ then return end
    local original = skybox_:GetMaterial()
    if not original then
        print("[Environment] 天空无材质：保留现状，仅更新光照和雾")
        return
    end
    originalSkyMaterial_ = original
    skyMaterial_ = original:Clone()
    local Sky = require "world.Sky"
    local path = Sky.GetRealisticPath()
    realisticTexture_ = path and cache:GetResource("TextureCube", path) or nil
    skyTexture_ = TextureCube:new()
    skyTexture_:SetSRGB(true)
    ---@type number[][][]
    local axes = {
        { {0, 0, -1}, {0, -1, 0}, {1, 0, 0} },
        { {0, 0, 1}, {0, -1, 0}, {-1, 0, 0} },
        { {1, 0, 0}, {0, 0, 1}, {0, 1, 0} },
        { {1, 0, 0}, {0, 0, -1}, {0, -1, 0} },
        { {1, 0, 0}, {0, -1, 0}, {0, 0, 1} },
        { {-1, 0, 0}, {0, -1, 0}, {0, 0, -1} },
    }
    for face = 1, 6 do
        local image = Image()
        image:SetSize(Config.SkySize, Config.SkySize, 4)
        skyImages_[face] = image
        ---@type EnvironmentSkyPixel[]
        local pixels = {}
        local right, up, forward = axes[face][1], axes[face][2], axes[face][3]
        for y = 0, Config.SkySize - 1 do
            for x = 0, Config.SkySize - 1 do
                local u, v = (x + 0.5) / Config.SkySize * 2 - 1, (y + 0.5) / Config.SkySize * 2 - 1
                local dx = forward[1] + u * right[1] + v * up[1]
                local dy = forward[2] + u * right[2] + v * up[2]
                local dz = forward[3] + u * right[3] + v * up[3]
                local length = math.sqrt(dx * dx + dy * dy + dz * dz)
                local elev = dy / length
                local waves = math.sin(dx / length * 19 + dz / length * 11) * math.cos(dz / length * 16 - elev * 7)
                pixels[#pixels + 1] = {
                    x = x, y = y, elevation = elev,
                    gradient = math.abs(elev) ^ (elev >= 0 and 0.55 or 1.5),
                    cloud = smoothstep(0.10, 0.75, waves) * smoothstep(0.04, 0.20, elev),
                }
            end
        end
        skyPixels_[face] = pixels
    end
    skybox_:SetMaterial(skyMaterial_)
end

local function applySky()
    if not skyMaterial_ then return end
    if realisticTexture_ and quality_.sky == "realistic" and not overcastSky_ then
        local brightness = (0.035 + 1.115 * day_) * (1.0 - cloud_ * 0.42)
        local dusk = golden_ * 0.65
        skyMaterial_:SetTexture(TU_DIFFUSE, realisticTexture_)
        skyMaterial_:SetShaderParameter("MatDiffColor", Variant(Vector4(
            brightness * (1.0 + dusk * 0.65), brightness * (1.0 - dusk * 0.15), brightness * (1.0 - dusk * 0.55), 1.0)))
        skyElapsed_, skyDirty_ = 0.0, false
        return
    end
    if not skyTexture_ then return end
    for face = 1, 6 do
        local image = skyImages_[face]
        for _, pixel in ipairs(assert(skyPixels_[face])) do
            local target = pixel.elevation >= 0 and zenith_ or ground_
            local base = colorLerp(horizon_, target, pixel.gradient)
            local clouds = pixel.cloud * (0.16 + 0.45 * cloud_) * (0.35 + 0.65 * day_)
            local cloudColor = colorLerp(horizon_, Color(0.86, 0.88, 0.90), day_ * 0.65)
            image:SetPixel(pixel.x, pixel.y, colorLerp(base, cloudColor, clouds))
        end
        -- TextureCube API 使用零起始 CubeMapFace（非 Lua 数组索引），face 0 必须先上传。
        if not skyTexture_:SetData(face - 1, image, false) then
            print("[Environment] 天空纹理上传失败；保留已有天空")
            if skybox_ and originalSkyMaterial_ then skybox_:SetMaterial(originalSkyMaterial_) end
            skyTexture_:Dispose()
            skyTexture_ = nil
            return
        end
    end
    skyMaterial_:SetTexture(TU_DIFFUSE, skyTexture_)
    skyMaterial_:SetShaderParameter("MatDiffColor", Variant(Vector4(2.0, 2.0, 2.0, 1.0)))
    skyElapsed_, skyDirty_ = 0.0, false
end

local function createRain()
    if not scene_ or not rainAllowed_ then return end
    local technique = cache:GetResource("Technique", "Techniques/DiffUnlitParticleAdd.xml")
    if not technique then
        print("[Environment] 雨丝Technique不可用：降级天空/雾天气，无近景雨丝")
        return
    end
    local image = Image()
    image:SetSize(4, 32, 4)
    for y = 0, 31 do
        for x = 0, 3 do
            local a = math.sin((y + 0.5) / 32 * math.pi) * math.exp(-((x - 1.5) / 1.5) ^ 2 * 3)
            image:SetPixel(x, y, Color(a, a, a, a))
        end
    end
    rainTexture_ = Texture2D:new()
    if not rainTexture_:SetData(image, true) then
        image:Dispose()
        rainTexture_:Dispose()
        rainTexture_ = nil
        print("[Environment] 雨丝纹理上传失败：降级天空/雾天气")
        return
    end
    image:Dispose()
    rainMaterial_ = Material:new()
    rainMaterial_:SetTechnique(0, technique)
    rainMaterial_:SetTexture(TU_DIFFUSE, rainTexture_)
    rainEffect_ = ParticleEffect:new()
    rainEffect_:SetMaterial(rainMaterial_)
    rainEffect_:SetEmitterType(EMITTER_BOX)
    rainEffect_:SetEmitterSize(Vector3(Config.RainWidth, 1.0, Config.RainWidth))
    rainEffect_:SetRelative(false) -- 已发射粒子保留世界坐标，不粘着相机。
    rainEffect_:SetScaled(false)
    rainEffect_:SetUpdateInvisible(false)
    rainEffect_:SetMinDirection(Vector3(0.06, -1.0, 0.03))
    rainEffect_:SetMaxDirection(Vector3(0.10, -1.0, 0.06))
    rainEffect_:SetMinVelocity(20.0)
    rainEffect_:SetMaxVelocity(24.0)
    rainEffect_:SetMinTimeToLive(0.65)
    rainEffect_:SetMaxTimeToLive(0.85)
    rainEffect_:SetMinParticleSize(Vector2(0.018, 0.30))
    rainEffect_:SetMaxParticleSize(Vector2(0.024, 0.48))
    rainEffect_:SetMinEmissionRate(0.0)
    rainEffect_:SetMaxEmissionRate(0.0)
    rainNode_ = scene_:CreateChild("EnvironmentRain")
    rainEmitter_ = rainNode_:CreateComponent("ParticleEmitter")
    rainEmitter_:SetEffect(rainEffect_)
    rainEmitter_:SetFaceCameraMode(FC_DIRECTION)
    rainEmitter_.castShadows = false
    rainEmitter_:SetEmitting(false)
    rainEmitter_.enabled = false
end

local function applyRain()
    if not rainEmitter_ or not rainEffect_ then return end
    local active = rain_ > 0.003 and not paused_ and not sheltered_ and lastCamera_ ~= nil
    rainEmitter_.enabled = active
    rainEmitter_:SetEmitting(active)
    -- ParticleEmitter 缓存 effect 参数；更新 Effect 后必须 ApplyEffect，而不是只改资源。
    local budget = Config.Quality[quality_.id] or Config.Quality.medium
    -- 数值变化时才重新应用，避免晴天/暂停时反复重绑原生粒子资源。
    local emission = active and budget.emission * rain_ or 0.0
    if math.abs(emission - lastEmission_) > 0.001 then
        rainEffect_:SetMinEmissionRate(emission)
        rainEffect_:SetMaxEmissionRate(emission)
        rainEmitter_:ApplyEffect()
        lastEmission_ = emission
    end
    if rainMaterial_ then
        local level = 0.035 + 0.25 * day_ + 0.06 * golden_
        rainMaterial_:SetShaderParameter("MatDiffColor", Variant(Color(level * 0.70, level * 0.80, level, 1.0)))
    end
end

local function apply()
    calculate()
    if zone_ then
        -- 只碰当前可用属性，不触碰 depthFogDensity/Enable、heightFog 或任何后效。
        zone_.fogColor = horizon_
        zone_.depthFogStart, zone_.depthFogEnd = fogStart_, fogEnd_
        zone_.ambientSource = AMBIENT_COLOR
        -- 无实时阴影的移动端路径降低均匀日光底照，保留材质和树冠明暗；
        -- 夜间端点、月光与投光池强度不变，不靠开启缺失的后效变体压曝光。
        local ambientDay = quality_.ambientMode == "skybox" and Color(0.22, 0.26, 0.31) or Color(0.24, 0.27, 0.30)
        -- 夜间保留可读的冷蓝底光，让站台结构与列车轮廓可见；明暗对比交给站台投光池和车灯。
        local ambient = colorLerp(Color(0.135, 0.160, 0.215), ambientDay, day_)
        local warm = colorLerp(ambient, Color(0.23, 0.15, 0.12), golden_ * 0.35)
        local scale = 1.0 - cloud_ * 0.34
        zone_.ambientColor = Color(warm.r * scale, warm.g * scale, warm.b * scale)
        -- 防止原日间IBL残留在夜晚金属表面；不分配或烘焙任何新IBL纹理。
        zone_.envTextureDiffIntensity = 0.0 -- AMBIENT_COLOR 漫射不读取此值。
        zone_.envTextureSpecIntensity = (0.025 + 0.20 * day_) * (1.0 - cloud_ * 0.50)
    end
    if sun_ then
        local angle = (hour_ - 6.0) / 12.0 * math.pi
        local sunDirection = Vector3(math.cos(angle), elevation_, -0.45 * elevation_ + 0.15):Normalized()
        local moonDirection = (sunDirection * -1.0 + Vector3(0.20, 0.18, 0.15)):Normalized()
        local sunBrightness = quality_.sunBrightness * smoothstep(-0.08, 0.15, elevation_) * sunScale_
        local moonBrightness = 0.30 * night_ * (1.0 - cloud_ * 0.55)
        if sunBrightness >= moonBrightness then
            sun_.node.direction = sunDirection * -1.0
            sun_.color = colorLerp(Color(1.0, 0.53, 0.27), quality_.sunColor, smoothstep(0.02, 0.50, elevation_))
            sun_.brightness = sunBrightness
        else
            sun_.node.direction = moonDirection * -1.0
            sun_.color = Color(0.55, 0.66, 1.0)
            sun_.brightness = moonBrightness
        end
        -- 不修改 castShadows/specularIntensity，原画质兼容策略继续生效。
    end
    if visuals_ then
        NightLighting.SetEnvironment(lamps_, quality_.id)
        NightLighting.Update(lastCamera_, lastFocus_)
    end
    if skyDirty_ or skyElapsed_ >= Config.SkyInterval then applySky() end
    applyRain()
end

--- Release only owned resources; never dispose the caller's Scene/Zone/Light/Sky node.
---@param preserveNightLights? boolean Internal re-init keeps registered stream sites
function Environment.Destroy(preserveNightLights)
    if not preserveNightLights then NightLighting.Shutdown() end
    if skybox_ and originalSkyMaterial_ then skybox_:SetMaterial(originalSkyMaterial_) end
    if rainNode_ then rainNode_:Dispose() end
    if rainEffect_ then rainEffect_:Dispose() end
    if rainMaterial_ then rainMaterial_:Dispose() end
    if rainTexture_ then rainTexture_:Dispose() end
    if skyMaterial_ then skyMaterial_:Dispose() end
    if skyTexture_ then skyTexture_:Dispose() end
    for _, image in ipairs(skyImages_) do image:Dispose() end
    -- realisticTexture_ 来自cache，是借用资源，绝不Dispose。
    realisticTexture_ = nil
    scene_, zone_, sun_, skybox_, originalSkyMaterial_, skyMaterial_, skyTexture_ = nil, nil, nil, nil, nil, nil, nil
    rainNode_, rainEmitter_, rainEffect_, rainMaterial_, rainTexture_, lastCamera_, lastFocus_ = nil, nil, nil, nil, nil, nil, nil
    skyImages_, skyPixels_ = {}, {}
    initialized_ = false
end

---@param scene Scene|nil Required unless options.visuals=false
---@param lighting Node|nil Existing Zone/Light parent; no components are duplicated
---@param options? EnvironmentOptions
---@return boolean
function Environment.Init(scene, lighting, options)
    Environment.Destroy(true)
    options = options or {}
    visuals_, rainAllowed_ = options.visuals ~= false, options.rain ~= false
    if visuals_ and (not scene or not lighting) then
        print("[Environment] Init拒绝：需要已有scene与lighting；状态测试可指定visuals=false")
        return false
    end
    scene_ = scene
    paused_, sheltered_, hour_, running_, overcastSky_ = false, false, Config.DefaultHour, true, false
    dayLength_, weather_ = Config.DayLength, "clear"
    cloud_, rain_, sunScale_, fogScale_, skyElapsed_, skyDirty_, lastEmission_ = 0.0, 0.0, 1.0, 1.0, 0.0, true, -1.0
    if finite(options.hour or options.time) then hour_ = (options.hour or options.time or Config.DefaultHour) % 24.0 end
    minutes_, revision_, visualDirty_ = hour_ * 60.0, 0, false
    if type(options.running) == "boolean" then running_ = options.running
    elseif type(options.timeRunning) == "boolean" then running_ = options.timeRunning end
    if finite(options.dayLength) and options.dayLength >= 60.0 then dayLength_ = options.dayLength end
    if Config.Weather[options.weather or ""] then weather_ = options.weather --[[@as string]] end
    local weather = Config.Weather[weather_]
    cloud_, rain_, sunScale_, fogScale_, fog_ = weather.cloud, weather.rain, weather.sunScale, weather.fogScale, weather.fog
    quality_ = type(options.quality) == "table" and options.quality or VisualQuality.Get(options.quality --[[@as string?]])
    if visuals_ and lighting then
        zone_ = lighting:GetComponent("Zone", true)
        sun_ = lighting:GetComponent("Light", true)
        if not zone_ or not sun_ then
            print("[Environment] Init拒绝：已有lighting必须包含Zone与主光")
            Environment.Destroy()
            return false
        end
        if scene then NightLighting.Attach(scene) end
        local skyNode = options.skyNode or (scene and scene:GetChild("Sky"))
        if skyNode then skybox_ = skyNode:GetComponent("Skybox") end
        createSky()
        createRain()
    end
    initialized_ = true
    Environment.SetQuality(quality_)
    print(string.format("[Environment] Init hour=%.2f weather=%s running=%s quality=%s sky=%s rain=%s",
        hour_, weather_, tostring(running_), quality_.id, tostring(skyTexture_ ~= nil), tostring(rainEmitter_ ~= nil)))
    return true
end

---@param preset VisualQualityPreset|string
function Environment.SetQuality(preset)
    quality_ = type(preset) == "table" and preset or VisualQuality.Get(preset --[[@as string]])
    if rainEffect_ and rainEmitter_ then
        local budget = Config.Quality[quality_.id] or Config.Quality.medium
        rainEffect_:SetNumParticles(budget.particles)
        rainEmitter_:ApplyEffect()
        rainEmitter_:SetNumParticles(budget.particles)
    end
    skyDirty_ = true
    if initialized_ then apply() end
end

---@param hour number Continuous hours; wraps negative values and midnight
---@return boolean
function Environment.SetTime(hour)
    if not finite(hour) then return false end
    local nextHour = hour % 24.0
    if math.abs(nextHour - hour_) > 0.000000001 then
        minutes_ = math.floor(minutes_ / 1440.0) * 1440.0 + nextHour * 60.0
        revision_ = revision_ + 1
    end
    hour_, skyDirty_ = nextHour, true
    if initialized_ then apply() end
    return true
end

---@param running boolean
---@return boolean
function Environment.SetTimeRunning(running)
    if type(running) ~= "boolean" then return false end
    running_ = running
    return true
end

---@param weather string clear/cloudy/rain/fog
---@param immediate? boolean Defaults false: smooth visual transition
---@return boolean
function Environment.SetWeather(weather, immediate)
    local target = Config.Weather[weather]
    if not target then return false end
    weather_ = weather
    if immediate then
        cloud_, rain_, sunScale_, fogScale_, fog_ = target.cloud, target.rain, target.sunScale, target.fogScale, target.fog
        skyDirty_ = true
    end
    if initialized_ then apply() end
    print(string.format("[Environment] 天气目标=%s immediate=%s", weather, tostring(immediate == true)))
    return true
end

--- Atomic UI patch: invalid values do not partially change the clock/weather.
---@param patch EnvironmentPatch
---@return boolean
function Environment.Configure(patch)
    if type(patch) ~= "table" then return false end
    if patch.hour ~= nil and not finite(patch.hour) then return false end
    if patch.running ~= nil and type(patch.running) ~= "boolean" then return false end
    if patch.weather ~= nil and not Config.Weather[patch.weather] then return false end
    if patch.dayLength ~= nil and (not finite(patch.dayLength) or patch.dayLength < 60.0) then return false end
    if patch.hour ~= nil then Environment.SetTime(patch.hour) end
    if patch.running ~= nil then running_ = patch.running end
    if patch.dayLength ~= nil then dayLength_ = patch.dayLength end
    if patch.weather ~= nil then weather_ = patch.weather end
    if initialized_ then apply() end
    return true
end

---@param paused boolean
function Environment.SetPaused(paused)
    paused_ = paused == true
    if initialized_ then applyRain() end
end

--- No particle/roof collision exists here: cab hides near-field streaks rather than raining indoors.
--- Weather/fog/rainIntensity remain active for soundscape and status. Exterior views restore rain.
---@param sheltered boolean
function Environment.SetSheltered(sheltered)
    local changed = sheltered_ ~= (sheltered == true)
    sheltered_ = sheltered == true
    if changed and sheltered_ and rainEmitter_ then rainEmitter_:RemoveAllParticles() end
    if initialized_ then applyRain() end
end

--- 固定模拟步只推进唯一时间/天气状态，不逐步上传天空或重设原生灯光。
---@param dt number
function Environment.Advance(dt)
    if not initialized_ or not finite(dt) or dt <= 0.0 or paused_ then return end
    if running_ then
        minutes_ = minutes_ + dt * (1440.0 / dayLength_)
        hour_ = (minutes_ / 60.0) % 24.0
    end
    local target = Config.Weather[weather_]
    local alpha = 1.0 - math.exp(-dt * 3.0 / Config.TransitionSeconds)
    local changing = math.abs(cloud_ - target.cloud) + math.abs(rain_ - target.rain) + math.abs(fog_ - target.fog)
    cloud_, rain_ = lerp(cloud_, target.cloud, alpha), lerp(rain_, target.rain, alpha)
    sunScale_, fogScale_ = lerp(sunScale_, target.sunScale, alpha), lerp(fogScale_, target.fogScale, alpha)
    fog_ = lerp(fog_, target.fog, alpha)
    if running_ or changing > 0.00001 then skyElapsed_ = skyElapsed_ + dt end
    calculate()
    visualDirty_ = true
end

---@return EnvironmentClock
function Environment.GetClock()
    return {minutes=minutes_, rate=1440.0/dayLength_, running=running_, paused=paused_, revision=revision_}
end

---@param dt number 独立调用仍可推进状态；main固定步Advance后必须传0，避免双计时。
---@param cameraPos? Vector3 真实渲染相机，决定雨跟随与灯的引擎裁剪距离
---@param focusPos? Vector3 当前观察目标；省略时照明退化为相机邻域行为
function Environment.Update(dt, cameraPos, focusPos)
    if not initialized_ then return end
    if focusPos then lastFocus_ = focusPos end
    if cameraPos then
        if lastCamera_ and rainEmitter_ and (cameraPos - lastCamera_).length > Config.RainTeleportDistance then
            rainEmitter_:RemoveAllParticles()
        end
        lastCamera_ = cameraPos
        if rainNode_ then rainNode_.worldPosition = cameraPos + Vector3(-1.0, Config.RainHeight, 0.0) end
    end
    Environment.Advance(dt)
    if visualDirty_ then
        apply()
        visualDirty_ = false
    else
        applyRain()
        if visuals_ then NightLighting.Update(lastCamera_, lastFocus_) end
    end
end

---@return EnvironmentStatus
function Environment.GetStatus()
    local minute = math.floor((hour_ % 1.0) * 60.0)
    return {
        hour = hour_, minute = minute, weather = weather_, weatherLabel = Config.Weather[weather_].label,
        clockText = string.format("%02d:%02d", math.floor(hour_), minute), running = running_, paused = paused_,
        lampFactor = lamps_, lamps = lamps_, headlightFactor = math.max(0.12, lamps_),
        signalFactor = 0.55 + lamps_ * 0.45, rainIntensity = rain_, cloudCover = cloud_, fogIntensity = fog_,
        dayMix = day_, nightMix = night_, sheltered = sheltered_, quality = quality_.id,
        fogStart = fogStart_, fogEnd = fogEnd_, skyReady = skyTexture_ ~= nil, rainReady = rainEmitter_ ~= nil,
    }
end

---@return EnvironmentSnapshot
function Environment.Export()
    return {
        version = 1, hour = hour_, minutes = minutes_, revision = revision_,
        running = running_, weather = weather_, dayLength = dayLength_,
        cloud = cloud_, rain = rain_, sunScale = sunScale_, fogScale = fogScale_, fog = fog_, overcastSky = overcastSky_,
    }
end

--- Accept settings-style {hour,running,weather} as well as full versioned journey snapshots.
--- Unknown/malformed input is rejected atomically; omitted transition fields settle at the target.
---@param saved table|nil
---@return boolean
function Environment.Restore(saved)
    if type(saved) ~= "table" then return false end
    if saved.version ~= nil and saved.version ~= 1 then return false end
    if saved.hour ~= nil and not finite(saved.hour) then return false end
    if saved.minutes ~= nil and (not finite(saved.minutes) or saved.minutes < 0) then return false end
    if saved.revision ~= nil and (not finite(saved.revision) or saved.revision < 0
        or saved.revision ~= math.floor(saved.revision)) then return false end
    if saved.minutes ~= nil and saved.hour ~= nil then
        local difference = math.abs((saved.minutes / 60.0) % 24.0 - saved.hour % 24.0)
        if math.min(difference, 24.0 - difference) > 0.000001 then return false end
    end
    if saved.running ~= nil and type(saved.running) ~= "boolean" then return false end
    if saved.overcastSky ~= nil and type(saved.overcastSky) ~= "boolean" then return false end
    if saved.weather ~= nil and not Config.Weather[saved.weather] then return false end
    if saved.dayLength ~= nil and (not finite(saved.dayLength) or saved.dayLength < 60.0) then return false end
    for _, field in ipairs({ "cloud", "rain", "sunScale", "fogScale", "fog" }) do
        local value = saved[field]
        if value ~= nil and (not finite(value) or value < 0.0 or value > 1.0) then return false end
    end
    local target = Config.Weather[saved.weather or weather_]
    if saved.minutes ~= nil then
        minutes_ = saved.minutes
    elseif saved.hour ~= nil then
        minutes_ = (saved.hour % 24.0) * 60.0
    end
    revision_ = math.floor(saved.revision or 0)
    hour_ = (minutes_ / 60.0) % 24.0
    if saved.running ~= nil then running_ = saved.running end
    weather_, dayLength_ = saved.weather or weather_, saved.dayLength or dayLength_
    cloud_, rain_ = saved.cloud or target.cloud, saved.rain or target.rain
    sunScale_, fogScale_ = saved.sunScale or target.sunScale, saved.fogScale or target.fogScale
    fog_ = saved.fog or target.fog -- v1旧档没有fog字段，按已验证目标补默认，不触碰磁盘。
    if type(saved.overcastSky) == "boolean" then overcastSky_ = saved.overcastSky
    else overcastSky_ = cloud_ >= 0.35 end
    skyDirty_ = true
    if initialized_ then apply() end
    print(string.format("[Environment] Restore hour=%.2f weather=%s cloud=%.3f rain=%.3f running=%s",
        hour_, weather_, cloud_, rain_, tostring(running_)))
    return true
end

return Environment
