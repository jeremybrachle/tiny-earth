shader_type spatial;
render_mode cull_disabled, unshaded;

// Block-grid look for the inner mini-globe's diggable voxel volume, matching the
// outer surface (voxel.gdshader): each cell face carries UV 0..1, and pixels near a
// UV edge are darkened so every block reads as a separate square. The volume is
// unshaded (the cavern is dark; the core light sits inside the sphere, so the
// outward-facing surface lights itself) — colour comes from the vertex COLOR.
//
// `brightness` dims the whole surface for the dark cavern and is exposed in the F3
// tuner (live, no remesh needed). The magenta core cube uses its own material, so
// it stays bright regardless of this.

uniform float brightness : hint_range(0.0, 1.5) = 0.45;
uniform float edge_width : hint_range(0.0, 0.25) = 0.06;
uniform float edge_dark  : hint_range(0.0, 1.0)  = 0.45;

void fragment() {
	float eu = (1.0 - step(edge_width, UV.x)) + step(1.0 - edge_width, UV.x);
	float ev = (1.0 - step(edge_width, UV.y)) + step(1.0 - edge_width, UV.y);
	float on_edge = clamp(eu + ev, 0.0, 1.0);
	ALBEDO = COLOR.rgb * brightness * mix(1.0, edge_dark, on_edge);
}
