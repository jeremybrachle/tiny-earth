shader_type spatial;
render_mode cull_disabled, blend_mix, diffuse_burley, specular_schlick_ggx;

uniform float wave_speed  : hint_range(0.0, 2.0)  = 0.28;
uniform float wave_scale  : hint_range(0.01, 1.0) = 0.06;
uniform float wave_amp    : hint_range(0.0, 2.0)  = 0.30;
uniform float wave_base   : hint_range(0.0, 0.5)  = 0.04;  // min lift above sea level — prevents z-fight
// Trough/crest kept close together so the wave reads as a gentle shimmer, not
// large dark/light blotches across the globe (at planetary scale the wavelength
// is ~100 units, so a wide trough↔crest colour gap paints big patches).
uniform vec4  color_trough : source_color = vec4(0.09, 0.34, 0.62, 1.0);
uniform vec4  color_crest  : source_color = vec4(0.13, 0.42, 0.70, 1.0);
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
	// CLAMP to [0,1]: without it wave_blend ran ~[-0.45, 1.45], which (a) made
	// the colour mix extrapolate past trough/crest into over-dark / over-bright
	// patches (the "blemishes"), and (b) drove the displacement negative, dipping
	// the surface BELOW sea level and opening a gap to the hollow interior.
	wave_blend = clamp(wave * 0.5 + 0.5, 0.0, 1.0);  // 0 = trough, 1 = crest
	VERTEX += NORMAL * (wave_blend * wave_amp + wave_base);
}

void fragment() {
	vec3 col = mix(color_trough.rgb, color_crest.rgb, wave_blend);
	ALBEDO    = col;
	EMISSION  = col * emission_str;
	ROUGHNESS = roughness;
	SPECULAR  = specular_str;
	METALLIC  = 0.0;
	// Near-opaque so the ocean reads as solid blue from above instead of letting
	// the inner shell's varied subsurface (rock / ceiling at mixed depths) show
	// through and blend to an ugly purple. A sliver of translucency keeps a touch
	// of depth at the shoreline.
	ALPHA     = 0.92;
}
