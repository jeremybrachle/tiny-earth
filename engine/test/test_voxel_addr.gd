extends GutTest

# Unit tests for VoxelAddr (scripts/planet/voxel_addr.gd) — the address math that
# maps a flat (col, row, depth) coordinate to/from (chunk, local) coordinates.


func test_defaults_are_zero() -> void:
	var a := VoxelAddr.new()
	assert_eq(a.face, 0)
	assert_eq(a.shell, 0)
	assert_eq(a.chunk_u, 0)
	assert_eq(a.local_u, 0)
	assert_eq(a.local_r, 0)


func test_from_face_col_row_decomposes_chunk_and_local() -> void:
	# col=20 with chunk_size=16 -> chunk 1, local 4
	var a := VoxelAddr.from_face_col_row(2, 1, 20, 5, 3, 16)
	assert_eq(a.face, 2)
	assert_eq(a.shell, 1)
	assert_eq(a.chunk_u, 1)
	assert_eq(a.chunk_v, 0)
	assert_eq(a.local_u, 4)
	assert_eq(a.local_v, 5)
	assert_eq(a.local_r, 3)


func test_round_trips_col_row_depth() -> void:
	var chunk_size := 16
	for col in [0, 7, 16, 31, 100]:
		for row in [0, 15, 48]:
			var depth := 9
			var a := VoxelAddr.from_face_col_row(0, 0, col, row, depth, chunk_size)
			var crd := a.to_col_row_depth(chunk_size)
			assert_eq(
				crd, Vector3i(col, row, depth), "round-trip failed for col=%d row=%d" % [col, row]
			)


func test_equals() -> void:
	var a := VoxelAddr.new(1, 0, 2, 3, 4, 5, 6)
	var b := VoxelAddr.new(1, 0, 2, 3, 4, 5, 6)
	var c := VoxelAddr.new(1, 0, 2, 3, 4, 5, 7)
	assert_true(a.equals(b))
	assert_false(a.equals(c))
