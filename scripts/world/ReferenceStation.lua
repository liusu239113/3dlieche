-- ReferenceStation: photographic platform language, no new asset dependency.
-- Route.SampleOffset is the ONLY world placement transform (including mountain base Y).
-- Clearance design (metres, no new physics/collision bodies):
--  house -68 | outer platform -19.9..-12.9 | lane2 -10.8 | island -8.9..-1.9
--            | main0 0 | up1 5 | up platform 6.9..13.9 | service rail 16.6
--  roof edges stay 0.30m inside every platform edge; no roof over live track.
--  columns remain on the furniture edge; 360×440mm I-sections, no floor-level braces.
--  lateral eave lattice stays >=5.99m; transverse truss bottoms >=6.45m.
--  Centre lamps hang BELOW every cross truss: no self-occlusion of pooled lights.
--  overhead info bottom 4.62m/exit bottom4.16m; ds>=61 and passenger corridors stay clear.
local Route = require "world.Route"
local World = require "world.WorldMaterials"
local Config = require "config.StationVisualConfig"
local NightLighting = require "world.NightLighting"
local Materials = require "config.Materials"
local Reference = {}

---@class ReferenceStationStats
---@field batches integer
---@field vertices integer
---@field labels integer
---@field columns integer
---@field trusses integer
---@field roofRibs integer
---@field clocks integer
---@field ledBoards integer
---@field adverts integer
---@field lampSites integer
---@field roofFirst number
---@field roofLast number
---@field roofMinY number
---@field lowestSignY number
---@field identity string
---@type table<number, ReferenceStationStats>
local stats_ = {}
---@type table<string, Material>
local materials_ = {}

---@param key string
---@param color Color
---@param metal number
---@param rough number
---@param emission? number
---@return Material
local function material(key,color,metal,rough,emission)
    if not materials_[key] then
        -- Never mutate World/Materials shared-cache materials when adding emission.
        local mat = World.Solid(color,metal,rough):Clone()
        if emission then
            mat:SetShaderParameter("MatEmissiveColor",Variant(Vector3(color.r,color.g,color.b)*emission))
        end
        materials_[key] = mat
    end
    return materials_[key]
end

---@param st RailwayStation
---@param ds number
---@param x number
---@param y number
---@return Vector3
local function p(st,ds,x,y) return Route.SampleOffset(st.s+ds,x,y) end

---@param root Node
---@param name string
---@param mat Material
---@param shadows boolean
---@param distance number
---@param tile? number
---@return RailwayBatch
local function batch(root,name,mat,shadows,distance,tile)
    local target = World.NewBatch(root:CreateChild(name),mat,shadows,tile)
    target.geometry.viewMask = 2
    target.geometry.drawDistance = distance
    target.geometry.shadowDistance = 110
    return target
end

---@param target RailwayBatch
---@param a Vector3
---@param b Vector3
---@param width number
---@param height? number
local function beam(target,a,b,width,height)
    local delta = b-a
    if delta:LengthSquared()<.000001 then return end
    local axis = delta:Normalized()
    local reference = math.abs(axis.y)>.95 and Vector3.RIGHT or Vector3.UP
    local u = axis:CrossProduct(reference):Normalized()*(width*.5)
    local v = axis:CrossProduct(u):Normalized()*((height or width)*.5)
    local a1,a2,a3,a4 = a-u-v,a+u-v,a+u+v,a-u+v
    local b1,b2,b3,b4 = b-u-v,b+u-v,b+u+v,b-u+v
    target:AddQuad(a1,a2,b2,b1);target:AddQuad(a2,a3,b3,b2)
    target:AddQuad(a3,a4,b4,b3);target:AddQuad(a4,a1,b1,b4)
    -- Structural members terminate inside chords/columns; buried end caps add no visible
    -- surface. Keep four real side faces, spend the budget on the open lattice silhouette.
end

---@param st RailwayStation
---@param targets RailwayBatch[]
---@param pause? fun()
local function finish(st,targets,pause)
    local stats = assert(stats_[st.index])
    for _,target in ipairs(targets) do
        stats.vertices = stats.vertices+target:Finish()
        if target.vertices>0 then stats.batches=stats.batches+1
        else target.geometry.node:Dispose() end
        if pause then pause() end
    end
end

---@param plan ReferenceStationArchitecture
---@param dx number
---@return number
local function roofY(plan,dx)
    if plan.roofShape=="mono" then
        return plan.eaveY+(plan.ridgeY-plan.eaveY)*(dx+plan.roofHalfWidth)/(2*plan.roofHalfWidth)
    end
    return plan.ridgeY-(plan.ridgeY-plan.eaveY)*math.abs(dx)/plan.roofHalfWidth
end

---@param plan ReferenceStationArchitecture
---@param ds number
---@return boolean
function Reference.IsCovered(plan,ds)
    for _,segment in ipairs(plan.roofSegments) do
        if ds>=segment.first and ds<=segment.last then return true end
    end
    return false
end

-- Floor furniture must leave BOTH real forecourt mouths clear, even when a
-- different roof length moves a column or open-air lighting pole onto a jamb.
---@param ds number
---@param platformIndex integer
---@param first? number
---@return number
local function furnitureS(ds,platformIndex,first)
    if platformIndex~=1 then return ds end
    if ds>-54.5 and ds<-43.5 then return first and first>-55 and -42 or -55 end
    if ds>-41.5 and ds<-31.5 then return first and first>-42 and -30.5 or -42 end
    return ds
end

-- Existing local diffuse-only materials: no new normal maps/shader variants.
local FINISHES = {
    zinc={roof=Color(.51,.55,.57),frame=Color(.49,.52,.50),soffit=Color(.29,.34,.36)},
    marine_steel={roof=Color(.40,.51,.56),frame=Color(.30,.40,.43),soffit=Color(.19,.28,.31)},
    warm_timber={roof=Color(.48,.33,.24),frame=Color(.42,.29,.18),soffit=Color(.24,.18,.13)},
    lake_steel={roof=Color(.43,.60,.62),frame=Color(.36,.46,.47),soffit=Color(.22,.34,.35)},
    graphite={roof=Color(.38,.43,.49),frame=Color(.38,.42,.46),soffit=Color(.18,.23,.28)},
    ochre_timber={roof=Color(.55,.42,.26),frame=Color(.48,.36,.22),soffit=Color(.27,.21,.13)},
    stone_pier={roof=Color(.46,.48,.43),frame=Color(.43,.43,.38),soffit=Color(.24,.27,.22)},
    forest_timber={roof=Color(.35,.49,.40),frame=Color(.42,.32,.21),soffit=Color(.15,.29,.20)},
    ridge_steel={roof=Color(.49,.53,.43),frame=Color(.40,.43,.35),soffit=Color(.27,.31,.23)},
    lake_terminal={roof=Color(.42,.57,.63),frame=Color(.42,.49,.51),soffit=Color(.20,.33,.39)},
}

---@param st RailwayStation
---@return ReferenceStationArchitecture
function Reference.GetPlan(st)
    return Config.GetReferenceArchitecture(st.index,Route.PlatformStart,Route.PlatformEnd)
end

---@param root Node
---@param st RailwayStation
---@param pause? fun()
function Reference.BuildCanopies(root,st,pause)
    local plan = Reference.GetPlan(st)
    stats_[st.index] = {batches=0,vertices=0,labels=0,columns=0,trusses=0,roofRibs=0,
        clocks=0,ledBoards=0,adverts=0,lampSites=0,roofFirst=plan.roofFirst,roofLast=plan.roofLast,
        roofMinY=plan.eaveY,lowestSignY=4.16,identity=plan.identity}
    local stats = assert(stats_[st.index])
    -- Keep the same four draw batches. Heavy frames are reserved for hubs/port;
    -- village timber portals and mountain stone piers replace, never overlay them.
    local palette=FINISHES[plan.finish] or FINISHES.zinc
    local sheet = batch(root,"ReferenceMetalCanopySheets",World.Textured("ReferenceRoof_"..plan.finish,
        "Textures/Railway/coach_steel.png",palette.roof,.82,.20),true,850,.85)
    local frameTexture=plan.frameStyle=="masonry" and "Textures/Railway/concrete.png" or "Textures/Railway/coach_paint.png"
    local frame = batch(root,"ReferenceWhiteColumnsAndTrusses",World.Textured("ReferenceFrame_"..plan.finish,
        frameTexture,palette.frame,.90,0),true,700,.80)
    local ribs = batch(root,"ReferenceCorrugatedRoofRibs",World.Textured("ReferenceSoffit_"..plan.finish,
        "Textures/Railway/coach_steel.png",palette.soffit,.94,.04),false,850,.85)
    local details = batch(root,"ReferenceSteelConnectionsDrainage",World.Textured("ReferenceGraphiteConnections",
        "Textures/Railway/coach_steel.png",Color(.20,.25,.28),.78,.30),false,220,.50)
    local _,_,yaw = Route.Sample(st.s)
    local angle = math.rad(yaw)
    for platformIndex,center in ipairs(plan.platformCenters) do
        local column = plan.columnCenters[platformIndex]
        local half = plan.roofHalfWidth
        -- Each independently supported segment follows the real route elevation.
        -- No sheets/chords bridge the deliberate daylight gaps.
        for _,roofSegment in ipairs(plan.roofSegments) do
        for ds=roofSegment.first,roofSegment.last-.001,plan.roofSampleStep do
            local last = math.min(roofSegment.last,ds+plan.roofSampleStep)
            for side=-1,1,2 do
                local edge = center+side*half
                local centerY,edgeY=roofY(plan,0),roofY(plan,side*half)
                local a,b,c,d = p(st,ds,center,centerY),p(st,last,center,centerY),
                    p(st,last,edge,edgeY),p(st,ds,edge,edgeY)
                if side>0 then sheet:AddQuad(a,b,c,d) else sheet:AddQuad(d,c,b,a) end
                local down = Vector3(0,-.024,0)
                if side>0 then ribs:AddQuad(d+down,c+down,b+down,a+down)
                else ribs:AddQuad(a+down,b+down,c+down,d+down) end
                beam(frame,p(st,ds,edge,edgeY-.13),p(st,last,edge,edgeY-.13),.10,.22)
            end
            -- Folded standing seams at the profile's economical panel spacing.
            for dx=-half+.12,half-.08,plan.roofRibStep do
                -- Standing seams retain the original 90mm-wide folded profile.
                local y = roofY(plan,dx)
                local baseY,crestY = y+.025,y+.070
                local a,b = p(st,ds,center+dx-.045,baseY),p(st,last,center+dx-.045,baseY)
                local c,d = p(st,last,center+dx,crestY),p(st,ds,center+dx,crestY)
                local e,f = p(st,last,center+dx+.045,baseY),p(st,ds,center+dx+.045,baseY)
                sheet:AddQuad(a,b,c,d);sheet:AddQuad(d,c,e,f)
                -- The soffit is the physical sheet 24mm below the upper face.
                -- Do not float dark strips under it to imitate corrugation shadows.
                stats.roofRibs=stats.roofRibs+1
            end
            -- Longitudinal purlins sit ON the truss top chord and below the roof skin.
            for _,dx in ipairs({-2.25,0,2.25}) do
                beam(frame,p(st,ds,center+dx,roofY(plan,dx)-.15),p(st,last,center+dx,roofY(plan,dx)-.15),.07,.18)
            end
            -- Folded gutters follow both real eave heights, including single-slope roofs.
            for side=-1,1,2 do
                local x = center+side*(half-.025)
                local eave=roofY(plan,side*half)
                beam(details,p(st,ds,x,eave-.23),p(st,last,x,eave-.23),.15,.025)
                beam(details,p(st,ds,x+side*.065,eave-.18),p(st,last,x+side*.065,eave-.18),.018,.12)
                -- Hubs/port have deep lattice edge girders. Local halts use the
                -- eave/purlin alone; never add a second detail overlay to fake identity.
                if plan.frameStyle=="lattice" then
                local latticeX=center+side*(half-.23)
                local upper,lower=eave-.29,eave-.29-plan.edgeTrussDepth
                beam(frame,p(st,ds,latticeX,upper),p(st,last,latticeX,upper),.12,.14)
                beam(frame,p(st,ds,latticeX,lower),p(st,last,latticeX,lower),.12,.14)
                local segments=math.max(1,math.ceil((last-ds)/6))
                for k=1,segments do
                    local aS,bS=ds+(last-ds)*(k-1)/segments,ds+(last-ds)*k/segments
                    -- Diagonal meets both continuous chords. Redundant verticals
                    -- at every 3m stitch were invisible from the cab and doubled CPU mesh.
                    if k%2==1 then beam(frame,p(st,aS,latticeX,lower),p(st,bS,latticeX,upper),.075)
                    else beam(frame,p(st,aS,latticeX,upper),p(st,bS,latticeX,lower),.075) end
                end
                end
            end
            if pause then pause() end
        end
        local columnCount = math.max(1,math.ceil((roofSegment.last-roofSegment.first-4)/plan.columnStep))
        local step = (roofSegment.last-roofSegment.first-4)/columnCount
        for i=0,columnCount do
            local nominalS = roofSegment.first+2+i*step
            local ds = furnitureS(nominalS,platformIndex,roofSegment.first)
            local top = roofY(plan,column-center)-.28
            if plan.frameStyle=="lattice" then
                -- Full-size steel I section: no floor-level brace across the aisle.
                for _,dz in ipairs({-plan.columnDepth/2+.025,plan.columnDepth/2-.025}) do
                    frame:AddBox(p(st,ds+dz,column,(plan.platformTop+top)/2),
                        Vector3(plan.columnWidth,top-plan.platformTop,.05),angle)
                end
                frame:AddBox(p(st,ds,column,(plan.platformTop+top)/2),
                    Vector3(.045,top-plan.platformTop,plan.columnDepth-.10),angle)
            else
                -- Timber/solid masonry piers have a genuinely different section,
                -- using fewer vertices than an I-column, within the same safety strip.
                frame:AddBox(p(st,ds,column,(plan.platformTop+top)/2),
                    Vector3(plan.columnWidth,top-plan.platformTop,plan.columnDepth),angle)
            end
            details:AddBox(p(st,ds,column,plan.platformTop+.045),Vector3(.56,.09,.60),angle)
            local bottom = plan.trussBottomY
            if plan.frameStyle=="lattice" then
                beam(frame,p(st,ds,center-half+.12,bottom),p(st,ds,center+half-.12,bottom),.13,.22)
                for segment=1,4 do
                    local x0 = center-half+.12+(segment-1)*(2*half-.24)/4
                    local x1 = center-half+.12+segment*(2*half-.24)/4
                    local y0,y1 = roofY(plan,x0-center)-.25,roofY(plan,x1-center)-.25
                    beam(frame,p(st,ds,x0,y0),p(st,ds,x1,y1),.08,.11)
                    beam(frame,p(st,ds,x0,bottom),p(st,ds,x0,y0),.035)
                    if segment==4 then beam(frame,p(st,ds,x1,bottom),p(st,ds,x1,y1),.035) end
                    if segment%2==1 then beam(frame,p(st,ds,x0,bottom),p(st,ds,x1,y1),.045)
                    else beam(frame,p(st,ds,x0,y0),p(st,ds,x1,bottom),.045) end
                end
            else
                -- Local stops: solid cantilever rafter + high knee brackets, not a
                -- metropolitan truss cage. Lowest member remains above 6.40m.
                for side=-1,1,2 do
                    beam(frame,p(st,ds,center,roofY(plan,0)-.27),
                        p(st,ds,center+side*(half-.12),roofY(plan,side*(half-.12))-.27),.18,.27)
                end
                beam(frame,p(st,ds,column,top-.62),p(st,ds,center,roofY(plan,0)-.30),.16,.18)
            end
            -- Compact column head brackets transfer load, not decorative floating triangles.
            for direction=-1,1,2 do
                beam(frame,p(st,ds,column,top-.70),p(st,ds+direction*.85,column,top),.07)
            end
            details:AddBox(p(st,ds,column,top),Vector3(.32,.07,.40),angle)
            if i%4==0 then
                local drainX = column+(column<center and -.17 or .17)
                details:AddTube(p(st,ds,drainX,plan.platformTop+.06),p(st,ds,drainX,plan.eaveY-.24),.045,6)
                beam(details,p(st,ds,drainX,plan.eaveY-.24),p(st,ds,center+(column<center and -1 or 1)*(half-.025),plan.eaveY-.24),.08)
                for _,y in ipairs({2.3,4.3,6.0}) do
                    details:AddBox(p(st,ds,drainX,y),Vector3(.13,.035,.13),angle)
                end
            end
            stats.columns=stats.columns+1;stats.trusses=stats.trusses+1
            if pause and i%4==0 then pause() end
        end
        -- Finished end cap shows sheet thickness and closed fascia, no open cut ends.
        for _,ds in ipairs({roofSegment.first,roofSegment.last}) do
            for side=-1,1,2 do
                beam(details,p(st,ds,center,roofY(plan,0)-.08),p(st,ds,center+side*half,roofY(plan,side*half)-.08),.055,.16)
            end
        end
        end
    end
    finish(st,{sheet,frame,ribs,details},pause)
end

---@param target RailwayBatch
---@param st RailwayStation
---@param ds number
---@param x0 number
---@param x1 number
---@param last number
---@param y number
---@param uvOrigin? Vector2
local function horizontalQuad(target,st,ds,x0,x1,last,y,uvOrigin)
    target:AddQuad(p(st,ds,x0,y),p(st,last,x0,y),p(st,last,x1,y),p(st,ds,x1,y),uvOrigin)
end

---@param root Node
---@param st RailwayStation
---@param pause? fun()
function Reference.BuildPaving(root,st,pause)
    local plan = Reference.GetPlan(st)
    local targets = {} ---@type RailwayBatch[]
    -- Three naturally mixed stone lots plus one dedicated pale coping/course finish.
    -- Keep all four existing draw nodes; the coping no longer disappears into a
    -- fourth checkerboard floor colour. Local concrete has actual aggregate grain.
    local tints = {Color(.39,.40,.39),Color(.44,.435,.415),Color(.48,.495,.49),Color(.66,.65,.60)}
    for i,tint in ipairs(tints) do
        targets[i] = batch(root,"ReferenceGranitePavers_"..i,
            World.Textured("ReferenceStationStoneLot"..i,"Textures/Railway/concrete.png",tint,.94),false,430,1.05)
    end
    local joint = batch(root,"ReferencePavingJointsAndDrainSlots",material("joint",Color(.20,.235,.24),0,.96),false,430)
    -- Copings/courses share one granite batch; no extra material/draw node for stone trim.
    local courses = assert(targets[4])
    local tactile = batch(root,"ReferenceYellowSafetyTactile",material("tactile",Color(.78,.65,.23),0,.89),false,430)
    local rib = batch(root,"ReferenceTactileRaisedRibs",material("tactileRib",Color(.65,.53,.17),0,.94),false,150)
    local _,_,yaw = Route.Sample(st.s)
    local angle = math.rad(yaw)
    local first,last = Route.PlatformStart,Route.PlatformEnd
    local middle,span = (first+last)/2,last-first
    for platformIndex,center in ipairs(plan.platformCenters) do
        horizontalQuad(joint,st,first,center-3.48,center+3.48,last,plan.platformTop+.007)
        -- Long coping courses and transverse expansion bands read at normal camera height.
        -- Outer edge facings are inside the existing 7m slab, never protrude toward a train.
        for side=-1,1,2 do
            local x0=center+side*3.5
            local x1=x0-side*.40
            for ds=first,last-.001,2.8 do
                local endS=math.min(last,ds+2.8)
                horizontalQuad(courses,st,ds+.014,math.min(x0,x1),math.max(x0,x1),endS-.014,plan.platformTop+.050)
                local edgeX=x0-side*.008
                -- Divide the existing real platform fascia into plinth / precast riser /
                -- coping nosing. These are adjoining facade surfaces, not fake shadows
                -- hovering beside the slab. No change to boarding edge or clearance.
                local facadeLot = targets[(math.floor((ds-first)/2.8)*13+platformIndex*7)%3+1]
                local finishes = {joint,facadeLot,courses}
                local levels = {.48,.64,plan.platformTop-.20,plan.platformTop-.035}
                for band=1,3 do
                    local a,b=p(st,ds+.014,edgeX,levels[band]),p(st,endS-.014,edgeX,levels[band])
                    local c,d=p(st,endS-.014,edgeX,levels[band+1]),p(st,ds+.014,edgeX,levels[band+1])
                    if side>0 then finishes[band]:AddQuad(a,d,c,b)
                    else finishes[band]:AddQuad(b,c,d,a) end
                end
            end
        end
        for ds=first+12,last-1,12 do
            horizontalQuad(courses,st,ds-.13,center-3.10,center+3.10,ds+.13,plan.platformTop+.018)
        end
        local row=0
        for ds=first,last-.001,plan.pavingSlabLength do
            row=row+1
            local nextS = math.min(last,ds+plan.pavingSlabLength)
            -- Hubs use finer six-course granite; small halts use four broad
            -- precast slabs, not thousands of metropolitan paving microtiles.
            local width=6.96/plan.pavingCourses
            for col=1,plan.pavingCourses do
                local x0 = center-3.48+(col-1)*width
                local x1 = x0+width
                -- Stable per-slab stone lot/UV phase, not diagonal colour stripes and
                -- not math.random (which would perturb world/gameplay random state).
                local seed=(row*73856093) ~ (col*19349663) ~ (platformIndex*83492791)
                local mixed=(seed ~ (seed >> 13)) & 0x7fffffff
                local index=mixed%3+1
                local phase=Vector2((mixed%97)/97,((mixed//97)%89)/89)
                horizontalQuad(targets[index],st,ds+.006,x0+.006,x1-.006,nextS-.006,plan.platformTop+.011,phase)
            end
            if pause and row%16==0 then pause() end
        end
        -- Yellow line/tactile side follows the boarding edge; island also has lane2 edge.
        local edges = platformIndex==1 and {1} or (platformIndex==2 and {-1,1} or {-1})
        for _,side in ipairs(edges) do
            local edge = center+side*3.5
            local safetyX,tactileX = edge-side*.80,edge-side*1.25
            for ds=first,last-.001,12 do
                local endS = math.min(last,ds+12)
                horizontalQuad(tactile,st,ds,safetyX-.08,safetyX+.08,endS,plan.platformTop+.058)
                horizontalQuad(tactile,st,ds,tactileX-.18,tactileX+.18,endS,plan.platformTop+.028)
                for _,dx in ipairs({-.11,0,.11}) do
                    horizontalQuad(rib,st,ds,tactileX+dx-.013,tactileX+dx+.013,endS,plan.platformTop+.040)
                end
            end
        end
        if platformIndex==1 then
            horizontalQuad(tactile,st,-49.18,center-3.48,center+2.43,-48.82,plan.platformTop+.029)
            for _,ds in ipairs({-49.11,-49,-48.89}) do
                horizontalQuad(rib,st,ds-.013,center-3.48,center+2.43,ds+.013,plan.platformTop+.042)
            end
        end
        -- Storm drains sit on the furniture strip, not across the yellow safety margin.
        local drainX = center+(platformIndex<3 and -1 or 1)*2.96
        for ds=first+4,last-2,8 do
            -- Flush drain inset: side/bottom faces are embedded in the paving slab.
            horizontalQuad(joint,st,ds-.31,drainX-.11,drainX+.11,ds+.31,plan.platformTop+.031)
            for z=-.24,.24,.12 do
                horizontalQuad(rib,st,ds+z-.011,drainX-.10,drainX+.10,ds+z+.011,plan.platformTop+.038)
            end
        end
    end
    targets[#targets+1]=joint;targets[#targets+1]=tactile;targets[#targets+1]=rib
    finish(st,targets,pause)
end

---@param target RailwayBatch
---@param center Vector3
---@param right Vector3
---@param up Vector3
---@param radius number
local function disc(target,center,right,up,radius)
    for i=1,32 do
        local a,b = (i-1)*math.pi/16,i*math.pi/16
        target:AddTri(center,center+right*(math.cos(b)*radius)+up*(math.sin(b)*radius),
            center+right*(math.cos(a)*radius)+up*(math.sin(a)*radius))
    end
end

-- Clock details are flush printed metal markings: only the visible face is required,
-- unlike structural beams. Avoid 6-face microboxes for every tick and hand.
---@param target RailwayBatch
---@param a Vector3
---@param b Vector3
---@param normal Vector3
---@param width number
local function clockMark(target,a,b,normal,width)
    local cross=(b-a):CrossProduct(normal)
    if cross:LengthSquared()<.000001 then return end
    local side=cross:Normalized()*(width*.5)
    target:AddQuad(a+side,b+side,b-side,a-side)
end

---@param root Node
---@param st RailwayStation
---@param ds number
---@param x number
---@param y number
---@param face number
---@param text string
---@param size number
---@param name string
---@param color Color
---@param makeSign fun(parent: Node, text: string, size: number): Node
local function textFace(root,st,ds,x,y,face,text,size,name,color,makeSign)
    local node = root:CreateChild(name)
    node.position = p(st,ds,x,y)
    local _,_,yaw = Route.Sample(st.s+ds)
    node.rotation = Quaternion(yaw+(face<0 and 0 or 180),Vector3.UP)
    local labelNode = makeSign(node,text,size)
    local label = labelNode:GetComponent("Text3D")
    if label then label.color=color;label.drawDistance=150 end
    local stats=assert(stats_[st.index]);stats.labels=stats.labels+1
end

---@param root Node
---@param st RailwayStation
---@param makeSign fun(parent: Node, text: string, size: number): Node
---@param pause? fun()
function Reference.BuildWayfinding(root,st,makeSign,pause)
    local plan = Reference.GetPlan(st)
    local stats = assert(stats_[st.index])
    local steel = batch(root,"ReferenceSuspendedSignFrames",World.Textured("ReferenceFurnitureBrushedSteel",
        "Textures/Railway/coach_steel.png",Color(.25,.29,.30),.80,.34),false,320)
    local blue = batch(root,"ReferenceBluePlatformSigns",material("blue",Color(.018,.055,.25),.12,.52),false,360)
    local black = batch(root,"ReferenceLEDClockHousings",material("black",Color(.018,.022,.028),.18,.64),false,320)
    local white = batch(root,"ReferenceWhiteClockFacesAndLightboxes",material("whiteGlow",Color(.91,.93,.91),.08,.58,.28),false,320)
    local red = batch(root,"ReferenceRedLEDLettering",material("redLED",Color(.88,.035,.015),0,.65,.7),false,260)
    local advert = batch(root,"ReferenceAdvertisementArtwork",material("poster",Color(.13,.37,.46),.05,.82),false,200)
    local screens = batch(root,"ReferenceWaitingWindScreens",Materials.Glass(Color(.56,.66,.67,.33)),false,280)
    local _,_,yaw = Route.Sample(st.s)
    local angle = math.rad(yaw)
    for platformIndex,center in ipairs(plan.platformCenters) do
        for signIndex,ds in ipairs(plan.signOffsets) do
            -- Inset cabinet, with actual blue end panels and a central white clock.
            local y = 5.16
            black:AddBox(p(st,ds,center,y),Vector3(5.5,1.08,.18),angle)
            for _,side in ipairs({-1,1}) do
                blue:AddBox(p(st,ds,center+side*2.40,y),Vector3(.68,1.14,.22),angle)
            end
            for _,dx in ipairs({-2.15,2.15}) do
                local top = roofY(plan,dx)-.03
                steel:AddBox(p(st,ds,center+dx,(top+y+.54)/2),Vector3(.038,top-y-.54,.038),angle)
                steel:AddBox(p(st,ds,center+dx,top),Vector3(.22,.06,.22),angle)
            end
            for face=-1,1,2 do
                local right = Route.RightAt(st.s+ds)*(-face)
                local normal = Route.TangentAt(st.s+ds)*face
                local clock = p(st,ds+face*.125,center,y)
                disc(steel,clock,right,Vector3.UP,.47)
                disc(white,clock+normal*.009,right,Vector3.UP,.415)
                for mark=1,12 do
                    local t = mark*math.pi/6
                    local a = clock+normal*.018+right*(math.sin(t)*.32)+Vector3.UP*(math.cos(t)*.32)
                    local b = clock+normal*.018+right*(math.sin(t)*.38)+Vector3.UP*(math.cos(t)*.38)
                    clockMark(black,a,b,normal,mark%3==0 and .027 or .015)
                end
                -- Static architectural clock (10:10), not a false gameplay timetable.
                local front = clock+normal*.027
                clockMark(black,front,front-right*.20+Vector3.UP*.12,normal,.037)
                clockMark(black,front,front+right*.22+Vector3.UP*.19,normal,.023)
                textFace(root,st,ds+face*.15,center-face*2.40,y,face,tostring(platformIndex),.63,
                    "ReferencePlatformNumber_"..platformIndex.."_"..signIndex,Color(.96,.97,.95),makeSign)
                -- Two short red LED captions stay inside the black inset, do not cross the clock.
                textFace(root,st,ds+face*.115,center-face*1.30,y+.11,face,st.name,.26,
                    "ReferenceLEDStation_"..platformIndex.."_"..signIndex,Color(1,.07,.025),makeSign)
                textFace(root,st,ds+face*.115,center+face*1.30,y+.11,face,"注意安全",.23,
                    "ReferenceLEDSafety_"..platformIndex.."_"..signIndex,Color(1,.07,.025),makeSign)
                -- Discrete LED modules below text, with black gaps, not one big glowing red bar.
                for led=1,12 do
                    for _,side in ipairs({-1,1}) do
                        local x = center+side*(.67+led*.105)
                        -- Emitting diodes are flush on the opaque cabinet: the rear/edge
                        -- microfaces are invisible. This winding faces the same normal as clock.
                        local centerLED=p(st,ds+face*.102,x,y-.28)
                        local halfX,halfY=right*.0275,Vector3.UP*.009
                        red:AddQuad(centerLED-halfX-halfY,centerLED-halfX+halfY,
                            centerLED+halfX+halfY,centerLED+halfX-halfY)
                    end
                end
            end
            stats.clocks=stats.clocks+2;stats.ledBoards=stats.ledBoards+1
            if pause then pause() end
        end
        -- Under-canopy exit signs point toward the real end stair; no invented track crossing.
        local exitS = 51
        blue:AddBox(p(st,exitS,center,4.38),Vector3(2.3,.44,.10),angle)
        for _,dx in ipairs({-.90,.90}) do
            if Reference.IsCovered(plan,exitS) then
                beam(steel,p(st,exitS,center+dx,4.60),p(st,exitS,center+dx,roofY(plan,dx)-.03),.025)
            end
        end
        if not Reference.IsCovered(plan,exitS) then
            -- Bare-end directional sign uses one furniture-row cantilever, not
            -- two posts in the boarding aisle and not a floating roof hanger.
            local x=plan.columnCenters[platformIndex]
            steel:AddTube(p(st,exitS,x,plan.platformTop),p(st,exitS,x,4.72),.045,6)
            beam(steel,p(st,exitS,x,4.72),p(st,exitS,center,4.72),.055)
            beam(steel,p(st,exitS,center,4.72),p(st,exitS,center,4.60),.025)
        end
        for face=-1,1,2 do
            textFace(root,st,exitS+face*.065,center,4.38,face,face<0 and "出口 / 天桥  ↑" or "↓  天桥 / 出口",.23,
                "ReferenceExitDirection_"..platformIndex,Color(.95,.97,.96),makeSign)
        end
        for _,ds in ipairs(plan.binOffsets) do
            local x = center+(platformIndex<3 and -2.90 or 2.90)
            steel:AddBox(p(st,ds,x,plan.platformTop+.48),Vector3(.48,.96,.62),angle)
            black:AddBox(p(st,ds,x+(platformIndex<3 and .25 or -.25),plan.platformTop+.75),Vector3(.012,.18,.39),angle)
            blue:AddBox(p(st,ds,x,plan.platformTop+1.0),Vector3(.52,.045,.66),angle)
        end
        if platformIndex==3 then
            for _,ds in ipairs(plan.benchOffsets) do
                for _,dx in ipairs({-.22,-.07,.08,.23}) do
                    steel:AddBox(p(st,ds,11.55+dx,plan.platformTop+.46),Vector3(.11,.045,2.25),angle)
                end
                for _,dz in ipairs({-.82,.82}) do
                    steel:AddBox(p(st,ds+dz,11.55,plan.platformTop+.23),Vector3(.52,.46,.045),angle)
                end
            end
        end
        -- Three open waiting bays per platform, set behind the continuous passenger aisle.
        -- island live paths x=-3.7/-7.1, up path x=8.7 stay entirely unobstructed.
        -- Screen backs sit at +/-2.85 from centre; the seat zone is only .50m deep.
        local outerSide=platformIndex==3 and 1 or -1
        for _,ds in ipairs(plan.waitingOffsets) do
            local backX=center+outerSide*2.85
            local seatX=center+outerSide*2.44
            if plan.waitingScreens then
            for _,dz in ipairs({-2.25,0,2.25}) do
                steel:AddBox(p(st,ds+dz,backX,plan.platformTop+1.23),Vector3(.075,2.46,.075),angle)
            end
            for section=-1,1,2 do
                screens:AddBox(p(st,ds+section*1.125,backX,plan.platformTop+1.35),Vector3(.028,1.94,2.12),angle)
            end
            for _,h in ipairs({.38,1.12,2.38}) do
                beam(steel,p(st,ds-2.25,backX,plan.platformTop+h),p(st,ds+2.25,backX,plan.platformTop+h),.065)
            end
            -- Contrasting etched safety band is visible from the train, not invisible glass only.
            white:AddBox(p(st,ds,backX-outerSide*.022,plan.platformTop+1.33),Vector3(.018,.12,4.35),angle)
            else
                -- Village/mountain halts have an open backed bench, not a miniature
                -- glazed city lounge. Its back is still wholly in the furniture band.
                black:AddBox(p(st,ds,backX,plan.platformTop+.91),Vector3(.065,.38,3.80),angle)
            end
            black:AddBox(p(st,ds,seatX,plan.platformTop+.49),Vector3(.50,.095,3.80),angle)
            for _,dz in ipairs({-1.55,0,1.55}) do
                steel:AddBox(p(st,ds+dz,seatX,plan.platformTop+.25),Vector3(.40,.45,.06),angle)
                steel:AddBox(p(st,ds+dz,seatX,plan.platformTop+.68),Vector3(.52,.055,.055),angle)
            end
            -- A shallow overhead shelter ties the screens to a substantial visible furniture bay.
            if plan.waitingScreens then
                steel:AddBox(p(st,ds,center+outerSide*2.55,plan.platformTop+2.48),Vector3(.82,.10,4.65),angle)
            end
            if pause then pause() end
        end
        -- Vertical ad lightboxes, outside both waiting path and the ds61 stair circulation.
        for advertIndex,ds in ipairs(plan.advertOffsets) do
            local x = center+(platformIndex<3 and -2.90 or 2.90)
            local y = plan.platformTop+1.48
            steel:AddBox(p(st,ds,x,plan.platformTop+.08),Vector3(.54,.16,1.68),angle)
            black:AddBox(p(st,ds,x,y),Vector3(.20,2.60,1.62),angle)
            for face=-1,1,2 do
                -- Ads face across the track, unlike overhead signs which face along the platform.
                local faceX = x+face*.11
                white:AddBox(p(st,ds,faceX,y),Vector3(.016,2.39,1.43),angle)
                advert:AddBox(p(st,ds,faceX+face*.012,y+.20),Vector3(.008,1.36,1.22),angle)
                -- Simple original landscape poster: mountain silhouette / route stripes.
                local a,b,c = p(st,ds-.55,faceX+face*.02,y-.45),p(st,ds+.55,faceX+face*.02,y-.45),p(st,ds-.07,faceX+face*.02,y+.75)
                if face<0 then white:AddTri(c,b,a) else white:AddTri(a,b,c) end
                for row=1,3 do
                    advert:AddBox(p(st,ds,faceX+face*.022,y-.72-row*.11),Vector3(.008,.035,.90-row*.12),angle)
                end
            end
            stats.adverts=stats.adverts+1
            if pause then pause() end
        end
    end
    finish(st,{steel,blue,black,white,red,advert,screens},pause)
end

---@param root Node
---@param st RailwayStation
---@param pause? fun()
function Reference.BuildLightingAndRailings(root,st,pause)
    local plan = Reference.GetPlan(st)
    local stats = assert(stats_[st.index])
    local steel = batch(root,"ReferenceLampHousingsAndRailings",World.Textured("ReferenceFurnitureBrushedSteel",
        "Textures/Railway/coach_steel.png",Color(.25,.29,.30),.80,.34),false,350)
    local bulb = batch(root,"ReferenceLinearLampDiffusers",NightLighting.GetBulbMaterial("station"),false,850)
    local _,_,yaw = Route.Sample(st.s)
    local angle = math.rad(yaw)
    local owner = "station:"..st.index
    NightLighting.Forget(owner)
    local first,last = Route.PlatformStart+6,Route.PlatformEnd-6
    local count = math.max(1,math.ceil((last-first)/18))
    for platformIndex,center in ipairs(plan.platformCenters) do
        for i=0,count do
            local ds = furnitureS(first+(last-first)*i/count,platformIndex)
            local covered = Reference.IsCovered(plan,ds)
            local y = covered and 6.36 or plan.platformTop+6.2
            -- Bare platform poles stay on furniture edge, cantilever puts lamp over walkway.
            if not covered then
                local x = plan.columnCenters[platformIndex]
                steel:AddTube(p(st,ds,x,plan.platformTop),p(st,ds,x,y+.15),.055,8)
                beam(steel,p(st,ds,x,y+.15),p(st,ds,center,y+.15),.065)
                steel:AddBox(p(st,ds,x,plan.platformTop+.10),Vector3(.28,.20,.28),angle)
            else
                for _,dz in ipairs({-.65,.65}) do
                    beam(steel,p(st,ds+dz,center,y+.07),p(st,ds+dz,center,roofY(plan,0)-.20),.023)
                end
            end
            steel:AddBox(p(st,ds,center,y),Vector3(.30,.070,1.60),angle)
            -- 扩散罩露出灯壳下缘和侧缘，高位外景也能看到亮灯，不被薄铁盒完全遮住。
            bulb:AddBox(p(st,ds,center,y-.07),Vector3(.34,.095,1.66),angle)
            -- 光源在扩散罩下方；普通点光照亮台面、候车旅客和雨棚底部。
            NightLighting.Register("station",owner,root,p(st,ds,center,y-.16),Vector3.DOWN,
                {brightness=140,range=30,fov=140,aspect=.75,color=Color(1,.91,.76)})
            stats.lampSites=stats.lampSites+1
        end
        -- Only OUTSIDE edges get guardrails. Never fence the island boarding edge.
        if platformIndex~=2 then
            local x = center+(platformIndex==1 and -1 or 1)*3.38
            for ds=Route.PlatformStart,Route.PlatformEnd-.001,3 do
                local finishS = math.min(Route.PlatformEnd,ds+3)
                -- Leave both real forecourt stair/ramp mouths open on negative platform.
                local opening = platformIndex==1 and ((ds>-55 and ds<-43) or (ds>-41 and ds<-32))
                if not opening then
                    steel:AddBox(p(st,ds,x,plan.platformTop+.60),Vector3(.045,1.20,.045),angle)
                    for _,h in ipairs({.30,.70,1.16}) do
                        beam(steel,p(st,ds,x,plan.platformTop+h),p(st,finishS,x,plan.platformTop+h),.035)
                    end
                    -- One centred open picket per 3m bay; continuous top/mid/bottom
                    -- rails retain the real 1.2m guard, without dense microboxes.
                    steel:AddBox(p(st,(ds+finishS)/2,x,plan.platformTop+.57),Vector3(.022,.98,.022),angle)
                end
            end
        end
        if pause then pause() end
    end
    finish(st,{steel,bulb},pause)
    print(string.format("[ReferenceStation] %s %s: %s/%s %d段棚 覆盖%.0fm(%.0f%%)×3 / %d柱 / %d圆钟 / %dLED牌 / %d灯箱 / %d池灯位 / %d批 %d顶点",
        st.name,plan.identity,plan.serviceTier,plan.roofShape,#plan.roofSegments,plan.coveredLength,plan.coverageRatio*100,
        stats.columns,stats.clocks,stats.ledBoards,stats.adverts,stats.lampSites,stats.batches,stats.vertices))
end

function Reference.GetStats(index) return stats_[index] end
function Reference.Forget(index) stats_[index]=nil end
function Reference.Shutdown() stats_={} end
return Reference
