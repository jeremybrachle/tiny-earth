extends StaticBody3D

# Emitted while the planet builds (see build_planet_async). `done`/`total` count
# chunks meshed so far; the loading screen drives its ProgressBar from this.
signal build_progress(done: int, total: int)
# A human-readable name for the current build phase, for the loading label.
signal build_phase(label: String)
signal build_finished

# Chunks meshed per frame during the build. 1/frame ≈ 50s (too slow); the
# handoff target is ~10s, so batch several per frame. Tune for the perf/“watch
# it generate” feel: lower = more visibly progressive, higher = faster.
const CHUNKS_PER_FRAME := 6

var resolution: int = 256
var planet_radius: float = 256.0
var chunks_per_edge: int = 16

var _faces: Array = []  # all 12 shell faces (6 outer CubeFace + 6 inner InnerCubeFace)
var _outer_faces: Array = []  # the 6 outer crust faces (surface continents/oceans)
var _inner_faces: Array = []  # the 6 inner shell faces (the hollow interior)


func _ready() -> void:
	# So the F3 cavity tuner (inner_globe_debug.gd) can find us and reach the inner
	# faces' ceiling materials for live city-light tuning.
	add_to_group("voxel_planet")
	var cfg := _load_planet_config()
	resolution = cfg.get("resolution", 256)
	planet_radius = cfg.get("planet_radius", float(resolution))
	chunks_per_edge = cfg.get("chunks_per_edge", resolution / 16)

	# Keep the base sphere collider in sync with the rendered radius so ocean
	# voxels (depth 0, no elevated collision mesh) have a surface to land on.
	var col := get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col and col.shape is SphereShape3D:
		(col.shape as SphereShape3D).radius = planet_radius

	# Instantiate the face nodes but DON'T build them here — their _ready() no
	# longer auto-builds. World calls build_planet_async() so the heavy meshing
	# spreads across frames behind the loading screen.
	for face in 6:
		var cf := preload("res://scripts/planet/cube_face.gd").new()
		cf.face_id = face
		cf.chunks_per_edge = chunks_per_edge
		cf.planet_radius = planet_radius
		cf.name = "CubeFace_%d" % face
		add_child(cf)
		_faces.append(cf)
		_outer_faces.append(cf)

	for face in 6:
		var icf := preload("res://scripts/planet/inner_cube_face.gd").new()
		icf.face_id = face
		icf.chunks_per_edge = chunks_per_edge
		icf.planet_radius = planet_radius
		icf.name = "InnerCubeFace_%d" % face
		add_child(icf)
		_faces.append(icf)
		_inner_faces.append(icf)


# The inner-shell ceiling materials (inner_voxel.gdshader), one per inner face,
# for the F3 cavity tuner to push city-light uniforms across all faces at once.
# Skips faces not yet built (material null during the async build).
func get_inner_materials() -> Array:
	var mats: Array = []
	for f in _inner_faces:
		var m: ShaderMaterial = f.get_ceiling_material()
		if m:
			mats.append(m)
	return mats


# Orchestrated, frame-spread build. Phases:
#   1. init + load every face's chunk data (cross-face seam culling needs ALL
#      data present before any meshing), yielding a frame per face.
#   2. mesh + collide every chunk, ordered spiral-out from `spawn_pos`,
#      CHUNKS_PER_FRAME per frame — surface (outer) shell first, then the hollow
#      interior (inner) shell, so each pops in as it builds.
#   3. rebuild cross-face seam edges now that all neighbours exist.
#
# All three phases drive ONE continuous progress bar via a virtual 0..PROGRESS_SCALE
# range (the loading UI rescales from the emitted done/total). The phases are mapped
# onto fixed slices so the long mesh phase no longer owns the entire percentage:
#   load 0–5%, mesh 5–95% (split between the two shells by their real chunk counts),
#   seam-stitch 95–100%.
func build_planet_async(spawn_pos: Vector3) -> void:
	const PROGRESS_SCALE := 1000
	const LOAD_END := 50  # phase 1 fills 0–5% of the bar
	const MESH_END := 950  # phase 2 fills 5–95%; seams fill the last 5%

	# Phase 1 — init + load (must finish for every face before any meshing).
	build_phase.emit("Loading terrain data…")
	var nf: int = _faces.size()
	for i in nf:
		_faces[i].init_face()
		_faces[i].load_chunks()
		build_progress.emit(int(float(i + 1) / float(maxi(nf, 1)) * LOAD_END), PROGRESS_SCALE)
		await get_tree().process_frame

	# Phase 2 — collect each shell's loaded chunks, sorted spiral-out from spawn
	# (the spawn point blooms first). A single running counter across both shells
	# maps onto the mesh slice, so the bar advances proportionally to real work.
	var outer_tasks := _collect_chunk_tasks(_outer_faces, spawn_pos)
	var inner_tasks := _collect_chunk_tasks(_inner_faces, spawn_pos)
	var n_mesh: int = maxi(outer_tasks.size() + inner_tasks.size(), 1)
	var mesh_span: int = MESH_END - LOAD_END
	var done := 0

	build_phase.emit("Raising continents & oceans…")
	done = await _mesh_tasks(outer_tasks, done, n_mesh, LOAD_END, mesh_span, PROGRESS_SCALE)

	build_phase.emit("Digging out the depths…")
	done = await _mesh_tasks(inner_tasks, done, n_mesh, LOAD_END, mesh_span, PROGRESS_SCALE)
	build_progress.emit(MESH_END, PROGRESS_SCALE)

	# Phase 3 — cross-face seam edges (all neighbour data now loaded).
	build_phase.emit("Stitching seams…")
	for i in nf:
		_faces[i].rebuild_seam_edges()
		build_progress.emit(
			MESH_END + int(float(i + 1) / float(maxi(nf, 1)) * (PROGRESS_SCALE - MESH_END)),
			PROGRESS_SCALE
		)
		await get_tree().process_frame

	build_progress.emit(PROGRESS_SCALE, PROGRESS_SCALE)
	build_finished.emit()


# Collect every loaded chunk on `faces`, ordered spiral-out from `spawn_pos`
# (nearest first), as build tasks for the mesh phase.
func _collect_chunk_tasks(faces: Array, spawn_pos: Vector3) -> Array:
	var tasks: Array = []
	for f in faces:
		for cx in chunks_per_edge:
			for cy in chunks_per_edge:
				if f.has_chunk(cx, cy):
					var d: float = spawn_pos.distance_squared_to(f.chunk_world_center(cx, cy))
					tasks.append({"f": f, "cx": cx, "cy": cy, "d": d})
	tasks.sort_custom(func(a, b): return a["d"] < b["d"])
	return tasks


# Mesh one shell's tasks, CHUNKS_PER_FRAME per frame. `done` is the running chunk
# count across BOTH shells; progress maps it into the mesh slice [base, base+span]
# of the virtual progress range. Returns the updated `done`.
func _mesh_tasks(tasks: Array, done: int, n_mesh: int, base: int, span: int, scale: int) -> int:
	for t in tasks:
		t["f"].build_chunk(t["cx"], t["cy"])
		done += 1
		if done % CHUNKS_PER_FRAME == 0:
			build_progress.emit(base + int(float(done) / float(n_mesh) * span), scale)
			await get_tree().process_frame
	return done


func _load_planet_config() -> Dictionary:
	var path := "res://planet/planet_config.json"
	if not FileAccess.file_exists(path):
		push_warning("planet_config.json not found — using defaults (radius=256, resolution=256)")
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	var result: Variant = JSON.parse_string(f.get_as_text())
	if result == null or not result is Dictionary:
		push_warning("planet_config.json parse failed — using defaults")
		return {}
	return result as Dictionary
