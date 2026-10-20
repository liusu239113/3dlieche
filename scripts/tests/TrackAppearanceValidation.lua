-- 真实CustomGeometry CPU验收；不require main，不读写玩家存档/云/声音，不创建viewport。
-- .cli/UrhoXRuntime tests/TrackAppearanceValidation.lua -tapcode_dir=/workspace -tool_mode
-- stdout由调用方重定向到/workspace/screenshots/track_appearance_cpu_stdout.txt。
-- 独立旧截面/原枕位参考网格与生产CG逐顶点比较；不是字符串或GetDimensions自证。
local Track = require "world.Track"
local World = require "world.WorldMaterials"
local Route = require "world.Route"
local Rail = require "world.RailNetwork"
local Modes = require "config.GameModes"
---@type Scene?
local scene_ = nil
local checks_,cases_,slices_ = 0,0,0
local originalMode_ = Modes.GetId()
local EPS = .004 -- 公里级世界坐标的float32误差；局部原尺寸另有独立近原点精测。
local PROFILE = {
    {-.075,.160},{.075,.160},{.075,.180},{.008,.185},{.008,.298},{.036,.305},
    {.036,.340},{-.036,.340},{-.036,.305},{-.008,.298},{-.008,.185},{-.075,.180},
}
---@param ok boolean
---@param message string
local function check(ok,message) checks_=checks_+1;assert(ok,"[TrackAppearance] "..message) end
local function near(a,b,epsilon,message)
    check(a==a and b==b and math.abs(a-b)<=epsilon,
        string.format("%s actual=%.9f expected=%.9f",message,a,b))
end
---@param a Vector3
---@param b Vector3
local function point(a,b,message) check((a-b):Length()<=EPS,message) end
---@param root Node
---@param name string
---@return CustomGeometry
local function mesh(root,name)
    return assert(assert(root:GetChild(name),name):GetComponent("CustomGeometry"),name)
end
---@param geometry CustomGeometry
local function count(geometry) return geometry:GetNumVertices(0) end
---@param geometry CustomGeometry
---@param i integer
---@return Vector3
local function vertex(geometry,i) return geometry:GetVertex(0,i).position end
local function owner(name) return assert(scene_):CreateChild(name) end
local function axes(s,lane)
    local p,t,yaw=Rail.Sample(s,lane)
    local angle=math.rad(yaw)
    return p,Vector3(math.cos(angle),0,-math.sin(angle)),t
end

-- 独立重建本次修改前的股道范围；道岔尖端3cm共用逻辑不允许因外观优化改变。
---@return RailwayTrackSpan[]
local function spans(first,last)
    local result={{first=first,last=last,lane=0},{first=first,last=last,lane=1}} ---@type RailwayTrackSpan[]
    for _,routing in ipairs(Rail.GetRoutingSections()) do
        for _,lane in ipairs({2,5}) do
            local path=lane==5 and routing.up or routing
            local a,b=math.max(first,path.first),math.min(last,path.last)
            local function separation(s)
                return (Rail.Sample(s,lane)-Rail.Sample(s,lane==5 and 1 or 0)):Length()
            end
            if b>a then
                if separation(a)<.03 then
                    local low,high=path.first,path.plateauFirst
                    for _=1,24 do
                        local mid=(low+high)/2
                        if separation(mid)<.03 then low=mid else high=mid end
                    end
                    a=math.max(a,(low+high)/2)
                end
                if separation(b)<.03 then
                    local low,high=path.plateauLast,path.last
                    for _=1,24 do
                        local mid=(low+high)/2
                        if separation(mid)<.03 then high=mid else low=mid end
                    end
                    b=math.min(b,(low+high)/2)
                end
                if b>a then result[#result+1]={first=a,last=b,lane=lane} end
            end
        end
    end
    for _,cross in ipairs(Rail.GetCrossovers()) do
        local a,b=math.max(first,cross.first),math.min(last,cross.last)
        if b>a then result[#result+1]={first=a,last=b,lane=cross.lane} end
    end
    return result
end

-- 独立参考构造使用World的真实CG提交，但绝不调用Track.BuildRail或其内部section。
local function referenceRails(root,ranges,material,low)
    local body=World.NewBatch(root:CreateChild("ReferenceBody"),material,false)
    local heads=World.NewBatch(root:CreateChild("ReferenceHead"),material,false)
    for _,span in ipairs(ranges) do
        local step=low and 12 or 6
        local n=math.max(1,math.ceil((span.last-span.first)/step))
        for side=-1,1,2 do
            local lateral=side*.7535
            for i=1,n do
                local s0=span.first+(span.last-span.first)*(i-1)/n
                local s1=span.first+(span.last-span.first)*i/n
                local p0,r0=axes(s0,span.lane)
                local p1,r1=axes(s1,span.lane)
                if low then
                    local a=p0+r0*(lateral-.036)+Vector3(0,.34,0)
                    local b=p1+r1*(lateral-.036)+Vector3(0,.34,0)
                    local c=p1+r1*(lateral+.036)+Vector3(0,.34,0)
                    local d=p0+r0*(lateral+.036)+Vector3(0,.34,0)
                    heads:AddQuad(a,b,c,d)
                    body:AddQuad(a-Vector3(0,.18,0),b-Vector3(0,.18,0),b,a)
                    body:AddQuad(d,c,c-Vector3(0,.18,0),d-Vector3(0,.18,0))
                else
                    for j=2,12 do
                        local k=j%12+1
                        local v0,v1=PROFILE[j],PROFILE[k]
                        local a=p0+r0*(lateral+v0[1])+Vector3(0,v0[2],0)
                        local b=p0+r0*(lateral+v1[1])+Vector3(0,v1[2],0)
                        local c=p1+r1*(lateral+v1[1])+Vector3(0,v1[2],0)
                        local d=p1+r1*(lateral+v0[1])+Vector3(0,v0[2],0)
                        local target=j==7 and heads or body
                        target:AddQuad(a,b,c,d)
                    end
                end
            end
        end
    end
    body:Finish();heads:Finish()
    return body.geometry,heads.geometry
end
---@param actual CustomGeometry
---@param expected CustomGeometry
local function compare(actual,expected,label,epsilon)
    local n=count(expected)
    check(count(actual)>=n,label.." original vertices lost")
    for i=0,n-1 do
        local a,b=actual:GetVertex(0,i),expected:GetVertex(0,i)
        check((a.position-b.position):Length()<=(epsilon or EPS),label.." original vertex "..i)
        near(a.normal:DotProduct(b.normal),1,.002,label.." original normal "..i)
        near(a.texCoord.x,b.texCoord.x,.002,label.." UV.x "..i)
        near(a.texCoord.y,b.texCoord.y,.002,label.." UV.y "..i)
    end
end
-- 低LOD生产按segment再side，参考按side再segment；比较有方向三角形集合而非顺序。
local function triangleKey(geometry,i)
    local rows={}
    for j=0,2 do
        local v=geometry:GetVertex(0,i+j)
        rows[#rows+1]=string.format("%.4f/%.4f/%.4f/%.4f/%.4f/%.4f",v.position.x,v.position.y,v.position.z,
            v.normal.x,v.normal.y,v.normal.z)
    end
    table.sort(rows)
    return table.concat(rows,"|")
end
local function sameTriangles(a,b,label)
    check(count(a)==count(b),label.." vertex count")
    local set={}
    for i=0,count(b)-1,3 do local key=triangleKey(b,i);set[key]=(set[key] or 0)+1 end
    for i=0,count(a)-1,3 do
        local key=triangleKey(a,i)
        check((set[key] or 0)>0,label.." actual triangle missing in reference")
        set[key]=set[key]-1
    end
    for _,remaining in pairs(set) do check(remaining==0,label.." duplicate/missing triangle") end
end

local function auditTriangles(root)
    local vertices,batches=0,0
    for _,g in ipairs(root:GetComponents("CustomGeometry",true)) do
        local n=count(g)
        if n>0 and g.enabled then
            check(g.viewMask==2,"track viewMask changed")
            check(n%3==0 and g.numGeometries==1,"invalid geometry topology")
            check(g:GetMaterial(0)~=nil,"missing actual material")
            vertices,batches=vertices+n,batches+1
            for i=0,n-1,3 do
                local a,b,c=vertex(g,i),vertex(g,i+1),vertex(g,i+2)
                local cross=(b-a):CrossProduct(c-a)
                check(cross:LengthSquared()>1e-9,"degenerate/zero span triangle")
                local outward=cross:Normalized()
                for j=0,2 do
                    local v=g:GetVertex(0,i+j)
                    near(v.normal:Length(),1,.0001,"non-unit normal")
                    check(v.normal:DotProduct(outward)>.999,"normal disagrees with winding")
                    check(v.texCoord.x==v.texCoord.x and v.texCoord.y==v.texCoord.y,"NaN UV")
                end
            end
        end
    end
    return vertices,batches
end
local function referenceSleepers(root,ranges,material)
    local batch=World.NewBatch(root:CreateChild("ReferenceSleepers"),material,false)
    local total=0
    for _,span in ipairs(ranges) do
        local low=math.ceil((span.first-.000001)/.6)
        local high=math.ceil((span.last-.000001)/.6)-1
        for index=low,high do
            local s=index*.6
            local branch=span.lane==2 or span.lane==5
            local gap=math.abs(Rail.GetLateral(s,span.lane)-Rail.GetLateral(s,span.lane==5 and 1 or 0))
            if s>=.12 and s<Route.GetLength()-.12 and (not branch or gap>2.6) then
                local p,r,t=axes(s,span.lane)
                local a=p-r*1.3-t*.12+Vector3(0,.06,0)
                local b=p+r*1.3-t*.12+Vector3(0,.06,0)
                local c=p+r*1.3+t*.12+Vector3(0,.06,0)
                local d=p-r*1.3+t*.12+Vector3(0,.06,0)
                local up=Vector3(0,.10,0)
                batch:AddQuad(a+up,d+up,c+up,b+up)
                batch:AddQuad(a+up,b+up,b,a);batch:AddQuad(b+up,c+up,c,b)
                batch:AddQuad(c+up,d+up,d,c);batch:AddQuad(d+up,a+up,a,d)
                total=total+1
            end
        end
    end
    batch:Finish()
    return batch.geometry,total
end
local function fastenerSites(first,last)
    local sites={}
    for lane=0,1 do
        for index=math.ceil((first-.000001)/6),math.ceil((last-.000001)/6)-1 do
            local s=index*6
            local clear=s>=.12 and s<Route.GetLength()-.12 and not Rail.GetSectionAt(s,lane)
            for _,cross in ipairs(Rail.GetCrossovers()) do
                if s>=cross.first-1 and s<=cross.last+1 then clear=false end
            end
            if clear then sites[#sites+1]={s=s,lane=lane} end
        end
    end
    return sites
end
local function auditFasteners(body,offset,first,last)
    local sites=fastenerSites(first,last)
    check(count(body)==offset+#sites*120,"fasteners not merged in original body batch / budget changed")
    local i=offset
    for _,site in ipairs(sites) do
        local p,r,t=axes(site.s,site.lane)
        local planar=Vector3(t.x,0,t.z):Normalized()
        for side=-1,1,2 do for edge=-1,1,2 do
            local minX,maxX,minZ,maxZ,minY,maxY=math.huge,-math.huge,math.huge,-math.huge,math.huge,-math.huge
            for j=0,29 do
                local delta=vertex(body,i+j)-p
                local x,z=delta:DotProduct(r),delta:DotProduct(planar)
                minX,maxX=math.min(minX,x),math.max(maxX,x)
                minZ,maxZ=math.min(minZ,z),math.max(maxZ,z)
                -- tangent有坡度，扣件上下层仍沿世界Y，与原轨底/枕保持同一约定。
                local y=delta.y-z*t.y/math.sqrt(t.x*t.x+t.z*t.z)
                minY,maxY=math.min(minY,y),math.max(maxY,y)
                check(math.abs(x)<1.3 and math.abs(z)<.121,"fastener outside original sleeper footprint")
                check(y<.22,"fastener intrudes wheel/flange clearance above .22m")
            end
            near((minX+maxX)*.5,side*.7535+edge*.089,EPS,"fastener rail seat")
            near(maxX-minX,.054,EPS*2,"real fastener width")
            near(maxZ-minZ,.10*math.sqrt(t.x*t.x+t.z*t.z),EPS*2,"real fastener length")
            near(minY,.16,EPS,"fastener base on sleeper")
            near(maxY,.205,EPS,"real fastener thickness, not shadow decal")
            check(.34-maxY>.12,"wheel clearance <120mm")
            near(site.s/.6,math.floor(site.s/.6+.5),1e-6,"fastener phase differs from sleeper grid")
            i=i+30
        end end
    end
    return #sites*120
end

-- 原点附近独立精测原截面边界、轨距、枕长/枕宽/轨腰/轨底，非元数据断言。
local function originalDimensions()
    local root=owner("OriginalDimensions")
    local body=World.NewBatch(root:CreateChild("Body"),World.Concrete(),false)
    local heads=World.NewBatch(root:CreateChild("Heads"),World.Concrete(),false)
    for side=-1,1,2 do Track.BuildRail(body,Route.GetLength(),side*.7535,12,18,heads,nil,0) end
    body:Finish();heads:Finish()
    local p,r=axes(12,0)
    local leftMin,leftMax,rightMin,rightMax=math.huge,-math.huge,math.huge,-math.huge
    for i=0,count(heads.geometry)-1 do
        local delta=vertex(heads.geometry,i)-p
        local x=delta:DotProduct(r)
        if x<0 then leftMin,leftMax=math.min(leftMin,x),math.max(leftMax,x)
        else rightMin,rightMax=math.min(rightMin,x),math.max(rightMax,x) end
        near(vertex(heads.geometry,i).y-Route.Sample(12+(i%6==2 and 6 or 0)).y,.34,.0001,"railhead height")
        check(heads.geometry:GetVertex(0,i).normal.y>.999,"railhead normal not upward")
    end
    near(rightMin-leftMax,1.435,.0001,"actual inner gauge")
    near(leftMax-leftMin,.072,.0001,"actual left polished strip width")
    near(rightMax-rightMin,.072,.0001,"actual right polished strip width")
    local xs,ys={},{}
    for i=0,count(body.geometry)-1 do
        local delta=vertex(body.geometry,i)-p
        xs[#xs+1]=delta:DotProduct(r)
        ys[#ys+1]=delta.y
    end
    for side=-1,1,2 do
        for _,entry in ipairs(PROFILE) do
            local found=false
            for j,x in ipairs(xs) do
                if math.abs(x-(side*.7535+entry[1]))<.0001 and math.abs(ys[j]-entry[2])<.0001 then found=true end
            end
            -- 轨顶角点仅在heads或body中；body也含轨头侧面完整角点。
            check(found,"original I-section point absent")
        end
    end
    root:Dispose()
    print("[TrackAppearance] ORIGINAL_DIMENSIONS gauge=1.435 head=.072 web=.016 foot=.150 railY=.340 footY=.160 PASS")
end

---@type Material[]
local shared_={}
local function materialAudit(nearRoot,farRoot)
    local sleeperMat=mesh(nearRoot,"SharedConcreteSleepers"):GetMaterial(0)
    local bodyMat=mesh(nearRoot,"SharedRailISections"):GetMaterial(0)
    local headMat=mesh(nearRoot,"SharedRunningHeads"):GetMaterial(0)
    check(sleeperMat~=World.Concrete(),"sleeper still aliases World.Concrete")
    check(sleeperMat~=bodyMat and bodyMat~=headMat,"track surface materials not distinct")
    check(mesh(farRoot,"SharedDistantRailBodies"):GetMaterial(0)==bodyMat,"far body not sharing oxidized material")
    check(mesh(farRoot,"SharedDistantRails"):GetMaterial(0)==headMat,"far head not sharing polished material")
    if #shared_==0 then shared_={sleeperMat,bodyMat,headMat} else
        check(shared_[1]==sleeperMat and shared_[2]==bodyMat and shared_[3]==headMat,"material allocation per chunk")
    end
    local technique=assert(cache:GetResource("Technique","Techniques/PBR/PBRDiff.xml"))
    for _,mat in ipairs({sleeperMat,bodyMat,headMat}) do
        check(mat:GetTechnique(0)==technique,"new technique/shader variant")
        check(mat:GetTexture(TU_NORMAL)==nil and mat:GetTexture(TU_SPECULAR)==nil,"unexpected extra textures")
        check(mat:GetVertexShaderDefines()=="" and mat:GetPixelShaderDefines()=="","new shader defines")
        check(mat:GetNumTechniques()==1,"extra LOD technique")
        near(mat:GetShaderParameter("MatDiffColor"):GetColor().a,1,0,"unexpected transparency")
    end
    local steel=cache:GetResource("Texture2D","Textures/Railway/coach_steel.png")
    check(bodyMat:GetTexture(TU_DIFFUSE)==steel and headMat:GetTexture(TU_DIFFUSE)==steel,"steel texture not cache-shared")
    check(sleeperMat:GetTexture(TU_DIFFUSE)==World.Concrete():GetTexture(TU_DIFFUSE),"concrete texture not shared")
    local sc=sleeperMat:GetShaderParameter("MatDiffColor"):GetColor()
    local bc=bodyMat:GetShaderParameter("MatDiffColor"):GetColor()
    local hc=headMat:GetShaderParameter("MatDiffColor"):GetColor()
    check(sc.r>sc.g and sc.g>sc.b and sc.r<.65,"sleepers not warm muted gray")
    check(bc.r>bc.g and bc.g>bc.b and hc.r>bc.r*1.5,"oxidation/polished contrast lost")
    check(bodyMat:GetShaderParameter("Roughness"):GetFloat()>.7 and headMat:GetShaderParameter("Roughness"):GetFloat()<.4,
        "roughness separation missing")
end

local function endpoints(nearHead,farHead,first,last,ranges)
    for _,span in ipairs(ranges) do
        for _,s in ipairs({span.first,span.last}) do
            local p,r=axes(s,span.lane)
            for side=-1,1,2 do for edge=-1,1,2 do
                local expected=p+r*(side*.7535+edge*.036)+Vector3(0,.34,0)
                for _,geometry in ipairs({nearHead,farHead}) do
                    local found=false
                    for i=0,count(geometry)-1 do
                        if (vertex(geometry,i)-expected):Length()<EPS then found=true;break end
                    end
                    check(found,"near/far endpoint section gap: "..s)
                end
            end end
        end
    end
    check(first<last,"endpoint fixture invalid")
end

local function buildCase(label,first,last)
    local root=owner(label)
    local nearRoot,farRoot,reference=root:CreateChild("Near"),root:CreateChild("Far"),root:CreateChild("Reference")
    local returned=Track.BuildChunk(nearRoot,first,last,true)
    local farReturned=Track.BuildChunk(farRoot,first,last,false)
    local ranges=spans(math.max(0,first),math.min(Route.GetLength(),last))
    local body,head=mesh(nearRoot,"SharedRailISections"),mesh(nearRoot,"SharedRunningHeads")
    local rb,rh=referenceRails(reference,ranges,World.Concrete(),false)
    compare(body,rb,label.." I section");compare(head,rh,label.." running head")
    check(count(head)==count(rh),"polished head geometry grew")
    local sleepers,n=referenceSleepers(reference,ranges,World.Concrete())
    compare(mesh(nearRoot,"SharedConcreteSleepers"),sleepers,label.." sleepers")
    check(count(mesh(nearRoot,"SharedConcreteSleepers"))==n*30,"sleeper count/phase changed")
    local added=auditFasteners(body,count(rb),math.max(0,first),math.min(Route.GetLength(),last))
    local fb,fh=referenceRails(reference,ranges,World.Concrete(),true)
    sameTriangles(mesh(farRoot,"SharedDistantRailBodies"),fb,label.." far body")
    sameTriangles(mesh(farRoot,"SharedDistantRails"),fh,label.." far head")
    endpoints(head,mesh(farRoot,"SharedDistantRails"),first,last,ranges)
    materialAudit(nearRoot,farRoot)
    local nv,nb=auditTriangles(nearRoot)
    local fv,fbb=auditTriangles(farRoot)
    -- 返回值历史上不含桥梁几何；不将已有桥梁的额外批次伪装成本次新增轨道批次。
    local bridgeVerts,bridgeBatches=0,0
    for _,g in ipairs(nearRoot:GetComponents("CustomGeometry",true)) do
        if g.node.name:match("^ElevatedBridge") then bridgeVerts,bridgeBatches=bridgeVerts+count(g),bridgeBatches+1 end
    end
    check(nv==returned+bridgeVerts,"near return accounting changed")
    check(fv==farReturned+bridgeVerts,"far return accounting changed")
    check(fbb-bridgeBatches==3,"far track exceeds three batches")
    check(added<=4800 and nb-bridgeBatches>=4,"near fastener budget exceeded")
    for _,node in ipairs(nearRoot:GetChildren(true)) do
        check(not node.name:lower():find("fastener",1,true),"per-fastener Node created")
    end
    print(string.format("[TrackAppearance] CASE %s s=%.3f..%.3f spans=%d sleepers=%d nearVertices=%d nearBatches=%d farVertices=%d farBatches=%d fastenerAdded=%d bridgeBatches=%d",
        label,first,last,#ranges,n,nv,nb,fv,fbb,added,bridgeBatches))
    cases_=cases_+1
    root:Dispose()
    return nv,nb,fv,fbb,added
end

local function lifecycle(first)
    local root=owner("Lifecycle")
    local a=root:CreateChild("Sync")
    Track.BuildChunk(a,first,first+120,true)
    local b=root:CreateChild("Yielded")
    local work=coroutine.create(function() Track.BuildChunk(b,first,first+120,true,function() coroutine.yield() end) end)
    while coroutine.status(work)~="dead" do
        local ok,err=coroutine.resume(work);check(ok,tostring(err));slices_=slices_+1
        check(slices_<500,"unbounded track coroutine")
    end
    for _,g in ipairs(a:GetComponents("CustomGeometry",true)) do
        local other=mesh(b,g.node.name)
        compare(other,g,"yield equivalence",0)
        check(other:GetMaterial(0)==g:GetMaterial(0),"yield cloned material")
    end
    check(#a:GetChildren(true)==#b:GetChildren(true),"yield changes node lifetime")
    a:Dispose();b:Dispose()
    for cut=1,12 do
        local cancelled=root:CreateChild("Cancel"..cut)
        local task=coroutine.create(function()
            Track.BuildChunk(cancelled,first,first+120,true,function() coroutine.yield() end)
        end)
        for _=1,cut do if coroutine.status(task)~="dead" then
            local ok,err=coroutine.resume(task);check(ok,tostring(err))
        end end
        -- 与WorldStream一致：丢弃未完成任务，然后释放拥有节点，不再resume已取消任务。
        coroutine.close(task)
        cancelled:Dispose()
    end
    check(#root:GetChildren(true)==0,"cancelled chunk retains descendants")
    local recreated=root:CreateChild("Recreated")
    Track.Init();Track.BuildChunk(recreated,first,first+120,true)
    check(mesh(recreated,"SharedConcreteSleepers"):GetMaterial(0)==shared_[1],"disposed chunk freed shared material")
    check(mesh(recreated,"SharedRailISections"):GetMaterial(0)==shared_[2],"body material lost after cancellation")
    root:Dispose()
    print(string.format("[TrackAppearance] LIFECYCLE sync=yielded cancellations=12 recreation=shared slices=%d PASS",slices_))
end

local function bridgeAudit()
    for _,range in ipairs(Route.GetStructureRanges()) do if range.kind=="bridge" then
        local first=range.first+12
        local root=owner("BridgeMaterial")
        Track.BuildChunk(root,first,math.min(range.last,first+120),true)
        for _,name in ipairs({"ElevatedBridgeDeck","ElevatedBridgeEdgeGirders","ElevatedBridgePiers"}) do
            check(mesh(root,name):GetMaterial(0)==World.Concrete(),"bridge concrete polluted by sleeper tint")
        end
        check(mesh(root,"ElevatedBridgeRailings"):GetMaterial(0)~=shared_[3],"bridge railings changed to railhead material")
        root:Dispose();buildCase("bridge",first,math.min(range.last,first+120));return
    end end
    error("[TrackAppearance] missing actual bridge fixture")
end
local function run()
    scene_=Scene();scene_:CreateComponent("Octree")
    local concrete=World.Concrete()
    local concreteColor=concrete:GetShaderParameter("MatDiffColor"):GetColor()
    local concreteRoughness=concrete:GetShaderParameter("Roughness"):GetFloat()
    Modes.Apply("normal");Route.Build();Track.Init()
    originalDimensions()
    -- 自动找无站场/渡线/桥梁的完整120m双线块，不假设首站外120m仍是空区间。
    local first=-1
    for s=120,Route.GetLength()-240,120 do
        local clear=true
        for at=s,s+120,6 do
            if Rail.GetSectionAt(at,0) or Rail.GetSectionAt(at,1) then clear=false end
        end
        for _,cross in ipairs(Rail.GetCrossovers()) do
            if s<cross.last+1 and s+120>cross.first-1 then clear=false end
        end
        for _,range in ipairs(Route.GetStructureRanges()) do
            if s<range.last and s+120>range.first then clear=false end
        end
        if clear then first=s;break end
    end
    check(first>0,"no plain120 fixture")
    local nv,nb,fv,fb,added=buildCase("plain120",first,first+120)
    check(nv==22800 and nb==4 and fv==1080 and fb==3 and added==4800,"plain double-line explicit budget changed")
    print("[TrackAppearance] BUDGET near 18000->22800 (+4800,+26.667%) batches4->4; far1080->1080 batches2->3; fasteners160 x30 vertices; addedNodes=0")
    -- 相位/LOD接缝跨任意非0.6m端点，含端点裁切；逐顶点旧枕位参考防重复/漏枕。
    buildCase("phase_left",240.17,300.31)
    buildCase("phase_right",300.31,360.29)
    buildCase("open_start",-30,25.37)
    buildCase("open_end",Route.GetLength()-25.37,Route.GetLength()+40)
    local station=assert(Rail.GetStationRouting(2))
    buildCase("station_branch",station.plateauFirst+5,station.plateauFirst+125)
    buildCase("switch_tip",station.first,station.first+120)
    buildCase("up_bypass",station.up.plateauFirst+5,station.up.plateauFirst+125)
    for _,cross in ipairs(Rail.GetCrossovers()) do buildCase("crossover"..cross.lane,cross.first+6,cross.first+126) end
    lifecycle(first)
    Modes.Apply("rage");Route.Build()
    local steep,curve,grade,k=0,0,0,0
    for s=240,Route.GetLength()-240,120 do
        if math.abs(Route.GradeAt(s))>grade then steep,grade=s,math.abs(Route.GradeAt(s)) end
        if math.abs(Route.CurvatureAt(s))>k then curve,k=s,math.abs(Route.CurvatureAt(s)) end
    end
    check(grade>.01 and k>0,"missing real grade/curve cases")
    buildCase("graded",steep,steep+120)
    buildCase("curved",curve,curve+120)
    -- 另找真实纵坡且非岔区的块，确保坡地扣件的体积/净空检查不因全部抑制而空过。
    local gradedFasteners=false
    for s=240,Route.GetLength()-240,120 do
        if math.abs(Route.GradeAt(s))>.01 and #fastenerSites(s,s+120)==40 then
            buildCase("graded_fasteners",s,s+120);gradedFasteners=true;break
        end
    end
    check(gradedFasteners,"missing graded fastener clearance fixture")
    local intervalFound=false
    for _,routing in ipairs(Rail.GetRoutingSections()) do if routing.kind=="interval" then
        buildCase("interval_switch",routing.first,routing.first+120)
        intervalFound=true;break
    end end
    check(intervalFound,"missing actual interval turnout fixture")
    bridgeAudit()
    check(World.Concrete()==concrete,"World.Concrete identity changed")
    local after=concrete:GetShaderParameter("MatDiffColor"):GetColor()
    near(after.r,concreteColor.r,0,"bridge concrete.r changed");near(after.g,concreteColor.g,0,"bridge concrete.g changed")
    near(after.b,concreteColor.b,0,"bridge concrete.b changed")
    near(concrete:GetShaderParameter("Roughness"):GetFloat(),concreteRoughness,0,"bridge concrete roughness changed")
    print(string.format("ALL_TRACK_APPEARANCE_CPU_PASS cases=%d checks=%d actualCG=true saveIO=NONE graphics=NONE",cases_,checks_))
end
function Start()
    local ok,err=xpcall(run,debug.traceback)
    if scene_ then scene_:Dispose();scene_=nil end
    Modes.Apply(originalMode_)
    if not ok then print("TRACK_APPEARANCE_CPU_FAIL "..tostring(err));log:Write(LOG_ERROR,tostring(err)) end
    engine:Exit()
end
