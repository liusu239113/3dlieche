-- ============================================================================
-- Materials - 材质工厂
-- 程序化材质只用 PBRNoTexture 系列；纹理材质走引擎预制 uuid
-- ============================================================================

local Materials = {}

local _solidCache = {}
local _uuidCache = {}

-- ---------------------------------------------------------------------------
-- 纯色 PBR 材质（带缓存，同色只建一份）
-- ---------------------------------------------------------------------------
---@param color Color
---@param metallic number
---@param roughness number
---@param emissive Color|nil
---@return Material
function Materials.Solid(color, metallic, roughness, emissive)
    metallic = metallic or 0.0
    roughness = roughness or 0.7
    local key = string.format("%.3f_%.3f_%.3f_%.3f_%.2f_%.2f",
        color.r, color.g, color.b, color.a, metallic, roughness)
    if emissive then
        key = key .. string.format("_%.2f_%.2f_%.2f", emissive.r, emissive.g, emissive.b)
    end

    local cached = _solidCache[key]
    if cached then return cached end

    local mat = Material:new()
    mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
    mat:SetShaderParameter("MatDiffColor", Variant(color))
    mat:SetShaderParameter("MatSpecColor", Variant(Color(0.5, 0.5, 0.5, 1.0)))
    mat:SetShaderParameter("Metallic", Variant(metallic))
    mat:SetShaderParameter("Roughness", Variant(roughness))
    if emissive then
        mat:SetShaderParameter("MatEmissiveColor", Variant(emissive))
    end
    _solidCache[key] = mat
    return mat
end

-- ---------------------------------------------------------------------------
-- 自发光材质（信号灯、车灯、招牌）
-- ---------------------------------------------------------------------------
---@param color Color
---@param strength number
---@return Material
function Materials.Glow(color, strength)
    strength = strength or 1.0
    local e = Color(color.r * strength, color.g * strength, color.b * strength)
    return Materials.Solid(color, 0.0, 0.4, e)
end

-- ---------------------------------------------------------------------------
-- 透明材质（玻璃）
-- ---------------------------------------------------------------------------
---@param color Color
---@return Material
function Materials.Glass(color)
    local key = string.format("glass_%.2f_%.2f_%.2f_%.2f", color.r, color.g, color.b, color.a)
    local cached = _solidCache[key]
    if cached then return cached end

    local mat = Material:new()
    mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTextureAlpha.xml"))
    mat:SetShaderParameter("MatDiffColor", Variant(color))
    mat:SetShaderParameter("Metallic", Variant(0.2))
    mat:SetShaderParameter("Roughness", Variant(0.08))
    _solidCache[key] = mat
    return mat
end

-- ---------------------------------------------------------------------------
-- 预制纹理材质（uuid），失败时回退到纯色
-- ---------------------------------------------------------------------------
---@param uuid string
---@param fallbackColor Color
---@return Material
function Materials.Prefab(uuid, fallbackColor)
    local cached = _uuidCache[uuid]
    if cached then return cached end

    local mat = cache:GetResource("Material", uuid)
    if not mat then
        print("[Materials] WARN: 预制材质加载失败, 回退纯色 -> " .. uuid)
        mat = Materials.Solid(fallbackColor, 0.0, 0.8)
    end
    _uuidCache[uuid] = mat
    return mat
end

return Materials
