extends CanvasLayer

# Esc-driven pause overlay. Built in code (like main_menu.gd) to avoid hand-written
# .tscn NodePath fragility (see memory: feedback_godot_tscn_nodepath). Instantiated
# by World only after the planet build finishes, so Esc can't pause mid-load.
#
# Pause model: this node runs with PROCESS_MODE_ALWAYS so it keeps receiving input
# while get_tree().paused is true; the player + planet (default PAUSABLE) freeze and
# stop receiving input, so the menu has the game world to itself. World is the only
# pausable context — the main menu doesn't instantiate this.

const MAIN_MENU_SCENE := "res://scenes/main_menu.tscn"

var _dim:            ColorRect = null
var _main_panel:     VBoxContainer = null
var _settings_panel: VBoxContainer = null
var _paused := false


func _ready() -> void:
	layer = 60
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	visible = false


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.keycode == KEY_ESCAPE and event.pressed and not event.echo:
		# Esc backs out of Settings first, otherwise toggles the pause overlay.
		if _paused and _settings_panel.visible:
			_show_main()
		else:
			_toggle()
		get_viewport().set_input_as_handled()


func _toggle() -> void:
	if _paused:
		_resume()
	else:
		_open()


func _open() -> void:
	_paused = true
	get_tree().paused = true
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_show_main()
	visible = true


func _resume() -> void:
	_paused = false
	get_tree().paused = false
	# Recapture the mouse for look/dig; the player also recaptures on left-click.
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	visible = false


# --- UI construction -------------------------------------------------------
func _build_ui() -> void:
	_dim = ColorRect.new()
	_dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_dim.color = Color(0.02, 0.03, 0.06, 0.72)
	# STOP swallows clicks so nothing leaks through to the (paused) world below.
	_dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_dim)

	_main_panel = _make_panel()
	_settings_panel = _make_panel()
	_build_main_panel()
	_build_settings_panel()
	_settings_panel.visible = false


# A centered VBox shell shared by the main + settings panels.
func _make_panel() -> VBoxContainer:
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER)
	box.anchor_left = 0.5; box.anchor_top = 0.5
	box.anchor_right = 0.5; box.anchor_bottom = 0.5
	box.offset_left = -160.0; box.offset_right = 160.0
	box.offset_top = -170.0;  box.offset_bottom = 170.0
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 16)
	add_child(box)
	return box


func _build_main_panel() -> void:
	var title := Label.new()
	title.text = "Paused"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 48)
	_main_panel.add_child(title)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 20)
	_main_panel.add_child(spacer)

	_main_panel.add_child(_make_button("Resume", _resume))
	_main_panel.add_child(_make_button("Settings", _show_settings))
	_main_panel.add_child(_make_button("Quit to Menu", _on_quit_to_menu))
	_main_panel.add_child(_make_button("Quit", _on_quit))


func _build_settings_panel() -> void:
	var title := Label.new()
	title.text = "Settings"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 40)
	_settings_panel.add_child(title)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 12)
	_settings_panel.add_child(spacer)

	var music_label := Label.new()
	music_label.text = "Music Volume"
	music_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_settings_panel.add_child(music_label)

	# Music is currently the only audio system; SFX sliders land here once SFX exist.
	var music_slider := HSlider.new()
	music_slider.custom_minimum_size = Vector2(0, 24)
	music_slider.min_value = 0.0
	music_slider.max_value = 1.0
	music_slider.step = 0.01
	var music := get_node_or_null("/root/Music")
	music_slider.value = music.get_volume_linear() if music else 0.5
	music_slider.value_changed.connect(_on_music_volume_changed)
	_settings_panel.add_child(music_slider)

	var spacer2 := Control.new()
	spacer2.custom_minimum_size = Vector2(0, 16)
	_settings_panel.add_child(spacer2)

	_settings_panel.add_child(_make_button("Back", _show_main))


func _make_button(text: String, handler: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 46)
	b.pressed.connect(handler)
	return b


# --- Panel switching + button handlers -------------------------------------
func _show_main() -> void:
	_main_panel.visible = true
	_settings_panel.visible = false


func _show_settings() -> void:
	_main_panel.visible = false
	_settings_panel.visible = true


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
