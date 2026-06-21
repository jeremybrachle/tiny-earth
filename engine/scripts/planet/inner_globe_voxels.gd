extends StaticBody3D

# A blocky voxel "skin" for the inner mini-globe that maps 1:1 to the real surface
# and is coloured to MATCH THE LOADING-SCREEN GLOBE exactly:
#   • every cell's colour is sampled straight from earth_biome_map.png by geographic
#     lat/lon (the same texture + projection main_menu.gd's globe uses), land AND
#     water alike — no custom palette here (the dark-water tones live in
#     inner_globe.gdshader / docs/HANDOFF.md for reference, tunable later in F3).
#   • elevation + land/ocean come from the outer chunk caches (ChunkLoader.load —
#     the very bytes CubeFace meshes): a cell is WATER if its topmost voxel is
#     water (flat at the base radius, NO bathymetry), else LAND raised by its
#     top voxel's depth.
#   • BRIGHTNESS dims the whole skin well below the raw texture so it reads in the
#     dark cavern instead of glowing.
#
# It is a heightmap skin, not a full volume, sitting on top of the smooth globe. The
# skin is unbreakable (digging only targets CubeFace / InnerCubeFace nodes) and ALWAYS
# ON — it's the inner-globe look. Built as the FIRST loading-screen step
# (planet_generator.build_inner_voxels) in two passes (all six faces' height maps
# first, then meshing) so cross-face seam walls resolve; a frame is yielded per face
# so it never hitches mid-game.

const CHUNK_SIZE := 16

# Overall dim applied to the sampled biome colours (via the material's albedo_color)
# so the skin isn't blindingly bright in the dark cavern. 1.0 = raw loading-globe
# colours. Will be exposed in the F3 tuner later.
const BRIGHTNESS := 0.5

# Voxel density relative to the surface grid. 1 = true 1:1 (one voxel per surface
# cell, ~393k columns); 2 = one voxel per 2x2 block (~98k columns, 4x lighter).
# Bump to 1 for the finest skin once we're happy with the look.
const DENSITY_STEP := 2

# Radial thickness of one elevation step, as a multiple of the natural voxel size
# (inner_r / res). >1 exaggerates relief so mountains read on the small globe.
const ELEV_SCALE := 2.0

var _inner_r: float = 64.0
var _res: int = 256
var _chunks_per_edge: int = 16
var _voxel_size: float = 0.5

var _mat: StandardMaterial3D
var _biome_img: Image = null
var _biw := 0
var _bih := 0
var _built := false

# Per-face surface data, filled in pass 1 (all six faces) before any meshing in
# pass 2, so a face's step walls can read its neighbours' heights ACROSS cube-face
# seams. Each entry is a res*res PackedInt32Array (top elevation in steps, -1 = no
# column) / PackedByteArray (top material), indexed col*res + row.
var _heights: Array = []  # 6 × PackedInt32Array
var _mats: Array = []  # 6 × PackedByteArray


func setup(inner_r: float, res: int, chunks_per_edge: int) -> void:
	_inner_r = inner_r
	_res = res
	_chunks_per_edge = chunks_per_edge
	_voxel_size = (inner_r / float(res)) * ELEV_SCALE

	# Unshaded vertex-colour material: the cavity is dark and the core light sits
	# inside the sphere, so (like the ceiling) the skin must light itself. cull_disabled
	# matches voxel.gdshader (the crust meshes the same winding) — without it the near
	# hemisphere is back-face culled and you see straight through to the far side.
	_mat = StandardMaterial3D.new()
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat.vertex_color_use_as_albedo = true
	_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mat.albedo_color = Color(BRIGHTNESS, BRIGHTNESS, BRIGHTNESS)  # dim for the cavern

	# Biome map for the loading-globe colours, sampled per cell by geographic lat/lon.
	var tex := load("res://planet/earth_biome_map.png") as Texture2D
	if tex:
		_biome_img = tex.get_image()
		if _biome_img:
			_biw = _biome_img.get_width()
			_bih = _biome_img.get_height()

	visible = true  # always-on look


func is_built() -> bool:
	return _built


# Build all six faces in two passes: first every face's height/material map (so a
# face's step walls can read its neighbours across cube-face seams), then the meshing.
# A frame is yielded per face so the skin pops in rather than freezing the game.
func build() -> void:
	if _built:
		return
	_built = true
	_heights.resize(6)
	_mats.resize(6)
	for face in 6:
		_compute_face(face)
		await get_tree().process_frame
	for face in 6:
		_emit_face(face)
		await get_tree().process_frame


# Pass 1: fill _heights[face] / _mats[face] from the outer chunk caches.
func _compute_face(face: int) -> void:
	var res := _res
	var heights := PackedInt32Array()
	heights.resize(res * res)
	heights.fill(-1)  # -1 = no column (skip)
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
					# Topmost voxel OF ANY KIND is the real surface. If it's water the
					# cell is flat (height 0) even when land sits beneath it (lakes,
					# inland seas) — otherwise that land would raise a blue block.
					var top_any := -1
					var top_mat := 0
					for d in CHUNK_SIZE:
						var m := ChunkLoader.voxel(data, lc, lr, d)
						if m == 0:
							continue
						top_any = d  # loop ascends in depth → highest non-air wins
						top_mat = m
					if top_any < 0:
						continue
					var idx := (cx * CHUNK_SIZE + lc) * res + (cy * CHUNK_SIZE + lr)
					mats[idx] = top_mat
					heights[idx] = 0 if top_mat == 2 else top_any

	_heights[face] = heights
	_mats[face] = mats


# Pass 2: mesh one face from its precomputed height/material map.
func _emit_face(face: int) -> void:
	var res := _res
	var heights: PackedInt32Array = _heights[face]
	var mats: PackedByteArray = _mats[face]

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var res_f := float(res)
	var eps := 0.5 / res_f
	var step := DENSITY_STEP

	for col in range(0, res, step):
		for row in range(0, res, step):
			var h := heights[col * res + row]
			if h < 0:
				continue
			var m: int = mats[col * res + row]
			var u0 := col / res_f
			var u1 := float(col + step) / res_f
			var v0 := row / res_f
			var v1 := float(row + step) / res_f
			# Every cell (land + water) takes the biome-map colour at its centre, so
			# the skin matches the loading globe exactly (dimmed by the material).
			var color := _cell_color(face, (u0 + u1) * 0.5, (v0 + v1) * 0.5, m)
			var r_top := _inner_r + float(h) * _voxel_size
			_emit_top(st, face, u0, v0, u1, v1, r_top, color)

			# Step walls where a neighbour column is lower (the blocky relief).
			var side := Color(color.r * 0.65, color.g * 0.65, color.b * 0.65, color.a)
			_maybe_side(st, face, heights, res, col + step, row, h, r_top, u1, v0, u1, v1, 1, 0, eps, side)
			_maybe_side(st, face, heights, res, col - step, row, h, r_top, u0, v1, u0, v0, -1, 0, eps, side)
			_maybe_side(st, face, heights, res, col, row + step, h, r_top, u1, v1, u0, v1, 0, 1, eps, side)
			_maybe_side(st, face, heights, res, col, row - step, h, r_top, u0, v0, u1, v0, 0, -1, eps, side)

	st.generate_normals()
	var mesh := st.commit()
	if mesh == null or mesh.get_surface_count() == 0:
		return

	var inst := MeshInstance3D.new()
	inst.mesh = mesh
	inst.material_override = _mat
	add_child(inst)

	# Collision from the same geometry (trimesh ignores colour) so the bumps are
	# walkable. Always enabled — the skin is the always-on inner-globe surface.
	var shape := mesh.create_trimesh_shape()
	shape.backface_collision = true
	var col_shape := CollisionShape3D.new()
	col_shape.shape = shape
	add_child(col_shape)


# Colour of a land cell, sampled from the biome map by geographic lat/lon (same
# projection as render_map.py / the cavity ceiling), so it matches the loading
# globe. Falls back to the surface palette if the map failed to load.
func _cell_color(face: int, u: float, v: float, m: int) -> Color:
	if _biome_img == null:
		return CubeFace.MAT_COLORS.get(m, Color.WHITE)
	var dir := CubeFace.face_uv_to_unit(face, u, v)
	var lat := asin(clamp(dir.y, -1.0, 1.0))
	var lon := atan2(-dir.z, dir.x)
	var tu := lon * 0.15915494 + 0.5  # 1/(2π)
	var tv := 0.5 - lat * 0.31830989  # 1/π
	var px := int(clamp(tu * float(_biw), 0.0, float(_biw - 1)))
	var py := int(clamp(tv * float(_bih), 0.0, float(_bih - 1)))
	return _biome_img.get_pixel(px, py)


# Emit a step wall down to a neighbour column if that neighbour is lower. The edge
# runs from (ua,va) to (ub,vb); (ddx,ddy) points outward into the neighbour.
func _maybe_side(
	st: SurfaceTool,
	face: int,
	heights: PackedInt32Array,
	res: int,
	ncol: int,
	nrow: int,
	h: int,
	r_top: float,
	ua: float,
	va: float,
	ub: float,
	vb: float,
	ddx: float,
	ddy: float,
	eps: float,
	color: Color
) -> void:
	var res_f := float(res)
	var cell := float(DENSITY_STEP) / res_f
	var u_mid := (ua + ub) * 0.5
	var v_mid := (va + vb) * 0.5

	var nh := h
	if ncol >= 0 and ncol < res and nrow >= 0 and nrow < res:
		var v := heights[ncol * res + nrow]
		if v >= 0:
			nh = v
	else:
		# Cross-face neighbour: map the cell just past the shared edge to its real
		# face/col/row (via the sphere direction) and read that face's precomputed
		# height, so the seam edge gets a proper wall instead of an invisible gap.
		var ndir := CubeFace.face_uv_to_unit(
			face, u_mid + ddx * cell * 0.5, v_mid + ddy * cell * 0.5
		)
		var fcr := CubeFace.unit_to_face_col_row(ndir, res)
		var nheights: PackedInt32Array = _heights[fcr[0]]
		var v := nheights[int(fcr[1]) * res + int(fcr[2])]
		if v >= 0:
			nh = v
	if nh >= h:
		return
	var r_in := _inner_r + float(nh) * _voxel_size

	var pa_top := CubeFace.face_uv_to_unit(face, ua, va) * r_top
	var pb_top := CubeFace.face_uv_to_unit(face, ub, vb) * r_top
	var pa_base := CubeFace.face_uv_to_unit(face, ua, va) * r_in
	var pb_base := CubeFace.face_uv_to_unit(face, ub, vb) * r_in

	var mid_pt := CubeFace.face_uv_to_unit(face, u_mid, v_mid)
	var out_pt := CubeFace.face_uv_to_unit(face, u_mid + ddx * eps, v_mid + ddy * eps)
	var expected_out := out_pt - mid_pt

	st.set_color(color)
	if (pa_top - pa_base).cross(pb_top - pa_base).dot(expected_out) > 0.0:
		st.add_vertex(pa_base)
		st.add_vertex(pa_top)
		st.add_vertex(pb_top)
		st.add_vertex(pa_base)
		st.add_vertex(pb_top)
		st.add_vertex(pb_base)
	else:
		st.add_vertex(pa_base)
		st.add_vertex(pb_top)
		st.add_vertex(pa_top)
		st.add_vertex(pa_base)
		st.add_vertex(pb_base)
		st.add_vertex(pb_top)


# A radial top quad over one block, normal pointing outward (away from origin).
func _emit_top(
	st: SurfaceTool, face: int, u0: float, v0: float, u1: float, v1: float, r: float, color: Color
) -> void:
	var p00 := CubeFace.face_uv_to_unit(face, u0, v0) * r
	var p10 := CubeFace.face_uv_to_unit(face, u1, v0) * r
	var p01 := CubeFace.face_uv_to_unit(face, u0, v1) * r
	var p11 := CubeFace.face_uv_to_unit(face, u1, v1) * r
	var normal := (p00 + p10 + p01 + p11) * 0.25
	st.set_color(color)
	if (p10 - p00).cross(p11 - p00).dot(normal) > 0.0:
		st.add_vertex(p00)
		st.add_vertex(p10)
		st.add_vertex(p11)
		st.add_vertex(p00)
		st.add_vertex(p11)
		st.add_vertex(p01)
	else:
		st.add_vertex(p00)
		st.add_vertex(p11)
		st.add_vertex(p10)
		st.add_vertex(p00)
		st.add_vertex(p01)
		st.add_vertex(p11)
