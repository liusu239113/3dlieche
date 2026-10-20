-- 基于正式main验收脚手架：双模式站台行人、真实客流及轨道禁入检查。
-- 存档/云全部隔离；每帧只执行一次生产流式更新，不暴力清空队列。
local Save=require "game.SaveStore"
local oldLoad,oldWrite,oldCloud,oldSet=Save.Load,Save.Write,Save.ReadCloud,Save.SetCloud
Save.Load=function() return nil end
Save.Write=function() return true end
Save.ReadCloud=function(callback) callback(nil) end
Save.SetCloud=function() end
require "main"
local mainStart,mainUpdate,mainPost,mainStop=Start,HandleUpdate,HandlePostUpdate,Stop
local Passenger=require "game.PassengerService"
local Route=require "world.Route"
local Station=require "world.Station"
local Camera=require "train.Camera"
local Stream=require "world.WorldStream"
local Environment=require "world.Environment"
local UI=require "urhox-libs/UI"
local mode_="normal"
for _,arg in ipairs(GetArguments()) do mode_=arg:match("^%-passenger%-mode=(.+)$") or mode_ end
assert(mode_=="normal" or mode_=="rage","未知乘客验收模式")
---@type Viewport?
local viewport_=nil
local ready_,bound_,done_,stopped_,warmed_=false,false,false,false,false
local frames_,settled_,renderFrames_,shots_,checks_=0,0,0,0,0
local function check(value,message)
    checks_=checks_+1;assert(value,"[PassengerStation] "..message)
end
local function cleanup()
    if stopped_ then return end
    stopped_=true;pcall(mainStop)
    Save.Load,Save.Write,Save.ReadCloud,Save.SetCloud=oldLoad,oldWrite,oldCloud,oldSet
end
local function guard(action)
    if done_ then return end
    local ok,message=xpcall(action,debug.traceback)
    if not ok then
        done_=true;print("PASSENGER_STATION_FAILED "..tostring(message))
        log:Write(LOG_ERROR,tostring(message));cleanup();engine:Exit()
    end
end
local function stationReady()
    local root=Stream.GetStats().root
    local node=root and root:GetChild("station_1")
    return node and node.enabled
end
local function audit()
    local scene=assert(GetGameScene())
    local root=assert(scene:GetChild("PlatformPassengers"))
    local dimensions=Station.GetDimensions()
    local ambient,service=0,0
    for _,node in ipairs(root:GetChildren()) do
        if node:IsEnabled() then
            local id=assert(tonumber(node.name:match("Passenger_(-?%d+)")))
            local position=node.worldPosition
            local s=Route.ProjectApprox(position)
            local lateral=(position-Route.Sample(s)):DotProduct(Route.RightAt(s))
            if id<0 then
                ambient=ambient+1
                check(lateral>=dimensions.upPlatformMin+1.3 and lateral<=dimensions.upPlatformMax-1.3,
                    "背景旅客越过站台安全走廊："..lateral)
                check(math.abs(position.y-Route.Sample(s).y-dimensions.platformTopY-.045)<.025,
                    "背景旅客脚底高度错位")
            else service=service+1 end
            local model=assert(node:GetComponent("StaticModel",true))
            check(model:GetWorldBoundingBox().size.y<3,"人物模型尺寸异常")
        end
    end
    check(ambient>0,"正式场景没有背景行人")
    check(Passenger.GetVisualStats().allocated<=36,"人物池超过预算")
    if mode_=="normal" then
        check(Passenger.HasActiveStop() and Passenger.GetStatus().totalBoarding>0,"普通模式未生成真实候车队列")
        check(service>0,"普通模式候车乘客未入镜")
    else check(not Passenger.HasActiveStop(),"狂暴模式意外生成客运站停") end
    return ambient,service
end
function Start()
    guard(function()
        mainStart();SetRenderQuality("medium");BeginJourney(false,mode_)
        SubscribeToEvent("EndFrame","HandlePassengerStationCapture")
    end)
end
function HandleUpdate(eventType,eventData)
    guard(function()
        frames_=frames_+1
        local step=VariantMap();step["TimeStep"]=Variant(.02)
        if not ready_ then
            mainUpdate(eventType,step --[[@as UpdateEventData]])
            check(GetApplicationState()~="error","正式场景加载失败")
            if GetApplicationState()=="playing" then
                viewport_=assert(renderer:GetViewport(0));ready_=true
                TogglePause();UI.SetRoot(nil);Camera.SetMode("track_front")
                Environment.Configure({hour=12,running=false,weather="clear"})
                renderer:SetNumViewports(0)
            end
        elseif not bound_ then
            settled_=stationReady() and settled_+1 or 0
            if settled_>=5 then
                renderer:SetNumViewports(1);renderer:SetViewport(0,assert(viewport_));bound_=true
            end
        end
        check(frames_<3600,"正式站台未在有界帧内就绪")
    end)
end
function HandlePostUpdate(eventType,eventData)
    guard(function()
        mainPost(eventType,eventData)
        if not ready_ then return end
        local station=assert(Route.GetStations()[1])
        local eye=assert(Camera.GetNode())
        -- 第一张对应用户的沿轨高视角，第二张从安全走廊查看实际脚底位置。
        local near=shots_>0
        eye.worldPosition=Route.SampleOffset(station.s+(near and -140 or 18),near and 9.5 or 3.8,near and 2.7 or 6.4)
        eye:LookAt(Route.SampleOffset(station.s+(near and -118 or -140),near and 8.7 or 6.0,near and 2.15 or 2.0))
        Environment.Update(0,eye.worldPosition)
    end)
end
function HandlePassengerStationCapture()
    guard(function()
        if not bound_ then return end
        renderFrames_=renderFrames_+1
        if renderFrames_<16 then return end
        local ambient,service=audit()
        local image=Image()
        if not graphics:TakeScreenShot(image) then
            image:Dispose();check(renderFrames_<48,"真实帧读回失败");return
        end
        if not warmed_ then warmed_=true;image:Dispose();return end
        local name="/workspace/screenshots/passenger_platform_"..mode_..(shots_==0 and "_overview.png" or "_aisle.png")
        check(image:SavePNG(name),"截图保存失败")
        local width,height=image.width,image.height;image:Dispose()
        local decoded=Image();check(decoded:Load(name),"PNG回读失败")
        check(decoded.width==width and decoded.height==height and width>0,"PNG尺寸不符")
        local low,high=1.0,0.0
        for y=1,8 do for x=1,12 do
            local pixel=decoded:GetPixel(math.floor(width*x/13),math.floor(height*y/9))
            local value=(pixel.r+pixel.g+pixel.b)/3;low,high=math.min(low,value),math.max(high,value)
        end end
        decoded:Dispose();check(high-low>.06,"不接受空白帧")
        print(string.format("PASSENGER_STATION_CAPTURE mode=%s ambient=%d service=%d file=%s",mode_,ambient,service,name))
        shots_=shots_+1;renderFrames_,warmed_=0,false
        if shots_==2 then
            print(string.format("ALL_PASSENGER_STATION_PASS mode=%s captures=2 checks=%d noSaveIO=true noCloudIO=true",mode_,checks_))
            done_=true;cleanup();engine:Exit()
        end
    end)
end
function Stop() cleanup() end
