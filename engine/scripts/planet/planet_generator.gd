class_name PlanetGenerator
extends Node3D

# Single staged planet generator — "one generator, not separate systems."
# generate_planet(stage_id) progressively enables features; stage N enables 0..N
# (fall-through). This round implements stages 0 and 1; stages 2-7 are documented,
# explicit not-yet-implemented branches.
#
#   stage 0 : inner sphere + radial gravity (TOTK Depths style — no inversion)
#   stage 1 : hollow cavity open air; same radial gravity throughout
#   stage 2 : shell 0 (lowest mineable voxel shell)
#   stage 3 : all 3 shells + boundary stitching
#   stage 4 : bathymetry carved into shell 2
#   stage 5 : continent land/sea mask
#   stage 6 : water fill to sea level (debug slider)
#   stage 7 : semantic compression layer (landmarks, scoring)
#
# The generator is additive: it runs alongside the existing outer VoxelPlanet and
# adds the inner-world subsystems. It registers in the "gravity_field" group so the
# player can query gravity_direction() without a hard dependency.

const _CONFIG_PATH := "res://planet/planet_config.json"
const DEFAULT_STAGE := 1

# Inner sphere radius as a fraction of the outer planet radius (ADR-001: 96/512 ≈ 0.1875;
# rounded to 0.25 here so the core is comfortably reachable below the inner-shell floor).
const INNER_RADIUS_FRACTION := 0.25

var _planet_radius: float = 512.0
var _inner_r: float = 128.0
var active_stage: int = 0


func setup(planet_radius: float) -> void:
	_planet_radius = planet_radius
	_inner_r = planet_radius * INNER_RADIUS_FRACTION


# Read the active generation stage from planet_config.json, falling back to
# DEFAULT_STAGE when the file or field is absent (the field is gitignored/regenerated).
func read_generation_stage() -> int:
	if not FileAccess.file_exists(_CONFIG_PATH):
		return DEFAULT_STAGE
	var f := FileAccess.open(_CONFIG_PATH, FileAccess.READ)
	if not f:
		return DEFAULT_STAGE
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if parsed is Dictionary and (parsed as Dictionary).has("generation_stage"):
		return int((parsed as Dictionary)["generation_stage"])
	return DEFAULT_STAGE


func generate_planet(stage_id: int) -> void:
	active_stage = stage_id
	add_to_group("gravity_field")
	print("PlanetGenerator: generating at stage %d (radius=%.1f, inner_r=%.1f)" % [
		stage_id, _planet_radius, _inner_r
	])

	# Fall-through: stage N enables everything up to N.
	if stage_id >= 0:
		_build_inner_sphere()  # stage 0 geometry
	# stage 1: hollow cavity is open air between inner-shell floor and inner sphere.
	# Gravity is always radial (toward origin); no blend, no inversion.
	if stage_id >= 2:
		push_warning("PlanetGenerator: stage 2 (shell 0) not yet implemented")
	if stage_id >= 3:
		push_warning("PlanetGenerator: stage 3 (3 shells + boundary stitching) not yet implemented")
	if stage_id >= 4:
		push_warning("PlanetGenerator: stage 4 (bathymetry) not yet implemented")
	if stage_id >= 5:
		push_warning("PlanetGenerator: stage 5 (land/sea mask) not yet implemented")
	if stage_id >= 6:
		push_warning("PlanetGenerator: stage 6 (water fill) not yet implemented")
	if stage_id >= 7:
		push_warning("PlanetGenerator: stage 7 (semantic compression) not yet implemented")


# Stage 0 — a visible, walkable sphere at the planet origin, lit from the core so
# it reads from inside the hollow. Radial gravity (already in player.gd) holds the
# player on its outer surface once the collider exists.
#
# TODO (later stage): mirror the outer Earth map onto this surface, inverted
# (TOTK Depths: dig under Florida → land on inverted Florida). Requires the land/sea
# mask (stage 5+) applied to the inner shell; the exact transform (same face/col/row
# with elevation inverted vs. antipodal) is to be resolved when that stage is built.
func _build_inner_sphere() -> void:
	var inner := StaticBody3D.new()
	inner.name = "InnerPlanet"

	var mesh_inst := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = _inner_r
	sphere.height = _inner_r * 2.0
	mesh_inst.mesh = sphere
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var img := Image.load_from_file("res://planet/earth_biome_map.png")
	if img:
		mat.albedo_color = Color.WHITE
		mat.albedo_texture = ImageTexture.create_from_image(img)
	else:
		mat.albedo_color = Color(0.45, 0.42, 0.40)
	mesh_inst.material_override = mat
	# SphereMesh UV seam is at local -Z. With +90° Y, local -Z → world -X = lon 180°
	# which matches the antimeridian (left/right edge of our equirectangular texture).
	# Adjust rotation_degrees.y if continents appear rotated; use 45° increments.
	mesh_inst.rotation_degrees = Vector3(0.0, 270.0, 0.0)
	inner.add_child(mesh_inst)

	var col := CollisionShape3D.new()
	var shape := SphereShape3D.new()
	shape.radius = _inner_r
	col.shape = shape
	inner.add_child(col)

	add_child(inner)

	# Light the hollow cavity from the core.
	var light := OmniLight3D.new()
	light.omni_range = _planet_radius
	light.light_energy = 5.0
	add_child(light)


# Gravity always pulls toward the origin regardless of stage or position.
# The hollow cavity is open air — the player digs through the crust, falls in,
# and lands on the inner sphere under the same radial gravity (TOTK Depths style).
func gravity_direction(pos: Vector3) -> Vector3:
	return -pos / maxf(pos.length(), 0.0001)
