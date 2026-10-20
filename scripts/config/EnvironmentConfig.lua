-- ============================================================================
-- EnvironmentConfig - 低成本昼夜/天气参数；不启用额外 shader 或桌面后效。
-- 所有距离单位为米，dayLength 单位为现实秒。画质只控制预算，不改天气状态。
-- ============================================================================
local Config = {}

Config.DefaultHour = 12.0
Config.DayLength = 3600.0
Config.TransitionSeconds = 8.0
Config.SkySize = 32 -- 6 * 32² texels，阴雨/低档回退；晴昼中高保留2048²照片。
Config.SkyInterval = 0.5
-- 独立近雾视距，不套阴雨 fogScale；80m内保留道旁信号的完整对比度。
Config.FogStart = 80.0
Config.FogEnd = 700.0

---@class EnvironmentWeatherPreset
---@field label string
---@field cloud number
---@field rain number
---@field sunScale number
---@field fogScale number
---@field fog number Independent near-fog blend [0,1]
---@type table<string, EnvironmentWeatherPreset>
Config.Weather = {
    clear = { label = "晴", cloud = 0.0, rain = 0.0, sunScale = 1.0, fogScale = 1.0, fog = 0.0 },
    cloudy = { label = "阴", cloud = 0.68, rain = 0.0, sunScale = 0.58, fogScale = 0.78, fog = 0.0 },
    rain = { label = "雨", cloud = 1.0, rain = 1.0, sunScale = 0.30, fogScale = 0.52, fog = 0.0 },
    fog = { label = "雾", cloud = 0.90, rain = 0.0, sunScale = 0.42, fogScale = 1.0, fog = 1.0 },
}

---@class EnvironmentQualityBudget
---@field particles integer
---@field emission number
---@type table<string, EnvironmentQualityBudget>
Config.Quality = {
    low = { particles = 180, emission = 170.0 },
    medium = { particles = 360, emission = 340.0 },
    high = { particles = 560, emission = 520.0 },
}

Config.RainHeight = 10.0
Config.RainWidth = 36.0
Config.RainTeleportDistance = 24.0

return Config
