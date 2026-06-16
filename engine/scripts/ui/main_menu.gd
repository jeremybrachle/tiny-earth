extends Control

# Start menu — loads instantly (UI only, no planet). "Play" hands off to the
# world scene, whose World._ready() then drives the progressive planet build
# behind a loading overlay. Kept code-built to avoid hand-written .tscn NodePath
# fragility (see memory: feedback_godot_tscn_nodepath).

const WORLD_SCENE := "res://scenes/world.tscn"


func _ready() -> void:
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_build_ui()


func _build_ui() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var bg := ColorRect.new()
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.color = Color(0.02, 0.03, 0.06)
	add_child(bg)

	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER)
	box.anchor_left = 0.5; box.anchor_top = 0.5
	box.anchor_right = 0.5; box.anchor_bottom = 0.5
	box.offset_left = -160.0; box.offset_right = 160.0
	box.offset_top = -150.0;  box.offset_bottom = 150.0
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 16)
	add_child(box)

	var title := Label.new()
	title.text = "Tiny Earth"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 52)
	box.add_child(title)

	var subtitle := Label.new()
	subtitle.text = "A diggable, hollow voxel Earth"
	subtitle.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle.add_theme_color_override("font_color", Color(0.66, 0.72, 0.84))
	box.add_child(subtitle)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 28)
	box.add_child(spacer)

	var play := Button.new()
	play.text = "Play"
	play.custom_minimum_size = Vector2(0, 46)
	play.pressed.connect(_on_play_pressed)
	box.add_child(play)

	var quit := Button.new()
	quit.text = "Quit"
	quit.custom_minimum_size = Vector2(0, 46)
	quit.pressed.connect(_on_quit_pressed)
	box.add_child(quit)


func _on_play_pressed() -> void:
	get_tree().change_scene_to_file(WORLD_SCENE)


func _on_quit_pressed() -> void:
	get_tree().quit()
