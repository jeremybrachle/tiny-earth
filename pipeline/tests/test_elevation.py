"""
Tests for pipeline/src/elevation.py
"""

import os
from pathlib import Path
from unittest.mock import patch

import numpy as np
import pytest

from elevation import elev_to_layers, build_elevation, VOXEL_LAYERS, MAX_ELEV_M, MIRRORED_FACES


# ---------------------------------------------------------------------------
# elev_to_layers unit tests
# ---------------------------------------------------------------------------

def test_elev_to_layers_zero():
    assert elev_to_layers(0) == 0


def test_elev_to_layers_negative():
    assert elev_to_layers(-500) == 0


def test_elev_to_layers_negative_large():
    assert elev_to_layers(-11000) == 0


def test_elev_to_layers_everest():
    assert elev_to_layers(MAX_ELEV_M) == VOXEL_LAYERS


def test_elev_to_layers_everest_slightly_above():
    # Values above MAX_ELEV_M should clamp to VOXEL_LAYERS
    assert elev_to_layers(MAX_ELEV_M + 100) == VOXEL_LAYERS


def test_elev_to_layers_midrange():
    # ~4000 m should be in [3, 5]
    result = elev_to_layers(4000)
    assert 3 <= result <= 5


def test_elev_to_layers_low_terrain():
    # 100 m should be layer 1 (the minimum positive layer)
    assert elev_to_layers(100) == 1


def test_elev_to_layers_returns_int():
    assert isinstance(elev_to_layers(1000), int)


def test_elev_to_layers_all_values_in_range():
    for elev in [-1000, 0, 100, 1000, 4000, 8000, 8849, 9000]:
        result = elev_to_layers(elev)
        assert 0 <= result <= VOXEL_LAYERS, f"elev={elev} → layers={result}"


# ---------------------------------------------------------------------------
# MIRRORED_FACES constant
#
# Must stay empty. The pipeline and Godot use the same face_uv_to_xyz formula,
# so the data needs no per-face flip. The east-west mirror seen earlier was a
# rendering bug (a reflection in Godot's Z-up → Y-up conversion), fixed in
# engine/scripts/planet/cube_face.gd — not a data problem.
# ---------------------------------------------------------------------------

def test_mirrored_faces_is_empty():
    assert MIRRORED_FACES == frozenset()


def test_mirrored_faces_contains_no_faces():
    for face in [0, 1, 2, 3, 4, 5]:
        assert face not in MIRRORED_FACES


# ---------------------------------------------------------------------------
# build_elevation with synthetic ETOPO data
# ---------------------------------------------------------------------------

def _make_synthetic_etopo(tmp_path: Path, flat_value: float = 0.0):
    """
    Write a minimal ETOPO-shaped NetCDF to tmp_path/etopo.nc using scipy.
    Returns the path.
    """
    from scipy.io import netcdf_file

    nlat, nlon = 180, 360
    lats = np.linspace(-89.5, 89.5, nlat, dtype=np.float32)
    lons = np.linspace(-179.5, 179.5, nlon, dtype=np.float32)
    z = np.full((nlat, nlon), flat_value, dtype=np.float32)

    nc_path = tmp_path / "etopo.nc"
    with netcdf_file(str(nc_path), "w") as f:
        f.createDimension("lat", nlat)
        f.createDimension("lon", nlon)
        lat_var = f.createVariable("lat", np.float32, ("lat",))
        lat_var[:] = lats
        lon_var = f.createVariable("lon", np.float32, ("lon",))
        lon_var[:] = lons
        z_var = f.createVariable("z", np.float32, ("lat", "lon"))
        z_var[:] = z

    return nc_path


def test_build_elevation_shape(tmp_path):
    nc_path = _make_synthetic_etopo(tmp_path, flat_value=0.0)
    resolution = 16
    elev, bath = build_elevation(nc_path, resolution)
    assert elev.shape == (6, resolution, resolution)
    assert bath.shape == (6, resolution, resolution)


def test_build_elevation_dtype(tmp_path):
    nc_path = _make_synthetic_etopo(tmp_path, flat_value=0.0)
    elev, bath = build_elevation(nc_path, 8)
    assert elev.dtype == np.uint8
    assert bath.dtype == np.uint8


def test_build_elevation_all_ocean_is_zero(tmp_path):
    nc_path = _make_synthetic_etopo(tmp_path, flat_value=-100.0)
    elev, bath = build_elevation(nc_path, 8)
    # Ocean everywhere → no land elevation layers.
    assert elev.max() == 0


def test_build_elevation_all_everest_is_max(tmp_path):
    nc_path = _make_synthetic_etopo(tmp_path, flat_value=float(MAX_ELEV_M))
    elev, bath = build_elevation(nc_path, 8)
    assert elev.min() == VOXEL_LAYERS
    assert elev.max() == VOXEL_LAYERS


def test_build_elevation_values_in_range(tmp_path):
    nc_path = _make_synthetic_etopo(tmp_path, flat_value=4000.0)
    elev, bath = build_elevation(nc_path, 8)
    assert elev.min() >= 0
    assert elev.max() <= VOXEL_LAYERS


def test_build_elevation_mirror_faces_present(tmp_path):
    """build_elevation should apply column flip for MIRRORED_FACES without error."""
    # Use an asymmetric z field so a flip would produce a different result
    from scipy.io import netcdf_file
    nlat, nlon = 180, 360
    lats = np.linspace(-89.5, 89.5, nlat, dtype=np.float32)
    lons = np.linspace(-179.5, 179.5, nlon, dtype=np.float32)
    # Gradient so left != right
    z = np.tile(np.linspace(0, MAX_ELEV_M, nlon, dtype=np.float32), (nlat, 1))
    nc_path = tmp_path / "etopo_grad.nc"
    with netcdf_file(str(nc_path), "w") as f:
        f.createDimension("lat", nlat)
        f.createDimension("lon", nlon)
        f.createVariable("lat", np.float32, ("lat",))[:] = lats
        f.createVariable("lon", np.float32, ("lon",))[:] = lons
        f.createVariable("z", np.float32, ("lat", "lon"))[:] = z
    elev, bath = build_elevation(nc_path, 8)
    assert elev.shape == (6, 8, 8)
    assert bath.shape == (6, 8, 8)


# ---------------------------------------------------------------------------
# Integration tests (skipped if ETOPO file absent)
# ---------------------------------------------------------------------------

ETOPO_PATH = Path(__file__).parents[2] / "data/cache/etopo_60s.nc"
ELEV_NPY   = Path(__file__).parents[2] / "data/cache/elevation.npy"

skip_if_no_etopo = pytest.mark.skipif(
    not ETOPO_PATH.exists(),
    reason="ETOPO file not downloaded (run: python pipeline/src/download.py --etopo)"
)
skip_if_no_elev = pytest.mark.skipif(
    not ELEV_NPY.exists(),
    reason="elevation.npy not generated (run: python pipeline/src/elevation.py)"
)


@skip_if_no_elev
def test_elevation_npy_shape():
    arr = np.load(ELEV_NPY)
    # Resolution is set by planet.yaml and may change (256, 512, ...).
    # Assert the cube-face layout and square faces rather than a fixed size.
    assert arr.ndim == 3
    assert arr.shape[0] == 6
    assert arr.shape[1] == arr.shape[2]


@skip_if_no_elev
def test_elevation_npy_dtype():
    arr = np.load(ELEV_NPY)
    assert arr.dtype == np.uint8


@skip_if_no_elev
def test_elevation_npy_values_in_range():
    arr = np.load(ELEV_NPY)
    assert arr.min() >= 0
    assert arr.max() <= VOXEL_LAYERS


@skip_if_no_elev
def test_elevation_some_cells_elevated():
    arr = np.load(ELEV_NPY)
    frac = (arr > 0).sum() / arr.size
    assert frac >= 0.05, f"Only {frac:.1%} of cells elevated — expected ≥5%"


@skip_if_no_elev
def test_everest_has_high_elevation():
    from cube_sphere import latlon_to_face_uv, face_uv_to_grid
    arr = np.load(ELEV_NPY)
    res = arr.shape[1]
    face, u, v = latlon_to_face_uv(27.99, 86.93)  # Everest
    col, row = face_uv_to_grid(u, v, res)
    layers = int(arr[face, col, row])
    # The exact layer count depends on resolution and nearest-neighbor sampling:
    # the cell center near the summit lands on ~6 layers at res=512 but ~5 at
    # res=256. The point of this test is that the Everest region is high terrain,
    # not flat/ocean — so the threshold scales with resolution.
    threshold = 6 if res >= 512 else 5
    assert layers >= threshold, f"Everest region layers={layers}, expected ≥{threshold} (high terrain)"


@skip_if_no_elev
def test_pacific_center_is_flat():
    from cube_sphere import latlon_to_face_uv, face_uv_to_grid
    arr = np.load(ELEV_NPY)
    res = arr.shape[1]
    face, u, v = latlon_to_face_uv(0.0, -150.0)  # Pacific Ocean
    col, row = face_uv_to_grid(u, v, res)
    layers = int(arr[face, col, row])
    assert layers == 0, f"Pacific center layers={layers}, expected 0"
