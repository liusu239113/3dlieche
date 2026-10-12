-- 世界拖动只认空白处起始的一个指针；UI控件和第二根手指不抢镜头。
local UI=require "urhox-libs/UI"
local Camera=require "train.Camera"
local ViewDrag={}
---@type number?
local pointer_=nil
local x_,y_,sensitivity_=0,0,.20
local accepted_,moved_,rejected_=0,0,""
local listeners_={} ---@type {kind:string,id:number}[]
---@type fun():boolean
local allowed_=function() return false end
function ViewDrag.Reset() pointer_=nil end
function ViewDrag.SetSensitivity(value) sensitivity_=math.max(.05,math.min(.6,value)) end
function ViewDrag.Init(allowed)
    ViewDrag.Shutdown()
    allowed_=allowed
    local function on(kind,handler)
        listeners_[#listeners_+1]={kind=kind,id=UI.Input.On(kind,handler)}
    end
    on("PointerDown",function(event)
        if pointer_ then rejected_="已有活动指针";return end
        if not allowed_() then rejected_="当前页面禁止世界拖动";return end
        if not event:IsPrimaryAction() then rejected_="不是主要操作";return end
        local scale=math.max(.01,UI.GetScale())
        if UI.FindWidgetAt(event.x/scale,event.y/scale) then rejected_="指针起始于界面控件";return end
        pointer_,x_,y_=event.pointerId,event.x,event.y
        accepted_,rejected_=accepted_+1,""
    end)
    on("PointerMove",function(event)
        if pointer_~=event.pointerId then return end
        if not allowed_() then rejected_="拖动期间页面变化";ViewDrag.Reset();return end
        local scale=math.max(.01,graphics:GetDPR())
        Camera.AddYaw((event.x-x_)/scale*sensitivity_)
        Camera.AddPitch((event.y-y_)/scale*sensitivity_)
        moved_=moved_+1
        x_,y_=event.x,event.y
    end)
    local function release(event) if pointer_==event.pointerId then ViewDrag.Reset() end end
    on("PointerUp",release);on("PointerCancel",release)
end
function ViewDrag.Shutdown()
    for _,entry in ipairs(listeners_) do UI.Input.Off(entry.kind,entry.id) end
    listeners_={};ViewDrag.Reset()
end
function ViewDrag.GetStatus()
    return {active=pointer_~=nil,sensitivity=sensitivity_,accepted=accepted_,moved=moved_,rejected=rejected_}
end
return ViewDrag
