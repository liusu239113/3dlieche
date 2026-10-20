-- 米制双正线外侧月台与正侧岛台、城市主题雨棚及单侧站房。
local Route = require "world.Route"
local World = require "world.WorldMaterials"
local Materials = require "config.Materials"
local Vegetation = require "world.Vegetation"
local StationBuildings = require "world.StationBuildings"
local NightLighting = require "world.NightLighting"
local ReferenceStation = require "world.ReferenceStation"
local StationVisualConfig = require "config.StationVisualConfig"
local Station = {}

-- 环境状态独立于流式站点：新建站直接继承当前因子；卸载先注销投光池灯位。
local lampFactor_ = 0.0
---@type table<number, boolean>
local lampOwners_ = {}
---@type table<string, Material>
local signMaterials_ = {}

---@param key string
---@param color Color
---@return Material
local function signMaterial(key, color)
    if not signMaterials_[key] then
        local material = Material()
        material:SetTechnique(0, assert(cache:GetResource("Technique", "Techniques/NoTextureUnlit.xml")))
        material:SetShaderParameter("MatDiffColor", Variant(color))
        signMaterials_[key] = material
    end
    return signMaterials_[key]
end

---@param lampFactor number 日间0、夜间1；可每帧调用，材质只在因子变化时更新
function Station.SetEnvironment(lampFactor)
    local factor = math.max(0, math.min(1, lampFactor))
    if math.abs(factor-lampFactor_) < .005 then return end
    lampFactor_ = factor
    NightLighting.SetEnvironment(factor)
    local diffuser = signMaterials_["lamp"]
    if diffuser then
        diffuser:SetShaderParameter("MatEmissiveColor", Variant(Vector3(1.20,1.04,.76)*factor))
    end
end

---@return Material
local function lampMaterial()
    if not signMaterials_["lamp"] then
        -- 独占材质，不改Materials.Solid缓存以免改变站外同色家具。
        local material = Material()
        material:SetTechnique(0, assert(cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml")))
        material:SetShaderParameter("MatDiffColor", Variant(Color(.73,.72,.64)))
        material:SetShaderParameter("Metallic", Variant(0.0))
        material:SetShaderParameter("Roughness", Variant(.75))
        material:SetShaderParameter("MatEmissiveColor", Variant(Vector3(1.20,1.04,.76)*lampFactor_))
        signMaterials_["lamp"] = material
    end
    return signMaterials_["lamp"]
end

-- 净空截面（局部X，米）：站房-68 | 保留外台[-19.9,-12.9]
-- 到发2=-10.8 | 岛台[-8.9,-1.9] | 下行0=0(+S) | 上行1=+5(-S) | 上行外台[6.9,13.9]。
-- 仅迁移原正岛台，旧负外台/站房/城市不镜像；全站三座实际实体站台。
-- 各棚只在对应月台上方，不跨股道/接触线；全线净空使用开放Route。
-- 站台相对轨基顶面=0.34+1.10=1.44米，基座底面=-0.02米；山地站全部叠加采样基高。
-- 完整站台覆盖 [停靠点-225,停靠点+85] 及八节编组尾部。
local INNER = 1.90
local WIDTH = 7.0
local OUTER = INNER + WIDTH
local NEGATIVE_PLATFORM_SHIFT = -11.0
local NEGATIVE_INNER = -INNER + NEGATIVE_PLATFORM_SHIFT
local NEGATIVE_OUTER = -OUTER + NEGATIVE_PLATFORM_SHIFT
local MAX_TRAIN_WIDTH = 3.38
local PLATFORM_Y = 1.44
local CANOPY_INNER = 2.25
local CANOPY_OUTER = 8.65
local CANOPY_Y = PLATFORM_Y + 4.60
local ELEVATED_DECK_TOP = PLATFORM_Y
local ELEVATED_DECK_BOTTOM = -.18
local ELEVATED_PIER_BOTTOM = -4.0
local ELEVATED_PIER_STEP = 80.0
local ELEVATED_PLATFORM_INDICES = {[1]=true,[5]=true}
---@type table[]
local placementData_ = {}
---@type table<number, boolean>
local themeLogged_ = {}

---@type table<string, Material>
local solidMaterials_ = {}
---@class StationRoofPoint
---@field lateral number 月台单侧横距
---@field height number 相对原雨棚标高
---@class StationCanopyRange
---@field first number 起点
---@field last number 终点
---@class StationPlanter
---@field x number
---@field z number
---@field width number
---@field depth number
---@class StationTheme
---@field name string
---@field roof Color
---@field steel Color
---@field board Color
---@field paving Color
---@field pavingTexture string
---@field benches number[]
---@field bins number[]
---@field lamps number[]
---@field ranges StationCanopyRange[]
---@field profile StationRoofPoint[]
---@field supportStep number
---@field boardWidth number
---@field boardHeight number
---@field cityLine string
---@field exitLabel string
---@field planters StationPlanter[]
---@field plazaLayout string

-- 差异不仅是配色：棚长、柱距、横向剖面、候车密度及出口空间共同定义城市。
-- 星汐双坡门廊、岚港分段港城棚、榆岑窄拱棚、镜澜单坡白棚、云湾连续透光棚。
---@type StationTheme[]
local THEMES = {
    { name="传统门廊", roof=Color(.32,.25,.21), steel=Color(.47,.24,.19), board=Color(.35,.16,.13),
      paving=Color(.69,.40,.31), pavingTexture="Textures/Railway/brick.png",
      ranges={{first=-155,last=35}}, profile={{lateral=2.25,height=-.55},{lateral=5.45,height=.02},{lateral=8.65,height=-.55}},
      supportStep=10, benches={-132,-98,-64,-12,22}, bins={-146,-80,8}, lamps={-130,-100,-70,-40,-10,20},
      boardWidth=3.6, boardHeight=.96, cityLine="星汐 · 星澜旅程门户", exitLabel="红砖站前广场",
      plazaLayout="ceremonial", planters={{x=-49,z=-88,width=9,depth=3.2},{x=-24,z=-88,width=9,depth=3.2},{x=-49,z=-22,width=9,depth=3.2},{x=-24,z=-22,width=9,depth=3.2}} },
    { name="港城分段", roof=Color(.24,.34,.42), steel=Color(.34,.44,.50), board=Color(.10,.26,.38),
      paving=Color(.56,.61,.64), pavingTexture="Textures/Railway/concrete.png",
      ranges={{first=-150,last=-106},{first=-102,last=-58},{first=-54,last=-10},{first=-6,last=38}},
      profile={{lateral=2.25,height=-.28},{lateral=3.65,height=.02},{lateral=8.65,height=-.40}},
      supportStep=14, benches={-130,-82,-34,18}, bins={-142,-70,28}, lamps={-132,-118,-84,-70,-36,-22,12,26},
      boardWidth=3.2, boardHeight=.80, cityLine="岚港 · 风帆港城", exitLabel="钟楼广场",
      plazaLayout="harbour", planters={{x=-48,z=-83,width=8,depth=3.2},{x=-48,z=-25,width=8,depth=3.2}} },
    { name="灰石拱廊", roof=Color(.39,.42,.38), steel=Color(.55,.57,.51), board=Color(.16,.31,.22),
      paving=Color(.60,.62,.56), pavingTexture="Textures/Railway/concrete.png",
      ranges={{first=-118,last=18}}, profile={{lateral=3.60,height=-.48},{lateral=4.44,height=-.20},{lateral=5.28,height=-.035},{lateral=6.12,height=.02},{lateral=6.96,height=-.035},{lateral=7.80,height=-.20},{lateral=8.65,height=-.48}},
      supportStep=12, benches={-98,-58,0}, bins={-110,-40,12}, lamps={-96,-72,-48,-24,0},
      boardWidth=3.0, boardHeight=.88, cityLine="榆岑 · 林谷绿廊", exitLabel="林谷绿化广场",
      plazaLayout="garden", planters={{x=-49,z=-88,width=10,depth=4},{x=-32,z=-88,width=10,depth=4},{x=-18,z=-78,width=6,depth=10},{x=-49,z=-23,width=10,depth=4},{x=-32,z=-23,width=10,depth=4},{x=-18,z=-23,width=6,depth=8}} },
    { name="宽体斜顶", roof=Color(.82,.83,.78), steel=Color(.62,.65,.63), board=Color(.15,.29,.36),
      paving=Color(.69,.70,.66), pavingTexture="Textures/Railway/concrete.png",
      ranges={{first=-168,last=46}}, profile={{lateral=2.25,height=.02},{lateral=8.65,height=-.52}},
      supportStep=18, benches={-144,-108,-72,-12,24}, bins={-156,-96,-24,36}, lamps={-144,-108,-72,-36,0,36},
      boardWidth=4.0, boardHeight=.74, cityLine="镜澜 · 湖岸枢纽", exitLabel="宽体候车厅广场",
      plazaLayout="axis", planters={{x=-49,z=-91,width=12,depth=3.2},{x=-27,z=-91,width=12,depth=3.2},{x=-49,z=-19,width=12,depth=3.2},{x=-27,z=-19,width=12,depth=3.2}} },
    { name="连续玻璃金属", roof=Color(.43,.49,.52), steel=Color(.58,.64,.67), board=Color(.08,.25,.32),
      paving=Color(.65,.68,.69), pavingTexture="Textures/Railway/concrete.png",
      ranges={{first=-190,last=60}}, profile={{lateral=2.25,height=-.10},{lateral=4.70,height=-.15},{lateral=7.15,height=-.20},{lateral=8.65,height=-.24}},
      supportStep=20, benches={-166,-126,-86,-58,-14,26,50}, bins={-178,-106,-38,42}, lamps={-170,-130,-90,-50,-10,30,50},
      boardWidth=3.8, boardHeight=.86, cityLine="云湾 · 群域换乘枢纽", exitLabel="公交 / 地铁接驳广场",
      plazaLayout="interchange", planters={{x=-47,z=-25,width=10,depth=3.2},{x=-29,z=-25,width=10,depth=3.2}} },
}

-- 山地站使用独立的雨棚剖面、分段长度和候车密度，不能只换颜色复用城市站几何。
local mountainThemes = {
    {base=3,name="翠川山麓窄拱棚",city="翠川 · 田园山麓",exit="翠川山麓广场",roof=Color(.37,.45,.34),
        ranges={{first=-132,last=18}},profile={{lateral=3.60,height=-.38},{lateral=4.55,height=-.12},{lateral=5.55,height=.02},{lateral=6.55,height=-.12},{lateral=8.65,height=-.52}},
        supportStep=14,benches={-108,-72,-30,4},bins={-118,-46,10},lamps={-112,-84,-56,-28,0},plazaLayout="garden"},
    {base=2,name="石门灰石分段棚",city="石门 · 岩岭门户",exit="石门岩岭广场",roof=Color(.35,.38,.37),
        ranges={{first=-142,last=-96},{first=-88,last=-42},{first=-34,last=14}},profile={{lateral=2.25,height=-.22},{lateral=3.70,height=.02},{lateral=8.65,height=-.46}},
        supportStep=12,benches={-122,-76,-24},bins={-132,-62,4},lamps={-126,-102,-78,-54,-30,-6},plazaLayout="harbour"},
    {base=1,name="云脊木色双坡棚",city="云脊 · 林海山城",exit="云脊林海广场",roof=Color(.29,.38,.31),
        ranges={{first=-158,last=32}},profile={{lateral=2.25,height=-.62},{lateral=5.45,height=-.02},{lateral=8.65,height=-.62}},
        supportStep=11,benches={-136,-104,-70,-34,4,24},bins={-146,-92,-36,18},lamps={-140,-112,-84,-56,-28,0,24},plazaLayout="ceremonial"},
    {base=4,name="松岚高地斜顶棚",city="松岚 · 高地风廊",exit="松岚观景广场",roof=Color(.67,.70,.60),
        ranges={{first=-174,last=42}},profile={{lateral=2.25,height=.04},{lateral=4.05,height=-.10},{lateral=8.65,height=-.58}},
        supportStep=16,benches={-150,-112,-74,-24,18},bins={-160,-88,-8,30},lamps={-152,-120,-88,-56,-24,8,34},plazaLayout="axis"},
    {base=5,name="天池湖岸透光棚",city="天池 · 湖盆终点",exit="天池客运接驳广场",roof=Color(.36,.52,.56),
        ranges={{first=-198,last=58}},profile={{lateral=2.25,height=-.12},{lateral=4.70,height=-.18},{lateral=7.15,height=-.25},{lateral=8.65,height=-.30}},
        supportStep=19,benches={-174,-132,-90,-48,-6,30,52},bins={-184,-112,-40,44},lamps={-178,-140,-102,-64,-26,12,46},plazaLayout="interchange"},
}
for index,identity in ipairs(mountainThemes) do
    local plan={}
    for key,value in pairs(THEMES[identity.base]) do plan[key]=value end
    plan.name,plan.cityLine,plan.exitLabel,plan.roof=identity.name,identity.city,identity.exit,identity.roof
    plan.ranges,plan.profile,plan.supportStep=identity.ranges,identity.profile,identity.supportStep
    plan.benches,plan.bins,plan.lamps,plan.plazaLayout=identity.benches,identity.bins,identity.lamps,identity.plazaLayout
    THEMES[index+5]=plan --[[@as StationTheme ]]
end

---@param st table
---@return StationTheme
local function theme(st) return THEMES[st.index] or THEMES[1] end

---@param profile StationRoofPoint[]
---@param lateral number
---@return number
local function roofHeight(profile, lateral)
    for i=2,#profile do
        local a,b=profile[i-1],profile[i]
        if lateral<=b.lateral then
            local t=math.max(0,math.min(1,(lateral-a.lateral)/(b.lateral-a.lateral)))
            return CANOPY_Y+a.height+(b.height-a.height)*t
        end
    end
    return CANOPY_Y+profile[#profile].height
end

---@param color Color
---@param metallic? number
---@param roughness? number
---@return Material
local function solid(color, metallic, roughness)
    local key=string.format("%.4f_%.4f_%.4f_%.4f_%.4f",color.r,color.g,color.b,metallic or 0,roughness or .8)
    if not solidMaterials_[key] then solidMaterials_[key]=World.Solid(color,metallic,roughness) end
    return solidMaterials_[key]
end
---@param st table
---@param along number
---@param lateral number
---@param y number
---@return Vector3
local function point(st, along, lateral, y)
    -- 原负月台全部几何（板、棚、柱、文字/家具/盲道）同一入口搬迁；
    -- 不能把站房-68或前广场当作负侧月台一起搬走。
    local adjusted = lateral >= -9.5 and lateral <= -1.5
        and lateral + NEGATIVE_PLATFORM_SHIFT or (lateral >= 1.5 and lateral <= 9.5 and -lateral or lateral)
    return Route.SampleOffset(st.s + along, adjusted, y)
end
---@param root Node
---@param name string
---@param material Material
---@param shadows boolean
---@param tile? number
---@return RailwayBatch
local function batch(root, name, material, shadows, tile)
    return World.NewBatch(root:CreateChild(name), material, shadows, tile)
end

-- 单侧折边屋面：金属面厚16毫米、玻璃面厚12毫米；梁另建，不能用厚板代替结构。
-- 轨道0 | 2.25留白 | 棚面2.25..8.65 | 月台外缘8.90；另一侧独立镜像。
---@param target RailwayBatch
---@param st table
---@param side number
---@param first number
---@param last number
---@param a StationRoofPoint
---@param b StationRoofPoint
local function roofStrip(target, st, side, first, last, a, b)
    local halfThickness = st.index == 5 and .006 or .008
    ---@param ds number
    ---@param r StationRoofPoint
    ---@param offset number
    ---@return Vector3
    local function p(ds, r, offset) return point(st,ds,side*r.lateral,CANOPY_Y+r.height+offset) end
    local u,v,w,x=p(first,a,halfThickness),p(last,a,halfThickness),p(last,b,halfThickness),p(first,b,halfThickness)
    local d,e,f,g=p(first,a,-halfThickness),p(last,a,-halfThickness),p(last,b,-halfThickness),p(first,b,-halfThickness)
    -- 两座旧月台现在都在负侧：原正台反射后也须翻转面绕序。
    target:AddQuad(x,w,v,u); target:AddQuad(d,e,f,g)
    target:AddQuad(d,e,v,u); target:AddQuad(x,w,f,g)
    target:AddQuad(d,u,x,g); target:AddQuad(f,w,v,e)
end

-- 工字钢真实截面，不再用双面零厚度竖片冒充横梁。
--     ━━━━━  上翼缘 160mm × 12mm
--       ┃    腹板12mm / 梁高240mm
--     ━━━━━  下翼缘；剖面沿端点方向挤出，全部进同一钢结构批。
---@param target RailwayBatch
---@param a Vector3
---@param b Vector3
local function steelBeam(target, a, b)
    local axis = (b-a):Normalized()
    local horizontal = Vector3.UP:CrossProduct(axis):Normalized()
    local vertical = axis:CrossProduct(horizontal):Normalized()
    local w,h,t = .08,.12,.012
    local section = {
        Vector2(-w,-h),Vector2(w,-h),Vector2(w,-h+t),Vector2(t/2,-h+t),
        Vector2(t/2,h-t),Vector2(w,h-t),Vector2(w,h),Vector2(-w,h),
        Vector2(-w,h-t),Vector2(-t/2,h-t),Vector2(-t/2,-h+t),Vector2(-w,-h+t),
    }
    local function p(origin,x,y) return origin+horizontal*x+vertical*y end
    for i=1,#section do
        local u,v=section[i],section[i%#section+1]
        target:AddQuad(p(a,u.x,u.y),p(a,v.x,v.y),p(b,v.x,v.y),p(b,u.x,u.y))
    end
    for _,r in ipairs({{-w,-h,w,-h+t},{-t/2,-h+t,t/2,h-t},{-w,h-t,w,h}}) do
        target:AddQuad(p(a,r[1],r[2]),p(a,r[1],r[4]),p(a,r[3],r[4]),p(a,r[3],r[2]))
        target:AddQuad(p(b,r[1],r[2]),p(b,r[3],r[2]),p(b,r[3],r[4]),p(b,r[1],r[4]))
    end
end

---@param root Node
---@param st table
---@param roof RailwayBatch
---@param frame RailwayBatch
---@param pause fun()|nil
local function buildCityCanopies(root, st, roof, frame, pause)
    local plan=theme(st)
    local _,_,yaw=Route.Sample(st.s)
    local angle=math.rad(yaw)
    local glazing=batch(root,"ContinuousCanopyGlazing",Materials.Glass(Color(.46,.65,.70,.36)),false)
    local drainage=batch(root,"CityCanopyDrainage",solid(Color(.27,.29,.27),.36,.82),false)
    local details=batch(root,"CanopySeamsAndConnections",solid(plan.steel,.32,.64),false)
    -- 柱径160毫米/底板300毫米；柱中线统一7.65，内侧边仍为7.57。
    -- 斜撑全部在4.2米以上，雨棚不跨轨道，台面客流通道保持原净空。
    for side=-1,1,2 do
        for _,range in ipairs(plan.ranges) do
            local first=math.max(Route.PlatformStart+2,range.first)
            local last=math.min(Route.PlatformEnd-2,range.last)
            local middle,span=(first+last)/2,last-first
            for i=2,#plan.profile do
                local a,b=plan.profile[i-1],plan.profile[i]
                local target=(st.index==5 and i==3) and glazing or roof
                roofStrip(target,st,side,first,last,a,b)
            end
            for i,r in ipairs(plan.profile) do
                local lat=r.lateral+(i==1 and .03 or (i==#plan.profile and -.03 or 0))
                frame:AddBox(point(st,middle,side*lat,roofHeight(plan.profile,lat)-.07),Vector3(.06,.12,span),angle)
            end
            -- 纵向屋面立缝仅每0.8米一道，合批且150米外不绘微细件。
            for lat=plan.profile[1].lateral+.4,plan.profile[#plan.profile].lateral-.1,.8 do
                if not (st.index==5 and lat>4.70 and lat<7.15) then
                    details:AddBox(point(st,middle,side*lat,roofHeight(plan.profile,lat)+.018),Vector3(.018,.020,span),angle)
                end
            end
            for ds=first+1,last-1,plan.supportStep do
                local columnTop=roofHeight(plan.profile,7.65)-.25
                frame:AddTube(point(st,ds,side*7.65,PLATFORM_Y+.05),point(st,ds,side*7.65,columnTop),.08,12)
                details:AddBox(point(st,ds,side*7.72,PLATFORM_Y+.025),Vector3(.30,.05,.30),angle)
                for _,dx in ipairs({-.115,.115}) do
                    for _,dz in ipairs({-.115,.115}) do
                        details:AddTube(point(st,ds+dz,side*(7.72+dx),PLATFORM_Y+.05),point(st,ds+dz,side*(7.72+dx),PLATFORM_Y+.073),.018,6)
                    end
                end
                for i=2,#plan.profile do
                    local a,b=plan.profile[i-1],plan.profile[i]
                    steelBeam(frame,point(st,ds,side*a.lateral,CANOPY_Y+a.height-.14),point(st,ds,side*b.lateral,CANOPY_Y+b.height-.14))
                end
                local inner=math.max(plan.profile[1].lateral+.3,6.10)
                frame:AddTube(point(st,ds,side*7.65,columnTop-.90),point(st,ds,side*inner,roofHeight(plan.profile,inner)-.25),.035,8)
                frame:AddTube(point(st,ds,side*7.65,columnTop-.70),point(st,ds,side*8.40,roofHeight(plan.profile,8.40)-.25),.028,8)
                details:AddBox(point(st,ds,side*7.65,columnTop+.025),Vector3(.24,.05,.30),angle)
                if st.index==1 then
                    -- 老站钢柱饰套/石脚保留传统尺度，但不再层叠方块柱头。
                    frame:AddTube(point(st,ds,side*7.65,PLATFORM_Y+.05),point(st,ds,side*7.65,PLATFORM_Y+.30),.12,12)
                elseif st.index==5 then
                    -- 玻璃带每个柱跨设横向压条，不增透明材质节点。
                    details:AddBox(point(st,ds,side*5.925,roofHeight(plan.profile,5.925)+.012),Vector3(2.45,.018,.055),angle)
                end
                if pause then pause() end
            end
            Station.BuildCanopyDrainage(root,st,side,first,last,drainage)
            if pause then pause() end
        end
    end
    glazing:Finish(); if pause then pause() end
    if st.index==5 then glazing.geometry.viewMask=2 end
    drainage:Finish(); if pause then pause() end
    drainage.geometry.drawDistance=200
    details:Finish(); if pause then pause() end
    details.geometry.drawDistance=150
    print(string.format("[Station] %s雨棚：薄面/圆管柱/实心工字钢截面/弯管排水，细节合批%d顶点，未新增逐柱节点",st.name,details.vertices))
end

-- Text3D的可读正面沿局部-Z，不是+Z。文字分别位于不透明板两侧外部，
-- 两面各自朝外，板身遮住另一面的镜像背面；不用反转字符串或负缩放。
---@param root Node
---@param st RailwayStation
---@param along number
---@param lateral number
---@param y number
---@param halfDepth number
---@param text string|fun(face: number): string
---@param size number
---@param name string
local function boardSigns(root, st, along, lateral, y, halfDepth, text, size, name)
    local _, _, yaw = Route.Sample(st.s)
    for face = -1, 1, 2 do
        local label = root:CreateChild(name .. (face > 0 and "_OuterFace" or "_InnerFace"))
        label.position = point(st, along, lateral + face * (halfDepth + .03), y)
        -- 原正台反射后面偏移与法线须同时反转，避免把字面嵌进背板。
        local worldFace=(lateral>=1.5 and lateral<=9.5) and -face or face
        label.rotation = Quaternion(yaw + (worldFace > 0 and -90 or 90), Vector3.UP)
        local faceText = type(text)=="function" and text(worldFace) or text
        Station.MakeWorldSign(label, faceText --[[@as string]], size)
    end
end

--- 站牌只读生产路线名称/顺序；开放端点不能虚构首尾相邻。
---@param st RailwayStation
function Station.GetSignInfo(st)
    local stations = Route.GetStations()
    local previous = stations[st.index-1]
    local following = stations[st.index+1]
    if Route.IsClosed() then
        previous = previous or stations[#stations]
        following = following or stations[1]
    end
    return {
        name = st.name,
        previousName = previous and previous.name or "线路起点",
        nextName = following and following.name or "线路终点",
        previousLabel = previous and "上站 "..previous.name or "线路起点",
        nextLabel = following and "下站 "..following.name or "线路终点",
        platform1 = "1 站台", platform2 = "2 站台",
        nameSize = .68, approachNameSize = .82,
        boardWidth = 5.8, boardHeight = 1.72,
        centerAlong = ({-59,-66,-63,-68,-59})[st.index] or -63,
    }
end

-- 进站识别牌横于线路，-Z/+Z各有独立正面；不billboard、不占股道净空。
---@param root Node
---@param st RailwayStation
---@param along number
---@param lateral number
---@param y number
---@param text string
---@param size number
---@param name string
local function approachSigns(root, st, along, lateral, y, text, size, name)
    local _, _, yaw = Route.Sample(st.s)
    for face=-1,1,2 do
        local label = root:CreateChild(name..(face<0 and "_ArrivalFace" or "_DepartureFace"))
        label.position = point(st, along+face*.10, lateral, y)
        label.rotation = Quaternion(yaw+(face<0 and 0 or 180),Vector3.UP)
        Station.MakeWorldSign(label,text,size)
    end
end

---@param scene Scene
---@param initialS number|nil
function Station.Build(scene, initialS)
    Station.Init()
    local root = scene:CreateChild("StationsPreview")
    local best, distance = Route.GetStations()[1], math.huge
    for _, st in ipairs(Route.GetStations()) do
        local delta=math.abs(st.s-(initialS or 0))
        if delta<distance then best,distance=st,delta end
    end
    if best then Station.BuildOne(root,best) end
    return root
end
-- 上行站台仅构建基座，连续雨棚/盲道/灯具与另两台共用 ReferenceStation。
local function buildUpPlatform(root,st,pause)
    local first,last=Route.PlatformStart,Route.PlatformEnd
    local middle,span=(first+last)/2,last-first
    local angle=math.rad(select(3,Route.Sample(st.s)))
    local base=batch(root,"UpPlatformConcrete",World.Concrete(),false,3)
    base:AddBox(Route.SampleOffset(st.s+middle,10.4,(PLATFORM_Y-.02)/2),
        Vector3(7,PLATFORM_Y+.02,span),angle)
    base:Finish()
    base.geometry.viewMask=2
    if pause then pause() end
end

function Station.Init()
    Station.Shutdown()
    placementData_, themeLogged_, lampOwners_ = {}, {}, {}
end

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
    local plan=theme(st)
        local first, last = Route.PlatformStart, Route.PlatformEnd
        local middle, span = (first + last) / 2, last - first
        for side = -1, 1, 2 do
            platform:AddBox(point(st, middle, side * (INNER + WIDTH / 2), (PLATFORM_Y - 0.02) / 2),
                Vector3(WIDTH, PLATFORM_Y + 0.02, span), angle)
            -- Recessed substrate; Reference's segmented coping top is at +.050,
            -- so the old continuous cap cannot z-fight with the new cut-stone joints.
            coping:AddBox(point(st, middle, side * (INNER + 0.19), PLATFORM_Y + 0.013),
                Vector3(0.38, 0.026, span), angle)
            if pause then pause() end
        end
        ReferenceStation.BuildCanopies(node,st,pause)
        buildUpPlatform(node,st,pause)
        for _, item in ipairs({platform,coping}) do item:Finish(); if pause then pause() end end
        -- 参考图中的高架枢纽补齐站台下部结构：连续板、边梁、栏杆和规律桥墩。
        if ELEVATED_PLATFORM_INDICES[st.index] then
            local deck=batch(node,"ElevatedStationDeck",World.Concrete(),true,4)
            local edge=batch(node,"ElevatedStationEdgeGirders",solid(Color(.48,.51,.52),.15,.78),true)
            local guard=batch(node,"ElevatedStationPlatformGuard",solid(Color(.56,.60,.62),.72,.48),true)
            local pier=batch(node,"ElevatedStationPiers",World.Concrete(),true,2)
            deck:AddBox(Route.SampleOffset(st.s+middle,-5.4,(ELEVATED_DECK_TOP+ELEVATED_DECK_BOTTOM)/2),
                Vector3(7.0,ELEVATED_DECK_TOP-ELEVATED_DECK_BOTTOM,span),angle)
            deck:AddBox(Route.SampleOffset(st.s+middle,10.4,(ELEVATED_DECK_TOP+ELEVATED_DECK_BOTTOM)/2),
                Vector3(7.0,ELEVATED_DECK_TOP-ELEVATED_DECK_BOTTOM,span),angle)
            for _,lateral in ipairs({-8.55,-2.25,7.25,13.55}) do
                edge:AddBox(Route.SampleOffset(st.s+middle,lateral,ELEVATED_DECK_BOTTOM-.34),
                    Vector3(.48,.68,span),angle)
            end
            -- The island has two boarding edges; never put an opaque guard on lane2.
            -- Open outer-edge railings are generated once by ReferenceStation.
            for ds=first+10,last-1,ELEVATED_PIER_STEP do
                local pierCenter=Route.SampleOffset(st.s+ds,-5.4,(ELEVATED_PIER_BOTTOM+ELEVATED_DECK_BOTTOM)/2)
                pier:AddBox(pierCenter,Vector3(1.35,ELEVATED_DECK_BOTTOM-ELEVATED_PIER_BOTTOM,1.35),angle)
                if pause then pause() end
            end
            deck:Finish();edge:Finish();guard:Finish();pier:Finish()
            deck.geometry.viewMask,edge.geometry.viewMask,guard.geometry.viewMask,pier.geometry.viewMask=2,2,2,2
        end
        -- 相机遮挡专用位4只给实体站台/棚结构，家具/牌面继续使用环境位2。
        platform.geometry.viewMask = 2
        Station.BuildPlatformSigns(node, st); if pause then pause() end
        Station.BuildBuilding(node, st, nil, nil, nil, pause); if pause then pause() end
        Station.BuildForecourt(node, st, pause); if pause then pause() end
        Station.BuildPlatformDetails(node, st, pause); if pause then pause() end
        Station.BuildProps(node, st, nil, PLATFORM_Y); if pause then pause() end
        if not themeLogged_[st.index] then
            local reference=ReferenceStation.GetPlan(st)
            print(string.format("[Station] %s：%s站房身份/广场保留；参考灰色连续桁架棚%.0f米×3 / 柱距≤12米 / 灯距≤18米；站台%.0f米，负外台-19.90..-12.90、岛台-8.90..-1.90、上行外台6.90..13.90/台面1.44米",
                st.name,plan.name,reference.roofLast-reference.roofFirst,span))
            themeLogged_[st.index]=true
        end
end

-- 雨水槽/落水管只贴雨棚外缘与柱背，不进入7.57米柱内边。
-- 槽壁0.02米、管径0.09米；用同一材质合批，禁用远处微细阴影。
---@param root Node
---@param st table
---@param side number
---@param first number
---@param last number
---@param shared? RailwayBatch
function Station.BuildCanopyDrainage(root, st, side, first, last, shared)
    local _, _, yaw = Route.Sample(st.s)
    local angle = math.rad(yaw)
    local metal = shared or batch(root, "CanopyGutters" .. side, solid(Color(.27,.29,.27), .36, .82), false)
    local span, middle = last - first, (last + first) / 2
    local profile=theme(st).profile
    local gutterY=roofHeight(profile,8.56)
    local pipeTop=gutterY-.26
    local pipeBottom=PLATFORM_Y+.05
    metal:AddBox(point(st, middle, side * 8.56, gutterY - .14), Vector3(.15,.025,span), angle)
    for _, lat in ipairs({8.49,8.63}) do
        metal:AddBox(point(st, middle, side * lat, gutterY - .095), Vector3(.02,.09,span), angle)
    end
    for _, ds in ipairs({first + 1,last - 5}) do
        -- 90毫米圆管，两个半径120毫米弯头；水平支管贴棚外侧接入竖管。
        local bend=.12
        local verticalTop=pipeTop-bend
        metal:AddTube(point(st,ds,side*7.81,pipeBottom),point(st,ds,side*7.81,verticalTop),.045,8)
        for i=1,6 do
            local a,b=(i-1)*math.pi/12,i*math.pi/12
            metal:AddTube(
                point(st,ds,side*(7.93-bend*math.cos(a)),verticalTop+bend*math.sin(a)),
                point(st,ds,side*(7.93-bend*math.cos(b)),verticalTop+bend*math.sin(b)),.045,8)
        end
        metal:AddTube(point(st,ds,side*7.93,pipeTop),point(st,ds,side*8.44,pipeTop),.045,8)
        for i=1,6 do
            local a,b=(i-1)*math.pi/12,i*math.pi/12
            metal:AddTube(
                point(st,ds,side*(8.44+bend*math.sin(a)),pipeTop+bend*(1-math.cos(a))),
                point(st,ds,side*(8.44+bend*math.sin(b)),pipeTop+bend*(1-math.cos(b))),.045,8)
        end
        metal:AddTube(point(st,ds,side*8.56,pipeTop+bend),point(st,ds,side*8.56,gutterY-.12),.045,8)
        for _, y in ipairs({.65,2.25,3.80}) do
            metal:AddBox(point(st, ds, side * 7.81, PLATFORM_Y + y), Vector3(.12,.035,.12), angle)
        end
    end
    if not shared then
        metal:Finish()
        metal.geometry.drawDistance = 200
    end
end

function Station.BuildPlatformSigns(root, st)
    local plan=theme(st)
    local info=Station.GetSignInfo(st)
    local steel = batch(root, "SignPosts", solid(plan.steel, 0.30, 0.78), true)
    -- 深墨底/暖白字/琥珀边统一全线；无光照牌面=低成本背光箱，夜间不依赖逐牌点光。
    local boards = batch(root, "CityNameBoards", signMaterial("ink",Color(.018,.040,.065)), false)
    local accents = batch(root, "StationSignAccents", signMaterial("amber",Color(.92,.64,.18)), false)
    local _, _, yaw = Route.Sample(st.s)
    local angle=math.rad(yaw)
    for side = -1, 1, 2 do
        local platform=side<0 and info.platform1 or info.platform2
        -- 中部取各城柱跨中点，背面看时雨棚柱不能切断字形。
        for _, ds in ipairs({ -175, info.centerAlong, 65 }) do
            local position = point(st, ds, side * 7.2, PLATFORM_Y)
            if st.index==1 or st.index==3 then
                for _,dz in ipairs({-info.boardWidth*.40,info.boardWidth*.40}) do
                    steel:AddBox(position+Vector3(0,.90,0)+Route.TangentAt(st.s)*dz,Vector3(.07,1.80,.07),angle)
                end
            else
                steel:AddBox(position+Vector3(0,.90,0),Vector3(.09,1.80,.09),angle)
            end
            boards:AddBox(position+Vector3(0,2.66,0),Vector3(.10,info.boardHeight,info.boardWidth),angle)
            accents:AddBox(position+Vector3(0,3.50,0),Vector3(.115,.055,info.boardWidth),angle)
            boardSigns(root,st,ds,side*7.2,PLATFORM_Y+2.74,.05,info.name,info.nameSize,"StationName")
            boardSigns(root,st,ds,side*7.2,PLATFORM_Y+3.37,.05,platform,.20,"StationPlatformNumber")
            -- 可读正面局部-X朝向随face翻转：从-X看文字右方向=-里程，背面=+里程。
            boardSigns(root,st,ds,side*7.2,PLATFORM_Y+2.12,.05,function(face)
                if face<0 then return "← "..info.nextLabel.."     "..info.previousLabel.." →" end
                return "← "..info.previousLabel.."     "..info.nextLabel.." →"
            end,.22,"StationNeighbourDirection")
        end
        -- 外侧月台原来离驾驶股道过远，侧面牌又接近侧视；入口识别牌正对两方向来车。
        -- 5.4m宽完全落于7m月台内：正台[2.75,8.15]、负台[-19.15,-13.75]。
        -- 牌底距台面2.27m，步行通道与灯棚不受阻，不增刚体。
        local ds=Route.PlatformStart+12
        boards:AddBox(point(st,ds,side*5.45,PLATFORM_Y+2.97),Vector3(5.4,1.4,.12),angle)
        accents:AddBox(point(st,ds,side*5.45,PLATFORM_Y+3.65),Vector3(5.4,.05,.135),angle)
        for _,lat in ipairs({3.05,7.85}) do
            steel:AddBox(point(st,ds,side*lat,PLATFORM_Y+1.80),Vector3(.07,3.60,.07),angle)
        end
        approachSigns(root,st,ds,side*5.45,PLATFORM_Y+3.18,info.name,info.approachNameSize,"ApproachStationName")
        approachSigns(root,st,ds,side*5.45,PLATFORM_Y+2.55,platform.." · 到站慢行",.26,"ApproachPlatformNumber")
    end
    -- 停车目标以生产st.s为准（不是平台末端），黄黑牌区别于红色信号。
    boards:AddBox(point(st,0,4.15,PLATFORM_Y+1.70),Vector3(1.24,1.45,.12),angle)
    accents:AddBox(point(st,0,4.15,PLATFORM_Y+2.40),Vector3(1.24,.05,.14),angle)
    steel:AddBox(point(st,0,4.15,PLATFORM_Y+.60),Vector3(.07,1.20,.07),angle)
    approachSigns(root,st,0,4.15,PLATFORM_Y+1.94,"停",.64,"StationStopTarget")
    approachSigns(root,st,0,4.15,PLATFORM_Y+1.35,"对标停车",.21,"StationStopInstruction")
    steel:Finish(); boards:Finish(); accents:Finish()
    steel.geometry.shadowDistance=70
    steel.geometry.drawDistance=220
    boards.geometry.drawDistance=260
    accents.geometry.drawDistance=220
    print(string.format("[StationSigns] %s：6块双面邻站/台号牌+2块固定朝向进站牌，背面箭头镜像布局；停车对标s=%.1f，无新增逐牌灯",st.name,st.s))
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
    for _, child in ipairs(node:GetChildrenWithComponent("CustomGeometry",true)) do
        local structure=child:GetComponent("CustomGeometry")
        if structure then structure.viewMask=2 end
    end
    local sign = node:CreateChild("HouseName")
    -- 站名置于门廊/拱廊最外侧，固定到建筑立面；深色背板隔离玻璃/墙体纹理。
    local signPosition=StationBuildings.GetSignPosition(style)
    local plaque=batch(node,"HouseNameBacking",signMaterial("ink",Color(.018,.040,.065)),false)
    plaque:AddBox(signPosition-Vector3(.055,0,0),Vector3(.08,1.55,6.0))
    plaque:Finish()
    plaque.geometry.drawDistance=260
    sign.position = signPosition+Vector3(.025,0,0)
    sign.rotation = Quaternion(-90, Vector3.UP)
    Station.MakeWorldSign(sign, st.name, .96)
    placementData_[#placementData_ + 1] = {
        name = st.name, index = st.index, x = center.x, y = center.y, z = center.z, radius = radius, clearance = clearance,
        worldBaseY = Route.Sample(st.s).y, platformWorldY = Route.Sample(st.s).y + PLATFORM_Y,
        s = st.s, platformStart = st.s + Route.PlatformStart, platformEnd = st.s + Route.PlatformEnd,
    }
    print(string.format("[Station] %s 站房原型=%s，完整包络净空 %.2f 米（要求至少 25 米）",
        st.name, style.archetype, clearance))
    -- Near-line waiting wings, NOT relocation/scaling of the landmark house.
    -- x=-34 +/-4.6; complete 12.3m roof envelope is checked per module against the route.
    -- ds[-96,-18] remains open for the main house sightline, -49 stairs and -37 ramp;
    -- ds>=57 stays open for the existing bridge/ground approach at x=-44.
    local wingRadius=math.sqrt(4.6^2+6.15^2)+.05
    local wings=root:CreateChild("StationNearLineWaitingWings")
    for _,ds in ipairs({-126,-114,-102,-12,0,12}) do
        local wingCenter=Route.SampleOffset(st.s+ds,-34,0)
        if Route.CanPlaceFootprint(wingCenter,wingRadius,Route.BuildingClearance) then
            local wing=wings:CreateChild("WaitingWing_"..ds)
            wing.position=wingCenter
            local _,_,wingYaw=Route.Sample(st.s+ds)
            wing.rotation=Quaternion(wingYaw,Vector3.UP)
            StationBuildings.BuildPlatformWing(wing,style,pause)
        else
            print(string.format("[Station] %s 近线翼廊 ds=%.0f 未通过全线路净空，跳过而不侵入轨道",st.name,ds))
        end
        if pause then pause() end
    end
end

-- 候车家具密度随城市改变，原有板条长椅和矩形灯具继续合批。
-- 星汐/榆岑保留木色板条，镜澜/云湾使用分隔金属座椅，入口-49附近留空。
function Station.BuildProps(root, st, _matLamp, _baseY)
    local plan=theme(st)
    local steel = batch(root, "FurnitureFrames", solid(plan.steel, .30, .78), true)
    local slats = batch(root, "BenchSlats", solid(st.index<=3 and Color(.42,.35,.27) or Color(.47,.51,.51), .12, .82), true)
    local diffuser = batch(root, "LampDiffusers", lampMaterial(), false)
    local _, _, yaw = Route.Sample(st.s)
    local angle = math.rad(yaw)
    for side = -1, 1, 2 do
        for _, ds in ipairs(plan.benches) do
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
            if st.index>=4 then
                for _,dz in ipairs({-.75,0,.75}) do
                    steel:AddBox(point(st,ds+dz,side*6.18,PLATFORM_Y+.66),Vector3(.56,.045,.045),angle)
                end
            end
        end
    end
    -- ReferenceStation owns all three platform lamp rows and the bounded NightLighting sites.
    -- Keep only the city-specific benches here; no duplicate old diffuser or pole geometry.
    lampOwners_[st.index] = true
    ReferenceStation.BuildLightingAndRailings(root,st)
    steel:Finish(); slats:Finish(); diffuser:Finish()
    slats.geometry.shadowDistance = 90
    diffuser.geometry.drawDistance = 180
end

-- 站前广场在站房入口（横距-58米）与负台外缘（-19.90米）之间。
-- 净空示意（局部X，非碰撞体）：
-- 站房-68 | 地面广场 | 坡道[-36.58,-19.90]/台阶[-22.90,-19.90]
--         | 月台[-19.90,-12.90] | 上行-5 | 下行0 | 正岛台 | 到发+10.8
-- 台阶/坡道/导向带终点只接外沿，不穿lane1；对侧天桥由StationYard独立负责。
-- 每个铺装单元检查全线包络，并裁止于负台外边，不能挪台后保留原接入。
function Station.BuildForecourt(root, st, pause)
    local origin, tangent, yaw = Route.Sample(st.s)
    local right = Route.RightAt(st.s)
    local angle = math.rad(yaw)
    local plan=theme(st)
    ---@param x number
    ---@param y number
    ---@param z number
    ---@return Vector3
    local function p(x, y, z)
        -- 广场/台阶/树池与对应站台同一采样基高，不把3D tangent.y再次当作竖直偏移。
        return Route.SampleOffset(st.s + z, x, y)
    end
    local paving = batch(root, "ForecourtPaving", World.Textured("StationForecourt_"..st.index, plan.pavingTexture, plan.paving, .98), false, st.index==1 and 1.5 or 3.0)
    local joints = batch(root, "ForecourtJoints", solid(Color(.44,.45,.41),0,.98), false)
    local curb = batch(root, "ForecourtStepsKerbs", solid(Color(.58,.60,.54),0,.97), true)
    local planted = batch(root, "ForecourtBedSoil", solid(Color(.28,.25,.20),0,.99), false)
    local steel = batch(root, "ForecourtRailings", solid(Color(.44,.47,.46),.65,.54), true)
    local accepted, rejected = 0, 0
    -- 仍用小块净空检查；形状改为门廊礼仪广场/港城窄边/林谷绿廊/镜澜宽轴/云湾接驳带。
    for x = -56.75, -14.75, 6 do
        for z = -95, -15, 10 do
            local clipped=(plan.plazaLayout=="harbour" and x>-20 and (z<-85 or z>-25))
                or (plan.plazaLayout=="garden" and x>-20 and z<-85)
                or (plan.plazaLayout=="axis" and x>-20 and (z<-85 or z>-25))
            -- 最后一列裁在新外沿，旧6米格不能铺到移后的负月台内部。
            local left,rightEdge=x-3,math.min(x+3,NEGATIVE_OUTER)
            local width=rightEdge-left
            local centerX=(left+rightEdge)/2
            local center = p(centerX,0,z)
            if width>.01 and not clipped and Route.CanPlaceFootprint(center,math.sqrt((width/2)^2+5*5),5) then
                paving:AddBox(p(centerX,.025,z),Vector3(width,.05,10),angle)
                joints:AddBox(p(centerX,.061,z-4.98),Vector3(width,.004,.025),angle)
                joints:AddBox(p(left+.02,.061,z),Vector3(.025,.004,10),angle)
                accepted = accepted + 1
            else rejected = rejected + 1 end
            if pause then pause() end
        end
    end
    -- 窄铺装补齐门槛至广场；3米台阶紧贴新版月台外边，级高/级深不变。
    paving:AddBox(p(-60.40,.025,-55),Vector3(1.30,.05,8),angle)
    local stairAlong = -49
    local stairStart = NEGATIVE_OUTER - 3.0
    for i = 1, 8 do
        local x = stairStart + (i-.5)*.375
        local height = PLATFORM_Y*i/8
        curb:AddBox(p(x,height/2,stairAlong),Vector3(.375,height,8),angle)
        joints:AddBox(p(x+.165,height+.003,stairAlong),Vector3(.022,.006,8),angle)
    end
    -- 1:12无障碍坡道，地面至台面高差1.39米、长16.68米；接新版外沿。
    local x1 = NEGATIVE_OUTER
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
    -- 花池按城市改为对称红砖广场、港城留白、林谷六组绿化、宽轴边庭及接驳边带。
    -- 每池仍检查完整包络；植物调用原Vegetation实现，保留通往-49台阶/-37坡道的空带。
    for _,bed in ipairs(plan.planters) do
        local z,w,d=bed.z,bed.width,bed.depth
        -- 保留所有城市花池，原贴轨侧花池随新月台外沿退到广场侧。
        local x=math.min(bed.x,NEGATIVE_OUTER-w/2-.5)
        local center=p(x,0,z)
        if Route.CanPlaceFootprint(center,math.sqrt((w/2)^2+(d/2)^2),5) then
            for _,dx in ipairs({-w/2+.09,w/2-.09}) do
                curb:AddBox(p(x+dx,.18,z),Vector3(.18,.36,d),angle)
            end
            for _,dz in ipairs({-d/2+.09,d/2-.09}) do
                curb:AddBox(p(x,.18,z+dz),Vector3(w-.36,.36,.18),angle)
            end
            planted:AddBox(p(x,.27,z),Vector3(w-.40,.02,d-.40),angle)
            Vegetation.BuildPlanter(root,center,right,tangent,w-.40,d-.40,.28,st.index)
        end
        if pause then pause() end
    end
    local city=batch(root,"ForecourtCityFixtures",solid(plan.board,.08,.83),true)
    local glass=batch(root,"ForecourtTransitGlass",Materials.Glass(Color(.46,.65,.70,.36)),false)
    -- 新增出口家具一律走完整线路包络检查，不跨铁路、不给对侧虚构出口桥。
    ---@param target RailwayBatch
    ---@param x number
    ---@param y number
    ---@param z number
    ---@param w number
    ---@param h number
    ---@param d number
    local function place(target,x,y,z,w,h,d)
        local left,rightEdge=x-w/2,math.min(x+w/2,NEGATIVE_OUTER)
        local clippedWidth=rightEdge-left
        local centerX=(left+rightEdge)/2
        if clippedWidth>.01 and Route.CanPlaceFootprint(p(centerX,0,z),math.sqrt((clippedWidth/2)^2+(d/2)^2),5) then
            target:AddBox(p(centerX,y,z),Vector3(clippedWidth,h,d),angle)
        end
    end
    if plan.plazaLayout=="ceremonial" then
        -- 星汐：红砖面中的两道石质礼仪轴，端部低石座与传统门廊呼应。
        for _,z in ipairs({-66,-44}) do
            place(curb,-38,.076,z,36,.02,.72)
        end
        for _,x in ipairs({-52,-21}) do
            for _,z in ipairs({-74,-30}) do
                place(curb,x,.24,z,1.0,.48,3.4)
            end
        end
    elseif plan.plazaLayout=="harbour" then
        -- 岚港：钟楼前方十二段罗盘铺装，不用喷泉巨块堵住主进站轴。
        for i=1,12 do
            local a,b=(i-1)*math.pi/6,i*math.pi/6
            local u,v=p(-39+6*math.cos(a),.077,-66+6*math.sin(a)),p(-39+6*math.cos(b),.077,-66+6*math.sin(b))
            local w,x=p(-39+5.6*math.cos(b),.077,-66+5.6*math.sin(b)),p(-39+5.6*math.cos(a),.077,-66+5.6*math.sin(a))
            if Route.CanPlaceFootprint(p(-39,0,-66),6,5) then curb:AddQuad(u,v,w,x) end
        end
        for _,z in ipairs({-82,-26}) do
            place(city,-35,.48,z,7,.12,.70)
            for _,dx in ipairs({-2.8,2.8}) do place(steel,-35+dx,.23,z,.10,.46,.55) end
        end
    elseif plan.plazaLayout=="garden" then
        -- 榆岑：绿廊沿外侧转折，石椅嵌在花池端部，不占台阶/坡道横向路径。
        for _,z in ipairs({-77,-29}) do
            place(curb,-38,.078,z,24,.024,1.4)
            for _,x in ipairs({-48,-30}) do
                place(curb,x,.26,z,4,.52,.72)
            end
        end
    elseif plan.plazaLayout=="axis" then
        -- 镜澜：宽体站的8米宽进站石轴与两列秩序化矮护柱。
        place(curb,-37,.077,-55,38,.022,8)
        for _,z in ipairs({-62,-43}) do
            for x=-52,-20,8 do place(steel,x,.40,z,.18,.80,.18) end
        end
    else
        -- 云湾：公交港湾和地铁出口均在广场外侧，候车棚不伸到铁路上方。
        for x=-48,-24,6 do
            place(city,x,.068,-84,4,.018,12)
            for _,dx in ipairs({-2.1,2.1}) do place(curb,x+dx,.092,-84,.12,.018,12) end
        end
        place(city,-37,3.20,-76,31,.10,3.8)
        place(glass,-37,1.85,-77.7,31,2.4,.055)
        for x=-50,-24,6.5 do place(steel,x,1.56,-77.7,.10,3.12,.10) end
        for _,x in ipairs({-46,-36,-26}) do
            place(steel,x,.46,-76,3,.08,.62)
            for _,dx in ipairs({-1.1,1.1}) do place(steel,x+dx,.23,-76,.07,.46,.46) end
        end
        -- 地铁口为真实下行方向提示/护栏，不修改地面或添加交互碰撞。
        place(city,-51,2.1,-31,.12,2.0,5.2)
        place(steel,-51,1.0,-34,.07,2.0,.07)
        place(steel,-51,1.0,-28,.07,2.0,.07)
        boardSigns(root,st,-31,-51,2.15,.06,"地铁换乘  ↓",.25,"MetroInterchange")
        place(city,-37,3.60,-76,.09,.62,6.0)
        boardSigns(root,st,-76,-37,3.60,.045,"城市公交接驳",.30,"BusInterchange")
    end
    city:Finish(); glass:Finish(); if pause then pause() end
    -- 地面导向带从站房入口走向台阶，止于月台外缘。
    local tactile=batch(root,"ForecourtGuidance",solid(Color(.64,.57,.34),0,.95),false)
    local guidanceStart=-56.75
    tactile:AddBox(p((guidanceStart+NEGATIVE_OUTER)/2,.062,-49),
        Vector3(NEGATIVE_OUTER-guidanceStart,.018,.32),angle)
    for _, item in ipairs({paving,joints,curb,planted,steel,tactile}) do item:Finish(); if pause then pause() end end
    local entranceBoard = batch(root, "ForecourtEntranceBoard", solid(plan.board,.08,.83), false)
    entranceBoard:AddBox(p(-54,2.5,-49),Vector3(.08,.65,5.6),angle)
    entranceBoard:Finish()
    boardSigns(root, st, -49, -54, 2.5, .04, "进站口 · 1站台 · "..plan.exitLabel, .19, "ForecourtEntranceSign")
    print(string.format("[Station] %s 广场%d格/拒绝%d格，站房至月台已接通；8级台阶及1:12外侧坡道，不跨铁路",st.name,accepted,rejected))
end

-- Actual grey paving, twin-edge tactile on island and suspended blue/clock/LED signs.
-- The historical sign/forecourt coordinates remain intact; Reference uses explicit real laterals.
function Station.BuildPlatformDetails(root, st, pause)
    ReferenceStation.BuildPaving(root,st,pause)
    ReferenceStation.BuildWayfinding(root,st,Station.MakeWorldSign,pause)
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
    label.drawDistance = 220
    label.fixedScreenSize = false
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
    ReferenceStation.Forget(index)
    NightLighting.Forget("station:" .. index)
    lampOwners_[index] = nil
end
function Station.Shutdown()
    for index in pairs(lampOwners_) do NightLighting.Forget("station:" .. index) end
    ReferenceStation.Shutdown()
    placementData_, themeLogged_, lampOwners_ = {}, {}, {}
end
function Station.GetPlacementData() return placementData_ end
function Station.GetDimensions()
    return {
        platformInner = INNER, platformOuter = OUTER, platformWidth = WIDTH, platformTopY = PLATFORM_Y,
        trainWidth = 3.1, maxTrainWidth = MAX_TRAIN_WIDTH,
        sideGap = INNER - MAX_TRAIN_WIDTH / 2, classicSideGap = INNER - 3.1 / 2,
        canopyInner = CANOPY_INNER, canopyOuter = CANOPY_OUTER,
        canopyTopY = 8.20, columnInner = 7.47,
        referenceCanopy = true, referenceRoofFirst = Route.PlatformStart+6,
        referenceRoofLast = math.min(Route.PlatformEnd-28,57),
        referencePlatformCenters = {-16.4,-5.4,10.4},
        referenceColumnCenters = {-18.65,-7.65,12.65},
        referenceColumnWidth = StationVisualConfig.ReferenceArchitecture.columnWidth,
        referenceColumnDepth = StationVisualConfig.ReferenceArchitecture.columnDepth,
        referenceTrussBottomY = StationVisualConfig.ReferenceArchitecture.trussBottomY,
        referenceLampSpacing = 18, referenceLampY = 6.27,
        platformStart = Route.PlatformStart, platformEnd = Route.PlatformEnd,
        buildingClearance = Route.BuildingClearance,
        negativePlatformShift = NEGATIVE_PLATFORM_SHIFT,
        negativePlatformMin = NEGATIVE_OUTER, negativePlatformMax = NEGATIVE_INNER,
        -- positive为历史API名称，真实岛台现在位于负横距；消费者不得假定符号。
        positivePlatformMin = -OUTER, positivePlatformMax = -INNER,
        islandPlatformMin = -OUTER, islandPlatformMax = -INNER,
        upPlatformMin = 6.9, upPlatformMax = 13.9,
        islandStairLateral = -5.4, upStairLateral = 10.4,
        negativeCanopyMin = -CANOPY_OUTER+NEGATIVE_PLATFORM_SHIFT,
        negativeCanopyMax = -CANOPY_INNER+NEGATIVE_PLATFORM_SHIFT,
        negativeColumnMin = -7.65-StationVisualConfig.ReferenceArchitecture.columnWidth/2+NEGATIVE_PLATFORM_SHIFT,
        negativeColumnMax = -7.65+StationVisualConfig.ReferenceArchitecture.columnWidth/2+NEGATIVE_PLATFORM_SHIFT,
        upLaneLateral = 5, stationLaneLateral = -10.8,
        negativePlatformToUpBody = (-10.8-MAX_TRAIN_WIDTH/2)-NEGATIVE_INNER,
        islandToSidingBody = -OUTER-(-10.8+MAX_TRAIN_WIDTH/2),
        forecourtStairMin = NEGATIVE_OUTER-3, forecourtStairMax = NEGATIVE_OUTER,
        forecourtRampMin = NEGATIVE_OUTER-16.68, forecourtRampMax = NEGATIVE_OUTER,
        forecourtGuidanceMax = NEGATIVE_OUTER,
        elevatedPlatformStations = {1,5},
        elevatedSupportDeckTopY = ELEVATED_DECK_TOP,
        elevatedSupportDeckBottomY = ELEVATED_DECK_BOTTOM,
        elevatedSupportPierStep = ELEVATED_PIER_STEP,
        elevatedSupportDescription = "站台板下连续箱板、边梁、外缘栏杆与规律桥墩",
    }
end
return Station
