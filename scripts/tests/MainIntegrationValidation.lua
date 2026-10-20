-- 真实main声音恢复集成，复用EmergenceApplicationValidation的main生命周期/触摸脚手架。
-- Save facade内存fixture，不开玩家文件，不调用云；生产格式/迁移校验由Emergence负责。
-- 只包装Announcements.new观察main实际创建的实例，绝不直接调用Announce或代造Feedback。
-- 列车位置/驾驶阶段通过公开RestoreState夹具注入；到站仍由main固定步->Game.CheckArrival产生。
-- 默认CPU确定性推进提示音；-main-integration-device使用SDL disk自然混音/真实解码时钟。
local Save=require "game.SaveStore"
local Announcements=require "audio.Announcements"
local Catalog=require "config.AnnouncementCatalog"
local originals_={Load=Save.Load,Write=Save.Write,Get=Save.Get,SetCloud=Save.SetCloud,
    ReadCloud=Save.ReadCloud,new=Announcements.new,cloud=clientCloud}
local fixture_={version=1,settings={sound=true,music=false,volume=.75,announcementVolume=.85,
    ambienceVolume=0,language="zh",cloud=true,quality="low",environment={hour=12,running=false,weather="clear"}},journeys={}}
local writes_,reads_,cloudCalls_,created_=0,0,0,0
local function copy(value) return cjson.decode(cjson.encode(value)) end
Save.Load=function() return copy(fixture_) end
Save.Get=function() return copy(fixture_) end
Save.Write=function(data) writes_=writes_+1;fixture_=copy(data);return true end
Save.SetCloud=function() end
Save.ReadCloud=function(callback) reads_=reads_+1;callback(copy(fixture_)) end
_G.clientCloud=setmetatable({}, {__index=function(_,key)
    return function() cloudCalls_=cloudCalls_+1;error("禁止真实云："..tostring(key)) end
end})
---@type RailwayAnnouncements?
local announcements_=nil
Announcements.new=function(options)
    created_=created_+1
    local actual=originals_.new(options)
    announcements_=actual
    return actual
end
require "main"
local mainStart,mainUpdate,mainPost,mainStop=Start,HandleUpdate,HandlePostUpdate,Stop
local UI=require "urhox-libs/UI"
local Hud=require "ui.Hud"
local Menu=require "ui.Menu"
local Train=require "train.Train"
local Game=require "game.Game"
local Passenger=require "game.PassengerService"
local Route=require "world.Route"
local Modes=require "config.GameModes"
local Soundscape=require "audio.Soundscape"
local PREFIX="[MainIntegration] "
local checks_,frames_,touchId_=0,0,980
local stopped_,done_,failed_,started_,device_=false,false,false,false,false
local stage_,stageFrame_="loading",0
local round_,voiceMax_,oldAccepted_=0,0.0,0
local firstInstance_={} ---@type table
local beforeArrival_={} ---@type table
local savedJourney_={} ---@type table
local reasons_={"master","announcement","language","background"}
local function check(value,message) checks_=checks_+1;assert(value,PREFIX..message) end
local function status() return assert(announcements_):GetStatus() end
local function transition(name)
    stage_,stageFrame_=name,frames_
    print(PREFIX.."stage="..name.." round="..round_.." frame="..frames_)
end
local function cleanup()
    if stopped_ then return end
    stopped_=true
    if started_ then
        local ok,message=pcall(mainStop)
        if not ok then failed_=true;log:Write(LOG_ERROR,PREFIX..tostring(message)) end
    end
    Save.Load,Save.Write,Save.Get=originals_.Load,originals_.Write,originals_.Get
    Save.SetCloud,Save.ReadCloud=originals_.SetCloud,originals_.ReadCloud
    Announcements.new=originals_.new
    _G.clientCloud=originals_.cloud
    print(PREFIX.."MEMORY_FIXTURE_CLEANED playerSaveIO=0 externalCloudCalls="..cloudCalls_.." writes="..writes_)
end
local function guard(action)
    if done_ or failed_ then return end
    local ok,message=xpcall(action,debug.traceback)
    if not ok then
        failed_=true;log:Write(LOG_ERROR,tostring(message));cleanup();engine:Exit()
    end
end
---@param dt? number
local function step(dt)
    local event=VariantMap();event["TimeStep"]=Variant(dt or .02)
    mainUpdate("Update",event --[[@as UpdateEventData]])
end
---@param root Widget
---@param id string
---@param scrollId? string
local function visible(root,id,scrollId)
    UI.Layout()
    local widget=assert(root:FindById(id),PREFIX.."缺少真实控件 "..id)
    local scroll=root:FindById(scrollId or "menuScroll") --[[@as ScrollView?]]
    if scroll then
        scroll:UpdateContentSize()
        local r,b=widget:GetAbsoluteLayoutForHitTest(),scroll:GetAbsoluteLayoutForHitTest()
        if r.y<b.y or r.y+r.h>b.y+b.h then scroll:ScrollBy(0,r.y+r.h*.5-b.y-b.h*.5);UI.Layout() end
    end
    return widget
end
---@param root Widget
---@param id string
---@param scrollId? string
local function tap(root,id,scrollId)
    local widget=visible(root,id,scrollId)
    local r=widget:GetAbsoluteLayoutForHitTest()
    check(r.w>0 and r.h>0 and UI.FindWidgetAt(r.x+r.w*.5,r.y+r.h*.5)==widget,"触摸未命中 "..id)
    touchId_=touchId_+1
    local x,y=(r.x+r.w*.5)*UI.GetScale(),(r.y+r.h*.5)*UI.GetScale()
    UI.InputAdapter.HandleTouchBegin(touchId_,x,y,.5)
    UI.InputAdapter.HandleTouchEnd(touchId_,x,y)
    -- 菜单按钮在生产MenuRoot:Update中提交动作；推进真实UI，而非调用按钮业务或伪造页面。
    UI.Update(.02)
    print(PREFIX.."REAL_TOUCH "..id)
end
---@param key string
---@param value number
local function volume(key,value)
    local root=assert(Hud.GetRoot())
    tap(root,"openVolumePanel")
    local widget=visible(root,"volumeSlider_"..key,"volumeScroll") --[[@as Slider]]
    local r=widget:GetAbsoluteLayoutForHitTest()
    local x=r.x+(value==0 and 1 or r.w*.75)
    check(UI.FindWidgetAt(x,r.y+r.h*.5)==widget,"真实音量滑杆命中失败")
    touchId_=touchId_+1
    UI.InputAdapter.HandleTouchBegin(touchId_,x*UI.GetScale(),(r.y+r.h*.5)*UI.GetScale(),.5)
    UI.InputAdapter.HandleTouchEnd(touchId_,x*UI.GetScale(),(r.y+r.h*.5)*UI.GetScale())
    check(value==0 and widget:GetValue()==0 or value>0 and widget:GetValue()>.6,"滑杆没有提交音量")
    tap(root,"closeVolumePanel")
    check(fixture_.settings[key]==widget:GetValue(),"main设置未由真实滑杆回调持久化")
end
local function begin(resume)
    check(GetApplicationState()=="menu","开始前不是主菜单")
    tap(assert(Menu.GetRoot()),"startGame")
    check(Menu.GetPage()=="modes" and GetGameScene()==nil,"模式页提前创建世界")
    tap(assert(Menu.GetRoot()),resume and "continueMode_normal" or "selectMode_normal")
    check(GetApplicationState()=="loading","模式卡片没有启动生产加载")
end
local function returnMenu()
    local root=assert(Hud.GetRoot())
    if not Hud.GetReadings().operationsExpanded then tap(root,"toggleOperations") end
    tap(root,"returnMainMenu","operationsDetails")
    check(GetApplicationState()=="menu" and GetGameScene()==nil,"返回菜单未释放真实世界")
end
-- 从真实main当前状态导出合法恢复夹具；不调用Arrive/BeginStop或修改Game模块内部变量。
local function prepareDriving(index)
    local station=assert(Route.GetStations()[index])
    local train=Train.ExportState()
    train.s,train.v,train.throttle,train.brake=station.s-100,0,0,1
    train.moving,train.reversing,train.topology=true,false,nil
    Train.RestoreState(train)
    Passenger.Reset()
    local game=Game.ExportState()
    game.state,game.nextIndex,game.lastArrival="driving",index,index-1
    game.initialService,game.timetable,game.dwellTimer=false,nil,0
    game.travelReversing,game.arrivalReversing,game.rewarded=false,false,{}
    Game.RestoreState(game)
    -- 夹具Reset使visits归零；先经过main观察一次驾驶态，避免与上次到站visits=1相同。
    step(.02)
end
local function completeRealStop(nextIndex)
    local visits=Passenger.GetStats().visits
    -- 后续访问不Reset/Restore客流和Game。真实乘降、最低站停、信号、关门、发车均走main。
    for _=1,1800 do
        if not Game.IsDwelling() then break end
        step(.2)
    end
    check(not Game.IsDwelling() and assert(Game.GetNextStation()).index==nextIndex,"真实连续乘降后未发车到下一站")
    check(Passenger.GetStats().visits==visits,"真实离站错误更改访问计数")
    local train=Train.ExportState()
    train.s,train.v,train.throttle,train.brake=assert(Route.GetStations()[nextIndex]).s-100,0,0,1
    train.moving=true
    Train.RestoreState(train)
    step(.02)
    return visits
end
local function arrive(index)
    local before=status().accepted
    local station=assert(Route.GetStations()[index])
    local train=Train.ExportState()
    train.s,train.v,train.throttle,train.brake=station.s-.1,0,0,1
    train.moving,train.reversing=true,false
    Train.RestoreState(train)
    step(.02)
    local actual=status()
    check(Game.IsDwelling() and Passenger.HasActiveStop(),"main固定步没有真实到站乘降")
    check(actual.accepted>before and actual.lastEvent.kind=="arrival" and actual.lastEvent.index==index,
        "main->Game到站->Feedback->Announcements没有接受新到站")
    -- 生产契约不强切正在播的短片段；压缩区间旅行后可仍在播放departure/approach。
    -- 读档首次到站必须真正派发chime；连续到站以新arrival入队+后续clear验证，不强迫抢断。
    check(index==2 and actual.activePath==Catalog.Chime
        or index>2 and actual.queued>0 and actual.activePath~="","新到站没有实际音频/待播队列")
    print(string.format(PREFIX.."REAL_MAIN_ARRIVAL_ACCEPTED index=%d accepted=%d activePath=%s instance=%d",
        index,actual.accepted,actual.activePath,created_))
end
local function assertDiscarded(reason)
    local actual=status()
    check(actual.queued==0 and actual.activePath=="" and not actual.playing,reason.."后保留旧播放/队列")
end
local function settingsOpen()
    local root=assert(Hud.GetRoot())
    if not Hud.GetReadings().operationsExpanded then tap(root,"toggleOperations") end
    tap(root,"openSettings","operationsDetails")
    check(GetApplicationState()=="settings","真实设置按钮无效")
end
local function languageTo(target)
    for _=1,4 do
        if fixture_.settings.language==target then return end
        tap(assert(Menu.GetRoot()),"settingsLanguage")
    end
    check(fixture_.settings.language==target,"语言真实按钮无法循环到目标")
end
local function focus(value)
    local event=VariantMap();event["Focus"]=value
    HandleApplicationPaused("InputFocus",event --[[@as InputFocusEventData]])
end
local function blockAndRestore()
    local reason=reasons_[round_]
    oldAccepted_=status().accepted
    if reason=="master" then
        volume("volume",0);check(status().masterVolume==0,"主音量未传给main真实广播实例")
        assertDiscarded(reason);volume("volume",.75)
    elseif reason=="announcement" then
        volume("announcementVolume",0);check(status().volume==0,"广播音量未传给main真实广播实例")
        assertDiscarded(reason);volume("announcementVolume",.75)
    elseif reason=="language" then
        settingsOpen();languageTo("off")
        check(status().language=="off","设置语言没有作用到真实广播实例")
        assertDiscarded(reason);languageTo("zh")
        tap(assert(Menu.GetRoot()),"settingsBack")
        check(Hud.GetReadings().paused,"设置返回未保留安全暂停")
        TogglePause()
    else
        focus(false);check(Hud.GetReadings().paused and status().blocked,"后台未暂停实际main和广播")
        assertDiscarded(reason);focus(true)
        check(Hud.GetReadings().paused,"前台恢复错误自动解暂停")
        TogglePause()
    end
    assertDiscarded(reason.."恢复")
    check(status().accepted==oldAccepted_,reason.."恢复凭空接受旧事件")
    transition("no-replay")
end
local function finish()
    check(reads_>0 and writes_>0 and cloudCalls_==0,"内存/云隔离未真正覆盖")
    cleanup();check(not failed_,"Stop清理失败")
    done_=true
    print(string.format("REAL_MAIN_AUDIO_REENTRY_PASS checks=%d frames=%d instances=%d freshArrivals=5 normalRoute=%s length=%.6f stations=10 decoderProgress=%.3f device=%s playerSaveIO=0 externalCloudCalls=0 gpuPixelsValidated=false audibleValidated=false hostAudioResumeInjected=%s",
        checks_,frames_,created_,Modes.Get("normal").routeId,Modes.Get("normal").routeLength,voiceMax_,tostring(device_),tostring(device_)))
    engine:Exit()
end
function Start()
    guard(function()
        for _,argument in ipairs(GetArguments()) do if argument=="-main-integration-device" then device_=true end end
        if device_ then
            engine:SetMaxFps(20);engine:SetMaxInactiveFps(20)
            -- 仅测试宿主首次触摸恢复音频的等效注入，不改生产main，不SetMode。
            check(audio:IsInitialized() and audio:Play(),"SDL disk设备未初始化/宿主等效resume失败")
        end
        started_=true;mainStart();begin(false)
    end)
end
function HandleUpdate()
    guard(function()
        frames_=frames_+1
        step(.02)
        check(frames_-stageFrame_<2400,"有界阶段超时 "..stage_)
        check(GetApplicationState()~="error","生产main加载/运行失败")
        if stage_=="loading" and GetApplicationState()=="playing" then
            check(#Route.GetStations()==10 and math.abs(Route.GetLength()-Modes.Get("normal").routeLength)<.001,
                "normal不是最新十站地图")
            check(status().lastEvent.kind=="welcome","新旅程未产生真实main欢迎")
            firstInstance_=assert(announcements_)
            prepareDriving(2)
            check(SaveJourneyNow(),"真实main无法保存内存旅程")
            savedJourney_=copy(fixture_.journeys.normal)
            returnMenu()
            check(firstInstance_.stopped,"返回菜单未Shutdown旧广播实例")
            begin(true);transition("reentry")
        elseif stage_=="reentry" and GetApplicationState()=="playing" then
            check(announcements_~=firstInstance_ and created_==2,"重进没有创建新真实广播实例")
            check(Hud.GetReadings().paused and status().accepted==0,"读档补播了welcome/旧广播")
            check(math.abs(Train.GetS()-savedJourney_.train.s)<.001,"重进坐标丢失")
            assertDiscarded("读档")
            TogglePause();arrive(2);round_=1;transition("voice")
        elseif stage_=="voice" then
            local actual=status()
            local definition=assert(Catalog.Get("arrival",2))
            if not device_ and actual.activePath==Catalog.Chime then
                assert(assert(announcements_).source):StopImmediate()
                step(.02)
                actual=status()
            end
            if actual.activePath==definition.zhPath then
                voiceMax_=math.max(voiceMax_,actual.timePosition)
                if not device_ or voiceMax_>.35 then
                    check(actual.lastEvent.voicedZh and actual.gain>0,"真实到站配音未带有效增益")
                    print(string.format(PREFIX.."REAL_MAIN_VOICE_ACTIVE accepted=%d path=%s position=%.3f cpuChimeAdvance=%s",
                        actual.accepted,actual.activePath,actual.timePosition,tostring(not device_)))
                    blockAndRestore()
                end
            end
            check(frames_-stageFrame_<350,"重进后实际arrival语音没有进入activePath/解码时钟")
        elseif stage_=="no-replay" and frames_-stageFrame_>=5 then
            assertDiscarded(reasons_[round_].."稳定恢复")
            check(status().accepted==oldAccepted_,"恢复数帧后补播旧事件")
            print(PREFIX.."NO_STALE_QUEUE_PASS reason="..reasons_[round_].." accepted="..oldAccepted_)
            if round_==4 then
                local visits=completeRealStop(6);arrive(6)
                check(Passenger.GetStats().visits==visits+1,"连续新站没有单调增加真实访问计数")
                local definition=assert(Catalog.Get("arrival",6))
                check(status().lastEvent.voicedZh and not status().lastEvent.voicedEn
                    and status().lastEvent.stationVoice and status().lastEvent.text==definition.text
                    and status().lastEvent.text:find(assert(Route.GetStations()[6]).name,1,true),
                    "新站真实中文配音/目标字幕不一致")
                local coverage=Catalog.GetCoverage()
                check(#Catalog.GetRecordingPlan()==34 and coverage.generatedChinese==34
                    and coverage.generatedStationChinese==30 and coverage.chineseStationVoices
                    and coverage.namedChineseStations==10 and coverage.unvoicedChineseStations==0,
                    "十站34条正式中文配音覆盖不完整")
                local job=assert(assert(announcements_).queue[1])
                check(job.definition.kind=="arrival" and job.definition.index==6 and #job.clips==2
                    and job.clips[1]==Catalog.Chime and job.clips[2]==definition.zhPath,
                    "新站队列没有提示音及准确目标录音")
                voiceMax_=0
                transition("new-chime")
            else
                round_=round_+1
                local visits=completeRealStop(round_+1);arrive(round_+1)
                check(Passenger.GetStats().visits==visits+1,"连续到站没有单调增加访问计数")
                transition("next-block")
            end
        elseif stage_=="next-block" then blockAndRestore()
        elseif stage_=="new-chime" then
            if not device_ and status().activePath~=Catalog.Chime then
                assert(assert(announcements_).source):StopImmediate();step(.02)
            end
            if status().activePath==Catalog.Chime then
                print(PREFIX.."NEW_STATION_CAPTION_CHIME_PASS index=6 voiced=true activePath="..status().activePath)
                transition("new-voice")
            end
        elseif stage_=="new-voice" then
            local definition=assert(Catalog.Get("arrival",6))
            if not device_ and status().activePath==Catalog.Chime then
                assert(assert(announcements_).source):StopImmediate();step(.02)
            end
            local actual=status()
            if actual.activePath==definition.zhPath then
                voiceMax_=math.max(voiceMax_,actual.timePosition)
                if not device_ or voiceMax_>.35 then
                    check(actual.lastEvent.voicedZh and actual.gain>0 and actual.caption==definition.text
                        and assert(assert(announcements_).source):GetSound()==assert(announcements_).sounds[assert(definition.zhPath)],
                        "真实main扩线到站录音未绑定准确Sound或增益/字幕异常")
                    print(string.format(PREFIX.."NEW_STATION_VOICE_ACTIVE_PASS index=6 path=%s position=%.3f cpuChimeAdvance=%s audibleValidated=false",
                        actual.activePath,actual.timePosition,tostring(not device_)))
                    finish()
                end
            end
            check(frames_-stageFrame_<350,"新站真实arrival录音没有进入activePath/解码时钟")
        end
    end)
end
function HandlePostUpdate(eventType,eventData)
    guard(function() mainPost(eventType,eventData) end)
end
function Stop() cleanup() end
