extends Node

# Autoload: persists player Settings across runs in user://settings.cfg.
#
# Today it backs the Graphics → Water Appearance sliders (pause menu). Values the
# player picks survive an app restart; the "Reset to Default" button restores the
# baked defaults below (the same numbers as the water.gdshader uniform defaults).
# Music volume still lives only for the session — fold it in here later if wanted.
#
# Flow: the pause menu reads/writes through get_water()/set_water()/reset_water();
# World calls apply_water() once the planet build finishes so the saved look is in
# effect from the first frame, not just after the player opens the menu.

const PATH := "user://settings.cfg"
const WATER_SECTION := "water"
const WATER_SHADER_PATH := "res://shaders/water.gdshader"

# Graphics quality preset. "high" = the full look (SSIL + SSAO + glow + realtime
# twinkling sky + 4-split shadows); "low" drops the expensive screen-space passes
# (SSIL/SSAO off, incremental sky, fewer/shorter shadow splits) for weaker GPUs and
# to run cooler. World.set_graphics_quality() applies it live to the WorldEnvironment;
# World reads get_quality() at setup so a saved choice is in effect from the first frame.
const GRAPHICS_SECTION := "graphics"
const QUALITY_KEY := "quality"
const QUALITY_HIGH := "high"
const QUALITY_LOW := "low"
const QUALITY_DEFAULT := QUALITY_HIGH

# Param -> baked default. Single source of truth: pause_menu reads its defaults
# from here, so the slider defaults and "Reset to Default" can't drift from these.
const WATER_DEFAULTS := {
	"albedo_mult": 2.49,
	"roughness": 0.28,
	"specular_str": 0.48,
	"water_alpha": 0.36,
	"emission_str": 0.36,
}

var _cfg := ConfigFile.new()


func _ready() -> void:
	# A missing config (first run) is fine — get_water() falls back to defaults.
	_cfg.load(PATH)


# Saved value for a water param, or its baked default if never changed.
func get_water(pname: String) -> float:
	return float(_cfg.get_value(WATER_SECTION, pname, WATER_DEFAULTS.get(pname, 0.0)))


func set_water(pname: String, value: float) -> void:
	_cfg.set_value(WATER_SECTION, pname, value)
	_cfg.save(PATH)


# Restore every water param to its baked default and persist that.
func reset_water() -> void:
	for pname in WATER_DEFAULTS:
		_cfg.set_value(WATER_SECTION, pname, WATER_DEFAULTS[pname])
	_cfg.save(PATH)


# Saved graphics quality preset ("high"/"low"), or the default if never changed.
func get_quality() -> String:
	return str(_cfg.get_value(GRAPHICS_SECTION, QUALITY_KEY, QUALITY_DEFAULT))


func set_quality(q: String) -> void:
	_cfg.set_value(GRAPHICS_SECTION, QUALITY_KEY, q)
	_cfg.save(PATH)


# Push the saved water values onto every live water ShaderMaterial in the tree.
# Called by World after the build so persisted settings apply from the start.
func apply_water() -> void:
	var mats := collect_water_mats()
	for pname in WATER_DEFAULTS:
		var v := get_water(pname)
		for m in mats:
			(m as ShaderMaterial).set_shader_parameter(pname, v)


# Every unique water ShaderMaterial under the scene root (each cube_face /
# inner_cube_face makes its own, ~12 total, all sharing water.gdshader).
func collect_water_mats() -> Array:
	var seen := {}
	var mats: Array = []
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
						mats.append(m)
		for c in n.get_children():
			stack.append(c)
	return mats
