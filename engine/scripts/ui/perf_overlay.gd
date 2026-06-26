extends CanvasLayer

# Lightweight runtime performance overlay — toggle with F7. Autoloaded so it works on
# the menu, the loading screen, and in-game alike. Reads Godot's Performance monitors
# (the same numbers as the editor Debugger → Monitors panel) so we can see, without the
# editor, whether the game is CPU-bound (high process ms), physics-bound (high physics
# ms), or draw-call/GPU heavy (high draw calls / primitives), and watch video memory.
#
# Updated ~5×/sec (not every frame) so the overlay itself is cheap. Starts hidden.

const _UPDATE_HZ := 5.0

var _label: Label
var _accum := 0.0
# Captured once: which OS + which GPU is actually rendering. This is how you tell a WSL
# build from a native Windows one — OS.get_name() reads "Linux" under WSL vs "Windows"
# native, and the adapter reads "llvmpipe" (SOFTWARE rendering — the CPU is doing all the
# GPU work, the classic cause of fan-blaring/overheating under WSLg) vs a real GPU name.
var _env_info := ""


func _ready() -> void:
	layer = 200
	process_mode = Node.PROCESS_MODE_ALWAYS  # keep updating while paused / loading
	_env_info = "%s · %s" % [OS.get_name(), RenderingServer.get_video_adapter_name()]

	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	panel.anchor_left = 1.0
	panel.anchor_right = 1.0
	panel.offset_left = -320.0
	panel.offset_top = 8.0
	panel.offset_right = -8.0
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(panel)

	_label = Label.new()
	_label.add_theme_font_size_override("font_size", 14)
	_label.add_theme_color_override("font_color", Color(0.6, 1.0, 0.6))
	_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	_label.add_theme_constant_override("outline_size", 4)
	panel.add_child(_label)

	visible = false


func _process(delta: float) -> void:
	if not visible:
		return
	_accum += delta
	if _accum < 1.0 / _UPDATE_HZ:
		return
	_accum = 0.0

	var fps := Performance.get_monitor(Performance.TIME_FPS)
	var cpu_ms := Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
	var phys_ms := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	var draws := Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	var prims := Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
	var vmem := Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0
	var nodes := Performance.get_monitor(Performance.OBJECT_NODE_COUNT)
	var smem := Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0

	_label.text = (
		"%s\n" % _env_info
		+ "FPS %d   (cap %d)\n"
		% [int(fps), Engine.max_fps]
		+ "CPU frame %.1f ms\n" % cpu_ms
		+ "Physics  %.1f ms\n" % phys_ms
		+ "Draw calls %d\n" % int(draws)
		+ "Primitives %.2fM\n" % (prims / 1e6)
		+ "Video mem  %.0f MB\n" % vmem
		+ "Static mem %.0f MB\n" % smem
		+ "Nodes %d" % int(nodes)
	)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F7:
		visible = not visible
		get_viewport().set_input_as_handled()
