shader_type spatial;
render_mode cull_disabled, unshaded, blend_mix;

// Tinted transparent "glass" blocks for the inner mini-globe's water cells — like
// stained/tinted glass in Minecraft: a dark see-through pane with a more-opaque frame
// at the block edges (UV border). Unshaded + no depth write (the default for the
// transparent pass) so the magenta core + hollow interior show through. Tint + alpha
// are F3-tunable.

uniform vec4 glass_color : source_color = vec4(0.165, 0.278, 0.341, 0.420);
uniform float edge_dark  : hint_range(0.0, 1.0) = 0.55;
uniform float edge_alpha : hint_range(0.0, 1.0) = 0.85;
uniform float edge_width : hint_range(0.0, 0.30) = 0.04;
// Faint Minecraft-glass-style etch on the TOP pane only, so the clear water is easier
// to spot from above. The mesher flags the top pane with vertex COLOR.r = 1.
uniform float etch_alpha : hint_range(0.0, 1.0) = 0.10;

void fragment() {
	float eu = (1.0 - step(edge_width, UV.x)) + step(1.0 - edge_width, UV.x);
	float ev = (1.0 - step(edge_width, UV.y)) + step(1.0 - edge_width, UV.y);
	float on_edge = clamp(eu + ev, 0.0, 1.0);
	ALBEDO = glass_color.rgb * mix(1.0, edge_dark, on_edge);
	ALPHA = mix(glass_color.a, edge_alpha, on_edge);

	// Top-pane etch (COLOR.r flags the top quad): two thin diagonal streaks + a couple
	// of small specks, all at low alpha — a subtle frosted highlight, not a pattern.
	if (COLOR.r > 0.5) {
		float etch = 0.0;
		etch += smoothstep(0.028, 0.0, abs(UV.x - UV.y + 0.30));
		etch += smoothstep(0.020, 0.0, abs(UV.x - UV.y - 0.14));
		etch += smoothstep(0.05, 0.0, distance(UV, vec2(0.24, 0.76)));
		etch += smoothstep(0.04, 0.0, distance(UV, vec2(0.74, 0.28)));
		etch = clamp(etch, 0.0, 1.0) * etch_alpha;
		ALBEDO = mix(ALBEDO, vec3(1.0), etch);
		ALPHA = clamp(ALPHA + etch, 0.0, 1.0);
	}
}
