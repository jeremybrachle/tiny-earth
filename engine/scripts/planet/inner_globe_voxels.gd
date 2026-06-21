extends StaticBody3D

# Drives the loading bar during the inner-globe build (world.gd maps it into the
# leading slice of the overall progress so "Sculpting inner globe" shows a percentage).
signal build_progress(done: int, total: int)

# The inner mini-globe as a HOLLOW, DIGGABLE voxel SHELL — a "Dyson sphere": a thin
# crust of blocks following Earth's terrain, with open hollow space inside down to a
# bright magenta core cube at the centre.
#
#   • LAND cells: biome-coloured blocks (the loading/menu-globe colours), with the real
#     terrain elevation on top, but only LAND_DEPTH blocks thick before hollow space.
#   • WATER cells: a single layer of TINTED TRANSPARENT GLASS blocks (you see through
#     them into the hollow; the block edges read as a frame — inner_globe_glass.gdshader).
#   • INSIDE: hollow. Dig a couple of blocks and you fall through to land on the magenta
#     core cube at the origin.
#
# Each surface cell is coloured/placed from the outer chunk caches (ChunkLoader.load) by
# geographic lat/lon, so it matches the loading globe. MESHING IS CHUNKED — each
# (face, 16x16 angular chunk) is one opaque MeshInstance + one glass MeshInstance, each
# with a trimesh collider; a dig only remeshes the affected chunk(s), so digging is local
# and fast. Built chunk-by-chunk on the loading screen.

const CHUNK_SIZE := 16          # source chunk-cache cells per side
const CHUNK_ANG := 16           # angular cells per render chunk side

const DENSITY_STEP := 2         # 1 = true 1:1; 2 = the approved look
const ELEV_SCALE := 2.0         # radial exaggeration of relief (also the layer thickness)
const SIDE_DIM := 0.8           # side walls a touch darker than tops
const RELIEF_MAX := 15          # max terrain relief in voxel-depth steps (0..15)

# Shell thickness in blocks: water is a single glass pane; land is a few blocks deep
# before the hollow interior (the owner wants ~3-5).
const WATER_DEPTH := 1
const LAND_DEPTH := 4

const CORE_R := 4.0                          # radius where the core begins
const CORE_COLOR := Color(1.0, 0.92, 0.55)   # bright sun-yellow centre cube (glows)
const _LAND_FALLBACK := Color(0.30, 0.45, 0.25)  # default land green (no land texel found)

# Glass vertex-colour flags. The glass shader ignores the tint vertex colour (it uses
# its own uniform) and instead reads COLOR.r as a "this is the TOP pane" flag so the
# faint surface etch is drawn on tops only, not the bottom/side panes.
const _GLASS_TOP := Color(1.0, 1.0, 1.0, 1.0)
const _GLASS_SIDE := Color(0.0, 0.0, 0.0, 1.0)

var _inner_r: float = 64.0
var _res: int = 256
var _chunks_per_edge: int = 16
var _voxel_size: float = 0.5

var _ang: int = 128
var _chunks_side: int = 8
var _layer_h: float = 0.5
var _base_layers: int = 0       # full layers from the core up to _inner_r
var _total_layers: int = 0      # base + RELIEF_MAX + 1

# Per-angular-cell shell band [bottom, top) and water flag (6*_ang*_ang). A cell
# (face,c,r,L) is solid iff bottom <= L < top and not dug.
var _top_layer := PackedInt32Array()
var _bottom_layer := PackedInt32Array()
var _is_water := PackedByteArray()
var _dug := {}

var _chunk_lo := PackedInt32Array()
var _chunk_hi := PackedInt32Array()
var _chunk_nodes := {}          # chunk index → {"op_mesh","op_col","gl_mesh","gl_col"}

# Pass-1 full-res maps (kept only long enough to fill the shell arrays).
var _heights: Array = []
var _mats: Array = []

var _mat: ShaderMaterial        # opaque land blocks (inner_globe_blocks.gdshader)
var _glass_mat: ShaderMaterial  # water glass blocks (inner_globe_glass.gdshader)
var _biome_img: Image = null
var _biw := 0
var _bih := 0
var _built := false
var _glass_enabled := true   # water-glass toggle (player KEY_G): visible + collidable


func setup(inner_r: float, res: int, chunks_per_edge: int) -> void:
	_inner_r = inner_r
	_res = res
	_chunks_per_edge = chunks_per_edge
	_voxel_size = (inner_r / float(res)) * ELEV_SCALE
	_layer_h = _voxel_size
	_ang = res / DENSITY_STEP
	_chunks_side = _ang / CHUNK_ANG
	_base_layers = int(floor((inner_r - CORE_R) / _layer_h))
	_total_layers = _base_layers + RELIEF_MAX + 1

	_mat = ShaderMaterial.new()
	_mat.shader = load("res://shaders/inner_globe_blocks.gdshader") as Shader
	_glass_mat = ShaderMaterial.new()
	_glass_mat.shader = load("res://shaders/inner_globe_glass.gdshader") as Shader

	var tex := load("res://planet/earth_biome_map.png") as Texture2D
	if tex:
		_biome_img = tex.get_image()
		if _biome_img:
			_biw = _biome_img.get_width()
			_bih = _biome_img.get_height()

	add_to_group("inner_globe_voxels")
	visible = true


func is_built() -> bool:
	return _built


# Outer extent — player.gd uses it to decide whether a dig lands here, and
# planet_generator sizes the loading-screen smooth globe to enclose it.
func surface_radius() -> float:
	return CORE_R + float(_total_layers) * _layer_h


func get_block_material() -> ShaderMaterial:
	return _mat


func get_glass_material() -> ShaderMaterial:
	return _glass_mat


# Turn the water glass OFF (hidden AND non-collidable, so you fall straight through the
# water without breaking blocks) or back ON. The state is remembered so chunks remeshed
# after a dig come back in the right visibility/collision.
func set_glass_enabled(on: bool) -> void:
	_glass_enabled = on
	for ci in _chunk_nodes:
		var node: Dictionary = _chunk_nodes[ci]
		if node.has("gl_mesh") and node["gl_mesh"]:
			node["gl_mesh"].visible = on
		if node.has("gl_col") and node["gl_col"]:
			node["gl_col"].disabled = not on


func is_glass_enabled() -> bool:
	return _glass_enabled


func build() -> void:
	if _built:
		return
	_built = true
	# Per-phase CPU timing (excludes the inter-frame awaits) so the load-time profiling
	# in the queue can see where the inner-globe build actually spends its time.
	const TOTAL_STEPS := 12  # 6 face computes + 6 face mesh passes (one await each)
	var step := 0
	var compute_ms := 0
	var mesh_ms := 0
	_heights.resize(6)
	_mats.resize(6)
	for face in 6:
		var s := Time.get_ticks_msec()
		_compute_face(face)
		compute_ms += Time.get_ticks_msec() - s
		step += 1
		build_progress.emit(step, TOTAL_STEPS)
		await get_tree().process_frame
	var shell_s := Time.get_ticks_msec()
	_build_shell()
	_heights = []
	_mats = []
	_make_center_cube()
	var shell_ms := Time.get_ticks_msec() - shell_s
	for face in 6:
		var s := Time.get_ticks_msec()
		for ccx in _chunks_side:
			for ccy in _chunks_side:
				_build_chunk(face, ccx, ccy)
		mesh_ms += Time.get_ticks_msec() - s
		step += 1
		build_progress.emit(step, TOTAL_STEPS)
		await get_tree().process_frame
	print(
		"[inner_globe] compute_faces=%dms  build_shell=%dms  mesh_chunks=%dms  (CPU work, excl. awaits)"
		% [compute_ms, shell_ms, mesh_ms]
	)


# Pass 1: fill _heights[face] / _mats[face] from the outer chunk caches.
func _compute_face(face: int) -> void:
	var res := _res
	var heights := PackedInt32Array()
	heights.resize(res * res)
	heights.fill(-1)
	var mats := PackedByteArray()
	mats.resize(res * res)
	mats.fill(0)

	for cx in _chunks_per_edge:
		for cy in _chunks_per_edge:
			var data := ChunkLoader.load(face, cx, cy)
			if data.is_empty():
				continue
			for lc in CHUNK_SIZE:
				for lr in CHUNK_SIZE:
					var top_any := -1
					var top_mat := 0
					for d in CHUNK_SIZE:
						var m := ChunkLoader.voxel(data, lc, lr, d)
						if m == 0:
							continue
						top_any = d
						top_mat = m
					if top_any < 0:
						continue
					var idx := (cx * CHUNK_SIZE + lc) * res + (cy * CHUNK_SIZE + lr)
					mats[idx] = top_mat
					heights[idx] = 0 if top_mat == 2 else top_any

	_heights[face] = heights
	_mats[face] = mats


# Downsample to the angular grid → shell band [bottom, top) + water flag, then each
# render-chunk's [lo, hi) scan range. Gaps (-1) become flat land (closes seams).
func _build_shell() -> void:
	var n := 6 * _ang * _ang
	_top_layer.resize(n)
	_bottom_layer.resize(n)
	_is_water.resize(n)
	for face in 6:
		var heights: PackedInt32Array = _heights[face]
		var mats: PackedByteArray = _mats[face]
		for c in _ang:
			for r in _ang:
				var si := (c * DENSITY_STEP) * _res + (r * DENSITY_STEP)
				var h := heights[si]
				var water := mats[si] == 2
				if h < 0:
					h = 0  # gap → flat land
				var top := _base_layers + (0 if water else h)
				var depth := WATER_DEPTH if water else LAND_DEPTH
				var bottom := maxi(0, top - depth)
				var ci := (face * _ang + c) * _ang + r
				_top_layer[ci] = top
				_bottom_layer[ci] = bottom
				_is_water[ci] = 1 if water else 0

	var nchunks := 6 * _chunks_side * _chunks_side
	_chunk_lo.resize(nchunks)
	_chunk_hi.resize(nchunks)
	for face in 6:
		for ccx in _chunks_side:
			for ccy in _chunks_side:
				var c0 := ccx * CHUNK_ANG
				var r0 := ccy * CHUNK_ANG
				var min_b := _total_layers
				var max_t := 0
				for c in range(c0, c0 + CHUNK_ANG):
					for r in range(r0, r0 + CHUNK_ANG):
						var idx := (face * _ang + c) * _ang + r
						if _bottom_layer[idx] < min_b:
							min_b = _bottom_layer[idx]
						if _top_layer[idx] > max_t:
							max_t = _top_layer[idx]
				var ci := _chunk_index(face, ccx, ccy)
				_chunk_lo[ci] = maxi(0, min_b)
				_chunk_hi[ci] = mini(_total_layers, max_t)


# --- occupancy -------------------------------------------------------------------

func _tl(face: int, c: int, r: int) -> int:
	return _top_layer[(face * _ang + c) * _ang + r]


func _bl(face: int, c: int, r: int) -> int:
	return _bottom_layer[(face * _ang + c) * _ang + r]


func _dug_key(face: int, c: int, r: int, L: int) -> int:
	return ((face * _ang + c) * _ang + r) * _total_layers + L


# Solidity of a cell in the shell band, wrapping across cube-face seams.
func _cell_solid(face: int, c: int, r: int, L: int) -> bool:
	if L < 0 or L >= _total_layers:
		return false
	if c < 0 or c >= _ang or r < 0 or r >= _ang:
		var u := (float(c) + 0.5) / float(_ang)
		var v := (float(r) + 0.5) / float(_ang)
		var dir := CubeFace.face_uv_to_unit(face, u, v)
		var fcr := CubeFace.unit_to_face_col_row(dir, _ang)
		face = int(fcr[0])
		c = int(fcr[1])
		r = int(fcr[2])
	if L < _bl(face, c, r) or L >= _tl(face, c, r):
		return false
	return not _dug.has(_dug_key(face, c, r, L))


# Is the cell's column water (glass)? Wraps across cube-face seams.
func _is_water_at(face: int, c: int, r: int) -> bool:
	if c < 0 or c >= _ang or r < 0 or r >= _ang:
		var u := (float(c) + 0.5) / float(_ang)
		var v := (float(r) + 0.5) / float(_ang)
		var dir := CubeFace.face_uv_to_unit(face, u, v)
		var fcr := CubeFace.unit_to_face_col_row(dir, _ang)
		face = int(fcr[0])
		c = int(fcr[1])
		r = int(fcr[2])
	return _is_water[(face * _ang + c) * _ang + r] == 1


# Solid AND opaque (land) — transparent glass cells don't count, so a land face next to
# glass still renders (no see-through at the land/water boundary).
func _solid_opaque(face: int, c: int, r: int, L: int) -> bool:
	return _cell_solid(face, c, r, L) and not _is_water_at(face, c, r)


# --- digging ---------------------------------------------------------------------

# Remove the cell containing the aim hit. `normal` is the surface normal at the hit, so
# we step half a block inward to land cleanly inside the target cell (robust for the
# thin shell). Returns true if a solid cell was cleared.
func dig_at(world_pos: Vector3, normal: Vector3) -> bool:
	var p := world_pos - normal * (_layer_h * 0.5)
	var rel := p - global_position
	var r := rel.length()
	var L := int(floor((r - CORE_R) / _layer_h))
	if L < 0 or L >= _total_layers:
		return false
	var fcr := CubeFace.unit_to_face_col_row(rel.normalized(), _ang)
	return _dig_cell(int(fcr[0]), int(fcr[1]), int(fcr[2]), L)


# Remove the single topmost solid cell along `dir` (the dig-underfoot key, one block).
func dig_top(dir: Vector3) -> bool:
	var fcr := CubeFace.unit_to_face_col_row(dir.normalized(), _ang)
	var face := int(fcr[0])
	var c := int(fcr[1])
	var r := int(fcr[2])
	for L in range(_tl(face, c, r) - 1, -1, -1):
		if _dig_cell(face, c, r, L):
			return true
	return false


func _dig_cell(face: int, c: int, r: int, L: int) -> bool:
	if not _cell_solid(face, c, r, L):
		return false
	_dug[_dug_key(face, c, r, L)] = true
	var chunks := {}
	chunks[_chunk_of(face, c, r)] = true
	chunks[_chunk_of(face, c + 1, r)] = true
	chunks[_chunk_of(face, c - 1, r)] = true
	chunks[_chunk_of(face, c, r + 1)] = true
	chunks[_chunk_of(face, c, r - 1)] = true
	for ci in chunks:
		_chunk_lo[ci] = clampi(mini(_chunk_lo[ci], L - 1), 0, _total_layers)
		_build_chunk_ci(ci)
	return true


# --- chunk indexing --------------------------------------------------------------

func _chunk_index(face: int, ccx: int, ccy: int) -> int:
	return (face * _chunks_side + ccx) * _chunks_side + ccy


func _chunk_of(face: int, c: int, r: int) -> int:
	if c < 0 or c >= _ang or r < 0 or r >= _ang:
		var u := (float(c) + 0.5) / float(_ang)
		var v := (float(r) + 0.5) / float(_ang)
		var dir := CubeFace.face_uv_to_unit(face, u, v)
		var fcr := CubeFace.unit_to_face_col_row(dir, _ang)
		face = int(fcr[0])
		c = int(fcr[1])
		r = int(fcr[2])
	return _chunk_index(face, c / CHUNK_ANG, r / CHUNK_ANG)


# --- meshing ---------------------------------------------------------------------

func _make_center_cube() -> void:
	var s := CORE_R * 2.0
	var box := BoxMesh.new()
	box.size = Vector3(s, s, s)
	# A glowing "sun" cube: strong HDR emission so it reads as a light source (and blooms
	# if glow is on). A co-located OmniLight (planet_generator) does the actual cavern
	# lighting. Room to add solar-flare later.
	var bmat := StandardMaterial3D.new()
	bmat.albedo_color = CORE_COLOR
	bmat.emission_enabled = true
	bmat.emission = CORE_COLOR
	bmat.emission_energy_multiplier = 6.0
	var inst := MeshInstance3D.new()
	inst.mesh = box
	inst.material_override = bmat
	add_child(inst)
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(s, s, s)
	col.shape = shape
	add_child(col)


func _build_chunk_ci(ci: int) -> void:
	var per_face := _chunks_side * _chunks_side
	var face := ci / per_face
	var rem := ci % per_face
	_build_chunk(face, rem / _chunks_side, rem % _chunks_side)


func _build_chunk(face: int, ccx: int, ccy: int) -> void:
	var ci := _chunk_index(face, ccx, ccy)
	var old: Variant = _chunk_nodes.get(ci)
	if old != null:
		for k in ["op_mesh", "op_col", "gl_mesh", "gl_col"]:
			if old.has(k) and old[k]:
				old[k].queue_free()
		_chunk_nodes.erase(ci)

	var lo := _chunk_lo[ci]
	var hi := _chunk_hi[ci]
	var c0 := ccx * CHUNK_ANG
	var r0 := ccy * CHUNK_ANG

	var st_op := SurfaceTool.new()
	st_op.begin(Mesh.PRIMITIVE_TRIANGLES)
	var st_gl := SurfaceTool.new()
	st_gl.begin(Mesh.PRIMITIVE_TRIANGLES)
	for c in range(c0, c0 + CHUNK_ANG):
		for r in range(r0, r0 + CHUNK_ANG):
			var water := _is_water[(face * _ang + c) * _ang + r] == 1
			for L in range(lo, hi):
				if not _cell_solid(face, c, r, L):
					continue
				_emit_cell(st_gl if water else st_op, face, c, r, L, water)

	var node := {}
	_commit_surface(st_op, _mat, node, "op")
	_commit_surface(st_gl, _glass_mat, node, "gl")
	# Honor the current glass toggle for freshly (re)meshed chunks (e.g. after a dig).
	if not _glass_enabled and node.has("gl_mesh"):
		node["gl_mesh"].visible = false
		node["gl_col"].disabled = true
	if not node.is_empty():
		_chunk_nodes[ci] = node


func _commit_surface(st: SurfaceTool, mat: ShaderMaterial, node: Dictionary, prefix: String) -> void:
	var mesh := st.commit()
	if mesh == null or mesh.get_surface_count() == 0:
		return
	var inst := MeshInstance3D.new()
	inst.mesh = mesh
	inst.material_override = mat
	add_child(inst)
	var shape := mesh.create_trimesh_shape()
	shape.backface_collision = true
	var col := CollisionShape3D.new()
	col.shape = shape
	add_child(col)
	node[prefix + "_mesh"] = inst
	node[prefix + "_col"] = col


func _emit_cell(st: SurfaceTool, face: int, c: int, r: int, L: int, water: bool) -> void:
	var r_in := CORE_R + float(L) * _layer_h
	var r_out := r_in + _layer_h
	var dir_c := CubeFace.face_uv_to_unit(face, (float(c) + 0.5) / _ang, (float(r) + 0.5) / _ang)
	var cell_center := dir_c * (r_out + r_in) * 0.5

	# Water = a tinted glass block. Double-sided (top + bottom panes). The grid frame is
	# on the TOP (true) but NOT the bottom (false): the glass is transparent, so a bottom
	# grid would show through the top from the surface (the "Gingham" look). SIDE faces
	# DO get the grid (true) — in the undug shell water is surrounded by solid neighbours
	# so no side renders, but once you break a water block the adjacent blocks' exposed
	# sides appear, and we want their edges to read. The glass shader uses its own tint
	# uniform, so the vertex colour is unused.
	if water:
		# Top pane carries _GLASS_TOP so the shader etches only its surface; bottom +
		# sides carry _GLASS_SIDE (no etch).
		if not _cell_solid(face, c, r, L + 1):
			_emit_radial_quad(st, face, c, r, r_out, _GLASS_TOP, cell_center, true)
		if not _cell_solid(face, c, r, L - 1):
			_emit_radial_quad(st, face, c, r, r_in, _GLASS_SIDE, cell_center, false)
		if not _cell_solid(face, c + 1, r, L):
			_emit_side(st, face, float(c + 1) / _ang, float(r) / _ang, float(r + 1) / _ang, true, r_out, r_in, _GLASS_SIDE, cell_center, true)
		if not _cell_solid(face, c - 1, r, L):
			_emit_side(st, face, float(c) / _ang, float(r) / _ang, float(r + 1) / _ang, true, r_out, r_in, _GLASS_SIDE, cell_center, true)
		if not _cell_solid(face, c, r + 1, L):
			_emit_side(st, face, float(r + 1) / _ang, float(c) / _ang, float(c + 1) / _ang, false, r_out, r_in, _GLASS_SIDE, cell_center, true)
		if not _cell_solid(face, c, r - 1, L):
			_emit_side(st, face, float(r) / _ang, float(c) / _ang, float(c + 1) / _ang, false, r_out, r_in, _GLASS_SIDE, cell_center, true)
		return

	var color := _land_color(face, (float(c) + 0.5) / _ang, (float(r) + 0.5) / _ang)
	var side := Color(color.r * SIDE_DIM, color.g * SIDE_DIM, color.b * SIDE_DIM, color.a)

	# Land faces render unless the neighbour is solid AND OPAQUE (another land cell). A
	# transparent glass (water) neighbour does NOT cull the land's face — otherwise the
	# land looks see-through where it meets the glass (the "glass bisects the land" bug).
	if not _solid_opaque(face, c, r, L + 1):
		_emit_radial_quad(st, face, c, r, r_out, color, cell_center, true)
	if not _solid_opaque(face, c, r, L - 1):
		_emit_radial_quad(st, face, c, r, r_in, color, cell_center, true)

	if not _solid_opaque(face, c + 1, r, L):
		_emit_side(st, face, float(c + 1) / _ang, float(r) / _ang, float(r + 1) / _ang, true, r_out, r_in, side, cell_center, true)
	if not _solid_opaque(face, c - 1, r, L):
		_emit_side(st, face, float(c) / _ang, float(r) / _ang, float(r + 1) / _ang, true, r_out, r_in, side, cell_center, true)
	if not _solid_opaque(face, c, r + 1, L):
		_emit_side(st, face, float(r + 1) / _ang, float(c) / _ang, float(c + 1) / _ang, false, r_out, r_in, side, cell_center, true)
	if not _solid_opaque(face, c, r - 1, L):
		_emit_side(st, face, float(r) / _ang, float(c) / _ang, float(c + 1) / _ang, false, r_out, r_in, side, cell_center, true)


func _emit_radial_quad(
	st: SurfaceTool, face: int, c: int, r: int, radius: float, color: Color, cell_center: Vector3, grid: bool
) -> void:
	var u0 := float(c) / _ang
	var u1 := float(c + 1) / _ang
	var v0 := float(r) / _ang
	var v1 := float(r + 1) / _ang
	var p0 := CubeFace.face_uv_to_unit(face, u0, v0) * radius
	var p1 := CubeFace.face_uv_to_unit(face, u1, v0) * radius
	var p2 := CubeFace.face_uv_to_unit(face, u1, v1) * radius
	var p3 := CubeFace.face_uv_to_unit(face, u0, v1) * radius
	_emit_quad(st, color, p0, p1, p2, p3, cell_center, grid)


func _emit_side(
	st: SurfaceTool, face: int, fixed: float, a: float, b: float, along_u: bool,
	r_out: float, r_in: float, color: Color, cell_center: Vector3, grid: bool
) -> void:
	var d0: Vector3
	var d1: Vector3
	if along_u:
		d0 = CubeFace.face_uv_to_unit(face, fixed, a)
		d1 = CubeFace.face_uv_to_unit(face, fixed, b)
	else:
		d0 = CubeFace.face_uv_to_unit(face, a, fixed)
		d1 = CubeFace.face_uv_to_unit(face, b, fixed)
	_emit_quad(st, color, d0 * r_out, d1 * r_out, d1 * r_in, d0 * r_in, cell_center, grid)


# Emit one quad. With grid=true the corners carry UV 0..1 so the shader draws block
# edges; with grid=false every vertex gets UV (0.5,0.5), inside the edge band, so no
# edge is drawn (used for glass bottom/sides — the frame stays top-only).
func _emit_quad(
	st: SurfaceTool, color: Color, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, cell_center: Vector3, grid: bool
) -> void:
	st.set_color(color)
	var c := Vector2(0.5, 0.5)
	var uv0 := Vector2(0, 0) if grid else c
	var uv1 := Vector2(1, 0) if grid else c
	var uv2 := Vector2(1, 1) if grid else c
	var uv3 := Vector2(0, 1) if grid else c
	var outward := (p0 + p1 + p2 + p3) * 0.25 - cell_center
	if (p1 - p0).cross(p2 - p0).dot(outward) >= 0.0:
		_v(st, p0, uv0)
		_v(st, p1, uv1)
		_v(st, p2, uv2)
		_v(st, p0, uv0)
		_v(st, p2, uv2)
		_v(st, p3, uv3)
	else:
		_v(st, p0, uv0)
		_v(st, p2, uv2)
		_v(st, p1, uv1)
		_v(st, p0, uv0)
		_v(st, p3, uv3)
		_v(st, p2, uv2)


func _v(st: SurfaceTool, p: Vector3, uv: Vector2) -> void:
	st.set_uv(uv)
	st.add_vertex(p)


# Colour for a LAND cell. The cell IS land (ChunkLoader's top voxel), but the biome
# texture can read ocean-blue at it (cube-sphere vs equirect misalignment near coasts,
# or map lakes/rivers) — which made stray blue blocks on the continents. So if the
# centre texel looks like water, search outward for the nearest land texel and use that
# (keeps the real biome shade), falling back to a default green.
func _land_color(face: int, u: float, v: float) -> Color:
	if _biome_img == null:
		return _LAND_FALLBACK
	var px := _tex_x(face, u, v)
	var py := _tex_y(face, u, v)
	var base := _biome_img.get_pixel(px, py)
	if not _is_water_color(base):
		return base
	for ring in range(1, 6):
		for dy in range(-ring, ring + 1):
			for dx in range(-ring, ring + 1):
				if maxi(absi(dx), absi(dy)) != ring:
					continue
				var sx := clampi(px + dx, 0, _biw - 1)
				var sy := clampi(py + dy, 0, _bih - 1)
				var col := _biome_img.get_pixel(sx, sy)
				if not _is_water_color(col):
					return col
	return _LAND_FALLBACK


# A biome texel reads as ocean/water if it's clearly blue-dominant AND dark. Ocean
# (mat 2 ≈ 26,89,166) is dark blue (luminance ≈ 0.31); bluish-white snow/ice (mat 6 ≈
# 230,237,247) is also technically b>g>r but very bright (luminance ≈ 0.93), so without
# the luminance gate the ice caps got misflagged as water and recoloured to land green.
func _is_water_color(col: Color) -> bool:
	var lum := 0.299 * col.r + 0.587 * col.g + 0.114 * col.b
	return lum < 0.6 and col.b > col.g and col.b > col.r


# Equirect texel coords for a face cell (render_map.py projection), split out so
# _land_color can sample neighbouring texels.
func _tex_x(face: int, u: float, v: float) -> int:
	var dir := CubeFace.face_uv_to_unit(face, u, v)
	var lon := atan2(-dir.z, dir.x)
	return int(clamp((lon * 0.15915494 + 0.5) * float(_biw), 0.0, float(_biw - 1)))


func _tex_y(face: int, u: float, v: float) -> int:
	var dir := CubeFace.face_uv_to_unit(face, u, v)
	var lat := asin(clamp(dir.y, -1.0, 1.0))
	return int(clamp((0.5 - lat * 0.31830989) * float(_bih), 0.0, float(_bih - 1)))
