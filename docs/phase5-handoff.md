# Phase 5 Handoff — Biomes + Elevation

**Status as of 2026-06-08:** Phase 4 (elevation) and Phase 5 (biomes) are complete. Planet shows
climate-zone colors with organic boundaries and real terrain height. Two polish items remain before
moving to Phase 6.

---

## Current State

| Item | Status |
|------|--------|
| Land/ocean silhouette | ✅ Done — `ne_10m_land` shapefiles, 256×256 per face |
| E-W mirror bug | ✅ Fixed — `face_uv_to_unit` uses `-raw.y` rotation |
| Biomes | ✅ Done — `data/cache/biomes.npy`, IDs 3-6 by latitude with ±8° smooth noise |
| Elevation | ✅ Done — `data/cache/elevation.npy`, 0–8 extra voxel layers from ETOPO 2022 |
| Side-wall rendering | ✅ Done — two-pass mesh build with full face depth grid |
| Block edge outlines | ✅ Done — ShaderMaterial with UV-based edge darkening |
| Elevation collision | ✅ Done — side-wall + top-face trimesh, backface_collision=true |

---

## Remaining Issue — Elevation Collision (geometry bug)

Block outlines are done. The remaining 5.5 item is correct elevation collision. See
`docs/collision-fix-handoff.md` for the full problem description and fix approach. That document
is written for a dedicated session (Claude Opus) to solve from scratch.

---

## Controls

| Key | Action |
|-----|--------|
| Arrow keys | Walk |
| Space | Jump / fly up |
| Ctrl | Fly down (fly mode) |
| V | Toggle fly/noclip |
| E | Destroy voxel underfoot |
| F | Toggle first/third person |

---

## Pipeline Commands

```bash
cd ~/programming/tiny-earth
source pipeline/.venv/bin/activate

# Regenerate biomes (e.g. after changing latitude thresholds):
python pipeline/src/biomes.py --root .

# Re-export with biomes + elevation:
python pipeline/src/export.py --biomes --elevation --root .

# Regenerate landmask from scratch (only needed if shapefile changes):
python pipeline/src/landmask.py --root .
```

---

## Roadmap

| Phase | Status | Summary |
|---|---|---|
| 0–3 | ✅ Done | Foundation, walkable sphere, voxels, land/ocean silhouette |
| 4 | ✅ Done | Elevation from ETOPO 2022 — mountains visible |
| 5 | ✅ Done | Biomes — climate-zone colors with organic boundaries |
| **5.5** | ✅ Done | Elevation collision — side walls + backface ejection |
| **5.75** | **← next** | Water surface rendering — semi-transparent ocean shader |
| 6 | Pending | Cities + semantic compression scoring |
| 7 | Pending | Landmark meshes |
| 8 | Pending | Visual polish + playable export |
