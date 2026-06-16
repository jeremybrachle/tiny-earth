# ADR 003 — Data Pipeline: Python 3.11+

**Status:** Accepted
**Date:** 2026-06-02

## Context

The pipeline must:
- Download and process GIS raster and vector data (GeoTIFF, shapefiles, GeoJSON)
- Reproject between coordinate systems (WGS84 ↔ cube face UV)
- Query REST APIs (Overpass, Wikipedia Pageviews)
- Output binary voxel chunk files and GeoJSON for the game engine

The pipeline runs offline as a data preprocessing step, not at game runtime. Performance is a secondary concern; correctness and ecosystem coverage are primary.

## Decision

**Python 3.11+** with GDAL, Rasterio, GeoPandas, Shapely, NumPy, Pillow, PyYAML, and requests/httpx.

## Rationale

- **Ecosystem.** GDAL/Rasterio/GeoPandas is the de facto standard GIS stack. No other language has comparable library coverage for raster reprojection, vector processing, and coordinate transformation in one coherent ecosystem.
- **Hiring signal.** Python GIS pipelines are immediately recognizable to engineers in geospatial, data engineering, and ML roles — all target audiences for this portfolio piece.
- **Separation of concerns.** The pipeline is a separate process from the game engine. It runs once (or on demand) and writes files. Godot reads those files at runtime. Language choice for the pipeline has zero impact on engine performance.
- **3.11+ specifically.** Performance improvements in 3.11 (interpreter speedups) and 3.12 (better error messages) make this the minimum viable version. No 3.10-or-below features are used.

## Consequences

- All pipeline code lives in `pipeline/src/`. It is a standalone Python project with its own `pyproject.toml` and `requirements.txt`.
- The pipeline must be fully testable with `pytest` with no game engine dependency.
- CI (`pipeline-test.yml`) runs `pytest` on every push to `main`. Pipeline math (especially cube-sphere projection) must have unit tests before Phase 1 begins.
- Godot never imports Python or calls pipeline code at runtime.
