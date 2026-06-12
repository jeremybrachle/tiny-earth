# Master Prompt: Tiny Semantic Earth — Documentation Generator

You are a technical documentation agent. Your job is to generate a set of
five markdown files for a software portfolio project called **Tiny Semantic Earth**.

Do not write any code. Only produce the requested markdown files, fully written
with real content. No placeholder text, no "[insert here]", no stubs.

---

## Project Summary

Tiny Semantic Earth is an open-source research and game-development project
that compresses real-world geographic data into a tiny, fully walkable voxel
planet while preserving human recognition of Earth's geography.

The core research question is:

> "What is the minimum amount of geographic information required for a human to
> instantly recognize Earth while still being able to walk around the entire
> planet in a few minutes?"

This is NOT a Minecraft clone. The novel contribution is a **semantic
compression engine** that ranks and filters real-world geographic features
(from OpenStreetMap and Natural Earth datasets) by importance and cultural
salience, then projects the survivors onto a tiny walkable sphere.

The project is a portfolio piece for a software engineer with 6 years of
professional experience (healthcare IT + insurance), demonstrating GIS data
pipelines, game engine integration, procedural generation, and original
research framing.

---

## What This Is (And Is Not)

| This IS | This IS NOT |
|---|---|
| A semantic compression engine | A Minecraft clone |
| A playable voxel globe | A 1:1 Earth recreation |
| A GIS + game engine integration demo | A flight simulator |
| An open-source portfolio project | A commercial adaptation of any franchise |
| A data-driven research artifact | A noise-based terrain generator |

No copyrighted assets, names, code, dialogue, or story elements from any
existing franchise will be used. All inspiration is conceptual only.

---

## Tone and Audience

Each document should have:
- An **executive summary** at the top (3–5 sentences, accessible to hiring
  managers and non-engineers)
- **Technical depth** below that for engineers reading the repo

Write in clear, confident technical prose. Not overly formal. This is a
personal project with research ambitions, not a corporate spec.

---

## Technical Decisions (Locked In — Do Not Re-Open)

### Game Engine: Godot 4.x

Use **Godot 4.x** with GDScript for rapid game logic and C# for
performance-critical systems (chunk generation, gravity physics).

Rationale (include this in docs where relevant):
- Fully open source, MIT licensed — no runtime fees, no licensing drama
- Native C# support for hot paths
- Strong 3D voxel community tooling
- No Unity-style surprise fee risk for a public portfolio demo

Note: `josebasierra/voxel-planets` (MIT licensed) is a Unity/C# reference
implementation. Because Godot was chosen, its code cannot be directly reused,
but its chunk management and LOD architecture patterns are instructive and
must be attributed per MIT license terms. Document this in REFERENCES.md.

### Visual Style: Hybrid Voxel + Low-Poly

Terrain is fully voxelized (cube sphere chunk system). Iconic landmarks
(Eiffel Tower, Statue of Liberty, Great Pyramid, etc.) are represented as
hand-crafted low-poly meshes placed by the pipeline at correct geographic
coordinates. This hybrid approach avoids the "sad rectangle Eiffel Tower"
problem of pure voxels while keeping terrain consistent and mineable.

The Bowerbyte "Blocky Planet" article specifically informed this decision by
documenting the cube-sphere distortion problem and practical limits of pure
voxel landmark representation.

### Data Pipeline: Python 3.11+

The pipeline lives in `pipeline/` inside the monorepo and is a fully separate
concern from the game engine. It transforms raw geographic data into
planet-ready assets.

**Python libraries (all include rationale in PIPELINE.md):**

| Library | Purpose |
|---|---|
| `GDAL` | Core raster/vector I/O, coordinate reprojection |
| `Rasterio` | Read/write GeoTIFF elevation and land mask rasters |
| `GeoPandas` | Vector data (coastlines, roads, cities, rivers) |
| `Shapely` | Geometry operations and spatial filtering |
| `NumPy` | Array math for voxel grid construction |
| `Pillow` | Export processed masks as PNG for Godot import |
| `PyYAML` | Pipeline configuration files |
| `requests` / `httpx` | Overpass API and Wikipedia Pageviews API calls |

### Coordinate System

All internal game engine coordinates use **cube face + local UV + depth**:

```
(face: int, u: float, v: float, depth: int)
```

Geographic coordinates (WGS84 lat/lon) are converted to cube face UV
coordinates entirely within the Python pipeline. Godot never touches raw
lat/lon — that is Python's problem. Document this boundary clearly.

### Planet Geometry: Cube Sphere

Six cube faces projected onto a sphere surface. Each face is an N×N grid
of surface voxels. Gives uniform voxel density across the planet, unlike
lat/lon grids which degenerate at the poles.

**Chunk system:**
- Chunk size: 16³ voxels (fixed — changing this mid-project breaks everything)
- Planet resolution: 256 surface voxels per cube face edge
- Estimated total chunks: ~1,500 at base resolution
- LOD: explicitly deferred past Phase 2 (note this in ROADMAP.md)

### Serialization Format

Pipeline outputs two artifact types:

**1. Scored GeoJSON** (`data/exports/features.geojson`) — output of Python
pipeline, consumed by Godot at import time. Each feature carries:

```json
{
  "type": "Feature",
  "geometry": { "type": "Point", "coordinates": [lon, lat] },
  "properties": {
    "name": "Paris",
    "feature_type": "city",
    "importance_score": 0.94,
    "population": 2161000,
    "cultural_salience_index": 0.88,
    "geographic_uniqueness": 0.72,
    "transport_hub_rank": 0.81,
    "cube_face": 2,
    "face_u": 0.531,
    "face_v": 0.448
  }
}
```

**2. Binary voxel chunks** (`engine/planet/faces/face_N/chunk_X_Y.bin`) —
raw voxel data consumed by Godot at runtime:
- Format: `uint8` material ID per voxel, row-major XYZ order
- Compression: zlib per chunk file
- Chunk size: 16³ = 4,096 bytes uncompressed per chunk

### Voxel Material IDs

```
0   = Air
1   = Ocean
2   = Land (generic)
3   = Sand / Desert
4   = Grass / Temperate
5   = Forest
6   = Snow / Ice / Tundra
7   = Rock / Mountain
8   = Urban / City
9   = Road / Rail
10  = Interior Rock (future mining layer)
255 = Reserved
```

### CI / Testing

GitHub Actions workflow runs `pytest` on every push to `main`. Pipeline
math (especially cube-sphere projection) must have unit tests before Phase 1
begins. No exceptions.

---

## Monorepo Structure

Use this exact layout in all documents that reference file paths:

```
tiny-earth/
├── README.md
├── REFERENCES.md
├── ATTRIBUTION.md          # third-party license obligations
├── LICENSES.md             # full text of third-party licenses
│
├── docs/
│   ├── PIPELINE.md
│   ├── ROADMAP.md
│   ├── RESEARCH.md
│   └── adr/                # Architecture Decision Records
│       ├── 001-engine-godot.md
│       ├── 002-cube-sphere.md
│       ├── 003-python-pipeline.md
│       ├── 004-chunk-format.md
│       └── 005-hybrid-visual-style.md
│
├── pipeline/               # Python: OSM → scored GeoJSON → planet-ready data
│   ├── pyproject.toml
│   ├── requirements.txt
│   ├── config/
│   │   └── planet.yaml     # resolution, chunk size, compression thresholds
│   ├── src/
│   │   ├── download.py     # fetch raw datasets
│   │   ├── landmask.py     # raster → land/ocean boolean grid
│   │   ├── elevation.py    # DEM → normalized height array
│   │   ├── biomes.py       # biome polygon → material ID per voxel
│   │   ├── fetch_osm.py    # Overpass API queries
│   │   ├── fetch_wiki.py   # Wikipedia Pageviews API
│   │   ├── score.py        # importance scoring formula
│   │   ├── compress.py     # configurable feature count cutoff
│   │   ├── cube_sphere.py  # lat/lon ↔ cube face UV projection math
│   │   └── export.py       # write GeoJSON + binary chunk files
│   └── tests/
│       ├── test_cube_sphere.py
│       ├── test_score.py
│       └── test_export.py
│
├── engine/                 # Godot 4 project
│   ├── project.godot
│   ├── scenes/
│   ├── scripts/
│   │   ├── planet/
│   │   │   ├── planet.gd
│   │   │   ├── cube_face.gd
│   │   │   ├── chunk.gd
│   │   │   └── chunk_loader.gd
│   │   ├── player/
│   │   │   ├── player.gd
│   │   │   └── gravity.gd
│   │   └── world/
│   │       └── world.gd
│   ├── assets/
│   │   ├── landmarks/      # low-poly landmark meshes (.glb)
│   │   └── materials/
│   └── planet/             # generated output from pipeline (gitignored raw)
│       └── faces/
│
├── data/
│   ├── raw/                # gitignored — downloaded source data
│   ├── processed/          # intermediate pipeline outputs
│   └── exports/            # final GeoJSON and chunk files
│
├── research/
│   └── compression_experiments/
│
└── .github/
    └── workflows/
        └── pipeline-test.yml
```

---

## Reference Sources

All of the following must appear in REFERENCES.md with their URLs, licenses,
and relevance notes exactly as described. Organize them into sections as
specified in the REFERENCES.md instructions below.

### Reference Projects (Study Only — No Code Reuse)

**1. Blocky Planet — Making Minecraft Spherical** (Bowerbyte)
- URL: https://www.bowerbyte.com/posts/blocky-planet/
- License: No open license published — reference and study only. Do not copy
  implementation, diagrams, or text.
- Relevance: Primary technical reference for the core problem of mapping cubic
  voxels onto a sphere surface without shader fakery. Documents the
  cube-sphere distortion problem and practical mitigation approaches. Directly
  informed the decision to use a hybrid voxel + low-poly style rather than
  pure voxels for landmarks.

**2. ddupont808/planetcraft**
- URL: https://github.com/ddupont808/planetcraft
- License: No license found — reference and study only. Do not copy any code.
- Relevance: Proof-of-concept Unity/C#/HLSL implementation of a playable
  spherical voxel planet using 6-grid cube-to-sphere mapping with dynamic
  chunk subdivision at altitude. Confirms technical feasibility of the
  approach. Architecture is instructive; code cannot be reused.

### Legally Reusable Projects

**3. josebasierra/voxel-planets**
- URL: https://github.com/josebasierra/voxel-planets
- License: MIT — legally usable with attribution
- Relevance: MIT-licensed Unity/C# implementation of voxel planet generation
  with octree-based LOD, inspired by Astroneer. The only legally reusable
  reference implementation in scope. Because this project uses Godot (not
  Unity), code cannot be directly ported, but chunk management and LOD
  patterns are a legitimate architectural reference. Must be attributed per
  MIT license terms in ATTRIBUTION.md.

### Open Data Sources

**4. Natural Earth**
- URL: https://www.naturalearthdata.com/
- License: Public Domain — no restrictions
- Relevance: Land/ocean shapefiles, coastlines, country borders, and river
  data used for Earth silhouette projection and feature boundaries.

**5. OpenStreetMap / Overpass API**
- URL: https://overpass-api.de/
- License: Open Database License (ODbL) — attribution required; share-alike
  applies to the database, not to derivative game content
- Relevance: Source of cities, capitals, world heritage sites, airports, and
  landmark coordinates for the semantic compression pipeline.

**6. Wikipedia Pageviews API**
- URL: https://wikitech.wikimedia.org/wiki/Analytics/AQS/Pageviews
- License: Creative Commons Attribution (CC-BY) — attribution required
- Relevance: Used as a cultural salience proxy in the importance scoring
  formula. Annual pageview count for a location's Wikipedia article serves
  as a quantifiable measure of global cultural recognition.

**7. ETOPO Global Relief Model** (NOAA)
- URL: https://www.ncei.noaa.gov/products/etopo-global-relief-model
- License: Public Domain
- Relevance: Global elevation and bathymetry data used to generate terrain
  height variation in the voxel planet (mountains, valleys, ocean depth).

**8. WWF Terrestrial Ecoregions**
- URL: https://www.worldwildlife.org/publications/terrestrial-ecoregions-of-the-world
- License: Open for non-commercial use with attribution
- Relevance: Biome classification polygons used to assign voxel material IDs
  (desert, tundra, forest, etc.) across the planet surface.

### Academic / Technical References

**9. Cube-to-sphere mapping mathematics**
- URL: https://mathproofs.blogspot.com/2005/07/mapping-cube-to-sphere.html
- License: Academic reference — mathematical formulas are not copyrightable.
  No code copied.
- Relevance: Core mathematical reference for projecting cube face UV
  coordinates onto a unit sphere surface without polar distortion.

### Tools and Libraries

**10. Godot Engine 4.x**
- URL: https://godotengine.org/
- License: MIT

**11. Python (3.11+)**
- URL: https://www.python.org/
- License: PSF License (open source compatible)

**12. GDAL**
- URL: https://gdal.org/
- License: MIT

**13. Rasterio**
- URL: https://rasterio.readthedocs.io/
- License: BSD-3-Clause

**14. GeoPandas**
- URL: https://geopandas.org/
- License: BSD-3-Clause

**15. Binvox** (optional, for voxelizing reference 3D meshes)
- URL: https://www.patrickmin.com/binvox/
- License: Freeware — not open source. Use only for internal asset conversion,
  not redistribution.

---

## Importance Scoring Formula

The scoring formula is an original formulation for this project. It is not
copied from any source. Include it in full in both PIPELINE.md and RESEARCH.md.

```
score(f) = (w_pop  × log(population(f) + 1))
         + (w_sal  × cultural_salience_index(f))
         + (w_uniq × geographic_uniqueness(f))
         + (w_conn × transport_hub_rank(f))
```

Where:

| Variable | Type | Source | Description |
|---|---|---|---|
| `population(f)` | integer | OSM / GeoNames | Raw population of city or metro area |
| `cultural_salience_index(f)` | float [0,1] | Wikipedia Pageviews API | Normalized annual Wikipedia pageview count for the feature's article |
| `geographic_uniqueness(f)` | float [0,1] | Computed | Inverse of local feature density — isolated features score higher than clustered ones |
| `transport_hub_rank(f)` | float [0,1] | OSM / IATA | Normalized rank of airport passenger volume or major rail hub status |
| `w_pop`, `w_sal`, `w_uniq`, `w_conn` | float | Config | Tunable weights, default 0.4 / 0.3 / 0.2 / 0.1 |

Log transform on population prevents mega-cities from dominating the score
while still preserving population as a meaningful signal.

Default weights are a starting point. The compression experiment (Phase 6 /
RESEARCH.md) tunes these and measures recognizability impact.

---

## Development Phases

Use all 9 phases (0–8) plus stretch goals in ROADMAP.md. Each phase must
include: goals, key deliverables, and a clear "done when" success criterion.

### Phase 0 — Foundation
Goals: repo exists, decisions are documented, pipeline skeleton runs.

Key deliverables:
- Git repo initialized with full monorepo layout
- `docs/adr/` — one ADR per major decision (001–005)
- `pipeline/config/planet.yaml` — defines resolution, chunk size, compression
  thresholds
- `pipeline/src/cube_sphere.py` — lat/lon ↔ cube face UV projection math,
  fully unit tested
- `pipeline/src/export.py` — writes empty chunk stubs in correct binary format
- `.github/workflows/pipeline-test.yml` — CI runs pytest on every push
- `ATTRIBUTION.md`, `LICENSES.md`, `REFERENCES.md` — populated, not stubs

Done when: `python pipeline/src/export.py` produces a valid (empty) planet
directory and all tests pass in CI.

---

### Phase 1 — Walkable Sphere (No Earth Data)
Goals: player walks around a tiny planet. Nothing else matters yet.

Key deliverables:
- Godot scene with a procedurally generated sphere (mesh placeholder, not
  voxels yet)
- Local radial gravity: `gravity = (center - position).normalized() × G`
  recomputed every physics frame
- Player controller that aligns to planet surface normal
- Camera follows player with correct "up" orientation
- Player completes a full orbit on foot without clipping or losing orientation

Done when: a player can walk around the entire planet in under 2 minutes
without motion sickness or orientation glitches.

---

### Phase 2 — Voxel Planet (No Earth Data)
Goals: replace the mesh sphere with a voxelized cube sphere.

Key deliverables:
- `cube_face.gd` — generates one face of the cube sphere as a voxel mesh
- All 6 faces generated and seamed correctly (no visible gaps at face edges)
- `chunk.gd` — chunk system loads/unloads based on player proximity
- `chunk_loader.gd` — reads `.bin` chunk files from `engine/planet/faces/`
- Player walks correctly on voxel surface
- Pipeline exports a uniform solid sphere (all voxels = Land material)

Technical note for docs: seam handling at cube face edges is the hardest
part of this phase. The chunk size of 16³ is fixed from this point forward.

Done when: voxelized planet loads from pipeline output and player walks on
it without gaps or seam artifacts.

---

### Phase 3 — Earth Silhouette (First Real Data)
Goals: recognizable continents appear. First contact with real Earth data.

Pipeline additions:
- `download.py` — fetch Natural Earth 110m land polygon shapefiles
- `landmask.py` — rasterize polygons to lat/lon grid → cube face UV grid
- `export.py` — write Land vs Ocean material IDs into chunk binary files

Key deliverables:
- Pipeline downloads and processes Natural Earth land polygons
- Land/ocean mask projected onto cube sphere voxel grid
- Ocean and land voxels rendered with distinct materials in Godot
- Full pipeline run + Godot load shows recognizable Earth silhouette

Done when: a person looking at the planet from orbit immediately says
"that's Earth."

---

### Phase 4 — Elevation
Goals: mountains exist. Earth has terrain variation.

Pipeline additions:
- `elevation.py` — ETOPO DEM → normalized height array → voxel column height

Key deliverables:
- Pipeline fetches ETOPO global relief data
- Elevation remapped to voxel layer count (e.g., sea level = 1, Everest = 8)
- Voxel columns vary in height according to real elevation data
- Himalayas, Rockies, Andes visually distinct from plains

Note: ocean depth is flat (single voxel layer) in this phase. Hollow oceans
and cave systems are explicitly deferred.

Done when: mountain ranges are identifiable by sight while walking the planet.

---

### Phase 5 — Biomes
Goals: Earth has color and climate variation.

Pipeline additions:
- `biomes.py` — WWF ecoregion polygons → material ID per surface voxel

Key deliverables:
- Biome classification layer projected onto cube sphere grid
- Material IDs mapped to voxel colors in Godot (desert = sand, tundra = snow)
- Equatorial belt visually distinct from polar regions
- Sahara, Amazon, Siberia, Antarctica all recognizable by color

Done when: Earth's major biome zones are distinguishable from orbit.

---

### Phase 6 — Cities and Semantic Compression Engine
Goals: civilization appears. The scoring formula runs for the first time.

Pipeline additions:
- `fetch_osm.py` — Overpass API queries for cities, capitals, airports,
  world heritage sites
- `fetch_wiki.py` — Wikipedia Pageviews API calls for cultural salience scores
- `score.py` — full importance scoring formula with configurable weights
- `compress.py` — configurable feature count cutoff (e.g., top 500 → top 50
  → top 10)

Key deliverables:
- OSM + Wikipedia data fetched and cached locally (respect rate limits)
- Scoring formula runs against all candidate features
- Configurable `compression_level` parameter in `planet.yaml`
- Top ~200 cities rendered as Urban material voxel clusters in Godot
- City cluster size proportional to importance score
- `ATTRIBUTION.md` updated with OSM ODbL and Wikipedia CC-BY attribution

Critical legal note: OSM attribution is legally required by ODbL. This is
not optional and must appear in the running application, not just the docs.

Done when: New York, London, Tokyo, and São Paulo are findable by walking to
the correct continent.

---

### Phase 7 — Landmark Placement
Goals: iconic structures exist. Geographic recognition becomes instant.

Pipeline additions:
- `landmarks.py` — curated landmark list → cube face UV coordinates → GeoJSON
  export for Godot

Key deliverables:
- Curated list of 20–30 globally recognizable landmarks with coordinates
- Each landmark represented as a hand-crafted low-poly mesh (.glb in Godot)
- Pipeline places landmarks at correct geographic coordinates on planet surface
- Examples: Eiffel Tower, Statue of Liberty, Great Pyramid, Golden Gate
  Bridge, Sydney Opera House, Colosseum, Taj Mahal

Technical note: landmarks are low-poly meshes, not voxels. This is the
hybrid visual style decision. Keep mesh complexity low (< 500 tris each)
to match the toy-scale aesthetic of the planet.

Done when: a player walks toward a pointed structure in France and knows
exactly where they are.

---

### Phase 8 — Visual Polish and Portfolio Release
Goals: it looks good enough to ship. The demo is presentable.

Key deliverables:
- Skybox / space backdrop in Godot
- Atmospheric color grading (day/night optional)
- Godot export builds for Windows, macOS, Linux
- Itch.io or GitHub Releases page with playable download
- README.md updated with screenshots and demo GIF
- All attribution and legal files verified complete

Shippable demo pass/fail criteria:
- Launches and runs on Windows, macOS, Linux without crashing
- Player can walk around the full planet surface
- Recognizable continents, elevation, biomes visible
- At least 10 landmarks placed and visible
- Loads in under 10 seconds on a mid-range laptop
- OSM attribution visible in game UI or credits screen

Done when: a stranger can download and run it without a README.

---

### Stretch Goals (Post-Phase 8)

**Stretch A — WASM Export**
- Export Godot project to WebAssembly
- Host playable version on itch.io or GitHub Pages
- No additional dependencies needed (Godot 4 supports WASM export natively)

**Stretch B — User Recognition Study**
- Show screenshots of the planet at each compression level to test subjects
- Ask: "Which continent are you on?" and "Which city is nearest?"
- Record accuracy vs. feature count
- Plot recognizability curve

**Stretch C — Research Paper**
- Target venue: IEEE VIS, ACM CHI, or GIScience conference
- Working title: "Semantic Compression of Geographic Information for
  Interactive Playable Worlds"
- Key figure: recognizability curve (feature count vs. identification accuracy)

**Stretch D — Tiny Bay Prototype**
- Apply the same pipeline to a single bay area (San Francisco Bay, Tokyo Bay)
- Test whether local-scale semantic compression works with street-level data
- Potential separate repo

---

## Files to Generate

Generate each of the following five files completely. Separate them clearly
with a line like `--- FILE: filename.md ---`.

---

### FILE 1: README.md

Structure:
- Project title: **Tiny Semantic Earth**
- Tagline (one punchy line)
- 1-paragraph elevator pitch accessible to hiring managers
- The core research question, quoted and prominent
- ASCII pipeline diagram showing the full flow from raw data to playable planet
- Phases overview table (Phase 0–8 + stretch goals, one line each)
- "How to run" section (note Python 3.11+ and Godot 4.x requirements; mark
  exact setup as TBD pending Phase 0 completion)
- Legal/attribution summary paragraph referencing REFERENCES.md, ATTRIBUTION.md
- Links to all docs: PIPELINE.md, ROADMAP.md, RESEARCH.md, REFERENCES.md,
  ATTRIBUTION.md, LICENSES.md
- Note that ARCHITECTURE.md is planned but not yet written

---

### FILE 2: PIPELINE.md

Structure:
- Executive summary (3–5 sentences for non-engineers)
- Full pipeline stage descriptions:

  **Stage 1 — Fetch**
  Sources: Natural Earth shapefiles (land mask, coastlines, rivers, borders),
  OSM via Overpass API (capitals, major cities, world heritage sites,
  airports, landmarks), ETOPO elevation GeoTIFF, WWF biome polygons.
  Note caching strategy: all raw data written to `data/raw/` and gitignored.
  Overpass API rate limits: respect `1 request / 1s`, use `data/raw/` cache
  to avoid re-fetching. Wikipedia Pageviews: respect 100 req/s limit, batch
  requests where possible.

  **Stage 2 — Enrich**
  Fetch Wikipedia annual pageview counts for each candidate feature.
  Normalize to [0,1] range across the full candidate set to produce
  `cultural_salience_index`. Document the normalization method (min-max).

  **Stage 3 — Score**
  Apply the full importance scoring formula (reproduce it in full here with
  variable definitions and the weight table). Explain each term's purpose
  and data source. Note that weights are tunable via `planet.yaml`.

  **Stage 4 — Compress**
  Apply configurable feature count cutoff from `planet.yaml`. Document the
  concept of the recognizability curve: as cutoff decreases, geographic
  information loss increases. This is the core research variable.
  Example cutoffs to document: 1000 features, 500, 200, 50, 10.

  **Stage 5 — Export**
  Output 1: `data/exports/features.geojson` — scored feature set with full
  property schema (reproduce the GeoJSON schema from the technical decisions
  section above).
  Output 2: binary chunk files (`engine/planet/faces/face_N/chunk_X_Y.bin`)
  — uint8 material IDs, zlib compressed, chunk-aligned 16³ blocks.

- Data format specs section: show the full GeoJSON property schema and
  binary chunk format
- API rate limit and caching notes
- Legal/attribution notes for each data source with URLs and license types

---

### FILE 3: REFERENCES.md

Organize into these five sections:

1. **Open Data Sources** — Natural Earth, OpenStreetMap/Overpass, Wikipedia
   Pageviews API, ETOPO, WWF Terrestrial Ecoregions

2. **Reference Projects (Study Only — No Code Reuse)** — Bowerbyte Blocky
   Planet, ddupont808/planetcraft. For each: explain clearly that the license
   status means no code may be copied, but architecture and approach may be
   studied.

3. **Legally Reusable Projects** — josebasierra/voxel-planets (MIT). Explain
   that MIT requires attribution, note it's Unity-based so code won't port
   directly to Godot, but architectural patterns are a legitimate reference.
   Include the required MIT attribution text.

4. **Academic / Technical References** — cube-to-sphere mapping math
   (mathproofs.blogspot.com). Note that mathematical formulas are not
   copyrightable; the reference is for citation and credit only.

5. **Tools and Libraries** — Godot 4 (MIT), Python 3.11+ (PSF), GDAL (MIT),
   Rasterio (BSD-3), GeoPandas (BSD-3), Binvox (freeware, not open source —
   internal use only).

For every entry include: name, URL, license, and one-sentence relevance note.

---

### FILE 4: ROADMAP.md

Structure:
- Executive summary (3–5 sentences)
- Full phase table: Phase 0–8 with goals, key deliverables, and "done when"
  success criteria (use the phase definitions from the development phases
  section above — reproduce them in full, not summarized)
- Weekend milestone table: ~9 weekends, one concrete deliverable per weekend
  (start from Phase 0 Week 1 through Phase 3 at minimum; mark Phase 4+
  as estimates)
- Deferred decisions table: items explicitly parked until after Phase 2

  | Decision | Why Deferred |
  |---|---|
  | LOD (level of detail) | Not needed until planet resolution increases |
  | Chunk streaming distance tuning | Validate chunk system first |
  | Mining / hollow planet interior | Validate surface layer first |
  | Multiplayer | Out of scope for v1 portfolio demo |
  | Mobile / web export | Validate desktop first (WASM is a stretch goal) |
  | Ocean depth / bathymetry | Flat ocean floor sufficient for Phase 3 |

- Stretch goals section (WASM export, user study, research paper, Tiny Bay)
- Definition of shippable demo (the Phase 8 pass/fail checklist)

---

### FILE 5: RESEARCH.md

Structure:
- Executive summary framing this as a novel research contribution (not just
  a game)
- Background section: why geographic recognition is interesting, what
  "semantic compression" means in a geographic context, and how this differs
  from traditional map generalization
- Core hypothesis: geographic features have a measurable "recognizability
  threshold" — there exists a minimum feature set F* such that for any
  feature set F where |F| ≥ |F*|, human geographic recognition accuracy
  exceeds some threshold θ. Below |F*|, accuracy drops sharply.
- Scoring formula section: reproduce the full formula with variable
  definitions, weight table, and explanation of each term's contribution
  to recognizability
- Compression ratio concept: define the compression ratio as
  |retained features| / |candidate features| and describe the expected
  shape of the recognizability curve (likely sigmoidal — sharp drop at a
  critical threshold)
- Experimental design section:
  - Independent variable: compression ratio (number of retained features)
  - Dependent variable: geographic recognition accuracy
  - Task: show a participant a screenshot of the compressed globe; ask
    "Which continent are you on?" and "Name the nearest city or landmark"
  - Measure: % correct identification at each compression level
  - Sample: small-n pilot (10–20 participants); document as a pilot study
  - Expected result: accuracy near 100% at 500+ features, drops sharply
    below ~50 features
- Research framing: "Semantic Compression of Geographic Information for
  Interactive Playable Worlds"
  - Potential venues: IEEE VIS, ACM CHI, GIScience, or CHI Play
  - Novel contribution: the scoring formula + recognizability curve +
    empirical threshold measurement
- Open questions and future directions:
  - Does the optimal feature set vary by culture/geography of the observer?
  - Can the pipeline generalize to fictional or historical worlds?
  - What is the minimum landmark set vs. minimum terrain set?
  - Can ML replace the hand-tuned scoring formula?

---

Generate all 5 files now, fully written, no stubs, no placeholders.