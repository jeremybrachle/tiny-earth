class_name ChunkLoader

const CHUNK_SIZE := 16


static func load(face: int, cx: int, cy: int) -> PackedByteArray:
	return _load_path("res://planet/faces/face_%d/chunk_%d_%d.bin" % [face, cx, cy])


static func load_inner(face: int, cx: int, cy: int) -> PackedByteArray:
	return _load_path("res://planet/faces/face_%d/inner_chunk_%d_%d.bin" % [face, cx, cy])


static func load_shell(face: int, shell: int, cx: int, cy: int) -> PackedByteArray:
	if shell == 0:
		return ChunkLoader.load(face, cx, cy)
	elif shell == 1:
		return load_inner(face, cx, cy)
	else:
		push_error("ChunkLoader.load_shell: invalid shell %d" % shell)
		return PackedByteArray()


static func shells_from_config(planet_config: Dictionary) -> int:
	return planet_config.get("shells", 2)


static func _load_path(p: String) -> PackedByteArray:
	var f := FileAccess.open(p, FileAccess.READ)
	if not f:
		push_error("ChunkLoader: failed to open %s — error %d" % [p, FileAccess.get_open_error()])
		return PackedByteArray()
	var compressed := f.get_buffer(f.get_length())
	f.close()
	var raw := compressed.decompress(
		CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE, FileAccess.COMPRESSION_DEFLATE
	)
	if raw.is_empty():
		push_error("ChunkLoader: decompression failed for %s" % p)
		return PackedByteArray()
	return raw


static func voxel(data: PackedByteArray, lc: int, lr: int, depth: int) -> int:
	return data[lc + CHUNK_SIZE * (lr + CHUNK_SIZE * depth)]
