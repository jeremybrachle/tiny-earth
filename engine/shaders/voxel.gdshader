shader_type spatial;
render_mode cull_disabled;

uniform float roughness  : hint_range(0.0, 1.0) = 0.92;
uniform float edge_width : hint_range(0.01, 0.2) = 0.07;
uniform float edge_dark  : hint_range(0.0, 1.0)  = 0.50;

// World-space position, used to derive the analytic sphere normal per-pixel.
varying vec3 v_world_pos;

void vertex() {
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	// Block-grid edge darkening (UV-based) — gives every voxel face its outline.
	float eu = (1.0 - step(edge_width, UV.x)) + step(1.0 - edge_width, UV.x);
	float ev = (1.0 - step(edge_width, UV.y)) + step(1.0 - edge_width, UV.y);
	float on_edge = clamp(eu + ev, 0.0, 1.0);
	ALBEDO    = COLOR.rgb * mix(1.0, edge_dark, on_edge);

	// Seam-free shading. The meshed (geometric) normal is computed per cube face,
	// so at a cube-face seam two faces meet at a tiny dihedral angle and the sun
	// lights one side brighter than the other — a hard line under overhead sun.
	// The analytic sphere normal (normalized world position) is continuous across
	// seams, so we use it for RADIAL faces (tops/bottoms, normal ~ radial). SIDE
	// walls (normal ~ tangential) keep the geometric normal so they still shade
	// directionally and retain block contrast. dot() discriminates the two.
	vec3 sphere_n = normalize(v_world_pos);
	vec3 geo_n    = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	float radial  = abs(dot(geo_n, sphere_n));               // ~1 on tops, ~0 on sides
	vec3 aligned  = sphere_n * sign(dot(geo_n, sphere_n));   // match outward/inward
	vec3 world_n  = mix(geo_n, aligned, smoothstep(0.7, 0.95, radial));
	NORMAL = (VIEW_MATRIX * vec4(world_n, 0.0)).xyz;

	ROUGHNESS = roughness;
	METALLIC  = 0.0;
	SPECULAR  = 0.1;
}
