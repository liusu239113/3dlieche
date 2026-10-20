-- 六车型真实成品回归：检查实际StaticModel/Model/纹理，不以source标签代替验收。
-- 本入口只创建验证场景，不运行main、不下载新资产、不烘焙/修改车体。
local Train = require "train.Train"
local Coach = require "train.Coach"
local Catalog = require "config.TrainCatalog"
local CoachModels = require "config.CoachModels"
local RollingStock = require "train.RollingStock"
local Route = require "world.Route"
local GameConfig = require "config.GameConfig"
local Passenger = require "game.PassengerService"
---@type Scene?
local scene_ = nil
local checks_ = 0
local function check(value,message)
    checks_ = checks_ + 1
    assert(value,"[CoachIntegration] " .. message)
end

---@param car TrainCar
local function checkActualTreads(car)
    local model = assert(car.drawable).model
    local geometry = model:GetGeometry(0,0)
    local vb = geometry:GetVertexBuffer(0)
    local data = vb:GetData()
    local po = vb:GetElementOffset(SEM_POSITION)
    local left,right = 0,0
    for i=0,vb.vertexCount-1 do
        data:Seek(i*vb.vertexSize+po)
        local p = data:ReadVector3()
        if math.abs(p.y-Catalog.RailTop) < .035 and math.abs(p.z)>car.pivot*.5 then
            if math.abs(p.x+GameConfig.RailGauge*.5)<.04 then left=left+1 end
            if math.abs(p.x-GameConfig.RailGauge*.5)<.04 then right=right+1 end
        end
    end
    check(left>0 and right>0,car.profile .. "实际MDL未找到两侧踏面顶点")
end

local function validateEntry(entry)
    local ok,message = Train.Select(entry.id,true)
    check(ok,entry.id .. "选择失败：" .. tostring(message))
    local valid,reason = Train.ValidateBindings()
    check(valid,reason)
    local cars = Train.GetCars()
    check(#cars==8,entry.id .. "不是完整8节")
    for i,car in ipairs(cars) do
        local expected,reverse = entry.head,false
        if entry.kind=="emu" then
            local role=assert(entry.roles)[i==1 and "head" or (i==8 and "tail" or "middle")]
            expected,reverse=role.profile,role.reverse==true
        elseif i>1 then expected=assert(Coach.GetIndependentProfile(entry.id)) end
        local asset=assert(Catalog.Assets[expected])
        local drawable=assert(car.drawable)
        check(car.profile==expected and car.reverse==reverse,entry.id .. "车节角色错误")
        check(drawable.model==cache:GetResource("Model",asset.modelPath),entry.id .. "实际MDL不是专属成品")
        check(drawable.model.name==asset.modelPath,entry.id .. "实际MDL路径不一致")
        check(drawable:GetMaterial(0):GetTexture(TU_DIFFUSE)==cache:GetResource("Texture2D",asset.diffusePath),
            entry.id .. "实际涂装绑定错误")
        local facing=assert(car.assetNode).rotation*Vector3.FORWARD
        check((facing-Vector3(0,0,reverse and -1 or 1)):Length()<.0001,entry.id .. "头尾实际旋转错误")
        if entry.kind~="emu" and i>1 then
            check(car.node:GetVar("CoachAssetSource"):GetString()=="generated_asset",entry.id .. "客车来源错误")
            check(#car.bogies==0,entry.id .. "给整体成品叠加了旧程序轮组")
        end
        checkActualTreads(car)
    end
    print(string.format("[CoachIntegration] %s 8/8实际MDL、纹理、角色朝向、实物踏面通过；独立客车=%d",
        entry.id,entry.kind=="emu" and 0 or 7))
end

local function snapshot()
    return {id=Train.GetSelectedId(),root=Train.GetRoot(),cars=Train.GetCars(),lead=Train.GetLeadNode(),
        s=Train.GetS(),v=Train.GetSpeedMs(),throttle=Train.GetThrottle(),brake=Train.GetBrake(),
        length=Train.GetActiveLength(),livery=Coach.GetLiveryId()}
end
local function unchanged(old)
    check(Train.GetSelectedId()==old.id and Train.GetRoot()==old.root and Train.GetCars()==old.cars
        and Train.GetLeadNode()==old.lead,"失败替换没有保留原车节点")
    check(Train.GetS()==old.s and Train.GetSpeedMs()==old.v and Train.GetThrottle()==old.throttle
        and Train.GetBrake()==old.brake and Train.GetActiveLength()==old.length,"失败替换改变驾驶状态")
    check(Coach.GetLiveryId()==old.livery,"失败替换未恢复客车队状态")
end

local function missingProfiles()
    for _,entry in ipairs(Catalog.Entries) do
        if entry.kind=="locomotive" then
            local spec=assert(CoachModels.Find(entry.id))
            local profile=spec.profileId
            local old=snapshot()
            spec.profileId=nil
            local ok,reason=xpcall(function()
                check(not Coach.Prepare(entry.id),"正式车队缺profile仍允许Prepare")
                for _,item in ipairs(Train.GetCatalog()) do
                    if item.id==entry.id then check(not item.ready,"缺profile目录仍标ready") end
                end
                check(not Train.Select(entry.id,true),"缺profile换车竟成功")
                local scratch=assert(scene_):CreateChild("MissingProfileProbe")
                local built=pcall(Coach.Build,scratch,1,1,entry.id)
                check(not built and #scratch:GetComponents("StaticModel",true)==0,"缺profile仍生成程序化客车")
                scratch:Dispose()
                unchanged(old)
            end,debug.traceback)
            spec.profileId=profile
            assert(ok,reason)
        end
    end
end

local function failedAssembly()
    local old=snapshot()
    local original=RollingStock.Build
    local calls=0
    RollingStock.Build=function(parent,id,reverse)
        local node,drawable=original(parent,id,reverse)
        calls=calls+1
        if calls==7 then
            -- 伪造标签仍正确，但真实第7节绑定成头车；事务必须发现并拒绝。
            drawable.model=assert(Train.GetCars()[1].drawable).model
        end
        return node,drawable
    end
    local ok,reason=xpcall(function()
        check(not Train.Select("DF4D",true),"错误实际MDL绑定未阻止提交")
        unchanged(old)
        check(Train.ValidateBindings(),"失败后原八节真实绑定损坏")
        check(#assert(Train.GetRoot()):GetChildren()==1,"失败暂存Vehicles子树未释放")
    end,debug.traceback)
    RollingStock.Build=original
    assert(ok,reason)
end

local function passengerSnapshotsEqual(before,after)
    check(before.boarded==after.boarded and before.alighted==after.alighted and before.visits==after.visits
        and #before.onboard==#after.onboard and #before.actors==#after.actors,"换车/恢复丢失客流数量或奖励进度")
    for i,actor in ipairs(before.actors) do
        local restored=assert(after.actors[i])
        check(actor.id==restored.id and actor.completed==restored.completed and actor.destination==restored.destination
            and (Vector3(table.unpack(actor.position))-Vector3(table.unpack(restored.position))):Length()<.00001,
            "换车/恢复改变乘客身份、完成记录、目的地或脚底位置")
    end
end

local function independentCoachDoorPlans()
    Passenger.Init(assert(scene_))
    local station=Route.GetStations()[1]
    check(Passenger.BeginStop(station,{initial=true,destinations={2,3,4,5}}),"无法建立真实始发站停")
    Passenger.Update(.1);Passenger.Update(10)
    local initial=Passenger.ExportState()
    check(initial.boarded>0 and #initial.onboard>0,"测试没有真实完成至少一人登乘")
    for _,entry in ipairs(Catalog.Entries) do
        if entry.kind=="locomotive" then
            local before=Passenger.ExportState()
            check(Train.Select(entry.id,true),"合法站停独立客车换车失败："..entry.id)
            Passenger.RefreshDoorPlan()
            passengerSnapshotsEqual(before,Passenger.ExportState())
            local plan=Passenger.GetDoorPlan()
            check(plan.valid and #plan.doors==14,"独立七客车没有14个安全模拟玄关："..entry.id)
            local covered={}
            for _,door in ipairs(plan.doors) do
                local car=Train.GetCars()[door.carIndex]
                check(door.carIndex>1 and car.profile==Coach.GetIndependentProfile(entry.id)
                    and door.source=="simulated_coach_end_vestibule","机车被当客运门或模拟锚冒充实测")
                check((door.position-door.edge):Length()<.95 and math.abs(door.position.y-door.edge.y)<=.35
                    and door.s>=station.s+Route.PlatformStart+1 and door.s<=station.s+Route.PlatformEnd-1,
                    "独立客车门跨轨/高差/站台纵向包络不安全")
                covered[door.carIndex]=true
            end
            local count=0;for _ in pairs(covered) do count=count+1 end
            check(count==7,"未覆盖所有七节独立客车")
            local trainSaved,passengersSaved=Train.ExportState(),Passenger.ExportState()
            Train.RestoreState(trainSaved);Passenger.RestoreState(passengersSaved)
            passengerSnapshotsEqual(passengersSaved,Passenger.ExportState())
            check(Passenger.GetDoorPlan().valid and Train.ValidateBindings(),"独立客车SaveRestore真实门/MDL绑定失败")
            local reverse,changed=Train.ToggleReversing()
            check(not reverse and not changed,"始发下行不能原地逆股运行")
            check(Passenger.BuildDoorPlan(station).doors[1].side==-1,"换向拒绝改变物理门侧或岛台方位")
            print("[CoachIntegration] "..entry.id.." 7客车14安全模拟玄关/部分上车清单原位/SaveRestore通过")
        end
    end
    local old=snapshot()
    local people=Passenger.ExportState()
    local target=assert(Coach.GetIndependentProfile("DF4D"))
    local profile=Catalog.Profiles[target]
    local width=profile.width
    local validator=Passenger.ValidateTrainSelection
    local observed=false
    Train.SetSelectionValidator(function(id,candidateCars)
        observed=true
        check(Train.GetCars()==old.cars,"提交前只读校验暴露未提交车节")
        profile.width=8 -- 仅门位安全探针：不触发更早的模型尺寸校验来冒充平台拒绝。
        local called,compatible,message=pcall(validator,id,candidateCars)
        profile.width=width
        assert(called,compatible)
        return compatible,message
    end)
    local ok,reason=pcall(function()
        check(not Train.Select("DF4D",true),"不安全平台门位仍提交新编组")
        unchanged(old)
        passengerSnapshotsEqual(people,Passenger.ExportState())
        check(observed and Passenger.GetDoorPlan().valid and Train.ValidateBindings(),"失败影响旧门计划/旧模型")
    end)
    profile.width=width
    Train.SetSelectionValidator(validator)
    assert(ok,reason)
    Passenger.Shutdown()
end

function Start()
    local ok,reason=xpcall(function()
        scene_=Scene()
        scene_:CreateComponent("Octree")
        Route.Build()
        Train.Build(assert(scene_))
        Train.Reset(0)
        for _,entry in ipairs(Catalog.Entries) do validateEntry(entry) end
        check(#Catalog.Entries==6,"未覆盖六车型")
        missingProfiles()
        failedAssembly()
        check(Train.Select("DF4D"),"故障恢复后不能换车")
        Train.Reset(Route.GetStations()[1].s)
        independentCoachDoorPlans()
        check(Train.Select("DF4D"),"客流回归结束无法恢复测试车型")
        local activeSpec=assert(CoachModels.Find("DF4D"))
        local activeProfile=assert(activeSpec.profileId)
        local activeCalibration=RollingStock.GetCalibration(activeProfile)
        local activeOld=snapshot()
        activeSpec.profileId=nil
        local preserved,preservedError=pcall(function()
            check(not Train.Select("DF4D",true),"当前车型配置丢失未拒绝")
            unchanged(activeOld)
            check(RollingStock.GetCalibration(activeProfile)==activeCalibration,"失败释放了旧车仍引用的成品缓存")
        end)
        activeSpec.profileId=activeProfile
        assert(preserved,preservedError)
        Train.SetThrottle(3);Train.SetBrake(.4)
        local before=snapshot()
        check(Train.Select("DF4D"),"同车型兼容选择失败")
        check(Train.GetLeadNode()==before.lead,"无force不应重建同车型")
        local car=Train.GetCars()[4]
        assert(car.drawable).model=assert(Train.GetCars()[1].drawable).model
        check(not Train.ValidateBindings(),"实例损坏未被发现")
        local oldLead=Train.GetLeadNode()
        check(Train.Select("DF4D",true),"同ID强制重建未恢复损坏实例")
        check(Train.GetLeadNode()~=oldLead and Train.GetRoot()==before.root,"强制重建未保留根/替换实例")
        check(Train.ValidateBindings(),"修复后的实际绑定失败")
        check(Train.GetS()==before.s and Train.GetBrake()==1 and Train.GetThrottle()==0,"修复后位置/安全制动错误")
        Train.SetThrottle(8);Train.SetBrake(0);Train.Update(.2)
        local moving=snapshot()
        check(math.abs(moving.v)>.1 and not Train.IsDerailed(),"测试列车未在轨道内真正移动")
        check(not Train.Select("DF4D",true),"行驶中允许强制重建")
        unchanged(moving)
        print(string.format("COACH_INTEGRATION_PASS sixTrains=6 externalMDL=48 independentCoaches=28 failureRollback=true forceRebuild=true checks=%d",checks_))
    end,debug.traceback)
    if not ok then log:Write(LOG_ERROR,"COACH_INTEGRATION_FAILED " .. tostring(reason)) end
end

function Stop()
    Passenger.Shutdown()
    Train.Shutdown()
    if scene_ then scene_:Dispose();scene_=nil end
end
