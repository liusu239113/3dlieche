-- 星澜群域：玩家可见名称的唯一纯数据源。
-- 稳定键只服务存档、资源加载及几何/动力校准，不是对外车型名称。
-- 无引擎对象、无文件读写、无事件订阅，可供主入口、线路配置与语音模块共同使用。
local FictionalWorld = {
    name = "星澜群域",
    operatorName = "群域行旅联队",
    routeDisplayName = "星汐—云湾干线",
    symbolName = "双棱航迹",
    symbolDescription = "两枚错位空心菱形与短航迹线；独立车队符号，不使用现实铁路或制造商徽记",
    disclaimer = "架空运营世界与虚构车队；模型沿用既有资产并派生涂装，不代表现实铁路或制造商。",
    stations = {
        {id="xingxi", name="星汐总站", shortName="星汐", englishName="Xingxi Terminal", regionName="星汐城"},
        {id="langang", name="岚港站", shortName="岚港", englishName="Langang Station", regionName="岚港城"},
        {id="yucen", name="榆岑站", shortName="榆岑", englishName="Yucen Station", regionName="榆岑谷地"},
        {id="jinglan", name="镜澜站", shortName="镜澜", englishName="Jinglan Station", regionName="镜澜水岸"},
        {id="yunwan", name="云湾总站", shortName="云湾", englishName="Yunwan Terminal", regionName="云湾城"},
    },
    stationNames = {"星汐总站", "岚港站", "榆岑站", "镜澜站", "云湾总站"},
    trainNames = {
        blue_white="沧羽 D12", DF4D="赤峦 D18", SS9G="苍穹 E21",
        HXD3D="雷隼 E32", CRH380A="流萤 M30", CR400AF="星澜 M35",
    },
    trainCodes = {
        blue_white="D12", DF4D="D18", SS9G="E21",
        HXD3D="E32", CRH380A="M30", CR400AF="M35",
    },
    coachName = "云舟 C24",
    coachCode = "C24",
    fleetSeries = "QY",
    -- 架空车号，不使用源贴图内的现实铭牌编号。
    fleetNumbers = {
        blue_white="D12-012", DF4D="D18-018", SS9G="E21-021",
        HXD3D="E32-032", CRH380A="M30-030", CR400AF="M35-035",
    },
}

return FictionalWorld
