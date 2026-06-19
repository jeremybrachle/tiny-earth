extends GutTest

# Unit tests for the lat/lon → planet coordinate port in scripts/planet/coords.gd.
# These guard the seam the spawn-point menu and landmark placement build on: a
# regression here would silently put every named location in the wrong spot.

const Coords := preload("res://scripts/planet/coords.gd")
const CubeFace := preload("res://scripts/planet/cube_face.gd")


func test_latlon_unit_is_unit_length() -> void:
	for ll in [Vector2(0, 0), Vector2(39.5, -98.5), Vector2(-33.9, 151.2), Vector2(90, 0)]:
		assert_almost_eq(Coords.latlon_to_unit(ll.x, ll.y).length(), 1.0, 1e-5)


func test_cardinal_directions() -> void:
	# (0°N, 0°E) is the +X axis; the north pole maps to world up (+Y); (0°N, 90°E)
	# is +Z in geographic Z-up → -... rotated to world. These pin the orientation.
	assert_almost_eq(
		Coords.latlon_to_unit(0, 0), Vector3(1, 0, 0), Vector3(1e-5, 1e-5, 1e-5)
	)
	assert_almost_eq(
		Coords.latlon_to_unit(90, 0), Vector3(0, 1, 0), Vector3(1e-5, 1e-5, 1e-5)
	)
	# (0°N, 90°E): geographic (0,1,0) → world (x, z, -y) = (0, 0, -1).
	assert_almost_eq(
		Coords.latlon_to_unit(0, 90), Vector3(0, 0, -1), Vector3(1e-5, 1e-5, 1e-5)
	)


func test_kansas_matches_baked_spawn() -> void:
	# The current hardcoded spawn (world.tscn Player transform) is Kansas,
	# ~39.5°N 98.5°W. Its normalized direction must equal what the port produces,
	# so swapping the baked transform for a lat/lon call doesn't move the player.
	var baked := Vector3(-29.64, 165.36, 198.38).normalized()
	assert_almost_eq(
		Coords.latlon_to_unit(39.5, -98.5), baked, Vector3(2e-3, 2e-3, 2e-3)
	)


func test_round_trip_through_face_col_row() -> void:
	# lat/lon → (face, col, row) → cell-centre unit vector should land back near
	# the original direction. Uses interior latitudes/longitudes to avoid the
	# face-seam clamping the projection tests already cover.
	var res := 256
	for ll in [Vector2(39.5, -98.5), Vector2(48.85, 2.35), Vector2(-1.29, 36.82)]:
		var want := Coords.latlon_to_unit(ll.x, ll.y)
		var fcr: Array = Coords.latlon_to_face_col_row(ll.x, ll.y, res)
		var u := (float(fcr[1]) + 0.5) / float(res)
		var v := (float(fcr[2]) + 0.5) / float(res)
		var got := CubeFace.face_uv_to_unit(int(fcr[0]), u, v)
		# One cell at res 256 subtends well under 1°; allow ~1 cell of slack.
		assert_almost_eq(got.dot(want), 1.0, 5e-4, "round-trip drift for %s" % ll)
