class_name Coords

# Geographic ↔ planet coordinate conversion (GDScript port of the forward half of
# pipeline/src/cube_sphere.py). Lets in-engine systems address the planet by real
# WGS84 lat/lon instead of raw world vectors — the seam the spawn-point menu and
# landmark placement both build on.
#
# Single source of truth: the cube-face *inverse* projection
# (xyz → face/col/row, with its equiangular pre-distortion) lives once in
# CubeFace.unit_to_face_col_row(). This file does NOT re-implement it; it only
# adds the lat/lon → unit-vector step and reuses that tested inverse, so the two
# can never drift. The lat/lon math mirrors cube_sphere.py latlon_to_xyz, and the
# Z-up (geographic) → Y-up (Godot world) rotation matches CubeFace.face_uv_to_unit
# exactly — verified against the baked Kansas spawn ((39.5°N, 98.5°W) → the
# Player transform in world.tscn).


# WGS84 lat/lon (degrees) → a unit vector in Godot WORLD space (Y-up).
#
# Geographic frame (matches cube_sphere.py) is Z-up:
#   x = cos(lat)·cos(lon),  y = cos(lat)·sin(lon),  z = sin(lat)
# CubeFace.face_uv_to_unit maps that Z-up point to Y-up world as (x, z, -y) — a
# proper rotation (det +1), NOT a bare axis swap (which mirrors east-west). We
# apply the same rotation here so the result lines up with the rendered planet.
static func latlon_to_unit(lat_deg: float, lon_deg: float) -> Vector3:
	var lat := deg_to_rad(lat_deg)
	var lon := deg_to_rad(lon_deg)
	var x := cos(lat) * cos(lon)
	var y := cos(lat) * sin(lon)
	var z := sin(lat)
	return Vector3(x, z, -y)


# WGS84 lat/lon (degrees) → a point on a sphere of the given radius, in world
# space. Convenience for "put this at sea level over (lat, lon)"; callers that
# need to sit on terrain still raise to the surface voxel themselves.
static func latlon_to_world(lat_deg: float, lon_deg: float, radius: float) -> Vector3:
	return latlon_to_unit(lat_deg, lon_deg) * radius


# WGS84 lat/lon (degrees) → [face, col, row] at the given face resolution.
# Delegates to the cube-face inverse projection (the one the mesher uses), so the
# cell returned is exactly the voxel column the renderer draws at that location.
static func latlon_to_face_col_row(lat_deg: float, lon_deg: float, resolution: int) -> Array:
	return CubeFace.unit_to_face_col_row(latlon_to_unit(lat_deg, lon_deg), resolution)
