-- 实际像素验收：五站街区、六个连续地理区与完整流式加载。
-- 复用游戏入口，不代替真实玩法；截图仅供本地验收。
require "main"
local startGame = Start
local postUpdateGame = HandlePostUpdate
local Route = require "world.Route"
local Train = require "train.Train"
local TrainCamera = require "train.Camera"
local WorldStream = require "world.WorldStream"
local Terrain = require "world.Terrain"
local Station = require "world.Station"
local Game = require "game.Game"
local Hud = require "ui.Hud"

---@type Scene?
local scene_ = nil
local rayChecks_ = 0
local checkedStations_ = {}
-- 当前固定街区规划：低密谷地不是每站强塞40栋，高密终点仍需完整84栋。
local expectedBuildings_ = {47,39,22,27,84}
local plannedBuildings_ = {}
local ready_ = false
local frame_ = 0
local current_ = 1
local FRAMES_PER_CASE = 32
local captured_ = {}
---@type {name:string,s:number,station:table?}[]
local cases_ = {}

local function activate(index)
    current_ = index
    local case = assert(cases_[index])
    Train.Reset(case.s)
    WorldStream.Reset(case.s)
    -- 离线验收等待全部局部任务完成，避免把尚未加载的地面/树当作最终画面。
    for _ = 1,12000 do
        if WorldStream.GetStats().pendingTasks == 0 then break end
        WorldStream.Update(case.s,0)
    end
    assert(WorldStream.GetStats().pendingTasks == 0, "局部流式队列未能收敛")
    Game.Init()
    Hud.SetStationName(case.station and case.station.name or "沿线景观验收")
    Hud.SetNextStation(case.name)
    print("[VisualUpgradeValidation] 切换 " .. case.name)
end

local function checkStationRays(station)
    if checkedStations_[station.index] then return end
    local scene = assert(scene_)
    local octree = assert(scene:GetComponent("Octree"))
    assert(octree.numLevels == 8, "主场景没有全线八叉树配置")
    assert(renderer:GetViewport(0).scene == scene, "验收更换了主场景")
    local root = assert(scene:GetChild("Station_"..station.name, true))
    local frame = assert(root:GetChild("CityCanopyStructure")):GetComponent("CustomGeometry")
    local platform = assert(root:GetChild("WeatheredConcretePlatforms")):GetComponent("CustomGeometry")
    assert(frame and platform and frame.enabledEffective and platform.enabledEffective,
        "主入口实际站台未启用")
    local firsts = {-155,-150,-118,-168,-190}
    local _,_,yaw = Route.Sample(station.s)
    local right = Quaternion(yaw,Vector3.UP)*Vector3.RIGHT
    local dimensions = Station.GetDimensions()
    for _,side in ipairs({-1,1}) do
        -- 柱侧射线检验真实三角面，负台位移和独立测试一致，不移动待测几何。
        local lateral = side*7.65+(side<0 and -11 or 0)
        local origin = Route.SampleOffset(station.s+firsts[station.index]+1,lateral,dimensions.platformTopY+1)
        local hit = octree:RaycastSingle(Ray(origin-right*.30,right),RAY_TRIANGLE,.6,DRAWABLE_GEOMETRY,4)
        assert(hit.drawable == frame and math.abs(hit.distance-.22)<.012,
            "主场景远站圆管支柱射线失效："..station.name)
        local surface = Route.SampleOffset(station.s-80,side>0 and 4.7 or -16,3)
        local floorHit = octree:RaycastSingle(Ray(surface,Vector3.DOWN),RAY_TRIANGLE,2,DRAWABLE_GEOMETRY,4)
        assert(floorHit.drawable == platform and math.abs(floorHit.distance-(3-dimensions.platformTopY))<.015,
            "主场景远站台面三角射线失效："..station.name)
        rayChecks_ = rayChecks_+2
    end
    for _,along in ipairs({-90,-30,0}) do
        for _,lane in ipairs({-5,0,10.8}) do
            local origin = Route.SampleOffset(station.s+along,lane,4)
            local hit = octree:RaycastSingle(Ray(origin,Vector3.UP),RAY_TRIANGLE,3,DRAWABLE_GEOMETRY,4)
            assert(not hit.drawable, "主场景运营股道上方存在遮挡："..station.name)
            rayChecks_ = rayChecks_+1
        end
    end
    checkedStations_[station.index] = true
    print(string.format("[VisualUpgradeValidation] MAIN_OCTREE station=%d rays=13 levels=%d actualScene=true",
        station.index,octree.numLevels))
end

local function checkCase()
    local case = assert(cases_[current_])
    local stream = WorldStream.GetStats()
    assert(stream.sceneryChunks > 0, "沿线景观块没有加载")
    assert(stream.pendingTasks == 0, "截图前流式任务尚未完成")
    local landscape = Terrain.GetLandscapeStats()
    if case.station then
        assert(stream.stationChunks == 1 and stream.cityChunks == 1, "当前车站或城市未生成")
        local found = false
        for _, city in ipairs(landscape.cities) do
            if city.stationIndex == case.station.index or city.index == case.station.index or city.name == case.station.name then
                assert(city.buildings >= plannedBuildings_[case.station.index]*.85
                    and city.buildings+(city.rejected or 0)==plannedBuildings_[case.station.index],
                    "当前城市未完整处理规划地块，或大量建筑丢失")
                assert(city.paving and city.paving > 0, "楼前铺装未生成")
                assert(city.streetTrees and city.streetTrees > 0, "楼间行道树未生成")
                if case.station.index==5 then
                    local detailedTowers=0
                    for _, item in ipairs(city.placements or {}) do
                        if item.asset=="residentialTower" then
                            detailedTowers=detailedTowers+1
                            assert(item.kind=="textured_mdl" and item.height>=50 and item.height<90,
                                "云湾住宅高层未保持真实比例/高度")
                        end
                    end
                    assert(detailedTowers>=4,"云湾新高层只存在于资源目录，未进入实际街区")
                    print(string.format("[VisualUpgradeValidation] YUNWAN residentialTowers=%d actualCity=true",detailedTowers))
                end
                for _, item in ipairs(city.pavingData or {}) do
                    assert(item.clearance >= 30, "城区铺装侵入轨道净空")
                end
                for _, item in ipairs(city.treeData or {}) do
                    assert(item.clearance >= 30, "行道树侵入轨道净空")
                end
                found = true
            end
        end
        assert(found, "当前站街区统计缺失，不用全场其他建筑数量冒充")
        for _, item in ipairs(Terrain.GetPlacementData()) do
            assert(Route.DistanceTo(Vector3(item.x,0,item.z))-item.radius >= 25,
                "城市建筑压住轨道净空")
        end
        local dimensions = Station.GetDimensions()
        assert(dimensions.sideGap >= .20 and dimensions.canopyInner > 2.15, "站台侵入列车净空")
        checkStationRays(case.station)
    end
    print(string.format("[VisualUpgradeValidation] %s：%d城市块/%d景观块，%d建筑/%d树/%d水岸",
        case.name,stream.cityChunks,stream.sceneryChunks,landscape.loadedBuildings,landscape.loadedTrees,landscape.loadedWater))
end

function Start()
    startGame()
    scene_ = assert(renderer:GetViewport(0).scene)
    assert(scene_:GetComponent("Octree").numLevels == 8, "主入口没有启用全线八叉树")
    TogglePause()
    local stats = Terrain.GetLandscapeStats()
    assert(#stats.plannedCities == 5, "五站规划不完整")
    local styles = {}
    for _, city in ipairs(stats.plannedCities) do
        assert(city.buildings == expectedBuildings_[city.stationIndex], "当前城市规划楼数被删改")
        plannedBuildings_[city.stationIndex] = city.buildings
        assert(not styles[city.style], "城市主题没有差异")
        styles[city.style] = true
    end
    for _, station in ipairs(Route.GetStations()) do
        cases_[#cases_+1] = {name="station_"..station.index,s=station.s+1,station=station}
    end
    -- 当前是六个连续地理区，不再要求旧版800米主题轮播。
    local themes = {"urban","fields","industry","village","water","urban"}
    assert(#stats.regions == 6 and stats.themeCycle == false, "连续地理区被恢复成主题轮播")
    local previous = 0
    for index, region in ipairs(stats.regions) do
        assert(region.theme == themes[index] and math.abs(region.first-previous)<.001
            and region.last>region.first, "地理区有断口/顺序不匹配")
        previous = region.last
        local sample = (region.first+region.last)*.5
        assert(Terrain.GetThemeAt(sample) == region.theme, "地理查询没有对应生产区域")
        cases_[#cases_+1] = {name="region_"..index.."_"..region.theme,s=sample}
    end
    assert(math.abs(previous-Route.GetLength())<.001 and #cases_==11, "全线地理样本覆盖不足")
    assert(TrainCamera.SetMode("birdseye"), "主入口鸟瞰机位不存在")
    activate(1)
    SubscribeToEvent("EndRendering", "HandleVisualUpgradeCapture")
    ready_ = true
end

---@param eventType string
---@param eventData PostUpdateEventData
function HandlePostUpdate(eventType,eventData)
    if not ready_ then return end
    postUpdateGame(eventType,eventData)
    frame_ = frame_ + 1
    local nextIndex = math.floor((frame_-1)/FRAMES_PER_CASE)+1
    if nextIndex <= #cases_ and nextIndex ~= current_ then activate(nextIndex) end
    -- 验收主动消化局部队列，不改变游戏里的3ms帧预算。
    for _ = 1,24 do
        if WorldStream.GetStats().pendingTasks == 0 then break end
        WorldStream.Update(Train.GetS(),0)
    end
    local case = assert(cases_[current_])
    local cameraNode = assert(TrainCamera.GetNode())
    local camera = assert(TrainCamera.GetCamera())
    local _,_,yaw = Route.Sample(case.s)
    local rotation = Quaternion(yaw,Vector3.UP)
    local origin = Route.Sample(case.s)
    local overview = frame_%FRAMES_PER_CASE < FRAMES_PER_CASE/2
    if case.station then
        -- 云湾对侧有高层，旧(150,64,140)机位落进楼体。独立验收眼点移至铁路上方，
        -- 不修改生产相机，不隐藏建筑；朝站房与后方街区观察。
        if overview and case.station.index==5 then
            cameraNode.position=origin+rotation*Vector3(0,118,175)
            cameraNode:LookAt(origin+rotation*Vector3(-150,24,-90))
        else
            cameraNode.position = origin+rotation*(overview and Vector3(150,64,140) or Vector3(72,24,65))
            cameraNode:LookAt(origin+rotation*(overview and Vector3(-85,12,-72) or Vector3(-60,7,-62)))
        end
        camera.fov = overview and 66 or 62
    else
        cameraNode.position = origin+rotation*(overview and Vector3(135,40,90) or Vector3(35,14,35))
        cameraNode:LookAt(origin+rotation*(overview and Vector3(0,7,-48) or Vector3(-38,4,-55)))
        camera.fov = overview and 68 or 65
    end
end

---@param eventType string
---@param eventData EndRenderingEventData
function HandleVisualUpgradeCapture(eventType,eventData)
    if not ready_ then return end
    local phase = frame_%FRAMES_PER_CASE
    local half = FRAMES_PER_CASE/2
    local overview = phase >= half-4 and phase <= half-1
    local closeup = phase >= FRAMES_PER_CASE-4 and phase <= FRAMES_PER_CASE-1
    if frame_ > #cases_*FRAMES_PER_CASE or (not overview and not closeup) then return end
    local case = assert(cases_[current_])
    local suffix = overview and "_overview" or ""
    local key = case.name..suffix
    if captured_[key] then return end
    checkCase()
    local image = Image()
    -- GLES读回可能暂时未就绪；有限重试，窗口耗尽仍明确失败。
    if not graphics:TakeScreenShot(image) then
        image:Dispose()
        assert(phase ~= (overview and half-1 or FRAMES_PER_CASE-1), "实际渲染截图四次重试均失败")
        return
    end
    assert(image:SavePNG("/workspace/screenshots/upgrade_"..key..".png"), "验收截图未落盘")
    image:Dispose()
    captured_[key] = true
    if current_ == #cases_ and suffix == "" then
        assert(rayChecks_ == 65, "五站主场景射线没有全部执行")
        local views = 0
        for _ in pairs(captured_) do views=views+1 end
        assert(views==#cases_*2, "缺少真实近景/总览")
        print(string.format("ALL_VISUAL_UPGRADE_PASS cases=%d views=%d stationRays=%d mainScene=true",#cases_,views,rayChecks_))
    end
end
