-- 真实选择协调器＋运营事件观察器回归；下载使用可控回调，不伪造车型模型验收。
local Selection=require "core.TrainSelection"
local Feedback=require "core.ExperienceFeedback"
local checks_=0
local function check(value,message) checks_=checks_+1;assert(value,"[ExperienceFlow] "..message) end

local function selectionCases()
    local requests,selected,messages,progress={},{},{},{}
    local active,allowed=true,true
    local chooser=Selection.new({
        resources=function(id) return {id..".mdl"} end,
        download=function(paths,done,onProgress)
            local id=paths[1]:sub(1,-5)
            if id=="cached" then onProgress(1);done(true,"已缓存")
            else requests[id]={done=done,progress=onProgress} end
        end,
        cancelDownload=function() end,
        canSelect=function() return allowed,allowed and "" or "列车已移动" end,
        select=function(id,force)
            if id=="broken" then return false,"模型验证失败" end
            selected[#selected+1]={id=id,force=force};return true,"已切换"..id
        end,
        isActive=function() return active end,
        onSelected=function() end,
        onProgress=function(busy,ratio,text) progress[#progress+1]={busy,ratio,text} end,
        onMessage=function(message) messages[#messages+1]=message end,
        name=function(id) return id end,
    })
    local doneA,doneB=0,0
    check(chooser:Request("A",function(ok) doneA=doneA+1;check(not ok,"旧A不应完成") end),"A未受理")
    check(chooser:GetStatus().active,"异步下载未保留pending")
    requests.A.progress(.4)
    check(chooser:GetStatus().ratio==.4,"进度未更新")
    check(chooser:Request("cached",function(ok) doneB=doneB+1;check(ok,"B同步缓存失败") end),"B未选择")
    check(doneA==1 and doneB==1,"取消/完成回调次数错误")
    requests.A.done(true,"")
    check(#selected==1 and selected[1].id=="cached","晚到A覆盖缓存B")
    local cancelled=0
    chooser:Request("C",function(ok) cancelled=cancelled+1;check(not ok,"C取消应失败") end)
    chooser:Cancel()
    requests.C.done(true,"")
    check(cancelled==1 and #selected==1 and not chooser:GetStatus().active,"取消后仍切车")
    chooser:Request("D")
    allowed=false
    requests.D.done(true,"")
    check(#selected==1 and #messages==1,"下载中移动后仍装配")
    allowed=true
    chooser:Request("E")
    active=false
    requests.E.done(true,"")
    check(#selected==1 and not chooser:GetStatus().active,"离开界面后仍装配")
    active=true
    chooser:Request("broken")
    requests.broken.done(true,"")
    check(#selected==1,"模型验证失败却替换旧车")
    check(chooser:Request("cached",nil,true),"同ID强制重建失败")
    check(selected[2].force,"同ID重建标记未透传")
    local oldCount=#progress
    requests.A.progress(.9)
    check(#progress==oldCount,"旧进度污染最新选择")
end

local function feedbackCases()
    local events={}
    local clears=0
    local observer=Feedback.new(function(kind,index,dir) events[#events+1]={kind,index,dir} end,
        function() clears=clears+1 end)
    local function snapshot(patch)
        local value={state="dwelling",nextIndex=1,lastArrival=1,initialService=true,service="local",journeyId="trip",
            visits=1,reversing=false,s=100,phase="boarding",terminal=false,dwelling=true}
        for k,v in pairs(patch or {}) do value[k]=v end
        return value
    end
    observer:Reset(snapshot(),true)
    check(#events==1 and events[1][1]=="welcome","始发欢迎错误")
    for _=1,4 do observer:Update(snapshot(),{blocked=true,reason="boarding",waitSeconds=40},100) end
    check(#events==1,"上客重复广播或误报信号")
    observer:Update(snapshot({phase="door_closing"}),{blocked=true,reason="boarding",waitSeconds=40},100)
    observer:Update(snapshot({phase="door_closing"}),{blocked=true,reason="boarding",waitSeconds=40},100)
    check(#events==2 and events[2][1]=="departure_reminder","关门提醒未去重")
    local driving=snapshot({state="driving",nextIndex=2,initialService=false,dwelling=false,phase="idle"})
    observer:Update(driving,{blocked=false},5000)
    check(events[#events][1]=="departure" and events[#events][2]==2,"发车下一站索引错误")
    driving.s=4000
    observer:Update(driving,{blocked=false},5000)
    observer:Update(driving,{blocked=false},5000)
    check(events[#events][1]=="approach" and #events==4,"进站距离/去重错误")
    local arrival=snapshot({lastArrival=2,nextIndex=2,initialService=false,visits=2,s=5000})
    observer:Update(arrival,{blocked=true,reason="occupied_ahead",waitSeconds=20},5000)
    check(events[#events-1][1]=="arrival" and events[#events][1]=="wait_signal","到站/信号说明未触发")
    observer:Update(arrival,{blocked=true,reason="occupied_ahead",waitSeconds=50},5000)
    check(#events==6,"同站等待重复广播")
    local terminal=snapshot({lastArrival=5,nextIndex=nil,initialService=false,visits=3,s=10000,terminal=true})
    observer:Update(terminal,{blocked=true,reason="terminal",waitSeconds=50},nil)
    check(events[#events][1]=="terminal","终到缺失")
    local count=#events
    observer:Update(snapshot({reversing=true,service="express"}),{blocked=false},100)
    check(#events==count and clears==2,"换向/换运营未清队列或乱报站")
    observer:Reset(driving,false)
    check(#events==count,"读档重置错误补播旧发车")
    local terminalDoors=snapshot({lastArrival=5,nextIndex=5,initialService=false,visits=4,
        phase="door_closing",terminalStop=true})
    observer:Reset(terminalDoors,false)
    observer:Update(terminalDoors,{blocked=true,reason="passengers",waitSeconds=30},nil)
    check(#events==count,"终到清客关门错误播报即将发车")
    local returning=snapshot({lastArrival=5,nextIndex=5,initialService=true,visits=4,
        journeyId="return",reversing=true,terminalStop=false})
    observer:Update(returning,{blocked=true,reason="passengers",waitSeconds=0},nil)
    check(#events==count+1 and events[#events][1]=="welcome" and events[#events][3]==-1,
        "折返旅程未新增visits时漏播欢迎")
    observer:Update(returning,{blocked=true,reason="passengers",waitSeconds=1},nil)
    check(#events==count+1,"折返欢迎重复")
    observer:Reset(returning,false)
    observer:Update(returning,{blocked=true,reason="passengers",waitSeconds=1},nil)
    check(#events==count+1,"读档折返错误补播欢迎")
    observer:Reset(returning,false)
    observer:Update(returning,{blocked=true,reason="passing_dispatch",waitSeconds=16},nil)
    check(events[#events][1]=="wait_signal" and #events==count+2,"待避出库等待缺少信号说明")
end

function Start()
    local ok,message=xpcall(function()
        selectionCases();feedbackCases()
        print("ALL_EXPERIENCE_FLOW_VALIDATION_PASS checks="..checks_)
    end,debug.traceback)
    if not ok then log:Write(LOG_ERROR,tostring(message)) end
    engine:Exit()
end
