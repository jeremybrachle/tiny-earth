shader_type spatial;
// depth_draw_always: the transparent, cull_disabled, self-overlapping wave geometry
// writes depth so overlapping fragments depth-REJECT instead of alpha-compounding into
// dark concentric rings ("dark circles"). See docs/HANDOFF-water-circles.md.
render_mode cull_disabled, blend_mix, depth_draw_always, diffuse_burley, specular_schlick_ggx;

// Calm, slow swell — tuned toward the gentle Minecraft/Luanti surface rather than
// a fast choppy sea. wave_speed governs how quickly the travelling ripples move;
// wave_amp how tall they are. Lower both for a placid, slowly-flowing surface.
uniform float wave_speed  : hint_range(0.0, 2.0)  = 0.10;
uniform float wave_scale  : hint_range(0.01, 1.0) = 0.06;
uniform float wave_amp    : hint_range(0.0, 2.0)  = 0.18;
uniform float wave_base   : hint_range(0.0, 0.5)  = 0.04;  // min lift above sea level — prevents z-fight
// Single uniform ocean colour. wave_blend drives the geometric displacement ONLY —
// it is no longer fed into the fragment colour, so the wave rings can never paint as
// colour/brightness bands across the globe.
uniform vec4  water_color  : source_color = vec4(0.16, 0.47, 0.74, 1.0);
uniform float roughness    : hint_range(0.0, 1.0) = 0.28;
uniform float specular_str : hint_range(0.0, 1.0) = 0.48;
uniform float emission_str : hint_range(0.0, 1.0) = 0.36;
// Brightness multiplier on the ocean albedo — the player-facing "make it brighter"
// knob (exposed in Settings → Graphics). >1 pushes the ocean into HDR for a bright,
// lit look. Stays out of the wave/displacement path, so it can never reintroduce the
// dark-rings artifact (that came from feeding wave_blend into colour).
uniform float albedo_mult  : hint_range(0.25, 3.0) = 2.49;
uniform float water_alpha  : hint_range(0.0, 1.0)  = 0.36;
// Underside (the surface seen from BELOW the water): brighten it and firm up its
// opacity so the waterline is clearly visible after submerging — otherwise the
// translucent surface dissolves into the underwater murk and you can't tell where
// the water ends. Applied only to back-facing fragments (FRONT_FACING == false).
uniform float underside_bright : hint_range(0.0, 3.0) = 1.7;
uniform float underside_alpha  : hint_range(0.0, 1.0) = 0.7;

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
	vec3 col = water_color.rgb * albedo_mult;
	ROUGHNESS = roughness;
	SPECULAR  = specular_str;
	METALLIC  = 0.0;
	// NOTE on winding: for the ocean-top quads, FRONT_FACING is TRUE when the
	// camera looks at the surface from BELOW the water and FALSE from above. (This
	// was verified empirically — the "from above looked less translucent" report
	// pinned down the orientation.) So the bright underside treatment goes on the
	// FRONT_FACING branch and the translucent top look on the else branch.
	if (FRONT_FACING) {
		// Surface seen from below (submerged, looking up): brighten and firm up the
		// alpha so the waterline reads as a distinct bright ceiling instead of
		// blending into the murk. max() keeps it visible even if the player has
		// turned water_alpha right down in Settings.
		ALBEDO   = col * underside_bright;
		EMISSION = water_color.rgb * emission_str * underside_bright;
		ALPHA    = max(water_alpha, underside_alpha);
	} else {
		// Surface seen from above (standing / swimming on top).
		ALBEDO   = col;
		EMISSION = water_color.rgb * emission_str;
		// Translucent so the bathymetric seafloor is faintly visible through the
		// water. depth_draw_always (see render_mode) stops the overlapping wave
		// fragments from compounding into dark rings, so we can afford low alpha.
		ALPHA    = water_alpha;
	}
}
