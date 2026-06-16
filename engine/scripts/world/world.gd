extends Node3D

@onready var _world_env : WorldEnvironment = $WorldEnvironment
@onready var _sun       : DirectionalLight3D = $DirectionalLight3D

# Loading overlay (built in code, lives in this scene) shown while the planet
# assembles progressively. Kept deliberately minimal — a bottom-anchored label +
# progress bar — so the planet blooming in behind it stays visible.
var _loading_layer: CanvasLayer = null
var _loading_bar:   ProgressBar = null
var _loading_label: Label       = null
var _phase_label:   String      = ""

# While the planet assembles we watch it from a FIXED camera out in space aimed
# at North America (the spawn hemisphere, which builds first). The player is
# frozen + hidden until the build finishes — no per-frame player physics or
# input, so the heavy meshing keeps the framerate to itself. The day/night sun
# is paused so the lighting stays stable. A static view means a low build-time
# framerate just reads as a slideshow, with no input lag to feel.
var _building: bool      = false
var _obs_cam:  Camera3D  = null

# Day/night cycle. The sun is a DirectionalLight3D; rotating it sweeps the light
# direction across the planet. Press T to cycle the time scale (pause → 1× → 10×
# → 60×) — useful for checking whether a shading seam moves with the sun (a
# faceted-normal lighting discontinuity) or stays fixed (a UV/texture artifact).
const _DAY_LENGTH_SEC := 120.0          # real seconds per full revolution at 1×
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
    # The sun orbits in the equatorial (X-Z) plane about the polar (+Y) axis, so
    # an equatorial observer sees it rise on one horizon, pass directly overhead,
    # and set on the other — east-rise / west-set, no permanent high elevation.
    # (Negate _sun_angle if east/west ends up reversed for your map orientation.)
    var sun_dir := Vector3(cos(_sun_angle), 0.0, sin(_sun_angle))
    _sun.look_at_from_position(Vector3.ZERO, -sun_dir, Vector3.UP)


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
    env.ambient_light_color  = Color(0.85, 0.85, 0.80)
    env.ambient_light_energy = 0.6

    # Filmic tone mapping — photographic contrast, no blown highlights.
    env.tonemap_mode     = Environment.TONE_MAPPER_ACES
    env.tonemap_white    = 6.0
    env.tonemap_exposure = 1.0

    # SSAO — light depth cues in voxel crevices, not heavy shadow painting.
    env.ssao_enabled   = true
    env.ssao_radius    = 1.0
    env.ssao_intensity = 1.0
    env.ssao_power     = 1.0
    env.ssao_detail    = 0.5

    # SSIL — subtle indirect bounce from sunlit surfaces.
    env.ssil_enabled   = true
    env.ssil_radius    = 4.0
    env.ssil_intensity = 1.0

    # Glow — slight halo around the sun disc in the sky shader.
    env.glow_enabled    = true
    env.glow_bloom      = 0.02
    env.glow_intensity  = 0.6
    env.glow_strength   = 1.0
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
    _sun.light_color  = Color(1.0, 0.98, 0.92)  # warm white
    _sun.light_energy = 1.1
    _sun.shadow_enabled = true
    _sun.directional_shadow_mode         = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
    _sun.directional_shadow_max_distance = 600.0


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
    # Spawn-out reveal order keys off the player's spawn position (Kansas).
    var spawn_pos: Vector3 = player.global_position if player else \
        Vector3(0.0, planet_r, 0.0)
    if player:
        player.set_physics_process(false)        # no surface yet; also keeps frames free
        player.set_process_unhandled_input(false) # don't let a stray click capture the mouse
        player.visible = false                    # hide the capsule; we watch from space

    _setup_observation_camera(spawn_pos, planet_r)

    planet.build_phase.connect(_on_build_phase)
    planet.build_progress.connect(_on_build_progress)
    planet.build_finished.connect(_on_build_finished)
    planet.build_planet_async(spawn_pos)


# A fixed camera out in space aimed at the planet centre from the spawn
# hemisphere, so North America (which builds first) faces the viewer and the
# planet is framed dead-centre. No orbit, no input — purely a static vantage.
func _setup_observation_camera(spawn_pos: Vector3, planet_r: float) -> void:
    _obs_cam = Camera3D.new()
    _obs_cam.far = planet_r * 10.0
    add_child(_obs_cam)
    _obs_cam.global_position = spawn_pos.normalized() * planet_r * 2.2
    _obs_cam.look_at(Vector3.ZERO, Vector3.UP)
    _obs_cam.current = true


func _build_loading_overlay() -> void:
    _loading_layer = CanvasLayer.new()
    _loading_layer.layer = 50
    add_child(_loading_layer)

    # Bottom-anchored so the planet assembling behind it stays in full view.
    var box := VBoxContainer.new()
    box.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
    box.anchor_left = 0.5; box.anchor_right = 0.5
    box.offset_left = -220.0; box.offset_right = 220.0
    box.offset_top = -120.0;  box.offset_bottom = -48.0
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
        _loading_label.text = "%s  %d%%" % [_phase_label, int(100.0 * float(done) / float(maxi(total, 1)))]


func _on_build_finished() -> void:
    _building = false
    var player := get_node_or_null("Player") as Node3D
    if player:
        player.set_physics_process(true)
        player.set_process_unhandled_input(true)  # restore look/dig/Esc input
        player.visible = true
        if player.has_method("on_world_ready"):
            player.on_world_ready()               # reveal the crosshair HUD
        var pcam := player.get_node_or_null("Camera3D") as Camera3D
        if pcam:
            pcam.current = true   # hand control back to the player camera
    if _obs_cam:
        _obs_cam.queue_free()
        _obs_cam = null
    if _loading_layer:
        _loading_layer.queue_free()
        _loading_layer = null

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
