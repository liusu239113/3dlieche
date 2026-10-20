-- Light API实测探针，不读/写玩家存档；输出cone默认值后退出。
function Start()
    local scene=Scene()
    local node=scene:CreateChild("Probe")
    local light=node:CreateComponent("Light")
    light.lightType=LIGHT_SPOT
    print(string.format("NIGHT_CONE_DEFAULT fov=%.2f inner=%.2f outer=%.2f physical=%s punctual=%s mask=%s",
        light.fov,light.innerConeAngle,light.outerConeAngle,tostring(light.usePhysicalValues),tostring(light.punctualLight),tostring(light.lightMask)))
    light.fov=140
    print(string.format("NIGHT_CONE_FOV140 fov=%.2f inner=%.2f outer=%.2f",light.fov,light.innerConeAngle,light.outerConeAngle))
    light.outerConeAngle=70
    light.innerConeAngle=45
    print(string.format("NIGHT_CONE_EXPLICIT fov=%.2f inner=%.2f outer=%.2f",light.fov,light.innerConeAngle,light.outerConeAngle))
    print("NIGHT_GPU compute="..tostring(graphics:GetComputeShaderSupport()))
    scene:Dispose()
    engine:Exit()
end
