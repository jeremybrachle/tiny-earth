# Phase 2 Handoff — Voxel Planet

**Goal:** Replace the smooth `SphereMesh` with a voxelized cube sphere. Six faces, each an N×N grid of surface quads projected onto the sphere. Player walks on voxel surface. Pipeline exports a uniform solid sphere.

**Done when:** Voxelized planet loads from `.bin` chunk files and the player walks the full surface without visible gaps or seam artifacts at face edges.

---

## Starting State

Phase 0 and Phase 1 are complete:

- `pipeline/src/cube_sphere.py` — lat/lon ↔ cube face UV math, fully tested. **Port this math to GDScript** — do not invent new projection logic.
- `pipeline/src/export.py` — writes empty (all-Air, material=0) `.bin` chunk files to `engine/planet/faces/`
- `engine/scenes/world.tscn` — player walking on a smooth sphere with radial gravity, sky, lighting
- `engine/scripts/player/player.gd` — **carry forward unchanged**
- `planet.yaml` — `resolution=256`, `chunk_size=16` — **both frozen**

The player controller, gravity, and camera all carry forward with zero changes.

---

## Binary Chunk Format

Every `.bin` file is a **zlib-compressed flat byte array** of `chunk_size³ = 4096` bytes.

```
engine/planet/faces/
  face_0/chunk_0_0.bin  …  chunk_15_15.bin   (+X face, 16×16 chunks)
  face_1/                                     (-X face)
  face_2/                                     (+Y face)
  face_3/                                     (-Y face)
  face_4/                                     (+Z face)
  face_5/                                     (-Z face)
```

**Byte index formula:**

```
index = local_col + chunk_size * (local_row + chunk_size * depth)
```

where `local_col` and `local_row` are 0–15 within the chunk, and `depth=0` is the surface layer (outermost from planet center). In Phase 2 all bytes = material ID (0=Air, 1=Land).

**Material IDs (Phase 2):**

| ID | Name |
|---|---|
| 0 | Air |
| 1 | Land |

**Reading in GDScript:**

```gdscript
var f := FileAccess.open(path, FileAccess.READ)
var compressed := f.get_buffer(f.get_length())
f.close()
# Godot's COMPRESSION_DEFLATE matches Python's zlib.compress() format.
var raw := compressed.decompress(chunk_size * chunk_size * chunk_size,
                                  FileAccess.COMPRESSION_DEFLATE)
# raw[index] is now the material ID for each voxel
```

> **Verify early:** print `raw[0]` after decompression to confirm it reads 1 (Land) not 0 or garbage. If decompression fails, check that `export.py` was run with the `--solid` flag (see Pipeline Changes below).

---

## Pipeline Change — Solid Export

The Phase 0 `export.py` writes all-Air chunks. Phase 2 needs all-Land chunks so there is something to render. Add a `--solid` flag:

```python
# In export.py, replace make_empty_chunk with:

MATERIAL_LAND = 1

def make_chunk(chunk_size: int, material: int = MATERIAL_AIR) -> bytes:
    """Return a zlib-compressed chunk filled with the given material."""
    raw = bytes([material] * chunk_size ** 3)
    return zlib.compress(raw, level=6)
```

Then add `--solid` to the argument parser:

```python
parser.add_argument("--solid", action="store_true",
                    help="Fill all voxels with Land (material 1) instead of Air")
```

And pass `material=MATERIAL_LAND if args.solid else MATERIAL_AIR` to `make_chunk`.

**Run before opening Godot:**

```bash
cd /path/to/tiny-earth
python pipeline/src/export.py --solid
```

This writes 1,536 chunk files (6 faces × 16 × 16) to `engine/planet/faces/`.

---

## Cube Sphere Math in GDScript

Port directly from `pipeline/src/cube_sphere.py`. Do not invent new math.

```gdscript
# Returns a unit sphere point for a given face UV coordinate.
# face: 0=+X, 1=-X, 2=+Y, 3=-Y, 4=+Z, 5=-Z  (pipeline convention, Z-up)
# u, v: [0.0, 1.0] within the face
static func face_uv_to_unit(face: int, u: float, v: float) -> Vector3:
    var s := u * 2.0 - 1.0
    var t := v * 2.0 - 1.0
    var raw: Vector3
    match face:
        0: raw = Vector3( 1.0,  s,    t)
        1: raw = Vector3(-1.0, -s,    t)
        2: raw = Vector3( s,    1.0,  t)
        3: raw = Vector3(-s,   -1.0,  t)
        4: raw = Vector3( s,    t,    1.0)
        5: raw = Vector3( s,   -t,   -1.0)
    raw = raw.normalized()
    # Pipeline is Z-up; Godot is Y-up. Swap to align north pole with +Y.
    return Vector3(raw.x, raw.z, raw.y)
```

The Y/Z swap means face 4 (+Z pipeline = north pole) maps to Godot's +Y. This matters starting Phase 3 when Earth data needs geographic orientation.

---

## Scene Structure

```
World (Node3D)  ← world.gd  [unchanged from Phase 1]
├── WorldEnvironment            [unchanged]
├── DirectionalLight3D          [unchanged]
├── VoxelPlanet (Node3D)  ← voxel_planet.gd  [new — replaces Planet]
│   ├── CubeFace_0 (StaticBody3D)  ← cube_face.gd
│   ├── CubeFace_1 …
│   ├── CubeFace_2 …
│   ├── CubeFace_3 …
│   ├── CubeFace_4 …
│   └── CubeFace_5 (StaticBody3D)
└── Player (CharacterBody3D)  ← player.gd  [unchanged]
```

**Remove** the old `Planet (StaticBody3D)` from the scene. Replace it with `VoxelPlanet`. Update the Player's `planet` export to point to `VoxelPlanet` — or change `player.gd` to find any `StaticBody3D` named "VoxelPlanet".

**Planet radius stays 10.** The voxel surface sits at radius ≈ 10; the old SphereShape3D collision can remain for Phase 2. Exact per-voxel collision comes in Phase 4 when elevation varies.

---

## Scripts

### `engine/scripts/planet/chunk_loader.gd`

```gdscript
class_name ChunkLoader

const CHUNK_SIZE := 16

static func load(face: int, cx: int, cy: int) -> PackedByteArray:
    var path := "res://planet/faces/face_%d/chunk_%d_%d.bin" % [face, cx, cy]
    var f := FileAccess.open(path, FileAccess.READ)
    if not f:
        return PackedByteArray()
    var compressed := f.get_buffer(f.get_length())
    f.close()
    return compressed.decompress(
        CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE,
        FileAccess.COMPRESSION_DEFLATE
    )

static func voxel(data: PackedByteArray, lc: int, lr: int, depth: int) -> int:
    return data[lc + CHUNK_SIZE * (lr + CHUNK_SIZE * depth)]
```

---

### `engine/scripts/planet/cube_face.gd`

One face of the planet. Iterates all chunks on this face and generates the surface mesh.

```gdscript
extends StaticBody3D

const CHUNK_SIZE  := 16
const CHUNKS_EDGE := 16   # resolution (256) / chunk_size (16)
const PLANET_R    := 10.0

@export var face_id: int = 0


func _ready() -> void:
    _build_face()


func _build_face() -> void:
    for cx in CHUNKS_EDGE:
        for cy in CHUNKS_EDGE:
            var data := ChunkLoader.load(face_id, cx, cy)
            if data.is_empty():
                continue
            var mesh_inst := MeshInstance3D.new()
            mesh_inst.mesh = _build_chunk_mesh(data, cx, cy)
            add_child(mesh_inst)


func _build_chunk_mesh(data: PackedByteArray, cx: int, cy: int) -> ArrayMesh:
    var st := SurfaceTool.new()
    st.begin(Mesh.PRIMITIVE_TRIANGLES)

    for lc in CHUNK_SIZE:
        for lr in CHUNK_SIZE:
            if ChunkLoader.voxel(data, lc, lr, 0) == 0:
                continue  # Air — skip

            # Global grid position of this voxel's 4 corners
            var col0 := cx * CHUNK_SIZE + lc
            var row0 := cy * CHUNK_SIZE + lr
            var res   := float(CHUNK_SIZE * CHUNKS_EDGE)  # 256.0

            var p00 := face_uv_to_unit(face_id,  col0      / res,  row0      / res) * PLANET_R
            var p10 := face_uv_to_unit(face_id, (col0 + 1) / res,  row0      / res) * PLANET_R
            var p01 := face_uv_to_unit(face_id,  col0      / res, (row0 + 1) / res) * PLANET_R
            var p11 := face_uv_to_unit(face_id, (col0 + 1) / res, (row0 + 1) / res) * PLANET_R

            # Two triangles (CCW winding, normals face outward)
            st.add_vertex(p00); st.add_vertex(p11); st.add_vertex(p10)
            st.add_vertex(p00); st.add_vertex(p01); st.add_vertex(p11)

    st.generate_normals()
    return st.commit()


static func face_uv_to_unit(face: int, u: float, v: float) -> Vector3:
    var s := u * 2.0 - 1.0
    var t := v * 2.0 - 1.0
    var raw: Vector3
    match face:
        0: raw = Vector3( 1.0,  s,    t)
        1: raw = Vector3(-1.0, -s,    t)
        2: raw = Vector3( s,    1.0,  t)
        3: raw = Vector3(-s,   -1.0,  t)
        4: raw = Vector3( s,    t,    1.0)
        5: raw = Vector3( s,   -t,   -1.0)
    raw = raw.normalized()
    return Vector3(raw.x, raw.z, raw.y)  # Z-up → Y-up
```

---

### `engine/scripts/planet/voxel_planet.gd`

```gdscript
extends Node3D

func _ready() -> void:
    for face in 6:
        var cf := preload("res://scripts/planet/cube_face.gd").new()
        cf.face_id = face
        cf.name = "CubeFace_%d" % face
        add_child(cf)
```

---

## Winding Order — Get This Right

The triangle winding order determines which side Godot considers "front" (outward-facing). For outward normals viewed from outside the sphere:

```
p01 --- p11
|     / |
|   /   |
| /     |
p00 --- p10
```

Triangles (CCW from outside): `(p00, p11, p10)` and `(p00, p01, p11)`.

If the planet appears **inside-out** (dark from outside, lit from inside), flip to: `(p00, p10, p11)` and `(p00, p11, p01)`.

---

## Seam Handling

At face edges, adjacent voxels belong to different faces. For Phase 2 (uniform solid sphere), **seams are not a problem** — all voxels are Land so there are no visibility decisions at edges. The sphere-projected corners of adjacent faces share the same world-space point (the projection is continuous at cube edges), so there are no visual gaps.

Seam handling across face boundaries — needed when Land meets Ocean — is deferred to Phase 3.

---

## Performance Notes

At full resolution (256×256 per face):
- 1,536 chunks × 256 surface quads = ~393,000 quads total
- `_build_face()` is synchronous — expect a 1–3 second hitch on first load
- Acceptable for Phase 2; streaming by player proximity comes in Phase 4

If iteration is slow, drop to `resolution=64` in `planet.yaml` during development (chunk structure stays identical, just fewer files). **Remember to re-run `export.py --solid` after any resolution change.**

---

## Validation Checklist

- [ ] `export.py --solid` runs without error and produces 1,536 `.bin` files
- [ ] Godot loads the scene without errors
- [ ] Six cube faces are visible and tile into a recognizable sphere shape
- [ ] Player stands on the voxel surface (not floating above or clipping through)
- [ ] No visible gaps at face seam edges
- [ ] Player can walk the full surface — gravity and alignment unchanged from Phase 1
- [ ] Face edges show slight geometric seaming (expected — cube face ≠ perfect sphere); no black gaps or z-fighting

---

## Common Pitfalls

**All chunks appear empty / nothing renders:** Run `export.py --solid`. The Phase 0 export writes all-Air (material=0), which the renderer correctly skips.

**Decompression error / wrong byte count:** The `decompress()` call needs the exact uncompressed size (`chunk_size³ = 4096`). If this throws, check `chunk_size` matches between Python and GDScript.

**Planet appears inside-out (normals facing inward):** Flip the triangle winding order — see Winding Order section above.

**Huge hitch on load / editor freezes:** Generating all 1,536 meshes synchronously takes time. During development, reduce `resolution` to 64 in `planet.yaml`, re-run the export, and build at lower resolution. Restore to 256 before Phase 3.

**Player falls through:** The collision in Phase 2 still uses the Phase 1 `SphereShape3D` (radius=10). The voxel `MeshInstance3D` nodes are visual only. This is intentional — exact voxel collision is deferred to Phase 4.

**Face seam gaps / dark lines:** These are z-fighting or winding issues at face edges, not missing geometry. Check that adjacent face UV corners produce identical world-space vertex positions (they should, since `face_uv_to_unit` is deterministic at edge UV values like 0.0 and 1.0).

---

## What Phase 3 Adds

Phase 3 replaces the uniform Land material with real Earth land/ocean data. The pipeline gains `download.py` and `landmask.py` — which rasterize Natural Earth 110m shapefiles onto the cube face grid and write material ID 1 (Land) or 2 (Ocean) per voxel column. The Godot side gains two distinct materials in the renderer. The voxel mesh generation code is unchanged; only the material IDs in the `.bin` files change.
