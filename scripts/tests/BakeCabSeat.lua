-- 显式离线派生座椅，复用BakeRollingStock脚手架；main不引用本入口。
-- 保留源模型四级LOD的上部顶点/法线/UV/切线，仅删除实测座面下方的办公椅底盘。
-- 新固定柱座在生产CabInterior中单独构建。原MDL/贴图不覆盖、不修改。
local SOURCE="model/80a31768-83df-5130-a748-31dd300add62/Meshes/cf8c3e36a7e24a518e2330f10a56d5cb.mdl"
local OUTPUT="/workspace/assets/CabDetails/FixedSeatUpper.mdl"

function Start()
    local ok,message=xpcall(function()
        assert(not fileSystem:FileExists(OUTPUT),"不覆盖既有派生座椅")
        if not fileSystem:DirExists("/workspace/assets/CabDetails/") then
            assert(fileSystem:CreateDir("/workspace/assets/CabDetails/"))
        end
        local original=assert(cache:GetResource("Model",SOURCE))
        local sourceBox=original.boundingBox
        -- 源点云实测：轮/五爪底盘0..0.18；升降杆0.23..0.33；完整座面从0.36开始。
        -- 0.34位于独立底盘与座面间隙，既移除轮底，也不裁靠背/扶手/座面。
        local cut=sourceBox.min.y+sourceBox.size.y*.34
        local model=original:Clone()
        local bounds=BoundingBox()
        local buffers={}
        for slot=0,original.numGeometries-1 do
            local levels=original:GetNumGeometryLodLevels(slot)
            assert(levels==4,"源座椅缺四级LOD")
            for lod=0,levels-1 do
                local source=assert(original:GetGeometry(slot,lod))
                assert(source.primitiveType==TRIANGLE_LIST)
                local vb=assert(source:GetVertexBuffer(0))
                local vertices=vb:GetData()
                local positions={}
                local positionOffset=vb:GetElementOffset(SEM_POSITION)
                for i=0,vb.vertexCount-1 do
                    vertices:Seek(i*vb.vertexSize+positionOffset)
                    positions[i+1]=vertices:ReadVector3()
                end
                local oldIB=assert(source:GetIndexBuffer())
                local indices=oldIB:GetData()
                indices:Seek(source.indexStart*oldIB.indexSize)
                local data=VectorBuffer()
                local count,removed=0,0
                for _=1,source.indexCount//3 do
                    local a=oldIB.indexSize==2 and indices:ReadUShort() or indices:ReadUInt()
                    local b=oldIB.indexSize==2 and indices:ReadUShort() or indices:ReadUInt()
                    local c=oldIB.indexSize==2 and indices:ReadUShort() or indices:ReadUInt()
                    local p,q,r=assert(positions[a+1]),assert(positions[b+1]),assert(positions[c+1])
                    if math.min(p.y,q.y,r.y)>=cut then
                        data:WriteUInt(a);data:WriteUInt(b);data:WriteUInt(c)
                        count=count+3
                        bounds:Merge(p);bounds:Merge(q);bounds:Merge(r)
                    else removed=removed+1 end
                end
                assert(count>source.indexCount*.5 and removed>0,"裁剪丢失过多上部或未移除轮底")
                local ib=IndexBuffer()
                ib.shadowed=true
                assert(ib:SetSize(count,true));assert(ib:SetData(data))
                buffers[#buffers+1]=ib
                local geometry=Geometry()
                assert(geometry:SetNumVertexBuffers(source.numVertexBuffers))
                for i=0,source.numVertexBuffers-1 do assert(geometry:SetVertexBuffer(i,source:GetVertexBuffer(i))) end
                geometry:SetIndexBuffer(ib)
                assert(geometry:SetDrawRange(TRIANGLE_LIST,0,count))
                geometry.lodDistance=source.lodDistance
                assert(model:SetGeometry(slot,lod,geometry))
                print(string.format("[BakeCabSeat] lod=%d triangles=%d->%d cutY=%.6f upperVerticesPreserved=true",
                    lod,source.indexCount//3,count//3,cut))
            end
        end
        model.boundingBox=bounds
        assert(model:Save(OUTPUT),"派生座椅保存失败")
        local loaded=Model()
        assert(loaded:Load(OUTPUT),"派生座椅读回失败")
        for slot=0,model.numGeometries-1 do
            assert(loaded:GetNumGeometryLodLevels(slot)==4)
            for lod=0,3 do
                local expected,actual=model:GetGeometry(slot,lod),loaded:GetGeometry(slot,lod)
                assert(expected.indexCount==actual.indexCount,"读回座椅索引变化")
                assert(expected:GetVertexBuffer(0):GetData().checksum==actual:GetVertexBuffer(0):GetData().checksum,"上部顶点/UV读回变化")
                assert(expected:GetIndexBuffer():GetData().checksum==actual:GetIndexBuffer():GetData().checksum,"索引读回变化")
            end
        end
        assert((loaded.boundingBox.min-bounds.min):Length()<.00001)
        print(string.format("ALL_FIXED_SEAT_BAKE_PASS lods=4 size=%.5f/%.5f/%.5f originalUnmodified=true",bounds.size.x,bounds.size.y,bounds.size.z))
        loaded:Dispose();model:Dispose()
    end,debug.traceback)
    if not ok then log:Write(LOG_ERROR,tostring(message)) end
    engine:Exit()
end
