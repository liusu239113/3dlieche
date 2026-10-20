-- ============================================================================
-- VisualQuality - 三档画质预设（流畅 / 标准 / 极致）
-- 只影响渲染负载与视觉表现，绝不改变线路、动力、AI班次与碰撞界。
-- ============================================================================

local VisualQuality = {}

VisualQuality.Default = "medium"

-- 每档独立描述：天空、环境光、雾、太阳、阴影、视距与密度。
-- 密度字段（vegetationScale / treeDistance / hillAmp）供地形与植被读取。
---@class VisualQualityPreset
---@field id string
---@field label string
---@field sky "realistic"|"gradient"
---@field ambientMode "skybox"|"color"
---@field fogStart number
---@field fogEnd number
---@field fogColor Color
---@field sunBrightness number
---@field sunColor Color
---@field shadowCascadeDistances number
---@field fxaa boolean
---@field shadows boolean
---@field shadowMapSize number
---@field lodBias number
---@field farClip number
---@field vegetationScale number
---@field treeDistance number
---@field terrainRadius number
---@field vegetationRadius number
---@field hillAmp number

---@type table<string, VisualQualityPreset>
-- 说明：Bloom/SSAO/SSR/体积雾/自动曝光等后效在此引擎的移动/GLES 着色器缓存里
-- 缺少对应变体，开启会导致 glLinkProgram 失败、整屏几何消失。因此本表只保留
-- 确定可用的画质开关：天空、雾、太阳、阴影、纹理密度、视距与植被密度。
-- 画面真实度由写实天空 cubemap + 地表纹理 + 混交林 + 长视距雾承担。
-- 实时阴影在本引擎的移动/GLES 渲染路径下不可用（着色器链接与帧读回均失败），
-- 因此三档统一关闭阴影，待真机验证后再按档开启。
-- 日间主光按当前受限合成路径配平，不能照搬带曝光的高亮度预设；
-- 月光与站台/公路投光池由Environment独立控制，不随此值缩暗。
VisualQuality.Presets = {
    low = {
        id = "low", label = "流畅",
        sky = "gradient", ambientMode = "color",
        fogStart = 620.0, fogEnd = 2100.0,
        fogColor = Color(0.63, 0.70, 0.75),
        sunBrightness = 0.85, sunColor = Color(1.0, 0.96, 0.88),
        shadowCascadeDistances = 80.0,
        fxaa = true,
        shadows = false, shadowMapSize = 512, lodBias = 1.0,
        farClip = 2200.0,
        vegetationScale = 0.55, treeDistance = 300.0,
        terrainRadius = 880.0, vegetationRadius = 640.0, hillAmp = 0.55,
    },
    medium = {
        id = "medium", label = "标准",
        sky = "realistic", ambientMode = "skybox",
        fogStart = 950.0, fogEnd = 3000.0,
        fogColor = Color(0.68, 0.75, 0.82),
        sunBrightness = 0.95, sunColor = Color(1.0, 0.955, 0.86),
        shadowCascadeDistances = 320.0,
        fxaa = true,
        shadows = false, shadowMapSize = 1024, lodBias = 1.2,
        farClip = 3400.0,
        vegetationScale = 1.0, treeDistance = 430.0,
        terrainRadius = 1200.0, vegetationRadius = 800.0, hillAmp = 1.0,
    },
    high = {
        id = "high", label = "极致",
        sky = "realistic", ambientMode = "skybox",
        fogStart = 1200.0, fogEnd = 4000.0,
        fogColor = Color(0.72, 0.79, 0.86),
        sunBrightness = 1.05, sunColor = Color(1.0, 0.95, 0.84),
        shadowCascadeDistances = 520.0,
        fxaa = true,
        shadows = false, shadowMapSize = 2048, lodBias = 1.5,
        farClip = 4600.0,
        vegetationScale = 1.7, treeDistance = 680.0,
        terrainRadius = 1520.0, vegetationRadius = 1120.0, hillAmp = 1.35,
    },
}

---@param id string
---@return boolean
function VisualQuality.IsValid(id)
    return VisualQuality.Presets[id] ~= nil
end

---@param id string|nil
---@return VisualQualityPreset
function VisualQuality.Get(id)
    return VisualQuality.Presets[id or ""] or VisualQuality.Presets[VisualQuality.Default]
end

-- 旧存档里的 "performance"/"detailed" 映射到新三档。
-- 旧 performance 升级到"标准"而不是"流畅"：老玩家下次进入即可看到画质提升，
-- 想要更省电可自行切到"流畅"。
---@param id string|nil
---@return string
function VisualQuality.Normalize(id)
    if VisualQuality.IsValid(id) then return id --[[@as string]] end
    if id == "performance" then return "medium" end
    if id == "detailed" then return "high" end
    return VisualQuality.Default
end

-- 菜单里循环切换：流畅 -> 标准 -> 极致 -> 流畅
---@param id string
---@return string
function VisualQuality.Next(id)
    ---@type string[]
    local order = { "low", "medium", "high" }
    local current = VisualQuality.Normalize(id)
    for index, value in ipairs(order) do
        if value == current then
            return order[index % #order + 1] or VisualQuality.Default
        end
    end
    return VisualQuality.Default
end

---@param id string
---@return string
function VisualQuality.Label(id)
    return VisualQuality.Get(id).label
end

return VisualQuality
