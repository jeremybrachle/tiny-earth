extends CanvasLayer

# TEMPORARY debug overlay to live-tune the inner mini-globe palette
# (inner_globe.gdshader). Toggle with F3. Drag sliders to change the colours in
# real time; the panel at the bottom prints copy-paste-ready values to send back
# so we can lock them into the shader defaults. Only created in debug builds
# (planet_generator.gd _build_inner_sphere) — delete this file + its instantiation
# to remove the tool.

# Defaults must mirror inner_globe.gdshader's uniform defaults so the sliders start
# where the shader does.
const FLOATS := {
	"palette_brightness": [1.0, 0.5, 3.0],
}
const COLORS := {
	"ocean_color": Color(0.05, 0.10, 0.22),
	"forest_color": Color(0.21, 0.39, 0.22),
	"temperate_color": Color(0.34, 0.52, 0.30),
	"savanna_color": Color(0.46, 0.51, 0.30),
	"desert_color": Color(0.52, 0.47, 0.33),
	"snow_color": Color(0.60, 0.64, 0.70),
}

var _mat: ShaderMaterial
var _vals := {}
var _summary: Label


func setup(mat: ShaderMaterial) -> void:
	_mat = mat
	layer = 128

	var panel := PanelContainer.new()
	panel.position = Vector2(12, 12)
	add_child(panel)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(340, 520)
	panel.add_child(scroll)

	var vb := VBoxContainer.new()
	vb.custom_minimum_size.x = 320
	scroll.add_child(vb)

	var title := Label.new()
	title.text = "Inner-globe palette  —  F3 to toggle"
	vb.add_child(title)

	for fname in FLOATS:
		var spec: Array = FLOATS[fname]
		_vals[fname] = spec[0]
		_mat.set_shader_parameter(fname, spec[0])
		_add_float_row(vb, fname, spec[0], spec[1], spec[2])

	for cname in COLORS:
		var col: Color = COLORS[cname]
		_vals[cname] = col
		_mat.set_shader_parameter(cname, col)
		for comp in 3:
			_add_color_row(vb, cname, comp)

	var copy_lbl := Label.new()
	copy_lbl.text = "\n— copy these back —"
	vb.add_child(copy_lbl)
	_summary = Label.new()
	_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vb.add_child(_summary)
	_update_summary()

	visible = false  # start hidden so it doesn't grab the mouse on spawn


func _add_float_row(vb: VBoxContainer, fname: String, val: float, lo: float, hi: float) -> void:
	var hb := HBoxContainer.new()
	var lbl := Label.new()
	lbl.text = fname
	lbl.custom_minimum_size.x = 140
	hb.add_child(lbl)
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
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
		_mat.set_shader_parameter(fname, v)
		vlbl.text = "%.2f" % v
		_update_summary())
	vb.add_child(hb)


func _add_color_row(vb: VBoxContainer, cname: String, comp: int) -> void:
	var comp_name: String = ["R", "G", "B"][comp]
	var col: Color = _vals[cname]
	var val: float = col[comp]
	var hb := HBoxContainer.new()
	var lbl := Label.new()
	lbl.text = "%s.%s" % [cname, comp_name]
	lbl.custom_minimum_size.x = 140
	hb.add_child(lbl)
	var s := HSlider.new()
	s.min_value = 0.0
	s.max_value = 1.0
	s.step = 0.005
	s.value = val
	s.custom_minimum_size.x = 120
	hb.add_child(s)
	var vlbl := Label.new()
	vlbl.text = "%.3f" % val
	vlbl.custom_minimum_size.x = 48
	hb.add_child(vlbl)
	s.value_changed.connect(func(v: float) -> void:
		var c: Color = _vals[cname]
		match comp:
			0: c.r = v
			1: c.g = v
			2: c.b = v
		_vals[cname] = c
		_mat.set_shader_parameter(cname, c)
		vlbl.text = "%.3f" % v
		_update_summary())
	vb.add_child(hb)


func _update_summary() -> void:
	var txt := ""
	for fname in FLOATS:
		txt += "%s = %.2f\n" % [fname, _vals[fname]]
	for cname in COLORS:
		var c: Color = _vals[cname]
		txt += "%s = vec3(%.3f, %.3f, %.3f)\n" % [cname, c.r, c.g, c.b]
	_summary.text = txt


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F3:
		visible = not visible
		# Free the mouse while tuning; recapture on hide so play resumes normally.
		Input.set_mouse_mode(
			Input.MOUSE_MODE_VISIBLE if visible else Input.MOUSE_MODE_CAPTURED
		)
		get_viewport().set_input_as_handled()
