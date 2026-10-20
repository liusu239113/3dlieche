-- 车型化驾驶舱视觉合同：共享真实舱体，按车型统一屏幕、操纵件和灯光语言。
-- 这里不宣称厂家原厂内饰；没有专属内舱资产时，明确使用统一模拟舱 + 车型主题。
local Config = {}

---@class CabVisualProfile
---@field accent Color
---@field screen Color
---@field warning Color
---@field cabinLight Color
---@field metallic number
---@field plastic number
---@field label string
local PROFILES = {
    CR400AF = {accent=Color(.14,.55,.60),screen=Color(.48,.91,.84),warning=Color(1,.52,.22),cabinLight=Color(.80,.91,1),metallic=.62,plastic=.72,label="星澜 CR400AF"},
    CRH380A = {accent=Color(.12,.42,.62),screen=Color(.46,.82,1),warning=Color(1,.48,.20),cabinLight=Color(.82,.92,1),metallic=.66,plastic=.70,label="星澜 CRH380A"},
    HXD3D = {accent=Color(.42,.20,.68),screen=Color(.72,.62,1),warning=Color(1,.40,.24),cabinLight=Color(.88,.84,1),metallic=.68,plastic=.74,label="星澜 HXD3D"},
    SS9G = {accent=Color(.16,.30,.62),screen=Color(.48,.74,1),warning=Color(1,.54,.20),cabinLight=Color(.80,.88,1),metallic=.68,plastic=.74,label="星澜 SS9G"},
    DF4D = {accent=Color(.70,.26,.12),screen=Color(1,.72,.48),warning=Color(1,.35,.20),cabinLight=Color(1,.84,.68),metallic=.58,plastic=.78,label="星澜 DF4D"},
    blue_white = {accent=Color(.16,.44,.56),screen=Color(.50,.88,.86),warning=Color(1,.58,.22),cabinLight=Color(.86,.94,1),metallic=.58,plastic=.76,label="星澜 沧羽"},
}

---@param id string|nil
---@return CabVisualProfile
function Config.Get(id)
    return PROFILES[id or ""] or PROFILES.blue_white
end

---@param id string|nil
---@return string
function Config.Label(id)
    return Config.Get(id).label
end

return Config
