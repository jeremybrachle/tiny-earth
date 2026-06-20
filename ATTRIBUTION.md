# Attribution

Third-party data, audio, and libraries used by Tiny Earth, with their attribution
requirements. Only sources actually used by the current build are listed here.

---

## Data Sources

### Natural Earth
Public Domain. No attribution required; credited here for transparency.
https://www.naturalearthdata.com/

Land and lake polygons (10m physical) used to build the land/ocean mask.

### ETOPO 2022 Global Relief Model (NOAA)
Public Domain. No attribution required; credited here for transparency.
https://www.ncei.noaa.gov/products/etopo-global-relief-model

Elevation and bathymetry, used for terrain height and mountain classification.

### Köppen-Geiger Climate Classification — Beck et al. 2018
**CC BY 4.0 — attribution required.**
https://creativecommons.org/licenses/by/4.0/

The biome colours are classified from the Beck et al. 2018 present-day
Köppen-Geiger 1 km raster. Attribution per CC BY 4.0:

> Beck, H.E., Zimmermann, N.E., McVicar, T.R., Vergopolan, N., Berg, A., & Wood, E.F.
> (2018). Present and future Köppen-Geiger climate classification maps at 1-km
> resolution. *Scientific Data* 5, 180214. https://doi.org/10.1038/sdata.2018.214

Dataset (figshare): https://figshare.com/ndownloader/files/12407516

### HYG Database (v4.1) — David Nash / astronexus
**CC BY-SA 4.0 — attribution + share-alike required.**
https://creativecommons.org/licenses/by-sa/4.0/

The night-sky star map (`engine/planet/star_map.png`, baked by
`pipeline/src/starmap.py`) is rendered from real star positions, magnitudes, and
B-V colours in the HYG database, which compiles the Hipparcos, Yale Bright Star,
and Gliese catalogs. As a derivative work it is likewise CC BY-SA 4.0.

> The HYG Database, compiled by David Nash. https://www.astronexus.com/hyg

Repository: https://codeberg.org/astronexus/hyg
(GitHub mirror: https://github.com/astronexus/HYG-Database)

### NASA Night Lights ("Earth's City Lights" / Black Marble)
Public Domain (NASA imagery). No attribution required; credited here as a courtesy.
https://earthobservatory.nasa.gov/images/55167/earths-city-lights · https://www.visibleearth.nasa.gov/

The cavity ceiling's land-tile "city lights" (`engine/planet/city_lights.png`,
fetched by `pipeline/src/citylights.py`) are sampled from NASA night-lights
imagery:
- **"Earth's City Lights"** (default) — DMSP, data courtesy Marc Imhoff (NASA GSFC)
  and Christopher Elvidge (NOAA NGDC); image by Craig Mayhew and Robert Simmon (NASA GSFC).
- **Black Marble 2016** (`--blackmarble`) — NASA Earth Observatory (VIIRS / Suomi NPP).

---

## Audio

### Clair de Lune — Claude Debussy (Suite bergamasque, L. 75, III)
Public Domain. No attribution required; credited here as a courtesy.
- **Composition:** Claude Debussy (1862–1918) — public domain (copyright expired).
- **Recording:** Public-domain recording sourced via Musopen / IMSLP.
- https://musopen.org/ · https://imslp.org/

The looping ambient background track (`engine/audio/clair_de_lune.mp3`).

---

## Libraries and Tools

### Godot Engine 4.x
MIT License. Copyright (c) 2007-present Godot Engine contributors.
https://godotengine.org/

### josebasierra/voxel-planets
MIT License. Copyright (c) Jose Basierra.
https://github.com/josebasierra/voxel-planets
Used as an architectural reference only — no code was directly ported (this project
uses Godot, not Unity). Attribution provided per MIT license terms.

### Python pipeline libraries
Credited as a courtesy; each is used as an installed dependency, not redistributed.

| Library | License |
|---|---|
| NumPy | BSD-3-Clause |
| SciPy | BSD-3-Clause |
| Shapely | BSD-3-Clause |
| Rasterio | BSD-3-Clause |
| pyshp (PyShp) | MIT |
| netCDF4 | MIT |
| Pillow | HPND (MIT-style) |
| PyYAML | MIT |
| Requests | Apache-2.0 |

See [LICENSES.md](LICENSES.md) for full license texts.
