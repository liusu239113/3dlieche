-- 共享模型局部空间CPU蒙皮缓存：生产读取离线帧，不上传GPU骨矩阵。
-- 输入明确为程序化行走clip而非动捕；CPU烘焙仅用于tests离线入口。
local PoseCache = {}
local FRAME_COUNT = 24
-- 完整字面量供官方构建器收集资源引用；不能仅靠运行时拼接文件名。
local RESOURCE_PATHS={
    {
        "PassengerPoses/male/idle.mdl",
        "PassengerPoses/male/walk_00.mdl","PassengerPoses/male/walk_01.mdl",
        "PassengerPoses/male/walk_02.mdl","PassengerPoses/male/walk_03.mdl",
        "PassengerPoses/male/walk_04.mdl","PassengerPoses/male/walk_05.mdl",
        "PassengerPoses/male/walk_06.mdl","PassengerPoses/male/walk_07.mdl",
        "PassengerPoses/male/walk_08.mdl","PassengerPoses/male/walk_09.mdl",
        "PassengerPoses/male/walk_10.mdl","PassengerPoses/male/walk_11.mdl",
        "PassengerPoses/male/walk_12.mdl","PassengerPoses/male/walk_13.mdl",
        "PassengerPoses/male/walk_14.mdl","PassengerPoses/male/walk_15.mdl",
        "PassengerPoses/male/walk_16.mdl","PassengerPoses/male/walk_17.mdl",
        "PassengerPoses/male/walk_18.mdl","PassengerPoses/male/walk_19.mdl",
        "PassengerPoses/male/walk_20.mdl","PassengerPoses/male/walk_21.mdl",
        "PassengerPoses/male/walk_22.mdl","PassengerPoses/male/walk_23.mdl",
    },
    {
        "PassengerPoses/female/idle.mdl",
        "PassengerPoses/female/walk_00.mdl","PassengerPoses/female/walk_01.mdl",
        "PassengerPoses/female/walk_02.mdl","PassengerPoses/female/walk_03.mdl",
        "PassengerPoses/female/walk_04.mdl","PassengerPoses/female/walk_05.mdl",
        "PassengerPoses/female/walk_06.mdl","PassengerPoses/female/walk_07.mdl",
        "PassengerPoses/female/walk_08.mdl","PassengerPoses/female/walk_09.mdl",
        "PassengerPoses/female/walk_10.mdl","PassengerPoses/female/walk_11.mdl",
        "PassengerPoses/female/walk_12.mdl","PassengerPoses/female/walk_13.mdl",
        "PassengerPoses/female/walk_14.mdl","PassengerPoses/female/walk_15.mdl",
        "PassengerPoses/female/walk_16.mdl","PassengerPoses/female/walk_17.mdl",
        "PassengerPoses/female/walk_18.mdl","PassengerPoses/female/walk_19.mdl",
        "PassengerPoses/female/walk_20.mdl","PassengerPoses/female/walk_21.mdl",
        "PassengerPoses/female/walk_22.mdl","PassengerPoses/female/walk_23.mdl",
    },
}
local VERTEX_BYTES = 52 -- 位置/法线/颜色/UV/切线；刻意移除blend属性
---@class PassengerBakeVertex
---@field position Vector3
---@field normal Vector3
---@field color integer
---@field uv Vector2
---@field tangent Vector4
---@field weights number[]
---@field indices number[]
---@class PassengerBakeLod
---@field vertices PassengerBakeVertex[]
---@field source Geometry
---@class PassengerBakedSet
---@field frames Model[]
---@field idle Model
---@field buffers VertexBuffer[]
---@field vertexBytes integer
---@field indexBytes integer? # 生产Load缓存的去重IB载荷
---@field shadowBytes integer? # 生产Load按IsShadowed缓存的去重VB+IB镜像载荷
---@field sourceBones integer
---@field bounds BoundingBox
---@field lodLevels integer
---@field cached boolean?
---@param source Model
---@return PassengerBakeLod[]
local function readLods(source)
    assert(source.numGeometries==1,"乘客CPU缓存仅支持已审计的单geometry资源")
    local levels=source:GetNumGeometryLodLevels(0)
    local result={} ---@type PassengerBakeLod[]
    -- 保留近景细节和远景低模；全部四LOD的25帧会增加不必要内存。
    for _,level in ipairs({0,levels-1}) do
        local geom=source:GetGeometry(0,level)
        local vb=geom:GetVertexBuffer(0)
        assert(vb.vertexSize==72 and vb:GetElementOffset(SEM_BLENDWEIGHTS)==52
            and vb:GetElementOffset(SEM_BLENDINDICES)==68,"乘客VB布局变化，拒绝按错误offset读取")
        assert(vb:HasElement(TYPE_VECTOR4,SEM_BLENDWEIGHTS)
            and vb:HasElement(TYPE_UBYTE4,SEM_BLENDINDICES),"乘客骨索引必须为非归一化UBYTE4")
        local data=vb:GetData()
        assert(data.size==vb.vertexCount*72,"乘客CPU源顶点镜像缺失")
        local vertices={} ---@type PassengerBakeVertex[]
        for _=1,vb.vertexCount do
            local position,normal=data:ReadVector3(),data:ReadVector3()
            local color=data:ReadUInt()
            local uv,tangent=data:ReadVector2(),data:ReadVector4()
            local weights={data:ReadFloat(),data:ReadFloat(),data:ReadFloat(),data:ReadFloat()}
            local indices={data:ReadUByte(),data:ReadUByte(),data:ReadUByte(),data:ReadUByte()}
            local sum=0
            for j=1,4 do
                assert(weights[j]>=0 and weights[j]<=1 and indices[j]<source:GetSkeleton():GetNumBones(),
                    "乘客CPU源权重/骨索引无效")
                sum=sum+weights[j]
            end
            assert(math.abs(sum-1)<.00001,"乘客CPU源权重不归一")
            vertices[#vertices+1]={position=position,normal=normal,color=color,uv=uv,
                tangent=tangent,weights=weights,indices=indices}
        end
        result[#result+1]={vertices=vertices,source=geom}
    end
    return result
end
---@param animation Animation
---@param name string
---@param time number
---@param fallback Quaternion
---@return Quaternion
local function sampleRotation(animation,name,time,fallback)
    local track=animation:GetTrack(name)
    if not track or track:GetNumKeyFrames()==0 then return fallback end
    assert(track.channelMask==CHANNEL_ROTATION,"乘客程序化clip不应包含未经实现的位置/缩放通道")
    local previous=track:GetKeyFrame(0)
    for k=1,track:GetNumKeyFrames()-1 do
        local next=track:GetKeyFrame(k)
        if time<=next.time then
            local span=next.time-previous.time
            return previous.rotation:Slerp(next.rotation,span>0 and (time-previous.time)/span or 0)
        end
        previous=next
    end
    return previous.rotation
end
---@param source Model
---@param animation Animation
---@param time number
---@return Matrix3x4[]
local function skinMatrices(source,animation,time)
    local skeleton=source:GetSkeleton()
    local world={} ---@type table<number,Matrix3x4>
    local skin={} ---@type Matrix3x4[]
    for i=0,skeleton:GetNumBones()-1 do
        local bone=skeleton:GetBone(i)
        local rotation=sampleRotation(animation,bone.name,time,bone.initialRotation)
        local localTransform=Matrix3x4(bone.initialPosition,rotation,bone.initialScale)
        -- MDL骨索引从0开始，根骨的parent指向自身。
        -- 两资源均有公共导入旋转，不可假定bindWorld*offset恒等。
        world[i]=bone.parentIndex==i and localTransform or assert(world[bone.parentIndex])*localTransform
        skin[i+1]=world[i]*bone.offsetMatrix
    end
    return skin
end
---@param matrix Matrix3x4
---@param vector Vector3
---@return Vector3
local function direction(matrix,vector)
    return Vector3(matrix.m00*vector.x+matrix.m01*vector.y+matrix.m02*vector.z,
        matrix.m10*vector.x+matrix.m11*vector.y+matrix.m12*vector.z,
        matrix.m20*vector.x+matrix.m21*vector.y+matrix.m22*vector.z)
end
---@param source Model
---@param animation Animation
---@return PassengerBakedSet
function PoseCache.Build(source,animation)
    print("[烘焙检查点] Build读取LOD前："..source.name)
    local lods=readLods(source)
    print(string.format("[烘焙检查点] Build读LOD完成：%d个LOD，近%d/远%d顶点",#lods,#lods[1].vertices,#lods[2].vertices))
    local set={frames={},idle=Model(),buffers={},vertexBytes=0,sourceBones=source:GetSkeleton():GetNumBones(),
        bounds=BoundingBox(),lodLevels=#lods} --[[@as PassengerBakedSet]]
    local elements={VertexElement(TYPE_VECTOR3,SEM_POSITION),VertexElement(TYPE_VECTOR3,SEM_NORMAL),
        VertexElement(TYPE_UBYTE4_NORM,SEM_COLOR),VertexElement(TYPE_VECTOR2,SEM_TEXCOORD),
        VertexElement(TYPE_VECTOR4,SEM_TANGENT)}
    for frame=0,FRAME_COUNT do
        if frame==0 then print("[烘焙检查点] 首帧骨矩阵计算前") end
        local skin=skinMatrices(source,animation,(frame%FRAME_COUNT)/FRAME_COUNT*animation.length)
        if frame==0 then print(string.format("[烘焙检查点] 首帧骨矩阵完成：%d骨",#skin)) end
        local baked=frame==FRAME_COUNT and set.idle or Model()
        baked:AddMetadata("PassengerSourceModel",Variant(source.name))
        baked:AddMetadata("PassengerPoseFrame",Variant(frame))
        baked.numGeometries=1
        assert(baked:SetNumGeometryLodLevels(0,#lods))
        local bounds=BoundingBox()
        for level,lod in ipairs(lods) do
            local output=VectorBuffer()
            for _,vertex in ipairs(lod.vertices) do
                -- 始终在模型局部空间进行CPU运算，避免5–30km站点平移进入骨矩阵。
                local combined=Matrix3x4.ZERO
                for j=1,4 do
                    local weighted=skin[vertex.indices[j]+1]*vertex.weights[j]
                    local sum=combined+weighted
                    combined=sum
                end
                local p=combined*vertex.position
                assert(p.x==p.x and p.y==p.y and p.z==p.z and p:Length()<3,"乘客CPU蒙皮超出安全包络")
                local n=direction(combined,vertex.normal):Normalized()
                local t=direction(combined,Vector3(vertex.tangent.x,vertex.tangent.y,vertex.tangent.z)):Normalized()
                output:WriteVector3(p)
                output:WriteVector3(n)
                output:WriteUInt(vertex.color)
                output:WriteVector2(vertex.uv)
                output:WriteVector4(Vector4(t.x,t.y,t.z,vertex.tangent.w))
                bounds:Merge(p)
            end
            if frame==0 and level==1 then
                print(string.format("[烘焙检查点] 首VB数据写完：%d字节，SetSize前",output.size))
            end
            local vb=VertexBuffer()
            vb.shadowed=true -- 支持设备恢复；镜像占用已计入内存预算
            assert(vb:SetSize(#lod.vertices,elements,false))
            if frame==0 and level==1 then print("[烘焙检查点] 首VB SetSize完成，SetData前") end
            assert(vb:SetData(output))
            if frame==0 and level==1 then print("[烘焙检查点] 首VB SetData完成") end
            assert(not vb:HasElement(SEM_BLENDWEIGHTS) and not vb:HasElement(SEM_BLENDINDICES))
            local geom=Geometry()
            assert(geom:SetVertexBuffer(0,vb))
            geom:SetIndexBuffer(lod.source:GetIndexBuffer()) -- 只读源IB，全帧共享
            assert(geom:SetDrawRange(lod.source.primitiveType,lod.source.indexStart,lod.source.indexCount))
            geom.lodDistance=level==1 and 0 or 40
            assert(baked:SetGeometry(0,level-1,geom))
            set.buffers[#set.buffers+1]=vb
            set.vertexBytes=set.vertexBytes+#lod.vertices*VERTEX_BYTES
        end
        -- 此临时Model只承载已计算的geometry，不直接Save。
        -- SetVertexBuffers的Lua table入口已实测原生退出；离线Bake序列化后由官方Load登记缓冲。
        baked.boundingBox=bounds
        assert(baked:SetGeometryCenter(0,bounds.center))
        if frame==0 then print("[烘焙检查点] 首帧CPU几何完成；跳过不可用的Model缓冲数组setter") end
        set.bounds:Merge(bounds)
        if frame<FRAME_COUNT then set.frames[frame+1]=baked end
    end
    print(string.format("[乘客CPU] %s 周期帧=%d+静止帧 LOD=%d GPU=%d 镜像=%d字节（共享）",
        source.name,FRAME_COUNT,#lods,set.vertexBytes,set.vertexBytes))
    return set
end
---@param set PassengerBakedSet
---@param walking boolean
---@param distance number
---@return Model, integer
function PoseCache.Select(set,walking,distance)
    local index=math.floor((distance/1.25%1)*FRAME_COUNT)+1
    return walking and set.frames[index] or set.idle,walking and index or 0
end
---@param kind integer
---@return PassengerBakedSet
function PoseCache.Load(kind)
    local paths=assert(RESOURCE_PATHS[kind],"未知人物预烘焙款式")
    local set={frames={},idle=assert(cache:GetResource("Model",paths[1]),"缺少离线乘客静止帧"),
        buffers={},vertexBytes=0,indexBytes=0,shadowBytes=0,sourceBones=41,
        bounds=BoundingBox(),lodLevels=2,cached=true} --[[@as PassengerBakedSet]]
    -- 仅初始化时读取真实缓冲对象及shadow状态；载荷不是实际驱动显存/RSS，且不含源模型/贴图/对象开销。
    local seenVertexBuffers={} ---@type table<VertexBuffer,boolean>
    local seenIndexBuffers={} ---@type table<IndexBuffer,boolean>
    for frame=0,FRAME_COUNT-1 do
        set.frames[frame+1]=assert(cache:GetResource("Model",paths[frame+2]),
            "缺少离线乘客帧；不允许在手机启动时执行CPU烘焙")
    end
    local all={set.idle,table.unpack(set.frames)}
    local expectedVertices=kind==1 and {3386,1782} or {6672,3017}
    for _,model in ipairs(all) do
        assert(model:GetSkeleton():GetNumBones()==0 and model:GetNumGeometryLodLevels(0)==2,
            "离线人物帧不符合无骨架/双LOD契约")
        local size=model.boundingBox.size
        assert(size.x>0 and size.y>.5 and size.z>0 and size.x<2 and size.y<2 and size.z<2,
            "离线人物实际包络无效")
        set.bounds:Merge(model.boundingBox)
        for level=0,1 do
            local geom=model:GetGeometry(0,level)
            local vb=geom:GetVertexBuffer(0)
            assert(vb.vertexSize==VERTEX_BYTES and vb.vertexCount==expectedVertices[level+1]
                and not vb:HasElement(SEM_BLENDINDICES) and not vb:HasElement(SEM_BLENDWEIGHTS),
                "离线人物近/远LOD顶点布局或款式契约错误")
            assert(geom.lodDistance==(level==0 and 0 or 40),"离线人物LOD距离契约错误")
            if not seenVertexBuffers[vb] then
                seenVertexBuffers[vb]=true
                local bytes=vb.vertexCount*vb.vertexSize
                set.vertexBytes=set.vertexBytes+bytes
                if vb:IsShadowed() then set.shadowBytes=(set.shadowBytes or 0)+bytes end
            end
            local ib=geom:GetIndexBuffer()
            if not seenIndexBuffers[ib] then
                seenIndexBuffers[ib]=true
                local bytes=ib.indexCount*ib.indexSize
                set.indexBytes=(set.indexBytes or 0)+bytes
                if ib:IsShadowed() then set.shadowBytes=(set.shadowBytes or 0)+bytes end
            end
        end
    end
    return set
end
---@return string[]
function PoseCache.GetResourcePaths()
    local paths={} ---@type string[]
    for _,kind in ipairs(RESOURCE_PATHS) do
        for _,path in ipairs(kind) do paths[#paths+1]=path end
    end
    return paths
end
---@param set PassengerBakedSet
function PoseCache.Dispose(set)
    if set.cached then return end -- cache拥有预烘焙资源，不可由人物模块释放
    for _,model in ipairs(set.frames) do model:Dispose() end
    set.idle:Dispose()
    for _,buffer in ipairs(set.buffers) do buffer:Dispose() end
end
return PoseCache
