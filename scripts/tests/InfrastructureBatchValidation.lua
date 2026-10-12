-- 基于现有设施模块脚手架：同一128m区间对照4×32m与1×128m。
-- 只验合批与几何等量，不把CPU离线检查当作真实渲染性能通过。
local Route=require "world.Route"
local Rail=require "world.RailNetwork"
local Infrastructure=require "world.Infrastructure"
local Config=require "config.GameConfig"
---@type Scene?
local scene_=nil
local checks_=0
local function check(value,message)
    checks_=checks_+1
    assert(value,message)
end
local function census(root)
    local vertices,meshes=0,0
    local bounds=BoundingBox()
    for _,geometry in ipairs(root:GetComponents("CustomGeometry",true)) do
        check(geometry.viewMask==2,"设施环境层被修改")
        for slot=0,geometry.numGeometries-1 do vertices=vertices+geometry:GetNumVertices(slot) end
        check(geometry:GetMaterial(0)~=nil,"设施材质被合批丢失")
        bounds:Merge(geometry:GetWorldBoundingBox())
        meshes=meshes+1
    end
    return vertices,meshes,bounds
end
function Start()
    local ok,message=xpcall(function()
        Route.Build()
        Rail.Reset(0,220,false)
        Infrastructure.Init()
        scene_=Scene()
        scene_:CreateComponent("Octree")
        check(Config.WorldStream.InfrastructureChunkLength==128,"生产设施块没有启用128m")
        local along=math.floor(Route.GetStations()[1].s/128)*128
        local ranges={along,4096,8192,16384,24576,math.floor((Route.GetLength()-256)/128)*128}
        local oldTotal,newTotal,slices=0,0,0
        for _,first in ipairs(ranges) do
            local small=scene_:CreateChild("Legacy32m")
            local combined=scene_:CreateChild("Combined128m")
            for index=0,3 do Infrastructure.BuildChunk(small:CreateChild("Small"..index),first+index*32,first+(index+1)*32) end
            local work=coroutine.create(function()
                Infrastructure.BuildChunk(combined,first,first+128,function() coroutine.yield() end)
            end)
            while coroutine.status(work)~="dead" do
                local resumed,err=coroutine.resume(work)
                check(resumed,"设施协程异常："..tostring(err))
                slices=slices+1
                check(slices<5000,"合批丢失有界yield")
            end
            local oldVertices,oldMeshes,oldBounds=census(small)
            local newVertices,newMeshes,newBounds=census(combined)
            check(oldVertices>0 and oldVertices==newVertices,string.format("设施合批删减或重复几何：%.0fm %d->%d",first,oldVertices,newVertices))
            check(newMeshes>0 and newMeshes<=9 and newMeshes<oldMeshes,"设施未减少提交节点")
            check((oldBounds.min-newBounds.min):Length()<.002 and (oldBounds.max-newBounds.max):Length()<.002,
                "导线/护栏/立柱实际包络被改变")
            oldTotal,newTotal=oldTotal+oldMeshes,newTotal+newMeshes
            print(string.format("[InfrastructureBatch] s=%.0f vertices=%d meshes=%d->%d",first,newVertices,oldMeshes,newMeshes))
            small:Dispose();combined:Dispose()
        end
        print(string.format("ALL_INFRASTRUCTURE_BATCH_PASS cases=%d meshes=%d->%d coroutineSlices=%d checks=%d",#ranges,oldTotal,newTotal,slices,checks_))
    end,debug.traceback)
    if not ok then log:Write(LOG_ERROR,tostring(message)) end
    engine:Exit()
end
