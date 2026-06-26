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

# Player-tunable water uniforms: name, min, max, step. Defaults + persistence live
# in the GameSettings autoload (GameSettings.WATER_DEFAULTS), the single source of
# truth, so the sliders, "Reset to Default", and the saved file can't drift.
const WATER_PARAMS := [
	["albedo_mult", 0.25, 3.0, 0.01],  # brightness
	["roughness", 0.0, 1.0, 0.01],  # lower = sharper sun glint
	["specular_str", 0.0, 1.0, 0.01],  # highlight strength
	["water_alpha", 0.0, 1.0, 0.01],  # opacity
	["emission_str", 0.0, 1.0, 0.01],  # self-glow
]

var _dim: ColorRect = null
var _pages := {}  # page name -> root Control (a CenterContainer)
var _page := ""  # currently shown page name
var _paused := false

# Water tuning state (Graphics page).
var _water_mats: Array = []  # unique water ShaderMaterials, collected on open
var _water_sliders := {}  # param name -> HSlider
var _water_value_labels := {}  # param name -> Label

# Audio page: the track picker, kept in sync with the Music autoload (which also
# changes track on auto-advance and the in-game [ / ] keys).
var _track_opt: OptionButton = null


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
	_set_hud_suppressed(true)  # hide the gameplay crosshair behind the menu
	_duck_music(true)  # drop the music a touch while paused
	_show("main")
	visible = true


func _resume() -> void:
	_paused = false
	get_tree().paused = false
	_set_hud_suppressed(false)
	_duck_music(false)
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

	# Track picker: pick any track from the playlist; prev/next step through it. The
	# dropdown stays synced via Music.track_changed (auto-advance + the in-game keys).
	_add_spacer(box, 12)
	var track_label := Label.new()
	track_label.text = "Track"
	track_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(track_label)

	_track_opt = OptionButton.new()
	_track_opt.custom_minimum_size = Vector2(0, 32)
	if music and music.has_method("get_track_titles"):
		var titles: Array = music.get_track_titles()
		for i in titles.size():
			_track_opt.add_item(str(titles[i]), i)
		_track_opt.selected = music.get_current_index()
		_track_opt.item_selected.connect(_on_track_selected)
		if music.has_signal("track_changed"):
			music.track_changed.connect(_on_music_track_changed)
	box.add_child(_track_opt)

	var nav_row := HBoxContainer.new()
	nav_row.add_theme_constant_override("separation", 8)
	nav_row.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_child(nav_row)
	var prev_btn := _make_button("‹ Prev", _on_track_prev)
	prev_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nav_row.add_child(prev_btn)
	var next_btn := _make_button("Next ›", _on_track_next)
	next_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nav_row.add_child(next_btn)

	# Shuffle: randomize the rotation (auto-advance + Next pick a random track).
	var shuffle_chk := CheckBox.new()
	shuffle_chk.text = "Shuffle"
	if music and music.has_method("get_shuffle"):
		shuffle_chk.button_pressed = music.get_shuffle()
		shuffle_chk.toggled.connect(_on_shuffle_toggled)
	box.add_child(shuffle_chk)

	_add_spacer(box, 16)
	box.add_child(_make_button("Back", func(): _show("settings")))


func _build_graphics_page() -> void:
	var box := _make_page("graphics")
	_add_title(box, "Graphics", 40)
	_add_spacer(box, 6)

	# Quality preset: High = full post-FX (SSIL/SSAO/glow/realtime sky/4-split shadows);
	# Low drops the heavy screen-space passes to run cooler on weak GPUs. Applied live
	# (and persisted) via World.set_graphics_quality().
	var quality_row := HBoxContainer.new()
	quality_row.add_theme_constant_override("separation", 8)
	box.add_child(quality_row)

	var quality_lbl := Label.new()
	quality_lbl.text = "Quality"
	quality_lbl.custom_minimum_size = Vector2(100, 0)
	quality_row.add_child(quality_lbl)

	var quality_opt := OptionButton.new()
	quality_opt.add_item("High", 0)
	quality_opt.add_item("Low", 1)
	quality_opt.selected = 1 if GameSettings.get_quality() == GameSettings.QUALITY_LOW else 0
	quality_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	quality_opt.item_selected.connect(_on_quality_selected)
	quality_row.add_child(quality_opt)

	_add_spacer(box, 10)

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

		var saved: float = GameSettings.get_water(pname)
		var slider := HSlider.new()
		slider.min_value = p[1]
		slider.max_value = p[2]
		slider.step = p[3]
		slider.value = saved
		slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		slider.value_changed.connect(func(v): _apply_water(pname, v))
		row.add_child(slider)
		_water_sliders[pname] = slider

		var vlbl := Label.new()
		vlbl.text = "%.2f" % saved
		vlbl.custom_minimum_size = Vector2(44, 0)
		vlbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		row.add_child(vlbl)
		_water_value_labels[pname] = vlbl

	_add_spacer(box, 10)
	box.add_child(_make_button("Reset to Default", _reset_water))
	box.add_child(_make_button("Back", func(): _show("settings")))


# --- Water tuning ----------------------------------------------------------
# Each cube_face / inner_cube_face makes its OWN ShaderMaterial.new() for water, so
# there are ~12 separate water materials sharing one shader. GameSettings walks the
# tree and dedups them; we cache that list so a slider can push to all at once.
func _collect_water_mats() -> void:
	_water_mats = GameSettings.collect_water_mats()


# Sync the sliders from the saved settings (GameSettings is the source of truth;
# it has already been applied to the live materials on world load).
func _sync_water_sliders() -> void:
	for p in WATER_PARAMS:
		var pname: String = p[0]
		var v: float = GameSettings.get_water(pname)
		_water_sliders[pname].set_value_no_signal(v)
		_set_water_value_label(pname, v)


func _apply_water(pname: String, value: float) -> void:
	for m in _water_mats:
		(m as ShaderMaterial).set_shader_parameter(pname, value)
	_set_water_value_label(pname, value)
	GameSettings.set_water(pname, value)  # persist to user://settings.cfg


func _on_quality_selected(idx: int) -> void:
	var q: String = GameSettings.QUALITY_LOW if idx == 1 else GameSettings.QUALITY_HIGH
	# PauseMenu is a child of World (World adds it post-build); reach up to apply live.
	var world := get_parent()
	if world and world.has_method("set_graphics_quality"):
		world.set_graphics_quality(q)


func _set_water_value_label(pname: String, value: float) -> void:
	_water_value_labels[pname].text = "%.2f" % value


func _reset_water() -> void:
	GameSettings.reset_water()
	for p in WATER_PARAMS:
		var pname: String = p[0]
		var v: float = GameSettings.get_water(pname)
		_water_sliders[pname].set_value_no_signal(v)
		_apply_water(pname, v)


# --- Pause side-effects ----------------------------------------------------
# The player is a sibling under World (World adds both); reach it to toggle its HUD.
func _set_hud_suppressed(suppressed: bool) -> void:
	var player := get_parent().get_node_or_null("Player")
	if player and player.has_method("set_hud_suppressed"):
		player.set_hud_suppressed(suppressed)


func _duck_music(ducked: bool) -> void:
	var music := get_node_or_null("/root/Music")
	if music and music.has_method("set_paused_duck"):
		music.set_paused_duck(ducked)


# --- Handlers --------------------------------------------------------------
func _on_music_volume_changed(v: float) -> void:
	var music := get_node_or_null("/root/Music")
	if music:
		music.set_volume_linear(v)


func _on_track_selected(idx: int) -> void:
	var music := get_node_or_null("/root/Music")
	if music:
		music.play_index(idx)


func _on_track_prev() -> void:
	var music := get_node_or_null("/root/Music")
	if music:
		music.prev()


func _on_track_next() -> void:
	var music := get_node_or_null("/root/Music")
	if music:
		music.next()


func _on_shuffle_toggled(on: bool) -> void:
	var music := get_node_or_null("/root/Music")
	if music:
		music.set_shuffle(on)


# Keep the dropdown's selection in sync when the track changes from elsewhere
# (auto-advance at a track's end, or the in-game [ / ] keys). set_value_no_signal
# equivalent for OptionButton: setting `selected` directly doesn't emit item_selected.
func _on_music_track_changed(index: int, _title: String) -> void:
	if _track_opt and index >= 0 and index < _track_opt.item_count:
		_track_opt.selected = index


func _on_quit_to_menu() -> void:
	# Unpause before the scene change, or the freshly loaded menu inherits paused.
	get_tree().paused = false
	_duck_music(false)  # leave the menu's music at full level
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	get_tree().change_scene_to_file(MAIN_MENU_SCENE)


func _on_quit() -> void:
	get_tree().quit()
