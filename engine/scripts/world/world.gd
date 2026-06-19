extends Node3D

@onready var _world_env: WorldEnvironment = $WorldEnvironment
@onready var _sun: DirectionalLight3D = $DirectionalLight3D

# Sky shader material, kept so the day/night cycle can rotate the star sphere with
# the sun (sky_rotation uniform). Set in _setup_sky.
var _sky_mat: ShaderMaterial = null

# Loading overlay (built in code, lives in this scene) shown while the planet
# assembles progressively. Kept deliberately minimal — a bottom-anchored label +
# progress bar — so the planet blooming in behind it stays visible.
var _loading_layer: CanvasLayer = null
var _loading_bar: ProgressBar = null
var _loading_label: Label = null
var _phase_label: String = ""

# While the planet assembles we watch it from a FIXED camera out in space aimed
# at North America (the spawn hemisphere, which builds first). The player is
# frozen + hidden until the build finishes — no per-frame player physics or
# input, so the heavy meshing keeps the framerate to itself. The day/night sun
# is paused so the lighting stays stable. A static view means a low build-time
# framerate just reads as a slideshow, with no input lag to feel.
var _building: bool = false
var _obs_cam: Camera3D = null

# Day/night cycle. The sun is a DirectionalLight3D; rotating it sweeps the light
# direction across the planet. Press T to cycle the time scale (pause → 1× → 10×
# → 60×) — useful for checking whether a shading seam moves with the sun (a
# faceted-normal lighting discontinuity) or stays fixed (a UV/texture artifact).
const _DAY_LENGTH_SEC := 120.0  # real seconds per full revolution at 1×
const _TIME_SCALES := [0.0, 1.0, 10.0, 60.0]
var _time_scale_idx := 1
var _sun_angle := 0.0


func _ready() -> void:
	Engine.max_fps = 60
	# Intercept the window-close so we can tear the heavy scene down in order
	# (see _notification) instead of letting Godot quit immediately — that
	# immediate path is what logged the "ObjectDB instances leaked / resources
	# still in use at exit" warnings on a manual close.
	get_tree().set_auto_accept_quit(false)
	_setup_sky()
	_setup_environment()
	_setup_sun()
	_setup_planet_generator()
	_start_build()


# Manual window close (the X button). Free the resource-heavy nodes — the voxel
# planet (all its chunk meshes, materials, shaders, collision shapes) and the
# audio player — BEFORE quitting, so they're released in tree order rather than
# during Godot's final teardown, which reported them as leaked/in-use at exit.
func _notification(what: int) -> void:
	if what != NOTIFICATION_WM_CLOSE_REQUEST:
		return
	var music := get_node_or_null("/root/Music")
	if music and music.has_method("stop_and_free"):
		music.stop_and_free()
	var planet := get_node_or_null("VoxelPlanet")
	if planet:
		planet.free()
	get_tree().quit()


func _process(delta: float) -> void:
	# During the build, leave the sun fixed (no day/night sweep while assembling
	# — keeps the lighting stable while the player free-flies). The player drives
	# its own camera/movement via _physics_process.
	if _building:
		return

	var scale: float = _TIME_SCALES[_time_scale_idx]
	if scale == 0.0:
		return
	_sun_angle += TAU / _DAY_LENGTH_SEC * scale * delta
	_apply_sun_direction()


# Point the sun for the current _sun_angle. The sun orbits in the equatorial (X-Z)
# plane about the polar (+Y) axis, so an equatorial observer sees it rise on one
# horizon, pass directly overhead, and set on the other — east-rise / west-set, no
# permanent high elevation. (Negate _sun_angle if east/west ends up reversed for
# your map orientation.) The subsolar point — where the sun is straight overhead —
# is the surface point in the +sun_dir direction.
func _apply_sun_direction() -> void:
	var sun_dir := Vector3(cos(_sun_angle), 0.0, sin(_sun_angle))
	_sun.look_at_from_position(Vector3.ZERO, -sun_dir, Vector3.UP)
	# The star sphere is intentionally left STATIONARY in-game (sky_rotation untouched).
	# Rotating it with the sun is physically correct but reads as distracting; the
	# stars still shift as the player walks the planet (that's view direction, not
	# sky rotation). The slow menu drift is unaffected (driven from main_menu.gd).


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_T:
		_time_scale_idx = (_time_scale_idx + 1) % _TIME_SCALES.size()
		print("Day/night time scale: %.0f×" % _TIME_SCALES[_time_scale_idx])


func _setup_sky() -> void:
	var shader := load("res://shaders/sky_space.gdshader") as Shader
	if shader == null:
		push_warning("sky_space.gdshader not found — keeping default sky")
		return
	var mat := ShaderMaterial.new()
	mat.shader = shader
	_sky_mat = mat

	# Pass planet radius so altitude-based atmosphere thinning works correctly.
	# VoxelPlanet._ready() runs before World._ready() (children before parent),
	# so planet_radius is already populated from planet_config.json by this point.
	var planet := get_node_or_null("VoxelPlanet")
	var planet_r: float = float(planet.get("planet_radius")) if planet else 256.0
	mat.set_shader_parameter("planet_radius", planet_r)

	var sky := Sky.new()
	sky.sky_material = mat
	_world_env.environment.sky = sky
	_world_env.environment.background_mode = Environment.BG_SKY


func _setup_environment() -> void:
	var env := _world_env.environment

	# Warm solid-color ambient fills the night side without going pitch black.
	# COLOR source gives consistent warm fill regardless of sky brightness.
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.85, 0.85, 0.80)
	env.ambient_light_energy = 0.6

	# Filmic tone mapping — photographic contrast, no blown highlights.
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_white = 6.0
	env.tonemap_exposure = 1.0

	# SSAO — light depth cues in voxel crevices, not heavy shadow painting.
	env.ssao_enabled = true
	env.ssao_radius = 1.0
	env.ssao_intensity = 1.0
	env.ssao_power = 1.0
	env.ssao_detail = 0.5

	# SSIL — subtle indirect bounce from sunlit surfaces.
	env.ssil_enabled = true
	env.ssil_radius = 4.0
	env.ssil_intensity = 1.0

	# Glow — slight halo around the sun disc in the sky shader.
	env.glow_enabled = true
	env.glow_bloom = 0.02
	env.glow_intensity = 0.6
	env.glow_strength = 1.0
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE


func _setup_planet_generator() -> void:
	# Staged inner-world generator, additive alongside the existing outer VoxelPlanet.
	# VoxelPlanet._ready() runs before World._ready() (children before parent), so
	# planet_radius is already populated from planet_config.json by this point.
	var planet := get_node_or_null("VoxelPlanet")
	var planet_r: float = float(planet.get("planet_radius")) if planet else 256.0
	var gen := preload("res://scripts/planet/planet_generator.gd").new()
	gen.name = "PlanetGenerator"
	add_child(gen)
	gen.setup(planet_r)
	gen.generate_planet(gen.read_generation_stage())


func _setup_sun() -> void:
	_sun.light_color = Color(1.0, 0.98, 0.92)  # warm white
	_sun.light_energy = 1.1
	_sun.shadow_enabled = true
	_sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	_sun.directional_shadow_max_distance = 600.0
	# Sun stays off through the loading screen — the space view of the building
	# planet is lit only by ambient, with no day/night sweep. It's switched on in
	# _on_build_finished, oriented to dawn at the player's spawn (see _start_build).
	# visible = false stops it lighting the scene, but Godot still feeds the light to
	# the sky shader as LIGHT0 (drawing the sun disc/corona). Gate that off in the sky
	# shader too via the sun_visible uniform until the build finishes.
	_sun.visible = false
	if _sky_mat:
		_sky_mat.set_shader_parameter("sun_visible", 0.0)


# --- Progressive build + loading overlay -----------------------------------
# The faces no longer build in their own _ready(); VoxelPlanet.build_planet_async
# spreads the meshing across frames and reports progress. We show a loading
# overlay, freeze the player (no surface to stand on yet), and reveal on finish.
func _start_build() -> void:
	var planet := get_node_or_null("VoxelPlanet")
	if planet == null:
		push_warning("World: VoxelPlanet missing — cannot run progressive build")
		return
	_building = true
	_build_loading_overlay()

	var planet_r: float = float(planet.get("planet_radius"))
	var player := get_node_or_null("Player") as Node3D
	# Spawn-out reveal order keys off the player's spawn position (the location
	# chosen on the menu — see SpawnPoints / player.gd _ready()).
	var spawn_pos: Vector3 = player.global_position if player else Vector3(0.0, planet_r, 0.0)
	# Start every run at dawn wherever the player spawns: put the subsolar point a
	# quarter-turn (90°) east of the spawn longitude so the sun begins on the horizon
	# and climbs as the day/night cycle advances. The spawn's longitude angle in the
	# X-Z plane is atan2(z, x); the sun is overhead at +sun_dir, so we trail it 90°.
	_sun_angle = atan2(spawn_pos.z, spawn_pos.x) - PI / 2.0
	if player:
		player.set_physics_process(false)  # no surface yet; also keeps frames free
		player.set_process_unhandled_input(false)  # don't let a stray click capture the mouse
		player.visible = false  # hide the capsule; we watch from space

	_setup_observation_camera(spawn_pos, planet_r)

	planet.build_phase.connect(_on_build_phase)
	planet.build_progress.connect(_on_build_progress)
	planet.build_finished.connect(_on_build_finished)
	planet.build_planet_async(spawn_pos)


# A fixed camera out in space aimed at the planet centre from the spawn
# hemisphere, so the chosen starting continent (which builds first) faces the
# viewer and the planet is framed dead-centre. No orbit, no input — purely a
# static vantage.
func _setup_observation_camera(spawn_pos: Vector3, planet_r: float) -> void:
	_obs_cam = Camera3D.new()
	_obs_cam.far = planet_r * 10.0
	add_child(_obs_cam)
	# Closer = bigger planet on screen (was 2.2). At this distance the globe's
	# silhouette ~asin(r/D) already fills most of the ~75° FOV, so there isn't much
	# headroom to also lift it — "bigger" and "higher with a bottom margin" trade off.
	# 1.9 is a modest zoom-in that still leaves a few degrees of top headroom for the
	# lift below. DIAL 1: lower → bigger (don't go below ~1.7 or the lift clips the top).
	var cam_dist := planet_r * 1.9
	_obs_cam.global_position = spawn_pos.normalized() * cam_dist
	# Aim slightly BELOW the planet centre so the globe sits HIGHER on screen,
	# leaving the bottom of the frame for the progress overlay. Offsetting the look
	# target is predictable (no guessing v_offset's world-unit scaling): the planet
	# centre is lifted by ~atan(drop / cam_dist) of the vertical FOV. Screen-up is the
	# world-up component perpendicular to the view ray, so the lift is straight up
	# regardless of which hemisphere we're viewing (incl. the Antarctica pole pick).
	var view_dir := (-_obs_cam.global_position).normalized()
	var screen_up := (Vector3.UP - Vector3.UP.dot(view_dir) * view_dir)
	if screen_up.length() < 0.01:
		screen_up = Vector3.FORWARD  # near-polar view: any perpendicular up works
	screen_up = screen_up.normalized()
	# DIAL 2: bigger factor → higher on screen. Kept small (~3° lift) because the
	# globe nearly fills the frame; raise toward ~0.10 only if you also zoom out.
	var look_drop := cam_dist * 0.05
	_obs_cam.look_at(-screen_up * look_drop, screen_up)
	_obs_cam.current = true


func _build_loading_overlay() -> void:
	_loading_layer = CanvasLayer.new()
	_loading_layer.layer = 50
	add_child(_loading_layer)

	# Bottom-anchored so the planet assembling behind it stays in full view.
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	box.anchor_left = 0.5
	box.anchor_right = 0.5
	box.offset_left = -220.0
	box.offset_right = 220.0
	box.offset_top = -120.0
	box.offset_bottom = -48.0
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 10)
	_loading_layer.add_child(box)

	var title := Label.new()
	title.text = "Tiny Earth"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 28)
	title.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	title.add_theme_constant_override("outline_size", 6)
	box.add_child(title)

	_loading_label = Label.new()
	_loading_label.text = "Generating planet…  0%"
	_loading_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_loading_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	_loading_label.add_theme_constant_override("outline_size", 4)
	box.add_child(_loading_label)

	_loading_bar = ProgressBar.new()
	_loading_bar.custom_minimum_size = Vector2(440, 22)
	_loading_bar.min_value = 0.0
	_loading_bar.max_value = 1.0
	_loading_bar.value = 0.0
	_loading_bar.show_percentage = false
	box.add_child(_loading_bar)


func _on_build_phase(label: String) -> void:
	_phase_label = label
	if _loading_label:
		_loading_label.text = label


func _on_build_progress(done: int, total: int) -> void:
	if _loading_bar:
		_loading_bar.max_value = float(maxi(total, 1))
		_loading_bar.value = float(done)
	if _loading_label:
		_loading_label.text = (
			"%s  %d%%" % [_phase_label, int(100.0 * float(done) / float(maxi(total, 1)))]
		)


func _on_build_finished() -> void:
	_building = false
	# Sun on now that the player takes control, oriented to dawn at the spawn
	# (_sun_angle was set in _start_build) so the very first lit frame is correct.
	# Re-enable the sun disc/corona in the sky shader so it reappears, rising east.
	_sun.visible = true
	if _sky_mat:
		_sky_mat.set_shader_parameter("sun_visible", 1.0)
	_apply_sun_direction()
	var player := get_node_or_null("Player") as Node3D
	if player:
		# Drop the player onto the actual terrain surface. player.gd._ready() placed
		# them at planet_radius + 1.5, but the outer shell stacks land voxels OUTWARD,
		# so any elevated column (mountains, even moderate terrain) sits well above
		# that — the player would otherwise start buried in solid rock and be stuck.
		# Now that the build is finished the collision shapes exist, so a raycast from
		# high above the spawn direction down toward the planet centre lands on the
		# true top voxel. Done before re-enabling physics so the first frame is clean.
		_drop_player_to_surface(player)
		# Face east into the sunrise: the dawn sun sits toward +sun_dir (see
		# _start_build / _apply_sun_direction), so aim the player's heading there.
		if player.has_method("face_horizontal"):
			player.face_horizontal(Vector3(cos(_sun_angle), 0.0, sin(_sun_angle)))
		player.set_physics_process(true)
		player.set_process_unhandled_input(true)  # restore look/dig/Esc input
		player.visible = true
		if player.has_method("on_world_ready"):
			player.on_world_ready()  # reveal the crosshair HUD
		var pcam := player.get_node_or_null("Camera3D") as Camera3D
		if pcam:
			pcam.current = true  # hand control back to the player camera
	if _obs_cam:
		_obs_cam.queue_free()
		_obs_cam = null
	if _loading_layer:
		_loading_layer.queue_free()
		_loading_layer = null

	# Apply any persisted Graphics → Water settings now that the per-face water
	# materials exist, so a player's saved look is in effect from the first frame.
	var settings := get_node_or_null("/root/GameSettings")
	if settings:
		settings.apply_water()

	# Start the ambient music now that the world is built and explorable.
	var music := get_node_or_null("/root/Music")
	if music:
		music.start()

	# Pause menu is created only now (post-build) so Esc can't pause mid-load.
	# Settings → Graphics tunes the water appearance live (finds the per-face water
	# materials the build created).
	var pause_menu := preload("res://scripts/ui/pause_menu.gd").new()
	pause_menu.name = "PauseMenu"
	add_child(pause_menu)


# Snap the player down onto the real top voxel of their spawn column. The spawn
# DIRECTION (which continent) is fixed by player.gd from the menu pick; only the
# RADIUS needs correcting for terrain elevation, so we keep the existing radial
# direction and raycast inward along it. Start well above the tallest possible
# column (15 voxels of stacked land) and end just below sea level so we always
# straddle the surface, then place the capsule a small clearance above the hit.
func _drop_player_to_surface(player: Node3D) -> void:
	var planet := get_node_or_null("VoxelPlanet") as Node3D
	if planet == null:
		return
	var planet_r: float = float(planet.get("planet_radius"))
	var origin: Vector3 = planet.global_position
	var dir: Vector3 = (player.global_position - origin).normalized()
	if dir.length() < 0.5:
		dir = Vector3.UP  # degenerate (player at centre) — pick a stable axis

	# Generous margins: max land stack is ~15 voxels (vox = planet_r/resolution),
	# so planet_r * 0.25 above the nominal surface clears any mountain; ending
	# below sea level guarantees the ray crosses the terrain top.
	var from: Vector3 = origin + dir * (planet_r * 1.25)
	var to: Vector3 = origin + dir * (planet_r * 0.9)
	var space := get_world_3d().direct_space_state
	var q := PhysicsRayQueryParameters3D.create(from, to)
	var body := player as CollisionObject3D
	if body:
		q.exclude = [body.get_rid()]
	var hit := space.intersect_ray(q)
	if hit.is_empty():
		return  # no surface found (shouldn't happen) — leave the _ready() spawn
	# Capsule sits 1.5 above the surface, matching player.gd's original clearance.
	player.global_position = hit["position"] + dir * 1.5
