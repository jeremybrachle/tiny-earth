You are a technical documentation agent. Your job is to generate a set of 
markdown files for a software portfolio project called **Tiny Semantic Earth** 
(working title). Do not write any code. Only produce the requested markdown 
files, fully filled out with real content — no placeholder text like 
"[insert here]".

---

## Project Summary

Tiny Semantic Earth is a walkable, toy-scale version of Earth built in a game 
engine. The core research question is:

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

## Technical Decisions (locked in)

- **Visual style:** Hybrid — voxel terrain base with stylized low-poly landmark 
  meshes for iconic structures (Eiffel Tower, Statue of Liberty, etc.)
- **Engine:** Undecided between Godot 4 and Unity. The docs should include a 
  neutral comparison section recommending one, with reasoning. Favor Godot 4 
  unless there's a compelling legal/technical reason to use Unity. Note that 
  `josebasierra/voxel-planets` is MIT licensed and Unity-based, which is a 
  legitimate head start if Unity is chosen.
- **Data pipeline:** Lives in a `pipeline/` folder inside the monorepo, written 
  in Python. It is a separate concern from the game engine.
- **Deployment:** Not a constraint yet. Don't optimize docs for any specific 
  target.
- **Legal posture:** Must remain clean. OpenStreetMap (ODbL), Natural Earth 
  (public domain), Wikipedia API (CC), MIT/BSD/Apache code only. A 
  REFERENCES.md must document every source with its license.

---

## Tone & Audience

Each document should have:
- An **executive summary** at the top (3–5 sentences, accessible to hiring 
  managers and non-engineers)
- **Technical depth** below that (architecture rationale, data formats, scoring 
  math, pipeline stages) for engineers reading the repo

Write in clear, confident technical prose. Not overly formal. This is a 
personal project with research ambitions, not a corporate spec.

---

## Monorepo Structure

Use this layout in all documents that reference file paths:

```
tiny-earth/
├── docs/
│   ├── ADR/               # Architecture Decision Records
├── pipeline/              # Python: OSM → scored GeoJSON → planet-ready data
│   ├── fetch/
│   ├── score/
│   └── export/
├── engine/                # Game engine project (Godot or Unity TBD)
│   ├── scenes/
│   ├── scripts/
│   └── assets/
├── data/
│   ├── raw/               # gitignored
│   ├── processed/
│   └── exports/
└── research/
    └── compression_experiments/
```

---

## Reference Sources

The following sources have been reviewed and must appear in REFERENCES.md with 
their URLs, licenses, and relevance notes exactly as described below:

1. **Blocky Planet — Making Minecraft Spherical** (Bowerbyte)
   - URL: https://www.bowerbyte.com/posts/blocky-planet/
   - License: No open license — reference/study only, do not copy implementation
   - Relevance: Primary technical reference for the core problem of mapping 
     cubic voxels onto a sphere surface without shader fakery. Documents the 
     cube-sphere distortion problem and practical mitigation approaches. 
     Informed the decision to pursue a hybrid voxel+low-poly style rather than 
     pure voxels.

2. **ddupont808/planetcraft** — Minecraft-like voxels mapped onto large spherical planets
   - URL: https://github.com/ddupont808/planetcraft
   - License: No license found — reference/study only, do not copy code
   - Relevance: Proof-of-concept Unity/C#/HLSL implementation showing a 
     playable spherical voxel planet using 6-grid cube-to-sphere mapping with 
     dynamic chunk subdivision at altitude. Demonstrates the mathematical 
     approach and confirms technical feasibility. Code cannot be reused but 
     architecture is instructive.

3. **josebasierra/voxel-planets** — Generation of planets with dynamic terrain
   - URL: https://github.com/josebasierra/voxel-planets
   - License: MIT — legally usable with attribution
   - Relevance: MIT-licensed Unity/C# implementation of voxel planet generation 
     with octree-based LOD, inspired by Astroneer. The only legally reusable 
     reference implementation in scope. If Unity is chosen as the engine, this 
     project's chunk management and LOD patterns are a legitimate head start. 
     Must be attributed per MIT license terms.

Also include these additional sources in REFERENCES.md:
- Natural Earth (https://www.naturalearthdata.com/) — public domain, land/ocean 
  shapefiles for Earth silhouette projection
- OpenStreetMap / Overpass API (https://overpass-api.de/) — ODbL license, 
  source of cities, capitals, landmarks, airports
- Wikipedia Pageviews API (https://wikitech.wikimedia.org/wiki/Analytics/AQS/Pageviews) 
  — CC license, used as cultural salience proxy in scoring
- Cube-to-sphere mapping math (https://mathproofs.blogspot.com/2005/07/mapping-cube-to-sphere.html) 
  — academic reference for the core sphere generation math
- Godot 4 (https://godotengine.org/) — MIT license
- Unity (https://unity.com/) — proprietary, note if chosen

---

## Files to Generate

Generate each of the following files completely. Separate them clearly with a 
line like `--- FILE: filename.md ---`.

### 1. README.md
- Project title, tagline, and 1-paragraph elevator pitch
- The core research question (quoted, prominent)
- Visual overview of the pipeline (ASCII diagram is fine)
- Phases overview (brief, link to ROADMAP.md)
- How to clone and run (stub — note engine and Python version requirements, 
  exact setup TBD)
- Legal/attribution summary
- Note that ARCHITECTURE.md is planned but not yet written
- Links to all other docs in the repo

### 2. PIPELINE.md
- Executive summary
- Full data pipeline stages with descriptions:
  1. Fetch: Natural Earth shapefiles (land mask, coastlines), OSM via Overpass 
     API (capitals, major cities, world heritage sites, airports)
  2. Enrich: Wikipedia page view API as cultural salience proxy
  3. Score: importance scoring function (document the formula, weights, and 
     what each term means)
  4. Compress: configurable feature count cutoff (e.g. top 500 → top 50 → 
     top 10)
  5. Export: output as GeoJSON with scored features, ready for engine import
- Data format specs (what fields each GeoJSON feature carries)
- Notes on rate limits and caching for OSM/Wikipedia APIs
- Legal/attribution notes for each data source with URLs

### 3. REFERENCES.md
- Every reference source organized into sections:
  Open Data Sources, Reference Projects (study-only),
  Legally Reusable Projects, Academic / Technical References, Tools & Libraries
- For each entry: name, URL, license, and a one-sentence relevance note
- Use the exact source details from the ## Reference Sources section above

### 4. ROADMAP.md
- Executive summary
- 5 development phases with goals, key deliverables, and success criteria:
  - Phase 1: Walkable Sphere (no data, just physics)
  - Phase 2: Earth Silhouette (land/ocean mask projected onto sphere)
  - Phase 3: Semantic Compression Engine (Python pipeline)
  - Phase 4: Landmark Placement (iconic mesh placement via pipeline data)
  - Phase 5: Visual Polish + Portfolio Release
- Weekend milestone table (one deliverable per weekend, ~7 weekends total)
- Stretch goals section (Tiny Bay prototype, WASM export, research paper)

### 5. RESEARCH.md
- Executive summary framing this as a novel research contribution
- The core hypothesis: geographic features have a "recognizability threshold" 
  that can be measured and quantified
- The semantic compression scoring formula (with variable definitions):
```
  score = (w_pop * log(population + 1))
        + (w_sal * cultural_salience_index)
        + (w_uniq * geographic_uniqueness)
        + (w_conn * transport_hub_rank)
```
- How each variable is sourced (OSM, Wikipedia, IATA codes, etc.)
- The compression ratio concept: feature count vs. recognizability curve
- Potential user study design (small-n: show users a compressed globe, ask 
  "which continent are you in?", measure accuracy vs. feature count)
- Framing as a potential paper:
  "Semantic Compression of Geographic Information for Interactive Playable Worlds"
- Open questions and future directions

---

Generate all 5 files now, fully written out, no stubs or placeholders.