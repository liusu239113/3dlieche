-- 生产音频模块回归：真实资源解码/字幕/事件去重/生命周期；不声明设备听感已验证。
-- 沿用 SoundBindingValidation 的一次性 pcall + engine:Exit 脚手架。
local Announcements=require "audio.Announcements"
local Catalog=require "config.AnnouncementCatalog"
local World=require "config.FictionalWorld"
local UiAudio=require "audio.UiAudio"
local Soundscape=require "audio.Soundscape"
local ExperienceFeedback=require "core.ExperienceFeedback"
local checks_=0
---@type RailwayAnnouncements?
local active_=nil
local function check(condition,message)
    checks_=checks_+1;assert(condition,"[AnnouncementsValidation] "..message)
end
---@param a RailwayAnnouncements
---@param terminalIndex integer
local function integrationCases(a,terminalIndex)
    a:Reset()
    local reverseIndex=math.floor(terminalIndex-1)
    local emitted={}
    local observer=(ExperienceFeedback --[[@as table]]).new(function(kind,index,direction)
        emitted[#emitted+1]=kind
        a:Announce(kind,index,direction)
    end,function() a:Reset() end)
    local function snapshot(patch)
        local value={state="dwell",nextIndex=1,lastArrival=1,initialService=true,service="local",journeyId=1,
            visits=1,reversing=false,s=100,phase="boarding",terminal=false,terminalStop=false,dwelling=true}
        for key,item in pairs(patch or {}) do value[key]=item end
        return value --[[@as AnnouncementSnapshot]]
    end
    a:SetSettings({sound=true,volume=.5,language="both"})
    observer:Reset(snapshot(),true)
    check(a:GetStatus().lastEvent.kind=="welcome","observer始发未映射生产welcome")
    local driving=snapshot({state="driving",nextIndex=terminalIndex,initialService=false,dwelling=false,s=200,phase="ready"})
    observer:Update(driving,{blocked=false},10000)
    check(a:GetStatus().lastEvent.kind=="departure" and a:GetStatus().lastEvent.index==terminalIndex,
        "observer发车目标被二次加减索引")
    driving.s=8900
    observer:Update(driving,{blocked=false},10000)
    check(a:GetStatus().lastEvent.kind=="approach" and a:GetStatus().lastEvent.index==terminalIndex,"生产进站目标错误")
    local arrival=snapshot({lastArrival=terminalIndex,nextIndex=terminalIndex,initialService=false,visits=2,s=10000,terminalStop=true})
    observer:Update(arrival,{blocked=true,reason="passengers",waitSeconds=0},10000)
    check(a:GetStatus().lastEvent.kind=="arrival" and a:GetStatus().lastEvent.index==terminalIndex,"生产到站目标错误")
    -- 正常终到最低12秒站停：先让已入队的真实提示音播完，再收到清客终到事件。
    a:Update(.1)
    a.source:StopImmediate()
    for _=1,12 do a:Update(1) end
    local before=a:GetStatus().accepted
    local terminal=snapshot({state="terminal",lastArrival=terminalIndex,nextIndex=terminalIndex,initialService=false,visits=2,
        s=10000,phase="ready",terminal=true,terminalStop=true})
    observer:Update(terminal,{blocked=true,reason="terminal",waitSeconds=0},nil)
    check(a:GetStatus().lastEvent.kind=="terminal" and a:GetStatus().accepted==before+1,
        "两阶段终到未独立产生terminal")
    check(a:GetStatus().queued==1,"终到保留了过期arrival队列")
    terminal.phase="door_closing"
    observer:Update(terminal,{blocked=true,reason="terminal",waitSeconds=1},nil)
    check(a:GetStatus().accepted==before+1,"终到关门错误触发发车提醒")
    local returning=snapshot({lastArrival=terminalIndex,nextIndex=terminalIndex,initialService=true,visits=2,s=10000,
        journeyId=2,reversing=true,terminalStop=false})
    observer:Update(returning,{blocked=true,reason="passengers",waitSeconds=0},nil)
    check(a:GetStatus().lastEvent.kind=="welcome" and a:GetStatus().lastEvent.direction==-1,
        "折返未新增visits时漏欢迎")
    before=a:GetStatus().accepted
    observer:Update(returning,{blocked=true,reason="passengers",waitSeconds=1},nil)
    check(a:GetStatus().accepted==before,"折返欢迎重复")
    a:SetBlocked(true);a:SetBlocked(false)
    observer:Update(returning,{blocked=true,reason="passengers",waitSeconds=2},nil)
    check(a:GetStatus().queued==0 and a:GetStatus().caption=="","暂停恢复补播旧欢迎或字幕")
    observer:Reset(returning,false)
    check(a:GetStatus().queued==0,"读档恢复补播欢迎")
    local reverseDriving=snapshot({state="driving",lastArrival=terminalIndex,nextIndex=reverseIndex,initialService=false,visits=2,
        journeyId=2,reversing=true,s=10000,phase="ready",dwelling=false})
    observer:Update(reverseDriving,{blocked=false},6000)
    check(a:GetStatus().lastEvent.kind=="departure" and a:GetStatus().lastEvent.index==reverseIndex
        and a:GetStatus().lastEvent.direction==-1,"折返下一站/方向错位")
    reverseDriving.s=7000
    observer:Update(reverseDriving,{blocked=false},6000)
    check(a:GetStatus().lastEvent.kind=="approach" and a:GetStatus().lastEvent.index==reverseIndex,"反向进站距离错位")
    a:SetVolume(0)
    local reverseArrival=snapshot({lastArrival=reverseIndex,nextIndex=reverseIndex,initialService=false,visits=3,journeyId=2,
        reversing=true,s=6000})
    observer:Update(reverseArrival,{blocked=true,reason="passengers",waitSeconds=0},6000)
    check(a:GetStatus().queued==0 and a:GetStatus().caption:find(World.stations[reverseIndex].name,1,true)~=nil,
        "音量0未保留逐站字幕或仍排音频")
    a:SetLanguage("en");a:SetVolume(.5)
    observer:Reset(reverseArrival,false)
    reverseArrival.phase="door_closing"
    observer:Update(reverseArrival,{blocked=true,reason="passengers",waitSeconds=0},6000)
    check(a:GetStatus().lastEvent.kind=="departure_reminder" and not a:GetStatus().lastEvent.voicedEn,
        "英文模式虚构未录制的提醒配音")
    check(#emitted>=10,"集成事件轨迹意外缺失")
end
local function validateCatalog()
    check(Catalog.VoiceName=="车站广播员_自然清亮女声试听" and Catalog.VoiceId=="ejenasfTqWt7CTPPsovM",
        "正式广播不是用户选定并确认的2号声线")
    check(Catalog.GenerationStatus=="complete" and Catalog.CompletedBatchChinese==19
        and Catalog.ExtensionBatchChinese==15 and Catalog.GetGenerationFailure()==nil,
        "原19段历史批次/新增15段与完整交付状态不一致")
    local failure=Catalog.GetPreviousGenerationFailure()
    check(failure.historical and failure.characterName=="车站广播员" and failure.voiceId=="zCBAatjWp22hVkvaEDFX",
        "旧角色失败诊断丢失或被归属给新声线")
    check(failure.attemptsThisRecovery==1 and failure.httpStatus==404 and failure.mcpCode==-32603,
        "历史唯一失败探针记录丢失")
    check(failure.languageCode=="cmn" and failure.stability==.5
        and failure.supersededByConfirmedVoice==Catalog.VoiceId,
        "历史失败没有与新已确认声线区分")
    check(failure.text==assert(Catalog.Get("welcome")).text and failure.response:find("HTTP 404",1,true),
        "历史失败原文与可复核请求不一致")
    local resources,planned,kinds,texts,recorded={},{},{},{},{}
    for _,path in ipairs(Catalog.GetResourcePaths()) do
        check(not resources[path],"实际资源清单重复："..path)
        resources[path]=true
    end
    local plan={}
    local definitions=Catalog.GetRecordingPlan()
    check(#definitions==4+3*#World.stations,"广播计划未覆盖全部车站")
    for _,definition in ipairs(definitions) do
        if definition.generated then plan[#plan+1]=definition end
    end
    check(#plan==34 and #plan==#definitions,"十站正式中文广播未全部交付")
    local originalCount,extensionCount=0,0
    local originalIds={"xingxi","langang","yucen","jinglan","yunwan"} ---@type string[]
    local extensionIds={"cuichuan","shimen","yunji","songlan","tianchi"} ---@type string[]
    for _,definition in ipairs(plan) do
        check(definition.text~="" and definition.text:find("%s",1,true)==nil,"文案未完成格式化")
        check(not texts[definition.text],"不同事件共用了相同录制文案")
        texts[definition.text]=true
        check(not planned[definition.plannedPath],"多个事件共用了计划录音路径")
        planned[definition.plannedPath]=true
        check(definition.plannedPath:match("^audio/voice/announcements/[%w_]+%.ogg$")~=nil,
            "计划录音不是资源根内的独立OGG")
        check(definition.generated and definition.zhPath~=nil and not definition.legacyFallback,
            "已完成的正式中文录音未登记或仍依赖旧欢迎")
        local path=assert(definition.zhPath)
        check(resources[path] and cache:Exists(path),"正式录音不在真实资源清单或文件缺失："..path)
        local fileKind=definition.kind=="departure" and "next" or definition.kind
        if definition.index<=5 then
            -- 原19条必须保持原批次的准确事件/目标路径，不能被新音频覆盖或混站。
            local suffix=definition.index>0 and "_"..assert(originalIds[definition.index]) or ""
            local expected="audio/voice/railway_natural_"..fileKind..suffix.."_zh_20261017_1_650660547ebc5cf5.ogg"
            check(path:match("^audio/voice/railway_natural_[%w_]+_zh_20261017_1_650660547ebc5cf5%.ogg$")~=nil,
                "原19条正式录音不是原官方返回路径")
            check(path==expected,"原批次录音事件/目标站错配："..path)
            originalCount=originalCount+1
        else
            local extensionIndex=math.floor(definition.index-5)
            local stationId=assert(extensionIds[extensionIndex])
            check(World.stations[definition.index].id==stationId,"扩线语音目标站ID错位")
            local expected="audio/voice/railway_natural_"..fileKind.."_"..stationId.."_zh_20261019_1_650660547ebc5cf5.ogg"
            check(path:match("^audio/voice/railway_natural_[%w_]+_zh_20261019_1_650660547ebc5cf5%.ogg$")~=nil,
                "新增15条正式录音不是扩线官方返回路径")
            check(path==expected,"扩线录音事件/目标站错配："..path)
            extensionCount=extensionCount+1
        end
        check(not recorded[path],"多个正式事件复用了同一条语音："..path)
        recorded[path]=true
        check(not resources[definition.plannedPath],"原计划路径被冒充真实工具输出")
        local sound=cache:GetResource("Sound",path) --[[@as Sound?]]
        check(sound~=nil,"新声线录音无法按引擎Sound加载："..path)
        local decoded=assert(sound)
        check(decoded:GetLength()>1 and decoded:GetLength()<30 and decoded:GetFrequency()==44100,
            "新声线录音时长/采样率异常："..path)
        check(decoded:IsCompressed() and not decoded:IsStereo() and decoded:GetDataSize()>1000,
            "新声线不是完整单声道Vorbis资源："..path)
        print(string.format("ANNOUNCEMENT_SOUND_LOAD_PASS kind=%s index=%d seconds=%.3f hz=%d bytes=%d path=%s",
            definition.kind,definition.index,decoded:GetLength(),decoded:GetFrequency(),decoded:GetDataSize(),path))
        kinds[definition.kind]=(kinds[definition.kind] or 0)+1
        check((definition.enPath~=nil)==(definition.kind=="welcome"),
            "未生成英文广播被错误登记或旧英文欢迎丢失")
    end
    check(originalCount==Catalog.CompletedBatchChinese and originalCount==19
        and extensionCount==Catalog.ExtensionBatchChinese and extensionCount==15,"历史/扩线批次真实路径计数不一致")
    for _,kind in ipairs({"welcome","terminal","wait_signal","departure_reminder"}) do
        check(kinds[kind]==1,"通用广播缺失："..kind)
    end
    for _,kind in ipairs({"departure","approach","arrival"}) do
        check(kinds[kind]==#World.stations,"逐站广播未覆盖十站："..kind)
    end
    -- 返回对象是快照：测试/工具读清单不应能篡改生产字幕或错误状态。
    plan[1].text="test mutation"
    failure.voiceId="test mutation"
    check(assert(Catalog.Get("welcome")).text~="test mutation"
        and Catalog.GetPreviousGenerationFailure().voiceId=="zCBAatjWp22hVkvaEDFX","清单/证据泄露可变内部状态")
end
local function validate()
    validateCatalog()
    for _,module in ipairs({Announcements,UiAudio,Soundscape}) do
        for _,path in ipairs(module.GetResourcePaths()) do
            check(cache:Exists(path),"资源清单引用缺失文件："..path)
            check(not path:find("announcements/",1,true),"未交付计划路径进入真实资源列表")
            local sound=cache:GetResource("Sound",path) --[[@as Sound?]]
            check(sound~=nil,"真实资源无法作为Sound解码："..path)
            check(assert(sound):GetLength()>0 and assert(sound):GetFrequency()>0,
                "已登记素材时长或采样率无效："..path)
        end
    end
    local coverage=Catalog.GetCoverage()
    check(coverage.generatedChinese==34 and coverage.plannedChinese==34
        and coverage.generatedStationChinese==30 and coverage.plannedStationChinese==30,
        "十站34段中文交付/30段逐站录音计数不真实")
    check(coverage.chineseStationVoices and coverage.namedChineseStations==10
        and coverage.unvoicedChineseStations==0 and not coverage.englishStationVoices
        and coverage.englishStationRecorded==0,"十站中文覆盖或未录制英文状态不真实")
    check(coverage.completedBatchChinese==19 and coverage.generationStatus=="complete" and coverage.generationError==nil,
        "历史19段批次语义或完整交付状态丢失")
    for index,station in ipairs(World.stations) do
        for _,kind in ipairs({"departure","approach","arrival"}) do
            local definition=assert(Catalog.Get(kind,index))
            check(definition.text:find(station.name,1,true)~=nil,"字幕不是统一架空站名")
            check(definition.generated and definition.zhPath~=nil
                and definition.enPath==nil,"逐站真实配音覆盖错误或虚构英文录音")
            check(definition.plannedPath~="","没有独立录制目标")
            local zh,en=Announcements.GetCaption(kind,index)
            check(zh==definition.text and en:find(station.englishName,1,true)~=nil,"字幕接口丢失目标站")
        end
    end
    check(Catalog.Get("departure",0)==nil and Catalog.Get("arrival",#World.stations+1)==nil,"非法站索引未拒绝")
    check(Catalog.Get("unknown",1)==nil,"未知广播类型未拒绝")
    check(Catalog.Get("next_station",2).kind=="departure","下一站别名无效")
    Soundscape.Init();Soundscape.SetSettings({sound=true,volume=.75,music=false,ambienceVolume=.45})
    Soundscape.SetContext("exterior",500,0,false,true);Soundscape.SetTrainMix(0,0,0,0)
    check(Soundscape.GetAnnouncementGain()>0,"禁持续行驶声误杀广播")
    Soundscape.SetEnvironment({weather="rain",rainIntensity=.8,lampFactor=.7})
    Soundscape.Update(.1)
    local environment=Soundscape.GetDiagnostics()
    check(environment.rainIntensity==.8 and environment.night==.7,"天气status参数未接收")
    check(environment.channels.rain.ready,"真实生成雨WAV未解码")
    check(environment.channels.rain.gain>0,"无列车循环参考时雨声静音")
    check(environment.continuousTrainLoops==false,"恢复了持续轮轨层")
    Soundscape.SetBlocked(true)
    check(Soundscape.GetAnnouncementGain()==0,"阻塞广播预算非零")
    Soundscape.SetBlocked(false)
    active_=Announcements.new({language="both",volume=.6})
    local a=assert(active_)
    local accepted,caption=a:Announce("welcome",1,1)
    check(accepted and caption~="","welcome事件无字幕")
    local status=a:GetStatus()
    check(status.lastEvent.voicedZh and status.lastEvent.voicedEn and not status.lastEvent.legacyFallback,
        "新中文欢迎/旧英文欢迎混合覆盖不正确")
    check(not a:Announce("welcome",1,1),"重复welcome入队")
    check(a:GetStatus().duplicates==1,"未记录去重")
    a:Update(.1)
    check(a:GetStatus().played==1,"真实报站提示音未进入Play")
    -- 每条正式录音均走一次真实生产队列，停止提示音只用于确定性推进，不假装设备已出声。
    a:SetLanguage("zh")
    for _,definition in ipairs(Catalog.GetRecordingPlan()) do
        if definition.generated then
        a:Reset()
        local index=definition.index>0 and definition.index or nil
        check(a:Announce(definition.kind,index,1),"正式广播未被生产队列接受")
        a:Update(.1)
        check(a:GetStatus().activePath==definition.chime,"提示音未先于正式语音")
        assert(a.source):StopImmediate()
        a:Update(.1)
        check(a:GetStatus().activePath==definition.zhPath,"生产队列没有播放对应的正式录音")
        check(assert(a.source):GetFrequency()==44100,"正式录音没有按原采样率播放")
        check(a:GetStatus().lastEvent.voicedZh and not a:GetStatus().lastEvent.legacyFallback,
            "正式语音派发退回了旧欢迎")
        end
    end
    -- 新增15条分别验证双向准确目标：提示音->本站录音，不借用相邻站或通用欢迎。
    for _,direction in ipairs({1,-1}) do
        for index=6,#World.stations do
            for _,kind in ipairs({"departure","approach","arrival"}) do
                a:Reset()
                local definition=assert(Catalog.Get(kind,index))
                check(a:Announce(kind,index,direction),"扩线双向事件未被接受")
                local job=assert(a.queue[1])
                check(#job.clips==2 and job.clips[1]==Catalog.Chime and job.clips[2]==definition.zhPath
                    and job.definition.index==index and job.definition.kind==kind,"扩线事件队列录音目标错配")
                check(not a:Announce(kind,index,direction),"扩线同方向同目标事件没有去重")
                a:Update(.1)
                check(a:GetStatus().activePath==Catalog.Chime,"扩线事件没有先播放提示音")
                assert(a.source):StopImmediate();a:Update(.1)
                local actual=a:GetStatus()
                check(actual.activePath==definition.zhPath and actual.lastEvent.voicedZh
                    and not actual.lastEvent.voicedEn and actual.lastEvent.direction==direction
                    and actual.lastEvent.stationVoice and actual.caption==definition.text,
                    "扩线事件没有播放准确方向/目标录音或字幕")
                check(assert(a.source):GetSound()==a.sounds[assert(definition.zhPath)]
                    and assert(a.source):GetFrequency()==44100,"扩线真实Sound绑定/采样率错配")
            end
        end
    end
    -- 中文补齐不能伪造英文；静音只保留目标字幕，不囤积新站配音。
    for index=6,#World.stations do
        for _,kind in ipairs({"departure","approach","arrival"}) do
            a:SetLanguage("en");a:Reset()
            local definition=assert(Catalog.Get(kind,index))
            check(a:Announce(kind,index,-1),"英文模式丢弃扩线字幕事件")
            local job=assert(a.queue[1])
            check(#job.clips==1 and job.clips[1]==Catalog.Chime
                and not a:GetStatus().lastEvent.voicedZh and not a:GetStatus().lastEvent.voicedEn,
                "英文模式错误播放扩线中文或虚构英文录音")
            a:Update(.1);assert(a.source):StopImmediate();a:Update(.1)
            check(a:GetStatus().queued==0,"英文扩线提示音之后排入不存在的录音")
            a:SetLanguage("zh");a:SetVolume(0);a:Reset()
            check(a:Announce(kind,index,1) and a:GetStatus().caption==definition.text
                and a:GetStatus().queued==0,"扩线静音没有保留字幕或囤积配音")
            a:SetVolume(.6)
            check(a:GetStatus().queued==0 and not a:Announce(kind,index,1),"恢复扩线音量补播了旧事件")
        end
    end
    a:SetLanguage("both")
    a:Reset()
    check(a:GetStatus().queued==0 and a:GetStatus().caption=="","Reset未清队列字幕")
    for index=1,#World.stations do
        check(a:Announce("departure",index,1),"新站区间被永久去重")
        check(not a:Announce("departure",index,1),"相同目标重复发车")
        check(a:Announce("approach",index,1),"进站事件缺失")
        check(a:Announce("arrival",index,1),"到站事件缺失")
        check(a:GetStatus().lastEvent.voicedZh and not a:GetStatus().lastEvent.voicedEn
            and a:GetStatus().lastEvent.stationVoice,"已生成逐站中文未进入生产队列或虚构英文配音")
    end
    check(a:Announce("departure",4,-1),"换向后事件被旧键阻挡")
    check(a:GetStatus().queued==1,"换向未清旧队列")
    a:SetBlocked(true)
    check(a:GetStatus().queued==0,"暂停未丢弃排队广播")
    check(not a:Announce("arrival",3,-1),"暂停接受了新广播")
    a:SetBlocked(false)
    check(a:GetStatus().queued==0,"恢复暂停补播过时广播")
    check(not a:Announce("departure",4,-1),"恢复暂停丢失seen导致旧发车重播")
    a:Reset()
    a:Announce("arrival",3,-1);a:SetLanguage("en")
    check(a:GetStatus().queued==0,"切语言未清队列")
    check(a:Announce("arrival",3,-1),"英语模式丢弃字幕事件")
    check(not a:GetStatus().lastEvent.voicedEn,"英文逐站覆盖伪造")
    a:SetVolume(0)
    check(a:GetStatus().queued==0,"静音保留旧队列")
    a:Announce("approach",2,-1)
    check(a:GetStatus().queued==0,"静音期间囤积待播语音")
    a:SetVolume(.5);a:SetLanguage("off")
    check(not a:Announce("arrival",2,-1),"广播off仍接受事件")
    a:SetLanguage("zh");a:Reset()
    -- 测试专用实例覆盖Load，模拟下载回调丢失，不发出任何真实失败下载。
    local productionLoad=a.Load
    local testHooks=a --[[@as table]]
    testHooks.Load=function(_,path) a.pending[path]=999 end
    a.sounds={}
    check(a:Announce("welcome",1,1),"失败路径事件未入队")
    for _=1,40 do a:Update(1) end
    check(a:GetStatus().queued==0 and a:GetStatus().skipped>=2,"缺素材或无回调永久堵塞队列")
    a.Load=productionLoad
    a:Reset()
    check(a:Announce("arrival",1,1),"失败后有效事件无法恢复")
    a:Update(.1)
    check(a:GetStatus().activePath==Catalog.Chime,"失败后真实提示音无法恢复")
    local count=a:GetStatus().accepted
    a:SetSettings({sound=false,volume=1,language="both"})
    check(a:GetStatus().queued==0 and not a:Announce("welcome"),"声音总开关无效")
    check(a:GetStatus().accepted==count,"禁音时接受计数异常")
    integrationCases(a,5)
    integrationCases(a,#World.stations)
    a:Shutdown();a:Shutdown()
    check(not a:Announce("welcome"),"Shutdown之后仍接受事件")
    UiAudio.Init();UiAudio.SetSettings(true,.5,"both")
    check(UiAudio.Click(),"实际UI点击素材未播放")
    UiAudio.SetBlocked(true)
    check(not UiAudio.Click() and not UiAudio.DoorClose(),"界面阻塞未禁提示音")
    UiAudio.SetBlocked(false);UiAudio.SetSettings(true,0,"both")
    check(not UiAudio.Click(),"UI音量0仍播放")
    UiAudio.Shutdown()
    print(string.format("ANNOUNCEMENTS_VALIDATION_PASS checks=%d chineseDelivered=34 originalBatch=19 extensionBatch=15 chineseStation=30/30 newStations=caption+chime+voice bidirectional=true terminalIndices=5,10 englishStation=0/30 sfx=3 deviceOutput=NOT_RUN audible=NOT_RUN",checks_))
end
function Start()
    local ok,message=pcall(validate)
    if active_ then active_:Shutdown() end
    UiAudio.Shutdown();Soundscape.Shutdown()
    if not ok then
        print("ANNOUNCEMENTS_VALIDATION_FAILED "..tostring(message))
        log:Write(LOG_ERROR,tostring(message))
    end
    engine:Exit()
end
