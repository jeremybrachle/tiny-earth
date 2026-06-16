shader_type spatial;
// depth_draw_always: the transparent, cull_disabled, self-overlapping wave geometry
// writes depth so overlapping fragments depth-REJECT instead of alpha-compounding into
// dark concentric rings ("dark circles"). See docs/HANDOFF-water-circles.md.
render_mode cull_disabled, blend_mix, depth_draw_always, diffuse_burley, specular_schlick_ggx;

uniform float wave_speed  : hint_range(0.0, 2.0)  = 0.28;
uniform float wave_scale  : hint_range(0.01, 1.0) = 0.06;
uniform float wave_amp    : hint_range(0.0, 2.0)  = 0.30;
uniform float wave_base   : hint_range(0.0, 0.5)  = 0.04;  // min lift above sea level — prevents z-fight
// Single uniform ocean colour. wave_blend drives the geometric displacement ONLY —
// it is no longer fed into the fragment colour, so the wave rings can never paint as
// colour/brightness bands across the globe.
uniform vec4  water_color  : source_color = vec4(0.11, 0.38, 0.66, 1.0);
uniform float roughness    : hint_range(0.0, 1.0) = 0.42;
uniform float specular_str : hint_range(0.0, 1.0) = 0.38;
uniform float emission_str : hint_range(0.0, 1.0) = 0.02;

varying float wave_blend;

void vertex() {
	vec3 p = VERTEX;
	float w1 = sin(p.x * wave_scale + p.z * wave_scale * 0.71 + TIME * wave_speed);
	float w2 = sin(p.y * wave_scale * 1.30 + p.x * wave_scale * 0.58 + TIME * wave_speed * 1.37) * 0.55;
	float w3 = cos(p.z * wave_scale * 0.85 + p.y * wave_scale * 0.44 + TIME * wave_speed * 0.83) * 0.35;
	float wave = w1 + w2 + w3;  // sums to roughly [-1.9, 1.9]
	// CLAMP to [0,1]: without it wave_blend ran ~[-0.45, 1.45], driving the
	// displacement negative and dipping the surface BELOW sea level — opening a
	// gap to the hollow interior. Keep it non-negative so waves only lift.
	wave_blend = clamp(wave * 0.5 + 0.5, 0.0, 1.0);  // 0 = flat, 1 = crest
	VERTEX += NORMAL * (wave_blend * wave_amp + wave_base);
}

void fragment() {
	vec3 col = water_color.rgb;
	ALBEDO    = col;
	EMISSION  = col * emission_str;
	ROUGHNESS = roughness;
	SPECULAR  = specular_str;
	METALLIC  = 0.0;
	// Translucent so the bathymetric seafloor is faintly visible through the water.
	// depth_draw_always (see render_mode) stops the overlapping wave fragments from
	// compounding into dark rings, so we can afford a low alpha again.
	ALPHA     = 0.5;
}
