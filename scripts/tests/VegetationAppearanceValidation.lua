-- 独立CPU植被合同；不创建viewport、不读写存档、不作像素/着色器通过声明。
local Modes=require "config.GameModes"
local Route=require "world.Route"
local Terrain=require "world.Terrain"
local Planting=require "world.CorridorPlanting"
local Vegetation=require "world.Vegetation"
---@type Scene?
local scene_=nil
local checks_=0
local function check(value,message)
    checks_=checks_+1
    assert(value,"[VegetationAppearance] "..message)
end
local SHARED="RailwayVegetation/Environment/Vegetation/Trees/Shared/Materials/"
local sources={treeA="Tree01_Leaves.xml",treeB="Tree19_Leaves.xml",treeC="Tree01_Leaves.xml",
    treeD="Tree19_Leaves.xml",treeE="Tree01_Leaves.xml",treeF="Tree19_Leaves.xml",treeG="Tree01_Leaves.xml"}
local function sourceChecks()
    local colors={}
    for _,kind in ipairs(Vegetation.TreeKinds) do
        local uri=SHARED..sources[kind]
        local original=assert(cache:GetResource("Material",uri))
        local before=original:GetShaderParameter("MatDiffColor"):GetColor()
        local asset=assert(Vegetation.GetAsset(kind))
        local material=asset.materials[2]
        check(material~=original,"cache source used as mutable runtime material "..kind)
        check(material:GetTechnique(0)==original:GetTechnique(0),"Technique replaced "..kind)
        check(material.vertexShaderDefines==original.vertexShaderDefines
            and material.pixelShaderDefines==original.pixelShaderDefines,"shader variants changed "..kind)
        check(material.cullMode==original.cullMode and material.shadowCullMode==original.shadowCullMode
            and material.alphaToCoverage==original.alphaToCoverage,"alpha/cull state changed "..kind)
        for _,unit in ipairs({TU_DIFFUSE,TU_NORMAL,TU_SPECULAR}) do
            check(material:GetTexture(unit)==original:GetTexture(unit),"texture source replaced "..kind)
        end
        local after=original:GetShaderParameter("MatDiffColor"):GetColor()
        check(before.r==after.r and before.g==after.g and before.b==after.b and before.a==after.a,
            "cache source color mutated "..kind)
        local color=material:GetShaderParameter("MatDiffColor"):GetColor()
        colors[string.format("%.3f/%.3f/%.3f",color.r,color.g,color.b)]=true
        for slot=0,asset.model.numGeometries-1 do
            local levels=asset.model:GetNumGeometryLodLevels(slot)
            for lod=0,levels-1 do
                local geometry=asset.model:GetGeometry(slot,lod)
                check(geometry.indexCount>0 and geometry.vertexCount>0,"empty source geometry "..kind)
                check(geometry:GetVertexBuffer(0)~=nil and geometry:GetIndexBuffer()~=nil,"missing buffers "..kind)
                print(string.format("[VegetationAppearance] SOURCE kind=%s slot=%d lod=%d triangles=%.0f distance=%.2f",
                    kind,slot,lod,geometry.indexCount/3,geometry.lodDistance))
            end
        end
        -- 完整网格根点到土面的真实变换，而非只核统计record.y。
        local root=assert(scene_):CreateChild("RootTransform_"..kind)
        local batch=Vegetation.NewBatch(root)
        local scale=Vegetation.Measure(asset,8.7)
        local center=Vector3(137,3.25,91)
        batch:Add(asset,center,scale,137)
        local instance=assert(root:GetChild(asset.name.."_Instance"))
        local bottom=instance.position+instance.rotation*(Vector3(asset.bounds.center.x,asset.bounds.min.y,asset.bounds.center.z)*scale)
        check((bottom-center):Length()<.0001,"real model root detached "..kind)
        root:Dispose()
    end
    local count=0
    for _ in pairs(colors) do count=count+1 end
    check(count==3,"leaf palette not bounded to three shared tones")
    check(Vegetation.GetAsset("treeA").materials[2]==Vegetation.GetAsset("treeG").materials[2],"same-source tone not shared")
end
local function records(first,last,layer)
    for _,chunk in ipairs(Planting.GetCorridorStats().chunks) do
        if chunk.first==first and chunk.last==last and chunk.layer==(layer or "all") then return chunk end
    end
    error("missing planting fixture")
end
local function identity(record)
    return string.format("%s/%s/%.8f/%.8f/%.8f/%.8f",record.kind,record.species,record.s,record.lateral,record.height,record.yaw)
end
local function setOf(data)
    local set={}
    for _,record in ipairs(data.records) do
        local key=identity(record)
        check(not set[key],"duplicate candidate in half-open fixture")
        set[key]=true
    end
    return set
end
local function placementChecks()
    local scene=assert(scene_)
    local options={density=1,treeDistance=430,shadows=false,ground=Terrain.GetGroundHeight,
        blocked=Terrain.GetPlantingBlockReason,forest=Vegetation.GetAsset}
    local fullRoot=scene:CreateChild("WholeFixture")
    Planting.BuildCorridor(fullRoot,4160,4320,options)
    local full=records(4160,4320)
    local expected=setOf(full)
    local splitRoot=scene:CreateChild("SplitFixture")
    Planting.BuildCorridor(splitRoot,4160,4240,options)
    Planting.BuildCorridor(splitRoot,4240,4320,options)
    local combined={}
    for _,data in ipairs({records(4160,4240),records(4240,4320)}) do
        for _,record in ipairs(data.records) do
            check(record.s>=data.first and record.s<data.last,"half-open ownership broken")
            local key=identity(record)
            check(expected[key] and not combined[key],"split changed or duplicated candidate")
            combined[key]=true
        end
    end
    for key in pairs(expected) do check(combined[key],"split lost candidate") end
    local cover={}
    local sparse={near=0,middle=0,distant=0}
    local treeCounts={near=0,middle=0,distant=0}
    local function recordCover(record)
        cover[record.species]=true
        if treeCounts[record.kind] then
            treeCounts[record.kind]=treeCounts[record.kind]+1
            if record.species=="treeB" or record.species=="treeF" then sparse[record.kind]=sparse[record.kind]+1 end
        end
    end
    local minHeight,maxHeight=math.huge,0
    local sides={left=0,right=0}
    local layers={}
    for _,record in ipairs(full.records) do
        local pos=Vector3(record.x,0,record.z)
        check(Route.CanPlaceFootprint(pos,record.radius,30),"railway clearance changed")
        check(not Terrain.GetPlantingBlockReason(pos,record.radius),"protected reservation overlap")
        local ground=Terrain.GetGroundHeight(record.x,record.z)
        if record.kind=="grass" or record.kind=="bush" then
            check(record.y<=ground+.001 and ground-record.y<record.height*.75+.15,"low roots not embedded safely")
        else
            check(math.abs(record.y-ground)<.0001,"tree root not on real ground")
            minHeight=math.min(minHeight,record.height);maxHeight=math.max(maxHeight,record.height)
            recordCover(record)
        end
        local side=record.lateral<0 and "left" or "right"
        sides[side]=sides[side]+1
        layers[record.kind]=(layers[record.kind] or 0)+1
    end
    check(sides.left>100 and sides.right>100,"one corridor side lost vegetation")
    for _,layer in ipairs({"grass","bush","near","middle","distant"}) do check((layers[layer] or 0)>10,"missing layer "..layer) end
    check(maxHeight-minHeight>10,"canopy height range collapsed")
    check(full.accepted<1000 and full.groups<=55,"instance/group budget exceeded")
    fullRoot:Dispose();splitRoot:Dispose();Planting.ResetCorridor()
    -- 半途取消与生产stream同样丢弃协程、Dispose owner、Forget对应数据，不恢复已删owner。
    local cancelRoot=scene:CreateChild("CancelFixture");cancelRoot.enabled=false
    local task=coroutine.create(function()
        Planting.BuildCorridor(cancelRoot,4160,4320,options,function() coroutine.yield() end)
    end)
    check(coroutine.resume(task),"paused builder failed")
    check(coroutine.status(task)=="suspended","builder did not yield")
    check(records(4160,4320).accepted>0,"cancellation did not interrupt a partial build")
    cancelRoot:Dispose();Planting.ForgetCorridor(4160,4320)
    check(Planting.GetCorridorStats().accepted==0 and #Planting.GetCorridorStats().chunks==0,"cancel leaked records")
    coroutine.close(task)
    local rebuiltRoot=scene:CreateChild("RebuiltFixture")
    Planting.BuildCorridor(rebuiltRoot,4160,4320,options)
    local rebuilt=records(4160,4320)
    check(rebuilt.accepted==full.accepted and rebuilt.groups==full.groups,"cancel rebuild budget changed")
    local actual=setOf(rebuilt)
    for key in pairs(expected) do check(actual[key],"cancel rebuild changed placement") end
    -- 七种源模型在sourceChecks逐种验证；实种只要求五种经真实LOD对照适宜的主形。
    for _,first in ipairs({2400,4320,6000,15000}) do
        local root=scene:CreateChild("CoverageFixture")
        Planting.BuildCorridor(root,first,first+160,options)
        local data=records(first,first+160)
        for _,record in ipairs(data.records) do recordCover(record) end
        root:Dispose();Planting.ForgetCorridor(first,first+160)
    end
    for _,kind in ipairs({"treeA","treeC","treeD","treeE","treeG"}) do check(cover[kind],"suitable primary tree absent "..kind) end
    check(sparse.middle==0 and sparse.distant==0,"sparse B/F planted as background woodland")
    check(sparse.near<=treeCounts.near*.08,"sparse B/F exceeds 8 percent near-layer accent budget")
    print(string.format("[VegetationAppearance] SPARSE_BF near=%d/%d middle=%d/%d distant=%d/%d sourceCatalog=7 suitablePlanted=5",
        sparse.near,treeCounts.near,sparse.middle,treeCounts.middle,sparse.distant,treeCounts.distant))
    print(string.format("[VegetationAppearance] PLACEMENT instances=%d groups=%d left=%d right=%d treeHeight=%.2f..%.2f fiveSuitableSpecies=true halfOpen=true cancellation=true",
        full.accepted,full.groups,sides.left,sides.right,minHeight,maxHeight))
    rebuiltRoot:Dispose();Planting.ResetCorridor()
end
function Start()
    local ok,message=xpcall(function()
        Modes.Apply("normal");Route.Build();Terrain.Init()
        scene_=Scene();scene_:CreateComponent("Octree")
        sourceChecks();placementChecks()
        print("ALL_VEGETATION_APPEARANCE_CPU_PASS checks="..checks_.." noGraphics=true visualLeafCoverageNotProven=true")
    end,debug.traceback)
    if not ok then print("VEGETATION_APPEARANCE_CPU_FAIL "..tostring(message));log:Write(LOG_ERROR,tostring(message)) end
    Terrain.Shutdown()
    if scene_ then scene_:Dispose();scene_=nil end
    engine:Exit()
end
