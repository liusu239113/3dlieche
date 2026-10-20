-- 独立生成的架空通用驾驶舱；主体、内衬和弧形控制台来自真实 MDL。
-- 六车共用标准舱，不宣称各车型的厂家专用内舱；动态显示/操纵件独立绑定。
local FictionalWorld = require "config.FictionalWorld"
local CabVisualConfig = require "config.CabVisualConfig"
local CabInterior = {}
local CAB_MASK, FLOOR = 8, -1.43
local CAB_MODEL = "model/ce4bf974f7cf4f0fb34b735ae52cfc1c/Meshes/ce4bf974f7cf4f0fb34b735ae52cfc1c.mdl"
local CHAIR_MODEL = "CabDetails/FixedSeatUpper.mdl"
local KINDS={CR400AF="emu",CRH380A="emu",HXD3D="electric",SS9G="electric",DF4D="diesel",blue_white="diesel"}
---@type Scene?
local scene_=nil
---@type Node?
local root_=nil
---@type Node?
local boundLead_=nil
---@type Text3D?
local speedText_=nil
---@type Text3D?
local controlText_=nil
local selectedId_,kind_,visible_,timer_="","diesel",false,0
local visual_=CabVisualConfig.Get(nil)
local offset_=Vector3.ZERO
---@type Material[]
local materials_={}
---@type table<string,Model>
local detailModels_={}

---@param color Color
---@param metal number
---@param rough number
---@param unlit? boolean
---@return Material
local function material(color,metal,rough,unlit)
    local mat=Material()
    mat:SetTechnique(0,assert(cache:GetResource("Technique",unlit and "Techniques/NoTextureUnlit.xml" or "Techniques/PBR/PBRNoTexture.xml")))
    mat:SetShaderParameter("MatDiffColor",Variant(color))
    mat:SetShaderParameter("Metallic",Variant(metal))
    mat:SetShaderParameter("Roughness",Variant(rough))
    materials_[#materials_+1]=mat
    return mat
end

---@param node Node
---@param model Model
---@param mat Material
---@return StaticModel
local function attach(node,model,mat)
    local drawable=node:CreateComponent("StaticModel")
    drawable.model=model
    drawable:SetMaterial(mat)
    drawable.viewMask,drawable.lightMask=CAB_MASK,CAB_MASK
    drawable.castShadows,drawable.drawDistance=false,35
    return drawable
end

-- 少量活动部件使用圆角实体，绝不重新搭建墙体、柜体或方块座椅。
---@param parent Node
---@param name string
---@param position Vector3
---@param size Vector3
---@param mat Material
---@param cylinder? boolean
---@return Node
local function detail(parent,name,position,size,mat,cylinder)
    local key=cylinder and "cylinder" or "rounded"
    if not detailModels_[key] then
        detailModels_[key]=cylinder and CylinderGeometry(.5,.5,1,16):ToModel()
            or RoundedBoxGeometry(1,1,1,2,.12):ToModel()
    end
    local node=parent:CreateChild(name)
    node.position,node.scale=position,size
    attach(node,detailModels_[key],mat)
    return node
end

---@param parent Node
---@param name string
---@param position Vector3
---@param value string
---@param size number
---@param color Color
---@return Text3D
local function text(parent,name,position,value,size,color)
    local node=parent:CreateChild(name)
    node.position,node.scale=position,Vector3.ONE*(size*128/36)
    local label=node:CreateComponent("Text3D")
    label:SetFont("Fonts/MiSans-Regular.ttf",36)
    label.text,label.color=value,color
    label.faceCameraMode,label.fixedScreenSize=FC_NONE,false
    label.viewMask,label.lightMask,label.castShadows,label.drawDistance=CAB_MASK,CAB_MASK,false,25
    label.horizontalAlignment,label.verticalAlignment,label.textAlignment=HA_CENTER,VA_CENTER,HA_CENTER
    return label
end

---@param root Node
local function buildBody(root)
    local mesh=assert(cache:GetResource("Model",CAB_MODEL),"缺少独立驾驶舱 MDL，禁止退回积木舱")
    local mat=Material()
    mat:SetTechnique(0,assert(cache:GetResource("Technique","Techniques/PBR/PBRDiffNormal.xml")))
    mat:SetTexture(TU_DIFFUSE,assert(cache:GetResource("Texture2D","model/ce4bf974f7cf4f0fb34b735ae52cfc1c/Textures/ce4bf974f7cf4f0fb34b735ae52cfc1c_00_D.jpg")))
    mat:SetTexture(TU_NORMAL,assert(cache:GetResource("Texture2D","model/ce4bf974f7cf4f0fb34b735ae52cfc1c/Textures/ce4bf974f7cf4f0fb34b735ae52cfc1c_00_N.png")))
    mat:SetShaderParameter("Metallic",Variant(.05))
    mat:SetShaderParameter("Roughness",Variant(.70))
    materials_[#materials_+1]=mat
    local box=mesh.boundingBox
    local size,center=box.size,box.center
    assert(size.x>.1 and size.y>.1 and size.z>.1,"驾驶舱包围盒无效")
    -- 六角度实渲确认：原始 -X 是前窗，Z 为宽度；+90°绕Y后前窗沿列车+Z。
    local node=root:CreateChild("GeneratedCabBody")
    local scale=Vector3(3.6/size.x,2.3/size.y,2.7/size.z)
    local rotation=Quaternion(90,Vector3.UP)
    local scaledCenter=Vector3(center.x*scale.x,center.y*scale.y,center.z*scale.z)
    node.scale,node.rotation=scale,rotation
    node.position=Vector3(0,FLOOR+1.15,-.60)-rotation*scaledCenter
    attach(node,mesh,mat)
    print(string.format("[CabInterior] 独立主体实测 %.4f×%.4f×%.4f；校正至宽2.70/长3.60/高2.30米，前窗+Z",size.x,size.y,size.z))
end

---@param root Node
---@param x number
---@param z number
local function buildSeat(root,x,z)
    local mesh=assert(cache:GetResource("Model",CHAIR_MODEL))
    local box=mesh.boundingBox
    local size,center=box.size,box.center
    -- 保留座面/扶手/靠背比例，面向前窗+Z；离线去掉五爪轮底后改成固定柱座。
    -- 点云实测源靠背在-X，旋转-90°后椅子前方+X对应舱内+Z。
    local scale=math.min(.65/math.max(size.x,size.z),.78/size.y)
    local rotation=Quaternion(-90,Vector3.UP)
    local seat=root:CreateChild("IndependentSeat")
    seat.scale,seat.rotation=Vector3.ONE*scale,rotation
    seat.position=Vector3(x,FLOOR+.40,z)-rotation*(Vector3(center.x,box.min.y,center.z)*scale)
    local mat=Material()
    mat:SetTechnique(0,assert(cache:GetResource("Technique","Techniques/PBR/PBRDiffNormal.xml")))
    mat:SetTexture(TU_DIFFUSE,assert(cache:GetResource("Texture2D","model/80a31768-83df-5130-a748-31dd300add62/Textures/cf8c3e36a7e24a518e2330f10a56d5cb_00_D.jpg")))
    mat:SetTexture(TU_NORMAL,assert(cache:GetResource("Texture2D","model/80a31768-83df-5130-a748-31dd300add62/Textures/cf8c3e36a7e24a518e2330f10a56d5cb_00_N.jpg")))
    mat:SetShaderParameter("Metallic",Variant(.02))
    mat:SetShaderParameter("Roughness",Variant(.85))
    materials_[#materials_+1]=mat
    attach(seat,mesh,mat)
    local baseMaterial=material(Color(.09,.11,.12),.62,.72)
    detail(root,"固定座椅底盘",Vector3(x,FLOOR+.022,z),Vector3(.36,.044,.36),baseMaterial,true)
    detail(root,"固定座椅支柱",Vector3(x,FLOOR+.22,z),Vector3(.09,.36,.09),baseMaterial,true)
    print(string.format("[CabInterior] 固定座椅：上部四级LOD保留，统一scale %.3f，柱座落地/前向+Z，无办公椅脚轮",scale))
end

---@param root Node
local function buildControls(root)
    buildBody(root)
    buildSeat(root,-.62,-1.65)
    buildSeat(root,.65,-1.65)
    local dark=material(Color(.03,.043,.05),.04,.8)
    local metal=material(Color(.47,.50,.53),.72,.4)
    local traction=material(visual_.accent,0,visual_.plastic)
    local brake=material(visual_.warning,0,visual_.plastic)
    local screen=material(Color(visual_.screen.r*.035,visual_.screen.g*.035,visual_.screen.b*.035),0,1,true)
    -- 贴在生成控制台的独立屏面上，不新造第二张桌子；文字为实时世界实体。
    local left=root:CreateChild("LiveSpeedDisplay")
    left.position=Vector3(-.62,-.48,-.09)
    left.rotation=Quaternion(-35,Vector3.UP)*Quaternion(55,Vector3.RIGHT)
    detail(left,"显示面",Vector3.ZERO,Vector3(.48,.22,.012),screen)
    speedText_=text(left,"速度数字",Vector3(0,.021,-.009),"000 km/h",.048,visual_.screen)
    text(left,"速度说明",Vector3(0,-.060,-.009),"实际速度",.018,Color(.58,.71,.71))
    local right=root:CreateChild("LiveControlDisplay")
    right.position=Vector3(.61,-.48,-.09)
    right.rotation=Quaternion(35,Vector3.UP)*Quaternion(55,Vector3.RIGHT)
    detail(right,"显示面",Vector3.ZERO,Vector3(.48,.22,.012),screen)
    controlText_=text(right,"牵引制动数字",Vector3(0,0,-.009),"牵引 0\n制动 0%",.031,visual_.screen)
    -- 保留真实舱体的仪表和驾驶台，不再叠加中央方盒、状态盒或程序化操纵杆。
    -- 这些附加几何会挡住参考图中的前窗视野，运行控制仍由 HUD 完成。
    text(root,"架空车型铭牌",Vector3(.65,-.90,-.39),FictionalWorld.trainNames[selectedId_] or FictionalWorld.trainNames.blue_white,.028,Color(.70,.75,.74))
    local lamp=root:CreateChild("CabLight")
    lamp.position=Vector3(0,.62,-.65)
    local light=lamp:CreateComponent("Light")
    light.lightType,light.color=LIGHT_POINT,visual_.cabinLight
    light.range,light.brightness,light.castShadows,light.lightMask=4.0,2.5,false,CAB_MASK
end

-- 场景根独立于旧车辆：换车先释放车体也不会留下失效子节点引用。
function CabInterior.Dispose()
    speedText_,controlText_=nil,nil
    if root_ then root_:Dispose();root_=nil end
    for _,mat in ipairs(materials_) do mat:Dispose() end
    materials_={}
    boundLead_,scene_,selectedId_,visible_,timer_=nil,nil,"",false,0
    offset_=Vector3.ZERO
    visual_=CabVisualConfig.Get(nil)
end

---@param scene Scene
---@param lead Node
---@param selectedId string
---@param cabOffset Vector3
function CabInterior.Ensure(scene,lead,selectedId,cabOffset)
    if root_ and scene_==scene and boundLead_==lead and selectedId_==selectedId and (offset_-cabOffset):LengthSquared()<.000001 then return end
    CabInterior.Dispose()
    scene_,boundLead_,selectedId_,offset_=scene,lead,selectedId,cabOffset
    kind_=KINDS[selectedId] or "diesel"
    visual_=CabVisualConfig.Get(selectedId)
    root_=scene:CreateChild("GeneratedCab_"..selectedId)
    root_.enabled=false
    local ok,message=xpcall(function() buildControls(assert(root_)) end,debug.traceback)
    if not ok then CabInterior.Dispose();error("[CabInterior] 独立内舱加载失败："..tostring(message)) end
    root_.worldPosition,root_.worldRotation=lead:LocalToWorld(cabOffset),lead.worldRotation
    print("[CabInterior] 架空通用舱接入："..(FictionalWorld.trainNames[selectedId] or selectedId).."；旧方块主体/柜体/座椅已移除")
end

---@param visible boolean
function CabInterior.SetVisible(visible)
    visible_=visible
    if root_ then root_.enabled=visible end
end
---@return boolean
function CabInterior.IsVisible() return visible_ and root_~=nil end
---@return Node?
function CabInterior.GetRoot() return root_ end
---@return string
function CabInterior.GetKind() return kind_ end

---@param mode string
---@return Vector3,number,number
function CabInterior.GetView(mode)
    if mode=="cab_window" then return Vector3(-1.08,.02,-.45),-82,-1 end
    if mode=="copilot" then return Vector3(.64,0,-1.35),-14,5 end
    if mode=="instruments" then return Vector3(0,.12,-1.10),0,24 end
    return Vector3(-.48,0,-1.35),16,5
end

---@return {modelPath:string,sharedStandard:boolean,bodyCount:integer,seats:integer,legacyBodyCount:integer}
function CabInterior.GetDiagnostics()
    return {modelPath=CAB_MODEL,sharedStandard=true,bodyCount=root_ and 1 or 0,seats=root_ and 2 or 0,legacyBodyCount=0}
end

---@param lead Node
---@param dt number
---@param speedKmh number
---@param throttle number
---@param maxThrottle number
---@param brake number
---@param reversing boolean
function CabInterior.Update(lead,dt,speedKmh,throttle,maxThrottle,brake,reversing)
    if not root_ or not visible_ or lead~=boundLead_ then return end
    root_.worldPosition,root_.worldRotation=lead:LocalToWorld(offset_),lead.worldRotation
    timer_=timer_+math.max(0,dt)
    if timer_<.20 then return end
    timer_=timer_%.20
    local speedValue=string.format("%03d km/h",math.floor(math.abs(speedKmh)+.5))
    local controlValue=string.format("牵引 %d\n制动 %d%%%s",math.floor(throttle),math.floor(Clamp(brake,0,1)*100+.5),reversing and " 倒" or "")
    if speedText_ and speedText_.text~=speedValue then speedText_.text=speedValue end
    if controlText_ and controlText_.text~=controlValue then controlText_.text=controlValue end
end

return CabInterior
