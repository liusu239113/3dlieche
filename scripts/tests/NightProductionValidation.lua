-- 真实production main夜景验收：SaveStore只在本进程替换为内存空档，绝不打开玩家文件/云。
-- 使用main真实Scene/Camera/列车/流式几何/画质；冻结同一帧位姿做开关灯像素对照。
local Save=require "game.SaveStore"
local originalLoad,originalWrite,originalReadCloud,originalSetCloud=Save.Load,Save.Write,Save.ReadCloud,Save.SetCloud
local writes_,clouds_=0,0
Save.Load=function() return nil end
Save.Write=function() writes_=writes_+1;return true end
Save.ReadCloud=function(callback) clouds_=clouds_+1;callback(nil) end
Save.SetCloud=function() end
require "main"
local mainStart,mainUpdate,mainPost,mainStop=Start,HandleUpdate,HandlePostUpdate,Stop
local Train=require "train.Train"
local Camera=require "train.Camera"
local Route=require "world.Route"
local Road=require "world.RoadCorridor"
local Night=require "world.NightLighting"
local Environment=require "world.Environment"
local Stream=require "world.WorldStream"
local Quality=require "config.VisualQuality"
local UI=require "urhox-libs/UI"
local Diagnostics=require "core.LightingDiagnostics"
local clusterCycle_,clusterSteps_=false,0
local mode_,case_,frame_,wait_,checks_="normal",1,0,0,0
local stopped_,done_,ready_=false,false,false
local stage_="loading"
local stationS_,roadS_,slopeS_=0.0,0.0,0.0
local screenshotCount_=0
local minimumDelta_=1.0
---@type Image?
local previous_=nil
local pair_="all"
local hour_,cameraMode_,pitchDelta_=22.0,"",0.0
local atStation_,selectedModel_=false,""
local phaseFrames_,readbacks_=0,0
local discarded_=false
local frozen_=false
local baseline_={eye=Vector3.ZERO,direction=Vector3.FORWARD,s=0.0,nodes=0,hour=0.0}
---@type Viewport?
local loadingViewport_=nil
for _,arg in ipairs(GetArguments()) do
    local mode=arg:match("^%-night%-mode=(.+)$")
    local pair=arg:match("^%-night%-pair=(.+)$")
    local hour=arg:match("^%-night%-hour=(.+)$")
    local camera=arg:match("^%-night%-camera=(.+)$")
    local pitch=arg:match("^%-night%-pitch=(.+)$")
    local model=arg:match("^%-night%-model=(.+)$")
    if mode then mode_=mode end
    if pair then pair_=pair end
    if hour then hour_=assert(tonumber(hour)) end
    if camera then cameraMode_=camera end
    if pitch then pitchDelta_=assert(tonumber(pitch)) end
    if model then selectedModel_=model end
    if arg=="-night-at-station" then atStation_=true end
    if arg=="-night-cluster-cycle" then clusterCycle_=true end
end
local pairCases={all={first=1,last=6},station={first=1,last=2},road={first=3,last=4},headlight={first=5,last=6}}
local firstCase_,lastCase_=1,6
local cases={"station_off","station_on","road_off","road_on","headlight_off","headlight_on"}
local function check(v,message) checks_=checks_+1;assert(v,"[NightProduction] "..message) end
local function cleanup()
    if stopped_ then return end
    stopped_=true
    local ok,message=pcall(mainStop)
    Save.Load,Save.Write,Save.ReadCloud,Save.SetCloud=originalLoad,originalWrite,originalReadCloud,originalSetCloud
    if not ok then log:Write(LOG_ERROR,tostring(message)) end
    if previous_ then previous_:Dispose();previous_=nil end
end
local function guard(action)
    if done_ then return end
    local ok,message=xpcall(action,debug.traceback)
    if not ok then done_=true;log:Write(LOG_ERROR,tostring(message));cleanup();engine:Exit() end
end
local function restoreAt(s,speed)
    local snapshot=Train.ExportState()
    snapshot.s,snapshot.v,snapshot.throttle,snapshot.brake=s,speed,0,speed==0 and 1 or 0
    snapshot.reversing,snapshot.moving,snapshot.derailed=false,speed~=0,false
    snapshot.topology=nil;snapshot.headlightMode="auto"
    Train.RestoreState(snapshot)
end
local function setCase(index)
    case_,wait_,phaseFrames_,readbacks_,discarded_=index,0,0,0,false
    if index%2==1 then frozen_=false end
    stage_="settle"
    if index==1 then restoreAt(stationS_,0)
    elseif index==5 and atStation_ then
        restoreAt(stationS_,0)
    elseif index==3 then
        restoreAt(roadS_,0)
        Stream.Reset(roadS_) -- 同一production WorldStream同步预热；不伪造几何或改灯。
    elseif index==5 then
        restoreAt(slopeS_-8,25)
        TogglePause()
        -- 正式main实际移动五步后冻结，验证的是移动后的车体/灯向，不是摆拍替代灯。
        for _=1,5 do
            local event=VariantMap();event["TimeStep"]=Variant(.10)
            mainUpdate("Update",event --[[@as UpdateEventData]])
            mainPost("PostUpdate",event --[[@as PostUpdateEventData]])
        end
        local movedS=Train.GetS()
        TogglePause();UI.SetRoot(nil)
        check(movedS>slopeS_-8,"production未真实移动")
        restoreAt(movedS,0)
        local direction=assert(Train.GetLeadNode()).worldRotation*Vector3.FORWARD
        local axis=(Train.GetTrackSample(movedS+8)-Train.GetTrackSample(movedS-8)):Normalized()
        check(direction:DotProduct(axis)>.999,"移动车体/灯光没有跟轨道纵坡")
        Stream.Reset(movedS)
        Camera.SetMode("track_front")
    end
    Environment.Configure({hour=hour_,running=false,weather="clear"})
    if cameraMode_~="" and index==firstCase_ then
        check(Camera.SetMode(cameraMode_),"指定生产机位不存在")
        Camera.AddPitch(pitchDelta_)
    end
    if index%2==0 then
        -- 上一关灯对照直接禁用了组件，显式标记一次重选，避免15帧静止复查延迟污染对照。
        Night.SetEnvironment(0,"performance");Night.SetEnvironment(1,"performance")
    end
    print(string.format("[NightProduction] mode=%s case=%s s=%.1f y=%.2f grade=%.4f",mode_,cases[index],Train.GetS(),Route.Sample(Train.GetS()).y,Route.GradeAt(Train.GetS())))
end
local function sampleDelta(image,prior)
    local total,lit,white,maxDelta=0,0,0,0
    for y=math.floor(image.height*.30),image.height-1,2 do
        for x=0,image.width-1,2 do
            local a,b=image:GetPixel(x,y),prior:GetPixel(x,y)
            local la,lb=(a.r+a.g+a.b)/3,(b.r+b.g+b.b)/3
            total=total+1
            if la>lb+.015 then lit=lit+1 end
            if la>.96 then white=white+1 end
            maxDelta=math.max(maxDelta,la-lb)
        end
    end
    return lit/total,white/total,maxDelta
end
function Start()
    guard(function()
        check(mode_=="normal" or mode_=="rage","invalid mode")
        local pair=pairCases[pair_]
        check(pair~=nil,"invalid -night-pair: "..pair_)
        firstCase_,lastCase_=assert(pair).first,assert(pair).last
        case_=firstCase_
        print(string.format("[NightProduction] selected mode=%s pair=%s cases=%d..%d",mode_,pair_,firstCase_,lastCase_))
        mainStart()
        check(SetRenderQuality("performance"),"production performance选择失败")
        BeginJourney(false,mode_)
        SubscribeToEvent("EndRendering","NightProductionCapture")
    end)
end
function HandleUpdate(eventType,eventData)
    guard(function()
        frame_=frame_+1
        local event=VariantMap();event["TimeStep"]=Variant(.02)
        mainUpdate(eventType,event --[[@as UpdateEventData]])
        -- 初载只跑正式协程，不绘制不可见的半成品；进入playing立即归还保活视口。
        if GetApplicationState()=="loading" then
            loadingViewport_=loadingViewport_ or renderer:GetViewport(0)
            renderer:SetNumViewports(0)
        elseif GetApplicationState()=="playing" and loadingViewport_ then
            renderer:SetNumViewports(1);renderer:SetViewport(0,loadingViewport_)
            loadingViewport_=nil
        end
        check(GetApplicationState()~="error","正式main加载失败")
        if not ready_ and GetApplicationState()=="playing" then
            ready_=true
            TogglePause();UI.SetRoot(nil)
            if selectedModel_~="" then
                check(Train.Select(selectedModel_),"指定生产车型装配失败")
                Camera.Update(0,Train.GetS()) -- 先处理换车重置，再应用指定机位/俯仰。
            end
            check(GetRenderQuality()==Quality.Normalize("performance"),"实际performance没有走规范档")
            check(renderer.materialQuality==QUALITY_MEDIUM,"production材质质量改变")
            local camera=assert(Camera.GetCamera())
            check((camera.viewMask & 2)~=0,"真实相机mask排除夜灯")
            local st=Route.GetStations()[1] -- 真实main已完整加载的出生站；禁止用未ready远站做灯光结论。
            stationS_=st.s
            slopeS_=stationS_+1300
            if mode_=="rage" then
                local bestGrade=0
                for s=500,Route.GetLength()-500,120 do
                    local grade=math.abs(Route.GradeAt(s))
                    if grade>bestGrade and Route.Sample(s).y>100 then bestGrade,slopeS_=grade,s end
                end
                check(bestGrade>.015,"狂暴production缺少真实山坡")
            end
            roadS_=slopeS_+200
            local warm=Stream.GetStats()
            check(warm.stationChunks>0 and warm.terrainChunks>0 and warm.sceneryChunks>0,"初始production世界未完整预热")
            -- 分段只跳过其他对照，不绕过真实main启动、出生站预热或目标段Reset。
            -- 保留Save.Load空内存档，避免构造旅程存档牵动客流/运营状态及磁盘。
            setCase(firstCase_)
        elseif stage_=="settle" then
            wait_=wait_+1
            local minimum=case_%2==0 and 6 or 12
            local warm=Stream.GetStats()
            local available=warm.sceneryChunks>0 and warm.terrainChunks>0 and (case_>2 or warm.stationChunks>0)
            if wait_>=minimum and available then stage_="capture" end
            check(wait_<240,"生产流式几何未ready，不能据此判灯光失败")
        end
    end)
end
function HandlePostUpdate(eventType,eventData)
    guard(function()
        if not frozen_ then mainPost(eventType,eventData)
        elseif clusterCycle_ then Diagnostics.Update(eventData:GetFloat("TimeStep"),"playing",GetGameScene()) end
        if not ready_ or stage_=="moving" then return end
        if clusterCycle_ then
            local selected=clusterSteps_==1
            check(Diagnostics.GetClusterSelected()==selected,"对照选择被覆盖")
            check(assert(renderer:GetViewport(0)):IsViewClusterEnabled()==selected,"当前视口开关与选择不符")
        end
        local camera=assert(Camera.GetNode())
        if stage_=="capture" then
            local now=Train.GetS()
            local direction=assert(Train.GetLeadNode()).worldRotation*Vector3.FORWARD
            local axis=(Train.GetTrackSample(now+8)-Train.GetTrackSample(now-8)):Normalized()
            check(direction:DotProduct(axis)>.999,"拍摄时生产车体纵坡不同步")
        end
        if cameraMode_~="" then
            -- 保留玩家实际机位，不再把站台或头灯挪到特意选的观察角度。
        elseif case_<=2 then
            camera.worldPosition=Route.SampleOffset(stationS_-140,-25,7.2)
            camera:LookAt(Route.SampleOffset(stationS_-35,-3,1.6))
        elseif case_<=4 then
            local pos,right=Road.Sample(roadS_)
            local tangent=Vector3(-right.z,0,right.x)
            camera.worldPosition=pos-tangent*22-right*7+Vector3(0,4.2,0)
            camera:LookAt(pos+tangent*48+Vector3(0,.4,0))
        end
        local focus=cameraMode_~="" and Camera.GetLightingFocus() or camera.worldPosition
        Environment.Update(0,camera.worldPosition,focus)
        local headlightMode=case_==6 and "on" or "off"
        if Train.GetHeadlightMode()~=headlightMode then Train.SetHeadlightMode(headlightMode) end
        -- 关灯对照只停用真实池组件，不改Zone/月光/曝光或路面材质。
        if case_%2==1 or case_>=5 then
            for _,light in ipairs(Night.GetLights()) do light.enabled=false end
        elseif case_<=4 then
            Night.SetEnvironment(1,"performance");Night.Update(camera.worldPosition,focus)
        end
        if stage_=="capture" and not frozen_ then
            -- 只在正式main完成机位和流式提交后冻结；对照期间不再新增几何、车辆或移动相机。
            baseline_={eye=camera.worldPosition,direction=camera.worldDirection,s=Train.GetS(),
                nodes=#assert(GetGameScene()):GetChildren(true),hour=Environment.GetStatus().hour}
            frozen_=true
        end
        if stage_=="capture" and case_%2==0 then
            local status=Environment.GetStatus()
            check(status.lampFactor>.99 and math.abs(status.hour-hour_)<.000001,"production时钟与灯态不同步")
            if case_<=4 then check(Night.GetStats().activeStation+Night.GetStats().activeRoad>0,"生产池没有实际启用") end
        end
    end)
end
function NightProductionCapture()
    guard(function()
        if stage_~="capture" then return end
        local camera=assert(Camera.GetNode())
        check(frozen_ and (camera.worldPosition-baseline_.eye):Length()<.000001
            and (camera.worldDirection-baseline_.direction):Length()<.000001,"对照相机发生变化")
        check(Train.GetS()==baseline_.s and #assert(GetGameScene()):GetChildren(true)==baseline_.nodes,
            "对照车辆或几何发生变化")
        check(math.abs(Environment.GetStatus().hour-baseline_.hour)<.000001,"对照时钟发生变化")
        phaseFrames_=phaseFrames_+1
        if phaseFrames_<12 or (clusterCycle_ and Diagnostics.IsClusterWarmingUp()) then return end
        local image=Image()
        local captured=graphics:TakeScreenShot(image)
        if not captured or image.width<1 or image.height<1 then
            image:Dispose();readbacks_=readbacks_+1
            check(readbacks_<24,"帧缓冲读回持续失败")
            return
        end
        if not discarded_ then discarded_=true;image:Dispose();return end
        local suffix=cameraMode_~="" and ("_"..cameraMode_.."_"..math.floor(hour_*60)) or ""
        local clusterSuffix=clusterCycle_ and ("_round"..clusterSteps_..(Diagnostics.GetClusterSelected() and "_A" or "_B")) or ""
        local name="/workspace/screenshots/night_production_"..mode_.."_"..cases[case_]..suffix..clusterSuffix..".png"
        check(image:SavePNG(name),"截图写盘失败")
        screenshotCount_=screenshotCount_+1
        if case_%2==1 then previous_=image
        else
            local delta,white,maximum=sampleDelta(image,assert(previous_))
            minimumDelta_=math.min(minimumDelta_,delta)
            print(string.format("[NightProduction] PIXEL mode=%s case=%s lit=%.5f white=%.5f maxDelta=%.3f quality=%s material=%s mask=%s pool=%d pending=%d",
                mode_,cases[case_],delta,white,maximum,GetRenderQuality(),tostring(renderer.materialQuality),tostring(assert(Camera.GetCamera()).viewMask),Night.GetStats().poolLights,Stream.GetStats().pendingTasks))
            check(delta>.003,"真实production路面/台面亮区不足："..cases[case_].." delta="..delta)
            check(white<.14,"夜景大面积刷白")
            previous_:Dispose();previous_=nil;image:Dispose()
        end
        if case_==lastCase_ and clusterCycle_ and clusterSteps_<2 then
            local s,hour,eye=Train.GetS(),Environment.GetStatus().hour,assert(Camera.GetNode()).worldPosition
            local light=assert(assert(Train.GetHeadlightDiagnostics().node):GetComponents("Light",true)[1])
            local brightness,range,position=light.brightness,light.range,light.node.worldPosition
            local selected=clusterSteps_==0
            -- 经真实HUD按钮回调验证暂停和视口切换，不直接绕过main修改引擎状态。
            local Hud=require "ui.Hud"
            UI.SetRoot(assert(Hud.GetRoot()))
            Hud.SetOperationsExpanded(true)
            local root=assert(Hud.GetRoot())
            local button=assert(root:FindById(selected and "lightingClusterA" or "lightingClusterB")) --[[@as Button]]
            local click=assert(button.props.onClick)
            click(button)
            check(Diagnostics.GetClusterSelected()==selected,"HUD按钮未接入真实切换")
            check(Hud.GetReadings().paused,"对照没有暂停真实玩法")
            check(Train.GetS()==s and Environment.GetStatus().hour==hour
                and (assert(Camera.GetNode()).worldPosition-eye):Length()<.000001,"路径切换改变车辆/时钟/机位")
            check(light.brightness==brightness and light.range==range
                and (light.node.worldPosition-position):Length()<.000001,"路径切换改变真实灯光参数")
            if not selected then
                -- 模拟重新建视口，诊断选择必须在下一正常帧恢复，而非仅作用旧实例。
                renderer:SetViewport(0,Viewport:new(assert(GetGameScene()),assert(Camera.GetCamera())))
                Diagnostics.Update(0,"playing",GetGameScene())
                check(not assert(renderer:GetViewport(0)):IsViewClusterEnabled(),"新视口丢失非集群选择")
            end
            clusterSteps_=clusterSteps_+1
            UI.SetRoot(nil)
            setCase(firstCase_)
            return
        end
        if case_==lastCase_ then
            check(not clusterCycle_ or clusterSteps_==2,"未完成B/A/B对照")
            check(clouds_==0,"触发了云读取")
            print(string.format("ALL_NIGHT_PRODUCTION_PASS mode=%s checks=%d screenshots=%d minLitDelta=%.5f saveDiskIO=0 cloudIO=0 interceptedWrites=%d pair=%s",mode_,checks_,screenshotCount_,minimumDelta_,writes_,pair_))
            done_=true;cleanup();engine:Exit()
        else setCase(case_+1) end
    end)
end
function Stop() cleanup() end
