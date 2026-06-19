extends CharacterBody3D

const GRAVITY_STRENGTH := 20.0
const WALK_SPEED := 5.0
const SWIM_SPEED := 4.5
const JUMP_VELOCITY := 8.0

# Swimming vertical motion. Default is to SINK (SINK_ACCEL → SINK_MAX terminal).
# Holding Space rises smoothly to the surface (SWIM_RISE_SPEED) and then floats
# there without bobbing — the vertical velocity is damped to rest and no gravity is
# applied while at the surface, so open-water surface swimming is smooth. The only
# upward launch is the climb-out: holding Space while LOOKING at a one-block shore
# ledge lifts the player up and onto it (CLIMB_RISE_SPEED) so you can leave the
# water without flying. WATER_VERTICAL_RATE is the damping rate for a smooth rise.
const SWIM_RISE_SPEED := 2.5
const CLIMB_RISE_SPEED := 5.0
const SINK_ACCEL := 8.0
const SINK_MAX := 4.0
const WATER_VERTICAL_RATE := 8.0
# Shore-climb probe. A point STEP_REACH ahead of the player (in the look direction)
# is checked for a solid top within the climb window [STEP_MIN_DOWN, STEP_MAX_UP]
# measured from the feet. The window reaches BELOW the feet too, so a shelf sitting
# a block or two under the surface still counts as climbable.
const STEP_REACH := 1.6
const STEP_MAX_UP := 2.3
const STEP_MIN_DOWN := -2.0
const FLY_SPEED := WALK_SPEED * 5.0

const MOUSE_SENSITIVITY := 0.08  # degrees per pixel
const PITCH_MIN := -89.0
const PITCH_MAX := 89.0
const TP_DISTANCE := 4.0
const TP_HEIGHT := 1.6

const _CubeFaceScript = preload("res://scripts/planet/cube_face.gd")

@export var planet: StaticBody3D
@onready var camera: Camera3D = $Camera3D
@onready var player_mesh: MeshInstance3D = $MeshInstance3D

var _first_person := false
var _flying := false
var _noclip := false  # fly-through-solid toggle (KEY_N); off by default
var _swimming := false
var _swim_bob := 0.0  # oscillator for camera bob while swimming
var _yaw: float = 0.0
var _pitch: float = -15.0
var _surface_right := Vector3(0, 0, 1)  # parallel-transported; avoids pole singularity

var _gravity_field: Node = null  # PlanetGenerator (in group "gravity_field"), looked up lazily
var _water_overlay: ColorRect = null
var _crosshair: Label = null
var _crosshair_enabled := true  # user preference (H toggles it off entirely)
var _world_ready := false  # gates the HUD off during the loading screen
var _hud_suppressed := false  # gates the HUD off while the pause menu is open


func _ready() -> void:
	# Tight near plane so the camera frustum doesn't poke through a nearby solid
	# face (cave ceiling / inner-shell roof) and reveal the culled hollow behind
	# it. Same trick Minecraft/Luanti use for low-clearance spaces.
	camera.near = 0.01
	if not planet:
		planet = get_node_or_null("../VoxelPlanet") as StaticBody3D
	if planet:
		# Spawn direction comes from the location picked on the menu (carried in
		# SpawnPoints.selected_index), not the baked .tscn transform — so the
		# Player transform in world.tscn is just a sensible fallback now. Default
		# index 0 is central Kansas, so launching world.tscn directly is unchanged.
		var spawn: Dictionary = SpawnPoints.selected()
		var surface_normal := Coords.latlon_to_unit(spawn["lat"], spawn["lon"])
		var axis := Vector3.UP.cross(surface_normal)
		if axis.length() > 0.001:
			global_basis = global_basis.rotated(
				axis.normalized(), Vector3.UP.angle_to(surface_normal)
			)
		# Snap to planet surface so spawn position stays correct regardless of radius_scale.
		var raw_r = planet.get("planet_radius")
		var planet_r: float = float(raw_r) if raw_r != null else 256.0
		global_position = planet.global_position + surface_normal * (planet_r + 1.5)

	var cl := CanvasLayer.new()
	cl.layer = 10
	add_child(cl)
	_water_overlay = ColorRect.new()
	_water_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	# Fog-like underwater murk: a desaturated blue-green that reads as depth haze
	# rather than a flat coloured pane. Alpha kept below the old 0.60 so the surface
	# line and nearby geometry stay legible once submerged.
	_water_overlay.color = Color(0.05, 0.20, 0.30, 0.52)
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
	# Hidden until the world finishes building (see on_world_ready); it would
	# otherwise float over the loading screen. H toggles it off entirely in-game.
	_crosshair.visible = false
	hud_cl.add_child(_crosshair)


# Crosshair shows only once in-game, not toggled off by the user (H key), and not
# while the pause menu is up (it would otherwise float over the dimmed menu).
func _refresh_crosshair() -> void:
	if _crosshair:
		_crosshair.visible = _world_ready and _crosshair_enabled and not _hud_suppressed


# Called by World once the planet build finishes and the player takes control.
func on_world_ready() -> void:
	_world_ready = true
	_refresh_crosshair()


# Hide/show the in-game HUD (crosshair) — driven by the pause menu open/close.
func set_hud_suppressed(suppressed: bool) -> void:
	_hud_suppressed = suppressed
	_refresh_crosshair()


func _physics_process(delta: float) -> void:
	if not planet:
		return
	var gravity_dir := _gravity_dir()
	var surface_normal := -gravity_dir
	up_direction = surface_normal

	# Stateless basis rebuild: surface-aligned with absolute yaw, no accumulated drift.
	# Uses world_up × surface_normal for right (right-handed, consistent with _ready).
	# Project last frame's right onto the current tangent plane (parallel transport).
	# This is stable at all latitudes including poles — no cross-product singularity.
	var right_proj := _surface_right - _surface_right.dot(surface_normal) * surface_normal
	var right := (
		right_proj.normalized()
		if right_proj.length() > 0.001
		else Vector3(1, 0, 0).cross(surface_normal).normalized()
	)
	_surface_right = right
	var forward_dir := surface_normal.cross(right).normalized()
	var yaw_rot := Basis(surface_normal, deg_to_rad(_yaw))
	global_basis = (
		Basis(yaw_rot * right, surface_normal, yaw_rot * (-forward_dir)).orthonormalized()
	)

	var cam_fwd := _project_to_plane(-camera.global_basis.z, surface_normal)
	var cam_right := _project_to_plane(camera.global_basis.x, surface_normal)
	var input := Vector2(
		Input.get_action_strength("ui_right") - Input.get_action_strength("ui_left"),
		Input.get_action_strength("ui_down") - Input.get_action_strength("ui_up")
	)

	# Only the outer surface has water. Gate the swim check by radius so that
	# standing on the inner sphere (which samples the outer face's material map)
	# never reads as "swimming".
	var planet_r := _planet_radius()
	var near_surface := global_position.length() > planet_r * 0.9
	# Body-in-water samples. chest_wet/body_wet tell "in the water" from "in the air
	# above the ocean" in the swim branch; body_wet also keeps swim+climb control
	# alive as you reach a shore where the column underfoot already reads as land.
	var chest_wet := _voxel_mat_at(global_position + surface_normal * 0.9) == 2
	var body_wet := chest_wet or _voxel_mat_at(global_position + surface_normal * 0.1) == 2
	_swimming = (not _flying) and near_surface and (_surface_mat_at(global_position) == 2 or body_wet)
	# Underwater tint shows only when the camera is INSIDE an actual water voxel,
	# not merely somewhere below an ocean column. The old radius-gated heuristic
	# false-fired when flying through inner-shell rock under ocean tiles.
	if _water_overlay:
		_water_overlay.visible = _voxel_mat_at(camera.global_position) == 2

	if _flying:
		var fly_dir := cam_fwd * -input.y + cam_right * input.x
		fly_dir += surface_normal * float(Input.is_action_pressed("ui_accept"))  # Space = up
		fly_dir -= surface_normal * float(Input.is_key_pressed(KEY_CTRL))  # Ctrl  = down
		if fly_dir.length() > 0.01:
			# Collision-aware fly (Issue 3): move_and_collide stops the player at solid
			# crust instead of noclipping through it. The apparent "hollow voxels" were
			# never a data/mesh bug — they are the inner shell's correctly face-culled
			# solid interior, only ever visible by flying inside undug rock. Air, dug
			# shafts, and the open hollow cavity have no collider, so they stay flyable.
			# KEY_N toggles _noclip back on for free hollow-space exploration.
			var motion := fly_dir.normalized() * FLY_SPEED * delta
			if _noclip:
				global_position += motion
			else:
				move_and_collide(motion)
		velocity = Vector3.ZERO
		_swim_bob = 0.0
	elif _swimming:
		var wish_dir := cam_fwd * -input.y + cam_right * input.x
		var horiz_vel := velocity - velocity.project(gravity_dir)

		if wish_dir.length() > 0.01:
			horiz_vel = wish_dir.normalized() * SWIM_SPEED
		else:
			horiz_vel = horiz_vel.lerp(Vector3.ZERO, 0.4)

		# Climbing out is deliberate, not automatic: the player must HOLD Space while
		# LOOKING at a climbable ledge (a step within reach — see _can_step_out). Facing
		# comes from the camera, so this only fires when you choose to climb a nearby
		# step, never as a surprise auto-jump. While climbing we drive the player
		# forward into the bank so the rise actually carries them up onto it.
		var holding_up := Input.is_action_pressed("ui_accept")
		var face_dir := _project_to_plane(-camera.global_basis.z, surface_normal)
		var ledge_ahead := holding_up and face_dir != Vector3.ZERO and _can_step_out(face_dir, surface_normal)

		var v_up := velocity.dot(surface_normal)
		var damp := clampf(WATER_VERTICAL_RATE * delta, 0.0, 1.0)
		if ledge_ahead:
			v_up = CLIMB_RISE_SPEED  # rise up the bank…
			horiz_vel = face_dir * SWIM_SPEED  # …and move onto it
			velocity = horiz_vel + surface_normal * v_up
		elif not body_wet:
			# Body is above the surface (e.g. just dropped out of fly over the ocean):
			# apply real gravity so the player falls naturally into the water rather
			# than drifting down at the slow in-water sink rate.
			if not is_on_floor():
				velocity += gravity_dir * GRAVITY_STRENGTH * delta
			velocity = velocity.project(gravity_dir) + horiz_vel
		elif holding_up:
			if chest_wet:
				v_up = lerp(v_up, SWIM_RISE_SPEED, damp)  # rise smoothly to the surface
			else:
				v_up = lerp(v_up, 0.0, damp)  # float at the surface — damped, no bob
			velocity = horiz_vel + surface_normal * v_up
		else:
			v_up = maxf(v_up - SINK_ACCEL * delta, -SINK_MAX)  # sink by default
			velocity = horiz_vel + surface_normal * v_up

		move_and_slide()

		# Slow oscillating bob for the camera while swimming.
		_swim_bob = fmod(_swim_bob + delta * 1.8, TAU)
	else:
		if not is_on_floor():
			velocity += gravity_dir * GRAVITY_STRENGTH * delta

		var wish_dir := cam_fwd * -input.y + cam_right * input.x
		var vert_vel := velocity.project(gravity_dir)
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
		camera.transform = Transform3D(
			Basis(Vector3.RIGHT, pitch_rad), Vector3(0.0, 1.6, 0.0) + bob_offset
		)
	else:
		# TODO(bug): third-person aim is inconsistent — a downward mouse move can
		# pitch the camera up OR down depending on the current yaw. The vertical
		# rotation is built around the fixed world axis Vector3.RIGHT instead of the
		# yaw-rotated surface-tangent right axis, so it doesn't track orientation the
		# way first-person (which is correct) does. Fix: rotate about the actual
		# surface-aligned right vector. Tracked in HANDOFF misc bugs.
		var horiz := Basis(surface_normal, deg_to_rad(_yaw))
		var vert := Basis(Vector3.RIGHT, pitch_rad)
		var offset := horiz * (vert * Vector3(0.0, TP_HEIGHT, TP_DISTANCE))
		camera.transform = Transform3D(Basis.IDENTITY, offset + bob_offset)
		# Camera collision ("spring arm"): if solid sits between the player's head
		# and the desired 3rd-person camera spot, pull the camera in to the hit
		# point so it doesn't clip through walls/ceilings into culled-solid space.
		# The rock IS solid (same as Minecraft/Luanti) — we just slide the camera
		# inward rather than letting it show the hollow. Skipped under _noclip so
		# free hollow-space exploration isn't fought by the camera.
		var head := global_position + global_basis.y * 1.0
		if not _noclip:
			var desired := camera.global_position
			var space := get_world_3d().direct_space_state
			var q := PhysicsRayQueryParameters3D.create(head, desired)
			q.exclude = [get_rid()]
			var chit := space.intersect_ray(q)
			if not chit.is_empty():
				camera.global_position = chit.position + (head - desired).normalized() * 0.2
		camera.look_at(head, global_basis.y)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
			_break_voxel_aimed()
		else:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

	# Esc is owned by the PauseMenu overlay (toggles get_tree().paused). The player
	# no longer frees the mouse on Esc — pausing serves that role now.

	if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		var dx: float = clamp(event.relative.x, -30.0, 30.0)
		var dy: float = clamp(event.relative.y, -30.0, 30.0)
		_yaw -= dx * MOUSE_SENSITIVITY
		_pitch -= dy * MOUSE_SENSITIVITY
		_pitch = clamp(_pitch, PITCH_MIN, PITCH_MAX)

	if event is InputEventKey and event.keycode == KEY_F and event.pressed and not event.echo:
		_first_person = not _first_person
		player_mesh.visible = not _first_person

	if event is InputEventKey and event.keycode == KEY_V and event.pressed and not event.echo:
		_flying = not _flying
		if not _flying:
			velocity = Vector3.ZERO  # prevent velocity carry-over when landing

	if event is InputEventKey and event.keycode == KEY_N and event.pressed and not event.echo:
		_noclip = not _noclip

	if event is InputEventKey and event.keycode == KEY_E and event.pressed and not event.echo:
		_break_voxel_underfoot()

	if event is InputEventKey and event.keycode == KEY_O and event.pressed and not event.echo:
		_toggle_water()

	if event is InputEventKey and event.keycode == KEY_H and event.pressed and not event.echo:
		_crosshair_enabled = not _crosshair_enabled
		_refresh_crosshair()


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
	var space := get_world_3d().direct_space_state
	var cam_pos := camera.global_position
	var cam_fwd := -camera.global_basis.z
	var query := PhysicsRayQueryParameters3D.create(cam_pos, cam_pos + cam_fwd * DIG_REACH)
	query.exclude = [get_rid()]
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return

	# Step 0.5 units into the hit block along the inward normal so the radius
	# sample lands clearly inside the voxel rather than on its face boundary.
	var inside: Vector3 = hit.position - hit.normal * 0.5
	var rel: Vector3 = inside - planet.global_position
	var r: float = rel.length()
	var unit: Vector3 = rel.normalized()

	var fr: Array = _CubeFaceScript.unit_to_face_col_row(unit, planet.resolution)
	var face := int(fr[0])
	var col := int(fr[1])
	var row := int(fr[2])

	var planet_r := _planet_radius()
	var vox := planet_r / float(planet.resolution)

	if r >= planet_r - vox:
		# Outer shell — outward convention: voxel d occupies the radial band
		# [planet_r + (d-1)*vox, planet_r + d*vox]. The inverse is
		# floor((r - planet_r)/vox) + 1 — NOT round(), which was one level too
		# low and removed the buried depth-0 voxel instead of the surface voxel.
		var depth: int = clamp(int(floor((r - planet_r) / vox)) + 1, 0, 15)
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
	var result: Array = _CubeFaceScript.unit_to_face_col_row(
		global_position.normalized(), planet.resolution
	)
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


# Material of the voxel that physically contains a world-space point (0 = none).
# Resolves shell + depth from radius the same way _break_voxel_aimed does, then
# reads the raw chunk byte via mat_at(). Unlike _surface_mat_at (which returns a
# column's top material), this answers "what voxel am I literally standing in?",
# so the underwater overlay only fires inside real water voxels.
func _voxel_mat_at(pos: Vector3) -> int:
	if not planet:
		return 0
	var rel := pos - planet.global_position
	var r := rel.length()
	var planet_r := _planet_radius()
	var vox := planet_r / float(planet.resolution)
	var fr: Array = _CubeFaceScript.unit_to_face_col_row(rel.normalized(), planet.resolution)
	var face := int(fr[0])
	var col := int(fr[1])
	var row := int(fr[2])
	if r >= planet_r - vox:
		var depth: int = int(floor((r - planet_r) / vox)) + 1
		var cf = planet.get_node_or_null("CubeFace_%d" % face)
		if cf and cf.has_method("mat_at"):
			return cf.mat_at(col, row, depth)
	else:
		var depth: int = int(floor((planet_r - r) / vox)) - 1
		var icf = planet.get_node_or_null("InnerCubeFace_%d" % face)
		if icf and icf.has_method("mat_at"):
			return icf.mat_at(col, row, depth)
	return 0


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


# Aim the player's heading along the horizontal projection of `world_dir` (e.g. the
# direction to the rising sun). The surface basis is rebuilt each physics frame from
# _surface_right + _yaw; choosing _surface_right = fwd × n makes forward_dir
# (= n × right) equal `fwd`, so with _yaw = 0 the camera looks straight along it.
# Called once by World after the build so every run starts facing east into sunrise.
func face_horizontal(world_dir: Vector3) -> void:
	var origin: Vector3 = planet.global_position if planet else Vector3.ZERO
	var n := (global_position - origin).normalized()
	var fwd := world_dir - world_dir.dot(n) * n
	if fwd.length() < 0.001:
		return  # world_dir is straight up/down — no meaningful heading
	fwd = fwd.normalized()
	_surface_right = fwd.cross(n)
	_yaw = 0.0


# True when there's a climbable ledge in the player's look direction `fwd` (a unit
# tangent). Probes the column a short way ahead by casting straight down and finding
# its solid top; if that top sits within the climb window relative to the feet
# ([STEP_MIN_DOWN, STEP_MAX_UP]) it's something we can haul out onto — a shore bank
# or a shallow shelf a block or two under the surface. Over open water the only
# solid ahead is the distant seafloor, far below the window, so this stays quiet.
# Tall cliffs put their top above STEP_MAX_UP and are likewise left un-climbable.
func _can_step_out(fwd: Vector3, surface_normal: Vector3) -> bool:
	if not planet:
		return false
	var space := get_world_3d().direct_space_state
	var ahead := global_position + fwd * STEP_REACH
	var from := ahead + surface_normal * 2.5
	var to := ahead - surface_normal * 3.0
	var q := PhysicsRayQueryParameters3D.create(from, to)
	q.exclude = [get_rid()]
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return false
	var rise: float = (Vector3(hit["position"]) - global_position).dot(surface_normal)
	return rise >= STEP_MIN_DOWN and rise <= STEP_MAX_UP
