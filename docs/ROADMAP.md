# Roadmap

## Executive Summary

Tiny Semantic Earth is planned in nine phases (0–8) that build from repo scaffolding to a polished portfolio demo. The first three phases establish the game engine foundation: physics, player movement, and the voxelized cube sphere. Phases 3 through 5 layer real Earth data — land mask, elevation, and biomes — onto the planet. Phase 6 runs the semantic compression engine for the first time. Phases 7 and 8 place iconic landmarks and ship the demo. The full arc from empty workspace to portfolio-ready release is estimated at roughly nine focused weekends of solo development.

---

## Development Phases

### Phase 0 — Foundation

**Goal:** Repo exists, decisions are documented, pipeline skeleton runs.

**Key deliverables:**
- Git repo initialized with full monorepo layout
- `docs/adr/` — one ADR per major decision (001–005)
- `pipeline/config/planet.yaml` — defines resolution, chunk size, compression thresholds
- `pipeline/src/cube_sphere.py` — lat/lon ↔ cube face UV projection math, fully unit tested
- `pipeline/src/export.py` — writes empty chunk stubs in correct binary format
- `.github/workflows/pipeline-test.yml` — CI runs `pytest` on every push to `main`
- `ATTRIBUTION.md`, `LICENSES.md`, `REFERENCES.md` — populated, not stubs

**Done when:** `python pipeline/src/export.py` produces a valid (empty) planet directory and all tests pass in CI.

---

### Phase 1 — Walkable Sphere

**Goal:** Player walks around a tiny planet. Nothing else matters yet.

**Key deliverables:**
- Godot scene with a procedurally generated sphere (mesh placeholder, not voxels yet)
- Local radial gravity: `gravity = (center - position).normalized() × G` recomputed every physics frame
- Player controller that aligns to planet surface normal
- Camera follows player with correct "up" orientation
- Player completes a full orbit on foot without clipping or losing orientation

**Done when:** A player can walk around the entire planet in under 2 minutes without motion sickness or orientation glitches.

---

### Phase 2 — Voxel Planet

**Goal:** Replace the mesh sphere with a voxelized cube sphere.

**Key deliverables:**
- `cube_face.gd` — generates one face of the cube sphere as a voxel mesh
- All 6 faces generated and seamed correctly (no visible gaps at face edges)
- `chunk.gd` — chunk system loads/unloads based on player proximity
- `chunk_loader.gd` — reads `.bin` chunk files from `engine/planet/faces/`
- Player walks correctly on voxel surface
- Pipeline exports a uniform solid sphere (all voxels = Land material)

**Technical note:** Seam handling at cube face edges is the hardest part of this phase. The chunk size of 16³ is fixed from this point forward — changing it mid-project breaks everything.

**Done when:** Voxelized planet loads from pipeline output and player walks on it without gaps or seam artifacts.

---

### Phase 3 — Earth Silhouette

**Goal:** Recognizable continents appear. First contact with real Earth data.

**Pipeline additions:**
- `download.py` — fetch Natural Earth 110m land polygon shapefiles
- `landmask.py` — rasterize polygons to lat/lon grid → cube face UV grid
- `export.py` — write Land vs Ocean material IDs into chunk binary files

**Key deliverables:**
- Pipeline downloads and processes Natural Earth land polygons
- Land/ocean mask projected onto cube sphere voxel grid
- Ocean and land voxels rendered with distinct materials in Godot
- Full pipeline run + Godot load shows recognizable Earth silhouette

**Done when:** A person looking at the planet from orbit immediately says "that's Earth."

---

### Phase 4 — Elevation

**Goal:** Mountains exist. Earth has terrain variation.

**Pipeline additions:**
- `elevation.py` — ETOPO DEM → normalized height array → voxel column height

**Key deliverables:**
- Pipeline fetches ETOPO global relief data
- Elevation remapped to voxel layer count (e.g., sea level = 1, Everest = 8)
- Voxel columns vary in height according to real elevation data
- Himalayas, Rockies, Andes visually distinct from plains

**Note:** Ocean depth is flat (single voxel layer) in this phase. Hollow oceans and cave systems are explicitly deferred.

**Done when:** Mountain ranges are identifiable by sight while walking the planet.

---

### Phase 5 — Biomes

**Goal:** Earth has color and climate variation.

**Pipeline additions:**
- `biomes.py` — WWF ecoregion polygons → material ID per surface voxel

**Key deliverables:**
- Biome classification layer projected onto cube sphere grid
- Material IDs mapped to voxel colors in Godot (desert = sand, tundra = snow)
- Equatorial belt visually distinct from polar regions
- Sahara, Amazon, Siberia, Antarctica all recognizable by color

**Done when:** Earth's major biome zones are distinguishable from orbit.

---

### Phase 6 — Cities and Semantic Compression Engine

**Goal:** Civilization appears. The scoring formula runs for the first time.

**Pipeline additions:**
- `fetch_osm.py` — Overpass API queries for cities, capitals, airports, world heritage sites
- `fetch_wiki.py` — Wikipedia Pageviews API calls for cultural salience scores
- `score.py` — full importance scoring formula with configurable weights
- `compress.py` — configurable feature count cutoff

**Key deliverables:**
- OSM + Wikipedia data fetched and cached locally (rate limits respected)
- Scoring formula runs against all candidate features
- Configurable `compression_level` parameter in `planet.yaml`
- Top ~200 cities rendered as Urban material voxel clusters in Godot
- City cluster size proportional to importance score
- `ATTRIBUTION.md` updated with OSM ODbL and Wikipedia CC-BY attribution

**Critical legal note:** OSM attribution is legally required by ODbL. It must appear in the running application, not just the docs.

**Done when:** New York, London, Tokyo, and São Paulo are findable by walking to the correct continent.

---

### Phase 7 — Landmark Placement

**Goal:** Iconic structures exist. Geographic recognition becomes instant.

**Pipeline additions:**
- `landmarks.py` — curated landmark list → cube face UV coordinates → GeoJSON export

**Key deliverables:**
- Curated list of 20–30 globally recognizable landmarks with coordinates
- Each landmark represented as a hand-crafted low-poly mesh (`.glb` in Godot)
- Pipeline places landmarks at correct geographic coordinates on planet surface
- Examples: Eiffel Tower, Statue of Liberty, Great Pyramid, Golden Gate Bridge, Sydney Opera House, Colosseum, Taj Mahal

**Technical note:** Landmarks are low-poly meshes, not voxels — this is the hybrid visual style decision. Keep mesh complexity low (< 500 tris each) to match the toy-scale aesthetic of the planet.

**Done when:** A player walks toward a pointed structure in France and knows exactly where they are.

---

### Phase 8 — Visual Polish and Portfolio Release

**Goal:** It looks good enough to ship. The demo is presentable.

**Key deliverables:**
- Skybox / space backdrop in Godot
- Atmospheric color grading (day/night optional)
- Godot export builds for Windows, macOS, Linux
- Itch.io or GitHub Releases page with playable download
- README.md updated with screenshots and demo GIF
- All attribution and legal files verified complete

**Key deliverables (updated):**
- Splash screen and main menu (new game, spawn point select, quit)
- Loading screen that displays chunk-build logs while the planet loads in the background; player sees the menu immediately rather than a blank window
- Spawn point selection — curated list of starting locations (e.g. Times Square, Eiffel Tower, Mount Everest, Amazon rainforest, Sahara, Antarctica)
- **Settings persistence** — write Audio + Graphics (water appearance) choices to `user://settings.cfg` (`ConfigFile`) so they survive a relaunch (currently session-only; added with the 7.99 water controls)
- **Shared settings menu** — extract the Audio/Graphics pages into a `settings_menu.gd` reachable from BOTH the main menu and the in-game pause menu (today they exist only in the pause menu)
- Godot export builds for Windows, macOS, Linux
- Itch.io or GitHub Releases page with playable download
- README.md updated with screenshots and demo GIF
- All attribution and legal files verified complete

**Shippable demo pass/fail checklist:**
- [ ] Launches and runs on Windows, macOS, Linux without crashing
- [ ] Splash screen and menu appear before planet finishes loading
- [ ] Player can walk around the full planet surface
- [ ] Recognizable continents, elevation, biomes visible
- [ ] At least 10 landmarks placed and visible
- [ ] Loads in under 10 seconds on a mid-range laptop
- [ ] OSM attribution visible in game UI or credits screen

**Performance note — chunk loading:** The six `CubeFace N: building 16×16 chunks` log lines
currently block the main thread before the first frame renders. Two approaches: (a) run chunk
builds on a background thread and show a loading bar on a splash screen, or (b) reduce startup
cost via a pre-baked merged mesh stored as a `.res` file that Godot loads directly. Option (b)
is faster to implement; option (a) is more flexible.

**Done when:** A stranger can download and run it without a README.

---

## Weekend Milestone Table

| Weekend | Deliverable | Phase | Status |
|---|---|---|---|
| 1 | Repo initialized; monorepo layout; ADRs 001–005 written; `planet.yaml` defined; CI running | 0 | ✅ |
| 2 | `cube_sphere.py` implemented and unit tested; `export.py` writes valid empty planet; all CI tests pass | 0 | ✅ |
| 3 | Godot scene with mesh sphere; local radial gravity working; player aligns to surface normal | 1 | ✅ |
| 4 | Player movement polished; full great-circle orbit confirmed in under 2 minutes; no orientation glitches | 1 | ✅ |
| 5 | All 6 cube faces generated and seamed; chunk system loads `.bin` files; player walks voxel surface | 2 | ✅ |
| 6 | Natural Earth land mask projected; land/ocean distinction visible; Earth silhouette recognizable from orbit | 3 | ✅ |
| 7 | ETOPO elevation integrated; biomes projected (climate-zone colors + organic boundaries); block outlines | 4–5 | ✅ |
| 7.5 | Elevation collision — player can land on and walk over elevated terrain (see collision-fix-handoff.md) | 5.5 | ✅ |
| 7.6 | Köppen-Geiger biome rewrite — all biomes 100% data-driven from Beck 2018 raster, no hardcoded bboxes | 5.75 | ✅ |
| 7.7 | Visual upgrade: space sky + stars + sun disc; PBR voxel shader; SSAO; ACES tonemapping; centralized planet scale via `planet_config.json`; altitude-aware atmosphere (day/night sky, dusk/dawn); resolution bump 256→512 | 5.9 | ✅ |
| 7.8 | Inner shell + seafloor geometry (visual); ocean water mesh; swimming detection | 6.0 | ✅ |
| 7.9 | Per-chunk collision replaces SphereShape3D; inner shell gets physics; shoreline gap closed; player can fall through excavated terrain and land on seafloor | 6.2 | ✅ |
| 7.95 | Volumetric water column: inner shell mat-2 voxels now emit translucent quads (`_add_water_to_surface` in `inner_cube_face.gd`); hollow gap resolved | 6.3 | ✅ |
| 7.95b | Water spreading on dig: removing a voxel adjacent to mat-2 fills the gap with water (Minecraft source-block semantics) | 6.3 | — |
| 7.95c | Planet drain + refill: debug keypress drains all water, refill re-floods from original ocean positions | 6.3 | — |
| 7.95d | Flowing water animation: TIME-driven UV scroll in water.gdshader | 6.3 | — |
| 7.95e | Buoyancy physics (upward force in water, Ctrl to dive); underwater fog camera effect; hollow centre room + OmniLight3D | 6.3 | — |
| 7.96 | All-planet lake water (1,355 NE10m lakes via `--lakes`); inner cavity biome ceiling art (depth-15 biome + ocean colour); inner sphere Earth map texture (`render_map.py`; `SHADING_MODE_UNSHADED`; `rotation_degrees = Vector3(0, 270, 0)`); unshaded inner shell shader (`inner_voxel.gdshader`) | 6.3 | ✅ |
| 7.97 | Architecture revamp: outer shell rewritten to per-voxel TYPE B mesher; cross-face neighbor stitching via sphere re-projection (no adjacency table); aim-based left-click digging (raycast → shell/depth dispatch). Visually verified. Open: crosshair HUD, invisible sides at face seams. | 6.4 | ✅ |
| 7.98 | Equiangular cube-sphere distortion fix: `tan(s·α)/tan(α)` remap at all 7 projection sites (cube_sphere.py ×2, landmask/biomes/elevation.py inline numpy ×3, cube_face.gd ×2); full cache rebuild with `--lakes`. Reduces face cell-area variation 5.16× → 1.41×. Nearly backed out (first attempt only updated 4 of 7 sites → continent warping) until the correct scope was identified. Seam invisible-face bug also fixed: cross-face `_is_solid_at` now samples cell centre not corner. | 6.4 | ✅ |
| 7.99 | Ocean "dark circles" artifact fixed (`water.gdshader`: `depth_draw_always` + single colour uniform). Water visual polish: brighter/HDR + daytime sun glint (`albedo_mult`/`water_alpha` uniforms added). Player-facing water controls under Pause → Settings → **Graphics** (sliders + reset); Settings split into Audio/Graphics sub-pages (`pause_menu.gd` page stack). Subsurface-dig black-screen fixed (`_solid_overlay` removed). | 6.4 | ✅ |
| **v1.1.0** | **Release (`architecture-revamp` → `main`).** Front-end: main menu, progressive loading screen (one continuous progress bar across all build phases, surface→interior shell split), ambient music (Clair de Lune autoload), pause menu w/ Audio+Graphics sub-pages. Crosshair hidden while paused; music keeps playing (ducked) when paused; Graphics settings persist to `user://settings.cfg`. See `CHANGELOG.md`. | — | ✅ |
| 8 | OSM fetch + Wikipedia enrich + scoring formula running; top 200 cities placed as Urban voxel clusters | 6 | — |
| 9 | 20+ landmark meshes placed; skybox added; Godot export builds shipped; portfolio README finalized | 7–8 *(estimate)* | — |

Phases 7–8 are marked as estimates; actual pace will depend on Phase 6 complexity and landmark asset authoring time.

---

## Deferred Decisions

| Decision | Why Deferred |
|---|---|
| LOD (level of detail) | Not needed until planet resolution increases past Phase 2 baseline |
| Chunk streaming distance tuning | Validate chunk system correctness first |
| Mining / hollow planet interior | Validate surface layer before adding subsurface complexity |
| Multiplayer | Out of scope for v1 portfolio demo |
| Mobile / web export | Validate desktop builds first (WASM is a stretch goal) |
| Ocean depth / bathymetry | Flat ocean floor is sufficient for Phase 3–5 |
| SDFGI (Godot voxel GI) | Planet-scale scenes are difficult for SDFGI cascades — the camera orbits a sphere so GI volumes shift constantly. Defer until Phase 7 when the camera is more stationary near landmark areas. |
| Day/night rotation cycle | Sun rotation requires a time-of-day system and moving DirectionalLight3D. Atmosphere shader already responds to LIGHT0_DIRECTION, so the visual part is free once rotation is added. Defer until after Phase 6. |

---

## Stretch Goals

### Stretch A — WASM Export
Export the Godot project to WebAssembly and host a playable version on itch.io or GitHub Pages. Godot 4 supports WASM export natively; no additional dependencies needed beyond attention to asset loading strategies and browser threading constraints.

### Stretch B — User Recognition Study
Show screenshots of the planet at each compression level to test participants. Ask: "Which continent are you on?" and "Which city is nearest?" Record accuracy vs. feature count. Plot the recognizability curve. This is the empirical validation for the core research hypothesis described in `docs/RESEARCH.md`.

### Stretch C — Research Paper
Target venue: IEEE VIS, ACM CHI, or GIScience conference. Working title: *"Semantic Compression of Geographic Information for Interactive Playable Worlds."* Key figure: recognizability curve (feature count vs. identification accuracy). Requires at least one round of user study data collection.

### Stretch D — Tiny Bay Prototype
Apply the same pipeline to a single bay area (San Francisco Bay, Tokyo Bay) to test whether local-scale semantic compression works with street-level data. Potential separate repo.

### Stretch E — Ambient Audio
Layered audio system with surface-aware footstep sounds (grass, sand, rock, snow, seafloor),
water splashing on ocean entry, underwater reverb filter on all sounds while submerged, and
ambient background music. Music sources: public domain classical recordings (Debussy's *Clair de
Lune*, Satie *Gymnopédies*, etc.) licensed via Musopen or similar. Long-term idea: collectable
"records" scattered on each continent that unlock region-specific traditional/folk music —
finding a record in Japan plays koto music, one in Brazil plays bossa nova, etc.

### Stretch F — Inner Sphere Visual Upgrade  *(planned next session)*
The inner sphere is currently a low-poly globe with a flat, blurry/pixelated biome texture.
Planned for the next session — sharpness + recolour, keeping continents aligned to the surface:
- **Resolution / sharpness** — two independent causes: (a) the baked map **texture resolution**
  (`render_map.py`) and (b) the **SphereMesh subdivision** (low subdivisions facet the silhouette
  regardless of texture). Bump both; also check texture filtering (point vs linear). Continents
  stay aligned because the same cube-sphere UV mapping is just sampled finer.
- **Colours** — the palette is pure data (`MAT_COLORS_RGB` in `render_map.py`). Explore options:
  greyscale-for-contrast, inverted (white land / black water), or a custom ramp. One table change.
- Both require a **pipeline re-bake** of the inner texture (run via `wsl bash -lc`, not the MSYS
  Bash tool — see HANDOFF pipeline gotcha), not a pure code change.
- Later polish (separate pass): separate water shader on ocean regions (animated, translucent,
  masked by biome type); slight normal-map bumpiness on land so it reads as terrain, not a
  painted ball. Matches the "dynamic mini-globe" aesthetic rather than a cheap decoration.

### Stretch H — Realistic Starfield (real star catalogue)
The night sky's stars are currently procedural noise (`sky_space.gdshader`). Replace them with
the **actual** stars Earth sees, so the sky is recognisable:
- Import a star catalogue (HYG database — ~120k stars with RA/Dec + apparent magnitude).
- Convert RA/Dec → a direction vector; drive star position and brightness from the catalogue.
- Feed positions + magnitudes into the sky shader (or a points mesh) instead of noise.
- Note: Tiny Earth currently has no axial rotation / heliocentric model, so a *static* correct
  sky is the first step; matching rotation/season comes later if a time model is added.

### Stretch G — City Lights (Night Mode)
Once Phase 6 cities are placed, add a night-side emissive pass: urban voxel clusters glow
amber/white on the dark side of the planet. Requires a day/night cycle (see Deferred Decisions)
or a static night-hemisphere texture. Visually striking from orbit and reinforces the semantic
compression concept — you can identify continents by their light clusters alone.
