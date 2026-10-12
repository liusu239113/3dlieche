-- Rail operations regression entry. Write-only delivery: run after coordinator LSP/build.
-- Logic: .cli/UrhoXRuntime tests/RailOperationsValidation.lua -tapcode_dir=/workspace
--        -tool_mode -graphicsheadless -validate -validate-frames=80 -validate-timeout=150
-- No screenshots here. Runtime counters/timings are CPU observations, not phone FPS claims.
require "main"
local startGame = Start
local updateGame = HandleUpdate
local postUpdateGame = HandlePostUpdate
local Route = require "world.Route"
local Rail = require "world.RailNetwork"
local Train = require "train.Train"
local Camera = require "train.Camera"
local Cab = require "train.CabInterior"
local Traffic = require "game.Traffic"
local Game = require "game.Game"
local Hud = require "ui.Hud"
local Stream = require "world.WorldStream"
local Config = require "config.GameConfig"
local UI = require "urhox-libs/UI"

local Validation = {checks = 0, cases = 0, phases = {}}
local frame_ = 0
local ready_ = false
---@type Scene?
local scene_ = nil
local EXPECTED_SERVICES = {localService = "local", express = "express", passing = "passing"}

---@param condition boolean
---@param message string
function Validation.Check(condition, message)
    Validation.checks = Validation.checks + 1
    if not condition then error("[RailOperations] " .. message, 2) end
end
---@param a number
---@param b number
---@param epsilon number
---@param message string
function Validation.Near(a, b, epsilon, message)
    Validation.Check(a == a and b == b and math.abs(a-b) <= epsilon,
        string.format("%s (actual %.9f expected %.9f)", message, a, b))
end
---@param a Vector3
---@param b Vector3
---@param epsilon number
---@param message string
function Validation.Point(a, b, epsilon, message)
    Validation.Check((a-b):Length() <= epsilon, message)
end
---@param name string
---@param action fun():any
function Validation.Phase(name, action)
    local started = os.clock()
    local result = table.pack(action())
    local milliseconds = (os.clock()-started)*1000
    local record = Validation.phases[name] or {count=0, totalMs=0, maxMs=0}
    record.count, record.totalMs = record.count+1, record.totalMs+milliseconds
    record.maxMs = math.max(record.maxMs,milliseconds)
    Validation.phases[name] = record
    return table.unpack(result,1,result.n)
end
---@param name string
---@param action fun()
local function test(name, action)
    Validation.Phase(name,action)
    Validation.cases = Validation.cases+1
    print("[RailOperations] PASS " .. name)
end

---@param dt number
---@return VariantMap
local function eventFor(dt)
    local data = VariantMap()
    data["TimeStep"] = Variant(dt)
    return data
end
---@param dt number
local function mainStep(dt)
    updateGame("Update",eventFor(dt) --[[@as UpdateEventData]])
end

-- Read-only census includes hidden nodes, so disabled legacy scene accumulation is visible.
---@param scene Scene
---@param label string
function Validation.Census(scene, label)
    local nodes, hidden, components, cabRoots = 0,0,0,0
    local function visit(node)
        nodes = nodes+1
        if not node.enabled then hidden = hidden+1 end
        components = components+node.numComponents
        if node.name:match("^GeneratedCab_") or node.name:match("^ProceduralCab_") then cabRoots = cabRoots+1 end
        Validation.Check(not node.name:match("^ProceduralCab_"),"已移除的方块舱仍存在："..label)
        for _, child in ipairs(node:GetChildren()) do visit(child) end
    end
    visit(scene)
    local stats = Stream.GetStats()
    print(string.format("[RailOperations] CENSUS %s nodes=%d hidden=%d components=%d cabRoots=%d " ..
        "staticModels=%d customGeometry=%d batches=%d primitives=%d streamChunks=%d pending=%d stations=%d cities=%d",
        label,nodes,hidden,components,cabRoots,#scene:GetComponents("StaticModel",true),
        #scene:GetComponents("CustomGeometry",true),renderer.numBatches,renderer.numPrimitives,
        stats.loadedChunks,stats.pendingTasks,stats.stationChunks,stats.cityChunks))
    Validation.Check(cabRoots <= 1, "旧实体内舱子树未释放：" .. label)
    Validation.Check(stats.stationChunks <= 1 and stats.cityChunks <= 1,
        "局部验收同时积累多站隐藏树：" .. label)
    return {nodes=nodes,hidden=hidden,components=components,cabRoots=cabRoots}
end
function Validation.PrintPhases()
    local names = {}
    for name in pairs(Validation.phases) do names[#names+1]=name end
    table.sort(names)
    for _, name in ipairs(names) do
        local record = Validation.phases[name]
        print(string.format("[RailOperations] CPU_PHASE %s n=%d totalMs=%.3f meanMs=%.3f maxMs=%.3f",
            name,record.count,record.totalMs,record.totalMs/math.max(1,record.count),record.maxMs))
    end
    print("[RailOperations] CPU timings + renderer workload only; no mobile/phone FPS inference.")
end

---@param id string
---@param allowDisabled? boolean
function Validation.Tap(id, allowDisabled)
    UI.Layout()
    local root = assert(Hud.GetRoot(),"HUD root未挂载")
    local button = assert(root:FindById(id),"真实按钮不存在："..id) --[[@as Button]]
    local rect = button:GetAbsoluteLayoutForHitTest()
    local width,height = UI.GetViewportSize()
    Validation.Check(rect.w>0 and rect.h>0 and rect.x>=-1 and rect.y>=-1
        and rect.x+rect.w<=width+1 and rect.y+rect.h<=height+1,"按钮实际布局越屏/为空："..id)
    if not allowDisabled then
        Validation.Check(not button:IsDisabled(),"操作按钮意外禁用："..id)
        Validation.Check(UI.FindWidgetAt(rect.x+rect.w*.5,rect.y+rect.h*.5)==button,
            "实际命中被其他控件遮挡："..id)
    end
    -- Observe framework click delivery; never invoke props.onClick / selector:Choose.
    local delivered = 0
    local observer = function() delivered=delivered+1 end
    button:OnEvent("click",observer)
    local x,y = (rect.x+rect.w*.5)*UI.GetScale(),(rect.y+rect.h*.5)*UI.GetScale()
    local types = UI.PointerEvent.Types
    local pointer = UI.PointerEvent
    local down = pointer.new(types.PointerDown,{pointerId=2901,pointerType=pointer.PointerTypes.Touch,
        x=x,y=y,pressure=.5,button=pointer.Button.Left,buttons=pointer.Buttons.Primary,isPrimary=true})
    local up = pointer.new(types.PointerUp,{pointerId=2901,pointerType=pointer.PointerTypes.Touch,
        x=x,y=y,pressure=0,button=pointer.Button.Left,buttons=pointer.Buttons.None,isPrimary=true})
    UI.HandlePointerEvent(down)
    UI.HandlePointerEvent(up)
    -- Selector pagination can destroy the tapped item; do not dereference disposed item afterwards.
    if root:FindById(id)==button then button:OffEvent("click",observer) end
    Validation.Check(delivered==(allowDisabled and 0 or 1),"触摸没有恰好一次真实Button点击："..id)
end

local function routeChecks()
    Validation.Check(Route.IsClosed()==false,"运营线路不是开放线路")
    local length = Route.GetLength()
    Validation.Check(length>50000,"未加载真实长走廊线路")
    local data = Route.GetValidationData()
    Validation.Check(data.closed==false and data.closureError>1000,"端点被伪装成闭合接缝")
    local points = Route.GetPoints()
    Validation.Near(points[#points].s,length,.001,"独立末端采样缺失")
    Validation.Near(Route.Wrap(-25),0,0,"起端Wrap必须截断而非环回")
    Validation.Near(Route.Wrap(length+25),length,0,"终端Wrap必须截断而非环回")
    Validation.Near(Route.Distance(5,length-5),length-10,.001,"开放Distance错误选择短闭合弧")
    Validation.Check(Route.ForwardDistance(length-5,5)==math.huge,"终端前方错误环回首站")
    local start,startTangent = Route.Sample(0)
    local finish,endTangent = Route.Sample(length)
    Validation.Point(Route.SampleExtended(-30),start-startTangent*30,.02,"起端视觉支点未沿切线延伸")
    Validation.Point(Route.SampleExtended(length+30),finish+endTangent*30,.02,"终端视觉支点未沿切线延伸")
    local stations = Route.GetStations()
    Validation.Check(#stations==5,"五站真实规划不完整")
    local previousS = -math.huge
    for _, station in ipairs(stations) do
        Validation.Check(station.s>previousS and station.s-700>0 and station.s+400<length,
            "车站/咽喉顺序或端点净空无效")
        previousS = station.s
        for relative=-720,420,20 do
            local s = station.s+relative
            local p0,t0 = Rail.Sample(s,0)
            local p1,t1 = Rail.Sample(s,1)
            local p2,t2 = Rail.Sample(s,2)
            Validation.Point(p0,Route.SampleExtended(s),.015,"0股道偏离真实中心线")
            Validation.Near((p1-p0):Length(),5,.02,"1股道双线间距不是5米")
            Validation.Near((p2-p0):Length(),Rail.GetLateral(s,2),.025,"2股道采样/侧线网格约定不一致")
            Validation.Near(t0:Length(),1,.002,"正线切线不是单位向量")
            Validation.Near(t1:Length(),1,.002,"上行切线不是单位向量")
            Validation.Near(t2:Length(),1,.002,"侧线切线不是单位向量")
            local a,b = Rail.Sample(s-.1,2),Rail.Sample(s+.1,2)
            Validation.Check((b-a):Length()<.25,"道岔存在横向跳变而非连续进路")
        end
        Validation.Near(Rail.GetLateral(station.s,2),10.8,.001,"站台侧线实际偏移缺失")
        Validation.Near(Rail.GetLateral(station.s-700,2),0,.001,"侧线入口未汇入正线")
        Validation.Near(Rail.GetLateral(station.s+400,2),0,.001,"侧线出口未汇回正线")
    end
    for _, segment in ipairs(Route.GetSegments()) do
        if segment.type=="arc" then
            local s = segment.s+segment.length*.5
            local p0,t0 = Rail.Sample(s,0)
            local p1,t1 = Rail.Sample(s,1)
            Validation.Near((p1-p0):Length(),5,.03,"弯道双线间距错误")
            Validation.Check(t0:DotProduct(t1)>.999,"相向股道几何切线不一致")
        end
    end
end

local function rebuildCount()
    local total = 0
    for _, connection in ipairs(Train.GetConnections()) do
        Validation.Check(connection.valid,"实测风挡无效："..connection.message)
        total = total+(connection.rebuilds or 0)
    end
    return total
end

local function idleChecks()
    local station = Route.GetStations()[1]
    Train.Reset(station.s+1)
    Validation.Check(Train.GetCarCount()==8 and #Train.GetConnections()==7,"8车动车/7组真实风挡不完整")
    local root = assert(Train.GetRoot())
    local nodes = #root:GetChildren(true)
    local count = rebuildCount()
    local positions = {} ---@type Vector3[]
    for i,car in ipairs(Train.GetCars()) do positions[i]=car.node.worldPosition end
    for _=1,80 do Train.UpdateVisuals(.25) end
    Validation.Check(rebuildCount()==count,"idle每帧重建风挡Geometry")
    Validation.Check(#root:GetChildren(true)==nodes,"idle生成额外隐藏车辆节点")
    for i,car in ipairs(Train.GetCars()) do
        Validation.Point(car.node.worldPosition,positions[i],.001,"idle车体姿态漂移")
    end
    Train.Reset(station.s+1000)
    Validation.Check(Train.SetDrivingMode("relaxed"),"停稳不能选择休闲模式")
    Train.SetThrottle(8)
    local straightCount = rebuildCount()
    for _=1,100 do Train.Update(.05);Train.UpdateVisuals(.05) end
    Validation.Check(rebuildCount()==straightCount,"直线整列平移仍每步重上传风挡顶点")
    Train.Reset(station.s+1)
end

local function turnoutChecks()
    local station = Route.GetStations()[1]
    local startS = station.s-800
    Train.Reset(startS)
    Validation.Check(Rail.SetPlayerChoice(1,startS,Train.GetActiveLength(),false),"前方侧线不能预选")
    local initial = assert(Rail.GetChoices()[station.index])
    Validation.Check(initial.lane==2 and not initial.locked,"预选提前错误占用/未选侧线")
    Train.SetThrottle(8)
    local prior = {} ---@type Vector3[]
    for i,car in ipairs(Train.GetCars()) do prior[i]=car.node.worldPosition end
    local lastS = Train.GetS()
    local entryLocked,mixed,tailHistory = false,false,false
    local tailSupportHistory,tailCenterMerged = false,false
    local count = rebuildCount()
    local finishS = station.s+400+Train.GetActiveLength()+35
    for step=1,6000 do
        Validation.Phase("train_dynamics",function() Train.Update(.05) end)
        Validation.Phase("train_visuals",function() Train.UpdateVisuals(.05) end)
        local s,ds = Train.GetS(),Train.GetS()-lastS
        local choice = assert(Rail.GetChoices()[station.index])
        if s+16>=station.s-700 and not entryLocked then
            Validation.Check(choice.locked,"车头包络进入咽喉后未锁进路")
            local accepted = Rail.SetPlayerChoice(-1,s,Train.GetActiveLength(),false)
            Validation.Check(not accepted and Rail.GetPlayerLane(station.s)==2,"占用时扳岔改变历史路径")
            entryLocked = true
        end
        for i,car in ipairs(Train.GetCars()) do
            local centerS = s+car.offset
            local expectedFront = Rail.Sample(centerS+car.pivot,2)
            local expectedRear = Rail.Sample(centerS-car.pivot,2)
            Validation.Point(car.node.worldPosition,(expectedFront+expectedRear)*.5,.025,
                "车厢未按各自s沿锁存历史侧线过岔："..i)
            Validation.Point(Train.GetTrackSample(centerS),Rail.Sample(centerS,2),.025,"GetTrackSample遗漏车厢历史进路")
            Validation.Check((car.node.worldPosition-prior[i]):Length()<=math.abs(ds)*1.06+.025,
                "过岔整列横移瞬移："..i)
            for _,bogie in ipairs(car.bogies) do
                Validation.Point(bogie.node.worldPosition,Rail.Sample(centerS+bogie.z,2),.035,"转向架脱离各自s侧线")
            end
            prior[i]=car.node.worldPosition
        end
        local cars = Train.GetCars()
        if s>station.s-500 and s<station.s-450 then
            mixed = math.abs(Rail.GetLateral(s,2)-Rail.GetLateral(s+cars[8].offset,2))>1
        end
        local tail=assert(cars[#cars])
        local tailCenterS=s+tail.offset
        local tailRearSupportS=tailCenterS-tail.pivot
        local yardExitS=station.s+Rail.YardEnd
        -- 锁定由整列保守包络决定；GetPlayerLane则属于所查询的采样点。
        -- [尾车后支点(2)] --出口-- [尾车中心(0)] 是合法汇入，不是历史进路丢失。
        if s>yardExitS+20 and s-Train.GetActiveLength()<=yardExitS then
            Validation.Check(choice.locked,"头车出岔但整列包络未clear时提前解锁")
            Validation.Check(choice.lane==2,"车头出岔后锁存进路被改为正线")
            if tailCenterS<=yardExitS then
                Validation.Check(Rail.GetPlayerLane(tailCenterS)==2,"头车出岔后站内尾车中心丢失历史路径")
                Validation.Point(Train.GetTrackSample(tailCenterS),Rail.Sample(tailCenterS,2),.025,
                    "站内尾车中心没有按历史侧线采样")
                tailHistory=true
            else
                Validation.Check(Rail.GetPlayerLane(tailCenterS)==0,"尾车中心越出口后没有合法汇入正线")
                Validation.Point(Train.GetTrackSample(tailCenterS),Rail.Sample(tailCenterS,0),.025,
                    "已汇入正线的尾车中心采样错误")
                tailCenterMerged=true
                if tailRearSupportS<=yardExitS then
                    Validation.Check(Rail.GetPlayerLane(tailRearSupportS)==2,
                        "尾车中心已出岔但站内后支点丢失历史路径")
                    Validation.Point(Train.GetTrackSample(tailRearSupportS),Rail.Sample(tailRearSupportS,2),.025,
                        "跨出口尾车后支点没有按历史侧线采样")
                    tailSupportHistory=true
                end
            end
        end
        lastS=s
        if s>=finishS then break end
        Validation.Check(step<6000,"真实牵引过岔未能在有界步数内完成")
    end
    Validation.Check(entryLocked and mixed and tailHistory,"未实际覆盖分时入岔/尾车历史路径")
    Validation.Check(tailCenterMerged and tailSupportHistory,
        "未实际覆盖尾车中心已汇入正线、后支点仍沿历史侧线且全列仍锁定的出口边界")
    Validation.Check(not Rail.GetChoices()[station.index].locked,"整列驶离咽喉后仍永久锁定")
    Validation.Check(rebuildCount()>count,"道岔车间偏角变化没有真实风挡变形")
    local originalLane = Rail.GetPlayerLane(station.s)
    Train.EmergencyBrake()
    for _=1,3000 do
        Train.Update(.05)
        if math.abs(Train.GetSpeedMs())<=.02 then break end
    end
    Validation.Check(Train.ToggleReversing(),"停稳后不能换向")
    Rail.UpdatePlayer(station.s+450,Train.GetActiveLength(),true)
    Validation.Check(Rail.GetPlayerLane(station.s)==originalLane,"折返重新占用时丢失历史进路")
    Validation.Check(not Rail.SetStationChoice(station.index,0,station.s+450,Train.GetActiveLength()),
        "倒车尾部占用期间允许换岔")
    Train.Reset(station.s+1)
end

local function timeChecks()
    local s = Route.GetStations()[1].s+1
    local function integrate(dt,n)
        Train.Reset(s)
        Traffic.SetPlayerOverride(nil)
        Traffic.Reset(s)
        Game.Init()
        Train.SetBrake(0);Train.SetThrottle(8)
        local beginning = GetFrameSimulationStats().total
        local elapsed = Game.GetElapsed()
        for _=1,n do mainStep(dt) end
        local timing = GetFrameSimulationStats()
        Validation.Near(timing.total-beginning,5,.0001,"真实main低FPS累计模拟时间不是5秒")
        Validation.Near(Game.GetElapsed()-elapsed,5,.0001,"Game计时被dt截成2秒")
        Validation.Near(timing.debt,0,.0001,"正常低FPS未消化完时间债务")
        return Train.GetS(),Train.GetSpeedMs()
    end
    local lowS,lowV = integrate(.25,20)
    local fineS,fineV = integrate(.05,100)
    Validation.Near(lowS,fineS,.015,".25×20和.05×100纵向里程不一致")
    Validation.Near(lowV,fineV,.002,"低FPS与高FPS动力积分不一致")
    local velocities = {}
    for _,mode in ipairs({"simulation","relaxed"}) do
        Train.Reset(s)
        Validation.Check(Train.SetDrivingMode(mode),"驾驶模式切换失败")
        Train.SetThrottle(8)
        for _=1,100 do Train.Update(.05) end
        velocities[mode]=Train.GetSpeedMs()
        Validation.Check(not Train.SetDrivingMode(mode=="relaxed" and "simulation" or "relaxed"),
            "行驶中切换驾驶模式未拒绝")
    end
    Validation.Check(velocities.relaxed>velocities.simulation*1.2,"休闲/模拟仅换标签而无真实动力差")
    Train.Reset(s)
    Validation.Check(not Train.SetDrivingMode("invalid"),"未知驾驶模式被接受")
    Train.SetDrivingMode("relaxed")
end

---@param scene Scene
function Validation.CameraChecks(scene)
    local presets = Camera.GetPresets()
    Validation.Check(#presets==16,"真实镜头目录不是16项")
    local ids,poses = {},{}
    for _,preset in ipairs(presets) do
        Validation.Check(type(preset.id)=="string" and preset.id~="" and preset.name~="" and not ids[preset.id],
            "镜头目录名称/id重复或无效")
        ids[preset.id]=true
        Validation.Check(Camera.SetMode(preset.id),"真实机位不支持目录id："..preset.id)
        Validation.Phase("camera",function() Camera.Update(.05,Train.GetS()) end)
        Validation.Check(Camera.GetMode()==preset.id and Camera.GetModeName()==preset.name,"实际机位与目录显示不同步")
        local node,camera = assert(Camera.GetNode()),assert(Camera.GetCamera())
        local position,direction = node.worldPosition,node.worldDirection
        Validation.Check(position.x==position.x and position.y==position.y and position.z==position.z
            and camera.fov>0 and camera.fov<180,"相机产生NaN或无效FOV")
        for id,pose in pairs(poses) do
            Validation.Check((position-pose.position):Length()>.1 or direction:DotProduct(pose.direction)<.9995
                or math.abs(camera.fov-pose.fov)>.2,"16镜头中存在重复实际眼点/朝向/焦距："..id.."/"..preset.id)
        end
        poses[preset.id]={position=position,direction=direction,fov=camera.fov}
        if Camera.IsCabView() then
            local cab = assert(Cab.GetRoot(),"司机机位没有生成实体舱")
            Validation.Check(Cab.IsVisible() and cab.scene==scene,
                "内舱只是屏幕UI或没有真实场景节点")
            local body=assert(cab:GetChild("GeneratedCabBody"),"正式内舱主体缺失"):GetComponent("StaticModel")
            Validation.Check(body and body.model.name==Cab.GetDiagnostics().modelPath,
                "驾驶舱主体不是独立MDL")
            Validation.Check(camera.viewMask & 8 ~= 0,"司机相机未包含实体舱mask")
            Validation.Check(cab:GetChild("IndependentSeat",true)~=nil and cab:GetChild("LiveSpeedDisplay",true)~=nil,
                "独立座椅或实时速度屏缺失")
            for _,model in ipairs(cab:GetComponents("StaticModel",true)) do
                Validation.Check(model.viewMask==8,"内舱对象未从外景渲染层隔离")
            end
        else
            Validation.Check(not Cab.IsVisible() and camera.viewMask & 8 == 0,"外景出现漂浮实体内舱")
        end
    end
    local oldMode = Camera.GetMode()
    Validation.Check(not Camera.SetMode("not_a_camera") and Camera.GetMode()==oldMode,"未知镜头改变有效机位")
    Camera.SetMode(presets[1].id)
    Camera.CycleMode(true)
    Validation.Check(Camera.GetMode()==presets[16].id,"反向循环16机位失败")
    Camera.CycleMode()
    Validation.Check(Camera.GetMode()==presets[1].id,"正向循环末机位回首项失败")
    for _,id in ipairs({"trackside","platform"}) do
        Camera.SetMode(id);Camera.Update(.05,Train.GetS())
        local anchor = assert(Camera.GetNode()).worldPosition
        local before = Train.GetS()
        Train.Reset(before+20);Camera.Update(.05,Train.GetS())
        Validation.Point(assert(Camera.GetNode()).worldPosition,anchor,.003,"固定机位错误随列车移动："..id)
        Train.Reset(before)
    end
    Camera.SetMode("cab");Camera.Update(.05,Train.GetS())
    local oldCab = assert(Cab.GetRoot()).ID
    Validation.Check(SelectTrain("DF4D"),"机车内舱换车fixture未能加载")
    Camera.Update(.05,Train.GetS())
    Validation.Check(Cab.GetKind()=="diesel" and assert(Cab.GetRoot()).ID~=oldCab,"换车仍使用旧动车内舱")
    Validation.Census(scene,"diesel_cab")
    Validation.Check(SelectTrain("CR400AF"),"未能恢复8车复兴号")
    Camera.Update(.05,Train.GetS())
    Validation.Check(Cab.GetKind()=="emu","恢复动车未重建对应实体舱")
    Validation.Census(scene,"emu_cab")
    Camera.SetMode("chase")
end

local function uiChecks()
    Train.Reset(Route.GetStations()[1].s+1)
    Traffic.Reset(Train.GetS());Game.Init();Game.UpdateHud(0)
    local presets = Camera.GetPresets()
    Hud.SetCameraCatalog(presets,Camera.GetMode())
    local selector = assert(Hud.GetCameraSelector())
    Validation.Check(assert(Hud.GetRoot()):FindById("cameraSelector")==selector,"镜头菜单不是实际挂载实例")
    Camera.SetMode(presets[#presets].id);Hud.SetCameraMode(Camera.GetMode(),Camera.GetModeName())
    for _,preset in ipairs(presets) do
        local brake = Train.GetBrake()
        Validation.Tap("openCameraSelector")
        Validation.Check(Hud.IsCameraSelectorOpen() and not Hud.GetReadings().paused,"镜头菜单意外暂停游戏")
        Validation.Near(Train.GetBrake(),brake,0,"镜头菜单错误释放制动")
        UI.Layout()
        local page = selector:GetPage()
        for _=2,page do Validation.Tap("previousCameraPage") end
        local found=false
        for p=1,selector:GetPageCount() do
            if assert(Hud.GetRoot()):FindById("selectCamera_"..preset.id) then
                Validation.Tap("selectCamera_"..preset.id);found=true;break
            end
            local prior=selector:GetPage()
            Validation.Tap("nextCameraPage")
            Validation.Check(selector:GetPage()==prior+1,"真实下一页未推进镜头页码")
            Validation.Check(p<selector:GetPageCount(),"遍历页数耗尽仍缺目录镜头")
        end
        Validation.Check(found and Camera.GetMode()==preset.id and not Hud.IsCameraSelectorOpen(),
            "真实触摸镜头选择未切换并关闭")
        Validation.Check(Hud.GetReadings().selectedCameraId==preset.id
            and Hud.GetReadings().selectedCameraName==preset.name,"镜头权威状态未同步HUD")
    end
    Validation.Tap("openCameraSelector")
    local total = GetFrameSimulationStats().total
    mainStep(.25);mainStep(.25)
    Validation.Near(GetFrameSimulationStats().total-total,.5,.0001,"非模态镜头菜单阻断模拟时间")
    Validation.Tap("closeCameraSelector")
    Validation.Check(not Hud.IsCameraSelectorOpen(),"真实关闭菜单按钮无效")
    -- Two genuine concurrent touches: camera menu must not cancel a held brake.
    UI.Layout()
    local handle=assert(assert(Hud.GetRoot()):FindById("brakeHandle"))
    local rect=handle:GetAbsoluteLayoutForHitTest()
    local holdX,holdY=(rect.x+rect.w*.5)*UI.GetScale(),(rect.y+rect.h*.5)*UI.GetScale()
    UI.InputAdapter.HandleTouchBegin(903,holdX,holdY,.5)
    Validation.Check(Hud.GetReadings().brakeHeld,"真实制动触摸未开始按住")
    Validation.Tap("openCameraSelector")
    mainStep(.25)
    Validation.Check(Hud.GetReadings().brakeHeld and not Hud.GetReadings().paused,
        "镜头菜单打开时取消另一个手指的制动/暂停游戏")
    Validation.Tap("closeCameraSelector")
    Validation.Check(Hud.GetReadings().brakeHeld,"关闭镜头菜单错误释放制动手柄")
    UI.InputAdapter.HandleTouchEnd(903,holdX,holdY)
    Validation.Check(not Hud.GetReadings().brakeHeld,"抬起真实制动触摸未释放")
    Validation.Tap("openTrainSelector")
    local elapsed,s = Game.GetElapsed(),Train.GetS()
    mainStep(.25)
    Validation.Check(Hud.IsTrainSelectorOpen() and Game.GetElapsed()==elapsed and Train.GetS()==s,
        "车型菜单未暂停真实main物理/计时")
    Validation.Tap("cancelTrainSelection")
    Validation.Check(not Hud.GetReadings().paused,"关闭车型菜单未恢复原非暂停状态")

    Train.Reset(Route.GetStations()[1].s-800)
    Traffic.Reset(Train.GetS());Game.Init();Game.UpdateHud(0)
    Validation.Tap("switchSiding")
    Validation.Check(Rail.GetChoices()[1].lane==2,"真实道岔按钮没有写入RailNetwork预选")
    Validation.Tap("switchMainline")
    Validation.Check(Rail.GetChoices()[1].lane==0,"正线按钮没有改变未锁进路")
    Validation.Tap("switchSiding")
    Train.SetThrottle(8)
    for _=1,1200 do
        Train.Update(.05)
        if Train.GetS()+16>=Route.GetStations()[1].s-700 then break end
    end
    Traffic.Update(.02);Game.UpdateHud(0)
    Validation.Check(Hud.GetReadings().switchLocked,"真实岔区占用未显示锁定")
    local button = assert(assert(Hud.GetRoot()):FindById("switchMainline")) --[[@as Button]]
    Validation.Check(button:IsDisabled(),"锁定岔区仍显示可点击扳岔按钮")
    Validation.Tap("switchMainline",true)
    Validation.Check(Rail.GetChoices()[1].lane==2,"真实触摸禁用按钮改变锁进路")
    Train.Reset(Route.GetStations()[1].s+1)
    Traffic.Reset(Train.GetS());Game.Init();Game.UpdateHud(0)
    Validation.Tap("drivingMode")
    Validation.Check(Train.GetDrivingMode()=="simulation","触摸驾驶模式仅改变标签")
    Validation.Tap("drivingMode")
    Validation.Check(Train.GetDrivingMode()=="relaxed","触摸驾驶模式无法恢复休闲")
    Validation.Tap("nextService")
    Validation.Check(Game.GetService()=="express","触摸运营任务未切为快速")
    Validation.Tap("nextService")
    Validation.Check(Game.GetService()=="passing","触摸运营任务未切为待避")
    Validation.Tap("nextService")
    Validation.Check(Game.GetService()=="local","三种任务循环不能回站站停")
    local qualityS,qualitySpeed,qualityXp=Train.GetS(),Train.GetSpeedMs(),Game.GetXp()
    Validation.Check(GetRenderQuality()=="performance" and not renderer.drawShadows
        and Hud.GetReadings().renderQuality=="流畅","默认流畅预设未实际应用")
    Validation.Tap("renderQuality")
    Validation.Check(GetRenderQuality()=="detailed" and renderer.drawShadows and renderer.specularLighting
        and Hud.GetReadings().renderQuality=="细致","真实画质触摸没有切换渲染器")
    Validation.Tap("renderQuality")
    Validation.Check(GetRenderQuality()=="performance" and not renderer.drawShadows and not renderer.specularLighting
        and Hud.GetReadings().renderQuality=="流畅","流畅预设没有恢复实际渲染开关")
    Validation.Check(Train.GetS()==qualityS and Train.GetSpeedMs()==qualitySpeed and Game.GetXp()==qualityXp,
        "切换画质改变列车位置/速度/经验")
    Validation.Check(not SetRenderQuality("invalid") and GetRenderQuality()=="performance",
        "未知画质改变当前预设")
end

local function serviceAndTerminalChecks()
    local stations = Route.GetStations()
    Train.Reset(stations[1].s+1);Traffic.Reset(Train.GetS());Game.Init()
    local services = Game.GetServices()
    Validation.Check(#services==3,"Game未提供3个真实运营任务")
    local ids = {}
    for _,item in ipairs(services) do ids[item.id]=true end
    for _,id in pairs(EXPECTED_SERVICES) do Validation.Check(ids[id]==true,"运营服务id缺失："..id) end
    local s,xp = Train.GetS(),Game.GetXp()
    Validation.Check(Game.SetService("express"),"快速服务无法切换")
    Validation.Check(Game.GetNextStation().index==3,"快速仍将天津列为必停站")
    Validation.Check(Game.SetService("local") and Game.GetNextStation().index==2,"站站停未恢复天津")
    Validation.Check(Game.SetService("passing") and Rail.GetChoices()[3].lane==2,"待避未预选济南真实侧线")
    Validation.Check(Train.GetS()==s and Game.GetXp()==xp,"切任务改变位置/经验")
    Validation.Check(not Game.SetService("invalid") and Game.GetService()=="passing","未知服务改变当前任务")

    local length = Route.GetLength()
    Train.Reset(length-20-.001);Train.SetThrottle(8);Train.Update(1)
    Validation.Near(Train.GetS(),length-20,.003,"终端车头没有物理安全停止")
    Validation.Check(Train.GetSpeedMs()==0 and Train.GetBrake()==1 and Train.GetThrottle()==0,
        "终端越界后未收油/制动/停稳")
    for _=1,20 do Train.SetThrottle(8);Train.Update(.25) end
    Validation.Near(Train.GetS(),length-20,.003,"终端继续牵引后Wrap回北京")
    Train.Reset(Train.GetActiveLength()+.001);Train.ToggleReversing();Train.SetThrottle(8);Train.Update(1)
    Validation.Near(Train.GetS(),Train.GetActiveLength(),.003,"起端后退未保住8车包络")

    local last = stations[#stations]
    Train.Reset(last.s-1);Traffic.Reset(Train.GetS());Game.Init()
    Validation.Check(Game.GetNextStation().index==last.index,"终到fixture站序错误")
    Train.SetThrottle(8);Train.Update(.5)
    Game.Update(.02)
    Validation.Check(Game.GetXp()==0,"未收油停稳就给到站经验")
    Train.EmergencyBrake()
    for _=1,600 do
        Train.Update(.05);Game.Update(.05)
        if math.abs(Train.GetSpeedMs())<=.02 and Game.IsDwelling() then break end
    end
    Validation.Check(Game.IsDwelling() and Game.GetXp()>0,"真实牵引再停车未识别终到")
    local awarded = Game.GetXp()
    for _=1,300 do Train.Update(.05);Game.Update(.05) end
    Validation.Check(Game.IsTerminal() and Game.GetNextStation()==nil,"终到自动Wrap站序至首站")
    Validation.Check(Game.GetXp()==awarded and Train.GetBrake()==1,"终到重复奖励或自动松闸")
    Validation.Near(Game.GetNearestStationDistance(),Route.Distance(Train.GetS(),last.s),.005,
        "开放末端最近站距离被计算为闭合/负数")
    Train.ToggleReversing();Game.Update(.02)
    Validation.Check(not Game.IsTerminal() and Game.GetNextStation().index==4,"终到手动换向未选择南京折返")
    Validation.Check(Game.GetXp()==awarded,"折返原地重发终到经验")
    Train.Reset(stations[1].s+1);Traffic.Reset(Train.GetS());Game.Init()
end

-- Traffic fixtures use only the public perception override, never mutate GetTrains copies.
local function trafficChecks()
    local station = Route.GetStations()[1]
    local origin = station.s+1000
    local function snapshot(id)
        for _,item in ipairs(Traffic.GetTrains()) do if item.id==id then return item end end
        error("[RailOperations] 调度fixture缺少真实班次："..id)
    end
    local function override(s,lane,reversing)
        Traffic.SetPlayerOverride({s=s,speedMs=0,length=220,frontOffset=16,lane=lane,
            reversing=reversing==true,deceleration=.65})
    end
    -- Caller .05s is not necessarily the simulated interval: .02s substeps
    -- alternate .04/.06s here. Bound motion by the measured logical elapsed
    -- and the scenario's actual constructor speed limit, never a fixed metre cap.
    ---@param id string
    ---@param previousHead number
    ---@param currentHead number
    ---@param direction number
    ---@param beforeElapsed number
    ---@param afterElapsed number
    ---@param constructionKmh number
    ---@param message string
    local function checkTrafficMovement(id,previousHead,currentHead,direction,
        beforeElapsed,afterElapsed,constructionKmh,message)
        local simulated = afterElapsed-beforeElapsed
        Validation.Check(beforeElapsed==beforeElapsed and afterElapsed==afterElapsed
            and simulated>0 and simulated<math.huge,
            string.format("%s：Traffic逻辑elapsed无效 (%s %.9f -> %.9f)",
                message,id,beforeElapsed,afterElapsed))
        local movement = direction*(currentHead-previousHead)
        local maximumMovement = simulated*(constructionKmh/3.6)+.005
        Validation.Check(movement>=-.005 and movement<=maximumMovement,
            string.format("%s (id=%s head=%.9f->%.9f elapsed=%.9f->%.9f dt=%.9f delta=%.9f max=%.9f)",
                message,id,previousHead,currentHead,beforeElapsed,afterElapsed,
                simulated,movement,maximumMovement))
    end
    Traffic.Shutdown();Traffic.Init(nil)
    Validation.Check(Traffic.SetService("local"),"Traffic站站停服务不可用")
    override(origin,0,false);Traffic.Reset(origin)
    Validation.Check(Traffic.GetStats().visible==0 and Traffic.GetStats().clonedCars==0,
        "纯Traffic感知测试创建了场景/资产克隆")
    Validation.Check(Traffic.GetSignalAspect(-999)=="red","未知信号未fail-closed")
    local slow = snapshot("L01")
    local playerS = slow.lo-16-100
    override(playerS,0,false)
    local speedKmh = Traffic.GetSpeedConstraint()
    local maximum,minimum = Traffic.GetMovementLimit()
    Validation.Near(speedKmh,(math.sqrt(2*.65*20)+slow.speedMs)*3.6,.025,
        "GetSpeedConstraint非km/h或没有80米真实尾距包络")
    Validation.Near(assert(maximum),playerS+20,.015,"maxS不是玩家中心的前方安全硬界")
    Validation.Check(minimum==nil,"前进防护错误给反向minS")
    Train.Reset(playerS);Train.SetThrottle(8)
    Train.Update(20,maximum,minimum)
    Validation.Near(Train.GetS(),assert(maximum),.015,"纵向积分越过Traffic硬安全界")
    Validation.Check(Train.GetSpeedMs()==0 and Train.GetBrake()==1,"命中硬界后未实际停稳制动")
    -- Already inside the margin: safety must stop NEW movement, never teleport backwards.
    playerS=slow.lo-16-60
    override(playerS,0,false)
    maximum,minimum=Traffic.GetMovementLimit()
    Validation.Near(assert(maximum),playerS,.015,"违规包络硬界试图把列车瞬移到后方")
    Train.Reset(playerS);Train.SetThrottle(8);Train.Update(.25,maximum,minimum)
    Validation.Near(Train.GetS(),playerS,.015,"已侵入安全余量后仍推进或瞬移")
    playerS=slow.hi+220+60
    override(playerS,0,true)
    maximum,minimum=Traffic.GetMovementLimit()
    Validation.Check(maximum==nil,"倒车防护仍返回maxS")
    Validation.Near(assert(minimum),playerS,.015,"倒车未按真实领先尾端提供minS")
    Train.Reset(playerS);Train.ToggleReversing();Train.SetThrottle(8);Train.Update(.25,maximum,minimum)
    Validation.Near(Train.GetS(),playerS,.015,"倒车越过80m防护界")

    -- Real AI must sense a stationary player ahead, even though Train is elsewhere.
    override(origin,0,false);Traffic.Reset(origin)
    slow=snapshot("L01")
    local blockerS=slow.hi+150+220
    override(blockerS,0,false)
    local realS=Train.GetS()
    local priorHead=slow.headS
    local sawHold=false
    for _=1,1600 do
        local beforeElapsed=Traffic.GetStats().elapsed
        Validation.Phase("traffic_logic",function() Traffic.Update(.05) end)
        local afterElapsed=Traffic.GetStats().elapsed
        slow=snapshot("L01")
        Validation.Check(slow.active and slow.dir==1 and slow.lane==0,
            "同线安全停车fixture进入离线调度或改变运营方向/股道")
        Validation.Check(slow.headS<=blockerS-220-80+.02,"同线AI穿过玩家全列尾端/80米安全区")
        checkTrafficMovement(slow.id,priorHead,slow.headS,slow.dir,beforeElapsed,afterElapsed,90,
            "同线AI靠瞬移制造安全停车")
        priorHead=slow.headS
        if slow.speedMs<=.02 then sawHold=true;break end
    end
    Validation.Check(sawHold,"AI未能在玩家前停稳")
    Validation.Near(Train.GetS(),realS,0,"SetPlayerOverride写入真实列车而非只替代感知")

    -- Opposing train actually passes the player, on lane1 exactly five metres apart.
    override(origin+600,0,false);Traffic.Reset(origin)
    local opposing=snapshot("O01")
    Validation.Check(opposing.active and opposing.dir==-1 and opposing.lane==1,
        "相向班次未使用独立上行线")
    local crossed=false
    priorHead=opposing.headS
    for _=1,1600 do
        local beforeElapsed=Traffic.GetStats().elapsed
        Traffic.Update(.05)
        local afterElapsed=Traffic.GetStats().elapsed
        opposing=snapshot("O01")
        Validation.Check(opposing.active and opposing.lane==1 and opposing.dir==-1,
            "相向班次进入离线调度或偷偷换到玩家正线")
        checkTrafficMovement(opposing.id,priorHead,opposing.headS,opposing.dir,
            beforeElapsed,afterElapsed,135,"相向双线通过产生瞬移")
        Validation.Near((Rail.Sample(opposing.headS,1)-Rail.Sample(opposing.headS,0)):Length(),5,.03,
            "相向班次实际轨道间距不是5米")
        priorHead=opposing.headS
        if opposing.hi<origin+600-220 then crossed=true;break end
    end
    Validation.Check(crossed,"相向车未实际沿独立双线通过玩家")

    -- Place only the perception hull in the entry fan; obtain locks from live AI.
    local yard=Route.GetStations()[3]
    local throatOrigin=yard.s-2250
    override(throatOrigin,0,false);Traffic.Reset(throatOrigin)
    slow=snapshot("L01") -- head=station-450, physically occupies entry throat.
    Validation.Check(slow.active and slow.lo<=yard.s-320 and slow.hi>=yard.s-700,
        "咽喉冲突fixture未实际进入进站扇区")
    local fanPlayerS=yard.s-1050
    override(fanPlayerS,2,false)
    Traffic.Update(.05)
    maximum,minimum=Traffic.GetMovementLimit()
    Validation.Check(maximum~=nil and maximum<=yard.s-700-80-16+.05,
        "侧线进路与正线AI在共享咽喉没有硬界防护")
    local hasLock=false
    for _,lock in ipairs(Traffic.GetStats().locks) do
        if lock.stationIndex==3 and lock.side=="entry" and lock.owner=="L01" then hasLock=true end
    end
    Validation.Check(hasLock and Traffic.GetSignalAspect(3)=="red","被AI占用咽喉未保持真实锁/红灯")
    Validation.Check(not Traffic.SetService("invalid"),"Traffic接受未知服务")
    Validation.Check(Traffic.SetService("express"),"Traffic快速服务不可用")

    -- Passing is not a timer trick: player must first be stopped wholly in lane2.
    Traffic.Shutdown();Traffic.Init(nil)
    override(yard.s,0,false);Traffic.Reset(yard.s)
    Validation.Check(Traffic.SetService("passing"),"待避真实后方快车未调度")
    for _=1,260 do Traffic.Update(.05) end
    local pass=assert(Traffic.GetStats().passing)
    Validation.Check(not pass.committed and not pass.cleared and Traffic.GetSignalAspect(3)=="red",
        "只过站停时间/玩家在正线仍完成待避")
    override(yard.s,2,false)
    local sawNoseBeforeTail,sawCleared=false,false
    local passingTrainId=pass.trainId
    local initialExpress=snapshot(passingTrainId)
    Validation.Check(initialExpress.active and initialExpress.lane==0 and initialExpress.dir==1,
        "纯待避连续性fixture未实际发出快车（不能用queued坐标替代活动运行）")
    priorHead=initialExpress.headS
    for step=1,10000 do
        local beforeElapsed=Traffic.GetStats().elapsed
        Validation.Phase("traffic_passing",function() Traffic.Update(.05) end)
        local afterStats=Traffic.GetStats()
        pass=assert(afterStats.passing)
        Validation.Check(pass.trainId==passingTrainId,"待避途中更换真实快车ID制造清空")
        local express=snapshot(passingTrainId)
        Validation.Check(express.active and express.lane==0 and express.dir==1,
            "待避快车进入离线调度或不在真实下行正线")
        checkTrafficMovement(express.id,priorHead,express.headS,express.dir,
            beforeElapsed,afterStats.elapsed,200,"待避靠挪动快车/瞬移清空而不是实际运行")
        priorHead=express.headS
        if express.headS>pass.exitClearS and express.lo<=pass.exitClearS then
            sawNoseBeforeTail=true
            Validation.Check(not pass.cleared and Traffic.GetSignalAspect(3)=="red",
                "快车车头出岔但尾车未trainclear就放行")
        end
        if pass.cleared then
            Validation.Check(express.lo>pass.exitClearS and pass.tailS>pass.exitClearS,
                "待避cleared不基于真实末车尾端")
            local aspect=Traffic.GetSignalAspect(3)
            Validation.Check(aspect=="green" or aspect=="yellow","整列clear后信号没有真实放行")
            sawCleared=true;break
        end
        Validation.Check(Traffic.GetSignalAspect(3)=="red","尾车未clear前出站信号开放")
        Validation.Check(step<10000,"后方快车未在500模拟秒内完成真实待避通过")
    end
    Validation.Check(sawNoseBeforeTail and sawCleared,"未覆盖头过岔/尾未clear和最后放行两个阶段")
    Validation.Check(Traffic.GetStats().visible==0 and Traffic.GetStats().clonedCars==0,
        "纯逻辑Traffic测试意外创建克隆场景")
    Traffic.SetPlayerOverride(nil)

    -- End-to-end Game task: enter the preselected siding with the real Train,
    -- actually stop, wait longer than dwell, then release ONLY after express tail clear.
    Train.Reset(yard.s-850)
    Traffic.Shutdown();Traffic.Init(nil);Traffic.Reset(Train.GetS());Game.Init()
    Validation.Check(Game.SetService("passing"),"Game真实待避服务fixture无法开始")
    local arrived=false
    for step=1,14000 do
        local distance=yard.s+12-Train.GetS()
        local velocity=math.abs(Train.GetSpeedMs())
        if distance<=.3 then
            Train.EmergencyBrake()
        else
            local target=math.min(8,math.sqrt(2*.45*math.max(0,distance-1)))
            if velocity>target+.10 then Train.SetThrottle(0);Train.SetBrake(.45)
            elseif velocity<target-.10 then Train.SetBrake(0);Train.SetThrottle(4)
            else Train.SetThrottle(0);Train.SetBrake(0) end
        end
        Traffic.Update(.05)
        local maxS,minS=Traffic.GetMovementLimit()
        Train.Update(.05,maxS,minS);Game.Update(.05)
        if Game.IsDwelling() then arrived=true;break end
        Validation.Check(step<14000,"真实列车未能在有界步数进入济南侧线停稳")
    end
    Validation.Check(arrived and Rail.GetPlayerLane(Train.GetS())==2,"待避到站不在真实侧线")
    local stoppedS,awarded,arrivalTime=Train.GetS(),Game.GetXp(),Game.GetElapsed()
    local departed=false
    for step=1,10000 do
        Traffic.Update(.05)
        local maxS,minS=Traffic.GetMovementLimit()
        Train.Update(.05,maxS,minS);Game.Update(.05)
        local progress=assert(Traffic.GetStats().passing)
        if not progress.cleared then
            Validation.Check(Game.IsDwelling() and Train.GetBrake()==1,
                "Game只等待12秒就忽略未clear快车发车")
            Validation.Near(Train.GetS(),stoppedS,.005,"红灯待避期间真实玩家列车移动")
        end
        if not Game.IsDwelling() then
            Validation.Check(progress.cleared and progress.tailS>progress.exitClearS,
                "Game发车不依赖快车真实末节clear")
            Validation.Check(Game.GetElapsed()-arrivalTime>=Config.Gameplay.DwellTime-.001,
                "真实待避跳过最低站停时间")
            Validation.Check(Game.GetNextStation().index==4 and Train.GetThrottle()==0 and Train.GetBrake()==0,
                "待避放行后没有选择南京/松闸手动牵引")
            departed=true;break
        end
        Validation.Check(step<10000,"Game在真实尾车clear后未完成待避发车")
    end
    Validation.Check(departed and Game.GetXp()==awarded,"待避任务未完成或停稳重复奖励")
end

local function reversePassingChecks()
    local station=Route.GetStations()[3]
    local realS=Train.GetS()
    local function perceive(lane,reversing)
        Traffic.SetPlayerOverride({s=station.s,speedMs=0,length=220,frontOffset=16,
            lane=lane,reversing=reversing,deceleration=.65})
    end
    local function snapshot(id)
        for _,train in ipairs(Traffic.GetTrains()) do if train.id==id then return train end end
        error("[RailOperations] 反向待避班次缺失："..id)
    end
    Traffic.Shutdown();Traffic.Init(nil)
    perceive(0,true)
    -- 仅隔离AI调度原点；不移动真实玩家或其站内感知包络。
    Traffic.Reset(station.s+5000)
    Validation.Check(Traffic.SetService("passing"),"反向待避服务不能安排")
    local pass=assert(Traffic.GetStats().passing)
    local id=pass.trainId
    local express=snapshot(id)
    Validation.Check(express.active and express.dir==-1 and express.lane==0,"反向快车实际方向/股道错误")
    Validation.Near(pass.exitClearS,station.s-780,.001,"反向清尾点错误")
    for _=1,650 do Traffic.Update(.02) end
    pass=assert(Traffic.GetStats().passing)
    Validation.Check(not pass.committed and not pass.cleared and Traffic.GetSignalAspect(3)=="red",
        "反向待避仅凭正线停稳计时完成")
    local preservedHead=snapshot(id).headS
    perceive(0,false)
    Validation.Check(Traffic.SetService("passing") and Traffic.GetStats().passing.trainId==id
        and snapshot(id).dir==-1,"未清尾时换向重排既有快车")
    Validation.Near(snapshot(id).headS,preservedHead,0,"中途换向挪动既有快车")
    perceive(2,true)
    local previousHead,previousTime=snapshot(id).headS,Traffic.GetStats().elapsed
    local sawNose,sawCleared=false,false
    for step=1,25000 do
        Traffic.Update(.02)
        local stats=Traffic.GetStats()
        pass=assert(stats.passing);express=snapshot(id)
        local moved=previousHead-express.headS
        Validation.Check(express.active and express.dir==-1 and express.lane==0 and pass.trainId==id,
            "反向待避途中换轨/换向/撤车")
        Validation.Check(moved>=-.005 and moved<=(stats.elapsed-previousTime)*200/3.6+.005,
            "反向快车非连续位移")
        Validation.Near(pass.tailS,express.hi,.001,"反向末车尾端误用lo")
        if express.headS<pass.exitClearS and express.hi>=pass.exitClearS then
            sawNose=true
            Validation.Check(not pass.cleared and Traffic.GetSignalAspect(3)=="red",
                "反向鼻端出岔但尾端未清空就放行")
        end
        if pass.cleared then
            Validation.Check(express.hi<pass.exitClearS,"反向clear不依据真实尾端")
            local aspect=Traffic.GetSignalAspect(3)
            Validation.Check(aspect=="green" or aspect=="yellow","反向整列清尾后信号未同步放行")
            sawCleared=true;break
        end
        Validation.Check(Traffic.GetSignalAspect(3)=="red","反向尾端未清空前信号开放")
        previousHead,previousTime=express.headS,stats.elapsed
        Validation.Check(step<25000,"反向待避未在500模拟秒内完成")
    end
    Validation.Check(sawNose and sawCleared,"反向未覆盖完整清尾阶段")
    Validation.Near(Train.GetS(),realS,0,"反向纯感知fixture修改真实玩家")
    Validation.Check(Traffic.GetStats().visible==0 and Traffic.GetStats().clonedCars==0,
        "反向纯逻辑fixture创建模型")
    Traffic.SetPlayerOverride(nil);Traffic.Shutdown()
end

function Start()
    local ok,message = xpcall(function()
        Validation.Phase("main_start",startGame)
        scene_ = assert(renderer:GetViewport(0).scene)
        Validation.Check(Train.GetSelectedId()=="CR400AF","8车EMU验收不能静默使用fallback车型")
        Validation.Census(scene_,"initial_local_world")
        test("open_route_and_0_1_2_sampling",routeChecks)
        test("idle_and_straight_gangway_rebuilds",idleChecks)
        test("historical_8_car_turnout_and_lock",turnoutChecks)
        test("low_fps_five_seconds_and_driving_modes",timeChecks)
        test("sixteen_spatial_cameras_and_real_cab",function() Validation.CameraChecks(assert(scene_)) end)
        test("real_touch_menu_pages_switches_and_modes",uiChecks)
        test("three_services_and_no_terminal_wrap",serviceAndTerminalChecks)
        test("traffic_safety_and_passing_trainclear",trafficChecks)
        test("reverse_passing_actual_tail_clear",reversePassingChecks)
        Train.Reset(Route.GetStations()[1].s+1)
        Traffic.SetPlayerOverride(nil);Traffic.Init(scene_)
        Game.Init();Camera.SetMode("chase")
        TogglePause()
        ready_=true
    end,debug.traceback)
    if not ok then
        log:Write(LOG_ERROR,tostring(message))
        error(message,0) -- Fail-loud: never turn a failed pcall into a PASS line.
    end
end

---@param eventType string
---@param eventData UpdateEventData
function HandleUpdate(eventType,eventData)
    Validation.Phase("main_update",function() updateGame(eventType,eventData) end)
    if not ready_ then return end
    frame_=frame_+1
    if frame_==76 then
        Validation.Census(assert(scene_),"logic_after_76_frames")
        local traffic=Traffic.GetStats()
        Validation.Check((traffic.errors or 0)==0,"实际AI模型克隆失败："..tostring(traffic.error))
        Validation.Check(traffic.visible>0 and traffic.visible<=traffic.maxVisible
            and traffic.clonedCars<=traffic.maxVisible*8,"实际AI可见8车编组未生成/超过有界数量")
        Validation.PrintPhases()
        print(string.format("ALL_RAIL_OPERATIONS_PASS cases=%d assertions=%d observedFrames=%d",
            Validation.cases,Validation.checks,frame_))
    end
end
---@param eventType string
---@param eventData PostUpdateEventData
function HandlePostUpdate(eventType,eventData)
    Validation.Phase("main_post_update",function() postUpdateGame(eventType,eventData) end)
end

return Validation
