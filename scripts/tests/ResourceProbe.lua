-- 资源可用性探针：一次性列出天空/光照/纹理候选资源是否真能加载。
local function try(kind, path)
    local ok, res = pcall(function() return cache:GetResource(kind, path) end)
    print(string.format("[ResourceProbe] %-11s %-58s -> %s", kind, path,
        (ok and res) and "OK" or ("MISS(" .. tostring(res) .. ")")))
    return ok and res ~= nil
end

-- 启动回归必须实际执行模块，不能只凭源码文件存在或构建成功判定通过。
local function validateStartupModules()
    local modules = {
        { name = "world.Vegetation", path = "world/Vegetation.lua", exports = { "GetAsset", "NewBatch", "GetResourcePaths" } },
        { name = "world.Terrain", path = "world/Terrain.lua", exports = { "Init", "Build" } },
        { name = "world.WorldStream", path = "world/WorldStream.lua", exports = { "Build", "Shutdown" } },
    }
    for _, entry in ipairs(modules) do
        assert(cache:Exists(entry.path), "[StartupValidation] 启动脚本未就绪：" .. entry.path)
        local module = require(entry.name)
        for _, name in ipairs(entry.exports) do
            assert(type(module[name]) == "function", "[StartupValidation] 缺少接口：" .. entry.name .. "." .. name)
        end
        print("[StartupValidation] 模块执行及接口检查通过：" .. entry.name)
    end
    print("STARTUP_MODULE_CHAIN_PASS modules=3")
end

function Start()
    local startupOk, startupError = xpcall(validateStartupModules, debug.traceback)
    if not startupOk then
        log:Write(LOG_ERROR, tostring(startupError))
        engine:Exit()
        return
    end
    for _, argument in ipairs(GetArguments()) do
        if argument == "-startup-only" then engine:Exit(); return end
    end
    print("[ResourceProbe] ===== 天空 cubemap =====")
    for _, p in ipairs({
        "Environment/Skybox/Realistic_Sky_03.xml",
        "Environment/Skybox/Realistic_Sky_10.xml",
        "Environment/Skybox/Realistic_Sky_23.xml",
        "Environment/Skybox/Realistic_Sky_26.xml",
        "Environment/Skybox/Cartoon_Sky_01.xml",
        "Textures/Skybox.xml",
    }) do try("TextureCube", p) end
    for _, u in ipairs({
        "uuid://E4ehad-5axjv7Ml9zasxNx06",
        "uuid://E_LhMeSIwE-bKC9lR3h2XYq1",
        "uuid://ENC1IXaQqFYisE64aHW9CwX0",
        "uuid://GNxJASZSCM8_0Qv-m3hrFG9c",
    }) do try("TextureCube", u) end

    print("[ResourceProbe] ===== LightGroup =====")
    for _, p in ipairs({
        "LightGroup/Daytime.xml", "LightGroup/Day.xml", "LightGroup/Dusk.xml",
        "LightGroup/Night.xml", "LightGroup/DefaultZone.xml",
    }) do try("XMLFile", p) end

    print("[ResourceProbe] ===== Technique =====")
    for _, p in ipairs({
        "Techniques/DiffSkybox.xml",
        "Techniques/PBR/PBRDiff.xml",
        "Techniques/PBR/PBRDiffNormal.xml",
        "Techniques/PBR/PBRMetallicRoughDiffNormalSpec.xml",
        "Techniques/PBR/PBRNoTexture.xml",
    }) do try("Technique", p) end

    print("[ResourceProbe] ===== 官方地表纹理候选 =====")
    for _, u in ipairs({
        "uuid://D9QkffXjJ2ZNpGOZu483iNoO",
    }) do try("Texture2D", u) end
    for _, p in ipairs({
        "Textures/Railway/grass.png", "Textures/Railway/ballast.png",
    }) do try("Texture2D", p) end

    print("[ResourceProbe] ===== 官方植被模型 =====")
    for _, p in ipairs({
        "RailwayVegetation/Environment/Vegetation/Trees/Tree02/Meshes/Tree02.mdl",
        "RailwayVegetation/Environment/Vegetation/Trees/Tree21/Meshes/Tree21.mdl",
    }) do try("Model", p) end

    print("[ResourceProbe] DONE")
end
