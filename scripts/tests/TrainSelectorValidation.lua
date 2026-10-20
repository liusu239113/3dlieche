-- 选择器异步合同回归：真实UI组件，完成由done而非同步return true驱动。
local UI=require "urhox-libs/UI"
local Selector=require "ui.TrainSelector"
local Train=require "train.Train"
local CoachModels=require "config.CoachModels"
local checks_=0
local function check(value,message)
    checks_=checks_+1
    assert(value,"[TrainSelectorValidation] " .. message)
end
function Start()
    local ok,reason=xpcall(function()
        UI.Init({theme="default-dark",scale=UI.Scale.DEFAULT,
            fonts={{family="sans",weights={normal="Fonts/MiSans-Regular.ttf",bold="Fonts/MiSans-Regular.ttf"}}}})
        local selector=Selector{}
        UI.SetRoot(UI.Panel{width="100%",height="100%",children={selector}})
        local ready,opens,cancels,calls=true,0,0,0
        local completions={} ---@type fun(success:boolean,message?:string)[]
        selector:SetSelected("blue_white","沧羽 D12")
        selector:SetCallbacks{
            getCatalog=function()
                opens=opens+1
                return {
                    {id="blue_white",name="沧羽 D12",kind="locomotive",ready=true},
                    {id="DF4D",name="赤峦 D18",kind="locomotive",ready=ready},
                    {id="SS9G",name="SS9G",kind="locomotive",ready=true},
                }
            end,
            onSelect=function(id,done)
                calls=calls+1
                completions[#completions+1]=done
                return true,"请求已受理"
            end,
            onCancel=function(id) cancels=cancels+1 end,
        }
        selector:Open()
        check(opens==1 and selector:FindTrain("DF4D").ready,"打开未刷新实际目录")
        check(selector:FindTrain("SS9G").name~="SS9G","内部真实车型ID泄漏为展示名")
        selector:Choose("DF4D");selector:Confirm()
        check(selector:IsOpen() and selector:IsBusy(),"return true被假当完成")
        check(selector.selectedId_=="blue_white" and selector.pendingId_=="DF4D","待切覆盖实际车型")
        selector:SetSelected("blue_white","沧羽 D12")
        selector:SetLoading(1)
        check(selector:IsBusy() and selector:IsOpen(),"100%下载或旧车型轮询假装完成")
        selector:Confirm()
        check(calls==1,"等待中重复提交")
        selector:Close()
        check(cancels==1 and not selector:IsBusy(),"关闭未取消当前请求")
        selector:Open()
        completions[1](true,"迟到成功")
        check(selector:IsOpen() and selector.selectedId_=="blue_white","取消后迟到done仍改车型")
        selector:Choose("DF4D");selector:Confirm()
        completions[1](false,"旧请求失败")
        check(selector:IsBusy(),"旧请求完成污染新请求")
        completions[2](false,"模拟装配失败，原列车保留")
        check(selector:IsOpen() and not selector:IsBusy() and selector.selectedId_=="blue_white",
            "失败未保留实际车型/重试窗口")
        selector:Choose("DF4D");selector:Confirm()
        completions[3](true,"实际装配成功")
        check(not selector:IsOpen() and not selector:IsBusy() and selector.selectedId_=="DF4D",
            "实际done成功未完成选择")
        check(cancels==1,"正常成功错误触发取消")
        ready=false
        selector:Open()
        check(not selector:FindTrain("DF4D").ready,"重开仍显示旧ready")
        selector:Close()
        ready=true
        selector:SetSelected("blue_white","blue_white")
        check(selector.selectedName_~="blue_white","SetSelected泄漏内部ID")
        selector:SetCallbacks{
            getCatalog=function() error("模拟目录不可用") end,
            onSelect=function(id,done) return true end,
        }
        selector:Open()
        check(#selector.catalog_==0,"目录刷新失败仍显示过期可选卡片")
        selector:Close()
        selector:SetCatalog{{id="DF4D",name="赤峦 D18",kind="locomotive",ready=true}}
        selector:SetCallbacks{onSelect=function(id,done) done(true,"同步实际装配完成");return true end}
        selector:Open();selector:Choose("DF4D");selector:Confirm()
        check(not selector:IsOpen() and selector.selectedId_=="DF4D","立即done同步兼容失败")
        selector:SetSelected("blue_white","沧羽 D12")
        selector:SetCallbacks{
            onSelect=function(id,done) completions[#completions+1]=done;return true end,
            onCancel=function(id) cancels=cancels+1 end,
        }
        selector:Open();selector:Choose("DF4D");selector:Confirm()
        selector:Destroy()
        check(cancels==2,"销毁未取消待切请求")
        completions[#completions](true,"销毁后迟到")
        -- 最后留下真实目录用于截图：先实际读GetCatalog，再改变客车配置验证重开刷新。
        local live=Selector{}
        UI.SetRoot(UI.Panel{width="100%",height="100%",children={live}})
        live:SetBounds(16,0,graphics:GetWidth()/UI.GetScale()-32,graphics:GetHeight()/UI.GetScale())
        live:SetSelected(Train.GetSelectedId(),Train.GetSelectedName())
        live:SetCallbacks{getCatalog=Train.GetCatalog,onSelect=function(id,done) return true end}
        live:Open()
        check(live:FindTrain("DF4D").ready,"真实已交付目录未就绪")
        live:Close()
        local spec=assert(CoachModels.Find("DF4D"))
        local profile=spec.profileId
        spec.profileId=nil
        local refreshed,refreshError=pcall(function()
            live:Open()
            check(not live:FindTrain("DF4D").ready,"真实配置缺失后打开仍显示ready")
        end)
        spec.profileId=profile
        assert(refreshed,refreshError)
        live:Close();live:Open()
        check(live:FindTrain("DF4D").ready,"真实配置恢复后重开未重新就绪")
        live:Choose("DF4D");live:Confirm();live:SetLoading(.45,"正在准备赤峦 D18 45%；旧列车仍保留，可取消。")
        check(live:IsBusy() and live:IsOpen(),"真实目录等待状态丢失")
        print(string.format("TRAIN_SELECTOR_VALIDATION_PASS checks=%d asyncAcceptedNotCompleted=true staleDoneIgnored=true cancel=true refreshedCatalog=true",checks_))
    end,debug.traceback)
    if not ok then log:Write(LOG_ERROR,tostring(reason)) end
end
function Stop() UI.Shutdown() end
