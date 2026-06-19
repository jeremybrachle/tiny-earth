extends Control

# Start menu — loads instantly (UI only, no planet). "Play" opens a starting-
# location picker (one spot per continent); choosing one records the selection in
# SpawnPoints and hands off to the world scene, whose World._ready() then drives
# the progressive planet build behind a loading overlay. The location is chosen
# once here and never revisited in-game (the planet is small — no mid-game
# respawn). Kept code-built to avoid hand-written .tscn NodePath fragility (see
# memory: feedback_godot_tscn_nodepath).

const WORLD_SCENE := "res://scenes/world.tscn"

# Two pages built once and toggled by visibility (no node freeing during a button
# callback). _main_page = title + Play/Quit; _spawn_page = location picker.
var _main_page: VBoxContainer
var _spawn_page: VBoxContainer


func _ready() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_build_ui()


func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	# Live 3D backdrop: a slowly turning, lit Earth (see _build_planet_backdrop).
	# Replaces the old flat ColorRect — gives the menu a "screen" and previews the
	# planet you're about to explore, while still loading instantly (one textured
	# sphere, no voxel build).
	_build_planet_backdrop()

	_main_page = _new_page()
	_build_main_page(_main_page)
	add_child(_main_page)

	_spawn_page = _new_page()
	_build_spawn_page(_spawn_page)
	# The spawn page's tall stack (heading + hint + 7 locations + Back) otherwise
	# sits low in the frame; lift it so the whole column reads as centered.
	_spawn_page.offset_top -= 50.0
	_spawn_page.offset_bottom -= 50.0
	add_child(_spawn_page)
	_spawn_page.visible = false


# --- Live planet backdrop -------------------------------------------------
# A 3D scene rendered into a SubViewport behind the menu UI: a slowly spinning,
# sun-lit globe wrapped with the equirectangular biome map, over the shared
# space-sky starfield. Pure code, instant (a single sphere — no voxel meshing),
# and visually continuous with the loading screen's space-cam shot of Earth.
const _GLOBE_SPIN_DEG_PER_SEC := 4.0  # leisurely; full turn ~90 s
# Initial spin so the globe opens over England/western Europe. The SphereMesh maps
# texture u=0 (longitude 180°, the date line / central Pacific) to the camera-facing
# +Z side at yaw 0, and yaw maps as front-longitude = −yaw − 180. So −180° puts the
# prime meridian (0° — England) at front. The leisurely spin then carries the front
# WESTWARD (Europe → Atlantic → North America), which is the "eventually reaches NA"
# motion the menu wants. Nudge if the biome map's framing shifts.
const _GLOBE_START_YAW_DEG := -180.0
# Axial tilt of the spin axis. Real Earth is 23.4°, but that leans the pole far
# enough off-screen-vertical to look wrong on the menu; a gentle lean reads better.
const _GLOBE_TILT_DEG := 10.0
var _globe: Node3D = null

# Slow celestial drift for the menu starfield (no day/night cycle here). Much
# slower than the globe spin so the backdrop feels alive without distracting from
# the menu — a full turn takes ~6 minutes. Drives the sky shader's sky_rotation.
const _SKY_DRIFT_DEG_PER_SEC := 1.0
var _sky_mat: ShaderMaterial = null
var _sky_rotation := 0.0


func _build_planet_backdrop() -> void:
	# Opaque fallback behind the viewport — covers a failed texture/shader load or
	# any letterboxing so the menu never shows engine grey.
	var back := ColorRect.new()
	back.set_anchors_preset(Control.PRESET_FULL_RECT)
	back.color = Color(0.01, 0.01, 0.02)
	back.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(back)

	var svc := SubViewportContainer.new()
	svc.set_anchors_preset(Control.PRESET_FULL_RECT)
	svc.stretch = true  # SubViewport tracks the container size
	svc.mouse_filter = Control.MOUSE_FILTER_IGNORE  # clicks fall through to the buttons
	add_child(svc)

	var vp := SubViewport.new()
	vp.own_world_3d = true  # its own 3D world (this is a 2D/Control scene)
	vp.msaa_3d = Viewport.MSAA_4X  # smooth the globe silhouette
	svc.add_child(vp)

	# Space sky (stars + a sun disc). The shader's atmosphere fades out once the
	# camera is well above planet_radius; with planet_radius = 1 and the camera at
	# distance 3 we get a clean starfield with no atmospheric wash.
	var we := WorldEnvironment.new()
	var env := Environment.new()
	var sky_shader := load("res://shaders/sky_space.gdshader") as Shader
	if sky_shader:
		var sky_mat := ShaderMaterial.new()
		sky_mat.shader = sky_shader
		sky_mat.set_shader_parameter("planet_radius", 1.0)
		_sky_mat = sky_mat
		var sky := Sky.new()
		sky.sky_material = sky_mat
		env.background_mode = Environment.BG_SKY
		env.sky = sky
	else:
		env.background_mode = Environment.BG_COLOR
		env.background_color = Color(0.01, 0.01, 0.02)
	# Dim warm fill so the night side of the globe isn't pitch black.
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.55, 0.60, 0.72)
	env.ambient_light_energy = 0.28
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	we.environment = env
	vp.add_child(we)

	var cam := Camera3D.new()
	cam.fov = 42.0
	vp.add_child(cam)
	cam.position = Vector3(0.0, 0.25, 3.0)
	cam.look_at(Vector3.ZERO, Vector3.UP)

	# Sun comes from upper-left-front: lights the side toward the viewer and leaves
	# a soft day/night terminator on the globe, matching the in-game look.
	var sun := DirectionalLight3D.new()
	vp.add_child(sun)
	sun.position = Vector3(-2.0, 1.4, 2.0)
	sun.look_at(Vector3.ZERO, Vector3.UP)
	sun.light_color = Color(1.0, 0.98, 0.92)
	sun.light_energy = 1.25

	# Gentle axial tilt on the parent, so the globe spins about a slightly leaned
	# axis (a hint of Earth's tilt without throwing the pole off the top of frame).
	var tilt := Node3D.new()
	tilt.rotation = Vector3(0.0, 0.0, deg_to_rad(_GLOBE_TILT_DEG))
	vp.add_child(tilt)

	_globe = MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 1.0
	sphere.height = 2.0
	sphere.radial_segments = 96
	sphere.rings = 48
	_globe.mesh = sphere
	var smat := StandardMaterial3D.new()
	var tex := load("res://planet/earth_biome_map.png") as Texture2D
	if tex:
		smat.albedo_texture = tex
		# Nearest filtering keeps the biome map's hard color blocks crisp, matching
		# the voxel aesthetic instead of smearing them into a smooth globe.
		smat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	else:
		smat.albedo_color = Color(0.20, 0.40, 0.60)
	smat.roughness = 1.0
	smat.metallic = 0.0
	_globe.material_override = smat
	_globe.rotation.y = deg_to_rad(_GLOBE_START_YAW_DEG)  # open facing North America
	tilt.add_child(_globe)


func _process(delta: float) -> void:
	if _globe:
		_globe.rotate_y(deg_to_rad(_GLOBE_SPIN_DEG_PER_SEC) * delta)
	if _sky_mat:
		_sky_rotation += deg_to_rad(_SKY_DRIFT_DEG_PER_SEC) * delta
		_sky_mat.set_shader_parameter("sky_rotation", _sky_rotation)


# A menu button with a translucent dark panel + hover/press states, readable over
# the moving globe. focus_mode NONE drops the keyboard focus ring (mouse-driven).
func _make_menu_button(label_text: String, min_height: float) -> Button:
	var b := Button.new()
	b.text = label_text
	b.custom_minimum_size = Vector2(0, min_height)
	b.focus_mode = Control.FOCUS_NONE
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0.07, 0.10, 0.16, 0.85)
	normal.set_corner_radius_all(6)
	normal.set_content_margin_all(8)
	normal.set_border_width_all(1)
	normal.border_color = Color(0.30, 0.45, 0.70, 0.6)
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = Color(0.13, 0.20, 0.32, 0.95)
	hover.border_color = Color(0.50, 0.70, 1.0, 0.9)
	var pressed := normal.duplicate() as StyleBoxFlat
	pressed.bg_color = Color(0.05, 0.07, 0.12, 0.95)
	b.add_theme_stylebox_override("normal", normal)
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", pressed)
	b.add_theme_stylebox_override("focus", normal)
	return b


# Dark outline so label text stays legible wherever it sits over the bright globe.
func _add_label_outline(label: Label, size: int) -> void:
	label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	label.add_theme_constant_override("outline_size", size)


# A centered vertical column the pages share, wide enough for the long location
# labels ("Amazon Basin · South America").
func _new_page() -> VBoxContainer:
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER)
	box.anchor_left = 0.5
	box.anchor_top = 0.5
	box.anchor_right = 0.5
	box.anchor_bottom = 0.5
	box.offset_left = -220.0
	box.offset_right = 220.0
	box.offset_top = -240.0
	box.offset_bottom = 240.0
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 14)
	return box


func _build_main_page(box: VBoxContainer) -> void:
	var title := Label.new()
	title.text = "Tiny Earth"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 52)
	_add_label_outline(title, 8)
	box.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "A diggable voxel Earth built from real geography"
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_color_override("font_color", Color(0.78, 0.84, 0.94))
	_add_label_outline(subtitle, 5)
	box.add_child(subtitle)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 28)
	box.add_child(spacer)

	var play := _make_menu_button("Play", 46)
	play.pressed.connect(_show_spawn_page)
	box.add_child(play)

	var quit := _make_menu_button("Quit", 46)
	quit.pressed.connect(_on_quit_pressed)
	box.add_child(quit)


func _build_spawn_page(box: VBoxContainer) -> void:
	# Top spacer fills the room the (now removed) hint used to take, so the buttons
	# stay put while the heading sits lower — more centered over the picker.
	var top_spacer := Control.new()
	top_spacer.custom_minimum_size = Vector2(0, 44)
	box.add_child(top_spacer)

	var heading := Label.new()
	heading.text = "Choose a starting location"
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	heading.add_theme_font_size_override("font_size", 30)
	_add_label_outline(heading, 6)
	box.add_child(heading)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 12)
	box.add_child(spacer)

	for i in SpawnPoints.LOCATIONS.size():
		var loc: Dictionary = SpawnPoints.LOCATIONS[i]
		var b := _make_menu_button(loc["name"], 38)
		b.pressed.connect(_on_location_pressed.bind(i))
		box.add_child(b)

	var back := _make_menu_button("← Back", 38)
	back.pressed.connect(_show_main_page)
	box.add_child(back)


func _show_spawn_page() -> void:
	_main_page.visible = false
	_spawn_page.visible = true


func _show_main_page() -> void:
	_spawn_page.visible = false
	_main_page.visible = true


func _on_location_pressed(index: int) -> void:
	SpawnPoints.selected_index = index
	get_tree().change_scene_to_file(WORLD_SCENE)


func _on_quit_pressed() -> void:
	get_tree().quit()
