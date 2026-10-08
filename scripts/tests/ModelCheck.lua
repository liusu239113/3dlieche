-- 只读诊断：分别渲染复兴号头车与中间车的烘焙模型，检查中间车是否带鼻子。
local Catalog = require "config.TrainCatalog"

local scene_ = nil
local items_ = {}
local frame_ = 0

local function build(id, x)
    local asset = assert(Catalog.Assets[id], "缺资源 " .. id)
    local node = scene_:CreateChild("Item_" .. id)
    node.position = Vector3(x, 0, 0)
    local model = assert(cache:GetResource("Model", asset.modelPath), "载入失败 " .. id)
    local sm = node:CreateComponent("StaticModel")
    sm:SetModel(model)
    local mat = Material:new()
    mat:SetTechnique(0, cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml"))
    mat:SetShaderParameter("MatDiffColor", Variant(Color(0.8, 0.8, 0.85, 1)))
    sm:SetMaterial(mat)
    local box = model.boundingBox
    print(string.format("[ModelCheck] %s size=%.2fx%.2fx%.2f minZ=%.2f maxZ=%.2f",
        id, box.size.x, box.size.y, box.size.z, box.min.z, box.max.z))
    return node, box
end

function Start()
    scene_ = Scene()
    scene_:CreateComponent("Octree")
    local zoneNode = scene_:CreateChild("Zone")
    zoneNode:CreateComponent("Zone")
    local lightNode = scene_:CreateChild("Sun")
    lightNode.direction = Vector3(0.4, -1, 0.5)
    local light = lightNode:CreateComponent("Light")
    light.lightType = LIGHT_DIRECTIONAL

    build("CR400AF_head", -16)
    build("CR400AF_middle", 16)
    build("CRH380A_head", -16)
    build("CRH380A_middle", 16)

    local camNode = scene_:CreateChild("Cam")
    camNode.position = Vector3(0, 24, -70)
    camNode:LookAt(Vector3(0, 2, 0))
    local cam = camNode:CreateComponent("Camera")
    cam.farClip = 500
    renderer:SetViewport(0, Viewport:new(scene_, cam))
    SubscribeToEvent("EndRendering", "HandleCapture")
end

function HandleCapture()
    frame_ = frame_ + 1
    if frame_ ~= 20 then return end
    local image = Image()
    if graphics:TakeScreenShot(image) then
        image:SavePNG("/workspace/screenshots/model_check.png")
        image:Dispose()
    end
end
