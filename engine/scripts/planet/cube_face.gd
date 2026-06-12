class_name CubeFace
extends StaticBody3D

const CHUNK_SIZE := 16
var planet_radius: float = 256.0  # set by VoxelPlanet before add_child; read from planet_config.json


# Material ID → vertex color (matches pipeline/src/biomes.py constants)
const MAT_COLORS := {
	1: Color(0.25, 0.55, 0.20),  # Land fallback
	2: Color(0.10, 0.35, 0.65),  # Ocean
	3: Color(0.85, 0.75, 0.45),  # Desert/Sand
	4: Color(0.40, 0.65, 0.25),  # Temperate (mid-latitude grassland)
	5: Color(0.15, 0.40, 0.15),  # Forest (boreal/subarctic)
	6: Color(0.90, 0.93, 0.97),  # Snow/Ice
	7: Color(0.10, 0.48, 0.12),  # Tropical rainforest
	8: Color(0.68, 0.62, 0.22),  # Savanna/grassland
	9: Color(0.52, 0.48, 0.44),  # Mountain/Rock
	10: Color(0.28, 0.22, 0.16), # Seafloor (sandy/rocky ocean floor)
}

@export var face_id: int = 0
@export var chunks_per_edge: int = 16

var _chunk_data  := {}   # int key (cx*CPE + cy) → PackedByteArray
var _mat: Material = null
var _water_mat: Material = null
var _chunk_insts := {}       # int key → MeshInstance3D
var _water_chunk_insts := {} # int key → MeshInstance3D

var _face_res       := 0
var _top_depth_grid := PackedInt32Array()  # [col * _face_res + row] → top depth (-1 = empty)
var _top_mat_grid   := PackedByteArray()   # [col * _face_res + row] → top material
var _chunk_col_shapes := {}   # int key → CollisionShape3D, one per chunk for elevated terrain


func _ready() -> void:
	_build_face()


func _build_face() -> void:
	_mat = ShaderMaterial.new()
	(_mat as ShaderMaterial).shader = load("res://shaders/voxel.gdshader") as Shader
	_water_mat = ShaderMaterial.new()
	(_water_mat as ShaderMaterial).shader = load("res://shaders/water.gdshader") as Shader

	_face_res = CHUNK_SIZE * chunks_per_edge
	_top_depth_grid.resize(_face_res * _face_res)
	_top_depth_grid.fill(-1)
	_top_mat_grid.resize(_face_res * _face_res)
	_top_mat_grid.fill(0)

	print("CubeFace %d: building %d×%d chunks" % [face_id, chunks_per_edge, chunks_per_edge])

	# Pass 1: load all chunks and populate the depth/material grid.
	# The grid must be complete before meshing so that side-wall generation
	# can look up neighbour depths across chunk boundaries.
	for cx in chunks_per_edge:
		for cy in chunks_per_edge:
			var data := ChunkLoader.load(face_id, cx, cy)
			if data.is_empty():
				continue
			_chunk_data[cx * chunks_per_edge + cy] = data
			_populate_grid_from_chunk(data, cx, cy)

	# Pass 2 + 3: build per-chunk land + ocean meshes from the start.
	for cx in chunks_per_edge:
		for cy in chunks_per_edge:
			var key := cx * chunks_per_edge + cy
			if _chunk_data.has(key):
				_rebuild_chunk(cx, cy, key)

	# Per-chunk collision: each 16×16 chunk gets its own CollisionShape3D covering
	# only its elevated columns (depth >= 1). Flat ground (depth 0) stays on the
	# VoxelPlanet sphere collider so we never overlap it.  On destroy only the one
	# affected chunk is rebuilt — O(256) instead of O(65536) per dig.
	for cx in chunks_per_edge:
		for cy in chunks_per_edge:
			_build_chunk_collision(cx, cy)

	print("CubeFace %d: done" % face_id)


# Build the collision trimesh for a single 16×16 chunk.  Only elevated columns
# (depth >= 1) are included; flat ground (depth 0) is covered by the VoxelPlanet
# sphere collider.  The shape is used with backface_collision = true so a capsule
# inside a column is ejected outward rather than trapped.
func _build_chunk_collision_mesh(cx: int, cy: int) -> ArrayMesh:
	var st       := SurfaceTool.new()
	var res      := float(_face_res)
	var vox_size := planet_radius / res
	var eps      := 0.5 / res
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for lc in CHUNK_SIZE:
		for lr in CHUNK_SIZE:
			var col := cx * CHUNK_SIZE + lc
			var row := cy * CHUNK_SIZE + lr
			var cf  := _column_faces(col, row)
			var r: float = planet_radius + cf.top_depth * vox_size

			if cf.emit_top:
				var p00 := face_uv_to_unit(face_id,  col       / res,  row       / res) * r
				var p10 := face_uv_to_unit(face_id, (col + 1)  / res,  row       / res) * r
				var p01 := face_uv_to_unit(face_id,  col       / res, (row + 1)  / res) * r
				var p11 := face_uv_to_unit(face_id, (col + 1)  / res, (row + 1)  / res) * r

				var outward := (p00 + p10 + p01 + p11) * 0.25
				if (p10 - p00).cross(p11 - p00).dot(outward) > 0.0:
					st.add_vertex(p00); st.add_vertex(p10); st.add_vertex(p11)
					st.add_vertex(p00); st.add_vertex(p11); st.add_vertex(p01)
				else:
					st.add_vertex(p00); st.add_vertex(p11); st.add_vertex(p10)
					st.add_vertex(p00); st.add_vertex(p01); st.add_vertex(p11)

			for wall in cf.walls:
				var dir: Vector2i = wall.dir
				var r_base: float = planet_radius + wall.base_layer * vox_size
				var u_a: float; var v_a: float; var u_b: float; var v_b: float
				if dir.x == 1:
					u_a = (col + 1) / res;  v_a = row       / res
					u_b = (col + 1) / res;  v_b = (row + 1) / res
				elif dir.x == -1:
					u_a = col       / res;  v_a = (row + 1) / res
					u_b = col       / res;  v_b = row       / res
				elif dir.y == 1:
					u_a = (col + 1) / res;  v_a = (row + 1) / res
					u_b = col       / res;  v_b = (row + 1) / res
				else:
					u_a = col       / res;  v_a = row       / res
					u_b = (col + 1) / res;  v_b = row       / res

				var pa_base := face_uv_to_unit(face_id, u_a, v_a) * r_base
				var pb_base := face_uv_to_unit(face_id, u_b, v_b) * r_base
				var pa_top  := face_uv_to_unit(face_id, u_a, v_a) * r
				var pb_top  := face_uv_to_unit(face_id, u_b, v_b) * r

				var u_mid  := (u_a + u_b) * 0.5
				var v_mid  := (v_a + v_b) * 0.5
				var mid_pt := face_uv_to_unit(face_id, u_mid, v_mid)
				var out_pt := face_uv_to_unit(face_id, u_mid + dir.x * eps, v_mid + dir.y * eps)
				var expected_out := out_pt - mid_pt

				if (pa_top - pa_base).cross(pb_top - pa_base).dot(expected_out) > 0.0:
					st.add_vertex(pa_base); st.add_vertex(pa_top);  st.add_vertex(pb_top)
					st.add_vertex(pa_base); st.add_vertex(pb_top);  st.add_vertex(pb_base)
				else:
					st.add_vertex(pa_base); st.add_vertex(pb_top);  st.add_vertex(pa_top)
					st.add_vertex(pa_base); st.add_vertex(pb_base); st.add_vertex(pb_top)
	return st.commit()


func _build_chunk_collision(cx: int, cy: int) -> void:
	var key := cx * chunks_per_edge + cy
	var old := _chunk_col_shapes.get(key) as CollisionShape3D
	if old != null and is_instance_valid(old):
		old.queue_free()
		_chunk_col_shapes.erase(key)
	var mesh := _build_chunk_collision_mesh(cx, cy)
	if mesh == null or mesh.get_surface_count() == 0:
		return
	var shape := mesh.create_trimesh_shape()
	shape.backface_collision = true
	var col_shape := CollisionShape3D.new()
	col_shape.shape = shape
	add_child(col_shape)
	_chunk_col_shapes[key] = col_shape


func _populate_grid_from_chunk(data: PackedByteArray, cx: int, cy: int) -> void:
	for lc in CHUNK_SIZE:
		for lr in CHUNK_SIZE:
			var top_depth := -1
			var top_mat   := 0
			for depth in CHUNK_SIZE:
				var m := ChunkLoader.voxel(data, lc, lr, depth)
				if m == 0:
					break
				top_depth = depth
				top_mat   = m
			var col := cx * CHUNK_SIZE + lc
			var row := cy * CHUNK_SIZE + lr
			var gi  := col * _face_res + row
			_top_depth_grid[gi] = top_depth
			_top_mat_grid[gi]   = top_mat


func _grid_depth(col: int, row: int) -> int:
	if col < 0 or col >= _face_res or row < 0 or row >= _face_res:
		return 0  # treat face boundary as ground level so walls close
	return _top_depth_grid[col * _face_res + row]


# Like _grid_depth but returns -1 for ocean/empty neighbours so coastline land
# blocks emit a side wall down to 1 voxel below sea level (ocean depth 0 is not
# solid, so a land block at depth 0 beside it needs a wall).
func _grid_solid_depth(col: int, row: int) -> int:
	if col < 0 or col >= _face_res or row < 0 or row >= _face_res:
		return 0  # face boundary = ground level
	var gi := col * _face_res + row
	var td := _top_depth_grid[gi]
	var tm := int(_top_mat_grid[gi])
	if td < 0 or tm == 2:
		return -1  # empty or ocean = no solid surface
	return td


# Single source of truth for what faces a column contributes to BOTH the render
# and collision meshes.  Reads the face-global depth/material grid so render and
# collision can never re-derive divergent skip logic or winding.
#   top_depth : outermost solid layer, -1 = empty column
#   top_mat   : top voxel material (0 = none)
#   emit_top  : emit a solid top quad — false for empty AND ocean (top_mat 2);
#               ocean tops are drawn by the separate transparent water mesh.
#   walls     : one entry per exposed side, [] for empty AND ocean columns
#               (Minecraft water is non-solid: no opaque wall, no collision).
#               Each: { dir: Vector2i, top_layer: int, base_layer: int }
func _column_faces(col: int, row: int) -> Dictionary:
	var gi        := col * _face_res + row
	var top_depth := _top_depth_grid[gi]
	var top_mat   := int(_top_mat_grid[gi])
	var solid     := top_depth >= 0 and top_mat != 2
	var walls := []
	if solid:
		for dir in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var nb_depth := _grid_solid_depth(col + dir.x, row + dir.y)
			if top_depth <= nb_depth:
				continue  # neighbour same height or higher — no exposed wall
			walls.append({
				"dir": dir,
				"top_layer": top_depth,
				"base_layer": max(nb_depth, 0) - 1,
			})
	return {
		"top_depth": top_depth,
		"top_mat": top_mat,
		"emit_top": solid,
		"walls": walls,
	}


# Remove the topmost (outermost) non-air voxel at the given column.
func remove_top_voxel(col: int, row: int) -> bool:
	var cx  := col / CHUNK_SIZE
	var cy  := row / CHUNK_SIZE
	var lc  := col % CHUNK_SIZE
	var lr  := row % CHUNK_SIZE
	var key := cx * chunks_per_edge + cy
	if not _chunk_data.has(key):
		return false
	var data: PackedByteArray = _chunk_data[key]

	var top := -1
	for depth in CHUNK_SIZE:
		if ChunkLoader.voxel(data, lc, lr, depth) == 0:
			break
		top = depth
	if top < 0:
		return false  # column already empty

	var idx := lc + CHUNK_SIZE * (lr + CHUNK_SIZE * top)
	data[idx] = 0
	_chunk_data[key] = data

	# Keep depth grid in sync so side-wall generation and collision stay correct.
	var new_top := top - 1
	var new_mat := 0
	if new_top >= 0:
		new_mat = ChunkLoader.voxel(data, lc, lr, new_top)
	var gi := col * _face_res + row
	_top_depth_grid[gi] = new_top
	_top_mat_grid[gi]   = new_mat

	_build_chunk_collision.call_deferred(cx, cy)
	_rebuild_chunk(cx, cy, key)
	for nb in [[cx - 1, cy], [cx + 1, cy], [cx, cy - 1], [cx, cy + 1]]:
		var nx: int = nb[0]
		var ny: int = nb[1]
		if nx < 0 or nx >= chunks_per_edge or ny < 0 or ny >= chunks_per_edge:
			continue
		if nx == cx and ny == cy:
			continue
		var nkey := nx * chunks_per_edge + ny
		if _chunk_data.has(nkey):
			_rebuild_chunk(nx, ny, nkey)
	return true


func _rebuild_chunk(cx: int, cy: int, key: int) -> void:
	var old_inst: MeshInstance3D = _chunk_insts.get(key) as MeshInstance3D
	if old_inst != null and is_instance_valid(old_inst):
		old_inst.visible = false
		old_inst.queue_free()
	var old_water: MeshInstance3D = _water_chunk_insts.get(key) as MeshInstance3D
	if old_water != null and is_instance_valid(old_water):
		old_water.visible = false
		old_water.queue_free()
	if not _chunk_data.has(key):
		return
	var chunk: PackedByteArray = _chunk_data[key] as PackedByteArray

	var st: SurfaceTool = SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_add_chunk_to_surface(st, chunk, cx, cy)
	st.generate_normals()
	var inst := MeshInstance3D.new()
	inst.mesh = st.commit()
	inst.material_override = _mat
	add_child(inst)
	_chunk_insts[key] = inst

	var st_w := SurfaceTool.new()
	st_w.begin(Mesh.PRIMITIVE_TRIANGLES)
	_add_ocean_tops_to_surface(st_w, chunk, cx, cy)
	st_w.generate_normals()
	var water_mesh := st_w.commit()
	if water_mesh != null and water_mesh.get_surface_count() > 0:
		var water_inst := MeshInstance3D.new()
		water_inst.mesh = water_mesh
		water_inst.material_override = _water_mat
		add_child(water_inst)
		_water_chunk_insts[key] = water_inst


func _add_ocean_tops_to_surface(st: SurfaceTool, data: PackedByteArray, cx: int, cy: int) -> void:
	var res        := float(CHUNK_SIZE * chunks_per_edge)
	var voxel_size := planet_radius / res

	for lc in CHUNK_SIZE:
		for lr in CHUNK_SIZE:
			var top_depth := -1
			var top_mat   := 0
			for depth in CHUNK_SIZE:
				var m := ChunkLoader.voxel(data, lc, lr, depth)
				if m == 0:
					break
				top_depth = depth
				top_mat   = m
			if top_depth < 0 or top_mat != 2:
				continue

			var col0 := cx * CHUNK_SIZE + lc
			var row0 := cy * CHUNK_SIZE + lr
			var r    := planet_radius + top_depth * voxel_size

			var color: Color = MAT_COLORS.get(2, Color.WHITE)
			var p00 := face_uv_to_unit(face_id,  col0      / res,  row0      / res) * r
			var p10 := face_uv_to_unit(face_id, (col0 + 1) / res,  row0      / res) * r
			var p01 := face_uv_to_unit(face_id,  col0      / res, (row0 + 1) / res) * r
			var p11 := face_uv_to_unit(face_id, (col0 + 1) / res, (row0 + 1) / res) * r

			st.set_color(color)
			if face_id == 2 or face_id == 3:
				st.set_uv(Vector2(0,0)); st.add_vertex(p00)
				st.set_uv(Vector2(1,1)); st.add_vertex(p11)
				st.set_uv(Vector2(1,0)); st.add_vertex(p10)
				st.set_uv(Vector2(0,0)); st.add_vertex(p00)
				st.set_uv(Vector2(0,1)); st.add_vertex(p01)
				st.set_uv(Vector2(1,1)); st.add_vertex(p11)
			else:
				st.set_uv(Vector2(0,0)); st.add_vertex(p00)
				st.set_uv(Vector2(1,0)); st.add_vertex(p10)
				st.set_uv(Vector2(1,1)); st.add_vertex(p11)
				st.set_uv(Vector2(0,0)); st.add_vertex(p00)
				st.set_uv(Vector2(1,1)); st.add_vertex(p11)
				st.set_uv(Vector2(0,1)); st.add_vertex(p01)


func _add_chunk_to_surface(st: SurfaceTool, data: PackedByteArray, cx: int, cy: int) -> void:
	var res        := float(CHUNK_SIZE * chunks_per_edge)
	var voxel_size := planet_radius / res   # world-unit height of one elevation layer
	var eps        := 0.5 / res

	for lc in CHUNK_SIZE:
		for lr in CHUNK_SIZE:
			var col0 := cx * CHUNK_SIZE + lc
			var row0 := cy * CHUNK_SIZE + lr
			var cf := _column_faces(col0, row0)
			if cf.top_depth < 0:
				continue

			var r: float = planet_radius + cf.top_depth * voxel_size  # radius of this column's top face
			var color: Color = MAT_COLORS.get(cf.top_mat, Color.WHITE)

			# Top face (ocean tops are drawn by the separate water mesh; empty
			# columns already skipped). Dot-product winding keeps normals outward
			# on every face without per-face special-casing.
			if cf.emit_top:
				var p00 := face_uv_to_unit(face_id,  col0      / res,  row0      / res) * r
				var p10 := face_uv_to_unit(face_id, (col0 + 1) / res,  row0      / res) * r
				var p01 := face_uv_to_unit(face_id,  col0      / res, (row0 + 1) / res) * r
				var p11 := face_uv_to_unit(face_id, (col0 + 1) / res, (row0 + 1) / res) * r
				var outward := (p00 + p10 + p01 + p11) * 0.25
				st.set_color(color)
				if (p10 - p00).cross(p11 - p00).dot(outward) > 0.0:
					st.set_uv(Vector2(0,0)); st.add_vertex(p00)
					st.set_uv(Vector2(1,0)); st.add_vertex(p10)
					st.set_uv(Vector2(1,1)); st.add_vertex(p11)
					st.set_uv(Vector2(0,0)); st.add_vertex(p00)
					st.set_uv(Vector2(1,1)); st.add_vertex(p11)
					st.set_uv(Vector2(0,1)); st.add_vertex(p01)
				else:
					st.set_uv(Vector2(0,0)); st.add_vertex(p00)
					st.set_uv(Vector2(1,1)); st.add_vertex(p11)
					st.set_uv(Vector2(1,0)); st.add_vertex(p10)
					st.set_uv(Vector2(0,0)); st.add_vertex(p00)
					st.set_uv(Vector2(0,1)); st.add_vertex(p01)
					st.set_uv(Vector2(1,1)); st.add_vertex(p11)

			# Side walls from _column_faces (none for ocean/empty columns).
			var side_color := Color(color.r * 0.65, color.g * 0.65, color.b * 0.65, color.a)
			for wall in cf.walls:
				var dir: Vector2i = wall.dir
				var r_base: float = planet_radius + wall.base_layer * voxel_size
				# Two UV points along the shared edge between this column and its neighbour.
				var u_a: float; var v_a: float; var u_b: float; var v_b: float
				if dir.x == 1:    # right neighbour — shared edge at col+1
					u_a = (col0 + 1) / res;  v_a = row0        / res
					u_b = (col0 + 1) / res;  v_b = (row0 + 1) / res
				elif dir.x == -1: # left neighbour — shared edge at col
					u_a = col0       / res;  v_a = (row0 + 1) / res
					u_b = col0       / res;  v_b = row0        / res
				elif dir.y == 1:  # forward neighbour — shared edge at row+1
					u_a = (col0 + 1) / res;  v_a = (row0 + 1) / res
					u_b = col0       / res;  v_b = (row0 + 1) / res
				else:              # backward neighbour — shared edge at row
					u_a = col0       / res;  v_a = row0        / res
					u_b = (col0 + 1) / res;  v_b = row0        / res
				var pa_base := face_uv_to_unit(face_id, u_a, v_a) * r_base
				var pb_base := face_uv_to_unit(face_id, u_b, v_b) * r_base
				var pa_top  := face_uv_to_unit(face_id, u_a, v_a) * r
				var pb_top  := face_uv_to_unit(face_id, u_b, v_b) * r

				var u_mid  := (u_a + u_b) * 0.5
				var v_mid  := (v_a + v_b) * 0.5
				var mid_pt := face_uv_to_unit(face_id, u_mid, v_mid)
				var out_pt := face_uv_to_unit(face_id, u_mid + dir.x * eps, v_mid + dir.y * eps)
				var expected_out := out_pt - mid_pt

				st.set_color(side_color)
				if (pa_top - pa_base).cross(pb_top - pa_base).dot(expected_out) > 0.0:
					st.set_uv(Vector2(0,0)); st.add_vertex(pa_base)
					st.set_uv(Vector2(0,1)); st.add_vertex(pa_top)
					st.set_uv(Vector2(1,1)); st.add_vertex(pb_top)
					st.set_uv(Vector2(0,0)); st.add_vertex(pa_base)
					st.set_uv(Vector2(1,1)); st.add_vertex(pb_top)
					st.set_uv(Vector2(1,0)); st.add_vertex(pb_base)
				else:
					st.set_uv(Vector2(0,0)); st.add_vertex(pa_base)
					st.set_uv(Vector2(1,1)); st.add_vertex(pb_top)
					st.set_uv(Vector2(0,1)); st.add_vertex(pa_top)
					st.set_uv(Vector2(0,0)); st.add_vertex(pa_base)
					st.set_uv(Vector2(1,0)); st.add_vertex(pb_base)
					st.set_uv(Vector2(1,1)); st.add_vertex(pb_top)


func set_water_visible(v: bool) -> void:
	for inst in _water_chunk_insts.values():
		(inst as MeshInstance3D).visible = v


func get_top_mat(col: int, row: int) -> int:
	if col < 0 or col >= _face_res or row < 0 or row >= _face_res:
		return 0
	return _top_mat_grid[col * _face_res + row]


static func face_uv_to_unit(face: int, u: float, v: float) -> Vector3:
	var s := u * 2.0 - 1.0
	var t := v * 2.0 - 1.0
	var raw: Vector3
	match face:
		0: raw = Vector3( 1.0,  s,    t)
		1: raw = Vector3(-1.0, -s,    t)
		2: raw = Vector3( s,    1.0,  t)
		3: raw = Vector3(-s,   -1.0,  t)
		4: raw = Vector3( s,    t,    1.0)
		5: raw = Vector3( s,   -t,   -1.0)
	raw = raw.normalized()
	# Z-up → Y-up as a proper rotation (-90° about X). Using a bare axis swap
	# (raw.x, raw.z, raw.y) is a reflection (det = -1) and mirrors the globe
	# east-west; negating the last component keeps it a rotation (det = +1).
	return Vector3(raw.x, raw.z, -raw.y)


# Inverse of face_uv_to_unit: given a unit sphere point, return [face, col, row].
static func unit_to_face_col_row(unit: Vector3, resolution: int) -> Array:
	var r: Vector3 = Vector3(unit.x, -unit.z, unit.y)  # undo Y-up → Z-up rotation
	var ax: float = absf(r.x)
	var ay: float = absf(r.y)
	var az: float = absf(r.z)
	var face: int = 0
	var s: float  = 0.0
	var t: float  = 0.0
	if ax >= ay and ax >= az:
		if r.x > 0.0:
			face = 0
			s =  r.y / r.x
			t =  r.z / r.x
		else:
			face = 1
			s =  r.y / r.x
			t = -r.z / r.x
	elif ay >= ax and ay >= az:
		if r.y > 0.0:
			face = 2
			s =  r.x / r.y
			t =  r.z / r.y
		else:
			face = 3
			s =  r.x / r.y
			t = -r.z / r.y
	else:
		if r.z > 0.0:
			face = 4
			s =  r.x / r.z
			t =  r.y / r.z
		else:
			face = 5
			s = -r.x / r.z
			t =  r.y / r.z
	var res_f: float = float(resolution)
	var col: int = int(clamp((s + 1.0) * 0.5 * res_f, 0.0, res_f - 1.0))
	var row: int = int(clamp((t + 1.0) * 0.5 * res_f, 0.0, res_f - 1.0))
	return [face, col, row]
