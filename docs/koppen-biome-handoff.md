# Session Handoff — Köppen-Geiger Biome Rewrite

**Goal for next session:** Replace the hardcoded desert bounding boxes in `biomes.py` with a
real Köppen-Geiger climate raster so every biome assignment is 100% data-driven at any resolution.

---

## Current State (end of session 2026-06-08)

### What's working

| Item | Status |
|------|--------|
| Land/ocean boundary | ✅ `ne_10m_land` shapefile, 256×256 per face |
| Lake data | ✅ `ne_10m_lakes` shapefile subtracted from landmask (Great Lakes, Caspian, etc.) |
| Elevation (mountain heights) | ✅ ETOPO 2022, 0–8 extra voxel layers |
| Elevation collision | ✅ Side-wall + top-face trimesh, `backface_collision=true` |
| Side-wall rendering | ✅ Two-pass mesh with full face depth grid |
| Side-wall shading | ✅ Side walls rendered at 65% brightness (Minecraft-style 3D depth) |
| Block edge outlines | ✅ ShaderMaterial with UV-based edge darkening |
| Biome material IDs | ✅ 7 active IDs (3–9) — see table below |
| Mountain/Rock coloring | ✅ Data-driven from ETOPO depth ≥ 4 (~4,400 m) |

### Current material IDs (pipeline → Godot)

| ID | Name | Color | Source |
|----|------|-------|--------|
| 2 | Ocean | blue | `ne_10m_land` (inverse) |
| 3 | Desert | sandy tan | **Hardcoded bboxes** ← fix target |
| 4 | Temperate | light green | Latitude 25–50°, non-desert |
| 5 | Forest | dark green | Latitude 50–65° |
| 6 | Snow/Ice | white | Latitude ≥ 65° |
| 7 | Tropical | rich dark green | Latitude < 15°, non-desert |
| 8 | Savanna | golden olive | Latitude 15–25°, non-desert |
| 9 | Mountain/Rock | gray-stone | ETOPO depth ≥ 4 (real data) |

### What's still hardcoded (the problem)

`pipeline/src/biomes.py` classifies Desert using `DESERT_BBOXES` — a hand-written list of
lat/lon rectangles:

```python
DESERT_BBOXES = [
    ( 15,  35, -17,  55),  # Sahara + Arabian Peninsula
    ( 25,  50,  75, 125),  # Gobi
    (-30, -17,  12,  22),  # Namib
    (-35, -15, -75, -65),  # Atacama
    (-35, -20, 113, 150),  # Australian outback
    ( 23,  35,-115,-105),  # Sonoran
    ( 23,  32,  63,  77),  # Thar
    (-52, -38, -70, -62),  # Patagonian
]
```

At higher resolutions these will produce obvious rectangular edges on the Sahara and Gobi.
The latitude splits for Tropical/Savanna/Temperate/Forest are also approximations (physically
reasonable, but not based on actual climate data).

---

## The Fix — Beck 2018 Köppen-Geiger Raster

**Beck et al. 2018** is the standard global climate classification used in climate science.
It assigns every point on Earth one of 30 climate classes at 1 km resolution.

- Download: free, no registration, ~30 MB GeoTIFF
- URL: `https://figshare.com/ndownloader/files/12407516` (present-day 1km map, zipped)
- Format: GeoTIFF (EPSG:4326, global extent), values 1–30
- Python reading: `rasterio` (preferred) or `scipy.ndimage.map_coordinates` on a pre-loaded array

### Köppen class → material ID mapping

```python
KOPPEN_TO_MATERIAL = {
    # Tropical (Af, Am, Aw, As)
    1: 7, 2: 7, 3: 7, 4: 7,
    # Arid desert (BWh, BWk)
    5: 3, 6: 3,
    # Arid steppe (BSh, BSk)
    7: 8, 8: 8,
    # Temperate (Csa, Csb, Csc, Cwa, Cwb, Cwc, Cfa, Cfb, Cfc)
    9: 4, 10: 4, 11: 4, 12: 4, 13: 4, 14: 4, 15: 4, 16: 4, 17: 4,
    # Continental (Dsa, Dsb, Dsc, Dsd, Dwa, Dwb, Dwc, Dwd, Dfa, Dfb, Dfc, Dfd)
    18: 5, 19: 5, 20: 5, 21: 5, 22: 5, 23: 5, 24: 5, 25: 5,
    26: 5, 27: 5, 28: 5, 29: 5,
    # Polar (ET=tundra, EF=ice cap)
    30: 6, 31: 6,
}
```

### Implementation approach (same pattern as `elevation.py`)

`elevation.py` already shows the pattern for reading a global raster:

1. Download the GeoTIFF (add `download_koppen()` to `download.py`)
2. Read it into a (lat, lon) grid with rasterio or scipy
3. For each cube face voxel, look up its lat/lon in the raster
4. Map the Köppen class to a material ID
5. Apply mountain override from ETOPO (depth ≥ 4 → ID 9) as a final pass

The existing `build_biomes()` function in `biomes.py` already computes `lat` and `lon` for
every voxel — just replace the bbox/latitude logic with a raster lookup.

### Files to change

| File | Change |
|------|--------|
| `pipeline/src/download.py` | Add `download_koppen()` + `--koppen` flag |
| `pipeline/src/biomes.py` | Replace `DESERT_BBOXES` + `_is_desert()` + lat splits with raster lookup |
| No Godot changes needed | `MAT_COLORS` in `cube_face.gd` already has IDs 3–9 |

### Pipeline run order after the rewrite

```bash
cd ~/programming/tiny-earth
source pipeline/.venv/bin/activate

python pipeline/src/download.py --koppen          # ~30 MB one-time download
python pipeline/src/biomes.py --root .            # rewrite reads koppen raster
python pipeline/src/export.py --biomes --elevation --root .
```

Landmask and elevation caches do NOT need to be regenerated — they are independent of biomes.

---

## Architecture Reference

```
World (Node3D)
├── VoxelPlanet (StaticBody3D)   ← sphere collider r=256 — DO NOT DISABLE
│   ├── CubeFace_0 (StaticBody3D, script=cube_face.gd)
│   │   ├── MeshInstance3D       ← visual mesh (merged, or per-chunk after first destroy)
│   │   └── CollisionShape3D     ← ConcavePolygonShape3D, rebuilt by _rebuild_top_collision()
│   ├── CubeFace_1 … CubeFace_5
└── Player (CharacterBody3D)
```

- `PLANET_R = 256.0`, `_face_res = 256` (16 chunks × 16 voxels), `vox_size = PLANET_R / 256`
- Elevation range 0–8 extra layers above `PLANET_R`. 0 = flat ground (sphere handles collision).
- Material IDs flow: `export.py` writes IDs into `.bin` chunk files → `cube_face.gd` reads
  them → `MAT_COLORS` dict maps ID to vertex color → shader reads `COLOR.rgb`

### Key files

| File | Role |
|------|------|
| `pipeline/src/landmask.py` | Rasterize ne_10m_land + subtract ne_10m_lakes → `landmask.npy` |
| `pipeline/src/biomes.py` | Assign material IDs to land voxels → `biomes.npy` |
| `pipeline/src/elevation.py` | Rasterize ETOPO → `elevation.npy` |
| `pipeline/src/export.py` | Merge all layers → `engine/planet/faces/*.bin` chunk files |
| `engine/scripts/planet/cube_face.gd` | Mesh + collision generation, `MAT_COLORS` dict |

---

## Controls (for testing after pipeline runs)

| Key | Action |
|-----|--------|
| Arrow keys | Walk |
| Space | Jump / fly up |
| Ctrl | Fly down (fly mode) |
| V | Toggle fly/noclip |
| E | Destroy voxel underfoot |
| F | Toggle first/third person |

---

## Roadmap Status

| Phase | Status | Summary |
|---|---|---|
| 0–3 | ✅ Done | Foundation, walkable sphere, voxels, land/ocean silhouette |
| 4 | ✅ Done | Elevation from ETOPO 2022 |
| 5 | ✅ Done | Biomes, lake data, block shading, edge outlines |
| 5.5 | ✅ Done | Elevation collision — side walls + backface ejection |
| **5.75** | **← next session** | Replace hardcoded desert bboxes with Köppen-Geiger raster |
| 5.8 | Pending | Water surface — semi-transparent ocean shader (deferred) |
| 6 | Pending | Cities + semantic compression scoring |
| 7 | Pending | Landmark meshes |
| 8 | Pending | Visual polish + playable export |

### Future consideration — Resolution bump

Current: 256×256 per face (~25 km/voxel, Florida ~5 voxels wide).
Planned: 512×512 per face (~12 km/voxel, Florida ~10 voxels wide).

This requires changing `planet.yaml` resolution 256→512 and Godot `chunks_per_edge` 16→32,
then regenerating the full pipeline. Do this AFTER the Köppen rewrite so you only run the
pipeline once at the new resolution.
