extends CanvasLayer

# TEMPORARY debug overlay to live-tune the hollow cavity's look. Toggle with F3.
# Tunes TWO shaders at once:
#   • the inner mini-globe palette (inner_globe.gdshader) — ocean/land/snow colours
#     + overall brightness, on the single globe material passed to setup().
#   • the cavity ceiling city lights (inner_voxel.gdshader) — colour + brightness/
#     gain/gamma, pushed across ALL inner faces (looked up lazily via the
#     "voxel_planet" group, since faces build async after this overlay is created).
# Each colour is a click-to-pick colour WHEEL (ColorPickerButton), not R/G/B dials.
# The "Print to console" button dumps copy-paste-ready shader-default lines so we
# can lock the chosen values into the shaders.
#
# Only created in debug builds (planet_generator.gd _build_inner_sphere). Delete
# this file + its instantiation to remove the tool.

# target: "globe" → the globe material; "city" → all inner ceiling materials;
# "stars" → BOTH the ceiling materials AND the sky material (sky_space.gdshader),
# tuned in lockstep so the cavity ceiling and the real sky agree.
# Defaults MUST mirror each shader's uniform defaults so the controls start where
# the shaders do.
const COLOR_SPECS := [
	{"name": "city_color", "target": "city", "def": Color(1.000, 0.800, 0.420)},
	# Inner-globe water glass tint + transparency (inner_globe_glass.gdshader). The alpha
	# channel IS the see-through amount, so this picker edits alpha.
	{"name": "glass_color", "target": "glass", "def": Color(0.165, 0.278, 0.341, 0.420), "alpha": true},
]
const FLOAT_SPECS := [
	# Inner-globe diggable voxel volume (inner_globe_blocks.gdshader) — live brightness +
	# block-edge controls, resolved via the "inner_globe_voxels" group.
	{"name": "brightness", "target": "blocks", "def": 0.45, "lo": 0.0, "hi": 1.5},
	{"name": "edge_dark", "target": "blocks", "def": 0.45, "lo": 0.0, "hi": 1.0},
	{"name": "edge_width", "target": "blocks", "def": 0.06, "lo": 0.0, "hi": 0.25},
	# Glass grid frame (top face only). Higher edge_dark = LIGHTER lines; lower
	# edge_width = THINNER. "uniform" overrides the shader-param name so these don't
	# collide with the blocks shader's edge_dark/edge_width in the _vals map.
	{"name": "glass_edge_dark", "uniform": "edge_dark", "target": "glass", "def": 0.55, "lo": 0.0, "hi": 1.0},
	{"name": "glass_edge_width", "uniform": "edge_width", "target": "glass", "def": 0.04, "lo": 0.0, "hi": 0.25},
	{"name": "glass_edge_alpha", "uniform": "edge_alpha", "target": "glass", "def": 0.85, "lo": 0.0, "hi": 1.0},
	{"name": "glass_etch_alpha", "uniform": "etch_alpha", "target": "glass", "def": 0.10, "lo": 0.0, "hi": 1.0},
	{"name": "palette_brightness", "target": "globe", "def": 1.0, "lo": 0.2, "hi": 3.0},
	{"name": "city_brightness", "target": "city", "def": 1.38, "lo": 0.0, "hi": 8.0},
	{"name": "city_gain", "target": "city", "def": 7.35, "lo": 0.5, "hi": 8.0},
	{"name": "city_gamma", "target": "city", "def": 2.79, "lo": 0.5, "hi": 4.0},
	# Stars — one slider drives the same uniform on both the ceiling and the sky.
	# The two shaders ship slightly different brightness defaults (the ceiling reads
	# darker), so the slider starts at the sky's value; dragging locks them together.
	{"name": "star_brightness", "target": "stars", "def": 6.0, "lo": 0.0, "hi": 6.0},
	{"name": "star_twinkle_speed", "target": "stars", "def": 2.19, "lo": 0.0, "hi": 6.0},
	{"name": "star_twinkle_floor", "target": "stars", "def": 0.04, "lo": 0.0, "hi": 1.0},
]

var _globe_mat: ShaderMaterial
var _sky_mat: ShaderMaterial  # sky_space.gdshader, for the shared "Stars" controls
var _vals := {}  # spec name → current value
var _targets := {}  # spec name → "globe" | "city" | "stars" | "blocks" | "glass"
var _uniforms := {}  # spec name → actual shader uniform name (defaults to the spec name)
var _summary: Label


func setup(globe_mat: ShaderMaterial, sky_mat: ShaderMaterial = null) -> void:
	_globe_mat = globe_mat
	_sky_mat = sky_mat
	layer = 128

	var panel := PanelContainer.new()
	panel.position = Vector2(12, 12)
	add_child(panel)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(360, 560)
	panel.add_child(scroll)

	var vb := VBoxContainer.new()
	vb.custom_minimum_size.x = 340
	scroll.add_child(vb)

	var title := Label.new()
	title.text = "Cavity tuner  —  F3 to toggle"
	vb.add_child(title)

	_add_header(vb, "Inner globe (blocks)")
	for spec in FLOAT_SPECS:
		if spec["target"] == "blocks":
			_add_float_row(vb, spec)

	_add_header(vb, "Inner globe water (glass)")
	for spec in COLOR_SPECS:
		if spec["target"] == "glass":
			_add_color_row(vb, spec)
	for spec in FLOAT_SPECS:
		if spec["target"] == "glass":
			_add_float_row(vb, spec)

	_add_header(vb, "Globe palette (loading preview)")
	for spec in COLOR_SPECS:
		if spec["target"] == "globe":
			_add_color_row(vb, spec)
	for spec in FLOAT_SPECS:
		if spec["target"] == "globe":
			_add_float_row(vb, spec)

	_add_header(vb, "City lights (ceiling)")
	for spec in COLOR_SPECS:
		if spec["target"] == "city":
			_add_color_row(vb, spec)
	for spec in FLOAT_SPECS:
		if spec["target"] == "city":
			_add_float_row(vb, spec)

	_add_header(vb, "Stars (sky + ceiling)")
	for spec in COLOR_SPECS:
		if spec["target"] == "stars":
			_add_color_row(vb, spec)
	for spec in FLOAT_SPECS:
		if spec["target"] == "stars":
			_add_float_row(vb, spec)

	var copy_btn := Button.new()
	copy_btn.text = "Print values to console"
	copy_btn.pressed.connect(_print_to_console)
	vb.add_child(copy_btn)

	_summary = Label.new()
	_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vb.add_child(_summary)
	_update_summary()

	visible = false  # start hidden so it doesn't grab the mouse on spawn


func _add_header(vb: VBoxContainer, text: String) -> void:
	var lbl := Label.new()
	lbl.text = "\n— %s —" % text
	vb.add_child(lbl)


func _add_color_row(vb: VBoxContainer, spec: Dictionary) -> void:
	var cname: String = spec["name"]
	var col: Color = spec["def"]
	_vals[cname] = col
	_targets[cname] = spec["target"]
	_uniforms[cname] = spec.get("uniform", cname)

	var hb := HBoxContainer.new()
	var lbl := Label.new()
	lbl.text = cname
	lbl.custom_minimum_size.x = 150
	hb.add_child(lbl)

	var edit_alpha: bool = spec.get("alpha", false)
	var cpb := ColorPickerButton.new()
	cpb.color = col
	cpb.edit_alpha = edit_alpha
	cpb.custom_minimum_size = Vector2(150, 26)
	hb.add_child(cpb)
	# Show the popup as a colour WHEEL (click the exact hue) rather than rectangles.
	var picker := cpb.get_picker()
	picker.picker_shape = ColorPicker.SHAPE_HSV_WHEEL
	picker.edit_alpha = edit_alpha
	cpb.color_changed.connect(func(c: Color) -> void:
		_vals[cname] = c
		_apply(cname, c)
		_update_summary())
	vb.add_child(hb)


func _add_float_row(vb: VBoxContainer, spec: Dictionary) -> void:
	var fname: String = spec["name"]
	var val: float = spec["def"]
	_vals[fname] = val
	_targets[fname] = spec["target"]
	_uniforms[fname] = spec.get("uniform", fname)

	var hb := HBoxContainer.new()
	var lbl := Label.new()
	lbl.text = fname
	lbl.custom_minimum_size.x = 150
	hb.add_child(lbl)
	var s := HSlider.new()
	s.min_value = spec["lo"]
	s.max_value = spec["hi"]
	s.step = 0.01
	s.value = val
	s.custom_minimum_size.x = 120
	hb.add_child(s)
	var vlbl := Label.new()
	vlbl.text = "%.2f" % val
	vlbl.custom_minimum_size.x = 48
	hb.add_child(vlbl)
	s.value_changed.connect(func(v: float) -> void:
		_vals[fname] = v
		_apply(fname, v)
		vlbl.text = "%.2f" % v
		_update_summary())
	vb.add_child(hb)


# Push a uniform to the right material(s): the single globe material; every inner
# ceiling material (resolved lazily — faces build after this overlay); or, for the
# shared star controls, BOTH the ceiling materials and the sky material at once.
func _apply(uname: String, value: Variant) -> void:
	var target: String = _targets[uname]
	var real: String = _uniforms.get(uname, uname)
	if target == "globe":
		if _globe_mat:
			_globe_mat.set_shader_parameter(real, value)
		return
	if target == "blocks":
		var bm := _blocks_material()
		if bm:
			bm.set_shader_parameter(real, value)
		return
	if target == "glass":
		var gm := _glass_material()
		if gm:
			gm.set_shader_parameter(real, value)
		return
	# "city" and "stars" both reach the ceiling materials; "stars" also reaches the sky.
	for m in _city_materials():
		m.set_shader_parameter(real, value)
	if target == "stars" and _sky_mat:
		_sky_mat.set_shader_parameter(real, value)


func _blocks_material() -> ShaderMaterial:
	var iv := get_tree().get_first_node_in_group("inner_globe_voxels")
	if iv and iv.has_method("get_block_material"):
		return iv.get_block_material()
	return null


func _glass_material() -> ShaderMaterial:
	var iv := get_tree().get_first_node_in_group("inner_globe_voxels")
	if iv and iv.has_method("get_glass_material"):
		return iv.get_glass_material()
	return null


func _city_materials() -> Array:
	var vp := get_tree().get_first_node_in_group("voxel_planet")
	if vp and vp.has_method("get_inner_materials"):
		return vp.get_inner_materials()
	return []


func _update_summary() -> void:
	_summary.text = _format_values()


func _print_to_console() -> void:
	print("\n=== Cavity tuner values (paste into shaders) ===")
	print("--- inner_globe.gdshader ---")
	for spec in COLOR_SPECS:
		if spec["target"] == "globe":
			print(_uniform_line(spec["name"]))
	for spec in FLOAT_SPECS:
		if spec["target"] == "globe":
			print(_uniform_line(spec["name"]))
	print("--- inner_voxel.gdshader ---")
	for spec in COLOR_SPECS:
		if spec["target"] == "city":
			print(_uniform_line(spec["name"]))
	for spec in FLOAT_SPECS:
		if spec["target"] == "city":
			print(_uniform_line(spec["name"]))
	print("--- stars → sky_space.gdshader AND inner_voxel.gdshader ---")
	for spec in FLOAT_SPECS:
		if spec["target"] == "stars":
			print(_uniform_line(spec["name"]))
	print("================================================\n")


func _format_values() -> String:
	var txt := ""
	for uname in _vals:
		txt += _uniform_line(uname) + "\n"
	return txt


func _uniform_line(uname: String) -> String:
	var v: Variant = _vals[uname]
	var real: String = _uniforms.get(uname, uname)
	if v is Color:
		if _targets.get(uname, "") == "glass":
			return "%s = vec4(%.3f, %.3f, %.3f, %.3f);" % [real, v.r, v.g, v.b, v.a]
		return "%s = vec3(%.3f, %.3f, %.3f);" % [real, v.r, v.g, v.b]
	return "%s = %.2f;" % [real, v]


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F3:
		visible = not visible
		# Free the mouse while tuning; recapture on hide so play resumes normally.
		Input.set_mouse_mode(
			Input.MOUSE_MODE_VISIBLE if visible else Input.MOUSE_MODE_CAPTURED
		)
		get_viewport().set_input_as_handled()
