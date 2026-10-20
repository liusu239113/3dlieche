-- 普通/狂暴的唯一模式配置入口。Apply必须在卸载旧世界之后、Route.Build之前调用。
-- 本模块不加载场景、不读写存档；普通旧存档缺失mode时由集成层视作normal。
local Config = require "config.GameConfig"
local ReliefConfig = require "config.ReliefConfig"
local RageRoute = require "world.RageRoute"
local NormalRoute = require "config.NormalRoute"
local GameModes = {}

---@class RailwayModeRules
---@field FreeDrive boolean
---@field IgnoreLineSpeedLimits boolean
---@field DisableDerailment boolean
---@field ChainCollisions boolean
---@field MixedTraffic boolean
---@field TrafficLogicCount? integer
---@field TrafficVisibleCount? integer
---@class RailwayGameMode
---@field id string
---@field name string
---@field subtitle string
---@field routeId string
---@field routeName string
---@field routeLength number
---@field platformLength number
---@field rules RailwayModeRules

-- 只记录模式拥有的配置。保持原表引用并且从不原地改原线路/地貌表；
-- rage -> normal精确恢复，且不覆盖画质、音量、环境或玩家选择的车型。
local normal_={
    RouteSegments=Config.RouteSegments,Stations=Config.Stations,
    RouteStart=Config.RouteStart,RouteStartYaw=Config.RouteStartYaw,
    RouteClosed=Config.RouteClosed,RouteTransitions=Config.RouteTransitions,
    RouteTransitionLength=Config.RouteTransitionLength,RouteProfile=Config.RouteProfile,
    MountainTerrain=Config.MountainTerrain,RouteRegions=Config.RouteRegions,
    StationLayout=Config.StationLayout,RouteId=Config.RouteId,RouteDisplayName=Config.RouteDisplayName,
    Seed=Config.WorldStream.Seed,
}
local relief_={
    Version=ReliefConfig.Version,PortalTransition=ReliefConfig.PortalTransition,
    MaintenanceHalfWidth=ReliefConfig.MaintenanceHalfWidth,
    Structures=ReliefConfig.Structures,Slopes=ReliefConfig.Slopes,Peaks=ReliefConfig.Peaks,
}
local ownedKeys={"RouteSegments","Stations","RouteStart","RouteStartYaw","RouteClosed",
    "RouteTransitions","RouteTransitionLength","RouteProfile","MountainTerrain","RouteRegions",
    "StationLayout","RouteId","RouteDisplayName"}
local names_={}
for i,station in ipairs(normal_.Stations) do names_[i]=station.name end
local normalMap_=NormalRoute.Create(normal_.RouteSegments,normal_.Stations,relief_)
local legacyNormalLength_=normalMap_.legacyLength

local function rules(rage)
    return {FreeDrive=rage,IgnoreLineSpeedLimits=rage,DisableDerailment=rage,
        ChainCollisions=rage,MixedTraffic=rage,
        TrafficLogicCount=rage and 8 or nil,TrafficVisibleCount=rage and 3 or nil}
end

---@param id? string
---@return string
function GameModes.Normalize(id)
    if id==nil or id=="" then return "normal" end
    assert(id=="normal" or id=="rage","[GameModes] 未知模式："..tostring(id))
    return id
end
---@return string
function GameModes.GetId() return GameModes.Normalize(Config.GameMode) end
---@return boolean
function GameModes.IsRage() return GameModes.GetId()=="rage" end

--- 返回描述副本，不暴露可修改的原始几何表。传id用于菜单，不传则查当前模式。
---@param id? string
---@return RailwayGameMode
function GameModes.Get(id)
    local key=GameModes.Normalize(id or GameModes.GetId())
    local rage=key=="rage"
    return {id=key,name=rage and "狂暴模式" or "普通模式",
        subtitle=rage and "自由试验 · 连锁涌现" or "自主驾驶 · 十站山海客运",
        routeId=rage and RageRoute.Id or normalMap_.id,
        routeName=rage and RageRoute.Name or normalMap_.name,
        routeLength=rage and RageRoute.GetLength() or normalMap_.length,
        platformLength=rage and 550 or 310,rules=rules(rage)}
end

--- 不在菜单选择时提前调用，以免取消/返回破坏仍可继续的旧旅程。
--- 加载时先用存档journey.mode决定id；严禁仅因玩家点狂暴就把普通坐标套入新地图。
---@param id? string
---@return RailwayGameMode
function GameModes.Apply(id)
    local key=GameModes.Normalize(id)
    -- 先恢复模式拥有字段，清除另一张地图的可选配置，再应用所选地图。
    for _,field in ipairs(ownedKeys) do Config[field]=normal_[field] end
    local map=key=="rage" and RageRoute.Create(names_) or normalMap_
    if key=="rage" then
        assert(map.length>=legacyNormalLength_*1.5,"[GameModes] 狂暴线路长度必须至少为原线1.5倍")
    end
    Config.RouteSegments,Config.Stations=map.segments,map.stations
    Config.RouteStart=Vector3(map.start.x,map.start.y,map.start.z)
    Config.RouteStartYaw=map.startYaw
    Config.RouteClosed,Config.RouteTransitions=false,true
    Config.RouteTransitionLength=map.transitionLength
    Config.RouteProfile,Config.MountainTerrain,Config.RouteRegions=map.profile,map.mountain,map.regions
    Config.StationLayout=map.stationLayout
    Config.RouteId,Config.RouteDisplayName=map.id,map.name
    Config.WorldStream.Seed=key=="rage" and RageRoute.Seed or normal_.Seed
    for field,value in pairs(map.relief) do ReliefConfig[field]=value end
    Config.GameMode=key
    Config.ModeRules=rules(key=="rage")
    local mode=GameModes.Get()
    print(string.format("[GameModes] %s / %s %.3fkm / 站台%d米；地图前配置已应用",
        mode.name,mode.routeName,mode.routeLength/1000,mode.platformLength))
    return mode
end
return GameModes
