-- ============================================================================
-- GameConfig - 全局配置（列车 / 线路 / 车站 / 视觉）
-- 单位：米、秒、千克
-- ============================================================================

local GameConfig = {}

GameConfig.Title = "火车驾驶模拟"

-- ---------------------------------------------------------------------------
-- 线路：圆角矩形环线（可无限循环驾驶）
-- 由直线段和圆弧段拼成，最后闭合
-- ---------------------------------------------------------------------------
-- 大半径演示环线：12/10公里长直线，R=9000米圆弧。
-- 用于高速驾驶模拟；未实现真实线路超高/缓和曲线认证。
GameConfig.RouteSegments = {
    { type = "straight", length = 12000 },
    { type = "arc", radius = 9000, angle = 90, dir = 1 },
    { type = "straight", length = 10000 },
    { type = "arc", radius = 9000, angle = 90, dir = 1 },
    { type = "straight", length = 12000 },
    { type = "arc", radius = 9000, angle = 90, dir = 1 },
    { type = "straight", length = 10000 },
    { type = "arc", radius = 9000, angle = 90, dir = 1 },
}

GameConfig.RouteStart = Vector3(0, 0, 0)
GameConfig.RouteStartYaw = 0
GameConfig.RouteStep = 10.0       -- 调试/包围盒点；车辆与净空使用解析线路，不插值这些点。

-- 全线逻辑常驻，只有周边渲染生成。所有距离米、帧预算毫秒。
GameConfig.WorldStream = {
    FrameBudgetMs = 3.0,
    MaxTaskSlices = 32,
    RefreshInterval = 0.20,
    TrackChunkLength = 120,
    DetailAhead = 960,
    DetailBehind = 600,
    ViewAhead = 3000,
    ViewBehind = 2800,
    UnloadMargin = 720,
    InitialDetailAhead = 240,
    InitialDetailBehind = 240,
    InitialInfrastructureRadius = 96,
    InfrastructureChunkLength = 32,
    InfrastructureAhead = 1500,
    InfrastructureBehind = 1100,
    StationRadius = 2800,
    TerrainCellSize = 160,
    TerrainRadius = 1120,
    VegetationRadius = 360,
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
    { name = "北京站", at = 0.100 },
    { name = "天津站", at = 0.300 },
    { name = "济南站", at = 0.500 },
    { name = "南京站", at = 0.700 },
    { name = "上海站", at = 0.900 },
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
    DwellTime = 20,                -- 站停时间（秒）
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
