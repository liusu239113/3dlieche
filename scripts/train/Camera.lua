-- 列车相机：保留ThirdPersonCamera外景库，16个真实空间机位及独立模型驾驶舱。
-- 基于现有Camera/场景脚手架；只拥有相机与内舱，不修改列车、UI、线路或共享配置。
local GameConfig = require "config.GameConfig"
local Route = require "world.Route"
local Locomotive = require "train.Locomotive"
local Train = require "train.Train"
local CabInterior = require "train.CabInterior"
local ThirdPersonCamera = require "urhox-libs.Camera.ThirdPersonCamera"

local Camera = {}
local CFG = GameConfig.Camera
local ENVIRONMENT_MASK = 4 -- 站台/站房/雨棚/桥障碍层；轨道细网格、植被及标牌不参与净空射线。
local EXTERIOR_MASK = 7
local INTERIOR_MASK = 15

---@class TrainCameraPreset
---@field id string
---@field name string
---@field kind string cab|orbit|fixed|track
---@field car string head|middle|tail|wheel
---@field distance number
---@field height number
---@field yaw number
---@field pitch number
---@field fov number

-- 每项独立选择目标车厢、眼点、追踪方式、焦距和朝向；不是16个名字共用三套机位。
---@type TrainCameraPreset[]
local PRESETS = {
    {id="cab",name="司机驾驶位",kind="cab",car="head",distance=0,height=0,yaw=16,pitch=5,fov=66},
    {id="cab_window",name="司机侧窗",kind="cab",car="head",distance=0,height=0,yaw=-82,pitch=-1,fov=72},
    {id="copilot",name="副司机席",kind="cab",car="head",distance=0,height=0,yaw=-14,pitch=5,fov=65},
    {id="instruments",name="仪表近景",kind="cab",car="head",distance=0,height=0,yaw=0,pitch=24,fov=56},
    {id="front_chase",name="前追车头",kind="orbit",car="head",distance=34,height=2.65,yaw=150,pitch=4,fov=57},
    {id="chase",name="后追编组",kind="orbit",car="tail",distance=44,height=2.4,yaw=18,pitch=8,fov=61},
    {id="side",name="左侧编组",kind="orbit",car="middle",distance=34,height=2.1,yaw=90,pitch=8,fov=62},
    {id="side_right",name="右侧编组",kind="orbit",car="middle",distance=39,height=2.3,yaw=-90,pitch=12,fov=60},
    {id="roof",name="头车顶观察",kind="orbit",car="head",distance=9,height=4.45,yaw=0,pitch=48,fov=57},
    {id="birdseye",name="全编组鸟瞰",kind="orbit",car="middle",distance=340,height=2.0,yaw=90,pitch=48,fov=60},
    {id="tail",name="尾车端部",kind="orbit",car="tail",distance=6,height=1.8,yaw=0,pitch=4,fov=63},
    {id="wheels",name="车轮近察",kind="orbit",car="wheel",distance=2.7,height=.80,yaw=90,pitch=5,fov=49},
    {id="trackside",name="轨旁定点",kind="fixed",car="head",distance=0,height=1.9,yaw=0,pitch=0,fov=55},
    {id="platform",name="站台固定",kind="fixed",car="middle",distance=0,height=3.06,yaw=0,pitch=0,fov=64},
    {id="track_front",name="前方轨道",kind="track",car="head",distance=0,height=.96,yaw=0,pitch=-2,fov=73},
    {id="distant",name="跟车远景",kind="orbit",car="middle",distance=360,height=2.5,yaw=-75,pitch=28,fov=58},
}
---@type table<string, TrainCameraPreset>
local byId_ = {}
for _, preset in ipairs(PRESETS) do byId_[preset.id] = preset end
-- 保持历史chase/side/cab原名；也接受面向功能的别名，不额外增加GetPresets条目。
local ALIASES = {driver="cab",driver_window="cab_window",co_driver="copilot",instrument="instruments",
    rear_chase="chase",left_side="side",right_side="side_right",head_roof="roof",
    birds_eye="birdseye",wheel="wheels",rail_front="track_front",long_chase="distant"}

---@type ThirdPersonCameraInstance|nil
local follow_ = nil
---@type Scene|nil
local scene_ = nil
---@type Node|nil
local target_ = nil
---@type Octree|nil
local octree_ = nil
---@type Node|nil
local node_ = nil
---@type Camera|nil
local camera_ = nil
---@type Node|nil
local lead_ = nil
---@type Node|nil
local fixedAnchor_ = nil
local selectedId_ = ""
local mode_ = "chase"
local yawOffset_ = 18.0
local pitch_ = 8.0
local sightDistance_ = 0.0
local snap_ = true
local fixedPending_ = true
local orbitSlot_ = "orbit_a"
local configuredDistance_ = -1.0
local configuredFov_ = -1.0
local probeTimer_ = 1.0
local probeValid_ = false
local probeAim_ = Vector3.ZERO
local probeDesired_ = Vector3.ZERO
local probeSafe_ = 0.0
local lastPosition_ = Vector3.ZERO
local lastPositionValid_ = false
local rayCount_ = 0
local obstructionLogged_ = false

---@return TrainCameraPreset
local function currentPreset() return assert(byId_[mode_]) end

--- 动态查找接口，允许主线程稍后新增GetTrackSample；返回值契约与Route.Sample相同。
---@param s number
---@return Vector3, Vector3, number
local function trackSample(s)
    local sampler = Train["GetTrackSample"] --[[@as fun(s:number):Vector3,Vector3,number]]
    if sampler then return sampler(s) end
    return Route.Sample(s)
end

---@param key string
---@return TrainCar|nil, integer
local function selectCar(key)
    local cars = Train.GetCars()
    local count = #cars
    local index = key=="tail" and math.max(1,count) or (key=="middle" and math.max(1,math.floor((count+1)*.5))
        or (key=="wheel" and math.max(1,math.min(2,count)) or 1))
    return cars[index], index
end

---@param aim Vector3
---@param direction Vector3
---@param distance number
---@return number
local function trace(aim, direction, distance)
    if not octree_ or distance<.001 then return distance end
    rayCount_ = rayCount_+1
    local hit = octree_:RaycastSingle(Ray(aim,direction),RAY_TRIANGLE,distance+.34,
        DRAWABLE_GEOMETRY,ENVIRONMENT_MASK)
    return hit.drawable and math.max(.025,hit.distance-.34) or distance
end

-- 净空设计（不是车辆物理）：
-- 列车mask=1（不探测自身），站台/站房/雨棚可见mask=6、障碍mask=4；内舱mask=8且外景禁用。
--                 上缘探针
--     目标 * ===== 中心线 ===== 相机
--                 左缘/右下缘探针（近裁剪面半径0.30米）
-- 中心射线在位置变化时立即检测；三条边缘探针50ms节流，累计移动>0.30米立即重测。
-- 缓存期间扣除两端总位移，不允许沿过期净空向外扩张；相机位移另做扫掠，防止横向穿墙。
-- 切换/换车/传送强制重测，不把合并网格巨大AABB误当实心墙，不做每帧9条三角射线。
---@param aim Vector3
---@param desired Vector3
---@param dt number
---@param force boolean
---@return Vector3
local function constrainSight(aim, desired, dt, force)
    local delta = desired-aim
    local distance = delta:Length()
    if distance<.001 or not octree_ then sightDistance_=distance; return desired end
    local direction = delta/distance
    local aimChange = (aim-probeAim_):Length()
    local desiredChange = (desired-probeDesired_):Length()
    local changed = force or not probeValid_ or aimChange+desiredChange>.00001
    probeTimer_ = probeTimer_+math.max(0,dt)
    local safe = distance
    if changed then safe = math.min(safe,trace(aim,direction,distance)) end
    local mustProbe = force or not probeValid_ or aimChange+desiredChange>.30 or (changed and probeTimer_>=.05)
    if mustProbe then
        local rightCross = direction:CrossProduct(Vector3.UP)
        local right = rightCross:LengthSquared()>.00001 and rightCross:Normalized() or Vector3.RIGHT
        local up = right:CrossProduct(direction):Normalized()
        local rimSafe = distance
        for _, rim in ipairs({up*.30,right*.30-up*.15,-right*.30-up*.15}) do
            rimSafe = math.min(rimSafe,trace(aim+rim,direction,distance))
        end
        probeAim_, probeDesired_, probeSafe_, probeValid_, probeTimer_ = aim,desired,math.min(safe,rimSafe),true,0
        safe = math.min(safe,rimSafe)
    else
        -- 不外推上一帧的障碍距离；移动量作为保守安全余量，到下一次实测才释放。
        safe = math.min(safe,math.max(.025,probeSafe_-aimChange-desiredChange))
    end
    local candidate = aim+direction*math.min(distance,safe)
    if lastPositionValid_ and not force then
        local motion = candidate-lastPosition_
        local motionLength = motion:Length()
        if motionLength>.001 then
            local allowed = trace(lastPosition_,motion/motionLength,motionLength)
            if allowed<motionLength then
                -- 横向扫掠命中：只有"向外扩张"才保留上次安全位置，避免相机沿墙面穿出。
                -- 环视/向内移动必须接受中心射线已验证的位置，否则站台雨棚下会完全转不动。
                local candidateDistance = (candidate-aim):Length()
                local lastDistance = (lastPosition_-aim):Length()
                if candidateDistance>lastDistance+.05 then candidate = lastPosition_ end
            end
        end
    end
    sightDistance_ = (candidate-aim):Length()
    if sightDistance_<distance-.15 and not obstructionLogged_ then
        print(string.format("[Camera] %s环境净空 %.1f -> %.1fm",mode_,distance,sightDistance_))
        obstructionLogged_ = true
    elseif sightDistance_>=distance-.15 then obstructionLogged_=false end
    return candidate
end

local function invalidate()
    probeValid_, probeTimer_, lastPositionValid_, snap_ = false,1,false,true
end

---@param fov number
local function setFov(fov)
    if not camera_ then return end
    local width,height = graphics:GetWidth(),graphics:GetHeight()
    if width>0 and height>width then
        local halfFov = math.rad(fov*.5)
        camera_.fov = math.min(100,math.deg(2*math.atan(math.tan(halfFov)*(16/9)*height/width)))
    else camera_.fov=fov end
end

---@param distance number
---@param fov number
local function configureOrbit(distance, fov)
    if not follow_ then return end
    if snap_ or math.abs(distance-configuredDistance_)>.025 or math.abs(fov-configuredFov_)>.025 then
        -- 库公开SetModeConfig只改配置；双槽触发真实模式切换，避免读取/改动库私有插值状态。
        orbitSlot_ = orbitSlot_=="orbit_a" and "orbit_b" or "orbit_a"
        follow_:SetModeConfig(orbitSlot_,{distance=math.max(.025,distance),offset=Vector3.ZERO,fov=fov})
        follow_:SetMode(orbitSlot_)
        configuredDistance_,configuredFov_ = distance,fov
    end
end

---@param scene Scene
function Camera.Build(scene)
    Camera.Shutdown()
    scene_ = scene
    follow_ = ThirdPersonCamera.Create(scene,{
        modes={orbit_a={distance=44,offset=Vector3.ZERO,fov=61},orbit_b={distance=44,offset=Vector3.ZERO,fov=61}},
        initialMode="orbit_a",transitionSpeed=12,nearClip=.12,farClip=math.min(CFG.FarClip or 2400,2400),
        minDistance=.025,collisionMask=ENVIRONMENT_MASK,
    })
    target_, fixedAnchor_ = scene:CreateChild("CameraTarget"),scene:CreateChild("CameraFixedAnchor")
    octree_,node_,camera_ = scene:GetComponent("Octree"),follow_:GetNode(),follow_:GetCamera()
    camera_.viewMask = EXTERIOR_MASK
    mode_,selectedId_,lead_,configuredDistance_,configuredFov_ = "front_chase","",nil,-1,-1
    Camera.ResetView()
    Locomotive.SetCabView(false)
    renderer:SetViewport(0,Viewport:new(scene,camera_))
    renderer.hdrRendering = true
    print("[Camera] 16实体机位就绪：ThirdPersonCamera外景/实体内舱/固定机位/节流净空")
end

function Camera.Shutdown()
    CabInterior.Dispose()
    Locomotive.SetCabView(false)
    if node_ then node_:Dispose() end
    if target_ then target_:Dispose() end
    if fixedAnchor_ then fixedAnchor_:Dispose() end
    follow_,scene_,target_,fixedAnchor_,octree_,node_,camera_,lead_ = nil,nil,nil,nil,nil,nil,nil,nil
    selectedId_,sightDistance_ = "",0
    invalidate()
end

---@return Node|nil
function Camera.GetNode() return node_ end
---@return Camera|nil
function Camera.GetCamera() return camera_ end
---@return number
function Camera.GetSightDistance() return sightDistance_ end
---@return string
function Camera.GetMode() return mode_ end
---@return string
function Camera.GetModeName() return currentPreset().name end
---@return {id:string,name:string}[]
function Camera.GetPresets()
    local result = {}
    for _, preset in ipairs(PRESETS) do result[#result+1]={id=preset.id,name=preset.name} end
    return result
end
---@return boolean
function Camera.IsCabView() return currentPreset().kind=="cab" end
---@return {mode:string,carIndex:integer,raycasts:integer,cabVisible:boolean,fixed:boolean,yaw:number,pitch:number}
function Camera.GetDiagnostics()
    local _,index = selectCar(currentPreset().car)
    return {mode=mode_,carIndex=index,raycasts=rayCount_,cabVisible=CabInterior.IsVisible(),fixed=currentPreset().kind=="fixed",
        yaw=yawOffset_,pitch=pitch_}
end

---@param name string
---@return boolean
function Camera.SetMode(name)
    local id = ALIASES[name] or name
    if not byId_[id] then return false end
    mode_ = id
    Camera.ResetView()
    local cab = Camera.IsCabView()
    CabInterior.SetVisible(cab)
    Locomotive.SetCabView(cab)
    if camera_ then camera_.viewMask = cab and INTERIOR_MASK or EXTERIOR_MASK end
    print("[Camera] 机位 -> "..Camera.GetModeName().." ("..id..")")
    return true
end

---@param reverse? boolean|number true或负数向前一项，默认向后一项
---@return string
function Camera.CycleMode(reverse)
    local step = (reverse==true or (type(reverse)=="number" and reverse<0)) and -1 or 1
    for index,preset in ipairs(PRESETS) do
        if preset.id==mode_ then
            Camera.SetMode(PRESETS[(index-1+step)%#PRESETS+1].id)
            break
        end
    end
    return mode_
end

---@param delta number
function Camera.AddYaw(delta)
    if currentPreset().kind=="fixed" then yawOffset_=(yawOffset_+delta+180)%360-180;return end
    if Camera.IsCabView() then
        local base = select(2,CabInterior.GetView(mode_))
        yawOffset_ = Clamp(yawOffset_+delta,base-55,base+55)
    elseif currentPreset().kind=="track" then yawOffset_=Clamp(yawOffset_+delta,-55,55)
    else yawOffset_=(yawOffset_+delta+180)%360-180 end
end

---@param delta number
function Camera.AddPitch(delta)
    if currentPreset().kind=="fixed" then pitch_=Clamp(pitch_+delta,-75,75);return end
    pitch_ = Clamp(pitch_+delta,Camera.IsCabView() and -35 or -10,Camera.IsCabView() and 50 or 80)
end

function Camera.ResetView()
    local preset = currentPreset()
    yawOffset_,pitch_ = preset.yaw,preset.pitch
    fixedPending_ = true
    invalidate()
end

---@param trainS number
---@param car TrainCar|nil
---@return Vector3, Quaternion, number
local function carTransform(trainS,car)
    if car then return car.node.worldPosition,car.node.worldRotation,trainS+car.offset end
    local position,_,yaw = trackSample(trainS)
    return position,Quaternion(yaw,Vector3.UP),trainS
end

---@param aim Vector3
---@param carS number
---@param direction number
---@param preset TrainCameraPreset
local function lockFixed(aim,carS,direction,preset)
    if not fixedAnchor_ then return end
    local position,tangent,yaw = trackSample(carS+28*direction)
    local right = Quaternion(yaw,Vector3.UP)*Vector3.RIGHT
    local desired = position-right*8+Vector3(0,preset.height,0)
    if preset.id=="platform" then
        local bestS,bestDistance = carS,math.huge
        -- 站台属于固定站场，不把列车所选历史股道当月台位置；从站场Route坐标锁世界机位。
        for _, station in ipairs(Route.GetStations()) do
            local candidate = Route.Sample(station.s-55)
            local distance = (candidate-aim):LengthSquared()
            if distance<bestDistance then bestS,bestDistance=station.s-55,distance end
        end
        position,tangent,yaw = Route.Sample(bestS)
        right = Quaternion(yaw,Vector3.UP)*Vector3.RIGHT
        desired = position+right*4.25+Vector3(0,preset.height,0)
    end
    local anchorAim = position+Vector3(0,preset.height,0)
    -- 仅锁定时做放置净空检查，之后允许列车离开/被建筑遮挡；不能把固定相机拖着追车。
    fixedAnchor_.worldPosition = constrainSight(anchorAim,desired,0,true)
    fixedPending_ = false
    print(string.format("[Camera] %s已锁定世界位置 (%.1f,%.1f,%.1f)",preset.id,
        fixedAnchor_.worldPosition.x,fixedAnchor_.worldPosition.y,fixedAnchor_.worldPosition.z))
end

---@param dt number
---@param trainS number 头车中心弧长，主线程在列车可视姿态更新之后调用
function Camera.Update(dt,trainS)
    if not follow_ or not target_ or not node_ or not camera_ or not scene_ then return end
    rayCount_ = 0
    local preset = currentPreset()
    local lead = Train.GetLeadNode()
    local id = Train.GetSelectedId()
    if lead~=lead_ or id~=selectedId_ then
        -- Train可能先释放旧车辆；只比较旧节点身份，不访问已Dispose旧节点的任何属性。
        CabInterior.Dispose()
        lead_,selectedId_ = lead,id
        fixedPending_ = true
        invalidate()
        Locomotive.SetCabView(preset.kind=="cab")
        print("[Camera] 头车变化，重置机位与内舱 -> "..id)
    end
    if preset.kind=="cab" then
        if not lead then CabInterior.SetVisible(false); return end
        CabInterior.Ensure(scene_,lead,id,Train.GetCabOffset())
        CabInterior.SetVisible(true)
        CabInterior.Update(lead,dt,Train.GetSpeedKmh(),Train.GetThrottle(),GameConfig.Train.MaxThrottle,
            Train.GetBrake(),Train.IsReversing())
        local eye = CabInterior.GetView(mode_)
        node_.worldPosition = lead:LocalToWorld(Train.GetCabOffset()+eye)
        node_.worldRotation = lead.worldRotation*Quaternion(yawOffset_,Vector3.UP)*Quaternion(pitch_,Vector3.RIGHT)
        camera_.nearClip,camera_.viewMask = .045,INTERIOR_MASK
        setFov(preset.fov)
        sightDistance_,snap_ = 0,false
        lastPositionValid_ = false
        return
    end
    CabInterior.SetVisible(false)
    -- 远景不需要贴眼近裁剪；提高near保留厘米层地表的深度精度，不挪轨道。
    camera_.nearClip = (preset.id=="birdseye" or preset.id=="distant") and 2.0 or .12
    camera_.viewMask = EXTERIOR_MASK
    local car = selectCar(preset.car)
    local position,rotation,carS = carTransform(trainS,car)
    local direction = (Train.GetSpeedMs()<-.02 or (math.abs(Train.GetSpeedMs())<=.02 and Train.IsReversing())) and -1 or 1
    local aim = position+Vector3(0,preset.height,0)
    local distance = preset.distance
    if preset.id=="birdseye" or preset.id=="distant" then
        local cars = Train.GetCars()
        local head,tail = cars[1],cars[#cars]
        if head and tail then aim=(head.node.worldPosition+tail.node.worldPosition)*.5+Vector3(0,preset.height,0) end
        -- 保留预设的最低观察距离，让整编组及站前街块在画面中有空间。
        distance = math.max(preset.distance,
            Train.GetActiveLength()*(preset.id=="birdseye" and 1.50 or 1.65))
    elseif preset.id=="tail" and car then
        aim = car.node:LocalToWorld(Vector3(0,preset.height,-car.length*.5))
    elseif preset.id=="wheels" and car then
        -- 选第二节车辆前转向架，而不是把机车中心低一点冒充车轮机位。
        aim = car.node:LocalToWorld(Vector3(-1.37,preset.height,car.pivot))
    elseif preset.id=="roof" then
        -- 机车受电弓不是车顶基准；视点移至头车鼻段，避免把车顶观察放进升弓机构里。
        aim = position+rotation*Vector3(0,preset.height,(car and car.length or 20)*.20)
    end
    local wasSnap = snap_
    if preset.kind=="fixed" then
        if fixedPending_ then lockFixed(aim,carS,direction,preset) end
        if not fixedAnchor_ then return end
        node_.worldPosition = fixedAnchor_.worldPosition
        node_:LookAt(aim)
        node_.worldRotation=node_.worldRotation*Quaternion(yawOffset_,Vector3.UP)*Quaternion(pitch_,Vector3.RIGHT)
        setFov(preset.fov)
        sightDistance_ = (aim-node_.worldPosition):Length()
        snap_,lastPositionValid_ = false,false
        return
    elseif preset.kind=="track" then
        -- 沿真实所选股道前方采样；高度不到1米，与司机/车头外追不是同一眼点。
        local frontS = carS+((car and car.length*.5 or 12)+4)*direction
        local trackPosition,tangent = trackSample(frontS)
        local lookPosition = trackSample(frontS+22*direction)
        local desired = trackPosition+Vector3(0,preset.height,0)
        local trackAim = lookPosition+Vector3(0,preset.height+.18,0)
        node_.worldPosition = constrainSight(trackAim,desired,dt,wasSnap)
        node_:LookAt(trackAim)
        node_.worldRotation = node_.worldRotation*Quaternion(yawOffset_,Vector3.UP)*Quaternion(pitch_,Vector3.RIGHT)
        setFov(preset.fov)
    else
        target_.worldPosition = aim
        configureOrbit(distance,preset.fov)
        -- 离散机位切换采用切镜；库时间步仅用于相机插值，不推进世界，不让相机穿舱缓慢飞过去。
        follow_:Update(wasSnap and 2.0 or math.max(0,dt),target_,rotation:YawAngle()+yawOffset_,pitch_)
        setFov(follow_:GetCurrentFOV())
        node_.worldPosition = constrainSight(aim,node_.worldPosition,dt,wasSnap)
        if (node_.worldPosition-aim):LengthSquared()>.0001 then node_:LookAt(aim) end
    end
    -- 使用目标车厢所在股道的实际标高，不把所有站场/轮景都钉在Y=0.8。
    local railPosition = trackSample(carS)
    local ground = node_.worldPosition
    local floorY = railPosition.y+(preset.id=="wheels" and .53 or .80)
    if ground.y<floorY then
        local raised = Vector3(ground.x,floorY,ground.z)
        -- 抬升同样检测短段，不直接把近裁剪面从地板移到棚顶内部。
        local allowed = trace(ground,Vector3.UP,floorY-ground.y)
        if allowed>=floorY-ground.y then node_.worldPosition=raised end
        node_:LookAt(aim)
    end
    lastPosition_,lastPositionValid_,snap_ = node_.worldPosition,true,false
end

return Camera
