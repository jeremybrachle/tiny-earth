extends GutTest

# Unit tests for the equiangular cube-sphere projection in
# scripts/planet/cube_face.gd. These are the static functions the mesher and
# (eventually) spawn-coordinate placement rely on, so a round-trip regression
# here would quietly move the whole planet.

const CubeFace := preload("res://scripts/planet/cube_face.gd")


func test_face_centres_map_to_axes() -> void:
	# u=v=0.5 is the centre of a face; each centre should sit on its axis.
	assert_almost_eq(
		CubeFace.face_uv_to_unit(0, 0.5, 0.5), Vector3(1, 0, 0), Vector3(1e-5, 1e-5, 1e-5)
	)
	assert_almost_eq(
		CubeFace.face_uv_to_unit(4, 0.5, 0.5), Vector3(0, 1, 0), Vector3(1e-5, 1e-5, 1e-5)
	)


func test_points_are_unit_length() -> void:
	for face in range(6):
		for uv in [Vector2(0.1, 0.1), Vector2(0.5, 0.5), Vector2(0.9, 0.3)]:
			var p := CubeFace.face_uv_to_unit(face, uv.x, uv.y)
			assert_almost_eq(p.length(), 1.0, 1e-5)


func test_round_trip_uv_to_col_row() -> void:
	var res := 64
	for face in range(6):
		# Interior cells only — corner cells can clamp/round to a neighbour face.
		for col in [16, 32, 48]:
			for row in [16, 32, 48]:
				var u := (float(col) + 0.5) / float(res)
				var v := (float(row) + 0.5) / float(res)
				var unit := CubeFace.face_uv_to_unit(face, u, v)
				var fcr: Array = CubeFace.unit_to_face_col_row(unit, res)
				assert_eq(fcr[0], face, "face mismatch for face %d" % face)
				assert_almost_eq(fcr[1], col, 1)
				assert_almost_eq(fcr[2], row, 1)
