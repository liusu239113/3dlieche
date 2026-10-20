-- 中国铁路风格架空线路的美术/工程尺度；米制，不是施工图或联锁认证参数。
-- 数值遵循普速电气化铁路常见量级；曲线、坡度、警冲/站界/鸣笛标的位置
-- 必须由真实解析路线推导，不用装饰性随机路牌伪造工程信息。
local Standards = {
    Identity = { routeName="星汐—云湾线", authority="星湾铁路工务", prefix="星云" },
    Track = {
        gauge=1.435, railMassKgPerM=60, railProfile="60kg/m",
        sleeperMaterial="prestressed_concrete", sleeperSpacing=.60,
        -- Track模块拥有实际钢轨/混凝土枕几何；设施不得再叠画一份。
    },
    Topology = {
        main=0, opposing=5.0, siding=-10.8,
        mainDirection=1, opposingDirection=-1,
        islandPlatformMin=-8.9, islandPlatformMax=-1.9,
        upPlatformMin=6.9, upPlatformMax=13.9,
        stationBuilding=-68, freightLaterals={16.6,22.4},
        bridgeCenter=2.5, bridgeWidth=18.4, bridgeDeckTop=-.18,
        bridgeMastLeft=-5.5, bridgeMastRight=10.5,
        stationMastLeft=-14.4, stationMastRight=27.0,
        tunnelCenter=2.5, tunnelHalfWidth=9.5,
        tunnelWallHeight=8.8, tunnelCrownHeight=12.6,
    },
    Catenary = {
        span=50, minimumSpan=40, maximumSpan=60,
        contactY=6.10, messengerY=7.05, sag=.22, stagger=.18,
        returnY=8.05, mastTop=8.30, mastOffset=3.60,
        foundationWidth=.78, foundationHeight=.48, mastWidth=.26,
        portalBottom=8.00, portalTop=8.55, portalMargin=2.40,
        wireStep=5, dropperStep=10, anchorInterval=1200,
        anchorOutset=2.40, anchorLongitudinal=6,
        bridgeFoundationWidth=.50,
    },
    Clearance = {
        trainHalfWidth=1.70, structuralHalfWidth=2.20,
        pantographTop=6.10, rigidOverheadMinimum=6.70,
        platformMargin=1.40, yardMargin=60,
        footbridgeAt=83, footbridgeMargin=8,
        signalSupportMargin=3,
    },
    Corridor = {
        cableOffset=2.85, cableWidth=.42, cableTop=.16,
        drainOffset=4.65, drainWidth=.72, drainDepth=.12,
        fenceOffset=9.60, fenceHeight=2.20, fencePitch=4,
        equipmentInterval=200, equipmentPhase=25, stakeInterval=200,
        slopeOffset=6.00, slopeOuter=8.60, slopeHeight=.70,
    },
    Signals = {
        interval=1600, lateralClearance=3.10, height=5.10,
        lensRadius=.135, lensPitch=.36, drawDistance=1200,
        unknownAspect="red", -- 未初始化/未知权限从不显示自创绿灯。
    },
    Markers = {
        kilometre=1000, halfKilometre=500, whistleLead=600,
        foulingTrackSpacing=4.00, boundaryOffset=3.30,
        -- 站界标只允许反方向未设进站机的站界。本站场两方向都有进站机，
        -- 因此默认不重复放站界标；GetValidationData给出以实际信号为界的stationBoundaries。
        reverseEntryHasSignal=true,
    },
    LOD = {
        structureDistance=1800, wireDistance=1500,
        corridorDistance=850, detailDistance=360,
        signTextDistance=120, mastTextDistance=75,
        utilityDistance=1400,
    },
    Lighting = {
        maxPointLights=0, -- 小设施用自发光灯罩，不加全线点光/阴影。
        utilityEmissiveStrength=.38, signalEmissiveStrength=1.80,
    },
}
return Standards
