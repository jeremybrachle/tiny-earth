# Changelog

## Session 2026-06-09 — Per-Chunk Collision + Inner Shell Physics (Phase 6.2 complete)

### Engine (Godot)

**SphereShape3D removed** (`world.tscn`) — The monolithic solid-sphere collider (`SphereShape3D_planet`, r=256) that covered the entire planet surface has been deleted. It was impossible to punch holes in it at runtime, so excavated columns and ocean tiles always left the player stuck at sea level.

**Per-chunk outer collision** (`cube_face.gd`) — Replaced the single `_col_shape: CollisionShape3D` (rebuilt from all 65,536 columns on every dig) with a `_chunk_col_shapes` dictionary: one `CollisionShape3D` per 16×16 chunk. On block destroy, only the one affected chunk's trimesh is rebuilt (~256 columns). Block-destroy freeze is eliminated. Ocean tiles (`mat == 2`) are excluded from the chunk collision so the player sinks through water. All other depth-0 and elevated solid columns get solid collision.

**Per-chunk inner shell collision** (`inner_cube_face.gd`) — Added the same per-chunk collision system to the inner shell. Every chunk on every face now has a `CollisionShape3D` covering the seafloor surface and its side walls. Player lands on the inner seafloor after falling through the outer surface.

**Shoreline gap closed** (`cube_face.gd`) — Outer face side walls previously stopped exactly at `planet_radius` (neighbor depth 0), leaving a 1-voxel-tall gap between the outer cliff face and the inner rock surface visible at every coastline. Side walls now extend 1 voxel below the neighbor surface using `max(nb_depth, 0) - 1`, closing the gap without z-fighting.

**Z-fighting fix** (`cube_face.gd`) — The initial `(nb_depth - 1)` formula sent the wall bottom to `planet_radius - 2 * voxel_size` for fully excavated neighbors (`nb_depth = -1`), coinciding exactly with the inner seafloor geometry. Clamped with `max(nb_depth, 0)` so the wall never goes deeper than `planet_radius - voxel_size`.

### Known issues entering next session

- **Buoyancy not implemented** — Player sinks and lands on seafloor correctly but falls at full gravity with no water resistance. Buoyancy force and `Ctrl`-to-dive still need to be added to `player.gd`.
- **No underwater camera effect** — No blue fog tint or visibility reduction when below the ocean surface.
- **First-dig visual delay** — On the very first block broken on any face a ~16-frame async mesh transition runs. Subsequent digs are instant. Known architectural trade-off.
- **Hollow centre empty** — The planet interior is physically reachable by falling through the outer shell but contains nothing. A room + `OmniLight3D` at the origin is planned for Phase 6.3.

---

## Session 2026-06-08 — Visual Upgrade + Resolution Bump (Phase 5.9 complete)

### Engine (Godot)

**Planet scale centralized** (`voxel_planet.gd`, `world.gd`) — Removed all hardcoded `256` constants. `export.py` now writes `engine/planet/planet_config.json` with `planet_radius`, `resolution`, `chunk_size`, and `chunks_per_edge`. `voxel_planet.gd` reads it at `_ready()`, auto-sizes the `SphereShape3D` collider, and passes values into each CubeFace. Player spawns snap to `planet_r + 1.5` regardless of `radius_scale`.

**Space sky with atmospheric scattering** (`sky_space.gdshader`, `world.gd`) — New sky shader uses Godot's `POSITION` built-in (camera world position) to compute altitude above surface and local up direction. Day side shows blue sky with warm dusk/dawn horizon tint; night side shows procedural star field; atmosphere thins as the player flies higher. Sun disc + inner/outer corona rendered on top. Altitude ceiling = `planet_radius × 0.12` so the scale works at any `radius_scale`.

**PBR voxel shader** (`voxel.gdshader`, `cube_face.gd`) — Replaced `unshaded` render mode with a full spatial PBR pass. Vertex colors become ALBEDO. Block edges darken via UV proximity (`edge_width` 0.07, `edge_dark` 0.50). Roughness 0.92 (matte), SPECULAR 0.1, METALLIC 0.0.

**Environment / lighting** (`world.gd`) — SSAO (radius 1.0, intensity 1.0, power 1.0), SSIL (radius 4.0), ACES filmic tonemapping (white 6.0, exposure 1.0), glow (bloom 0.02, additive), warm solid ambient fill (Color 0.85,0.85,0.80 @ 0.6 energy), sun energy 1.1 warm white.

### Pipeline

**Resolution bump 256 → 512** (`planet.yaml`) — Geographic resolution doubled. ~12 km/voxel; Florida ~10 blocks wide; Great Lakes, coastlines, island chains visibly crisper.

**`radius_scale` added** (`planet.yaml`, `export.py`) — `planet_radius = resolution × radius_scale`. Changing only `radius_scale` requires re-running only `export.py`, not the full pipeline.

### Bug Fixes

- Player no longer spawns inside the planet when `radius_scale != 1.0`
- Sphere collider auto-syncs to actual `planet_radius` (was hardcoded to 256 in `world.tscn`)
- Stars no longer bleed through day-side horizon (fixed `smoothstep` range on `eye_up`)
- Great Lakes restored — `landmask.py` must always be run with `--lakes` flag

---

## Session 2026-06-08 — Köppen-Geiger Biome Rewrite (Phase 5.75 complete)

### Pipeline

**Köppen-Geiger raster** (`pipeline/src/biomes.py`) — Replaced all hardcoded `DESERT_BBOXES` rectangles and latitude-band splits with a lookup against the Beck et al. 2018 Köppen-Geiger 1 km GeoTIFF. Every biome assignment is now 100% data-driven. Removed `DESERT_BBOXES`, `_is_desert()`, and `_make_smooth_noise()`. Added `KOPPEN_TO_MATERIAL` mapping (30 Köppen classes → 7 material IDs), `load_koppen()` (rasterio), and `_sample_koppen()` (affine-inverse pixel lookup + vectorised LUT). Latitude-band logic kept as a fallback if the raster file is missing.

**Download** (`pipeline/src/download.py`) — Added `download_koppen()` for the Beck 2018 figshare GeoTIFF. Handles both bare-GeoTIFF and zip-wrapped delivery by checking TIFF magic bytes. Added `--koppen` flag to `main()`.

### Verification
- Pipeline ran clean: face counts show Desert concentrated in correct geographic regions (Sahara, Arabian Peninsula, Gobi, Sonoran, Australian outback) with natural irregular boundaries
- Godot screenshot confirms organic biome edges — no rectangular seams on North America, Rockies mountain coloring correct
- No Godot code changes required; existing `MAT_COLORS` IDs 2–9 in `cube_face.gd` were already correct

---

## Session 2026-06-08 — Elevation Collision Fix + Minecraft-Style Block Shading (Phase 5.5 complete)

### Engine (Godot)

**Side-wall + top-face collision** (`cube_face.gd`) — `_build_top_collision_mesh()` now generates both the top quad and outward-facing side walls for every elevated column. Side-wall winding is resolved at runtime by comparing the trial cross-product normal against the expected outward direction (one step toward the neighbour in UV space), so the fix works correctly on all 6 cube faces without a per-face flip table.

**Backface collision enabled** — `_rebuild_top_collision()` sets `shape.backface_collision = true` on the ConcavePolygonShape3D. A player who enters a column from an unexpected angle is ejected to the nearest surface rather than trapped.

**Flat ground untouched** — depth-0 columns are excluded from the elevated collision mesh. The VoxelPlanet sphere collider (r=256) continues to handle all flat terrain.

**Minecraft-style block shading** (`cube_face.gd`) — Side-wall vertex colors are darkened to 65% of the top-face color at mesh generation time. Top faces stay full brightness; side walls are dimmer, giving a clear 3D block depth cue without requiring lighting or shader changes. Works automatically after every block destroy since `_add_chunk_to_surface` is shared by both the initial build and per-chunk rebuilds.

### Verification
- Player stopped by mountain side walls from any approach direction
- Player lands cleanly on 1-layer and multi-layer elevated columns
- Destroying a block (E) removes its collision immediately; side-wall shading correct on rebuilt chunk
- No regression on flat ocean/plains

---

## Session 2026-06-08 — Biomes, Elevation, Side-Wall Rendering

### Pipeline

**Biomes** (`pipeline/src/biomes.py`, new) — Reads `landmask.npy` and assigns climate-zone material IDs by latitude. Added ±8° smooth spatial noise (16×16 random grid bilinearly upsampled to 256×256) so biome boundaries look organic rather than hard latitude lines.
- ID 3 = Desert/Sand (|lat| < 25°)
- ID 4 = Grass/Temperate (25–50°)
- ID 5 = Forest (50–65°)
- ID 6 = Snow/Ice (>65°)

**Elevation** (`pipeline/src/elevation.py`, `pipeline/src/download.py`) — ETOPO 2022 download URL was stale (NOAA moved data to THREDDS fileServer). Updated URL and downloaded 469 MB NetCDF. Rasterized to `elevation.npy` (6×256×256 uint8, 0–8 extra voxel layers). Max 7 layers on face 2 (Himalayas).

**Export** (`pipeline/src/export.py`) — Added `--biomes` flag. `--elevation` now works with both `--landmask` and `--biomes`. Final export: `python pipeline/src/export.py --biomes --elevation --root .`

### Engine (Godot)

**Biome colors** (`cube_face.gd`) — Expanded `MAT_COLORS` from 2 entries (land/ocean) to 6 (+ desert, temperate, forest, snow).

**Side-wall rendering** (`cube_face.gd`) — Rewrote `_build_face` as a two-pass process: pass 1 loads all chunks and populates a full-face `_top_depth_grid` / `_top_mat_grid`; pass 2 builds the mesh. `_add_chunk_to_surface` now generates side-wall quads wherever a column is higher than its neighbor, using `_grid_depth()` for cross-chunk neighbor lookups. Previously elevated blocks were floating platforms with visible holes; now terrain looks like solid connected voxel stacks.

### Known issues entering next session

- **Elevated terrain not solid** — player can walk through elevated voxel columns. `VoxelPlanet` has a sphere collider at r=256 (flat surface only). CubeFace needs trimesh collision shapes.
- **No block edge lines** — voxels blend together without visible grid lines. Need a shader that darkens pixels near UV edges.

---

## Session 2026-06-03 — Player Polish, Block Destruction, Map Quality

### Engine (Godot)

**CI fix** — GitHub Actions workflow was only installing `pytest pytest-cov PyYAML`, causing numpy/shapely import errors. Changed to `pip install -r requirements-phase3.txt -r requirements-phase4.txt`.

**Mouse camera drift fixed** (`player.gd`) — Camera yaw was applied multiplicatively onto `global_basis` each frame, causing continuous rotation. Replaced with a stateless basis rebuild from `surface_normal` each frame using correct right-handed cross product order (`world_up × surface_normal`). Also reduced `MOUSE_SENSITIVITY` 0.2 → 0.08.

**Startup time optimized** (`cube_face.gd`) — Replaced 256 individual `MeshInstance3D` nodes per face (1,536 total) with a single merged mesh per face (6 total). Startup drops from ~60 s to ~5–10 s. Draw calls drop from 1,536 to 6.

**Fly mode** (`player.gd`) — Press `V` to toggle noclip fly. Arrow keys = horizontal, Space = up, Ctrl = down. `FLY_SPEED = WALK_SPEED * 5`.

**Block destruction** (`cube_face.gd`, `player.gd`) — Press `E` to destroy the topmost voxel of the column you are standing on. First destroy triggers a one-time switch from merged-face mesh to 256 per-chunk meshes (~1–2 s); subsequent destroys rebuild only the affected chunk (<10 ms). Inverse cube-face mapping (`unit_to_face_col_row`) converts player world position to face/col/row.

**GDScript type fixes** — `class_name CubeFace` caused load-order errors in `player.gd`; replaced with `preload()`. `abs()` replaced with `absf()` to resolve Variant overload ambiguity. All local variables in static functions given explicit type annotations.

### Pipeline

**Landmask source upgraded** (`download.py`, `landmask.py`) — Changed from `ne_110m_land` (1:110 million, very coarse) to `ne_10m_land` (1:10 million). At 25 km/voxel this makes Caribbean islands, Greenland, and detailed coastlines render correctly. Zip is ~25 MB vs 2 MB.

### Known issues entering next session

- **Cube face seam landmask discontinuity** — One face boundary shows a clean straight-line cut where geography abruptly changes to ocean. Likely a missing or incorrect entry in `MIRRORED_FACES`. See phase5-handoff.md.
- **ETOPO elevation** — Download may still be in progress. Pipeline commands ready; no Godot changes needed once data arrives.

---

## Phase 1 — Walkable Sphere ✓
*Completed 2026-06-02*

**Milestone:** Player walks around a tiny planet with correct local radial gravity. First visual output of the project.

### What was built
- `engine/project.godot` — Godot 4.3 project config with WASD + arrow key input map
- `engine/scenes/world.tscn` — full scene: World → Planet (StaticBody3D, r=10) + Player (CharacterBody3D) + lighting
- `engine/scripts/player/player.gd` — radial gravity, surface-normal alignment, camera-relative movement, jump
- `engine/scripts/planet/planet.gd` — static sphere, no logic (gravity computed by player)
- `engine/scripts/world/world.gd` — scene root, no logic
- `engine/icon.svg` — project icon
- Procedural sky + DirectionalLight3D for visibility

### Key bug found
Hand-written `.tscn` files cannot reliably resolve `@export var node: NodeType` properties via `NodePath`. Fix: add `get_node_or_null("../Planet")` fallback in `_ready()`. NodePath resolution in Godot 4 is relative to the node's *owner* (scene root), not the node itself — so `"../Planet"` (sibling) must be `"Planet"` (from root), but the runtime fallback is more robust than relying on either.

### Validation checklist
- [x] Player spawns on surface without falling through
- [x] Gravity pulls toward planet center from any position
- [x] Player's feet always point toward the planet
- [x] Sky and directional lighting render correctly
- [x] Full orbit on foot in under 2 minutes
- [x] No orientation glitch crossing from one side to the other
- [x] Jumping lands back on sphere

---

## Phase 0 — Foundation ✓
*Completed prior to 2026-06-02*

- Git repo initialized, monorepo layout
- ADRs 001–005 written
- `pipeline/config/planet.yaml` — resolution=256, chunk_size=16 (frozen)
- `pipeline/src/cube_sphere.py` — lat/lon ↔ cube face UV math, unit tested
- `pipeline/src/export.py` — writes valid empty chunk stubs
- `.github/workflows/pipeline-test.yml` — CI runs pytest on push to main
- `ATTRIBUTION.md`, `LICENSES.md`, `REFERENCES.md` populated

---

## Up Next — Phase 2: Voxel Planet

Replace the smooth `SphereMesh` with a voxelized cube sphere. Six faces, each an N×N grid of cube voxels. Chunk system loads `.bin` files produced by `export.py`. Gravity and player controller carry forward unchanged.

Key deliverables:
- `cube_face.gd` — generates one face of the cube sphere as a voxel mesh
- All 6 faces seamed correctly (no visible gaps at edges)
- `chunk.gd` + `chunk_loader.gd` — load/unload `.bin` chunk files by player proximity
- Pipeline exports a uniform solid sphere (all voxels = Land material)

Hardest part: seam handling at cube face edges. `chunk_size=16` is now frozen.
