# References

Every external source used by Tiny Semantic Earth — organized by type. Each entry includes URL, license, and a one-sentence relevance note.

---

## Open Data Sources

### Natural Earth
- **URL:** https://www.naturalearthdata.com/
- **License:** Public Domain — no restrictions
- **Relevance:** Land/ocean shapefiles, coastlines, country borders, and river data used for Earth silhouette projection and feature boundaries.

### OpenStreetMap / Overpass API
- **URL:** https://overpass-api.de/
- **License:** Open Database License (ODbL 1.0) — attribution required; share-alike applies to the database, not to derivative game content
- **Attribution:** © OpenStreetMap contributors
- **Relevance:** Source of cities, capitals, world heritage sites, airports, and landmark coordinates for the semantic compression pipeline.

### Wikipedia Pageviews API
- **URL:** https://wikitech.wikimedia.org/wiki/Analytics/AQS/Pageviews
- **License:** Creative Commons Attribution (CC-BY) — attribution required
- **Relevance:** Annual pageview count per Wikipedia article used as a quantifiable proxy for global cultural recognition in the importance scoring formula.

### ETOPO Global Relief Model (NOAA)
- **URL:** https://www.ncei.noaa.gov/products/etopo-global-relief-model
- **License:** Public Domain
- **Relevance:** Global elevation and bathymetry data used to generate terrain height variation in the voxel planet (mountains, valleys, ocean depth).

### WWF Terrestrial Ecoregions
- **URL:** https://www.worldwildlife.org/publications/terrestrial-ecoregions-of-the-world
- **License:** Open for non-commercial use with attribution
- **Relevance:** Biome classification polygons used to assign voxel material IDs (desert, tundra, forest, etc.) across the planet surface.

---

## Reference Projects (Study Only — No Code Reuse)

### Blocky Planet — Making Minecraft Spherical (Bowerbyte)
- **URL:** https://www.bowerbyte.com/posts/blocky-planet/
- **License:** No open license published — reference and study only. Do not copy implementation, diagrams, or text.
- **Relevance:** Primary technical reference for mapping cubic voxels onto a sphere surface without shader fakery; documents the cube-sphere distortion problem and practical mitigation approaches that directly informed the decision to use a hybrid voxel + low-poly style rather than pure voxels for landmarks.

### ddupont808/planetcraft
- **URL:** https://github.com/ddupont808/planetcraft
- **License:** No license found — reference and study only. Do not copy any code.
- **Relevance:** Proof-of-concept Unity/C#/HLSL implementation of a playable spherical voxel planet using 6-grid cube-to-sphere mapping with dynamic chunk subdivision at altitude; confirms technical feasibility of the approach and illustrates the architectural pattern even though the code cannot be reused.

---

## Legally Reusable Projects

### josebasierra/voxel-planets
- **URL:** https://github.com/josebasierra/voxel-planets
- **License:** MIT — legally usable with attribution
- **Attribution required:** See `ATTRIBUTION.md`

This is the only legally reusable reference implementation in scope. It is a Unity/C# project implementing voxel planet generation with octree-based LOD, inspired by Astroneer. Because this project uses Godot (not Unity), the code cannot be directly ported, but the chunk management and LOD architecture patterns are a legitimate reference. Must be attributed per MIT license terms.

---

## Academic / Technical References

### Cube-to-Sphere Mapping Mathematics
- **URL:** https://mathproofs.blogspot.com/2005/07/mapping-cube-to-sphere.html
- **License:** Academic reference — mathematical formulas are not copyrightable. No code copied.
- **Relevance:** Core mathematical reference for projecting cube face UV coordinates onto a unit sphere surface without polar distortion; the geometric primitive underlying `pipeline/src/cube_sphere.py`.

---

## Tools and Libraries

### Godot Engine 4.x
- **URL:** https://godotengine.org/
- **License:** MIT

### Python 3.11+
- **URL:** https://www.python.org/
- **License:** Python Software Foundation License (open source compatible)

### GDAL
- **URL:** https://gdal.org/
- **License:** MIT
- **Use:** Core raster/vector I/O and coordinate reprojection in the pipeline.

### Rasterio
- **URL:** https://rasterio.readthedocs.io/
- **License:** BSD-3-Clause
- **Use:** Read/write GeoTIFF elevation and land mask rasters.

### GeoPandas
- **URL:** https://geopandas.org/
- **License:** BSD-3-Clause
- **Use:** Vector data processing (coastlines, roads, cities, rivers).

### Binvox
- **URL:** https://www.patrickmin.com/binvox/
- **License:** Freeware — not open source. Internal asset conversion use only; must not be redistributed.
- **Use:** Optional tool for voxelizing reference 3D meshes during landmark asset authoring.
