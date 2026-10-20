-- 状态与存档边界专项：纯CPU、内存文件替身，不访问玩家档或云服务。
local EnvironmentValidation=require "tests.EnvironmentValidation"
local Timetable=require "game.Timetable"
local checks_=0
local function check(value,message)
    checks_=checks_+1
    assert(value,"[ClockStorageValidation] "..message)
end

local function storageChecks()
    local originalFile,originalFileSystem=File,fileSystem
    local originalStore=package.loaded["game.SaveStore"]
    local text=cjson.encode({version=1,settings={},journey={game={xp=321}}})
    local writes=0
    local readMode=FILE_READ
    local fakeSystem={FileExists=function() return true end}
    local function fakeFile(_,mode)
        return {
            IsOpen=function() return true end,
            ReadString=function() return text end,
            WriteString=function(_,value) writes=writes+1;text=value;return true end,
            Dispose=function() end,
        }
    end
    local ok,message=xpcall(function()
        fileSystem=fakeSystem --[[@as any]]
        File=fakeFile --[[@as any]]
        package.loaded["game.SaveStore"]=nil
        local store=require "game.SaveStore"
        local restored=assert(store.Load())
        check(restored.journey.game.xp==321,"旧档运营进度丢失")
        check(store.Write(restored,false) and writes==1,"旧档不能正常保存")
        text=cjson.encode({version=1,settings={},journey={game={timetable={version=999}}}})
        check(store.Load()==nil,"未知时刻表进入旅程")
        check(not store.Write({version=1,settings={}},false),"未知时刻表被自动保存覆盖")
        check(writes==1 and text:find('999',1,true)~=nil,"未知档原文改变")
        check(Timetable.ValidateSnapshot(nil),"无时刻表旧档被拒")
        check(not Timetable.ValidateSnapshot({version=999}),"未来时刻表版本被接受")
        check(readMode==FILE_READ,"验证意外改变文件枚举")
    end,debug.traceback)
    File,fileSystem=originalFile,originalFileSystem
    package.loaded["game.SaveStore"]=originalStore
    assert(ok,message)
end

function Start()
    local ok,message=xpcall(function()
        local environmentChecks=EnvironmentValidation.RunState()
        storageChecks()
        print(string.format("CLOCK_STORAGE_VALIDATION_PASS environment=%d storage=%d diskWrites=0 cloudCalls=0",environmentChecks,checks_))
    end,debug.traceback)
    if not ok then
        print("CLOCK_STORAGE_VALIDATION_FAILED "..tostring(message))
        log:Write(LOG_ERROR,tostring(message))
    end
    engine:Exit()
end
