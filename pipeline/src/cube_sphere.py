"""
Cube sphere coordinate conversion: WGS84 lat/lon ↔ cube face UV.

All geographic data enters the pipeline as lat/lon and exits as
(face, u, v) — Godot never sees raw geographic coordinates.

Face layout (right-hand coordinate system, Z-up):
  0 = +X face   1 = -X face
  2 = +Y face   3 = -Y face
  4 = +Z face   5 = -Z face

UV coordinates are in [0, 1] with (0,0) at the face corner
corresponding to the most-negative local axes.
"""

import math

FACE_PX, FACE_NX = 0, 1
FACE_PY, FACE_NY = 2, 3
FACE_PZ, FACE_NZ = 4, 5

NUM_FACES = 6


def latlon_to_xyz(lat_deg: float, lon_deg: float) -> tuple[float, float, float]:
    """Convert WGS84 lat/lon (degrees) to a unit sphere point."""
    lat = math.radians(lat_deg)
    lon = math.radians(lon_deg)
    x = math.cos(lat) * math.cos(lon)
    y = math.cos(lat) * math.sin(lon)
    z = math.sin(lat)
    return x, y, z


def xyz_to_latlon(x: float, y: float, z: float) -> tuple[float, float]:
    """Convert a unit sphere point to WGS84 lat/lon (degrees)."""
    lat = math.degrees(math.asin(max(-1.0, min(1.0, z))))
    lon = math.degrees(math.atan2(y, x))
    return lat, lon


def xyz_to_face_uv(x: float, y: float, z: float) -> tuple[int, float, float]:
    """
    Project a unit sphere point onto a cube face.

    Returns (face, u, v) where u and v are in [0, 1].
    The dominant axis determines the face; the other two axes
    determine the UV position within that face.
    """
    ax, ay, az = abs(x), abs(y), abs(z)

    if ax >= ay and ax >= az:
        if x > 0:
            face = FACE_PX
            u_raw, v_raw = y / x, z / x
        else:
            face = FACE_NX
            u_raw, v_raw = -y / (-x), z / (-x)
    elif ay >= ax and ay >= az:
        if y > 0:
            face = FACE_PY
            u_raw, v_raw = x / y, z / y
        else:
            face = FACE_NY
            u_raw, v_raw = -x / (-y), z / (-y)
    else:
        if z > 0:
            face = FACE_PZ
            u_raw, v_raw = x / z, y / z
        else:
            face = FACE_NZ
            u_raw, v_raw = x / (-z), -y / (-z)

    # u_raw, v_raw are in [-1, 1] — normalize to [0, 1]
    return face, (u_raw + 1.0) / 2.0, (v_raw + 1.0) / 2.0


def face_uv_to_xyz(face: int, u: float, v: float) -> tuple[float, float, float]:
    """
    Unproject a cube face UV coordinate back to a unit sphere point.

    u and v must be in [0, 1].
    """
    # Denormalize [0,1] → [-1,1]
    s = u * 2.0 - 1.0
    t = v * 2.0 - 1.0

    if face == FACE_PX:
        x, y, z = 1.0, s, t
    elif face == FACE_NX:
        x, y, z = -1.0, -s, t
    elif face == FACE_PY:
        x, y, z = s, 1.0, t
    elif face == FACE_NY:
        x, y, z = -s, -1.0, t
    elif face == FACE_PZ:
        x, y, z = s, t, 1.0
    else:  # FACE_NZ
        x, y, z = s, -t, -1.0

    mag = math.sqrt(x * x + y * y + z * z)
    return x / mag, y / mag, z / mag


def latlon_to_face_uv(lat_deg: float, lon_deg: float) -> tuple[int, float, float]:
    """Convert WGS84 lat/lon to cube face UV. Convenience wrapper."""
    return xyz_to_face_uv(*latlon_to_xyz(lat_deg, lon_deg))


def face_uv_to_latlon(face: int, u: float, v: float) -> tuple[float, float]:
    """Convert cube face UV to WGS84 lat/lon. Convenience wrapper."""
    return xyz_to_latlon(*face_uv_to_xyz(face, u, v))


def face_uv_to_grid(u: float, v: float, resolution: int) -> tuple[int, int]:
    """
    Convert [0,1] UV to integer grid cell indices [0, resolution-1].

    Used to determine which voxel column a geographic point maps to.
    """
    col = min(int(u * resolution), resolution - 1)
    row = min(int(v * resolution), resolution - 1)
    return col, row


def grid_to_chunk(col: int, row: int, chunk_size: int) -> tuple[int, int, int, int]:
    """
    Convert a grid cell (col, row) to chunk index and local cell offset.

    Returns (chunk_x, chunk_y, local_col, local_row).
    """
    chunk_x = col // chunk_size
    chunk_y = row // chunk_size
    local_col = col % chunk_size
    local_row = row % chunk_size
    return chunk_x, chunk_y, local_col, local_row
