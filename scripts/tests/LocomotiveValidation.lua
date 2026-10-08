-- ============================================================================
-- 机车独立验收场景：加载、轮轨校准、驾驶移动及视角切换回归
-- 基于 3D 场景脚手架；不加载站房/地形的远端材质，便于隔离资产问题。
-- ============================================================================

local Route = require "world.Route"
local Track = require "world.Track"
local Train = require "train.Train"
local TrainCamera = require "train.Camera"

---@type Scene|nil
local scene_ = nil

function Start()
    scene_ = Scene()
    scene_:CreateComponent("Octree")
    local zone = scene_:CreateComponent("Zone")
    zone.boundingBox = BoundingBox(Vector3(-6000, -6000, -6000), Vector3(6000, 6000, 6000))
    zone.ambientSource = AMBIENT_COLOR
    zone.ambientColor = Color(0.36, 0.39, 0.43)
    zone.fogColor = Color(0.70, 0.77, 0.84)
    zone.fogStart = 60
    zone.fogEnd = 500
    local sunNode = scene_:CreateChild("Sun")
    sunNode.direction = Vector3(-0.6, -1.0, -0.3)
    local sun = sunNode:CreateComponent("Light")
    sun.lightType = LIGHT_DIRECTIONAL
    sun.brightness = 2.0

    Route.Build()
    Track.Build(scene_)
    Train.Build(scene_)
    TrainCamera.Build(scene_)

    local lead = assert(Train.GetLeadNode(), "机车节点不存在")
    local visual = assert(lead:GetChild("LocomotiveModel"), "机车模型节点不存在")
    local drawable = assert(visual:GetComponent("StaticModel"), "机车渲染组件不存在")
    assert(not lead:GetChild("Flip"), "不应保留旧机车翻转节点")
    assert(not lead:GetChild("Body"), "不应叠加旧积木车体")
    assert(drawable.model:GetNumGeometryLodLevels(0) == 4, "机车 LOD 丢失")
    assert(drawable:GetMaterial():GetTexture(TU_DIFFUSE), "机车涂装贴图缺失")
    assert(drawable:GetMaterial():GetTexture(TU_NORMAL), "机车法线贴图缺失")
    local size = drawable.model.boundingBox.size
    assert(size.z > 20.9 and size.z < 21.2, "机车车长校准失败")
    assert(size.x > 2.9 and size.x < 3.2, "机车车宽校准失败")
    assert(size.y > 4.0 and size.y < 4.3, "机车车高校准失败")

    -- 司机视角必须隐藏本车外壳，切回外部视角恢复。
    TrainCamera.SetMode("cab")
    assert(not drawable.enabled, "司机视角外壳未隐藏")
    TrainCamera.SetMode("side")
    assert(drawable.enabled, "外部视角未恢复车身")
    TrainCamera.SetMode("chase")
    assert(drawable.enabled, "跟随视角未恢复车身")

    -- 模型替换不能破坏原来的纵向驾驶接口。
    Train.Reset(100)
    local before = Train.GetS()
    Train.ThrottleUp()
    Train.Update(1.0)
    Train.UpdateVisuals(1.0)
    assert(Train.GetSpeedMs() > 0, "推油门后机车没有前进")
    assert(Train.GetS() > before, "机车位置没有更新")
    Train.EmergencyBrake()
    assert(Train.GetThrottle() == 0 and Train.GetBrake() == 1, "紧急制动接口异常")
    Train.Reset(100)
    assert(Train.GetSpeedMs() == 0, "机车复位未停稳")

    -- 使用和游戏相同的资产，摄像机只为验收展示固定在前侧。
    local cameraNode = assert(TrainCamera.GetNode())
    local position = Train.GetLeadPosition()
    cameraNode.position = position + Vector3(22, 9, 22)
    cameraNode:LookAt(position + Vector3(0, 2.0, 0))
    local camera = assert(TrainCamera.GetCamera())
    camera.fov = 42
    camera.nearClip = 0.1
    renderer.hdrRendering = true
    SubscribeToEvent("Update", "HandleValidationUpdate")
    print("[LocomotiveValidation] 资产加载、四级LOD、米制尺寸、前进/制动/复位、司机/外部视角回归全部通过")
end

---@param eventType string
---@param eventData UpdateEventData
function HandleValidationUpdate(eventType, eventData)
    -- 持有静态场景，仅验证渲染，不依赖真实时间改变验收角度。
end

function Stop()
    if scene_ then scene_:Dispose() end
    scene_ = nil
end
