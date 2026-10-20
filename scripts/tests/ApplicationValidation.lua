-- 真main入口E2E：真实触摸菜单/设置/换车、环境唯一真源、广播生命周期、保存恢复。
require "main"
local mainStart,mainUpdate,mainPost,mainStop=Start,HandleUpdate,HandlePostUpdate,Stop
local UI=require "urhox-libs/UI"
local Menu=require "ui.Menu"
local Hud=require "ui.Hud"
local Train=require "train.Train"
local Camera=require "train.Camera"
local Passenger=require "game.PassengerService"
local Audio=require "audio.AudioManager"
local Save=require "game.SaveStore"
local UiAudio=require "audio.UiAudio"
local Environment=require "world.Environment"
local Announcements=require "audio.Announcements"
local Game=require "game.Game"
local announcementsNew=Announcements.new
local saveSetCloud=Save.SetCloud
local saveReadCloud=Save.ReadCloud
local savePath_="railway_autosave_v1.json"
---@type VectorBuffer?
local saveOriginal_=nil
local saveExisted_=false
local saveProtected_=false
local cloudRequested_=false
local cloudReadRequests_=0
---@type RailwayAnnouncements?
local actualAnnouncements_=nil
local stage_,frames_,checks_,startFrame_="menu",0,0,0
local failed_,complete_=false,false
local baseline_={} ---@type table
local pendingCapture_=""
local CameraYaw0_=0
local function check(value,message) checks_=checks_+1;assert(value,"[ApplicationValidation] "..message) end
local function guard(action)
    if failed_ or complete_ then return end
    local ok,message=xpcall(action,debug.traceback)
    if not ok then
        failed_=true
        log:Write(LOG_ERROR,tostring(message))
    end
end
local function tap(root,id,scrollId)
    UI.Layout()
    local control=assert(root:FindById(id),"缺少控件："..id)
    local scroll=root:FindById(scrollId or "menuScroll") --[[@as ScrollView?]]
    if scroll then
        scroll:UpdateContentSize() -- 新展开/换页的滚动内容尚未经历下一帧Update。
        local r=control:GetAbsoluteLayoutForHitTest()
        local bounds=scroll:GetAbsoluteLayoutForHitTest()
        if r.y<bounds.y or r.y+r.h>bounds.y+bounds.h then
            scroll:ScrollBy(0,r.y+r.h*.5-bounds.y-bounds.h*.5)
            UI.Layout()
        end
    end
    local r=control:GetAbsoluteLayoutForHitTest()
    check(r.w>0 and r.h>0,"按钮实际布局缺失："..id)
    local x,y=(r.x+r.w*.5)*UI.GetScale(),(r.y+r.h*.5)*UI.GetScale()
    local target=UI.FindWidgetAt(x/UI.GetScale(),y/UI.GetScale())
    check(target==control,"真实触摸命中目标不是"..id)
    UI.InputAdapter.HandleTouchBegin(901,x,y,.5)
    UI.InputAdapter.HandleTouchEnd(901,x,y)
end
local function capture(name)
    local image=Image()
    check(graphics:TakeScreenShot(image),"截图失败")
    check(image:SavePNG("/workspace/screenshots/application-experience-"..name..".png"),"截图保存失败")
    image:Dispose()
end
local function nextStage(name)
    stage_,startFrame_=name,frames_
    print("[ApplicationValidation] stage="..name.." frame="..frames_)
end
local function assertEnvironment(snapshot,message)
    local actual=Environment.Export()
    for _,key in ipairs({"hour","dayLength","cloud","rain","sunScale","fogScale"}) do
        check(math.abs(actual[key]-snapshot[key])<.00001,message.."环境数值丢失："..key)
    end
    check(actual.weather==snapshot.weather and actual.running==snapshot.running,message.."天气/时间流动丢失")
end
function Start()
    guard(function()
        saveExisted_=fileSystem:FileExists(savePath_)
        if saveExisted_ then
            local file=File(savePath_,FILE_READ)
            check(file:IsOpen(),"无法保护既有设备存档")
            saveOriginal_=file:Read(file:GetSize());file:Dispose()
        end
        saveProtected_=true
        Save.SetCloud=function(enabled)
            cloudRequested_=enabled==true
            saveSetCloud(false) -- 本地E2E永不读写玩家云存档。
        end
        Save.ReadCloud=function(callback)
            cloudReadRequests_=cloudReadRequests_+1
            callback(Save.Get())
        end
        -- 只观察main实际创建的实例；不注入假广播、不替代其事件/更新逻辑。
        Announcements.new=function(options)
            local actual=announcementsNew(options)
            actualAnnouncements_=actual
            return actual
        end
        mainStart()
        check(graphics:GetWidth()==1280 and graphics:GetHeight()==720,"CLI实际渲染尺寸不是1280x720")
        baseline_.uiContext=UI.GetNVGContext()
        check(GetApplicationState()=="menu","未从主菜单启动")
        check(GetGameScene()==nil and renderer.numViewports==0,"开始前已经创建游戏世界")
        SubscribeToEvent("EndRendering","ApplicationValidationCapture")
    end)
end
function ApplicationValidationCapture()
    if failed_ then return end
    if frames_==2 then capture("menu") end
    if pendingCapture_~="" then local name=pendingCapture_;pendingCapture_="";capture(name) end
end
---@param eventType string
---@param eventData UpdateEventData
function HandleUpdate(eventType,eventData)
    guard(function()
        frames_=frames_+1
        mainUpdate(eventType,eventData)
        check(frames_-startFrame_<1200,"阶段超时："..stage_)
        check(GetApplicationState()~="error","真实入口进入错误页："..stage_)
        if stage_=="menu" and frames_==4 then
            -- 不继承前一轮验收写入的夜雨；通过真实菜单设置建立白昼代表图。
            tap(assert(Menu.GetRoot()),"gameSettings")
            tap(assert(Menu.GetRoot()),"settingsTimeDay")
            tap(assert(Menu.GetRoot()),"settingsWeather_clear")
            tap(assert(Menu.GetRoot()),"settingsBack")
            tap(assert(Menu.GetRoot()),"startGame")
            check(Menu.GetPage()=="modes" and GetGameScene()==nil,"模式选择前提前加载地图")
            tap(assert(Menu.GetRoot()),"selectMode_normal")
            check(GetApplicationState()=="loading","普通模式按钮没有进入加载页")
            pendingCapture_="loading";nextStage("loading")
        elseif stage_=="loading" and GetApplicationState()=="playing" then
            check(UI.GetNVGContext()==baseline_.uiContext,"加载结束重建了UI上下文")
            check(GetGameScene()~=nil and renderer.numViewports==1 and Train.GetCarCount()==8,"场景/viewport/八节车未加载")
            check(Train.ValidateBindings(),"默认车型实际MDL绑定失败")
            local visual=Passenger.GetVisualStats()
            check(visual.cpuBaked and not visual.skinned and visual.bonesPerActor==0
                and visual.sharedPoseFrames==50 and visual.geometryBuilds==0,"共享离线人物帧状态错误")
            check(Passenger.GetStatus().totalBoarding>300,"真实始发队列丢失")
            -- 只验声音系统已初始化，不以拥有几个持续loop当作产品需求。
            check(Audio.GetDiagnostics().ownedSoundCount>0,"实际音频资源系统未准备")
            check(Environment.GetStatus().skyReady,"主场景环境未接入真实天空")
            local announcement=assert(actualAnnouncements_):GetStatus()
            check(announcement.accepted==1 and announcement.lastEvent.kind=="welcome","main未触发唯一始发欢迎事件")
            check(announcement.lastEvent.legacyFallback==true and not announcement.lastEvent.stationVoice,
                "把旧欢迎语音冒充新站点录音")
            check(not announcement.englishStationVoices,"虚报英文站点语音覆盖")
            baseline_.welcomeAccepted=announcement.accepted
            Camera.SetMode("side");Camera.Update(0,Train.GetS())
            CameraYaw0_=Camera.GetDiagnostics().yaw
            nextStage("playing")
        elseif stage_=="playing" and frames_==startFrame_+8 then
            pendingCapture_="playing"
        elseif stage_=="playing" and frames_==startFrame_+12 then
            check(Hud.GetRenderedFrames()>0,"HUD未实际渲染")
            local root=assert(UI.GetRoot())
            for _,id in ipairs({"speedInstrument","throttleHandle","brakeHandle","openCameraSelector","openTrainSelector","pauseGame"}) do
                local r=assert(root:FindById(id)):GetAbsoluteLayout()
                check(r.w>0 and r.h>0,"驾驶控件不可见："..id)
            end
            local paused=Hud.GetReadings().paused
            tap(root,"pauseGame");check(Hud.GetReadings().paused~=paused,"真实暂停触摸无效")
            check(assert(actualAnnouncements_):GetStatus().queued==0,"暂停后广播队列未清空")
            tap(root,"pauseGame");check(Hud.GetReadings().paused==paused,"真实恢复触摸无效")
            local before=assert(Camera.GetNode()).worldPosition
            UI.Layout()
            local x,y=graphics:GetWidth()*.5,graphics:GetHeight()*.5
            check(UI.FindWidgetAt(x/UI.GetScale(),y/UI.GetScale())==nil,"世界空白处被HUD挡住")
            UI.InputAdapter.HandleTouchBegin(905,x,y,.5)
            check(require("train.ViewDrag").GetStatus().active,"世界触摸未接管")
            UI.InputAdapter.HandleTouchMove(905,x+80,y+12,.5)
            UI.InputAdapter.HandleTouchEnd(905,x+80,y+12)
            Camera.Update(.2,Train.GetS())
            local view=Camera.GetDiagnostics()
            check(math.abs(view.yaw-CameraYaw0_)>.5 or (assert(Camera.GetNode()).worldPosition-before):Length()>.5,
                "真实拖动未改变相机")
            -- 直接改变世界真源后进入设置：Settings必须回读Environment而非旧settings缓存。
            check(Environment.Configure({hour=19.25,running=false,weather="cloudy"}),"环境真源设置失败")
            tap(root,"toggleOperations")
            tap(root,"openSettings","operationsDetails")
            check(GetApplicationState()=="settings" and Menu.GetPage()=="settings","HUD设置未进入真实设置页")
            local hour=assert(assert(Menu.GetRoot()):FindById("environmentHour")) --[[@as Label]]
            check(hour:GetText():find("19:15",1,true)~=nil,"设置未回读实际Environment时刻")
            check(Environment.GetStatus().paused and assert(actualAnnouncements_):GetStatus().blocked,
                "设置页未暂停环境/广播")
            tap(assert(Menu.GetRoot()),"settingsTimeNight")
            check(Environment.GetStatus().hour==22,"夜间按钮未改变真实Environment")
            tap(assert(Menu.GetRoot()),"settingsWeather_rain")
            check(Environment.GetStatus().weather=="rain","雨天按钮未改变真实Environment")
            local environment=Environment.Export()
            local saved=assert(Save.Get())
            check(saved.journey.environment.hour==22 and saved.settings.environment.weather=="rain",
                "环境设置未立即保存真实旅程与设置")
            baseline_.environment=environment
            pendingCapture_="settings-night-rain"
            nextStage("settings")
        elseif stage_=="settings" and frames_>=startFrame_+3 then
            assertEnvironment(baseline_.environment,"设置暂停期间")
            -- 通过真实按钮切到中文，证明广播设置桥接；不假设历史本地存档语言。
            local root=assert(Menu.GetRoot())
            for _=1,4 do
                if UiAudio.GetStatus().language=="zh" then break end
                tap(root,"settingsLanguage");root=assert(Menu.GetRoot())
            end
            check(UiAudio.GetStatus().language=="zh" and assert(actualAnnouncements_):GetStatus().language=="zh",
                "语言设置未同步实际广播实例")
            tap(root,"settingsBack")
            check(GetApplicationState()=="playing" and Hud.GetReadings().paused,"设置返回未恢复暂停驾驶页")
            check(UI.GetNVGContext()==baseline_.uiContext,"设置返回重建UI上下文")
            check(Hud.GetReadings().environmentText:find("雨",1,true)~=nil,"HUD环境摘要未回读真源")
            assertEnvironment(baseline_.environment,"设置返回后")
            nextStage("selecting")
        elseif stage_=="selecting" and frames_>=startFrame_+2 then
            local root=assert(Hud.GetRoot())
            baseline_.s,baseline_.xp,baseline_.nextIndex=Train.GetS(),Game.GetXp(),Game.GetNextStation().index
            baseline_.trainRoot=Train.GetRoot()
            tap(root,"openTrainSelector")
            local selector=assert(Hud.GetTrainSelector())
            check(selector:IsOpen() and selector:FindTrain("DF4D").ready,"真实车型目录未刷新")
            tap(root,"selectTrain_DF4D");tap(root,"confirmTrain")
            nextStage("switching")
        elseif stage_=="switching" and not assert(Hud.GetTrainSelector()):IsBusy() then
            check(Train.GetSelectedId()=="DF4D" and not Hud.IsTrainSelectorOpen(),"真实切车完成未提交正确车型")
            check(Train.ValidateBindings(),"实际切换后的8节MDL绑定无效")
            check(Train.GetRoot()==baseline_.trainRoot and Train.GetS()==baseline_.s,"切车破坏根/位置")
            check(Game.GetXp()==baseline_.xp and Game.GetNextStation().index==baseline_.nextIndex,"切车改变经验/站序")
            check(Train.GetThrottle()==0 and Train.GetBrake()==1,"切车未安全制动")
            check(Hud.GetReadings().paused and Audio.GetPowerType()=="diesel","切车丢失用户暂停/音频动力同步")
            check(Audio.GetDiagnostics().trainId==nil or Audio.GetDiagnostics().trainId=="DF4D","实际声音车型未同步")
            assertEnvironment(baseline_.environment,"切车后")
            baseline_.count,baseline_.waiting=Passenger.GetStatus().onboard,Passenger.GetStatus().waiting
            baseline_.camera,baseline_.trainId=Camera.GetMode(),Train.GetSelectedId()
            check(SaveJourneyNow(),"真实存档写入失败")
            local saved=assert(Save.Get())
            check(saved.journey.train.id=="DF4D" and saved.journey.environment.hour==22
                and saved.journey.environment.weather=="rain" and not saved.journey.environment.running,
                "存档未保存实际列车/环境真源")
            pendingCapture_="selected-fleet"
            nextStage("saving")
        elseif stage_=="saving" and frames_>=startFrame_+2 then
            ReturnToMainMenu()
            check(GetGameScene()==nil and renderer.numViewports==0,"回菜单没有释放真实世界")
            check(assert(actualAnnouncements_).stopped,"回菜单未Shutdown实际广播实例")
            tap(assert(Menu.GetRoot()),"gameSettings")
            tap(assert(Menu.GetRoot()),"settingsTimeDusk")
            local saved=assert(Save.Get())
            check(saved.journey.environment.hour==18 and saved.settings.environment.hour==18,
                "主菜单环境设置未同步继续旅程快照")
            baseline_.environment=saved.journey.environment
            tap(assert(Menu.GetRoot()),"settingsBack")
            tap(assert(Menu.GetRoot()),"continueGame")
            check(GetApplicationState()=="loading","继续旅程没有进入loading")
            nextStage("restoring")
        elseif stage_=="restoring" and GetApplicationState()=="playing" then
            check(math.abs(Train.GetS()-baseline_.s)<.001,"恢复位置改变")
            check(Train.GetSelectedId()==baseline_.trainId and Train.ValidateBindings(),"恢复车型/实际MDL错误")
            check(Passenger.GetStatus().onboard==baseline_.count and Passenger.GetStatus().waiting==baseline_.waiting,
                "恢复乘降清单丢失")
            check(Camera.GetMode()==baseline_.camera and Hud.GetReadings().paused,"恢复机位或安全暂停丢失")
            check(Game.GetXp()==baseline_.xp,"恢复运营经验丢失")
            check(UiAudio.GetStatus().language=="zh" and assert(actualAnnouncements_):GetStatus().language=="zh",
                "恢复广播语言设置丢失")
            check(assert(actualAnnouncements_):GetStatus().queued==0,"读档重播旧广播队列")
            assertEnvironment(baseline_.environment,"读档恢复")
            check(Hud.GetReadings().environmentText:find("雨",1,true)~=nil,"读档HUD天气摘要错误")
            pendingCapture_="restored-dusk-rain"
            nextStage("restored")
        elseif stage_=="restored" and frames_>=startFrame_+3 then
            complete_=true
            print(string.format("ALL_APPLICATION_VALIDATION_PASS checks=%d frames=%d menuNoScene=true settingsReturn=true realTouch=true savedPassengers=true environmentSource=true actualTrainBindings=true announcementLifecycle=true",checks_,frames_))
        end
    end)
end
---@param eventType string
---@param eventData PostUpdateEventData
function HandlePostUpdate(eventType,eventData) guard(function() mainPost(eventType,eventData) end) end
function Stop()
    Announcements.new=announcementsNew
    mainStop()
    Save.SetCloud,Save.ReadCloud=saveSetCloud,saveReadCloud
    if saveProtected_ then
        if saveExisted_ then
            local file=File(savePath_,FILE_WRITE)
            assert(file:IsOpen(),"无法恢复既有设备存档")
            local bytes=assert(saveOriginal_)
            check(file:Write(bytes)==bytes.size,"既有设备存档恢复不完整")
            file:Dispose()
        else
            check(not fileSystem:FileExists(savePath_) or fileSystem:Delete(savePath_),"无法清理测试新存档")
        end
        print(string.format("[ApplicationValidation] SAVE_RESTORED existed=%s cloudRequested=%s interceptedCloudReads=%d externalCloudCalls=0",
            tostring(saveExisted_),tostring(cloudRequested_),cloudReadRequests_))
    end
end
