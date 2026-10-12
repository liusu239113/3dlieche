-- 架空铁路验收：仅本测试文件可写；不修改生产代码，不在编写时运行Runtime/GPU/build。
-- 主线程入口 tests/FictionalRailValidation.lua；建议 -graphicsheadless -validate-frames=4200。
-- 每帧只恢复一次协程，每8个固定步/每256个三角形主动yield；不是frame1跑全套。
-- Visual通过HELPERS_ONLY载入本文件，不载入会覆盖Start的旧RailOperations测试。
require "main"
local startGame, updateGame, postGame, stopGame = Start, HandleUpdate, HandlePostUpdate, Stop
local Route = require "world.Route"
local Rail = require "world.RailNetwork"
local Train = require "train.Train"
local Game = require "game.Game"
local Traffic = require "game.Traffic"
local Passenger = require "game.PassengerService"
local Hud = require "ui.Hud"
local Audio = require "audio.AudioManager"
local Landmarks = require "world.Landmarks"
local Terrain = require "world.Terrain"
local Track = require "world.Track"
local Infrastructure = require "world.Infrastructure"
local Stream = require "world.WorldStream"
local Config = require "config.GameConfig"
local UI = require "urhox-libs/UI"

local V = {checks=0,cases=0,phases={},logicStatus="NOT_RUN",backgroundDraws=0,backgroundAlpha=-1}
V.MainStart,V.MainUpdate,V.MainPost,V.MainStop=startGame,updateGame,postGame,stopGame
V.Trains={
    {id="blue_white",name="沧羽 D12",horn="audio/sfx/fantasy/horn_d12.mp3"},
    {id="DF4D",name="赤峦 D18",horn="audio/sfx/fantasy/horn_d18.mp3"},
    {id="SS9G",name="苍穹 E21",horn="audio/sfx/fantasy/horn_e21.mp3"},
    {id="HXD3D",name="雷隼 E32",horn="audio/sfx/fantasy/horn_e32.mp3"},
    {id="CRH380A",name="流萤 M30",horn="audio/sfx/fantasy/horn_m30.mp3"},
    {id="CR400AF",name="星澜 M35",horn="audio/sfx/fantasy/horn_m35.mp3"},
}
V.Stations={"星汐总站","岚港站","榆岑站","镜澜站","云湾总站"}
---@type Scene?
local scene_ = nil
---@type Node?
local fixture_ = nil
---@type thread?
local runner_ = nil
local frame_,steps_,failed_,completed_ = 0,0,false,false
local backgroundRestore_ = function() end

---@param condition boolean
---@param message string
function V.Check(condition,message)
    V.checks=V.checks+1
    if not condition then error("[架空铁路自检] "..message,2) end
end
---@param a number
---@param b number
---@param epsilon number
---@param message string
function V.Near(a,b,epsilon,message)
    V.Check(a==a and b==b and math.abs(a-b)<=epsilon,
        string.format("%s：实际 %.9f / 预期 %.9f",message,a,b))
end
---@param a Vector3
---@param b Vector3
---@param epsilon number
---@param message string
function V.Point(a,b,epsilon,message) V.Check((a-b):Length()<=epsilon,message) end
---@param name string
---@param action fun():any
function V.Phase(name,action)
    local begin=os.clock()
    local result=table.pack(action())
    local elapsed=(os.clock()-begin)*1000
    local record=V.phases[name] or {count=0,totalMs=0,maxMs=0}
    record.count,record.totalMs=record.count+1,record.totalMs+elapsed
    record.maxMs=math.max(record.maxMs,elapsed)
    V.phases[name]=record
    return table.unpack(result,1,result.n)
end
function V.PrintPhases()
    local keys={}
    for key in pairs(V.phases) do keys[#keys+1]=key end
    table.sort(keys)
    for _,key in ipairs(keys) do
        local p=V.phases[key]
        print(string.format("[架空铁路自检] CPU_PHASE %s n=%d totalMs=%.3f maxMs=%.3f",key,p.count,p.totalMs,p.maxMs))
    end
end
local function pass(name)
    V.cases=V.cases+1
    print("[架空铁路自检] 通过："..name)
end
function V.Yield() coroutine.yield() end
local function budget()
    steps_=steps_+1
    if steps_%8==0 then V.Yield() end
end
local function eventFor(dt)
    local data=VariantMap();data["TimeStep"]=Variant(dt);return data
end
function V.MainStep(dt)
    updateGame("Update",eventFor(dt) --[[@as UpdateEventData]])
end
function V.SetPaused(paused)
    if Hud.GetReadings().paused~=paused then TogglePause() end
    V.Check(Hud.GetReadings().paused==paused,"主循环暂停状态未同步")
end

-- 复用真实协议而不是require旧tests、调用Button.props.onClick或伪造命中结果。
function V.Touch(kind,id,x,y)
    local types=UI.PointerEvent.Types
    local px,py=x*UI.GetScale(),y*UI.GetScale()
    -- 与引擎真实触摸同入口：RegisterPointer + Input listeners/Gesture + UI callback。
    -- 直接UI.HandlePointerEvent只投递widget，不产生ScrollView.OnPanMove，不能当滑动。
    if kind==types.PointerDown then UI.InputAdapter.HandleTouchBegin(id,px,py,.5)
    elseif kind==types.PointerMove then UI.InputAdapter.HandleTouchMove(id,px,py,.5)
    elseif kind==types.PointerUp then UI.InputAdapter.HandleTouchEnd(id,px,py)
    elseif kind==types.PointerCancel then UI.InputAdapter.HandleTouchCancel(id)
    else error("未知真实触摸协议类型："..tostring(kind)) end
end
function V.Tap(id)
    UI.Layout()
    local root=assert(Hud.GetRoot())
    local button=assert(root:FindById(id),"真实按钮缺失："..id) --[[@as Button]]
    local r=button:GetAbsoluteLayoutForHitTest()
    local w,h=UI.GetViewportSize()
    V.Check(r.w>0 and r.h>0 and r.x>=0 and r.y>=0 and r.x+r.w<=w+1 and r.y+r.h<=h+1,
        "真实按钮越屏/被裁："..id)
    V.Check(not button:IsDisabled() and UI.FindWidgetAt(r.x+r.w*.5,r.y+r.h*.5)==button,"真实按钮被遮挡/禁用："..id)
    local delivered=0
    local observe=function() delivered=delivered+1 end
    button:OnEvent("click",observe)
    V.Touch(UI.PointerEvent.Types.PointerDown,7921,r.x+r.w*.5,r.y+r.h*.5)
    V.Touch(UI.PointerEvent.Types.PointerUp,7921,r.x+r.w*.5,r.y+r.h*.5)
    if root:FindById(id)==button then button:OffEvent("click",observe) end
    V.Check(delivered==1,"真实触摸并未恰好投递一次click："..id)
end
function V.ScrollToButton(id)
    local function rect(r) return string.format("(%.2f,%.2f %.2fx%.2f)",r.x,r.y,r.w,r.h) end
    local function widgetName(widget)
        return widget and tostring(widget.props.id or widget.className or widget) or "nil"
    end
    for attempt=1,16 do
        UI.Layout()
        local root=assert(Hud.GetRoot())
        local button=assert(root:FindById(id)) --[[@as Button]]
        local target=button:GetAbsoluteLayoutForHitTest()
        local hit=UI.FindWidgetAt(target.x+target.w*.5,target.y+target.h*.5)
        local body=assert(root:FindById("operationsDetails")) --[[@as ScrollView]]
        local scroll=body:GetAbsoluteLayoutForHitTest()
        local actual=body:GetAbsoluteLayout()
        local sx,sy=body:GetScroll()
        local cw,ch=body:GetContentSize()
        local content=assert(body:GetChildAt(1)):GetAbsoluteLayoutForHitTest()
        local width,height=UI.GetViewportSize()
        print(string.format("[架空铁路自检] SCROLL_DIAG attempt=%d target=%s hit=%s disabled=%s visible=%s viewport=%.2fx%.2f scale=%.3f bodyHit=%s bodyActual=%s content=%s contentSize=%.2fx%.2f offset=(%.3f,%.3f) targetRect=%s",
            attempt,id,widgetName(hit),tostring(button:IsDisabled()),tostring(button:IsVisible()),width,height,
            UI.GetScale(),rect(scroll),rect(actual),rect(content),cw,ch,sx,sy,rect(target)))
        if hit==button then return end
        V.Check(scroll.h>20,"运营详情实际滚动视口太小")
        local x=scroll.x+scroll.w*.68
        local y=scroll.y+(target.y<scroll.y and scroll.h*.18 or scroll.h*.82)
        local endY=target.y<scroll.y and scroll.y+scroll.h*.82 or scroll.y+scroll.h*.17
        local startHit=UI.FindWidgetAt(x,y)
        print(string.format("[架空铁路自检] SWIPE_START hit=%s at=(%.2f,%.2f) endY=%.2f",widgetName(startHit),x,y,endY))
        V.Touch(UI.PointerEvent.Types.PointerDown,7922,x,y)
        V.Yield() -- 跨真实帧；Gesture使用引擎wall time，不能同帧六Move伪造手势时序。
        for j=1,6 do
            local moveY=y+(endY-y)*j/6
            V.Touch(UI.PointerEvent.Types.PointerMove,7922,x,moveY)
            local _,offset=body:GetScroll()
            print(string.format("[架空铁路自检] SWIPE_MOVE attempt=%d step=%d deltaY=%.3f offsetY=%.3f dragging=%s hit=%s",
                attempt,j,(endY-y)/6,offset,tostring(body.state.isDragging),widgetName(UI.FindWidgetAt(x,moveY))))
            V.Yield()
        end
        V.Touch(UI.PointerEvent.Types.PointerUp,7922,x,endY)
        V.Yield()
        UI.Update(.03)
    end
    error("[架空铁路自检] 16次真实InputAdapter/Gesture滑动仍未露出按钮："..id)
end

-- 实际Panel绘制调用探针：不修改库/生产文件，不替换像素/全局NVG函数。
-- 跟随真实RenderFullBackground调用，读取其实际GetRenderProp并调用原始绘制。
-- headless逻辑不宣称渲染通过；仅visual在真实渲染30帧后要求draws>0。
function V.InstallBackgroundProbe()
    local panel=assert(assert(Hud.GetRoot()):FindById("routeInfo"))
    local original=panel.RenderFullBackground
    local prior=rawget(panel,"RenderFullBackground")
    V.backgroundDraws,V.backgroundAlpha=0,-1
    rawset(panel,"RenderFullBackground",function(self,nvg,overrides)
        local color=overrides and overrides.backgroundColor or self:GetRenderProp("backgroundColor")
        V.Check(type(color)=="table" and color[4]>0 and color[4]<200,"真实信息Panel绘制背景不是半透明RGBA")
        V.Near(self:GetRenderProp("opacity") or 1,1,.001,"背景透明错误降低整个文字子树opacity")
        V.backgroundDraws,V.backgroundAlpha=V.backgroundDraws+1,color[4]
        return original(self,nvg,overrides)
    end)
    backgroundRestore_=function() rawset(panel,"RenderFullBackground",prior) end
    return backgroundRestore_
end
function V.CheckHudBounds()
    UI.Layout()
    local root=assert(Hud.GetRoot())
    local w,h=UI.GetViewportSize()
    local route=assert(root:FindById("routeInfo")):GetAbsoluteLayout()
    local operationPanel=assert(root:FindById("railwayControls"))
    local operations=operationPanel:GetAbsoluteLayoutForHitTest()
    local toggle=assert(root:FindById("toggleOperations"))
    local headerWidget=assert(toggle.parent)
    local header=headerWidget:GetAbsoluteLayoutForHitTest()
    local button=toggle:GetAbsoluteLayoutForHitTest()
    local function rect(r) return string.format("(%.3f,%.3f %.3fx%.3f)",r.x,r.y,r.w,r.h) end
    print(string.format("[架空铁路自检] HUD_BOUNDS_DIAG expanded=%s viewport=%.3fx%.3f scale=%.3f operationsActual=%s operationsHit=%s headerActual=%s headerHit=%s buttonActual=%s buttonHit=%s padding=(%s,%s,%s,%s) border=%s",
        tostring(Hud.GetReadings().operationsExpanded),w,h,UI.GetScale(),
        rect(operationPanel:GetAbsoluteLayout()),rect(operations),
        rect(headerWidget:GetAbsoluteLayout()),rect(header),rect(toggle:GetAbsoluteLayout()),rect(button),
        tostring(operationPanel.props.paddingTop),tostring(operationPanel.props.paddingRight),
        tostring(operationPanel.props.paddingBottom),tostring(operationPanel.props.paddingLeft),
        tostring(operationPanel.props.borderWidth)))
    V.Near(header.h,44,.01,"运营标题行实际布局不是44px")
    V.Near(button.h,44,.01,"运营折叠按钮实际布局不是44px")
    V.Check(header.y>=operations.y+1-.01 and header.y+header.h<=operations.y+operations.h-1+.01
        and button.x>=operations.x+1-.01 and button.x+button.w<=operations.x+operations.w-1+.01
        and button.y>=header.y-.01 and button.y+button.h<=header.y+header.h+.01,
        "44px运营标题/按钮被外Panel边框裁切")
    for _,y in ipairs({button.y+.5,button.y+button.h-.5}) do
        V.Check(UI.FindWidgetAt(button.x+button.w*.5,y)==toggle,"运营44px按钮顶部/底部不能完整命中")
    end
    if Hud.GetReadings().operationsExpanded then
        if w-24<900 or h-24<580 then
            V.Check(operations.h<=140+.01,"小屏运营展开实际总高超过140px")
        end
        local body=assert(root:FindById("operationsDetails")):GetAbsoluteLayoutForHitTest()
        V.Check(body.y>=header.y+header.h+2-.01 and body.y+body.h<=operations.y+operations.h-1+.01,
            "44px标题加间距后滚动视口被运营Panel裁切")
    end
    -- 通过现有换向按钮父链获取左下提示，不给生产HUD增加测试专用接口。
    local left=assert(assert(assert(root:FindById("reverser")).parent).parent)
    local hint=assert(left:GetChildAt(1))
    if hint:IsVisible() then
        local r=hint:GetAbsoluteLayoutForHitTest()
        V.Check(r.h>0 and operations.y+operations.h<=r.y+.01,"左下键盘提示被运营折叠/展开Panel覆盖")
    end
    V.Near(left:GetAbsoluteLayoutForHitTest().y-(operations.y+operations.h),12,.01,
        "运营Panel未按真实左下提示/按钮高度保留12px间距")
    for _,id in ipairs({"brakeHandle","throttleHandle","cycleCamera","openCameraSelector","toggleRouteInfo","toggleOperations"}) do
        local widget=assert(root:FindById(id))
        local r=widget:GetAbsoluteLayoutForHitTest()
        V.Check(r.w>0 and r.h>0 and r.x>=-1 and r.y>=-1 and r.x+r.w<=w+1 and r.y+r.h<=h+1,
            "小屏核心驾驶按钮实际越界："..id)
        V.Check(UI.FindWidgetAt(r.x+r.w*.5,r.y+r.h*.5)==widget,"小屏核心驾驶按钮被遮挡："..id)
        if id=="brakeHandle" or id=="throttleHandle" then
            local overlap=route.x<r.x+r.w and route.x+route.w>r.x and route.y<r.y+r.h and route.y+route.h>r.y
            V.Check(not overlap,"小屏信息Panel遮住核心驾驶手柄："..id)
        end
    end
end

-- 逐固定步追踪真实路径/首次完成位置。board终点inside；alight终点clear。
-- 示意：站台clear -> edge -> threshold -> inside（上）；反向下且最后走离站台。
-- 仅首次completed瞬间验证；之后下车者合法继续走天桥，不能再要求永远停在clear。
---@class FictionalPassengerTrace
---@field prior table<number,RailwayPassenger>
---@field done table<number,boolean>
---@field doors table<number,boolean>
---@field completed integer
function V.NewTrace() return {prior={},done={},doors={},completed=0} --[[@as FictionalPassengerTrace]] end
---@param trace FictionalPassengerTrace
---@param dt number
function V.ObservePassengers(trace,dt)
    local plan=Passenger.GetDoorPlan()
    for _,actor in ipairs(Passenger.GetPassengers()) do
        local prior=trace.prior[actor.id]
        if prior and actor.doorId==prior.doorId then
            V.Check((actor.position-prior.position):Length()<=actor.speed*dt+.005,
                "乘客一步瞬移超过真实步行速度："..actor.id)
        end
        if actor.completed and not trace.done[actor.id] and prior and not prior.completed then
            local door=assert(plan.doors[actor.doorId],"完成乘客没有实际门位")
            V.Point(actor.position,actor.kind=="boarding" and door.inside or door.clear,.015,
                "乘客未到实际门内/站台净空就被计数："..actor.id)
            V.Check(actor.walkDistance>.65,"乘客未实际走路就完成乘降")
            if actor.kind=="boarding" then
                V.Check(actor.state=="onboard" and not actor.visible,"已上车乘客仍站在站台")
                V.Check(#actor.targets>=4,"上车路径没有真实门槛/边缘/门内四阶段")
                V.Point(actor.targets[2],door.edge,.01,"上车路径绕过实际站台边缘")
                V.Point(actor.targets[3],door.position,.01,"上车路径绕过实际门槛")
                trace.doors[door.id]=true
            end
            trace.done[actor.id],trace.completed=true,trace.completed+1
        end
        trace.prior[actor.id]=actor
    end
end
---@param plan PassengerDoorPlan
---@param lane integer
function V.CheckDoorPlan(plan,lane)
    V.Check(plan.valid and plan.lane==lane and #plan.doors>=7,"实际客运门规划无效/不足")
    local cars=Train.GetCars()
    local covered={}
    for _,door in ipairs(plan.doors) do
        V.Check(door.side==(lane==2 and -1 or 1),"侧线/反向牵引错误翻转实际站台侧")
        V.Check(door.s>=Route.GetStations()[plan.stationIndex].s+Route.PlatformStart
            and door.s<=Route.GetStations()[plan.stationIndex].s+Route.PlatformEnd,"门位越出真实站台纵向包络")
        V.Check(door.clear.y>=plan.platformY and door.clear.y<=plan.platformY+.08,"候车脚点不在实际站台顶面")
        V.Check((door.position-door.edge):Length()<1.0,"乘客门位跨越另一条运营轨")
        local car=assert(cars[door.carIndex])
        V.Check(car.profile=="coach" or door.source=="simulated_flat_end_vestibule",
            "未实测EMU门位冒充真实资产门；机车不可乘降")
        if door.source=="simulated_flat_end_vestibule" then
            V.Check(car.frontEnd~=nil or car.rearEnd~=nil,"模拟门没有实测平端参考")
        end
        covered[door.carIndex]=true
    end
    local count=0;for _ in pairs(covered) do count=count+1 end
    V.Check(count>=7,"门规划漏掉可乘降客车")
end
local function fixedStep(dt,trace)
    local before=Passenger.GetPassengers()
    if trace then for _,p in ipairs(before) do trace.prior[p.id]=p end end
    V.MainStep(dt)
    if trace then V.ObservePassengers(trace,dt) end
    budget()
end
---@param actor RailwayPassenger
---@param plan PassengerDoorPlan
---@return number
local function remainingPath(actor,plan)
    if actor.completed then return 0 end
    local targets=actor.targets
    local first=actor.targetIndex
    if #targets==0 then
        local door=assert(plan.doors[actor.doorId],"待乘降人没有合法新门")
        targets=actor.kind=="boarding" and {door.clear,door.edge,door.position,door.inside}
            or {door.position,door.edge,door.clear}
        first=1
    end
    local distance=0
    local previous=actor.position
    for index=first,#targets do
        local nextPoint=assert(targets[index])
        distance=distance+(nextPoint-previous):Length()
        previous=nextPoint
    end
    return distance
end
local function dumpQueue(label,elapsed,trace)
    local status=Passenger.GetStatus()
    local plan=Passenger.GetDoorPlan()
    print(string.format("[架空铁路自检] QUEUE_%s elapsed=%.3f phase=%s ready=%s paused=%s speed=%.5f boarded=%d/%d alighted=%d/%d trace=%d doors=%d",
        label,elapsed,status.phase,tostring(status.ready),tostring(Passenger.IsPaused()),Train.GetSpeedMs(),
        status.boarded,status.totalBoarding,status.alighted,status.totalAlighting,trace.completed,#plan.doors))
    if label~="TIMEOUT" then return end
    for _,actor in ipairs(Passenger.GetPassengers()) do
        local distance=remainingPath(actor,plan)
        print(string.format("[架空铁路自检] QUEUE_ACTOR id=%d kind=%s state=%s door=%d completed=%s target=%d/%d remaining=%.3fm minSeconds=%.3f speed=%.3f walked=%.3f position=(%.3f,%.3f,%.3f)",
            actor.id,actor.kind,actor.state,actor.doorId,tostring(actor.completed),actor.targetIndex,#actor.targets,
            distance,distance/math.max(.01,actor.speed),actor.speed,actor.walkDistance,
            actor.position.x,actor.position.y,actor.position.z))
    end
end
---@param trace FictionalPassengerTrace
---@param requireAllDoors? boolean false only for nearest-door rebind after changing train
local function finishBoarding(trace,requireAllDoors)
    local total=Passenger.GetStatus().totalBoarding
    local plan=Passenger.GetDoorPlan()
    local doorCount=#plan.doors
    -- 同一door同一kind串行服务：每人实际剩余路径/speed相加，门间并行取max。
    -- 先下后上两相位相加，再加真实1.6s关门及离散步误差。不是盲放大到90s。
    local boarding,alighting={},{}
    for _,actor in ipairs(Passenger.GetPassengers()) do
        if not actor.completed then
            V.Check(actor.speed>0,"队列步速为0，不能用更长预算掩盖deadlock")
            local map=actor.kind=="boarding" and boarding or alighting
            map[actor.doorId]=(map[actor.doorId] or 0)+remainingPath(actor,plan)/actor.speed+.04
        end
    end
    local boardTime,alightTime=0,0
    for _,seconds in pairs(boarding) do boardTime=math.max(boardTime,seconds) end
    for _,seconds in pairs(alighting) do alightTime=math.max(alightTime,seconds) end
    local expected=boardTime+alightTime+1.6
    V.Check(expected<88,"真实门队列预计超过90秒硬预算，拒绝隐藏远门重绑/死锁")
    local seconds=math.min(90,math.max(6,expected+2))
    local maxSteps=math.ceil(seconds/.02)
    print(string.format("[架空铁路自检] QUEUE_BUDGET actualPathSerial=%.3fs allowed=%.3fs cap=90s allDoors=%s actors=%d doors=%d",
        expected,seconds,tostring(requireAllDoors~=false),total,doorCount))
    for step=1,maxSteps do
        fixedStep(.02,trace)
        if trace.completed>=total and Passenger.GetStatus().phase=="ready" then break end
        if not Passenger.HasActiveStop() then break end
        if step%250==0 then dumpQueue("PROGRESS",step*.02,trace) end
        if step==maxSteps then
            dumpQueue("TIMEOUT",step*.02,trace)
            V.Check(false,"真实乘客队列超出按实际剩余路径/门串行计算的有界预算")
        end
    end
    V.Check(trace.completed>=total and total>0,"真实登乘未完成全部候车人")
    local covered=0;for _ in pairs(trace.doors) do covered=covered+1 end
    if requireAllDoors~=false then V.Check(covered==doorCount,"可用门没有各自实际服务至少一人")
    else
        V.Check(covered>0 and covered<=doorCount,"换车近门重新绑定没有实际合法门完成")
        print(string.format("[架空铁路自检] REBOUND_DOORS %d/%d：换车保人位置后最近门服务；全部门覆盖另由未换车始发/侧线新stop严格验收",covered,doorCount))
    end
end

local function initialChecks()
    V.Check(Train.GetSelectedId()=="CR400AF" and Train.GetSelectedName()=="星澜 M35","真实默认八车不是星澜 M35")
    local status=Game.GetPassengerStatus()
    V.Check(status.totalBoarding>0 and not status.ready and status.doorsOpen,"始发没有真实候车/登乘联锁")
    V.Check(Game.GetXp()==0 and Game.GetOperatingStats().rewards==0,"始发未运营就给经验")
    V.CheckDoorPlan(Passenger.GetDoorPlan(),0)
    local s=Train.GetS()
    UI.Layout()
    local lever=assert(assert(Hud.GetRoot()):FindById("throttleHandle")) --[[@as CabLever]]
    local rect=lever:GetAbsoluteLayoutForHitTest()
    local displayed=Hud.GetReadings().throttle
    V.Touch(UI.PointerEvent.Types.PointerDown,7930,rect.x+rect.w*.6,rect.y+35)
    V.Touch(UI.PointerEvent.Types.PointerUp,7930,rect.x+rect.w*.6,rect.y+35)
    V.Check(Train.GetThrottle()==0 and Hud.GetReadings().throttle==displayed and lever.notch_==displayed,
        "真实牵引触摸在未ready时乐观更新仪表/调用牵引")
    Train.SetBrake(0);Train.SetThrottle(8)
    V.MainStep(.02)
    V.Near(Train.GetS(),s,.00001,"主循环绕过Game操作接口仍能在未乘降完成时牵引")
    V.Check(Train.GetThrottle()==0 and Train.GetBrake()==1,"Train.Update前没有强制乘客联锁")
    local actors=Passenger.GetPassengers()
    local xp,time=Game.GetXp(),Game.GetElapsed()
    V.SetPaused(true)
    for _=1,8 do V.MainStep(.25);Passenger.UpdateVisuals(.25);budget() end
    V.Near(Game.GetElapsed(),time,0,"暂停仍推进运营时间")
    local paused=Passenger.GetPassengers()
    V.Check(#paused==#actors,"暂停改变队列长度")
    for i,a in ipairs(actors) do
        V.Point(paused[i].position,a.position,.00001,"暂停仍推进乘客位置")
        V.Check(paused[i].completed==a.completed and paused[i].state==a.state,"暂停仍完成乘降阶段")
    end
    V.SetPaused(false)
    -- 未换车的真实始发仍严格覆盖全部合法门，不能为了换车nearest分配删掉此契约。
    local originalTrace=V.NewTrace()
    finishBoarding(originalTrace,true)
    V.Check(Game.GetXp()==0,"未换车真实始发完成后非法经验")
    pass("未换车EMU始发所有合法门实际完成位置")
    Train.Reset(s);Traffic.Reset(s);Game.Init();Game.UpdateHud(0)
    local trace=V.NewTrace()
    for _=1,24 do fixedStep(.02,trace) end
    local before=Passenger.GetPassengers();local count=Passenger.GetStatus().totalBoarding
    local done=Passenger.GetStatus().boarded
    V.Yield()
    V.Check(SelectTrain("DF4D"),"始发换车真实资源加载失败")
    V.MainStep(.02)
    local after=Passenger.GetPassengers()
    V.Check(#after==#before and Passenger.GetStatus().totalBoarding==count
        and Passenger.GetStatus().boarded>=done,"换车丢弃/重建候车队列或倒退已登乘数")
    for i,p in ipairs(before) do
        local retained=assert(after[i])
        V.Check(retained.id==p.id,"换车重新创建乘客id")
        V.Check((retained.position-p.position):Length()<=retained.speed*.02+.005,
            "换车保队列但把未完成人传送到新门")
        V.Check(retained.walkDistance>=p.walkDistance,"换车倒退真实累计步行路程")
    end
    -- 阈值/inside因换车变化；保留逻辑id后重新跟踪当前合法门，而非要求旧门坐标。
    trace.prior={}
    V.CheckDoorPlan(Passenger.GetDoorPlan(),0)
    finishBoarding(trace,false)
    for _=1,30 do fixedStep(.02) end
    V.Check(Game.GetXp()==xp and Game.GetOperatingStats().rewards==0,"完成始发登乘仍非法获得到站经验")
    V.Check(Passenger.GetStats().onboard==count,"候车数与实际车内manifest不一致")
    pass("始发逐门登乘/0经验/直接牵引联锁/暂停/换车保队列")
end

local function hudChecks()
    local saved=UI.GetScale()
    V.CheckHudBounds() -- 原布局先检查可见键盘提示与44px折叠标题，不仅测隐藏提示的小屏。
    -- 只改测试布局比例，不调用禁用SetMode、不冒充真实手机DPR。
    UI.SetScale(graphics:GetWidth()/640)
    UI.Update(.1);Hud.Update(0);UI.Layout()
    local w,h=UI.GetViewportSize()
    print(string.format("[架空铁路自检] 小屏布局fixture base=%.0fx%.0f physical=%dx%d realDPR=%.2f（不是手机听感/性能验收）",w,h,graphics:GetWidth(),graphics:GetHeight(),graphics:GetDPR()))
    V.Check(w<900 and h<580,"小屏fixture未实际进入紧凑布局")
    Hud.SetRouteExpanded(false);Hud.SetOperationsExpanded(false)
    V.CheckHudBounds()
    V.Tap("toggleRouteInfo")
    V.Check(Hud.GetReadings().routeExpanded,"真实详情触摸未展开")
    V.CheckHudBounds()
    local root=assert(Hud.GetRoot())
    local handle=assert(root:FindById("brakeHandle")):GetAbsoluteLayoutForHitTest()
    local x,y=handle.x+handle.w*.5,handle.y+handle.h*.5
    V.Touch(UI.PointerEvent.Types.PointerDown,7923,x,y)
    V.Check(Hud.GetReadings().brakeHeld,"核心制动真实触摸未进入hold")
    V.Tap("toggleOperations")
    V.Check(Hud.GetReadings().operationsExpanded and not Hud.GetReadings().routeExpanded,"小屏展开详情没有互斥折叠")
    V.Check(Hud.GetReadings().brakeHeld,"第二指切面板释放了核心制动owner")
    V.CheckHudBounds()
    V.Touch(UI.PointerEvent.Types.PointerUp,7924,x,y)
    V.Check(Hud.GetReadings().brakeHeld,"非owner抬指非法释放核心制动")
    V.Touch(UI.PointerEvent.Types.PointerUp,7923,x,y)
    V.Check(not Hud.GetReadings().brakeHeld,"owner抬指未释放核心制动")
    V.ScrollToButton("nextService")
    local previous=Game.GetService()
    V.Tap("nextService")
    V.Check(Game.GetService()~=previous,"实际滑动后服务按钮没有改变权威Game状态")
    V.ScrollToButton("openTrainSelector");V.Tap("openTrainSelector")
    V.Check(Hud.IsTrainSelectorOpen() and Hud.GetReadings().paused,"实际滑到车型按钮后没有模态暂停")
    V.Tap("cancelTrainSelection")
    V.Check(not Hud.IsTrainSelectorOpen(),"真实车型菜单无法取消")
    V.ScrollToButton("toggleSound")
    local enabled=Audio.IsEnabled();V.Tap("toggleSound")
    V.Check(Audio.IsEnabled()~=enabled and Hud.GetReadings().soundEnabled==Audio.IsEnabled(),"声音真实按钮未连接Audio权威状态")
    V.Tap("toggleSound")
    V.Check(Audio.IsEnabled()==enabled,"声音真实按钮不能恢复")
    local snapshot=Hud.GetReadings().passenger
    snapshot.boarded=9999
    V.Check(Hud.GetReadings().passenger.boarded~=9999,"HUD只读副本暴露内部可变客运状态")
    local panel=assert(root:FindById("routeInfo"))
    V.Check(panel.Render==UI.Panel.Render,"信息Panel仍使用强制不透明Metal渲染")
    V.Check(panel:GetRenderProp("backgroundColor")[4]==142,"真实Panel背景属性并非alpha142")
    print("[架空铁路自检] 背景实际绘制调用 NOT_RUN（headless）；必须由Visual真实GPU探针验收，非声明PASS")
    Hud.SetOperationsExpanded(false);Hud.SetRouteExpanded(false)
    Game.SetService("local")
    UI.SetScale(saved);UI.Update(.1);Hud.Update(0);UI.Layout()
    pass("小屏真实触摸折叠/滑动/核心制动多指/声音开关")
end

local function audioAdvance(speed,notch,n)
    for i=1,n do Audio.Update(.02,speed,notch,20);if i%8==0 then V.Yield() end end
end
local function loopMap()
    local map={}
    local d=Audio.GetDiagnostics()
    for _,e in ipairs(d.loops) do map[e.id]={frequency=e.frequency,gain=e.gain,play=e.playCalls} end
    for _,e in ipairs(d.environmentLoops) do map[e.id]={frequency=e.frequency,gain=e.gain,play=e.playCalls} end
    return map
end
function V.CheckAudioLoops()
    local d=Audio.GetDiagnostics()
    V.Check(d.initialized and #d.loops==4 and next(d.failedClips)==nil,"音频源初始化/四层循环/资源失败")
    local ids={}
    local totalGain=0
    for _,group in ipairs({d.loops,d.environmentLoops}) do
        for _,e in ipairs(group) do
            V.Check(not ids[e.id] and e.playing and e.looped,"循环源重复id/未播放/不是loop")
            ids[e.id]=true
            V.Check(e.frequency>1000 and e.frequency<300000 and e.duration>.2 and e.rms>0.00001,
                "真实PCM循环频率/长度/有效RMS无效："..e.id)
            V.Check(e.playCalls==1 and e.restarts==0,"健康循环被每Update重播："..e.id)
            if not e.generatedEnvironment then
                V.Check(math.abs(e.periodicClosureDelta)<1e-8,"解析循环端点不连续："..e.id)
            else
                V.Check(e.resourcePath~="" and e.samples>0,"生成环境床并未读取真实PCM资源")
            end
            totalGain=totalGain+e.gain
        end
    end
    V.Check(totalGain>.02 and d.loopSourcesAudible>0,"循环声明playing但实际gain全为0")
    return d
end
local function audioChecks()
    Audio.SetEnabled(true);Audio.SetSuspended(false)
    for _,train in ipairs(V.Trains) do
        V.Yield()
        V.Check(SelectTrain(train.id),"六架空车真实选择失败："..train.name)
        V.Check(Train.GetSelectedName()==train.name,"车型展示名仍是现实品牌："..train.id)
        audioAdvance(0,0,80)
        local idle=V.CheckAudioLoops()
        V.Check(idle.trainId==train.id and idle.trainName==train.name and idle.hornPath==train.horn,"音频车型身份不同步")
        local horn=assert(cache:GetResource("Sound",train.horn)) --[[@as Sound]]
        V.Check(horn:GetLength()>.2 and horn:GetLength()<12 and horn:GetDataSize()>1000,"真实horn MP3没有有效长度/解码数据")
        V.Near(horn:GetFrequency(),48000,1,"真实缓存horn采样率不是48kHz")
        V.Check(not horn:IsLooped() and Audio.PlayHorn(),"horn未以真实单次资源播放")
        V.Check(not Audio.GetDiagnostics().hornUsingFallback,"存在六horn却偷偷回退程序horn")
        print(string.format("[架空铁路自检] HORN_RESOURCE %s path=%s seconds=%.3f frequency=%.0f",train.name,train.horn,horn:GetLength(),horn:GetFrequency()))
        local initial=loopMap()
        local owned=Audio.GetDiagnostics().ownedSoundCount
        audioAdvance(0,8,50)
        local loaded=V.CheckAudioLoops();local traction=false
        for _,e in ipairs(loaded.loops) do if e.layer=="traction" then traction=e.gain>.01 end end
        V.Check(traction,"0kmh加牵引没有实际非零traction混音")
        audioAdvance(90,0,50)
        local rolling,wind,changed=false,false,false
        for _,e in ipairs(V.CheckAudioLoops().loops) do
            if e.layer=="rolling" then rolling=e.gain>.01 end
            if e.layer=="wind" then wind=e.gain>.001 end
            if initial[e.id] and math.abs(initial[e.id].frequency-e.frequency)>10 then changed=true end
        end
        V.Check(rolling and wind and changed,"惰行速度没有实际rolling/wind增益与frequency连续调制")
        V.Check(Audio.GetDiagnostics().ownedSoundCount==owned,"普通Update不断生成新Sound资源")
        local before=loopMap();local elapsed=Audio.GetDiagnostics().elapsed
        Audio.SetSuspended(true)
        audioAdvance(90,8,8)
        local stopped=Audio.GetDiagnostics()
        V.Check(stopped.loopsPaused and stopped.loopSourcesAudible==0,"暂停只标志位但循环仍可闻")
        V.Near(stopped.elapsed,elapsed,0,"暂停推进音频逻辑")
        for _,group in ipairs({stopped.loops,stopped.environmentLoops}) do
            for _,e in ipairs(group) do V.Near(e.gain,0,.000001,"暂停实际source gain非零") end
        end
        Audio.SetSuspended(false);audioAdvance(40,3,50)
        local restored=loopMap()
        for id,value in pairs(before) do V.Check(restored[id] and restored[id].play==value.play,"暂停恢复重建源/重播造成相位丢失") end
        V.CheckAudioLoops()
    end
    local envIds={}
    for _,kind in ipairs({"city","forest","river","tunnel","city","forest","river","tunnel"}) do
        V.Yield();V.Check(Audio.SetEnvironment(kind),"真实环境声音不支持："..kind)
        audioAdvance(45,2,70)
        local d=V.CheckAudioLoops();local audible=false
        for _,e in ipairs(d.environmentLoops) do
            if e.layer==kind or e.layer==kind.."_detail" then audible=audible or e.gain>.01 end
            if envIds[e.layer] then V.Check(envIds[e.layer]==e.id,"重复环境切换累计新源") else envIds[e.layer]=e.id end
        end
        V.Check(d.environment==kind and audible,"环境混音只改标签未生效")
    end
    V.Check(Audio.AnnounceArrival(1),"架空到站提示未播放")
    local announcement=Audio.GetDiagnostics()
    V.Check(announcement.announcementProcedural and announcement.announcementPath==""
        and announcement.announcementSoundId:find("chime",1,true)~=nil,"混入现实车站真人广播")
    V.Check(Audio.AnnounceDeparture(5),"架空发车提示未播放")
    V.Check(Audio.GetDiagnostics().announcementPath=="","发车提示仍引用现实广播路径")
    V.Check(not Audio.SetTrainId("not_a_train"),"未知音频车型id被接受")
    V.Check(SelectTrain("CR400AF"),"音频测试不能恢复星澜")
    audioAdvance(0,0,80);V.CheckAudioLoops()
    print("[架空铁路自检] AUDIO_PROGRAM_RESOURCE_PASS；听感 NOT_RUN（即使audioDevicePlaying=true也不代表人耳验收；禁止-nosound宣称听感PASS）")
    pass("六horn真实缓存/连续混音频率/非零增益/暂停恢复/换车源收敛/架空提示")
end

-- 真正从未占岔区连续驶入，正向从入口、反向从全列已清出口。只用于门位fixture。
-- 不通过Reset到已占用侧线，不篡改Rail.GetChoices返回表。
function V.DriveIntoSiding(station,reversing)
    local start=reversing and station.s+Rail.YardEnd+Train.GetActiveLength()+80 or station.s+Rail.YardStart-80
    Train.Reset(start)
    if reversing then V.Check(Train.ToggleReversing(),"反向侧线fixture无法换向") end
    V.Check(Rail.SetPlayerChoice(1,start,Train.GetActiveLength(),reversing),"实际侧线无法提前选路")
    Train.SetDrivingMode("relaxed")
    local target=station.s+5
    for step=1,6000 do
        local distance=(reversing and -1 or 1)*(target-Train.GetS())
        local speed=math.abs(Train.GetSpeedMs())
        if distance<.5 then Train.EmergencyBrake()
        else
            local desired=math.min(10,math.sqrt(2*.40*math.max(0,distance-1)))
            if speed>desired+.15 then Train.SetThrottle(0);Train.SetBrake(.45)
            elseif speed<desired-.15 then Train.SetBrake(0);Train.SetThrottle(4)
            else Train.SetThrottle(0);Train.SetBrake(0) end
        end
        Train.Update(.1)
        if distance<15 and speed<=.02 then break end
        if step%8==0 then V.Yield() end
        V.Check(step<6000,"实际侧线驶入超过600秒有界预算")
    end
    Train.EmergencyBrake();Train.UpdateVisuals(0)
    V.Check(Rail.GetPlayerLane(Train.GetS())==2,"真实连续驶入并未在侧线")
    for _,car in ipairs(Train.GetCars()) do
        V.Check(Rail.GetPlayerLane(Train.GetS()+car.offset)==2,"侧线门位fixture有车仍在正线/咽喉")
    end
end
local function sidingChecks()
    V.SetPaused(true)
    for _,reverse in ipairs({false,true}) do
        V.DriveIntoSiding(Route.GetStations()[3],reverse)
        Traffic.Reset(Train.GetS());Game.Init();Game.UpdateHud(0)
        V.CheckDoorPlan(Passenger.GetDoorPlan(),2)
        V.SetPaused(false)
        local trace=V.NewTrace();finishBoarding(trace)
        V.Check(Game.GetXp()==0,"侧线新游戏初始登乘被奖励")
        V.SetPaused(true)
        pass(reverse and "真实反向侧线逐门登乘" or "真实正向侧线逐门登乘")
    end
end
local function driveShortArrival(station,reversing)
    -- 仅迁移线路位置fixture；保留Passenger onboard/Game奖励锁存。到站前仍实际走>=120m。
    Train.Reset(station.s+(reversing and 180 or -180))
    if reversing then Train.ToggleReversing() end
    Traffic.Reset(Train.GetS())
    -- 公开任务切换重新选择当前位置方向必停站，不调用Arrive、不伪造moving。
    Game.SetService("express");Game.SetService("local")
    V.Check(Game.GetNextStation().index==station.index,"短途真实驶入fixture站序不正确")
    for step=1,2200 do
        local remaining=(reversing and -1 or 1)*(station.s-Train.GetS())
        local speed=math.abs(Train.GetSpeedMs())
        if remaining<.5 then Train.EmergencyBrake()
        else
            local target=math.min(5,math.sqrt(.8*math.max(0,remaining-2)))
            if speed>target+.12 then Train.SetThrottle(0);Train.SetBrake(.5)
            elseif speed<target-.12 then Train.SetBrake(0);Train.SetThrottle(4)
            else Train.SetThrottle(0);Train.SetBrake(0) end
        end
        Train.Update(.05)
        Game.Update(.05)
        if Game.IsDwelling() then break end
        if step%8==0 then V.Yield() end
        V.Check(step<2200,"实际短途到站超过110秒预算")
    end
    V.Check(Game.IsDwelling() and Passenger.HasActiveStop(),"真实牵引/停稳没有产生客运到站")
end
local function terminalChecks()
    -- 上一侧线完成后先正常发车结束活跃stop；只保留真实manifest。
    V.SetPaused(false)
    for _=1,1000 do
        fixedStep(.02)
        if not Passenger.HasActiveStop() then break end
    end
    V.Check(not Passenger.HasActiveStop(),"已完成侧线乘降仍不能结束stop")
    driveShortArrival(Route.GetStations()[5],false)
    local trace=V.NewTrace()
    local alighters=Passenger.GetStatus().totalAlighting
    V.Check(alighters>0 and Passenger.GetStatus().totalBoarding==0,"终到没有实际manifest下车/非法上新客")
    local before=Game.GetXp()
    for step=1,2000 do
        fixedStep(.02,trace)
        if Game.IsTerminal() then break end
        V.Check(step<2000,"终到下车关门未在40秒预算完成")
    end
    V.Check(Game.IsTerminal() and Passenger.GetStats().onboard==0 and trace.completed==alighters,
        "终到未全部实际下车就进入终端")
    V.Check(Game.GetXp()>before and Game.GetOperatingStats().completedTrips>=1,"真实终到乘降/行驶未结算奖励")
    local awarded,journey=Game.GetXp(),Game.GetOperatingStats().journeyId
    for _=1,4 do Game.SetService("express");Game.SetService("local");fixedStep(.02) end
    V.Check(Game.GetXp()==awarded and Game.GetOperatingStats().journeyId==journey,"终到原地任务切换刷经验/新旅程")
    V.Check(Train.ToggleReversing(),"终到手动换向失败")
    fixedStep(.02)
    V.Check(Game.GetOperatingStats().journeyId==journey+1 and Passenger.GetStatus().totalBoarding>0
        and not Game.CanDepart(),"终到折返跳过新候车登乘")
    local returnTrace=V.NewTrace();finishBoarding(returnTrace)
    for _=1,700 do fixedStep(.02);if not Passenger.HasActiveStop() then break end end
    V.Check(Game.GetXp()==awarded,"折返原地新登乘重发终到经验")
    V.Check(not Passenger.HasActiveStop(),"折返新乘客完成后无法发车")
    driveShortArrival(Route.GetStations()[4],true)
    local nextTrace=V.NewTrace()
    for step=1,2200 do
        fixedStep(.02,nextTrace)
        if Game.GetXp()>awarded then break end
        V.Check(step<2200,"新旅程真实到站奖励未完成")
    end
    V.Check(Game.GetXp()>awarded,"新旅程实走/乘降后没有新奖励")
    local newXp=Game.GetXp()
    for _=1,16 do Game.SetService("express");Game.SetService("local");fixedStep(.02) end
    V.Check(Game.GetXp()==newXp,"新旅程同站原地切任务重复奖励")
    pass("终到真实全下车/折返新登乘/新旅程奖励/禁止原地刷")
    V.SetPaused(true)
end

-- 三角形均来自实际CustomGeometry或Model CPU VB/IB，不由definitions重新合成表面。
---@class FictionalTriangle
---@field a Vector3
---@field b Vector3
---@field c Vector3
---@field normal Vector3
---@field name string
---@field mask integer
---@field minX number
---@field maxX number
---@field minY number
---@field maxY number
---@field minZ number
---@field maxZ number
---@param root Node
---@param cooperative boolean?
---@param include? fun(name:string):boolean
---@return FictionalTriangle[]
function V.ReadTriangles(root,cooperative,include)
    local out={} ---@type FictionalTriangle[]
    ---@param a Vector3
    ---@param b Vector3
    ---@param c Vector3
    ---@param normal Vector3
    ---@param name string
    ---@param mask integer
    local function add(a,b,c,normal,name,mask)
        local cross=(b-a):CrossProduct(c-a)
        if cross:LengthSquared()>1e-12 then
            out[#out+1]={a=a,b=b,c=c,normal=normal,name=name,mask=mask,
                minX=math.min(a.x,b.x,c.x),maxX=math.max(a.x,b.x,c.x),
                minY=math.min(a.y,b.y,c.y),maxY=math.max(a.y,b.y,c.y),
                minZ=math.min(a.z,b.z,c.z),maxZ=math.max(a.z,b.z,c.z)}
        end
        if cooperative and #out%256==0 then V.Yield() end
    end
    for _,g in ipairs(root:GetComponents("CustomGeometry",true)) do
        if not include or include(g.node.name) then
            local transform=g.node.worldTransform
            for slot=0,g.numGeometries-1 do
                local n=g:GetNumVertices(slot)
                V.Check(n%3==0,"实际CG不是完整triangle list")
                for k=0,n-3,3 do
                    local a,b,c=g:GetVertex(slot,k),g:GetVertex(slot,k+1),g:GetVertex(slot,k+2)
                    add(transform*a.position,transform*b.position,transform*c.position,a.normal,g.node.name,g.viewMask)
                end
            end
        end
    end
    for _,draw in ipairs(root:GetComponents("StaticModel",true)) do
        local model=assert(draw.model)
        for slot=0,model.numGeometries-1 do
            local g=assert(model:GetGeometry(slot,0))
            V.Check(g.primitiveType==TRIANGLE_LIST,"实际Model不是triangle list")
            local vb=assert(g:GetVertexBuffer(0))
            V.Check(vb:HasElement(SEM_POSITION,0),"实际Model VB缺position")
            local data=vb:GetData();local offset=vb:GetElementOffset(SEM_POSITION,0)
            local ib=g:GetIndexBuffer()
            local indices=ib and ib:GetData() or VectorBuffer()
            local count=ib and g.indexCount or g.vertexCount
            V.Check(data:GetSize()>=vb.vertexCount*vb.vertexSize,"实际Model CPU顶点数据不可读")
            local function vertex(index)
                data:Seek(index*vb.vertexSize+offset)
                return draw.node.worldTransform*data:ReadVector3()
            end
            for k=0,count-3,3 do
                local i0,i1,i2=g.vertexStart+k,g.vertexStart+k+1,g.vertexStart+k+2
                if ib then
                    indices:Seek((g.indexStart+k)*ib.indexSize)
                    if ib.indexSize==2 then i0,i1,i2=indices:ReadUShort(),indices:ReadUShort(),indices:ReadUShort()
                    else i0,i1,i2=indices:ReadUInt(),indices:ReadUInt(),indices:ReadUInt() end
                end
                local a,b,c=vertex(i0),vertex(i1),vertex(i2)
                add(a,b,c,(b-a):CrossProduct(c-a):Normalized(),draw.node.name,draw.viewMask)
            end
        end
    end
    return out
end
-- 双面Moller-Trumbore，不以包含空洞的AABB冒充实体面；只用AABB作加速排除。
---@param triangles FictionalTriangle[]
---@param origin Vector3
---@param direction Vector3
---@param maxDistance number
---@param filter? fun(t:FictionalTriangle):boolean
---@return number, FictionalTriangle?
function V.Ray(triangles,origin,direction,maxDistance,filter)
    local nearest,hit=maxDistance,nil
    local endPoint=origin+direction*maxDistance
    local minX,maxX=math.min(origin.x,endPoint.x)-.001,math.max(origin.x,endPoint.x)+.001
    local minY,maxY=math.min(origin.y,endPoint.y)-.001,math.max(origin.y,endPoint.y)+.001
    local minZ,maxZ=math.min(origin.z,endPoint.z)-.001,math.max(origin.z,endPoint.z)+.001
    for _,t in ipairs(triangles) do
        local intersects=t.maxX>=minX and t.minX<=maxX
            and t.maxY>=minY and t.minY<=maxY and t.maxZ>=minZ and t.minZ<=maxZ
        if intersects and (not filter or filter(t)) then
            local e1,e2=t.b-t.a,t.c-t.a
            local p=direction:CrossProduct(e2)
            local determinant=e1:DotProduct(p)
            if math.abs(determinant)>1e-9 then
                local inv=1/determinant
                local delta=origin-t.a
                local u=delta:DotProduct(p)*inv
                if u>=-.00001 and u<=1.00001 then
                    local q=delta:CrossProduct(e1)
                    local v=direction:DotProduct(q)*inv
                    if v>=-.00001 and u+v<=1.00001 then
                        local distance=e2:DotProduct(q)*inv
                        if distance>=0 and distance<nearest then nearest,hit=distance,t end
                    end
                end
            end
        end
    end
    return nearest,hit
end
local function matches(text) return function(t) return t.name:find(text,1,true)~=nil end end
local function actualGroundCheck(def)
    local root=assert(Stream.GetStats().root)
    for _,g in ipairs(root:GetComponents("CustomGeometry",true)) do
        if g.node.name:find("远景土地保底",1,true) then
            local tris=V.ReadTriangles(g.node,true)
            for _,offset in ipairs({-180,0,180}) do
                local origin=Route.SampleOffset(def.s,offset,2)
                local _,hit=V.Ray(tris,origin,Vector3(0,-1,0),4)
                V.Check(not hit,"实际保底mesh盖住桥下谷地（只改declared cut无效）")
            end
            local outside=Route.SampleOffset(def.s,800,2)
            local _,hit=V.Ray(tris,outside,Vector3(0,-1,0),4)
            V.Check(hit~=nil,"谷地裁切顺便删掉整个远景保底")
            return
        end
    end
    error("[架空铁路自检] 没找到真实Terrain保底CG")
end
function V.CheckLandmarkMesh(root,def,cooperative,structureS)
    local triangles=V.ReadTriangles(root,cooperative,function(name)
        -- 仍构建真实详细钢轨/枕木；净空射线只读涉及轨头、导线、桥隧和河谷的实体面。
        return name=="SharedRunningHeads" or name=="SharedDistantRails"
            or name:find("AllElectrifiedLaneWires",1,true)~=nil
            or name:find("连续可见内衬",1,true)~=nil or name:find("开口混凝土门户",1,true)~=nil
            or name:find("留洞山体外壳",1,true)~=nil or name:find("轨下桥面梁墩",1,true)~=nil
            or name:find("实际深谷坡面",1,true)~=nil or name:find("横穿铁路河流",1,true)~=nil
    end)
    local sampleS=structureS or def.s
    V.Check(#triangles>30,"实际桥隧fixture没有实体mesh")
    local railFilter=function(t) return t.name=="SharedRunningHeads" or t.name=="SharedDistantRails" end
    local wireFilter=matches("AllElectrifiedLaneWires")
    for _,ds in ipairs({-8,0,8}) do
        local s=sampleS+ds
        for lane=0,2 do
            local p=Rail.Sample(s,lane)
            local right=Route.RightAt(s)
            local rail=Track.GetDimensions().railCentreOffset
            for _,side in ipairs({-1,1}) do
                local origin=p+right*(rail*side)+Vector3(0,1,0)
                local distance,hit=V.Ray(triangles,origin,Vector3(0,-1,0),2,railFilter)
                V.Check(hit~=nil,"桥隧内真实钢轨面不存在：lane"..lane)
                V.Near(origin.y-distance,p.y+.34,.003,"桥隧实际轨头改变标高")
            end
            -- 横向穿过真实wire截面，在6.10和6.84..7.05检查；zigzag允许±.18。
            local contactOrigin=p-right*.35+Vector3(0,6.10,0)
            local _,contact=V.Ray(triangles,contactOrigin,right,.7,wireFilter)
            V.Check(contact~=nil,"桥隧没有连续真实接触线：lane"..lane)
            local messenger=false
            for sample=0,26 do
                local origin=p-right*.35+Vector3(0,6.82+sample*.01,0)
                local _,hit=V.Ray(triangles,origin,right,.7,wireFilter)
                messenger=messenger or hit~=nil
            end
            V.Check(messenger,"桥隧没有连续真实承力索：lane"..lane)
            if cooperative then V.Yield() end
            if def.kind=="tunnel" then
                local origin=p+Vector3(0,7.10,0)
                local distance,hit=V.Ray(triangles,origin,Vector3.UP,20,matches("连续可见内衬"))
                V.Check(hit~=nil and distance>1.5,"实际隧道拱面穿入承力索/受电弓净空")
                V.Check(hit.mask & 4~=0 and hit.mask & 2~=0,"隧道实体不参与相机避墙/世界显示")
                local _,blocked=V.Ray(triangles,p+Vector3(0,2.5,0),Route.TangentAt(s),10,
                    function(t) return t.name:find("连续可见内衬",1,true) or t.name:find("开口混凝土门户",1,true) or t.name:find("留洞山体外壳",1,true) end)
                V.Check(not blocked,"隧道实际实体面封住运营轨通道")
            else
                local origin=p+Vector3(0,.0,0)
                local distance,hit=V.Ray(triangles,origin,Vector3(0,-1,0),3,matches("轨下桥面梁墩"))
                V.Check(hit~=nil,"桥下没有真实承轨桥面")
                V.Near(origin.y-distance,-.18,.006,"桥面实际实体顶不是轨下-.18")
            end
        end
    end
    if def.kind=="tunnel" then
        local center=Route.SampleOffset(def.s,-2.5,2.5)
        local right=Route.RightAt(def.s)
        for _,side in ipairs({-1,1}) do
            local distance,wall=V.Ray(triangles,center,right*side,20,matches("连续可见内衬"))
            V.Check(wall~=nil,"隧道实际侧墙三角不可测")
            V.Near(distance,9.5,.01,"实际侧墙内半宽不是9.5米/center不是-2.5")
        end
        local crown,roof=V.Ray(triangles,Route.SampleOffset(def.s,-2.5,7.1),Vector3.UP,20,matches("连续可见内衬"))
        V.Check(roof~=nil,"隧道实际冠顶三角不可测")
        V.Near(7.1+crown,12.6,.015,"实际拱顶不是12.6米")
        local count=0
        for _,t in ipairs(triangles) do
            if t.name:find("连续可见内衬",1,true) or t.name:find("开口混凝土门户",1,true) then
                local cross=(t.b-t.a):CrossProduct(t.c-t.a):Normalized()
                V.Check(cross:DotProduct(t.normal)>.98,"隧道实际三角正反面绕序与法线不一致")
                count=count+1
            end
        end
        V.Check(count>20,"隧道没有真实双面内衬/门户")
    else
        local origin=Route.SampleOffset(def.s,120,5)
        local valley,earth=V.Ray(triangles,origin,Vector3(0,-1,0),100,matches("实际深谷坡面"))
        V.Check(earth~=nil and origin.y-valley < -20,"桥下实际mesh没有20米以上深谷")
        local waterOrigin=Route.SampleOffset(def.s,-2.5,5)
        local water,river=V.Ray(triangles,waterOrigin,Vector3(0,-1,0),100,matches("横穿铁路河流"))
        V.Check(river~=nil and math.abs(waterOrigin.y-water-def.waterY)<.02,"桥下没有实际横穿河流面")
    end
    print(string.format("[架空铁路自检] ACTUAL_MESH %s %s triangles=%d，实体三角采样而非声明",def.id,def.kind,#triangles))
end
local function worldChecks()
    local defs=Landmarks.GetLandmarks()
    local selected={}
    for _,def in ipairs(defs) do if def.kind=="bridge" or def.kind=="tunnel" then selected[#selected+1]=def end end
    V.Check(#selected==4,"世界并非两桥两隧完整规划")
    local expected={rail_bridge_1={8000,8640},rail_bridge_4={55362.634,56082.634},
        rail_tunnel_2={21998.230,23598.230},rail_tunnel_3={32606.882,34366.882}}
    for _,def in ipairs(selected) do
        V.Near(def.first,expected[def.id][1],.02,"桥隧实际弧长起端偏移")
        V.Near(def.last,expected[def.id][2],.02,"桥隧实际弧长终端偏移")
        V.Check(Landmarks.GetEnvironmentAt(def.s)==(def.kind=="tunnel" and "tunnel" or "water"),"真实环境分类不跟桥隧位置")
        V.Check(Audio.SetEnvironment(Landmarks.GetEnvironmentAt(def.s)),"真实世界环境标签没有音频映射")
        fixture_=assert(scene_):CreateChild("FictionalMeshFixture_"..def.id)
        Landmarks.BuildChunk(fixture_,def.s-20,def.s+20,V.Yield)
        Track.BuildChunk(fixture_,def.s-20,def.s+20,true,V.Yield)
        Infrastructure.BuildChunk(fixture_,def.s-20,def.s+20,V.Yield)
        V.CheckLandmarkMesh(fixture_,def,true)
        if def.kind=="bridge" then actualGroundCheck(def) end
        fixture_:Dispose();fixture_=nil
        Landmarks.ForgetChunk(def.s-20,def.s+20)
        if def.kind=="tunnel" then
            -- 入口实际门户洞心必须无实体端盖；只在已定义真实起点建局部40米。
            fixture_=assert(scene_):CreateChild("FictionalPortalFixture_"..def.id)
            Landmarks.BuildChunk(fixture_,def.first,def.first+40,V.Yield)
            local triangles=V.ReadTriangles(fixture_,true)
            for lane=0,1 do
                local p=Rail.Sample(def.first-2,lane)+Vector3(0,2.0,0)
                local _,hit=V.Ray(triangles,p,Route.TangentAt(def.first),10)
                V.Check(not hit,"真实门户/山体端盖封住轨道洞口")
            end
            fixture_:Dispose();fixture_=nil;Landmarks.ForgetChunk(def.first,def.first+40)
        end
        V.Yield()
    end
    -- 接缝检测：两个独立240m半开块，在边界两侧±8m测实际轨头/电线/拱墙/桥面。
    -- 桥墩：横向射线穿过柱身，柱脚向下穿入实际谷基；不以AABB充当实体支撑。
    for _,def in ipairs(selected) do
        local seam=math.floor(def.s/240)*240
        fixture_=assert(scene_):CreateChild("ChunkSeam_"..def.id)
        for _,a in ipairs({seam-240,seam}) do
            Landmarks.BuildChunk(fixture_:CreateChild("SeparateChunk"),a,a+240,V.Yield)
            Track.BuildChunk(fixture_,a,a+240,true,V.Yield)
            Infrastructure.BuildChunk(fixture_,a,a+240,V.Yield)
        end
        V.CheckLandmarkMesh(fixture_,def,true,seam)
        if def.kind=="bridge" then
            local triangles=V.ReadTriangles(fixture_,true,function(name)
                return name:find("轨下桥面梁墩",1,true)~=nil or name:find("实际深谷坡面",1,true)~=nil
            end)
            local s=def.first+40+math.floor((seam-def.first-40)/80)*80
            local origin=Route.SampleOffset(s,-7.5,-10)
            local _,pier=V.Ray(triangles,origin,Route.RightAt(s),10,matches("轨下桥面梁墩"))
            V.Check(pier~=nil,"半开分块接缝附近缺少实际桥墩柱身")
            local ground=Route.SampleOffset(s,5.5,5)
            local depth,earth=V.Ray(triangles,ground,-Vector3.UP,100,matches("实际深谷坡面"))
            V.Check(earth~=nil,"桥墩附近真实谷基缺失")
            local foot=Route.SampleOffset(s,-2.5,ground.y-depth-.2)
            local _,base=V.Ray(triangles,foot-Route.RightAt(s)*6,Route.RightAt(s),12,matches("轨下桥面梁墩"))
            V.Check(base~=nil,"桥墩底座未下沉到实际谷基")
        end
        fixture_:Dispose();fixture_=nil
        Landmarks.ForgetChunk(seam-240,seam);Landmarks.ForgetChunk(seam,seam+240)
        V.Yield()
    end
    pass("两桥两隧240m实际分块接缝/桥墩柱身与谷基支撑")
    V.Check(Landmarks.GetEnvironmentAt(Route.GetStations()[1].s)=="urban","首站实际环境不是城市")
    V.Check(Landmarks.GetEnvironmentAt(15000)=="forest","站间实际环境不是林地")
    pass("两桥两隧实际钢轨/电线/拱墙/门户三角净空/深谷与Terrain真cut")
end
local function catalogChecks()
    V.Check(#Route.GetStations()==5,"五站线路数量不一致")
    for i,s in ipairs(Route.GetStations()) do V.Check(s.name==V.Stations[i],"站名不是架空五站："..s.name) end
    local names={};for _,item in ipairs(Train.GetCatalog()) do names[item.id]=item.name end
    for _,t in ipairs(V.Trains) do V.Check(names[t.id]==t.name,"六车型内部id/架空显示名不同步："..t.id) end
    pass("六架空车型/五架空站名/内部id不变")
end
local worldOnly_=false
for _,argument in ipairs(GetArguments()) do if argument=="-world-only" then worldOnly_=true end end
local function runAll()
    V.logicStatus="RUNNING"
    V.Yield() -- 首帧不会执行case
    if worldOnly_ then
        worldChecks();V.Yield()
        completed_,V.logicStatus=true,"PASS"
        print(string.format("ALL_FICTIONAL_WORLD_MESH_PASS cases=%d assertions=%d frame=%d",V.cases,V.checks,frame_))
        return
    end
    catalogChecks();V.Yield()
    initialChecks();V.Yield()
    hudChecks();V.Yield()
    audioChecks();V.Yield()
    sidingChecks();V.Yield()
    terminalChecks();V.Yield()
    worldChecks();V.Yield()
    completed_,V.logicStatus=true,"PASS"
    V.PrintPhases()
    print(string.format("ALL_FICTIONAL_RAIL_LOGIC_PASS cases=%d assertions=%d frame=%d；听感/实际背景绘制=NOT_RUN待Visual",V.cases,V.checks,frame_))
end
local function guard(action)
    if failed_ or completed_ then return end
    local ok,message=xpcall(action,debug.traceback)
    if not ok then
        failed_,V.logicStatus=true,"FAILED"
        print(string.format("ALL_FICTIONAL_RAIL_LOGIC_FAILED cases=%d assertions=%d frame=%d",V.cases,V.checks,frame_))
        log:Write(LOG_ERROR,tostring(message));error(message,0)
    end
end
if not rawget(_G,"FICTIONAL_RAIL_HELPERS_ONLY") then
    function Start()
        guard(function()
            V.Phase("main_start_only",startGame)
            scene_=assert(renderer:GetViewport(0).scene)
            runner_=coroutine.create(runAll)
            print("[架空铁路自检] 已启动分帧协程；框架NOT_RUN/assertions=0不是本业务测试状态")
        end)
    end
    ---@param eventType string
    ---@param eventData UpdateEventData
    function HandleUpdate(eventType,eventData)
        guard(function()
            frame_=frame_+1
            V.Check(frame_<=4150,"分帧业务自检超过4150真实帧预算")
            local thread=assert(runner_)
            V.Phase("coroutine_frame_slice",function()
                local ok,message=coroutine.resume(thread)
                if not ok then error(message,0) end
            end)
        end)
    end
    ---@param eventType string
    ---@param eventData PostUpdateEventData
    function HandlePostUpdate(eventType,eventData)
        if not worldOnly_ then
            guard(function() V.Phase("main_post_visual_only",function() postGame(eventType,eventData) end) end)
        end
    end
    function Stop()
        backgroundRestore_()
        if fixture_ then fixture_:Dispose();fixture_=nil end
        if not completed_ and not failed_ then
            print(string.format("ALL_FICTIONAL_RAIL_LOGIC_NOT_RUN_OR_INCOMPLETE status=%s cases=%d assertions=%d frame=%d",V.logicStatus,V.cases,V.checks,frame_))
        end
        if stopGame then stopGame() end
    end
end
return V
