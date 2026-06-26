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
var _loading_track_label: Label = null  # "now playing" text on the loading-screen music row
var _phase_label: String = ""

# While the planet assembles we watch it from a FIXED camera out in space aimed
# at North America (the spawn hemisphere, which builds first). The player is
# frozen + hidden until the build finishes — no per-frame player physics or
# input, so the heavy meshing keeps the framerate to itself. The day/night sun
# is paused so the lighting stays stable. A static view means a low build-time
# framerate just reads as a slideshow, with no input lag to feel.
var _building: bool = false
# True once the progressive build has finished and gameplay started. Gates the
# per-frame realtime sky (twinkle) so it only turns on after loading — the early
# _apply_graphics_quality() call in _ready (before _start_build flips _building)
# must NOT switch the sky to REALTIME mid-load.
var _built: bool = false
var _obs_cam: Camera3D = null
# Spawn position (from the menu pick, read off the Player) — chosen in _enter_loading_view
# and reused by _start_build to drive the build/reveal order and the observation camera.
var _spawn_pos: Vector3 = Vector3.ZERO
# Load-time profiling (queue item 1, "measure first"): wall-clock for the whole build
# and the inner-globe sub-build, printed alongside the per-phase CPU timing.
var _build_start_ms: int = 0

# Day/night cycle. The sun is a DirectionalLight3D; rotating it sweeps the light
# direction across the planet. Press T to cycle the time scale (pause → 1× → 10×
# → 60×) — useful for checking whether a shading seam moves with the sun (a
# faceted-normal lighting discontinuity) or stays fixed (a UV/texture artifact).
const _DAY_LENGTH_SEC := 120.0  # real seconds per full revolution at 1×
const _TIME_SCALES := [0.0, 1.0, 10.0, 60.0]
# How far BELOW the eastern horizon the sun starts, in degrees of extra westward
# trail beyond the 90° dawn offset. 0 = exactly on the horizon; a few degrees opens
# the run with the sun just under the horizon so it visibly rises. The on-screen
# elevation is shallower than this at high latitudes (≈ asin(cos(lat)·sin(this))):
# at the Alps (~46°N) 12° reads as ~8° below. Raise for a longer pre-dawn.
const _DAWN_DEPRESSION_DEG := 12.0
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
	_apply_graphics_quality()  # gate the expensive post-FX by the saved High/Low preset

	# Paint the loading overlay FIRST, before the heavy synchronous planet-generator
	# setup. _setup_planet_generator() → generate_planet() blocks for a noticeable
	# beat, and it used to run before any overlay existed — so the previous
	# (level-select) frame stayed frozen on screen the whole time. Building the
	# overlay and yielding two frames here lets the bar actually render at 0% before
	# we hit that stall, so the transition reads as "loading" instead of a hang.
	_building = true
	_build_start_ms = Time.get_ticks_msec()
	_build_loading_overlay()
	_on_build_phase("Preparing planet")
	# Switch to the space view (hide the player capsule, make the observation camera
	# current) BEFORE the awaits + the synchronous generator stall. Otherwise the
	# player's own camera stays active for those 1–2s and you see the capsule floating
	# in an empty starfield until _start_build finally hid it.
	_enter_loading_view()
	await get_tree().process_frame
	await get_tree().process_frame

	# Measure the deferred setup cost (queue item 1a "measure the gap first"): this
	# is the synchronous stall that previously preceded the first painted frame.
	var setup_s := Time.get_ticks_msec()
	_setup_planet_generator()
	print("[load] generator setup=%dms" % (Time.get_ticks_msec() - setup_s))
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
	# Closing DURING the loading screen leaked ObjectDB instances: the build coroutine
	# is parked on an await and these build-time-only nodes never got torn down. Free
	# them here too so a mid-load close releases in tree order instead of at exit.
	# (Harmless post-build — they're already freed/null by then; the guards no-op.)
	if _obs_cam and is_instance_valid(_obs_cam):
		_obs_cam.free()
		_obs_cam = null
	if _loading_layer and is_instance_valid(_loading_layer):
		_loading_layer.free()
		_loading_layer = null
	var gen := get_node_or_null("PlanetGenerator")
	if gen:
		gen.free()
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
	# Music track skip: [ = previous, ] = next (cycles the playlist; see Music autoload).
	if event is InputEventKey and event.pressed and not event.echo:
		var music := get_node_or_null("/root/Music")
		if music:
			if event.keycode == KEY_BRACKETRIGHT:
				music.next()
			elif event.keycode == KEY_BRACKETLEFT:
				music.prev()


func _setup_sky() -> void:
	var shader := load("res://shaders/sky_space.gdshader") as Shader
	if shader == null:
		push_warning("sky_space.gdshader not found — keeping default sky")
		return
	var mat := ShaderMaterial.new()
	mat.shader = shader
	_sky_mat = mat

	# Real night sky baked by pipeline/src/starmap.py. If it hasn't been baked yet
	# the sampler is simply unbound (black sky, no crash) until star_map.png exists.
	if FileAccess.file_exists("res://planet/star_map.png"):
		var star_tex := load("res://planet/star_map.png") as Texture2D
		if star_tex:
			mat.set_shader_parameter("star_map", star_tex)

	# Pass planet radius so altitude-based atmosphere thinning works correctly.
	# VoxelPlanet._ready() runs before World._ready() (children before parent),
	# so planet_radius is already populated from planet_config.json by this point.
	var planet := get_node_or_null("VoxelPlanet")
	var planet_r: float = float(planet.get("planet_radius")) if planet else 256.0
	mat.set_shader_parameter("planet_radius", planet_r)

	var sky := Sky.new()
	sky.sky_material = mat
	# Cheap incremental updates during the loading build (a full per-frame sky pass on
	# top of the heavy meshing was glitching). Switched to REALTIME in
	# _on_build_finished so the in-game star twinkle animates smoothly.
	sky.process_mode = Sky.PROCESS_MODE_INCREMENTAL
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
	gen.sky_mat = _sky_mat  # so the F3 cavity tuner's star controls reach the sky too
	add_child(gen)
	gen.setup(planet_r)
	gen.generate_planet(gen.read_generation_stage())


func _setup_sun() -> void:
	_sun.light_color = Color(1.0, 0.98, 0.92)  # warm white
	_sun.light_energy = 1.1
	_sun.shadow_enabled = true
	_sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	_sun.directional_shadow_max_distance = 600.0
	# The sun stays ON through the loading screen so the building planet is actually
	# lit (ambient-only read far too dark). _start_build orients it to graze the
	# globe from the observation-camera side; _on_build_finished re-points it to the
	# gameplay dawn direction. What we DON'T want back on the loading screen is the
	# bright sky disc/corona — visible=false didn't suppress that anyway (Godot still
	# feeds the light to the sky shader as LIGHT0). So we light with the real light
	# but gate the disc off via the sun_visible uniform, flipped to 1 on finish.
	_sun.visible = true
	if _sky_mat:
		_sky_mat.set_shader_parameter("sun_visible", 0.0)
		# Freeze the star twinkle during the loading build — the per-frame sky
		# re-render on top of the heavy meshing was glitching on some machines.
		_sky_mat.set_shader_parameter("star_twinkle_enable", 0.0)


# --- Graphics quality preset ----------------------------------------------
# Gate the expensive renderer features by the player's High/Low choice (persisted
# in GameSettings, tuned from the pause Settings → Graphics page). High = the full
# look; Low drops the screen-space passes (SSIL/SSAO) and the per-frame sky re-render
# and lightens shadows, which is the big GPU/heat saver on weak machines and the path
# toward the Mobile renderer. The non-gated env params (tonemap, ambient, SSAO/SSIL
# radii, glow) stay as set in _setup_environment; this only flips the heavy switches.
func _apply_graphics_quality() -> void:
	var low := _is_low_quality()
	var env := _world_env.environment

	# SSIL is the priciest screen-space effect for the subtlest gain → first to go.
	# SSAO is moderate; also off on Low. Glow stays on both (cheap, part of the sun look).
	env.ssil_enabled = not low
	env.ssao_enabled = not low

	# Shadows: fewer splits + shorter distance on Low (cheaper cascade render).
	_sun.directional_shadow_mode = (
		DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS if low
		else DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	)
	_sun.directional_shadow_max_distance = 300.0 if low else 600.0

	# Realtime sky (star twinkle) is a full-screen pass every frame. Only run it on
	# High, and only once gameplay starts — during the build the sky is kept
	# INCREMENTAL regardless (the loading framerate can't spare a per-frame re-render).
	var sky: Sky = env.sky
	if sky and _built:
		sky.process_mode = (
			Sky.PROCESS_MODE_INCREMENTAL if low else Sky.PROCESS_MODE_REALTIME
		)


func _is_low_quality() -> bool:
	var gs := get_node_or_null("/root/GameSettings")
	if gs and gs.has_method("get_quality"):
		return str(gs.get_quality()) == GameSettings.QUALITY_LOW
	return false


# Live toggle from the pause Settings → Graphics page. Persists the choice and
# re-applies it to the running WorldEnvironment/sun immediately.
func set_graphics_quality(q: String) -> void:
	var gs := get_node_or_null("/root/GameSettings")
	if gs and gs.has_method("set_quality"):
		gs.set_quality(q)
	_apply_graphics_quality()


# --- Progressive build + loading overlay -----------------------------------
# The faces no longer build in their own _ready(); VoxelPlanet.build_planet_async
# spreads the meshing across frames and reports progress. We show a loading
# overlay, freeze the player (no surface to stand on yet), and reveal on finish.
func _start_build() -> void:
	var planet := get_node_or_null("VoxelPlanet")
	if planet == null:
		push_warning("World: VoxelPlanet missing — cannot run progressive build")
		return
	# _building, _build_start_ms, the loading overlay and the space view are established
	# in _ready() (before the heavy generator setup) so the bar paints and the player
	# capsule is hidden immediately; guard in case _start_build is reached without that
	# prelude.
	if _loading_layer == null:
		_building = true
		_build_start_ms = Time.get_ticks_msec()
		_build_loading_overlay()
		_enter_loading_view()

	planet.build_phase.connect(_on_build_phase)
	planet.build_progress.connect(_on_build_progress)
	planet.build_finished.connect(_on_build_finished)

	# Build the always-on inner-globe voxel skin FIRST so it's the first thing that
	# pops in on the loading screen (it reads the static chunk caches, not the meshed
	# crust, so it doesn't depend on the main build). Awaited before the long crust
	# build kicks off so it never hitches mid-game.
	var gen := get_node_or_null("PlanetGenerator")
	if gen and gen.has_method("build_inner_voxels"):
		_on_build_phase("Sculpting inner globe")
		# Drive the loading bar's leading slice from the inner-globe build so it shows a
		# percentage instead of sitting at 0% (the inner build runs before the crust).
		var ivnodes := get_tree().get_nodes_in_group("inner_globe_voxels")
		if not ivnodes.is_empty() and ivnodes[0].has_signal("build_progress"):
			ivnodes[0].build_progress.connect(_on_inner_progress)
		var inner_s := Time.get_ticks_msec()
		await gen.build_inner_voxels()
		print("[load] inner-globe build wall=%dms" % (Time.get_ticks_msec() - inner_s))

	planet.build_planet_async(_spawn_pos)


# Enter the loading "watch from space" view: hide the player capsule, freeze its
# physics/input, switch to a fixed observation camera, and orient the build light.
# Done as early as possible (in _ready, before the synchronous generator setup) so the
# very first painted frame shows the space view rather than the player capsule floating
# in an empty starfield while the heavy setup blocks.
func _enter_loading_view() -> void:
	var planet := get_node_or_null("VoxelPlanet")
	var planet_r: float = float(planet.get("planet_radius")) if planet else 256.0
	var player := get_node_or_null("Player") as Node3D
	# Spawn-out reveal order keys off the player's spawn position (the location chosen
	# on the menu — see SpawnPoints / player.gd _ready()).
	_spawn_pos = player.global_position if player else Vector3(0.0, planet_r, 0.0)
	# Start every run at dawn wherever the player spawns: put the subsolar point a
	# quarter-turn (90°) east of the spawn longitude so the sun begins on the horizon,
	# plus a small extra trail (_DAWN_DEPRESSION_DEG) so it starts JUST BELOW the eastern
	# horizon and visibly rises. The spawn's longitude angle in the X-Z plane is
	# atan2(z, x); the sun is overhead at +sun_dir, so we trail it 90° + the depression.
	_sun_angle = atan2(_spawn_pos.z, _spawn_pos.x) - PI / 2.0 - deg_to_rad(_DAWN_DEPRESSION_DEG)
	if player:
		player.set_physics_process(false)  # no surface yet; also keeps frames free
		player.set_process_unhandled_input(false)  # don't let a stray click capture the mouse
		player.visible = false  # hide the capsule; we watch from space

	_setup_observation_camera(_spawn_pos, planet_r)

	# Light the assembling globe from the observation-camera side so it reads in 3D
	# during the loading screen instead of flat ambient. The camera sits along
	# +spawn_pos (see _setup_observation_camera), so putting the subsolar point near
	# that direction lights the hemisphere we're watching; a small upward tilt leaves a
	# soft terminator near the bottom edge rather than dead-flat front lighting. This is
	# build-time only — _on_build_finished re-points the sun via _apply_sun_direction().
	# The sky disc stays gated off (sun_visible uniform = 0, set in _setup_sun).
	var build_light_dir := (_spawn_pos.normalized() + Vector3.UP * 0.35).normalized()
	var build_up_ref := Vector3.UP if abs(build_light_dir.dot(Vector3.UP)) < 0.99 else Vector3.FORWARD
	_sun.look_at_from_position(Vector3.ZERO, -build_light_dir, build_up_ref)


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
	box.offset_top = -168.0  # extra room for the music-control row below the bar
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

	_build_loading_music_row(box)


# A small music player on the loading screen (‹  ♪ track  ›) so the player can change
# the track while the planet builds. The keyboard [ / ] shortcuts also work here (see
# _unhandled_input); these are the on-screen equivalent.
func _build_loading_music_row(box: VBoxContainer) -> void:
	var music := get_node_or_null("/root/Music")
	if music == null:
		return
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 10)
	box.add_child(row)

	var prev_btn := Button.new()
	prev_btn.text = "‹"
	prev_btn.focus_mode = Control.FOCUS_NONE
	prev_btn.custom_minimum_size = Vector2(40, 28)
	prev_btn.pressed.connect(func(): music.prev())
	row.add_child(prev_btn)

	_loading_track_label = Label.new()
	_loading_track_label.text = "♪"
	_loading_track_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_loading_track_label.custom_minimum_size = Vector2(280, 0)
	_loading_track_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	_loading_track_label.add_theme_constant_override("outline_size", 4)
	row.add_child(_loading_track_label)

	var next_btn := Button.new()
	next_btn.text = "›"
	next_btn.focus_mode = Control.FOCUS_NONE
	next_btn.custom_minimum_size = Vector2(40, 28)
	next_btn.pressed.connect(func(): music.next())
	row.add_child(next_btn)

	# Reflect the current track and follow any change (buttons, keys, auto-advance).
	if music.has_method("get_track_titles") and music.has_method("get_current_index"):
		var titles: Array = music.get_track_titles()
		var ci: int = music.get_current_index()
		if ci >= 0 and ci < titles.size():
			_loading_track_label.text = "♪ %s" % titles[ci]
	if music.has_signal("track_changed"):
		music.track_changed.connect(_on_loading_track_changed)


func _on_loading_track_changed(_index: int, title: String) -> void:
	if _loading_track_label and is_instance_valid(_loading_track_label):
		_loading_track_label.text = "♪ %s" % title


func _on_build_phase(label: String) -> void:
	_phase_label = label
	if _loading_label:
		_loading_label.text = label


# The inner-globe build owns the first _INNER_FRAC of the bar; the crust build owns
# the rest. Both phases route through _set_loading_frac so the bar fills once, 0→100%.
const _INNER_FRAC := 0.15


func _on_inner_progress(done: int, total: int) -> void:
	_set_loading_frac(float(done) / float(maxi(total, 1)) * _INNER_FRAC)


func _on_build_progress(done: int, total: int) -> void:
	_set_loading_frac(_INNER_FRAC + float(done) / float(maxi(total, 1)) * (1.0 - _INNER_FRAC))


func _set_loading_frac(frac: float) -> void:
	if _loading_bar:
		_loading_bar.max_value = 1.0
		_loading_bar.value = frac
	if _loading_label:
		_loading_label.text = "%s  %d%%" % [_phase_label, int(100.0 * frac)]


func _on_build_finished() -> void:
	_building = false
	_built = true  # gameplay started — _apply_graphics_quality may now enable realtime sky
	print("[load] total build wall=%dms" % (Time.get_ticks_msec() - _build_start_ms))
	# Hide the loading-screen smooth inner globe now that play begins, revealing the
	# diggable hollow voxel shell it was enclosing (kept hidden behind it during loading).
	var gen := get_node_or_null("PlanetGenerator")
	if gen and gen.has_method("reveal_inner_globe"):
		gen.reveal_inner_globe()
	# Sun on now that the player takes control, oriented to dawn at the spawn
	# (_sun_angle was set in _start_build) so the very first lit frame is correct.
	# Re-enable the sun disc/corona in the sky shader so it reappears, rising east.
	_sun.visible = true
	if _sky_mat:
		_sky_mat.set_shader_parameter("sun_visible", 1.0)
		_sky_mat.set_shader_parameter("star_twinkle_enable", 1.0)  # twinkle on in-game
	# Now that the heavy build is done, apply the graphics preset for gameplay: on
	# High this re-renders the sky every frame so the twinkle animates (kept
	# INCREMENTAL during the build to spare the loading framerate); on Low it stays
	# incremental. _built was just set true above, so the sky branch runs now.
	_apply_graphics_quality()
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
		var music := get_node_or_null("/root/Music")
		if music and music.has_signal("track_changed") and music.track_changed.is_connected(_on_loading_track_changed):
			music.track_changed.disconnect(_on_loading_track_changed)
		_loading_track_label = null
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
