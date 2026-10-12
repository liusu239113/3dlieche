-- Bounded real-render companion. No Runtime/build is run while authoring this file.
-- Linux invocation (after coordinator LSP/build):
-- LIBGL_ALWAYS_SOFTWARE=1 GALLIUM_DRIVER=llvmpipe EGL_PLATFORM=surfaceless
-- .cli/UrhoXRuntime tests/RailOperationsVisualValidation.lua -tapcode_dir=/workspace
-- -tool_mode -graphicssurfaceless -validate -validate-frames=360 -validate-timeout=600
-- -x 1280 -y 720；使用默认100ms尖峰阈值，不放宽验收。
-- Exactly six internal screenshots, first after frame120, later cases <=40frames.
-- Capture identity remains frozen for two more rendered frames after readback.
-- No command-line -screenshot flag: it would add a seventh shot or exit too early.
require "main"
local startGame = Start
local updateGame = HandleUpdate
local postUpdateGame = HandlePostUpdate
local V = require "tests.RailOperationsValidation"
local Route = require "world.Route"
local Rail = require "world.RailNetwork"
local Train = require "train.Train"
local Camera = require "train.Camera"
local Cab = require "train.CabInterior"
local Traffic = require "game.Traffic"
local Stream = require "world.WorldStream"
local Terrain = require "world.Terrain"
local Hud = require "ui.Hud"
local Game = require "game.Game"
local UI = require "urhox-libs/UI"

---@class RailVisualCase
---@field name string
---@field s number
---@field mode string
---@field theme? string
---@field siding? boolean
---@field menu? boolean
---@type RailVisualCase[]
local cases_ = {}
---@type Scene?
local scene_ = nil
local frame_,caseIndex_,caseStart_,captures_,attempts_ = 0,1,0,0,0
local advance_,completed_,failed_,capturing_,captured_ = false,false,false,false,false
local lastRenderingFrame_,capturedFrame_,holdFrames_,drainSlices_ = -1,-1,0,0
local activeS_ = 0
local expectedHud_ = {stationName="",nextStation="",track="",speedLimitKmh=0}
local OUTPUT = "/workspace/screenshots/"

-- Runtime may keep dispatching events after a Lua error. Latch the first failure
-- before rethrowing so retries cannot later save misleading images or print PASS.
---@param action fun()
local function guarded(action)
    if failed_ then return end
    local ok,message=xpcall(action,debug.traceback)
    if not ok then
        failed_,advance_,capturing_ = true,false,false
        log:Write(LOG_ERROR,tostring(message))
        print(string.format("[RailVisual] FAILED captures=%d/6 case=%d frame=%d",captures_,caseIndex_,frame_))
        error(message,0)
    end
end

-- Find a real, planned scenery theme; never instantiate all five station worlds.
local function sceneryS(theme)
    for s=1600,Route.GetLength()-3000,200 do
        local nearest=math.huge
        for _,station in ipairs(Route.GetStations()) do nearest=math.min(nearest,Route.Distance(s,station.s)) end
        if Terrain.GetThemeAt(s)==theme and nearest>3200 then return s end
    end
    error("[RailVisual] 实际线路找不到远离城市的景观主题："..theme)
end

-- Siding eight-car formation reaches the yard continuously from before the switch.
-- This is a deterministic camera fixture, not a Train.Reset into an occupied branch.
local function moveIntoSiding(station)
    Train.Reset(station.s-850)
    V.Check(Rail.SetPlayerChoice(1,Train.GetS(),Train.GetActiveLength(),false),"视觉fixture不能预选实际侧线")
    V.Check(Train.SetDrivingMode("relaxed"),"视觉fixture停稳模式设置失败")
    local arrived=false
    for step=1,14000 do
        local distance=station.s+12-Train.GetS()
        local velocity=math.abs(Train.GetSpeedMs())
        if distance<=.3 then Train.EmergencyBrake()
        else
            local target=math.min(8,math.sqrt(2*.45*math.max(0,distance-1)))
            if velocity>target+.10 then Train.SetThrottle(0);Train.SetBrake(.45)
            elseif velocity<target-.10 then Train.SetBrake(0);Train.SetThrottle(4)
            else Train.SetThrottle(0);Train.SetBrake(0) end
        end
        Train.Update(.05)
        if distance<20 and math.abs(Train.GetSpeedMs())<=.02 then arrived=true;break end
        V.Check(step<14000,"视觉真实侧线驶入fixture未在有界步数完成")
    end
    V.Check(arrived and Rail.GetPlayerLane(Train.GetS())==2,"侧线截图并非实际入岔后八车编组")
    Train.EmergencyBrake();Train.UpdateVisuals(0)
    for _,car in ipairs(Train.GetCars()) do
        V.Check(Rail.GetPlayerLane(Train.GetS()+car.offset)==2,"侧线截图有车厢仍不在锁存侧线")
    end
end

local function activate(index)
    V.Check(not failed_ and (captures_==0 or captured_ and holdFrames_>=2),
        "截图身份尚未完成两个独立EndRendering帧锁存就切换case")
    caseIndex_,caseStart_,attempts_ = index,frame_,0
    captured_,capturing_,capturedFrame_,holdFrames_,drainSlices_ = false,false,-1,0,0
    local case=assert(cases_[index])
    Hud.SetCameraSelectorOpen(false)
    if case.siding then
        V.Phase("fixture_siding_continuous_move",function() moveIntoSiding(Route.GetStations()[3]) end)
    else Train.Reset(case.s);Train.EmergencyBrake() end
    -- Reset explicitly destroys the previous LOCAL subtree and its queues.
    -- Only one case's station/city can live in this scene at any time.
    V.Phase("world_reset",function() Stream.Reset(Train.GetS()) end)
    Traffic.SetPlayerOverride(nil);Traffic.Reset(Train.GetS())
    Game.Init();Game.UpdateHud(0)
    V.Check(Camera.SetMode(case.mode),"视觉真实镜头目录不支持："..case.mode)
    Camera.Update(.05,Train.GetS())
    Hud.SetCameraMode(Camera.GetMode(),Camera.GetModeName())
    local viewport=assert(renderer:GetViewport(0))
    viewport:SetScene(assert(scene_))
    viewport:SetCamera(assert(Camera.GetCamera()))
    UI.Layout()
    activeS_=Train.GetS()
    local readings=Hud.GetReadings()
    expectedHud_={stationName=readings.stationName,nextStation=readings.nextStation,
        track=readings.track,speedLimitKmh=readings.speedLimitKmh}
    local stats=Stream.GetStats()
    V.Check(stats.stationChunks<=1 and stats.cityChunks<=1,"视觉case同步创建了多站城市")
    print(string.format("[RailVisual] CASE %d/6 %s s=%.2f frame=%d",index,case.name,Train.GetS(),frame_))
end

function Start()
    guarded(function()
        V.Phase("main_start_visual",startGame)
        scene_=assert(renderer:GetViewport(0).scene)
        V.Check(Train.GetSelectedId()=="CR400AF" and Train.GetCarCount()==8,
            "视觉真实车型不是8车复兴号，不能静默回退")
        V.Check(#Camera.GetPresets()==16,"实际镜头目录不是16项")
        TogglePause() -- Frozen deterministic poses; main continues local stream/camera.
        if not fileSystem:DirExists(OUTPUT) then
            V.Check(fileSystem:CreateDir(OUTPUT),"内部截图目录不可创建")
        end
        local first=Route.GetStations()[1]
        local industry=sceneryS("industry")
        -- 林丘过渡边缘只有矮起伏；选区域内部核查真实丘林，不把边缘平地冒充森林。
        local forest=33000
        V.Check(Terrain.GetThemeAt(forest)=="village","丘林验收位置不属于真实地理区")
        cases_={
            {name="rail_operations_cab",s=first.s+1,mode="cab"},
            {name="rail_operations_station_double_track",s=first.s+1,mode="birdseye"},
            {name="rail_operations_siding_eight_cars",s=Route.GetStations()[3].s+12,mode="birdseye",siding=true},
            {name="rail_operations_industry",s=industry,mode="distant",theme="industry"},
            {name="rail_operations_hills_forest",s=forest,mode="distant",theme="village"},
            {name="rail_operations_sixteen_camera_menu",s=first.s+1,mode="cab",menu=true},
        }
        activate(1)
        SubscribeToEvent("EndRendering","HandleRailVisualCapture")
    end)
end

---@param eventType string
---@param eventData UpdateEventData
function HandleUpdate(eventType,eventData)
    guarded(function()
        V.Phase("main_update_visual",function() updateGame(eventType,eventData) end)
        frame_=frame_+1
        V.Check(frame_<350 or completed_,"六个真实截图未在350帧内完成（少图必须失败）")
    end)
end
---@param eventType string
---@param eventData PostUpdateEventData
local function postUpdateVisual(eventType,eventData)
    if advance_ then advance_=false;activate(caseIndex_+1) end
    V.Phase("main_post_update_visual",function() postUpdateGame(eventType,eventData) end)
    if completed_ then return end
    -- Validation-only scheduling accelerates at most 64 task slices per frame.
    -- CPU phase time is reported; this is not a production/phone FPS claim.
    -- No unbounded synchronous loop and no full-route/five-station generation.
    V.Phase("bounded_local_stream_drain",function()
        for _=1,64 do
            if Stream.GetStats().pendingTasks==0 then break end
            Stream.Update(Train.GetS(),0)
            drainSlices_=drainSlices_+1
        end
    end)
    Traffic.UpdateVisuals(.10) -- Only visual interpolation/cloning, not AI time advance.
    local stats=Traffic.GetStats()
    V.Check(stats.visible<=stats.maxVisible and stats.clonedCars<=stats.maxVisible*8,
        "AI视觉克隆超过有界3组8车")
    V.Check((stats.errors or 0)==0,"AI实际模型克隆失败："..tostring(stats.error))
    local case=assert(cases_[caseIndex_])
    if case.menu and frame_-caseStart_>=4 and not Hud.IsCameraSelectorOpen() then
        V.Tap("openCameraSelector")
        local selector=assert(Hud.GetCameraSelector())
        V.Check(selector:GetPageCount()>=2,"16镜头实际菜单没有分页")
        local page=selector:GetPage()
        V.Tap("nextCameraPage")
        V.Check(selector:GetPage()==page+1,"真实菜单分页触摸没有推进")
        V.Tap("previousCameraPage")
        V.Check(selector:GetPage()==page,"真实菜单上页触摸没有恢复")
        UI.Layout()
        local rect=Hud.GetLayout().cameraSelector
        local width,height=UI.GetViewportSize()
        V.Check(rect.w>0 and rect.h>0 and rect.x>=0 and rect.y>=0
            and rect.x+rect.w<=width+1 and rect.y+rect.h<=height+1,"实际16菜单面板越出屏幕")
        V.Check(Hud.GetReadings().cameraCount==16,"菜单展示目录与16实际镜头不一致")
    end
end

---@param eventType string
---@param eventData PostUpdateEventData
function HandlePostUpdate(eventType,eventData)
    guarded(function() postUpdateVisual(eventType,eventData) end)
end

-- Snapshot live renderer/HUD identity without synthesizing any image pixels.
-- Held frames must retain the same actual viewport, pose, station and camera.
---@param case RailVisualCase
---@param phase string
local function verifyIdentity(case,phase)
    local viewport=assert(renderer:GetViewport(0))
    local camera=assert(Camera.GetCamera())
    local node=assert(Camera.GetNode())
    local readings=Hud.GetReadings()
    V.Check(viewport.scene==scene_ and viewport.camera==camera,
        "截图实际viewport不属于当前场景/相机："..case.name)
    V.Near(Train.GetS(),activeS_,.005,"截图锁存期间列车位置改变："..case.name)
    V.Check(Camera.GetMode()==case.mode and readings.selectedCameraId==case.mode,
        "截图相机/HUD机位与case不一致："..case.name)
    V.Check(readings.stationName==expectedHud_.stationName and readings.nextStation==expectedHud_.nextStation
        and readings.track==expectedHud_.track,
        "截图站名/距离/股道HUD与已激活case不一致："..case.name)
    V.Near(readings.speedLimitKmh,expectedHud_.speedLimitKmh,.005,"截图HUD限速跨case："..case.name)
    V.Check(not case.menu or readings.cameraSelectorOpen,"截图菜单未保持打开："..case.name)
    local eye=node.worldPosition
    print(string.format("[RailVisual] IDENTITY phase=%s case=%d name=%s frame=%d scene=%s camera=%s mode=%s s=%.3f eye=(%.3f,%.3f,%.3f) HUD=%s/%s track=%s limit=%.3f menu=%s",
        phase,caseIndex_,case.name,frame_,tostring(viewport.scene),tostring(camera),Camera.GetMode(),
        Train.GetS(),eye.x,eye.y,eye.z,readings.stationName,readings.nextStation,readings.track,
        readings.speedLimitKmh,tostring(readings.cameraSelectorOpen)))
end

-- Verify actual readback bytes, not merely the screenshot API's success flag.
-- File API was checked against File.d.lua; no io.open/os shell/file substitution.
---@param path string
---@param image Image
local function verifySaved(path,image)
    local file=File(path,FILE_READ)
    V.Check(file:IsOpen() and file:GetSize()>256,"PNG成功提示但实际文件不可读/为空")
    for _,byte in ipairs({137,80,78,71,13,10,26,10}) do
        V.Check(file:ReadUByte()==byte,"落盘不是PNG文件")
    end
    file:Seek(0)
    local decoded=Image()
    V.Check(decoded:Load(path),"实际PNG回读解码失败")
    V.Check(decoded.width==image.width and decoded.height==image.height,"PNG回读像素尺寸变化")
    local darkest,brightest=math.huge,-math.huge
    for y=1,8 do
        for x=1,12 do
            local pixel=decoded:GetPixel(math.floor(decoded.width*x/13),math.floor(decoded.height*y/9))
            local value=pixel.r*.2126+pixel.g*.7152+pixel.b*.0722
            darkest,brightest=math.min(darkest,value),math.max(brightest,value)
        end
    end
    V.Check(brightest-darkest>.035 and brightest>.08,"真实渲染PNG为空黑/单色帧")
    decoded:Dispose();file:Dispose()
end

local function captureVisual()
    if completed_ or capturing_ or advance_ or lastRenderingFrame_==frame_ then return end
    lastRenderingFrame_=frame_
    local case=assert(cases_[caseIndex_])
    if captured_ then
        V.Check(frame_>capturedFrame_,"成功截图同帧重复进入锁存处理")
        verifyIdentity(case,"hold")
        holdFrames_=holdFrames_+1
        if holdFrames_>=2 then
            if caseIndex_==#cases_ then
                V.Check(captures_==6,"真实截图数量不是恰好6张")
                completed_=true
                V.PrintPhases()
                print(string.format("ALL_RAIL_OPERATIONS_VISUAL_PASS screenshots=%d assertions=%d frame=%d",
                    captures_,V.checks,frame_))
                print("[RailVisual] PNGs are internal review only; inspect actual files, no assets URI, no phone FPS claim.")
            else advance_=true end
        end
        return
    end
    local age=frame_-caseStart_
    local due=caseIndex_==1 and frame_>=124 or (caseIndex_>1 and age>=34)
    if not due then return end
    V.Check(frame_>=120,"bootstrap结束前禁止截取真实验收图")
    local stats=Stream.GetStats()
    if stats.pendingTasks~=0 then
        -- Queue gets at most six extra frames; after that fail instead of keeping
        -- thousands of disabled partially built nodes until an endless timeout.
        V.Check(caseIndex_==1 and frame_<130 or (caseIndex_>1 and age<40),
            "有界局部流式队列在截图窗口内未收敛："..case.name)
        return
    end
    V.Census(assert(scene_),case.name)
    if case.theme then
        V.Check(Terrain.GetThemeAt(Train.GetS())==case.theme and stats.sceneryChunks>0,
            "景观截图位置不属于实际主题/未加载")
        local landscape=Terrain.GetLandscapeStats()
        if case.theme=="village" then
            V.Check(landscape.loadedHillCells>0 and landscape.loadedHillTrees>0
                and landscape.maxLoadedHillHeight>10,"丘林截图没有真实起伏和坡面植被")
            print(string.format("[RailVisual] HILLS cells=%d trees=%d maxHeight=%.3f",
                landscape.loadedHillCells,landscape.loadedHillTrees,landscape.maxLoadedHillHeight))
        end
    end
    if case.mode=="cab" then
        local root=assert(Cab.GetRoot())
        local body=assert(root:GetChild("GeneratedCabBody")):GetComponent("StaticModel")
        V.Check(Cab.IsVisible() and body and body.model.name==Cab.GetDiagnostics().modelPath,
            "司机截图没有实际独立MDL内舱")
    end
    if case.menu then V.Check(Hud.IsCameraSelectorOpen(),"16菜单截图未打开真实菜单") end
    V.Check(caseIndex_==1 and frame_<134 or (caseIndex_>1 and age<=40),
        "真实截图超出有界捕获窗口："..case.name)
    verifyIdentity(case,"before_capture")
    local image=Image()
    capturing_=true
    attempts_=attempts_+1
    local ok=graphics:TakeScreenShot(image)
    if not ok then
        image:Dispose()
        capturing_=false
        V.Check(attempts_<4,"EndRendering真实截图4次有限重试均失败："..case.name)
        return
    end
    captured_,capturedFrame_,holdFrames_ = true,frame_,0
    V.Check(image.width==graphics:GetWidth() and image.height==graphics:GetHeight(),"实际截图非当前屏幕像素")
    local path=OUTPUT..case.name..".png"
    V.Check(image:SavePNG(path),"真实截图PNG未落盘："..case.name)
    verifySaved(path,image)
    image:Dispose()
    verifyIdentity(case,"after_capture")
    capturing_=false
    captures_=captures_+1
    print(string.format("[RailVisual] REAL_SCREENSHOT %d/6 %s frame=%d attempt=%d drainSlices=%d renderer.batches=%d primitives=%d",
        captures_,path,frame_,attempts_,drainSlices_,renderer.numBatches,renderer.numPrimitives))
end

---@param eventType string
---@param eventData EndRenderingEventData
function HandleRailVisualCapture(eventType,eventData)
    guarded(captureVisual)
end
