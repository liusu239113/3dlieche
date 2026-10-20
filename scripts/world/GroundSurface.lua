-- 单层地表原面裁分：只改变草/混土/土肩的归属，不改高程、法线或桥谷裁切。
-- 原三角 -> 同平面最长约14m细分 -> 两次标量裁分 -> 共用3个PBRDiff批。
-- 无透明叠片/阴影片/vertex-color变体；半开空间cell仍由Terrain唯一拥有。
local Route = require "world.Route"
local World = require "world.WorldMaterials"
local GroundSurface = {}
local TILE = 51.2

-- 两主线中心0/+5；道床原外脚-2.10/+7.10保持不变。
-- 土肩露在道床之外约1.5..3m，混草过渡到12..17m；沿程慢变且左右不对称。
-- 不依赖已加载Track/Station，故卸载/重建顺序不会移动地表边界。
---@param p Vector3
---@return number, number
local function bands(p)
    local _,s=Route.DistanceTo(p)
    local origin=Route.Sample(s)
    local lateral=(p-origin):DotProduct(Route.RightAt(s))-2.5
    local side=lateral<0 and -1 or 1
    local soil=6.5+.7*math.sin(s/23+side*1.7)+.35*math.sin(s/8.7+side)
    local edge=13.0+2.1*math.sin(s/39+side*2.3)+.8*math.sin(s/13.1-side)
    return math.abs(lateral)-soil,math.abs(lateral)-edge
end

---@param polygon Vector3[]
---@param which integer
---@param values fun(p:Vector3):number,number
---@return Vector3[], Vector3[]
local function partition(polygon,which,values)
    local inside,outside={},{} ---@type Vector3[], Vector3[]
    local previous=assert(polygon[#polygon])
    local f1,f2=values(previous)
    local old=which==1 and f1 or f2
    for _,p in ipairs(polygon) do
        local e1,e2=values(p)
        local current=which==1 and e1 or e2
        if (old<0)~=(current<0) then
            -- 对同一有向边反向计算也得到同一点；两个输出共用它，不产生裂缝/面积叠加。
            local t=old/(old-current)
            local cross=previous+(p-previous)*t
            inside[#inside+1]=cross;outside[#outside+1]=cross
        end
        local target=current<0 and inside or outside
        target[#target+1]=p
        previous,old=p,current
    end
    return inside,outside
end

---@class RailwayGroundSurface
---@field owner Node
---@field material Material
---@field tile number
---@field batches table<string,RailwayBatch>
---@field samples table<string,number[]>
---@field pending integer
local Surface={}
Surface.__index=Surface
---@param owner Node
---@param material Material
---@param tile? number
---@return RailwayGroundSurface
function GroundSurface.New(owner,material,tile)
    local self=setmetatable({},Surface)
    self:Init(owner,material,tile or TILE)
    return self
end
function Surface:Init(owner,material,tile)
    self.owner=owner;self.material=material;self.tile=tile;self.batches={};self.samples={};self.pending=0
end
---@param p Vector3
---@return number,number
function Surface:Bands(p)
    local key=string.format("%.4f/%.4f",p.x,p.z)
    local sample=self.samples[key]
    if not sample then
        local a,b=bands(p)
        sample={a,b};self.samples[key]=sample
    end
    return assert(sample[1]),assert(sample[2])
end
---@param material Material
---@param tile number
function Surface:SetBase(material,tile) self.material=material;self.tile=tile end
---@param key string
---@return RailwayBatch
function Surface:Batch(key)
    local id=key=="base" and "base_"..tostring(self.material) or key
    local batch=self.batches[id]
    if batch then return batch end
    local material=key=="earth" and World.GroundEarth() or (key=="verge" and World.GroundVerge() or self.material)
    batch=World.NewBatch(self.owner:CreateChild("NaturalGround_"..key),material,false,self.tile)
    self.batches[id]=batch
    return batch
end
---@param polygon Vector3[]
---@param key string
function Surface:Polygon(polygon,key)
    if #polygon<3 then return end
    local batch=self:Batch(key)
    for i=2,#polygon-1 do batch:AddTriPlanar(polygon[1],polygon[i],polygon[i+1],self.tile) end
end
---@param a Vector3
---@param b Vector3
---@param c Vector3
function Surface:Piece(a,b,c)
    local function values(p) return self:Bands(p) end
    local earth,remainder=partition({a,b,c},1,values)
    self:Polygon(earth,"earth")
    if #remainder<3 then return end
    local verge,grass=partition(remainder,2,values)
    self:Polygon(verge,"verge");self:Polygon(grass,"base")
end

---@param a Vector3
---@param b Vector3
---@param c Vector3
---@param detail? boolean false：背景/丘陵只用原三角，不增加顶点
---@param pause? fun()
function Surface:AddTri(a,b,c,detail,pause)
    local center=(a+b+c)/3
    local radius=math.max((a-center):Length(),(b-center):Length(),(c-center):Length())
    local distance=Route.DistanceTo(center)
    if detail==false or distance>22+radius then
        self:Batch("base"):AddTriPlanar(a,b,c,self.tile)
        return
    end
    -- 每个原三角只在本身平面内分片，山地20m原对角线与采样函数完全不变。
    -- 80m源三角最多8²片；20m山地最多2²片；裁切后的窄三角按实际最长边缩减。
    local longest=math.max((b-a):Length(),(c-b):Length(),(a-c):Length())
    local n=math.max(1,math.min(8,math.ceil(longest/14.2)))
    local ab,ac=b-a,c-a
    local function at(i,j) return a+ab*(i/n)+ac*(j/n) end
    for i=0,n-1 do
        for j=0,n-i-1 do
            local p,q,r=at(i,j),at(i+1,j),at(i,j+1)
            self:Piece(p,q,r)
            if j<n-i-1 then self:Piece(q,at(i+1,j+1),r) end
            self.pending=self.pending+2
            if pause and self.pending>=2 then self.pending=0;pause() end
        end
    end
end
---@param pause? fun()
---@return integer, integer
function Surface:Finish(pause)
    local vertices,batches=0,0
    local keys={}
    for key in pairs(self.batches) do keys[#keys+1]=key end
    table.sort(keys)
    -- 顺序固定：同步/协程/重新加载时结果完全一致。
    for _,key in ipairs(keys) do
        local batch=self.batches[key]
        local n=batch:Finish()
        vertices=vertices+n
        if n>0 then batches=batches+1 end
        if pause then pause() end
    end
    return vertices,batches
end
return GroundSurface
