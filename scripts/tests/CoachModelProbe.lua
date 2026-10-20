-- 只读探针：对四款新客车原始MDL做LOD0实测，输出旋正后包络、轮区候选与踏面中心。
-- 不写资产、不改profile、不运行游戏；仅供人工据此填写RollingStockProfile的contact ROI。
local IDS = {
    "f24f03ef03e94627ba410efae414df3e",
    "f0276be35e6648f9bd819305cab10159",
    "3970f65da0f14917b1c97ed296e2cd35",
    "7010b9a50dd5414d96d9aa94d420dec2",
    -- 已知已接入中间车，用作探针自校验。
    "fb6db791acae4c95a0455e5270f4e417",
}

---@param geometry Geometry
---@return integer[]
local function readIndices(geometry)
    local buffer = geometry:GetIndexBuffer()
    local result = {}
    if not buffer or geometry.indexCount == 0 then
        for i = geometry.vertexStart, geometry.vertexStart + geometry.vertexCount - 1 do
            result[#result + 1] = i
        end
        return result
    end
    local data = buffer:GetData()
    data:Seek(geometry.indexStart * buffer.indexSize)
    for _ = 1, geometry.indexCount do
        result[#result + 1] = buffer.indexSize == 2 and data:ReadUShort() or data:ReadUInt()
    end
    return result
end

---@param source Model
---@return Vector3[], Vector3[]
local function readLodZero(source)
    ---@type Vector3[]
    local positions = {}
    ---@type Vector3[]
    local normals = {}
    ---@type table<VertexBuffer, table<number, boolean>>
    local seen = {}
    for g = 0, source.numGeometries - 1 do
        local geom = source:GetGeometry(g, 0)
        for b = 0, geom.numVertexBuffers - 1 do
            local vb = geom:GetVertexBuffer(b)
            if vb:HasElement(SEM_POSITION) then
                local used = seen[vb] or {}
                seen[vb] = used
                local data = vb:GetData()
                local po = vb:GetElementOffset(SEM_POSITION)
                local no = vb:HasElement(SEM_NORMAL) and vb:GetElementOffset(SEM_NORMAL) or -1
                for _, index in ipairs(readIndices(geom)) do
                    if not used[index] then
                        used[index] = true
                        data:Seek(index * vb.vertexSize + po)
                        positions[#positions + 1] = data:ReadVector3()
                        if no >= 0 then
                            data:Seek(index * vb.vertexSize + no)
                            normals[#normals + 1] = data:ReadVector3()
                        else
                            normals[#normals + 1] = Vector3.DOWN
                        end
                    end
                end
            end
        end
    end
    return positions, normals
end

--- 与 RollingStock.principalYaw 完全一致的XZ协方差主轴。
---@param positions Vector3[]
---@return number
local function principalYaw(positions)
    local mx, mz = 0.0, 0.0
    for _, p in ipairs(positions) do mx, mz = mx + p.x, mz + p.z end
    mx, mz = mx / #positions, mz / #positions
    local xx, xz, zz = 0.0, 0.0, 0.0
    for _, p in ipairs(positions) do
        local x, z = p.x - mx, p.z - mz
        xx, xz, zz = xx + x * x, xz + x * z, zz + z * z
    end
    local lambda = (xx + zz + math.sqrt((xx - zz)^2 + 4 * xz * xz)) * .5
    local x, z = xz, lambda - xx
    if math.abs(x) + math.abs(z) < .00000001 then x, z = 1, 0 end
    if z < 0 then x, z = -x, -z end
    return -math.deg(math.atan(x, z))
end

---@param values number[]
---@param fraction number
---@return number
local function quantile(values, fraction)
    table.sort(values)
    return assert(values[math.max(1, math.min(#values, math.floor((#values - 1) * fraction) + 1))])
end

---@param id string
local function probe(id)
    local path = "model/" .. id .. "/Meshes/" .. id .. ".mdl"
    if not cache:Exists(path) then
        print(string.format("[CoachProbe] %s 缺失：%s", id, path))
        return
    end
    local source = assert(cache:GetResource("Model", path))
    local positions, normals = readLodZero(source)
    local yaw = principalYaw(positions)
    local rotation = Quaternion(yaw, Vector3.UP)
    local bounds = BoundingBox()
    for i, p in ipairs(positions) do
        local rp = rotation * p
        local rn = rotation * assert(normals[i])
        positions[i] = rp
        normals[i] = rn
        bounds:Merge(rp)
    end
    local size, center = bounds.size, bounds.center
    print(string.format("[CoachProbe] %s LOD0顶点=%d geo=%d LOD=%d", id, #positions, source.numGeometries,
        source:GetNumGeometryLodLevels(0)))
    print(string.format("[CoachProbe] %s PCA yaw=%.6f° 旋正包络=%.4fx%.4fx%.4f 中心=(%.4f,%.4f,%.4f) 长宽比=%.2f",
        id, yaw, size.x, size.y, size.z, center.x, center.y, center.z, size.z / size.x))
    -- 朝下法线顶点里取最低5%作为踏面候选，左右按x中位数分侧。
    ---@type Vector3[]
    local down = {}
    for i, p in ipairs(positions) do
        if normals[i].y < -.55 then down[#down + 1] = p end
    end
    if #down < 16 then
        print(string.format("[CoachProbe] %s 朝下顶点不足(%d)，无法定位踏面", id, #down))
        return
    end
    local ys = {} ---@type number[]
    for _, p in ipairs(down) do ys[#ys + 1] = p.y end
    local bottom = quantile(ys, .05)
    ---@type Vector3[]
    local low = {}
    for _, p in ipairs(down) do if p.y <= bottom + .006 then low[#low + 1] = p end end
    local xs = {} ---@type number[]
    for _, p in ipairs(low) do xs[#xs + 1] = p.x end
    local midX = quantile(xs, .5)
    ---@type Vector3[]
    local left, right = {}, {}
    for _, p in ipairs(low) do
        if p.x < midX then left[#left + 1] = p else right[#right + 1] = p end
    end
    ---@param group Vector3[]
    ---@return number,number,number,number,number,number,number
    local function report(group)
        if #group == 0 then return 0, 0, 0, 0, 0, 0, 0 end
        local gx, gz, gy = {}, {}, {}
        for _, p in ipairs(group) do
            gx[#gx + 1], gz[#gz + 1], gy[#gy + 1] = p.x, p.z, p.y
        end
        return #group, quantile(gx, .05), quantile(gx, .95), quantile(gz, .02), quantile(gz, .98),
            quantile(gx, .5), quantile(gy, .5)
    end
    local ln, lx0, lx1, lz0, lz1, lxc, lyc = report(left)
    local rn, rx0, rx1, rz0, rz1, rxc, ryc = report(right)
    print(string.format("[CoachProbe] %s 踏面候选总数=%d 底部y=%.4f", id, #low, bottom))
    print(string.format("[CoachProbe] %s 左 n=%d x[%.4f,%.4f] z[%.4f,%.4f] cx=%.4f cy=%.4f", id, ln, lx0, lx1, lz0, lz1, lxc, lyc))
    print(string.format("[CoachProbe] %s 右 n=%d x[%.4f,%.4f] z[%.4f,%.4f] cx=%.4f cy=%.4f", id, rn, rx0, rx1, rz0, rz1, rxc, ryc))
    print(string.format("[CoachProbe] %s 建议源踏面横距=%.5f", id, rxc - lxc))
    cache:ReleaseResource("Model", path)
end

function Start()
    local ok, message = pcall(function()
        for _, id in ipairs(IDS) do probe(id) end
        print("[CoachProbe] COACH_MODEL_PROBE_DONE 仅离线只读测量，未写资产")
    end)
    if not ok then log:Write(LOG_ERROR, "[CoachProbe] " .. tostring(message)) end
    engine:Exit()
end
