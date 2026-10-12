-- 独立高层住宅实渲验收，复用CabAssetValidation/3D场景脚手架。
-- 测量真实包围盒与四级LOD；统一缩放，不把低层楼拉高。
---@type Scene?
local scene_ = nil
---@type Node?
local cameraNode_ = nil
local frame_,case_,captured_ = 0,1,{}
local BASE="model/4a6814a7-dedd-5062-b1c3-cefdd17665aa/"
local cases_={
    {name="tower_front",eye=Vector3(85,72,-110)},
    {name="tower_back",eye=Vector3(-85,66,110)},
    {name="tower_roof",eye=Vector3(72,130,-85)},
    {name="tower_entrance",eye=Vector3(20,8,-38),aim=Vector3(0,8,0)},
}
local height_=0
local failed_,ready_=false,false

local function setCase(index)
    case_=index
    local case=assert(cases_[index])
    local node=assert(cameraNode_)
    node.position=case.eye
    node:LookAt(case.aim or Vector3(0,height_*.46,0))
end

function Start()
    local ok,message=xpcall(function()
        scene_=Scene()
        scene_:CreateComponent("Octree"):SetSize(BoundingBox(Vector3(-500,-50,-500),Vector3(500,500,500)),8)
        local lighting=scene_:CreateChild("Lighting")
        local zone=lighting:CreateComponent("Zone")
        zone.boundingBox=BoundingBox(Vector3(-500,-50,-500),Vector3(500,500,500))
        zone.ambientSource=AMBIENT_COLOR
        zone.ambientColor=Color(.24,.26,.29)
        zone.fogColor=Color(.60,.67,.72)
        zone.fogStart,zone.fogEnd=350,500
        zone.tonemapMode=TONEMAP_MODE_ACES
        zone.fxaaEnabled=true
        zone.autoExposureEnabled=false
        local sunNode=lighting:CreateChild("Sun")
        sunNode.direction=Vector3(.45,-1,.55)
        local light=sunNode:CreateComponent("Light")
        light.lightType,light.brightness,light.castShadows=LIGHT_DIRECTIONAL,1.15,false
        local model=assert(cache:GetResource("Model",BASE.."Meshes/35a410a32def4781ab882d4bb83e9d57.mdl"))
        local box=model.boundingBox
        local size=box.size
        assert(size.x>.01 and size.y>.01 and size.z>.01,"住宅真实包围盒无效")
        local scale=math.min(85/size.y,32/size.x,36/size.z)
        height_=size.y*scale
        assert(height_>=55,"候选并非符合地块比例的真正高层")
        local triangleCounts={}
        for lod=0,3 do
            local triangles=0
            for slot=0,model.numGeometries-1 do
                assert(model:GetNumGeometryLodLevels(slot)==4,"住宅不具备四级LOD")
                local geometry=assert(model:GetGeometry(slot,lod))
                assert(geometry:GetVertexBuffer(0):HasElement(SEM_NORMAL)
                    and geometry:GetVertexBuffer(0):HasElement(SEM_TEXCOORD),"住宅缺少法线/UV")
                triangles=triangles+geometry.indexCount/3
                print(string.format("[TowerAsset] slot=%d lod=%d indices=%d vertices=%d distance=%.5f",slot,lod,geometry.indexCount,geometry.vertexCount,geometry.lodDistance))
            end
            triangleCounts[lod+1]=triangles
        end
        assert(triangleCounts[4]<triangleCounts[1],"住宅LOD未降低三角数")
        local mat=Material()
        mat:SetTechnique(0,assert(cache:GetResource("Technique","Techniques/PBR/PBRDiffNormal.xml")))
        mat:SetTexture(TU_DIFFUSE,assert(cache:GetResource("Texture2D",BASE.."Textures/35a410a32def4781ab882d4bb83e9d57_00_D.jpg")))
        mat:SetTexture(TU_NORMAL,assert(cache:GetResource("Texture2D",BASE.."Textures/35a410a32def4781ab882d4bb83e9d57_00_N.jpg")))
        mat:SetShaderParameter("Metallic",Variant(.0))
        mat:SetShaderParameter("Roughness",Variant(.85))
        local node=scene_:CreateChild("DetailedResidentialTower")
        node.scale=Vector3.ONE*scale
        node.position=Vector3(-box.center.x*scale,-box.min.y*scale,-box.center.z*scale)
        local drawable=node:CreateComponent("StaticModel")
        drawable.model=model
        drawable:SetMaterial(0,mat)
        drawable.castShadows=false
        print(string.format("[TowerAsset] SOURCE %.5fx%.5fx%.5f SCALE %.5f WORLD %.3fx%.3fx%.3f triangles=%.0f/%.0f/%.0f/%.0f",
            size.x,size.y,size.z,scale,size.x*scale,height_,size.z*scale,table.unpack(triangleCounts)))
        cameraNode_=scene_:CreateChild("Camera")
        local camera=cameraNode_:CreateComponent("Camera")
        camera.nearClip,camera.farClip,camera.fov=.12,500,58
        renderer:SetViewport(0,Viewport(scene_,camera))
        renderer.drawShadows=false
        renderer.hdrRendering=true
        setCase(1)
        SubscribeToEvent("Update","HandleTowerAssetUpdate")
        SubscribeToEvent("EndRendering","HandleTowerAssetCapture")
        ready_=true
    end,debug.traceback)
    if not ok then failed_=true;log:Write(LOG_ERROR,tostring(message));engine:Exit() end
end

---@param eventType string
---@param eventData UpdateEventData
function HandleTowerAssetUpdate(eventType,eventData)
    if not ready_ or failed_ then return end
    frame_=frame_+1
    local index=math.min(#cases_,math.floor((frame_-1)/18)+1)
    if index~=case_ then setCase(index) end
end

---@param eventType string
---@param eventData EndRenderingEventData
function HandleTowerAssetCapture(eventType,eventData)
    if not ready_ or failed_ or frame_%18<14 or captured_[case_] then return end
    local image=Image()
    if not graphics:TakeScreenShot(image) then image:Dispose();return end
    assert(image.width==640 and image.height==360,"高层验收实际分辨率变化")
    assert(image:SavePNG("/workspace/screenshots/"..cases_[case_].name..".png"),"高层实渲截图失败")
    image:Dispose()
    captured_[case_]=true
    print("[TowerAsset] REAL_CAPTURE "..cases_[case_].name)
    if case_==#cases_ then print("ALL_TOWER_ASSET_PASS views=4 uniformScale=true lods=4") end
end

function Stop()
    cameraNode_=nil
    if scene_ then scene_:Dispose();scene_=nil end
end
