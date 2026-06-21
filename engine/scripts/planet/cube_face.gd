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

# Equiangular (tangent) cube-sphere pre-distortion strength. MUST match
# cube_sphere.py EQUIANGULAR_ALPHA (π/4 = full equiangular; →0 = plain linear).
const EQUIANGULAR_ALPHA := PI / 4.0
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
	10: Color(0.28, 0.22, 0.16),  # Seafloor (sandy/rocky ocean floor)
}

@export var face_id: int = 0
@export var chunks_per_edge: int = 16

var _chunk_data := {}  # int key (cx*CPE + cy) → PackedByteArray (raw voxels)
var _mat: Material = null
var _water_mat: Material = null
var _chunk_insts := {}  # int key → MeshInstance3D
var _water_chunk_insts := {}  # int key → MeshInstance3D

var _face_res := 0
var _chunk_col_shapes := {}  # int key → CollisionShape3D, one per chunk

# --- Water gravity settling (source-block, full-voxel) ---------------------
# Mirror of the inner shell's settling, with the OUTWARD depth convention: here
# higher depth = higher elevation, so "down" (toward sea level) = LOWER depth.
# Water falls to the air voxel at depth-1 first; at depth 0 (sea level) it hands
# off to the inner shell (depth 0) so coastal pools drain into the subsurface;
# otherwise it spreads sideways into same-level air. Never flows upward. Dig
# events seed the frontier; a Timer drains it so water creeps in over time.
const FLOW_HZ := 6.0  # settling ticks per second
const FLOW_PER_TICK := 8  # max cells processed per tick (per face) — low so a dug
# pocket fills with a visible creep instead of snapping full instantly
var _flow_timer: Timer = null
var _active_water := {}  # gk → [c, r, d]  (membership + payload)
var _active_order: Array = []  # FIFO of gk for round-robin draining


func _ready() -> void:
	pass  # The build is driven externally by VoxelPlanet.build_planet_async() so
	# the planet can assemble progressively across frames (loading screen).


# --- Staged build API (driven by VoxelPlanet's orchestrator) ---------------
# _build_face() was split into init / load / build-chunk / seam steps so the
# orchestrator can interleave them across frames (await between batches),
# rendering the planet live instead of blocking the main thread before frame 1.


func init_face() -> void:
	_mat = ShaderMaterial.new()
	(_mat as ShaderMaterial).shader = load("res://shaders/voxel.gdshader") as Shader
	_water_mat = ShaderMaterial.new()
	(_water_mat as ShaderMaterial).shader = load("res://shaders/water.gdshader") as Shader

	_face_res = CHUNK_SIZE * chunks_per_edge

	# Water settling tick. Stays stopped until a dig (or seam/shell hand-off)
	# seeds the frontier, then runs until the water has nowhere left to flow.
	_flow_timer = Timer.new()
	_flow_timer.wait_time = 1.0 / FLOW_HZ
	_flow_timer.one_shot = false
	_flow_timer.timeout.connect(_on_flow_tick)
	add_child(_flow_timer)


# Pass 1: load all chunks. Raw bytes are kept so the per-voxel mesher can look
# up neighbour occupancy across chunk boundaries (no derived grid needed). Must
# complete for ALL faces before meshing so cross-face seam culling is correct.
func load_chunks() -> void:
	for cx in chunks_per_edge:
		for cy in chunks_per_edge:
			var data := ChunkLoader.load(face_id, cx, cy)
			if data.is_empty():
				continue
			_chunk_data[cx * chunks_per_edge + cy] = data


func has_chunk(cx: int, cy: int) -> bool:
	return _chunk_data.has(cx * chunks_per_edge + cy)


# Build one chunk's land + ocean mesh and its matching collision shape. No-op if
# the chunk is unloaded. Called once per chunk by the orchestrator (batched).
# The collision shape reuses the land render mesh's geometry (same triangles —
# create_trimesh_shape ignores colour/uv/normals) instead of re-running the
# per-voxel mesher a second time, which roughly halves the bulk-build mesh cost.
func build_chunk(cx: int, cy: int) -> void:
	var key := cx * chunks_per_edge + cy
	if not _chunk_data.has(key):
		return
	var land_mesh := _rebuild_chunk(cx, cy, key)
	_build_chunk_collision(cx, cy, land_mesh)


# Approximate world-space centre of a chunk on this shell — used by the
# orchestrator to order the build (spiral out from the spawn point).
func chunk_world_center(cx: int, cy: int) -> Vector3:
	var cpe := float(chunks_per_edge)
	var u := (float(cx) + 0.5) / cpe
	var v := (float(cy) + 0.5) / cpe
	return face_uv_to_unit(face_id, u, v) * planet_radius


# Re-mesh the chunks along all four face edges. Run once by the orchestrator
# AFTER every face has loaded its data, so cross-face neighbour lookups resolve
# (faces built without it cull seam walls toward not-yet-loaded faces, leaving
# invisible side walls until a nearby dig).
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


# True voxel occupancy test, used for 6-way face culling. A face is emitted only
# where a solid voxel borders an open one.
#   depth < 0              → solid (inner shell provides floor; don't gap here)
#   depth >= CHUNK_SIZE    → open (air above the surface)
#   water (mat 2)          → open (coast/seafloor faces show through)
#   out-of-face-bounds     → look up the neighbour face via sphere re-projection
#   unloaded neighbour     → solid (don't open into the unknown)
func _is_solid_at(cx: int, cy: int, data: PackedByteArray, lc: int, lr: int, depth: int) -> bool:
	if depth < 0:
		return false
	if depth >= CHUNK_SIZE:
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
	# Cross-face: project the out-of-bounds cell onto the sphere and re-project to
	# find which neighbour face owns this voxel and its local coords. Culling a
	# seam face when the neighbour is solid keeps flat seams clean (no standing
	# wall, no shadow line); emitting it when the neighbour is air fixes genuine
	# see-through holes at coastlines/cliffs that straddle a seam. For the common
	# solid-to-solid case the lookup is robust: even a slightly-off re-projection
	# still lands on solid terrain and correctly culls. The `return true` (solid)
	# fallbacks below therefore bias toward the clean culled look when the
	# neighbour can't be resolved. Sample the cell CENTRE (+0.5), not the corner,
	# which lands on the ambiguous seam line.
	var u := (float(col) + 0.5) / float(_face_res)
	var v := (float(row) + 0.5) / float(_face_res)
	var unit := face_uv_to_unit(face_id, u, v)
	var r := unit_to_face_col_row(unit, _face_res)
	var nface := int(r[0])
	if nface == face_id:
		# Degenerate: boundary pixel projected back to same face. Nudge inward.
		var eps: float = 0.5 / float(_face_res)
		var u2: float = clamp(u, eps, 1.0 - eps)
		var v2: float = clamp(v, eps, 1.0 - eps)
		unit = face_uv_to_unit(face_id, u2, v2)
		r = unit_to_face_col_row(unit, _face_res)
		nface = int(r[0])
		if nface == face_id:
			return true  # cube corner — treat as solid (clean culled seam)
	var nb := get_parent().get_node_or_null("CubeFace_%d" % nface) as CubeFace
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
# orients the normal toward the surface (top) or toward the centre (bottom).
func _emit_radial_face(
	st: SurfaceTool,
	u0: float,
	v0: float,
	u1: float,
	v1: float,
	r: float,
	color: Color,
	outward: bool
) -> void:
	var p00 := face_uv_to_unit(face_id, u0, v0) * r
	var p10 := face_uv_to_unit(face_id, u1, v0) * r
	var p01 := face_uv_to_unit(face_id, u0, v1) * r
	var p11 := face_uv_to_unit(face_id, u1, v1) * r
	var normal := (p00 + p10 + p01 + p11) * 0.25
	if not outward:
		normal = -normal
	st.set_color(color)
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


# A lateral voxel face toward `dir`, spanning r_in (inward side) to r_out (outward
# side). Dot-product winding points the normal into the open neighbour.
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

	var pa_top := face_uv_to_unit(face_id, u_a, v_a) * r_out
	var pb_top := face_uv_to_unit(face_id, u_b, v_b) * r_out
	var pa_base := face_uv_to_unit(face_id, u_a, v_a) * r_in
	var pb_base := face_uv_to_unit(face_id, u_b, v_b) * r_in

	var u_mid := (u_a + u_b) * 0.5
	var v_mid := (v_a + v_b) * 0.5
	var mid_pt := face_uv_to_unit(face_id, u_mid, v_mid)
	var out_pt := face_uv_to_unit(face_id, u_mid + dir.x * eps, v_mid + dir.y * eps)
	var expected_out := out_pt - mid_pt

	st.set_color(color)
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
# open neighbour (air / water / cross the inner shell), in all 6 directions. This
# is what makes the outer crust a real volume — dug holes show their surroundings
# and horizontal tunnels mesh. Consumed by BOTH render and collision so they
# never diverge. Ocean (mat 2) is skipped here; ocean tops are a separate water
# mesh, and _is_solid_at treats water as open so coast faces still show.
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
				if m == 0 or m == 2:
					continue

				var color: Color = MAT_COLORS.get(m, Color.WHITE)
				var r_out := planet_radius + float(depth) * voxel_size  # outward (top)
				var r_in := planet_radius + (float(depth) - 1.0) * voxel_size  # inward (bottom)

				# Outward (top) face — exposed if the voxel just outward is open.
				if not _is_solid_at(cx, cy, data, lc, lr, depth + 1):
					_emit_radial_face(st, u0, v0, u1, v1, r_out, color, true)

				# Inward (bottom) face — always emit so the crust looks solid from inside.
				var under := Color(color.r * 0.5, color.g * 0.5, color.b * 0.5, color.a)
				_emit_radial_face(st, u0, v0, u1, v1, r_in, under, false)

				# Four lateral faces — exposed where the side neighbour is open.
				for dir in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					if not _is_solid_at(cx, cy, data, lc + dir.x, lr + dir.y, depth):
						var side_color := Color(
							color.r * 0.65, color.g * 0.65, color.b * 0.65, color.a
						)
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


# `reuse` lets the bulk build pass the already-built land render mesh so collision
# doesn't re-mesh the chunk; the dig/seam paths call this deferred with no mesh and
# rebuild it fresh.
func _build_chunk_collision(cx: int, cy: int, reuse: Mesh = null) -> void:
	var key := cx * chunks_per_edge + cy
	var old := _chunk_col_shapes.get(key) as CollisionShape3D
	if old != null and is_instance_valid(old):
		old.queue_free()
		_chunk_col_shapes.erase(key)
	var mesh := reuse if reuse != null else _build_chunk_collision_mesh(cx, cy)
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
	var res := float(_face_res)
	var voxel_size := planet_radius / res

	for lc in CHUNK_SIZE:
		for lr in CHUNK_SIZE:
			var top_depth := -1
			var top_mat := 0
			for depth in CHUNK_SIZE:
				var m := ChunkLoader.voxel(data, lc, lr, depth)
				if m == 0:
					break
				top_depth = depth
				top_mat = m
			if top_depth < 0 or top_mat != 2:
				continue

			var col0 := cx * CHUNK_SIZE + lc
			var row0 := cy * CHUNK_SIZE + lr
			var r := planet_radius + top_depth * voxel_size

			var color: Color = MAT_COLORS.get(2, Color.WHITE)
			var p00 := face_uv_to_unit(face_id, col0 / res, row0 / res) * r
			var p10 := face_uv_to_unit(face_id, (col0 + 1) / res, row0 / res) * r
			var p01 := face_uv_to_unit(face_id, col0 / res, (row0 + 1) / res) * r
			var p11 := face_uv_to_unit(face_id, (col0 + 1) / res, (row0 + 1) / res) * r

			st.set_color(color)
			if face_id == 2 or face_id == 3:
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
			else:
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


# Returns the committed land render mesh so build_chunk can reuse it for collision
# without re-meshing. Other callers (digs, water flow, seams) ignore the return.
func _rebuild_chunk(cx: int, cy: int, key: int) -> Mesh:
	# Retrieve UNTYPED (no `as` cast) — `as` on a freed object throws "Trying to
	# cast a freed object". Always erase the dict entry after freeing: the water
	# instance is only re-stored when the water mesh is non-empty, so a chunk
	# whose water just emptied would otherwise leave a stale freed reference that
	# crashes the next rebuild (aborting it mid-way → missing/transparent mesh).
	var old_inst = _chunk_insts.get(key)
	if old_inst != null and is_instance_valid(old_inst):
		old_inst.visible = false
		old_inst.queue_free()
	_chunk_insts.erase(key)
	var old_water = _water_chunk_insts.get(key)
	if old_water != null and is_instance_valid(old_water):
		old_water.visible = false
		old_water.queue_free()
	_water_chunk_insts.erase(key)
	if not _chunk_data.has(key):
		return null
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

	return inst.mesh


func set_water_visible(v: bool) -> void:
	for inst in _water_chunk_insts.values():
		(inst as MeshInstance3D).visible = v


# Material of the outermost solid voxel in a column (0 if the column is empty).
# Scans inward from the top so the surface material is reported even with caves.
func get_top_mat(col: int, row: int) -> int:
	if col < 0 or col >= _face_res or row < 0 or row >= _face_res:
		return 0
	var cx := col / CHUNK_SIZE
	var cy := row / CHUNK_SIZE
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


# Add a water cell to the settling frontier (deduped) and ensure the flow tick
# is running. Out-of-bounds / out-of-depth cells are ignored so call sites don't
# each have to guard.
func _enqueue_water(c: int, r: int, d: int) -> void:
	if c < 0 or c >= _face_res or r < 0 or r >= _face_res:
		return
	if d < 0 or d >= CHUNK_SIZE:
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
# this face. Writes the water, re-meshes the touched chunk immediately, and adds
# the cell to this face's frontier so it keeps flowing on this face's tick.
func seed_external_water(col: int, row: int, depth: int) -> void:
	if mat_at(col, row, depth) != 0:
		return
	var dirty := {}
	if not _set_water(col, row, depth, dirty):
		return
	var rebuilt := {}
	_rebuild_dirty_chunks(dirty, rebuilt)
	_enqueue_water(col, row, depth)


# Re-mesh every chunk the flow tick wrote water into (render + ocean-top mesh).
# Collision is unchanged (air↔water are both non-solid), so it isn't rebuilt.
# `rebuilt` dedupes against any later neighbour rebuilds.
func _rebuild_dirty_chunks(dirty: Dictionary, rebuilt: Dictionary) -> void:
	for entry in dirty.values():
		var dx: int = (entry as Array)[0]
		var dy: int = (entry as Array)[1]
		var dkey: int = dx * chunks_per_edge + dy
		if not rebuilt.has(dkey) and _chunk_data.has(dkey):
			rebuilt[dkey] = true
			_rebuild_chunk(dx, dy, dkey)


# Apply the flow rule to one water cell. Falls toward sea level (depth-1) first;
# at depth 0 hands the water off to the inner shell; otherwise spreads into
# same-level air (in-face or across a seam). Returns true if any water moved.
func _settle_one(c: int, r: int, d: int, dirty: Dictionary) -> bool:
	if mat_at(c, r, d) != 2:
		return false
	# Fall toward sea level (lower depth = lower elevation).
	if d - 1 >= 0:
		if mat_at(c, r, d - 1) == 0 and _set_water(c, r, d - 1, dirty):
			_enqueue_water(c, r, d - 1)
			return true
	elif _fall_into_inner(c, r):
		# At sea level: hand off to the inner shell's depth 0 below.
		return true
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


# Drop sea-level water into the inner shell: if the inner face's depth-0 voxel
# directly below (same col/row) is air, hand the water to it so it keeps falling
# inward on the inner shell's own tick. The two shells meet at r = planet_radius.
func _fall_into_inner(c: int, r: int) -> bool:
	var inner := get_parent().get_node_or_null("InnerCubeFace_%d" % face_id) as InnerCubeFace
	if inner == null or not is_instance_valid(inner):
		return false
	if inner.mat_at(c, r, 0) != 0:
		return false
	inner.seed_external_water(c, r, 0)
	return true


# Flow sideways across a cube-face seam: re-project the out-of-bounds neighbour
# (nc, nr) to its owning face and, if that cell is air, hand the water off to
# that face. Depth is radial and shared across all faces, so it carries over.
func _cross_seam_water(nc: int, nr: int, d: int) -> bool:
	var u := (float(nc) + 0.5) / float(_face_res)
	var v := (float(nr) + 0.5) / float(_face_res)
	var unit := face_uv_to_unit(face_id, u, v)
	var rr := unit_to_face_col_row(unit, _face_res)
	var nface := int(rr[0])
	if nface == face_id:
		return false
	var nb := get_parent().get_node_or_null("CubeFace_%d" % nface) as CubeFace
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
# the depth-above cell (water falls in), same-level/below water, and seam
# neighbours (a coastal dig may border ocean on an adjacent face).
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
			var unit := face_uv_to_unit(face_id, u, v)
			var rr := unit_to_face_col_row(unit, _face_res)
			var nface := int(rr[0])
			if nface == face_id:
				continue
			var nb := get_parent().get_node_or_null("CubeFace_%d" % nface) as CubeFace
			if nb == null or not is_instance_valid(nb):
				continue
			var ncol: int = int(rr[1])
			var nrow: int = int(rr[2])
			if nb.mat_at(ncol, nrow, nd) == 2:
				nb._enqueue_water(ncol, nrow, nd)


# Drain the settling frontier: process up to FLOW_PER_TICK water cells, then
# re-mesh the chunks they touched. Water is non-solid (air↔water both open to
# _is_solid_at), so only render/ocean meshes rebuild — collision is untouched.
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
# leaves see-through holes (the neighbour face still shows its old "both solid,
# cull the wall" mesh). For each out-of-face neighbour cell, re-project to find
# its owning face and rebuild that face's affected chunk + collision.
func _rebuild_seam_neighbors(col: int, row: int) -> void:
	for dir in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
		var ncol: int = col + dir.x
		var nrow: int = row + dir.y
		if ncol >= 0 and ncol < _face_res and nrow >= 0 and nrow < _face_res:
			continue  # same face — already covered by the in-face neighbour rebuild
		var u := (float(ncol) + 0.5) / float(_face_res)
		var v := (float(nrow) + 0.5) / float(_face_res)
		var unit := face_uv_to_unit(face_id, u, v)
		var r := unit_to_face_col_row(unit, _face_res)
		var nface := int(r[0])
		if nface == face_id:
			continue
		var nb := get_parent().get_node_or_null("CubeFace_%d" % nface) as CubeFace
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


# Remove a specific voxel by column + depth. Used by aimed digging.
func remove_voxel(col: int, row: int, depth: int) -> bool:
	var cx := col / CHUNK_SIZE
	var cy := row / CHUNK_SIZE
	var lc := col % CHUNK_SIZE
	var lr := row % CHUNK_SIZE
	var key := cx * chunks_per_edge + cy
	if not _chunk_data.has(key):
		return false
	var data: PackedByteArray = _chunk_data[key]
	var m := ChunkLoader.voxel(data, lc, lr, depth)
	if m == 0 or m == 2:
		return false
	data[lc + CHUNK_SIZE * (lr + CHUNK_SIZE * depth)] = 0
	_chunk_data[key] = data
	# Seed water settling: adjacent ocean/water creeps into the new air over the
	# next ticks (gravity flow), instead of snap-filling on the dig.
	_seed_flow_around(col, row, depth)
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
	_rebuild_seam_neighbors(col, row)
	return true


# Remove the outermost (highest-depth) non-air voxel of a column — the surface
# the player is standing on. Returns false when the column is already empty, so
# the caller can chain the dig into the inner shell.
func remove_top_voxel(col: int, row: int) -> bool:
	var cx := col / CHUNK_SIZE
	var cy := row / CHUNK_SIZE
	var lc := col % CHUNK_SIZE
	var lr := row % CHUNK_SIZE
	var key := cx * chunks_per_edge + cy
	if not _chunk_data.has(key):
		return false
	var data: PackedByteArray = _chunk_data[key]

	# Scan inward from the top for the first (outermost) solid non-water voxel.
	# Water (mat-2) is skipped so the sea surface is never mined directly;
	# ocean columns fall through to the inner shell for digging.
	var top := -1
	for depth in range(CHUNK_SIZE - 1, -1, -1):
		var m := ChunkLoader.voxel(data, lc, lr, depth)
		if m != 0 and m != 2:
			top = depth
			break
	if top < 0:
		return false  # column already empty

	var idx := lc + CHUNK_SIZE * (lr + CHUNK_SIZE * top)
	data[idx] = 0
	_chunk_data[key] = data
	# Seed water settling (gravity flow over time) — see remove_voxel.
	_seed_flow_around(col, row, top)

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
	_rebuild_seam_neighbors(col, row)
	return true


static func face_uv_to_unit(face: int, u: float, v: float) -> Vector3:
	var s := u * 2.0 - 1.0
	var t := v * 2.0 - 1.0
	# Equiangular pre-distortion — must match cube_sphere.py face_uv_to_xyz.
	s = tan(s * EQUIANGULAR_ALPHA) / tan(EQUIANGULAR_ALPHA)
	t = tan(t * EQUIANGULAR_ALPHA) / tan(EQUIANGULAR_ALPHA)
	var raw: Vector3
	match face:
		0:
			raw = Vector3(1.0, s, t)
		1:
			raw = Vector3(-1.0, -s, t)
		2:
			raw = Vector3(s, 1.0, t)
		3:
			raw = Vector3(-s, -1.0, t)
		4:
			raw = Vector3(s, t, 1.0)
		5:
			raw = Vector3(s, -t, -1.0)
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
	var s: float = 0.0
	var t: float = 0.0
	if ax >= ay and ax >= az:
		if r.x > 0.0:
			face = 0
			s = r.y / r.x
			t = r.z / r.x
		else:
			face = 1
			s = r.y / r.x
			t = -r.z / r.x
	elif ay >= ax and ay >= az:
		if r.y > 0.0:
			face = 2
			s = r.x / r.y
			t = r.z / r.y
		else:
			face = 3
			s = r.x / r.y
			t = -r.z / r.y
	else:
		if r.z > 0.0:
			face = 4
			s = r.x / r.z
			t = r.y / r.z
		else:
			face = 5
			s = -r.x / r.z
			t = r.y / r.z
	# Invert equiangular pre-distortion — must match cube_sphere.py xyz_to_face_uv.
	s = atan(s * tan(EQUIANGULAR_ALPHA)) / EQUIANGULAR_ALPHA
	t = atan(t * tan(EQUIANGULAR_ALPHA)) / EQUIANGULAR_ALPHA
	var res_f: float = float(resolution)
	var col: int = int(clamp((s + 1.0) * 0.5 * res_f, 0.0, res_f - 1.0))
	var row: int = int(clamp((t + 1.0) * 0.5 * res_f, 0.0, res_f - 1.0))
	return [face, col, row]
