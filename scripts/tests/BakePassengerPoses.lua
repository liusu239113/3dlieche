-- 仅离线资产序列化：不构建、不发布、不改源MDL；生产仍只加载预烘焙帧。
local Passengers=require "world.Passengers"
local PoseCache=require "world.PassengerPoseCache"
local ROOT="/workspace/assets/PassengerPoses/"
-- 上游Urho3D 1.8 Model.cpp的UMD2元素编码；与两源的72字节头布局交叉核对。
local ELEMENTS={
    TYPE_VECTOR3 | (SEM_POSITION << 8),
    TYPE_VECTOR3 | (SEM_NORMAL << 8),
    TYPE_UBYTE4_NORM | (SEM_COLOR << 8),
    TYPE_VECTOR2 | (SEM_TEXCOORD << 8),
    TYPE_VECTOR4 | (SEM_TANGENT << 8),
}
---@param path string
local function newPath(path)
    assert(path:sub(1,#ROOT)==ROOT and not path:find("..",1,true),"烘焙写路径越界")
    assert(not fileSystem:FileExists(path),"拒绝覆盖已有/来源不明文件："..path)
end
---@param expected Model
---@param actual Model
local function verify(expected,actual)
    assert(actual.numGeometries==1 and actual.numMorphs==0,"回读geometry/morph契约错误")
    assert(actual:GetSkeleton():GetNumBones()==0,"回读重新出现骨架")
    assert(actual:GetNumGeometryLodLevels(0)==2,"回读LOD丢失")
    assert((actual.boundingBox.min-expected.boundingBox.min):Length()<.00001
        and (actual.boundingBox.max-expected.boundingBox.max):Length()<.00001,"回读包络变化")
    assert((actual:GetGeometryCenter(0)-expected:GetGeometryCenter(0)):Length()<.00001,"回读geometry中心变化")
    for level=0,1 do
        local a,b=expected:GetGeometry(0,level),actual:GetGeometry(0,level)
        local av,bv=a:GetVertexBuffer(0),b:GetVertexBuffer(0)
        assert(b.numVertexBuffers==1 and bv.vertexCount==av.vertexCount and bv.vertexSize==52
            and not bv:HasElement(SEM_BLENDWEIGHTS) and not bv:HasElement(SEM_BLENDINDICES),"回读VB布局变化")
        assert(bv:HasElement(TYPE_VECTOR3,SEM_POSITION) and bv:GetElementOffset(SEM_POSITION)==0
            and bv:HasElement(TYPE_VECTOR3,SEM_NORMAL) and bv:GetElementOffset(SEM_NORMAL)==12
            and bv:HasElement(TYPE_UBYTE4_NORM,SEM_COLOR) and bv:GetElementOffset(SEM_COLOR)==24
            and bv:HasElement(TYPE_VECTOR2,SEM_TEXCOORD) and bv:GetElementOffset(SEM_TEXCOORD)==28
            and bv:HasElement(TYPE_VECTOR4,SEM_TANGENT) and bv:GetElementOffset(SEM_TANGENT)==36,
            "回读UMD2元素编码变化")
        local ad,bd=av:GetData(),bv:GetData()
        assert(ad.size==bd.size and ad.checksum==bd.checksum,"回读CPU顶点/UV/切线变化")
        local ai,bi=a:GetIndexBuffer(),b:GetIndexBuffer()
        assert(ai.indexCount==bi.indexCount and ai.indexSize==bi.indexSize,"回读IB布局变化")
        local aid,bid=ai:GetData(),bi:GetData()
        assert(aid.size==bid.size and aid.checksum==bid.checksum,"回读索引变化")
        assert(a.primitiveType==b.primitiveType and a.indexStart==b.indexStart
            and a.indexCount==b.indexCount and a.lodDistance==b.lodDistance,"回读绘制范围/LOD阈值变化")
    end
end
---@param model Model
---@return VectorBuffer
local function serialize(model)
    assert(model.numGeometries==1 and model:GetNumGeometryLodLevels(0)==2,"序列化仅支持已审计双LOD人物")
    local output=VectorBuffer()
    assert(output:WriteFileID("UMD2") and output:WriteUInt(2))
    for level=0,1 do
        local vb=model:GetGeometry(0,level):GetVertexBuffer(0)
        local data=vb:GetData()
        assert(vb.vertexSize==52 and data.size==vb.vertexCount*52,"序列化VB镜像错误")
        assert(output:WriteUInt(vb.vertexCount) and output:WriteUInt(#ELEMENTS))
        for _,element in ipairs(ELEMENTS) do assert(output:WriteUInt(element)) end
        assert(output:WriteUInt(0) and output:WriteUInt(0)) -- 无morph范围
        assert(output:Write(data)==data.size)
    end
    assert(output:WriteUInt(2))
    for level=0,1 do
        local ib=model:GetGeometry(0,level):GetIndexBuffer()
        local data=ib:GetData()
        assert((ib.indexSize==2 or ib.indexSize==4) and data.size==ib.indexCount*ib.indexSize,"序列化IB镜像错误")
        assert(output:WriteUInt(ib.indexCount) and output:WriteUInt(ib.indexSize))
        assert(output:Write(data)==data.size)
    end
    assert(output:WriteUInt(1) and output:WriteUInt(0) and output:WriteUInt(2)) -- 单geometry，无骨映射，双LOD
    for level=0,1 do
        local geom=model:GetGeometry(0,level)
        assert(output:WriteFloat(geom.lodDistance) and output:WriteUInt(geom.primitiveType))
        assert(output:WriteUInt(level) and output:WriteUInt(level)) -- VB/IB引用均从0开始
        assert(output:WriteUInt(geom.indexStart) and output:WriteUInt(geom.indexCount))
    end
    assert(output:WriteUInt(0) and output:WriteUInt(0)) -- 无morph，无bone
    assert(output:WriteBoundingBox(model.boundingBox) and output:WriteVector3(model:GetGeometryCenter(0)))
    -- 两款源在标准bbox+center之后均有10个零字节；仅兼容占位，未解释为公开格式字段。
    -- 候选必须通过官方Load和完整回读；最终仍由官方Model:Save输出。
    for _=1,10 do assert(output:WriteUByte(0)) end
    return output
end
---@param model Model
---@param path string
---@param checkpoint boolean
local function save(model,path,checkpoint)
    local candidate=path..".candidate.mdl"
    newPath(path)
    newPath(candidate)
    if checkpoint then print("[烘焙检查点] 首帧UMD2候选序列化前："..candidate) end
    local bytes=serialize(model)
    local file=File(candidate,FILE_WRITE)
    assert(file:IsOpen(),"候选文件创建失败："..candidate)
    local written=file:Write(bytes)
    file:Dispose()
    assert(written==bytes.size,"候选文件写入不完整")
    if checkpoint then print("[烘焙检查点] 首帧候选写完，官方Model:Load前") end
    local loaded=Model()
    assert(loaded:Load(candidate),"候选官方Load失败："..candidate)
    verify(model,loaded)
    if checkpoint then print("[烘焙检查点] 首帧候选官方Load/完整校验完成，官方Save前") end
    newPath(path)
    assert(loaded:Save(path),"官方Model:Save失败："..path)
    if checkpoint then print("[烘焙检查点] 首帧官方Save完成，最终Load前") end
    local final=Model()
    assert(final:Load(path),"最终帧官方Load失败："..path)
    verify(model,final)
    final:Dispose()
    loaded:Dispose()
    assert(fileSystem:Delete(candidate),"已校验候选清理失败："..candidate)
    if checkpoint then print("[烘焙检查点] 首帧最终官方Load/完整回读校验完成") end
end
function Start()
    print("[烘焙检查点] 进入BakePassengerPoses.Start")
    local ok,err=pcall(function()
        -- 所有候选/最终路径预检，再开始任何资产写入；已有文件一律不覆盖。
        for _,relative in ipairs(PoseCache.GetResourcePaths()) do
            local path="/workspace/assets/"..relative
            newPath(path)
            newPath(path..".candidate.mdl")
        end
        for kind=1,2 do
            local folder=ROOT..(kind==1 and "male" or "female")
            assert(fileSystem:CreateDir(folder),"离线资源目录创建失败")
            print(string.format("[烘焙检查点] 款式%d 输出目录完成，BakeOffline前",kind))
            local set=Passengers.BakeOffline(kind)
            for frame,model in ipairs(set.frames) do
                save(model,folder..string.format("/walk_%02d.mdl",frame-1),frame==1)
            end
            save(set.idle,folder.."/idle.mdl",false)
            print(string.format("[人物离线烘焙] 款式%d，25帧/双LOD，GPU=%d字节；候选Load+官方Save+最终Load全部校验一致",kind,set.vertexBytes))
            PoseCache.Dispose(set)
        end
        print("PASSENGER_BAKE_PASS：两款共50帧已完整回读验证；尚未构建或手机验收")
    end)
    if not ok then log:Write(LOG_ERROR,"[人物离线烘焙失败] "..tostring(err)) end
    -- 公开Engine:Exit无退出码参数；失败依LOG_ERROR且绝不打印PASS，不能把exit0当成功。
    engine:Exit()
end
