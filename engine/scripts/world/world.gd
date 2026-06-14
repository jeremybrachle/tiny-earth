extends Node3D

@onready var _world_env : WorldEnvironment = $WorldEnvironment
@onready var _sun       : DirectionalLight3D = $DirectionalLight3D

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
    _setup_sky()
    _setup_environment()
    _setup_sun()
    _setup_planet_generator()


func _process(delta: float) -> void:
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
