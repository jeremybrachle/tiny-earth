# Pipeline

## Executive Summary

The Tiny Semantic Earth data pipeline is a Python program that transforms raw geographic data from public sources into two artifact types: a scored GeoJSON feature file and a set of binary voxel chunk files ready for the game engine. It fetches terrain data (land mask, elevation, biomes) and named features (cities, landmarks, airports) from public datasets, enriches each feature with Wikipedia pageview data as a cultural salience proxy, scores every feature using a composite importance formula, filters down to a configurable top-N, and exports the survivors. The pipeline is the core research artifact: by varying N, it produces compressed views of Earth at different information densities. All sources are public domain or openly licensed; see the legal notes at the end of this document.

---

## Libraries

| Library | Purpose |
|---|---|
| `GDAL` | Core raster/vector I/O, coordinate reprojection |
| `Rasterio` | Read/write GeoTIFF elevation and land mask rasters |
| `GeoPandas` | Vector data processing (coastlines, roads, cities, rivers) |
| `Shapely` | Geometry operations and spatial filtering |
| `NumPy` | Array math for voxel grid construction |
| `Pillow` | Export processed masks as PNG for Godot import |
| `PyYAML` | Pipeline configuration (`pipeline/config/planet.yaml`) |
| `requests` / `httpx` | Overpass API and Wikipedia Pageviews API calls |

---

## Pipeline Flow

```
[Natural Earth]   [ETOPO Relief]   [WWF Biomes]   [OSM / Overpass]
  (shapefiles)     (GeoTIFF)        (polygons)      (cities, landmarks)
       │               │                │                  │
       ▼               ▼                ▼                  ▼
  download.py     download.py      download.py        fetch_osm.py
  landmask.py     elevation.py     biomes.py               │
       │               │                │                  │
       └───────────────┴────────────────┘                  │
                       │                                   │
                       │              ┌────────────────────┘
                       │              ▼
                       │         fetch_wiki.py ◄── [Wikipedia Pageviews API]
                       │         (cultural_salience_index per feature)
                       │              │
                       │              ▼
                       │          score.py
                       │          (composite importance score)
                       │              │
                       │              ▼
                       │         compress.py
                       │         (configurable top-N cutoff)
                       │              │
                       └──────────────┤
                                      ▼
                                  export.py
                       ┌──────────────┴──────────────┐
                       ▼                             ▼
          data/exports/features.geojson    engine/planet/faces/
          (scored feature set)             face_N/chunk_X_Y.bin
                                           (binary voxel chunks)
```

All scripts live in `pipeline/src/`. Configuration is in `pipeline/config/planet.yaml`.

---

## Stage 1 — Fetch

**Scripts:** `download.py`, `landmask.py`, `elevation.py`, `biomes.py`, `fetch_osm.py`
**Outputs:** `data/raw/`

Four parallel data sources are fetched and cached:

**Natural Earth** (`download.py` + `landmask.py`): Downloads the 1:110m land polygon and coastline shapefiles. `landmask.py` rasterizes the land polygons to a lat/lon grid and then projects to cube face UV coordinates, producing a boolean land/ocean mask per surface voxel.

**ETOPO Elevation** (`download.py` + `elevation.py`): Fetches the ETOPO global relief GeoTIFF from NOAA. `elevation.py` normalizes the elevation range to a small integer (0–8 extra voxel layers above sea level) for remapping into the chunk format. Ocean depth is treated as flat (single voxel) in Phase 4.

**WWF Biomes** (`download.py` + `biomes.py`): Fetches WWF Terrestrial Ecoregion polygons. `biomes.py` projects biome classifications onto the cube face UV grid and maps them to voxel material IDs (e.g., tropical forest → material 5, desert → material 3, tundra → material 6).

**OpenStreetMap / Overpass API** (`fetch_osm.py`): Issues structured Overpass QL queries to fetch four feature classes:
- National capitals (`place=capital`)
- Cities with population > 100,000 (`place=city`)
- UNESCO World Heritage Sites (`heritage=* AND operator:wikidata`)
- Major international airports (`aeroway=aerodrome AND iata=*`)

All raw data is written to `data/raw/` and gitignored. Cached files are reused if less than 7 days old to avoid redundant API calls during iterative development.

**Rate limits:** Overpass API — sleep 1s between requests; use a single batch query per feature class. Wikipedia Pageviews — respect 100 req/s limit; batch requests where possible and use exponential backoff on HTTP 429.

---

## Stage 2 — Enrich

**Script:** `fetch_wiki.py`
**Inputs:** `data/raw/osm_features.geojson`
**Outputs:** `data/processed/osm_enriched.geojson`

For each OSM feature with a `name` tag, queries the Wikipedia Pageviews API for trailing 12-month annual pageview count. Where a `wikidata` link is available, the canonical English article title is resolved via the Wikidata API first.

Raw pageview count stored as `pageviews_12mo_raw`. After all features are enriched, values are normalized to [0, 1] using min-max normalization across the full candidate set to produce `cultural_salience_index`.

All responses are cached in `data/processed/pageviews_cache.json` with a 30-day TTL.

---

## Stage 3 — Score

**Script:** `score.py`
**Inputs:** `data/processed/osm_enriched.geojson`
**Outputs:** `data/processed/osm_scored.geojson`

Applies the composite importance formula to each feature:

```
score(f) = (w_pop  × log(population(f) + 1))
         + (w_sal  × cultural_salience_index(f))
         + (w_uniq × geographic_uniqueness(f))
         + (w_conn × transport_hub_rank(f))
```

| Variable | Type | Source | Description |
|---|---|---|---|
| `population(f)` | integer | OSM / GeoNames | Raw population of city or metro area |
| `cultural_salience_index(f)` | float [0,1] | Wikipedia Pageviews API | Normalized annual Wikipedia pageview count |
| `geographic_uniqueness(f)` | float [0,1] | Computed | Inverse of local feature density — isolated features score higher than clustered ones |
| `transport_hub_rank(f)` | float [0,1] | OSM / IATA | Normalized rank by airport passenger volume or major rail hub status |
| `w_pop`, `w_sal`, `w_uniq`, `w_conn` | float | `planet.yaml` | Default: **0.4 / 0.3 / 0.2 / 0.1** |

`geographic_uniqueness` is computed by counting other features of the same class within a 5° angular radius (~550 km at the equator) and taking the inverse: `1 / (1 + neighbor_count)`. This penalizes dense clusters (e.g., Western European capitals) and rewards isolated features.

Log transform on population prevents megacities from dominating the score while still preserving population as a meaningful signal. Weights are tunable via `pipeline/config/planet.yaml` to support compression experiments with different scoring configurations.

---

## Stage 4 — Compress

**Script:** `compress.py`
**Inputs:** `data/processed/osm_scored.geojson`
**Outputs:** `data/processed/osm_compressed.geojson`

Sorts features by `score` descending and retains the top N. N is set via `compression_level` in `planet.yaml`. A minimum diversity constraint ensures at least one feature per continent is retained regardless of score.

The compression ratio — defined as `|retained features| / |candidate features|` — is the independent variable in the recognizability experiments. Typical cutoffs:

| Feature count | Character |
|---|---|
| 1000 | Dense — most major cities and many secondary cities |
| 500 | Standard — all major capitals and prominent landmarks |
| 200 | Sparse — globally iconic locations only |
| 50 | Extreme — roughly one feature per country |
| 10 | Limit case — five or six continents plus the most iconic landmarks |

As cutoff decreases, geographic information loss increases. This is the core research variable described in `docs/RESEARCH.md`.

---

## Stage 5 — Export

**Script:** `export.py`
**Inputs:** `data/processed/osm_compressed.geojson`, terrain arrays from Stages 1–2
**Outputs:**
- `data/exports/features.geojson`
- `engine/planet/faces/face_N/chunk_X_Y.bin`

Produces two artifact types:

### Scored GeoJSON

`data/exports/features.geojson` — consumed by Godot at import time to place landmarks and cities. Full property schema:

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

The `cube_face`, `face_u`, and `face_v` fields are pre-computed by `cube_sphere.py` during export. Godot never touches raw WGS84 lat/lon — coordinate conversion is entirely a Python pipeline responsibility.

### Binary Voxel Chunks

`engine/planet/faces/face_N/chunk_X_Y.bin` — raw voxel data consumed by Godot at runtime:
- Format: `uint8` material ID per voxel, row-major XYZ order
- Compression: zlib per chunk file
- Chunk size: 16³ = 4,096 bytes uncompressed per chunk

### Voxel Material IDs

```
0   = Air
1   = Land (generic)
2   = Ocean
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

---

## Legal and Attribution Notes

| Source | License | Obligation |
|---|---|---|
| Natural Earth | Public Domain | None; attribution appreciated |
| OpenStreetMap / Overpass API | ODbL 1.0 | **Required:** "© OpenStreetMap contributors" must appear in the running application |
| Wikipedia Pageviews API | CC BY-SA | Data used as a numeric signal only; no article text reproduced |
| ETOPO (NOAA) | Public Domain | None |
| WWF Terrestrial Ecoregions | Non-commercial with attribution | Attribution required; non-commercial use only |

OSM attribution is a legal obligation under ODbL, not a courtesy. It must appear in the game UI or credits screen, not only in documentation.
