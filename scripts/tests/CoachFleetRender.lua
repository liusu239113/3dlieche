-- 只读渲染：逐款机车牵引完整编组，拍侧面与端面，供人工核对客车是否已换成独立成品。
local Train = require "train.Train"
local Route = require "world.Route"
local SkyUtils = require "urhox-libs.Rendering.SkyUtils"
local IDS = {"DF4D", "SS9G", "HXD3D", "blue_white"}
---@type Scene?
local scene_ = nil
---@type Node?
local camNode_ = nil
local frame_, shots_, index_ = 0, 0, 1
local failed_ = false

local function guard(action)
    if failed_ then return end
    local ok, err = xpcall(action, debug.traceback)
    if not ok then
        failed_ = true
        print("COACH_FLEET_RENDER_FAILED " .. tostring(err))
        log:Write(LOG_ERROR, tostring(err))
        engine:Exit()
    end
end

function Start()
    guard(function()
        scene_ = Scene()
        local octree = scene_:CreateComponent("Octree")
        octree:SetSize(BoundingBox(Vector3(-120000, -5000, -120000), Vector3(120000, 5000, 120000)), 8)
        local group = scene_:CreateChild("Lighting")
        local zone = group:CreateComponent("Zone")
        zone.boundingBox = BoundingBox(Vector3(-120000, -5000, -120000), Vector3(120000, 5000, 120000))
        zone.ambientSource = AMBIENT_COLOR
        zone.ambientColor = Color(.26, .29, .32)
        zone.tonemapMode = TONEMAP_MODE_ACES
        zone.vignetteEnabled = false
        zone.autoExposureEnabled = false
        zone.fogStart, zone.fogEnd = 600, 1400
        local sunNode = group:CreateChild("Sun")
        sunNode.direction = Vector3(.55, -1, .5)
        local sun = sunNode:CreateComponent("Light")
        sun.lightType = LIGHT_DIRECTIONAL
        sun.color = Color(1, .97, .9)
        sun.brightness = 1.25
        sun.castShadows = false
        SkyUtils.CreateGradientSky(assert(scene_), SkyUtils.Presets.Day)
        Route.Build()
        Train.Build(assert(scene_))
        camNode_ = scene_:CreateChild("Camera")
        local camera = camNode_:CreateComponent("Camera")
        camera.fov, camera.nearClip, camera.farClip = 50, .1, 1200
        renderer:SetViewport(0, Viewport:new(assert(scene_), camera))
        assert(Train.Select(IDS[1]))
        Train.Reset(200)
        for _ = 1, 40 do Train.UpdateVisuals(0) end
        -- 首帧编组尚未定位到线路，等相机稳定后再截图。
        frame_ = -30
        SubscribeToEvent("EndRendering", "HandleFleetCapture")
    end)
end

function HandleFleetCapture()
    guard(function()
        frame_ = frame_ + 1
        if frame_ < 30 or frame_ % 4 ~= 0 then return end
        local cars = Train.GetCars()
        -- 取整个编组包围盒中心，用世界坐标远距俯视，保证整列都在画面内。
        local box = BoundingBox()
        for _, car in ipairs(cars) do box:Merge(car.node.worldPosition) end
        local focus = box.center
        local span = math.max(30, box.size:Length())
        camNode_.position = focus + Vector3(span * .55, span * .45, span * .55)
        camNode_:LookAt(focus)
        print(string.format("[FleetShot] %s focus=(%.1f,%.1f,%.1f) span=%.0f",
            IDS[index_], focus.x, focus.y, focus.z, span))
        local image = Image()
        assert(graphics:TakeScreenShot(image), "截图失败")
        assert(image:SavePNG("/workspace/screenshots/coach_fleet_" .. IDS[index_] .. ".png"))
        image:Dispose()
        shots_ = shots_ + 1
        if index_ >= #IDS then
            print(string.format("COACH_FLEET_RENDER_PASS shots=%d", shots_))
            engine:Exit()
        else
            index_ = index_ + 1
            assert(Train.Select(IDS[index_]))
            Train.Reset(200)
            for _ = 1, 40 do Train.UpdateVisuals(0) end
            frame_ = -30
        end
    end)
end
