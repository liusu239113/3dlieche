-- 由3D场景脚手架/StationCanopyValidation派生，直接构建生产车站；不修改主入口。
-- 验收五站双面站名/邻站方向、驾驶40m识别、夜间、站房与流式重建。
local Route=require "world.Route"
local Station=require "world.Station"
local Config=require "config.GameConfig"
---@type Scene?
local scene_=nil
---@type Node?
local root_=nil
---@type Node?
local cameraNode_=nil
---@type Camera?
local camera_=nil
---@type Zone?
local zone_=nil
---@type Light?
local sun_=nil
local stationIndex_,viewIndex_,age_,checks_,captures_=1,1,0,0,0
local failed_,checked_=false,false
local VIEWS={"side_day","reverse_night","cab_40m_day","cab_40m_night","house_day"}

local function check(value,message)
    checks_=checks_+1
    assert(value,message)
end
local function guarded(action)
    if failed_ then return end
    local ok,message=xpcall(action,debug.traceback)
    if not ok then failed_=true;log:Write(LOG_ERROR,tostring(message));engine:Exit() end
end
local function activate(index)
    if root_ then
        Station.Forget(stationIndex_)
        root_:Dispose()
        root_=nil
    end
    stationIndex_,viewIndex_,age_,checked_=index,1,0,false
    -- 故意在建站前设夜间，验证流式新站继承，而非只更新启动时已有灯。
    Station.SetEnvironment(1)
    root_=assert(scene_):CreateChild("StationSignAcceptance")
    Station.BuildOne(root_,assert(Route.GetStations()[index]))
end

local function geometryChecks()
    local st=assert(Route.GetStations()[stationIndex_])
    local node=assert(assert(root_):GetChild("Station_"..st.name))
    local info=Station.GetSignInfo(st)
    local stations=Route.GetStations()
    check(st.name==Config.Stations[stationIndex_].name,"站名脱离统一配置")
    check(info.previousName==(stationIndex_>1 and stations[stationIndex_-1].name or "线路起点"),"开放线路上站错误")
    check(info.nextName==(stationIndex_<#stations and stations[stationIndex_+1].name or "线路终点"),"开放线路下站错误")
    local right,tangent=Route.RightAt(st.s),Route.TangentAt(st.s)
    local names,approaches,neighbours,stops=0,0,0,0
    for _,textNode in ipairs(node:GetChildrenWithComponent("Text3D",true)) do
        local label=assert(textNode:GetComponent("Text3D"))
        check(label.faceCameraMode==FC_NONE and not label.fixedScreenSize,"文字随相机旋转或远处等屏缩放")
        check(not label.castShadows and label.drawDistance<=220,"文字阴影/绘距预算失效")
        local parent=assert(textNode.parent)
        if parent.name:match("^StationName_") then
            check(label.worldBoundingBox.min.y>Station.GetDimensions().platformTopY+2.28
                and label.worldBoundingBox.max.y<Station.GetDimensions().platformTopY+3.23,"主站名字形越出独立行或重叠台号")
        elseif parent.name:match("^StationNeighbourDirection_") then
            check(label.worldBoundingBox.max.y<Station.GetDimensions().platformTopY+2.28,"邻站行与主站名重叠")
        elseif parent.name:match("^StationPlatformNumber_") then
            check(label.worldBoundingBox.min.y>Station.GetDimensions().platformTopY+3.23,"台号与主站名重叠")
        end
        local normal=parent.worldRotation*Vector3(0,0,-1)
        if parent.name:match("^StationName_") then
            names=names+1
            check(label.text==st.name,"双面站名错误")
            local logicalFace=parent.name:find("OuterFace",1,true) and 1 or -1
            local lat=(parent.worldPosition-Route.Sample(st.s)):DotProduct(right)
            local face=lat>-11 and -logicalFace or logicalFace
            check(normal:DotProduct(right*face)>.999,"站牌可读正面朝向错误")
            check(label.worldBoundingBox.size.y>.45,"站名实体字高仍过小")
            check(label.worldBoundingBox.size:Length()<5.8,"主站名超出牌面")
            -- 每面中央字形前方2m不得被自身立柱/雨棚柱挡住（不把文字当碰撞体）。
            local textCenter=label.worldBoundingBox.center
            local hits=assert(assert(scene_):GetComponent("Octree")):Raycast(
                Ray(textCenter+normal*2,-normal),RAY_TRIANGLE,1.98,DRAWABLE_GEOMETRY,2)
            for _,hit in ipairs(hits) do
                -- Text3D宽松包围盒也参加RAY_TRIANGLE，不把自身字形包络误当实体遮挡。
                check(not hit.drawable or hit.drawable.node:GetComponent("Text3D")~=nil,
                    "站牌实体立柱或雨棚柱穿过主站名正前方")
            end
        elseif parent.name:match("^StationNeighbourDirection_") then
            neighbours=neighbours+1
            local logicalFace=parent.name:find("OuterFace",1,true) and 1 or -1
            local lat=(parent.worldPosition-Route.Sample(st.s)):DotProduct(right)
            local face=lat>-11 and -logicalFace or logicalFace
            local expected=face<0 and "← "..info.nextLabel.."     "..info.previousLabel.." →"
                or "← "..info.previousLabel.."     "..info.nextLabel.." →"
            check(label.text==expected,"背面邻站方向未交换")
            local textRight=parent.worldRotation*Vector3.RIGHT
            check(textRight:DotProduct(tangent)*face>.999,"屏幕右箭头不指向对应里程")
            check(label.worldBoundingBox.size:Length()<5.8,"邻站文字超出牌面")
        elseif parent.name:match("^ApproachStationName_") then
            approaches=approaches+1
            check(label.text==st.name,"进站识别牌不显示配置站名")
            local arrival=parent.name:find("ArrivalFace",1,true)~=nil
            check(normal:DotProduct(tangent*(arrival and -1 or 1))>.999,"进站识别牌朝向错误")
        elseif parent.name:match("^StationStopTarget_") then
            stops=stops+1
            check(math.abs(Route.ProjectApprox(parent.worldPosition)-st.s)<.12,"停车牌面偏离运营停靠点超过板厚余量")
        end
    end
    check(names==12 and neighbours==12 and approaches==4 and stops==2,"双面站牌数量错误")
    local vertices=0
    for _,name in ipairs({"SignPosts","CityNameBoards","StationSignAccents"}) do
        local geom=assert(assert(node:GetChild(name)):GetComponent("CustomGeometry"))
        check(not geom.castShadows or name=="SignPosts","发光牌面意外投影")
        vertices=vertices+geom:GetNumVertices(0)
    end
    check(vertices<2400,"站牌未合批或几何预算失控")
    local lights=node:GetChildrenWithComponent("Light",true)
    check(#lights==2,"站台超过每侧一盏近景补光预算")
    for _,lightNode in ipairs(lights) do
        local light=assert(lightNode:GetComponent("Light"))
        check(light.enabled and math.abs(light.brightness-8)<.001,"新建站未继承夜间因子")
        check(not light.castShadows and light.range<=9 and light.drawDistance<=80,"补光超预算")
    end
    Station.SetEnvironment(0)
    for _,lightNode in ipairs(lights) do check(not assert(lightNode:GetComponent("Light")).enabled,"白天未关补光") end
    Station.SetEnvironment(1)
    check(#Station.GetPlacementData()==1,"流式卸载未清站点记录")
    print(string.format("[StationSignValidation] GEOMETRY station=%s labels=%d signVertices=%d lights=%d",st.name,#node:GetChildrenWithComponent("Text3D",true),vertices,#lights))
end

local function applyView()
    local st=Route.GetStations()[stationIndex_]
    local mode=VIEWS[viewIndex_]
    local night=mode=="reverse_night" or mode=="cab_40m_night"
    local zone,sun=assert(zone_),assert(sun_)
    zone.ambientColor=night and Color(.012,.018,.030) or Color(.34,.37,.40)
    zone.fogColor=night and Color(.018,.028,.050) or Color(.64,.73,.81)
    sun.brightness=night and .08 or 1.8
    Station.SetEnvironment(night and 1 or 0)
    local camera,node=assert(camera_),assert(cameraNode_)
    camera.fov=62
    if mode=="side_day" then
        node.worldPosition=Route.SampleOffset(st.s+Station.GetSignInfo(st).centerAlong,-15,3.45)
        node:LookAt(Route.SampleOffset(st.s+Station.GetSignInfo(st).centerAlong,7.2,4.1))
    elseif mode=="reverse_night" then
        node.worldPosition=Route.SampleOffset(st.s+Station.GetSignInfo(st).centerAlong,29,3.45)
        node:LookAt(Route.SampleOffset(st.s+Station.GetSignInfo(st).centerAlong,7.2,4.1))
    elseif mode=="house_day" then
        node.worldPosition=Route.SampleOffset(st.s-55,-39,3.4)
        node:LookAt(Route.SampleOffset(st.s-55,-58,6.7))
    else
        -- 正常驾驶机位高3.45m，fov62，不偷改焦距放大站牌。
        local along=Route.PlatformStart+12-40
        node.worldPosition=Route.SampleOffset(st.s+along,0,3.45)
        node.rotation=Quaternion(select(3,Route.Sample(st.s)),Vector3.UP)
    end
end

function Start()
    guarded(function()
        Route.Build()
        Station.Init()
        scene_=Scene()
        local octree=scene_:CreateComponent("Octree")
        octree:SetSize(BoundingBox(Vector3(-50000,-1000,-50000),Vector3(50000,1000,50000)),8)
        zone_=scene_:CreateComponent("Zone")
        zone_.boundingBox=BoundingBox(Vector3(-50000,-1000,-50000),Vector3(50000,1000,50000))
        zone_.ambientSource=AMBIENT_COLOR
        zone_.depthFogStart,zone_.depthFogEnd=300,800
        local sunNode=scene_:CreateChild("SignAcceptanceSun")
        sunNode.direction=Vector3(.35,-1,.55)
        sun_=sunNode:CreateComponent("Light")
        sun_.lightType,sun_.castShadows=LIGHT_DIRECTIONAL,false
        cameraNode_=scene_:CreateChild("SignAcceptanceCamera")
        camera_=cameraNode_:CreateComponent("Camera")
        camera_.nearClip,camera_.farClip,camera_.viewMask=.1,900,7
        renderer:SetViewport(0,Viewport:new(scene_,camera_))
        renderer.hdrRendering=true
        renderer.dynamicInstancing=true
        activate(1)
        SubscribeToEvent("PostUpdate","HandleStationSignValidationUpdate")
        SubscribeToEvent("EndRendering","HandleStationSignValidationCapture")
    end)
end
---@param eventType string
---@param eventData PostUpdateEventData
function HandleStationSignValidationUpdate(eventType,eventData)
    guarded(function()
        age_=age_+1
        if not checked_ then geometryChecks();checked_=true end
        applyView()
        check(age_<24,"站牌截图未按有界帧数完成")
    end)
end
---@param eventType string
---@param eventData EndRenderingEventData
function HandleStationSignValidationCapture(eventType,eventData)
    guarded(function()
        if age_<6 then return end
        local image=Image()
        if not graphics:TakeScreenShot(image) then image:Dispose();return end
        local key=stationIndex_.."_"..VIEWS[viewIndex_]
        check(image:SavePNG("/workspace/screenshots/station_sign_"..key..".png"),"站牌截图未落盘")
        image:Dispose()
        captures_=captures_+1
        print(string.format("[StationSignValidation] REAL_CAPTURE %s batches=%d primitives=%d",key,renderer.numBatches,renderer.numPrimitives))
        age_=0
        if viewIndex_<#VIEWS then viewIndex_=viewIndex_+1
        elseif stationIndex_<#Route.GetStations() then activate(stationIndex_+1)
        else
            check(captures_==25,"五站日/夜/正背面/驾驶/站房未全覆盖")
            Station.Forget(stationIndex_)
            assert(root_):Dispose()
            root_=nil
            Station.SetEnvironment(.5)
            Station.Shutdown()
            print(string.format("ALL_STATION_SIGN_PASS stations=5 views=%d checks=%d",captures_,checks_))
            engine:Exit()
        end
    end)
end
