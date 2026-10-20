-- 完整本地道路车辆；沿用scaffold-3d-scene父子节点所有权，不创建Scene/物理/灯光。
-- 四款UMD2均已CPU逐顶点/端面UV核对：X长轴、+X格栅/前灯、-X尾灯/尾牌、Y向上。
-- 资源库预览的黑色并非交付D颜色；首款仅材质乘炭灰，不修改任何原件。
local Vehicles = {}
---@class RailwayRoadVehicleDefinition
---@field kind string
---@field label string
---@field mesh string
---@field diffuse string
---@field normal string
---@field length number
---@field height number
---@field width number
---@field axleHalf number
---@field tint number
---@field front Vector3
---@field sourceMin Vector3
---@field sourceMax Vector3
---@type RailwayRoadVehicleDefinition[]
local definitions_ = {
    {kind="bus",label="城市公交",length=8.6,height=3.05,width=2.45,axleHalf=2.6,tint=1,front=Vector3.RIGHT,
        sourceMin=Vector3(-.4990234375,-.2353515625,-.2216796875),sourceMax=Vector3(.4990234375,.2353515625,.2216796875),
        mesh="model/971f8f1b-a231-5c7f-b9d9-505fbdc1c029/Meshes/3474fff4d8aa4823ac0c3dba89fd6f0f.mdl",
        diffuse="model/971f8f1b-a231-5c7f-b9d9-505fbdc1c029/Textures/3474fff4d8aa4823ac0c3dba89fd6f0f_00_D.jpg",
        normal="model/971f8f1b-a231-5c7f-b9d9-505fbdc1c029/Textures/3474fff4d8aa4823ac0c3dba89fd6f0f_00_N.jpg"},
    {kind="sedan_dark",label="炭灰轿车",length=4.7,height=1.5,width=1.85,axleHalf=1.35,tint=.24,front=Vector3.RIGHT,
        sourceMin=Vector3(-.4990234375,-.1708984375,-.2392578125),sourceMax=Vector3(.4990234375,.1708984375,.2392578125),
        mesh="model/f17e2264-956a-5fa2-ba41-2287fc02934a/Meshes/3299d6bc46c84215a963d4b7ec4ba7e8.mdl",
        diffuse="model/f17e2264-956a-5fa2-ba41-2287fc02934a/Textures/3299d6bc46c84215a963d4b7ec4ba7e8_00_D.jpg",
        normal="model/f17e2264-956a-5fa2-ba41-2287fc02934a/Textures/3299d6bc46c84215a963d4b7ec4ba7e8_00_N.jpg"},
    {kind="sedan_white",label="白色轿车",length=4.7,height=1.5,width=1.85,axleHalf=1.35,tint=1,front=Vector3.RIGHT,
        sourceMin=Vector3(-.4990234375,-.1494140625,-.2548828125),sourceMax=Vector3(.4990234375,.1494140625,.2548828125),
        mesh="model/e508e3fe-f4ec-5f5b-aa9c-fc1ec818b297/Meshes/08940b701a6448f9a9ef7915c538f36c.mdl",
        diffuse="model/e508e3fe-f4ec-5f5b-aa9c-fc1ec818b297/Textures/08940b701a6448f9a9ef7915c538f36c_00_D.jpg",
        normal="model/e508e3fe-f4ec-5f5b-aa9c-fc1ec818b297/Textures/08940b701a6448f9a9ef7915c538f36c_00_N.jpg"},
    {kind="suv",label="浅色城市SUV",length=4.8,height=1.75,width=1.95,axleHalf=1.4,tint=1,front=Vector3.RIGHT,
        sourceMin=Vector3(-.4990234375,-.2001953125,-.2587890625),sourceMax=Vector3(.4990234375,.2001953125,.2587890625),
        mesh="model/2656d919-1452-50d8-a746-b2ff15a128bb/Meshes/148c7267a4774fe088a752215ae83f81.mdl",
        diffuse="model/2656d919-1452-50d8-a746-b2ff15a128bb/Textures/148c7267a4774fe088a752215ae83f81_00_D.jpg",
        normal="model/2656d919-1452-50d8-a746-b2ff15a128bb/Textures/148c7267a4774fe088a752215ae83f81_00_N.jpg"},
}
---@class RailwayRoadVehicleAsset
---@field model Model
---@field material Material
---@field bounds BoundingBox
---@field scale Vector3
---@field definition RailwayRoadVehicleDefinition
---@type table<string,RailwayRoadVehicleAsset>
local assets_ = {}
---@type table<string,boolean>
local attempted_ = {}
---@param kind? string 无参数保持旧公交调用兼容；未知kind不偷偷换公交。
---@return RailwayRoadVehicleDefinition?
function Vehicles.GetDefinition(kind)
    for _,def in ipairs(definitions_) do if def.kind==(kind or "bus") then return def end end
    return nil
end
function Vehicles.GetDefinitions() return definitions_ end
function Vehicles.GetResourcePaths()
    local paths = {}
    for _,def in ipairs(definitions_) do
        paths[#paths+1]=def.mesh;paths[#paths+1]=def.diffuse;paths[#paths+1]=def.normal
    end
    return paths
end
---@param kind? string
---@return RailwayRoadVehicleAsset?
function Vehicles.GetAsset(kind)
    local def=Vehicles.GetDefinition(kind)
    if not def then return nil end
    if attempted_[def.kind] then return assets_[def.kind] end
    attempted_[def.kind]=true
    local model=cache:GetResource("Model",def.mesh)
    -- 原XML使用uuid纹理；直接重建本地D/N材质，避免失配和额外联网查找。
    local technique=cache:GetResource("Technique","Techniques/PBR/PBRDiffNormal.xml")
    local diffuse=cache:GetResource("Texture2D",def.diffuse)
    local normal=cache:GetResource("Texture2D",def.normal)
    if not model or not technique or not diffuse or not normal then
        print("[RoadVehicles] "..def.label.."完整模型/贴图缺失，不生成色块替身")
        return nil
    end
    local size=model.boundingBox.size
    if math.min(size.x,size.y,size.z)<.001 then return nil end
    local material=Material:new()
    material:SetTechnique(0,technique)
    material:SetTexture(TU_DIFFUSE,diffuse);material:SetTexture(TU_NORMAL,normal)
    material:SetShaderParameter("MatDiffColor",Variant(Color(def.tint,def.tint,def.tint,1)))
    material:SetShaderParameter("Metallic",Variant(.12));material:SetShaderParameter("Roughness",Variant(.59))
    material.occlusion=false
    local asset={model=model,material=material,bounds=model.boundingBox,
        scale=Vector3(def.length/size.x,def.height/size.y,def.width/size.z),definition=def}
    assets_[def.kind]=asset
    print(string.format("[RoadVehicles] %s bbox %.6f/%.6f/%.6f -> %.2f×%.2f×%.2fm；+X车头；%d材质slot",
        def.label,size.x,size.y,size.z,def.length,def.height,def.width,model.numGeometries))
    return asset
end
-- 所有几何slot均设置；不依赖只有slot0的偶然资产布局。
---@param drawable StaticModel
---@param asset RailwayRoadVehicleAsset
function Vehicles.ApplyAsset(drawable,asset)
    drawable.model=asset.model
    for slot=0,asset.model.numGeometries-1 do drawable:SetMaterial(slot,asset.material) end
end
-- 胎底中心贴曲面，源+X绕本地Z随纵坡抬头，yaw再对齐实际行驶方向。
-- 路面占用包络：max宽2.45m <3.5m单车道；不加碰撞体或物理交通。
---@param node Node
---@param surface Vector3
---@param forward Vector3
---@param kind? string
---@return boolean
function Vehicles.Pose(node,surface,forward,kind)
    local asset=Vehicles.GetAsset(kind)
    if not asset then return false end
    local horizontal=math.sqrt(forward.x*forward.x+forward.z*forward.z)
    if horizontal<.001 then return false end
    local yaw=math.deg(math.atan(forward.x,forward.z))-90
    local pitch=math.deg(math.atan(forward.y,horizontal))
    local rotation=Quaternion(yaw,Vector3.UP)*Quaternion(pitch,Vector3.FORWARD)
    local bounds=asset.bounds
    local offset=Vector3(-bounds.center.x*asset.scale.x,-bounds.min.y*asset.scale.y,-bounds.center.z*asset.scale.z)
    node.position=surface+rotation*offset
    node.rotation=rotation;node.scale=asset.scale
    return true
end
---@class RailwayRoadVehicleRecord
---@field node Node
---@field surface Vector3
---@field forward Vector3
---@field kind string
---@field width number
---@field length number
---@field height number
---@class RailwayRoadVehicleBatch
---@field root Node
---@field groups table<string,StaticModelGroup>
---@field instances integer
---@field records RailwayRoadVehicleRecord[]
---@field Add fun(self:RailwayRoadVehicleBatch,surface:Vector3,forward:Vector3,name?:string,kind?:string):boolean
local Batch={}
Batch.__index=Batch
---@param root Node
---@return RailwayRoadVehicleBatch
function Vehicles.NewBatch(root)
    local batch=setmetatable({},Batch)
    batch:Init(root)
    return batch
end
function Batch:Init(root) self.root=root;self.groups={};self.instances=0;self.records={} end
---@param surface Vector3
---@param forward Vector3
---@param name? string
---@param kind? string
---@return boolean
function Batch:Add(surface,forward,name,kind)
    local asset=Vehicles.GetAsset(kind)
    if not asset then return false end
    local def=asset.definition
    local key=def.kind.."_"..math.floor(surface.x/128).."_"..math.floor(surface.z/128)
    local group=self.groups[key]
    if not group then
        local node=self.root:CreateChild("本地车辆实例批_"..key)
        node.position=Vector3(math.floor(surface.x/128)*128+64,0,math.floor(surface.z/128)*128+64)
        group=node:CreateComponent("StaticModelGroup")
        Vehicles.ApplyAsset(group,asset)
        group.viewMask=6;group.castShadows=true;group.shadowDistance=125
        group.drawDistance=850;group.lodBias=.7;group.occluder=false
        self.groups[key]=group
    end
    local node=self.root:CreateChild(name or def.label)
    if not Vehicles.Pose(node,surface,forward,def.kind) then node:Dispose();return false end
    group:AddInstanceNode(node)
    self.instances=self.instances+1
    self.records[#self.records+1]={node=node,surface=surface,forward=forward,kind=def.kind,
        width=def.width,length=def.length,height=def.height}
    return true
end
-- 独立可移动StaticModel池；模型/材质共享，节点绝不加入静态实例组。
-- region/车道状态由RoadCorridor持有；此池只管理可见Node的租借/归还。
---@class RailwayRoadVehicleLease
---@field node Node
---@field drawable StaticModel
---@field kind string
---@field id string
---@field active boolean
---@class RailwayRoadVehiclePool
---@field Init fun(self:RailwayRoadVehiclePool,parent:Node,limit:integer)
---@field root Node
---@field leases RailwayRoadVehicleLease[]
---@field limit integer
---@field created integer
---@field reused integer
---@field active integer
---@field Acquire fun(self:RailwayRoadVehiclePool,id:string,kind:string):RailwayRoadVehicleLease?
---@field Release fun(self:RailwayRoadVehiclePool,lease:RailwayRoadVehicleLease)
---@field Dispose fun(self:RailwayRoadVehiclePool)
local Pool={}
Pool.__index=Pool
---@param parent Node
---@param limit? integer
---@return RailwayRoadVehiclePool
function Vehicles.NewPool(parent,limit)
    local pool=setmetatable({},Pool)
    pool:Init(parent,limit or 64)
    return pool
end
---@param parent Node
---@param limit integer
function Pool:Init(parent,limit)
    self.root=parent:CreateChild("动态双向公路车流池",LOCAL)
    self.leases={};self.limit=limit;self.created=0;self.reused=0;self.active=0
end
---@param id string
---@param kind string
---@return RailwayRoadVehicleLease?
function Pool:Acquire(id,kind)
    local asset=Vehicles.GetAsset(kind)
    if not asset then return nil end
    local lease=nil ---@type RailwayRoadVehicleLease?
    for _,entry in ipairs(self.leases) do
        if not entry.active and entry.kind==kind then lease=entry;break end
    end
    if not lease then
        for _,entry in ipairs(self.leases) do if not entry.active then lease=entry;break end end
    end
    if not lease then
        if #self.leases>=self.limit then return nil end
        local node=self.root:CreateChild(id,LOCAL)
        node.enabled=false
        local drawable=node:CreateComponent("StaticModel")
        drawable.viewMask=6;drawable.castShadows=true;drawable.shadowDistance=125
        drawable.drawDistance=950;drawable.lodBias=.7;drawable.occluder=false
        lease={node=node,drawable=drawable,kind=kind,id=id,active=false} --[[@as RailwayRoadVehicleLease]]
        self.leases[#self.leases+1]=lease;self.created=self.created+1
    else self.reused=self.reused+1 end
    Vehicles.ApplyAsset(lease.drawable,asset)
    lease.node.name=id;lease.node.enabled=false -- 先Pose，再开启；不得闪过旧位置。
    lease.kind=kind;lease.id=id;lease.active=true;self.active=self.active+1
    return lease
end
---@param lease RailwayRoadVehicleLease
function Pool:Release(lease)
    if not lease.active then return end
    lease.node.enabled=false;lease.active=false;lease.id=""
    self.active=math.max(0,self.active-1)
end
function Pool:Dispose()
    for _,lease in ipairs(self.leases) do lease.active=false end
    self.root:Dispose();self.leases={};self.active=0
end
return Vehicles
