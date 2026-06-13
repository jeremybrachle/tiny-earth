"""
Rasterize ETOPO 2022 elevation data onto the cube sphere grid.

Produces a (6, RESOLUTION, RESOLUTION) numpy uint8 array where each value is
the number of EXTRA voxel layers above the base surface layer (0–8):

  0 = sea level or below (ocean + flat land) — one surface layer only
  1 = low terrain (~1–1,100 m)
  ...
  8 = highest terrain (Everest 8,849 m)

Result is cached to data/cache/elevation.npy.

Usage:
    python pipeline/src/elevation.py
    python pipeline/src/elevation.py --config pipeline/config/planet.yaml --root .
"""

import argparse
import sys
from pathlib import Path

import numpy as np
import yaml

from cube_sphere import EQUIANGULAR_ALPHA
from landmask import MIRRORED_FACES

MAX_ELEV_M = 8849      # Everest summit (meters)
VOXEL_LAYERS = 8       # maximum extra layers above surface
MAX_OCEAN_M = 11000    # Challenger Deep / Mariana Trench (meters) — ocean depth reference
MAX_BATH_LAYERS = 12   # cap ocean water column at 12 voxels (leaves seafloor + rock
                       # crust within the 16-deep inner shell). Deepest trenches reach
                       # this; shelves stay 1–2. Tune for trench drama vs. crust thickness.

CACHE_REL      = Path("data/cache/elevation.npy")
BATH_CACHE_REL = Path("data/cache/bathymetry.npy")
DEFAULT_NC_REL = Path("data/cache/etopo_60s.nc")


def load_config(config_path: Path) -> dict:
    with config_path.open() as f:
        return yaml.safe_load(f)


def load_etopo(nc_path: Path) -> tuple:
    """
    Load ETOPO NetCDF. Returns (lats, lons, z_grid).

    lats: (nlat,) float32 ascending degrees [-90, 90]
    lons: (nlon,) float32 degrees [-180, 180]
    z_grid: (nlat, nlon) float32 elevation in meters
    """
    try:
        from scipy.io import netcdf_file
        with netcdf_file(str(nc_path), "r", mmap=False) as f:
            lats = np.array(f.variables["lat"][:], dtype=np.float32)
            lons = np.array(f.variables["lon"][:], dtype=np.float32)
            z    = np.array(f.variables["z"][:],   dtype=np.float32)
        print("Loaded ETOPO via scipy")
    except Exception:
        import netCDF4
        ds = netCDF4.Dataset(str(nc_path))
        lats = np.array(ds.variables["lat"][:], dtype=np.float32)
        lons = np.array(ds.variables["lon"][:], dtype=np.float32)
        z    = np.array(ds.variables["z"][:],   dtype=np.float32)
        ds.close()
        print("Loaded ETOPO via netCDF4")

    # Ensure lats are ascending for np.searchsorted
    if lats[0] > lats[-1]:
        lats = lats[::-1]
        z    = z[::-1, :]

    return lats, lons, z


def elev_to_layers(elev_m: float) -> int:
    """Map elevation in meters to extra voxel layer count (0–VOXEL_LAYERS)."""
    if elev_m <= 0:
        return 0
    return min(int(elev_m / MAX_ELEV_M * VOXEL_LAYERS) + 1, VOXEL_LAYERS)


def depth_to_layers(elev_m: float) -> int:
    """Map ETOPO value for ocean tiles to water-column depth layers (1–MAX_BATH_LAYERS).

    For ocean tiles the ETOPO value is ≤ 0.  Returns the number of water voxels
    that will sit above the seafloor: minimum 1, capped at MAX_BATH_LAYERS so
    the water surface never rises more than a few voxels above flat land.
    """
    depth_m = abs(min(elev_m, 0.0))
    if depth_m == 0.0:
        return 1  # tidal flat / very shallow coast — still needs 1 water layer
    return min(int(depth_m / MAX_OCEAN_M * MAX_BATH_LAYERS) + 1, MAX_BATH_LAYERS)


def _sample_elevation(
    lats: np.ndarray,
    lons: np.ndarray,
    z_grid: np.ndarray,
    lat_q: np.ndarray,
    lon_q: np.ndarray,
) -> np.ndarray:
    """
    Nearest-neighbor sample z_grid at query (lat_q, lon_q) arrays.
    Returns float32 array of elevation values.
    """
    lat_idx = np.searchsorted(lats, lat_q, side="left").clip(0, len(lats) - 1)
    # Normalise longitude to [-180, 180] then searchsorted
    lon_wrapped = ((lon_q.astype(np.float32) + 180) % 360) - 180
    lon_idx = np.searchsorted(lons, lon_wrapped, side="left").clip(0, len(lons) - 1)
    return z_grid[lat_idx, lon_idx]


def build_elevation(nc_path: Path, resolution: int) -> tuple:
    """Build elevation and bathymetry grids simultaneously from ETOPO data.

    Returns:
        (elev_grid, bath_grid) — both (6, resolution, resolution) uint8.
        elev_grid: extra land-elevation voxel layers above sea level (0–VOXEL_LAYERS).
        bath_grid:  ocean water-column depth layers (0 for land, 1–MAX_BATH_LAYERS for ocean).
    """
    lats, lons, z_grid = load_etopo(nc_path)

    elev_grid = np.zeros((6, resolution, resolution), dtype=np.uint8)
    bath_grid = np.zeros((6, resolution, resolution), dtype=np.uint8)

    cols = np.arange(resolution)
    rows = np.arange(resolution)
    col_idx, row_idx = np.meshgrid(cols, rows, indexing="ij")
    u_flat = ((col_idx + 0.5) / resolution).ravel().astype(np.float32)
    v_flat = ((row_idx + 0.5) / resolution).ravel().astype(np.float32)

    s = u_flat * 2.0 - 1.0
    t = v_flat * 2.0 - 1.0
    # Equiangular pre-distortion — must match cube_sphere.face_uv_to_xyz.
    s = np.tan(s * EQUIANGULAR_ALPHA) / np.tan(EQUIANGULAR_ALPHA)
    t = np.tan(t * EQUIANGULAR_ALPHA) / np.tan(EQUIANGULAR_ALPHA)
    ones = np.ones_like(s)

    for face in range(6):
        print(f"  face {face}/5 ...", end=" ", flush=True)

        if face == 0:
            x, y, z_c = ones, s, t
        elif face == 1:
            x, y, z_c = -ones, -s, t
        elif face == 2:
            x, y, z_c = s, ones, t
        elif face == 3:
            x, y, z_c = -s, -ones, t
        elif face == 4:
            x, y, z_c = s, t, ones
        else:
            x, y, z_c = s, -t, -ones

        mag = np.sqrt(x**2 + y**2 + z_c**2)
        x, y, z_c = x / mag, y / mag, z_c / mag

        lon = np.degrees(np.arctan2(y, x)).astype(np.float32)
        lat = np.degrees(np.arcsin(np.clip(z_c, -1.0, 1.0))).astype(np.float32)

        elev = _sample_elevation(lats, lons, z_grid, lat, lon)

        vect_elev = np.vectorize(elev_to_layers)
        vect_bath = np.vectorize(depth_to_layers)
        elev_layers = vect_elev(elev).astype(np.uint8)
        bath_layers = vect_bath(elev).astype(np.uint8)

        elev_face = elev_layers.reshape(resolution, resolution)
        bath_face = bath_layers.reshape(resolution, resolution)
        if face in MIRRORED_FACES:
            elev_face = elev_face[:, ::-1]
            bath_face = bath_face[:, ::-1]
        elev_grid[face] = elev_face
        bath_grid[face] = bath_face

        print(
            f"elev max={int(elev_grid[face].max())}  "
            f"bath max={int(bath_grid[face].max())}  "
            f"ocean_cells={int((bath_grid[face] > 0).sum())}"
        )

    return elev_grid, bath_grid


def rasterize(nc_path: Path, config: dict, repo_root: Path) -> np.ndarray:
    """Build or load cached elevation and bathymetry grids.

    Returns the elevation grid (6, resolution, resolution) uint8.
    Also writes bathymetry.npy to the same cache directory as a side-effect.
    """
    resolution = config["planet"]["resolution"]
    cache_path = repo_root / CACHE_REL
    bath_path  = repo_root / BATH_CACHE_REL

    if (
        cache_path.exists()
        and bath_path.exists()
        and nc_path.exists()
        and cache_path.stat().st_mtime > nc_path.stat().st_mtime
    ):
        arr = np.load(cache_path)
        if arr.shape == (6, resolution, resolution):
            print(f"Cache hit: {cache_path}")
            return arr
        print(f"Cache shape mismatch ({arr.shape}) — rebuilding.")

    if not nc_path.exists():
        print(f"ETOPO file not found: {nc_path}", file=sys.stderr)
        print("Run: python pipeline/src/download.py --etopo", file=sys.stderr)
        sys.exit(1)

    print(f"Building elevation + bathymetry grids at resolution {resolution} ...")
    elev_grid, bath_grid = build_elevation(nc_path, resolution)

    cache_path.parent.mkdir(parents=True, exist_ok=True)
    np.save(cache_path, elev_grid)
    np.save(bath_path,  bath_grid)

    nonzero = int((elev_grid > 0).sum())
    total = 6 * resolution * resolution
    print(f"\nDone: {nonzero:,} elevated cells ({nonzero / total:.1%})")
    print(f"Cached elevation to {cache_path}")
    print(f"Cached bathymetry to {bath_path}")
    return elev_grid


def main() -> None:
    parser = argparse.ArgumentParser(description="Rasterize ETOPO elevation onto cube sphere.")
    parser.add_argument("--config", default="pipeline/config/planet.yaml")
    parser.add_argument("--root", default=".")
    parser.add_argument("--nc", default=None, help="Override path to ETOPO .nc file")
    args = parser.parse_args()

    config = load_config(Path(args.config))
    repo_root = Path(args.root).resolve()
    nc_path = Path(args.nc) if args.nc else repo_root / DEFAULT_NC_REL

    rasterize(nc_path, config, repo_root)


if __name__ == "__main__":
    main()
