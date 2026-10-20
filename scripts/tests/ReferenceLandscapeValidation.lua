-- 参考图沿线层次回归，真实引擎CPU几何/本地资产，无main/云变量/玩家存档。
-- 基于scaffold-3d-scene的Scene持有模式；交由主验收串行运行，不创建灯光或构建任务。
local Modes=require "config.GameModes"
local Route=require "world.Route"
local Terrain=require "world.Terrain"
local Landscape=require "world.Landscape"
local Road=require "world.RoadCorridor"
local Scenery=require "world.RailwayScenery"
local Vegetation=require "world.Vegetation"
local Vehicles=require "world.RoadVehicles"
---@type Scene|nil
local scene_=nil
local checks_=0
local function check(value,message) checks_=checks_+1;assert(value,"[ReferenceLandscape] "..message) end
local function near(a,b,tolerance,message) check(math.abs(a-b)<tolerance,message.." "..a.." / "..b) end
function Start()
    local ok,err=xpcall(function()
        Modes.Apply("normal");Route.Build();Terrain.Init()
        scene_=Scene();scene_:CreateComponent("Octree")
        for _,path in ipairs(Vegetation.GetResourcePaths()) do check(cache:Exists(path),"植被资源路径不存在 "..path) end
        for _,path in ipairs(Vehicles.GetResourcePaths()) do check(cache:Exists(path),"客车资源路径不存在 "..path) end
        local asset=assert(Vehicles.GetAsset())
        near(asset.bounds.size.x*asset.scale.x,8.6,.001,"真实客车长轴错误")
        near(asset.bounds.size.y*asset.scale.y,3.05,.001,"真实客车高度错误")
        near(asset.bounds.size.z*asset.scale.z,2.45,.001,"真实客车宽度超车道")
        for _,direction in ipairs({-1,1}) do
            local node=scene_:CreateChild("PoseCheck")
            local s=assert(Route.GetStations()[1]).s+120
            local surface,forward=Road.SampleVehicle(s,direction)
            check(Vehicles.Pose(node,surface,forward),"车辆贴地姿态失败")
            local bottom=node:LocalToWorld(Vector3(asset.bounds.center.x,asset.bounds.min.y,asset.bounds.center.z))
            near((bottom-surface):Length(),0,.002,"轮胎底部没有贴道路")
            check((node.rotation*Vector3(1,0,0)):DotProduct(forward)>.999,"车头朝向错误/车辆横行")
            local roadPoint,right=Road.Sample(s)
            near((surface-roadPoint):DotProduct(right),direction*1.75,.002,"公交不在右行车道")
            node:Dispose()
        end
        local stations=Route.GetStations() --[[@as table<number,RailwayStation>]]
        for _,index in ipairs({1,5}) do
            local station=assert(stations[index])
            local owner=scene_:CreateChild("CityFixture_"..index)
            Landscape.BuildCity(owner,station)
            local target=nil ---@type table|nil
            for _,data in ipairs(Landscape.GetStats().cities) do if data.stationIndex==index then target=data end end
            check(target~=nil,"实际城市统计缺失")
            local city=assert(target)
            print(string.format("[ReferenceLandscape] CITY_ACTUAL %d buildings=%d skyline=%d streetTrees=%d hedges=%d",index,city.buildings,city.highRises,city.streetTrees,city.hedges or 0))
            check(city.buildings>=70,"城区仍只有孤立楼，实际栋数="..city.buildings)
            check(city.highRises>=20,"中远景天际线缺失")
            check(city.streetTrees>=20,"城市实际街树不足")
            check((city.hedges or 0)>=20,"城市实际绿篱不足")
            for _,record in ipairs(city.placements) do check(record.clearance>=30,"城市侵入全线铁路净空") end
            check(#owner:GetComponents("StaticModelGroup",true)>0,"城市无真实模型实例组")
            print(string.format("[ReferenceLandscape] CITY %d buildings=%d skyline=%d trees=%d hedges=%d meshes=%d vertices=%d",index,city.buildings,city.highRises,city.trees,city.hedges or 0,city.meshes,city.vertices))
            Landscape.ForgetStation(index);owner:Dispose()
        end
        local first=math.floor((assert(Route.GetStations()[1]).s+1200)/240)*240
        local owner=scene_:CreateChild("RoadFixture")
        Road.BuildChunk(owner,first,first+240)
        local stats=Road.GetStats()
        local expected=0
        for _,record in ipairs(Road.GetTrafficPlan()) do
            if record.s>=first and record.s<first+240 then expected=expected+1 end
        end
        check(stats.vehicles==expected and stats.vehicles<=4,"道路车辆数量不符全线稀疏半开计划")
        for _,record in ipairs(stats.vehicleData) do
            local vehicleAsset=assert(Vehicles.GetAsset(record.kind))
            local bottom=record.node:LocalToWorld(Vector3(vehicleAsset.bounds.center.x,vehicleAsset.bounds.min.y,vehicleAsset.bounds.center.z))
            local delta=bottom-record.surface --[[@as Vector3]]
            near(delta:Length(),0,.002,"静态车流胎底没有贴地")
            check((record.node.rotation*Vector3.RIGHT):DotProduct(record.forward)>.999,"混合车辆车头方向错误")
            check(record.width<=2.45 and record.width<3.5,"混合车辆侵出单车道")
            local closest=nil ---@type CorridorTrafficPlacement?
            local distance=math.huge
            for _,placement in ipairs(Road.GetTrafficPlan()) do
                if placement.s>=first and placement.s<first+240 then
                    local surface=Road.SampleVehicle(placement.s,placement.direction,placement.kind)
                    local d=(surface-record.surface):Length()
                    if d<distance then closest=placement;distance=d end
                end
            end
            local placement=assert(closest)
            near(distance,0,.002,"车辆不属于当前道路chunk计划")
            local center,right=Road.Sample(placement.s)
            near((record.surface-center):DotProduct(right),placement.direction*1.75,.004,"混合车辆不在正确右行车道")
        end
        print(string.format("[ReferenceLandscape] ROAD vehicles=%d liveGroups=%d",stats.vehicles,#owner:GetComponents("StaticModelGroup",true)))
        Road.ForgetChunk(first,first+240);owner:Dispose()
        local drains,hedges=0,0
        for _,sample in ipairs({2400,4200,6600,9600}) do
            local root=scene_:CreateChild("VergeFixture")
            Scenery.BuildChunk(root,sample,sample+240)
            local data=Scenery.GetStats();drains=drains+data.drains;hedges=hedges+data.hedges
            Scenery.ForgetChunk(sample,sample+240);root:Dispose()
        end
        check(drains>0 and hedges>0,"沿线实际排水/绿篱全部被排除")
        print(string.format("ALL_REFERENCE_LANDSCAPE_CPU_PASS checks=%d drains=%d hedges=%d saveIO=NONE",checks_,drains,hedges))
    end,debug.traceback)
    if not ok then log:Write(LOG_ERROR,tostring(err)) end
    engine:Exit()
end
function Stop()
    Terrain.Shutdown()
    if scene_ then scene_:Dispose();scene_=nil end
end
