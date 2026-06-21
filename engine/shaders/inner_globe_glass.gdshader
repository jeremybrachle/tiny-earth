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

void fragment() {
	float eu = (1.0 - step(edge_width, UV.x)) + step(1.0 - edge_width, UV.x);
	float ev = (1.0 - step(edge_width, UV.y)) + step(1.0 - edge_width, UV.y);
	float on_edge = clamp(eu + ev, 0.0, 1.0);
	ALBEDO = glass_color.rgb * mix(1.0, edge_dark, on_edge);
	ALPHA = mix(glass_color.a, edge_alpha, on_edge);
}
