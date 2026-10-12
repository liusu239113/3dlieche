-- 生成音效读取器：只在本地资源就绪后解码温和 PCM，不回退旧合成声。
local AudioCache = {}
---@class AudioBakedEntry
---@field dataSize integer
---@field stats ProceduralSoundStats
---@type table<string, AudioBakedEntry>
local entries_ = {}
local attempted_, loaded_ = false, false
local count_, seconds_, maximum_ = 0, 0.0, 0.0
---@type table<string, string>
local errors_ = {}
---@type table<string, fun(ready:boolean)[]>
local pending_ = {}
local METADATA = "audio/sfx/comfort/metadata.json"
local function metadata()
    if loaded_ then return end
    attempted_ = true
    if not cache:Exists(METADATA) then errors_.metadata="生成音效统计尚未就绪"; return end
    local file = cache:GetFile(METADATA) --[[@as File?]]
    if not file then errors_.metadata="生成音效统计文件缺失"; return end
    file:Seek(0)
    local text = file:ReadLine()
    file:Dispose()
    local ok, data = pcall(cjson.decode,text)
    if not ok or type(data)~="table" or type(data.entries)~="table" then
        errors_.metadata="生成音效统计格式错误"; return
    end
    entries_,loaded_ = data.entries,true
    errors_.metadata=nil
end

-- GetFile 不触发媒体 DWP。未下载不是永久损坏，不读文件、不产生资源缺失日志。
---@param path string
---@return ProceduralSound?
function AudioCache.Load(path)
    if not cache:Exists(path) then return nil end
    metadata()
    local entry = entries_[path]
    if not loaded_ or not entry then errors_[path]="缺少生成音效统计"; return nil end
    local file = cache:GetFile(path) --[[@as File?]]
    if not file then errors_[path]="下载完成后音效仍不可读"; return nil end
    local started = os.clock()
    file:Seek(0)
    local buffer = file:Read(file:GetSize())
    file:Dispose()
    buffer:Seek(0)
    local reader = tolua.cast(buffer,"Deserializer") --[[@as Deserializer]]
    local sound = Sound()
    if not sound:LoadWav(reader) or sound:GetDataSize()~=entry.dataSize then
        sound:Dispose(); errors_[path]="音效格式或数据长度错误"; return nil
    end
    sound:SetLooped(entry.stats.looped)
    if entry.stats.looped then sound:FixInterpolation() end
    local took = os.clock()-started
    count_,seconds_,maximum_ = count_+1,seconds_+took,math.max(maximum_,took)
    errors_[path]=nil
    print(string.format("[AudioCache] %s %.2fs RMS%.4f peak%.3f",path,entry.stats.duration,entry.stats.rms,entry.stats.peak))
    return {sound=sound,stats=entry.stats,wav=buffer,baked=true,resourcePath=path,loadSeconds=took}
end

-- 合并同资源请求；失败回调后清除 pending，允许用户重试，禁止忙等下载状态。
---@param path string
---@param callback fun(ready:boolean)
function AudioCache.Request(path,callback)
    if cache:Exists(path) and cache:Exists(METADATA) then callback(true); return end
    local callbacks=pending_[path]
    if callbacks then callbacks[#callbacks+1]=callback; return end
    pending_[path]={callback}
    cache:DownloadResources({METADATA,path},function(success,failedCount)
        local waiting=pending_[path] or {}
        pending_[path]=nil
        local ready=success and cache:Exists(path) and cache:Exists(METADATA)
        if ready then errors_[path]=nil else errors_[path]="音效下载失败，可重试" end
        if not ready then print("[AudioCache] 下载未完成："..path.." / "..failedCount) end
        for _,done in ipairs(waiting) do done(ready) end
    end)
end
function AudioCache.GetDiagnostics()
    local pendingCount=0
    for _ in pairs(pending_) do pendingCount=pendingCount+1 end
    return {metadataLoaded=loaded_,metadataAttempted=attempted_,metadataPath=METADATA,version=3,
        loadCount=count_,loadSeconds=seconds_,maxLoadSeconds=maximum_,errors=errors_,pendingCount=pendingCount}
end
function AudioCache.ResetDiagnostics() errors_={}; count_,seconds_,maximum_=0,0,0 end
return AudioCache
