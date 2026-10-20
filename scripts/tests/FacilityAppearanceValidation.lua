-- 设施外观CPU专项：真实生产CustomGeometry、原始逐顶点/三角形对照，不启动图形。
-- 修改前两份输入保存在screenshots/facility_*_before.lua（仅测试输入，不写存档）。
-- .cli/UrhoXRuntime tests/FacilityAppearanceValidation.lua -tapcode_dir=/workspace -tool_mode
local Route=require "world.Route"
local Rail=require "world.RailNetwork"
local World=require "world.WorldMaterials"
local Track=require "world.Track"
local Infrastructure=require "world.RailwayInfrastructure"
local Yard=require "world.StationYard"
local Landmarks=require "world.Landmarks"
local Modes=require "config.GameModes"
---@type Scene?
local scene_=nil
local checks_,cases_=0,0
local originalMode_=Modes.GetId()
local maximumAdded_,maxBuildMs_,maxSliceMs_=0,0,0
local function check(value,message)
    checks_=checks_+1;assert(value,"[FacilityAppearance] "..message)
end
local function near(a,b,message)
    check(math.abs(a-b)<.00001,message.." "..tostring(a).." != "..tostring(b))
end
-- 输入是本轮编辑前直接归档的真实生产文件，而非在测试里复制几何公式自证。
local function baseline(path)
    local file=File(path,FILE_READ)
    check(file:IsOpen(),"missing before-input "..path)
    local lines={}
    while not file.eof do lines[#lines+1]=file:ReadLine() end
    file:Dispose()
    return assert(load(table.concat(lines,"\n"),"@"..path,"t",_G))()
end
---@param root Node
---@param name string
---@return CustomGeometry
local function mesh(root,name)
    return assert(assert(root:GetChild(name,true),name):GetComponent("CustomGeometry"))
end
---@param root Node
local function totals(root)
    local vertices,batches=0,0
    for _,g in ipairs(root:GetComponents("CustomGeometry",true)) do
        local n=g:GetNumVertices(0)
        vertices=vertices+n
        if n>0 and g.enabled then batches=batches+1 end
        check(g.viewMask==2,"visibility mask changed")
        check(n%3==0,"incomplete actual triangle")
    end
    check(#root:GetComponents("Light",true)==0,"new lights")
    check(#root:GetComponents("CollisionShape",true)==0,"new collision bodies")
    return vertices,batches,#root:GetChildren(true)
end
---@param actual CustomGeometry
---@param expected CustomGeometry
local function prefix(actual,expected,label)
    check(actual:GetNumVertices(0)>=expected:GetNumVertices(0),label.." original vertices lost")
    check(actual.castShadows==expected.castShadows and actual.drawDistance==expected.drawDistance,label.." shadow/LOD changed")
    for i=0,expected:GetNumVertices(0)-1 do
        local a,b=actual:GetVertex(0,i),expected:GetVertex(0,i)
        check((a.position-b.position):Length()<.000001,label.." old point moved "..i)
        check((a.normal-b.normal):Length()<.000001,label.." old normal changed "..i)
        check((a.texCoord-b.texCoord):Length()<.000001,label.." old UV changed "..i)
    end
end
---@param mat Material
---@param path string
local function finish(mat,path)
    check(mat:GetTechnique(0)==cache:GetResource("Technique","Techniques/PBR/PBRDiff.xml"),"unexpected technique")
    check(mat:GetNumTechniques()==1,"extra technique")
    check(mat:GetVertexShaderDefines()=="" and mat:GetPixelShaderDefines()=="","new shader define")
    check(mat:GetTexture(TU_DIFFUSE)==cache:GetResource("Texture2D",path),"not sharing preheated texture")
    check(mat:GetTexture(TU_NORMAL)==nil and mat:GetTexture(TU_SPECULAR)==nil,"new normal/spec texture")
    near(mat:GetShaderParameter("MatDiffColor"):GetColor().a,1,"alpha changed")
    check(mat:GetShaderParameter("MatEmissiveColor"):GetVector3():Length()<.000001,"surface falsely emits light")
end
---@param mat Material
---@param other Material
local function equalFinish(mat,other)
    check(mat~=other,"unexpected cross-module material alias")
    check(mat:GetTexture(TU_DIFFUSE)==other:GetTexture(TU_DIFFUSE),"Track/yard texture mismatch")
    local a,b=mat:GetShaderParameter("MatDiffColor"):GetColor(),other:GetShaderParameter("MatDiffColor"):GetColor()
    near(a.r,b.r,"Track/yard red");near(a.g,b.g,"Track/yard green");near(a.b,b.b,"Track/yard blue")
    near(mat:GetShaderParameter("Metallic"):GetFloat(),other:GetShaderParameter("Metallic"):GetFloat(),"Track/yard metallic")
    near(mat:GetShaderParameter("Roughness"):GetFloat(),other:GetShaderParameter("Roughness"):GetFloat(),"Track/yard roughness")
end
---@param geometry CustomGeometry
local function triangleKey(geometry,i)
    local rows={}
    for j=0,2 do
        local v=geometry:GetVertex(0,i+j)
        rows[#rows+1]=string.format("%.5f/%.5f/%.5f/%.5f/%.5f/%.5f/%.5f/%.5f",v.position.x,v.position.y,v.position.z,
            v.normal.x,v.normal.y,v.normal.z,v.texCoord.x,v.texCoord.y)
    end
    return table.concat(rows,"|")
end
-- 材质批转移不改变三角形/绕序/UV；全树多重集合保证不是把梁柱漏掉来省预算。
local function triangles(root)
    local result={}
    for _,g in ipairs(root:GetComponents("CustomGeometry",true)) do
        for i=0,g:GetNumVertices(0)-1,3 do
            local key=triangleKey(g,i);result[key]=(result[key] or 0)+1
        end
    end
    return result
end
local function infrastructureCase(before,a,b,label)
    local root=assert(scene_):CreateChild(label)
    local oldRoot,newRoot=root:CreateChild("Before"),root:CreateChild("Actual")
    local old=before.BuildChunk(oldRoot,a,b)
    local slice=os.clock()
    local started=os.clock()
    local returned=Infrastructure.BuildChunk(newRoot,a,b,function()
        maxSliceMs_=math.max(maxSliceMs_,(os.clock()-slice)*1000);slice=os.clock()
    end)
    maxBuildMs_=math.max(maxBuildMs_,(os.clock()-started)*1000)
    local nv,nb,nn=totals(newRoot)
    local ov,ob,on=totals(oldRoot)
    check(returned==nv and old==ov,"native/returned count mismatch")
    check(nb==ob and nn==on,"added infrastructure Node/batch")
    check(nv<=24000,"50m infrastructure >24k vertices")
    local added=nv-ov;maximumAdded_=math.max(maximumAdded_,added)
    check(added>=0 and added<=2160,"detail vertex budget >2160/50m")
    for _,g in ipairs(oldRoot:GetComponents("CustomGeometry",true)) do
        local actual=mesh(newRoot,g.node.name)
        prefix(actual,g,label.." "..g.node.name)
        if actual:GetNumVertices(0)>g:GetNumVertices(0) then
            check(g.node.name=="镀锌柱腕臂门架" or g.node.name=="排水沟暗底","unexpected batch grew")
            for i=g:GetNumVertices(0),actual:GetNumVertices(0)-1 do
                local v=actual:GetVertex(0,i)
                local _,s=Route.DistanceTo(v.position)
                local p=Route.Sample(s)
                local x=(v.position-p):DotProduct(Route.RightAt(s))
                local y=v.position.y-p.y
                check(y<1.32 and y>.14,"detail enters overhead/ground envelope")
                local cable=math.min(math.abs(x+2.85),math.abs(x-7.85))
                local cabinet=math.min(math.abs(x+3.85),math.abs(x-8.85))
                check(cable<=.211 or cabinet<=.311,"detail outside original maintenance footprint")
                check(v.normal:Length()>.999 and v.normal:Length()<1.001,"detail invalid normal")
                check(v.texCoord.x==v.texCoord.x and v.texCoord.y==v.texCoord.y,"NaN UV")
            end
        end
    end
    local data=Infrastructure.GetValidationData()
    if label:find("bridge",1,true) or label:find("tunnel",1,true) or label:find("station",1,true) then
        check(added==0,"ground details added to bridge/tunnel/station")
    end
    for _,signal in ipairs(data.signals) do check(signal.aspect=="red","unknown signal not red") end
    for _,spec in ipairs({{"镀锌柱腕臂门架","coach_steel.png"},{"混凝土基础沟槽","concrete.png"},
        {"防护网设备柜","coach_steel.png"},{"排水沟暗底","concrete.png"},{"路基石砌护坡","concrete.png"}}) do
        local mat=mesh(newRoot,spec[1]):GetMaterial(0)
        finish(mat,"Textures/Railway/"..spec[2])
        check(mat:GetShaderParameter("Roughness"):GetFloat()>=.75,"weathered finish mirror-like")
        check(mat~=World.Concrete(),"facility aliases global concrete")
    end
    print(string.format("[FacilityAppearance] CASE %s %.3f..%.3f old=%d new=%d added=%d batches=%d nodes=%d originalVertices=UNCHANGED",
        label,a,b,ov,nv,added,nb,nn))
    before.Forget(a,b);Infrastructure.Forget(a,b);root:Dispose();cases_=cases_+1
end
local function yardCase(before,st)
    local root=assert(scene_):CreateChild("Yard"..st.index)
    local oldRoot,newRoot=root:CreateChild("Before"),root:CreateChild("Actual")
    local old=before.Build(oldRoot,st)
    local actual=Yard.Build(newRoot,st)
    local ov,ob,on=totals(oldRoot)
    local nv,nb,nn=totals(newRoot)
    check(ov==nv and ob==nb and on==nn,"yard geometry/node/batch budget changed")
    check(actual.vertices==nv and actual.batches==nb and old.vertices==ov,"yard count accounting")
    local expected=triangles(oldRoot)
    for _,g in ipairs(newRoot:GetComponents("CustomGeometry",true)) do
        for i=0,g:GetNumVertices(0)-1,3 do
            local key=triangleKey(g,i)
            check((expected[key] or 0)>0,"yard triangle/UV/winding moved during batch transfer")
            expected[key]=expected[key]-1
        end
    end
    for _,remaining in pairs(expected) do check(remaining==0,"yard triangle lost") end
    local nearRoot=root:CreateChild("TrackWitness")
    Track.BuildChunk(nearRoot,st.s,st.s+12,true)
    local body,head=mesh(newRoot,"YardMaterial_3"):GetMaterial(0),mesh(newRoot,"YardMaterial_4"):GetMaterial(0)
    finish(body,"Textures/Railway/coach_steel.png");finish(head,"Textures/Railway/coach_steel.png")
    equalFinish(body,mesh(nearRoot,"SharedRailISections"):GetMaterial(0))
    equalFinish(head,mesh(nearRoot,"SharedRunningHeads"):GetMaterial(0))
    local frame=mesh(newRoot,"YardMaterial_7"):GetMaterial(0)
    finish(frame,"Textures/Railway/coach_steel.png")
    local c=frame:GetShaderParameter("MatDiffColor"):GetColor()
    check(c.r>.40 and c.g>.45 and c.b>.45,"yard structure made too dark/rusty")
    check(frame:GetShaderParameter("Roughness"):GetFloat()>=.79,"structure mirror-like")
    check(mesh(newRoot,"BridgeObstacle_7"):GetMaterial(0)==frame,"bridge not using structural finish")
    check(mesh(newRoot,"YardMaterial_1"):GetMaterial(0)~=World.Concrete(),"yard mutates global concrete")
    -- 轨腰批仅包含走行线/道岔与低矮缓冲器；信号架/天桥不准被染成锈轨。
    local rusty=mesh(newRoot,"YardMaterial_3")
    for i=0,rusty:GetNumVertices(0)-1 do
        local v=rusty:GetVertex(0,i).position
        local _,s=Route.DistanceTo(v)
        check(v.y-Route.Sample(s).y<1.1,"tall structural steel still uses rusty track finish")
    end
    local heads=Yard.GetSignalHeads();check(#heads==#before.GetSignalHeads(),"signal head count changed")
    for _,h in ipairs(heads) do check(h.aspect=="red","yard unknown authority not red") end
    Yard.UpdateSignals({GetBlockSignalAspect=function(_,lane) return lane==0 and "green" or "yellow" end})
    for _,h in ipairs(Yard.GetSignalHeads()) do check(h.aspect==(h.lane==0 and "green" or "yellow"),"per-head signal authority changed") end
    Yard.UpdateSignals(nil)
    for _,h in ipairs(Yard.GetSignalHeads()) do check(h.aspect=="red","missing authority leaves stale yard green") end
    print(string.format("[FacilityAppearance] YARD %d vertices=%d batches=%d nodes=%d triangleMultiset=UNCHANGED TrackFinish=MATCH signalFailSafe=PASS",
        st.index,nv,nb,nn))
    before.Forget(st.index);Yard.Forget(st.index);root:Dispose();cases_=cases_+1
end
-- WorldStream同样的所有权顺序：Forget -> 丢弃协程 -> Dispose；已取消任务绝不resume。
local function lifecycle(first)
    local root=assert(scene_):CreateChild("FacilityLifecycle")
    local sync=root:CreateChild("Sync")
    Infrastructure.BuildChunk(sync,first,first+50)
    local material=mesh(sync,"镀锌柱腕臂门架"):GetMaterial(0)
    local vertices,batches,nodes=totals(sync)
    Infrastructure.Forget(first,first+50)
    local yielded=root:CreateChild("Yielded")
    local slices=0
    local task=coroutine.create(function()
        Infrastructure.BuildChunk(yielded,first,first+50,function() coroutine.yield() end)
    end)
    while coroutine.status(task)~="dead" do
        local ok,err=coroutine.resume(task);check(ok,tostring(err));slices=slices+1
        check(slices<500,"unbounded facility coroutine")
    end
    local actualVertices,actualBatches,actualNodes=totals(yielded)
    check(actualVertices==vertices and actualBatches==batches and actualNodes==nodes,"yield changes facility budget")
    for _,g in ipairs(sync:GetComponents("CustomGeometry",true)) do
        local actual=mesh(yielded,g.node.name)
        prefix(actual,g,"facility sync/yield")
        check(actual:GetMaterial(0)==g:GetMaterial(0),"yield allocates a new material")
    end
    Infrastructure.Forget(first,first+50)
    sync:Dispose();yielded:Dispose()
    for cut=1,8 do
        local cancelled=root:CreateChild("Cancel"..cut)
        local work=coroutine.create(function()
            Infrastructure.BuildChunk(cancelled,first,first+50,function() coroutine.yield() end)
        end)
        for _=1,cut do
            if coroutine.status(work)~="dead" then local ok,err=coroutine.resume(work);check(ok,tostring(err)) end
        end
        Infrastructure.Forget(first,first+50);coroutine.close(work);cancelled:Dispose()
        check(Infrastructure.GetStats().loadedChunks==0 and Infrastructure.GetStats().signals==0,"cancel retains chunk/lamp reference")
    end
    check(#root:GetChildren(true)==0,"cancel retains child nodes")
    local recreated=root:CreateChild("Recreated")
    Infrastructure.BuildChunk(recreated,first,first+50)
    check(mesh(recreated,"镀锌柱腕臂门架"):GetMaterial(0)==material,"recreation disposed shared material")
    Infrastructure.Forget(first,first+50);recreated:Dispose()
    -- 站场也须能在任意前几个yield处取消并重新创建，不残留按站索引登记的entry。
    local st=assert(Route.GetStations()[3])
    for cut=1,4 do
        local cancelled=root:CreateChild("YardCancel"..cut)
        local work=coroutine.create(function() Yard.Build(cancelled,st,function() coroutine.yield() end) end)
        for _=1,cut do if coroutine.status(work)~="dead" then
            local ok,err=coroutine.resume(work);check(ok,tostring(err))
        end end
        Yard.Forget(st.index);coroutine.close(work);cancelled:Dispose()
        check(Yard.GetStats().stationCount==0 and #Yard.GetSignalHeads()==0,"cancel retains yard entry/lamps")
    end
    root:Dispose()
    print(string.format("[FacilityAppearance] LIFECYCLE sync=yielded slices=%d infrastructureCancellations=8 yardCancellations=4 recreation=shared PASS",slices))
end
local function rageCases(before)
    Infrastructure.Shutdown();before.Shutdown()
    Modes.Apply("rage");Route.Build();Landmarks.Init();Infrastructure.Init(scene_);before.Init(scene_)
    local graded=-1
    local supports=Infrastructure.GetValidationData().supports
    for _,support in ipairs(supports) do
        local first=math.floor(support.s/50)*50
        if support.mode=="ground" and math.abs(Route.GradeAt(first+25))>.01 then
            local clear=true
            for _,other in ipairs(supports) do
                if other.s>=first-60 and other.s<=first+110 and other.mode~="ground" then clear=false;break end
            end
            if clear then graded=first;break end
        end
    end
    check(graded>0,"missing actual rage ground grade >10permille")
    infrastructureCase(before,graded,graded+50,"rage_graded_ground")
    lifecycle(graded)
    print(string.format("[FacilityAppearance] RAGE_GRADE s=%.3f gradePermille=%.3f originalCatenaryAndFoundation=UNCHANGED PASS",
        graded,Route.GradeAt(graded+25)*1000))
end
local function run()
    scene_=Scene();scene_:CreateComponent("Octree")
    local concrete=World.Concrete()
    local color=concrete:GetShaderParameter("MatDiffColor"):GetColor()
    local roughness=concrete:GetShaderParameter("Roughness"):GetFloat()
    local oldInfra=baseline("/workspace/screenshots/facility_RailwayInfrastructure_before.lua")
    local oldYard=baseline("/workspace/screenshots/facility_StationYard_before.lua")
    Modes.Apply("normal");Route.Build();Landmarks.Init();Infrastructure.Init(scene_);oldInfra.Init(scene_)
    -- 正常模式包含10站；选一段带柜体的真实地面，另验车站、所有桥隧及非整点接缝。
    local ground=-1
    for s=2025,Route.GetLength()-100,200 do
        local clear=true
        for _,p in ipairs(Infrastructure.GetValidationData().supports) do
            if p.s>=s-30 and p.s<=s+80 and p.mode~="ground" then clear=false end
        end
        if clear then ground=s-25;break end
    end
    check(ground>0,"no ground cabinet fixture")
    infrastructureCase(oldInfra,ground,ground+50,"ground_cabinet")
    infrastructureCase(oldInfra,ground+50,ground+100,"ground_adjacent")
    infrastructureCase(oldInfra,ground+.17,ground+25.31,"phase_left")
    infrastructureCase(oldInfra,ground+25.31,ground+50.29,"phase_right")
    local st=Route.GetStations()[3]
    local station=math.floor(st.s/50)*50
    infrastructureCase(oldInfra,station,station+50,"station_portal")
    for _,def in ipairs(Landmarks.GetDefinitions()) do
        if def.kind=="bridge" or def.kind=="tunnel" then
            local s=math.floor(def.s/50)*50
            infrastructureCase(oldInfra,s,s+50,def.kind.."_"..def.id)
        end
    end
    ---@type table[]
    local stations=Route.GetStations()
    for index,stationData in ipairs(stations) do
        if index==1 or index==3 or index==#stations then yardCase(oldYard,stationData) end
    end
    rageCases(oldInfra)
    check(World.Concrete()==concrete,"global concrete identity changed")
    local after=concrete:GetShaderParameter("MatDiffColor"):GetColor()
    near(after.r,color.r,"global concrete.r");near(after.g,color.g,"global concrete.g");near(after.b,color.b,"global concrete.b")
    near(concrete:GetShaderParameter("Roughness"):GetFloat(),roughness,"global concrete roughness")
    print(string.format("ALL_FACILITY_APPEARANCE_CPU_PASS cases=%d checks=%d maxAddedVertices50m=%d addedNodes=0 addedBatches=0 maxBuildMs=%.3f maxSliceMs=%.3f targetMs=3 overTarget=%s graphics=NONE saveIO=NONE",
        cases_,checks_,maximumAdded_,maxBuildMs_,maxSliceMs_,tostring(maxSliceMs_>3)))
end
function Start()
    local ok,err=xpcall(run,debug.traceback)
    Infrastructure.Shutdown();Yard.Shutdown()
    if scene_ then scene_:Dispose();scene_=nil end
    Modes.Apply(originalMode_)
    if not ok then print("FACILITY_APPEARANCE_CPU_FAIL "..tostring(err));log:Write(LOG_ERROR,tostring(err)) end
    engine:Exit()
end
