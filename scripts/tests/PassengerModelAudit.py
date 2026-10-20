"""Read-only passenger MDL audit; does not launch the runtime or alter assets."""
import glob
import math
import struct


def audit(path):
    data = open(path, "rb").read()
    at = 4

    def uint():
        nonlocal at
        value = struct.unpack_from("<I", data, at)[0]
        at += 4
        return value

    def floats(count):
        nonlocal at
        value = struct.unpack_from("<" + "f" * count, data, at)
        at += 4 * count
        return value

    buffers = []
    for _ in range(uint()):
        count = uint()
        element_count = uint()
        elements = [uint() for _ in range(element_count)]
        uint()
        uint()
        stride = sum([4, 4, 8, 12, 16, 4, 4][e & 255] for e in elements)
        raw = data[at:at + count * stride]
        at += count * stride
        weights = [struct.unpack_from("<4f", raw, i * stride + 52) for i in range(count)]
        indices = [struct.unpack_from("<4B", raw, i * stride + 68) for i in range(count)]
        assert all(all(math.isfinite(v) and 0 <= v <= 1.001 for v in w) for w in weights)
        assert all(abs(sum(w) - 1) < .00001 for w in weights)
        assert max(max(v) for v in indices) < 41
        buffers.append((count, stride, raw))
        print("VB", len(buffers) - 1, count, stride, "valid weights/indices")
    index_buffers = []
    for _ in range(uint()):
        count = uint()
        size = uint()
        index_buffers.append(struct.unpack_from("<" + ("H" if size == 2 else "I") * count, data, at))
        at += count * size
    for g in range(uint()):
        mapping_count = uint()
        mapping = [uint() for _ in range(mapping_count)]
        print("geometry palette", g, mapping)
        lod_count = uint()
        for lod in range(lod_count):
            distance = floats(1)[0]
            primitive, vb, ib, start, count = [uint() for _ in range(5)]
            assert max(index_buffers[ib][start:start + count]) < buffers[vb][0]
            print("LOD", lod, distance, "valid indices")
    assert uint() == 0, "unexpected morph buffers"

    def multiply(a, b):
        return [[sum(a[i][k] * b[k][j] for k in range(4)) for j in range(4)] for i in range(4)]

    worlds, errors, bind_skins = [], [], []
    bone_count = uint()
    for i in range(bone_count):
        end = data.index(0, at)
        name = data[at:end].decode()
        at = end + 1
        parent = uint()
        pos = floats(3)
        w, x, y, z = floats(4)
        scale = floats(3)
        raw = floats(12)
        inverse_bind = [list(raw[j * 4:j * 4 + 4]) for j in range(3)] + [[0, 0, 0, 1]]
        rotation = [[1 - 2 * (y*y + z*z), 2 * (x*y - z*w), 2 * (x*z + y*w)],
                    [2 * (x*y + z*w), 1 - 2 * (x*x + z*z), 2 * (y*z - x*w)],
                    [2 * (x*z - y*w), 2 * (y*z + x*w), 1 - 2 * (x*x + y*y)]]
        local = [[rotation[a][b] * scale[b] for b in range(3)] + [pos[a]] for a in range(3)] + [[0, 0, 0, 1]]
        world = multiply(worlds[parent], local) if parent != i else local
        worlds.append(world)
        skin = multiply(world, inverse_bind)
        bind_skins.append(skin)
        if i in (0, 1, 2, 24):
            print("BIND_SKIN", name, skin)
        errors.append((max(abs(skin[a][b] - (1 if a == b else 0)) for a in range(4) for b in range(4)), name))
        mask = data[at]
        at += 1
        if mask & 1:
            floats(1)
        if mask & 2:
            floats(6)
    print("BIND_RESIDUAL", sorted(errors, reverse=True)[:5])
    variation = max(abs(skin[a][b] - bind_skins[0][a][b]) for skin in bind_skins for a in range(4) for b in range(4))
    print("BIND_VARIATION", variation)
    assert variation < .0001, "bones disagree about common imported bind transform"
    print("MODEL_AUDIT_PASS all LODs; does not prove GPU/mobile palette precision")


if __name__ == "__main__":
    for model_path in glob.glob("/workspace/assets/model/*/Meshes/rig-*.mdl"):
        if "1327bd" in model_path or "dc91" in model_path:
            print(model_path)
            audit(model_path)
