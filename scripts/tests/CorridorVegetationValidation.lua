-- CPU-only placement/stream regression; no viewport, graphics, audio or save I/O.
local Modes = require "config.GameModes"
local Route = require "world.Route"
local Terrain = require "world.Terrain"
local Landscape = require "world.Landscape"
local Vegetation = require "world.Vegetation"
local World = require "world.WorldMaterials"
local Landmarks = require "world.Landmarks"
local Stream = require "world.WorldStream"
local Config = require "config.GameConfig"
---@type Scene?
local scene_ = nil
local function check(value,message) assert(value,"[CorridorVegetation] "..message) end
local function baseline()
    for _,s in ipairs({2400,4200,6000,6400,9600,15000}) do
        local counts={0,0,0}
        for layer,band in ipairs({{41,58,10},{116,178,13},{325,440,16}}) do
            local rejected={rail=0,structure=0,city=0,yard=0,nature=0}
            for ds=0,144,16 do
                for _,side in ipairs({-1,1}) do
                    local pos=Route.SampleOffset(s+ds,side*(band[1]+band[2])*.5,0)
                    local asset=assert(Vegetation.GetAsset("treeA"))
                    local _,r=Vegetation.Measure(asset,band[3])
                    if not Route.CanPlaceFootprint(pos,r,30) then rejected.rail=rejected.rail+1
                    elseif Landmarks.Reserves(pos,r) then rejected.structure=rejected.structure+1
                    elseif Landscape.InCity(pos,r) then rejected.city=rejected.city+1
                    elseif Landscape.InStationYard(pos,r) then rejected.yard=rejected.yard+1
                    elseif Landscape.ReservesNature(pos,r) then rejected.nature=rejected.nature+1
                    else counts[layer]=counts[layer]+1 end
                end
            end
            print(string.format("[CorridorVegetation] BASE s=%d layer=%d accepted=%d/20 rail=%d structure=%d city=%d yard=%d nature=%d",s,layer,counts[layer],rejected.rail,rejected.structure,rejected.city,rejected.yard,rejected.nature))
        end
    end
end
function Start()
    local ok,err=xpcall(function()
        Modes.Apply("normal");Route.Build();Terrain.Init()
        for _,kind in ipairs({"treeA","treeB","treeC","treeD","treeE","treeF","treeG","bush","grass"}) do
            local asset=assert(Vegetation.GetAsset(kind))
            print(string.format("[CorridorVegetation] BBOX %s %.3f %.3f %.3f",kind,asset.bounds.size.x,asset.bounds.size.y,asset.bounds.size.z))
            for slot=0,asset.model.numGeometries-1 do
                local values={}
                for lod=0,asset.model:GetNumGeometryLodLevels(slot)-1 do
                    local geom=asset.model:GetGeometry(slot,lod)
                    values[#values+1]=tostring(lod).."="..geom.indexCount/3
                end
                print("[CorridorVegetation] LOD "..kind.." slot="..slot.." "..table.concat(values,","))
            end
        end
        if os.getenv("CORRIDOR_BASELINE")=="1" then baseline();return end
        scene_=Scene();scene_:CreateComponent("Octree")
        if os.getenv("CORRIDOR_STREAM")=="1" then
            local before=os.clock()
            local root=Stream.Build(scene_,4216.65)
            print(string.format("[CorridorVegetation] STREAM_BUILD %.3fs terrain=%d near=%d middle=%d distant=%d",os.clock()-before,Stream.GetStats().terrainChunks,Stream.GetStats().vegetationChunks,Stream.GetStats().woodlandChunks,Stream.GetStats().forestChunks))
            local budget=Config.WorldStream.FrameBudgetMs
            local readyFrames=0
            for frame=1,1800 do
                Stream.Update(4216.65,1/60)
                local all=true
                for _,kind in ipairs({"vegetation","woodland","forest"}) do
                    local step=kind=="vegetation" and 80 or 160
                    for index=math.floor(4216.65/step),math.floor((4216.65+640)/step) do
                        local node=root:GetChild(kind.."_"..index)
                        if not node or not node.enabled then all=false end
                    end
                end
                if all then readyFrames=frame;break end
            end
            check(readyFrames>0,"forward layered vegetation starved under production budget")
            check(Config.WorldStream.FrameBudgetMs==budget and budget==3,"changed production frame budget")
            local stats=Stream.GetStats()
            print(string.format("ALL_CORRIDOR_STREAM_CPU_PASS frames=%d seconds=%.2f terrain=%d near=%d middle=%d distant=%d lastMs=%.3f maxSliceMs=%.3f",readyFrames,readyFrames/60,stats.terrainChunks,stats.vegetationChunks,stats.woodlandChunks,stats.forestChunks,stats.lastUpdateMs,stats.maxTaskMs))
            local gapFrames=0
            for frame=1,1800 do
                local s=4216.65+frame*(113/3.6)/60
                Stream.Update(s,1/60)
                local ready=true
                for _,kind in ipairs({"vegetation","woodland","forest"}) do
                    local step=kind=="vegetation" and 80 or 160
                    for index=math.floor(s/step),math.floor((s+320)/step) do
                        local node=root:GetChild(kind.."_"..index)
                        if not node or not node.enabled then ready=false end
                    end
                end
                if not ready then gapFrames=gapFrames+1 end
            end
            check(gapFrames==0,"113km/h front 320m vegetation not ready frames="..gapFrames)
            print("ALL_CORRIDOR_DRIVING_CPU_PASS speedKmh=113 seconds=30 missingFrontFrames="..gapFrames)
            Stream.Shutdown()
            check(Terrain.GetPlantingStats().accepted==0,"shutdown leaked planting records")
            return
        end
        if os.getenv("CORRIDOR_PLANT_ONLY")~="1" then
            -- 同相位新地表合同由真实CG逐点/面积/世界UV验收，不把3.2换成另一个元数据常数。
            require("tests.GroundSurfaceValidation").CheckSurfaceContract(assert(scene_))
        end
        ---@type table<number, {layers:table<string,number>,accepted:number}>
        local sampleData={}
        for _,s in ipairs({2400,4160,4320,6000,6400,9600,15000,36000}) do
            local owner=scene_:CreateChild("CorridorFixture_"..s)
            local before=os.clock()
            Terrain.BuildTrees(owner,s,s+160)
            local buildMs=(os.clock()-before)*1000
            local data=Terrain.GetPlantingStats().chunks
            local target=nil ---@type table?
            for _,candidate in ipairs(data) do if candidate.first==s then target=candidate end end
            local actual=assert(target)
            sampleData[s]=actual
            for _,record in ipairs(actual.records) do
                check(record.s>=s and record.s<s+160,"tree belongs to another chunk")
                local pos=Vector3(record.x,0,record.z)
                check(Route.CanPlaceFootprint(pos,record.radius,30),"tree violates railway clearance")
                check(not Terrain.GetPlantingBlockReason(pos,record.radius),"tree overlaps protected field/city/structure")
                local expected=Terrain.GetGroundHeight(record.x,record.z)
                check(math.abs(record.y-expected)<.04,"roots detached from actual terrain")
            end
            print(string.format("[CorridorVegetation] BUILT s=%d accepted=%d/%d grass=%d bushes=%d near=%d middle=%d distant=%d fieldRejected=%d structureRejected=%d cityRejected=%d groups=%d CPUms=%.1f",s,actual.accepted,actual.attempted,
                actual.layers.grass or 0,actual.layers.bush or 0,actual.layers.near or 0,actual.layers.middle or 0,actual.layers.distant or 0,
                actual.rejected.field or 0,actual.rejected.structure or 0,actual.rejected.city or 0,actual.groups,buildMs))
            local groups=owner:GetComponents("StaticModelGroup",true)
            local triangleBudget,batches=0,0
            for _,group in ipairs(groups) do
                local model=group.model
                for slot=0,model.numGeometries-1 do
                    triangleBudget=triangleBudget+model:GetGeometry(slot,0).indexCount/3*group.numInstanceNodes
                    batches=batches+1
                end
            end
            print(string.format("[CorridorVegetation] BUDGET s=%d instances=%d groups=%d batches=%d trianglesLOD0=%.0f",s,actual.accepted,#groups,batches,triangleBudget))
            owner:Dispose();Terrain.ForgetTrees(s,s+160)
        end
        for _,s in ipairs({4160,4320}) do
            local data=sampleData[s]
            check((data.layers.grass or 0)>35 and (data.layers.bush or 0)>35,"actual screenshot corridor has no near grass/shrubs")
            check((data.layers.near or 0)>5 and (data.layers.distant or 0)>25,"screenshot corridor still lacks grouped trees/background forest")
        end
        check((sampleData[9600].layers.near or 0)==0 and (sampleData[9600].layers.middle or 0)==0,"trees planted inside real tunnel")
        check(sampleData[6400].accepted==0,"trees planted in station/city reservation")
        if os.getenv("CORRIDOR_PLANT_ONLY")=="1" then
            print("ALL_CORRIDOR_PLACEMENT_CPU_PASS noGraphics=true terrainSurfaceChecks=separate")
            return
        end
        local hillSamples=0
        for _,s in ipairs({4320,12000,15000}) do
            for _,lat in ipairs({-550,-450,450,550}) do
                local pos=Route.SampleOffset(s,lat,0)
                local owner=scene_:CreateChild("GroundFixture")
                Terrain.BuildCell(owner,math.floor(pos.x/160),math.floor(pos.z/160),160)
                local expected=Terrain.GetGroundHeight(pos.x,pos.z)
                if expected>.01 then hillSamples=hillSamples+1 end
                print(string.format("[CorridorVegetation] GROUND s=%d lat=%d y=%.3f meshes=%d",s,lat,expected,#owner:GetComponents("CustomGeometry",true)))
                owner:Dispose()
            end
        end
        check(hillSamples>0,"old plain hill interpolation never reaches submitted slopes")
        print("ALL_CORRIDOR_VEGETATION_CPU_PASS noGraphics=true noSaveIO=true")
    end,debug.traceback)
    if not ok then print("[CorridorVegetation] FAILED "..tostring(err));log:Write(LOG_ERROR,tostring(err)) end
    Terrain.Shutdown()
    if scene_ then scene_:Dispose();scene_=nil end
    engine:Exit()
end
