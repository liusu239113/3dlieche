-- 基于TowerAssetValidation与3D场景脚手架的真实LOD诊断。
-- 使用完整成品车体和原涂装；不改共享Model、玩家相机或生产画质。
-- 单车隔离测试只验证实际提交的LOD三角数，不冒充完整游戏性能成绩。
local Catalog = require "config.TrainCatalog"
local RollingStock = require "train.RollingStock"

---@type Scene?
local scene_ = nil
---@type Camera?
local camera_ = nil
---@type StaticModel?
local body_ = nil
---@type Material?
local material_ = nil
---@type string[]
local ids_ = {"DF4D","SS9G","HXD3D","CRH380A_head","CRH380A_middle",
    "CR400AF_head","CR400AF_middle_v2","blue_white"}
---@type number[]
local distances_ = {8,34,75,150,340,750,1500,2200}
local frame_,startFrame_,idIndex_,distanceIndex_ = 0,0,1,1
local hiddenPrimitives_,passMultiplier_,checks_ = 0,0,0
local ready_,failed_,complete_ = false,false,false
local triangles_ = {} ---@type integer[]

local function guard(action)
    if failed_ or complete_ then return end
    local ok,message=xpcall(action,debug.traceback)
    if not ok then failed_=true;log:Write(LOG_ERROR,tostring(message)) end
end

local function positionCase()
    local body,camera=assert(body_),assert(camera_)
    local box=body.worldBoundingBox
    local distance=assert(distances_[distanceIndex_])
    camera.node.position=box.center+Vector3(distance,0,0)
    camera.node:LookAt(box.center)
    body.enabled=false
    startFrame_=frame_
end

local function loadCase()
    local id=assert(ids_[idIndex_])
    local asset=assert(Catalog.Assets[id])
    local model=select(1,RollingStock.LoadBakedModel(id))
    assert(model.numGeometries==1,"LOD诊断需要显式扩展多geometry计数")
    assert(model:GetNumGeometryLodLevels(0)==4,"成品LOD不完整："..id)
    local body=assert(body_)
    body.model=model
    body:SetMaterial(assert(material_))
    local mat=assert(material_)
    mat:SetTexture(TU_DIFFUSE,assert(cache:GetResource("Texture2D",asset.diffusePath)))
    triangles_={}
    for lod=0,3 do
        local geometry=assert(model:GetGeometry(0,lod))
        assert(geometry.indexCount%3==0,"成品不是完整三角列表")
        triangles_[lod+1]=geometry.indexCount//3
        print(string.format("[RollingStockLodProbe] MODEL id=%s lod=%d triangles=%d threshold=%.5f size=%.3f/%.3f/%.3f",
            id,lod,triangles_[lod+1],geometry.lodDistance,model.boundingBox.size.x,
            model.boundingBox.size.y,model.boundingBox.size.z))
    end
    passMultiplier_=0
    positionCase()
end

function Start()
    guard(function()
        scene_=Scene()
        scene_:CreateComponent("Octree"):SetSize(BoundingBox(Vector3(-3000,-3000,-3000),Vector3(3000,3000,3000)),8)
        local zone=scene_:CreateChild("Lighting"):CreateComponent("Zone")
        zone.boundingBox=BoundingBox(Vector3(-3000,-3000,-3000),Vector3(3000,3000,3000))
        zone.ambientSource=AMBIENT_COLOR
        zone.ambientColor=Color(.25,.25,.25)
        zone.fogStart,zone.fogEnd=2900,3000
        zone.autoExposureEnabled,zone.fxaaEnabled,zone.bloomPlusEnabled=false,false,false
        zone.bloomWeight,zone.ssaoIntensity=0,0
        material_=Material()
        material_:SetTechnique(0,assert(cache:GetResource("Technique","Techniques/DiffUnlit.xml")))
        body_=scene_:CreateChild("FullBakedCarBody"):CreateComponent("StaticModel")
        body_.castShadows=false
        camera_=scene_:CreateChild("Camera"):CreateComponent("Camera")
        camera_.nearClip,camera_.farClip,camera_.fov=.12,3000,60
        renderer:SetViewport(0,Viewport(scene_,camera_))
        renderer.drawShadows=false
        loadCase()
        SubscribeToEvent("Update","HandleRollingStockLodProbeUpdate")
        SubscribeToEvent("EndRendering","HandleRollingStockLodProbeRendering")
        ready_=true
    end)
end

---@param eventType string
---@param eventData UpdateEventData
function HandleRollingStockLodProbeUpdate(eventType,eventData)
    if ready_ and not failed_ and not complete_ then frame_=frame_+1 end
end

---@param eventType string
---@param eventData EndRenderingEventData
function HandleRollingStockLodProbeRendering(eventType,eventData)
    if not ready_ then return end
    guard(function()
        local age=frame_-startFrame_
        local body,camera=assert(body_),assert(camera_)
        if age==4 then
            hiddenPrimitives_=renderer.numPrimitives
            body.enabled=true
            return
        end
        if age<10 then return end
        assert(body:IsInView(camera),"完整成品车体未实际进入渲染视野")
        assert(body.model==select(1,RollingStock.LoadBakedModel(ids_[idIndex_])),"诊断替换成了其他模型")
        local distance=camera:GetDistance(body.worldBoundingBox.center)
        assert(math.abs(distance-distances_[distanceIndex_])<.01,"诊断相机距离改变")
        assert(camera.lodBias==1 and body.lodBias==1,"诊断擅自修改LOD偏置")
        local submitted=renderer.numPrimitives-hiddenPrimitives_
        if distanceIndex_==1 then
            assert(submitted>0 and submitted%triangles_[1]==0,"近景提交量无法映射LOD0")
            passMultiplier_=submitted//triangles_[1]
            assert(passMultiplier_>=1 and passMultiplier_<=4,"未知车体渲染pass数")
        end
        local selected=-1
        for lod=0,3 do
            if submitted==triangles_[lod+1]*passMultiplier_ then
                assert(selected==-1,"三角数相同，无法唯一识别LOD")
                selected=lod
            end
        end
        assert(selected>=0,"实际提交三角数不属于任一完整LOD")
        local boxSize=body.worldBoundingBox.size
        local normalized=camera:GetLodDistance(distance,(boxSize.x+boxSize.y+boxSize.z)/3,body.lodBias)
        local geometricScale=camera:GetLodDistance(distance,1,body.lodBias)
        checks_=checks_+1
        print(string.format("[RollingStockLodProbe] REAL id=%s distance=%.3f selectedLOD=%d triangles=%d submitted=%d passes=%d normalized=%.5f unitScale=%.5f cameraBias=%.2f drawableBias=%.2f",
            ids_[idIndex_],distance,selected,triangles_[selected+1],submitted,passMultiplier_,normalized,geometricScale,
            camera.lodBias,body.lodBias))
        if distanceIndex_<#distances_ then distanceIndex_=distanceIndex_+1;positionCase();return end
        distanceIndex_=1
        if idIndex_<#ids_ then idIndex_=idIndex_+1;loadCase();return end
        complete_=true
        print(string.format("ALL_ROLLING_STOCK_LOD_PROBE_COMPLETE models=%d checks=%d actualSubmission=true productionUnchanged=true performancePassNotClaimed=true",#ids_,checks_))
    end)
end

function Stop()
    camera_,body_=nil,nil
    if scene_ then scene_:Dispose();scene_=nil end
    if material_ then material_:Dispose();material_=nil end
end
