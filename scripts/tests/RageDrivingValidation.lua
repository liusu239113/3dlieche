-- 基于现有TrainDynamicsValidation的真实动力回归，不复制Train.Update的积分公式。
-- 狂暴玩家仅有纵向自由度；真实弯道/道岔采样后保持车体直立，不创建侧翻姿态。
local Modes=require "config.GameModes"
local Config=require "config.GameConfig"
local Route=require "world.Route"
local Train=require "train.Train"
local Catalog=require "config.TrainCatalog"
local Network=require "world.RailNetwork"
---@type Scene?
local scene_=nil
local checks_=0
local function check(value,message)
    checks_=checks_+1
    assert(value,"[RageDriving] "..message)
end
local function advance(seconds)
    for _=1,math.floor(seconds/.02) do Train.Update(.02) end
    Train.UpdateVisuals(0)
end
local function snapshotAt(s,v)
    local value=Train.ExportState()
    value.s,value.v,value.throttle,value.brake=s,v,0,0
    value.derailed=false
    value.reversing=false
    value.topology=nil
    Train.RestoreState(value)
end
function Start()
    local ok,message=xpcall(function()
        Modes.Apply("normal");Route.Build()
        local normalLength=Route.GetLength()
        local default=assert(Catalog.Find(Catalog.DefaultId))
        Modes.Apply("rage");Route.Build()
        check(Route.GetLength()>normalLength*1.5,"狂暴不是独立长图")
        check(Route.PlatformEnd-Route.PlatformStart==550,"站台未加长")
        scene_=Scene();scene_:CreateComponent("Octree")
        Train.Build(scene_)
        local first=assert(Route.GetStations()[1])
        Train.Reset(first.s+1)
        check(Train.IsRageMode(),"模式未接真实Train")
        check(Train.GetCarCount()==8 and Train.ValidateBindings(),"玩家编组不是8节真实MDL")
        Train.SetBrake(0);Train.SetThrottle(Config.Train.MaxThrottle)
        advance(50)
        check(Train.GetSpeedKmh()>default.operatingSpeedKmh,"狂暴牵引没有超越原运营速度")
        check(not Train.IsDerailed(),"狂暴牵引误触发事故")
        local arcS=0.0
        for _,segment in ipairs(Route.GetSegments()) do
            if segment.type=="arc" then arcS=segment.s+segment.length*.5;break end
        end
        check(arcS>0,"未找到真实弯道")
        snapshotAt(arcS,400)
        advance(3)
        check(Train.GetSpeedMs()>390,"狂暴被构造速度/曲线限制强制截断")
        check(not Train.IsDerailed() and not Train.GetAccidentStatus().active,"超速弯道仍侧翻")
        for _,car in ipairs(Train.GetCars()) do
            local forward=car.node.worldRotation*Vector3.FORWARD
            local front=Train.GetTrackSample(Train.GetS()+car.offset+car.pivot)
            local rear=Train.GetTrackSample(Train.GetS()+car.offset-car.pivot)
            local axis=(front-rear):Normalized()
            local right=car.node.worldRotation*Vector3.RIGHT
            check((forward-axis):Length()<.0001 and math.abs(right.y)<.0001,
                "玩家车厢未跟坡或出现横滚")
        end
        local gradeS=0.0
        for s=500,Route.GetLength()-500,80 do
            if Route.GradeAt(s)>.025 and Route.GradeAt(s-240)>.025 then gradeS=s;break end
        end
        check(gradeS>0,"未找到整列都在真实上坡的区段")
        snapshotAt(gradeS,35)
        local uphillStart=Train.GetSpeedMs()
        advance(1)
        check(Train.GetSpeedMs()<uphillStart,"上坡未受重力减速")
        for _,car in ipairs(Train.GetCars()) do
            local front=Train.GetTrackSample(Train.GetS()+car.offset+car.pivot)
            local rear=Train.GetTrackSample(Train.GetS()+car.offset-car.pivot)
            check(math.abs(front.y-rear.y)>.1,"真实坡道八节支点仍全在平面")
            check((car.node.worldPosition-(front+rear)*.5):Length()<.002,"坡道车体未落两支点中点")
            check(((car.node.worldRotation*Vector3.FORWARD)-(front-rear):Normalized()):Length()<.0001,
                "车头方向未跟真实坡面")
            check(math.abs((car.node.worldRotation*Vector3.RIGHT).y)<.0001,"爬坡错误产生横滚")
        end
        Train.SetHeadlightMode("auto");Train.UpdateHeadlight(0)
        check(not Train.GetHeadlightDiagnostics().enabled,"自动车灯白天没有关闭")
        Train.UpdateHeadlight(1)
        check(Train.GetHeadlightDiagnostics().lights==2,"自动车灯夜间双束未亮")
        Train.SetHeadlightMode("off");Train.UpdateHeadlight(1)
        check(not Train.GetHeadlightDiagnostics().enabled,"手动关闭被夜间更新覆盖")
        Train.SetHeadlightMode("on");Train.UpdateHeadlight(0)
        check(Train.GetHeadlightDiagnostics().lights==2,"手动开启被白天更新覆盖")
        check(not Train.SetHeadlightMode("invalid") and Train.GetHeadlightMode()=="on","无效车灯模式污染状态")
        snapshotAt(gradeS,0);Train.SetBrake(1)
        local _,slopeReversed=Train.ToggleReversing()
        check(slopeReversed,"坡道停稳无法原股换向")
        Train.UpdateHeadlight(1)
        check(Train.GetHeadlightDiagnostics().node.parent==Train.GetCars()[8].node,"反向车灯未移到真实尾端")
        local savedLight=Train.ExportState()
        Train.SetHeadlightMode("off");Train.RestoreState(savedLight)
        check(Train.GetHeadlightMode()=="on","车灯手动模式读档丢失")
        check(Train.Derail("测试碰撞") == false and not Train.IsDerailed(),"狂暴玩家碰撞仍结束本局")
        snapshotAt(Route.GetLength()-25,100)
        advance(1)
        check(Train.GetS()<=Route.GetLength()-20 and Train.GetSpeedMs()==0,"开放末端未安全缓冲")
        check(not Train.IsDerailed(),"开放末端倾覆")
        local _,changed=Train.ToggleReversing()
        check(changed,"末端停稳不能R换向")
        Train.SetBrake(0);Train.SetThrottle(8);advance(2)
        check(Train.GetSpeedMs()<0,"换向后未真实反向运行")
        local moving=Train.ExportState()
        Train.RestoreState(moving)
        check(math.abs(Train.GetSpeedMs()-moving.v)<1e-6,"狂暴速度读档丢失")
        Train.Shutdown();scene_:Dispose();scene_=nil
        Modes.Apply("normal");Route.Build()
        scene_=Scene();scene_:CreateComponent("Octree")
        Train.Build(scene_);Train.Reset(assert(Route.GetStations()[1]).s+1)
        check(not Train.IsRageMode(),"普通残留狂暴规则")
        check(Train.GetMaxSpeedKmh()==default.maxSpeedKmh,"普通量程/构造速度改变")
        check(math.abs(Route.GetLength()-normalLength)<.001 and Route.PlatformEnd-Route.PlatformStart==310,
            "切回普通地图/站台没有恢复")
        local uphillS,downhillS=0.0,0.0
        for s=34000,Route.GetLength()-500,40 do
            if Route.GradeAt(s)>.015 and Route.GradeAt(s-240)>.015 then uphillS=s end
            if Route.GradeAt(s)<-.015 and Route.GradeAt(s-240)<-.015 then downhillS=s end
        end
        check(uphillS>0 and downhillS>0,"普通新图缺整列坡段")
        snapshotAt(uphillS,25)
        local upStart=Train.GetSpeedMs();advance(1)
        local upChange=Train.GetSpeedMs()-upStart
        check(upChange<-.1,"普通上坡没有重力减速")
        snapshotAt(downhillS,25)
        local downStart=Train.GetSpeedMs();advance(1)
        check(Train.GetSpeedMs()>downStart,"普通下坡没有重力助推")
        check(Train.GetServiceDeceleration(true)<Train.GetServiceDeceleration(),"普通山区制动提示未预留下坡余量")
        snapshotAt(1500,25)
        check(Train.GetServiceDeceleration(true)==Train.GetServiceDeceleration(),"前段平地提示被山区污染")
        snapshotAt(1500,180)
        advance(2)
        check(Train.IsDerailed(),"普通结构超速事故被狂暴规则永久关闭")
        Train.Shutdown();scene_:Dispose();scene_=nil
        Network.Reset(0,0,false)
        print(string.format("ALL_RAGE_DRIVING_PASS checks=%d realTrain=true infiniteLineSpeed=true upright=true normalAccidentsPreserved=true",checks_))
    end,debug.traceback)
    if not ok then log:Write(LOG_ERROR,tostring(message)) end
    if scene_ then Train.Shutdown();scene_:Dispose();scene_=nil end
    Modes.Apply("normal")
    engine:Exit()
end
