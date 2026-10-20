-- 默认33.186577km五站走廊的合成地貌设计，不是现实测绘或DEM复刻。
-- 仅地表/桥隧规划：不改Route几何、里程、站点、存档坐标或车辆纵断面。
-- 不等距地理序列：翠川低丘 -> 岚港三洞岭 -> 榆岑峡谷/支流 -> 云脊三洞岭 -> 镜澜河谷。
return {
    Version = "corridor_relief_v2",
    PortalTransition = 80.0,
    MaintenanceHalfWidth = 28.0,
    -- 原有两桥两隧由Landmarks保留。新增工程全部落在既有直线父段内。
    Structures = {
        {id="langang_west_bore",kind="tunnel",name="岚港西岭隧道",first=8570,last=8830,halfWidth=210,height=112},
        {id="langang_east_bore",kind="tunnel",name="岚港东岭隧道",first=10600,last=10880,halfWidth=225,height=126},
        {id="yuzen_spur_bore",kind="tunnel",name="榆岑石门隧道",first=12800,last=13320,halfWidth=265,height=165},
        {id="yuzen_creek_bridge",kind="bridge",name="榆岑石溪铁路桥",first=13700,last=14000,halfWidth=520,depth=28,waterY=-15},
        {id="yuzen_gorge_bridge",kind="bridge",name="榆岑南涧铁路桥",first=15300,last=15640,halfWidth=520,depth=42,waterY=-19},
        {id="yunji_west_bore",kind="tunnel",name="云脊西隧道",first=18245,last=18585,halfWidth=235,height=144},
        {id="yunji_east_bore",kind="tunnel",name="云脊东隧道",first=20370,last=20660,halfWidth=245,height=151},
    },
    -- 负侧贴线坡脚保留28m维护带；正侧只在远离国道的170m之外起坡。
    -- toe/crest/outer为离主线距离，坡底均实际落到Y=-.25保底。
    Slopes = {
        {id="cuichuan_foothill",name="翠川低丘",first=2300,last=3010,side=-1,toe=32,crest=125,outer=320,height=32},
        {id="langang_cut",name="岚港出城岩切坡",first=5300,last=5900,side=-1,toe=28,crest=98,outer=310,height=52},
        {id="langang_approach",name="岚港主岭前缘",first=8100,last=8460,side=-1,toe=30,crest=150,outer=360,height=86},
        {id="yuzen_stone_cut",name="石门谷侧切坡",first=11160,last=12590,side=-1,toe=28,crest=122,outer=390,height=96},
        {id="yuzen_west_wall",name="榆岑峡谷西壁",first=14200,last=15120,side=-1,toe=29,crest=155,outer=410,height=118},
        {id="yunji_approach",name="云脊岭前丘陵",first=17900,last=18130,side=-1,toe=30,crest=112,outer=320,height=64},
        {id="yunji_exit_cut",name="云脊东口峡壁",first=20920,last=21980,side=-1,toe=28,crest=148,outer=395,height=107},
        {id="jinglan_river_hill",name="镜澜河谷侧丘",first=26420,last=27100,side=-1,toe=31,crest=160,outer=410,height=79},
        {id="yunwan_low_ridge",name="云湾入城前低岭",first=29700,last=30420,side=-1,toe=34,crest=135,outer=340,height=47},
    },
    -- 明确地理山脊，不再按固定1150m轮播峰；保持道路正侧净空。
    Peaks = {
        {id="cuichuan_back_ridge",s=4710,lateral=-570,halfWidth=245,height=108},
        {id="langang_back_ridge",s=11480,lateral=-620,halfWidth=260,height=211},
        {id="yuzen_high_ridge",s=14620,lateral=-710,halfWidth=255,height=278},
        {id="yunji_back_ridge",s=21160,lateral=-700,halfWidth=265,height=296},
        {id="jinglan_watershed",s=26880,lateral=-720,halfWidth=265,height=227},
        {id="yunwan_back_hill",s=30040,lateral=-580,halfWidth=225,height=116},
    },
}
