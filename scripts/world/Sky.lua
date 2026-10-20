-- ============================================================================
-- Sky - 天空与大气
-- 优先使用官方写实 cubemap（自带真实云层），不可用时回退程序化渐变。
-- 天空盒在 postopaque pass 渲染、不参与雾，与 Zone 的雾彻底解耦。
-- ============================================================================
local SkyUtils = require "urhox-libs.Rendering.SkyUtils"
local Sky = {}

-- 官方写实天空：2048² 六面 KTX，ASTC 压缩，含真实积云与地平线霞光。
local REALISTIC_CANDIDATES = {
    "Textures/Sky/RealisticSky26.ktx",
    "Textures/Sky/RealisticSky03.ktx",
}
---@type string|nil
local activeRealistic_ = nil
---@type boolean
local realisticProbed_ = false

---@return string|nil
function Sky.FindRealistic()
    if realisticProbed_ then return activeRealistic_ end
    realisticProbed_ = true
    for _, path in ipairs(REALISTIC_CANDIDATES) do
        local texture = cache:GetResource("TextureCube", path)
        if texture then
            activeRealistic_ = path
            print(string.format("[Sky] 写实天空可用：%s %dx%d（六面真实云层）", path, texture.width, texture.height))
            return activeRealistic_
        end
    end
    print("[Sky] 警告：官方写实天空不可用，回退程序化渐变")
    return nil
end

---@param scene Scene
---@param preset VisualQualityPreset
---@return Node
function Sky.Create(scene, preset)
    local node = scene:CreateChild("Sky")
    local skybox = node:CreateComponent("Skybox")
    local model = cache:GetResource("Model", "Models/Box.mdl")
    local technique = cache:GetResource("Technique", "Techniques/DiffSkybox.xml")
    if model then skybox:SetModel(model) end
    if not technique then return node end

    local material = Material:new()
    material:SetTechnique(0, technique)

    local realistic = preset.sky == "realistic" and Sky.FindRealistic() or nil
    if realistic then
        local texture = cache:GetResource("TextureCube", realistic)
        material:SetTexture(TU_DIFFUSE, texture)
        -- 官方 cubemap 已是 HDR 量级，只需轻微提升即可匹配 ACES 曝光。
        material:SetShaderParameter("MatDiffColor", Variant(Vector4(1.15, 1.15, 1.15, 1.0)))
        node:SetVar("SkyRealistic", true)
    else
        -- 程序化渐变回退：LDR 值需 2x 补偿 ACES 色调映射。
        local cubemap = SkyUtils.MakeGradientCubemap({
            zenith = Color(0.19, 0.42, 0.78),
            horizon = preset.fogColor,
            ground = Color(0.30, 0.35, 0.28),
            skyExp = 0.55,
        })
        material:SetTexture(TU_DIFFUSE, cubemap)
        material:SetShaderParameter("MatDiffColor", Variant(Vector4(2.0, 2.0, 2.0, 1.0)))
        node:SetVar("SkyRealistic", false)
    end

    skybox:SetMaterial(material)
    return node
end

-- 供环境光烘焙：把天空盒纹理作为 IBL 来源。
---@return string|nil
function Sky.GetRealisticPath()
    return Sky.FindRealistic()
end

return Sky
