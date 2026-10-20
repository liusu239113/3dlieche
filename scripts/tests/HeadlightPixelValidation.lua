-- 真实动车灯像素验收：沿用NightLightingValidation的独立场景/EndRendering对照结构。
-- 正式Train.Build/Select("CRH380A")、正式Track/World材质、正式Camera.track_front与22点Environment。
-- 不加载main/全世界，不造替代灯、不动挂点/强度/材质/曝光；首个读回帧丢弃。
local Modes=require "config.GameModes"
local Route=require "world.Route"
local Track=require "world.Track"
local World=require "world.WorldMaterials"
local Train=require "train.Train"
local Camera=require "train.Camera"
local Environment=require "world.Environment"
local Night=require "world.NightLighting"
---@type Scene?
local scene_=nil
---@type Zone?
local zone_=nil
---@type Image?
local offImage_=nil
local checks_,rendered_,phase_=0,0,1
local phaseFrames_,attempts_,readbacks_=0,0,0
local WARMUP_FRAMES,MAX_READBACK_ATTEMPTS=8,24
local discarded_,done_,cleaned_=false,false,false
local baseline_={eye=Vector3.ZERO,direction=Vector3.FORWARD,s=0.0,ambient=Color(0,0,0),sun=0.0,nodes=0}
local output_="/workspace/screenshots/"
local model_,cameraMode_,mode_,hour_,position_="CRH380A","track_front","normal",22,0.0
local tag_="CRH380A"
local pitchDelta_=0.0
for _,arg in ipairs(GetArguments()) do
    local model=arg:match("^%-headlight%-model=(.+)$")
    local camera=arg:match("^%-headlight%-camera=(.+)$")
    local mode=arg:match("^%-headlight%-mode=(.+)$")
    local hour=arg:match("^%-headlight%-hour=(.+)$")
    local position=arg:match("^%-headlight%-s=(.+)$")
    local pitch=arg:match("^%-headlight%-pitch%-delta=(.+)$")
    if pitch then pitchDelta_=assert(tonumber(pitch)) end
    if model then model_=model end
    if camera then cameraMode_=camera end
    if mode then mode_=mode end
    if hour then hour_=assert(tonumber(hour)) end
    if position then position_=assert(tonumber(position)) end
end
if model_~="CRH380A" or cameraMode_~="track_front" or hour_~=22 or mode_~="normal" then
    tag_=model_.."_"..mode_.."_"..cameraMode_.."_"..math.floor(hour_*60)
end
local function check(value,message) checks_=checks_+1;assert(value,"[HeadlightPixel] "..message) end
local function cleanup()
    if cleaned_ then return end
    cleaned_=true
    if offImage_ then offImage_:Dispose();offImage_=nil end
    Environment.Destroy();Night.Shutdown();Camera.Shutdown();Train.Shutdown()
    if scene_ then scene_:Dispose();scene_=nil end
end
local function guard(action)
    if done_ then return end
    local ok,message=xpcall(action,debug.traceback)
    if not ok then
        done_=true;print("HEADLIGHT_PIXEL_FAILED "..tostring(message));log:Write(LOG_ERROR,tostring(message))
        cleanup();engine:Exit()
    end
end
local function sampleDelta(image,prior)
    local total,lit,white,maxDelta=0,0,0,0
    -- 采样带随真实机位：track_front 前方轨面在下半屏；roof 俯视的前方轨面在上半屏。
    local firstRow = (cameraMode_=="roof" or cameraMode_=="front_chase") and 0
        or math.floor(image.height*.30)
    local lastRow = (cameraMode_=="roof") and math.floor(image.height*.55) or image.height-1
    for y=firstRow,lastRow,2 do
        for x=0,image.width-1,2 do
            local a,b=image:GetPixel(x,y),prior:GetPixel(x,y)
            local la,lb=(a.r+a.g+a.b)/3,(b.r+b.g+b.b)/3
            total=total+1
            if la>lb+.015 then lit=lit+1 end
            if la>.96 then white=white+1 end
            maxDelta=math.max(maxDelta,la-lb)
        end
    end
    return lit/total,white/total,maxDelta
end
function Start()
    guard(function()
        Modes.Apply(mode_);Route.Build();Track.Init()
        scene_=Scene();scene_:CreateComponent("Octree")
        renderer.hdrRendering=true;renderer.drawShadows=false
        renderer.materialQuality=QUALITY_MEDIUM;renderer.specularLighting=false
        local lighting=scene_:CreateChild("HeadlightPixelLighting")
        zone_=lighting:CreateComponent("Zone")
        zone_.boundingBox=BoundingBox(-100000,100000)
        zone_.autoExposureEnabled=false;zone_.vignetteEnabled=false
        zone_.bloomWeight=0;zone_.ssaoIntensity=0;zone_.ssrEnabled=false
        zone_.ssgiEnabled=false;zone_.volumetricFogEnabled=false
        local moon=lighting:CreateChild("Moon"):CreateComponent("Light")
        moon.lightType=LIGHT_DIRECTIONAL;moon.castShadows=false
        check(Environment.Init(scene_,lighting,{hour=hour_,running=false,weather="clear",quality="medium",rain=false}),"真实Environment初始化失败")
        Train.Build(scene_)
        local selected,message=Train.Select(model_)
        check(selected,"真实编组装配失败："..message)
        check(Train.GetSelectedId()==model_ and Train.ValidateBindings(),"不是指定的正式八节编组")
        -- 指定里程支持复现玩家图中的近轨位置，默认仍保持原回归场景。
        local s=position_>0 and position_ or Route.GetStations()[1].s+1300
        Train.Reset(s);Train.SetBrake(1)
        for first=math.floor((s-120)/120)*120,s+360,120 do
            Track.BuildChunk(scene_,first,first+120,true)
        end
        local ground=World.NewBatch(scene_:CreateChild("HeadlightPixelGround"),World.Solid(Color(.24,.30,.18),0,1),false,20)
        local center=Route.Sample(s+100)
        ground:AddBox(Vector3(center.x,center.y-.25,center.z),Vector3(700,.5,700));ground:Finish()
        Camera.Build(scene_);Camera.Update(0,s)
        check(Camera.SetMode(cameraMode_),"正式机位选择失败")
        Camera.AddPitch(pitchDelta_)
        Camera.Update(0,s)
        local node=assert(Camera.GetNode())
        local camera=assert(Camera.GetCamera())
        camera.farClip=500 -- 仅裁掉未生成远景；眼点/视向/FOV保持正式track_front。
        Environment.Update(0,node.worldPosition)
        check(math.abs(Environment.GetStatus().hour-hour_)<.00001 and Environment.GetStatus().lampFactor>.99,"不是指定夜间环境")
        check(Night.GetStats().sites==0,"测试混入站台/道路照明")
        check((camera.viewMask & 2)~=0,"正式相机看不见轨面")
        local lights=Train.GetHeadlightDiagnostics()
        check(#lights.mounts==2,"缺少真实车壳求交挂点")
        check(#lights.mounts[1].rim==12 and #lights.mounts[2].rim==12,"未使用真实车壳灯缘")
        Train.SetHeadlightMode("off");Train.UpdateHeadlight(1)
        baseline_={eye=node.worldPosition,direction=node.worldDirection,s=Train.GetS(),ambient=assert(zone_).ambientColor,
            sun=moon.brightness,nodes=#assert(scene_):GetChildren(true)}
        print(string.format("[HeadlightPixel] ready model=%s camera=%s hour=%.4f s=%.1f nodes=%d mask=%d",Train.GetSelectedId(),cameraMode_,hour_,s,baseline_.nodes,camera.viewMask))
        SubscribeToEvent("EndRendering","HeadlightPixelCapture")
    end)
end
function HeadlightPixelCapture()
    guard(function()
        rendered_=rendered_+1
        phaseFrames_=phaseFrames_+1
        local node=assert(Camera.GetNode())
        check((node.worldPosition-baseline_.eye):Length()<.000001 and (node.worldDirection-baseline_.direction):Length()<.000001,"开关对照相机变化")
        check(Train.GetS()==baseline_.s and #assert(scene_):GetChildren(true)==baseline_.nodes,"开关对照场景/车辆变化")
        local ambient=assert(zone_).ambientColor
        check(math.abs(ambient.r-baseline_.ambient.r)<.000001 and math.abs(ambient.g-baseline_.ambient.g)<.000001
            and math.abs(ambient.b-baseline_.ambient.b)<.000001,"开灯借环境光变亮")
        -- GLES异步readback在初始帧可返回false；每个灯态至少8个渲染帧后才申请读回。
        if phaseFrames_<WARMUP_FRAMES then return end
        attempts_=attempts_+1
        local image=Image()
        local captured=graphics:TakeScreenShot(image)
        if not captured or image.width<1 or image.height<1 then
            image:Dispose()
            print(string.format("[HeadlightPixel] framebuffer pending phase=%d attempt=%d frame=%d",phase_,attempts_,rendered_))
            check(attempts_<MAX_READBACK_ATTEMPTS,"真实GLES帧缓冲在有限重试内仍未就绪")
            return
        end
        readbacks_=readbacks_+1
        if not discarded_ then
            discarded_=true;image:Dispose()
            print("[HeadlightPixel] first successful framebuffer discarded")
            return
        end
        if phase_==1 then
            local off=Train.GetHeadlightDiagnostics()
            check(off.lights==0 and off.fillLights==0,"关灯对照仍有车灯或近轨补光")
            check(image:SavePNG(output_.."headlight_pixel_"..tag_.."_off.png"),"关灯截图保存失败")
            offImage_=image
            Train.SetHeadlightMode("on");Train.UpdateHeadlight(1)
            phase_=2
            phaseFrames_,attempts_=0,0
            discarded_=false -- 灯态切换后先丢一次成功读回，避免异步队列返回关灯旧帧。
            print("[HeadlightPixel] off captured; real train headlights on")
            return
        end
        local on=Train.GetHeadlightDiagnostics()
        check(on.lights==2 and on.fillLights==1,"真实远近Spot或近轨补光未开启")
        check(image:SavePNG(output_.."headlight_pixel_"..tag_.."_on.png"),"开灯截图保存失败")
        local delta,white,maximum=sampleDelta(image,assert(offImage_))
        image:Dispose()
        print(string.format("[HeadlightPixel] PIXEL lit=%.5f white=%.5f maxDelta=%.3f frames=%d batches=%d primitives=%d",delta,white,maximum,rendered_,graphics.numBatches,graphics.numPrimitives))
        check(delta>.003,"真实轨面亮区不足 delta="..delta)
        check(white<.14,"真实车灯大面积刷白 white="..white)
        print(string.format("ALL_HEADLIGHT_PIXEL_PASS checks=%d model=%s mode=%s camera=%s productionTrain=true productionTrack=true productionCamera=true hour=%.4f lit=%.5f white=%.5f frames=%d readbacks=%d saveDiskIO=0 cloudIO=0",checks_,model_,mode_,cameraMode_,hour_,delta,white,rendered_,readbacks_))
        done_=true;cleanup();engine:Exit()
    end)
end
function Stop() cleanup() end
