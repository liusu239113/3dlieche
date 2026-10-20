-- Deterministic environment regression. RunState needs only math + Color/Vector globals,
-- so it also runs under a plain Lua harness with value-type stubs (not a render test).
-- Official runtime entry Start additionally checks the existing Zone/Light/Skybox integration.
local Environment = require "world.Environment"
local VisualQuality = require "config.VisualQuality"
local Validation = {}
local checks_ = 0
---@type Scene|nil
local scene_ = nil

---@param value boolean
---@param message string
local function check(value, message)
    checks_ = checks_ + 1
    assert(value, "[EnvironmentValidation] " .. message)
end

---@param a number
---@param b number
---@param message string
local function near(a, b, message) check(math.abs(a - b) < 0.000001, message) end

---@param a EnvironmentSnapshot
---@param b EnvironmentSnapshot
local function sameSnapshot(a, b)
    for _, field in ipairs({ "hour", "dayLength", "cloud", "rain", "sunScale", "fogScale", "fog" }) do
        near(a[field], b[field], "snapshot changed: " .. field)
    end
    check(a.running == b.running and a.weather == b.weather, "snapshot flags changed")
    check(a.overcastSky == b.overcastSky, "snapshot sky-mode hysteresis changed")
end

---@return integer
function Validation.RunState()
    checks_ = 0
    check(Environment.Init(nil, nil, { visuals = false, hour = 12.0, running = false }), "state init failed")
    local day = Environment.GetStatus()
    check(day.clockText == "12:00" and day.minute == 0, "clock format")
    check(day.weather == "clear" and day.weatherLabel == "晴", "default weather")
    near(day.lampFactor, 0.0, "day lamps must be off")
    near(day.rainIntensity, 0.0, "clear rain must be zero")
    near(day.dayMix, 1.0, "noon day blend")
    check(day.signalFactor >= 0.5, "signals invisible in daylight")
    check(not day.skyReady and not day.rainReady, "state-only init allocated visual resources")

    Environment.SetTime(18.0)
    local dusk = Environment.GetStatus()
    check(dusk.lampFactor > day.lampFactor and dusk.lampFactor < 1.0, "dusk lamps must blend")
    Environment.SetTime(23.0)
    local night = Environment.GetStatus()
    check(night.clockText == "23:00" and night.nightMix > 0.99, "night status")
    near(night.lampFactor, 1.0, "night lamps")
    near(night.headlightFactor, 1.0, "night headlights")
    check(night.fogEnd < day.fogEnd, "night visibility should be lower but bounded")
    for hour = 0, 24, 0.125 do
        Environment.SetTime(hour)
        local status = Environment.GetStatus()
        check(status.lampFactor >= 0 and status.lampFactor <= 1, "lamp factor bounds")
        check(status.fogStart >= 180 and status.fogEnd >= status.fogStart + 500, "rail visibility floor")
    end

    check(Environment.SetTime(-1.0), "negative hour rejected")
    near(Environment.GetStatus().hour, 23.0, "negative wrap")
    Environment.SetTime(49.5)
    check(Environment.GetStatus().clockText == "01:30", "multi-day wrap")
    Environment.Configure({ hour = 23.99, running = true, dayLength = 60.0 })
    Environment.Update(0.1)
    check(Environment.GetStatus().hour < 0.1, "midnight rollover")
    local beforeFreeze = Environment.Export()
    Environment.SetTimeRunning(false)
    Environment.Update(10.0)
    near(Environment.GetStatus().hour, beforeFreeze.hour, "clock freeze")

    Environment.SetTime(12.0)
    check(Environment.SetWeather("rain"), "rain target")
    local targetOnly = Environment.GetStatus()
    check(targetOnly.weather == "rain" and targetOnly.weatherLabel == "雨", "target weather status")
    near(targetOnly.rainIntensity, 0, "weather switched abruptly")
    Environment.Update(1.0)
    local wet = Environment.GetStatus()
    check(wet.rainIntensity > 0 and wet.rainIntensity < 1, "rain failed smooth transition")
    check(wet.fogEnd < day.fogEnd, "rain fog not coupled")
    local halfway = Environment.Export()
    Environment.SetWeather("clear", true)
    check(Environment.Restore(halfway), "partial weather restore failed")
    sameSnapshot(Environment.Export(), halfway)

    Environment.SetPaused(true)
    local paused = Environment.Export()
    Environment.Update(100.0)
    sameSnapshot(Environment.Export(), paused)
    check(Environment.GetStatus().paused, "paused status")
    Environment.SetPaused(false)
    Environment.Update(1.0)
    check(Environment.GetStatus().rainIntensity > wet.rainIntensity, "weather failed to resume")
    check(not Environment.GetStatus().running, "pause changed clock toggle")

    local qualitySnapshot = Environment.Export()
    for _, id in ipairs({ "low", "medium", "high" }) do
        Environment.SetQuality(VisualQuality.Get(id))
        sameSnapshot(Environment.Export(), qualitySnapshot)
        local status = Environment.GetStatus()
        check(status.quality == id and status.weather == "rain", "quality reset weather")
        check(status.fogEnd < VisualQuality.Get(id).fogEnd, "quality erased rainy fog")
    end
    Environment.SetSheltered(true)
    check(Environment.GetStatus().sheltered, "shelter flag")
    near(Environment.GetStatus().rainIntensity, qualitySnapshot.rain, "shelter erased weather")
    Environment.SetSheltered(false)

    Environment.SetWeather("cloudy", true)
    local cloudy = Environment.GetStatus()
    check(cloudy.weatherLabel == "阴" and cloudy.cloudCover > 0.5, "cloudy state")
    near(cloudy.rainIntensity, 0.0, "cloudy emitted rain")
    local invalidStart = Environment.Export()
    check(not Environment.SetWeather("storm"), "unknown weather accepted")
    check(not Environment.SetTime(0 / 0), "NaN time accepted")
    check(not Environment.SetTime(math.huge), "infinite time accepted")
    check(not Environment.Configure({hour = 5, weather = "bad"}), "invalid patch accepted")
    sameSnapshot(Environment.Export(), invalidStart)
    check(not Environment.Restore({version = 99, hour = 5}), "future snapshot version accepted")
    check(not Environment.Restore({hour = 5, rain = 2}), "out-of-range rain accepted")
    check(not Environment.Restore({hour = 5, dayLength = 0}), "zero day length accepted")
    check(not Environment.Restore({hour = 5, cloud = 0 / 0}), "NaN snapshot accepted")
    check(not Environment.Restore({hour = 5, overcastSky = "bad"}), "invalid sky-mode accepted")
    sameSnapshot(Environment.Export(), invalidStart)
    Environment.Update(-1.0)
    Environment.Update(0.0)
    Environment.Update(math.huge)
    Environment.Update(0 / 0)
    sameSnapshot(Environment.Export(), invalidStart)

    Environment.Restore({hour = 17.5, running = false, weather = "rain"})
    check(Environment.GetStatus().clockText == "17:30", "settings-style restore clock")
    near(Environment.GetStatus().rainIntensity, 1.0, "settings-style restore target")
    check(Environment.GetStatus().weather == "rain", "settings-style restore weather")
    Environment.Init(nil, nil, {visuals = false, hour = 12, running = false})
    Environment.SetWeather("rain")
    Environment.Update(4.0)
    local largeStep = Environment.Export()
    Environment.Init(nil, nil, {visuals = false, hour = 12, running = false})
    Environment.SetWeather("rain")
    for _ = 1, 40 do Environment.Update(0.1) end
    sameSnapshot(Environment.Export(), largeStep)
    Environment.Update(100.0)
    near(Environment.GetStatus().rainIntensity, 1.0, "rain convergence")
    Environment.SetWeather("clear")
    Environment.Update(100.0)
    check(Environment.GetStatus().rainIntensity < 0.000001, "rain never stopped")
    -- 独立近雾：晴→雾不是按weather字符串瞬切；无降水不应触发声景雨量。
    Environment.Init(nil, nil, {visuals = false, hour = 12, running = false, quality = "medium"})
    local clearFog = Environment.GetStatus()
    check(Environment.SetWeather("fog"), "fog target rejected")
    near(Environment.GetStatus().fogEnd, clearFog.fogEnd, "fog switched before simulation")
    near(Environment.GetStatus().fogIntensity, 0, "fog weight switched abruptly")
    local previousEnd = clearFog.fogEnd
    for _ = 1, 40 do
        Environment.Update(0.1)
        local status = Environment.GetStatus()
        check(status.fogEnd < previousEnd and status.fogEnd > 700, "fog did not approach monotonically")
        check(status.fogStart >= 80 and status.fogEnd > status.fogStart + 500, "near-fog visibility bounds")
        near(status.rainIntensity, 0, "clear-to-fog introduced rain/sound intensity")
        previousEnd = status.fogEnd
    end
    local fogHalfway, halfwayStatus = Environment.Export(), Environment.GetStatus()
    Environment.SetPaused(true)
    Environment.Update(20)
    sameSnapshot(Environment.Export(), fogHalfway)
    near(Environment.GetStatus().fogEnd, halfwayStatus.fogEnd, "pause advanced fog visibility")
    Environment.SetPaused(false)
    Environment.SetWeather("clear", true)
    check(Environment.Restore(fogHalfway), "partial fog restore failed")
    sameSnapshot(Environment.Export(), fogHalfway)
    near(Environment.GetStatus().fogEnd, halfwayStatus.fogEnd, "restored fog visibility jumped")
    Environment.Update(100)
    local fogDay = Environment.GetStatus()
    check(fogDay.weather == "fog" and fogDay.weatherLabel == "雾", "fog label/status")
    near(fogDay.fogStart, 80, "settled fog start must be 80m")
    near(fogDay.fogEnd, 700, "settled fog end must be 700m")
    check(fogDay.signalFactor > clearFog.signalFactor and fogDay.headlightFactor >= .8, "fog signals/headlights not readable")
    check(Environment.Export().overcastSky == true, "fog retained photographic blue sky")
    for _, id in ipairs({ "low", "medium", "high" }) do
        local saved = Environment.Export()
        Environment.SetQuality(id)
        sameSnapshot(Environment.Export(), saved)
        near(Environment.GetStatus().fogStart, 80, "quality erased near fog start")
        near(Environment.GetStatus().fogEnd, 700, "quality erased near fog end")
    end
    Environment.SetSheltered(true)
    near(Environment.GetStatus().fogEnd, 700, "cab shelter erased outside fog")
    Environment.SetTime(23)
    near(Environment.GetStatus().fogEnd, 700, "night collapsed near-fog sight distance")
    near(Environment.GetStatus().rainIntensity, 0, "night fog introduced rain")
    Environment.SetSheltered(false)
    Environment.SetTime(12)
    Environment.SetQuality("medium")
    local settledFog = Environment.Export()
    Environment.SetWeather("clear")
    near(Environment.GetStatus().fogEnd, 700, "fog-to-clear snapped visibility")
    Environment.Update(1)
    check(Environment.GetStatus().fogEnd > 700 and Environment.GetStatus().fogIntensity > 0, "fog-to-clear not smooth")
    Environment.SetWeather("fog")
    Environment.Update(1)
    check(Environment.GetStatus().fogEnd < clearFog.fogEnd, "reversing transition lost fog")
    check(Environment.Restore(settledFog), "settled fog restore")
    Environment.SetWeather("rain")
    Environment.Update(1)
    check(Environment.GetStatus().rainIntensity > 0 and Environment.GetStatus().fogIntensity > 0, "fog-to-rain lost independent weights")
    Environment.Update(100)
    near(Environment.GetStatus().fogIntensity, 0, "rain inherited near fog")
    Environment.SetWeather("fog")
    Environment.Update(1)
    check(Environment.GetStatus().rainIntensity < 1 and Environment.GetStatus().rainIntensity > 0, "rain-to-fog cut rainfall abruptly")
    Environment.Update(100)
    near(Environment.GetStatus().rainIntensity, 0, "settled fog retained rain/sound intensity")
    local beforeInvalidFog = Environment.Export()
    for _, value in ipairs({ -0.1, 1.1, math.huge, 0/0, "mist" }) do
        check(not Environment.Restore({hour = 5, weather = "clear", fog = value}), "invalid fog snapshot accepted")
        sameSnapshot(Environment.Export(), beforeInvalidFog)
    end
    -- 兼容旧v1三天气档；整个验证只传table，不读取/写入玩家存档，更不调用云端。
    for _, id in ipairs({ "clear", "cloudy", "rain", "fog" }) do
        check(Environment.Restore({version=1,hour=12,running=false,weather=id}), "v1 settings restore " .. id)
        near(Environment.GetStatus().fogIntensity, id == "fog" and 1 or 0, "missing fog field migration " .. id)
    end
    Environment.Init(nil, nil, {visuals=false,hour=12,running=false})
    Environment.SetWeather("fog")
    Environment.Update(4)
    local fogLargeStep = Environment.Export()
    Environment.Init(nil, nil, {visuals=false,hour=12,running=false})
    Environment.SetWeather("fog")
    for _ = 1, 40 do Environment.Update(.1) end
    sameSnapshot(Environment.Export(), fogLargeStep)
    -- 迟滞带内恢复保留原模式，两种方向都不能由目标天气重猜。
    for _, overcast in ipairs({ true, false }) do
        check(Environment.Restore({hour=12,weather="clear",cloud=.27,fog=.2,overcastSky=overcast}), "hysteresis restore")
        check(Environment.Export().overcastSky == overcast, "hysteresis lost in restore band")
    end
    -- 自然跨日保留绝对分钟；固定步推进与PostUpdate视觉提交不得双计时。
    Environment.Init(nil,nil,{visuals=false,hour=23.99,running=true,dayLength=60})
    local clockStart=Environment.GetClock()
    Environment.Advance(.1)
    local clockNext=Environment.GetClock()
    near(clockNext.minutes-clockStart.minutes,2.4,"absolute midnight delta")
    check(clockNext.minutes>1440 and Environment.GetStatus().hour<.1,"absolute midnight lost day")
    Environment.Update(0)
    near(Environment.GetClock().minutes,clockNext.minutes,"visual flush double advanced time")
    near(Environment.GetClock().rate,24,"clock simulation rate")
    Environment.Advance(120)
    near(Environment.GetClock().minutes,clockNext.minutes+2880,"multi-day step lost days")
    local absoluteSaved=Environment.Export()
    Environment.SetTime(9)
    check(Environment.GetClock().revision==1,"manual time revision")
    check(Environment.Restore(absoluteSaved),"absolute snapshot restore")
    near(Environment.GetClock().minutes,assert(absoluteSaved.minutes),"absolute restore lost days")
    check(Environment.GetClock().revision==absoluteSaved.revision,"restore revision changed")
    local unchanged=Environment.Export()
    for _,bad in ipairs({{minutes=-1},{minutes=0/0},{minutes=1440,hour=12},{revision=-1},{revision=.5}}) do
        check(not Environment.Restore(bad),"invalid absolute clock accepted")
        near(Environment.GetClock().minutes,assert(unchanged.minutes),"invalid restore mutated clock")
    end
    Environment.SetPaused(true)
    Environment.Advance(10)
    near(Environment.GetClock().minutes,assert(unchanged.minutes),"paused Advance changed clock")
    Environment.SetPaused(false)
    Environment.SetTimeRunning(false)
    Environment.Advance(10)
    near(Environment.GetClock().minutes,assert(unchanged.minutes),"stopped Advance changed clock")
    check(Environment.Restore({version=1,hour=17.5,running=false,weather="clear"}),"legacy clock migration")
    near(Environment.GetClock().minutes,1050,"legacy clock minutes")
    check(Environment.GetClock().revision==0,"legacy revision")
    Environment.Destroy()
    print(string.format("ALL_ENVIRONMENT_STATE_VALIDATION_PASS checks=%d", checks_))
    return checks_
end

---@param scene Scene
---@param lighting Node
---@param skyNode Node
---@return integer
function Validation.RunVisualBindings(scene, lighting, skyNode)
    local zone = assert(lighting:GetComponent("Zone", true))
    local light = assert(lighting:GetComponent("Light", true))
    local sky = assert(skyNode:GetComponent("Skybox"))
    local original = sky:GetMaterial()
    local postBefore = {zone.bloomWeight, zone.ssaoIntensity, zone.ssrEnabled, zone.volumetricFogEnabled, light.castShadows}
    check(Environment.Init(scene, lighting, {hour = 12, running = false, skyNode = skyNode}), "native Init failed")
    check(Environment.GetStatus().skyReady, "native sky texture not uploaded")
    check(lighting:GetComponent("Zone", true) == zone and lighting:GetComponent("Light", true) == light, "native lighting replaced")
    check(#scene:GetComponents("Zone", true) == 1, "duplicated Zone")
    local dayFog, dayAmbient, dayLight = zone.fogColor, zone.ambientColor, light.brightness
    Environment.SetTime(23.0)
    check(zone.fogColor.r < dayFog.r and zone.ambientColor.r < dayAmbient.r, "night zone remains daytime")
    check(light.brightness < dayLight, "night sun remains bright")
    Environment.SetWeather("rain", true)
    Environment.Update(0.1, Vector3(100, 4, 200))
    if Environment.GetStatus().rainReady then
        local rainNode = assert(scene:GetChild("EnvironmentRain"))
        local emitter = assert(rainNode:GetComponent("ParticleEmitter"))
        check(emitter.enabled and emitter.emitting, "native rain not emitting")
        check(not emitter.effect.relative, "rain must use world-space particles")
        near(rainNode.worldPosition.x, 99.0, "rain does not follow camera X")
        near(rainNode.worldPosition.z, 200.0, "rain does not follow camera Z")
        Environment.SetPaused(true)
        check(not emitter.enabled, "rain simulation continues while paused")
        Environment.SetPaused(false)
        check(emitter.enabled, "rain simulation failed to resume")
        Environment.SetSheltered(true)
        check(not emitter.enabled and not emitter.emitting, "rain inside cab")
        Environment.SetSheltered(false)
        check(emitter.enabled and emitter.emitting, "exterior rain failed to resume")
        Environment.SetQuality("low")
        check(emitter.numParticles == 180, "low particle budget")
        Environment.SetQuality("high")
        check(emitter.numParticles == 560, "high particle budget")
    end
    Environment.SetTime(12)
    Environment.SetWeather("fog", true)
    Environment.Update(.1, Vector3(0, 2, 0))
    near(zone.depthFogStart, 80, "native fog start not applied")
    near(zone.depthFogEnd, 700, "native fog end not applied")
    check(math.abs(zone.fogColor.r-zone.fogColor.b) < .04, "native fog not neutral grey")
    local fogRainNode = scene:GetChild("EnvironmentRain")
    if fogRainNode then
        local emitter = assert(fogRainNode:GetComponent("ParticleEmitter"))
        check(not emitter.enabled and not emitter.emitting, "native fog emitted rain")
    end
    local path = assert((require "world.Sky").GetRealisticPath())
    local photo = assert(cache:GetResource("TextureCube", path))
    check(photo.width == 2048, "original photographic sky resolution regressed")
    local fogCube = assert(assert(sky:GetMaterial()):GetTexture(TU_DIFFUSE))
    check(fogCube ~= photo and fogCube.width == 32, "fog must use 32px CPU sky")
    for _, id in ipairs({ "low", "high", "medium" }) do
        Environment.SetQuality(id)
        near(zone.depthFogEnd, 700, "native quality change lost fog")
        check(assert(sky:GetMaterial()):GetTexture(TU_DIFFUSE) == fogCube, "quality reallocated fog cubemap")
    end
    Environment.SetWeather("clear", true)
    check(assert(sky:GetMaterial()):GetTexture(TU_DIFFUSE) == photo, "clear did not restore original photographic sky")
    -- 声景只接原样状态；音乐和人群音量置零，晴→雾不加载任何声音、不触发资源下载。
    local Soundscape = require "audio.Soundscape"
    Soundscape.Init()
    Soundscape.SetSettings({sound=true,volume=.75,musicVolume=0,ambienceVolume=.45})
    Soundscape.SetContext("cab",1000,0,false,true)
    Environment.SetWeather("fog",true)
    Soundscape.SetEnvironment(Environment.GetStatus())
    Soundscape.Update(.1)
    local sound = Soundscape.GetDiagnostics()
    near(sound.rainIntensity,0,"fog soundscape rain intensity")
    near(sound.channels.rain.gain,0,"fog soundscape rain gain")
    check(sound.channels.rain.playCalls == 0 and not sound.channels.rain.ready,"fog loaded/played rain audio")
    Soundscape.Shutdown()
    check(zone.bloomWeight == postBefore[1] and zone.ssaoIntensity == postBefore[2]
        and zone.ssrEnabled == postBefore[3] and zone.volumetricFogEnabled == postBefore[4]
        and light.castShadows == postBefore[5], "environment enabled forbidden effects")
    Environment.Destroy()
    check(sky:GetMaterial() == original, "original sky material not restored")
    check(scene:GetChild("EnvironmentRain") == nil, "rain node leaked after destroy")
    print(string.format("ALL_ENVIRONMENT_BINDINGS_VALIDATION_PASS checks=%d", checks_))
    return checks_
end

function Start()
    local ok, err = xpcall(function()
        Validation.RunState()
        scene_ = Scene() -- Module reference owns Scene through exit.
        scene_:CreateComponent("Octree")
        local lighting = scene_:CreateChild("DayLighting")
        lighting:CreateComponent("Zone")
        local sunNode = lighting:CreateChild("Sun")
        local light = sunNode:CreateComponent("Light")
        light.lightType = LIGHT_DIRECTIONAL
        local Sky = require "world.Sky"
        local skyNode = Sky.Create(scene_, VisualQuality.Get("medium"))
        Validation.RunVisualBindings(scene_, lighting, skyNode)
    end, debug.traceback)
    if not ok then log:Write(LOG_ERROR, tostring(err)) end
    -- -validate 按帧结束并写JSON；Start内直接Exit会跳过运行期报告落盘。
end

return Validation
