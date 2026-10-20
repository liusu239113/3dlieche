-- 天空资源加载探针：验证官方写实 cubemap 能否被引擎读成 TextureCube 并贴到 Skybox。
local scene_ = nil

local function tryCube(path)
    local ok, tex = pcall(function() return cache:GetResource("TextureCube", path) end)
    if ok and tex then
        print(string.format("[SkyProbe] TextureCube %-46s -> OK  %dx%d", path, tex.width, tex.height))
        return tex
    end
    print(string.format("[SkyProbe] TextureCube %-46s -> MISS %s", path, tostring(tex)))
    return nil
end

function Start()
    scene_ = Scene()
    scene_:CreateComponent("Octree")
    print("[SkyProbe] ===== 候选 cubemap =====")
    local tex = tryCube("Textures/Sky/RealisticSky26.ktx")
    tryCube("Textures/Sky/RealisticSky03.ktx")
    tryCube("Textures/Skybox.xml")

    if tex then
        local mat = Material:new()
        local tech = cache:GetResource("Technique", "Techniques/DiffSkybox.xml")
        print("[SkyProbe] DiffSkybox technique = " .. tostring(tech ~= nil))
        if tech then
            mat:SetTechnique(0, tech)
            mat:SetTexture(TU_DIFFUSE, tex)
            local node = scene_:CreateChild("Sky")
            local box = cache:GetResource("Model", "Models/Box.mdl")
            print("[SkyProbe] Box.mdl = " .. tostring(box ~= nil))
            if box then
                local sky = node:CreateComponent("Skybox")
                sky:SetModel(box)
                sky:SetMaterial(mat)
                print("[SkyProbe] Skybox 组件已挂载，材质已绑定")
            end
        end
    end

    -- 渲染一帧确认无崩溃
    local cameraNode = scene_:CreateChild("Cam")
    cameraNode.position = Vector3(0, 0, 0)
    local camera = cameraNode:CreateComponent("Camera")
    renderer:SetViewport(0, Viewport:new(scene_, camera))
    print("[SkyProbe] DONE")
end
