-- 原创架空广播文案与真实配音覆盖。站名只从 FictionalWorld 获取。
-- 2026-10-17：用户选定试听2号并确认新声线后，首批19条官方 ElevenLabs 独立输出已落盘。
-- 2026-10-19：沿用同一已确认声线，补齐后五站15条；十站中文广播现已全覆盖。
-- path 使用工具真实返回的资源路径；plannedPath 保留原录制计划，不当作交付资产。
-- 原角色映射不变；旧欢迎资源不计入34段正式录音。
local World = require "config.FictionalWorld"
---@type {id:string,name:string,englishName:string}[]
local stations = World.stations
local Catalog = {}
Catalog.Chime = "audio/sfx/rail_announcement_chime.wav"
Catalog.DoorChime = "audio/sfx/rail_door_close_chime.wav"
Catalog.GenerationStatus = "complete"
Catalog.CompletedBatchChinese = 19 -- 2026-10-17 首批历史数量，不覆写为总覆盖。
Catalog.ExtensionBatchChinese = 15 -- 2026-10-19 后五站独立补录。
Catalog.VoiceName = "车站广播员_自然清亮女声试听"
Catalog.VoiceId = "ejenasfTqWt7CTPPsovM" -- 用户明确选择并由官方 confirm 保存；不覆写旧角色映射。
Catalog.GenericEnglish = "audio/voice/fictional_boarding_en_1_aca51c5d8ff454f4.ogg"
local LEGACY_ZH = "audio/voice/fictional_boarding_zh_1_aca51c5d8ff454f4.ogg"

---@class RailwayAnnouncementRecording
---@field plannedPath string
---@field generated boolean
---@field path? string
---@field fallback? string
---@field text? string
---@type table<string,RailwayAnnouncementRecording>
local general = {
    welcome = {generated=true, plannedPath="audio/voice/announcements/welcome_zh.ogg", fallback=LEGACY_ZH,
        path="audio/voice/railway_natural_welcome_zh_20261017_1_650660547ebc5cf5.ogg",
        text="各位旅客，欢迎乘坐群域行旅联队列车。这里是星澜群域，愿沿途的山川与灯火，陪伴您一段安稳的旅程。请将行李放妥，保管好随身物品，感谢您的配合。"},
    terminal = {generated=true, plannedPath="audio/voice/announcements/terminal_zh.ogg",
        path="audio/voice/railway_natural_terminal_zh_20261017_1_650660547ebc5cf5.ogg",
        text="本次列车已到达终点站。请带齐随身物品，在车门开启后依次下车。感谢您与群域行旅联队共度这段旅程，愿下一程，依然一路平安。"},
    wait_signal = {generated=true, plannedPath="audio/voice/announcements/wait_signal_zh.ogg",
        path="audio/voice/railway_natural_wait_signal_zh_20261017_1_650660547ebc5cf5.ogg",
        text="各位旅客，列车正在等待前方信号，稍后继续运行。请您安心在座位上等候，不要靠近车门。感谢您的理解与耐心。"},
    departure_reminder = {generated=true, plannedPath="audio/voice/announcements/departure_reminder_zh.ogg",
        path="audio/voice/railway_natural_departure_reminder_zh_20261017_1_650660547ebc5cf5.ogg",
        text="各位旅客，列车即将发车，车门即将关闭。请勿倚靠车门，请将随身物品收好。尚未上车的旅客，请留意站台引导，不要追赶列车。"},
}
-- 每条官方调用仅一条输入；完整真实路径字面量供构建追踪，未拼接或切分长音轨。
---@type table<string,RailwayAnnouncementRecording[]>
local stationRecordings = {
    departure = {
        {generated=true,plannedPath="audio/voice/announcements/next_xingxi_zh.ogg",
            path="audio/voice/railway_natural_next_xingxi_zh_20261017_1_650660547ebc5cf5.ogg"},
        {generated=true,plannedPath="audio/voice/announcements/next_langang_zh.ogg",
            path="audio/voice/railway_natural_next_langang_zh_20261017_1_650660547ebc5cf5.ogg"},
        {generated=true,plannedPath="audio/voice/announcements/next_yucen_zh.ogg",
            path="audio/voice/railway_natural_next_yucen_zh_20261017_1_650660547ebc5cf5.ogg"},
        {generated=true,plannedPath="audio/voice/announcements/next_jinglan_zh.ogg",
            path="audio/voice/railway_natural_next_jinglan_zh_20261017_1_650660547ebc5cf5.ogg"},
        {generated=true,plannedPath="audio/voice/announcements/next_yunwan_zh.ogg",
            path="audio/voice/railway_natural_next_yunwan_zh_20261017_1_650660547ebc5cf5.ogg"},
        {generated=true,plannedPath="audio/voice/announcements/departure_cuichuan_zh.ogg",
            path="audio/voice/railway_natural_next_cuichuan_zh_20261019_1_650660547ebc5cf5.ogg"},
        {generated=true,plannedPath="audio/voice/announcements/departure_shimen_zh.ogg",
            path="audio/voice/railway_natural_next_shimen_zh_20261019_1_650660547ebc5cf5.ogg"},
        {generated=true,plannedPath="audio/voice/announcements/departure_yunji_zh.ogg",
            path="audio/voice/railway_natural_next_yunji_zh_20261019_1_650660547ebc5cf5.ogg"},
        {generated=true,plannedPath="audio/voice/announcements/departure_songlan_zh.ogg",
            path="audio/voice/railway_natural_next_songlan_zh_20261019_1_650660547ebc5cf5.ogg"},
        {generated=true,plannedPath="audio/voice/announcements/departure_tianchi_zh.ogg",
            path="audio/voice/railway_natural_next_tianchi_zh_20261019_1_650660547ebc5cf5.ogg"},
    },
    approach = {
        {generated=true,plannedPath="audio/voice/announcements/approach_xingxi_zh.ogg",
            path="audio/voice/railway_natural_approach_xingxi_zh_20261017_1_650660547ebc5cf5.ogg"},
        {generated=true,plannedPath="audio/voice/announcements/approach_langang_zh.ogg",
            path="audio/voice/railway_natural_approach_langang_zh_20261017_1_650660547ebc5cf5.ogg"},
        {generated=true,plannedPath="audio/voice/announcements/approach_yucen_zh.ogg",
            path="audio/voice/railway_natural_approach_yucen_zh_20261017_1_650660547ebc5cf5.ogg"},
        {generated=true,plannedPath="audio/voice/announcements/approach_jinglan_zh.ogg",
            path="audio/voice/railway_natural_approach_jinglan_zh_20261017_1_650660547ebc5cf5.ogg"},
        {generated=true,plannedPath="audio/voice/announcements/approach_yunwan_zh.ogg",
            path="audio/voice/railway_natural_approach_yunwan_zh_20261017_1_650660547ebc5cf5.ogg"},
        {generated=true,plannedPath="audio/voice/announcements/approach_cuichuan_zh.ogg",
            path="audio/voice/railway_natural_approach_cuichuan_zh_20261019_1_650660547ebc5cf5.ogg"},
        {generated=true,plannedPath="audio/voice/announcements/approach_shimen_zh.ogg",
            path="audio/voice/railway_natural_approach_shimen_zh_20261019_1_650660547ebc5cf5.ogg"},
        {generated=true,plannedPath="audio/voice/announcements/approach_yunji_zh.ogg",
            path="audio/voice/railway_natural_approach_yunji_zh_20261019_1_650660547ebc5cf5.ogg"},
        {generated=true,plannedPath="audio/voice/announcements/approach_songlan_zh.ogg",
            path="audio/voice/railway_natural_approach_songlan_zh_20261019_1_650660547ebc5cf5.ogg"},
        {generated=true,plannedPath="audio/voice/announcements/approach_tianchi_zh.ogg",
            path="audio/voice/railway_natural_approach_tianchi_zh_20261019_1_650660547ebc5cf5.ogg"},
    },
    arrival = {
        {generated=true,plannedPath="audio/voice/announcements/arrival_xingxi_zh.ogg",
            path="audio/voice/railway_natural_arrival_xingxi_zh_20261017_1_650660547ebc5cf5.ogg"},
        {generated=true,plannedPath="audio/voice/announcements/arrival_langang_zh.ogg",
            path="audio/voice/railway_natural_arrival_langang_zh_20261017_1_650660547ebc5cf5.ogg"},
        {generated=true,plannedPath="audio/voice/announcements/arrival_yucen_zh.ogg",
            path="audio/voice/railway_natural_arrival_yucen_zh_20261017_1_650660547ebc5cf5.ogg"},
        {generated=true,plannedPath="audio/voice/announcements/arrival_jinglan_zh.ogg",
            path="audio/voice/railway_natural_arrival_jinglan_zh_20261017_1_650660547ebc5cf5.ogg"},
        {generated=true,plannedPath="audio/voice/announcements/arrival_yunwan_zh.ogg",
            path="audio/voice/railway_natural_arrival_yunwan_zh_20261017_1_650660547ebc5cf5.ogg"},
        {generated=true,plannedPath="audio/voice/announcements/arrival_cuichuan_zh.ogg",
            path="audio/voice/railway_natural_arrival_cuichuan_zh_20261019_1_650660547ebc5cf5.ogg"},
        {generated=true,plannedPath="audio/voice/announcements/arrival_shimen_zh.ogg",
            path="audio/voice/railway_natural_arrival_shimen_zh_20261019_1_650660547ebc5cf5.ogg"},
        {generated=true,plannedPath="audio/voice/announcements/arrival_yunji_zh.ogg",
            path="audio/voice/railway_natural_arrival_yunji_zh_20261019_1_650660547ebc5cf5.ogg"},
        {generated=true,plannedPath="audio/voice/announcements/arrival_songlan_zh.ogg",
            path="audio/voice/railway_natural_arrival_songlan_zh_20261019_1_650660547ebc5cf5.ogg"},
        {generated=true,plannedPath="audio/voice/announcements/arrival_tianchi_zh.ogg",
            path="audio/voice/railway_natural_arrival_tianchi_zh_20261019_1_650660547ebc5cf5.ogg"},
    },
}
local templates = {
    departure="列车已发车，下一站，%s。请您坐稳扶好，祝您旅途愉快。",
    approach="前方即将到达，%s。请下车的旅客提前整理随身物品，列车停稳后再起身。",
    arrival="%s，到了。请在车门开启后有序下车，留意站台与车厢之间的空隙。",
}
local aliases = {next_station="departure", signal_wait="wait_signal", waiting="wait_signal",
    boarding="welcome", reminder="departure_reminder", final="terminal"}

---@param kind string
---@return string
function Catalog.NormalizeKind(kind) return aliases[kind] or kind end

---@class RailwayAnnouncementDefinition
---@field kind string
---@field index number
---@field text string
---@field englishText string
---@field zhPath? string
---@field enPath? string
---@field chime string
---@field generated boolean
---@field plannedPath string
---@field legacyFallback boolean

--- index 始终是目标站；departure 并不在这里再自动加减站序。
---@param kind string
---@param index? number
---@return RailwayAnnouncementDefinition?
function Catalog.Get(kind,index)
    kind=Catalog.NormalizeKind(kind)
    local recordings=stationRecordings[kind]
    if index~=nil and (type(index)~="number" or index%1~=0) then return nil end
    local station=index and stations[index] or nil
    if index~=nil and not station then return nil end
    ---@type RailwayAnnouncementRecording?
    local recording=general[kind]
    if recordings then
        if not station or not index then return nil end
        recording=recordings[index]
        if not recording then
            -- 新站只有真实站名字幕和提示音，不复用含其他站名的旧录音。
            recording={generated=false,plannedPath="audio/voice/announcements/"..kind.."_"..station.id.."_zh.ogg"}
        end
    end
    if not recording then return nil end
    local text=recording.text or string.format(templates[kind],assert(station).name)
    local englishText=""
    if station then
        if kind=="departure" then englishText="The next stop is "..station.englishName.."."
        elseif kind=="approach" then englishText="We are approaching "..station.englishName.."."
        elseif kind=="arrival" then englishText="We have arrived at "..station.englishName.."." end
    end
    local english={welcome="Welcome aboard. Please keep your belongings with you.",
        terminal="This is the final stop. Thank you for travelling with us.",
        wait_signal="We are waiting for a signal. Please remain seated.",
        departure_reminder="The train is ready to depart. Please stand clear of the doors."}
    return {kind=kind,index=index or 0,text=text,englishText=english[kind] or englishText,
        zhPath=recording.generated and recording.path or recording.fallback,
        enPath=kind=="welcome" and Catalog.GenericEnglish or nil,
        chime=kind=="departure_reminder" and Catalog.DoorChime or Catalog.Chime,
        generated=recording.generated,plannedPath=recording.plannedPath,
        legacyFallback=recording.fallback~=nil and not recording.generated}
end

--- 稳定顺序的独立录制清单：每条均可直接作为官方工具的单条输入；不拼接或猜测分段。
---@return RailwayAnnouncementDefinition[]
function Catalog.GetRecordingPlan()
    local definitions={}
    for _,kind in ipairs({"welcome","terminal","wait_signal","departure_reminder"}) do
        definitions[#definitions+1]=assert(Catalog.Get(kind))
    end
    for _,kind in ipairs({"departure","approach","arrival"}) do
        for index=1,#World.stations do
            definitions[#definitions+1]=assert(Catalog.Get(kind,index))
        end
    end
    return definitions
end

--- 当前34段没有生成错误；旧角色的404不是新声线的失败状态。
---@return table?
function Catalog.GetGenerationFailure() return nil end

--- 历史探针仅作诊断，不在运行时重试、不读取或修改角色映射。
function Catalog.GetPreviousGenerationFailure()
    return {
        date="2026-10-17",tool="text_to_dialogue",attemptsThisRecovery=1,historical=true,
        characterName="车站广播员",voiceId="zCBAatjWp22hVkvaEDFX",
        languageCode="cmn",stability=.5,outputName="railway_original_welcome_zh_20261017",
        text=assert(Catalog.Get("welcome")).text,httpStatus=404,mcpCode=-32603,
        response="MCP error -32603: MCP error -32603: Tool 'text_to_dialogue' failed: 对话生成失败: Speech generation failed: HTTP 404",
        cause="unconfirmed_voice_or_service_route",serviceRecoveryRequired=false,
        supersededByConfirmedVoice=Catalog.VoiceId,
    }
end

--- 仅返回真实交付资源；pending plannedPath 不可冒充已生成录音。
---@return string[]
function Catalog.GetResourcePaths()
    local paths={Catalog.Chime,Catalog.DoorChime,LEGACY_ZH,Catalog.GenericEnglish}
    for _,recording in pairs(general) do
        if recording.generated and recording.path then paths[#paths+1]=recording.path end
    end
    for _,recordings in pairs(stationRecordings) do
        for _,recording in ipairs(recordings) do
            if recording.generated and recording.path then paths[#paths+1]=recording.path end
        end
    end
    return paths
end

function Catalog.GetCoverage()
    local generated,stationCount=0,0
    for _,recording in pairs(general) do if recording.generated then generated=generated+1 end end
    for _,recordings in pairs(stationRecordings) do
        for _,recording in ipairs(recordings) do
            if recording.generated then generated=generated+1;stationCount=stationCount+1 end
        end
    end
    local plannedStationChinese=#World.stations*3
    return {plannedChinese=4+plannedStationChinese,generatedChinese=generated,plannedStationChinese=plannedStationChinese,
        generatedStationChinese=stationCount,legacyChineseWelcome=true,legacyEnglishWelcome=true,
        chineseStationVoices=stationCount==plannedStationChinese,englishStationVoices=false,
        namedChineseStations=stationCount/3,unvoicedChineseStations=#World.stations-stationCount/3,
        completedBatchChinese=Catalog.CompletedBatchChinese,extensionBatchChinese=Catalog.ExtensionBatchChinese,
        englishStationRecorded=0,generationStatus=Catalog.GenerationStatus,
        generationError=nil,voiceName=Catalog.VoiceName,voiceId=Catalog.VoiceId}
end
return Catalog
