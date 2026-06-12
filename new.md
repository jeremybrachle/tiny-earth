# Project Seed: Tiny Semantic Earth

## Executive Summary

Tiny Semantic Earth is an open-source research and game-development project that compresses real-world geographic data into a tiny, fully walkable voxel planet while preserving human recognition of Earth's geography.

The core research question is:

> **What is the smallest playable representation of Earth that still feels like Earth?**

The project is a **semantic compression engine** — not a terrain generator, not a Minecraft clone, not a flight simulator. It answers the question: *how much geographic information can be removed before people stop recognizing the planet?*

---

## What This Is (And Is Not)

| This IS | This IS NOT |
|---|---|
| A semantic compression engine | A Minecraft clone |
| A playable voxel globe | A 1:1 Earth recreation |
| A GIS visualization tool | A flight simulator |
| An open-source portfolio project | A commercial adaptation of any franchise |
| A data-driven research artifact | A procedural noise terrain generator |

**Legal note:** No copyrighted assets, names, code, dialogue, or story elements from any existing franchise will be used. All inspiration is conceptual only.

---

## Core Design Philosophy

Traditional GIS-to-game pipeline:

```
Earth
↓ huge raw dataset
Game World (1:1 or scaled)
```

Tiny Semantic Earth pipeline:

```
Earth
↓ semantic compression (Python)
Meaning Layer (what matters)
↓ voxel generation (Godot)
Tiny Playable Planet
```

The innovation is **not** spherical rendering.
The innovation is the extraction of *meaning* from geographic data and discarding everything else — like compressing a symphony down to its melody and seeing if you can still hum it.

---

## Target Audiences

| Audience | Hook |
|---|---|
| Voxel / Minecraft players | "Walk around Earth in five minutes." |
| GIS enthusiasts | "A playable globe generated from real OpenStreetMap data." |
| Data science / ML | "What is the minimum dataset required for human geographic recognition?" |
| Game developers | "A reusable pipeline for generating tiny planets from any dataset." |
| Educational users | "Explore Earth as a toy-sized interactive globe." |

---

## Long-Term Vision

Earth is the first dataset. The same pipeline could eventually generate:

- Fantasy worlds from novel text
- Historical maps from archival data
- Fictional settings from structured descriptions
- Procedurally generated alien planets

The end goal is a generic **World Compression Engine**. Earth is the proof of concept.

---

## Technical Stack (Decided — Not Up For Debate)

### Game Engine
**Godot 4.x** (GDScript + C# where performance requires it)

Rationale:
- Fully open source, no licensing fees or runtime royalties
- Native C# support for performance-critical systems (chunk generation, gravity)
- GDScript for rapid prototyping of game logic
- No Unity-style runtime fee risk for a public demo
- Strong 3D voxel community tooling

### Data Pipeline
**Python 3.11+** with:

| Library | Purpose |
|---|---|
| `GDAL` | Core raster/vector I/O, reprojection |
| `Rasterio` | Read/write GeoTIFF elevation and land mask rasters |
| `GeoPandas` | Vector data (coastlines, roads, cities, rivers) |
| `Shapely` | Geometry operations and spatial filtering |
| `NumPy` | Array math for voxel grid construction |
| `Pillow` | Export processed masks as PNG for Godot import |
| `PyYAML` | Pipeline configuration files |

### Geographic Data Sources

| Dataset | Source | License | Used For |
|---|---|---|---|
| Land/Ocean mask | Natural Earth | Public Domain | Continent shapes |
| Elevation (DEM) | SRTM / ETOPO | Public Domain | Mountain heights |
| Coastlines, borders, rivers | Natural Earth | Public Domain | Recognizable features |
| Cities, roads, landmarks | OpenStreetMap | ODbL (with attribution) | Civilization layer |
| Biome classification | WWF Terrestrial Ecoregions | Open | Biome coloring |

### Voxel Asset Pipeline
**Binvox** — converts 3D mesh landmarks into voxel representations for in-world placement.

### Serialization Format
Planet data serialized as:

```
planet/
  metadata.yaml         # planet radius, chunk size, resolution
  faces/
    face_0/
      chunk_0_0.bin     # raw voxel chunk (binary, zlib compressed)
      chunk_0_1.bin
      ...
    face_1/
    ...
```

Binary chunk format: `uint8` material ID per voxel, zlib compressed, chunk-aligned.

---

## Architecture

### Planet Geometry: Cube Sphere

```
6 cube faces
↓ project vertices onto sphere surface
↓ subdivide uniformly
Seamless spherical mesh
```

Each face is an N×N grid projected onto the sphere. This gives uniform voxel density across the planet surface — unlike latitude/longitude grids which go to hell at the poles.

### Coordinate System

All internal coordinates use **cube face + local UV + depth**:

```
(face: int, u: float, v: float, depth: int)
```

Geographic coordinates (lat/lon) are converted to cube face coordinates by the Python pipeline before any data enters Godot. Godot never touches raw WGS84 — that's a Python problem.

### Chunk System

```
Planet
└── Face[6]
    └── Chunk[N×N] per face
        └── Voxel[CHUNK_SIZE³]
```

- **Chunk size:** 16³ voxels (tunable)
- **Planet resolution:** configurable — start at 256 surface voxels per face edge (~1,500 chunks total), tune up from there
- **LOD:** Not in scope for Phase 1–3. Add in Phase 4+ if needed.

### Local Gravity

```
gravity_direction = (planet_center - player_position).normalized()
```

Every rigid body computes its own "down" vector. Player controller aligns to local gravity. This is the core mechanic that makes walking around the planet feel right.

### Voxel Material IDs

```
0   = Air
1   = Ocean
2   = Land (generic)
3   = Sand / Desert
4   = Grass
5   = Forest
6   = Snow / Ice
7   = Rock / Mountain
8   = Urban / City
9   = Road
10  = Interior Rock (mining layer)
255 = Reserved
```

---

## Repository Layout

```
tiny-semantic-earth/
├── README.md
├── REFERENCES.md          # conceptual inspirations only
├── ATTRIBUTION.md         # OSM, Natural Earth, etc.
├── LICENSES.md            # all third-party licenses
│
├── pipeline/              # Python data pipeline
│   ├── pyproject.toml
│   ├── requirements.txt
│   ├── config/
│   │   └── planet.yaml    # resolution, chunk size, output path
│   ├── src/
│   │   ├── download.py    # fetch raw datasets
│   │   ├── landmask.py    # raster → land/ocean boolean grid
│   │   ├── elevation.py   # DEM → normalized height array
│   │   ├── biomes.py      # biome classification → material IDs
│   │   ├── cities.py      # OSM city points → importance ranking
│   │   ├── landmarks.py   # OSM landmarks → voxel asset placement
│   │   ├── compress.py    # semantic compression / importance filtering
│   │   ├── cube_sphere.py # lat/lon → cube face UV projection
│   │   └── export.py      # write planet/ chunk files for Godot
│   └── tests/
│
├── godot/                 # Godot 4 project
│   ├── project.godot
│   ├── src/
│   │   ├── planet/
│   │   │   ├── planet.gd          # root planet node
│   │   │   ├── cube_face.gd       # one face of the cube sphere
│   │   │   ├── chunk.gd           # voxel chunk logic
│   │   │   └── chunk_loader.gd    # streaming chunk I/O
│   │   ├── player/
│   │   │   ├── player.gd          # controller
│   │   │   └── gravity.gd         # local gravity system
│   │   └── world/
│   │       └── world.gd           # scene root, planet + player
│   ├── assets/
│   │   └── voxel_materials.tres
│   └── planet/                    # generated output from pipeline
│
├── docs/
│   ├── adr/               # Architecture Decision Records
│   │   ├── 001-engine-godot.md
│   │   ├── 002-cube-sphere.md
│   │   ├── 003-python-pipeline.md
│   │   └── 004-chunk-format.md
│   └── research/
│       └── compression-notes.md
│
└── .github/
    └── workflows/
        └── pipeline-test.yml  # CI for Python pipeline unit tests
```

---

## Implementation Phases

### Phase 0 — Foundation
**Goal:** Repo is real. Decisions are documented. Pipeline skeleton exists.

Deliverables:
- [ ] Git repo initialized with above layout
- [ ] `docs/adr/` — one ADR per major decision (engine, geometry, chunk format, pipeline)
- [ ] `pipeline/config/planet.yaml` — defines resolution constants
- [ ] `pipeline/src/cube_sphere.py` — lat/lon ↔ cube face UV math, unit tested
- [ ] `pipeline/src/export.py` — writes empty chunk stubs in correct binary format
- [ ] `pipeline/tests/` — at minimum, test the projection math
- [ ] `.github/workflows/pipeline-test.yml` — CI runs `pytest` on push
- [ ] `ATTRIBUTION.md`, `LICENSES.md`, `REFERENCES.md` — stubs with correct licenses

Done when: `python pipeline/src/export.py` produces a valid (empty) planet directory.

---

### Phase 1 — Walkable Sphere (No Earth Data)
**Goal:** Player walks around a tiny planet. Nothing else matters yet.

Deliverables:
- [ ] Godot scene with a procedurally generated sphere (can be mesh-based placeholder)
- [ ] Local radial gravity system working
- [ ] Player controller that aligns to planet surface normal
- [ ] Camera follows player with correct "up" orientation
- [ ] Player can walk all the way around without falling off or clipping

Technical notes:
- Gravity vector recomputed every physics frame: `gravity = (center - position).normalized() * G`
- This phase intentionally skips voxels — validate gravity and movement first
- Sphere radius: ~50–100 Godot units. Small enough to see curvature while walking.

Done when: You can walk around the entire planet in under 2 minutes without motion sickness.

---

### Phase 2 — Voxel Planet (No Earth Data)
**Goal:** Replace the mesh sphere with a voxelized cube sphere.

Deliverables:
- [ ] `cube_face.gd` — generates one face of the cube sphere as a voxel mesh
- [ ] All 6 faces generated and seamed correctly (no gaps at edges)
- [ ] `chunk.gd` — chunk system loads/unloads based on player proximity
- [ ] `chunk_loader.gd` — reads `.bin` chunk files from `godot/planet/` directory
- [ ] Player still walks correctly on voxel surface
- [ ] Pipeline exports a uniform solid sphere (all voxels = `Land`)

Technical notes:
- Cube sphere projection formula: normalize the cube face UV point to unit sphere
- Seam handling at face edges is the hardest part of this phase — plan for it
- `CHUNK_SIZE = 16` — don't change this mid-project, it affects everything

Done when: Voxelized planet loads from pipeline output and player walks on it.

---

### Phase 3 — Earth Land Mask (First Real Data)
**Goal:** Recognizable continents. First contact with real Earth.

Pipeline additions:
- `pipeline/src/download.py` — fetch Natural Earth land polygons
- `pipeline/src/landmask.py` — rasterize polygons to lat/lon grid → cube face grid
- `pipeline/src/export.py` — write Land vs Ocean material IDs into chunks

Deliverables:
- [ ] Pipeline downloads and processes Natural Earth 110m land polygon dataset
- [ ] Land/ocean mask projected onto cube sphere voxel grid
- [ ] Ocean voxels rendered differently from land voxels (material color)
- [ ] Running the full pipeline + loading Godot shows recognizable Earth shape

Done when: Someone looking at the planet from orbit says *"Oh that's Earth."*

---

### Phase 4 — Elevation
**Goal:** Mountains exist. Earth has terrain variation.

Pipeline additions:
- `pipeline/src/elevation.py` — ETOPO or SRTM DEM → normalized height array → voxel stack height

Deliverables:
- [ ] Pipeline fetches ETOPO 1-arc-minute elevation dataset
- [ ] Elevation remapped to voxel layer count (e.g., sea level = 1 layer, Everest = 8 layers)
- [ ] Voxel columns vary in height based on real elevation data
- [ ] Himalayas, Rockies, Andes visually distinct from plains

Technical notes:
- Remap elevation to a small integer range (0–8 extra voxel layers is enough at tiny scale)
- Ocean depth can be flat (single voxel) for now — save hollow oceans for later

Done when: You can identify mountain ranges by sight while walking.

---

### Phase 5 — Biomes
**Goal:** Earth has color. Deserts look like deserts, ice looks like ice.

Pipeline additions:
- `pipeline/src/biomes.py` — WWF ecoregion polygons → material ID per voxel

Deliverables:
- [ ] Biome classification layer projected onto cube sphere grid
- [ ] Material IDs mapped to voxel colors in Godot (desert=sand, tundra=snow, etc.)
- [ ] Equatorial belt visually different from polar regions

Done when: Earth's major climatic zones are recognizable from orbit.

---

### Phase 6 — Cities
**Goal:** Civilization exists. Major population centers are visible.

Pipeline additions:
- `pipeline/src/cities.py` — OSM city points + population data → importance ranking → top N cities

Deliverables:
- [ ] OSM city dataset filtered to top ~200 most important cities by population
- [ ] Cities rendered as Urban material voxel clusters
- [ ] City "importance" controls cluster size (NYC > village)
- [ ] `ATTRIBUTION.md` updated with OpenStreetMap ODbL attribution

Technical notes:
- OSM attribution is legally required. Do not skip this.
- Do not try to place all 8 million OSM settlements. Pick the top ~200. This is semantic compression.

Done when: You can find New York, London, Tokyo, and São Paulo by walking to the right continent.

---

### Phase 7 — Landmarks
**Goal:** Iconic structures exist. Geographic recognition becomes instant.

Pipeline additions:
- `pipeline/src/landmarks.py` — curated landmark list → voxel asset placement coordinates

Deliverables:
- [ ] Curated list of ~20–30 globally recognizable landmarks
- [ ] Each landmark hand-crafted as a voxel asset (via Binvox or manual construction)
- [ ] Assets placed at correct geographic coordinates on the planet surface
- [ ] Examples: Eiffel Tower, Statue of Liberty, Great Pyramid, Golden Gate Bridge, Sydney Opera House

Technical notes:
- Hand-crafting these is intentional. Procedural generation won't give you recognizable icons.
- Keep models at voxel scale appropriate to planet size (3–8 voxels tall for most landmarks)

Done when: You walk up to a pointy thing in France and know exactly where you are.

---

### Phase 8 — Semantic Compression Engine
**Goal:** Quantify what we actually built. Answer the research question.

Deliverables:
- [ ] `pipeline/src/compress.py` — configurable importance threshold per layer
- [ ] Pipeline accepts a `compression_level` parameter (0.0 = everything, 1.0 = bare minimum)
- [ ] At each compression level, export a planet snapshot
- [ ] `docs/research/compression-notes.md` — record what survives at each level
- [ ] Simple recognition test: show screenshots to people, ask them to identify locations

Research question answered:

> At what compression level does Earth stop feeling like Earth?

Done when: You have data showing the minimum geographic feature set for human recognition.

---

## Open Questions (Deferred Intentionally)

These are real problems, parked until after Phase 2:

| Question | Why Deferred |
|---|---|
| LOD (level of detail) | Not needed until planet size increases |
| Chunk streaming distance | Validate chunk system first |
| Mining / hollow interior | Validate surface first |
| Multiplayer | Out of scope for v1 demo |
| Mobile/web export | Validate desktop first |

---

## Definition of "Shippable Demo"

A shippable demo exists after Phase 5. It must:

- Run on Windows/macOS/Linux as a Godot export
- Allow the player to walk around the full planet
- Show recognizable continents, elevation, and biomes
- Load in under 10 seconds
- Not crash

Phases 6–8 are research extensions on top of a working demo.

---

## Legal Requirements

Maintain in repo root:

- `REFERENCES.md` — conceptual inspirations (no code, no assets copied)
- `ATTRIBUTION.md` — OpenStreetMap ODbL, Natural Earth, ETOPO, Binvox
- `LICENSES.md` — all third-party library licenses

Permitted:
- OpenStreetMap data (ODbL — attribution required, share-alike on the data)
- Natural Earth (Public Domain)
- ETOPO / SRTM elevation (Public Domain)
- MIT/BSD/Apache licensed libraries
- All original code

Not permitted:
- Assets, names, or code from proprietary games or franchises
- Paid/proprietary GIS datasets without license review