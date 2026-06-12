# Session Handoff — Elevation Collision Geometry Fix

> **RESOLVED 2026-06-08** — Side-wall + top-face collision mesh implemented in `cube_face.gd` with `backface_collision = true`. Player can no longer walk through or get trapped in elevated blocks.

**Goal for this session:** Player can land on top of elevated terrain blocks and walk around on
them. Player cannot walk through the sides of elevated blocks. Destroying a block removes its
collision.

---

## Current Behaviour (broken)

- Player walks through the **sides** of elevated blocks — no side-wall collision exists.
- If the player enters an elevated block volume from the side they get **trapped** because
  the block is too tall to jump out of and there is no side collision to push them back out.
- Flat terrain (no elevation) works fine — the `VoxelPlanet` sphere collider (r=256) keeps
  the player on the surface everywhere.
- Block **top faces** have collision that works when approached from directly above, but
  because there are no side walls the approach path is unguarded.

---

## Architecture

```
World (Node3D)
├── VoxelPlanet (StaticBody3D)   ← has SphereShape3D r=256 collision — DO NOT DISABLE
│   ├── CubeFace_0 (StaticBody3D, script=cube_face.gd)
│   │   └── CollisionShape3D    ← ConcavePolygonShape3D, rebuilt by _rebuild_top_collision()
│   ├── CubeFace_1 … CubeFace_5
└── Player (CharacterBody3D)
```

- `PLANET_R = 256.0`, `_face_res = 256` (16 chunks × 16 voxels), `vox_size = 1.0` (1 world
  unit per voxel layer).
- Elevation range: 0–8 extra layers above `PLANET_R`. Most ocean/plains = depth 0.
  Himalayas/Andes peak at ~7–8.
- **VoxelPlanet sphere must stay enabled.** It provides floor collision for flat terrain
  (depth=0 columns). If disabled the player falls through flat ground.

---

## The One File to Change

`engine/scripts/planet/cube_face.gd` — specifically `_build_top_collision_mesh()` (line ~97).

Everything else (visual mesh, chunk loading, block destruction) is working correctly and should
not be touched.

---

## Why the Current Collision Mesh Is Wrong

`_build_top_collision_mesh()` returns an `ArrayMesh` that is passed to
`create_trimesh_shape()` → `ConcavePolygonShape3D`. Godot's `ConcavePolygonShape3D` computes
each triangle's collision normal from the **vertex winding order** (cross product of edges).
With `backface_collision = false` (the default), only the **front face** collides — the side
whose normal points toward the incoming object.

The current function generates **top faces only** — no side walls. This means:
- Player can enter an elevated column from the side with zero resistance.
- Inside the column the top face is above them; with `backface_collision=false` the top face
  does not block upward movement so they can pass through it going up — but the sphere keeps
  them pressed against r=256 inside the column, and if the column depth ≥ 2 layers the player
  can never jump high enough to fully clear the top face on the way down.

**The fix is to add side walls to the collision mesh with outward-facing normals.**

### Why winding is tricky here

The visual mesh uses `render_mode unshaded, cull_disabled` — both sides of every triangle are
rendered regardless of winding. So winding was never validated for the visual mesh. When side
wall triangles are added to the collision mesh, their winding determines whether the collision
normal points **outward** (correct — pushes player away from the column) or **inward** (wrong —
pulls player into the column).

The winding that produces an outward normal **differs between cube faces** because
`face_uv_to_unit()` applies a Z-up → Y-up rotation after projecting onto the cube. This changes
the handedness of the (u, v) tangent basis on different faces, flipping which winding is
"outward". The visual top-face mesh already accounts for this: faces 2 and 3 use reversed
winding. Side walls need the same per-face treatment, but the correct flip for side walls has
not been determined.

---

## `face_uv_to_unit` — the projection function

```gdscript
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
    # Z-up → Y-up as rotation (det=+1). The negation on the last component
    # is what keeps it a rotation rather than a reflection.
    return Vector3(raw.x, raw.z, -raw.y)
```

The (u, v) → sphere tangent basis handedness varies per face. Faces 2 and 3 are the ones
where the default winding flips — the visual mesh already handles this for top faces.

---

## Recommended Fix Approach

### Step 1 — Determine correct side-wall winding at runtime

Rather than hardcoding a flip table, compute the expected outward direction and test whether
the chosen winding agrees with it. If not, swap two vertices.

For a wall on direction `dir = [dc, dr]` at the edge between column `(col, row)` and its
neighbour:

```gdscript
# mid-point of the wall edge in UV space
var u_mid := (u_a + u_b) * 0.5
var v_mid := (v_a + v_b) * 0.5
var eps   := 0.5 / float(_face_res)

# step one voxel outward in the wall-normal direction
var u_out := u_mid + dc * eps
var v_out := v_mid + dr * eps

# expected outward direction: from the wall edge toward the neighbour
var expected_out := face_uv_to_unit(face_id, u_out, v_out) \
                  - face_uv_to_unit(face_id, u_mid, v_mid)

# trial winding: pa_base → pa_top → pb_top
var trial_normal := (pa_top - pa_base).cross(pb_top - pa_base)

if trial_normal.dot(expected_out) > 0.0:
    # winding is correct — normal points outward
    st.add_vertex(pa_base); st.add_vertex(pa_top);  st.add_vertex(pb_top)
    st.add_vertex(pa_base); st.add_vertex(pb_top);  st.add_vertex(pb_base)
else:
    # winding is backwards — flip it
    st.add_vertex(pa_base); st.add_vertex(pb_top);  st.add_vertex(pa_top)
    st.add_vertex(pa_base); st.add_vertex(pb_base); st.add_vertex(pb_top)
```

This works for all 6 faces without needing to know in advance which faces flip.

### Step 2 — Same treatment for top faces

The visual mesh already uses the correct winding for top faces (faces 2/3 flip). Apply the same
runtime test to keep the collision mesh in sync without depending on the hardcoded flip:

```gdscript
var center  := (p00 + p10 + p01 + p11) * 0.25
var outward := center  # on a sphere centered at origin, position ≈ outward direction
var trial   := (p10 - p00).cross(p11 - p00)
if trial.dot(outward) > 0.0:
    st.add_vertex(p00); st.add_vertex(p10); st.add_vertex(p11)
    st.add_vertex(p00); st.add_vertex(p11); st.add_vertex(p01)
else:
    st.add_vertex(p00); st.add_vertex(p11); st.add_vertex(p10)
    st.add_vertex(p00); st.add_vertex(p01); st.add_vertex(p11)
```

### Step 3 — Keep `_rebuild_top_collision()` as-is

No other callers need to change. `_rebuild_top_collision()` is called at startup
(`_build_face()`) and on every block destroy (`remove_top_voxel()`). Both paths use
`_build_top_collision_mesh()` and assign the result to `_col_shape.shape`. This is already
correct.

---

## Current `_build_top_collision_mesh()` (what to replace)

```gdscript
func _build_top_collision_mesh() -> ArrayMesh:
    var st       := SurfaceTool.new()
    var res      := float(_face_res)
    var vox_size := PLANET_R / res
    st.begin(Mesh.PRIMITIVE_TRIANGLES)
    for col in _face_res:
        for row in _face_res:
            var gi        := col * _face_res + row
            var top_depth := _top_depth_grid[gi]
            if top_depth < 0:
                continue
            var r   := PLANET_R + top_depth * vox_size
            var p00 := face_uv_to_unit(face_id,  col       / res,  row       / res) * r
            var p10 := face_uv_to_unit(face_id, (col + 1)  / res,  row       / res) * r
            var p01 := face_uv_to_unit(face_id,  col       / res, (row + 1)  / res) * r
            var p11 := face_uv_to_unit(face_id, (col + 1)  / res, (row + 1)  / res) * r
            st.add_vertex(p00); st.add_vertex(p10); st.add_vertex(p11)
            st.add_vertex(p00); st.add_vertex(p11); st.add_vertex(p01)
    return st.commit()
```

The new version should keep the same loop structure and top-face logic, then add the side-wall
loop (same `dirs`, same UV edge coordinates as `_add_chunk_to_surface()`) with the runtime
winding test from Step 1. Full side-wall UV reference from the existing visual mesh function:

```gdscript
var dirs := [[1, 0], [-1, 0], [0, 1], [0, -1]]
for dir in dirs:
    var nc: int = col + dir[0]
    var nr: int = row + dir[1]
    var nb_depth: int = _grid_depth(nc, nr)
    if top_depth <= nb_depth:
        continue  # neighbour is same height or taller, no exposed wall

    var r_base := PLANET_R + nb_depth * vox_size
    var u_a: float; var v_a: float; var u_b: float; var v_b: float
    if dir[0] == 1:       # right
        u_a = (col + 1) / res; v_a = row       / res
        u_b = (col + 1) / res; v_b = (row + 1) / res
    elif dir[0] == -1:    # left
        u_a = col       / res; v_a = (row + 1) / res
        u_b = col       / res; v_b = row       / res
    elif dir[1] == 1:     # forward
        u_a = (col + 1) / res; v_a = (row + 1) / res
        u_b = col       / res; v_b = (row + 1) / res
    else:                  # backward
        u_a = col       / res; v_a = row       / res
        u_b = (col + 1) / res; v_b = row       / res

    var pa_base := face_uv_to_unit(face_id, u_a, v_a) * r_base
    var pb_base := face_uv_to_unit(face_id, u_b, v_b) * r_base
    var pa_top  := face_uv_to_unit(face_id, u_a, v_a) * r
    var pb_top  := face_uv_to_unit(face_id, u_b, v_b) * r
    # ... winding test here, then st.add_vertex(...)
```

---

## What NOT to Change

- `_add_chunk_to_surface()` — visual mesh; working correctly
- `_rebuild_top_collision()` — the caller; no changes needed
- `remove_top_voxel()` — block destruction; already calls `_rebuild_top_collision()`
- `world.tscn` — VoxelPlanet sphere collision stays **enabled**
- `player.gd` — no changes needed

---

## Verification Checklist

After the fix, test in Godot:
- [ ] Walk on flat ocean/plains — no regression, player does not sink
- [ ] Walk up to a mountain edge — player is stopped by the side wall, cannot walk through it
- [ ] Jump onto a 1-layer elevated block from outside — player lands on top cleanly
- [ ] Jump onto a multi-layer elevated block — player lands on top cleanly  
- [ ] Press `E` to destroy a block underfoot — collision clears, player falls to next level
- [ ] No getting trapped in elevated blocks from any approach

## Controls (for testing)
| Key | Action |
|-----|--------|
| Arrow keys | Walk |
| Space | Jump / fly up |
| V | Toggle fly mode (escape if stuck) |
| E | Destroy voxel underfoot |
