-- 独立美术资产实渲检查，基于 scaffold-3d-scene 的场景/光照/相机生命周期。
-- 只检查真实 MDL；不绘制替代模型，不把资源预览当运行画面。
---@type Scene?
local scene_ = nil
---@type Node?
local cameraNode_ = nil
local frame_, case_, captured_ = 0, 1, {}
local cases_ = {
    {name="cab_asset_front",eye=Vector3(0,2,-6),aim=Vector3(0,1.2,0)},
    {name="cab_asset_back",eye=Vector3(0,2,6),aim=Vector3(0,1.2,0)},
    {name="cab_asset_left",eye=Vector3(-6,2,0),aim=Vector3(0,1.2,0)},
    {name="cab_asset_right",eye=Vector3(6,2,0),aim=Vector3(0,1.2,0)},
    {name="cab_asset_inside_front",eye=Vector3(-.45,1.5,-1.25),aim=Vector3(0,1.2,1.4)},
    {name="cab_asset_inside_back",eye=Vector3(-.45,1.5,1.25),aim=Vector3(0,1.2,-1.4)},
}
local BASE="model/ce4bf974f7cf4f0fb34b735ae52cfc1c/"

local function setCase(index)
    case_=index
    local c=assert(cases_[index])
    local camera=assert(cameraNode_)
    camera.position=c.eye
    camera:LookAt(c.aim)
end

function Start()
    local ok,message=xpcall(function()
        scene_=Scene()
        scene_:CreateComponent("Octree")
        local lighting=scene_:CreateChild("LightGroup")
        lighting:LoadXML(assert(cache:GetResource("XMLFile","LightGroup/Daytime.xml")):GetRoot())
        local zone=assert(lighting:GetComponent("Zone",true))
        zone.fogStart,zone.fogEnd=100,200
        local node=scene_:CreateChild("GeneratedCabAsset")
        local model=assert(cache:GetResource("Model",BASE.."Meshes/ce4bf974f7cf4f0fb34b735ae52cfc1c.mdl"))
        local box=model.boundingBox
        local size=box.size
        local center=box.center
        local scale=Vector3(2.7/size.x,2.3/size.y,3.6/size.z)
        node.scale=scale
        node.position=Vector3(-center.x*scale.x,1.15-center.y*scale.y,-center.z*scale.z)
        local object=node:CreateComponent("StaticModel")
        object.model=model
        local mat=Material()
        mat:SetTechnique(0,assert(cache:GetResource("Technique","Techniques/PBR/PBRDiffNormal.xml")))
        mat:SetTexture(TU_DIFFUSE,assert(cache:GetResource("Texture2D",BASE.."Textures/ce4bf974f7cf4f0fb34b735ae52cfc1c_00_D.jpg")))
        mat:SetTexture(TU_NORMAL,assert(cache:GetResource("Texture2D",BASE.."Textures/ce4bf974f7cf4f0fb34b735ae52cfc1c_00_N.png")))
        mat:SetShaderParameter("Metallic",Variant(.05))
        mat:SetShaderParameter("Roughness",Variant(.7))
        object.material=mat
        object.castShadows=false
        local lightNode=scene_:CreateChild("InsideLight")
        lightNode.position=Vector3(0,1.9,0)
        local light=lightNode:CreateComponent("Light")
        light.lightType,light.range,light.brightness=LIGHT_POINT,5,3
        print(string.format("[CabAsset] bbox size=%.4f/%.4f/%.4f center=%.4f/%.4f/%.4f geometries=%d",size.x,size.y,size.z,center.x,center.y,center.z,model.numGeometries))
        cameraNode_=scene_:CreateChild("Camera")
        local camera=cameraNode_:CreateComponent("Camera")
        camera.nearClip,camera.farClip,camera.fov=.035,100,65
        renderer:SetViewport(0,Viewport(scene_,camera))
        renderer.hdrRendering=true
        setCase(1)
        SubscribeToEvent("Update","HandleCabAssetUpdate")
        SubscribeToEvent("EndRendering","HandleCabAssetCapture")
    end,debug.traceback)
    if not ok then log:Write(LOG_ERROR,tostring(message));engine:Exit() end
end

---@param eventType string
---@param eventData UpdateEventData
function HandleCabAssetUpdate(eventType,eventData)
    frame_=frame_+1
    local index=math.min(#cases_,math.floor((frame_-1)/12)+1)
    if index~=case_ then setCase(index) end
end

---@param eventType string
---@param eventData EndRenderingEventData
function HandleCabAssetCapture(eventType,eventData)
    if frame_%12<9 or captured_[case_] then return end
    local image=Image()
    if not graphics:TakeScreenShot(image) then image:Dispose();return end
    local path="/workspace/screenshots/"..cases_[case_].name..".png"
    assert(image:SavePNG(path),"真实资产截图失败")
    image:Dispose()
    captured_[case_]=true
    print("[CabAsset] REAL_CAPTURE "..path)
    if case_==#cases_ then print("ALL_CAB_ASSET_VIEWS_PASS");engine:Exit() end
end

function Stop()
    cameraNode_=nil
    if scene_ then scene_:Dispose();scene_=nil end
end
