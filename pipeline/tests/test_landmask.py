"""
Tests for landmask.py.

Unit tests use a synthetic geometry so no shapefile is needed.
Integration tests load data/cache/landmask.npy and are skipped when absent.
Run the full pipeline first to enable integration tests:
    python pipeline/src/download.py
    python pipeline/src/landmask.py
"""

from pathlib import Path

import numpy as np
import pytest
import shapely
from shapely.geometry import box

import landmask as lm
from cube_sphere import latlon_to_face_uv

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_REPO_ROOT = Path(__file__).parent.parent.parent
_CACHE_PATH = _REPO_ROOT / "data" / "cache" / "landmask.npy"


def _lookup(grid: np.ndarray, lat: float, lon: float) -> int:
    """Return the material ID at a geographic coordinate."""
    resolution = grid.shape[1]
    face, u, v = latlon_to_face_uv(lat, lon)
    col = min(int(u * resolution), resolution - 1)
    row = min(int(v * resolution), resolution - 1)
    return int(grid[face, col, row])


# ---------------------------------------------------------------------------
# Unit tests — synthetic geometry, no external data needed
# ---------------------------------------------------------------------------


def test_build_landmask_shape():
    land = box(-180, -90, 180, 90)  # whole globe is land
    grid = lm.build_landmask(land, resolution=8)
    assert grid.shape == (6, 8, 8)
    assert grid.dtype == np.uint8


def test_build_landmask_all_land():
    land = box(-180, -90, 180, 90)
    grid = lm.build_landmask(land, resolution=8)
    assert (grid == lm.MATERIAL_LAND).all()


def test_build_landmask_all_ocean():
    empty = shapely.from_wkt("GEOMETRYCOLLECTION EMPTY")
    grid = lm.build_landmask(empty, resolution=8)
    assert (grid == lm.MATERIAL_OCEAN).all()


def test_build_landmask_only_eastern_hemisphere():
    """Eastern hemisphere land (lon >= 0) should classify correctly."""
    eastern = box(0, -90, 180, 90)
    grid = lm.build_landmask(eastern, resolution=32)
    # Prime meridian, equator — just inside eastern hemisphere
    assert _lookup(grid, 0.0, 1.0) == lm.MATERIAL_LAND
    # Pacific center — western hemisphere
    assert _lookup(grid, 0.0, -150.0) == lm.MATERIAL_OCEAN


def test_material_ids_are_only_land_and_ocean():
    land = box(-90, -45, 90, 45)
    grid = lm.build_landmask(land, resolution=8)
    unique = set(grid.ravel().tolist())
    assert unique <= {lm.MATERIAL_LAND, lm.MATERIAL_OCEAN}


# ---------------------------------------------------------------------------
# Integration tests — skipped unless pipeline has been run
# ---------------------------------------------------------------------------


@pytest.fixture(scope="module")
def real_grid():
    if not _CACHE_PATH.exists():
        pytest.skip(
            f"landmask.npy not found at {_CACHE_PATH} — run the pipeline first:\n"
            "  python pipeline/src/download.py\n"
            "  python pipeline/src/landmask.py"
        )
    return np.load(_CACHE_PATH)


def test_north_pole_is_ocean(real_grid):
    # Arctic Ocean — no land at exactly 90°N
    assert _lookup(real_grid, 90.0, 0.0) == lm.MATERIAL_OCEAN


def test_amazon_basin_is_land(real_grid):
    # Amazon basin, Brazil ~3°S 60°W
    assert _lookup(real_grid, -3.0, -60.0) == lm.MATERIAL_LAND


def test_pacific_center_is_ocean(real_grid):
    # Mid-Pacific, well clear of any island
    assert _lookup(real_grid, 0.0, -150.0) == lm.MATERIAL_OCEAN


def test_land_fraction_in_expected_range(real_grid):
    total = real_grid.size
    land_frac = (real_grid == lm.MATERIAL_LAND).sum() / total
    assert 0.25 <= land_frac <= 0.45, (
        f"Land fraction {land_frac:.1%} is outside expected range 25–45%"
    )


def test_no_face_is_monochromatic(real_grid):
    for face in range(6):
        face_data = real_grid[face]
        assert (face_data == lm.MATERIAL_LAND).any(), f"Face {face} has no Land"
        assert (face_data == lm.MATERIAL_OCEAN).any(), f"Face {face} has no Ocean"
