extends CharacterBody3D

const GRAVITY_STRENGTH := 20.0
const WALK_SPEED       := 5.0
const SWIM_SPEED       := 2.5
const JUMP_VELOCITY    := 8.0
const FLY_SPEED        := WALK_SPEED * 5.0

const MOUSE_SENSITIVITY := 0.08  # degrees per pixel
const PITCH_MIN := -89.0
const PITCH_MAX :=  89.0
const TP_DISTANCE := 4.0
const TP_HEIGHT   := 1.6

const _CubeFaceScript = preload("res://scripts/planet/cube_face.gd")

@export var planet: StaticBody3D
@onready var camera: Camera3D = $Camera3D
@onready var player_mesh: MeshInstance3D = $MeshInstance3D

var _first_person := false
var _flying       := false
var _swimming     := false
var _swim_bob     := 0.0   # oscillator for camera bob while swimming
var _yaw:   float = 0.0
var _pitch: float = -15.0
var _surface_right := Vector3(0, 0, 1)  # parallel-transported; avoids pole singularity

var _gravity_field: Node = null   # PlanetGenerator (in group "gravity_field"), looked up lazily
var _water_overlay: ColorRect = null
var _crosshair: Label = null


func _ready() -> void:
	if not planet:
		planet = get_node_or_null("../VoxelPlanet") as StaticBody3D
	if planet:
		var surface_normal := (global_position - planet.global_position).normalized()
		var axis := Vector3.UP.cross(surface_normal)
		if axis.length() > 0.001:
			global_basis = global_basis.rotated(axis.normalized(), Vector3.UP.angle_to(surface_normal))
		# Snap to planet surface so spawn position stays correct regardless of radius_scale.
		var raw_r = planet.get("planet_radius")
		var planet_r: float = float(raw_r) if raw_r != null else 256.0
		global_position = planet.global_position + surface_normal * (planet_r + 1.5)

	var cl := CanvasLayer.new()
	cl.layer = 10
	add_child(cl)
	_water_overlay = ColorRect.new()
	_water_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_water_overlay.color = Color(0.02, 0.10, 0.32, 0.60)
	_water_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_water_overlay.visible = false
	cl.add_child(_water_overlay)

	var hud_cl := CanvasLayer.new()
	hud_cl.layer = 11
	add_child(hud_cl)
	_crosshair = Label.new()
	_crosshair.text = "+"
	_crosshair.set_anchors_preset(Control.PRESET_FULL_RECT)
	_crosshair.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_crosshair.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_crosshair.add_theme_font_size_override("font_size", 24)
	_crosshair.visible = true
	hud_cl.add_child(_crosshair)


func _physics_process(delta: float) -> void:
	if not planet:
		return
	var gravity_dir    := _gravity_dir()
	var surface_normal := -gravity_dir
	up_direction = surface_normal

	# Stateless basis rebuild: surface-aligned with absolute yaw, no accumulated drift.
	# Uses world_up × surface_normal for right (right-handed, consistent with _ready).
	# Project last frame's right onto the current tangent plane (parallel transport).
	# This is stable at all latitudes including poles — no cross-product singularity.
	var right_proj := _surface_right - _surface_right.dot(surface_normal) * surface_normal
	var right := right_proj.normalized() if right_proj.length() > 0.001 \
		else Vector3(1, 0, 0).cross(surface_normal).normalized()
	_surface_right = right
	var forward_dir := surface_normal.cross(right).normalized()
	var yaw_rot := Basis(surface_normal, deg_to_rad(_yaw))
	global_basis = Basis(
		yaw_rot * right,
		surface_normal,
		yaw_rot * (-forward_dir)
	).orthonormalized()

	var cam_fwd   := _project_to_plane(-camera.global_basis.z, surface_normal)
	var cam_right := _project_to_plane( camera.global_basis.x, surface_normal)
	var input := Vector2(
		Input.get_action_strength("ui_right") - Input.get_action_strength("ui_left"),
		Input.get_action_strength("ui_down")  - Input.get_action_strength("ui_up")
	)

	# Only the outer surface has water. Gate the swim check by radius so that
	# standing on the inner sphere (which samples the outer face's material map)
	# never reads as "swimming".
	var planet_r := _planet_radius()
	var near_surface := global_position.length() > planet_r * 0.9
	_swimming = (not _flying) and near_surface and _surface_mat_at(global_position) == 2
	if _water_overlay:
		var cam_dist := camera.global_position.length()
		_water_overlay.visible = cam_dist < planet_r and cam_dist > planet_r * 0.9 \
			and _surface_mat_at(global_position) == 2

	if _flying:
		var fly_dir := cam_fwd * -input.y + cam_right * input.x
		fly_dir += surface_normal * float(Input.is_action_pressed("ui_accept"))   # Space = up
		fly_dir -= surface_normal * float(Input.is_key_pressed(KEY_CTRL))         # Ctrl  = down
		if fly_dir.length() > 0.01:
			global_position += fly_dir.normalized() * FLY_SPEED * delta
		velocity = Vector3.ZERO
		_swim_bob = 0.0
	elif _swimming:
		# Gravity still keeps the player on the sphere surface. Movement is
		# slower and jumping is replaced by a gentle surface-push (wading feel).
		if not is_on_floor():
			velocity += gravity_dir * GRAVITY_STRENGTH * delta

		var wish_dir  := cam_fwd * -input.y + cam_right * input.x
		var vert_vel  := velocity.project(gravity_dir)
		var horiz_vel := velocity - vert_vel

		if wish_dir.length() > 0.01:
			horiz_vel = wish_dir.normalized() * SWIM_SPEED
		else:
			horiz_vel = horiz_vel.lerp(Vector3.ZERO, 0.4)

		velocity = vert_vel + horiz_vel

		if Input.is_action_just_pressed("ui_accept") and is_on_floor():
			velocity += surface_normal * JUMP_VELOCITY

		move_and_slide()

		# Slow oscillating bob for the camera while swimming.
		_swim_bob = fmod(_swim_bob + delta * 1.8, TAU)
	else:
		if not is_on_floor():
			velocity += gravity_dir * GRAVITY_STRENGTH * delta

		var wish_dir  := cam_fwd * -input.y + cam_right * input.x
		var vert_vel  := velocity.project(gravity_dir)
		var horiz_vel := velocity - vert_vel

		if wish_dir.length() > 0.01:
			horiz_vel = wish_dir.normalized() * WALK_SPEED
		else:
			horiz_vel = horiz_vel.lerp(Vector3.ZERO, 0.25)

		velocity = vert_vel + horiz_vel

		if Input.is_action_just_pressed("ui_accept") and is_on_floor():
			velocity += surface_normal * JUMP_VELOCITY

		move_and_slide()
		_swim_bob = 0.0

	# Update camera position/orientation from yaw + pitch.
	# While swimming, add a gentle vertical bob offset.
	var pitch_rad := deg_to_rad(_pitch)
	var bob_offset := global_basis.y * sin(_swim_bob) * 0.12 if _swimming else Vector3.ZERO
	if _first_person:
		camera.transform = Transform3D(Basis(Vector3.RIGHT, pitch_rad), Vector3(0.0, 1.6, 0.0) + bob_offset)
	else:
		var horiz := Basis(surface_normal, deg_to_rad(_yaw))
		var vert   := Basis(Vector3.RIGHT, pitch_rad)
		var offset := horiz * (vert * Vector3(0.0, TP_HEIGHT, TP_DISTANCE))
		camera.transform = Transform3D(Basis.IDENTITY, offset + bob_offset)
		camera.look_at(global_position + global_basis.y * 1.0, global_basis.y)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
			_break_voxel_aimed()
		else:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

	if event is InputEventKey and event.keycode == KEY_ESCAPE and event.pressed:
		Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

	if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		var dx: float = clamp(event.relative.x, -30.0, 30.0)
		var dy: float = clamp(event.relative.y, -30.0, 30.0)
		_yaw   -= dx * MOUSE_SENSITIVITY
		_pitch -= dy * MOUSE_SENSITIVITY
		_pitch  = clamp(_pitch, PITCH_MIN, PITCH_MAX)

	if event is InputEventKey and event.keycode == KEY_F and event.pressed and not event.echo:
		_first_person = not _first_person
		player_mesh.visible = not _first_person

	if event is InputEventKey and event.keycode == KEY_V and event.pressed and not event.echo:
		_flying = not _flying
		if not _flying:
			velocity = Vector3.ZERO  # prevent velocity carry-over when landing

	if event is InputEventKey and event.keycode == KEY_E and event.pressed and not event.echo:
		_break_voxel_underfoot()

	if event is InputEventKey and event.keycode == KEY_O and event.pressed and not event.echo:
		_toggle_water()

	if event is InputEventKey and event.keycode == KEY_H and event.pressed and not event.echo:
		if _crosshair:
			_crosshair.visible = not _crosshair.visible


var _water_visible := true

func _toggle_water() -> void:
	_water_visible = not _water_visible
	if not planet:
		return
	for face in 6:
		var cf = planet.get_node_or_null("CubeFace_%d" % face)
		if cf and cf.has_method("set_water_visible"):
			cf.set_water_visible(_water_visible)


const DIG_REACH := 10.0

# Raycast from the camera and remove the voxel the player is aiming at.
# Works on both the outer shell and inner shell at any depth.
func _break_voxel_aimed() -> void:
	if not planet:
		return
	var space   := get_world_3d().direct_space_state
	var cam_pos := camera.global_position
	var cam_fwd := -camera.global_basis.z
	var query   := PhysicsRayQueryParameters3D.create(cam_pos, cam_pos + cam_fwd * DIG_REACH)
	query.exclude = [get_rid()]
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return

	# Step 0.5 units into the hit block along the inward normal so the radius
	# sample lands clearly inside the voxel rather than on its face boundary.
	var inside: Vector3 = hit.position - hit.normal * 0.5
	var rel:    Vector3 = inside - planet.global_position
	var r:      float   = rel.length()
	var unit:   Vector3 = rel.normalized()

	var fr: Array = _CubeFaceScript.unit_to_face_col_row(unit, planet.resolution)
	var face    := int(fr[0])
	var col     := int(fr[1])
	var row     := int(fr[2])

	var planet_r := _planet_radius()
	var vox      := planet_r / float(planet.resolution)

	if r >= planet_r - vox:
		# Outer shell — outward convention: r_out(d) = planet_r + d*vox
		var depth: int = clamp(int(round((r - planet_r) / vox)), 0, 15)
		var cf := planet.get_node_or_null("CubeFace_%d" % face)
		if cf:
			cf.remove_voxel(col, row, depth)
	else:
		# Inner shell — inward convention: r_out(d) = planet_r - (d+1)*vox
		var depth: int = clamp(int(floor((planet_r - r) / vox)) - 1, 0, 15)
		var icf := planet.get_node_or_null("InnerCubeFace_%d" % face)
		if icf:
			icf.remove_voxel(col, row, depth)


# Remove the topmost voxel of the column the player is standing on.
# Chains to the inner face once the outer column is fully excavated.
func _break_voxel_underfoot() -> void:
	if not planet:
		return
	var result: Array = _CubeFaceScript.unit_to_face_col_row(global_position.normalized(), planet.resolution)
	var face_idx := int(result[0])
	var col := int(result[1])
	var row := int(result[2])
	var cube_face := planet.get_node_or_null("CubeFace_%d" % face_idx)
	if cube_face and cube_face.remove_top_voxel(col, row):
		return
	# Outer column empty — dig into inner shell
	var inner_face := planet.get_node_or_null("InnerCubeFace_%d" % face_idx)
	if inner_face:
		inner_face.remove_top_voxel(col, row)


func _surface_mat_at(pos: Vector3) -> int:
	if not planet:
		return 0
	var result: Array = _CubeFaceScript.unit_to_face_col_row(pos.normalized(), planet.resolution)
	var face_node = planet.get_node_or_null("CubeFace_%d" % int(result[0]))
	if face_node and face_node.has_method("get_top_mat"):
		var mat: int = face_node.get_top_mat(int(result[1]), int(result[2]))
		if mat != 0:
			return mat
	# Below the outer surface — check inner face (water body in ocean columns).
	var inner_face = planet.get_node_or_null("InnerCubeFace_%d" % int(result[0]))
	if inner_face and inner_face.has_method("get_top_mat"):
		return inner_face.get_top_mat(int(result[1]), int(result[2]))
	return 0


# Gravity direction at the player's position. Queries the PlanetGenerator (group
# "gravity_field") so stages ≥ 1 get the hollow-cavity transition blend; falls back
# to plain radial gravity toward the planet origin when no generator is present
# (stage 0, or generator not yet created).
func _gravity_dir() -> Vector3:
	if _gravity_field == null or not is_instance_valid(_gravity_field):
		_gravity_field = get_tree().get_first_node_in_group("gravity_field")
	if _gravity_field and _gravity_field.has_method("gravity_direction"):
		return _gravity_field.gravity_direction(global_position)
	return (planet.global_position - global_position).normalized()


func _planet_radius() -> float:
	var raw = planet.get("planet_radius") if planet else null
	return float(raw) if raw != null else 256.0


func _project_to_plane(v: Vector3, normal: Vector3) -> Vector3:
	var projected := v - v.dot(normal) * normal
	return projected.normalized() if projected.length() > 0.001 else Vector3.ZERO
