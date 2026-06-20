// Inner mini-globe shader — recolours the equirectangular biome map into the
// SAME hues as the cavity ceiling (MAT_COLORS in inner_cube_face.gd), then lifts
// them with palette_brightness so the core globe reads clearly across the hollow.
// The ceiling can stay dark because the glowing star/city field carries it; the
// globe has no such glow, so it needs to be brighter than the raw MAT_COLORS.
// Unshaded (like the ceiling) so it reads from any angle.
//
// The biome map is a discrete-palette equirect (ocean blue / greens / tans /
// snow white). We classify each texel by simple channel heuristics and emit the
// matching palette colour. Every category colour, threshold and the overall
// brightness is a uniform, so the whole look is tunable live.
//
// NOTE: this is ONLY for the in-game inner sphere (planet_generator.gd
// _build_inner_sphere). The menu globe (main_menu.gd) keeps the bright Earth
// texture on purpose.
shader_type spatial;
render_mode cull_back, unshaded;

uniform sampler2D biome_tex : source_color, filter_nearest;

// Overall lift applied to every classified colour. Left at 1.0 now that the
// colours below are tuned to their final values (easier to reason about); raise
// it for a quick global brighten.
uniform float palette_brightness : hint_range(0.5, 3.0) = 1.0;

// Palette — same hue family as the ceiling MAT_COLORS but tuned for the globe:
// a DARK ocean, and LIGHTER, more-varied greens (forest → temperate → savanna)
// so the continents read with depth instead of one flat green.
uniform vec3 ocean_color     : source_color = vec3(0.05, 0.10, 0.22);  // dark blue
uniform vec3 desert_color    : source_color = vec3(0.52, 0.47, 0.33);  // sandy tan
uniform vec3 temperate_color : source_color = vec3(0.34, 0.52, 0.30);  // mid green (lighter)
uniform vec3 forest_color    : source_color = vec3(0.21, 0.39, 0.22);  // deep green (lighter)
uniform vec3 snow_color      : source_color = vec3(0.60, 0.64, 0.70);  // light grey
uniform vec3 savanna_color   : source_color = vec3(0.46, 0.51, 0.30);  // yellow-green

// Classification knobs (tune live if a region miscolours).
uniform float ocean_blue_bias : hint_range(0.0, 0.5)  = 0.08;  // how blue-dominant = ocean
uniform float snow_min        : hint_range(0.4, 1.0)  = 0.70;  // all channels above this = snow
uniform float desert_warm_min : hint_range(0.3, 1.0)  = 0.55;  // red this high + r>=g*k = desert
uniform float desert_rg_ratio : hint_range(0.6, 1.2)  = 0.85;  // r >= g*this = warm/tan
uniform float savanna_rg_ratio: hint_range(0.4, 1.0)  = 0.62;  // r >= g*this (but < desert) = savanna
uniform float forest_dark_max : hint_range(0.2, 0.8)  = 0.45;  // green below this = forest, else temperate

void fragment() {
	vec3 c = texture(biome_tex, UV).rgb;
	vec3 outc;

	if (c.b > c.r + ocean_blue_bias && c.b > c.g + ocean_blue_bias) {
		outc = ocean_color;
	} else if (min(c.r, min(c.g, c.b)) > snow_min) {
		outc = snow_color;
	} else if (c.r > desert_warm_min && c.r >= c.g * desert_rg_ratio) {
		outc = desert_color;
	} else if (c.r >= c.g * savanna_rg_ratio) {
		// Yellow-green grassland between pure green and tan desert.
		outc = savanna_color;
	} else {
		// Remaining greens: darker = forest, brighter = temperate.
		outc = (c.g < forest_dark_max) ? forest_color : temperate_color;
	}

	ALBEDO = outc * palette_brightness;
}
