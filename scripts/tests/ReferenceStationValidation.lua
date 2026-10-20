-- Derived from scaffold-3d-scene + existing StationCanopyValidation.
-- Builds the real production station, not a substitute mock. Main agent runs this entry.
-- Checks all graded identities, real roof/track/aisle/stair clearance and reduced budgets.
local Route = require "world.Route"
local Modes = require "config.GameModes"
local Station = require "world.Station"
local Yard = require "world.StationYard"
local Reference = require "world.ReferenceStation"
local World = require "world.WorldMaterials"
local Night = require "world.NightLighting"
local Buildings = require "world.StationBuildings"
local Config = require "config.StationVisualConfig"
local VisualQuality = require "config.VisualQuality"
---@type Scene?
local scene_ = nil
---@type Node?
local root_ = nil
---@type Node?
local eye_ = nil
---@type Camera?
local camera_ = nil
---@type Light?
local sun_ = nil
---@type Zone?
local zone_ = nil
local index_,view_,age_,checks_,captures_ = 1,1,0,0,0
local checked_,failed_ = false,false
local VIEWS = {"platform_day","truss_detail","overview","platform_night"}
local firstStation_,lastStation_=1,5
---@type integer[]
local captureViews_={1,2,3,4}
local captureViewIndex_=1
local geometryOnly_=false
local mode_="normal"
-- Optional bounded acceptance subsets. CPU defaults to every station in the selected mode.
for _,arg in ipairs(GetArguments()) do
    local mode=arg:match("^%-mode=(.+)$")
    if mode then assert(mode=="normal" or mode=="rage");mode_=mode end
    if arg=="-graphicsheadless" or arg=="-geometry-only" then geometryOnly_=true end
    local station=tonumber(arg:match("^%-index=(%d+)$"))
    local wantedView=arg:match("^%-view=(.+)$")
    if station then
        assert(station>=1 and station<=#Config.Stations,"-index must name an existing station")
        firstStation_,lastStation_=math.floor(station),math.floor(station)
    end
    if wantedView then
        local found=false
        for i,name in ipairs(VIEWS) do
            if wantedView==name or wantedView==tostring(i) then captureViews_={i};found=true;break end
        end
        assert(found,"unknown -view; use platform_day/truss_detail/overview/platform_night")
    end
end
for _,arg in ipairs(GetArguments()) do
    if arg=="-graphicssurfaceless" then geometryOnly_=false end
end
local function check(value,message)
    checks_=checks_+1
    assert(value,"[ReferenceStationValidation] "..message)
end
local function guarded(action)
    if failed_ then return end
    local ok,err=xpcall(action,debug.traceback)
    if not ok then failed_=true;print("REFERENCE_STATION_FAILED "..tostring(err));log:Write(LOG_ERROR,tostring(err));engine:Exit() end
end
local function unload()
    Station.Forget(index_)
    Yard.Forget(index_)
    if root_ then root_:Dispose();root_=nil end
    check(Reference.GetStats(index_)==nil,"unloaded station retains reference stats")
    for _,site in ipairs(Night.GetSites()) do
        check(site.owner~="station:"..index_,"unloaded station retains pooled lamp site")
    end
end
local function activate(index)
    if root_ then unload() end
    index_,view_,age_,checked_=index,assert(captureViews_[1]),0,false
    captureViewIndex_=1
    local st=assert(Route.GetStations()[index])
    Station.SetEnvironment(1) -- New streamed station must inherit current night factor.
    root_=assert(scene_):CreateChild("ReferenceStationAcceptance")
    Station.BuildOne(root_,st)
    Yard.Build(root_,st)
end
-- Isolated CPU witnesses call the real world batch writer, including all twelve
-- box triangles. Do not infer a winding bug from brightness in a screenshot.
local function batchSurfaceChecks()
    local owner=assert(scene_):CreateChild("WorldBatchSurfaceWitness")
    local mat=World.Solid(Color(.35,.37,.36),0,.9)
    local faceDotMin=1.0
    for _,yaw in ipairs({0,.63,1.57,-1.13}) do
        local target=World.NewBatch(owner:CreateChild("Box"),mat,false,1)
        local center,size=Vector3(12,3,-8),Vector3(.36,4.8,.44)
        target:AddBox(center,size,yaw)
        check(target:Finish()==36,"world box no longer contains exactly six faces")
        for face=0,5 do
            for triangle=0,1 do
                local offset=face*6+triangle*3
                local a=target.geometry:GetVertex(0,offset)
                local b=target.geometry:GetVertex(0,offset+1)
                local c=target.geometry:GetVertex(0,offset+2)
                local outward=((a.position+b.position+c.position)/3-center):Normalized()
                local cross=(b.position-a.position):CrossProduct(c.position-a.position):Normalized()
                check(cross:DotProduct(outward)>0,"world box face points into the box")
                for _,vertex in ipairs({a,b,c}) do
                    local alignment=vertex.normal:DotProduct(cross)
                    faceDotMin=math.min(faceDotMin,alignment)
                    check(alignment>.9999,"world box vertex normal disagrees with face winding")
                    check(math.abs(vertex.normal:Length()-1)<.0001,"world box normal not unit length")
                end
            end
        end
    end
    local target=World.NewBatch(owner:CreateChild("UVPhase"),mat,false,1)
    target:AddQuad(Vector3(0,0,0),Vector3(0,0,2),Vector3(3,0,2),Vector3(3,0,0),Vector2(.37,.61))
    check(target:Finish()==6,"UV phase changed triangle count")
    local a,b,c,d=target.geometry:GetVertex(0,0),target.geometry:GetVertex(0,1),
        target.geometry:GetVertex(0,2),target.geometry:GetVertex(0,5)
    check((a.texCoord-Vector2(.37,.61)):Length()<.0001,"quad UV origin ignored")
    check((b.texCoord-Vector2(.37,2.61)):Length()<.0001,"quad metre UV V scale wrong")
    check((c.texCoord-Vector2(3.37,2.61)):Length()<.0001 and (d.texCoord-Vector2(3.37,.61)):Length()<.0001,
        "quad triangles do not retain continuous metre UVs")
    print(string.format("[ReferenceStationValidation] BOX_NORMALS faces=24 triangles=48 minAlignment=%.6f UV_PHASE=PASS",faceDotMin))
    owner:Dispose()
end
---@param node Node
local function materialChecks(node)
    local function geometry(name)
        return assert(assert(node:GetChild(name)):GetComponent("CustomGeometry"))
    end
    local top=geometry("ReferenceMetalCanopySheets")
    local soffit=geometry("ReferenceCorrugatedRoofRibs")
    local frame=geometry("ReferenceWhiteColumnsAndTrusses")
    local connectors=geometry("ReferenceSteelConnectionsDrainage")
    local topMat,soffitMat=top:GetMaterial(),soffit:GetMaterial()
    local topColor=topMat:GetShaderParameter("MatDiffColor"):GetColor()
    local bottomColor=soffitMat:GetShaderParameter("MatDiffColor"):GetColor()
    check(topColor.r-bottomColor.r>.15,"roof top/soffit share an indistinguishable finish")
    check(soffit.drawDistance==top.drawDistance,"long roof loses its underside in the mid distance")
    for _,item in ipairs({top,soffit,frame,connectors}) do
        local mat=item:GetMaterial()
        check(mat:GetTexture(TU_DIFFUSE)~=nil,"canopy finish has no verified local texture")
        check(mat:GetShaderParameter("Roughness"):GetFloat()>=.70,"canopy finish has mirror-like roughness")
        check(mat:GetShaderParameter("MatEmissiveColor"):GetVector3():Length()<.0001,"canopy finish falsely emits light")
        check(mat:GetTexture(TU_NORMAL)==nil,"canopy silently requires an unverified normal shader variant")
    end
    check(frame:GetMaterial():GetShaderParameter("Metallic"):GetFloat()==0,"painted I-column treated as bare metal")
    for vertex=0,soffit:GetNumVertices(0)-1 do
        check(soffit:GetVertex(0,vertex).normal.y<-.9,"soffit batch contains floating non-sheet strips")
    end
    local stone=geometry("ReferenceGranitePavers_1"):GetMaterial():GetShaderParameter("MatDiffColor"):GetColor()
    local coping=geometry("ReferenceGranitePavers_4"):GetMaterial():GetShaderParameter("MatDiffColor"):GetColor()
    check(coping.r-stone.r>.20,"platform coping has no distinct stone finish")
    -- 灯壳/栏杆/候车框为同一拉丝材质；发光仅属于独立灯罩批，不整架发白。
    local furniture=geometry("ReferenceSuspendedSignFrames"):GetMaterial()
    local railings=geometry("ReferenceLampHousingsAndRailings"):GetMaterial()
    local furnitureColor=furniture:GetShaderParameter("MatDiffColor"):GetColor()
    check(furniture==railings,"站台家具重复创建不同金属材质")
    check(furniture:GetTexture(TU_DIFFUSE)~=nil and furniture:GetTexture(TU_NORMAL)==nil,
        "站台金属未使用本地受支持纹理")
    check(furnitureColor.r<.31 and furnitureColor.g<.34 and furnitureColor.b<.35,
        "站台栏杆/家具恢复成亮白纯色")
    check(furniture:GetShaderParameter("Roughness"):GetFloat()>=.75
        and furniture:GetShaderParameter("MatEmissiveColor"):GetVector3():Length()<.0001,
        "家具金属发光或过于镜面")
    check(geometry("ReferenceLinearLampDiffusers"):GetMaterial()~=furniture,
        "真实夜间灯罩被家具材质替换")
    print(string.format("[ReferenceStationValidation] MATERIAL_TIERS topR=%.3f soffitR=%.3f stoneR=%.3f copingR=%.3f localTextures=4 noNewNormals=true",
        topColor.r,bottomColor.r,stone.r,coping.r))
end
local function geometryChecks()
    local st=assert(Route.GetStations()[index_])
    local root=assert(root_)
    local node=assert(root:GetChild("Station_"..st.name))
    materialChecks(node)
    local stats=assert(Reference.GetStats(index_))
    local plan=Reference.GetPlan(st)
    print(string.format("[ReferenceStationValidation] PRE_BUDGET %s batches=%d/%d vertices=%d/%d",
        st.name,stats.batches,plan.maxBatches,stats.vertices,plan.maxVertices))
    for _,child in ipairs(node:GetChildrenWithComponent("CustomGeometry",true)) do
        if child.name:match("^Reference") and child.parent==node then
            local geometry=assert(child:GetComponent("CustomGeometry"))
            print(string.format("[ReferenceStationValidation] BATCH %s vertices=%d",child.name,geometry:GetNumVertices(0)))
        end
    end
    check(stats.batches<=plan.maxBatches,"platform detail draw-node budget exceeded")
    check(stats.vertices<=plan.maxVertices,"platform detail vertex budget exceeded")
    check(stats.labels<=plan.maxTextLabels and stats.labels==18*#plan.signOffsets+6,"graded suspended sign text count incorrect")
    check(stats.clocks==6*#plan.signOffsets and stats.ledBoards==3*#plan.signOffsets
        and stats.adverts==3*#plan.advertOffsets,"graded clock/LED/advert missing on one platform")
    check(stats.trusses==stats.columns,"supporting portals/trusses missing")
    check(stats.roofRibs>0,"real standing seams missing")
    check(stats.roofFirst>=Route.PlatformStart+6 and stats.roofLast<=57,"roof not fitted to route/stair approach")
    check(plan.roofRibStep>=.8 and plan.columnStep<=16,"reduced seam/support budget violated")
    check(Station.GetDimensions().sideGap>=.20,"train/platform boarding gap changed")
    local expectedColumns=0
    for _,segment in ipairs(plan.roofSegments) do
        expectedColumns=expectedColumns+3*(math.ceil((segment.last-segment.first-4)/plan.columnStep)+1)
    end
    check(stats.columns==expectedColumns,"support rhythm does not cover every separate roof segment")
    check(stats.batches<=20 and stats.vertices<=math.ceil(180000*math.max(1,(Route.PlatformEnd-Route.PlatformStart)/310)),"reduced hard geometry budget exceeded")
    check(#node:GetChildrenWithComponent("Light",true)==0,"per-fixture Lights bypass night pool")
    check(node:GetChild("UpPlatformCanopy")==nil,"old glass canopy/V supports still generated")
    check(node:GetChild("CityProfileCanopies")==nil,"old low-detail roof duplicates new roof")
    check(stats.identity==Config.GetStation(index_).key,"five-station identity overwritten")
    local house=assert(node:GetChild("StationHouse"))
    check(house:GetChild("ReferenceStationGlazedGallery")~=nil,"glass station-house gallery missing")
    check(#Station.GetPlacementData()==1 and Station.GetPlacementData()[1].clearance>=25,"station house clearance changed")
    local expectedArchetypes={"palace","tower","gate","block","terminal","palace","gate","tower","block","terminal"}
    check(Buildings.Styles[index_].archetype==expectedArchetypes[index_],"historic station-house identity lost")
    local referenceNodes=0
    for _,child in ipairs(node:GetChildrenWithComponent("CustomGeometry",true)) do
        if child.name:match("^Reference") and child.parent==node then
            referenceNodes=referenceNodes+1
            local geometry=assert(child:GetComponent("CustomGeometry"))
            check(geometry.viewMask==2,"new geometry changed environment visibility mask")
            check(geometry:GetNumVertices(0)>0,"empty reference geometry node")
        end
    end
    check(referenceNodes==stats.batches,"batch statistics do not match real geometry")
    -- Real production triangle queries, NOT only configuration-box checks.
    local octree=assert(assert(scene_):GetComponent("Octree"))
    for _,ds in ipairs({-180,-102,-24,42}) do
        for _,lane in ipairs({-10.8,0,5,16.6,22.4}) do
            local hit=octree:RaycastSingle(Ray(Route.SampleOffset(st.s+ds,lane,3.6),Vector3.UP),RAY_TRIANGLE,5,DRAWABLE_GEOMETRY,2)
            check(not hit.drawable,"reference structure intrudes live track/overhead envelope")
        end
    end
    -- Probe actual production triangles in each covered bay AND every daylight gap.
    -- Paving/base must remain present even where shelter is deliberately absent.
    local roof=assert(assert(node:GetChild("ReferenceMetalCanopySheets")):GetComponent("CustomGeometry"))
    local function roofWitness(ds,wanted)
        for _,center in ipairs(plan.platformCenters) do
            local origin=Route.SampleOffset(st.s+ds,center+.73,10)
            local hit=octree:RaycastSingle(Ray(origin,Vector3.DOWN),RAY_TRIANGLE,3.2,DRAWABLE_GEOMETRY,2)
            if wanted then
                check(hit.drawable==roof,"graded roof bay missing real sheet triangles")
            else
                check(not hit.drawable,"daylight gap/end still covered by hidden metropolitan roof")
            end
            local floor=octree:RaycastSingle(Ray(Route.SampleOffset(st.s+ds,center,1.8),Vector3.DOWN),RAY_TRIANGLE,.7,DRAWABLE_GEOMETRY,2)
            check(floor.drawable~=nil,"three-platform paving/base removed with reduced canopy")
        end
    end
    local previous=Route.PlatformStart
    for _,segment in ipairs(plan.roofSegments) do
        check(segment.last>segment.first and segment.first>=previous,"canopy segments overlap or invert")
        if segment.first-previous>3 then roofWitness((previous+segment.first)/2,false) end
        roofWitness((segment.first+segment.last)/2,true)
        previous=segment.last
    end
    roofWitness((plan.roofLast+Route.PlatformEnd)/2,false)
    for _,offsets in ipairs({plan.signOffsets,plan.waitingOffsets,plan.advertOffsets}) do
        for _,ds in ipairs(offsets) do
            check(Reference.IsCovered(plan,ds),"covered furniture/sign hangs in an open segment gap")
            check(ds<=55 and not(ds>-57 and ds<-29),"furniture invades stair/forecourt circulation")
        end
    end
    -- Size witnesses use production vertices, not counters/config values alone.
    local structure=assert(assert(node:GetChild("ReferenceWhiteColumnsAndTrusses")):GetComponent("CustomGeometry"))
    local columnS=plan.roofFirst+2
    for platformIndex,columnX in ipairs(plan.columnCenters) do
        local origin=Route.SampleOffset(st.s+columnS,columnX,0)
        local right,tangent=Route.RightAt(st.s+columnS),Route.TangentAt(st.s+columnS)
        local minX,maxX,minZ,maxZ=10,-10,10,-10
        for vertexIndex=0,structure:GetNumVertices(0)-1 do
            local delta=structure:GetVertex(0,vertexIndex).position-origin
            local x,z=delta:DotProduct(right),delta:DotProduct(tangent)
            -- Box vertices are at the foot/top, not interpolated along their faces.
            -- Inspect the actual foot ring (the old mid-height filter contained no vertices).
            if math.abs(x)<.7 and math.abs(z)<.7 and math.abs(delta.y-plan.platformTop)<.01 then
                minX,maxX=math.min(minX,x),math.max(maxX,x)
                minZ,maxZ=math.min(minZ,z),math.max(maxZ,z)
            end
        end
        check(maxX-minX>=.35 and maxZ-minZ>=.43,"real structural column remains a thin post")
    end
    local roofOrigin=Route.SampleOffset(st.s+plan.roofFirst,plan.platformCenters[2],0)
    local roofRight=Route.RightAt(st.s+plan.roofFirst)
    local seenRidge=false
    local crestX=plan.roofShape=="mono" and plan.roofHalfWidth or 0
    for vertexIndex=0,roof:GetNumVertices(0)-1 do
        local vertex=roof:GetVertex(0,vertexIndex).position
        if math.abs((vertex-roofOrigin):DotProduct(roofRight)-crestX)<.03
            and math.abs(vertex.y-roofOrigin.y-plan.ridgeY)<.03 then seenRidge=true;break end
    end
    check(seenRidge and plan.ridgeY-plan.eaveY>=.70,"actual graded pitched roof silhouette missing")
    local wings=assert(node:GetChild("StationNearLineWaitingWings"))
    check(#wings:GetChildren()==6,"near-line waiting wing missing")
    for _,wing in ipairs(wings:GetChildren()) do
        check(Route.CanPlaceFootprint(wing.worldPosition,math.sqrt(4.6^2+6.15^2)+.05,Route.BuildingClearance),"near-line wing failed production footprint clearance")
        check(wing:GetChild("NearLineWingPiersAndLintels")~=nil,"near-line wing has no real facade geometry")
    end
    -- Centre lamps must emit below opaque cross trusses; changing a roof must not shadow its own pool.
    check(plan.trussBottomY-.11>6.40,"cross truss cuts through the lamp housing")
    for _,x in ipairs({-3.7,-7.1,8.7}) do
        local clear=octree:RaycastSingle(Ray(Route.SampleOffset(st.s-34,x,2.20),Route.TangentAt(st.s)),RAY_TRIANGLE,88,DRAWABLE_GEOMETRY,2)
        check(not clear.drawable,"longitudinal passenger aisle blocked by new furniture")
    end
    for _,ds in ipairs({-49,-37}) do
        local mouth=octree:RaycastSingle(Ray(Route.SampleOffset(st.s+ds,-20.20,2.15),Route.RightAt(st.s)),RAY_TRIANGLE,3,DRAWABLE_GEOMETRY,2)
        check(not mouth.drawable,"forecourt stair/ramp mouth blocked by a column or fixture")
    end
    -- Actual stair treads and cross-track deck clearance in BOTH platform lengths.
    -- Down rays prove the existing stairs still exist; horizontal rays prove the
    -- new exposed-end lamps/signs do not close a real stair entrance or headroom.
    local bridgeS=math.max(83,Route.PlatformEnd-2)
    local stairS=bridgeS-19
    for _,center in ipairs(plan.platformCenters) do
        for _,dx in ipairs({-.80,0,.80}) do
            local approach=octree:RaycastSingle(Ray(Route.SampleOffset(st.s+stairS-3,center+dx,3.25),Route.TangentAt(st.s)),
                RAY_TRIANGLE,3,DRAWABLE_GEOMETRY,2)
            check(not approach.drawable,"new canopy fixture closes real stair approach")
            for _,fraction in ipairs({.12,.45,.80}) do
                local ds=stairS+19*fraction
                local treadY=1.44+(10.60-1.44)*fraction
                local tread=octree:RaycastSingle(Ray(Route.SampleOffset(st.s+ds,center+dx,treadY+.40),Vector3.DOWN),
                    RAY_TRIANGLE,.8,DRAWABLE_GEOMETRY,2)
                check(tread.drawable~=nil and tread.drawable.node.name=="BridgeObstacle_8","real stair tread removed/covered by platform detail")
                local headHits=octree:Raycast(Ray(Route.SampleOffset(st.s+ds,center+dx,treadY+.35),Vector3.UP),
                    RAY_TRIANGLE,2.15,DRAWABLE_GEOMETRY,2)
                local structuralClear=true
                for _,head in ipairs(headHits) do
                    -- Text3D picking bounds include empty glyph margins; only real
                    -- CustomGeometry/StaticModel surfaces are a structural obstruction.
                    local drawable=head.drawable
                    if drawable and not drawable.node:GetComponent("Text3D") then
                        structuralClear=false
                        check(false,string.format("stair headroom invaded %s ds=%.2f x=%.2f by %s",st.name,ds,center+dx,drawable.node.name))
                    end
                end
                check(structuralClear,"structural stair headroom blocked")
            end
        end
    end
    for _,lane in ipairs({-10.8,0,5,16.6,22.4}) do
        local deck=octree:RaycastSingle(Ray(Route.SampleOffset(st.s+bridgeS,lane,10),Vector3.UP),
            RAY_TRIANGLE,1,DRAWABLE_GEOMETRY,2)
        check(deck.drawable~=nil,"real cross-track bridge deck missing")
        local clear=octree:RaycastSingle(Ray(Route.SampleOffset(st.s+bridgeS,lane,3.6),Vector3.UP),
            RAY_TRIANGLE,5,DRAWABLE_GEOMETRY,2)
        check(not clear.drawable,"cross-track bridge intrudes rolling-stock/overhead clearance")
    end
    local textCount=0
    for _,textNode in ipairs(node:GetChildrenWithComponent("Text3D",true)) do
        local parent=textNode.parent
        if parent and parent.name:match("^Reference") then
            textCount=textCount+1
            local text=assert(textNode:GetComponent("Text3D"))
            check(text.faceCameraMode==FC_NONE and not text.fixedScreenSize,"suspended sign billboards to camera")
            check(text.drawDistance<=150 and not text.castShadows,"text draw/shadow budget exceeded")
        end
    end
    check(textCount==stats.labels,"sign face text missing")
    local sites=0
    for _,site in ipairs(Night.GetSites()) do
        if site.owner=="station:"..index_ then
            sites=sites+1
            check(site.kind=="station" and site.direction.y<-.99,"night light not registered as down-facing station site")
            check(site.position.y-Route.Sample(Route.ProjectApprox(site.position)).y>=6.26,"lamp source not below high canopy")
        end
    end
    check(sites==stats.lampSites and sites>=54,"full three-platform night coverage missing")
    print(string.format("[ReferenceStationValidation] GEOMETRY %s batches=%d vertices=%d clocks=%d signs=%d lights=%d",
        st.name,stats.batches,stats.vertices,stats.clocks,stats.labels,sites))
end
-- Independent structural identity witnesses deliberately exclude station names,
-- keys, colours and district strings: swapping signs/paint cannot satisfy them.
local function gradedPlanChecks()
    local seen={}
    local expectedFrames={"lattice","lattice","timber","portal","lattice","timber","masonry","timber","portal","portal"}
    local expectedSegments={1,2,1,2,2,1,2,2,1,2}
    local expectedSigns={4,3,1,2,4,1,2,2,1,3}
    for i=1,10 do
        local plan=Config.GetReferenceArchitecture(i,Route.PlatformStart,Route.PlatformEnd)
        local signature=string.format("%s/%s/%d/%.3f/%d/%d/%d",plan.roofShape,plan.frameStyle,#plan.roofSegments,
            plan.coverageRatio,#plan.signOffsets,#plan.waitingOffsets,#plan.advertOffsets)
        check(not seen[signature],"two stations have identical non-colour structural profiles")
        seen[signature]=true
        check(plan.frameStyle==expectedFrames[i] and #plan.roofSegments==expectedSegments[i],"city grade lost its structural system/segmentation")
        check(#plan.signOffsets==expectedSigns[i],"city grade lost its facility density")
        check(plan.coverageRatio>.25 and plan.coverageRatio<.95,"platform coverage is unrealistic or uniform full-length")
        if i==3 or i==6 or i==9 then
            check(plan.coverageRatio<.45 and not plan.waitingScreens and #plan.advertOffsets==0,
                "small halt regressed to dense metropolitan glazed/ad shelter")
        end
    end
end

local function applyView()
    local st=assert(Route.GetStations()[index_])
    local eye,camera=assert(eye_),assert(camera_)
    local mode=VIEWS[view_]
    local night=mode=="platform_night"
    local zone,sun=assert(zone_),assert(sun_)
    zone.ambientSource=AMBIENT_COLOR
    zone.ambientColor=night and Color(.018,.024,.036) or Color(.32,.35,.38)
    zone.fogColor=night and Color(.02,.03,.05) or Color(.64,.71,.78)
    sun.brightness=night and .08 or 1.8
    Station.SetEnvironment(night and 1 or 0)
    -- 灯池Attach可能发生在首站构建时；显式同步验收时相，不依赖站点材质去重缓存。
    Night.SetEnvironment(night and 1 or 0,"medium")
    camera.fov=64
    if mode=="overview" then
        eye.position=Route.SampleOffset(st.s-160,38,23)
        eye:LookAt(Route.SampleOffset(st.s-70,-24,4))
    elseif mode=="truss_detail" then
        eye.position=Route.SampleOffset(st.s-120,-4.7,3.2)
        eye:LookAt(Route.SampleOffset(st.s-102,-5.4,6.0))
    else
        eye.position=Route.SampleOffset(st.s-140,-4.6,3.1)
        eye:LookAt(Route.SampleOffset(st.s-45,-5.6,4.5))
    end
    Night.Update(eye.worldPosition)
end
function Start()
    guarded(function()
        Modes.Apply(mode_);Route.Build();Station.Init();Yard.Shutdown()
        gradedPlanChecks()
        -- CPU defaults to all real stations; rendering remains the bounded original
        -- five-station subset unless -index explicitly selects any station (1..10).
        local explicitIndex=false
        for _,arg in ipairs(GetArguments()) do
            if arg:match("^%-index=") then explicitIndex=true end
        end
        if geometryOnly_ and not explicitIndex then lastStation_=math.floor(#Route.GetStations()) end
        scene_=Scene()
        batchSurfaceChecks()
        local octree=scene_:CreateComponent("Octree")
        octree:SetSize(BoundingBox(Vector3(-60000,-2000,-60000),Vector3(60000,4000,60000)),8)
        local group=scene_:CreateChild("LightGroup")
        group:LoadXML(assert(cache:GetResource("XMLFile","LightGroup/Daytime.xml")):GetRoot())
        zone_=assert(group:GetComponent("Zone",true))
        local quality=VisualQuality.Get("medium")
        zone_.depthFogStart,zone_.depthFogEnd=quality.fogStart,quality.fogEnd
        -- Match production GLES-safe medium path; no unavailable shadow/post variants.
        zone_.autoExposureEnabled=false;zone_.vignetteEnabled=false
        zone_.bloomWeight=0;zone_.ssaoIntensity=0
        zone_.ssrEnabled=false;zone_.ssgiEnabled=false;zone_.volumetricFogEnabled=false
        zone_:SetAttribute("Bloom Enable",Variant(false))
        sun_=assert(group:GetComponent("Light",true))
        sun_.castShadows=quality.shadows
        eye_=scene_:CreateChild("ReferenceAcceptanceCamera")
        camera_=eye_:CreateComponent("Camera")
        camera_.nearClip,camera_.farClip,camera_.viewMask=.08,1800,3
        local viewport=Viewport:new(scene_,camera_)
        viewport:SetRect(IntRect(0,0,960,540))
        renderer:SetViewport(0,viewport)
        renderer.hdrRendering,renderer.dynamicInstancing=true,true
        renderer.drawShadows=quality.shadows
        renderer.materialQuality=QUALITY_MEDIUM;renderer.specularLighting=false
        Night.SetEnvironment(0,"medium")
        activate(firstStation_)
        SubscribeToEvent("PostUpdate","HandleReferenceStationUpdate")
        SubscribeToEvent("EndRendering","HandleReferenceStationCapture")
    end)
end
---@param eventType string
---@param eventData PostUpdateEventData
function HandleReferenceStationUpdate(eventType,eventData)
    guarded(function()
        age_=age_+1
        applyView()
        if age_>=5 and not checked_ then
            geometryChecks();checked_=true
            if geometryOnly_ then
                if index_<lastStation_ then activate(index_+1)
                else
                    local count=lastStation_-firstStation_+1
                    unload();Night.Shutdown()
                    print(string.format("ALL_REFERENCE_STATION_CPU_PASS mode=%s stations=%d checks=%d captures=0 GLES=NONE",mode_,count,checks_))
                    engine:Exit()
                end
                return
            end
        end
        check(age_<40,"capture exceeded bounded frame count")
    end)
end
---@param eventType string
---@param eventData EndRenderingEventData
function HandleReferenceStationCapture(eventType,eventData)
    if geometryOnly_ then return end
    guarded(function()
        if age_<8 then return end
        local image=Image()
        if not graphics:TakeScreenShot(image) then image:Dispose();return end
        local key=string.format("%d_%s",index_,VIEWS[view_])
        local view=image:GetSubimage(IntRect(0,0,960,540))
        check(view~=nil and view:SavePNG("screenshots/reference_station_"..key..".png"),"real gameplay viewport screenshot save failed")
        view:Dispose();image:Dispose()
        captures_=captures_+1
        if VIEWS[view_]=="platform_night" then
            check(Night.GetStats().activeStation>0,"夜景灯池没有启用实际投光组件")
        end
        print(string.format("[ReferenceStationValidation] REAL_CAPTURE %s rendererBatches=%d primitives=%d activeStationLights=%d",key,renderer.numBatches,renderer.numPrimitives,Night.GetStats().activeStation))
        if captureViewIndex_<#captureViews_ then
            captureViewIndex_=captureViewIndex_+1
            view_,age_=assert(captureViews_[captureViewIndex_]),0
        elseif index_<lastStation_ then activate(index_+1)
        else
            local stationCount=lastStation_-firstStation_+1
            check(captures_==stationCount*#captureViews_,"requested station/view coverage incomplete")
            unload();Night.Shutdown()
            print(string.format("ALL_REFERENCE_STATION_PASS stations=%d views=%d checks=%d",stationCount,captures_,checks_))
            engine:Exit()
        end
    end)
end
function Stop()
    Station.Shutdown();Yard.Shutdown();Night.Shutdown()
    if root_ then root_:Dispose();root_=nil end
    scene_,eye_,camera_,zone_,sun_=nil,nil,nil,nil,nil
end
