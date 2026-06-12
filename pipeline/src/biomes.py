"""
Assign biome material IDs to each land voxel on the cube sphere grid.

Reads data/cache/landmask.npy (6, RESOLUTION, RESOLUTION) uint8 and produces
data/cache/biomes.npy with the same shape, replacing land pixels (1) with a
climate-zone material ID:

  2 = Ocean      (unchanged)
  3 = Desert     BWh / BWk in Köppen-Geiger
  4 = Temperate  C-group climates
  5 = Forest     D-group (continental) climates
  6 = Snow/Ice   Polar (ET / EF)
  7 = Tropical   A-group climates
  8 = Savanna    BSh / BSk (arid steppe)
  9 = Mountain   ETOPO depth ≥ 4 (~4,400 m+) — data-driven override

Primary classification uses the Beck et al. 2018 Köppen-Geiger 1 km GeoTIFF.
Mountain coloring is 100% data-driven from ETOPO elevation.npy.

Usage:
    python pipeline/src/biomes.py
    python pipeline/src/biomes.py --config pipeline/config/planet.yaml --root .
"""

import argparse
import sys
from pathlib import Path

import numpy as np
import yaml

LANDMASK_CACHE_REL   = Path("data/cache/landmask.npy")
BIOMES_CACHE_REL     = Path("data/cache/biomes.npy")
ELEVATION_CACHE_REL  = Path("data/cache/elevation.npy")
KOPPEN_CACHE_REL     = Path("data/cache/koppen_beck2018.tif")

MATERIAL_OCEAN     = 2
MATERIAL_DESERT    = 3
MATERIAL_TEMPERATE = 4
MATERIAL_FOREST    = 5
MATERIAL_SNOW      = 6
MATERIAL_TROPICAL  = 7
MATERIAL_SAVANNA   = 8
MATERIAL_MOUNTAIN  = 9

MOUNTAIN_ELEV_THRESHOLD = 4  # ETOPO depth layers; depth 4 ≈ 4,400 m above sea level

# Beck 2018 Köppen class integer → material ID.
# Classes: 1-4=Tropical, 5-6=Arid desert, 7-8=Arid steppe,
#          9-17=Temperate, 18-29=Continental, 30-31=Polar.
KOPPEN_TO_MATERIAL = {
    1: MATERIAL_TROPICAL, 2: MATERIAL_TROPICAL,
    3: MATERIAL_TROPICAL, 4: MATERIAL_TROPICAL,
    5: MATERIAL_DESERT,   6: MATERIAL_DESERT,
    7: MATERIAL_SAVANNA,  8: MATERIAL_SAVANNA,
    9: MATERIAL_TEMPERATE, 10: MATERIAL_TEMPERATE, 11: MATERIAL_TEMPERATE,
    12: MATERIAL_TEMPERATE, 13: MATERIAL_TEMPERATE, 14: MATERIAL_TEMPERATE,
    15: MATERIAL_TEMPERATE, 16: MATERIAL_TEMPERATE, 17: MATERIAL_TEMPERATE,
    18: MATERIAL_FOREST, 19: MATERIAL_FOREST, 20: MATERIAL_FOREST,
    21: MATERIAL_FOREST, 22: MATERIAL_FOREST, 23: MATERIAL_FOREST,
    24: MATERIAL_FOREST, 25: MATERIAL_FOREST, 26: MATERIAL_FOREST,
    27: MATERIAL_FOREST, 28: MATERIAL_FOREST, 29: MATERIAL_FOREST,
    30: MATERIAL_SNOW, 31: MATERIAL_SNOW,
}


def load_config(config_path: Path) -> dict:
    with config_path.open() as f:
        return yaml.safe_load(f)


def load_koppen(tif_path: Path) -> tuple:
    """Load Beck 2018 GeoTIFF. Returns (data, transform) where data is (nlat, nlon) uint8."""
    import rasterio
    with rasterio.open(str(tif_path)) as src:
        data = src.read(1)           # (nlat, nlon) uint8
        transform = src.transform    # affine: pixel → geographic coords
    return data, transform


def _sample_koppen(
    data: np.ndarray,
    transform,
    lat_2d: np.ndarray,
    lon_2d: np.ndarray,
) -> np.ndarray:
    """
    Look up Köppen class for every (lat, lon) in lat_2d/lon_2d, map to material ID.
    Returns (resolution, resolution) uint8 array.
    """
    # Affine: (col, row) → (lon, lat).  Inverse gives pixel coords from geographic.
    # transform.c = west edge lon, transform.f = north edge lat
    # transform.a = pixel width (lon), transform.e = pixel height (lat, negative)
    west  = transform.c
    north = transform.f
    res_x = transform.a   # degrees per pixel (positive)
    res_y = transform.e   # degrees per pixel (negative)

    nlat, nlon = data.shape

    col = ((lon_2d - west) / res_x).astype(np.int32)
    row = ((lat_2d - north) / res_y).astype(np.int32)

    np.clip(col, 0, nlon - 1, out=col)
    np.clip(row, 0, nlat - 1, out=row)

    koppen_class = data[row, col]

    # Vectorised lookup via a LUT array (index = Köppen class, value = material ID)
    max_class = max(KOPPEN_TO_MATERIAL.keys()) + 1
    lut = np.full(max_class + 1, MATERIAL_TEMPERATE, dtype=np.uint8)
    for k, v in KOPPEN_TO_MATERIAL.items():
        lut[k] = v

    safe_class = np.clip(koppen_class, 0, max_class).astype(np.int32)
    return lut[safe_class]


def build_biomes(
    landmask: np.ndarray,
    resolution: int,
    elevation: np.ndarray | None = None,
    koppen: tuple | None = None,
) -> np.ndarray:
    """
    Build (6, resolution, resolution) uint8 biome material array.

    Ocean pixels (2) are kept unchanged. Land pixels (1) are replaced with a
    biome ID from the Köppen-Geiger raster. Elevation (from ETOPO) overrides
    any zone to Mountain where depth >= MOUNTAIN_ELEV_THRESHOLD.

    Falls back to latitude-band classification if koppen is None.
    """
    biomes = landmask.copy()

    cols = np.arange(resolution)
    rows = np.arange(resolution)
    col_idx, row_idx = np.meshgrid(cols, rows, indexing="ij")
    u_flat = ((col_idx + 0.5) / resolution).ravel().astype(np.float32)
    v_flat = ((row_idx + 0.5) / resolution).ravel().astype(np.float32)

    s = u_flat * 2.0 - 1.0
    t = v_flat * 2.0 - 1.0
    ones = np.ones_like(s)

    for face in range(6):
        if face == 0:
            x, y, z = ones, s, t
        elif face == 1:
            x, y, z = -ones, -s, t
        elif face == 2:
            x, y, z = s, ones, t
        elif face == 3:
            x, y, z = -s, -ones, t
        elif face == 4:
            x, y, z = s, t, ones
        else:
            x, y, z = s, -t, -ones

        mag = np.sqrt(x**2 + y**2 + z**2)
        x_n, y_n, z_n = x / mag, y / mag, z / mag

        lat = np.degrees(np.arcsin(np.clip(z_n, -1.0, 1.0)))
        lon = np.degrees(np.arctan2(y_n, x_n))

        lat_2d = lat.reshape(resolution, resolution)
        lon_2d = lon.reshape(resolution, resolution)

        if koppen is not None:
            biome_grid = _sample_koppen(koppen[0], koppen[1], lat_2d, lon_2d)
        else:
            # Latitude-band fallback (no Köppen data available)
            abs_lat = np.abs(lat_2d)
            biome_grid = np.where(
                abs_lat >= 65, MATERIAL_SNOW,
                np.where(abs_lat >= 50, MATERIAL_FOREST,
                np.where(abs_lat < 15, MATERIAL_TROPICAL,
                np.where(abs_lat < 25, MATERIAL_SAVANNA,
                         MATERIAL_TEMPERATE)))
            ).astype(np.uint8)

        if elevation is not None:
            land = landmask[face] == 1
            high_elev = (elevation[face] >= MOUNTAIN_ELEV_THRESHOLD) & land
            biome_grid = np.where(high_elev, MATERIAL_MOUNTAIN, biome_grid)

        land = landmask[face] == 1
        biomes[face] = np.where(land, biome_grid, landmask[face])

        counts = {
            "tropical":  int((biomes[face] == MATERIAL_TROPICAL).sum()),
            "savanna":   int((biomes[face] == MATERIAL_SAVANNA).sum()),
            "desert":    int((biomes[face] == MATERIAL_DESERT).sum()),
            "temperate": int((biomes[face] == MATERIAL_TEMPERATE).sum()),
            "forest":    int((biomes[face] == MATERIAL_FOREST).sum()),
            "snow":      int((biomes[face] == MATERIAL_SNOW).sum()),
            "mountain":  int((biomes[face] == MATERIAL_MOUNTAIN).sum()),
        }
        print(f"  face {face}: {counts}")

    return biomes


def main() -> None:
    parser = argparse.ArgumentParser(description="Assign biome material IDs to the cube sphere grid.")
    parser.add_argument("--config", default="pipeline/config/planet.yaml")
    parser.add_argument("--root", default=".")
    args = parser.parse_args()

    config = load_config(Path(args.config))
    repo_root = Path(args.root).resolve()
    resolution = config["planet"]["resolution"]

    landmask_path = repo_root / LANDMASK_CACHE_REL
    if not landmask_path.exists():
        print(f"Error: landmask not found at {landmask_path}", file=sys.stderr)
        print("Run: python pipeline/src/landmask.py", file=sys.stderr)
        sys.exit(1)

    landmask = np.load(landmask_path)
    if landmask.shape != (6, resolution, resolution):
        print(f"Error: landmask shape {landmask.shape} does not match (6, {resolution}, {resolution})", file=sys.stderr)
        sys.exit(1)

    elevation_path = repo_root / ELEVATION_CACHE_REL
    elevation = None
    if elevation_path.exists():
        elevation = np.load(elevation_path)
        if elevation.shape != (6, resolution, resolution):
            print(f"Warning: elevation shape {elevation.shape} mismatch — skipping mountain override.")
            elevation = None
        else:
            print(f"Loaded elevation from {elevation_path} (mountain threshold: depth ≥ {MOUNTAIN_ELEV_THRESHOLD})")
    else:
        print(f"Warning: elevation not found at {elevation_path} — no mountain coloring.")

    koppen = None
    koppen_path = repo_root / KOPPEN_CACHE_REL
    if koppen_path.exists():
        print(f"Loading Köppen-Geiger raster from {koppen_path} ...")
        koppen = load_koppen(koppen_path)
        print(f"  raster shape: {koppen[0].shape}")
    else:
        print(f"Warning: Köppen raster not found at {koppen_path} — falling back to latitude bands.")
        print("Run: python pipeline/src/download.py --koppen")

    print(f"Building biomes grid at resolution {resolution} ...")
    biomes = build_biomes(landmask, resolution, elevation=elevation, koppen=koppen)

    out_path = repo_root / BIOMES_CACHE_REL
    np.save(out_path, biomes)
    print(f"\nCached to {out_path}")


if __name__ == "__main__":
    main()
