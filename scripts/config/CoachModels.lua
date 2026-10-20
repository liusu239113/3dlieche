-- 四款机车客车的独立生成资产接入表；不是涂装表，也不把程序化Model当生成资产。
-- 用户已确认四款外观；原始模型经tools生成、离线校准轮轨/朝向/尺寸后落盘，
-- 并登记到TrainCatalog.Profiles/Assets。source="generated_asset"仅表示来源，
-- 运营验收仍由RollingStock实际元数据/踏面检查决定。

---@class IndependentCoachSpec
---@field locomotiveId string
---@field source string pending_generation|generated_asset
---@field profileId string|nil 对应真实独立客车的RollingStockProfile，不是机车/动车profile
---@field assetId string|nil 生成工具返回的生命周期ID，不从MDL文件名推断
---@field reviewConfirmed boolean 用户已确认此生成主体

local CoachModels = {}

---@type table<string, IndependentCoachSpec>
CoachModels.ByLocomotive = {
    blue_white = {locomotiveId="blue_white",source="generated_asset",profileId="blue_white_coach",
        assetId="f24f03ef03e94627ba410efae414df3e",reviewConfirmed=true},
    DF4D = {locomotiveId="DF4D",source="generated_asset",profileId="DF4D_coach",
        assetId="f0276be35e6648f9bd819305cab10159",reviewConfirmed=true},
    SS9G = {locomotiveId="SS9G",source="generated_asset",profileId="SS9G_coach",
        assetId="3970f65da0f14917b1c97ed296e2cd35",reviewConfirmed=true},
    HXD3D = {locomotiveId="HXD3D",source="generated_asset",profileId="HXD3D_coach",
        assetId="7010b9a50dd5414d96d9aa94d420dec2",reviewConfirmed=true},
}

---@param locomotiveId string
---@return IndependentCoachSpec|nil
function CoachModels.Find(locomotiveId)
    return CoachModels.ByLocomotive[locomotiveId]
end

return CoachModels
