-- 星澜群域客车涂装：四款机车各牵引一支独立视觉的云舟 C24 客车队。
-- 只声明颜色与名称，不创建引擎对象、不读写文件；Coach 与 Train 共用此纯数据表。
-- 颜色为线性 RGB 乘色（用于 MatDiffColor），车辆几何仍共用已验收的 24 米车体。

---@class CoachLivery
---@field id string 与机车内部 ID 一致的稳定键，仅用于加载与存档
---@field name string 玩家可见的客车队名称
---@field code string 架空车号前缀
---@field body number[] 上部车体主色
---@field skirt number[] 下部裙板/腰带色
---@field stripe number[] 腰线与顶部特征条色
---@field roof number[] 车顶金属色
---@field door number[] 车门色
---@field accent number[] 车头端与扶手点缀色

local CoachLiveries = {}

-- 与 FictionalWorld.trainNames 一一对应；每支车队颜色明显可分，不靠微调同一蓝色。
---@type table<string, CoachLivery>
CoachLiveries.ByLocomotive = {
    blue_white = {
        id = "blue_white", name = "云舟 C24 · 沧羽编队", code = "C24",
        body = { .86, .89, .85 }, skirt = { .10, .36, .40 }, stripe = { .95, .72, .30 },
        roof = { .72, .75, .76 }, door = { .12, .30, .36 }, accent = { .93, .78, .42 },
    },
    DF4D = {
        id = "DF4D", name = "云舟 C24 · 赤峦编队", code = "C24",
        body = { .84, .79, .70 }, skirt = { .40, .16, .10 }, stripe = { .88, .60, .20 },
        roof = { .70, .66, .60 }, door = { .34, .14, .09 }, accent = { .90, .64, .26 },
    },
    SS9G = {
        id = "SS9G", name = "云舟 C24 · 苍穹编队", code = "C24",
        body = { .80, .84, .89 }, skirt = { .12, .22, .44 }, stripe = { .78, .82, .88 },
        roof = { .68, .72, .78 }, door = { .14, .24, .46 }, accent = { .82, .86, .92 },
    },
    HXD3D = {
        id = "HXD3D", name = "云舟 C24 · 雷隼编队", code = "C24",
        body = { .80, .78, .86 }, skirt = { .30, .18, .46 }, stripe = { .58, .80, .86 },
        roof = { .70, .70, .76 }, door = { .26, .16, .42 }, accent = { .64, .84, .90 },
    },
    CRH380A = {
        id = "CRH380A", name = "流萤 M30 · 群域快运", code = "M30",
        body = { .90, .93, .91 }, skirt = { .10, .42, .36 }, stripe = { .35, .72, .58 },
        roof = { .74, .77, .76 }, door = { .12, .36, .32 }, accent = { .46, .78, .62 },
    },
    CR400AF = {
        id = "CR400AF", name = "星澜 M35 · 群域旗舰", code = "M35",
        body = { .88, .90, .94 }, skirt = { .22, .20, .48 }, stripe = { .62, .52, .88 },
        roof = { .73, .75, .80 }, door = { .20, .18, .44 }, accent = { .70, .58, .92 },
    },
}

CoachLiveries.Fallback = "blue_white"

---@param id string|nil
---@return CoachLivery
function CoachLiveries.Get(id)
    local livery = id and CoachLiveries.ByLocomotive[id]
    if livery then return livery end
    return assert(CoachLiveries.ByLocomotive[CoachLiveries.Fallback])
end

return CoachLiveries
