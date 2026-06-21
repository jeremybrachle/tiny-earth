// Inner mini-globe shader — shows the equirectangular biome map DIRECTLY, exactly
// like the menu globe (main_menu.gd), so the core sphere matches that look (full
// colour variety incl. snow/ice caps). Unshaded so it reads from any angle in the
// hollow (the core OmniLight sits inside the sphere and can't light its outward
// face). NEAREST filter keeps the biome blocks crisp.
//
// We used to reclassify the texels into a tunable 6-colour palette here; that
// dropped the ice caps and the green variety, so it was removed. The owner's saved
// palette (dark water etc.) is recorded in docs/HANDOFF.md if we ever want it back.
//
// NOTE: this is the in-game smooth inner sphere (planet_generator.gd
// _build_inner_sphere) — the toggle-OFF fallback for the F4 voxel skin.
shader_type spatial;
render_mode cull_back, unshaded;

uniform sampler2D biome_tex : source_color, filter_nearest;

// Overall brightness multiplier (1.0 = raw map colours, matching the menu globe).
// Live-tunable in the F3 cavity tuner.
uniform float palette_brightness : hint_range(0.2, 3.0) = 1.0;

void fragment() {
	ALBEDO = texture(biome_tex, UV).rgb * palette_brightness;
}
