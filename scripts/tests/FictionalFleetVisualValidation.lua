-- 六车架空车壳真实视觉验收，基于3D scene scaffold；不导入旧测试/main/世界/HUD。
-- 主线程统一build后串行运行本入口：-x 1280 -y 720（参数和值分开）。
-- 首图至少120真实帧；每次切case后至少30帧；readback后保持原Scene/镜头2帧。
-- 恰好12图：各车型nose完整头车与side；动车side同时展示头车与实际中间车。
-- side双车为明确标记的独立资产并排检视，不冒充完整八节运营编组。
local Catalog = require "config.TrainCatalog"
local FictionalWorld = require "config.FictionalWorld"
local RollingStock = require "train.RollingStock"
local Locomotive = require "train.Locomotive"
local Connections = require "train.EMUConnections"

---@class FictionalFleetCase
---@field id string
---@field name string
---@field view string
---@field output string
---@type FictionalFleetCase[]
local cases_ = {}
---@type Scene?
local scene_ = nil
---@type Node?
local cameraNode_ = nil
---@type Camera?
local camera_ = nil
---@type Node?
local preview_ = nil
---@type Text3D?
local title_ = nil
---@type Material[]
local ownedMaterials_ = {}
---@type Image?
local image_ = nil
local frame_, caseStart_, index_, captures_, hold_, captureFrame_, lastRender_ = 0,0,0,0,0,-1,-1
local stage_, failed_, complete_ = "bootstrap",false,false
local frozenEye_, frozenDirection_ = Vector3.ZERO,Vector3.FORWARD
local checksums_ = {} ---@type table<string, boolean>
local OUTPUT = "/workspace/screenshots/"

local function guard(action)
    if failed_ or complete_ then return end
    local ok, message = xpcall(action, debug.traceback)
    if not ok then
        failed_ = true
        print(string.format("ALL_FICTIONAL_FLEET_VISUAL_FAILED screenshots=%d/12 case=%d frame=%d stage=%s",captures_,index_,frame_,stage_))
        log:Write(LOG_ERROR,tostring(message))
        error(message,0)
    end
end

---@param color Color
---@return Material
local function solid(color)
    local mat = Material:new()
    mat:SetTechnique(0,assert(cache:GetResource("Technique","Techniques/PBR/PBRNoTexture.xml")))
    mat:SetShaderParameter("MatDiffColor",Variant(color))
    mat:SetShaderParameter("Roughness",Variant(.72))
    ownedMaterials_[#ownedMaterials_+1] = mat
    return mat
end

-- 不加载LightGroup：检视fixture需固定纯色环境与曝光，避免预设色偏改变涂装判断。
local function ensureScene()
    scene_ = Scene() -- 模块级强持有，直到Stop；禁止局部Scene被GC。
    local scene = assert(scene_)
    scene:CreateComponent("Octree")
    local zone = scene:CreateComponent("Zone")
    zone.boundingBox = BoundingBox(Vector3(-500,-500,-500),Vector3(500,500,500))
    zone.ambientSource, zone.ambientColor = AMBIENT_COLOR,Color(.40,.41,.43)
    zone.fogColor, zone.fogStart, zone.fogEnd = Color(.12,.16,.20),350,450
    zone.tonemapMode, zone.autoExposureEnabled = TONEMAP_MODE_ACES,false
    local sunNode = scene:CreateChild("检视固定主光")
    sunNode.direction = Vector3(.30,-.8,.40)
    local sun = sunNode:CreateComponent("Light")
    sun.lightType, sun.color, sun.brightness, sun.castShadows = LIGHT_DIRECTIONAL,Color(1,.97,.92),1.35,false
    cameraNode_ = scene:CreateChild("检视固定相机")
    camera_ = assert(cameraNode_):CreateComponent("Camera")
    local camera = assert(camera_)
    camera.nearClip, camera.farClip, camera.fov, camera.viewMask, camera.lodBias = .1,450,48,1,4
    renderer.hdrRendering = true
    renderer:SetViewport(0,Viewport:new(scene,camera))
    local floor = scene:CreateChild("无世界成本检视地板")
    -- Box为1米模型；测试地板仅薄板，不创建物理碰撞。
    floor.position, floor.scale = Vector3(0,-.10,0),Vector3(100,.20,130)
    local model = floor:CreateComponent("StaticModel")
    model.model, model.material, model.castShadows = assert(cache:GetResource("Model","Models/Box.mdl")),solid(Color(.18,.22,.25)),false
    local titleNode = assert(cameraNode_):CreateChild("架空车名Text3D")
    titleNode.position, titleNode.scale = Vector3(0,3.05,8),Vector3.ONE*.78
    title_ = titleNode:CreateComponent("Text3D")
    local title = assert(title_)
    assert(title:SetFont("Fonts/MiSans-Regular.ttf",36),"车名字体不可加载")
    title.faceCameraMode, title.fixedScreenSize, title.viewMask = FC_NONE,false,1
    title.horizontalAlignment, title.verticalAlignment, title.textAlignment = HA_CENTER,VA_CENTER,HA_CENTER
    title.color = Color(.92,.90,.76)
    for _,entry in ipairs(Catalog.Entries) do
        local code = assert(FictionalWorld.trainCodes[entry.id])
        cases_[#cases_+1] = {id=entry.id,name=entry.name,view="nose",output="fictional_fleet_"..code.."_nose"}
        cases_[#cases_+1] = {id=entry.id,name=entry.name,view="side",output="fictional_fleet_"..code.."_side"}
    end
    assert(#cases_==12,"必须恰好六车型十二图")
end

---@param node Node
---@param id string
local function checkTextures(node,id)
    local asset = assert(Catalog.Assets[id])
    assert(asset.diffusePath:find("FictionalLiveries/",1,true)==1,"D未接入架空派生资产")
    assert(asset.normalPath:find("FictionalLiveries/",1,true)==1,"N未接入架空派生资产")
    local draws = node:GetComponents("StaticModel",true)
    assert(#draws>0,"真实车壳没有StaticModel")
    for _,draw in ipairs(draws) do
        assert(draw.enabled and draw.model and draw.model.numGeometries>0,"真实车壳隐藏或模型为空")
        for slot=0,draw.numGeometries-1 do
            local mat = assert(draw:GetMaterial(slot),"车壳材质槽为空")
            local diffuse,normal = assert(mat:GetTexture(TU_DIFFUSE)),assert(mat:GetTexture(TU_NORMAL))
            if id=="HXD3D" and draw.node.name=="BodyShellRepair" then
                assert(diffuse.name=="FictionalLiveries/Leisun_E32_patch_D.png"
                    and normal.name=="FictionalLiveries/Leisun_E32_patch_N.png","E32局部原创补片材质错配")
            else
                assert(diffuse.name==asset.diffusePath and normal.name==asset.normalPath,"真实车壳D/N与Catalog派生路径不一致")
            end
        end
    end
end

---@param parent Node
---@param profile string
---@param number string
local function emuIdentity(parent,profile,number)
    local p = assert(Catalog.Profiles[profile])
    local mat = Connections.CreateIdentityMaterial()
    ownedMaterials_[#ownedMaterials_+1] = mat
    local car = {node=parent,offset=parent.position.z,pivot=p.pivot,bogies={},length=p.length,
        profile=profile,reverse=false,number=number,service="trailer",
        frontEnd=RollingStock.GetConnectionEnd(profile,"front",false),
        rearEnd=RollingStock.GetConnectionEnd(profile,"rear",false)} --[[@as TrainCar]]
    Connections.BuildIdentity(car,mat)
end

local function activate(nextIndex)
    assert(nextIndex==1 or hold_==2,"截图后未hold2便换case")
    if preview_ then preview_:Dispose();preview_=nil end
    index_, hold_, stage_ = nextIndex,0,"setup"
    local case = assert(cases_[index_])
    local entry = assert(Catalog.Find(case.id))
    local root = assert(scene_):CreateChild("架空车壳检视_"..FictionalWorld.trainCodes[case.id])
    preview_ = root
    Locomotive.SetCabView(false)
    local head = root:CreateChild("实际头车")
    Locomotive.Build(head,entry.head)
    checkTextures(head,entry.head)
    local length = Locomotive.GetLength(entry.head)
    local headDrawable = assert(head:GetComponent("StaticModel",true))
    local height = assert(headDrawable.model).boundingBox.max.y
    local totalLength = length
    local target = Vector3(0,height*.44,0)
    if entry.kind=="emu" then emuIdentity(head,entry.head,"01") end
    if case.view=="side" and entry.kind=="emu" then
        local middleId = assert(entry.middle)
        local middleProfile = assert(Catalog.Profiles[middleId])
        -- 头车/中间车沿直线分离一米：完整可见、无虚假风挡，不改变生产编组。
        head.position = Vector3(0,0,length*.5+.5)
        local middle = root:CreateChild("实际中间车")
        middle.position = Vector3(0,0,-middleProfile.length*.5-.5)
        RollingStock.Build(middle,middleId)
        checkTextures(middle,middleId)
        emuIdentity(middle,middleId,"02")
        totalLength = length+middleProfile.length+1
        target = Vector3(0,height*.44,(length-middleProfile.length)*.5)
    end
    local node,camera = assert(cameraNode_),assert(camera_)
    if case.view=="nose" then
        -- 三分之四前视也必须容纳整车，不能以鼻端特写冒充全车标识检查。
        node.position = target+Vector3(-length*.84,height*.60,length*.70)
    else
        node.position = target+Vector3(totalLength*.96,height*.45,-totalLength*.04)
    end
    node:LookAt(target)
    camera.fov = 48
    -- 根据真实模型BBox角点投影自动后退；完整包络保持5%画面边距。
    for attempt=1,12 do
        local fits = true
        for _,draw in ipairs(root:GetComponents("StaticModel",true)) do
            local b = assert(draw.model).boundingBox
            for _,x in ipairs({b.min.x,b.max.x}) do for _,y in ipairs({b.min.y,b.max.y}) do for _,z in ipairs({b.min.z,b.max.z}) do
                local screen = camera:WorldToScreenPoint(draw.node:LocalToWorld(Vector3(x,y,z)))
                fits = fits and screen.x>.055 and screen.x<.945 and screen.y>.13 and screen.y<.93
            end end end
        end
        if fits then break end
        assert(attempt<12,"实际车壳无法完整装入镜头")
        node.position = target+(node.position-target)*1.10
    end
    frozenEye_, frozenDirection_ = node.worldPosition,node.worldDirection
    assert(title_).text = case.name.." · "..(case.view=="nose" and "完整头车前视" or (entry.kind=="emu" and "头车 / 中间车侧视" or "完整机车侧视"))
    caseStart_, stage_ = frame_,"settle"
    print(string.format("[架空车队视觉] CASE %d/12 %s realSize=%dx%d frame=%d",index_,case.name,graphics:GetWidth(),graphics:GetHeight(),frame_))
end

local function identity()
    local viewport = assert(renderer:GetViewport(0))
    assert(viewport.scene==scene_ and viewport.camera==camera_,"截图实际Scene/Camera跨case")
    local node = assert(cameraNode_)
    assert((node.worldPosition-frozenEye_):Length()<.00001 and (node.worldDirection-frozenDirection_):Length()<.00001,"截图镜头漂移")
    assert(preview_ and preview_.enabled and title_ and title_.text:find(cases_[index_].name,1,true)==1,"真实车壳/架空Text3D身份丢失")
    assert(renderer.numPrimitives>100 and renderer.numBatches>2,"真实车壳尚未渲染")
end

local function capture()
    if stage_=="setup" or lastRender_==frame_ then return end
    lastRender_ = frame_
    if stage_=="hold" then
        assert(frame_>captureFrame_,"同帧重复算hold")
        identity();hold_=hold_+1
        if hold_==2 then
            if image_ then image_:Dispose();image_=nil end
            if index_==12 then
                assert(captures_==12,"真实PNG不是十二张")
                complete_=true
                print(string.format("ALL_FICTIONAL_FLEET_VISUAL_PASS screenshots=12 frame=%d",frame_))
                print("[架空车队视觉] PASS仅证明真实车壳/派生材质/架空车名/PNG链路；现实标识与修补美术效果须人工查看十二张PNG。")
            else stage_="advance" end
        end
        return
    end
    if stage_~="settle" or frame_<120 or frame_-caseStart_<30 then return end
    identity()
    local image = Image();image_=image
    assert(graphics:TakeScreenShot(image),"实际帧readback失败")
    local path = OUTPUT..cases_[index_].output..".png"
    assert(image:SavePNG(path),"真实车壳PNG未保存")
    local decoded = Image()
    assert(decoded:Load(path) and decoded.width==graphics:GetWidth() and decoded.height==graphics:GetHeight(),"PNG解码/分辨率错误")
    local lo,hi = math.huge,-math.huge
    for y=1,8 do for x=1,12 do
        local p = decoded:GetPixel(math.floor(decoded.width*x/13),math.floor(decoded.height*y/9))
        local light = p.r*.2126+p.g*.7152+p.b*.0722
        lo,hi=math.min(lo,light),math.max(hi,light)
    end end
    assert(hi-lo>.045 and hi>.10,"真实截图全黑或单色")
    local file = File(path,FILE_READ)
    assert(file:IsOpen() and file:GetSize()>1000,"PNG文件为空")
    local checksum = tostring(file:GetChecksum())
    assert(not checksums_[checksum],"不同case保存同一旧截图")
    checksums_[checksum]=true
    decoded:Dispose();file:Dispose();identity()
    captures_,captureFrame_,hold_,stage_ = captures_+1,frame_,0,"hold"
    print(string.format("[架空车队视觉] REAL_SCREENSHOT %d/12 %s frame=%d",captures_,path,frame_))
end

function Start()
    guard(function()
        assert(graphics:GetWidth()==1280 and graphics:GetHeight()==720,"请使用分开的CLI参数 -x 1280 -y 720")
        if not fileSystem:DirExists(OUTPUT) then assert(fileSystem:CreateDir(OUTPUT)) end
        ensureScene();activate(1)
        SubscribeToEvent("Update","HandleFictionalFleetUpdate")
        SubscribeToEvent("EndRendering","HandleFictionalFleetCapture")
        print("[架空车队视觉] 独立检视已启动；未执行main/全逻辑/World/UI测试。")
    end)
end
---@param eventType string
---@param eventData UpdateEventData
function HandleFictionalFleetUpdate(eventType,eventData)
    guard(function()
        frame_=frame_+1
        assert(frame_<600,"十二图未在600真实帧预算内完成")
        if stage_=="advance" then activate(index_+1) end
    end)
end
---@param eventType string
---@param eventData EndRenderingEventData
function HandleFictionalFleetCapture(eventType,eventData) guard(capture) end
function Stop()
    UnsubscribeFromEvent("Update");UnsubscribeFromEvent("EndRendering")
    if not complete_ and not failed_ then
        print(string.format("ALL_FICTIONAL_FLEET_VISUAL_FAILED incomplete screenshots=%d/12 frame=%d",captures_,frame_))
    end
    if image_ then image_:Dispose();image_=nil end
    if scene_ then scene_:Dispose();scene_=nil end
    for _,mat in ipairs(ownedMaterials_) do mat:Dispose() end
    ownedMaterials_={};cameraNode_,camera_,preview_,title_=nil,nil,nil,nil
end
