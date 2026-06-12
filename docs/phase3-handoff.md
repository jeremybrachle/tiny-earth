# Phase 3 Handoff — Earth Silhouette

**Goal:** Recognizable continents appear. Real Natural Earth land/ocean data replaces the uniform solid sphere.

**Done when:** A person looking at the planet immediately says "that's Earth."

---

## Part A: Finish Phase 2 First (Two Bugs)

Phase 2 code is complete on disk but has two confirmed bugs. Fix these before starting Phase 3 work.

### A1 — Kill the stale Godot cache

Godot on Windows does not detect file changes on WSL. The editor cache (`filesystem_cache8`) is stale and causes Godot to serve an old version of `world.tscn` that references a node named `"Planet"` which no longer exists.

**From WSL terminal, before opening Godot:**

```bash
cd /home/kerry/programming/tiny-earth/engine
rm .godot/editor/filesystem_cache8 .godot/editor/filesystem_update4
```

### A2 — Fix RESOLUTION in voxel_planet.gd

`engine/scripts/planet/voxel_planet.gd` has `RESOLUTION := 64` but chunk files on disk are resolution=256. This makes the planet load only 4×4 of 16×16 chunks per face — roughly 6% of the surface, effectively invisible.

Change line 5:
```gdscript
# Before:
const RESOLUTION := 64
# After:
const RESOLUTION := 256
```

`CHUNKS_PER_EDGE` recalculates automatically (256 / 16 = 16). No other changes needed in this file.

### A3 — Fix the player fallback in player.gd

`engine/scripts/player/player.gd` has a `_ready()` fallback that searches for `"../Planet"`. That node was renamed to `"VoxelPlanet"`. If the Inspector-assigned `planet` property ever comes in null, the fallback should find the right node.

In `_ready()`, change the one fallback line:
```gdscript
# Before:
planet = get_node_or_null("../Planet") as StaticBody3D
# After:
planet = get_node_or_null("../VoxelPlanet") as StaticBody3D
```

### A4 — Add diagnostics to chunk_loader.gd

Replace the silent failure in `load()` so file I/O errors show in the Output panel:

```gdscript
static func load(face: int, cx: int, cy: int) -> PackedByteArray:
	var path := "res://planet/faces/face_%d/chunk_%d_%d.bin" % [face, cx, cy]
	var f := FileAccess.open(path, FileAccess.READ)
	if not f:
		push_error("ChunkLoader: failed to open %s — error %d" % [path, FileAccess.get_open_error()])
		return PackedByteArray()
	var compressed := f.get_buffer(f.get_length())
	f.close()
	var raw := compressed.decompress(
		CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE,
		FileAccess.COMPRESSION_DEFLATE
	)
	if raw.is_empty():
		push_error("ChunkLoader: decompression failed for %s" % path)
		return PackedByteArray()
	return raw
```

### A5 — Add build prints to cube_face.gd

Add two prints bracketing `_build_face()` so you can confirm the mesh loop runs:

```gdscript
func _build_face() -> void:
	print("CubeFace %d: building %d×%d chunks" % [face_id, chunks_per_edge, chunks_per_edge])
	for cx in chunks_per_edge:
		# ... existing loop ...
	print("CubeFace %d: done, %d mesh instances" % [face_id, get_child_count()])
```

### A6 — Reopen Godot and re-save world.tscn

1. Open Godot (cache deleted → it re-scans from disk)
2. Open `scenes/world.tscn`
3. Select the **Player** node → Inspector → verify `planet` shows **VoxelPlanet**
   - If empty: drag VoxelPlanet from the scene tree into the `planet` slot
4. Press **Ctrl+S** to save

### Phase 2 Success Criteria

Run the scene and confirm in the Output panel:

```
CubeFace 0: building 16×16 chunks
CubeFace 0: done, 256 mesh instances
CubeFace 1: building 16×16 chunks
CubeFace 1: done, 256 mesh instances
... (6 faces total)
```

- No `push_error` lines from ChunkLoader
- Voxel sphere is visible (faceted, uniform gray-green)
- WASD moves the player
- Player wraps the surface normally

---

## Part B: Phase 3 — Earth Silhouette

Once Phase 2 is confirmed working, Part B begins.

### Starting State

- `engine/planet/faces/` — 1,536 all-Land `.bin` files (from `export.py --solid`)
- `pipeline/config/planet.yaml` — `resolution: 256`, `chunk_size: 16` (both frozen)
- `pipeline/src/cube_sphere.py` — lat/lon ↔ cube face UV math, tested. **Do not change.**
- `pipeline/src/export.py` — writes chunk files, has `--solid` flag

### What Phase 3 Adds

Three new pipeline scripts. No changes to Godot GDScript except adding an Ocean material.

#### 1. `pipeline/src/download.py` — fetch Natural Earth shapefiles

```python
# Download Natural Earth 110m land polygons from naturalearthdata.com
# Cache to data/cache/ne_110m_land.zip (TTL per planet.yaml cache.osm_ttl_days)
# No API key needed; direct download
```

Target URL: `https://naciscdn.org/naturalearth/110m/physical/ne_110m_land.zip`

The file is ~50 KB. Unzip to `data/cache/ne_110m_land/ne_110m_land.shp`.

#### 2. `pipeline/src/landmask.py` — rasterize polygons onto the cube sphere grid

This is the core of Phase 3. For each of the 6 faces × 256 × 256 = 393,216 surface voxels, classify as Land (1) or Ocean (2).

```python
# pseudocode — implement with shapely + pyproj
for face in range(6):
    for col in range(RESOLUTION):
        for row in range(RESOLUTION):
            u = (col + 0.5) / RESOLUTION
            v = (row + 0.5) / RESOLUTION
            xyz = face_uv_to_unit(face, u, v)  # from cube_sphere.py
            lat, lon = xyz_to_latlon(xyz)
            material = MATERIAL_LAND if land_polygons.contains(Point(lon, lat)) else MATERIAL_OCEAN
            grid[face][col][row] = material
```

Key functions already exist in `cube_sphere.py`:
- `face_uv_to_xyz(face, u, v)` → unit vector
- `xyz_to_latlon(x, y, z)` → `(lat_deg, lon_deg)`

Use `shapely.geometry.shape()` to load Natural Earth polygons and `.contains(Point(lon, lat))` for point-in-polygon tests. This is the slow step — budget 30–60 seconds for the full 393K-point rasterization.

**Material IDs for Phase 3:**

| ID | Name |
|---|---|
| 0 | Air |
| 1 | Land |
| 2 | Ocean |

#### 3. Update `export.py` to write landmask data

Replace the uniform `--solid` fill with per-voxel material from `landmask.py`:

```python
def export_planet(config, repo_root, landmask: dict):
    """Write chunk files using the provided face→col→row→material dict."""
    for face in range(6):
        for cx in range(chunks_per_edge):
            for cy in range(chunks_per_edge):
                raw = bytearray(chunk_size ** 3)
                for lc in range(chunk_size):
                    for lr in range(chunk_size):
                        col = cx * chunk_size + lc
                        row = cy * chunk_size + lr
                        mat = landmask[face][col][row]
                        # surface layer (depth=0), rest stays Air
                        idx = lc + chunk_size * (lr + chunk_size * 0)
                        raw[idx] = mat
                write_chunk(face, cx, cy, bytes(raw))
```

Run with: `python pipeline/src/export.py --landmask`

#### 4. Add Ocean material in Godot

In `cube_face.gd`, swap the `MeshInstance3D` approach for one that assigns a material based on the majority material in the chunk:

```gdscript
# Quick approach: two SurfaceTool passes per chunk — one for Land, one for Ocean
# Or: one mesh with two surfaces (surface 0 = Land, surface 1 = Ocean)
```

The simplest Phase 3 approach: keep one mesh per chunk, use vertex colors. Land = green, Ocean = blue. Full material system with `StandardMaterial3D` slots can come in Phase 5 (Biomes) when more materials appear.

### Phase 3 Pipeline Run Order

```bash
# 1. Download shapefiles (cached after first run)
python pipeline/src/download.py

# 2. Rasterize land mask (~60s)
python pipeline/src/landmask.py

# 3. Export chunks with land/ocean data
python pipeline/src/export.py --landmask

# 4. Open Godot, run scene — verify Earth silhouette visible
```

### Phase 3 TDD Notes

`landmask.py` has testable pure functions. Write pytest tests before implementation:

```python
# Test: North Pole is not Land
# Test: Amazon basin (~-3°, -60°) is Land
# Test: Pacific center (~0°, -150°) is Ocean
# Test: exactly 30–40% of globe surface is Land (±5%)
# Test: no face has 100% of one material (no face is all Land or all Ocean)
```

### Phase 3 Validation Checklist

- [ ] `download.py` fetches and caches `ne_110m_land.shp` without error
- [ ] `landmask.py` produces a 6×256×256 grid where ~30–40% of cells = Land
- [ ] All pytest tests pass
- [ ] `export.py --landmask` produces 1,536 `.bin` files (same count, different contents)
- [ ] Godot loads without errors
- [ ] Planet shows two distinct visual zones (land / ocean)
- [ ] Africa, North America, Eurasia clearly visible from orbit
- [ ] Antarctica visible as Land mass at south pole (Godot -Y)
- [ ] Player walks between Land and Ocean tiles without gaps or z-fighting

### Common Pitfalls

**Antarctica upside-down or in wrong hemisphere:** The pipeline is Z-up, Godot is Y-up. The `Vector3(raw.x, raw.z, raw.y)` swap in `face_uv_to_unit` means Godot +Y is the north pole (face 4 in pipeline convention). Verify: walk to Godot +Y → should reach Arctic/north pole.

**Point-in-polygon is slow:** Natural Earth 110m is coarse but still takes time for 393K points. Precompute a numpy raster (256×256 per face) and cache it as `data/cache/landmask.npy` — skip rasterization if the cache file exists and is newer than the shapefile.

**Ocean shows as Air (invisible):** Check that `export.py --landmask` writes material ID 2 (not 0) for Ocean cells. The renderer skips material 0 (Air) but must render 2 (Ocean).

**WSL/Godot file sync:** After running `export.py --landmask` from WSL, delete the Godot cache before reopening:
```bash
rm engine/.godot/editor/filesystem_cache8 engine/.godot/editor/filesystem_update4
```

---

## What Phase 4 Adds

ETOPO elevation data → voxel column heights. Sea level = 1 voxel deep; Everest = ~8 voxels tall. The Himalayas, Andes, and Rockies become identifiable by terrain shape alone.
