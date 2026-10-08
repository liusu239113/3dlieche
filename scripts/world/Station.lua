-- 真实尺度直线站台、薄钢结构雨棚及单侧站房。
local Route = require "world.Route"
local World = require "world.WorldMaterials"
local Vegetation = require "world.Vegetation"
local StationBuildings = require "world.StationBuildings"
local Station = {}

-- 净空截面：现代最大3.38米车体占 [-1.69,+1.69]，站台从 +/-1.90 开始，
-- 最小单侧间隙0.21米；经典3.10米车体间隙0.35米，不能把轨距当作车宽。
-- 雨棚内边 +/-2.25、柱内边 +/-7.57不变；平台仍宽7米，外边随内边移至8.90。
-- 站房连同屋檐对完整闭合线路检测净空，不只对所在站的局部线路。
--    站房 >=25米 | 7米站台 | >=.21间隙 | 列车 | >=.21间隙 | 7米站台
-- 站台绝对顶面=0.34+1.10=1.44 米，基座底面=-0.02 米。
-- 完整站台处于直线内，覆盖 [停靠点-225,停靠点+85] 及八节编组尾部。
local INNER = 1.90
local WIDTH = 7.0
local OUTER = INNER + WIDTH
local MAX_TRAIN_WIDTH = 3.38
local PLATFORM_Y = 1.44
local CANOPY_INNER = 2.25
local CANOPY_OUTER = 8.65
local CANOPY_Y = PLATFORM_Y + 4.60
---@type table[]
local placementData_ = {}

---@type table<string, Material>
local solidMaterials_ = {}
local function solid(color, metallic, roughness)
    local key=string.format("%.4f_%.4f_%.4f_%.4f_%.4f",color.r,color.g,color.b,metallic or 0,roughness or .8)
    if not solidMaterials_[key] then solidMaterials_[key]=World.Solid(color,metallic,roughness) end
    return solidMaterials_[key]
end
local function point(st, along, lateral, y)
    return Route.SampleOffset(st.s + along, lateral, y)
end
local function batch(root, name, material, shadows, tile)
    return World.NewBatch(root:CreateChild(name), material, shadows, tile)
end

-- Text3D的可读正面沿局部-Z，不是+Z。文字分别位于不透明板两侧外部，
-- 两面各自朝外，板身遮住另一面的镜像背面；不用反转字符串或负缩放。
local function boardSigns(root, st, along, lateral, y, halfDepth, text, size, name)
    local _, _, yaw = Route.Sample(st.s)
    for face = -1, 1, 2 do
        local label = root:CreateChild(name .. (face > 0 and "_OuterFace" or "_InnerFace"))
        label.position = point(st, along, lateral + face * (halfDepth + .03), y)
        label.rotation = Quaternion(yaw + (face > 0 and -90 or 90), Vector3.UP)
        Station.MakeWorldSign(label, text, size)
    end
end

---@param scene Scene
---@param initialS number|nil
function Station.Build(scene, initialS)
    Station.Init()
    local root = scene:CreateChild("StationsPreview")
    local best, distance = Route.GetStations()[1], math.huge
    for _, st in ipairs(Route.GetStations()) do
        local delta=math.abs((st.s-(initialS or 0)+Route.GetLength()/2)%Route.GetLength()-Route.GetLength()/2)
        if delta<distance then best,distance=st,delta end
    end
    if best then Station.BuildOne(root,best) end
    return root
end
function Station.Init() placementData_ = {} end

---@param root Node
---@param st table
---@param pause fun()|nil
function Station.BuildOne(root, st, pause)
        local node = root:CreateChild("Station_" .. st.name)
        local _, _, yaw = Route.Sample(st.s)
        local angle = math.rad(yaw)
        -- 暖灰混凝土降低重复频率；明确过滤模式，不只设置未启用的各向异性数值。
        local concreteTexture = cache:GetResource("Texture2D", "Textures/Railway/concrete.png")
        if concreteTexture then
            concreteTexture:SetFilterMode(FILTER_ANISOTROPIC)
            concreteTexture:SetAnisotropy(4)
        end
        local platformMat = World.Textured("StationConcreteWarm", "Textures/Railway/concrete.png", Color(.64,.65,.61), .97)
        local copingMat = solid(Color(.68,.68,.62), 0, .96)
        local platform = batch(node, "WeatheredConcretePlatforms", platformMat, false, 3.0)
        local coping = batch(node, "StoneCoping", copingMat, false)
        local safety = batch(node, "SafetyLines", solid(Color(0.76, 0.63, 0.21), 0, 0.96), false)
        local roofColors = { Color(.30,.34,.32), Color(.26,.33,.35), Color(.33,.35,.30) }
        local roofColor = roofColors[(st.index - 1) % #roofColors + 1] or roofColors[1]
        local roofMat = solid(roofColor, .04, .90) -- 哑光老化涂层，抑制薄边高光闪烁。
        local roof = batch(node, "MutedSheetCanopies", roofMat, true)
        local frame = batch(node, "PaintedCanopySteel", solid(Color(.32,.37,.34), .08, .86), true)
        local first, last = Route.PlatformStart, Route.PlatformEnd
        local middle, span = (first + last) / 2, last - first
        for side = -1, 1, 2 do
            platform:AddBox(point(st, middle, side * (INNER + WIDTH / 2), (PLATFORM_Y - 0.02) / 2),
                Vector3(WIDTH, PLATFORM_Y + 0.02, span), angle)
            coping:AddBox(point(st, middle, side * (INNER + 0.19), PLATFORM_Y + 0.025),
                Vector3(0.38, 0.05, span), angle)
            safety:AddBox(point(st, middle, side * (INNER + 0.80), PLATFORM_Y + 0.053),
                Vector3(0.16, 0.016, span), angle)
            -- 170 米长薄钢雨棚退让出列车限界，厚度仅 0.12 米。
            -- 铁路正上方保持开敞，不使用巨大不透明块体。
            -- 长度只做小幅站别差异；两个悬挂牌和候车长椅均仍在遮雨区。
            local canopyStart = -140.0 + (st.index % 3) * 5
            local canopyEnd = 30.0 - (st.index % 2) * 4
            local canopyMiddle = (canopyStart + canopyEnd) / 2
            local canopySpan = canopyEnd - canopyStart
            -- 保留0.08米PBR承雨薄板；实景A/B确认长咬合肋产生远距亚像素白斑，
            -- 不再生成微肋，避免用覆盖整站的合批drawDistance冒充逐段近景LOD。
            roof:AddBox(point(st, canopyMiddle, side * ((CANOPY_INNER + CANOPY_OUTER) / 2), CANOPY_Y - .02),
                Vector3(CANOPY_OUTER - CANOPY_INNER, .08, canopySpan), angle)
            -- 下折檐口形成薄板真实断面，不增加巨大灰色檐板或扩大横向包络。
            for _, lat in ipairs({CANOPY_INNER + .035, CANOPY_OUTER - .035}) do
                frame:AddBox(point(st, canopyMiddle, side * lat, CANOPY_Y - .13), Vector3(.055, .18, canopySpan), angle)
            end
            for ds = canopyStart + 1, canopyEnd - 1, 12 do
                frame:AddBox(point(st, ds, side * 7.65, PLATFORM_Y + 2.25), Vector3(0.16, 4.50, 0.16), angle)
                frame:AddBox(point(st, ds, side * 5.45, CANOPY_Y - 0.19), Vector3(6.4, 0.16, 0.10), angle)
                -- 柱脚底板与短加强肋，毫米/厘米尺度而非额外粗柱。
                frame:AddBox(point(st, ds, side * 7.72, PLATFORM_Y + .025), Vector3(.30, .05, .30), angle)
                frame:AddBox(point(st, ds, side * 7.72, CANOPY_Y - .44), Vector3(.28, .38, .035), angle)
            end
            for _, lat in ipairs({ 2.35, 8.55 }) do
                frame:AddBox(point(st, canopyMiddle, side * lat, CANOPY_Y - 0.18), Vector3(0.08, 0.16, canopySpan), angle)
            end
            Station.BuildCanopyDrainage(node, st, side, canopyStart, canopyEnd)
            if pause then pause() end
        end
        for _, item in ipairs({platform,coping,safety,roof,frame}) do item:Finish(); if pause then pause() end end
        frame.geometry.shadowDistance = 100
        Station.BuildPlatformSigns(node, st); if pause then pause() end
        Station.BuildBuilding(node, st, nil, nil, nil, pause); if pause then pause() end
        Station.BuildForecourt(node, st, pause); if pause then pause() end
        Station.BuildPlatformDetails(node, st, pause); if pause then pause() end
        Station.BuildProps(node, st, nil, PLATFORM_Y); if pause then pause() end
        print(string.format("[Station] %s：站台310米，内边1.90/外边8.90米；现代最大3.38米车宽间隙0.21米/经典3.10米间隙0.35米，顶面1.44米，雨棚内边2.25米",
            st.name))
end

-- 雨水槽/落水管只贴雨棚外缘与柱背，不进入7.57米柱内边。
-- 槽壁0.02米、管径0.09米；用同一材质合批，禁用远处微细阴影。
function Station.BuildCanopyDrainage(root, st, side, first, last)
    local _, _, yaw = Route.Sample(st.s)
    local angle = math.rad(yaw)
    local metal = batch(root, "CanopyGutters" .. side, solid(Color(.27,.29,.27), .36, .82), false)
    local span, middle = last - first, (last + first) / 2
    metal:AddBox(point(st, middle, side * 8.56, CANOPY_Y - .14), Vector3(.15,.025,span), angle)
    for _, lat in ipairs({8.49,8.63}) do
        metal:AddBox(point(st, middle, side * lat, CANOPY_Y - .095), Vector3(.02,.09,span), angle)
    end
    for _, ds in ipairs({first + 1,last - 5}) do
        metal:AddBox(point(st, ds, side * 7.81, PLATFORM_Y + 2.16), Vector3(.09,4.28,.09), angle)
        metal:AddBox(point(st, ds, side * 8.17, CANOPY_Y - .21), Vector3(.78,.09,.09), angle)
        for _, y in ipairs({.65,2.25,3.80}) do
            metal:AddBox(point(st, ds, side * 7.81, PLATFORM_Y + y), Vector3(.12,.035,.12), angle)
        end
    end
    metal:Finish()
    metal.geometry.drawDistance = 200
end

function Station.BuildPlatformSigns(root, st)
    local steel = batch(root, "SignPosts", solid(Color(0.40, 0.43, 0.44), 0.7, 0.48), true)
    local boards = batch(root, "BlueNameBoards", solid(Color(0.09, 0.22, 0.33), 0.1, 0.75), false)
    local _, _, yaw = Route.Sample(st.s)
    for side = -1, 1, 2 do
        for _, ds in ipairs({ -175, -60, 65 }) do
            local position = point(st, ds, side * 7.2, PLATFORM_Y)
            steel:AddBox(position + Vector3(0, 1.3, 0), Vector3(0.07, 2.6, 0.07), math.rad(yaw))
            boards:AddBox(position + Vector3(0, 2.50, 0), Vector3(0.10, 0.70, 3.0), math.rad(yaw))
            boardSigns(root, st, ds, side * 7.2, PLATFORM_Y + 2.5, .05,
                st.name, .28, "StationName")
        end
    end
    steel:Finish(); boards:Finish()
end

-- 每座城市使用各自的原型站房（红墙大屋顶/钟楼/拱门/多层/玻璃枢纽），
-- 体量、材质、屋顶形态都不同，不再五站共用同一栋楼。
function Station.BuildBuilding(root, st, matBrick, matCream, matGlass, pause)
    local style = StationBuildings.Styles[st.index] or StationBuildings.Styles[1]
    local radius = StationBuildings.FootprintRadius(style)
    local center = point(st, -55, -68, 0)
    local clearance = Route.DistanceTo(center) - radius
    if not Route.CanPlaceFootprint(center, radius, Route.BuildingClearance) then
        print("[Station] 错误：已拒绝不满足净空的站房：" .. st.name)
        return
    end
    local node = root:CreateChild("StationHouse")
    node.position = center
    local _, _, yaw = Route.Sample(st.s)
    node.rotation = Quaternion(yaw, Vector3.UP)
    StationBuildings.Build(node, style, pause)
    local sign = node:CreateChild("HouseName")
    sign.position = Vector3(style.D / 2 + 0.9, style.H * 0.78, 0)
    sign.rotation = Quaternion(-90, Vector3.UP)
    Station.MakeWorldSign(sign, st.name, 0.64)
    placementData_[#placementData_ + 1] = {
        name = st.name, index = st.index, x = center.x, z = center.z, radius = radius, clearance = clearance,
        s = st.s, platformStart = st.s + Route.PlatformStart, platformEnd = st.s + Route.PlatformEnd,
    }
    print(string.format("[Station] %s 站房原型=%s，完整包络净空 %.2f 米（要求至少 25 米）",
        st.name, style.archetype, clearance))
end

-- 每站仅六张金属长椅和小型矩形灯具。
-- 取消圆柱球头行人、巨大行李块及过多站台杂物。
function Station.BuildProps(root, st, _matLamp, _baseY)
    local steel = batch(root, "FurnitureFrames", solid(Color(.31,.35,.34), .30, .78), true)
    local slats = batch(root, "BenchSlats", solid(Color(.37,.40,.37), .12, .82), true)
    local diffuser = batch(root, "LampDiffusers", solid(Color(.73,.72,.64), 0, .75), false)
    local _, _, yaw = Route.Sample(st.s)
    local angle = math.rad(yaw)
    for side = -1, 1, 2 do
        for _, ds in ipairs({ -125, -65, 15 }) do
            -- 分隔长椅板条与开放腿架，替代一整块实心座面/靠背。
            for _, lat in ipairs({5.96,6.12,6.28,6.44}) do
                slats:AddBox(point(st,ds,side*lat,PLATFORM_Y+.46),Vector3(.12,.055,2.4),angle)
            end
            for _, y in ipairs({.65,.83,.99}) do
                slats:AddBox(point(st,ds,side*6.43,PLATFORM_Y+y),Vector3(.045,.115,2.4),angle)
            end
            for _, along in ipairs({-.85,.85}) do
                for _,lat in ipairs({6.00,6.40}) do
                    steel:AddBox(point(st,ds+along,side*lat,PLATFORM_Y+.23),Vector3(.045,.46,.045),angle)
                end
                steel:AddBox(point(st,ds+along,side*6.43,PLATFORM_Y+.72),Vector3(.045,.57,.045),angle)
                steel:AddBox(point(st,ds+along,side*6.2,PLATFORM_Y+.44),Vector3(.55,.045,.045),angle)
            end
        end
        for ds = -115, 5, 24 do
            steel:AddBox(point(st, ds, side * 5.7, CANOPY_Y - 0.30), Vector3(0.16, 0.05, 1.2), angle)
            diffuser:AddBox(point(st,ds,side*5.7,CANOPY_Y-.332),Vector3(.125,.014,1.12),angle)
        end
    end
    steel:Finish(); slats:Finish(); diffuser:Finish()
    slats.geometry.shadowDistance = 90
    diffuser.geometry.drawDistance = 180
end

-- 站前广场在站房入口（横距-58米）与左月台外缘（-8.90米）之间。
-- 净空示意（局部X，非碰撞体）：
-- 站房-68 | 门廊-58 | 地面广场 | 1:12坡道/8级台阶 | 月台-8.90..-1.90 | 铁路0
-- 不跨越铁路，也不虚构另一侧月台的人行平交。对侧出口只指向沿台端部。
-- 每个铺装单元检查整条闭合线路；台阶/坡道只占月台外侧，不动既有台面。
function Station.BuildForecourt(root, st, pause)
    local origin, tangent, yaw = Route.Sample(st.s)
    local right = Route.RightAt(st.s)
    local angle = math.rad(yaw)
    local function p(x, y, z) return origin + right * x + tangent * z + Vector3(0, y, 0) end
    local paving = batch(root, "ForecourtPaving", World.Textured("StationForecourtPaving", "Textures/Railway/concrete.png", Color(.63,.64,.59), .98), false, 3.0)
    local joints = batch(root, "ForecourtJoints", solid(Color(.44,.45,.41),0,.98), false)
    local curb = batch(root, "ForecourtStepsKerbs", solid(Color(.58,.60,.54),0,.97), true)
    local planted = batch(root, "ForecourtBedSoil", solid(Color(.28,.25,.20),0,.99), false)
    local steel = batch(root, "ForecourtRailings", solid(Color(.44,.47,.46),.65,.54), true)
    local accepted, rejected = 0, 0
    -- 6x10小块局部合批，不把50米宽广场当成一个巨大包围圆而误拒绝。
    for x = -56.75, -14.75, 6 do
        for z = -95, -15, 10 do
            local center = p(x,0,z)
            if Route.CanPlaceFootprint(center,math.sqrt(3*3+5*5),5) then
                paving:AddBox(p(x,.025,z),Vector3(6,.05,10),angle)
                joints:AddBox(p(x,.061,z-4.98),Vector3(6,.004,.025),angle)
                joints:AddBox(p(x-2.98,.061,z),Vector3(.025,.004,10),angle)
                accepted = accepted + 1
            else rejected = rejected + 1 end
            if pause then pause() end
        end
    end
    -- 窄铺装补齐门槛至广场；3米台阶紧贴新版月台外边，级高/级深不变。
    paving:AddBox(p(-60.40,.025,-55),Vector3(1.30,.05,8),angle)
    local stairAlong = -49
    local stairStart = -OUTER - 3.0
    for i = 1, 8 do
        local x = stairStart + (i-.5)*.375
        local height = PLATFORM_Y*i/8
        curb:AddBox(p(x,height/2,stairAlong),Vector3(.375,height,8),angle)
        joints:AddBox(p(x+.165,height+.003,stairAlong),Vector3(.022,.006,8),angle)
    end
    -- 1:12无障碍坡道，地面至台面高差1.39米、长16.68米；接新版外沿。
    local x1 = -OUTER
    local x0, z0, z1 = x1 - 16.68, -38.2, -35.8
    local y0,y1 = .05,PLATFORM_Y
    local a,c,d,e = p(x0,y0,z0),p(x0,y0,z1),p(x1,y1,z1),p(x1,y1,z0)
    curb:AddQuad(a,c,d,e)
    curb:AddQuad(p(x0,0,z0),a,e,p(x1,0,z0))
    curb:AddQuad(p(x1,0,z1),d,c,p(x0,0,z1))
    curb:AddQuad(p(x0,0,z0),p(x1,0,z0),p(x1,0,z1),p(x0,0,z1))
    for _, z in ipairs({z0,z1}) do
        for i=0,8 do
            local t=i/8
            local x=x0+(x1-x0)*t
            local y=y0+(y1-y0)*t
            steel:AddBox(p(x,y+.45,z),Vector3(.045,.90,.045),angle)
        end
        local loA,loB=p(x0,y0+.90,z),p(x1,y1+.90,z)
        -- 手扶栏杆用窄四边形沿坡度连接，不需要每段一个节点。
        steel:AddQuad(loA,p(x0,y0+.95,z),p(x1,y1+.95,z),loB)
        steel:AddQuad(loB,p(x1,y1+.95,z),p(x0,y0+.95,z),loA)
    end
    -- 空心种植池：只留18厘米宽的矮边框与下沉土面，不再以9米实心绿块冒充植物。
    -- 外包圆保持原9×3.2米，植物完整包围盒必须装入池内；入口/坡道通路不变。
    for _, z in ipairs({-87,-22}) do
        for _, x in ipairs({-48,-25}) do
            local center = p(x,0,z)
            if Route.CanPlaceFootprint(center,math.sqrt(4.5^2+1.6^2),5) then
                for _, dx in ipairs({-4.41,4.41}) do
                    curb:AddBox(p(x+dx,.18,z),Vector3(.18,.36,3.2),angle)
                end
                for _, dz in ipairs({-1.51,1.51}) do
                    curb:AddBox(p(x,.18,z+dz),Vector3(8.64,.36,.18),angle)
                end
                planted:AddBox(p(x,.27,z),Vector3(8.60,.02,2.80),angle)
                Vegetation.BuildPlanter(root,center,right,tangent,8.6,2.8,.28,st.index)
            end
        end
    end
    -- 地面导向带从站房入口走向台阶，止于月台外缘。
    local tactile=batch(root,"ForecourtGuidance",solid(Color(.64,.57,.34),0,.95),false)
    tactile:AddBox(p(-34,.062,-49),Vector3(45.5,.018,.32),angle)
    for _, item in ipairs({paving,joints,curb,planted,steel,tactile}) do item:Finish(); if pause then pause() end end
    local entranceBoard = batch(root, "ForecourtEntranceBoard", solid(Color(.09,.22,.29),0,.90), false)
    entranceBoard:AddBox(p(-54,2.5,-49),Vector3(.08,.65,3.9),angle)
    entranceBoard:Finish()
    boardSigns(root, st, -49, -54, 2.5, .04, "进站口  →  1站台", .28, "ForecourtEntranceSign")
    print(string.format("[Station] %s 广场%d格/拒绝%d格，站房至月台已接通；8级台阶及1:12外侧坡道，不跨铁路",st.name,accepted,rejected))
end

-- 月台细节仍按材质合批：铺装缝、盲道条纹、排水篦子、台号及候车/出口提示。
-- 家具横距>=5米；安全线/盲道仍为表面细节，不侵入现代车体最小0.21米间隙。
function Station.BuildPlatformDetails(root, st, pause)
    local _,_,yaw=Route.Sample(st.s)
    local angle=math.rad(yaw)
    local seams=batch(root,"PlatformPavingJoints",solid(Color(.48,.49,.46),0,.97),false)
    local tactile=batch(root,"TactileGuidanceTiles",solid(Color(.69,.61,.36),0,.95),false)
    local ribs=batch(root,"TactileRibs",solid(Color(.58,.51,.29),0,.95),false)
    local dark=batch(root,"DrainGratesBinOpenings",solid(Color(.23,.27,.27),.35,.73),false)
    local steel=batch(root,"BinsAndSuspendedFrames",solid(Color(.43,.47,.46),.65,.55),true)
    local blue=batch(root,"PlatformInformationBoards",solid(Color(.10,.23,.29),.08,.81),false)
    for side=-1,1,2 do
        -- 微薄铺装缝抬离基面1厘米，避免原底面恰贴台面的深度闪烁。
        for ds=Route.PlatformStart+2,Route.PlatformEnd-1,3 do
            seams:AddBox(point(st,ds,side*((INNER+OUTER)/2),PLATFORM_Y+.013),Vector3(WIDTH-.55,.006,.018),angle)
            if pause then pause() end
        end
        for _,lat in ipairs({4.20,6.15,OUTER-.60}) do
            seams:AddBox(point(st,-70,side*lat,PLATFORM_Y+.013),Vector3(.018,.006,310),angle)
        end
        -- 导盲带与安全线之间保留通道，家具不动；条纹离带面留1厘米。
        tactile:AddBox(point(st,-70,side*3.15,PLATFORM_Y+.019),Vector3(.36,.018,308),angle)
        for _,lat in ipairs({3.04,3.15,3.26}) do
            ribs:AddBox(point(st,-70,side*lat,PLATFORM_Y+.041),Vector3(.026,.006,308),angle)
        end
        if side==-1 then
            local lateralCenter = -(OUTER+2.97)/2
            local guidanceWidth = OUTER-2.97
            tactile:AddBox(point(st,-49,lateralCenter,PLATFORM_Y+.020),Vector3(guidanceWidth,.020,.36),angle)
            for _,ds in ipairs({-49.11,-49,-48.89}) do
                ribs:AddBox(point(st,ds,lateralCenter,PLATFORM_Y+.043),Vector3(guidanceWidth,.006,.025),angle)
            end
        end
        for ds=-215,75,10 do
            dark:AddBox(point(st,ds,side*8.45,PLATFORM_Y+.014),Vector3(.32,.008,.72),angle)
            for offset=-.28,.28,.14 do
                steel:AddBox(point(st,ds+offset,side*8.45,PLATFORM_Y+.031),Vector3(.32,.006,.025),angle)
            end
        end
        for _,ds in ipairs({-155,-91,41}) do
            steel:AddBox(point(st,ds,side*6.75,PLATFORM_Y+.48),Vector3(.52,.96,.72),angle)
            dark:AddBox(point(st,ds,side*6.47,PLATFORM_Y+.73),Vector3(.015,.20,.48),angle)
            steel:AddBox(point(st,ds,side*6.75,PLATFORM_Y+.99),Vector3(.60,.055,.78),angle)
        end
        for _,ds in ipairs({-104,-20}) do
            -- 牌面朝轨道、背侧再贴同样文字；挂杆止于雨棚底，不占走道。
            blue:AddBox(point(st,ds,side*5.45,PLATFORM_Y+3.75),Vector3(.08,.88,4.9),angle)
            for _,dz in ipairs({-1.95,1.95}) do
                steel:AddBox(point(st,ds+dz,side*5.45,PLATFORM_Y+4.20),Vector3(.035,.82,.035),angle)
            end
            boardSigns(root, st, ds, side * 5.45, PLATFORM_Y + 3.75, .04,
                (side < 0 and "1" or "2") .. " 站台   黄线内候车", .24, "PlatformNumberAndWaiting")
        end
        local ds=side<0 and -49 or 52
        blue:AddBox(point(st,ds,side*7.10,PLATFORM_Y+2.70),Vector3(.07,.52,3.3),angle)
        steel:AddBox(point(st,ds,side*7.10,PLATFORM_Y+1.27),Vector3(.06,2.54,.06),angle)
        boardSigns(root, st, ds, side * 7.10, PLATFORM_Y + 2.70, .035,
            side < 0 and "出口  ←  站前广场" or "出口  →  沿台端部", .22, "PlatformExitDirection")
    end
    for _, item in ipairs({seams,tactile,ribs,dark,steel,blue}) do item:Finish(); if pause then pause() end end
end

---@param parent Node
---@param text string
---@param size number
function Station.MakeWorldSign(parent, text, size)
    local node = parent:CreateChild("WorldSign")
    -- 字体字号是像素，不是米；采用清晰的 48 像素字形，按默认 128 像素/米换算。
    node.scale = Vector3.ONE * (size * 128 / 48)
    local label = node:CreateComponent("Text3D")
    label.viewMask = 2
    label.faceCameraMode = FC_NONE
    label.castShadows = false
    label.drawDistance = 160
    if not label:SetFont("Fonts/MiSans-Bold.ttf", 48) then
        print("[Station] 警告：站名牌字体不可用")
    end
    label.text = text
    label.textAlignment = HA_CENTER
    label.horizontalAlignment = HA_CENTER
    label.verticalAlignment = VA_CENTER
    label.color = Color(0.93, 0.94, 0.92)
    return node
end
function Station.MakeSignText(parent, text, size)
    return Station.MakeWorldSign(parent, text, size)
end
function Station.Forget(index)
    for i=#placementData_,1,-1 do
        if placementData_[i].index==index then table.remove(placementData_,i) end
    end
end
function Station.Shutdown() placementData_ = {} end
function Station.GetPlacementData() return placementData_ end
function Station.GetDimensions()
    return {
        platformInner = INNER, platformOuter = OUTER, platformWidth = WIDTH, platformTopY = PLATFORM_Y,
        trainWidth = 3.1, maxTrainWidth = MAX_TRAIN_WIDTH,
        sideGap = INNER - MAX_TRAIN_WIDTH / 2, classicSideGap = INNER - 3.1 / 2,
        canopyInner = CANOPY_INNER, canopyOuter = CANOPY_OUTER,
        canopyTopY = CANOPY_Y + 0.06, columnInner = 7.57,
        platformStart = Route.PlatformStart, platformEnd = Route.PlatformEnd,
        buildingClearance = Route.BuildingClearance,
    }
end
return Station
