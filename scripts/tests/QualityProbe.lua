-- 画质探针：真实入口跑完整加载，再从多个机位抓图，用于画质前后对比。
-- 不修改生产配置；只读相机/HUD，不推进玩法逻辑。
-- 运行：LIBGL_ALWAYS_SOFTWARE=1 ... UrhoXRuntime tests/QualityProbe.lua -tool_mode \
--       -graphicssurfaceless -validate -validate-frames=N -x 1280 -y 720
require "main"
local mainStart, mainUpdate, mainPost = Start, HandleUpdate, HandlePostUpdate
local Camera = require "train.Camera"

local OUTPUT = "/workspace/screenshots/quality/"
local tag_ = os.getenv("QUALITY_PROBE_TAG") or "before"
-- 显式画质档：low / medium / high。未设置时沿用存档设置。
local forceQuality_ = os.getenv("QUALITY_PROBE_QUALITY")
-- 可选：把列车移到指定线路里程再抓图（用于郊区/山林路段与参考图对比）。
local forceS_ = tonumber(os.getenv("QUALITY_PROBE_S") or "")
-- 诊断用：抓图前强制关闭实时阴影（隔离阴影 shader 问题）。
local noShadow_ = os.getenv("QUALITY_PROBE_NOSHADOW") == "1"
-- 诊断用：抓图前强制关闭 HDR。
local noHdr_ = os.getenv("QUALITY_PROBE_NOHDR") == "1"

---@type {id:string,name:string}[]
local views_ = {
    { id = "cab",         name = "01_cab" },
    { id = "front_chase", name = "02_front_chase" },
    { id = "side",        name = "03_side" },
}

local frame_, viewIndex_, wait_, stage_ = 0, 0, 0, "boot"
local retry_ = 0
local settleFrames_ = 0
local failed_, complete_ = false, false
local image_ = Image()

local function guard(action)
    if failed_ or complete_ then return end
    local ok, message = xpcall(action, debug.traceback)
    if not ok then
        failed_ = true
        print("[QualityProbe] FAILED stage=" .. stage_ .. " frame=" .. frame_)
        print(tostring(message))
        log:Write(LOG_ERROR, "[QualityProbe] " .. tostring(message))
    end
end

local function capture(name)
    if graphics:TakeScreenShot(image_) and image_:SavePNG(OUTPUT .. tag_ .. "_" .. name .. ".png") then
        print(string.format("[QualityProbe] SHOT %s frame=%d", name, frame_))
        return true
    end
    print("[QualityProbe] SHOT FAILED " .. name)
    return false
end

function Start()
    guard(function()
        mainStart()
        os.execute("mkdir -p " .. OUTPUT)
        print("[QualityProbe] 启动完成，tag=" .. tag_)
        -- 验证用：放宽流式每帧预算，让世界在软渲染下也能较快收敛。
        -- 只影响本次进程，不改生产配置。
        local GameConfig = require "config.GameConfig"
        if GameConfig.WorldStream then
            GameConfig.WorldStream.FrameBudgetMs = 80.0
            GameConfig.WorldStream.MaxTaskSlices = 2048
            print("[QualityProbe] 验证用流式预算 80ms/2048切片")
        end
        BeginJourney(false)
        SubscribeToEvent("EndRendering", "HandleQualityCapture")
    end)
end

-- 抓图在 EndRendering 之后（画面已合成）；推进状态在 HandleUpdate。
-- surfaceless readback 偶发失败，失败则原地重试，最多 6 次。
function HandleQualityCapture()
    if failed_ or complete_ or stage_ ~= "capture" or wait_ > 0 then return end
    local view = views_[viewIndex_]
    if not view then return end
    if not capture(view.name) then
        retry_ = retry_ + 1
        if retry_ <= 6 then return end
        print("[QualityProbe] 放弃 " .. view.name)
    end
    retry_ = 0
    viewIndex_ = viewIndex_ + 1
    if viewIndex_ > #views_ then
        complete_ = true
        print("[QualityProbe] COMPLETE shots=" .. (#views_) .. " tag=" .. tag_)
    else
        Camera.SetMode(views_[viewIndex_].id)
        wait_ = 6
    end
end

---@param eventType string
---@param eventData UpdateEventData
function HandleUpdate(eventType, eventData)
    guard(function()
        frame_ = frame_ + 1
        mainUpdate(eventType, eventData)
        if frame_ % 30 == 0 then
            print(string.format("[QualityProbe] 进度 frame=%d state=%s stage=%s wait=%d view=%d",
                frame_, tostring(GetApplicationState()), stage_, wait_, viewIndex_))
        end
        if stage_ == "boot" then
            if GetApplicationState() == "playing" then
                if forceQuality_ then SetRenderQuality(forceQuality_) end
                if noShadow_ then renderer.drawShadows = false end
                if noHdr_ then renderer.hdrRendering = false end
                if forceS_ then
                    local Train = require "train.Train"
                    Train.Reset(forceS_)
                    print(string.format("[QualityProbe] 列车移到 s=%.0f", forceS_))
                end
                stage_ = "settle"
                wait_ = 45
                print("[QualityProbe] 进入游戏，等待世界流式收敛")
            end
        elseif stage_ == "settle" then
            wait_ = wait_ - 1
            -- 等待世界流式推进到足以看清画质：不要求完全收敛（软渲染下太慢），
            -- 只要植被块建出若干、地形铺开、pending 降到低位即可抓图。
            local Stream = require "world.WorldStream"
            local st = Stream.GetStats()
            settleFrames_ = settleFrames_ + 1
            local enough = st.vegetationChunks >= 4 and st.terrainChunks >= 30
            if (wait_ <= 0 and enough and st.pendingTasks <= 90) or settleFrames_ > 500 then
                stage_ = "capture"
                viewIndex_ = 1
                wait_ = 0
                Camera.SetMode(views_[1].id)
                print(string.format(
                    "[QualityProbe] STREAM near=%d far=%d infra=%d scenery=%d veg=%d terrain=%d station=%d city=%d pending=%d",
                    st.nearRailChunks, st.farRailChunks, st.infrastructureChunks, st.sceneryChunks,
                    st.vegetationChunks, st.terrainChunks, st.stationChunks, st.cityChunks, st.pendingTasks))
                print("[QualityProbe] 开始抓图")
            end
        elseif stage_ == "capture" and wait_ > 0 then
            wait_ = wait_ - 1
        end
    end)
end

---@param eventType string
---@param eventData PostUpdateEventData
function HandlePostUpdate(eventType, eventData)
    guard(function()
        mainPost(eventType, eventData)
    end)
end
