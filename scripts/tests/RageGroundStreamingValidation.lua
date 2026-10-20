-- 高速动态回归：不碰存档/云，不通过限速或暂停让地形追赶。
-- 生产WorldStream完成加载后按592/936/1223km/h连续推进，检查实际提交的地面三角形。
local Modes=require "config.GameModes"
local Config=require "config.GameConfig"
local Route=require "world.Route"
local Stream=require "world.WorldStream"
local Mountain=require "world.MountainProfile"
---@type Scene?
local scene_=nil
local checks_,samples_,holes_=0,0,0
local maxUpdateMs_=0.0
local visual_=false
---@type Node?
local camera_=nil
local frames_=0
local visualS_=7000.0
local failed_=false
for _,arg in ipairs(GetArguments()) do if arg=="-ground-visual" then visual_=true end end
local function check(value,message)
    checks_=checks_+1
    assert(value,"[RageGround] "..message)
end
-- 用XZ三角重心查询真正上传的顶点，不把解析高程函数或ready标志当成覆盖证明。
local function heightAt(node,x,z)
    for _,mesh in ipairs(node:GetComponents("CustomGeometry",true)) do
        if mesh.enabled then
            for slot=0,mesh.numGeometries-1 do
                for i=0,mesh:GetNumVertices(slot)-3,3 do
                    local a=mesh:GetVertex(slot,i).position
                    local b=mesh:GetVertex(slot,i+1).position
                    local c=mesh:GetVertex(slot,i+2).position
                    local det=(b.z-c.z)*(a.x-c.x)+(c.x-b.x)*(a.z-c.z)
                    if math.abs(det)>1e-8 then
                        local u=((b.z-c.z)*(x-c.x)+(c.x-b.x)*(z-c.z))/det
                        local v=((c.z-a.z)*(x-c.x)+(a.x-c.x)*(z-c.z))/det
                        if u>=-1e-5 and v>=-1e-5 and u+v<=1.00001 then
                            return a.y*u+b.y*v+c.y*(1-u-v)
                        end
                    end
                end
            end
        end
    end
    return nil
end
local function coverage(root,s)
    local size=Config.WorldStream.TerrainCellSize
    for _,offset in ipairs({-120,-40,25,120}) do
        local p=Route.SampleOffset(s,offset,0)
        local x,z=math.floor(p.x/size),math.floor(p.z/size)
        local tile=root:GetChild("ground_"..x.."_"..z)
        samples_=samples_+1
        if not tile or not tile.enabled then holes_=holes_+1;error("[RageGround] 高速核心地面缺失 s="..s.." lateral="..offset) end
        local y=heightAt(tile,p.x,p.z)
        check(y~=nil,"真实地面网格未覆盖采样点")
        -- 结构接管区仍保留真实下降的谷底，不把桥谷抬到轨面。
        local expected=Mountain.GetGroundHeight(p.x,p.z)
        check(math.abs(assert(y)+.04-expected)<3.0,"基础面与20m高程偏离")
    end
end
local function run()
    Modes.Apply("rage");Route.Build()
    scene_=Scene();scene_:CreateComponent("Octree")
    local root=Stream.Build(scene_,7000)
    if visual_ then
        renderer.drawShadows=false
        -- 离屏验收只用颜色环境光与太阳，不加载依赖编辑器暗角贴图的预设。
        local zone=scene_:CreateComponent("Zone")
        zone.boundingBox=BoundingBox(Vector3(-100000,-2000,-100000),Vector3(100000,5000,100000))
        zone.ambientSource=AMBIENT_COLOR
        zone.ambientColor=Color(.55,.60,.68)
        zone.fogColor=Color(.64,.76,.87)
        zone:SetAttribute("Bloom Enable",Variant(false))
        zone.depthFogStart=1400;zone.depthFogEnd=2600
        local sunNode=scene_:CreateChild("验收太阳")
        sunNode.direction=Vector3(.3,-.8,.4)
        local sun=sunNode:CreateComponent("Light")
        sun.lightType=LIGHT_DIRECTIONAL;sun.brightness=1.2;sun.castShadows=false
        camera_=scene_:CreateChild("高速地表验收相机")
        local camera=camera_:CreateComponent("Camera")
        camera.nearClip=.2;camera.farClip=2600;camera.fov=65;camera.viewMask=3
        renderer:SetViewport(0,Viewport:new(scene_,camera))
        SubscribeToEvent("Update","HandleGroundVisualUpdate")
        SubscribeToEvent("EndRendering","HandleGroundVisualCapture")
        return
    end
    local initial=Stream.GetStats()
    check(initial.permanentGroundChunks>1000,"没有全线核心地面")
    check(initial.mountainBackdropChunks==0,"狂暴仍重复生成昂贵的远景地面")
    local core=initial.permanentGroundChunks
    -- 全线跨站场/桥隧/回头弯；不先静止drain任何新窗口。
    for s=0,Route.GetLength(),317 do coverage(root,s) end
    for _,kmh in ipairs({592,936,1223}) do
        local s=6500.0
        local dt=1/30
        for frame=1,180 do
            s=s+kmh/3.6*dt
            local before=os.clock();Stream.Update(s,dt)
            maxUpdateMs_=math.max(maxUpdateMs_,(os.clock()-before)*1000)
            if frame%6==0 then coverage(root,s);coverage(root,s+400);coverage(root,s+1200) end
        end
        check(Stream.GetStats().permanentGroundChunks==core,"高速卸载错误回收核心地面")
        print(string.format("RAGE_GROUND_SPEED_PASS kmh=%d frames=180 samples=%d holes=%d",kmh,samples_,holes_))
    end
    -- 长距离跳转、反向高速和细节卸载后仍有地面；不限位移/速度。
    for _,s in ipairs({78000,109000,45000,7000,0,Route.GetLength()}) do
        Stream.Update(s,.1);coverage(root,s)
    end
    local stats=Stream.GetStats()
    check(stats.groundSlices>0,"基础面独立通道未工作")
    print(string.format("ALL_RAGE_GROUND_PASS checks=%d samples=%d holes=%d coreTiles=%d groundSlices=%d maxUpdateMs=%.3f startupMs=%.3f speedLimited=false pauseDrain=false",
        checks_,samples_,holes_,core,stats.groundSlices,maxUpdateMs_,stats.startupMs))
end
local function cleanup()
    Stream.Shutdown()
    if scene_ then scene_:Dispose();scene_=nil end
end
function Start()
    local ok,message=xpcall(run,debug.traceback)
    if visual_ and ok then return end
    cleanup()
    if not ok then log:Write(LOG_ERROR,tostring(message)) end
    engine:Exit()
end
function HandleGroundVisualUpdate()
    if failed_ then return end
    local ok,message=xpcall(function()
        frames_=frames_+1
        visualS_=visualS_+1223/3.6/30
        Stream.Update(visualS_,1/30)
        local node=assert(camera_)
        node.position=Route.SampleOffset(visualS_-100,65,38)
        node:LookAt(Route.SampleOffset(visualS_+500,0,2))
    end,debug.traceback)
    if not ok then failed_=true;log:Write(LOG_ERROR,tostring(message));cleanup();engine:Exit() end
end
function HandleGroundVisualCapture()
    if failed_ or frames_<60 then return end
    local ok,message=xpcall(function()
        local image=Image()
        if not graphics:TakeScreenShot(image) then
            image:Dispose()
            -- GLES读回可延迟一帧；重试期间仍持续1223km/h，不静止等待地形。
            check(frames_<66,"六次真实地表截图读取失败")
            return
        end
        local saved=image:SavePNG("/workspace/screenshots/rage_ground_1223.png")
        image:Dispose()
        check(saved,"真实地表截图保存失败")
        print(string.format("RAGE_GROUND_REAL_FRAME_PASS speedKmh=1223 frames=%d pauseDrain=false",frames_))
        cleanup();engine:Exit()
    end,debug.traceback)
    if not ok then failed_=true;log:Write(LOG_ERROR,tostring(message));cleanup();engine:Exit() end
end
function Stop() cleanup() end
