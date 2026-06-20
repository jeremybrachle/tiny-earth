// Inner shell voxel shader — same edge-darkening as voxel.gdshader but unshaded
// so biome vertex colours on the cavity ceiling read correctly regardless of which
// way the face normals point relative to the OmniLight3D at origin.
//
// The cavity ceiling (the innermost voxel layer, faced inward toward the hollow)
// lights up per tile via UV2.x, both sampled by the tile's world direction so
// they map to REAL geography / the real sky:
//   UV2.x == 0  → ordinary rock / dug wall: plain edge-darkened albedo, no glow.
//   UV2.x == 1  → inverted LAND  → real "city lights" (NASA night-lights map,
//                 sampled by geographic lat/lon), warm-tinted + gently twinkling.
//   UV2.x == 2  → inverted OCEAN → the real night sky (baked star catalog map,
//                 1:1 with sky_space.gdshader), twinkling in lockstep.
// Each tile draws its own field fully (no masking), so nothing is clipped at the
// shore — land and ocean tiles simply sample different real datasets.
shader_type spatial;
render_mode cull_disabled, unshaded;

uniform float edge_width : hint_range(0.01, 0.2) = 0.07;
uniform float edge_dark  : hint_range(0.0, 1.0)  = 0.50;

// City lights (inverted land) — REAL night-lights, sampled from a NASA equirect
// by geographic direction so the glowing cities land on the real continents.
// city_gamma shapes the falloff (higher = only bright cores show); city_gain
// scales intensity before the warm tint. Twinkle is gentle (high floor).
uniform sampler2D city_tex     : source_color, filter_linear;
uniform vec3  city_color       : source_color = vec3(1.0, 0.80, 0.42);
uniform float city_brightness  : hint_range(0.0, 8.0) = 3.4;
uniform float city_gamma       : hint_range(0.5, 4.0) = 1.6;
uniform float city_gain        : hint_range(0.5, 8.0) = 3.0;
uniform float city_twinkle_floor : hint_range(0.0, 1.0) = 0.6;  // higher = steadier than stars

// Stars (inverted ocean) — the REAL night sky, sampled from the same baked
// catalog map as sky_space.gdshader so the ceiling projection shows the identical
// constellations, in lockstep.
uniform sampler2D star_map       : source_color, filter_linear;
uniform float star_brightness    : hint_range(0.0, 6.0)  = 2.6;
uniform float star_twinkle_speed : hint_range(0.0, 6.0)  = 2.5;
uniform float star_twinkle_floor : hint_range(0.0, 1.0)  = 0.25;
uniform float star_twinkle_enable: hint_range(0.0, 1.0)  = 1.0;
uniform vec3  space_tint         : source_color = vec3(0.0, 0.0, 0.012);

varying vec3 v_world;

float hash3(vec3 p) {
    p = fract(p * vec3(443.9, 441.4, 437.2));
    p += dot(p, p.zyx + 19.19);
    return fract((p.x + p.y) * p.z);
}

// Sample the baked real star map by direction with a per-star twinkle — an exact
// copy of sky_space.gdshader's sample_stars so the ceiling's ocean projection and
// the real sky agree star-for-star (twinkle included).
vec3 sample_stars(vec3 dir) {
    float u = atan(dir.z, dir.x) * 0.15915494 + 0.5;   // 1/(2π)
    float v = acos(clamp(dir.y, -1.0, 1.0)) * 0.31830989;  // 1/π
    vec3 s = texture(star_map, vec2(u, v)).rgb;
    vec3 cell = floor(dir * 120.0);
    float ph = hash3(cell + 88.2) * 6.2831853;
    float sp = star_twinkle_speed * (0.5 + hash3(cell + 3.3) * 1.5);
    float tw = star_twinkle_floor + (1.0 - star_twinkle_floor) * (0.5 + 0.5 * sin(TIME * sp + ph));
    tw = mix(1.0, tw, star_twinkle_enable);
    return s * tw;
}

void vertex() {
    v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
    float eu = (1.0 - step(edge_width, UV.x)) + step(1.0 - edge_width, UV.x);
    float ev = (1.0 - step(edge_width, UV.y)) + step(1.0 - edge_width, UV.y);
    float on_edge = clamp(eu + ev, 0.0, 1.0);
    vec3 base = COLOR.rgb * mix(1.0, edge_dark, on_edge);

    // Fold the glow into ALBEDO too: under `unshaded`, EMISSION alone may not reach
    // the framebuffer, and ALBEDO brightness is what the environment glow blooms.
    vec3 emis = vec3(0.0);
    float kind = UV2.x;
    if (kind > 0.5) {
        vec3 dir = normalize(v_world);
        if (kind > 1.5) {
            // Inverted ocean → the REAL night sky, sampled from the baked catalog
            // map (1:1 projection, in lockstep with sky_space.gdshader).
            emis = (space_tint + sample_stars(dir)) * star_brightness;
        } else {
            // Inverted land → REAL city lights. Convert the ceiling direction to
            // geographic lat/lon (inverse of cube_face.gd's Godot↔pipeline map:
            // godot (x,y,z) → pipeline (x,-z,y), with lat=asin(z), lon=atan2(y,x)),
            // then to a standard equirect UV (matches render_map.py / the biome map).
            float lat = asin(clamp(dir.y, -1.0, 1.0));
            float lon = atan(-dir.z, dir.x);
            vec2 cuv = vec2(lon * 0.15915494 + 0.5, 0.5 - lat * 0.31830989);
            vec3 cl = texture(city_tex, cuv).rgb;
            float lum = max(cl.r, max(cl.g, cl.b));
            float inten = pow(lum, city_gamma) * city_gain;
            // Gentle twinkle so cities shimmer subtly (steadier than the stars).
            vec3 cell = floor(dir * 120.0);
            float ph = hash3(cell + 88.2) * 6.2831853;
            float sp = star_twinkle_speed * (0.5 + hash3(cell + 3.3) * 1.5);
            float tw = city_twinkle_floor + (1.0 - city_twinkle_floor) * (0.5 + 0.5 * sin(TIME * sp + ph));
            tw = mix(1.0, tw, star_twinkle_enable);
            emis = city_color * inten * city_brightness * tw;
        }
    }
    ALBEDO = base + emis;
    EMISSION = emis;
}
