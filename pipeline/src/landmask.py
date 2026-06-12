"""
Rasterize Natural Earth land polygons onto the cube sphere grid.

Produces a (6, RESOLUTION, RESOLUTION) numpy uint8 array where:
  1 = Land
  2 = Ocean

Result is cached to data/cache/landmask.npy and reused if it is newer
than the source shapefile.

Usage:
    python pipeline/src/landmask.py
    python pipeline/src/landmask.py --config pipeline/config/planet.yaml --root .
"""

import argparse
import sys
from pathlib import Path

import numpy as np
import shapefile  # pyshp — pure Python, no GDAL needed
import shapely
import yaml
from shapely.geometry import shape

from cube_sphere import face_uv_to_xyz, xyz_to_latlon

MATERIAL_LAND = 1
MATERIAL_OCEAN = 2

# No faces need a data flip. The pipeline and Godot both use the same
# face_uv_to_xyz formula, so grid[face][col, row] maps to the same geographic
# position in both systems. Godot's winding-order flip for faces 2/3 is a
# rendering-only correction that does not affect data layout.
MIRRORED_FACES = frozenset()

CACHE_REL = Path("data/cache/landmask.npy")
DEFAULT_SHP_REL = Path("data/cache/ne_10m_land/ne_10m_land.shp")
DEFAULT_LAKES_REL = Path("data/cache/ne_10m_lakes/ne_10m_lakes.shp")


def load_config(config_path: Path) -> dict:
    with config_path.open() as f:
        return yaml.safe_load(f)


def load_land_geometry(shp_path: Path) -> shapely.Geometry:
    """Read the shapefile and return a single unioned land MultiPolygon."""
    with shapefile.Reader(str(shp_path)) as sf:
        polygons = [shape(s.__geo_interface__) for s in sf.shapes()]
    return shapely.unary_union(polygons)


def load_lakes_geometry(shp_path: Path) -> shapely.Geometry:
    """Read the lakes shapefile and return a single unioned lake MultiPolygon."""
    with shapefile.Reader(str(shp_path)) as sf:
        polygons = [shape(s.__geo_interface__) for s in sf.shapes()]
    return shapely.unary_union(polygons)


def build_landmask(
    land_geom: shapely.Geometry,
    resolution: int,
    lakes_geom: shapely.Geometry | None = None,
) -> np.ndarray:
    """
    Classify every surface voxel as Land or Ocean.

    Returns a (6, resolution, resolution) uint8 array.
    Uses shapely 2's vectorized contains_xy for speed (~5-15 s at res=256).
    If lakes_geom is provided, pixels inside lake polygons are set to Ocean.
    """
    grid = np.zeros((6, resolution, resolution), dtype=np.uint8)

    # Pre-compute UV centers for all cells — same for every face
    cols = np.arange(resolution)
    rows = np.arange(resolution)
    col_idx, row_idx = np.meshgrid(cols, rows, indexing="ij")  # (res, res)
    u_flat = ((col_idx + 0.5) / resolution).ravel()  # (res*res,)
    v_flat = ((row_idx + 0.5) / resolution).ravel()

    s = u_flat * 2.0 - 1.0
    t = v_flat * 2.0 - 1.0
    ones = np.ones_like(s)

    for face in range(6):
        print(f"  face {face}/5 ...", end=" ", flush=True)

        # Vectorized face_uv_to_xyz
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
        x, y, z = x / mag, y / mag, z / mag

        # Vectorized xyz_to_latlon (only lon/lat needed for contains_xy)
        lon = np.degrees(np.arctan2(y, x))
        lat = np.degrees(np.arcsin(np.clip(z, -1.0, 1.0)))

        # shapely 2 vectorized: contains_xy(geom, x=lon, y=lat)
        is_land = shapely.contains_xy(land_geom, lon, lat)

        face_data = is_land.reshape(resolution, resolution)
        if face in MIRRORED_FACES:
            face_data = face_data[:, ::-1]
        grid[face] = np.where(face_data, MATERIAL_LAND, MATERIAL_OCEAN)
        land_n = int(is_land.sum())

        # Subtract lakes: pixels inside lake polygons become Ocean regardless
        # of whether they were classified as Land above.
        if lakes_geom is not None:
            is_lake = shapely.contains_xy(lakes_geom, lon, lat)
            lake_data = is_lake.reshape(resolution, resolution)
            if face in MIRRORED_FACES:
                lake_data = lake_data[:, ::-1]
            grid[face] = np.where(lake_data, MATERIAL_OCEAN, grid[face])
            lake_n = int(is_lake.sum())
            print(f"{land_n}/{resolution * resolution} Land, {lake_n} Lake pixels")
        else:
            print(f"{land_n}/{resolution * resolution} Land")

    return grid


def rasterize(
    shp_path: Path,
    config: dict,
    repo_root: Path,
    lakes_path: Path | None = None,
) -> np.ndarray:
    """Build or load cached landmask. Returns (6, resolution, resolution) uint8."""
    resolution = config["planet"]["resolution"]
    cache_path = repo_root / CACHE_REL

    # Cache is invalid if lakes are requested but weren't used to build it,
    # so always rebuild when lakes_path is supplied.
    if (
        lakes_path is None
        and cache_path.exists()
        and shp_path.exists()
        and cache_path.stat().st_mtime > shp_path.stat().st_mtime
    ):
        print(f"Cache hit: {cache_path}")
        arr = np.load(cache_path)
        if arr.shape == (6, resolution, resolution):
            return arr
        print(f"Cache resolution mismatch ({arr.shape} vs {resolution}) — rebuilding.")

    print(f"Loading land polygons from {shp_path} ...")
    land_geom = load_land_geometry(shp_path)

    lakes_geom = None
    if lakes_path is not None and lakes_path.exists():
        print(f"Loading lakes from {lakes_path} ...")
        lakes_geom = load_lakes_geometry(lakes_path)
    elif lakes_path is not None:
        print(f"Warning: lakes shapefile not found at {lakes_path} — skipping lake subtraction.")

    total_points = 6 * resolution * resolution
    print(f"Rasterizing {total_points:,} points ({resolution}×{resolution} per face) ...")
    grid = build_landmask(land_geom, resolution, lakes_geom)

    cache_path.parent.mkdir(parents=True, exist_ok=True)
    np.save(cache_path, grid)

    land_count = int((grid == MATERIAL_LAND).sum())
    ocean_count = int((grid == MATERIAL_OCEAN).sum())
    print(
        f"\nDone: {land_count:,} Land ({land_count / total_points:.1%}), "
        f"{ocean_count:,} Ocean ({ocean_count / total_points:.1%})"
    )
    print(f"Cached to {cache_path}")

    return grid


def main() -> None:
    parser = argparse.ArgumentParser(description="Rasterize land mask onto cube sphere.")
    parser.add_argument("--config", default="pipeline/config/planet.yaml")
    parser.add_argument("--root", default=".")
    parser.add_argument("--shp", default=None, help="Override path to ne_10m_land.shp")
    parser.add_argument(
        "--lakes",
        action="store_true",
        help="Subtract lake polygons (ne_10m_lakes) from land — adds Great Lakes, Caspian, etc.",
    )
    parser.add_argument("--lakes-shp", default=None, help="Override path to ne_10m_lakes.shp")
    args = parser.parse_args()

    config = load_config(Path(args.config))
    repo_root = Path(args.root).resolve()
    shp_path = Path(args.shp) if args.shp else repo_root / DEFAULT_SHP_REL

    if not shp_path.exists():
        print(f"Shapefile not found: {shp_path}", file=sys.stderr)
        print("Run: python pipeline/src/download.py", file=sys.stderr)
        sys.exit(1)

    lakes_path = None
    if args.lakes:
        lakes_path = Path(args.lakes_shp) if args.lakes_shp else repo_root / DEFAULT_LAKES_REL
        if not lakes_path.exists():
            print(f"Lakes shapefile not found: {lakes_path}", file=sys.stderr)
            print("Run: python pipeline/src/download.py --lakes", file=sys.stderr)
            sys.exit(1)

    rasterize(shp_path, config, repo_root, lakes_path=lakes_path)


if __name__ == "__main__":
    main()
