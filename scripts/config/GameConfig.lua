-- ============================================================================
-- GameConfig - 全局配置（列车 / 线路 / 车站 / 视觉）
-- 单位：米、秒、千克
-- ============================================================================

local FictionalWorld = require "config.FictionalWorld"
local GameConfig = {}

GameConfig.Title = "TRS实况铁路模拟"

-- 默认先保障移动端负载；细致模式保留近景阴影与镜面，不影响运营逻辑或资源完整性。
GameConfig.RenderQuality = "performance"

-- ---------------------------------------------------------------------------
-- 线路：有端点的五站走廊，左右交替曲线，不再首尾闭合。
-- 星澜群域的五座架空城市；采用中国铁路工程与左行运营风格，不冒称实测复刻。
-- 各弧内加入对称缓和曲线；保留每段里程、总转角和站序，工程性调整世界XZ。
GameConfig.RouteClosed = false
GameConfig.RouteTransitions = true
GameConfig.RouteTransitionLength = 120
GameConfig.RouteSegments = {
    { type="straight",length=2200 },
    { type="arc",radius=1600,angle=32,dir=1 },
    { type="straight",length=1300,landmark="bridge_a" },
    { type="arc",radius=1000,angle=42,dir=-1 },
    { type="straight",length=2300 },
    { type="arc",radius=1800,angle=35,dir=1 },
    { type="straight",length=2400,landmark="tunnel_a" },
    { type="arc",radius=1200,angle=48,dir=-1 },
    { type="straight",length=2200 },
    { type="arc",radius=2200,angle=26,dir=1 },
    { type="straight",length=2000 },
    { type="arc",radius=1400,angle=44,dir=-1 },
    { type="straight",length=2500,landmark="tunnel_b" },
    { type="arc",radius=1100,angle=40,dir=1 },
    { type="straight",length=2100 },
    { type="arc",radius=2000,angle=30,dir=-1 },
    { type="straight",length=1600,landmark="bridge_b" },
    { type="arc",radius=1600,angle=38,dir=1 },
    { type="straight",length=2300 },
    { type="arc",radius=2400,angle=24,dir=-1 },
    { type="straight",length=2600 },
}

GameConfig.RouteStart = Vector3(0, 0, 0)
GameConfig.RouteStartYaw = 0
GameConfig.RouteStep = 10.0       -- 调试/包围盒点；车辆与净空使用解析线路，不插值这些点。

-- 全线逻辑常驻，只有周边渲染生成。所有距离米、帧预算毫秒。
GameConfig.WorldStream = {
    FrameBudgetMs = 3.0,
    MaxTaskSlices = 32,
    HighSpeedFrameBudgetMs = 6.0,
    HighSpeedMaxTaskSlices = 64,
    -- 狂暴只扩大预取窗口，绝不作为速度上限或制动器。
    RageViewAhead = 5200,
    RageDetailAhead = 2400,
    RageInfrastructureAhead = 3000,
    RageSceneryAhead = 3200,
    RageTerrainRadius = 2400,
    RefreshInterval = 0.20,
    TrackChunkLength = 120,
    DetailAhead = 480,
    DetailBehind = 360,
    ViewAhead = 2400,
    ViewBehind = 1800,
    UnloadMargin = 720,
    InitialDetailAhead = 240,
    InitialDetailBehind = 240,
    InitialInfrastructureRadius = 150,
    -- 中国式接触网按全线50m网格归属；半开块在任意边界不重复柱位。
    InfrastructureChunkLength = 100,
    InfrastructureAhead = 1500,
    InfrastructureBehind = 1100,
    StationRadius = 2800,
    CityRadius = 2100,
    SceneryChunkLength = 240,
    SceneryAhead = 1600,
    SceneryBehind = 1200,
    InitialSceneryRadius = 240,
    TerrainCellSize = 160,
    TerrainRadius = 1120,
    VegetationRadius = 640,
    Seed = 20261006,
}

-- 本轮统一使用平坦线路；恢复坡度前必须同步建立对应路基与地形。
GameConfig.HillAmplitude = 0.0
GameConfig.HillWaves = 3

-- 轨道尺寸
GameConfig.BallastWidth = 5.2     -- 道砟带宽
GameConfig.RailGauge = 1.435      -- 标准轨距
GameConfig.RailWidth = 0.09       -- 钢轨宽
GameConfig.RailHeight = 0.20      -- 轨面离地高

-- ---------------------------------------------------------------------------
-- 车站（at = 在线路上的位置比例 0~1）
-- ---------------------------------------------------------------------------
GameConfig.Stations = {
    { name = FictionalWorld.stationNames[1], at = 0.025 },
    { name = FictionalWorld.stationNames[2], at = 0.270 },
    { name = FictionalWorld.stationNames[3], at = 0.540 },
    { name = FictionalWorld.stationNames[4], at = 0.735 },
    { name = FictionalWorld.stationNames[5], at = 0.960 },
}

-- ---------------------------------------------------------------------------
-- 列车参数（蓝白长机罩内燃机车 + 客车编组）
-- ---------------------------------------------------------------------------
GameConfig.Train = {
    Cars = 8,                      -- 总车辆数（1 机车 + 7 客车）
    CarLength = 24.0,              -- 单节车长
    CarGap = 1.6,                  -- 车钩间距
    BodyWidth = 3.1,
    BodyHeight = 3.4,
    BodyBottom = 0.9,              -- 车体底面离轨面高度

    Mass = 138000,                 -- 机车质量 kg
    CarMass = 52000,               -- 客车质量 kg

    MaxSpeedKmh = 120,             -- 构造速度
    MaxThrottle = 8,               -- 油门档位数

    -- 138 吨编组下的加减速表现（1 m/s² 需要 138000 N）
    MaxTractive = 105000,          -- 最大牵引力 N（≈0.76 m/s²，0→80km/h 约 30 秒）
    PowerKneeSpeed = 12.0,         -- 恒功率拐点 m/s，超过后牵引力按 1/v 衰减
    MaxBrakeForce = 165000,        -- 最大制动力 N（≈1.20 m/s²，80km/h 制动距离约 205 米）

    -- 阻力（Davis 简化式，单位：m/s^2 等效加速度）
    ResistA = 0.09,
    ResistB = 0.0016,
    ResistC = 0.00006,
}

-- ---------------------------------------------------------------------------
-- 玩法参数
-- ---------------------------------------------------------------------------
GameConfig.Gameplay = {
    SpeedLimitKmh = 350,           -- 区间上限；最终取车型、曲线、站区与进站制动的最小值
    StationSpeedKmh = 60,          -- 站场许可速度，不是整线限速
    BrakeReactionSeconds = 1.5,    -- 制动提示与速度包络的反应余量
    StationBrakeDistance = 900,    -- 兼容旧接口；实际提示按 v²/(2a) 动态计算
    StopTolerance = 60,            -- 停车精度容差（米）
    DwellTime = 12,                -- 站停时间（秒）
    DrivingMode = "relaxed",       -- 休闲牵引默认更敏捷；可切换保持原SI参数的模拟模式
    RelaxedTractiveScale = 1.65,
    RelaxedPowerScale = 2.8,
    XpPerStation = 100,            -- 每站经验
    XpSpeedBonus = 50,             -- 准点/精准停车奖励
}

-- ---------------------------------------------------------------------------
-- 配色（参照参考图：蓝白雨棚 + 红砖站房 + 蓝白机车）
-- ---------------------------------------------------------------------------
GameConfig.Colors = {
    CanopyBlue = Color(0.20, 0.52, 0.66),
    CanopyDark = Color(0.12, 0.34, 0.46),
    BrickRed = Color(0.62, 0.20, 0.15),
    BrickDark = Color(0.44, 0.13, 0.10),
    Cream = Color(0.90, 0.86, 0.76),
    PlatformGray = Color(0.72, 0.71, 0.68),
    PlatformEdge = Color(0.88, 0.72, 0.20),
    LocoWhite = Color(0.90, 0.90, 0.92),
    LocoBlue = Color(0.13, 0.28, 0.62),
    LocoRed = Color(0.72, 0.13, 0.11),
    CarWhite = Color(0.93, 0.94, 0.95),
    GlassDark = Color(0.10, 0.14, 0.20),
    Steel = Color(0.55, 0.57, 0.60),
    DarkSteel = Color(0.20, 0.21, 0.23),
    Ballast = Color(0.36, 0.34, 0.32),
    Sleeper = Color(0.28, 0.24, 0.20),
    Concrete = Color(0.62, 0.62, 0.60),
    Asphalt = Color(0.30, 0.30, 0.32),
    SignalGreen = Color(0.15, 0.85, 0.30),
    SignalRed = Color(0.90, 0.15, 0.12),
    TreeLeaf = Color(0.20, 0.42, 0.16),
    TreeLeaf2 = Color(0.26, 0.50, 0.20),
    Trunk = Color(0.28, 0.20, 0.13),
    RoofTile = Color(0.48, 0.16, 0.13),
    WallYellow = Color(0.86, 0.78, 0.58),
    WallWhite = Color(0.88, 0.87, 0.84),
    WallGray = Color(0.55, 0.57, 0.60),
    WallGlassBlue = Color(0.30, 0.52, 0.68),
}

-- 预制纹理材质 uuid（引擎内置材质库）
GameConfig.MaterialUUID = {
    Grass = "uuid://EFSiAWPsKtpGQpTAGBbflyyK",
    Asphalt = "uuid://DKmYSWaMUJO6PDtihBbjHUQj",
    Brick = "uuid://DXjwQX_lcF60zC4F9y9yAyG_",
    Concrete = "uuid://Gm0CwVtSclGB7uj0Zs_eP8Gs",
    Metal = "uuid://D9QYQXRhlgGnRlDw8jDNGTya",
    Wood = "uuid://DdH4-Su6Cppk8qaKI2AiCLs-",
    Marble = "uuid://HndW0W0ASO7zyBNhRXFeCwdL",
}

-- ---------------------------------------------------------------------------
-- 相机
-- ---------------------------------------------------------------------------
GameConfig.Camera = {
    ChaseDistance = 26.0,
    ChaseOffsetY = 8.5,
    ChaseFov = 62.0,
    FarClip = 2600.0,
    NearClip = 0.5,
    MinPitch = -45.0,
    MaxPitch = 25.0,
}

return GameConfig
