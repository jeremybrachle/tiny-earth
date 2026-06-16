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

var resolution: int     = 256
var planet_radius: float = 256.0
var chunks_per_edge: int = 16

var _faces: Array = []   # all 12 shell faces (6 outer CubeFace + 6 inner InnerCubeFace)

func _ready() -> void:
	var cfg := _load_planet_config()
	resolution      = cfg.get("resolution",     256)
	planet_radius   = cfg.get("planet_radius",  float(resolution))
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
		cf.face_id       = face
		cf.chunks_per_edge = chunks_per_edge
		cf.planet_radius = planet_radius
		cf.name = "CubeFace_%d" % face
		add_child(cf)
		_faces.append(cf)

	for face in 6:
		var icf := preload("res://scripts/planet/inner_cube_face.gd").new()
		icf.face_id        = face
		icf.chunks_per_edge = chunks_per_edge
		icf.planet_radius  = planet_radius
		icf.name = "InnerCubeFace_%d" % face
		add_child(icf)
		_faces.append(icf)


# Orchestrated, frame-spread build. Phases:
#   1. init + load every face's chunk data (cross-face seam culling needs ALL
#      data present before any meshing), yielding a frame per face.
#   2. mesh + collide every chunk in one global list, ordered spiral-out from
#      `spawn_pos`, CHUNKS_PER_FRAME per frame — each chunk pops in as it builds.
#   3. rebuild cross-face seam edges now that all neighbours exist.
# Emits build_progress throughout and build_finished at the end.
func build_planet_async(spawn_pos: Vector3) -> void:
	# Phase 1 — init + load.
	build_phase.emit("Loading terrain data…")
	for f in _faces:
		f.init_face()
		f.load_chunks()
		await get_tree().process_frame

	# Phase 2 — collect every loaded chunk, sort by distance from spawn (spiral
	# out: the spawn point blooms first), then mesh in batches.
	var tasks: Array = []
	for f in _faces:
		for cx in chunks_per_edge:
			for cy in chunks_per_edge:
				if f.has_chunk(cx, cy):
					var d: float = spawn_pos.distance_squared_to(f.chunk_world_center(cx, cy))
					tasks.append({"f": f, "cx": cx, "cy": cy, "d": d})
	tasks.sort_custom(func(a, b): return a["d"] < b["d"])

	build_phase.emit("Raising continents & oceans…")
	var total: int = tasks.size()
	var done := 0
	for t in tasks:
		t["f"].build_chunk(t["cx"], t["cy"])
		done += 1
		if done % CHUNKS_PER_FRAME == 0:
			build_progress.emit(done, total)
			await get_tree().process_frame
	build_progress.emit(total, total)

	# Phase 3 — cross-face seam edges (all neighbour data now loaded).
	build_phase.emit("Stitching seams…")
	for f in _faces:
		f.rebuild_seam_edges()
		await get_tree().process_frame

	build_finished.emit()


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
