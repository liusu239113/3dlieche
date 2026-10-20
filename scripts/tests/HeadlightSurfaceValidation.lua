-- 原生车灯几何回归：只建真实车队，不读写玩家存档/云，不调用main或build。
-- 独立Ray:HitDistance三角射线复核每车型灯心/12个灯缘，不能用节点存在代替贴壳验收。
local Train=require "train.Train"
local Modes=require "config.GameModes"
local Route=require "world.Route"
local Night=require "world.NightLighting"
local Catalog=require "config.TrainCatalog"
local Validation={}
---@type Scene?
local scene_=nil
local checks_=0
local function check(value,message) checks_=checks_+1;assert(value,"[HeadlightSurface] "..message) end

---@param model Model
---@return Vector3[][]
local function triangles(model)
    local result={} ---@type Vector3[][]
    for g=0,model.numGeometries-1 do
        local geom=model:GetGeometry(g,0)
        if geom.primitiveType==TRIANGLE_LIST then
            local vb=geom:GetVertexBuffer(0)
            local buffer,offset=vb:GetData(),vb:GetElementOffset(SEM_POSITION)
            local function p(index)
                buffer:Seek(index*vb.vertexSize+offset)
                return buffer:ReadVector3()
            end
            local ib=geom:GetIndexBuffer()
            local indices={} ---@type integer[]
            if ib and geom.indexCount>0 then
                local data=ib:GetData();data:Seek(geom.indexStart*ib.indexSize)
                for _=1,geom.indexCount do indices[#indices+1]=ib.indexSize==2 and data:ReadUShort() or data:ReadUInt() end
            else
                for index=geom.vertexStart,geom.vertexStart+geom.vertexCount-1 do indices[#indices+1]=index end
            end
            for i=1,#indices-2,3 do result[#result+1]={p(indices[i]),p(indices[i+1]),p(indices[i+2])} end
        end
    end
    return result
end

---@param mesh Vector3[][]
---@param point Vector3
---@param nativeEnd number
---@param length number
local function verifySurface(mesh,point,nativeEnd,length)
    local origin=Vector3(point.x*nativeEnd,point.y,(length*.5+1)*nativeEnd)
    local ray=Ray(origin,Vector3(0,0,-nativeEnd))
    local nearest=math.huge
    for _,tri in ipairs(mesh) do
        -- Ray三角接口是单面；另一绕序也测，避免由原模型索引手性决定验收结果。
        local a,b,c=assert(tri[1]),assert(tri[2]),assert(tri[3])
        nearest=math.min(nearest,ray:HitDistance(a,b,c),ray:HitDistance(c,b,a))
    end
    check(nearest<length,"灯区独立射线没有命中")
    local hit=origin+Vector3(0,0,-nativeEnd)*nearest
    check(math.abs(hit.z-point.z*nativeEnd)<.003,"灯具悬空/穿壳："..tostring(point))
end

---@param car TrainCar
---@param direction number
local function verifyCurrent(car,direction)
    local status=Train.GetHeadlightDiagnostics()
    local node=assert(status.node)
    check(node.parent==car.node,"灯未挂在真实行驶端")
    check(node.position:Length()<.00001,"统一BBox灯位重新覆盖贴壳坐标")
    check(#status.mounts==2 and status.lights==2 and status.fillLights==1,"双束实际Light或近轨补光缺失")
    local model=assert(assert(car.drawable).model)
    local mesh=triangles(model)
    local nativeEnd=direction*(car.reverse and -1 or 1)
    for _,mount in ipairs(status.mounts) do
        verifySurface(mesh,mount.surface,nativeEnd,car.length)
        check(#mount.rim==12,"灯缘未逐点求交")
        for _,point in ipairs(mount.rim) do verifySurface(mesh,point,nativeEnd,car.length) end
        local marker=assert(mount.marker)
        check(marker:GetComponent("StaticModel")==nil,"仍用悬空球代替灯具")
        local lens=assert(marker:GetComponent("CustomGeometry"))
        check(not lens.castShadows,"灯面遮挡自己的光")
        local beam=assert(mount.beam)
        check((beam.position-mount.surface):Length()<.065,"真实光源与灯面脱离")
        local light=assert(beam:GetComponent("Light"))
        check(light.lightType==LIGHT_SPOT and not light.perVertex and light.punctualLight,"不是跨平台逐像素Spot")
        check(not light.usePhysicalValues,"光强被物理流明换算二次衰减")
        check((light.viewMask & 2)~=0 and (light.lightMask & 2)~=0,"光源不照实际轨道/站台层")
        check(math.abs(light.outerConeAngle-light.fov*.5)<.001,"PBR衰减锥与裁剪锥脱节")
        local targetDistance=beam.name=="FarBeam" and 70 or 20
        local targetS=Train.GetS()+car.offset+direction*(mount.surface.z+targetDistance)
        local target=Train.GetTrackSample(targetS)+Vector3(0,.34,0)
        check(beam.worldDirection:DotProduct((target-beam.worldPosition):Normalized())>.9999,"投光轴未对准实际前方轨面")
    end
    local original=assert(status.mounts[1].marker).worldPosition
    Train.SetHeadlightMode("off");Train.UpdateHeadlight(1)
    local off=Train.GetHeadlightDiagnostics()
    check(off.lights==0 and off.fillLights==0,"关灯组件或近轨补光未关")
    check(not assert(status.mounts[1].marker).enabled,"关灯灯面还在发亮")
    Train.SetHeadlightMode("on");Train.UpdateHeadlight(0)
    check((assert(status.mounts[1].marker).worldPosition-original):Length()<.00001,"昼夜更新移动灯具")
end

function Validation.Run()
    Modes.Apply("normal");Route.Build()
    scene_=Scene();scene_:CreateComponent("Octree")
    Train.Build(scene_);Train.Reset(Route.GetStations()[1].s+1)
    for _,entry in ipairs(Catalog.Entries) do
        check(Train.Select(entry.id),"无法装配"..entry.id)
        Train.SetHeadlightMode("on");Train.UpdateHeadlight(1)
        verifyCurrent(Train.GetCars()[1],1)
        local snapshot=Train.ExportState()
        snapshot.reversing=true;snapshot.topology=nil
        Train.RestoreState(snapshot);Train.UpdateHeadlight(1)
        verifyCurrent(Train.GetCars()[8],-1)
        snapshot.reversing=false;Train.RestoreState(snapshot);Train.UpdateHeadlight(1)
        verifyCurrent(Train.GetCars()[1],1)
    end
    -- 灯池source父树隐藏、再显现、移动和卸载不得留下旧投光。
    local source=assert(scene_):CreateChild("LampSource")
    local pos=Vector3(0,6.27,0)
    Night.Register("station","surface-test",source,pos,Vector3.DOWN,{brightness=260,range=30,fov=140,aspect=.75})
    Night.SetEnvironment(1,"low");Night.Update(Vector3(0,2,0))
    local found=false
    for _,light in ipairs(Night.GetLights()) do
        if light.enabled then
            found=true
            check((light.node.worldPosition-pos):Length()<.001,"站台Light脱离灯面")
            check(light.brightness==260 and light.lightType==LIGHT_POINT and light.punctualLight,"站台未使用普通点光")
        end
    end
    check(found,"站台没有实际投光")
    source.position=Vector3(0,0,10)
    Night.Update(Vector3(0,2,10))
    for _,light in ipairs(Night.GetLights()) do
        if light.enabled then check(math.abs(light.node.worldPosition.z-10)<.001,"source移动后仍从旧位置照明") end
    end
    source.enabled=false
    for _=1,15 do Night.Update(Vector3(0,2,10)) end
    check(Night.GetStats().activeStation==0,"隐藏源节点仍漏光")
    Night.Forget("surface-test")
    check(Night.GetStats().sites==0,"卸载残留灯位")
    print(string.format("ALL_HEADLIGHT_SURFACE_PASS checks=%d sixModels=true bothEnds=true independentTriangleRays=true",checks_))
    return checks_
end

function Start()
    local ok,message=xpcall(Validation.Run,debug.traceback)
    if not ok then log:Write(LOG_ERROR,tostring(message)) end
    Night.Shutdown();Train.Shutdown()
    if scene_ then scene_:Dispose();scene_=nil end
    engine:Exit()
end
return Validation
