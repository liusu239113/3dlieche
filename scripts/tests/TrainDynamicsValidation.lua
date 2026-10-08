-- Explicit CPU regression entry; uses Train.Update, not a duplicate physics implementation.
local Train = require "train.Train"
local RollingStock = require "train.RollingStock"
local Catalog = require "config.TrainCatalog"
local Route = require "world.Route"
local GameConfig = require "config.GameConfig"
---@type Scene|nil
local scene_ = nil
local DT = .05

local function check(value, message)
    assert(value, "[Dynamics] " .. message)
end

---@param seconds number
local function advance(seconds)
    for _ = 1, math.floor(seconds / DT) do Train.Update(DT) end
end

function Start()
    local ok, message = pcall(function()
        Route.Build()
        scene_ = Scene()
        scene_:CreateComponent("Octree")
        local started = os.clock()
        Train.Build(scene_)
        local loadSeconds = os.clock() - started
        check(Train.GetSelectedId() == "CR400AF", "default fell back")
        check(RollingStock.IsReady("CR400AF_head") and RollingStock.IsReady("CR400AF_middle"), "default not loaded")
        check(not RollingStock.IsReady("DF4D") and not RollingStock.IsReady("CRH380A_head"), "unselected models prepared")
        local menu = Train.GetCatalog()
        check(#menu == #Catalog.Entries, "catalog incomplete")
        for _, item in ipairs(menu) do check(item.ready, item.id .. " delivered but unselectable") end
        check(not RollingStock.IsReady("DF4D") and not RollingStock.IsReady("CRH380A_head"), "catalog prepared models")
        local report = {"DEFAULT_ONLY_LOAD_PASS seconds=" .. tostring(loadSeconds)}
        local dt = .05
        for _, entry in ipairs(Catalog.Entries) do
            Train.Reset(0)
            local selected, selectedMessage = Train.Select(entry.id)
            check(selected, selectedMessage)
            check(Train.GetOperatingSpeedKmh() == entry.operatingSpeedKmh, "operating speed mismatch")
            check(Train.GetMaxSpeedKmh() == entry.maxSpeedKmh, "construction speed mismatch")
            check(Train.GetServiceDeceleration() == entry.serviceDeceleration, "service deceleration mismatch")
            Train.SetThrottle(GameConfig.Train.MaxThrottle)
            advance(2)
            check(Train.GetSpeedMs() == 0, "selection brake lock failed")
            Train.SetBrake(0)
            local targetMs = entry.operatingSpeedKmh / 3.6
            local time, distance, reached = 0.0, 0.0, false
            for _ = 1, math.floor(1200 / dt) do
                Train.Update(dt)
                time = time + dt
                distance = distance + math.abs(Train.GetSpeedMs()) * dt
                if Train.GetSpeedMs() >= targetMs - .05 then reached = true break end
            end
            check(reached, entry.id .. " cannot reach operating speed within 1200s")
            check(Train.GetSpeedKmh() <= entry.maxSpeedKmh + .01, "construction cap violated")
            local movingSelect = Train.Select(Catalog.DefaultId)
            check(not movingSelect, "moving selection allowed")
            local v = Train.GetSpeedMs()
            local traction = math.min(entry.maxTractive, entry.powerW / math.max(v, .1))
            local resistance = entry.resistA + entry.resistB * v + entry.resistC * v * v
            check(traction > resistance, "no operating-speed acceleration margin")
            Train.SetThrottle(0)
            Train.SetBrake(0)
            advance(5)
            check(Train.GetSpeedMs() < v and Train.GetSpeedMs() >= 0, "coasting resistance sign wrong")
            Train.EmergencyBrake()
            local brakingSeconds = 0.0
            for _ = 1, math.floor(240 / dt) do
                Train.Update(dt)
                brakingSeconds = brakingSeconds + dt
                check(Train.GetSpeedMs() >= 0, "braking crossed zero")
                if Train.GetSpeedMs() == 0 then break end
            end
            check(Train.GetSpeedMs() == 0, "emergency brake did not stop")
            check(Train.ToggleReversing(), "stationary reverse failed")
            Train.SetBrake(0)
            Train.SetThrottle(GameConfig.Train.MaxThrottle)
            advance(4)
            check(Train.GetSpeedMs() < 0, "reverse does not move")
            Train.EmergencyBrake()
            advance(20)
            check(Train.GetSpeedMs() == 0, "reverse braking crossed zero")
            report[#report + 1] = string.format("%s PASS target=%.0f actual=%.3f time=%.2fs distance=%.1fm F=%.2fkN R=%.2fkN emergency=%.2fs mass=%.0fkg power=%.3fMW",
                entry.id, entry.operatingSpeedKmh, v * 3.6, time, distance, traction / 1000, resistance / 1000,
                brakingSeconds, entry.mass, entry.powerW / 1000000)
        end
        report[#report + 1] = "ALL_TRAIN_DYNAMICS_PASS"
        for _, line in ipairs(report) do print("[Dynamics] " .. line) end
        local file = File("/workspace/screenshots/train_dynamics.txt", FILE_WRITE)
        check(file:IsOpen(), "report cannot open")
        for _, line in ipairs(report) do check(file:WriteLine(line), "report cannot write") end
        file:Close()
    end)
    if not ok then print("[Dynamics] FAIL " .. tostring(message)) end
    engine:Exit()
end
