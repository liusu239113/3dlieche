-- ============================================================================
-- Coach - 星澜群域云舟 C24 客车，长24米，基于 core.MeshUtils.GeoBuilder。
-- 局部+Z为前端，Y向上，单位为米。父节点原点为线路基准而非轨面。
-- 轨面y=.34、轮心y=.80、踏面半径=.46；静态重复部件按材质合批并共享Model。
-- 仅转向架和车轮需要运动。窗洞真实留空，玻璃后面不存在白色整盒。
-- 首次按需烘焙内存样板，后续Build不重复生成网格；没有新增客室/车型专属内饰。
-- ============================================================================

local MeshUtils = require "core.MeshUtils"
local Materials = require "config.Materials"
local FictionalWorld = require "config.FictionalWorld"
local CoachLiveries = require "config.CoachLiveries"
local CoachModels = require "config.CoachModels"
local Catalog = require "config.TrainCatalog"
local RollingStock = require "train.RollingStock"

---@class CoachBogie
---@field node Node 枢轴位于局部(0,0,z)，子部件高度采用线路基准。
---@field z number 纵向枢轴偏移，分别为-8.5和+8.5米。

---@class CoachBuildResult
---@field wheels Node[] 八个独立车轮节点，挂在各自转向架下。
---@field bogies CoachBogie[] 两个可独立转向的转向架枢轴。
---@field wheelRadius number 踏面滚动半径.46米，不是轮缘半径。
---@field assetNode Node|nil 实际独立MDL节点；程序化样板无此字段。
---@field drawable StaticModel|nil 实际绑定的独立MDL，不从来源标签推断。

local Coach = {}
Coach.Length = 24.0
Coach.Width = 3.10
Coach.BodyBottom = 1.30
Coach.RoofHeight = 4.08
Coach.RailTop = 0.34
Coach.WheelRadius = 0.46
Coach.BogieOffset = 8.50
Coach.AxleSpacing = 2.40

-- 净空示意：正视图/侧视图（仅视觉模型，不创建碰撞组件）：
--                顶点 y4.08
--             .--------------.
--           /     弧形车顶     \   侧顶过渡 y3.47
--          |      独立窗洞      |  窗洞 y2.25..3.29
--          |      蓝白蒙皮      |
--          +--------------------+  车体底部 y1.30
--             弹簧 / 侧框           轮心 y.80
--             O            O       x=+/-.7175，踏面半径.46
--             |            |       轨面 y.34
-- 侧向：端壁-12 / 转向架-8.5（轴位+/-1.2）/ 转向架+8.5 / 端壁+12。
-- 踏面最高1.26 < 车底1.30；轮缘最高1.278，仍留净空。
-- 踏板最近边z10.25，位于前轮外廓z10.16以外。

---@class CoachMaterials
---@field white Material
---@field blue Material
---@field stripe Material 车队特征条与车门色
---@field roof Material
---@field dark Material
---@field steel Material
---@field rubber Material
---@field glass Material
---@field detail Material
---@field door Material
---@field accent Material

---@type table<string, CoachMaterials>
local materialCache = {}
---@type CoachLivery
local livery_ = CoachLiveries.Get(CoachLiveries.Fallback)

---@class CoachSharedMesh
---@field name string
---@field model Model
---@field material Material
---@field shadows boolean
---@field vertices integer

-- Model持有FillModel导出的缓冲，模块再强持有Model；销毁车辆节点不能Dispose共享模型。
-- 缓存只有首节/普通车体、同型转向架和左右轮，不持有Scene或已销毁的车辆节点。
---@type table<string, CoachSharedMesh[]>
local bodyCache = {}
---@type CoachSharedMesh[]
local bogieCache = {}
---@type table<number, CoachSharedMesh>
local wheelCache = {}

---@class CoachBatches
---@field white GeoBuilder
---@field blue GeoBuilder
---@field roof GeoBuilder
---@field dark GeoBuilder
---@field steel GeoBuilder
---@field rubber GeoBuilder
---@field glass GeoBuilder
---@field detail GeoBuilder
---@field stripe GeoBuilder 车队特征条
---@field door GeoBuilder 车门扇
---@field accent GeoBuilder 点缀件

---@return CoachBatches
local function NewBatches()
    return {
        white = MeshUtils.NewBuilder(), blue = MeshUtils.NewBuilder(),
        roof = MeshUtils.NewBuilder(), dark = MeshUtils.NewBuilder(),
        steel = MeshUtils.NewBuilder(), rubber = MeshUtils.NewBuilder(),
        glass = MeshUtils.NewBuilder(), detail = MeshUtils.NewBuilder(),
        stripe = MeshUtils.NewBuilder(), door = MeshUtils.NewBuilder(),
        accent = MeshUtils.NewBuilder(),
    }
end

---@param path string
---@param color Color
---@param metallic number
---@param roughness number
---@param normalPath? string
---@param clamp? boolean
---@return Material
local function Textured(path, color, metallic, roughness, normalPath, clamp)
    -- PBRDiff/PBRDiffNormal是文档指定的纹理Technique，不使用猜测路径。
    local diffuse = cache:GetResource("Texture2D", path)
    if not diffuse then
        print("[Coach] 贴图缺失，回退到PBR纯色材质：" .. path)
        return Materials.Solid(color, metallic, roughness)
    end
    if normalPath and not MeshUtils.SupportsTangents() then normalPath = nil end
    local material = Material:new()
    local techniquePath = normalPath and "Techniques/PBR/PBRDiffNormal.xml"
        or "Techniques/PBR/PBRDiff.xml"
    material:SetTechnique(0, cache:GetResource("Technique", techniquePath))
    diffuse:SetSRGB(true)
    diffuse:SetFilterMode(FILTER_ANISOTROPIC)
    diffuse:SetAnisotropy(4)
    diffuse:SetAddressMode(COORD_U, clamp and ADDRESS_CLAMP or ADDRESS_WRAP)
    diffuse:SetAddressMode(COORD_V, clamp and ADDRESS_CLAMP or ADDRESS_WRAP)
    material:SetTexture(TU_DIFFUSE, diffuse)
    if normalPath then
        local normal = cache:GetResource("Texture2D", normalPath)
        normal:SetSRGB(false)
        normal:SetFilterMode(FILTER_ANISOTROPIC)
        material:SetTexture(TU_NORMAL, normal)
    end
    material:SetShaderParameter("MatDiffColor", Variant(color))
    material:SetShaderParameter("MatSpecColor", Variant(Color(.5, .5, .5, 1)))
    material:SetShaderParameter("Metallic", Variant(metallic))
    material:SetShaderParameter("Roughness", Variant(roughness))
    return material
end

---@return CoachMaterials
local function GetMaterials()
    local cached = materialCache[livery_.id]
    if cached then return cached end
    local paint = "Textures/Railway/coach_paint.png"
    local normal = "Textures/Railway/coach_paint_normal.png"
    local steel = "Textures/Railway/coach_steel.png"
    local l = livery_
    ---@param v number[]
    ---@return number, number, number
    local function rgb(v) return assert(v[1]), assert(v[2]), assert(v[3]) end
    local materials = {
        white = Textured(paint, Color(rgb(l.body)), .05, .43, normal),
        blue = Textured(paint, Color(rgb(l.skirt)), .07, .40, normal),
        stripe = Textured(paint, Color(rgb(l.stripe)), .10, .38, normal),
        roof = Textured(steel, Color(rgb(l.roof)), .38, .56),
        dark = Textured(steel, Color(.18, .20, .21), .30, .68),
        steel = Textured(steel, Color(.66, .70, .72), .75, .37),
        rubber = Materials.Solid(Color(.038, .045, .050), 0, .89),
        -- 真实窗洞中的不透明深色玻璃，避免透明排序及白色衬底。
        glass = Textured("Textures/Railway/coach_glass.png", Color(1, 1, 1), .12, .16, nil, true),
        detail = Textured("FictionalLiveries/Yunzhou_C24_detail_D.png", Color(.95, .97, .97), .12, .60, nil, true),
        door = Textured(paint, Color(rgb(l.door)), .08, .41, normal),
        accent = Textured(paint, Color(rgb(l.accent)), .16, .36, normal),
    }
    materialCache[livery_.id] = materials
    return materials
end

-- 利用MeshUtils标准构建器的顶点法线/UV数组做局部扩展，
-- 不修改共享工具，也不为每个细节新增节点。
---@param b GeoBuilder
---@param a Vector3
---@param c Vector3
---@param d Vector3
---@param e Vector3
---@param u0? number
---@param v0? number
---@param u1? number
---@param v1? number
local function QuadUV(b, a, c, d, e, u0, v0, u1, v1)
    local first = b:Count()
    b:AddQuad(a, c, d, e)
    local left, top = u0 or 0, v0 or 0
    local right, bottom = u1 or 1, v1 or 1
    b.uvs[first + 1] = Vector2(left, top)
    b.uvs[first + 2] = Vector2(right, top)
    b.uvs[first + 3] = Vector2(right, bottom)
    b.uvs[first + 4] = Vector2(left, top)
    b.uvs[first + 5] = Vector2(right, bottom)
    b.uvs[first + 6] = Vector2(left, bottom)
end

---@param b GeoBuilder
---@param x number
---@param y number
---@param z number
---@param w number
---@param h number
---@param length number
local function Box(b, x, y, z, w, h, length)
    b:AddBox(Vector3(x, y, z), Vector3(w, h, length))
end

-- 圆柱/连接杆直接烘焙到合批网格，轴向采用引擎空间坐标。
---@param b GeoBuilder
---@param start Vector3
---@param finish Vector3
---@param radius number
---@param segments? integer
---@param caps? boolean 相邻弹簧段省略被遮住的内部端盖，首尾段仍封口。
local function Rod(b, start, finish, radius, segments, caps)
    local axis = (finish - start):Normalized()
    local reference = math.abs(axis.y) > .9 and Vector3.RIGHT or Vector3.UP
    local u = axis:CrossProduct(reference):Normalized()
    local v = axis:CrossProduct(u):Normalized()
    -- 亚厘米扶手无需12/14边；保留输入的更低分段和圆柱半径，不变成方盒。
    local count = math.min(segments or 8, radius >= .08 and 8 or 6)
    for i = 1, count do
        local t0, t1 = (i - 1) * 2 * math.pi / count, i * 2 * math.pi / count
        local n0 = u * math.cos(t0) + v * math.sin(t0)
        local n1 = u * math.cos(t1) + v * math.sin(t1)
        local a, c = start + n0 * radius, finish + n0 * radius
        local d, e = finish + n1 * radius, start + n1 * radius
        local first = b:Count()
        QuadUV(b, a, e, d, c, (i - 1) / count, 0, i / count, (finish - start):Length() * 2)
        b.norms[first + 1], b.norms[first + 2], b.norms[first + 3] = n0, n1, n1
        b.norms[first + 4], b.norms[first + 5], b.norms[first + 6] = n0, n1, n0
        if caps ~= false then
            b:AddTri(start, e, a)
            b:AddTri(finish, c, d)
        end
    end
end

-- 沿现有GeoBuilder一次性生成样板，再由引擎FillModel导出完整法线/UV/切线。
-- 不用GetVertex改指针字段，不手写索引布局；后续Build只复用Model，不能Clone复制VB。
---@param b GeoBuilder
---@param name string
---@param material Material
---@param shadows? boolean
---@return CoachSharedMesh
local function BakeMesh(b, name, material, shadows)
    local count = b:Count()
    assert(count > 0 and count % 3 == 0, "[Coach] 样板三角形顶点数无效")
    local scratch = Node()
    scratch.enabled = false
    local model = Model()
    local ok, message = pcall(function()
        assert(b:CommitTo(scratch, material) == count, "[Coach] 样板提交顶点不完整")
        local geometry = assert(scratch:GetComponent("CustomGeometry"))
        assert(geometry:FillModel(model), "[Coach] CustomGeometry导出Model失败")
        assert(model.numGeometries == 1 and model:GetGeometry(0, 0).vertexCount == count,
            "[Coach] 共享Model几何不完整")
        assert(model:SetGeometryCenter(0, model.boundingBox.center), "[Coach] 共享Model中心设置失败")
    end)
    -- FillModel输出由Model拥有，不与临时CustomGeometry生命周期绑定。
    scratch:RemoveAllComponents()
    scratch:Dispose()
    if not ok then model:Dispose(); error(tostring(message)) end
    return {name=name, model=model, material=material, shadows=shadows ~= false, vertices=count}
end

---@param b CoachBatches
---@param prefix string
---@return CoachSharedMesh[]
local function BakeBatches(b, prefix)
    local m = GetMaterials()
    local result = {} ---@type CoachSharedMesh[]
    local function append(builder, suffix, material, shadows)
        if builder:Count() > 0 then
            result[#result + 1] = BakeMesh(builder, prefix .. suffix, material, shadows)
        end
    end
    append(b.white, "PaintWhite", m.white, true)
    append(b.blue, "PaintBlue", m.blue, true)
    append(b.stripe, "LiveryStripe", m.stripe, true)
    append(b.door, "DoorLeaf", m.door, true)
    append(b.accent, "LiveryAccent", m.accent, true)
    append(b.roof, "RoofSteel", m.roof, true)
    append(b.dark, "Underframe", m.dark, true)
    append(b.steel, "MetalDetails", m.steel, true)
    append(b.rubber, "Rubber", m.rubber, true)
    append(b.glass, "Glazing", m.glass, false)
    append(b.detail, "Engineering", m.detail, false)
    return result
end

---@param node Node
---@param mesh CoachSharedMesh
local function AttachMesh(node, mesh)
    local drawable = node:CreateComponent("StaticModel")
    drawable.model = mesh.model
    drawable:SetMaterial(mesh.material)
    drawable.castShadows = mesh.shadows
    drawable.viewMask = 1
end

---@param meshes CoachSharedMesh[]
---@param parent Node
---@return integer
local function AttachBatches(meshes, parent)
    local count = 0
    for _, mesh in ipairs(meshes) do
        AttachMesh(parent:CreateChild(mesh.name), mesh)
        count = count + mesh.vertices
    end
    return count
end

---@param y number
---@return number
local function ShellX(y)
    -- 下部内收斜面平滑接入宽3.10米的竖直侧壁。
    if y < 1.49 then return 1.40 + (y - 1.30) / .19 * .15 end
    return 1.55
end

---@param b GeoBuilder
---@param side number
---@param z0 number
---@param z1 number
---@param y0 number
---@param y1 number
local function SidePanel(b, side, z0, z1, y0, y1)
    local xa, xb = side * ShellX(y0), side * ShellX(y1)
    if side > 0 then
        QuadUV(b, Vector3(xa, y0, z0), Vector3(xb, y1, z0),
            Vector3(xb, y1, z1), Vector3(xa, y0, z1),
            z0 * .35, -y0 * .35, z1 * .35, -y1 * .35)
    else
        QuadUV(b, Vector3(xa, y0, z1), Vector3(xb, y1, z1),
            Vector3(xb, y1, z0), Vector3(xa, y0, z0),
            z1 * .35, -y0 * .35, z0 * .35, -y1 * .35)
    end
end

---@class CoachOpening
---@field z0 number
---@field z1 number
---@field y0 number
---@field y1 number
---@field door boolean

---@return CoachOpening[]
local function Openings()
    ---@type CoachOpening[]
    local openings = { {z0=-11.10,z1=-10.20,y0=1.50,y1=3.30,door=true} }
    for i = 1, 11 do
        local z = (i - 6) * 1.73
        openings[#openings + 1] = {z0=z-.67,z1=z+.67,y0=2.25,y1=3.29,door=false}
    end
    openings[#openings + 1] = {z0=10.20,z1=11.10,y0=1.50,y1=3.30,door=true}
    return openings
end

---@param b CoachBatches
---@param openings CoachOpening[]
local function BuildShell(b, openings)
    ---@type number[]
    local rows = {1.30, 1.49, 1.50, 1.98, 2.10, 2.25, 3.29, 3.30, 3.47}
    for _, side in ipairs({-1, 1}) do
        for i = 1, #rows - 1 do
            local y0 = assert(rows[i])
            local y1 = assert(rows[i + 1])
            local mid = (y0 + y1) * .5
            local batch = mid < 1.98 and b.blue or b.white
            local cursor = -12.0
            for _, opening in ipairs(openings) do
                if mid > opening.y0 and mid < opening.y1 then
                    if opening.z0 > cursor then SidePanel(batch, side, cursor, opening.z0, y0, y1) end
                    cursor = opening.z1
                end
            end
            if cursor < 12 then SidePanel(batch, side, cursor, 12, y0, y1) end
        end
        -- 细腰线、雨槽及焊接分缝，不使用包围整车的色块盒子。
        Box(b.steel, side * 1.553, 2.105, 0, .018, .024, 23.96)
        -- 车队特征条：上窄下宽双带，属于该机车专属客车队，颜色来自涂装表。
        Box(b.stripe, side * 1.550, 3.455, 0, .022, .040, 23.94)
        Box(b.stripe, side * 1.551, 2.230, 0, .020, .055, 23.94)
        Box(b.accent, side * 1.552, 2.155, 0, .016, .022, 23.94)
        for _, z in ipairs({-9.45, -5.19, -1.73, 1.73, 5.19, 9.45}) do
            Box(b.dark, side * 1.552, 1.73, z, .006, .36, .008)
        end
    end
    -- 地板为车轮上方的薄板，不使用贯穿轮子的整段深底架。
    Box(b.dark, 0, 1.365, 0, 2.80, .13, 23.88)
    for _, side in ipairs({-1, 1}) do
        Box(b.dark, side * 1.35, 1.385, 0, .13, .17, 23.65)
    end

    -- 椭圆弧形车顶与侧顶过渡连续扫掠，使用平滑顶点法线。
    local segments = 32
    for i = 1, segments do
        local t0 = -math.pi * .5 + (i - 1) * math.pi / segments
        local t1 = -math.pi * .5 + i * math.pi / segments
        local x0, y0 = 1.55 * math.sin(t0), 3.47 + .61 * math.cos(t0)
        local x1, y1 = 1.55 * math.sin(t1), 3.47 + .61 * math.cos(t1)
        local n0 = Vector3(math.sin(t0) / 1.55, math.cos(t0) / .61, 0):Normalized()
        local n1 = Vector3(math.sin(t1) / 1.55, math.cos(t1) / .61, 0):Normalized()
        local first = b.roof:Count()
        QuadUV(b.roof, Vector3(x0,y0,-12), Vector3(x0,y0,12),
            Vector3(x1,y1,12), Vector3(x1,y1,-12), 0,(i-1)/segments*2,12,i/segments*2)
        b.roof.norms[first+1], b.roof.norms[first+2], b.roof.norms[first+3] = n0,n0,n1
        b.roof.norms[first+4], b.roof.norms[first+5], b.roof.norms[first+6] = n0,n1,n1
        for _, sign in ipairs({-1, 1}) do
            local centre = Vector3(0,3.47,sign*12)
            local a, c = Vector3(x0,y0,sign*12), Vector3(x1,y1,sign*12)
            if sign > 0 then b.white:AddTri(centre,c,a) else b.white:AddTri(centre,a,c) end
        end
    end
end

---@param b GeoBuilder
---@param side number
---@param x number
---@param z0 number
---@param z1 number
---@param y0 number
---@param y1 number
---@param u0? number
---@param v0? number
---@param u1? number
---@param v1? number
local function SideFace(b, side, x, z0, z1, y0, y1, u0, v0, u1, v1)
    if side > 0 then
        QuadUV(b,Vector3(x,y1,z0),Vector3(x,y1,z1),Vector3(x,y0,z1),Vector3(x,y0,z0),u0,v0,u1,v1)
    else
        QuadUV(b,Vector3(x,y1,z1),Vector3(x,y1,z0),Vector3(x,y0,z0),Vector3(x,y0,z1),u0,v0,u1,v1)
    end
end

---@param b CoachBatches
---@param openings CoachOpening[]
local function BuildWindowsAndDoors(b, openings)
    for _, side in ipairs({-1, 1}) do
        for _, opening in ipairs(openings) do
            local z0,z1,y0,y1 = opening.z0,opening.z1,opening.y0,opening.y1
            local z,y = (z0+z1)*.5,(y0+y1)*.5
            local width,height = z1-z0,y1-y0
            -- 四侧窗洞内缘连接外蒙皮x1.55与内凹玻璃x1.50。
            Box(b.rubber,side*1.524,y0+.015,z,.055,.030,width)
            Box(b.rubber,side*1.524,y1-.015,z,.055,.030,width)
            Box(b.rubber,side*1.524,y,z0+.015,.055,height,.030)
            Box(b.rubber,side*1.524,y,z1-.015,.055,height,.030)
            -- 18毫米不锈钢细框围绕玻璃，而不遮盖整块玻璃。
            Box(b.steel,side*1.554,y0,z,.025,.018,width+.028)
            Box(b.steel,side*1.554,y1,z,.025,.018,width+.028)
            Box(b.steel,side*1.554,y,z0,.025,height,.018)
            Box(b.steel,side*1.554,y,z1,.025,height,.018)
            if not opening.door then
                SideFace(b.glass,side,side*1.507,z0+.032,z1-.032,y0+.032,y1-.032)
                -- 上部可开启窗条及薄窗台明确每扇窗的独立尺度。
                Box(b.steel,side*1.532,y1-.23,z,.016,.014,width-.06)
                Box(b.steel,side*1.575,y0-.025,z,.064,.022,width+.025)
            else
                -- 实心门扇单独留上部窗洞，不在门玻璃后面铺白板。
                Box(b.door,side*1.509,1.84,z,.033,.64,width-.065)
                Box(b.door,side*1.509,2.35,z,.033,.38,width-.065)
                Box(b.door,side*1.509,3.215,z,.033,.13,width-.065)
                Box(b.door,side*1.509,2.82,z0+.10,.033,.65,.13)
                Box(b.door,side*1.509,2.82,z1-.10,.033,.65,.13)
                -- 门缝两侧点缀色，让不同客车队的车门在远处也能区分。
                Box(b.accent,side*1.509,1.84,z0+.035,.036,.64,.03)
                Box(b.accent,side*1.509,1.84,z1-.035,.036,.64,.03)
                SideFace(b.glass,side,side*1.516,z0+.18,z1-.18,2.55,3.12)
                Box(b.steel,side*1.538,2.54,z,.022,.021,width-.30)
                Box(b.steel,side*1.538,3.13,z,.022,.021,width-.30)
                Rod(b.steel,Vector3(side*1.563,2.22,z1-.15),Vector3(side*1.563,2.38,z1-.15),.015,6)
                -- 三层防滑踏板位于最近车轮外廓以外。
                for k = 1, 3 do
                    local stairY = .91 + (k-1)*.19
                    local stairX = side*(1.63-(k-1)*.075)
                    Box(b.dark,stairX,stairY,z,.31,.065,.80)
                    local xa,xb = stairX-.145,stairX+.145
                    QuadUV(b.detail,Vector3(xa,stairY+.034,z-.39),Vector3(xa,stairY+.034,z+.39),
                        Vector3(xb,stairY+.034,z+.39),Vector3(xb,stairY+.034,z-.39),.015,.515,.485,.985)
                end
                for _, dz in ipairs({-.48,.48}) do
                    Rod(b.dark,Vector3(side*1.43,.92,z+dz),Vector3(side*1.43,1.50,z+dz),.022,6)
                    Rod(b.steel,Vector3(side*1.585,1.72,z+dz),Vector3(side*1.585,3.08,z+dz),.017,8)
                end
                Box(b.blue,side*1.572,3.34,z,.08,.040,1.12)
            end
        end
        -- 图集铭牌和技术标记留UV边距，避免mipmap颜色串格。
        SideFace(b.detail,side,side*1.558,-.49,.49,1.63,1.96,.015,.015,.485,.485)
        SideFace(b.detail,side,side*1.557,6.52,7.61,1.65,1.96,.515,.515,.985,.985)
    end
end

---@param b CoachBatches
---@param index integer
local function BuildEnds(b, index)
    for _, sign in ipairs({-1, 1}) do
        local z = sign*11.955
        -- 端壁中间真实留出连通门，不把黑盒贴在实心端壁上。
        Box(b.white,-1.055,2.47,z,.99,2.0,.09)
        Box(b.white,1.055,2.47,z,.99,2.0,.09)
        Box(b.blue,0,1.405,z,2.84,.21,.09)
        Box(b.white,0,3.365,z,1.12,.21,.09)
        Box(b.blue,-1.055,1.75,sign*12.006,.99,.48,.012)
        Box(b.blue,1.055,1.75,sign*12.006,.99,.48,.012)
        -- 端部车队色带：连接处一眼分辨当前牵引车队。
        Box(b.stripe,0,3.365,sign*12.012,1.16,.13,.010)
        Box(b.accent,-1.32,2.30,sign*12.010,.10,1.30,.010)
        Box(b.accent,1.32,2.30,sign*12.010,.10,1.30,.010)
        -- 内凹的端部门扇以及独立小窗。
        Box(b.dark,0,1.98,sign*11.91,1.065,.92,.035)
        Box(b.dark,-.48,2.82,sign*11.91,.10,.76,.035)
        Box(b.dark,.48,2.82,sign*11.91,.10,.76,.035)
        Box(b.dark,0,3.20,sign*11.91,1.065,.10,.035)
        local paneZ = sign*11.935
        if sign > 0 then
            QuadUV(b.glass,Vector3(-.42,3.13,paneZ),Vector3(-.42,2.44,paneZ),
                Vector3(.42,2.44,paneZ),Vector3(.42,3.13,paneZ))
        else
            QuadUV(b.glass,Vector3(.42,3.13,paneZ),Vector3(.42,2.44,paneZ),
                Vector3(-.42,2.44,paneZ),Vector3(-.42,3.13,paneZ))
        end
        -- 橡胶风挡套与八道压缩褶，中央为中空矩形通道。
        for _, side in ipairs({-1, 1}) do
            Box(b.rubber,side*.625,2.465,sign*12.38,.17,1.90,.72)
        end
        Box(b.rubber,0,3.415,sign*12.38,1.42,.15,.72)
        Box(b.dark,0,1.515,sign*12.39,1.15,.07,.74)
        for i = 1, 8 do
            local ribZ = sign*(12.055+(i-1)*.095)
            Box(b.rubber,-.705,2.465,ribZ,.085,1.98,.055)
            Box(b.rubber,.705,2.465,ribZ,.085,1.98,.055)
            Box(b.rubber,0,3.445,ribZ,1.49,.080,.055)
        end
        Box(b.steel,-.752,2.465,sign*12.76,.035,1.96,.045)
        Box(b.steel,.752,2.465,sign*12.76,.035,1.96,.045)
        Box(b.steel,0,3.445,sign*12.76,1.54,.035,.045)
        -- 车钩尖位于正负12.80米，匹配1.60米车体间隙。
        local hookY = (index == 1 and sign > 0) and 1.42 or 1.04
        Box(b.dark,0,hookY,sign*12.23,.19,.17,.69)
        Box(b.steel,0,hookY,sign*12.64,.29,.24,.26)
        Box(b.dark,.10,hookY,sign*12.77,.13,.23,.06)
        Box(b.dark,-.085,hookY,sign*12.735,.07,.21,.12)
        if hookY > 1.1 then
            Box(b.dark,0,1.37,11.68,.48,.24,.48)
        else
            Box(b.dark,0,1.205,sign*11.81,.46,.23,.54)
        end
        -- 制动软管、端部扶手及缓冲盘保持合批。
        for _, side in ipairs({-1,1}) do
            Rod(b.rubber,Vector3(side*.40,1.36,sign*12.03),Vector3(side*.38,.91,sign*12.43),.027,8)
            Rod(b.steel,Vector3(side*1.05,1.88,sign*12.015),Vector3(side*1.05,2.92,sign*12.015),.017,8)
            Box(b.dark,side*.97,1.04,sign*12.11,.17,.17,.35)
            Box(b.steel,side*.97,1.04,sign*12.30,.30,.23,.055)
        end
    end
end

---@param b CoachBatches
local function BuildEquipment(b)
    -- 设备集中布置在两转向架之间，不使用穿过车轮的全宽设备盒。
    Box(b.dark,-.69,1.025,-3.40,.92,.50,2.15)
    Box(b.dark,.71,1.015,-.85,.88,.52,1.80)
    Box(b.dark,-.67,1.045,2.20,.95,.45,1.42)
    Rod(b.dark,Vector3(.59,1.04,2.30),Vector3(.59,1.04,4.55),.21,14)
    Rod(b.steel,Vector3(-.20,1.23,-5.60),Vector3(-.20,1.23,5.60),.045,8)
    for _, z in ipairs({-3.90,-2.88,-1.45,-.25,1.70,2.70}) do
        Box(b.steel,0,1.245,z,2.28,.07,.065)
    end
    for _, side in ipairs({-1,1}) do
        SideFace(b.detail,side,side*1.155,-4.37,-2.43,.87,1.22,.515,.015,.985,.485)
        for _, z in ipairs({-4.24,-2.58}) do
            Box(b.steel,side*1.163,1.14,z,.027,.17,.040)
        end
    end
    -- 低矮车顶进气罩放在侧顶肩部，最高点不超过4.10米。
    for _, z in ipairs({-4.60,4.60}) do
        for _, side in ipairs({-1,1}) do
            Box(b.roof,side*.91,3.965,z,.44,.18,1.44)
            SideFace(b.detail,side,side*1.136,z-.66,z+.66,3.92,4.04,.515,.015,.985,.485)
        end
    end
end

---@param b GeoBuilder
---@param x number
---@param y number
---@param z number
local function Spring(b, x, y, z)
    -- 五圈实体螺旋弹簧，钢丝直径28毫米，合入金属批次。
    local steps = 40
    for i = 1, steps do
        local t0,t1 = (i-1)*2*math.pi*5/steps,i*2*math.pi*5/steps
        Rod(b,Vector3(x+.066*math.cos(t0),y-.105+(i-1)*.21/steps,z+.066*math.sin(t0)),
            Vector3(x+.066*math.cos(t1),y-.105+i*.21/steps,z+.066*math.sin(t1)),.014,5,i == 1 or i == steps)
    end
end

---@param parent Node
---@param z number
---@param number integer
---@return CoachBogie
local function BuildBogie(parent, z, number)
    local pivot = parent:CreateChild("CoachBogie" .. number)
    pivot.position = Vector3(0,0,z)
    if #bogieCache > 0 then
        AttachBatches(bogieCache, pivot)
        return {node=pivot,z=z}
    end
    local b = NewBatches()
    -- 开放式H框架。轮心x.7175，侧框x1.015，不用板块遮住轮子。
    for _, side in ipairs({-1,1}) do
        Box(b.dark,side*1.015,1.10,0,.17,.18,3.22)
        Box(b.dark,side*1.015,.995,0,.13,.09,2.70)
        for _, axleZ in ipairs({-1.2,1.2}) do
            Box(b.dark,side*.997,.80,axleZ,.235,.27,.33)
            Rod(b.steel,Vector3(side*1.123,.80,axleZ),Vector3(side*1.153,.80,axleZ),.085,12)
            for _, dz in ipairs({-.22,.22}) do
                Spring(b.steel,side*1.015,1.065,axleZ+dz)
                Box(b.dark,side*1.015,.935,axleZ+dz,.20,.05,.19)
                Box(b.dark,side*1.015,1.195,axleZ+dz,.21,.045,.20)
            end
            -- 闸瓦位于踏面外侧少许，并连接横向制动拉杆。
            for _, dz in ipairs({-.49,.49}) do
                Box(b.dark,side*.735,.89,axleZ+dz,.095,.20,.060)
            end
        end
        Rod(b.rubber,Vector3(side*.69,1.18,0),Vector3(side*.69,1.28,0),.20,12)
        Rod(b.steel,Vector3(side*1.02,.98,-.57),Vector3(side*1.02,1.19,.15),.035,8)
        for _, dz in ipairs({-.53,.53}) do
            Box(b.steel,side*1.106,1.105,dz,.024,.08,.085)
        end
    end
    Box(b.dark,0,1.125,0,1.89,.16,.46)
    for _, axleZ in ipairs({-1.2,1.2}) do
        Rod(b.steel,Vector3(-1.00,.80,axleZ),Vector3(1.00,.80,axleZ),.065,12)
        Rod(b.dark,Vector3(-.90,.89,axleZ+.46),Vector3(.90,.89,axleZ+.46),.025,8)
    end
    bogieCache = BakeBatches(b, "Bogie")
    AttachBatches(bogieCache, pivot)
    return {node=pivot,z=z}
end

-- 铁路车轮分级剖面：轴向坐标/半径，轮缘在内侧。
-- 最大轮缘半径.478，踏面半径.46，中心x=+/-.7175。
-- 踏面轴向宽.15米，覆盖钢轨头中心x=+/-.7535。
---@type Vector2[]
local WHEEL_PROFILE = {
    Vector2(-.150,.095),Vector2(-.150,.19),Vector2(-.125,.22),Vector2(-.115,.38),Vector2(-.105,.478),
    Vector2(-.085,.478),Vector2(-.075,.46),Vector2(.075,.46),Vector2(.090,.39),Vector2(.037,.30),
    Vector2(.032,.18),Vector2(.123,.14),Vector2(.123,.095),
}

---@param parent Node
---@param side number
---@param axleZ number
---@return Node
local function BuildWheel(parent, side, axleZ)
    local wheel = parent:CreateChild("CoachWheel")
    wheel.position = Vector3(side*.7175,.80,axleZ)
    -- 网格已经烘焙成X轴轮轴，保留单位四元数作为自转基础朝向。
    wheel.rotation = Quaternion()
    local shared = wheelCache[side]
    if shared then
        AttachMesh(wheel, shared)
        return wheel
    end
    local b = MeshUtils.NewBuilder()
    -- 12边仍采到上下踏面极值、完整13点轮缘剖面；仅降低圆周细分。
    local segments = 12
    for j = 1, #WHEEL_PROFILE-1 do
        local p0 = assert(WHEEL_PROFILE[j])
        local p1 = assert(WHEEL_PROFILE[j + 1])
        for i = 1, segments do
            local t0,t1 = (i-1)*2*math.pi/segments,i*2*math.pi/segments
            local a = Vector3(side*p0.x,p0.y*math.cos(t0),p0.y*math.sin(t0))
            local c = Vector3(side*p1.x,p1.y*math.cos(t0),p1.y*math.sin(t0))
            local d = Vector3(side*p1.x,p1.y*math.cos(t1),p1.y*math.sin(t1))
            local e = Vector3(side*p0.x,p0.y*math.cos(t1),p0.y*math.sin(t1))
            local slopeX,slopeR = p1.x-p0.x,p1.y-p0.y
            local n0 = Vector3(-side*slopeR,slopeX*math.cos(t0),slopeX*math.sin(t0)):Normalized()
            local n1 = Vector3(-side*slopeR,slopeX*math.cos(t1),slopeX*math.sin(t1)):Normalized()
            local first = b:Count()
            if side > 0 then
                QuadUV(b,a,e,d,c,(i-1)/segments,0,i/segments,1)
                b.norms[first+1],b.norms[first+2],b.norms[first+3] = n0,n1,n1
                b.norms[first+4],b.norms[first+5],b.norms[first+6] = n0,n1,n0
            else
                QuadUV(b,a,c,d,e,(i-1)/segments,0,i/segments,1)
                b.norms[first+1],b.norms[first+2],b.norms[first+3] = n0,n0,n1
                b.norms[first+4],b.norms[first+5],b.norms[first+6] = n0,n1,n1
            end
        end
    end
    -- 外侧轮毂螺栓提供可见的转动参考，不额外增加节点。
    for i = 1, 6 do
        local angle = (i-1)*math.pi/3
        local y,z = .115*math.cos(angle),.115*math.sin(angle)
        Rod(b,Vector3(side*.124,y,z),Vector3(side*.144,y,z),.019,6)
    end
    local mesh = BakeMesh(b, side < 0 and "CoachWheelLeft" or "CoachWheelRight", GetMaterials().steel, true)
    wheelCache[side] = mesh
    AttachMesh(wheel, mesh)
    return wheel
end

--- 正式目录机车必须有独立成品；旧程序化样板仅供显式非目录工具使用。
---@param locomotiveId string
---@return boolean
function Coach.RequiresIndependentProfile(locomotiveId)
    local entry = Catalog.Find(locomotiveId)
    return entry ~= nil and entry.kind == "locomotive"
end

--- 只接受有生成来源记录且专属本机车的真实客车profile；不挪用动车或车头。
---@param locomotiveId string
---@return string|nil, string
function Coach.GetIndependentProfile(locomotiveId)
    local spec = CoachModels.Find(locomotiveId)
    if not spec or not spec.profileId then
        return nil, Coach.RequiresIndependentProfile(locomotiveId)
            and "正式车队缺少独立客车成品配置，禁止程序化代用" or "独立生成主体尚未交付"
    end
    if spec.locomotiveId ~= locomotiveId or spec.source ~= "generated_asset"
        or not spec.reviewConfirmed or not spec.assetId or spec.assetId == "" then
        return nil, "独立客车来源/用户确认记录不完整"
    end
    local profileId = spec.profileId
    local profile = Catalog.Profiles[profileId]
    if not profile or not Catalog.Assets[profileId] or not profile.verified
        or profile.pivot <= 0 then
        return nil, "独立客车缺少成品配置或轮轨校准"
    end
    if profile.expectedShape == "single_cab" then
        return nil, "独立客车端部不可是带驾驶室的单端机车"
    end
    for _, entry in ipairs(Catalog.Entries) do
        if entry.head == profileId or entry.middle == profileId then
            return nil, "禁止把既有车头/动车中间车冒充独立机车客车"
        end
        local usedProfiles = {entry.head}
        if entry.middle then usedProfiles[#usedProfiles+1] = entry.middle end
        for _, usedId in ipairs(usedProfiles) do
            local usedProfile, usedAsset = Catalog.Profiles[usedId], Catalog.Assets[usedId]
            if (usedProfile and usedProfile.modelId == profile.modelId)
                or (usedAsset and usedAsset.modelPath == Catalog.Assets[profileId].modelPath) then
                return nil, "独立客车不能仅为既有车头/动车资产改profile名字"
            end
        end
        if entry.roles then
            for _, role in ipairs({entry.roles.head,entry.roles.middle,entry.roles.tail}) do
                if role.profile == profileId then return nil, "禁止复用其他车型角色冒充独立客车" end
            end
        end
    end
    for otherId, other in pairs(CoachModels.ByLocomotive) do
        if otherId ~= locomotiveId then
            local otherProfile = other.profileId and Catalog.Profiles[other.profileId]
            local otherAsset = other.profileId and Catalog.Assets[other.profileId]
            if other.profileId == profileId or other.assetId == spec.assetId
                or (otherProfile and otherProfile.modelId == profile.modelId)
                or (otherAsset and otherAsset.modelPath == Catalog.Assets[profileId].modelPath) then
                return nil, "四款客车不得仅换色共享同一个生成主体"
            end
        end
    end
    return profileId, "真实独立生成客车已配置"
end

---@class CoachAssetStatus
---@field source string generated_asset|procedural_placeholder|unverified_asset
---@field accepted boolean
---@field message string
---@field profileId string|nil

---@param locomotiveId string
---@return CoachAssetStatus
function Coach.GetAssetStatus(locomotiveId)
    local profileId, message = Coach.GetIndependentProfile(locomotiveId)
    if not profileId then
        local spec = CoachModels.Find(locomotiveId)
        return {source=(Coach.RequiresIndependentProfile(locomotiveId) or (spec and spec.profileId))
                and "unverified_asset" or "procedural_placeholder",
            accepted=false,message=message}
    end
    -- 机车牵引客车靠车钩连接，不做动车式满宽风挡端面验收；
    -- 只要没有单端驾驶室(GetIndependentProfile已拒绝)且成品可用即视为可接入。
    if not RollingStock.IsAvailable(profileId) then
        return {source="unverified_asset",accepted=false,profileId=profileId,
            message="独立客车成品未交付或未包含在发布包"}
    end
    local profile = Catalog.Profiles[profileId]
    return {source="generated_asset",accepted=true,profileId=profileId,
        message="独立生成客车已交付，轮轨实测验收通过（" .. (profile and profile.description or "") .. "）"}
end

--- 正式目录缺少独立成品即失败，不能偷偷用程序化客车拼成“成功”编组。
---@param locomotiveId string
---@return boolean, string
function Coach.Prepare(locomotiveId)
    local spec = CoachModels.Find(locomotiveId)
    if not spec or not spec.profileId then
        if Coach.RequiresIndependentProfile(locomotiveId) then
            local _, message = Coach.GetIndependentProfile(locomotiveId)
            return false, message
        end
        return true, "显式非目录程序化样板"
    end
    local profileId, message = Coach.GetIndependentProfile(locomotiveId)
    if not profileId then return false, message end
    local available, reason = RollingStock.EnsureBakedAvailable(profileId)
    if not available then return false, reason end
    local status = Coach.GetAssetStatus(locomotiveId)
    if not status.accepted then return false, status.message end
    return RollingStock.Prepare(profileId)
end

--- 切换客车队涂装。几何缓冲与转向架/车轮共享缓存不随车队重建；
--- 此缓存只属于程序代用，不代表已交付四个独立生成主体。
---@param locomotiveId string|nil 机车内部 ID
---@return string 实际生效的涂装名
function Coach.SelectLivery(locomotiveId)
    local livery = CoachLiveries.Get(locomotiveId)
    if livery.id ~= livery_.id then
        livery_ = livery
        bodyCache = {}
    end
    return livery.name
end

---@return string
function Coach.GetLiveryName() return livery_.name end
---@return string
function Coach.GetLiveryId() return livery_.id end

--- 在已有车辆父节点下构建，不改变父节点的位置或旋转。
--- forwardSign由Train决定动画方向；模型始终朝局部+Z，负值不会翻转车体。
--- 车轮自转：node.rotation = Quaternion(angleDegrees,Vector3.RIGHT) * base。
--- 转向架轨道定位和转向由Train使用返回的枢轴z完成。
---@param parent Node
---@param index integer 首节客车为1，其+Z端车钩y1.42，其余端车钩y1.04。
---@param forwardSign? number 动画方向策略，默认为+1。
---@param locomotiveId? string 使用此机车已确认的独立客车；省略时沿用所选客车队。
---@return CoachBuildResult
function Coach.Build(parent, index, forwardSign, locomotiveId)
    local fleetId = locomotiveId or livery_.id
    local spec = CoachModels.Find(fleetId)
    -- 在写标签/创建网格之前拒绝缺配置，保证直接调用Build也不能绕过正式目录策略。
    assert(not Coach.RequiresIndependentProfile(fleetId) or (spec and spec.profileId),
        "正式车队缺少独立客车成品配置，禁止程序化代用")
    parent:SetVar("DisplayName", Variant(FictionalWorld.coachName))
    parent:SetVar("LiveryName", Variant(livery_.name))
    parent:SetVar("FleetNumber", Variant(string.format("%s-%02d", livery_.code, index)))
    if spec and spec.profileId then
        local ok, message = Coach.Prepare(fleetId)
        assert(ok, message)
        local profileId = assert(Coach.GetIndependentProfile(fleetId))
        local assetNode, drawable = RollingStock.Build(parent, profileId)
        local asset = assert(Catalog.Assets[profileId])
        assert(drawable.model and drawable.model == cache:GetResource("Model", asset.modelPath),
            "独立客车实际MDL绑定与交付成品不一致")
        parent:SetVar("CoachAssetSource", Variant("generated_asset"))
        parent:SetVar("CoachProfile", Variant(profileId))
        print(string.format("[Coach] %s 第%d节：独立生成成品 %s；共享MDL，不重建车体或叠加程序轮组",
            fleetId,index,profileId))
        -- 此独立成品包含真实轮组；没有分离部件时不能再加旧Coach轮/底架假装动画。
        return {wheels={},bogies={},wheelRadius=Coach.WheelRadius,assetNode=assetNode,drawable=drawable}
    end
    parent:SetVar("CoachAssetSource", Variant("procedural_placeholder"))
    parent:SetVar("CoachProfile", Variant("coach"))
    -- 唯一几何差异是首节+Z端高车钩；不是按每个车号复制整个车体缓冲。
    local key = index == 1 and "first" or "standard"
    local meshes = bodyCache[key]
    if not meshes then
        local b = NewBatches()
        local openings = Openings()
        BuildShell(b,openings)
        BuildWindowsAndDoors(b,openings)
        BuildEnds(b,index)
        BuildEquipment(b)
        meshes = BakeBatches(b, "Coach")
        bodyCache[key] = meshes
    end
    local staticVertices = AttachBatches(meshes, parent)
    ---@type CoachBogie[]
    local bogies = {BuildBogie(parent,-Coach.BogieOffset,1),BuildBogie(parent,Coach.BogieOffset,2)}
    ---@type Node[]
    local wheels = {}
    for _, bogie in ipairs(bogies) do
        for _, axleZ in ipairs({-1.2,1.2}) do
            for _, side in ipairs({-1,1}) do
                wheels[#wheels+1] = BuildWheel(bogie.node,side,axleZ)
            end
        end
    end
    local bogieVertices = 0
    for _, mesh in ipairs(bogieCache) do bogieVertices = bogieVertices + mesh.vertices end
    local leftWheel, rightWheel = assert(wheelCache[-1]), assert(wheelCache[1])
    local totalVertices = staticVertices + 2 * bogieVertices + 4 * (leftWheel.vertices + rightWheel.vertices)
    print(string.format("[Coach] 第%d节：共享车体%d/整车%d顶点，0CG/%d StaticModel，2转向架/8独立X轴轮，方向%+.0f",
        index,staticVertices,totalVertices,#meshes + 2 * #bogieCache + 8,forwardSign or 1))
    return {wheels=wheels,bogies=bogies,wheelRadius=Coach.WheelRadius}
end

return Coach
