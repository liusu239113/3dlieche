-- 基于主入口与RailPerformanceValidation的真实离屏渲染诊断脚手架。
-- 只在独立进程临时关闭单类drawable/后效，末尾恢复；不修改生产场景配置。
-- 差分样本不是完整游戏性能成绩，默认100ms框架阈值保持不变。
require "main"
local startGame, updateGame, postUpdateGame = Start, HandleUpdate, HandlePostUpdate
local Train = require "train.Train"
local Camera = require "train.Camera"
local Stream = require "world.WorldStream"
local Hud = require "ui.Hud"
local Game = require "game.Game"
local Traffic = require "game.Traffic"

---@type Scene?
local scene_ = nil
---@type Camera?
local camera_ = nil
---@type Zone?
local zone_ = nil
---@class RailRenderProbeDrawable
---@field drawable Drawable
---@field enabled boolean
---@field category string
---@type RailRenderProbeDrawable[]
local drawables_ = {}
local cases_ = {
    {id="baseline"}, {id="without_near_rails", category="nearRail"},
    {id="without_infrastructure", category="infrastructure"},
    {id="without_vegetation", category="vegetation"},
    {id="without_city", category="city"}, {id="without_station", category="station"},
    {id="without_trains", category="trains"}, {id="without_people", category="people"},
    {id="without_ground", category="ground"}, {id="without_fxaa", effect="fxaa"},
    {id="without_bloom_ssao", effect="bloom_ssao"}, {id="without_hud", effect="hud"},
    {id="without_geometry", effect="geometry"}, {id="without_sun", effect="sun"},
    {id="restored"},
}
local frame_, caseIndex_, stageStart_ = 0, 0, 0
local ready_, failed_, complete_ = false, false, false
local previousWall_ = 0
local baseline_ = {s=0, nodes=0, eye=Vector3.ZERO, direction=Vector3.FORWARD,
    trafficElapsed=0, fxaa=false, bloom=false, bloomWeight=0, ssaoIntensity=0}
---@type Light?
local sun_=nil
local sunEnabled_=true
---@type table<string, table>
local records_ = {}

local function guard(action)
    if failed_ or complete_ then return end
    local ok, message = xpcall(action, debug.traceback)
    if not ok then failed_=true; error(message,0) end
end

---@param drawable Drawable
local function category(drawable)
    if drawable.node.name:find("Tree",1,true) or drawable.node.name:find("Bush",1,true)
        or drawable.node.name:find("Grass",1,true) then return "vegetation" end
    local node = drawable.node
    while node and node~=scene_ do
        if node.name=="Train" or node.name=="AITraffic" then return "trains" end
        if node.name:match("^nearRail_") then return "nearRail" end
        if node.name:match("^infrastructure_") then return "infrastructure" end
        if node.name:match("^vegetation_") then return "vegetation" end
        if node.name:match("^station_") then return "station" end
        if node.name:match("^city_") then return "city" end
        if node.name:match("^terrain_") or node.name:match("^scenery_") then return "ground" end
        node = node.parent
    end
    if drawable:GetTypeName()=="AnimatedModel" then return "people" end
    return "other"
end

local function restore()
    for _, entry in ipairs(drawables_) do entry.drawable.enabled=entry.enabled end
    local zone = assert(zone_)
    zone.fxaaEnabled=baseline_.fxaa
    zone.bloomPlusEnabled=baseline_.bloom
    zone.bloomWeight=baseline_.bloomWeight
    zone.ssaoIntensity=baseline_.ssaoIntensity
    assert(sun_).enabled=sunEnabled_
    assert(Hud.GetRoot()):SetVisible(true)
end

local function checkIdentity()
    local viewport = assert(renderer:GetViewport(0))
    local camera = assert(camera_)
    assert(viewport.scene==scene_ and viewport.camera==camera, "诊断偷换场景/相机")
    assert(graphics:GetWidth()==640 and graphics:GetHeight()==360, "诊断分辨率改变")
    assert(Camera.GetMode()=="birdseye" and Hud.GetReadings().paused, "诊断离开暂停鸟瞰机位")
    assert(math.abs(Train.GetS()-baseline_.s)<.001, "诊断推进玩家位置")
    assert((camera.node.worldPosition-baseline_.eye):Length()<.002
        and (camera.node.worldDirection-baseline_.direction):Length()<.00002, "诊断机位改变")
    assert(Stream.GetStats().pendingTasks==0, "诊断流式尚未收敛")
    assert(math.abs(Traffic.GetStats().elapsed-baseline_.trafficElapsed)<.00001, "诊断推进AI")
end

local function activate(index)
    restore()
    caseIndex_,stageStart_=index,frame_
    local case = assert(cases_[index])
    local disabled=0
    for _, entry in ipairs(drawables_) do
        if (case.category and entry.category==case.category or case.effect=="geometry") and entry.enabled then
            entry.drawable.enabled=false
            disabled=disabled+1
        end
    end
    local zone = assert(zone_)
    if case.effect=="fxaa" then zone.fxaaEnabled=false end
    if case.effect=="bloom_ssao" then
        zone.bloomPlusEnabled=false; zone.bloomWeight=0; zone.ssaoIntensity=0
    end
    if case.effect=="hud" then assert(Hud.GetRoot()):SetVisible(false) end
    if case.effect=="sun" then assert(sun_).enabled=false end
    assert(not case.category or disabled>0, "诊断分类未命中："..case.id)
    records_[case.id]={samples={},disabled=disabled}
    print(string.format("[RailRenderProbe] CASE %s disabled=%d temporaryDiagnosticOnly=true",case.id,disabled))
end

local function census()
    local scene = assert(scene_)
    local seen, counts = {}, {}
    local components = {}
    for _, component in ipairs(scene:GetComponents("StaticModel",true)) do components[#components+1]=component end
    for _, component in ipairs(scene:GetComponents("StaticModelGroup",true)) do components[#components+1]=component end
    for _, component in ipairs(scene:GetComponents("CustomGeometry",true)) do components[#components+1]=component end
    for _, component in ipairs(scene:GetComponents("AnimatedModel",true)) do components[#components+1]=component end
    for _, component in ipairs(scene:GetComponents("Text3D",true)) do components[#components+1]=component end
    for _, component in ipairs(components) do
        local drawable=component --[[@as Drawable]]
        if not seen[drawable.ID] then
            seen[drawable.ID]=true
            local key=category(drawable)
            drawables_[#drawables_+1]={drawable=drawable,enabled=drawable.enabled,category=key}
            counts[key]=(counts[key] or 0)+1
        end
    end
    for key, count in pairs(counts) do
        print(string.format("[RailRenderProbe] CENSUS category=%s drawables=%d",key,count))
    end
    local zone=assert(zone_)
    baseline_={s=Train.GetS(),nodes=#scene:GetChildren(true),eye=assert(camera_).node.worldPosition,
        direction=assert(camera_).node.worldDirection,trafficElapsed=Traffic.GetStats().elapsed,
        fxaa=zone.fxaaEnabled,bloom=zone.bloomPlusEnabled,bloomWeight=zone.bloomWeight,
        ssaoIntensity=zone.ssaoIntensity}
    print(string.format("[RailRenderProbe] EFFECTS fxaa=%s bloom=%s bloomWeight=%.3f ssao=%.3f hdr=%s",
        tostring(baseline_.fxaa),tostring(baseline_.bloom),baseline_.bloomWeight,
        baseline_.ssaoIntensity,tostring(renderer.hdrRendering)))
    activate(1)
end

function Start()
    guard(function()
        startGame()
        scene_=assert(renderer:GetViewport(0).scene)
        camera_=assert(Camera.GetCamera())
        zone_=assert(assert(scene_:GetChild("DayLighting")):GetComponent("Zone"))
        sun_=assert(assert(scene_:GetChild("DayLighting")):GetComponent("Light",true))
        sunEnabled_=sun_.enabled
        -- 列出实际渲染命令，不猜测后效是否真有pass；只读，不修改RenderPath。
        local path=assert(renderer:GetViewport(0).renderPath)
        for i=0,path:GetNumCommands()-1 do
            local command=path:GetCommand(i)
            print(string.format("[RailRenderProbe] COMMAND index=%d tag=%s type=%d enabled=%s pass=%s pixel=%s defines=%s",
                i,command.tag,command.type,tostring(command.enabled),command.pass,command.pixelShaderName,command.pixelShaderDefines))
        end
        TogglePause()
        assert(Camera.SetMode("birdseye"))
        Camera.Update(.05,Train.GetS())
        Hud.SetCameraMode(Camera.GetMode(),Camera.GetModeName())
        assert(SetRenderQuality("performance"))
        Game.UpdateHud(0)
        previousWall_=Time:GetSystemTime()
        SubscribeToEvent("EndRendering","HandleRenderProbeRendering")
        ready_=true
    end)
end

---@param eventType string
---@param eventData UpdateEventData
function HandleUpdate(eventType,eventData)
    if not ready_ then return end
    guard(function() frame_=frame_+1;updateGame(eventType,eventData) end)
end

---@param eventType string
---@param eventData PostUpdateEventData
function HandlePostUpdate(eventType,eventData)
    if not ready_ then return end
    guard(function()
        postUpdateGame(eventType,eventData)
        if caseIndex_==0 then
            for _=1,64 do
                if Stream.GetStats().pendingTasks==0 then break end
                Stream.Update(Train.GetS(),0)
            end
        end
    end)
end

---@param eventType string
---@param eventData EndRenderingEventData
function HandleRenderProbeRendering(eventType,eventData)
    if not ready_ then return end
    guard(function()
        local now=Time:GetSystemTime()
        local wall=now-previousWall_
        previousWall_=now
        if caseIndex_==0 then
            if frame_>=120 then census() end
            return
        end
        checkIdentity()
        if frame_-stageStart_<=5 then return end
        local case=assert(cases_[caseIndex_])
        local record=records_[case.id]
        record.samples[#record.samples+1]={wall=wall,batches=renderer.numBatches,primitives=renderer.numPrimitives}
        if #record.samples<12 then return end
        local total,lowest,highest,batches,primitives=0,math.huge,0,0,0
        for _, sample in ipairs(record.samples) do
            total=total+sample.wall
            lowest,highest=math.min(lowest,sample.wall),math.max(highest,sample.wall)
            batches=batches+sample.batches;primitives=primitives+sample.primitives
        end
        print(string.format("[RailRenderProbe] RESULT case=%s samples=12 wallMeanMs=%.3f wallMinMs=%.3f wallMaxMs=%.3f batches=%.1f primitives=%.1f disabled=%d",
            case.id,total/12,lowest,highest,batches/12,primitives/12,record.disabled))
        if caseIndex_<#cases_ then activate(caseIndex_+1);return end
        restore()
        assert(#assert(scene_):GetChildren(true)==baseline_.nodes,"诊断结束节点数变化")
        for _, entry in ipairs(drawables_) do assert(entry.drawable.enabled==entry.enabled,"诊断未恢复drawable") end
        complete_=true
        print(string.format("ALL_RAIL_RENDER_PROBE_COMPLETE cases=%d samples=12each restored=true performancePassNotClaimed=true",#cases_))
    end)
end
