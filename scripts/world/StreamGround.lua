-- 山地基础面独立于精细地表/植被队列；保持20m世界格，不用粗面跨过轨道和桥谷。
-- 基础面低于精细面4cm常驻可见；基础谷底不随装饰/细节取消而消失。
local Mountain = require "world.MountainProfile"
local World = require "world.WorldMaterials"
local Config = require "config.GameConfig"
local Ground = {}
---@type table<string,number>
local heights_ = {}
local count_ = 0

function Ground.Clear()
    heights_,count_ = {},0
end
---@param x number
---@param z number
---@return Vector3
local function point(x,z)
    local key=x.."_"..z
    local y=heights_[key]
    if y==nil then
        y=Mountain.DesignHeight(x,z)
        if count_>=65536 then heights_,count_={},0 end
        heights_[key]=y;count_=count_+1
    end
    return Vector3(x,y-.04,z)
end

---@param owner Node
---@param cellX number
---@param cellZ number
---@param size number
---@param pause? fun()
---@param core? boolean 常驻核心带保留谷底/站基，不依赖尚未完成的桥梁和城镇装饰
---@return integer
function Ground.BuildCell(owner,cellX,cellZ,size,pause,core)
    local batch=World.NewBatch(owner:CreateChild("高速山地基础面"),World.Grassland(),false,10)
    batch.geometry.viewMask=6
    batch.geometry.drawDistance=5200
    local step=assert(Config.MountainTerrain).GridStep or 20
    local x1,z1=(cellX+1)*size,(cellZ+1)*size
    for x=cellX*size,x1-.001,step do
        for z=cellZ*size,z1-.001,step do
            local xx,zz=math.min(x1,x+step),math.min(z1,z+step)
            local a,b,c,d=point(x,z),point(x,zz),point(xx,zz),point(xx,z)
            -- 同一20m对角线，保留低于成品4cm的真实谷底/站基。
            -- 核心仍取Mountain设计高程（桥谷下降、隧道轨基），不是跨谷的轨面平板。
            for _,tri in ipairs({{a,b,c},{a,c,d}}) do
                -- 站基/桥谷装饰可能尚未提交；保留设计高程谷底，不能提前裁出天空洞。
                local pieces={tri}
                for _,piece in ipairs(pieces) do
                    for i=2,#piece-1 do batch:AddTriPlanar(piece[1],piece[i],piece[i+1],10) end
                end
            end
        end
        if pause then pause() end
    end
    return batch:Finish()
end
return Ground
