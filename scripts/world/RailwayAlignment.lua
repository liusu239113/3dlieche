-- 纯铁路工程几何模块，不读取配置、场景、云服务或存档，也不触发渲染。
-- 单位米；Y向上，左手坐标：yaw=0朝+Z，正偏航/曲率向右转。
-- s为水平工程里程，不是存在纵坡时更长的三维行驶弧长。
--
-- 完整输入结构：
-- Build { segments={...}, start={x=0,y=0,z=0}, startYaw=0,
--   pointStep=10, integrationTolerance=1e-5, distanceTolerance=0.001,
--   profile={ startY=0, startGrade=0, segments={
--     {type="grade",length=100,grade=0},
--     {type="verticalCurve",length=200,endGrade=0.01}, ... } },
--   cant={ {s=0,cant=0}, {s=100,cant=0.10}, ... }, gauge=1.435 }
-- 平面线元（length>0，偏航角单位度，曲率单位弧度/米）：
--   {type="straight",length=...}
--   {type="arc",radius=...,angle=...,dir=1|-1} -- 长度=半径*弧度角
--   {type="arc",length=...,curvature=...}      -- 有符号非零曲率
--   {type="transition",length=...,k0=...,k1=...} -- 曲率随里程线性变化
-- 显式纵断面必须覆盖全线；坡度为dy/ds比值，不是千分数。
-- 竖曲线采用抛物线（坡度随s线性变化）；可选endY仅作一致性核验，
-- 不会静默扭曲测量输入。不传profile则保持start.y，纵坡为0。
-- 超高节点线性插值，节点范围外保持端值。
-- cant为左轨减右轨的高度差，单位米；正值使列车向右倾。
-- gauge是倾斜轨道横断面上两根参考钢轨之间的距离。
-- RightAt返回单位倾斜横向向量；SampleOffset的y仍沿世界Y向上，
-- 与Route兼容，不表示轨道法线距离。TangentAt包括纵坡分量。
-- Sample与Route一致，返回pos,tangent,yaw。查询里程钳制在[0,L]。
--
-- FromLegacySegments(defs,options)保留每个父段长度、有符号总角、
-- landmark与里程。每个圆弧改为对称的缓和/圆弧/缓和组合：
--   峰值曲率=有符号总角/(L-缓和长度)，中间圆弧长=L-2*缓和长度。
-- 各接缝位置和切向连续，但不保持原圆弧的XZ端点：固定长度和总角，
-- 同时要求两端曲率为0，不能再声称保留原圆弧端点。
-- GetSourceSegments保留straight/arc父段，供站场、桥隧包络使用；
-- GetSegments给出真实工程子线元。父段arc.radius为补偿后的峰值半径，
-- sourceRadius保留原半径；复合圆弧不伪造单一圆心。
--
-- 辛普森截断误差界：对f=exp(i*yaw)，四阶导数模上界为
-- K^4+6*K^2*|k'|+3*k'^2。积分单元按长度分配预算，因而全线XZ向量
-- 截断误差不大于integrationTolerance（不含浮点舍入误差）。
-- distanceTolerance必须大于2*integrationTolerance，保证局部求精收敛。
-- 积分和空间索引使用Lua双精度；Vector3输出可能受引擎单精度舍入影响，
-- 例如30公里坐标附近有数毫米误差，不能把积分界当成最终渲染坐标精度。
-- DistanceTo求全线XZ最近点，忽略输入y；返回真实曲线候选距离上界，
-- 与理想最小值之差不大于distanceTolerance+2*integrationTolerance，
-- 不含浮点舍入。BVH包络以K*h^2/8保守包住弦与曲线的偏差；
-- 局部分支定界求精，而非仅用折线弦估计距离。
-- Get系列返回缓存只读记录，调用方不得修改；所有输入均复制、不改原表。

---@class AlignmentElement
---@field type string
---@field s number
---@field length number
---@field x number
---@field z number
---@field heading number
---@field yaw number
---@field k0 number
---@field k1 number
---@field rate number
---@field radius number
---@field dir number
---@field sourceIndex integer
---@field landmark? string
---@field nodes table[]
---@field cellLength number
---@class RailwayAlignment
---@field _segments AlignmentElement[]
---@field _sources table[]
---@field _points table[]
---@field _profile table[]
---@field _cant table[]
---@field _length number
---@field _startY number
---@field _startGrade number
---@field _gauge number
---@field _integrationTolerance number
---@field _distanceTolerance number
---@field _bvh table
---@field _validation table
---@field Sample fun(self:RailwayAlignment,s:number):Vector3,Vector3,number
---@field SampleOffset fun(self:RailwayAlignment,s:number,lateral:number,y?:number):Vector3
---@field DistanceTo fun(self:RailwayAlignment,worldPos:Vector3|table):number,number
---@field RightAt fun(self:RailwayAlignment,s:number):Vector3
---@field TangentAt fun(self:RailwayAlignment,s:number):Vector3
---@field CurvatureAt fun(self:RailwayAlignment,s:number):number
---@field GradeAt fun(self:RailwayAlignment,s:number):number
---@field HeightAt fun(self:RailwayAlignment,s:number):number
---@field CantAt fun(self:RailwayAlignment,s:number):number
---@field GetLength fun(self:RailwayAlignment):number
---@field GetSourceSegments fun(self:RailwayAlignment):table[]
---@field GetSegments fun(self:RailwayAlignment):AlignmentElement[]
---@field GetPoints fun(self:RailwayAlignment):table[]
---@field GetValidationData fun(self:RailwayAlignment):table
local Alignment = {}
Alignment.__index = Alignment

local MAX_LENGTH, MAX_COORD, MAX_COUNT = 10000000, 100000000, 250000
local PI2 = 2 * math.pi

local function finite(v)
    return type(v) == "number" and v == v and v > -math.huge and v < math.huge
end

local function number(v, name, low, high)
    assert(finite(v), "[Alignment] " .. name .. " must be finite")
    assert((not low or v >= low) and (not high or v <= high), "[Alignment] " .. name .. " out of range")
    return v
end

local function positive(v, name, high)
    number(v, name, 0, high or MAX_LENGTH)
    assert(v > 0, "[Alignment] " .. name .. " must be positive")
    return v
end

local function array(t, name, allowEmpty)
    assert(type(t) == "table", "[Alignment] " .. name .. " must be an array")
    local count = #t
    assert((allowEmpty or count > 0) and count <= MAX_COUNT, "[Alignment] " .. name .. " invalid count")
    for key in pairs(t) do
        assert(type(key) == "number" and key % 1 == 0 and key >= 1 and key <= count,
            "[Alignment] " .. name .. " must be dense")
    end
    for i = 1, count do assert(type(t[i]) == "table", "[Alignment] " .. name .. " contains a hole/non-table") end
    return t
end

local function clamp(v, a, b) return math.max(a, math.min(b, v)) end

local function coordinates(v)
    assert(v ~= nil, "[Alignment] position missing")
    local ok, x, y, z = pcall(function() return v.x, v.y, v.z end)
    assert(ok, "[Alignment] position must expose x/y/z")
    return number(x, "position.x", -MAX_COORD, MAX_COORD),
        number(y, "position.y", -MAX_COORD, MAX_COORD), number(z, "position.z", -MAX_COORD, MAX_COORD)
end

local function sinc(x)
    if math.abs(x) < 1e-4 then return 1 - x*x/6 + x*x*x*x/120 end
    return math.sin(x) / x
end

---@param seg AlignmentElement
local function headingAt(seg, ds) return seg.heading + ds * (seg.k0 + 0.5 * seg.rate * ds) end

---@param seg AlignmentElement
local function integrateCell(seg, a, b)
    local h, mid = b-a, (a+b)*0.5
    local t0, tm, t1 = headingAt(seg,a), headingAt(seg,mid), headingAt(seg,b)
    return h/6*(math.sin(t0)+4*math.sin(tm)+math.sin(t1)),
        h/6*(math.cos(t0)+4*math.cos(tm)+math.cos(t1))
end

---@param seg AlignmentElement
local function planAt(seg, ds)
    local heading = headingAt(seg, ds)
    if seg.rate == 0 then
        local halfTurn = 0.5 * seg.k0 * ds
        local distance = ds * sinc(halfTurn)
        return seg.x + distance*math.sin(seg.heading+halfTurn),
            seg.z + distance*math.cos(seg.heading+halfTurn), heading
    end
    local i = math.min(#seg.nodes, math.floor(ds/seg.cellLength)+1)
    local node = seg.nodes[i]
    local dx, dz = integrateCell(seg, node.ds, ds)
    return node.x+dx, node.z+dz, heading
end

---@param seg AlignmentElement
local function integrate(seg, tolerancePerMetre)
    seg.nodes, seg.cellLength = {}, seg.length
    if seg.rate == 0 then return end
    local k, a = math.max(math.abs(seg.k0),math.abs(seg.k1)), math.abs(seg.rate)
    local fourthBound = k^4 + 6*k*k*a + 3*a*a
    local step = math.min(25, (2880*tolerancePerMetre/fourthBound)^0.25, 0.1/math.max(k,1e-12))
    local count = math.max(1,math.ceil(seg.length/step))
    assert(count <= MAX_COUNT, "[Alignment] integration budget exceeded")
    seg.cellLength = seg.length/count
    local x, z = seg.x, seg.z
    for i = 1, count do
        local ds = (i-1)*seg.cellLength
        seg.nodes[i] = {ds=ds,x=x,z=z}
        local dx, dz = integrateCell(seg,ds,i*seg.cellLength)
        x, z = x+dx, z+dz
    end
end

local function readDefinition(def)
    local kind = def.type
    assert(kind == "straight" or kind == "arc" or kind == "transition", "[Alignment] unknown segment type")
    local length, k0, k1 = 0.0, 0.0, 0.0
    if kind == "arc" and def.radius ~= nil then
        local radius = positive(def.radius,"radius",MAX_COORD)
        local dir = def.dir == nil and 1 or number(def.dir,"dir",-1,1)
        assert(dir == 1 or dir == -1,"[Alignment] dir must be +1 or -1")
        local angle = positive(def.angle,"angle",360)
        length, k0, k1 = radius*math.rad(angle), dir/radius, dir/radius
        if def.length ~= nil then
            assert(math.abs(number(def.length,"arc.length")-length) <= math.max(1e-8,length*1e-12),
                "[Alignment] arc length disagrees with radius/angle")
        end
    else
        length = positive(def.length,"length")
        if kind == "arc" then
            k0 = number(def.curvature,"curvature",-1,1)
            assert(k0 ~= 0,"[Alignment] zero curvature arc: use straight")
            k1 = k0
        elseif kind == "transition" then
            k0, k1 = number(def.k0,"k0",-1,1), number(def.k1,"k1",-1,1)
        end
    end
    positive(length,"derived length")
    assert(math.abs(0.5*(k0+k1)*length) <= PI2+1e-10,"[Alignment] element turn exceeds 360 degrees")
    return length, k0, k1
end

function Alignment:_buildProfile(profile)
    self._profile, self._startGrade = {}, 0.0
    if profile == nil then return end
    assert(type(profile)=="table","[Alignment] profile must be a table")
    self._startY = number(profile.startY or self._startY,"profile.startY",-MAX_COORD,MAX_COORD)
    self._startGrade = number(profile.startGrade or 0,"profile.startGrade",-1,1)
    local s, y, grade = 0.0, self._startY, self._startGrade
    for _, def in ipairs(array(profile.segments,"profile.segments")) do
        local length = positive(def.length,"profile.length")
        assert(def.type == "grade" or def.type == "verticalCurve","[Alignment] unknown profile type")
        local endGrade = grade
        if def.type == "grade" then
            if def.grade ~= nil then
                endGrade = number(def.grade,"profile.grade",-1,1)
                assert(math.abs(endGrade-grade)<1e-12,"[Alignment] grade break requires a verticalCurve")
            end
        else endGrade = number(def.endGrade,"profile.endGrade",-1,1) end
        local rate = (endGrade-grade)/length
        self._profile[#self._profile+1] = {s=s,length=length,y=y,grade=grade,rate=rate}
        local endY = y+0.5*(grade+endGrade)*length
        number(endY,"profile end elevation",-MAX_COORD,MAX_COORD)
        if def.endY ~= nil then
            assert(math.abs(number(def.endY,"profile.endY")-endY)<1e-7,"[Alignment] profile endY inconsistent with grades")
        end
        s, y, grade = s+length, endY, endGrade
    end
    assert(math.abs(s-self._length)<math.max(1e-7,self._length*1e-12),"[Alignment] profile must cover full length")
end

function Alignment:_buildCant(knots)
    self._cant = {}
    if knots == nil then return end
    local previous = -1.0
    for _, knot in ipairs(array(knots,"cant")) do
        local s = number(knot.s,"cant.s",0,self._length)
        assert(s>previous,"[Alignment] cant knots must increase")
        local cant = number(knot.cant,"cant height",-0.3,0.3)
        assert(math.abs(cant)*math.sqrt(1+self._startGrade^2)<self._gauge,
            "[Alignment] cant exceeds available gauge/grade frame")
        for _,p in ipairs(self._profile) do
            local maxGrade=math.max(math.abs(p.grade),math.abs(p.grade+p.rate*p.length))
            assert(math.abs(cant)*math.sqrt(1+maxGrade^2)<self._gauge,
                "[Alignment] cant exceeds available gauge/grade frame")
        end
        self._cant[#self._cant+1] = {s=s,cant=cant}
        previous = s
    end
end

local function chordDistance(qx,qz,ax,az,bx,bz)
    local dx,dz = bx-ax,bz-az
    local d2 = dx*dx+dz*dz
    local t = d2>0 and clamp(((qx-ax)*dx+(qz-az)*dz)/d2,0,1) or 0
    local ex,ez = ax+t*dx-qx,az+t*dz-qz
    return math.sqrt(ex*ex+ez*ez),t
end

local function boxDistance(box,x,z)
    local dx = math.max(box.minX-x,0,x-box.maxX)
    local dz = math.max(box.minZ-z,0,z-box.maxZ)
    return math.sqrt(dx*dx+dz*dz)
end

local function hierarchy(pieces)
    local minX,minZ,maxX,maxZ = math.huge,math.huge,-math.huge,-math.huge
    for _, p in ipairs(pieces) do
        minX,minZ,maxX,maxZ = math.min(minX,p.minX),math.min(minZ,p.minZ),math.max(maxX,p.maxX),math.max(maxZ,p.maxZ)
    end
    local node = {minX=minX,minZ=minZ,maxX=maxX,maxZ=maxZ}
    if #pieces == 1 then node.piece = pieces[1]; return node end
    local xAxis = maxX-minX > maxZ-minZ
    table.sort(pieces,function(a,b)
        return xAxis and a.minX+a.maxX < b.minX+b.maxX or (not xAxis and a.minZ+a.maxZ < b.minZ+b.maxZ)
    end)
    local left,right = {},{}
    for i,p in ipairs(pieces) do
        local target = i<=math.floor(#pieces/2) and left or right
        target[#target+1] = p
    end
    node.left,node.right = hierarchy(left),hierarchy(right)
    return node
end

function Alignment:_buildIndex()
    local pieces = {}
    for _, seg in ipairs(self._segments) do
        local k = math.max(math.abs(seg.k0),math.abs(seg.k1))
        local count = seg.type=="straight" and 1 or math.max(1,math.ceil(seg.length/math.min(128,0.15/math.max(k,1e-12))))
        assert(#pieces+count <= MAX_COUNT,"[Alignment] nearest-point index budget exceeded")
        for i = 1,count do
            local a,b = (i-1)*seg.length/count,i*seg.length/count
            local ax,az = planAt(seg,a)
            local bx,bz = planAt(seg,b)
            local margin = k*(b-a)^2/8 + 2*self._integrationTolerance + 1e-8
            pieces[#pieces+1] = {seg=seg,a=a,b=b,ax=ax,az=az,bx=bx,bz=bz,
                minX=math.min(ax,bx)-margin,maxX=math.max(ax,bx)+margin,
                minZ=math.min(az,bz)-margin,maxZ=math.max(az,bz)+margin}
        end
    end
    self._bvh = hierarchy(pieces)
    self._validation.indexPieces = #pieces
end

--- Build返回独立实例；没有模块单例，也不修改任何项目配置。
---@param spec table
---@return RailwayAlignment
function Alignment.Build(spec)
    assert(type(spec)=="table","[Alignment] Build expects a specification")
    local self = setmetatable({},Alignment)
    self:_init(spec)
    return self
end

function Alignment:_init(spec)
    self._segments,self._sources,self._points,self._validation = {},{},{},{}
    self._length,self._startY,self._startGrade = 0.0,0.0,0.0
    self._gauge = positive(spec.gauge or 1.435,"gauge",10)
    self._integrationTolerance = number(spec.integrationTolerance or 1e-5,"integrationTolerance",1e-10,0.1)
    self._distanceTolerance = number(spec.distanceTolerance or 0.001,"distanceTolerance",1e-6,1)
    assert(self._distanceTolerance>2*self._integrationTolerance,
        "[Alignment] distanceTolerance must exceed 2*integrationTolerance")
    local step = number(spec.pointStep or 10,"pointStep",0.5,1000)
    local start = spec.start or {x=0,y=0,z=0}
    local x,y,z = coordinates(start)
    self._startY = y
    local heading = math.rad(number(spec.startYaw or 0,"startYaw",-360000,360000))
    local definitions = array(spec.segments,"segments")
    assert(#definitions<=10000,"[Alignment] too many engineering elements")
    for i,def in ipairs(definitions) do
        local length,k0,k1 = readDefinition(def)
        self._segments[i] = {type=def.type,s=self._length,length=length,k0=k0,k1=k1,rate=(k1-k0)/length,
            x=0,z=0,heading=0,yaw=0,radius=k0==0 and 0 or 1/math.abs(k0),dir=k0<0 and -1 or 1,
            landmark=def.landmark,sourceIndex=def.sourceIndex or i,nodes={},cellLength=length}
        self._length = self._length+length
        positive(self._length,"total length")
    end
    for _,seg in ipairs(self._segments) do
        seg.x,seg.z,seg.heading,seg.yaw = x,z,heading,math.deg(heading)
        integrate(seg,self._integrationTolerance/self._length)
        x,z,heading = planAt(seg,seg.length)
        number(x,"end.x",-MAX_COORD,MAX_COORD); number(z,"end.z",-MAX_COORD,MAX_COORD)
    end
    self:_buildProfile(spec.profile)
    self:_buildCant(spec.cant)
    self._validation = {length=self._length,totalYaw=math.deg(heading)- (spec.startYaw or 0),
        integrationErrorBound=self._integrationTolerance,distanceErrorBound=self._distanceTolerance+2*self._integrationTolerance,
        startX=start.x,startZ=start.z,endX=x,endZ=z,elementCount=#self._segments,
        maxCurvatureJump=0.0,defaultFlat=spec.profile==nil,defaultCant=spec.cant==nil}
    for i,seg in ipairs(self._segments) do
        if i>1 then
            self._validation.maxCurvatureJump = math.max(self._validation.maxCurvatureJump, math.abs(seg.k0-self._segments[i-1].k1))
        end
        local count = math.max(1,math.ceil(seg.length/step))
        assert(#self._points+count+1 <= MAX_COUNT,"[Alignment] point cache budget exceeded")
        for j=1,count do self._points[#self._points+1] = self:PointAt(seg.s+(j-1)*seg.length/count) end
    end
    self._points[#self._points+1] = self:PointAt(self._length)
    self:_buildIndex()
    self._sources = self._segments
end

---@param definitions table[]
---@param options? table
---@return RailwayAlignment
function Alignment.fromSegments(definitions,options)
    local spec = {}
    for key,value in pairs(options or {}) do spec[key]=value end
    spec.segments = definitions
    return Alignment.Build(spec)
end
Alignment.FromSegments = Alignment.fromSegments

--- angle为正角度数；dir指定左右转，返回可复用的显式工程线元。
function Alignment.SymmetricCurve(length,angle,transitionLength,dir)
    positive(length,"symmetric.length")
    positive(angle,"symmetric.angle",360)
    positive(transitionLength,"transitionLength")
    assert(2*transitionLength<length,"[Alignment] transitions must leave a positive circular middle")
    dir = dir or 1
    assert(dir==1 or dir==-1,"[Alignment] symmetric dir must be +1 or -1")
    local k = dir*math.rad(angle)/(length-transitionLength)
    return {
        {type="transition",length=transitionLength,k0=0,k1=k},
        {type="arc",length=length-2*transitionLength,curvature=k},
        {type="transition",length=transitionLength,k0=k,k1=0},
    }
end

---@param definitions table[]
---@param options? table
---@return RailwayAlignment
function Alignment.FromLegacySegments(definitions,options)
    options = options or {}
    assert(type(options)=="table","[Alignment] legacy options must be a table")
    local requested = positive(options.transitionLength or 120,"transitionLength")
    local elements,parents = {},{}
    for i,def in ipairs(array(definitions,"legacy segments")) do
        assert(def.type=="straight" or def.type=="arc","[Alignment] legacy requires straight/arc")
        local length,k0 = readDefinition(def)
        local parent = {type=def.type,landmark=def.landmark,length=length,sourceIndex=i,
            firstElement=#elements+1,sourceRadius=def.radius or 0,angle=def.angle or 0,dir=k0<0 and -1 or 1}
        local expanded = {{type="straight",length=length}}
        if def.type=="arc" then
            assert(def.radius~=nil,"[Alignment] legacy arc requires radius/angle")
            local transition = math.min(requested,length*0.25)
            expanded = Alignment.SymmetricCurve(length,def.angle,transition,parent.dir)
            parent.transitionLength,parent.radius,parent.composite = transition,1/math.abs(expanded[2].curvature),true
        else parent.radius,parent.composite = 0,false end
        for _,element in ipairs(expanded) do
            element.landmark,element.sourceIndex = def.landmark,i
            elements[#elements+1] = element
        end
        parent.lastElement = #elements
        parents[#parents+1] = parent
    end
    local result = Alignment.fromSegments(elements,options)
    for _,parent in ipairs(parents) do
        local first = result._segments[parent.firstElement]
        parent.s,parent.yaw = first.s,first.yaw
        parent.pos = result:Sample(parent.s)
        parent.x,parent.z = first.x,first.z
        parent.endPos,parent.endTangent,parent.endYaw = result:Sample(first.s+parent.length)
    end
    result._sources = parents
    result._validation.sourceCount = #parents
    assert(result._validation.maxCurvatureJump<1e-12,"[Alignment] legacy smoothing curvature discontinuity")
    return result
end

function Alignment:GetLength() return self._length end
function Alignment:GetSegments() return self._segments end
function Alignment:GetSourceSegments() return self._sources end
function Alignment:GetPoints() return self._points end
function Alignment:GetValidationData() return self._validation end

function Alignment:Clamp(s) return clamp(number(s,"s"),0,self._length) end

---@return AlignmentElement, number
function Alignment:_elementAt(s)
    local lo,hi = 1,#self._segments
    while lo<hi do
        local mid = math.floor((lo+hi+1)/2)
        if self._segments[mid].s<=s then lo=mid else hi=mid-1 end
    end
    local seg = self._segments[lo]
    return seg,s-seg.s
end

function Alignment:_heightGrade(s)
    if #self._profile==0 then return self._startY,0 end
    local lo,hi=1,#self._profile
    while lo<hi do
        local mid=math.floor((lo+hi+1)/2)
        if self._profile[mid].s<=s then lo=mid else hi=mid-1 end
    end
    local p = self._profile[lo]
    local ds = s-p.s
    return p.y+p.grade*ds+0.5*p.rate*ds*ds, p.grade+p.rate*ds
end

function Alignment:HeightAt(s)
    local height=self:_heightGrade(self:Clamp(s))
    return height
end

function Alignment:GradeAt(s)
    local _,grade=self:_heightGrade(self:Clamp(s))
    return grade
end

function Alignment:CantAt(s)
    local at = self:Clamp(s)
    local knots=self._cant
    if #knots==0 then return 0 end
    if at<=knots[1].s then return knots[1].cant end
    if at>=knots[#knots].s then return knots[#knots].cant end
    local lo,hi=1,#knots
    while hi-lo>1 do
        local mid=math.floor((lo+hi)/2)
        if knots[mid].s<=at then lo=mid else hi=mid end
    end
    local a,b=knots[lo],knots[hi]
    return a.cant+(b.cant-a.cant)*(at-a.s)/(b.s-a.s)
end

function Alignment:CurvatureAt(s)
    local seg,ds=self:_elementAt(self:Clamp(s))
    return seg.k0+seg.rate*ds
end

---@return Vector3, Vector3, number
function Alignment:Sample(s)
    local at=self:Clamp(s)
    local seg,ds=self:_elementAt(at)
    local x,z,heading=planAt(seg,ds)
    local y,grade=self:_heightGrade(at)
    local norm=math.sqrt(1+grade*grade)
    return Vector3(x,y,z),Vector3(math.sin(heading)/norm,grade/norm,math.cos(heading)/norm),math.deg(heading)
end

function Alignment:TangentAt(s)
    local _,tangent=self:Sample(s)
    return tangent
end

function Alignment:RightAt(s)
    local at=self:Clamp(s)
    local seg,ds=self:_elementAt(at)
    local heading=headingAt(seg,ds)
    local grade=self:GradeAt(at)
    local norm=math.sqrt(1+grade*grade)
    local bank=math.asin(self:CantAt(at)*norm/self._gauge)
    local c,b=math.cos(bank),math.sin(bank)
    return Vector3(math.cos(heading)*c+math.sin(heading)*grade/norm*b,
        -b/norm,-math.sin(heading)*c+math.cos(heading)*grade/norm*b)
end

function Alignment:SampleOffset(s,lateral,y)
    number(lateral,"lateral",-MAX_COORD,MAX_COORD)
    number(y or 0,"vertical offset",-MAX_COORD,MAX_COORD)
    local pos=self:Sample(s)
    return pos+self:RightAt(s)*lateral+Vector3(0,y or 0,0)
end

function Alignment:PointAt(s)
    local at=self:Clamp(s)
    local pos,tangent,yaw=self:Sample(at)
    return {s=at,pos=pos,tangent=tangent,yaw=yaw,right=self:RightAt(at),grade=self:GradeAt(at),
        cant=self:CantAt(at),curvature=self:CurvatureAt(at)}
end

--- 求全线XZ最近距离与里程；BVH搜索包括所有端点。
---@param worldPos Vector3|table
---@return number distance, number s
function Alignment:DistanceTo(worldPos)
    local qx,_,qz=coordinates(worldPos)
    local state={distance=math.huge,s=0.0,leaves=0,evaluations=0,nodes=0}
    local function consider(seg,ds)
        local x,z=planAt(seg,ds)
        local dx,dz=qx-x,qz-z
        local distance=math.sqrt(dx*dx+dz*dz)
        state.evaluations=state.evaluations+1
        if distance<state.distance then state.distance,state.s=distance,seg.s+ds end
    end
    local function refine(seg,a,b,ax,az,bx,bz,depth)
        local chord,t=chordDistance(qx,qz,ax,az,bx,bz)
        local ka,kb=seg.k0+seg.rate*a,seg.k0+seg.rate*b
        local margin=math.max(math.abs(ka),math.abs(kb))*(b-a)^2/8+2*self._integrationTolerance
        if chord-margin>=state.distance-self._distanceTolerance then return end
        consider(seg,a+(b-a)*t)
        if chord-margin>=state.distance-self._distanceTolerance then return end
        assert(depth<50,"[Alignment] nearest-point refinement did not converge")
        local mid=(a+b)*0.5
        local mx,mz=planAt(seg,mid)
        if t<0.5 then
            refine(seg,a,mid,ax,az,mx,mz,depth+1); refine(seg,mid,b,mx,mz,bx,bz,depth+1)
        else
            refine(seg,mid,b,mx,mz,bx,bz,depth+1); refine(seg,a,mid,ax,az,mx,mz,depth+1)
        end
    end
    local function visit(node)
        state.nodes=state.nodes+1
        if boxDistance(node,qx,qz)>=state.distance-self._distanceTolerance then return end
        local p=node.piece
        if p then
            state.leaves=state.leaves+1
            local seg=p.seg
            if seg.rate==0 and seg.k0==0 then
                local _,t=chordDistance(qx,qz,p.ax,p.az,p.bx,p.bz)
                consider(seg,p.a+(p.b-p.a)*t)
            elseif seg.rate==0 then
                consider(seg,p.a); consider(seg,p.b)
                -- 在局部圆坐标投影，避免曲率趋于0时巨大圆心相减损失精度。
                local dx,dz=qx-seg.x,qz-seg.z
                local along=dx*math.sin(seg.heading)+dz*math.cos(seg.heading)
                local across=dx*math.cos(seg.heading)-dz*math.sin(seg.heading)
                local delta=math.atan(seg.k0*along,1-seg.k0*across)
                local turn=(seg.dir*delta)%PI2
                local ds=turn/math.abs(seg.k0)
                if ds>=p.a-1e-8 and ds<=p.b+1e-8 then consider(seg,clamp(ds,p.a,p.b)) end
            else
                consider(seg,p.a); consider(seg,p.b)
                refine(seg,p.a,p.b,p.ax,p.az,p.bx,p.bz,0)
            end
            return
        end
        local dl,dr=boxDistance(node.left,qx,qz),boxDistance(node.right,qx,qz)
        if dl<dr then visit(node.left); visit(node.right) else visit(node.right); visit(node.left) end
    end
    visit(self._bvh)
    self._validation.lastQueryLeaves,self._validation.lastQueryEvaluations,self._validation.lastQueryNodes=state.leaves,state.evaluations,state.nodes
    return state.distance,clamp(state.s,0,self._length)
end

function Alignment:ProjectApprox(worldPos)
    local _,s=self:DistanceTo(worldPos)
    return s
end

--- XZ圆形占地包络的保守净空判断，扣除求解器的距离上界误差。
function Alignment:CanPlaceFootprint(center,radius,clearance)
    number(radius,"footprint radius",0,MAX_COORD)
    number(clearance,"clearance",0,MAX_COORD)
    local distance=self:DistanceTo(center)
    return distance-radius-self._validation.distanceErrorBound>=clearance
end

--- 可验证的显式合成工程模板，不冒充中国铁路实测数据。
function Alignment.EngineeringTemplate()
    local segments={{type="straight",length=400}}
    for _,seg in ipairs(Alignment.SymmetricCurve(600,24,120,1)) do segments[#segments+1]=seg end
    segments[#segments+1]={type="straight",length=400}
    return {segments=segments,start={x=0,y=12,z=0},startYaw=0,pointStep=10,
        profile={startY=12,startGrade=0,segments={
            {type="grade",length=400,grade=0,endY=12},
            {type="verticalCurve",length=300,endGrade=0.01,endY=13.5},
            {type="verticalCurve",length=300,endGrade=0,endY=15},
            {type="grade",length=400,grade=0,endY=15},
        }},cant={{s=0,cant=0},{s=400,cant=0},{s=520,cant=0.10},
            {s=880,cant=0.10},{s=1000,cant=0},{s=1400,cant=0}}}
end

return Alignment
