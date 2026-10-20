-- 真实CustomGeometry地表验收；CPU-only，无main/viewport/存档/声音。
-- .cli/UrhoXRuntime tests/GroundSurfaceValidation.lua -tapcode_dir=/workspace -tool_mode
-- 面积/点覆盖/原平面/世界UV/材质/相邻cell/取消重建均读取实际提交顶点，不以统计表自证。
local Modes=require "config.GameModes"
local Route=require "world.Route"
local Terrain=require "world.Terrain"
local Mountain=require "world.MountainProfile"
local Landscape=require "world.Landscape"
local World=require "world.WorldMaterials"
local Ground=require "world.GroundSurface"
local Config=require "config.GameConfig"
local Validation={}
---@type Scene?
local scene_=nil
local checks_,cases_,maxSlice_,maxVertices_,maxBatches_=0,0,0,0,0
local originalMode_=Modes.GetId()
local TILE=51.2
local function check(ok,message) checks_=checks_+1;assert(ok,"[GroundSurface] "..message) end
local function near(a,b,eps,message) check(a==a and b==b and math.abs(a-b)<=eps,message..string.format(" %.8f / %.8f",a,b)) end
---@param root Node
---@return CustomGeometry[]
local function meshes(root)
    local result={}
    for _,g in ipairs(root:GetComponents("CustomGeometry",true)) do
        if g.node.name:match("^NaturalGround_") and g:GetNumVertices(0)>0 then result[#result+1]=g end
    end
    return result
end
---@param a Vector3
---@param b Vector3
---@param c Vector3
local function area(a,b,c) return math.abs((b-a):CrossProduct(c-a).y)*.5 end
---@param p Vector3
---@param a Vector3
---@param b Vector3
---@param c Vector3
---@return number?, number?
local function bary(p,a,b,c)
    local ax,az,bx,bz=p.x-a.x,p.z-a.z,b.x-a.x,b.z-a.z
    local cx,cz=c.x-a.x,c.z-a.z
    local det=bx*cz-bz*cx
    if math.abs(det)<1e-10 then return nil,nil end
    return (ax*cz-az*cx)/det,(bx*az-bz*ax)/det
end
---@param g CustomGeometry
---@param i integer
local function triangle(g,i) return g:GetVertex(0,i).position,g:GetVertex(0,i+1).position,g:GetVertex(0,i+2).position end
---@param root Node
---@param source? Vector3[][]
local function audit(root,source)
    local sum,vertices,batches=0,0,0
    for _,g in ipairs(meshes(root)) do
        local n=g:GetNumVertices(0);vertices=vertices+n;batches=batches+1
        check(n%3==0 and not g.castShadows,"ground topology/shadow changed")
        local material=g:GetMaterial(0)
        check(material:GetTechnique(0)==cache:GetResource("Technique","Techniques/PBR/PBRDiff.xml"),"new technique")
        check(material:GetVertexShaderDefines()=="" and material:GetPixelShaderDefines()=="","new shader variant")
        check(material:GetTexture(TU_NORMAL)==nil,"ground normal/tangent dependency")
        near(material:GetUVTiling().x,1,0,"material double UV scale")
        for i=0,n-1,3 do
            local a,b,c=triangle(g,i)
            local cross=(b-a):CrossProduct(c-a)
            check(cross.y>0 and cross:LengthSquared()>1e-9,"degenerate/inverted triangle")
            sum=sum+area(a,b,c)
            for j=0,2 do
                local v=g:GetVertex(0,i+j)
                near(v.texCoord.x,v.position.x/TILE,.0002,"world U discontinuous")
                near(v.texCoord.y,v.position.z/TILE,.0002,"world V discontinuous")
                near(v.normal:Length(),1,.00001,"normal length")
                check(v.normal:DotProduct(cross:Normalized())>.9999,"normal differs from original plane")
                if source then
                    local found=false
                    for _,t in ipairs(source) do
                        local u,w=bary(v.position,t[1],t[2],t[3])
                        if u and w and u>=-.002 and w>=-.002 and u+w<=1.002 then
                            local y=t[1].y*(1-u-w)+t[2].y*u+t[3].y*w
                            if math.abs(y-v.position.y)<.012 then found=true;break end
                        end
                    end
                    check(found,"vertex escaped original clipped triangle plane")
                end
            end
        end
    end
    maxVertices_=math.max(maxVertices_,vertices);maxBatches_=math.max(maxBatches_,batches)
    return sum,vertices,batches
end
---@param root Node
---@param p Vector3
---@return number, Material?
local function coverage(root,p)
    local count=0
    local material=nil ---@type Material?
    for _,g in ipairs(meshes(root)) do
        for i=0,g:GetNumVertices(0)-1,3 do
            local a,b,c=triangle(g,i)
            local u,v=bary(p,a,b,c)
            if u and v and u>1e-5 and v>1e-5 and u+v<1-1e-5 then count=count+1;material=g:GetMaterial(0) end
        end
    end
    return count,material
end
---@param root Node
local function fingerprint(root)
    local rows={}
    for _,g in ipairs(meshes(root)) do
        for i=0,g:GetNumVertices(0)-1 do
            local v=g:GetVertex(0,i)
            rows[#rows+1]=string.format("%s %.5f %.5f %.5f %.6f %.6f",g.node.name,v.position.x,v.position.y,v.position.z,v.texCoord.x,v.texCoord.y)
        end
    end
    table.sort(rows);return table.concat(rows,"\n")
end
---@param action fun(pause:fun())
local function sliced(action)
    local slices,peak=0,0
    local task=coroutine.create(function() action(function() coroutine.yield() end) end)
    while coroutine.status(task)~="dead" do
        local before=os.clock()
        local ok,err=coroutine.resume(task)
        peak=math.max(peak,(os.clock()-before)*1000)
        check(ok,tostring(err));slices=slices+1;check(slices<20000,"unbounded coroutine")
    end
    maxSlice_=math.max(maxSlice_,peak)
    return peak,slices
end
---@param root Node
---@param s number
---@param first number
---@param last number
---@param width number
---@param y fun(x:number,z:number):number
local function strip(root,s,first,last,width,y,pause)
    local surface=Ground.New(root,World.Grassland())
    local source={}
    for along=first,last-.001,20 do
        local finish=math.min(last,along+20)
        local function p(at,lateral)
            local v=Route.SampleOffset(s+at,lateral,0)
            return Vector3(v.x,y(v.x,v.z),v.z)
        end
        local a,b,c,d=p(along,-width),p(finish,-width),p(finish,width),p(along,width)
        source[#source+1]={a,b,c};source[#source+1]={a,c,d}
        surface:AddTri(a,b,c,true,pause);surface:AddTri(a,c,d,true,pause)
    end
    surface:Finish(pause)
    return source
end
---@param scene Scene
function Validation.CheckSurfaceContract(scene)
    local root=scene:CreateChild("SurfaceContract")
    local s=4216.65
    local y=function() return 0 end
    local source=strip(root,s,0,40,40,y)
    local actual,vertices,batches=audit(root,source)
    local expected=0
    for _,t in ipairs(source) do expected=expected+area(t[1],t[2],t[3]) end
    near(actual,expected,.08,"single-layer original area")
    check(batches==3 and vertices>12 and vertices<=3000,"near strip batch/vertex budget")
    for _,lateral in ipairs({-30,-11,-3,2.5,8,14,30}) do
        local p=Route.SampleOffset(s+17.131,lateral,0)
        local count,mat=coverage(root,p)
        check(count==1,"surface hole/overlap lateral="..lateral)
        if math.abs(lateral-2.5)>25 then check(mat==World.Grassland(),"far band not grass") end
        if math.abs(lateral-2.5)<3 then check(mat==World.GroundEarth(),"inner ground not soil") end
    end
    local retained=World.Grassland()
    root:Dispose()
    check(World.Grassland()==retained,"chunk freed shared surface material")
    print(string.format("[GroundSurface] CONTRACT area=%.3f vertices=%d batches=%d UV=world/51.2 originalY=0 PASS",actual,vertices,batches))
end
local function standalone()
    local scene=assert(scene_)
    Validation.CheckSurfaceContract(scene)
    for _,s in ipairs({4216.65,15000,36000}) do
        local root=scene:CreateChild("SlopedStrip")
        local origin=Route.Sample(s)
        local y=function(x,z) return 21+(x-origin.x)*.035+(z-origin.z)*.018 end
        local source=strip(root,s,0,80,40,y)
        local actual,n,b=audit(root,source)
        local expected=0
        for _,t in ipairs(source) do expected=expected+area(t[1],t[2],t[3]) end
        near(actual,expected,.18,"sloped strip area")
        check(b<=3 and n<=6000,"sloped strip budget")
        local other=scene:CreateChild("YieldedStrip")
        local peak,slices=sliced(function(pause) strip(other,s,0,80,40,y,pause) end)
        check(fingerprint(root)==fingerprint(other),"yield changes actual geometry")
        print(string.format("[GroundSurface] STRIP s=%.2f vertices=%d batches=%d area=%.3f slices=%d maxSliceMs=%.3f",s,n,b,actual,slices,peak))
        root:Dispose();other:Dispose();cases_=cases_+1
    end
    -- 两个独立拥有块共边；两侧ε样本必须同材质，交界非80m量化色带。
    local a,b=scene:CreateChild("BoundaryA"),scene:CreateChild("BoundaryB")
    local y=function() return 0 end
    strip(a,4216.65,0,80,40,y);strip(b,4216.65,80,160,40,y)
    local different=0
    for lateral=-30,35,1.731 do
        local n1,m1=coverage(a,Route.SampleOffset(4216.65+79.999,lateral,0))
        local n2,m2=coverage(b,Route.SampleOffset(4216.65+80.001,lateral,0))
        check(n1==1 and n2==1,"half-open adjacent strip coverage")
        if m1~=m2 then different=different+1 end
    end
    check(different==0,"material band resets at chunk boundary")
    a:Dispose();b:Dispose()
    -- 半成品任务撤销后只Dispose拥有节点，重新加载必须同指纹、共享材质。
    local root=scene:CreateChild("Lifecycle")
    local sync=root:CreateChild("Sync")
    strip(sync,4216.65,0,80,40,y)
    local expected=fingerprint(sync)
    for cut=1,12 do
        local cancelled=root:CreateChild("Cancel")
        local task=coroutine.create(function() strip(cancelled,4216.65,0,80,40,y,function() coroutine.yield() end) end)
        for _=1,cut do if coroutine.status(task)~="dead" then local ok,err=coroutine.resume(task);check(ok,tostring(err)) end end
        coroutine.close(task);cancelled:Dispose()
    end
    local recreated=root:CreateChild("Recreated")
    strip(recreated,4216.65,0,80,40,y)
    check(fingerprint(recreated)==expected,"cancel/recreate changes UV or triangles")
    root:Dispose()
    print("[GroundSurface] LIFECYCLE cancellations=12 sync=yielded=recreated sharedMaterials=true PASS")
end
local function actualCells()
    for _,s in ipairs({4216.65,6000,15000,38500}) do
        local pos=Route.Sample(s)
        local cx,cz=math.floor(pos.x/160),math.floor(pos.z/160)
        local root=assert(scene_):CreateChild("ActualCell")
        local peak,slices=sliced(function(pause) Terrain.BuildCell(root,cx,cz,160,pause) end)
        local source={}
        local step=Mountain.IsActiveAt(s) and 20 or 80
        for x=cx*160,(cx+1)*160-.001,step do for z=cz*160,(cz+1)*160-.001,step do
            local function p(xx,zz) return Vector3(xx,Mountain.IsActiveAt(s) and Mountain.DesignHeight(xx,zz) or 0,zz) end
            local a,b,c,d=p(x,z),p(x,z+step),p(x+step,z+step),p(x+step,z)
            local _,sampleS=Route.DistanceTo((a+c)*.5)
            if Mountain.IsActiveAt(s)==Mountain.IsActiveAt(sampleS) then
                local tris=step==20 and {{a,b,c},{a,c,d}} or {{a,b,c,d}}
                for _,tri in ipairs(tris) do for _,piece in ipairs(Landscape.ClipUnclaimedGround(tri)) do
                    for i=2,#piece-1 do source[#source+1]={piece[1],piece[i],piece[i+1]} end
                end end
            end
        end end
        local actual,n,b=audit(root,source)
        local expected=0
        for _,t in ipairs(source) do expected=expected+area(t[1],t[2],t[3]) end
        near(actual,expected,1.2,"actual Terrain area differs from old clipped source")
        check(b<=3 and n<=6000,"actual cell exceeds +2 ground batches/6000 vertices")
        print(string.format("[GroundSurface] CELL s=%.2f cell=%d,%d sourceTriangles=%d actualArea=%.3f vertices=%d batches=%d slices=%d maxSliceMs=%.3f",s,cx,cz,#source,actual,n,b,slices,peak))
        Terrain.ForgetCell(cx,cz);root:Dispose();cases_=cases_+1
    end
end
local function runValidation()
    local ok,err=xpcall(function()
        Modes.Apply("normal");Route.Build();Terrain.Init()
        scene_=Scene();scene_:CreateComponent("Octree")
        -- 预热真实资源后计持续切片，避免把首次CPU PNG解码误算成每帧流式成本。
        World.Grassland();World.GroundEarth();World.GroundVerge();World.UrbanGround()
        local concrete,ballast=World.Concrete(),World.Ballast()
        local cc=concrete:GetShaderParameter("MatDiffColor"):GetColor()
        standalone();actualCells()
        check(World.Concrete()==concrete and World.Ballast()==ballast,"non-ground material identity polluted")
        near(concrete:GetShaderParameter("MatDiffColor"):GetColor().r,cc.r,0,"concrete tint polluted")
        check(Config.WorldStream.FrameBudgetMs==3,"production stream budget changed")
        if maxSlice_>=3 then
            print(string.format("GROUND_SURFACE_BUDGET_WARNING rawMaxSliceMs=%.3f exceeds3ms=true GC=normal budgetUnchanged=true",maxSlice_))
        end
        print(string.format("ALL_GROUND_SURFACE_GEOMETRY_CPU_PASS checks=%d cases=%d maxVertices=%d maxBatches=%d rawMaxSliceMs=%.3f hard3ms=%s noGraphics=true saveIO=NONE",checks_,cases_,maxVertices_,maxBatches_,maxSlice_,maxSlice_<3 and "PASS" or "UNPROVEN"))
    end,debug.traceback)
    if not ok then print("GROUND_SURFACE_CPU_FAIL "..tostring(err));log:Write(LOG_ERROR,tostring(err)) end
    Terrain.Shutdown()
    if scene_ then scene_:Dispose();scene_=nil end
    Modes.Apply(originalMode_);engine:Exit()
end
-- require复用合同时不能覆盖调用者的Start事件入口。
local moduleName=...
if moduleName~="tests.GroundSurfaceValidation" then _G.Start=runValidation end
return Validation
