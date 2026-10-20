-- 最新选择意图拥有唯一请求；下载完成不允许反向覆盖后来的同步选择。
---@class TrainSelectionOptions
---@field resources fun(id:string):string[]
---@field download fun(paths:string[],done:fun(ok:boolean,message:string),progress:fun(ratio:number))
---@field cancelDownload fun()
---@field canSelect fun(id:string):boolean,string
---@field select fun(id:string,force:boolean):boolean,string
---@field isActive fun():boolean
---@field onSelected fun(id:string)
---@field onProgress fun(active:boolean,ratio:number,message:string)
---@field onMessage fun(message:string)
---@field name fun(id:string):string

---@class PendingTrainChoice
---@field id string
---@field generation number
---@field done fun(ok:boolean,message:string)|nil

---@class TrainSelection
---@field options TrainSelectionOptions
---@field generation number
---@field pending PendingTrainChoice|nil
---@field ratio number
local TrainSelection = {}
TrainSelection.__index = TrainSelection

---@param options TrainSelectionOptions
---@return TrainSelection
function TrainSelection.new(options)
    local self = setmetatable({},TrainSelection) ---@type TrainSelection
    self:init(options)
    return self
end

---@param options TrainSelectionOptions
function TrainSelection:init(options)
    self.options,self.generation,self.pending,self.ratio=options,0,nil,0
end

---@param message? string
function TrainSelection:Cancel(message)
    self.generation=self.generation+1
    local old=self.pending
    self.pending=nil
    self.ratio=0
    -- 先失效请求，避免取消接口同步回调重新完成旧选择。
    self.options.cancelDownload()
    self.options.onProgress(false,0,"")
    if old then
        print("[TrainSelection] 取消 "..old.id.."："..(message or "已取消切车"))
        if old.done then old.done(false,message or "已取消切车，原列车保留") end
    end
end

---@param id string
---@param done? fun(ok:boolean,message:string)
---@param force? boolean
---@return boolean,string
function TrainSelection:Request(id,done,force)
    self:Cancel("已改选其他车型，原请求取消")
    if not self.options.isActive() then
        local message="当前不在驾驶界面，不能切车"
        if done then done(false,message) end
        return false,message
    end
    local permitted,reason=self.options.canSelect(id)
    if not permitted then
        if done then done(false,reason) end
        return false,reason
    end
    local request={id=id,generation=self.generation,done=done} --[[@as PendingTrainChoice]]
    self.pending=request
    local completed,result,message=false,false,""
    self.options.onProgress(true,0,"正在准备"..self.options.name(id).."的车体、贴图与声音")
    self.options.download(self.options.resources(id),function(ok,downloadMessage)
        if self.pending~=request or request.generation~=self.generation then return end
        if not self.options.isActive() then self:Cancel("界面已切换，切车请求已取消");return end
        local allowed,validation=self.options.canSelect(id)
        if ok and not allowed then ok,downloadMessage=false,validation end
        if ok then
            local success,selectionMessage=self.options.select(id,force==true)
            ok,downloadMessage=success,selectionMessage
        end
        if self.pending~=request then return end
        self.pending=nil
        self.ratio=ok and 1 or self.ratio
        self.options.onProgress(false,self.ratio,"")
        if ok then self.options.onSelected(id) end
        completed,result,message=true,ok,downloadMessage
        print(string.format("[TrainSelection] %s %s：%s",id,ok and "装配完成" or "失败并保留旧编组",message))
        if request.done then request.done(ok,message)
        else self.options.onMessage(message) end
    end,function(ratio)
        if self.pending~=request or request.generation~=self.generation then return end
        self.ratio=math.max(0,math.min(1,ratio))
        self.options.onProgress(true,self.ratio,"正在准备"..self.options.name(id).."，完成后装配")
    end)
    if completed then return result,message end
    return true,"车型资源准备中，可取消；原列车保持不变"
end

function TrainSelection:GetStatus()
    return {active=self.pending~=nil,id=self.pending and self.pending.id or "",ratio=self.ratio,generation=self.generation}
end

return TrainSelection
