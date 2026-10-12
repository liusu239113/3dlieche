-- 局部侧壳覆盖补集，不替换原车体。D18沿原同侧UV补上侧缺面。
-- E32仅补+X中央缺面，使用原创架空侧板；原门窗/凸门板投影均已扣除。
local Repairs = {}
---@type table<string, Model>
local models_ = {}
local subscribed_ = false
local PATCH_NAME = "BodyShellRepair"

---@class BodyShellPatchData
---@field version integer
---@field status string
---@field sourceTriangle integer
---@field side integer
---@field vertices number[][]

---@param id string
---@return Model?
function Repairs.GetModel(id)
    if id ~= "DF4D" and id ~= "HXD3D" then return nil end
    if models_[id] then return models_[id] end
    -- Literal resource reference is intentional: build must include the patch.
    local path=id=="DF4D" and "RollingStockBaked/DF4D_body_shell_patch.json"
        or "RollingStockBaked/HXD3D_body_shell_patch.json"
    local file = assert(cache:GetFile(path), "缺少局部补壳")
    local data = cjson.decode(file:ReadLine()) --[[@as BodyShellPatchData]]
    file:Close()
    assert(data.version == 1 and data.status == "partial")
    assert(id=="DF4D" and data.side==-1 and data.sourceTriangle==29
        or id=="HXD3D" and data.side==1 and data.sourceTriangle==-1)
    assert(#data.vertices > 0 and #data.vertices % 3 == 0 and #data.vertices < 65536)
    local vb, ib, geometry = VertexBuffer:new(), IndexBuffer:new(), Geometry:new()
    vb.shadowed, ib.shadowed = true, true
    assert(vb:SetSize(#data.vertices, {
        VertexElement(TYPE_VECTOR3, SEM_POSITION),
        VertexElement(TYPE_VECTOR3, SEM_NORMAL),
        VertexElement(TYPE_VECTOR4, SEM_TANGENT),
        VertexElement(TYPE_VECTOR2, SEM_TEXCOORD),
    }))
    assert(ib:SetSize(#data.vertices, false))
    local vertices, indices, bounds = VectorBuffer(), VectorBuffer(), BoundingBox()
    for i, row in ipairs(data.vertices) do
        assert(#row == 12, "局部补壳顶点格式错误")
        local p = Vector3(row[1], row[2], row[3])
        local valid=id=="DF4D" and p.x < -1.3 and p.x > -1.6 and p.y >= 3.48-.00001 and p.y <= 4.025+.00001
            and p.z >= .18-.00001 and p.z <= 7.5+.00001
            or id=="HXD3D" and math.abs(p.x-1.425)<.00001 and p.y>=1.88-.00001 and p.y<=4.30+.00001
            and p.z>=-7.45-.00001 and p.z<=7.05+.00001
        assert(valid, "补壳越出已验证ROI")
        vertices:WriteVector3(p)
        vertices:WriteVector3(Vector3(row[4], row[5], row[6]))
        vertices:WriteVector4(Vector4(row[7], row[8], row[9], row[10]))
        vertices:WriteVector2(Vector2(row[11], row[12]))
        indices:WriteUShort(i-1)
        bounds:Merge(p)
    end
    assert(vb:SetData(vertices) and ib:SetData(indices))
    assert(geometry:SetVertexBuffer(0, vb))
    geometry:SetIndexBuffer(ib)
    assert(geometry:SetDrawRange(TRIANGLE_LIST, 0, #data.vertices))
    local model = Model:new()
    -- Geometry retains its shared buffers. The native binding cannot convert
    -- Lua tables to Vector<SharedPtr<...>> in SetVertexBuffers/SetIndexBuffers.
    -- Match example 24: assign Geometry directly, without serializing this Model.
    model.numGeometries = 1
    assert(model:SetGeometry(0, 0, geometry))
    model.boundingBox = bounds
    models_[id] = model -- Shared resource; never Dispose while any clone uses it.
    print(string.format("[BodyShellRepairs] %s局部补壳%d三角；不替换全车/门窗",id,#data.vertices//3))
    return model
end

-- Locomotive.SetCabView changes only the original StaticModel. Mirror that
-- component's enabled event to its local patch (including cloned car subtrees).
-- No per-frame scan, strong Node registry, material copy or global cull change.
---@param eventType string
---@param eventData ComponentEnabledChangedEventData
function HandleBodyShellRepairVisibility(eventType, eventData)
    local node = eventData:GetPtr("Node")
    if not node or (node.name ~= "RollingStock_DF4D" and node.name ~= "RollingStock_HXD3D") then return end
    local patch = node:GetChild(PATCH_NAME)
    if not patch then return end
    local original = node:GetComponent("StaticModel")
    if original then patch.enabled = original.enabled end
end

---@type Material?
local fictionalMaterial_=nil
---@param id string
---@param original Material
---@return Material
function Repairs.GetMaterial(id,original)
    if id~="HXD3D" then return original end
    if not fictionalMaterial_ then
        local material=original:Clone()
        material:SetTexture(TU_DIFFUSE,assert(cache:GetResource("Texture2D","FictionalLiveries/Leisun_E32_patch_D.png")))
        material:SetTexture(TU_NORMAL,assert(cache:GetResource("Texture2D","FictionalLiveries/Leisun_E32_patch_N.png")))
        fictionalMaterial_=material
    end
    return assert(fictionalMaterial_)
end

-- 无名手工Model不能被原生Node.Clone按resource name重新解析；克隆后显式重绑共享资源。
---@param root Node
function Repairs.RestoreClone(root)
    for _,node in ipairs(root:GetChildren(true)) do
        if node.name==PATCH_NAME then
            local parent=node.parent
            local id=parent.name:match("^RollingStock_(.+)$")
            if id then
                local original=parent:GetComponent("StaticModel")
                local drawable=node:GetComponent("StaticModel")
                if original and drawable then
                    drawable.model=assert(Repairs.GetModel(id))
                    drawable:SetMaterial(0,Repairs.GetMaterial(id,original.material))
                end
            end
        end
    end
end

---@param parent Node
---@param id string
---@param material Material
---@return StaticModel?
function Repairs.Attach(parent, id, material)
    local model = Repairs.GetModel(id)
    if not model then return nil end
    if not subscribed_ then
        SubscribeToEvent("ComponentEnabledChanged", "HandleBodyShellRepairVisibility")
        subscribed_ = true
    end
    local patch = parent:CreateChild(PATCH_NAME)
    local drawable = patch:CreateComponent("StaticModel")
    drawable.model = model
    drawable:SetMaterial(0,Repairs.GetMaterial(id,material))
    drawable.viewMask, drawable.castShadows = 1, true
    local original = parent:GetComponent("StaticModel")
    patch.enabled = not original or original.enabled
    return drawable
end

return Repairs
