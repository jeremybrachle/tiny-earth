shader_type spatial;
render_mode cull_disabled;

uniform float roughness  : hint_range(0.0, 1.0) = 0.92;
uniform float edge_width : hint_range(0.01, 0.2) = 0.05;
uniform float edge_dark  : hint_range(0.0, 1.0)  = 0.68;

void fragment() {
    // Compute sphere normal per-pixel from world position so it's continuous across
    // cube-face boundaries. VERTEX in fragment is view-space position; INV_VIEW_MATRIX
    // brings it to world space, then VIEW_MATRIX rotates back for Godot's lighting.
    vec3 world_pos = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
    NORMAL = normalize((VIEW_MATRIX * vec4(normalize(world_pos), 0.0)).xyz);

    float eu = 1.0 - smoothstep(0.0, edge_width, UV.x) * (1.0 - smoothstep(1.0 - edge_width, 1.0, UV.x));
    float ev = 1.0 - smoothstep(0.0, edge_width, UV.y) * (1.0 - smoothstep(1.0 - edge_width, 1.0, UV.y));
    float on_edge = clamp(eu + ev, 0.0, 1.0);
    ALBEDO    = COLOR.rgb * mix(1.0, edge_dark, on_edge);
    ROUGHNESS = roughness;
    METALLIC  = 0.0;
    SPECULAR  = 0.05;
}
