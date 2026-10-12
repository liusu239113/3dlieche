-- 真实主入口内舱/站房验收：四机位、六车型换车、实时显示、外景隐藏和重开。
require "main"
local gameStart,gameUpdate,gamePost=Start,HandleUpdate,HandlePostUpdate
local Train=require "train.Train"
local Camera=require "train.Camera"
local Cab=require "train.CabInterior"
local Stream=require "world.WorldStream"
local Route=require "world.Route"
local Station=require "world.Station"
local Hud=require "ui.Hud"
local UI=require "urhox-libs/UI"
---@type Scene?
local scene_=nil
local frame_,case_,age_,checks_,failed_=0,1,0,0,false
local captured_={}
local cases_={
    {id="CR400AF",mode="cab",name="cab_driver_integrated"},
    {id="CR400AF",mode="cab_window",name="cab_window_integrated"},
    {id="CR400AF",mode="copilot",name="cab_copilot_integrated"},
    {id="CR400AF",mode="instruments",name="cab_instruments_integrated"},
    {id="CR400AF",mode="cab",name="cab_fixed_seats_integrated",seats=true},
    {id="CRH380A",mode="cab",name="cab_m30_integrated"},
    {id="HXD3D",mode="cab",name="cab_e32_integrated"},
    {id="SS9G",mode="cab",name="cab_e21_integrated"},
    {id="DF4D",mode="cab",name="cab_d18_integrated"},
    {id="blue_white",mode="cab",name="cab_d12_integrated"},
    {id="CR400AF",mode="front_chase",name="station_house_integrated",station=true},
}
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
    case_,age_=index,0
    local c=assert(cases_[index])
    if Train.GetSelectedId()~=c.id then
        local ok,message=Train.Select(c.id)
        check(ok,"换车失败："..tostring(message))
    end
    Train.Reset(Route.GetStations()[1].s+1)
    Train.UpdateVisuals(0)
    check(Camera.SetMode(c.mode),"机位不存在")
    Camera.Update(.25,Train.GetS())
    Hud.HideBanner()
    print("[CabIntegration] CASE "..c.name)
end
function Start()
    guarded(function()
        gameStart()
        TogglePause()
        scene_=assert(renderer:GetViewport(0).scene)
        check(#Camera.GetPresets()==16,"机位目录丢失")
        activate(1)
        SubscribeToEvent("EndRendering","HandleCabIntegrationCapture")
    end)
end
---@param eventType string
---@param eventData UpdateEventData
function HandleUpdate(eventType,eventData)
    guarded(function()
        gameUpdate(eventType,eventData)
        frame_,age_=frame_+1,age_+1
        check(frame_<400,"内舱验收超出有界帧数")
    end)
end
---@param eventType string
---@param eventData PostUpdateEventData
function HandlePostUpdate(eventType,eventData)
    guarded(function()
        if captured_[case_] and age_>24 then activate(case_+1) end
        gamePost(eventType,eventData)
        for _=1,64 do
            if Stream.GetStats().pendingTasks==0 then break end
            Stream.Update(Train.GetS(),0)
        end
        local c=cases_[case_]
        if c.station then
            check(not Cab.IsVisible(),"外景仍显示漂浮内舱")
            local node=assert(Camera.GetNode())
            local origin,_,yaw=Route.Sample(Route.GetStations()[1].s-55)
            local rotation=Quaternion(yaw,Vector3.UP)
            node.worldPosition=origin+rotation*Vector3(-22,15,38)
            node:LookAt(origin+rotation*Vector3(-68,10,0))
            assert(Camera.GetCamera()).fov=62
        end
        if c.seats then
            -- 独立检视机位朝后拍摄固定柱座，不改变生产16机位目录。
            local root=assert(Cab.GetRoot())
            local node=assert(Camera.GetNode())
            node.worldPosition=root:LocalToWorld(Vector3(0,-.02,.35))
            node:LookAt(root:LocalToWorld(Vector3(0,-.70,-1.65)))
            assert(Camera.GetCamera()).fov=72
        end
        -- 将测试读数保持多个真实渲染帧，不在截图同帧改字又恢复，避免只测字符串。
        if not c.station and age_>=14 then
            Cab.Update(assert(Train.GetLeadNode()),.21,123,7,8,.65,false)
        end
        if age_==8 or age_==14 then
            local image=Image()
            if graphics:TakeScreenShot(image) then
                check(image:SavePNG(string.format("/workspace/screenshots/probe_%s_%d.png",c.name,age_)),"连续读回失败")
            end
            image:Dispose()
        end
    end)
end
---@param eventType string
---@param eventData EndRenderingEventData
function HandleCabIntegrationCapture(eventType,eventData)
    guarded(function()
        if age_<20 or captured_[case_] or Stream.GetStats().pendingTasks~=0 then return end
        local c=cases_[case_]
        local scene=assert(scene_)
        local cameraNode=assert(Camera.GetNode())
        local forward=cameraNode.worldRotation*Vector3.FORWARD
        local localForward=assert(Train.GetLeadNode()).worldRotation:Inverse()*forward
        print(string.format("[CabIntegration] POSE %s mode=%s forward=%.3f/%.3f/%.3f yaw=%.2f pitch=%.2f",c.name,Camera.GetMode(),localForward.x,localForward.y,localForward.z,cameraNode.rotation:YawAngle(),cameraNode.rotation:PitchAngle()))
        local roots=0
        for _,node in ipairs(scene:GetChildren()) do
            check(not node.name:match("^ProceduralCab_"),"仍有旧方块内舱")
            if node.name:match("^GeneratedCab_") then roots=roots+1 end
        end
        check(roots<=1,"换车遗留多个内舱")
        if not c.station then
            local root=assert(Cab.GetRoot())
            local body=assert(root:GetChild("GeneratedCabBody")):GetComponent("StaticModel")
            check(body and body.model.name==Cab.GetDiagnostics().modelPath,"主体不是正式 MDL")
            local bodyMaterial=assert(body:GetMaterial(0),"主体材质槽空")
            local texture=bodyMaterial:GetTexture(TU_DIFFUSE)
            check(texture and texture.name:find("ce4bf974",1,true),"主体没有真实本地贴图")
            print(string.format("[CabIntegration] MATERIAL technique=%s texture=%s",bodyMaterial:GetTechnique(0).name,texture.name))
            check(Cab.IsVisible() and roots==1,"舱内机位未显示实体")
            local bodySize=body.worldBoundingBox.size
            check(math.abs(bodySize.x-2.7)<.01 and math.abs(bodySize.y-2.3)<.01 and math.abs(bodySize.z-3.6)<.01,"内舱尺寸失配")
            check(#root:GetChildren()>5,"内舱子树缺失")
            local count=0
            local bases,pillars=0,0
            for _,node in ipairs(root:GetChildren()) do
                if node.name=="IndependentSeat" then
                    count=count+1
                    local seat=assert(node:GetComponent("StaticModel"))
                    check(seat.model.name=="CabDetails/FixedSeatUpper.mdl","仍是五爪办公椅原网格")
                    check(seat.model:GetNumGeometryLodLevels(0)==4,"固定座椅丢失四级LOD")
                    check(math.abs(node.scale.x-node.scale.y)<.00001 and math.abs(node.scale.x-node.scale.z)<.00001,
                        "座椅非统一缩放")
                    local facing=node.rotation*Vector3.RIGHT
                    check(facing.z>.99,"固定座椅未朝向前窗")
                elseif node.name=="固定座椅底盘" then bases=bases+1
                elseif node.name=="固定座椅支柱" then pillars=pillars+1 end
            end
            check(count==2 and bases==2 and pillars==2,"独立座椅/落地柱座未加载")
            local eye=assert(Camera.GetNode()).worldPosition
            local localEye=root:WorldToLocal(eye)
            check(math.abs(localEye.x)<1.2 and localEye.z>-2.3 and localEye.z<1.1,"眼点在舱外")
            -- 已在PostUpdate保持真实读数，检查组件后再拍摄，不提前恢复。
            local speed=assert(root:GetChild("速度数字",true)):GetComponent("Text3D")
            check(speed and speed.text=="123 km/h","生成台实时数字没有更新")
            local control=assert(root:GetChild("牵引制动数字",true)):GetComponent("Text3D")
            check(control and control.text=="牵引 7\n制动 65%","牵引制动实际组件未更新")
            local traction=assert(root:GetChild("牵引操纵杆"))
            check(math.abs(traction.rotation:PitchAngle())>1,"活动操纵杆未转动")
        else
            local house=assert(scene:GetChild("DetailedStationHouse",true),"新站房未装入实际世界")
            local model=assert(house:GetComponent("StaticModel"))
            check(model.viewMask==6 and model.model.numGeometries>0,"站房不参加真实环境渲染/净空")
            for _,p in ipairs(Station.GetPlacementData()) do check(p.clearance>=25,"新站房侵入铁路净空") end
        end
        local image=Image()
        if not graphics:TakeScreenShot(image) then image:Dispose();return end
        check(image:SavePNG("/workspace/screenshots/verified_"..c.name..".png"),"运行截图写入失败")
        image:Dispose()
        captured_[case_]=true
        print(string.format("[CabIntegration] REAL_CAPTURE %s batches=%d primitives=%d",c.name,renderer.numBatches,renderer.numPrimitives))
        if case_==#cases_ then
            Train.Derail("内舱重开回归")
            Hud.ShowGameOver("内舱重开回归")
            UI.Layout()
            local button=assert(assert(Hud.GetRoot()):FindById("restartJourney"))
            local r=button:GetAbsoluteLayoutForHitTest()
            check(r.w>0 and r.h>0,"重开按钮未入布局")
            local scale=UI.GetScale()
            UI.InputAdapter.HandleTouchBegin(886,(r.x+r.w*.5)*scale,(r.y+r.h*.5)*scale,.5)
            UI.InputAdapter.HandleTouchEnd(886,(r.x+r.w*.5)*scale,(r.y+r.h*.5)*scale)
            check(not Train.IsDerailed(),"真实重开按钮未清事故")
            check(Camera.SetMode("cab"),"重开不能回驾驶位")
            Camera.Update(.25,Train.GetS())
            check(Cab.IsVisible(),"重开内舱失效")
            print(string.format("ALL_CAB_INTEGRATION_PASS cases=%d checks=%d frames=%d",#cases_,checks_,frame_))
            engine:Exit()
        end
    end)
end
