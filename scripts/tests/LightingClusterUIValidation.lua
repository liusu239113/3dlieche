-- 灯光对照按钮专项触摸验收；不创建世界、不读取或写入玩家存档。
local UI=require "urhox-libs/UI"
local Hud=require "ui.Hud"
local frame_,checks_,requests_,captures_=0,0,{},0
local failed_,completed_=false,false
local ids_={"lightingClusterA","lightingClusterB","captureLightingDiagnostics"}
local function check(value,message)
    checks_=checks_+1
    assert(value,"[LightingClusterUI] "..message)
end
local function guard(action)
    if failed_ then return end
    local ok,message=xpcall(action,debug.traceback)
    if not ok then failed_=true;log:Write(LOG_ERROR,tostring(message));engine:Exit() end
end
local function reveal(id)
    UI.Layout()
    local root=assert(Hud.GetRoot())
    local scroll=assert(root:FindById("operationsDetails")) --[[@as ScrollView]]
    local item=assert(root:FindById(id)):GetAbsoluteLayoutForHitTest()
    local bounds=scroll:GetAbsoluteLayoutForHitTest()
    local _,y=scroll:GetScroll()
    scroll:SetScroll(0,math.max(0,y+item.y-bounds.y-2))
    UI.Layout()
end
local function tap(id)
    local root=assert(Hud.GetRoot())
    local target=assert(root:FindById(id))
    local rect=target:GetAbsoluteLayoutForHitTest()
    print(string.format("[LightingClusterUI] target=%s rect=%.4f,%.4f %.4fx%.4f",id,rect.x,rect.y,rect.w,rect.h))
    check(rect.w>=43.99 and rect.h>=43.99,"触摸区域不足44px："..id) -- Yoga浮点布局容许0.01px舍入误差。
    local x,y=rect.x+rect.w*.5,rect.y+rect.h*.5
    check(UI.FindWidgetAt(x,y)==target,"按钮未处于可点击区域："..id)
    UI.InputAdapter.HandleTouchBegin(993,x*UI.GetScale(),y*UI.GetScale(),.5)
    UI.InputAdapter.HandleTouchEnd(993,x*UI.GetScale(),y*UI.GetScale())
end
function Start()
    guard(function()
        Hud.Init({
            onLightingCluster=function(selected)
                requests_[#requests_+1]=selected
                Hud.SetLightingDiagnosticsStatus(selected and "当前 A：集群光照 · 预热中" or "当前 B：非集群光照 · 预热完成")
            end,
            onLightingDiagnostics=function() captures_=captures_+1 end,
        })
        Hud.SetLightingDiagnosticsStatus("当前 B：非集群光照 · 预热完成")
        Hud.SetOperationsExpanded(true)
        SubscribeToEvent("Update","HandleUpdate")
    end)
end
function HandleUpdate()
    guard(function()
        frame_=frame_+1
        for index,id in ipairs(ids_) do
            local first=3+(index-1)*5
            if frame_==first then reveal(id) end
            if frame_==first+2 then tap(id) end
        end
        if frame_==21 then
            check(#requests_==2 and requests_[1]==true and requests_[2]==false,"A/B请求顺序错误")
            check(captures_==1,"取证按钮回调未触发")
            local root=assert(Hud.GetRoot())
            local status=assert(root:FindById("lightingDiagnosticsStatus")) --[[@as Label]]
            check(status:GetText():find("当前 B",1,true),"状态未同步")
            local captureButton=assert(root:FindById("captureLightingDiagnostics")) --[[@as Button]]
            check(tostring(captureButton.props.text):find("LD-20261020-B",1,true),"版本标记错误")
            completed_=true
            print(string.format("ALL_LIGHTING_CLUSTER_UI_PASS checks=%d requests=%d captures=%d",checks_,#requests_,captures_))
            engine:Exit()
        end
    end)
end
function Stop()
    if not failed_ and not completed_ then log:Write(LOG_ERROR,"[LightingClusterUI] 验收未完成") end
    Hud.Shutdown()
end
