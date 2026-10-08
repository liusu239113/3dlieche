-- 纯速度策略边界验收，不创建场景、纹理或渲染网格。
local Policy = require "game.SpeedPolicy"

local function input(s, operating)
    return {
        s = s, length = 100000, operatingKmh = operating, lineKmh = 350,
        deceleration = .7, reversing = false, segments = {}, stations = {},
        nextStopS = nil, dwelling = false, stationKmh = 60, reactionSeconds = 1.5,
    }
end

function Start()
    local success, message = pcall(function()
        assert(Policy.Calculate(input(1000, 350)) == 350, "复兴号区间不是350")
        assert(Policy.Calculate(input(1000, 300)) == 300, "和谐号区间不是300")
        assert(Policy.Calculate(input(1000, 120)) == 120, "普速机车被错误放到350")
        local case = input(1000, 350)
        case.nextStopS = 25000
        assert(Policy.Calculate(case) == 350, "长区间被固定80限制")
        case.nextStopS = 2000
        local approach = Policy.Calculate(case)
        case.nextStopS = 1500
        assert(Policy.Calculate(case) < approach, "靠近停车点没有渐减")
        case.nextStopS = 1000
        assert(Policy.Calculate(case) == 10, "停车微调速度不正确")
        case.dwelling = true
        assert(Policy.Calculate(case) == 0, "站停不是0")
        case = input(1000, 350)
        case.stations = { { s = 1200 } }
        assert(Policy.Calculate(case) == 60, "站场没有独立60限制")
        case = input(1000, 350)
        case.segments = { { type = "arc", s = 900, length = 1000, radius = 9000 } }
        assert(Policy.Calculate(case) == 330, "曲线半径限制不正确")
        assert(Policy.CurveLimit(250, 350) <= 60, "小半径不能直接允许350")
        case = input(99950, 350)
        case.nextStopS = 100
        assert(Policy.Calculate(case) < 100, "闭合接缝进站没有减速")
        case = input(50, 350)
        case.reversing = true
        case.nextStopS = 99900
        assert(Policy.Calculate(case) < 100, "反向过接缝没有减速")
        print("[SpeedPolicyValidation] PASS: 车型运营、区间/曲线/站区、渐减进站、反向接缝")
    end)
    if not success then error(message) end
    engine:Exit()
end
