-- 中国铁路沿线的米制设计参数；架空国道编号/地名，不指向任何真实坐标线路。
-- 默认双线干线无平交、无道路移动车；道口仅可由真实受控低速支线显式注册。
local CorridorConfig = {
    Seed = 20261017,
    Road = {
        Id = "G986", -- 架空编号，仅用于本游戏，不声称真实国家公路。
        Lateral = 92.0,
        StationLateral = 128.0,
        LaneWidth = 3.5,
        Shoulder = 1.25,
        SurfaceY = 0.16,
        SegmentLength = 12.0,
        GuardrailPostSpacing = 12.0,
        MarkerSpacing = 1000.0,
        SignSpacing = 1200.0,
        CameraSpacing = 2400.0,
        DrawDistance = 1800.0,
        MaxChunkLength = 320.0,
        StationPlateau = 850.0,
        StationTransition = 650.0,
        TunnelBypassLateral = 430.0,
        MountainMaintenanceMargin = 16.0, -- 道路完整肩部到山壳保留维护带，不仅中心线不相交。
        TunnelBypassTransition = 700.0,
        ProfileStep = 12.0,
        MaxGrade = 0.055,
        PierSpacing = 24.0,
        ReservationMargin = 5.0,
        MovingVehicles = false,
    },
    Overpass = {
        Enabled = true,
        MinStationDistance = 1500.0,
        SpanHalfLength = 24.0,
        RailHeadClearance = 9.0, -- 梁底距轨面，覆盖接触网及余量；非仅车顶净高。
        DeckThickness = 0.85,
        RampGrade = 0.055,
        EndLateral = 235.0,
        Width = 7.0,
        MaxPerStraight = 1,
    },
    Crossing = {
        Definitions = {}, -- 当前高速双线无平交；禁止凭空添加不运营的展示短轨。
        MaxRailSpeedKmh = 40.0,
        WarningSeconds = 35.0,
        MinimumApproach = 180.0,
        ClearHoldSeconds = 6.0,
        OpenSeconds = 5.0,
        StopDistance = 10.0,
        SightDistance = 100.0,
    },
    Scenery = {
        SampleLength = 240.0,
        DrawDistance = 1500.0,
        MaxChunkLength = 320.0,
        RailClearance = 32.0,
        MaxGroundLateral = 285.0, -- Terrain现有山丘从310m起，绝不在坡顶假定y=0。
        FieldWidth = 36.0,
        FieldLength = 64.0,
        TowerSpacing = 1440.0,
    },
    -- 尺度参考：JTG B01车道/路肩常用量级、GB 5768黄中线/白边线语义。
    -- 此处是模拟场景设计参数，不是公路工程合规证明或现实坐标复刻。
    References = {
        "JTG B01-2014 公路工程技术标准：车道、路肩与净空设计参考",
        "GB 5768 道路交通标志和标线：黄线分隔对向、白线分隔同向/边缘",
        "铁路道口管理有关规定：干线优先立交，道口须受控且监测完整占用",
    },
}
return CorridorConfig
