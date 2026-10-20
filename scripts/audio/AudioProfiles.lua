-- 六个幻想声音档案。内部车型 ID 固定，玩家名称依次为沧羽/赤峦/苍穹/雷隼/流萤/星澜。
-- 每款独立怠速脉冲、牵引泛音、轮轨/风声色彩与混音；频率不是现实车型录音标识。
-- 音频文件路径与响度由下方 PATHS 统一装配，表内的声学参数供离线合成器使用。
---@class FantasyAudioProfile
---@field id string
---@field name string
---@field powerType string
---@field seed integer
---@field idleHz number
---@field pulseHz number
---@field idleHarmonics number[]
---@field tractionHz number
---@field tractionHarmonics number[]
---@field modulation number
---@field railHz number
---@field railColour number
---@field windColour number
---@field idleGain number
---@field tractionGain number
---@field rollingGain number
---@field windGain number
---@field speedScale number
---@field throttleNotches number
---@field runningPath? string
---@field idlePath? string
---@field hornPath string
---@field brakePath? string
---@field hornGain number
---@field hornNotes number[]
---@field description string

local Profiles = {}
Profiles.Ids = { "blue_white", "DF4D", "SS9G", "HXD3D", "CRH380A", "CR400AF" }

---@type table<string, FantasyAudioProfile>
Profiles.Trains = {
    blue_white = {
        id = "blue_white", name = "沧羽 D12", powerType = "diesel", seed = 1201,
        idleHz = 42, pulseHz = 7, idleHarmonics = { 1, .48, .24, .13 },
        tractionHz = 63, tractionHarmonics = { 1, .58, .28, .17 }, modulation = .20,
        railHz = 3, railColour = .74, windColour = .44,
        idleGain = .34, tractionGain = .49, rollingGain = .36, windGain = .25,
        speedScale = 130, throttleNotches = 8,
        hornNotes = { 196, 294, 392 },
        description = "低沉脉冲机组，圆润牵引泛音，厚实轮轨",
    },
    DF4D = {
        id = "DF4D", name = "赤峦 D18", powerType = "diesel", seed = 1807,
        idleHz = 34, pulseHz = 9, idleHarmonics = { 1, .68, .36, .22, .10 },
        tractionHz = 51, tractionHarmonics = { 1, .71, .44, .20 }, modulation = .32,
        railHz = 4, railColour = .80, windColour = .53,
        idleGain = .39, tractionGain = .55, rollingGain = .40, windGain = .26,
        speedScale = 145, throttleNotches = 8,
        hornNotes = { 164, 246, 328 },
        description = "不对称重脉冲机组，粗粝牵引与密集轮轨节奏",
    },
    SS9G = {
        id = "SS9G", name = "苍穹 E21", powerType = "electric", seed = 2111,
        idleHz = 96, pulseHz = 3, idleHarmonics = { 1, .20, .10 },
        tractionHz = 138, tractionHarmonics = { 1, .32, .18, .07 }, modulation = .17,
        railHz = 3.5, railColour = .67, windColour = .40,
        idleGain = .23, tractionGain = .46, rollingGain = .32, windGain = .27,
        speedScale = 170, throttleNotches = 8,
        hornNotes = { 247, 370, 494 },
        description = "温和辅助电气嗡鸣，清晰阶次牵引和中频滚动",
    },
    HXD3D = {
        id = "HXD3D", name = "雷隼 E32", powerType = "electric", seed = 3217,
        idleHz = 76, pulseHz = 4.5, idleHarmonics = { 1, .29, .15, .06 },
        tractionHz = 184, tractionHarmonics = { 1, .49, .21, .12 }, modulation = .29,
        railHz = 4.5, railColour = .61, windColour = .35,
        idleGain = .26, tractionGain = .51, rollingGain = .37, windGain = .29,
        speedScale = 180, throttleNotches = 8,
        hornNotes = { 220, 330, 440 },
        description = "深辅机底音，带周期相位调制的锐利逆变牵引",
    },
    CRH380A = {
        id = "CRH380A", name = "流萤 M30", powerType = "electric", seed = 3019,
        idleHz = 126, pulseHz = 2, idleHarmonics = { 1, .12, .05 },
        tractionHz = 228, tractionHarmonics = { 1, .23, .09 }, modulation = .13,
        railHz = 5, railColour = .53, windColour = .27,
        idleGain = .18, tractionGain = .37, rollingGain = .27, windGain = .36,
        speedScale = 330, throttleNotches = 8,
        hornNotes = { 330, 495, 660 },
        description = "轻柔通风怠速，通透高频牵引，柔顺滚动与气流",
    },
    CR400AF = {
        id = "CR400AF", name = "星澜 M35", powerType = "electric", seed = 3523,
        idleHz = 114, pulseHz = 2.5, idleHarmonics = { 1, .17, .08 },
        tractionHz = 272, tractionHarmonics = { 1, .19, .13, .04 }, modulation = .21,
        railHz = 5.5, railColour = .48, windColour = .22,
        idleGain = .20, tractionGain = .39, rollingGain = .29, windGain = .39,
        speedScale = 350, throttleNotches = 8,
        hornNotes = { 294, 441, 588 },
        description = "平滑辅机，明亮多阶牵引，细密轮轨与宽频气流",
    },
}

-- 所有播放资源均是生成后经低通、峰值与响度处理的音效。
local PATHS = {
    blue_white = {"rail_d12", .68},
    DF4D = {"rail_d18", .66},
    SS9G = {"rail_e21", .64},
    HXD3D = {"rail_e32", .66},
    CRH380A = {"rail_m30", .70},
    CR400AF = {"rail_m35", .72},
}
for _, id in ipairs(Profiles.Ids) do
    local profile = Profiles.Trains[id]
    local stem, hornGain = table.unpack(PATHS[id])
    local short = string.sub(stem, 6)
    profile.runningPath = "audio/sfx/comfort/" .. stem .. "_running_warm.wav"
    profile.idlePath = "audio/sfx/comfort/" .. stem .. "_idle_warm.wav"
    profile.hornPath = "audio/sfx/comfort/comfort_horn_" .. short .. ".wav"
    profile.brakePath = "audio/sfx/comfort/comfort_brake_" .. short .. ".wav"
    profile.hornGain = hornGain
    profile.description = "生成专属循环 · 独立机组/牵引/轮轨/气流音色"
end
---@type table<string, string>
local aliases = {}
for _, id in ipairs(Profiles.Ids) do
    local profile = Profiles.Trains[id]
    aliases[string.lower(id)] = id
    aliases[profile.name] = id
end

---@param id string
---@return FantasyAudioProfile|nil
function Profiles.Find(id)
    return Profiles.Trains[aliases[string.lower(id)] or id]
end

---@param powerType? string
---@return FantasyAudioProfile
function Profiles.Default(powerType)
    return Profiles.Trains[powerType == "diesel" and "blue_white" or "SS9G"]
end

return Profiles
