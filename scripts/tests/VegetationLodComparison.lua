-- 受控树冠诊断，不冒充正式main截图：7官方树同高同距，后排固定LOD2、前排固定LOD0。
-- 基于3D scene scaffold；借原VB/IB，原Technique与alpha材质，无新shader变体。
-- 仅主代理可用唯一GLES运行。CPU模式不作画面通过结论。
local Vegetation=require "world.Vegetation"
---@type Scene?
local scene_=nil
local frames_=0
local function fixedLod(asset,lod)
    local model=Model()
    model:SetNumGeometries(asset.model.numGeometries)
    local triangles=0
    for slot=0,asset.model.numGeometries-1 do
        local source=asset.model:GetGeometry(slot,math.min(lod,asset.model:GetNumGeometryLodLevels(slot)-1))
        local geometry=Geometry()
        geometry:SetVertexBuffer(0,source:GetVertexBuffer(0));geometry:SetIndexBuffer(source:GetIndexBuffer())
        geometry:SetDrawRange(source.primitiveType,source.indexStart,source.indexCount,source.vertexStart,source.vertexCount)
        model:SetGeometry(slot,0,geometry)
        model:SetGeometryCenter(slot,asset.model:GetGeometryCenter(slot))
        triangles=triangles+source.indexCount/3
    end
    model.boundingBox=asset.bounds
    return model,triangles
end
function Start()
    scene_=Scene();scene_:CreateComponent("Octree")
    local zone=scene_:CreateChild("Zone"):CreateComponent("Zone")
    zone.boundingBox=BoundingBox(-1000,1000)
    zone.ambientSource=AMBIENT_COLOR;zone.ambientColor=Color(.42,.46,.52)
    zone.fogColor=Color(.66,.76,.86);zone.depthFogStart=500;zone.depthFogEnd=1000
    zone.tonemapMode=TONEMAP_MODE_ACES;zone.autoExposureEnabled=false;zone.vignetteEnabled=false
    zone.bloomWeight=0;zone.ssaoIntensity=0;zone.ssrEnabled=false;zone.ssgiEnabled=false
    zone.volumetricFogEnabled=false;zone.motionBlurEnabled=false;zone.fxaaEnabled=false
    renderer.materialQuality=QUALITY_MEDIUM;renderer.drawShadows=false;renderer.specularLighting=false
    local lightNode=scene_:CreateChild("Sun");lightNode.direction=Vector3(.3,-1,.5)
    local light=lightNode:CreateComponent("Light");light.lightType=LIGHT_DIRECTIONAL
    light.color=Color(1,.95,.86);light.brightness=1.8;light.castShadows=false
    local ground=scene_:CreateChild("Ground");ground.scale=Vector3(150,1,75)
    local groundModel=ground:CreateComponent("StaticModel")
    groundModel.model=cache:GetResource("Model","Models/Plane.mdl")
    local material=Material()
    material:SetTechnique(0,cache:GetResource("Technique","Techniques/PBR/PBRNoTexture.xml"))
    material:SetShaderParameter("MatDiffColor",Variant(Color(.36,.39,.28)))
    groundModel.material=material
    for index,kind in ipairs(Vegetation.TreeKinds) do
        local asset=assert(Vegetation.GetAsset(kind))
        for row,lod in ipairs({0,2}) do
            local model,triangles=fixedLod(asset,lod)
            local wrapper={name=kind.."_LOD"..lod,model=model,materials=asset.materials,bounds=asset.bounds,
                drawDistance=1000,shadowDistance=0,shadows=false}
            local batch=Vegetation.NewBatch(scene_:CreateChild(wrapper.name))
            local scale=Vegetation.Measure(asset,9)
            batch:Add(wrapper,Vector3((index-4)*17,0,(row-1)*24),scale,0)
            print(string.format("VEGETATION_LOD_COMPARE column=%d kind=%s row=%d lod=%d triangles=%.0f",index,kind,row,lod,triangles))
        end
    end
    local cameraNode=scene_:CreateChild("Camera")
    cameraNode.position=Vector3(0,40,-100);cameraNode:LookAt(Vector3(0,5,14))
    local camera=cameraNode:CreateComponent("Camera");camera.orthographic=true;camera.orthoSize=81
    camera.farClip=500;camera.viewMask=0xffffffff
    renderer.hdrRendering=true
    renderer:SetViewport(0,Viewport:new(scene_,camera))
    graphics.windowTitle="Vegetation columns A B C D E F G; front LOD0, back LOD2"
    SubscribeToEvent("EndFrame","HandleVegetationLodCapture")
end
function HandleVegetationLodCapture()
    frames_=frames_+1
    if frames_<16 then return end
    local image=Image()
    local ok=graphics:TakeScreenShot(image)
    if ok then
        assert(image:SavePNG("/workspace/screenshots/vegetation_7species_lod0_vs_lod2.png"))
        print("VEGETATION_LOD_COMPARE_CAPTURE front=LOD0 back=LOD2 columns=treeA..treeG visualReviewRequired=true")
    else print("VEGETATION_LOD_COMPARE_NO_FRAME CPU_is_not_visual_validation=true") end
    image:Dispose()
    engine:Exit()
end
function Stop() if scene_ then scene_:Dispose();scene_=nil end end
