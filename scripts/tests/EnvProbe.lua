-- 环境专用探针：只构建「线路 + 光照/天空 + 地形地标」，完全不加载列车/人物/UI。
-- 用途：在人物资源缺失或 main 加载失败时，仍能独立验收山林/湖岸/远山等环境画质。
-- 运行：LIBGL_ALWAYS_SOFTWARE=1 ... UrhoXRuntime tests/EnvProbe.lua -tool_mode \
--       -graphicssurfaceless -validate -validate-frames=N -x 1280 -y 720
local Route = require "world.Route"
local Terrain = require "world.Terrain"
local Landmarks = require "world.Landmarks"
local WorldStream = require "world.WorldStream"
local Sky = require "world.Sky"
local VisualQuality = require "config.VisualQuality"
local GameConfig = require "config.GameConfig"

local OUTPUT = "/workspace/screenshots/quality/"
local tag_ = os.getenv("ENV_PROBE_TAG") or "env"
local focusS_ = tonumber(os.getenv("ENV_PROBE_S") or "") or 3740

local frame_, stage_, wait_, viewIndex_ = 0, "boot", 0, 0
local settleFrames_, retry_ = 0, 0
local failed_, complete_ = false, false
local image_ = Image()
---@type Scene?
local scene_ = nil
---@type Node?
local camNode_ = nil
---@type Camera?
local camera_ = nil
---@type Node?
local lighting_ = nil

-- 巡视机位：相对焦点里程的偏移（侧向/高度/前向）与俯仰。
-- 必须包含近轨驾驶高度的机位（≈1.5–3m），不能只给高空俯视。
---@type {name:string,lateral:number,up:number,along:number,pitch:number}[]
local views_ = {
    { name = "01_lake_wide",   lateral = 260, up = 110, along = 0,    pitch = -20 },
    { name = "02_lake_low",    lateral = 150, up = 16,  along = -40,  pitch = -3 },
    { name = "03_bridge_side", lateral = 170, up = 40,  along = -80,  pitch = -10 },
    { name = "04_ridge",       lateral = 80,  up = 60,  along = -900, pitch = -6 },
    -- 近轨驾驶高度：贴近轨面朝前看，验收实际驾驶视野里的环境。
    { name = "05_track_level", lateral = 0,   up = 2.4, along = -220, pitch = 0 },
    { name = "06_trackside",   lateral = 42,  up = 1.8, along = 0,    pitch = 2 },
}

local shots_ = 0

local function guard(action)
    if failed_ or complete_ then return end
    local ok, message = xpcall(action, debug.traceback)
    if not ok then
        failed_ = true
        print("[EnvProbe] FAILED stage=" .. stage_ .. " frame=" .. frame_)
        print(tostring(message))
        log:Write(LOG_ERROR, "[EnvProbe] " .. tostring(message))
    end
end

local function capture(name)
    if graphics:TakeScreenShot(image_) and image_:SavePNG(OUTPUT .. tag_ .. "_" .. name .. ".png") then
        print(string.format("[EnvProbe] SHOT %s frame=%d", name, frame_))
        return true
    end
    return false
end

local function placeCamera(view)
    if not camera_ or not camNode_ then return end
    local pos = Route.Sample(focusS_)
    local right = Route.RightAt(focusS_)
    local tangent = Route.TangentAt(focusS_)
    local eye = pos + right * view.lateral + Vector3(0, view.up, 0) + tangent * view.along
    camNode_.position = eye
    local target = pos + Vector3(0, 4, 0)
    local dir = (target - eye):Normalized()
    local pr = math.rad(view.pitch)
    local flat = Vector3(dir.x, 0, dir.z):Normalized()
    camNode_.worldDirection = (flat * math.cos(pr) + Vector3(0, 1, 0) * math.sin(pr)):Normalized()
end

local function buildWorld()
    scene_ = Scene()
    scene_:CreateComponent("Octree")
    Route.Build()
    local bounds = BoundingBox()
    for _, p in ipairs(Route.GetPoints()) do
        bounds:Merge(p.pos - Vector3(3000, 1000, 3000))
        bounds:Merge(p.pos + Vector3(3000, 2000, 3000))
    end
    scene_:GetComponent("Octree"):SetSize(bounds, 8)

    -- 光照与天空（与 main.CreateLighting 等价的精简版）。
    lighting_ = scene_:CreateChild("DayLighting")
    local zone = lighting_:CreateComponent("Zone")
    zone.boundingBox = bounds
    local preset = VisualQuality.Get("medium")
    zone.fogColor = preset.fogColor
    zone.fogStart = preset.fogStart
    zone.fogEnd = preset.fogEnd
    zone.tonemapMode = TONEMAP_MODE_ACES
    zone.fxaaEnabled = true
    zone.ambientSource = AMBIENT_COLOR
    zone.ambientColor = Color(0.34, 0.40, 0.48)
    local sunNode = lighting_:CreateChild("Sun")
    sunNode.direction = Vector3(0.45, -1.0, 0.55)
    local sun = sunNode:CreateComponent("Light")
    sun.lightType = LIGHT_DIRECTIONAL
    sun.color = preset.sunColor
    sun.brightness = preset.sunBrightness
    sun.castShadows = false
    Sky.Create(scene_, preset)

    Terrain.SetQuality(preset)
    local initialS = focusS_
    WorldStream.Build(scene_, initialS)

    camNode_ = scene_:CreateChild("EnvProbeCamera")
    camera_ = camNode_:CreateComponent("Camera")
    camera_.fov = 55
    camera_.farClip = 6000
    camera_.nearClip = 0.5
    renderer:SetViewport(0, Viewport:new(scene_, camera_))
    print("[EnvProbe] 环境构建完成（无列车/人物/UI）")
end

function Start()
    guard(function()
        os.execute("mkdir -p " .. OUTPUT)
        print("[EnvProbe] 启动 tag=" .. tag_ .. " 焦点 s=" .. focusS_)
        GameConfig.WorldStream.FrameBudgetMs = 80.0
        GameConfig.WorldStream.MaxTaskSlices = 2048
        buildWorld()
        SubscribeToEvent("Update", "HandleEnvUpdate")
        SubscribeToEvent("EndRendering", "HandleEnvCapture")
        SubscribeToEvent("PostUpdate", "HandleEnvPost")
    end)
end

function HandleEnvCapture()
    if failed_ or complete_ or stage_ ~= "capture" or wait_ > 0 then return end
    local view = views_[viewIndex_]
    if not view then return end
    if capture(view.name) then
        shots_ = shots_ + 1
    else
        retry_ = retry_ + 1
        if retry_ <= 6 then return end
        -- 放弃该机位，但不能计入成功数。
        print("[EnvProbe] 放弃 " .. view.name .. "（读回持续失败）")
    end
    retry_ = 0
    viewIndex_ = viewIndex_ + 1
    if viewIndex_ > #views_ then
        complete_ = true
        local ok = shots_ == #views_
        print(string.format("[EnvProbe] %s shots=%d/%d tag=%s",
            ok and "COMPLETE" or "PARTIAL", shots_, #views_, tag_))
    else
        placeCamera(views_[viewIndex_])
        wait_ = 6
    end
end

---@param eventType string
---@param eventData UpdateEventData
function HandleEnvUpdate(eventType, eventData)
    guard(function()
        frame_ = frame_ + 1
        local st = WorldStream.GetStats()
        if stage_ == "boot" then
            stage_ = "settle"
            wait_ = 30
        elseif stage_ == "settle" then
            settleFrames_ = settleFrames_ + 1
            local enough = st.vegetationChunks >= 4 and st.terrainChunks >= 30
            if (wait_ <= 0 and enough and st.pendingTasks <= 90) or settleFrames_ > 500 then
                stage_ = "capture"
                viewIndex_ = 1
                wait_ = 0
                placeCamera(views_[1])
                print(string.format("[EnvProbe] STREAM veg=%d terrain=%d scenery=%d pending=%d 开始抓图",
                    st.vegetationChunks, st.terrainChunks, st.sceneryChunks, st.pendingTasks))
            else
                wait_ = wait_ - 1
            end
        elseif stage_ == "capture" and wait_ > 0 then
            wait_ = wait_ - 1
        end
    end)
end

---@param eventType string
---@param eventData PostUpdateEventData
function HandleEnvPost(eventType, eventData)
    guard(function()
        WorldStream.Update(focusS_, eventData:GetFloat("TimeStep"))
        placeCamera(views_[math.max(1, math.min(#views_, viewIndex_))])
    end)
end
