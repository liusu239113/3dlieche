-- 基于 PassengerStationValidation：正式 main 场景的车站结构对照与双向汽车实拍。
-- 内存存档，不调用云；每帧仅一次生产 PostUpdate，不手工 drain 世界任务。
local Save=require "game.SaveStore"
local original_={Load=Save.Load,Get=Save.Get,Write=Save.Write,ReadCloud=Save.ReadCloud,SetCloud=Save.SetCloud}
local fixture_={version=1,settings={quality="medium",sound=false,music=false,cloud=false,
    environment={hour=12,running=false,weather="clear"}},journeys={}}
Save.Load=function() return fixture_ end
Save.Get=function() return fixture_ end
Save.Write=function(value) fixture_=value;return true end
Save.ReadCloud=function(callback) callback(nil) end
Save.SetCloud=function() end
require "main"
local mainStart,mainUpdate,mainPost,mainStop=Start,HandleUpdate,HandlePostUpdate,Stop
local Route=require "world.Route"
local Train=require "train.Train"
local Stream=require "world.WorldStream"
local Road=require "world.RoadCorridor"
local Camera=require "train.Camera"
local Environment=require "world.Environment"
local UI=require "urhox-libs/UI"
local stationIndex_,road_=3,false
for _,arg in ipairs(GetArguments()) do
    stationIndex_=tonumber(arg:match("^%-scene%-station=(%d+)$")) or stationIndex_
    if arg=="-scene-road" then road_=true end
end
local frames_,settled_,checks_,shots_=0,0,0,0
local ready_,bound_,warmed_,done_,stopped_=false,false,false,false,false
local clock_,renderFrames_=0,0
local baseline_={} ---@type table<string,{position:Vector3,direction:number}>
---@type Viewport?
local viewport_=nil
local function check(value,message) checks_=checks_+1;assert(value,"[WorldSceneVisual] "..message) end
local function cleanup()
    if stopped_ then return end
    stopped_=true;pcall(mainStop)
    Save.Load,Save.Get,Save.Write=original_.Load,original_.Get,original_.Write
    Save.ReadCloud,Save.SetCloud=original_.ReadCloud,original_.SetCloud
end
local function guard(action)
    if done_ then return end
    local ok,message=xpcall(action,debug.traceback)
    if not ok then
        done_=true;print("WORLD_SCENE_VISUAL_FAILED "..tostring(message))
        log:Write(LOG_ERROR,tostring(message));cleanup();engine:Exit()
    end
end
local function target()
    if road_ then return 4200 end
    local stations=Route.GetStations() --[[@as RailwayStation[] ]]
    return assert(stations[stationIndex_]).s
end
function Start()
    guard(function()
        mainStart();BeginJourney(false,"normal")
        SubscribeToEvent("EndFrame","HandleWorldSceneCapture")
    end)
end
function HandleUpdate(eventType,eventData)
    guard(function()
        frames_=frames_+1
        local step=VariantMap();step["TimeStep"]=Variant(.05)
        if not ready_ then
            mainUpdate(eventType,step --[[@as UpdateEventData]])
            check(GetApplicationState()~="error","正式场景加载失败")
            if GetApplicationState()=="loading" then
                viewport_=viewport_ or renderer:GetViewport(0)
                renderer:SetNumViewports(0)
            elseif GetApplicationState()=="playing" then
                viewport_=renderer:GetViewport(0) or viewport_
                assert(viewport_,"初载视口未保活");ready_=true
                TogglePause();UI.SetRoot(nil)
                local snapshot=Train.ExportState()
                snapshot.s,snapshot.v,snapshot.derailed,snapshot.topology=target(),0,false,nil
                Train.RestoreState(snapshot)
                renderer:SetNumViewports(0)
                Environment.Configure({hour=12,running=false,weather="clear"})
            end
        elseif not bound_ then
            local complete=road_ and Road.GetTrafficStats().positive>0 and Road.GetTrafficStats().negative>0
                or not road_ and Stream.IsStationReady(stationIndex_)
            settled_=complete and settled_+1 or 0
            if settled_>=16 then
                renderer:SetNumViewports(1);renderer:SetViewport(0,assert(viewport_));bound_=true
                if road_ then TogglePause();UI.SetRoot(nil) end
            end
        elseif road_ and shots_>0 then
            -- 让正式 main 的非暂停 Update/PostUpdate 驱动车流，不能测试里另推一次。
            mainUpdate(eventType,step --[[@as UpdateEventData]])
            clock_=clock_+GetFrameSimulationStats().simulated
        end
        check(frames_<5000,"对照场景未在有界帧就绪")
    end)
end
function HandlePostUpdate(eventType,eventData)
    guard(function()
        local step=VariantMap();step["TimeStep"]=Variant(.05)
        mainPost(eventType,step --[[@as PostUpdateEventData]])
        if not ready_ then return end
        local eye=assert(Camera.GetNode())
        local s=target()
        if road_ then
            eye.worldPosition=Route.SampleOffset(s-75,71,16)
            eye:LookAt(Route.SampleOffset(s+80,92,1))
        else
            eye.worldPosition=Route.SampleOffset(s+120,46,31)
            eye:LookAt(Route.SampleOffset(s-85,-7,3.5))
        end
        Environment.Update(0,eye.worldPosition)
    end)
end
function HandleWorldSceneCapture()
    guard(function()
        if not bound_ then return end
        renderFrames_=renderFrames_+1
        if renderFrames_<16 or shots_>0 and clock_<5 then return end
        local image=Image();check(graphics:TakeScreenShot(image),"真实像素读回失败")
        if not warmed_ then warmed_=true;image:Dispose();return end
        local label=road_ and (shots_==0 and "road_before" or "road_after") or "station_"..stationIndex_
        local path="/workspace/screenshots/world_scene_"..label..".png"
        check(image:SavePNG(path),"图片保存失败");image:Dispose()
        local decoded=Image();check(decoded:Load(path),"图片回读失败")
        local low,high=1.0,0.0
        for y=1,8 do for x=1,12 do
            local pixel=decoded:GetPixel(math.floor(decoded.width*x/13),math.floor(decoded.height*y/9))
            local value=(pixel.r+pixel.g+pixel.b)/3;low,high=math.min(low,value),math.max(high,value)
        end end
        decoded:Dispose();check(high-low>.06,"不接受空白图")
        if road_ then
            local positive,negative=0,0
            for _,vehicle in ipairs(Road.GetTrafficVehicles()) do
                local key=tostring(vehicle.id)
                if shots_==0 then baseline_[key]={position=vehicle.node.worldPosition,direction=vehicle.direction}
                else
                    local previous=baseline_[key]
                    if previous then
                        local distance=(vehicle.node.worldPosition-previous.position):Length()
                        check(distance>20,"公路车辆实际Node未持续移动")
                        if previous.direction>0 then positive=positive+1 else negative=negative+1 end
                    end
                end
            end
            if shots_>0 then check(positive>0 and negative>0,"未验证两个方向的实际移动") end
            print(string.format("WORLD_ROAD_CAPTURE positiveMoved=%d negativeMoved=%d seconds=%.2f file=%s",positive,negative,clock_,path))
        else print("WORLD_STATION_CAPTURE index="..stationIndex_.." file="..path) end
        shots_=shots_+1;renderFrames_,warmed_=0,false
        if not road_ or shots_==2 then
            print("ALL_WORLD_SCENE_VISUAL_PASS checks="..checks_.." noPlayerSaveIO=true noCloudIO=true")
            done_=true;cleanup();engine:Exit()
        end
    end)
end
function Stop() cleanup() end
