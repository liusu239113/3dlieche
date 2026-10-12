-- 版本化自动存档，只含游戏进度与设置。云端写入需玩家在设置中明确开启。
local SaveStore={}
local PATH="railway_autosave_v1.json"
---@type table?
local latest_=nil
local status_="尚无存档"
local pending_,cloudEnabled_=false,false
local function valid(data)
    return type(data)=="table" and data.version==1 and type(data.settings)=="table"
end
function SaveStore.Load()
    if fileSystem:FileExists(PATH) then
        local file=File(PATH,FILE_READ)
        if file and file:IsOpen() then
            local text=file:ReadString();file:Dispose()
            local ok,data=pcall(cjson.decode,text)
            if ok and valid(data) then latest_=data;status_="已读取设备存档" end
        elseif file then file:Dispose() end
    end
    return latest_
end
function SaveStore.ReadCloud(callback)
    if not cloudEnabled_ or not clientCloud then callback(latest_);return end
    clientCloud:Get("railway_autosave_v1",{
        ok=function(values)
            local data=values.railway_autosave_v1
            if valid(data) and (not latest_ or (data.timestamp or 0)>(latest_.timestamp or 0)) then
                latest_=data;status_="已读取云存档"
            end
            callback(latest_)
        end,
        error=function() status_="云存档读取失败，使用设备存档";callback(latest_) end,
        timeout=function() status_="云存档读取超时，使用设备存档";callback(latest_) end,
    })
end
function SaveStore.SetCloud(enabled) cloudEnabled_=enabled==true end
---@param data table
---@param cloud? boolean
function SaveStore.Write(data,cloud)
    if not valid(data) then return false end
    data.timestamp=os.time()
    local ok,text=pcall(cjson.encode,data)
    if not ok then status_="存档编码失败";return false end
    local file=File(PATH,FILE_WRITE)
    if not file or not file:IsOpen() then
        if file then file:Dispose() end
        status_="设备存档写入失败";return false
    end
    local written=file:WriteString(text)
    file:Dispose()
    if not written then status_="设备存档写入失败";return false end
    latest_=data;status_="已自动保存至设备"
    if cloud and cloudEnabled_ and clientCloud and not pending_ then
        pending_=true
        clientCloud:Set("railway_autosave_v1",data,{
            ok=function() pending_=false;status_="设备与云存档已保存" end,
            error=function() pending_=false;status_="设备已保存，云端失败后稍后重试" end,
            timeout=function() pending_=false;status_="设备已保存，云端请求超时" end,
        })
    end
    return true
end
function SaveStore.Get() return latest_ end
function SaveStore.GetStatus() return status_ end
return SaveStore
