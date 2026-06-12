shader_type spatial;
render_mode cull_disabled;

uniform float roughness  : hint_range(0.0, 1.0) = 0.92;
uniform float edge_width : hint_range(0.01, 0.2) = 0.07;
uniform float edge_dark  : hint_range(0.0, 1.0)  = 0.50;

void fragment() {
    float eu = (1.0 - step(edge_width, UV.x)) + step(1.0 - edge_width, UV.x);
    float ev = (1.0 - step(edge_width, UV.y)) + step(1.0 - edge_width, UV.y);
    float on_edge = clamp(eu + ev, 0.0, 1.0);
    ALBEDO    = COLOR.rgb * mix(1.0, edge_dark, on_edge);
    ROUGHNESS = roughness;
    METALLIC  = 0.0;
    SPECULAR  = 0.1;
}
