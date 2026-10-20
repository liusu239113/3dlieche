-- Real surfaceless pixels: representative railway fixture, not full-main acceptance.
-- No build, HTML, service, or runtime installation. EndRendering saves only actual readback.
local Environment = require "world.Environment"
local Quality = require "config.VisualQuality"
local Sky = require "world.Sky"
local Materials = require "config.Materials"
local Config = require "config.EnvironmentConfig"
---@type Scene?
local scene_ = nil
---@type Node?
local lighting_ = nil
---@type Node?
local cameraNode_ = nil
---@type Node?
local cab_ = nil
---@type Light[]
local lamps_ = {}
---@type Material[]
local bulbs_ = {}
---@type Material?
local signal_ = nil
---@type Skybox?
local sky_ = nil
---@type Material?
local photo_ = nil
local frame_, index_, age_, captures_, checks_ = 0, 1, 0, 0, 0
local failed_, complete_ = false, false
local previousRain_ = Vector3.ZERO
local movedRain_ = false
local OUTPUT = "/workspace/screenshots/environment_fog_visual_"
---@type EnvironmentSnapshot?
local fogTransition_ = nil
---@class EnvironmentVisualCase
---@field name string
---@field hour number
---@field weather string
---@field photo? boolean
---@field paused? boolean
---@field sheltered? boolean
---@field cab? boolean
---@field quality? string
---@field transition? boolean
---@field restore? boolean
---@type EnvironmentVisualCase[]
local cases_ = {
    {name="00_photo_baseline",hour=12,weather="clear",photo=true},
    {name="01_day_clear",hour=12,weather="clear"},
    {name="02_dusk_clear",hour=18,weather="clear"},
    {name="03_night_clear",hour=23,weather="clear"},
    {name="04_day_cloudy",hour=12,weather="cloudy"},
    {name="05_day_rain",hour=12,weather="rain"},
    {name="06_day_rain_moving",hour=12,weather="rain"},
    {name="07_rain_paused_a",hour=12,weather="rain",paused=true},
    {name="08_rain_paused_b",hour=12,weather="rain",paused=true},
    {name="09_rain_sheltered",hour=12,weather="rain",sheltered=true},
    {name="10_cab_sheltered",hour=12,weather="rain",sheltered=true,cab=true},
    {name="11_rain_resumed",hour=12,weather="rain"},
    {name="12_rain_low",hour=12,weather="rain",quality="low"},
    {name="13_rain_medium_restored",hour=12,weather="rain",quality="medium"},
    {name="14_clear_medium_restored",hour=12,weather="clear",quality="medium"},
    {name="15_clear_to_fog_transition",hour=12,weather="fog",transition=true},
    {name="16_fog_transition_restored",hour=12,weather="fog",restore=true,paused=true},
    {name="17_day_fog",hour=12,weather="fog"},
    {name="18_night_fog",hour=23,weather="fog"},
    {name="19_fog_low",hour=12,weather="fog",quality="low"},
    {name="20_fog_high",hour=12,weather="fog",quality="high"},
    {name="21_fog_cab_sheltered",hour=12,weather="fog",sheltered=true,cab=true},
    {name="22_clear_after_fog",hour=12,weather="clear"},
}

---@param value boolean
---@param message string
local function check(value,message) checks_=checks_+1;assert(value,"[EnvironmentVisual] "..message) end
---@param action fun()
local function guard(action)
    if failed_ or complete_ then return end
    local ok,err=xpcall(action,debug.traceback)
    if not ok then failed_=true;log:Write(LOG_ERROR,tostring(err));engine:Exit() end
end

---@param name string
---@param pos Vector3
---@param scale Vector3
---@param mat Material
---@param parent? Node
---@return Node
local function box(name,pos,scale,mat,parent)
    local node=(parent or assert(scene_)):CreateChild(name)
    node.position,node.scale=pos,scale
    local model=node:CreateComponent("StaticModel")
    model.model=assert(cache:GetResource("Model","Models/Box.mdl")) -- documented 1m unit box
    model.material=mat
    model.castShadows=false
    return node
end

local function fixture()
    local concrete=Materials.Solid(Color(.46,.48,.48),0,.9)
    local grass=Materials.Solid(Color(.25,.34,.19),0,1)
    local rail=Materials.Solid(Color(.47,.48,.50),.7,.3)
    local ballast=Materials.Solid(Color(.23,.24,.26),0,1)
    local wood=Materials.Solid(Color(.20,.16,.12),0,1)
    box("Ground",Vector3(0,-.25,220),Vector3(1500,.5,1500),grass)
    box("Ballast",Vector3(0,.10,180),Vector3(4.5,.20,500),ballast)
    for _,x in ipairs({-.72,.72}) do box("Rail",Vector3(x,.24,180),Vector3(.10,.12,500),rail) end
    for z=-10,180,2 do box("Sleeper",Vector3(0,.18,z),Vector3(2.7,.13,.25),wood) end
    box("Platform",Vector3(6,.65,65),Vector3(7,1.3,130),concrete)
    box("PlatformEdge",Vector3(2.65,1.32,65),Vector3(.3,.05,130),Materials.Solid(Color(.90,.75,.25),0,.8))
    box("Station",Vector3(17,4,65),Vector3(13,8,28),Materials.Solid(Color(.60,.48,.35),0,.9))
    box("Roof",Vector3(11,6,50),Vector3(16,.3,65),Materials.Solid(Color(.19,.23,.25),.1,.7))
    for z=20,100,20 do
        box("Pillar",Vector3(10,3,z),Vector3(.35,6,.35),concrete)
        box("LampPole",Vector3(3.3,3.8,z),Vector3(.14,5,.14),rail)
        local bulb=Materials.Glow(Color(1,.86,.58),.1):Clone()
        box("Bulb",Vector3(3.3,6.4,z),Vector3(.8,.12,.4),bulb)
        bulbs_[#bulbs_+1]=bulb
        local lightNode=assert(scene_):CreateChild("PlatformLight")
        lightNode.position=Vector3(3.3,6.2,z)
        local light=lightNode:CreateComponent("Light")
        light.lightType=LIGHT_POINT;light.color=Color(1,.86,.58);light.range=12;light.brightness=0;light.castShadows=false
        lamps_[#lamps_+1]=light
    end
    box("SignalPole",Vector3(-2,2.5,24),Vector3(.12,5,.12),rail)
    box("SignalHousing",Vector3(-2,4.7,24),Vector3(.65,1.4,.3),wood)
    signal_=Materials.Glow(Color(.05,1,.25),.5):Clone()
    box("GreenSignal",Vector3(-2,4.9,23.8),Vector3(.30,.30,.1),signal_)
    for i=1,12 do
        box("DistantHill",Vector3(-480+i*82,30+(i%3)*12,600+(i%4)*110),Vector3(120,70+(i%3)*24,110),
            Materials.Solid(Color(.24,.31,.25),0,1))
    end
    -- Test-only cab aperture: never claims to validate the production cab mesh.
    cab_=assert(scene_):CreateChild("CabFixture")
    local trim=Materials.Solid(Color(.10,.12,.14),.1,.7)
    box("CabRoof",Vector3(0,4,-15),Vector3(5,.45,7),trim,cab_)
    box("CabDash",Vector3(0,1.3,-14),Vector3(5,1.1,.9),trim,cab_)
    box("CabLeft",Vector3(-2,2.5,-14),Vector3(.3,3,.6),trim,cab_)
    box("CabRight",Vector3(2,2.5,-14),Vector3(.3,3,.6),trim,cab_)
    cab_:SetEnabledRecursive(false)
end

local function activate()
    local case=cases_[index_]
    if not case.photo then
        if index_==2 then
            check(Environment.Init(assert(scene_),assert(lighting_),{hour=case.hour,running=false,weather=case.weather}),"Init failed")
        else
            Environment.SetPaused(false)
            Environment.SetSheltered(false)
            Environment.SetQuality(case.quality or "medium")
            Environment.SetTime(case.hour)
            Environment.SetWeather(case.weather,not case.transition)
            if case.restore then
                check(Environment.Restore(assert(fogTransition_)),"partial fog restore failed")
            end
            if case.transition then
                Environment.Update(2,assert(cameraNode_).worldPosition)
                fogTransition_ = Environment.Export()
            end
        end
        Environment.SetPaused(case.paused==true)
        Environment.SetSheltered(case.sheltered==true)
    end
    assert(cab_):SetEnabledRecursive(case.cab==true)
    age_=0
    print(string.format("[EnvironmentVisual] CASE name=%s hour=%.2f weather=%s paused=%s sheltered=%s",
        case.name,case.hour,case.weather,tostring(case.paused==true),tostring(case.sheltered==true)))
end

function Start()
    guard(function()
        scene_=Scene();scene_:CreateComponent("Octree")
        renderer.drawShadows=false;renderer.materialQuality=QUALITY_MEDIUM;renderer.specularLighting=false
        renderer.hdrRendering=true
        lighting_=scene_:CreateChild("DayLighting")
        local zone=lighting_:CreateComponent("Zone")
        zone.boundingBox=BoundingBox(Vector3(-3000,-3000,-3000),Vector3(3000,3000,3000))
        zone.ambientSource=AMBIENT_COLOR;zone.ambientColor=Color(.34,.40,.48)
        zone.fogColor=Quality.Get("medium").fogColor;zone.depthFogStart=950;zone.depthFogEnd=3000
        zone.tonemapMode=TONEMAP_MODE_ACES;zone.vignetteEnabled=false;zone.autoExposureEnabled=false
        zone.bloomWeight=0;zone.ssaoIntensity=0;zone.ssrEnabled=false;zone.ssgiEnabled=false;zone.volumetricFogEnabled=false
        local sunNode=lighting_:CreateChild("Sun");sunNode.direction=Vector3(.45,-1,.55)
        local light=sunNode:CreateComponent("Light");light.lightType=LIGHT_DIRECTIONAL;light.color=Color(1,.955,.86);light.brightness=1.35
        sky_=Sky.Create(scene_,Quality.Get("medium")):GetComponent("Skybox")
        photo_=sky_:GetMaterial()
        fixture()
        cameraNode_=scene_:CreateChild("Camera");cameraNode_.position=Vector3(0,2.4,-18);cameraNode_:LookAt(Vector3(0,5,70))
        local camera=cameraNode_:CreateComponent("Camera");camera.fov=65;camera.nearClip=.1;camera.farClip=3000
        renderer:SetViewport(0,Viewport:new(scene_,camera))
        activate()
        SubscribeToEvent("Update","HandleEnvironmentVisualUpdate")
        SubscribeToEvent("EndRendering","HandleEnvironmentVisualCapture")
    end)
end

function HandleEnvironmentVisualUpdate()
    guard(function()
        frame_,age_=frame_+1,age_+1
        local case=cases_[index_]
        if not case.photo then
            if not case.transition then Environment.Update(1/30,assert(cameraNode_).worldPosition) end
            local status=Environment.GetStatus()
            for _,light in ipairs(lamps_) do light.brightness=status.lampFactor*5 end
            for _,bulb in ipairs(bulbs_) do bulb:SetShaderParameter("MatEmissiveColor",Variant(Color(1,.86,.58)*(status.lampFactor*1.2))) end
            if signal_ then signal_:SetShaderParameter("MatEmissiveColor",Variant(Color(.05,1,.25)*status.signalFactor)) end
            if case.weather=="rain" then
                local emitter=assert(assert(scene_):GetChild("EnvironmentRain")):GetComponent("ParticleEmitter")
                check(emitter~=nil,"native rain missing")
                if case.paused or case.sheltered then check(not emitter.enabled,"rain not hidden/paused") end
                if index_==6 and age_==5 then
                    for i=0,emitter.numBillboards-1 do
                        local b=emitter:GetBillboard(i)
                        if b.enabled then previousRain_=b.position;break end
                    end
                elseif index_==6 and age_==6 then
                    for i=0,emitter.numBillboards-1 do
                        local b=emitter:GetBillboard(i)
                        if b.enabled then movedRain_=b.position.y<previousRain_.y;break end
                    end
                    check(movedRain_,"rain does not fall downward between real engine frames")
                end
            end
        end
    end)
end

function HandleEnvironmentVisualCapture()
    guard(function()
        local wait=index_==1 and 10 or 8
        if age_<wait then return end
        local case=cases_[index_]
        local image=Image()
        check(graphics:TakeScreenShot(image),"real framebuffer readback failed")
        check(image.width>=640 and image.height>=360,"unexpected actual framebuffer size")
        print(string.format("[EnvironmentVisual] FRAMEBUFFER %dx%d",image.width,image.height))
        check(image:SavePNG(OUTPUT..case.name..".png"),"PNG write failed")
        image:Dispose();captures_=captures_+1
        print(string.format("[EnvironmentVisual] CAPTURE %s frame=%d batches=%d primitives=%d",case.name,frame_,graphics.numBatches,graphics.numPrimitives))
        if case.photo or case.paused or case.sheltered then
            check(graphics.numBatches==25 or case.cab==true and graphics.numBatches==26,"unexpected precipitation drawcall")
        elseif case.weather=="rain" then
            check(graphics.numBatches==26,"precipitation not submitted to actual renderer")
        end
        if index_==14 then
            check(Environment.GetStatus().weather=="rain" and Environment.GetStatus().quality=="medium","quality restored default weather")
            local path=assert(Sky.GetRealisticPath())
            check(assert(sky_):GetMaterial():GetTexture(TU_DIFFUSE)~=cache:GetResource("TextureCube",path),"rain quality must retain overcast sky, not photographic blue")
        end
        if index_==15 then
            local path=assert(Sky.GetRealisticPath())
            check(assert(sky_):GetMaterial():GetTexture(TU_DIFFUSE)==cache:GetResource("TextureCube",path),"clear medium failed to restore photographic cubemap")
        end
        if case.weather == "fog" then
            local status = Environment.GetStatus()
            local zone = assert(assert(lighting_):GetComponent("Zone"))
            check(status.rainIntensity < .000001,"fog retained rain intensity")
            check(graphics.numBatches == (case.cab and 26 or 25),"fog submitted precipitation drawcall")
            check(status.signalFactor >= .55,"fog signal factor below daylight floor")
            local emitter = assert(assert(scene_):GetChild("EnvironmentRain")):GetComponent("ParticleEmitter")
            check(not assert(emitter).enabled,"fog emitter active")
            if not case.transition and not case.restore then
                check(status.fogStart == 80 and status.fogEnd == 700,"fog visibility not 80..700m")
                check(math.abs(zone.fogColor.r-zone.fogColor.b) < .04,"fog horizon not neutral grey")
                local texture = assert(assert(sky_):GetMaterial()):GetTexture(TU_DIFFUSE)
                check(assert(texture).width == 32,"fog did not use low-cost CPU sky")
            else
                check(status.fogEnd > 700 and status.fogEnd < 3000,"fog transition not intermediate")
            end
            print(string.format("[EnvironmentVisual] FOG start=%.3f end=%.3f blend=%.6f rain=%.6f signal=%.3f",
                status.fogStart,status.fogEnd,status.fogIntensity,status.rainIntensity,status.signalFactor))
        end
        if case.name == "22_clear_after_fog" then
            local path = assert(Sky.GetRealisticPath())
            local texture = assert(assert(sky_):GetMaterial()):GetTexture(TU_DIFFUSE)
            check(texture == cache:GetResource("TextureCube",path) and assert(texture).width == 2048,"fog-to-clear lost 2048 photo sky")
        end
        if index_==#cases_ then
            complete_=true
            print(string.format("ALL_ENVIRONMENT_VISUAL_CAPTURE_PASS screenshots=%d checks=%d rainDownward=%s skySize=%d",captures_,checks_,tostring(movedRain_),Config.SkySize))
            -- 完成后由-validate自动结束并写报告，避免脚本Exit绕过报告。
        else index_=index_+1;activate() end
    end)
end

function Stop() Environment.Destroy() end
