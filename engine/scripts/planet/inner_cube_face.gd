class_name InnerCubeFace
extends StaticBody3D

# Renders the inner shell of the planet — solid rock under land, and ocean
# columns (water body + seafloor) under ocean tiles.  Depth 0 is just below
# the planet surface; depth 15 is 16 voxels deep toward the hollow centre.
#
# Radius formula (inward from surface):
#   r(depth) = planet_radius - (depth + 1) * voxel_size

const _CubeFaceScript = preload("res://scripts/planet/cube_face.gd")
const CHUNK_SIZE := 16

var planet_radius: float = 256.0
var face_id: int = 0
var chunks_per_edge: int = 16

const MAT_COLORS := {
	1:  Color(0.25, 0.55, 0.20),  # Land fallback
	2:  Color(0.10, 0.35, 0.65),  # Ocean / water body
	3:  Color(0.85, 0.75, 0.45),  # Desert/Sand
	4:  Color(0.40, 0.65, 0.25),  # Temperate
	5:  Color(0.15, 0.40, 0.15),  # Forest
	6:  Color(0.90, 0.93, 0.97),  # Snow/Ice
	7:  Color(0.10, 0.48, 0.12),  # Tropical
	8:  Color(0.68, 0.62, 0.22),  # Savanna
	9:  Color(0.52, 0.48, 0.44),  # Rock/Mountain
	10: Color(0.28, 0.22, 0.16),  # Seafloor
	11: Color(0.10, 0.35, 0.65),  # Ocean ceiling (solid stand-in for mat 2 at depth 15)
}

var _mat: Material = null
var _water_mat: Material = null
var _chunk_insts := {}
var _water_chunk_insts := {}

var _chunk_data := {}
var _face_res := 0
var _top_depth_grid := PackedInt32Array()
var _top_mat_grid   := PackedByteArray()
var _chunk_col_shapes := {}   # int key → CollisionShape3D, one per chunk
var _opened_columns   := {}   # gi key → true for columns with outer shell fully dug


func _ready() -> void:
	_build_face()


func _build_face() -> void:
	_mat = ShaderMaterial.new()
	(_mat as ShaderMaterial).shader = load("res://shaders/inner_voxel.gdshader") as Shader
	_water_mat = ShaderMaterial.new()
	(_water_mat as ShaderMaterial).shader = load("res://shaders/water.gdshader") as Shader

	_face_res = CHUNK_SIZE * chunks_per_edge
	_top_depth_grid.resize(_face_res * _face_res)
	_top_depth_grid.fill(0)
	_top_mat_grid.resize(_face_res * _face_res)
	_top_mat_grid.fill(9)  # default rock

	print("InnerCubeFace %d: building %d×%d chunks" % [face_id, chunks_per_edge, chunks_per_edge])

	for cx in chunks_per_edge:
		for cy in chunks_per_edge:
			var data := ChunkLoader.load_inner(face_id, cx, cy)
			if data.is_empty():
				continue
			_chunk_data[cx * chunks_per_edge + cy] = data
			_populate_grid_from_chunk(data, cx, cy)

	for cx in chunks_per_edge:
		for cy in chunks_per_edge:
			var key := cx * chunks_per_edge + cy
			if _chunk_data.has(key):
				_rebuild_chunk(cx, cy, key)

	for cx in chunks_per_edge:
		for cy in chunks_per_edge:
			_build_chunk_collision(cx, cy)

	# Deferred so it runs after every sibling face has finished _ready() (faces
	# build sequentially): re-mesh the edge chunks now that cross-face neighbour
	# data is loaded. Without this, faces built early cull seam walls toward
	# not-yet-loaded faces, leaving invisible side walls until a nearby dig.
	_rebuild_seam_edges.call_deferred()

	print("InnerCubeFace %d: done" % face_id)


# Re-mesh the chunks along all four face edges (run once, deferred, at load).
func _rebuild_seam_edges() -> void:
	var last := chunks_per_edge - 1
	var seen := {}
	for i in chunks_per_edge:
		for c in [[0, i], [last, i], [i, 0], [i, last]]:
			var cx: int = c[0];  var cy: int = c[1]
			var key: int = cx * chunks_per_edge + cy
			if seen.has(key) or not _chunk_data.has(key):
				continue
			seen[key] = true
			_rebuild_chunk(cx, cy, key)
			_build_chunk_collision.call_deferred(cx, cy)


# Finds the outermost solid non-water voxel in each column.
# For land (all rock): depth 0 → r = planet_radius - 1.
# For ocean (N water layers then seafloor): depth N → r = planet_radius - (N+1).
func _populate_grid_from_chunk(data: PackedByteArray, cx: int, cy: int) -> void:
	for lc in CHUNK_SIZE:
		for lr in CHUNK_SIZE:
			var floor_depth := CHUNK_SIZE - 1
			var floor_mat   := 9
			for depth in CHUNK_SIZE:
				var m := ChunkLoader.voxel(data, lc, lr, depth)
				if m != 0 and m != 2:  # first non-air, non-water = seafloor or rock
					floor_depth = depth
					floor_mat   = m
					break
			var col := cx * CHUNK_SIZE + lc
			var row := cy * CHUNK_SIZE + lr
			var gi  := col * _face_res + row
			_top_depth_grid[gi] = floor_depth
			_top_mat_grid[gi]   = floor_mat


# True voxel occupancy test, used for 6-way face culling.  A face is emitted
# only where a solid voxel borders an open one.
#   depth outside [0, CHUNK_SIZE)  → open (surface side / cavity side)
#   water (mat 2)                  → open (so seafloor/rock faces show; the water
#                                    body itself is drawn by the ocean surface)
#   out-of-face-bounds             → solid (cross-face meshing not handled yet)
#   unloaded neighbour chunk       → solid (don't open a face into the unknown)
func _is_solid_at(cx: int, cy: int, data: PackedByteArray, lc: int, lr: int, depth: int) -> bool:
	if depth < 0 or depth >= CHUNK_SIZE:
		return false
	if lc >= 0 and lc < CHUNK_SIZE and lr >= 0 and lr < CHUNK_SIZE:
		var m := ChunkLoader.voxel(data, lc, lr, depth)
		return m != 0 and m != 2
	var col := cx * CHUNK_SIZE + lc
	var row := cy * CHUNK_SIZE + lr
	if col >= 0 and col < _face_res and row >= 0 and row < _face_res:
		var nkey := (col / CHUNK_SIZE) * chunks_per_edge + (row / CHUNK_SIZE)
		if not _chunk_data.has(nkey):
			return true
		var nm := ChunkLoader.voxel(_chunk_data[nkey], col % CHUNK_SIZE, row % CHUNK_SIZE, depth)
		return nm != 0 and nm != 2
	# Cross-face lookup via sphere re-projection (same pattern as CubeFace).
	# Culling the seam face when the neighbour is solid keeps flat seams clean;
	# emitting it when the neighbour is air fixes see-through holes. The `return
	# true` fallbacks bias toward the clean culled look when the neighbour can't
	# be resolved. Sample the cell CENTRE (+0.5), not the ambiguous corner.
	var u    := (float(col) + 0.5) / float(_face_res)
	var v    := (float(row) + 0.5) / float(_face_res)
	var unit := _CubeFaceScript.face_uv_to_unit(face_id, u, v)
	var r    := _CubeFaceScript.unit_to_face_col_row(unit, _face_res)
	var nface := int(r[0])
	if nface == face_id:
		# Degenerate: boundary pixel projected back to same face. Nudge inward.
		var eps: float = 0.5 / float(_face_res)
		var u2: float = clamp(u, eps, 1.0 - eps)
		var v2: float = clamp(v, eps, 1.0 - eps)
		unit = _CubeFaceScript.face_uv_to_unit(face_id, u2, v2)
		r = _CubeFaceScript.unit_to_face_col_row(unit, _face_res)
		nface = int(r[0])
		if nface == face_id:
			return true  # cube corner — treat as solid (clean culled seam)
	var nb := get_parent().get_node_or_null("InnerCubeFace_%d" % nface) as InnerCubeFace
	if nb == null or not is_instance_valid(nb):
		return true
	var ncol := int(r[1]);  var nrow := int(r[2])
	var ncx  := ncol / CHUNK_SIZE;  var ncy := nrow / CHUNK_SIZE
	var nkey := ncx * chunks_per_edge + ncy
	if not nb._chunk_data.has(nkey):
		return true
	var nm := ChunkLoader.voxel(nb._chunk_data[nkey], ncol % CHUNK_SIZE, nrow % CHUNK_SIZE, depth)
	return nm != 0 and nm != 2


# A radial (top/bottom) voxel face at radius r over one column cell. `outward`
# orients the normal toward the surface (top) or toward the cavity (bottom).
func _emit_radial_face(st: SurfaceTool, u0: float, v0: float, u1: float, v1: float, r: float, color: Color, outward: bool) -> void:
	var p00 := _CubeFaceScript.face_uv_to_unit(face_id, u0, v0) * r
	var p10 := _CubeFaceScript.face_uv_to_unit(face_id, u1, v0) * r
	var p01 := _CubeFaceScript.face_uv_to_unit(face_id, u0, v1) * r
	var p11 := _CubeFaceScript.face_uv_to_unit(face_id, u1, v1) * r
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


# A lateral voxel face toward `dir`, spanning r_in (cavity side) to r_out
# (surface side).  Dot-product winding points the normal into the open neighbour.
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

	var pa_top  := _CubeFaceScript.face_uv_to_unit(face_id, u_a, v_a) * r_out
	var pb_top  := _CubeFaceScript.face_uv_to_unit(face_id, u_b, v_b) * r_out
	var pa_base := _CubeFaceScript.face_uv_to_unit(face_id, u_a, v_a) * r_in
	var pb_base := _CubeFaceScript.face_uv_to_unit(face_id, u_b, v_b) * r_in

	var u_mid  := (u_a + u_b) * 0.5
	var v_mid  := (v_a + v_b) * 0.5
	var mid_pt := _CubeFaceScript.face_uv_to_unit(face_id, u_mid, v_mid)
	var out_pt := _CubeFaceScript.face_uv_to_unit(face_id, u_mid + dir.x * eps, v_mid + dir.y * eps)
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
# open neighbour (air / water / cavity), in all 6 directions.  This is what makes
# the sub-surface a real volume — every block below ground is represented, dug
# holes show their full surroundings, and horizontal tunnels mesh correctly.
# Consumed by BOTH render (_rebuild_chunk) and collision (_build_chunk_collision_mesh).
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
				if m == 0:
					continue
				if m == 2 and depth < CHUNK_SIZE - 1:
					continue  # water body — skip mid-column; seafloor and mat-11 ceiling render normally

				var color: Color = MAT_COLORS.get(m, Color(0.4, 0.35, 0.3))
				var r_out := planet_radius - (float(depth) + 1.0) * voxel_size  # toward surface
				var r_in  := planet_radius - (float(depth) + 2.0) * voxel_size  # toward cavity

				# Outward (top) face — exposed if the voxel just outward is open.
				if not _is_solid_at(cx, cy, data, lc, lr, depth - 1):
					_emit_radial_face(st, u0, v0, u1, v1, r_out, color, true)

				# Inward (bottom) face — exposed if the voxel just inward is open
				# (the cavity beneath the deepest rock, or an excavated pocket).
				if not _is_solid_at(cx, cy, data, lc, lr, depth + 1):
					var under := Color(color.r * 0.5, color.g * 0.5, color.b * 0.5, color.a)
					_emit_radial_face(st, u0, v0, u1, v1, r_in, under, false)

				# Four lateral faces — exposed where the side neighbour is open.
				for dir in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					if not _is_solid_at(cx, cy, data, lc + dir.x, lr + dir.y, depth):
						var side_color := Color(color.r * 0.65, color.g * 0.65, color.b * 0.65, color.a)
						_emit_side_face(st, col0, row0, dir, r_in, r_out, res, eps, side_color)



# Emits a single translucent outward face per ocean column (the topmost water
# voxel only), plus side faces toward explicit air gaps from digging.
#
# One-face-per-column gives a continuous smooth ocean surface with no visible
# grid lines at shallow/deep boundaries.  Stacking one face per depth layer
# makes depth-transition edges visible through the translucent outer-shell
# surface, creating a blocky grid appearance.
#
# Side faces use an explicit air (mat 0) check to skip water→water walls, which
# would draw a grid line at every adjacent-column boundary.
func _add_water_to_surface(st_w: SurfaceTool, data: PackedByteArray, cx: int, cy: int) -> void:
	var res        := float(_face_res)
	var voxel_size := planet_radius / res
	var eps        := 0.5 / res
	var color: Color = MAT_COLORS.get(2, Color(0.10, 0.35, 0.65))

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
				if m != 2:
					continue
				var r_out := planet_radius - (float(depth) + 1.0) * voxel_size
				var r_in  := planet_radius - (float(depth) + 2.0) * voxel_size

				# Top face: only when the voxel immediately outward (depth-1) is air.
				# depth > 0 guard prevents stacking with the outer shell's sea surface.
				# This makes the water surface visible when looking down into a dug
				# shaft that has been flooded from the side.
				if depth > 0 and mat_at(col0, row0, depth - 1) == 0:
					_emit_radial_face(st_w, u0, v0, u1, v1, r_out, color, true)

				# Side faces — toward air only. Suppress at face-boundary edges
				# (nc/nr out of [0, _face_res)) to avoid mirrored double-walls at
				# cube-face seams; the adjacent face renders its own water correctly.
				for dir in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					var nc: int = col0 + dir.x
					var nr: int = row0 + dir.y
					if nc < 0 or nc >= _face_res or nr < 0 or nr >= _face_res:
						continue
					if mat_at(nc, nr, depth) == 0:
						_emit_side_face(st_w, col0, row0, dir, r_in, r_out, res, eps, color)


func _build_chunk_collision_mesh(cx: int, cy: int) -> ArrayMesh:
	# Collision uses the exact same voxel faces as the render mesh, so the solid
	# you see is the solid you hit (create_trimesh_shape ignores the colour/uv).
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


# Raw material byte of the voxel at (col, row, depth); 0 for air, out-of-range,
# or an unloaded chunk. Used for point-in-voxel queries (e.g. the underwater
# overlay) so callers can ask "what material is at this exact 3D point?".
func mat_at(col: int, row: int, depth: int) -> int:
	if col < 0 or col >= _face_res or row < 0 or row >= _face_res:
		return 0
	if depth < 0 or depth >= CHUNK_SIZE:
		return 0
	var cx  := col / CHUNK_SIZE
	var cy  := row / CHUNK_SIZE
	var key := cx * chunks_per_edge + cy
	if not _chunk_data.has(key):
		return 0
	return ChunkLoader.voxel(_chunk_data[key], col % CHUNK_SIZE, row % CHUNK_SIZE, depth)


# If any of the 6 face-neighbors of (col, row, depth) is water (mat-2),
# write mat-2 into that voxel and return true. Called right after zeroing a
# dug voxel so the hole immediately fills when adjacent to the ocean.
# BFS flood fill starting from (start_col, start_row, start_depth), which was
# just zeroed. Every connected air voxel that touches a water (mat-2) neighbor
# gets filled with water — same semantics as Minecraft/Luanti source blocks.
# Returns a Dictionary of chunk key → [cx, cy] for every chunk that was written.
func _flood_fill_water_from(start_col: int, start_row: int, start_depth: int) -> Dictionary:
	print("_flood_fill_water_from called at (%d,%d,%d)" % [start_col, start_row, start_depth])
	const MAX_FILL := 512  # voxel cap to keep single-dig cost bounded
	var queue := [[start_col, start_row, start_depth]]
	var seen  := {}
	# Track voxels filled by THIS BFS run so has_water can see them immediately,
	# bypassing any PackedByteArray COW lag on _chunk_data dictionary reads.
	var filled := {}  # gk → true for voxels filled with water this run
	var dirty := {}   # chunk key → [cx, cy]
	var count := 0

	while queue.size() > 0 and count < MAX_FILL:
		var v: Array = queue.pop_front()
		var c: int = v[0];  var r: int = v[1];  var d: int = v[2]
		if d < 0 or d >= CHUNK_SIZE: continue
		if c < 0 or c >= _face_res or r < 0 or r >= _face_res: continue
		var gk: int = (c * _face_res + r) * CHUNK_SIZE + d
		if seen.has(gk): continue
		seen[gk] = true
		if mat_at(c, r, d) != 0: continue  # not air — skip

		# A neighbor counts as water if it holds mat-2 in chunk data OR was
		# filled with water earlier in this BFS run (the filled set avoids
		# relying on _chunk_data read-back for voxels written this iteration).
		var has_water: bool = \
			mat_at(c + 1, r,     d    ) == 2 or filled.has(((c+1) * _face_res + r)     * CHUNK_SIZE + d) or \
			mat_at(c - 1, r,     d    ) == 2 or filled.has(((c-1) * _face_res + r)     * CHUNK_SIZE + d) or \
			mat_at(c,     r + 1, d    ) == 2 or filled.has((c * _face_res + (r+1))     * CHUNK_SIZE + d) or \
			mat_at(c,     r - 1, d    ) == 2 or filled.has((c * _face_res + (r-1))     * CHUNK_SIZE + d) or \
			mat_at(c,     r,     d - 1) == 2 or filled.has((c * _face_res + r) * CHUNK_SIZE + (d-1))     or \
			mat_at(c,     r,     d + 1) == 2 or filled.has((c * _face_res + r) * CHUNK_SIZE + (d+1))
		if not has_water: continue

		var cx: int = c / CHUNK_SIZE;  var cy: int = r / CHUNK_SIZE
		var lc: int = c % CHUNK_SIZE;  var lr: int = r % CHUNK_SIZE
		var key: int = cx * chunks_per_edge + cy
		if not _chunk_data.has(key): continue
		var data: PackedByteArray = _chunk_data[key]
		data[lc + CHUNK_SIZE * (lr + CHUNK_SIZE * d)] = 2
		_chunk_data[key] = data
		filled[gk] = true
		dirty[key] = [cx, cy]
		count += 1

		queue.push_back([c + 1, r, d]);  queue.push_back([c - 1, r, d])
		queue.push_back([c, r + 1, d]);  queue.push_back([c, r - 1, d])
		queue.push_back([c, r, d - 1]);  queue.push_back([c, r, d + 1])

	print("_flood_fill_water_from done, filled %d voxels" % count)
	return dirty


# After a dig at a face-edge cell, the ADJACENT cube face's seam voxels may now
# border new air and need their walls re-meshed — otherwise digging at a seam
# leaves see-through holes. Re-project each out-of-face neighbour to its owning
# face and rebuild that face's affected chunk + collision.
func _rebuild_seam_neighbors(col: int, row: int) -> void:
	for dir in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var ncol: int = col + dir.x
		var nrow: int = row + dir.y
		if ncol >= 0 and ncol < _face_res and nrow >= 0 and nrow < _face_res:
			continue  # same face — already covered by the in-face neighbour rebuild
		var u := (float(ncol) + 0.5) / float(_face_res)
		var v := (float(nrow) + 0.5) / float(_face_res)
		var unit := _CubeFaceScript.face_uv_to_unit(face_id, u, v)
		var r := _CubeFaceScript.unit_to_face_col_row(unit, _face_res)
		var nface := int(r[0])
		if nface == face_id:
			continue
		var nb := get_parent().get_node_or_null("InnerCubeFace_%d" % nface) as InnerCubeFace
		if nb == null or not is_instance_valid(nb):
			continue
		var nc: int = int(r[1]);  var nr: int = int(r[2])
		var ncx: int = nc / CHUNK_SIZE;  var ncy: int = nr / CHUNK_SIZE
		var nkey: int = ncx * nb.chunks_per_edge + ncy
		if nb._chunk_data.has(nkey):
			nb._rebuild_chunk(ncx, ncy, nkey)
			nb._build_chunk_collision.call_deferred(ncx, ncy)


# Remove a specific voxel by column + depth. Opens the column if it becomes
# fully empty (chains to open_column so the cavity passage is created).
func remove_voxel(col: int, row: int, depth: int) -> bool:
	var cx  := col / CHUNK_SIZE
	var cy  := row / CHUNK_SIZE
	var lc  := col % CHUNK_SIZE
	var lr  := row % CHUNK_SIZE
	var key := cx * chunks_per_edge + cy
	if not _chunk_data.has(key):
		return false
	var data: PackedByteArray = _chunk_data[key]
	if ChunkLoader.voxel(data, lc, lr, depth) == 0:
		return false
	data[lc + CHUNK_SIZE * (lr + CHUNK_SIZE * depth)] = 0
	_chunk_data[key] = data
	var dirty := _flood_fill_water_from(col, row, depth)
	data = _chunk_data[key]
	# Check if column is now fully empty — if so, open the cavity passage.
	var has_solid := false
	for d in CHUNK_SIZE:
		var m := ChunkLoader.voxel(data, lc, lr, d)
		if m != 0 and m != 2:
			has_solid = true
			break
	if not has_solid:
		open_column(col, row)
		return true
	_build_chunk_collision.call_deferred(cx, cy)
	var rebuilt := {}
	_rebuild_chunk(cx, cy, key);  rebuilt[key] = true
	for nb in [[cx - 1, cy], [cx + 1, cy], [cx, cy - 1], [cx, cy + 1]]:
		var nx: int = nb[0];  var ny: int = nb[1]
		if nx < 0 or nx >= chunks_per_edge or ny < 0 or ny >= chunks_per_edge:
			continue
		var nkey := nx * chunks_per_edge + ny
		if _chunk_data.has(nkey) and not rebuilt.has(nkey):
			rebuilt[nkey] = true
			_rebuild_chunk(nx, ny, nkey)
	for entry in dirty.values():
		var dx: int = (entry as Array)[0];  var dy: int = (entry as Array)[1]
		var dkey: int = dx * chunks_per_edge + dy
		if not rebuilt.has(dkey) and _chunk_data.has(dkey):
			rebuilt[dkey] = true
			_rebuild_chunk(dx, dy, dkey)
	_rebuild_seam_neighbors(col, row)
	return true


func open_column(col: int, row: int) -> void:
	var cx := col / CHUNK_SIZE
	var cy := row / CHUNK_SIZE
	_opened_columns[col * _face_res + row] = true
	_build_chunk_collision.call_deferred(cx, cy)
	_rebuild_chunk(cx, cy, cx * chunks_per_edge + cy)
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
	_rebuild_seam_neighbors(col, row)


func get_top_mat(col: int, row: int) -> int:
	if col < 0 or col >= _face_res or row < 0 or row >= _face_res:
		return 0
	return _top_mat_grid[col * _face_res + row]


func remove_top_voxel(col: int, row: int) -> bool:
	var cx  := col / CHUNK_SIZE
	var cy  := row / CHUNK_SIZE
	var lc  := col % CHUNK_SIZE
	var lr  := row % CHUNK_SIZE
	var key := cx * chunks_per_edge + cy
	if not _chunk_data.has(key):
		return false
	var data: PackedByteArray = _chunk_data[key]

	# Find the current floor voxel (first non-water solid from depth 0).
	var floor_d := -1
	for depth in CHUNK_SIZE:
		var m := ChunkLoader.voxel(data, lc, lr, depth)
		if m != 0 and m != 2:
			floor_d = depth
			break
	if floor_d < 0:
		return false

	var idx := lc + CHUNK_SIZE * (lr + CHUNK_SIZE * floor_d)
	data[idx] = 0  # erase the floor voxel (expose rock below)
	_chunk_data[key] = data
	var dirty := _flood_fill_water_from(col, row, floor_d)
	data = _chunk_data[key]

	# Update grid: new floor is the next non-water solid below.
	var new_floor := floor_d
	var new_mat   := 9
	for depth in range(floor_d + 1, CHUNK_SIZE):
		var m := ChunkLoader.voxel(data, lc, lr, depth)
		if m != 0 and m != 2:
			new_floor = depth
			new_mat   = m
			break
	if new_floor == floor_d:
		# No deeper solid — inner column fully dug; open passage to cavity.
		open_column(col, row)
		return true

	var gi := col * _face_res + row
	_top_depth_grid[gi] = new_floor
	_top_mat_grid[gi]   = new_mat

	_build_chunk_collision.call_deferred(cx, cy)
	var rebuilt := {}
	_rebuild_chunk(cx, cy, key);  rebuilt[key] = true
	for nb in [[cx - 1, cy], [cx + 1, cy], [cx, cy - 1], [cx, cy + 1]]:
		var nx: int = nb[0];  var ny: int = nb[1]
		if nx < 0 or nx >= chunks_per_edge or ny < 0 or ny >= chunks_per_edge:
			continue
		var nkey := nx * chunks_per_edge + ny
		if _chunk_data.has(nkey) and not rebuilt.has(nkey):
			rebuilt[nkey] = true
			_rebuild_chunk(nx, ny, nkey)
	for entry in dirty.values():
		var dx: int = (entry as Array)[0];  var dy: int = (entry as Array)[1]
		var dkey: int = dx * chunks_per_edge + dy
		if not rebuilt.has(dkey) and _chunk_data.has(dkey):
			rebuilt[dkey] = true
			_rebuild_chunk(dx, dy, dkey)
	_rebuild_seam_neighbors(col, row)
	return true


func _rebuild_chunk(cx: int, cy: int, key: int) -> void:
	var old: MeshInstance3D = _chunk_insts.get(key) as MeshInstance3D
	if old != null and is_instance_valid(old):
		old.visible = false
		old.queue_free()
	var old_water: MeshInstance3D = _water_chunk_insts.get(key) as MeshInstance3D
	if old_water != null and is_instance_valid(old_water):
		old_water.visible = false
		old_water.queue_free()
	if not _chunk_data.has(key):
		return
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_add_chunk_to_surface(st, _chunk_data[key], cx, cy)
	st.generate_normals()
	var inst := MeshInstance3D.new()
	inst.mesh = st.commit()
	inst.material_override = _mat
	add_child(inst)
	_chunk_insts[key] = inst

	var st_w := SurfaceTool.new()
	st_w.begin(Mesh.PRIMITIVE_TRIANGLES)
	_add_water_to_surface(st_w, _chunk_data[key], cx, cy)
	st_w.generate_normals()
	var water_mesh := st_w.commit()
	if water_mesh != null and water_mesh.get_surface_count() > 0:
		var water_inst := MeshInstance3D.new()
		water_inst.mesh = water_mesh
		water_inst.material_override = _water_mat
		add_child(water_inst)
		_water_chunk_insts[key] = water_inst
