-- 狂暴 HUD 仅投影 Traffic 快照，不推进碰撞、连锁或计分。
local UI = require "urhox-libs/UI"
local Skin = require "ui.CabStyle"
local C = Skin.Colors
local Rage = {}

---@class CabRageStats
---@field score? number 累计真实连锁分
---@field impacts? number 去重接触事件数
---@field playerImpacts? number 玩家参与的接触数
---@field npcImpacts? number 纯 NPC 接触数
---@field chains? number 二次传播接触数，不是当前连锁长度
---@field currentChain? number 最近八秒同族命中车节数
---@field maxChain? number 历史最大单族命中车节数
---@field diversity? number 已发生的事件类型数
---@field airborne? number 当前腾空的 NPC 车节数，不是累计次数
---@field lastEvent? string 机器事件名，不直接当中文摘要
---@field eventText? string 最新真实事件摘要

---@type CabRageStats
local stats_ = {}
---@type Label?
local score_ = nil
---@type Label?
local chain_ = nil
---@type Label?
local event_ = nil
---@type Label?
local details_ = nil
local width_ = 300

---@param value any
---@return integer
local function Count(value)
    local n = tonumber(value)
    if not n or n ~= n or n == math.huge or n == -math.huge then return 0 end
    return math.max(0, math.floor(n))
end

---@param target Label?
---@param text string
local function Text(target, text)
    if target and target:GetText() ~= text then target:SetText(text) end
end

--- 使用真实字宽摘要，避免长事件溢出紧凑条；完整原文仍保留在快照中。
---@param value string
---@return string
local function Fit(value)
    local size, face = UI.Theme.FontSize(9), UI.Theme.FontFace("sans", "bold")
    local room = math.max(32, width_ - 22)
    if UI.MeasureTextWidth(value, size, face) <= room then return value end
    local result = ""
    for _, code in utf8.codes(value) do
        local char = utf8.char(code)
        if UI.MeasureTextWidth(result .. char .. "…", size, face) > room then break end
        result = result .. char
    end
    return result .. "…"
end

local function Refresh()
    if not score_ or not UI.GetNVGContext() then return end
    local s = stats_
    Text(score_, Fit("连锁分 " .. Count(s.score) .. " · 当前 " .. Count(s.currentChain)))
    Text(chain_, Fit("最大连锁 " .. Count(s.maxChain) .. " · 事件种类 " .. Count(s.diversity)))
    local event = s.eventText
    Text(event_, Fit(event and event ~= "" and ("事件 · " .. event:gsub("[\r\n]+", " ")) or "事件 · 尚未发生碰撞"))
    Text(details_, string.format("接触 %d · 玩家 %d / NPC %d\n二次传播 %d · 腾空车节 %d\n其他列车正常成列行驶\n玩家撞击才形成连锁",
        Count(s.impacts), Count(s.playerImpacts), Count(s.npcImpacts), Count(s.chains), Count(s.airborne)))
end

---@param stats CabRageStats?
function Rage.SetStats(stats)
    local s = stats or {}
    -- 拷贝值，不保留可变 Traffic 表；缺失字段归零，不在 UI 猜测事件或累加。
    stats_ = { score = Count(s.score), impacts = Count(s.impacts), playerImpacts = Count(s.playerImpacts),
        npcImpacts = Count(s.npcImpacts), chains = Count(s.chains), currentChain = Count(s.currentChain),
        maxChain = Count(s.maxChain), diversity = Count(s.diversity), airborne = Count(s.airborne),
        lastEvent = type(s.lastEvent) == "string" and s.lastEvent or "",
        eventText = type(s.eventText) == "string" and s.eventText or "" }
    Refresh()
end

---@return CabRageStats
function Rage.GetStats()
    local copy = {} ---@type CabRageStats
    for key, value in pairs(stats_) do copy[key] = value end
    return copy
end

function Rage.Reset() Rage.SetStats(nil) end

---@param width number
function Rage.Layout(width)
    if width_ == width then return end
    width_ = width
    Refresh()
end

function Rage.Create()
    local function label(id, text, height, color)
        return UI.Label { id = id, text = text, height = height, minHeight = height,
            fontSize = 9, fontWeight = "bold", fontColor = color, minWidth = 0,
            width = "100%", flexShrink = 0, maxLines = 1, pointerEvents = "none" }
    end
    score_ = label("rageScore", "", 22, C.orange)
    chain_ = label("rageChain", "", 18, C.teal)
    event_ = label("rageEvent", "", 22, C.secondary)
    details_ = UI.Label { id = "rageDetails", text = "", height = 76, minHeight = 76,
        fontSize = 9, fontWeight = "bold", fontColor = C.secondary, whiteSpace = "normal",
        maxLines = 4, lineHeight = 1.1, minWidth = 0, pointerEvents = "none" }
    Refresh()
    return {
        header = UI.Panel { id = "rageHeader", width = "100%", height = 40,
            pointerEvents = "none", children = {
                label("rageRules", "狂暴 · 不限速 / 不侧翻", 18, C.orange), score_,
            } },
        summary = UI.Panel { id = "rageSummary", width = "100%", height = 40,
            pointerEvents = "none", children = { chain_, event_ } },
        details = details_,
    }
end

return Rage
