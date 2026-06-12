class_name CubeFace
extends StaticBody3D

# Renders the OUTER shell of the planet as a true per-voxel volume (TYPE B).
# Every solid voxel emits exactly the faces exposed to an open neighbour, so
# subsurface rock, dug pits, and horizontal tunnels all mesh correctly.
#
# Radius convention (OUTWARD growth — opposite of the inner shell):
#   The pipeline stacks land voxels outward from sea level: depth 0 sits at
#   planet_radius, and each deeper index is one voxel FARTHER OUT (elevation).
#   So a voxel at index `depth` occupies the radial band
#     [planet_radius + (depth - 1) * voxel_size , planet_radius + depth * voxel_size]
#   giving
#     top    (outward) face at r = planet_radius +  depth      * voxel_size
#     bottom (inward)  face at r = planet_radius + (depth - 1)  * voxel_size
#   The topmost solid voxel's top face lands at planet_radius + top_depth*voxel,
#   exactly where the old heightmap model drew it — so the surface is unchanged.
#
#   NOTE: this is intentionally NOT the inner shell's `planet_radius - (depth+1)`
#   formula. The two shells grow in opposite radial directions; using the inner
#   formula here would invert the terrain and sink it below the sphere.

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

var _chunk_data  := {}   # int key (cx*CPE + cy) → PackedByteArray (raw voxels)
var _mat: Material = null
var _water_mat: Material = null
var _chunk_insts := {}       # int key → MeshInstance3D
var _water_chunk_insts := {} # int key → MeshInstance3D

var _face_res       := 0
var _chunk_col_shapes := {}   # int key → CollisionShape3D, one per chunk


func _ready() -> void:
	_build_face()


func _build_face() -> void:
	_mat = ShaderMaterial.new()
	(_mat as ShaderMaterial).shader = load("res://shaders/voxel.gdshader") as Shader
	_water_mat = ShaderMaterial.new()
	(_water_mat as ShaderMaterial).shader = load("res://shaders/water.gdshader") as Shader

	_face_res = CHUNK_SIZE * chunks_per_edge

	print("CubeFace %d: building %d×%d chunks" % [face_id, chunks_per_edge, chunks_per_edge])

	# Pass 1: load all chunks. Raw bytes are kept so the per-voxel mesher can look
	# up neighbour occupancy across chunk boundaries (no derived grid needed).
	for cx in chunks_per_edge:
		for cy in chunks_per_edge:
			var data := ChunkLoader.load(face_id, cx, cy)
			if data.is_empty():
				continue
			_chunk_data[cx * chunks_per_edge + cy] = data

	# Pass 2: build per-chunk land + ocean meshes.
	for cx in chunks_per_edge:
		for cy in chunks_per_edge:
			var key := cx * chunks_per_edge + cy
			if _chunk_data.has(key):
				_rebuild_chunk(cx, cy, key)

	# Pass 3: per-chunk collision. Each 16×16 chunk gets its own CollisionShape3D
	# matching its rendered solid faces, so the solid you see is the solid you hit.
	# On a dig only the affected chunk (+ neighbours) is rebuilt, never all 65536.
	for cx in chunks_per_edge:
		for cy in chunks_per_edge:
			_build_chunk_collision(cx, cy)

	print("CubeFace %d: done" % face_id)


# True voxel occupancy test, used for 6-way face culling. A face is emitted only
# where a solid voxel borders an open one.
#   depth < 0              → solid (below the outer crust lies the inner shell,
#                            which provides the floor; don't open a face into it)
#   depth >= CHUNK_SIZE    → open (air above the surface)
#   water (mat 2)          → open (so the seafloor/coast faces show; the water
#                            body itself is drawn by the separate ocean mesh)
#   out-of-face-bounds     → solid (cross-face meshing not handled yet — Step 3)
#   unloaded neighbour     → solid (don't open a face into the unknown)
func _is_solid_at(cx: int, cy: int, data: PackedByteArray, lc: int, lr: int, depth: int) -> bool:
	if depth < 0:
		return true
	if depth >= CHUNK_SIZE:
		return false
	if lc >= 0 and lc < CHUNK_SIZE and lr >= 0 and lr < CHUNK_SIZE:
		var m := ChunkLoader.voxel(data, lc, lr, depth)
		return m != 0 and m != 2
	var col := cx * CHUNK_SIZE + lc
	var row := cy * CHUNK_SIZE + lr
	if col < 0 or col >= _face_res or row < 0 or row >= _face_res:
		return true
	var nkey := (col / CHUNK_SIZE) * chunks_per_edge + (row / CHUNK_SIZE)
	if not _chunk_data.has(nkey):
		return true
	var nm := ChunkLoader.voxel(_chunk_data[nkey], col % CHUNK_SIZE, row % CHUNK_SIZE, depth)
	return nm != 0 and nm != 2


# A radial (top/bottom) voxel face at radius r over one column cell. `outward`
# orients the normal toward the surface (top) or toward the centre (bottom).
func _emit_radial_face(st: SurfaceTool, u0: float, v0: float, u1: float, v1: float, r: float, color: Color, outward: bool) -> void:
	var p00 := face_uv_to_unit(face_id, u0, v0) * r
	var p10 := face_uv_to_unit(face_id, u1, v0) * r
	var p01 := face_uv_to_unit(face_id, u0, v1) * r
	var p11 := face_uv_to_unit(face_id, u1, v1) * r
	var normal := (p00 + p10 + p01 + p11) * 0.25
	if not outward:
		normal = -normal
	st.set_color(color)
	if (p10 - p00).cross(p11 - p00).dot(normal) > 0.0:
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


# A lateral voxel face toward `dir`, spanning r_in (inward side) to r_out (outward
# side). Dot-product winding points the normal into the open neighbour.
func _emit_side_face(st: SurfaceTool, col0: int, row0: int, dir: Vector2i, r_in: float, r_out: float, res: float, eps: float, color: Color) -> void:
	var u_a: float; var v_a: float; var u_b: float; var v_b: float
	if dir.x == 1:
		u_a = (col0 + 1) / res;  v_a = row0        / res
		u_b = (col0 + 1) / res;  v_b = (row0 + 1)  / res
	elif dir.x == -1:
		u_a = col0       / res;  v_a = (row0 + 1)  / res
		u_b = col0       / res;  v_b = row0         / res
	elif dir.y == 1:
		u_a = (col0 + 1) / res;  v_a = (row0 + 1)  / res
		u_b = col0       / res;  v_b = (row0 + 1)  / res
	else:
		u_a = col0       / res;  v_a = row0         / res
		u_b = (col0 + 1) / res;  v_b = row0         / res

	var pa_top  := face_uv_to_unit(face_id, u_a, v_a) * r_out
	var pb_top  := face_uv_to_unit(face_id, u_b, v_b) * r_out
	var pa_base := face_uv_to_unit(face_id, u_a, v_a) * r_in
	var pb_base := face_uv_to_unit(face_id, u_b, v_b) * r_in

	var u_mid  := (u_a + u_b) * 0.5
	var v_mid  := (v_a + v_b) * 0.5
	var mid_pt := face_uv_to_unit(face_id, u_mid, v_mid)
	var out_pt := face_uv_to_unit(face_id, u_mid + dir.x * eps, v_mid + dir.y * eps)
	var expected_out := out_pt - mid_pt

	st.set_color(color)
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


# True per-voxel mesher: every solid voxel emits exactly the faces exposed to an
# open neighbour (air / water / cross the inner shell), in all 6 directions. This
# is what makes the outer crust a real volume — dug holes show their surroundings
# and horizontal tunnels mesh. Consumed by BOTH render and collision so they
# never diverge. Ocean (mat 2) is skipped here; ocean tops are a separate water
# mesh, and _is_solid_at treats water as open so coast faces still show.
func _add_chunk_to_surface(st: SurfaceTool, data: PackedByteArray, cx: int, cy: int) -> void:
	var res        := float(_face_res)
	var voxel_size := planet_radius / res
	var eps        := 0.5 / res

	for lc in CHUNK_SIZE:
		for lr in CHUNK_SIZE:
			var col0 := cx * CHUNK_SIZE + lc
			var row0 := cy * CHUNK_SIZE + lr
			var u0 := col0 / res
			var u1 := (col0 + 1) / res
			var v0 := row0 / res
			var v1 := (row0 + 1) / res
			for depth in CHUNK_SIZE:
				var m := ChunkLoader.voxel(data, lc, lr, depth)
				if m == 0 or m == 2:
					continue

				var color: Color = MAT_COLORS.get(m, Color.WHITE)
				var r_out := planet_radius + float(depth) * voxel_size          # outward (top)
				var r_in  := planet_radius + (float(depth) - 1.0) * voxel_size  # inward (bottom)

				# Outward (top) face — exposed if the voxel just outward is open.
				if not _is_solid_at(cx, cy, data, lc, lr, depth + 1):
					_emit_radial_face(st, u0, v0, u1, v1, r_out, color, true)

				# Inward (bottom) face — exposed if the voxel just inward is open
				# (an excavated pocket). depth 0's inward neighbour is the inner
				# shell, treated as solid, so flat ground emits no buried floor.
				if not _is_solid_at(cx, cy, data, lc, lr, depth - 1):
					var under := Color(color.r * 0.5, color.g * 0.5, color.b * 0.5, color.a)
					_emit_radial_face(st, u0, v0, u1, v1, r_in, under, false)

				# Four lateral faces — exposed where the side neighbour is open.
				for dir in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					if not _is_solid_at(cx, cy, data, lc + dir.x, lr + dir.y, depth):
						var side_color := Color(color.r * 0.65, color.g * 0.65, color.b * 0.65, color.a)
						_emit_side_face(st, col0, row0, dir, r_in, r_out, res, eps, side_color)


# Collision uses the exact same voxel faces as the render mesh (create_trimesh_shape
# ignores colour/uv), so the solid you see is the solid you hit.
func _build_chunk_collision_mesh(cx: int, cy: int) -> ArrayMesh:
	var key := cx * chunks_per_edge + cy
	if not _chunk_data.has(key):
		return null
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_add_chunk_to_surface(st, _chunk_data[key], cx, cy)
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


# Ocean tops: one transparent quad per surface water voxel. Water is non-solid,
# so it is drawn here (not in the opaque per-voxel mesh) and has no collision.
func _add_ocean_tops_to_surface(st: SurfaceTool, data: PackedByteArray, cx: int, cy: int) -> void:
	var res        := float(_face_res)
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


func set_water_visible(v: bool) -> void:
	for inst in _water_chunk_insts.values():
		(inst as MeshInstance3D).visible = v


# Material of the outermost solid voxel in a column (0 if the column is empty).
# Scans inward from the top so the surface material is reported even with caves.
func get_top_mat(col: int, row: int) -> int:
	if col < 0 or col >= _face_res or row < 0 or row >= _face_res:
		return 0
	var cx  := col / CHUNK_SIZE
	var cy  := row / CHUNK_SIZE
	var key := cx * chunks_per_edge + cy
	if not _chunk_data.has(key):
		return 0
	var data: PackedByteArray = _chunk_data[key]
	var lc := col % CHUNK_SIZE
	var lr := row % CHUNK_SIZE
	for depth in range(CHUNK_SIZE - 1, -1, -1):
		var m := ChunkLoader.voxel(data, lc, lr, depth)
		if m != 0:
			return m
	return 0


# Remove the outermost (highest-depth) non-air voxel of a column — the surface
# the player is standing on. Returns false when the column is already empty, so
# the caller can chain the dig into the inner shell.
func remove_top_voxel(col: int, row: int) -> bool:
	var cx  := col / CHUNK_SIZE
	var cy  := row / CHUNK_SIZE
	var lc  := col % CHUNK_SIZE
	var lr  := row % CHUNK_SIZE
	var key := cx * chunks_per_edge + cy
	if not _chunk_data.has(key):
		return false
	var data: PackedByteArray = _chunk_data[key]

	# Scan inward from the top for the first (outermost) solid voxel.
	var top := -1
	for depth in range(CHUNK_SIZE - 1, -1, -1):
		if ChunkLoader.voxel(data, lc, lr, depth) != 0:
			top = depth
			break
	if top < 0:
		return false  # column already empty

	var idx := lc + CHUNK_SIZE * (lr + CHUNK_SIZE * top)
	data[idx] = 0
	_chunk_data[key] = data

	# Per-voxel mesher reads occupancy directly, so there is no grid to update;
	# just rebuild this chunk's mesh + collision and refresh the four neighbours
	# (removing a voxel can expose their previously-hidden side faces).
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
