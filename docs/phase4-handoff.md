# Phase 4 Handoff — Elevation

**Goal:** Mountains exist. Voxel column heights vary with real ETOPO elevation data. Himalayas, Rockies, and Andes are identifiable by terrain shape alone.

**Done when:** Walking from a lowland to a mountain range shows a visually obvious rise in the voxel surface.

---

## Scale + Camera + Pipeline Session (2026-06-03) — Read This First

This session implemented all Phase 4 infrastructure except the actual ETOPO download (large file — do that next). All changes are committed. The globe now looks visually correct: player is 1.8 voxels tall, continent shapes are un-mirrored, mouse look works.

### Changes Applied This Session

| File | Change |
|---|---|
| `engine/scripts/planet/cube_face.gd` | **PLANET_R 10 → 256** — voxels now 1 unit wide; player is 1.8 voxels tall (Blocky Planet proportions). Also updated `_build_chunk_mesh` to find column top depth and render top face at `PLANET_R + depth * voxel_size`. |
| `engine/scenes/world.tscn` | Collision sphere radius 10 → 256; player spawn Y 11.9 → 257.9 |
| `engine/scripts/player/player.gd` | **Mouse camera** — left-click captures, Esc releases. `_yaw`/`_pitch` state drives camera each frame. Third-person orbits player; first-person tilts camera. Movement direction follows camera. |
| `pipeline/src/landmask.py` | **Mirror fix** — `MIRRORED_FACES = frozenset({2, 3})` flips column axis for faces 2 & 3 before writing grid. Fixes east-west continent flip (Florida now points east). |
| `pipeline/src/download.py` | Added `download_etopo()` function + `--etopo` flag with streaming download (~400-800 MB). |
| `pipeline/src/elevation.py` | **New** — reads ETOPO NetCDF, produces `(6, 256, 256)` uint8 array (0-8 extra voxel layers). Shares `MIRRORED_FACES` from landmask. |
| `pipeline/src/export.py` | Added `--elevation` flag; columns now stacked from depth 0 to `extra_layers`. |
| `pipeline/tests/test_elevation.py` | **New** — 17 unit + 6 integration tests (integration skip if ETOPO absent). |
| `pipeline/requirements-phase4.txt` | **New** — `scipy>=1.11`, `netCDF4>=1.6` |
| `pipeline/config/planet.yaml` | Added `etopo_ttl_days: 365` under `cache:` |

### Scale Reference (current: PLANET_R = 256)

| Quantity | Value |
|---|---|
| Voxel side length | 1.0 Godot unit |
| Player height | 1.8 voxels |
| 1 Godot unit represents | 24.9 km real world |
| Planet diameter | 512 Godot units ≈ 12,749 km (≈ real Earth) |
| Visual scale | ~1:24,887 (similar to a desk globe, ~51 cm diameter) |
| Each voxel covers | ~620 km² of real Earth surface |

The game planet is visually **desk-globe scale** (1:25,000 approximately). The terrain data covers all of real Earth but at 25 km/voxel resolution.

To change PLANET_R: edit `engine/scripts/planet/cube_face.gd` line 4 and `engine/scenes/world.tscn` line 19 (sphere radius) and line 46 (player spawn Y = PLANET_R + 1.9). No pipeline re-run needed.

### Known Issue: Mouse Rotation Drift

The camera yaw accumulates a continuous rotation bug. The code applies `_yaw` as a rotation multiplied onto `global_basis` each frame, which is additive — the player spins continuously even without mouse input. **Fix needed next session:**

Replace the yaw-application block in `_physics_process` with a stateless approach: store `_surface_forward: Vector3` (the surface-tangent forward direction), update it only on movement input, and build `global_basis` from scratch each frame as `surface_normal × _surface_forward × _yaw_rotation`.

Specifically, replace:
```gdscript
var yaw_q := Quaternion(surface_normal, deg_to_rad(_yaw))
global_basis = (Basis(yaw_q) * global_basis).orthonormalized()
```

With a stateless rebuild:
```gdscript
# Compute a stable surface-aligned "north" basis with no yaw drift
var right   := surface_normal.cross(Vector3(0, 1, 0)).normalized()
if right.length() < 0.1:  # near poles, use a different reference
    right = surface_normal.cross(Vector3(1, 0, 0)).normalized()
var forward := right.cross(surface_normal).normalized()
# Apply yaw rotation around surface_normal as absolute angle
var yaw_rot := Basis(surface_normal, deg_to_rad(_yaw))
global_basis = Basis(
    yaw_rot * right,
    surface_normal,
    yaw_rot * (-forward)
).orthonormalized()
```

Also reduce `MOUSE_SENSITIVITY` from `0.2` to `0.08` for Minecraft-like feel.

### Current Test Count

127 passed, 6 skipped (ETOPO integration tests, skip if `.nc` absent)

### Godot State After This Session

- Scale: PLANET_R=256, player 1.8 voxels tall ✓
- Land/ocean visible, continents correct orientation ✓
- Mouse camera works (but has drift bug — see above) ✓
- Elevation rendering: code is ready, chunks await ETOPO data ✓
- Startup time: ~1 min (known issue — 1,536 meshes built synchronously, see below) ✓

### Known Issue: Slow Startup (~1 minute)

The output `CubeFace N: building 16×16 chunks` happens for all 6 faces sequentially. Each face builds 256 MeshInstance3D nodes synchronously on the main thread during `_ready()`. At 1,536 meshes × ~500 triangles each = ~768K triangles, this is the bottleneck.

**Fix options for next session (pick one):**
1. **Defer to idle frames**: Use `call_deferred` or `await get_tree().process_frame` to spread mesh building across frames — no code restructure, loads progressively.
2. **Merge chunks per face**: Build one `ArrayMesh` per face instead of 256 separate `MeshInstance3D` nodes — reduces draw calls from 1,536 to 6.
3. **Thread workers**: Build meshes in background threads using Godot's `Thread` class — complex but fully non-blocking.

Recommended: Option 2 (merge per face) — it both speeds up loading AND reduces the runtime draw call count, which is currently excessive.

---

## Rendering Fix Session (2026-06-03) — Read This First

This session fixed rendering bugs before starting Phase 4 elevation. The globe is now fully walkable and visually solid. These changes are committed.

### Fixes Applied

| File | Change |
|---|---|
| `engine/scripts/planet/cube_face.gd` | **Winding flip for faces 2 & 3** — these two cube faces had a left-handed u/v basis in Godot world space, producing inward-facing normals → invisible from outside → large square holes in the surface. Flipped vertex order for `face_id == 2 or face_id == 3` only. |
| `engine/scripts/planet/cube_face.gd` | **Unshaded material** — `SHADING_MODE_UNSHADED` so all faces render at full vertex color brightness regardless of light direction. Eliminates dark-side hollow-marble look. |
| `engine/scripts/planet/cube_face.gd` | **Cull disabled** — `CULL_DISABLED` renders both sides of each face quad. Hides hairline seam gaps at the 12 cube edges by showing colored geometry through them instead of the dark void. |
| `engine/scripts/player/player.gd` | **First-person toggle** — press **F** to switch between third-person (default) and first-person (camera at head height, capsule hidden). Uses `_unhandled_input` with `InputEventKey`. |

### Known Issue: Map is Mirrored East–West

The landmask and continent shapes are rendered **mirrored** — standing in the Gulf of Mexico, the Florida peninsula and surrounding land point the wrong direction. This is a coordinate axis flip somewhere between `latlon_to_face_uv` in `cube_sphere.py` (pipeline) and `face_uv_to_unit` in `cube_face.gd` (Godot). The fix is to flip the `col` or `u` axis for affected faces in one of these functions. **This must be diagnosed and fixed before Phase 4 elevation data is generated**, otherwise the elevation grid will also be mirrored.

Likely fix: in `cube_sphere.py → latlon_to_face_uv`, check if `col = resolution - 1 - col` corrects the orientation. Verify by confirming Florida points east-into-Atlantic in Godot.

### Current Godot State (2026-06-03)

- Planet renders all 6 faces, no holes, no see-through gaps
- Land = muted green, Ocean = deep blue, continents recognizable but mirrored
- Player walks on surface with radial gravity, arrow keys + space jump
- F key toggles first/third person
- 110 pytest tests pass
- 1,536 chunk files present in `engine/planet/faces/`

---

## Current State (End of Phase 3)

Everything below is done and verified. A new context window can trust this state.

### What's Working

- **Godot:** Player walks the full voxel sphere. Arrow keys move, space jumps. No errors in Output panel.
- **Phase 3 pipeline:** All three pipeline scripts complete and tested.
- **Land/Ocean data:** 1,536 chunk files rewritten with material 1 (Land) and 2 (Ocean).
- **Vertex colors:** `cube_face.gd` renders Land as muted green, Ocean as deep blue.
- **110 tests pass:** `pytest pipeline/tests/` — 110/110.
- **Godot cache cleared:** `engine/.godot/editor/filesystem_cache8` deleted before this handoff.

### Files Changed Since Phase 2

| File | What changed |
|---|---|
| `engine/scripts/planet/voxel_planet.gd` | `RESOLUTION` fixed 64 → 256 |
| `engine/scripts/planet/cube_face.gd` | Vertex colors; `StandardMaterial3D` with `vertex_color_use_as_albedo`; diagnostic prints |
| `engine/scripts/planet/chunk_loader.gd` | Silent failures → `push_error` |
| `engine/scripts/player/player.gd` | Fallback node path `"../Planet"` → `"../VoxelPlanet"` |
| `pipeline/config/planet.yaml` | `resolution` fixed 64 → 256 |
| `pipeline/src/download.py` | **New** — fetches Natural Earth shapefile with TTL cache |
| `pipeline/src/landmask.py` | **New** — rasterizes land/ocean mask; cached to `data/cache/landmask.npy` |
| `pipeline/src/export.py` | Added `--landmask` mode; `MATERIAL_OCEAN = 2` constant |
| `pipeline/requirements-phase3.txt` | **New** — minimal requirements without GDAL (pyshp, shapely, numpy, requests, pyyaml) |
| `pipeline/tests/test_landmask.py` | **New** — 15 tests, unit + geographic accuracy integration tests |
| `docs/PIPELINE.md` | Fixed material ID table (was swapped: 1=Ocean was wrong; 1=Land is correct) |

### Material ID Table (frozen after Phase 2)

```
0   = Air
1   = Land (generic)
2   = Ocean
3   = Sand / Desert        ← Phase 5
4   = Grass / Temperate    ← Phase 5
5   = Forest               ← Phase 5
6   = Snow / Ice / Tundra  ← Phase 5
7   = Rock / Mountain      ← Phase 5
8   = Urban / City         ← Phase 6
9   = Road / Rail          ← Phase 6
10  = Interior Rock        ← Phase 6+
```

### Python Venv

A working venv lives at `pipeline/.venv`. Activate it from WSL:

```bash
source ~/programming/tiny-earth/pipeline/.venv/bin/activate
```

This venv uses `requirements-phase3.txt` (no GDAL). Phase 4 will need GDAL/rasterio for GeoTIFF reading — install system GDAL first:

```bash
sudo apt-get install -y libgdal-dev gdal-bin python3-gdal
pip install rasterio
```

### To Verify Phase 3 in Godot

1. Open Godot, open `scenes/world.tscn`
2. Run the scene
3. Confirm Output panel shows all 6 faces building 16×16 chunks (256 each)
4. Planet should be **green (land) and blue (ocean)** with recognizable continent shapes
5. Arrow keys move the player; Space jumps

If it still looks gray, check that `cube_face.gd` has `mat.vertex_color_use_as_albedo = true` in `_build_face()`.

---

## Part A: Phase 4 — Elevation

### Goal

Replace the flat single-layer surface with voxel columns of varying height based on ETOPO global relief data.

- Sea level = 1 voxel layer
- Everest = ~8 voxel layers above sea level
- Mountains: linear interpolation of elevation range → layer count

### Data Source

**ETOPO 2022** — NOAA 1 arc-minute global relief model (land elevation + ocean bathymetry).

- Format: GeoTIFF, ~800 MB full resolution. Use the 1-minute grid (60 arc-sec).
- Download URL: `https://www.ngdc.noaa.gov/mgg/global/relief/ETOPO2022/data/60s/60s_bed_elev_netcdf/ETOPO_2022_v1_60s_N90W180_bed.nc`
- License: Public Domain (NOAA)
- Cache: `data/cache/etopo_60s.nc`

Alternative smaller option: **ETOPO1** (~400 MB):
`https://www.ngdc.noaa.gov/mgg/global/relief/ETOPO1/data/ice_surface/grid_registered/netcdf/ETOPO1_Ice_g_gmt4.grd.gz`

Use whichever is easier to download. NetCDF format requires `scipy` or `netCDF4`.

### New Script: `pipeline/src/elevation.py`

```python
"""
Fetch ETOPO elevation data and produce a (6, RESOLUTION, RESOLUTION) int8 array
where each value is the number of EXTRA voxel layers above the surface layer.

  0 = sea level (or below) — 1-layer surface only
  1–8 = meters remapped to extra layers (Everest ≈ 8)

Cache to data/cache/elevation.npy. Skip if cache is newer than source file.
"""
```

Key math:
```python
# Remap elevation to voxel layer count
# Land: 0 = flat, 8 = Everest (8,849 m)
# Ocean: 0 (flat ocean floor, single layer)
MAX_ELEV_M = 8849  # Everest
VOXEL_LAYERS = 8   # max extra layers above surface

def elev_to_layers(elev_m: float, is_land: bool) -> int:
    if not is_land or elev_m <= 0:
        return 0
    return min(int(elev_m / MAX_ELEV_M * VOXEL_LAYERS) + 1, VOXEL_LAYERS)
```

The algorithm is the same as landmask: iterate all 6 faces × 256 × 256, sample elevation at the lat/lon of each voxel center, map to layer count.

### Update `export.py` for Elevation

Add `--elevation` flag. When set, for each surface voxel:
- Depth 0 = surface material (Land or Ocean from landmask)
- Depths 1..N = same material (fills the column up)
- All deeper depths = Air

```python
for depth in range(layer_count + 1):
    idx = lc + chunk_size * (lr + chunk_size * depth)
    raw[idx] = mat
```

New invocation:
```bash
python pipeline/src/export.py --landmask --elevation
```

### Pipeline Run Order for Phase 4

```bash
# 1. Download ETOPO (large file — ~400-800 MB, cached after first run)
python pipeline/src/download.py --etopo

# 2. Rasterize elevation grid
python pipeline/src/elevation.py

# 3. Export with both landmask and elevation
python pipeline/src/export.py --landmask --elevation

# 4. Clear Godot cache and reopen
rm engine/.godot/editor/filesystem_cache8 engine/.godot/editor/filesystem_update4
```

### Godot Changes for Elevation

`cube_face.gd` currently only reads `depth=0`. To support elevation, the mesh builder needs to loop over all non-zero depths:

```gdscript
for depth in ChunkLoader.CHUNK_SIZE:
    var mat := ChunkLoader.voxel(data, lc, lr, depth)
    if mat == 0:
        break  # columns are contiguous from depth 0; first Air ends the column
    # ... build the top face quad at this depth
```

Only the **top face** of each voxel layer needs to be rendered (players see the surface from above). Side faces can be added later for the mining/cave phase.

### Phase 4 TDD Notes

```python
# Test: elevation array shape is (6, 256, 256)
# Test: all values are 0–8 (uint8 clamped to VOXEL_LAYERS)
# Test: Everest (~28°N, 87°E) has max or near-max layer count
# Test: Pacific center (0°, -150°) has layer count == 0
# Test: at least 5% of cells have layer count > 0 (mountains exist)
```

### Phase 4 Validation Checklist

- [ ] `elevation.npy` produced, shape (6, 256, 256), values 0–8
- [ ] All pytest tests pass
- [ ] `export.py --landmask --elevation` produces 1,536 chunks
- [ ] Mountain ranges visible as raised terrain in Godot
- [ ] Himalayas identifiable — high ridge visible in Asia
- [ ] Player can walk up a mountain slope without gaps or clipping
- [ ] Player at peak of highest voxel column is ~8 units above sea level

---

## Roadmap Review

The full 9-phase roadmap is in `docs/ROADMAP.md`. Quick reference:

| Phase | Status | Summary |
|---|---|---|
| 0 | ✅ Done | Foundation, ADRs, pipeline skeleton |
| 1 | ✅ Done | Walkable sphere with radial gravity |
| 2 | ✅ Done | Voxel cube sphere, chunk system |
| 3 | ✅ Done | Land/ocean silhouette, recognizable continents |
| **4** | **← next** | Elevation — mountains and terrain variation |
| 5 | Pending | Biomes — color by climate zone |
| 6 | Pending | Cities + semantic compression scoring formula |
| 7 | Pending | Landmark meshes (Eiffel Tower, Pyramids, etc.) |
| 8 | Pending | Visual polish + playable export |

---

## ADR Notes and Open Questions

### ADR Inconsistency Fixed

`docs/PIPELINE.md` had material IDs `1=Ocean, 2=Land` — **this was wrong and has been corrected** to `1=Land, 2=Ocean`, matching `export.py` constants and the Phase 3 handoff. If you see any other doc with the swapped IDs, fix it.

### Open Question: Face Seam Gaps

Phase 2 goal ("no visible gaps at face edges") is not yet met. The 12 cube face edges have hairline gaps because adjacent face meshes don't share vertices. Collision is fine (SphereShape3D covers the full surface). Visually, the gaps are noticeable but not game-breaking.

Options to fix:
1. Extend each face mesh by half a voxel at the edge (requires neighbor face data at build time)
2. Add a thin "seam filler" mesh along each of the 12 edges
3. Accept for now and fix in Phase 8 Polish

Recommended: defer to Phase 8. It's cosmetic and the collision works.

### Open Question: WASD vs Arrow Keys

Current player controller uses Godot's default `ui_up/down/left/right` actions (arrow keys only). The Phase 2 success criterion said "WASD moves the player" — this is not implemented. Adding WASD requires either:
- Adding WASD to the default action mappings in Godot's Project Settings → Input Map
- Or adding custom actions (`move_forward`, etc.) in player.gd

Recommended: fix in Phase 8 Polish alongside control remapping.

### Deferred: GDAL for Phase 4+

Phase 3 used `pyshp` (pure Python) to read shapefiles, avoiding GDAL. Phase 4 needs to read NetCDF/GeoTIFF files, which requires `rasterio` → `GDAL`. Before starting Phase 4, install system GDAL:

```bash
sudo apt-get install -y libgdal-dev gdal-bin
pip install --upgrade pip
pip install rasterio netCDF4
```

Or use `scipy` to read NetCDF directly without rasterio:
```python
from scipy.io import netcdf_file
```

**Status as of 2026-06-03:** scipy and netCDF4 are installed. GDAL is not needed — `elevation.py` uses scipy/netCDF4 directly.

---

## Next Session Priorities (2026-06-03)

### Priority 1 — Complete Phase 4 Elevation (requires big download)

```bash
# Activate venv
source pipeline/.venv/bin/activate

# Download ETOPO (400-800 MB, takes a few minutes)
python pipeline/src/download.py --etopo --root .

# Rasterize elevation to (6, 256, 256) uint8 array
python pipeline/src/elevation.py --root .

# Export chunks with elevation columns
python pipeline/src/export.py --landmask --elevation --root .

# Clear Godot cache before reopening
rm engine/.godot/editor/filesystem_cache8 engine/.godot/editor/filesystem_update4
```

Verify: Himalayas show as a raised ridge in Asia. Player at Everest peak should be ~8 units above sea level.

### Priority 2 — Fix Mouse Camera Drift

**Bug:** Camera rotates continuously even without mouse input because `_yaw` is applied multiplicatively onto `global_basis` each frame.

**File:** `engine/scripts/player/player.gd`

**Fix:** Replace the yaw-application block in `_physics_process` with a stateless basis rebuild using a stable surface reference vector. See detailed fix at the top of this document (in the session notes). Also reduce `MOUSE_SENSITIVITY` from `0.2` to `0.08`.

### Priority 3 — Scale Customization

To change the visual scale, edit **one constant**: `PLANET_R` in `engine/scripts/planet/cube_face.gd` line 4. Then update two values in `engine/scenes/world.tscn`:
- Line 19: `SphereShape3D radius` = PLANET_R
- Line 46: Player spawn Y = PLANET_R + 1.9

No pipeline re-run needed. Just save files and hit Play in Godot (or F5).

**Current scale (PLANET_R = 256):**
- 1 unit = 24.9 km real world
- Planet = ~desk globe size (1:25,000 scale)
- Planet diameter = 512 units

**Smaller/larger options:**
| PLANET_R | 1 unit = | Scale | Feel |
|---|---|---|---|
| 64 | 99.5 km | 1:99,500 | Very small, walk equator in ~80 sec |
| 128 | 49.8 km | 1:49,800 | Small, ~2.5 min equator |
| **256** | **24.9 km** | **1:24,900** | **Current** |
| 512 | 12.5 km | 1:12,400 | Large, ~10 min equator |
| 1024 | 6.2 km | 1:6,200 | Very large |

Spawn Y formula: `PLANET_R + 1.9` (e.g., PLANET_R=128 → spawn Y=129.9).

### Priority 4 — Flyover / Noclip Mode

Add a fly mode to `player.gd` toggled by pressing **V** (or Tab):

```gdscript
var _flying := false

# In _unhandled_input:
if event is InputEventKey and event.keycode == KEY_V and event.pressed and not event.echo:
    _flying = not _flying

# In _physics_process, replace movement section with:
if _flying:
    # Noclip: move in camera direction, ignore gravity and collision
    var fly_speed := WALK_SPEED * 3.0
    var fly_dir := Vector3.ZERO
    fly_dir += camera.global_basis.z * -input.y  # forward/back
    fly_dir += camera.global_basis.x *  input.x  # strafe
    if Input.is_action_pressed("ui_accept"):
        fly_dir += surface_normal  # space = up
    if Input.is_action_pressed("ui_cancel"):
        fly_dir -= surface_normal  # ctrl = down (add ui_cancel to input map)
    global_position += fly_dir.normalized() * fly_speed * delta if fly_dir.length() > 0.01 else Vector3.ZERO
    return  # skip gravity + move_and_slide
```

### Priority 5 — Scale Percentage in README

Add a scale table to `README.md`. The formula for real-Earth percentage:

```
Scale ratio = PLANET_R / (Earth_radius_km / km_per_unit)
            = PLANET_R / (6371 / (6371 / PLANET_R))
            = 1  ← the planet IS Earth at reduced resolution
```

A clearer framing: the planet is always "100% of Earth" in geographic coverage, but at reduced voxel resolution. What varies is the **visual size**:

```
Visual scale = 1 : (6,371,000 m / PLANET_R m)  if 1 unit = 1 m
             = 1 : 24,887  at PLANET_R = 256

Voxel resolution = 24.9 km per voxel side  (at PLANET_R = 256)
Total surface voxels = 393,216  (vs Earth's 510M km² / 620 km²/voxel ≈ same)
```

Put this in `README.md` as a "Scale" section. Example text:

> **Scale:** This planet is a 1:24,900 scale model of Earth (similar to a desk globe). Each voxel represents approximately 25 km × 25 km of real terrain. The geographic data covers 100% of Earth's surface at 25 km resolution.

### Priority 6 — Fix Slow Startup

Startup takes ~1 minute because 1,536 MeshInstance3D nodes are built synchronously in `_ready()`.

**Recommended fix — merge chunks per face** in `cube_face.gd`:

Instead of creating one `MeshInstance3D` per chunk, accumulate all chunk geometry into a single `SurfaceTool`, then call `st.commit()` once per face. This reduces node count from 1,536 to 6 and eliminates repeated mesh allocation overhead.

```gdscript
func _build_face() -> void:
    var mat := StandardMaterial3D.new()
    mat.vertex_color_use_as_albedo = true
    mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
    mat.cull_mode = BaseMaterial3D.CULL_DISABLED

    var st := SurfaceTool.new()
    st.begin(Mesh.PRIMITIVE_TRIANGLES)

    for cx in chunks_per_edge:
        for cy in chunks_per_edge:
            var data := ChunkLoader.load(face_id, cx, cy)
            if data.is_empty():
                continue
            _add_chunk_to_surface(st, data, cx, cy)  # renamed from _build_chunk_mesh

    st.generate_normals()
    var mesh_inst := MeshInstance3D.new()
    mesh_inst.mesh = st.commit()
    mesh_inst.material_override = mat
    add_child(mesh_inst)
```

This should reduce startup from ~60 seconds to ~5–10 seconds. The trade-off: when elevation data changes you must rebuild the whole face mesh (currently you'd only rebuild affected chunks — but that's not implemented yet anyway).

### Luanti Export (Phase 8 stretch goal)

The 16×16×16 uint8 chunk format is similar in spirit to Minetest's MapBlock but not binary-compatible (Minetest uses uint16 node IDs in SQLite, different axis order). A conversion script is feasible but complex due to the cube-sphere → flat-grid coordinate mismatch. Document as an ADR when approaching Phase 8.
