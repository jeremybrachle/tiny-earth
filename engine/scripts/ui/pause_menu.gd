extends CanvasLayer

# Esc-driven pause overlay. Built in code (like main_menu.gd) to avoid hand-written
# .tscn NodePath fragility (see memory: feedback_godot_tscn_nodepath). Instantiated
# by World only after the planet build finishes, so Esc can't pause mid-load.
#
# Pause model: this node runs with PROCESS_MODE_ALWAYS so it keeps receiving input
# while get_tree().paused is true; the player + planet (default PAUSABLE) freeze and
# stop receiving input, so the menu has the game world to itself. World is the only
# pausable context — the main menu doesn't instantiate this.
#
# Page model: a small stack of centered pages (main → settings → audio / graphics).
# Esc walks back up one level (audio/graphics → settings → main → resume). Settings
# → Graphics tunes the live water shader; Settings → Audio holds the music volume.

const MAIN_MENU_SCENE := "res://scenes/main_menu.tscn"
const WATER_SHADER_PATH := "res://shaders/water.gdshader"

# Player-tunable water uniforms: name, min, max, step, default. Defaults mirror the
# water.gdshader uniform defaults; "Reset to default" restores these.
const WATER_PARAMS := [
	["albedo_mult",  0.25, 3.0, 0.01, 2.49],  # brightness
	["roughness",    0.0,  1.0, 0.01, 0.28],  # lower = sharper sun glint
	["specular_str", 0.0,  1.0, 0.01, 0.48],  # highlight strength
	["water_alpha",  0.0,  1.0, 0.01, 0.36],  # opacity
	["emission_str", 0.0,  1.0, 0.01, 0.36],  # self-glow
]

var _dim: ColorRect = null
var _pages := {}          # page name -> root Control (a CenterContainer)
var _page := ""           # currently shown page name
var _paused := false

# Water tuning state (Graphics page).
var _water_mats: Array = []          # unique water ShaderMaterials, collected on open
var _water_sliders := {}             # param name -> HSlider
var _water_value_labels := {}        # param name -> Label


func _ready() -> void:
	layer = 60
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	visible = false


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.keycode == KEY_ESCAPE and event.pressed and not event.echo:
		if _paused:
			# Esc backs up one page level; from the top page it resumes.
			match _page:
				"audio", "graphics":
					_show("settings")
				"settings":
					_show("main")
				_:
					_resume()
		else:
			_open()
		get_viewport().set_input_as_handled()


func _open() -> void:
	_paused = true
	get_tree().paused = true
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_show("main")
	visible = true


func _resume() -> void:
	_paused = false
	get_tree().paused = false
	# Recapture the mouse for look/dig; the player also recaptures on left-click.
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	visible = false


func _show(page: String) -> void:
	_page = page
	for pg in _pages:
		_pages[pg].visible = (pg == page)
	if page == "graphics":
		_collect_water_mats()
		_sync_water_sliders()


# --- UI construction -------------------------------------------------------
func _build_ui() -> void:
	_dim = ColorRect.new()
	_dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_dim.color = Color(0.02, 0.03, 0.06, 0.72)
	# STOP swallows clicks so nothing leaks through to the (paused) world below.
	_dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_dim)

	_build_main_page()
	_build_settings_page()
	_build_audio_page()
	_build_graphics_page()
	_show("main")


# A full-screen CenterContainer keeps each page centered and auto-sized to its
# content (so the taller Graphics page lays out cleanly without manual offsets).
func _make_page(name: String) -> VBoxContainer:
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	_pages[name] = center

	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(360, 0)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 14)
	center.add_child(box)
	return box


func _add_title(box: VBoxContainer, text: String, size: int) -> void:
	var title := Label.new()
	title.text = text
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", size)
	box.add_child(title)


func _add_spacer(box: VBoxContainer, h: float) -> void:
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, h)
	box.add_child(spacer)


func _make_button(text: String, handler: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 46)
	b.pressed.connect(handler)
	return b


func _build_main_page() -> void:
	var box := _make_page("main")
	_add_title(box, "Paused", 48)
	_add_spacer(box, 20)
	box.add_child(_make_button("Resume", _resume))
	box.add_child(_make_button("Settings", func(): _show("settings")))
	box.add_child(_make_button("Quit to Menu", _on_quit_to_menu))
	box.add_child(_make_button("Quit", _on_quit))


func _build_settings_page() -> void:
	var box := _make_page("settings")
	_add_title(box, "Settings", 40)
	_add_spacer(box, 16)
	box.add_child(_make_button("Audio", func(): _show("audio")))
	box.add_child(_make_button("Graphics", func(): _show("graphics")))
	_add_spacer(box, 8)
	box.add_child(_make_button("Back", func(): _show("main")))


func _build_audio_page() -> void:
	var box := _make_page("audio")
	_add_title(box, "Audio", 40)
	_add_spacer(box, 12)

	var music_label := Label.new()
	music_label.text = "Music Volume"
	music_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(music_label)

	# Music is currently the only audio system; SFX sliders land here once SFX exist.
	var music_slider := HSlider.new()
	music_slider.custom_minimum_size = Vector2(0, 24)
	music_slider.min_value = 0.0
	music_slider.max_value = 1.0
	music_slider.step = 0.01
	var music := get_node_or_null("/root/Music")
	music_slider.value = music.get_volume_linear() if music else 0.5
	music_slider.value_changed.connect(_on_music_volume_changed)
	box.add_child(music_slider)

	_add_spacer(box, 16)
	box.add_child(_make_button("Back", func(): _show("settings")))


func _build_graphics_page() -> void:
	var box := _make_page("graphics")
	_add_title(box, "Graphics", 40)
	_add_spacer(box, 6)

	var water_label := Label.new()
	water_label.text = "Water Appearance"
	water_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(water_label)

	for p in WATER_PARAMS:
		var pname: String = p[0]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		box.add_child(row)

		var lbl := Label.new()
		lbl.text = pname
		lbl.custom_minimum_size = Vector2(100, 0)
		row.add_child(lbl)

		var slider := HSlider.new()
		slider.min_value = p[1]
		slider.max_value = p[2]
		slider.step = p[3]
		slider.value = p[4]
		slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		slider.value_changed.connect(func(v): _apply_water(pname, v))
		row.add_child(slider)
		_water_sliders[pname] = slider

		var vlbl := Label.new()
		vlbl.text = "%.2f" % float(p[4])
		vlbl.custom_minimum_size = Vector2(44, 0)
		vlbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		row.add_child(vlbl)
		_water_value_labels[pname] = vlbl

	_add_spacer(box, 10)
	box.add_child(_make_button("Reset to Default", _reset_water))
	box.add_child(_make_button("Back", func(): _show("settings")))


# --- Water tuning ----------------------------------------------------------
# Each cube_face / inner_cube_face makes its OWN ShaderMaterial.new() for water, so
# there are ~12 separate water materials sharing one shader. Collect every unique one
# (dedup by id) so a slider can push its value to all of them at once.
func _collect_water_mats() -> void:
	var seen := {}
	_water_mats.clear()
	var stack: Array = [get_tree().root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D:
			var m: Material = (n as MeshInstance3D).material_override
			if m is ShaderMaterial:
				var sh: Shader = (m as ShaderMaterial).shader
				if sh != null and sh.resource_path == WATER_SHADER_PATH:
					var id := m.get_instance_id()
					if not seen.has(id):
						seen[id] = true
						_water_mats.append(m)
		for c in n.get_children():
			stack.append(c)


# Initialise the sliders from the live material values (falling back to the shader
# default when a uniform hasn't been overridden yet), so the page reflects reality.
func _sync_water_sliders() -> void:
	var mat: ShaderMaterial = _water_mats[0] if not _water_mats.is_empty() else null
	for p in WATER_PARAMS:
		var pname: String = p[0]
		var v = mat.get_shader_parameter(pname) if mat else null
		if v == null:
			v = p[4]
		_water_sliders[pname].set_value_no_signal(float(v))
		_set_water_value_label(pname, float(v))


func _apply_water(pname: String, value: float) -> void:
	for m in _water_mats:
		(m as ShaderMaterial).set_shader_parameter(pname, value)
	_set_water_value_label(pname, value)


func _set_water_value_label(pname: String, value: float) -> void:
	_water_value_labels[pname].text = "%.2f" % value


func _reset_water() -> void:
	for p in WATER_PARAMS:
		var pname: String = p[0]
		_water_sliders[pname].set_value_no_signal(float(p[4]))
		_apply_water(pname, float(p[4]))


# --- Handlers --------------------------------------------------------------
func _on_music_volume_changed(v: float) -> void:
	var music := get_node_or_null("/root/Music")
	if music:
		music.set_volume_linear(v)


func _on_quit_to_menu() -> void:
	# Unpause before the scene change, or the freshly loaded menu inherits paused.
	get_tree().paused = false
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	get_tree().change_scene_to_file(MAIN_MENU_SCENE)


func _on_quit() -> void:
	get_tree().quit()
