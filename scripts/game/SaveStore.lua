-- 版本化自动存档，只含游戏进度与设置。云端写入需玩家在设置中明确开启。
local SaveStore={}
local Timetable=require "game.Timetable"
local PATH="railway_autosave_v1.json"
---@type table?
local latest_=nil
local status_="尚无存档"
local pending_,cloudEnabled_=false,false
local writeProtected_,cloudProtected_=false,false
local function validJourney(journey,mode)
    if type(journey)~="table" then return false end
    local id=journey.mode or "normal"
    if id~="normal" and id~="rage" then return false end
    if mode and mode~=id then return false end
    if journey.routeId~=nil and (type(journey.routeId)~="string" or #journey.routeId>100) then return false end
    local game=journey.game
    if game~=nil and type(game)~="table" then return false end
    if game and (not Timetable.ValidateSnapshot(game.timetable)
        or (game.mode~=nil and game.mode~=id)) then return false end
    return true
end
local function valid(data)
    if type(data)~="table" or data.version~=1 or type(data.settings)~="table" then return false end
    if data.journey~=nil and not validJourney(data.journey) then return false end
    if data.journeys~=nil then
        if type(data.journeys)~="table" then return false end
        for mode,journey in pairs(data.journeys) do
            if (mode~="normal" and mode~="rage") or not validJourney(journey,mode) then return false end
        end
    end
    return true
end
function SaveStore.Load()
    if fileSystem:FileExists(PATH) then
        local file=File(PATH,FILE_READ)
        if file and file:IsOpen() then
            local text=file:ReadString();file:Dispose()
            local ok,data=pcall(cjson.decode,text)
            if ok and valid(data) then
                latest_=data;status_="已读取设备存档"
            else
                -- 未知未来格式/损坏档不进入旅程，也不得被菜单自动保存覆盖。
                latest_=nil
                writeProtected_=true
                status_="设备存档无法兼容，已保留原文件并禁止覆盖"
            end
        elseif file then file:Dispose() end
    end
    return latest_
end
function SaveStore.ReadCloud(callback)
    if not cloudEnabled_ or not clientCloud then callback(latest_);return end
    clientCloud:Get("railway_autosave_v1",{
        ok=function(values)
            local data=values.railway_autosave_v1
            if not valid(data) then
                if data~=nil then
                    cloudProtected_=true
                    status_="云存档无法兼容，已禁止覆盖云端，继续使用设备进度"
                end
            elseif not latest_ or (data.timestamp or 0)>(latest_.timestamp or 0) then
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
    if writeProtected_ then return false end
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
    if cloud and cloudEnabled_ and not cloudProtected_ and clientCloud and not pending_ then
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
