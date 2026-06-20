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

# Inner-shell palette — deliberately MUTED vs the outer surface (cube_face.gd):
# pulled toward grey and a touch darker so the cavity reads as a dim, subterranean
# under-world rather than a second bright Earth. The blue is a desaturated slate
# (less vivid than the outer ocean), and the ocean CEILING (mat 11) is darker still
# so the projected starfield reads against it (see inner_voxel.gdshader).
const MAT_COLORS := {
	1: Color(0.17, 0.25, 0.15),  # Land fallback
	2: Color(0.10, 0.18, 0.27),  # Ocean / water body (muted slate — water mesh uses its own shader)
	3: Color(0.40, 0.37, 0.27),  # Desert/Sand
	4: Color(0.21, 0.30, 0.17),  # Temperate
	5: Color(0.13, 0.21, 0.13),  # Forest
	6: Color(0.40, 0.44, 0.49),  # Snow/Ice (muted grey-blue — no white tint on the ceiling)
	7: Color(0.12, 0.25, 0.14),  # Tropical
	8: Color(0.33, 0.31, 0.20),  # Savanna
	9: Color(0.25, 0.24, 0.22),  # Rock/Mountain
	10: Color(0.16, 0.14, 0.12),  # Seafloor
	11: Color(0.04, 0.08, 0.15),  # Ocean ceiling (dark slate — starfield backdrop)
}

var _mat: Material = null
var _water_mat: Material = null
var _chunk_insts := {}
var _water_chunk_insts := {}

var _chunk_data := {}
var _face_res := 0
var _top_depth_grid := PackedInt32Array()
var _top_mat_grid := PackedByteArray()
var _chunk_col_shapes := {}  # int key → CollisionShape3D, one per chunk
var _opened_columns := {}  # gi key → true for columns with outer shell fully dug

# --- Water gravity settling (source-block, full-voxel) ---------------------
# A frontier of "active" water cells that may still spread. Dig events seed it;
# a Timer drains it a few dozen cells per tick so water creeps into dug space
# and settles instead of snap-filling. Flow rule: fall to the air voxel below
# (higher depth = more inward = lower) first; else spread sideways into same-
# level air; never flow upward. Bounded to depth [0, MAX_FLOW_DEPTH] so the
# hollow centre stays dry. The ocean is an infinite source (water cells are
# never removed) — communicating-vessel fill, not conservative finite volume.
const FLOW_HZ := 6.0  # settling ticks per second
const FLOW_PER_TICK := 8  # max cells processed per tick (per face) — low so a dug
# pocket fills with a visible creep instead of snapping full instantly
const MAX_FLOW_DEPTH := 15  # never fill deeper than this (keep centre dry)
var _flow_timer: Timer = null
var _active_water := {}  # gk → [c, r, d]  (membership + payload)
var _active_order: Array = []  # FIFO of gk for round-robin draining


func _ready() -> void:
	pass  # The build is driven externally by VoxelPlanet.build_planet_async() so
	# the planet can assemble progressively across frames (loading screen).


# --- Staged build API (driven by VoxelPlanet's orchestrator) ---------------
# Mirror of CubeFace's staged API so the orchestrator can drive outer and inner
# shells through the same load → build-chunk → seam pipeline across frames.


func init_face() -> void:
	_mat = ShaderMaterial.new()
	(_mat as ShaderMaterial).shader = load("res://shaders/inner_voxel.gdshader") as Shader
	# Same baked real star map as the sky → the ocean-ceiling projection shows the
	# identical constellations. The file_exists guard avoids load() errors before
	# the maps are baked (starmap.py / citylights.py) — the shaders just show no
	# stars/cities until then.
	if FileAccess.file_exists("res://planet/star_map.png"):
		var star_tex := load("res://planet/star_map.png") as Texture2D
		if star_tex:
			(_mat as ShaderMaterial).set_shader_parameter("star_map", star_tex)
	# Real night-lights for the land ceiling tiles, sampled by geographic direction
	# so cities land on the real continents.
	if FileAccess.file_exists("res://planet/city_lights.png"):
		var city_tex := load("res://planet/city_lights.png") as Texture2D
		if city_tex:
			(_mat as ShaderMaterial).set_shader_parameter("city_tex", city_tex)
	_water_mat = ShaderMaterial.new()
	(_water_mat as ShaderMaterial).shader = load("res://shaders/water.gdshader") as Shader

	_face_res = CHUNK_SIZE * chunks_per_edge
	_top_depth_grid.resize(_face_res * _face_res)
	_top_depth_grid.fill(0)
	_top_mat_grid.resize(_face_res * _face_res)
	_top_mat_grid.fill(9)  # default rock

	# Water settling tick. Stays stopped until a dig (or seam-in) seeds the
	# frontier, then runs until the water has nowhere left to flow.
	_flow_timer = Timer.new()
	_flow_timer.wait_time = 1.0 / FLOW_HZ
	_flow_timer.one_shot = false
	_flow_timer.timeout.connect(_on_flow_tick)
	add_child(_flow_timer)


func load_chunks() -> void:
	for cx in chunks_per_edge:
		for cy in chunks_per_edge:
			var data := ChunkLoader.load_inner(face_id, cx, cy)
			if data.is_empty():
				continue
			_chunk_data[cx * chunks_per_edge + cy] = data
			_populate_grid_from_chunk(data, cx, cy)


func has_chunk(cx: int, cy: int) -> bool:
	return _chunk_data.has(cx * chunks_per_edge + cy)


func build_chunk(cx: int, cy: int) -> void:
	var key := cx * chunks_per_edge + cy
	if not _chunk_data.has(key):
		return
	_rebuild_chunk(cx, cy, key)
	_build_chunk_collision(cx, cy)


# Approximate world-space centre of a chunk on the INNER shell (just below the
# crust), so the orchestrator can order it by distance from the spawn point.
func chunk_world_center(cx: int, cy: int) -> Vector3:
	var cpe := float(chunks_per_edge)
	var u := (float(cx) + 0.5) / cpe
	var v := (float(cy) + 0.5) / cpe
	var voxel_size := planet_radius / float(chunks_per_edge * CHUNK_SIZE)
	var r := planet_radius - CHUNK_SIZE * voxel_size
	return _CubeFaceScript.face_uv_to_unit(face_id, u, v) * r


# Re-mesh the chunks along all four face edges. Run once by the orchestrator
# AFTER every face has loaded its data (see CubeFace.rebuild_seam_edges).
func rebuild_seam_edges() -> void:
	var last := chunks_per_edge - 1
	var seen := {}
	for i in chunks_per_edge:
		for c in [[0, i], [last, i], [i, 0], [i, last]]:
			var cx: int = c[0]
			var cy: int = c[1]
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
			var floor_mat := 9
			for depth in CHUNK_SIZE:
				var m := ChunkLoader.voxel(data, lc, lr, depth)
				if m != 0 and m != 2:  # first non-air, non-water = seafloor or rock
					floor_depth = depth
					floor_mat = m
					break
			var col := cx * CHUNK_SIZE + lc
			var row := cy * CHUNK_SIZE + lr
			var gi := col * _face_res + row
			_top_depth_grid[gi] = floor_depth
			_top_mat_grid[gi] = floor_mat


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
	var u := (float(col) + 0.5) / float(_face_res)
	var v := (float(row) + 0.5) / float(_face_res)
	var unit := _CubeFaceScript.face_uv_to_unit(face_id, u, v)
	var r := _CubeFaceScript.unit_to_face_col_row(unit, _face_res)
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
	var ncol := int(r[1])
	var nrow := int(r[2])
	var ncx := ncol / CHUNK_SIZE
	var ncy := nrow / CHUNK_SIZE
	var nkey := ncx * chunks_per_edge + ncy
	if not nb._chunk_data.has(nkey):
		return true
	var nm := ChunkLoader.voxel(nb._chunk_data[nkey], ncol % CHUNK_SIZE, nrow % CHUNK_SIZE, depth)
	return nm != 0 and nm != 2


# A radial (top/bottom) voxel face at radius r over one column cell. `outward`
# orients the normal toward the surface (top) or toward the cavity (bottom).
func _emit_radial_face(
	st: SurfaceTool,
	u0: float,
	v0: float,
	u1: float,
	v1: float,
	r: float,
	color: Color,
	outward: bool,
	ceiling_uv2: Vector2 = Vector2.ZERO
) -> void:
	var p00 := _CubeFaceScript.face_uv_to_unit(face_id, u0, v0) * r
	var p10 := _CubeFaceScript.face_uv_to_unit(face_id, u1, v0) * r
	var p01 := _CubeFaceScript.face_uv_to_unit(face_id, u0, v1) * r
	var p11 := _CubeFaceScript.face_uv_to_unit(face_id, u1, v1) * r
	var normal := (p00 + p10 + p01 + p11) * 0.25
	if not outward:
		normal = -normal
	st.set_color(color)
	# Ceiling tag for inner_voxel.gdshader. x: 0 = plain, 1 = land (city lights),
	# 2 = ocean (starfield). y: per-tile random seed for the land light. Persists
	# across the add_vertex calls below.
	st.set_uv2(ceiling_uv2)
	if (p10 - p00).cross(p11 - p00).dot(normal) > 0.0:
		st.set_uv(Vector2(0, 0))
		st.add_vertex(p00)
		st.set_uv(Vector2(1, 0))
		st.add_vertex(p10)
		st.set_uv(Vector2(1, 1))
		st.add_vertex(p11)
		st.set_uv(Vector2(0, 0))
		st.add_vertex(p00)
		st.set_uv(Vector2(1, 1))
		st.add_vertex(p11)
		st.set_uv(Vector2(0, 1))
		st.add_vertex(p01)
	else:
		st.set_uv(Vector2(0, 0))
		st.add_vertex(p00)
		st.set_uv(Vector2(1, 1))
		st.add_vertex(p11)
		st.set_uv(Vector2(1, 0))
		st.add_vertex(p10)
		st.set_uv(Vector2(0, 0))
		st.add_vertex(p00)
		st.set_uv(Vector2(0, 1))
		st.add_vertex(p01)
		st.set_uv(Vector2(1, 1))
		st.add_vertex(p11)


# A lateral voxel face toward `dir`, spanning r_in (cavity side) to r_out
# (surface side).  Dot-product winding points the normal into the open neighbour.
func _emit_side_face(
	st: SurfaceTool,
	col0: int,
	row0: int,
	dir: Vector2i,
	r_in: float,
	r_out: float,
	res: float,
	eps: float,
	color: Color
) -> void:
	var u_a: float
	var v_a: float
	var u_b: float
	var v_b: float
	if dir.x == 1:
		u_a = (col0 + 1) / res
		v_a = row0 / res
		u_b = (col0 + 1) / res
		v_b = (row0 + 1) / res
	elif dir.x == -1:
		u_a = col0 / res
		v_a = (row0 + 1) / res
		u_b = col0 / res
		v_b = row0 / res
	elif dir.y == 1:
		u_a = (col0 + 1) / res
		v_a = (row0 + 1) / res
		u_b = col0 / res
		v_b = (row0 + 1) / res
	else:
		u_a = col0 / res
		v_a = row0 / res
		u_b = (col0 + 1) / res
		v_b = row0 / res

	var pa_top := _CubeFaceScript.face_uv_to_unit(face_id, u_a, v_a) * r_out
	var pb_top := _CubeFaceScript.face_uv_to_unit(face_id, u_b, v_b) * r_out
	var pa_base := _CubeFaceScript.face_uv_to_unit(face_id, u_a, v_a) * r_in
	var pb_base := _CubeFaceScript.face_uv_to_unit(face_id, u_b, v_b) * r_in

	var u_mid := (u_a + u_b) * 0.5
	var v_mid := (v_a + v_b) * 0.5
	var mid_pt := _CubeFaceScript.face_uv_to_unit(face_id, u_mid, v_mid)
	var out_pt := _CubeFaceScript.face_uv_to_unit(face_id, u_mid + dir.x * eps, v_mid + dir.y * eps)
	var expected_out := out_pt - mid_pt

	st.set_color(color)
	st.set_uv2(Vector2.ZERO)  # side walls are never ceiling — plain shading
	if (pa_top - pa_base).cross(pb_top - pa_base).dot(expected_out) > 0.0:
		st.set_uv(Vector2(0, 0))
		st.add_vertex(pa_base)
		st.set_uv(Vector2(0, 1))
		st.add_vertex(pa_top)
		st.set_uv(Vector2(1, 1))
		st.add_vertex(pb_top)
		st.set_uv(Vector2(0, 0))
		st.add_vertex(pa_base)
		st.set_uv(Vector2(1, 1))
		st.add_vertex(pb_top)
		st.set_uv(Vector2(1, 0))
		st.add_vertex(pb_base)
	else:
		st.set_uv(Vector2(0, 0))
		st.add_vertex(pa_base)
		st.set_uv(Vector2(1, 1))
		st.add_vertex(pb_top)
		st.set_uv(Vector2(0, 1))
		st.add_vertex(pa_top)
		st.set_uv(Vector2(0, 0))
		st.add_vertex(pa_base)
		st.set_uv(Vector2(1, 0))
		st.add_vertex(pb_base)
		st.set_uv(Vector2(1, 1))
		st.add_vertex(pb_top)


# True per-voxel mesher: every solid voxel emits exactly the faces exposed to an
# open neighbour (air / water / cavity), in all 6 directions.  This is what makes
# the sub-surface a real volume — every block below ground is represented, dug
# holes show their full surroundings, and horizontal tunnels mesh correctly.
# Consumed by BOTH render (_rebuild_chunk) and collision (_build_chunk_collision_mesh).
func _add_chunk_to_surface(st: SurfaceTool, data: PackedByteArray, cx: int, cy: int) -> void:
	var res := float(_face_res)
	var voxel_size := planet_radius / res
	var eps := 0.5 / res

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
				if m == 2:
					continue  # water is never solid — drawn as translucent swim-through
					# water by _add_water_to_surface (never a solid/collidable
					# face). Stored ocean-ceiling art uses mat 11, not mat 2, so
					# this only affects flood-filled water reaching depth 15:
					# without it, that bottom-layer water re-solidified into an
					# unbreakable blue block. Matches _is_solid_at (mat 2 = open).

				var color: Color = MAT_COLORS.get(m, Color(0.4, 0.35, 0.3))
				var r_out := planet_radius - (float(depth) + 1.0) * voxel_size  # toward surface
				var r_in := planet_radius - (float(depth) + 2.0) * voxel_size  # toward cavity

				# Outward (top) face — exposed if the voxel just outward is open.
				if not _is_solid_at(cx, cy, data, lc, lr, depth - 1):
					_emit_radial_face(st, u0, v0, u1, v1, r_out, color, true)

				# Inward (bottom) face — exposed if the voxel just inward is open
				# (the cavity beneath the deepest rock, or an excavated pocket).
				if not _is_solid_at(cx, cy, data, lc, lr, depth + 1):
					var under := Color(color.r * 0.5, color.g * 0.5, color.b * 0.5, color.a)
					# Only the innermost layer (depth 15) IS the cavity ceiling: tag it
					# (UV2.x) so inner_voxel.gdshader lights it — land → warm city lights
					# (1), ocean (mat 10/11) → cool star projection (2). Both share one
					# twinkling field, coloured per tile. Dug interior walls stay plain.
					var ceiling_uv2 := Vector2.ZERO
					if depth == CHUNK_SIZE - 1:
						ceiling_uv2 = Vector2(2.0, 0.0) if (m == 10 or m == 11) else Vector2(1.0, 0.0)
					_emit_radial_face(st, u0, v0, u1, v1, r_in, under, false, ceiling_uv2)

				# Four lateral faces — exposed where the side neighbour is open.
				for dir in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					if not _is_solid_at(cx, cy, data, lc + dir.x, lr + dir.y, depth):
						var side_color := Color(
							color.r * 0.65, color.g * 0.65, color.b * 0.65, color.a
						)
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
	var res := float(_face_res)
	var voxel_size := planet_radius / res
	var eps := 0.5 / res
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
				var r_in := planet_radius - (float(depth) + 2.0) * voxel_size

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
	var cx := col / CHUNK_SIZE
	var cy := row / CHUNK_SIZE
	var key := cx * chunks_per_edge + cy
	if not _chunk_data.has(key):
		return 0
	return ChunkLoader.voxel(_chunk_data[key], col % CHUNK_SIZE, row % CHUNK_SIZE, depth)


# Add a water cell to the settling frontier (deduped) and make sure the flow
# tick is running. Out-of-bounds / out-of-depth cells are ignored here so call
# sites don't each have to guard.
func _enqueue_water(c: int, r: int, d: int) -> void:
	if c < 0 or c >= _face_res or r < 0 or r >= _face_res:
		return
	if d < 0 or d > MAX_FLOW_DEPTH:
		return
	var gk: int = (c * _face_res + r) * CHUNK_SIZE + d
	if _active_water.has(gk):
		return
	_active_water[gk] = [c, r, d]
	_active_order.push_back(gk)
	if _flow_timer != null and _flow_timer.is_stopped():
		_flow_timer.start()


# Write mat-2 into the in-face voxel (c, r, d) and record its chunk as dirty.
# Returns false if the chunk isn't loaded. Caller is responsible for bounds.
func _set_water(c: int, r: int, d: int, dirty: Dictionary) -> bool:
	var cx: int = c / CHUNK_SIZE
	var cy: int = r / CHUNK_SIZE
	var lc: int = c % CHUNK_SIZE
	var lr: int = r % CHUNK_SIZE
	var key: int = cx * chunks_per_edge + cy
	if not _chunk_data.has(key):
		return false
	var data: PackedByteArray = _chunk_data[key]
	data[lc + CHUNK_SIZE * (lr + CHUNK_SIZE * d)] = 2
	_chunk_data[key] = data
	dirty[key] = [cx, cy]
	return true


# Called by a neighbouring face when water flows across the cube-face seam into
# this face. Writes the water, re-meshes the touched chunk immediately, and
# adds the cell to this face's frontier so it keeps flowing on this face's tick.
func seed_external_water(col: int, row: int, depth: int) -> void:
	if mat_at(col, row, depth) != 0:
		return
	var dirty := {}
	if not _set_water(col, row, depth, dirty):
		return
	var rebuilt := {}
	_rebuild_dirty_chunks(dirty, rebuilt)
	_enqueue_water(col, row, depth)


# Apply the flow rule to one water cell. Fills the air voxel directly below
# (depth + 1) if any; otherwise spreads into same-level air neighbours (in-face
# or across a seam). Returns true if any water was placed (so the cell stays in
# the frontier and keeps feeding). `dirty` accumulates this face's touched chunks.
func _settle_one(c: int, r: int, d: int, dirty: Dictionary) -> bool:
	if mat_at(c, r, d) != 2:
		return false
	# Fall first: into the air voxel one step inward (higher depth = lower).
	if d + 1 <= MAX_FLOW_DEPTH and mat_at(c, r, d + 1) == 0:
		if _set_water(c, r, d + 1, dirty):
			_enqueue_water(c, r, d + 1)
			return true
		return false
	# Otherwise spread sideways into same-level air.
	var moved := false
	for dir in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var nc: int = c + dir.x
		var nr: int = r + dir.y
		if nc >= 0 and nc < _face_res and nr >= 0 and nr < _face_res:
			if mat_at(nc, nr, d) == 0 and _set_water(nc, nr, d, dirty):
				_enqueue_water(nc, nr, d)
				moved = true
		elif _cross_seam_water(nc, nr, d):
			moved = true
	return moved


# Flow sideways across a cube-face seam: re-project the out-of-bounds neighbour
# (nc, nr) to its owning face and, if that cell is air, hand the water off to
# that face. Depth is radial and shared across all faces, so it carries over.
func _cross_seam_water(nc: int, nr: int, d: int) -> bool:
	var u := (float(nc) + 0.5) / float(_face_res)
	var v := (float(nr) + 0.5) / float(_face_res)
	var unit := _CubeFaceScript.face_uv_to_unit(face_id, u, v)
	var rr := _CubeFaceScript.unit_to_face_col_row(unit, _face_res)
	var nface := int(rr[0])
	if nface == face_id:
		return false
	var nb := get_parent().get_node_or_null("InnerCubeFace_%d" % nface) as InnerCubeFace
	if nb == null or not is_instance_valid(nb):
		return false
	var ncol: int = int(rr[1])
	var nrow: int = int(rr[2])
	if nb.mat_at(ncol, nrow, d) != 0:
		return false
	nb.seed_external_water(ncol, nrow, d)
	return true


# Seed the settling frontier with the water cells around a just-dug voxel, so
# adjacent ocean/water starts creeping into the new air on the next tick. Covers
# the depth-above cell (water falls in) and same-level/below water, plus seam
# neighbours (the dug cell may border ocean on an adjacent face).
func _seed_flow_around(col: int, row: int, depth: int) -> void:
	for n in [
		[col + 1, row, depth],
		[col - 1, row, depth],
		[col, row + 1, depth],
		[col, row - 1, depth],
		[col, row, depth - 1],
		[col, row, depth + 1]
	]:
		var nc: int = n[0]
		var nr: int = n[1]
		var nd: int = n[2]
		if nc >= 0 and nc < _face_res and nr >= 0 and nr < _face_res:
			if mat_at(nc, nr, nd) == 2:
				_enqueue_water(nc, nr, nd)
		elif nd == depth:
			# Lateral seam neighbour — enqueue on the owning face if it's water.
			var u := (float(nc) + 0.5) / float(_face_res)
			var v := (float(nr) + 0.5) / float(_face_res)
			var unit := _CubeFaceScript.face_uv_to_unit(face_id, u, v)
			var rr := _CubeFaceScript.unit_to_face_col_row(unit, _face_res)
			var nface := int(rr[0])
			if nface == face_id:
				continue
			var nb := get_parent().get_node_or_null("InnerCubeFace_%d" % nface) as InnerCubeFace
			if nb == null or not is_instance_valid(nb):
				continue
			var ncol: int = int(rr[1])
			var nrow: int = int(rr[2])
			if nb.mat_at(ncol, nrow, nd) == 2:
				nb._enqueue_water(ncol, nrow, nd)


# Drain the settling frontier: process up to FLOW_PER_TICK water cells, then
# re-mesh the chunks they touched. Water is non-solid (air↔water both open to
# _is_solid_at), so only render/water meshes rebuild — collision is untouched.
func _on_flow_tick() -> void:
	if _active_order.is_empty():
		_flow_timer.stop()
		return
	var dirty := {}
	var processed := 0
	while processed < FLOW_PER_TICK and not _active_order.is_empty():
		var gk: int = _active_order.pop_front()
		var payload = _active_water.get(gk)
		_active_water.erase(gk)
		if payload == null:
			continue
		var c: int = payload[0]
		var r: int = payload[1]
		var d: int = payload[2]
		if _settle_one(c, r, d, dirty):
			_enqueue_water(c, r, d)  # still a source — keep feeding next tick
		processed += 1
	var rebuilt := {}
	_rebuild_dirty_chunks(dirty, rebuilt)
	if _active_order.is_empty():
		_flow_timer.stop()


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
		var nc: int = int(r[1])
		var nr: int = int(r[2])
		var ncx: int = nc / CHUNK_SIZE
		var ncy: int = nr / CHUNK_SIZE
		var nkey: int = ncx * nb.chunks_per_edge + ncy
		if nb._chunk_data.has(nkey):
			nb._rebuild_chunk(ncx, ncy, nkey)
			nb._build_chunk_collision.call_deferred(ncx, ncy)


# Re-mesh every chunk the flood fill wrote water into. The BFS can propagate
# far down a pre-dug shaft into chunks the dug-chunk neighbour loop never
# touches, so these must be rebuilt explicitly or the new water is invisible.
# Collision is unchanged (air→water are both non-solid), so only the render +
# water meshes are rebuilt. `rebuilt` dedupes against later neighbour rebuilds.
func _rebuild_dirty_chunks(dirty: Dictionary, rebuilt: Dictionary) -> void:
	for entry in dirty.values():
		var dx: int = (entry as Array)[0]
		var dy: int = (entry as Array)[1]
		var dkey: int = dx * chunks_per_edge + dy
		if not rebuilt.has(dkey) and _chunk_data.has(dkey):
			rebuilt[dkey] = true
			_rebuild_chunk(dx, dy, dkey)


# Remove a specific voxel by column + depth. Opens the column if it becomes
# fully empty (chains to open_column so the cavity passage is created).
func remove_voxel(col: int, row: int, depth: int) -> bool:
	var cx := col / CHUNK_SIZE
	var cy := row / CHUNK_SIZE
	var lc := col % CHUNK_SIZE
	var lr := row % CHUNK_SIZE
	var key := cx * chunks_per_edge + cy
	if not _chunk_data.has(key):
		return false
	var data: PackedByteArray = _chunk_data[key]
	if ChunkLoader.voxel(data, lc, lr, depth) == 0:
		return false
	data[lc + CHUNK_SIZE * (lr + CHUNK_SIZE * depth)] = 0
	_chunk_data[key] = data
	# Seed water settling: neighbouring ocean/water now creeps into the new air
	# over the next ticks (gravity flow), instead of snap-filling on the dig.
	_seed_flow_around(col, row, depth)
	var rebuilt := {}
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
	if not rebuilt.has(key):
		_rebuild_chunk(cx, cy, key)
		rebuilt[key] = true
	for nb in [[cx - 1, cy], [cx + 1, cy], [cx, cy - 1], [cx, cy + 1]]:
		var nx: int = nb[0]
		var ny: int = nb[1]
		if nx < 0 or nx >= chunks_per_edge or ny < 0 or ny >= chunks_per_edge:
			continue
		var nkey := nx * chunks_per_edge + ny
		if _chunk_data.has(nkey) and not rebuilt.has(nkey):
			rebuilt[nkey] = true
			_rebuild_chunk(nx, ny, nkey)
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
	var cx := col / CHUNK_SIZE
	var cy := row / CHUNK_SIZE
	var lc := col % CHUNK_SIZE
	var lr := row % CHUNK_SIZE
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
	# Seed water settling (gravity flow over time) — see remove_voxel.
	_seed_flow_around(col, row, floor_d)
	var rebuilt := {}

	# Update grid: new floor is the next non-water solid below.
	var new_floor := floor_d
	var new_mat := 9
	for depth in range(floor_d + 1, CHUNK_SIZE):
		var m := ChunkLoader.voxel(data, lc, lr, depth)
		if m != 0 and m != 2:
			new_floor = depth
			new_mat = m
			break
	if new_floor == floor_d:
		# No deeper solid — inner column fully dug; open passage to cavity.
		open_column(col, row)
		return true

	var gi := col * _face_res + row
	_top_depth_grid[gi] = new_floor
	_top_mat_grid[gi] = new_mat

	_build_chunk_collision.call_deferred(cx, cy)
	if not rebuilt.has(key):
		_rebuild_chunk(cx, cy, key)
		rebuilt[key] = true
	for nb in [[cx - 1, cy], [cx + 1, cy], [cx, cy - 1], [cx, cy + 1]]:
		var nx: int = nb[0]
		var ny: int = nb[1]
		if nx < 0 or nx >= chunks_per_edge or ny < 0 or ny >= chunks_per_edge:
			continue
		var nkey := nx * chunks_per_edge + ny
		if _chunk_data.has(nkey) and not rebuilt.has(nkey):
			rebuilt[nkey] = true
			_rebuild_chunk(nx, ny, nkey)
	_rebuild_seam_neighbors(col, row)
	return true


func _rebuild_chunk(cx: int, cy: int, key: int) -> void:
	# Retrieve UNTYPED (no `as` cast) — `as` on a freed object throws "Trying to
	# cast a freed object". Always erase the dict entry after freeing: the water
	# instance is only re-stored when the water mesh is non-empty, so a chunk
	# whose water just emptied would otherwise leave a stale freed reference that
	# crashes the next rebuild (aborting it mid-way → missing/transparent mesh).
	var old = _chunk_insts.get(key)
	if old != null and is_instance_valid(old):
		old.visible = false
		old.queue_free()
	_chunk_insts.erase(key)
	var old_water = _water_chunk_insts.get(key)
	if old_water != null and is_instance_valid(old_water):
		old_water.visible = false
		old_water.queue_free()
	_water_chunk_insts.erase(key)
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
