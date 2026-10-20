-- 合成山体/轨基唯一地表函数。只计算，不持有Scene或网格；由Terrain空间cell流式提交。
-- 截面（m，轨基相对高）：
-- 山脊(-1100) / 岩肩(-230,+300) / 切坡脚(-36,0) | 0/+5双线 | 道路带(+40..+700,0) / 远岭
-- 桥谷全宽独立下切；隧道内中央地表仍在轨下，山壳/内衬归Landmarks，不封真洞口。
local Route=require "world.Route"
local Config=require "config.GameConfig"
local ReliefConfig=require "config.ReliefConfig"
local Mountain={}
--- 普通延伸线只在旧前缀之后使用山地；狂暴未设First，行为保持全线。
function Mountain.IsActiveAt(s)
    return Config.MountainTerrain~=nil and s>=(Config.MountainTerrain.First or 0)
end
---@type table[]
local structures_={}
local routeLength_=-1
local profileIdentity_={}
---@type table<string,number>
local cornerCache_={}
local cacheCount_=0
local function structures()
    if routeLength_~=Route.GetLength() or profileIdentity_~=Config.RouteProfile then
        structures_=Route.GetStructureRanges()
        routeLength_=Route.GetLength();profileIdentity_=Config.RouteProfile
        cornerCache_,cacheCount_={},0
    end
    return structures_
end
local function smooth(value)
    local t=math.max(0,math.min(1,value))
    return t*t*(3-2*t)
end
local function base(s,lateral)
    local stationFade=1.0
    for _,station in ipairs(Route.GetStations()) do
        stationFade=math.min(stationFade,smooth((math.abs(s-station.s)-1450)/1100))
    end
    local left=math.max(0,-lateral-48)
    local wave=.72+.18*math.sin(s/760+lateral/510)+.10*math.sin(s/290-lateral/180)
    local ridge=(240+120*s/Route.GetLength())*smooth(left/220)
        *(.40+.60*smooth((left-280)/650))*wave
    local right=math.max(0,lateral-720)
    local highland=180*smooth(right/600)*(.76+.24*math.sin(s/950+lateral/250))
    -- 国道同一基高的维护带；桥谷另行真实下切，非桥地段不得在路下凭空挖沟。
    -- 新旧地貌在接续后1200m渐变，不在33km边界切出竖墙。
    local mountainStart=Config.MountainTerrain and Config.MountainTerrain.First
    local joining=mountainStart and smooth((s-mountainStart)/1200) or 1
    return (ridge+highland)*stationFade*joining
end

--- 相对轨基地表。山坡的平滑纵向包络与ReliefGeometry一致；原普通地貌不受影响。
function Mountain.RelativeAt(s,lateral)
    if not Mountain.IsActiveAt(s) then return 0 end
    local value=base(s,lateral)
    -- 桥谷外缘与原始谷面同高再渐变入山，不能让山地高坡在520m裁切边形成竖直裂口。
    -- 同时沿桥台前后600m过渡：20m世界格跨桥端裁切时不得从高山角点直接插值到谷口。
    for _,def in ipairs(structures()) do
        if def.kind=="bridge" and s>=def.first-600 and s<=def.last+600 then
            local across=math.abs(lateral-(def.lateral or 2.5))
            local approach=smooth((s-def.first+600)/600)*smooth((def.last+600-s)/600)
            local side=smooth((across-def.halfWidth)/260)
            value=value*(1-approach*(1-side))
        end
    end
    for _,def in ipairs(ReliefConfig.Slopes or {}) do
        if s>=def.first and s<=def.last and lateral*def.side>=def.toe and lateral*def.side<=def.outer then
            local x=lateral*def.side
            local fade=math.min(180,(def.last-def.first)*.25)
            local envelope=smooth((s-def.first)/fade)*smooth((def.last-s)/fade)
            local height=def.height*envelope*(.88+.08*math.sin(s/97+def.first*.0013)+.04*math.sin(s/41-def.first*.0013))
            local span=def.crest-def.toe
            local xx={def.toe,def.toe+span*.14,def.toe+span*.29,def.toe+span*.43,
                def.toe+span*.62,def.toe+span*.76,def.crest,def.crest+(def.outer-def.crest)*.44,def.outer}
            local yy={0,.16,.36,.38,.68,.70,1,.64,0}
            for i=1,#xx-1 do
                if x<=xx[i+1] then
                    local t=(x-xx[i])/(xx[i+1]-xx[i])
                    local cut=height*(yy[i]+(yy[i+1]-yy[i])*t)
                    -- 设计岩肩融入连续山体，不与第二个叠加网格Z-fight。
                    value=math.max(value,cut)
                    break
                end
            end
        end
    end
    for _,def in ipairs(structures()) do
        if s>=def.first and s<=def.last and math.abs(lateral-(def.lateral or 2.5))<def.halfWidth then
            if def.kind=="bridge" then
                local t=(s-def.first)/(def.last-def.first)
                local along=smooth(math.min(t,1-t)/.30)
                local across=1-smooth((math.abs(lateral-(def.lateral or 2.5))-330)/190)
                return -.25-(def.depth or 50)*along*across
            elseif def.kind=="tunnel" then
                -- 外壳归Landmarks。中央不盖地表；外脚与真实山壳相接。
                if math.abs(lateral-2.5)<def.halfWidth*1.14 then return -.25 end
            end
        end
    end
    return value
end

--- 连续设计地表。实际Terrain以20m固定世界网格分片；GetGroundHeight做相同三角插值。
function Mountain.DesignHeight(x,z)
    local _,s=Route.DistanceTo(Vector3(x,0,z))
    local origin=Route.Sample(s)
    local lateral=(Vector3(x,origin.y,z)-origin):DotProduct(Route.RightAt(s))
    return origin.y+Mountain.RelativeAt(s,lateral)
end

function Mountain.GetGroundHeight(x,z)
    if not Config.MountainTerrain then return 0 end
    -- 桥谷/隧道由沿线扫掠网格接管，不能用横跨切边的世界格三角近似抬高谷底。
    local _,s=Route.DistanceTo(Vector3(x,0,z))
    if not Mountain.IsActiveAt(s) then return 0 end
    local origin=Route.Sample(s)
    local lateral=(Vector3(x,origin.y,z)-origin):DotProduct(Route.RightAt(s))
    for _,def in ipairs(structures()) do
        if s>=def.first and s<=def.last and math.abs(lateral-2.5)<=def.halfWidth then
            return origin.y+Mountain.RelativeAt(s,lateral)
        end
    end
    local step=Config.MountainTerrain.GridStep or 20
    local x0,z0=math.floor(x/step)*step,math.floor(z/step)*step
    local u,v=(x-x0)/step,(z-z0)/step
    local function corner(cx,cz)
        local key=cx.."_"..cz
        local cached=cornerCache_[key]
        if cached~=nil then return cached end
        local height=Mountain.DesignHeight(cx,cz)
        -- 只缓存数值，最多8192角点；无全图网格/节点常驻，不随133km旅程无限增长。
        if cacheCount_>=8192 then cornerCache_,cacheCount_={},0 end
        cornerCache_[key]=height;cacheCount_=cacheCount_+1
        return height
    end
    local a,b,c,d=corner(x0,z0),corner(x0,z0+step),corner(x0+step,z0+step),corner(x0+step,z0)
    return v>=u and a*(1-v)+b*(v-u)+c*u or a*(1-u)+c*v+d*(u-v)
end
return Mountain
