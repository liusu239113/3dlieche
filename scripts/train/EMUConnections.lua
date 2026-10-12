-- EMU风挡：只接受离线实测平端；随两车真实端面变形，不向World batch登记。
-- 基于3D scene scaffold的CustomGeometry/米制/PBR范式，Train独占节点和材质生命周期。
local FictionalWorld = require "config.FictionalWorld"
local Connections = {}

---@class EMUConnection
---@field node Node
---@field geometry CustomGeometry
---@field lead TrainCar
---@field following TrainCar
---@field gap number 实测端面间设计距离，含真实车钩包络所需距离
---@field ringA Vector3[]
---@field ringB Vector3[]
---@field centerA Vector3
---@field centerB Vector3
---@field length number
---@field yawDegrees number
---@field valid boolean
---@field message string
---@field localRingA? Vector3[]
---@field localRingB? Vector3[]
---@field rebuilds? integer

-- 连接视觉设计（不增加物理碰撞）：
--    前车实测rear       柔性折叠风挡       后车实测front
--    ┌──────┐A ~~~~~~~~~~~~~~~~~~ B┌──────┐
--    └──────┘                      └──────┘
-- A/B是各自车体LocalToWorld得到的端面；每个四角独立插值，弯道外侧伸长内侧压缩。
-- 首末环嵌入实测±0.18m截面，避免端面凹凸留下光缝；绝不把nose/BBox当平端。
-- 最大偏角/伸缩以当前线路验收；退化或超范围显式诊断，不能静默变成数十米黑管。
local FOLDS = 18
Connections.FoldSegments = FOLDS
local SHRINK = .94

---@return Material
function Connections.CreateMaterial()
    local material = Material:new()
    material:SetTechnique(0, assert(cache:GetResource("Technique", "Techniques/PBR/PBRNoTexture.xml")))
    material:SetShaderParameter("MatDiffColor", Variant(Color(.075,.080,.086,1)))
    material:SetShaderParameter("Metallic", Variant(.02))
    material:SetShaderParameter("Roughness", Variant(.88))
    return material
end

---@return Material
function Connections.CreateIdentityMaterial()
    local material = Material:new()
    material:SetTechnique(0,assert(cache:GetResource("Technique","Techniques/NoTextureUnlit.xml")))
    material:SetShaderParameter("MatDiffColor",Variant(Color(.82,.78,.66,1)))
    return material
end

---@param car TrainCar
---@param face RollingStockEndFace
---@param inset? boolean
---@return Vector3
function Connections.EndCenter(car, face, inset)
    local c = face.center
    return car.node:LocalToWorld(Vector3(c.x,c.y,c.z-(inset and face.outward*face.slabDepth or 0)))
end

---@param car TrainCar
---@param face RollingStockEndFace
---@return Vector3[]
function Connections.EndRing(car, face)
    local c = face.center
    local x, y = face.width*.5*SHRINK, face.height*.5*SHRINK
    local z = c.z-face.outward*face.slabDepth
    return {
        car.node:LocalToWorld(Vector3(c.x-x,c.y-y,z)),
        car.node:LocalToWorld(Vector3(c.x+x,c.y-y,z)),
        car.node:LocalToWorld(Vector3(c.x+x,c.y+y,z)),
        car.node:LocalToWorld(Vector3(c.x-x,c.y+y,z)),
    }
end

---@param parent Node
---@param lead TrainCar
---@param following TrainCar
---@param gap number
---@param material Material
---@return EMUConnection
function Connections.Create(parent, lead, following, gap, material)
    assert(lead.rearEnd and following.frontEnd, "未实测连接端不得生成风挡")
    local node = parent:CreateChild("Gangway_" .. lead.number .. "_" .. following.number)
    local geometry = node:CreateComponent("CustomGeometry")
    geometry.dynamic, geometry.viewMask, geometry.castShadows = true, 1, true
    geometry.shadowDistance = 80
    geometry.material = material
    return {node=node,geometry=geometry,lead=lead,following=following,gap=gap,
        ringA={},ringB={},centerA=Vector3.ZERO,centerB=Vector3.ZERO,
        length=0,yawDegrees=0,valid=true,message="待更新"}
end

---@param geometry CustomGeometry
---@param a Vector3
---@param b Vector3
---@param c Vector3
local function triangle(geometry, a, b, c)
    local cross = (b-a):CrossProduct(c-a)
    local normal = cross:LengthSquared() > 1e-10 and cross:Normalized() or Vector3.UP
    for _, point in ipairs({a,b,c}) do geometry:DefineVertex(point); geometry:DefineNormal(normal) end
end

---@param connection EMUConnection
function Connections.Update(connection)
    local lead, following = connection.lead, connection.following
    local faceA, faceB = assert(lead.rearEnd), assert(following.frontEnd)
    local centerA, centerB = Connections.EndCenter(lead,faceA), Connections.EndCenter(following,faceB)
    local ringsA, ringsB = Connections.EndRing(lead,faceA), Connections.EndRing(following,faceB)
    connection.centerA, connection.centerB = centerA, centerB
    connection.ringA, connection.ringB = ringsA, ringsB
    connection.length = (centerB-centerA):Length()
    local dot = Clamp(lead.node.worldDirection:DotProduct(following.node.worldDirection),-1,1)
    connection.yawDegrees = math.deg(math.acos(dot))
    local valid = connection.length > .05 and connection.length <= connection.gap+.75
        and connection.yawDegrees <= 12
    if not valid and connection.valid then
        print(string.format("[EMUConnections] %s 超出验收伸缩/偏角：%.3fm / %.3f°", connection.node.name,
            connection.length,connection.yawDegrees))
    end
    connection.valid, connection.message = valid, valid and "实测端面风挡对齐" or "风挡伸缩或偏角超限"
    connection.geometry.enabled = valid
    if not valid then return end
    -- 小局部坐标提高大地图精度；所有顶点在Train子树，viewMask保持1。
    connection.node.worldPosition = (centerA+centerB)*.5
    connection.node.worldRotation = lead.node.worldRotation
    local geometry = connection.geometry
    local localA, localB = {}, {} ---@type Vector3[], Vector3[]
    local changed = not connection.localRingA or not connection.localRingB
    for k = 1, 4 do
        localA[k], localB[k] = connection.node:WorldToLocal(ringsA[k]), connection.node:WorldToLocal(ringsB[k])
        if connection.localRingA and connection.localRingB then
            if (localA[k] - connection.localRingA[k]):LengthSquared() > .000004
                or (localB[k] - connection.localRingB[k]):LengthSquared() > .000004 then changed = true end
        end
    end
    -- 直线整列平移只更新连接节点，不重新上传432个顶点；弯道/道岔真实变形才重建。
    if not changed then return end
    connection.localRingA, connection.localRingB = localA, localB
    connection.rebuilds = (connection.rebuilds or 0) + 1
    geometry:BeginGeometry(0, TRIANGLE_LIST)
    local previous = {} ---@type Vector3[]
    for i=0,FOLDS do
        local t = i/FOLDS
        local ring = {} ---@type Vector3[]
        local center = (localA[1]+localA[3])*.5+((localB[1]+localB[3])*.5-(localA[1]+localA[3])*.5)*t
        for k=1,4 do
            -- 在连接局部空间插值；69km世界坐标的float会把端环再量化约4mm。
            local point = localA[k]+(localB[k]-localA[k])*t
            local bulge = i>0 and i<FOLDS and (i%2==0 and .065 or -.060) or 0
            ring[k] = point+(point-center):Normalized()*bulge
        end
        if i>0 then
            for k=1,4 do
                local nextK = k%4+1
                triangle(geometry,previous[k],ring[k],previous[nextK])
                triangle(geometry,previous[nextK],ring[k],ring[nextK])
            end
        end
        previous = ring
    end
    geometry:Commit()
end

-- 小端面编号：七段数码仅0.19m高；不覆盖侧面原有涂装/车窗，不改材质或加屋顶盖板。
local DIGITS = {
    ["0"]={1,2,3,4,5,6}, ["1"]={2,3}, ["2"]={1,2,7,5,4},
    ["3"]={1,2,7,3,4}, ["4"]={6,7,2,3}, ["5"]={1,6,7,3,4},
    ["6"]={1,6,7,5,3,4}, ["7"]={1,2,3}, ["8"]={1,2,3,4,5,6,7}, ["9"]={1,2,3,4,6,7},
}
local SEGMENTS = {{0,.18,.075,.012},{.063,.096,.012,.072},{.063,.012,.012,.072},
    {0,0,.075,.012},{0,.012,.012,.072},{0,.096,.012,.072},{0,.090,.075,.012}}

---@param car TrainCar
---@param material Material
function Connections.BuildIdentity(car, material)
    local family = car.profile:match("^CRH380A") and "CRH380A" or "CR400AF"
    car.node:SetVar("DisplayName",Variant(FictionalWorld.trainNames[family]))
    car.node:SetVar("FleetNumber",Variant(FictionalWorld.trainCodes[family] .. "-" .. car.number))
    car.node:SetVar("CarNumber",Variant(car.number))
    car.node:SetVar("ServiceType",Variant(car.service))
    local face = car.rearEnd or car.frontEnd
    if not face then return end
    local identity = car.node:CreateChild("CarIdentity_" .. car.number .. "_" .. car.service)
    local geometry = identity:CreateComponent("CustomGeometry")
    geometry.viewMask, geometry.castShadows, geometry.material = 1, false, material
    geometry:BeginGeometry(0,TRIANGLE_LIST)
    local z = face.center.z+face.outward*.012
    local x0, y0 = face.center.x+.38, face.center.y+face.height*.32
    local function rect(x,y,w,h)
        local a,b,c,d = Vector3(x,y,z),Vector3(x+w,y,z),Vector3(x+w,y+h,z),Vector3(x,y+h,z)
        if face.outward>0 then triangle(geometry,a,b,c);triangle(geometry,a,c,d)
        else triangle(geometry,a,c,b);triangle(geometry,a,d,c) end
    end
    for index=1,#car.number do
        for _, segment in ipairs(DIGITS[car.number:sub(index,index)] or {}) do
            local s = SEGMENTS[segment]
            rect(x0+(index-1)*.10+s[1],y0+s[2],s[3],s[4])
        end
    end
    -- 七段车厢序号旁追加独立双棱航迹，不借用现实铁路/厂家徽记。
    local function diamond(x, y, radius)
        local a,b,c,d = Vector3(x,y+radius,z),Vector3(x+radius*.65,y,z),
            Vector3(x,y-radius,z),Vector3(x-radius*.65,y,z)
        local inner = radius*.62
        local aa,bb,cc,dd = Vector3(x,y+inner,z),Vector3(x+inner*.65,y,z),
            Vector3(x,y-inner,z),Vector3(x-inner*.65,y,z)
        local function strip(p,q,r,s)
            if face.outward>0 then triangle(geometry,p,q,r);triangle(geometry,p,r,s)
            else triangle(geometry,p,r,q);triangle(geometry,p,s,r) end
        end
        strip(a,b,bb,aa);strip(b,c,cc,bb);strip(c,d,dd,cc);strip(d,a,aa,dd)
    end
    diamond(x0-.13,y0+.10,.060)
    diamond(x0-.065,y0+.08,.060)
    local dots = car.service=="motor" and 2 or (car.service=="dining" and 3 or 1)
    for i=1,dots do rect(x0+(i-1)*.04,y0-.035,.022,.014) end
    geometry:Commit()
    -- 侧面只追加细线数码，不加底板/蒙皮；位置取已验证模型横向包络与实测端面，避免盖住窗带。
    local profile = require("config.TrainCatalog").Profiles[car.profile]
    if not profile then return end
    local sideGeometry = identity:CreateChild("SideNumber"):CreateComponent("CustomGeometry")
    sideGeometry.viewMask,sideGeometry.castShadows,sideGeometry.material=1,false,material
    sideGeometry:BeginGeometry(0,TRIANGLE_LIST)
    local baseZ = face.center.z-face.outward*.55
    local baseY = face.center.y+face.height*.43
    for _, sign in ipairs({-1,1}) do
        local x = sign*(profile.width*.5+.018)
        local function sideRect(z,y,w,h)
            local a,b,c,d=Vector3(x,y,z),Vector3(x,y,z+w),Vector3(x,y+h,z+w),Vector3(x,y+h,z)
            if sign<0 then triangle(sideGeometry,a,b,c);triangle(sideGeometry,a,c,d)
            else triangle(sideGeometry,a,c,b);triangle(sideGeometry,a,d,c) end
        end
        for index=1,#car.number do
            for _, segment in ipairs(DIGITS[car.number:sub(index,index)] or {}) do
                local s = SEGMENTS[segment]
                sideRect(baseZ+(index-1)*.10+s[1],baseY+s[2],s[3],s[4])
            end
        end
        for i=1,dots do sideRect(baseZ+(i-1)*.04,baseY-.035,.022,.014) end
    end
    sideGeometry:Commit()
end

return Connections
