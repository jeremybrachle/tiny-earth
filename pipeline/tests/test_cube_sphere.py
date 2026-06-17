"""
Unit tests for cube_sphere.py.

All round-trip tests must pass within floating-point tolerance.
Known geographic points are tested against their expected face assignments
to catch any face orientation bugs early.
"""

import math

import pytest

from cube_sphere import (
    FACE_NX,
    FACE_NY,
    FACE_NZ,
    FACE_PX,
    FACE_PY,
    FACE_PZ,
    face_uv_to_grid,
    face_uv_to_latlon,
    face_uv_to_xyz,
    grid_to_chunk,
    latlon_to_face_uv,
    latlon_to_xyz,
)

TOLERANCE = 1e-9
DEGREE_TOLERANCE = 1e-6


# ---------------------------------------------------------------------------
# Round-trip: latlon → face_uv → latlon
# ---------------------------------------------------------------------------

ROUND_TRIP_POINTS = [
    # (lat, lon, description)
    (0.0, 0.0, "null island (+X face center)"),
    (0.0, 90.0, "+Y face center"),
    (0.0, -90.0, "-Y face center"),
    (0.0, 180.0, "-X face center"),
    (90.0, 0.0, "north pole (+Z)"),
    (-90.0, 0.0, "south pole (-Z)"),
    (51.5, -0.1, "London"),
    (40.7, -74.0, "New York"),
    (35.7, 139.7, "Tokyo"),
    (-33.9, 151.2, "Sydney"),
    (-22.9, -43.2, "Rio de Janeiro"),
    (30.0, 31.2, "Cairo"),
    (55.8, 37.6, "Moscow"),
    (1.3, 103.8, "Singapore"),
    (-34.6, -58.4, "Buenos Aires"),
    (48.9, 2.3, "Paris"),
    (28.6, 77.2, "New Delhi"),
    (6.5, 3.4, "Lagos"),
    (-4.3, 15.3, "Kinshasa"),
    (64.1, -21.9, "Reykjavik"),
]


@pytest.mark.parametrize("lat,lon,label", ROUND_TRIP_POINTS)
def test_round_trip(lat, lon, label):
    face, u, v = latlon_to_face_uv(lat, lon)
    lat2, lon2 = face_uv_to_latlon(face, u, v)

    # Normalize longitude to [-180, 180] for comparison
    def norm_lon(x):
        return ((x + 180) % 360) - 180

    assert abs(lat2 - lat) < DEGREE_TOLERANCE, f"{label}: lat {lat} → {lat2}"
    assert abs(norm_lon(lon2) - norm_lon(lon)) < DEGREE_TOLERANCE, f"{label}: lon {lon} → {lon2}"


# ---------------------------------------------------------------------------
# UV bounds: all outputs must be in [0, 1]
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("lat,lon,label", ROUND_TRIP_POINTS)
def test_uv_in_unit_range(lat, lon, label):
    face, u, v = latlon_to_face_uv(lat, lon)
    assert 0.0 <= u <= 1.0, f"{label}: u={u}"
    assert 0.0 <= v <= 1.0, f"{label}: v={v}"


# ---------------------------------------------------------------------------
# Known face assignments
# ---------------------------------------------------------------------------


def test_null_island_is_px_face():
    face, u, v = latlon_to_face_uv(0.0, 0.0)
    assert face == FACE_PX


def test_lon90_is_py_face():
    face, _, _ = latlon_to_face_uv(0.0, 90.0)
    assert face == FACE_PY


def test_lon_neg90_is_ny_face():
    face, _, _ = latlon_to_face_uv(0.0, -90.0)
    assert face == FACE_NY


def test_lon180_is_nx_face():
    face, _, _ = latlon_to_face_uv(0.0, 180.0)
    assert face == FACE_NX


def test_north_pole_is_pz_face():
    face, _, _ = latlon_to_face_uv(90.0, 0.0)
    assert face == FACE_PZ


def test_south_pole_is_nz_face():
    face, _, _ = latlon_to_face_uv(-90.0, 0.0)
    assert face == FACE_NZ


# ---------------------------------------------------------------------------
# Face centers map to UV (0.5, 0.5)
# ---------------------------------------------------------------------------

FACE_CENTERS = [
    (FACE_PX, 0.0, 0.0),
    (FACE_NX, 0.0, 180.0),
    (FACE_PY, 0.0, 90.0),
    (FACE_NY, 0.0, -90.0),
    (FACE_PZ, 90.0, 0.0),
    (FACE_NZ, -90.0, 0.0),
]


@pytest.mark.parametrize("face,lat,lon", FACE_CENTERS)
def test_face_center_is_uv_half(face, lat, lon):
    _, u, v = latlon_to_face_uv(lat, lon)
    assert abs(u - 0.5) < DEGREE_TOLERANCE, f"face {face}: u={u}"
    assert abs(v - 0.5) < DEGREE_TOLERANCE, f"face {face}: v={v}"


# ---------------------------------------------------------------------------
# latlon_to_xyz: result must be a unit vector
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("lat,lon,label", ROUND_TRIP_POINTS)
def test_xyz_is_unit_vector(lat, lon, label):
    x, y, z = latlon_to_xyz(lat, lon)
    mag = math.sqrt(x * x + y * y + z * z)
    assert abs(mag - 1.0) < TOLERANCE, f"{label}: |xyz|={mag}"


# ---------------------------------------------------------------------------
# face_uv_to_xyz: result must be a unit vector
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("face,lat,lon", FACE_CENTERS)
def test_face_uv_to_xyz_unit_vector(face, lat, lon):
    x, y, z = face_uv_to_xyz(face, 0.5, 0.5)
    mag = math.sqrt(x * x + y * y + z * z)
    assert abs(mag - 1.0) < TOLERANCE


# ---------------------------------------------------------------------------
# face_uv_to_grid
# ---------------------------------------------------------------------------


def test_grid_cell_bottom_left():
    col, row = face_uv_to_grid(0.0, 0.0, resolution=256)
    assert col == 0 and row == 0


def test_grid_cell_top_right():
    col, row = face_uv_to_grid(1.0, 1.0, resolution=256)
    assert col == 255 and row == 255


def test_grid_cell_center():
    col, row = face_uv_to_grid(0.5, 0.5, resolution=256)
    assert col == 128 and row == 128


def test_grid_cell_clamped():
    # u/v slightly over 1.0 due to float arithmetic should not go out of bounds
    col, row = face_uv_to_grid(0.9999999, 0.9999999, resolution=256)
    assert 0 <= col <= 255
    assert 0 <= row <= 255


# ---------------------------------------------------------------------------
# grid_to_chunk
# ---------------------------------------------------------------------------


def test_chunk_index_first_cell():
    cx, cy, lc, lr = grid_to_chunk(0, 0, chunk_size=16)
    assert cx == 0 and cy == 0 and lc == 0 and lr == 0


def test_chunk_index_second_chunk():
    cx, cy, lc, lr = grid_to_chunk(16, 0, chunk_size=16)
    assert cx == 1 and cy == 0 and lc == 0 and lr == 0


def test_chunk_local_offset():
    cx, cy, lc, lr = grid_to_chunk(17, 5, chunk_size=16)
    assert cx == 1 and cy == 0 and lc == 1 and lr == 5


def test_chunk_last_cell():
    cx, cy, lc, lr = grid_to_chunk(255, 255, chunk_size=16)
    assert cx == 15 and cy == 15 and lc == 15 and lr == 15
