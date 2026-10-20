"""CPU-only MDL and real Lua traffic regression; no engine process or save/cloud I/O.
Run: /workspace/.tmp/luatest/bin/python /workspace/scripts/tests/RoadVehicleAudit.py
Requires lupa.lua54. Does not edit assets.
"""
from pathlib import Path
import math
import struct
from lupa.lua54 import LuaRuntime

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "scripts"
ASSETS = ROOT / "assets"


def mdl(path):
    data = path.read_bytes()
    assert data[:4] == b"UMD2", path
    at = 4

    def uint():
        nonlocal at
        value = struct.unpack_from("<I", data, at)[0]
        at += 4
        return value

    def floats(n):
        nonlocal at
        value = struct.unpack_from("<" + "f" * n, data, at)
        at += n * 4
        return value

    buffers = []
    for _ in range(uint()):
        count, element_count = uint(), uint()
        elements = [uint() for _ in range(element_count)]
        uint(); uint()
        stride = sum([4, 4, 8, 12, 16, 4, 4][e & 255] for e in elements)
        positions = [struct.unpack_from("<3f", data, at + i * stride) for i in range(count)]
        assert all(math.isfinite(v) for p in positions for v in p)
        buffers.append(positions)
        at += count * stride
    indices = []
    for _ in range(uint()):
        count, size = uint(), uint()
        assert size in (2, 4)
        indices.append(struct.unpack_from("<" + ("H" if size == 2 else "I") * count, data, at))
        at += count * size
    geometries = uint()
    lod_counts = []
    for _ in range(geometries):
        mappings = uint()
        assert mappings == 0, "Expected static complete car, not a rig"
        lod_count = uint()
        lod_counts.append(lod_count)
        for _ in range(lod_count):
            floats(1)
            primitive, vb, ib, first, count = [uint() for _ in range(5)]
            assert primitive == 0 and count % 3 == 0
            assert first + count <= len(indices[ib])
            assert max(indices[ib][first:first + count]) < len(buffers[vb])
    assert uint() == 0 and uint() == 0, "Unexpected morph/skeleton payload"
    bounds = floats(6)
    max_lod_overshoot = 0.0
    for lod, positions in enumerate(buffers):
        for i in range(3):
            low, high = min(p[i] for p in positions), max(p[i] for p in positions)
            excess = max(bounds[i] - low, high - bounds[i + 3], 0)
            # Delivered simplified LODs overshoot the LOD0 header by up to .0064.
            # Verify LOD0 precisely; bound/report simplification error rather than
            # modifying source meshes or claiming every LOD has identical extents.
            assert excess <= (1e-6 if lod == 0 else .008), (path, lod, excess)
            max_lod_overshoot = max(max_lod_overshoot, excess)
    print("MDL_AUDIT_PASS", path.parent.parent.name, "bbox", bounds,
          "geometries", geometries, "lods", lod_counts, "maxLodOvershoot", max_lod_overshoot)
    return bounds, geometries


def run():
    lua = LuaRuntime(unpack_returned_tuples=True)
    lua.execute("package.path = ... .. '/?.lua;' .. package.path", str(SCRIPTS))
    # Explicit mathematical/cache test doubles; never presented as real GLES proof.
    lua.execute(r'''
local V={};V.__index=V
function V.__add(a,b)return Vector3(a.x+b.x,a.y+b.y,a.z+b.z)end
function V.__sub(a,b)return Vector3(a.x-b.x,a.y-b.y,a.z-b.z)end
function V.__mul(a,b)
    if type(a)=='number' then return Vector3(a*b.x,a*b.y,a*b.z) end
    return Vector3(a.x*b,a.y*b,a.z*b)
end
function V.__div(a,b)return Vector3(a.x/b,a.y/b,a.z/b)end
function V:LengthSquared()return self.x*self.x+self.y*self.y+self.z*self.z end
function V:Length()return math.sqrt(self:LengthSquared())end
function V:Normalized()local n=self:Length();return n>0 and self/n or Vector3(0,0,0)end
function V:DotProduct(b)return self.x*b.x+self.y*b.y+self.z*b.z end
function V:CrossProduct(b)return Vector3(self.y*b.z-self.z*b.y,self.z*b.x-self.x*b.z,self.x*b.y-self.y*b.x)end
Vector3=setmetatable({}, {__call=function(_,x,y,z)return setmetatable({x=x or 0,y=y or 0,z=z or 0},V)end})
Vector3.ZERO=Vector3();Vector3.ONE=Vector3(1,1,1);Vector3.UP=Vector3(0,1,0)
Vector3.DOWN=Vector3(0,-1,0);Vector3.FORWARD=Vector3(0,0,1);Vector3.RIGHT=Vector3(1,0,0)
function Vector2(x,y)return {x=x,y=y}end
function Color(r,g,b,a)return {r=r,g=g,b=b,a=a or 1}end
local Q={};Q.__index=Q
function Q.__mul(a,b)
    if b.w then
        return setmetatable({w=a.w*b.w-a.x*b.x-a.y*b.y-a.z*b.z,
          x=a.w*b.x+a.x*b.w+a.y*b.z-a.z*b.y,y=a.w*b.y-a.x*b.z+a.y*b.w+a.z*b.x,
          z=a.w*b.z+a.x*b.y-a.y*b.x+a.z*b.w},Q)
    end
    local t=Vector3(a.x,a.y,a.z):CrossProduct(b)*2
    return b+t*a.w+Vector3(a.x,a.y,a.z):CrossProduct(t)
end
function Quaternion(angle,axis)
    if not angle then return setmetatable({w=1,x=0,y=0,z=0},Q) end
    local s=math.sin(math.rad(angle)*.5)
    return setmetatable({w=math.cos(math.rad(angle)*.5),x=axis.x*s,y=axis.y*s,z=axis.z*s},Q)
end
function Variant(v)return v end
Material={new=function()return {SetTechnique=function()end,SetTexture=function()end,SetShaderParameter=function()end}end}
TU_DIFFUSE=0;TU_NORMAL=1;LOCAL=0
function MakeTestScene()
    local N={};N.__index=N
    function N:CreateChild(name)
        local child=setmetatable({name=name,position=Vector3.ZERO,rotation=Quaternion(),scale=Vector3.ONE,enabled=true,children={}},N)
        self.children[#self.children+1]=child;return child
    end
    function N:CreateComponent(kind)
        local c={materials={}}
        function c:SetMaterial(index,material)self.materials[index]=material end
        function c:GetMaterial(index)return self.materials[index]end
        return c
    end
    function N:LocalToWorld(v)
        return self.position+self.rotation*Vector3(v.x*self.scale.x,v.y*self.scale.y,v.z*self.scale.z)
    end
    function N:Dispose() self.disposed=true end
    return setmetatable({children={}},N)
end
''')
    models = {}

    def resource(kind, path):
        if kind != "Model":
            return lua.table()
        if path not in models:
            bounds, geometries = mdl(ASSETS / path)
            lo, hi = lua.globals().Vector3(*bounds[:3]), lua.globals().Vector3(*bounds[3:])
            box = lua.table_from({"min": lo, "max": hi})
            box["size"] = lua.globals().Vector3(*(bounds[i + 3] - bounds[i] for i in range(3)))
            box["center"] = lua.globals().Vector3(*((bounds[i + 3] + bounds[i]) * .5 for i in range(3)))
            models[path] = lua.table_from({"boundingBox": box, "numGeometries": geometries})
        return models[path]

    lua.globals().auditResource = resource
    lua.globals().auditExists = lambda path: (ASSETS / path).is_file()
    lua.execute('cache={GetResource=function(_,kind,path)return auditResource(kind,path) end,Exists=function(_,path)return auditExists(path)end}')
    for name in ("world/RoadVehicles", "world/RoadCorridor", "game/TrafficVisuals",
                 "tests/RoadTrafficValidation", "tests/ReferenceLandscapeValidation"):
        lua.execute("assert(load(...))", (SCRIPTS / (name + ".lua")).read_text())
    lua.execute('local t=require "tests.RoadTrafficValidation"; assert(t.Run()); t.ValidateAssets(MakeTestScene())')
    lua.execute(r'''
local vehicles=require "world.RoadVehicles"
local target={slots={}};function target:SetMaterial(slot,material)self.slots[slot]=material end
vehicles.ApplyAsset(target,{model={numGeometries=3},material={}})
assert(target.slots[0] and target.slots[1] and target.slots[2],"all-slot coverage regression")
print("ALL_ROAD_VEHICLE_AUDIT_PASS realMDL=true LuaMathDoubles=true GLES=NOT_EXECUTED noSaveIO=true noCloudIO=true")
''')


if __name__ == "__main__":
    run()
