extends StaticBody3D

var resolution: int     = 256
var planet_radius: float = 256.0
var chunks_per_edge: int = 16

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

	for face in 6:
		var cf := preload("res://scripts/planet/cube_face.gd").new()
		cf.face_id       = face
		cf.chunks_per_edge = chunks_per_edge
		cf.planet_radius = planet_radius
		cf.name = "CubeFace_%d" % face
		add_child(cf)

	for face in 6:
		var icf := preload("res://scripts/planet/inner_cube_face.gd").new()
		icf.face_id        = face
		icf.chunks_per_edge = chunks_per_edge
		icf.planet_radius  = planet_radius
		icf.name = "InnerCubeFace_%d" % face
		add_child(icf)


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
