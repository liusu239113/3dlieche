-- 真实引擎静态视觉验收，不加载main/Game/Save，不访问云或玩家存档。
-- 只复用scaffold-3d-scene的Scene/LightGroup/Camera生命周期。
local Route = require "world.Route"
local Terrain = require "world.Terrain"
local Landscape = require "world.Landscape"
local Landmarks = require "world.Landmarks"
local Road = require "world.RoadCorridor"
local Scenery = require "world.RailwayScenery"
local Track = require "world.Track"
local VisualQuality = require "config.VisualQuality"
local Visual = {}
---@type Scene?
local scene_ = nil
---@type Node?
local cameraNode_ = nil
local function setup()
    Route.Build()
    Terrain.Init()
    Terrain.SetQuality(VisualQuality.Get("low"))
    Track.Init()
    scene_ = Scene()
    scene_:CreateComponent("Octree")
    Road.Init(scene_)
    Scenery.Init(scene_)
    Landscape.SetCorridorExclusion(function(pos, radius, purpose)
        return Road.IsExcluded(pos, radius, purpose) or Scenery.IsExcluded(pos, radius, purpose)
    end)
    local lighting = scene_:CreateChild("LightGroup")
    lighting:LoadXML(cache:GetResource("XMLFile", "LightGroup/Daytime.xml"):GetRoot())
    local zone = lighting:GetComponent("Zone", true)
    local sun = lighting:GetComponent("Light", true)
    sun.castShadows = false
    zone:SetAttribute("Bloom Enable", Variant(false))
    zone.depthFogStart, zone.depthFogEnd = 2000, 6000
    renderer.hdrRendering = true
    Terrain.BuildGround(scene_:CreateChild("世界保底"))
    cameraNode_ = scene_:CreateChild("验证相机")
    local camera = cameraNode_:CreateComponent("Camera")
    camera.farClip, camera.nearClip, camera.fov = 5000, .25, 55
    camera.viewMask = 3
    renderer:SetViewport(0, Viewport:new(scene_, camera))
end
local function build(first, last, hills)
    for s = first, last - .001, 240 do
        local finish = math.min(last, s + 240)
        Road.BuildChunk(scene_, s, finish)
        Scenery.BuildChunk(scene_, s, finish)
        Landmarks.BuildChunk(scene_, s, finish)
        Track.BuildChunk(scene_:CreateChild("双线轨道"), s, finish, false)
    end
    if hills then
        local center = Road.Sample(first + 950)
        local minX, maxX = center.x - 500, center.x + 500
        local minZ, maxZ = center.z - 500, center.z + 500
        for x = math.floor(minX / 160), math.floor(maxX / 160) do
            for z = math.floor(minZ / 160), math.floor(maxZ / 160) do
                Terrain.BuildHills(scene_:CreateChild("丘陵格"), x, z, 160)
            end
        end
    end
end
function Visual.Run(mode)
    setup()
    if mode == "bypass" then
        for _, def in ipairs(Landmarks.GetDefinitions()) do
            if def.kind == "tunnel" then
                build(def.first - 850, def.last + 850, true)
                local target = Road.Sample(def.first + 130)
                cameraNode_.position = target + Route.RightAt(def.s) * 620 + Route.TangentAt(def.s) * -550 + Vector3(0, 410, 0)
                cameraNode_:LookAt(target + Vector3(0, 30, 0))
                break
            end
        end
    elseif mode == "village" then
        for _, plot in ipairs(Scenery.GetExclusions()) do
            if plot.kind == "village" then
                build(plot.s - 600, plot.s + 600, false)
                cameraNode_.position = plot.pos + Route.RightAt(plot.s) * -100 + Route.TangentAt(plot.s) * -125 + Vector3(0, 90, 0)
                cameraNode_:LookAt(plot.pos)
                break
            end
        end
    else
        local loop = Road.GetConnections()[1]
        assert(loop, "当前线路没有合法上跨回环")
        build(loop.first - 260, loop.last + 260, false)
        local s = loop.crossings[1]
        local target = Route.SampleOffset(s, 25, 4)
        cameraNode_.position = target + Route.RightAt(s) * -380 + Route.TangentAt(s) * -580 + Vector3(0, 350, 0)
        cameraNode_:LookAt(target + Route.TangentAt(s) * 150)
    end
    print("[CorridorVisualValidation] 静态场景已生成，无存档/云访问 mode=" .. tostring(mode))
end
function Start() Visual.Run("overpass") end
return Visual
