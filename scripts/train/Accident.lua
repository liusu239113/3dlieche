-- 手动驾驶事故：按真实车体弦切线估计侧向加速度；建议限速只提示、不抢控件。
-- 风险设计（游戏模型，非铁路工程安全认证）：
--   曲线 R：a=v²/R，超过2.8m/s²持续0.45s -> 脱轨。
--   结构极限：超过构造速度1.35倍持续1s -> 走行部失稳。
--   碰撞：逐车弧长包络重叠且横距<3.4m，异轨平行会车不相撞。
--   端点：整列真实首尾越出开放轨道 -> 撞端脱轨，不钳里程自动停车。
-- 事故锁存后使用独立世界姿态，脱轨、偏移与翻滚不再被锁轨更新覆盖。
local Route = require "world.Route"
local Accident = {}
local active_,reason_,age_,risk_,strain_,stress_ = false,"",0.0,0.0,0.0,0.0
local speed_,side_ = 0.0,1
---@class DerailmentCar
---@field node Node
---@field origin Vector3
---@field rotation Quaternion
---@field right Vector3
---@field forward Vector3
---@field delay number
---@field yaw number
---@type DerailmentCar[]
local cars_ = {}
function Accident.Reset()
    active_,reason_,age_,risk_,strain_,stress_,speed_=false,"",0,0,0,0,0
    cars_={}
end
---@param cars TrainCar[]
---@param velocity number
---@param reason string
---@param side number?
function Accident.Trigger(cars,velocity,reason,side)
    if active_ then return false end
    active_,reason_,age_,speed_,side_=true,reason,0,math.abs(velocity),side or 1
    cars_={}
    for i,car in ipairs(cars) do
        local rotation=car.node.worldRotation
        cars_[i]={node=car.node,origin=car.node.worldPosition,rotation=rotation,
            right=rotation*Vector3.RIGHT,forward=rotation*Vector3.FORWARD*(velocity<0 and -1 or 1),
            delay=(i-1)*.11,yaw=(i%3-1)*4}
    end
    print(string.format("[Accident] %s：%d节编组进入轨外滑行和倾覆，本局结束",reason,#cars))
    return true
end
---@param dt number
---@param velocity number
---@param maximumKmh number
---@param s number
---@param length number
---@param sample fun(s:number):Vector3,Vector3,number
---@param cars TrainCar[]
function Accident.Evaluate(dt,velocity,maximumKmh,s,length,sample,cars)
    if active_ then return end
    local _,a=sample(s-5)
    local _,b=sample(s+5)
    local turn=math.atan(a:CrossProduct(b).y,a:DotProduct(b))
    local acceleration=velocity*velocity*math.abs(turn)/10
    risk_=acceleration/2.8
    strain_=acceleration>2.8 and strain_+dt or math.max(0,strain_-dt*2)
    stress_=math.abs(velocity)*3.6>maximumKmh*1.35 and stress_+dt or math.max(0,stress_-dt*2)
    if strain_>=.45 then Accident.Trigger(cars,velocity,"弯道侧向加速度过大，轮对脱轨",turn>=0 and -1 or 1)
    elseif stress_>=1 then Accident.Trigger(cars,velocity,"超过车辆结构承受范围，走行部失稳")
    elseif not Route.IsClosed() and (s-length<0 or s+16>Route.GetLength()) then
        Accident.Trigger(cars,velocity,"列车越过线路物理终端，撞端脱轨")
    end
end
---@param dt number
function Accident.Update(dt)
    if active_ then age_=age_+math.max(0,dt) end
end
function Accident.UpdateVisuals()
    if not active_ then return end
    for _,car in ipairs(cars_) do
        local t=math.max(0,age_-car.delay)
        local progress=math.min(1,t/2.4)
        local eased=progress*progress*(3-2*progress)
        local distance=speed_*1.5*(1-math.exp(-t/1.5))
        local roll=side_*eased*(85+car.yaw)
        local rotation=car.rotation*Quaternion(car.yaw*eased,Vector3.UP)*Quaternion(roll,Vector3.FORWARD)
        local lift=1.72*math.sin(math.rad(math.abs(roll)))
        car.node.worldPosition=car.origin+car.forward*distance+car.right*(side_*eased*(5.5+math.min(8,speed_*.06)))+Vector3(0,lift,0)
        car.node.worldRotation=rotation
    end
end
function Accident.GetStatus() return {active=active_,reason=reason_,age=age_,risk=risk_,side=side_,speed=speed_} end
function Accident.IsActive() return active_ end
return Accident
