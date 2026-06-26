shader_type sky;

uniform float planet_radius    = 256.0;  // set by world.gd from planet_config.json
// Real night sky — baked from a star catalog by pipeline/src/starmap.py. Sampled
// by direction; inner_voxel.gdshader samples the SAME map so the ocean-ceiling
// projection shows the identical real constellations. filter_linear (no mipmaps)
// keeps faint single stars from fading out at distance.
uniform sampler2D star_map     : source_color, filter_linear;
uniform float star_brightness  : hint_range(0.0, 6.0) = 6.0;
uniform float star_twinkle_speed  : hint_range(0.0, 6.0) = 2.19;  // matches inner_voxel.gdshader
uniform float star_twinkle_floor  : hint_range(0.0, 1.0) = 0.04;  // low = dramatic twinkle
uniform float star_twinkle_enable : hint_range(0.0, 1.0) = 1.0;  // 0 = steady (loading screen / menu)
uniform float sun_size         : hint_range(0.005, 0.08) = 0.018;
uniform float sun_glow         : hint_range(0.0, 2.0)   = 0.6;
uniform float sun_visible      : hint_range(0.0, 1.0)   = 1.0;  // 0 hides disc+corona (loading screen)
uniform vec3  space_tint       : source_color = vec3(0.0, 0.0, 0.012);
uniform vec3  sky_zenith_color : source_color = vec3(0.20, 0.45, 0.90);
uniform vec3  sky_horizon_color: source_color = vec3(0.80, 0.62, 0.38);

// Celestial rotation about the polar (+Y) axis, in radians. world.gd feeds the
// day/night sun angle here so the whole star sphere rises/sets in lockstep with
// the sun; the menu feeds a slow drift. The sun disc itself follows
// LIGHT0_DIRECTION and is NOT rotated here.
uniform float sky_rotation = 0.0;

float hash3(vec3 p) {
    p = fract(p * vec3(443.9, 441.4, 437.2));
    p += dot(p, p.zyx + 19.19);
    return fract((p.x + p.y) * p.z);
}

// Rotate a direction about the +Y (polar) axis. Used to carry the star sphere
// with the sun.
vec3 rotate_y(vec3 v, float a) {
    float c = cos(a);
    float s = sin(a);
    return vec3(v.x * c + v.z * s, v.y, -v.x * s + v.z * c);
}

// Sample the baked real star map by celestial direction, with a per-star
// twinkle. The UV convention here is the exact inverse of starmap.py's
// direction→UV, so constellations land where the catalog put them. The twinkle
// phase/speed come from a COARSE direction hash (~one cell per star) so each
// star shimmers independently without flickering across its own few pixels.
// IDENTICAL helper in inner_voxel.gdshader → sky + ceiling stay in lockstep.
vec3 sample_stars(vec3 dir) {
    float u = atan(dir.z, dir.x) * 0.15915494 + 0.5;   // 1/(2π)
    float v = acos(clamp(dir.y, -1.0, 1.0)) * 0.31830989;  // 1/π
    vec3 s = texture(star_map, vec2(u, v)).rgb;
    vec3 cell = floor(dir * 120.0);
    float ph = hash3(cell + 88.2) * 6.2831853;
    float sp = star_twinkle_speed * (0.5 + hash3(cell + 3.3) * 1.5);
    float tw = star_twinkle_floor + (1.0 - star_twinkle_floor) * (0.5 + 0.5 * sin(TIME * sp + ph));
    tw = mix(1.0, tw, star_twinkle_enable);  // enable=0 → steady (no twinkle)
    return s * tw;
}

void sky() {
    vec3 dir   = EYEDIR;

    // Star sphere lives in celestial coordinates: undo the sky rotation so that a
    // star fixed in the sky appears to sweep across the view as sky_rotation
    // advances (rising east / setting west with the sun). Flip the sign here if
    // east/west reads reversed for your map orientation.
    vec3 cdir = rotate_y(dir, -sky_rotation);

    // Real stars, sampled from the baked catalog map. No painted Milky Way band —
    // the natural density of real stars along the galactic plane is the only
    // "Milky Way". The brightest stars bloom via the environment's glow.
    vec3 stars = sample_stars(cdir) * star_brightness;

    vec3 color = space_tint + stars;

    // --- Atmosphere ---
    // normalize(POSITION) = camera's local "up" (planet center is at world origin)
    vec3  up        = normalize(POSITION);
    float eye_up    = dot(dir, up);                     // +1 = looking at zenith
    float sun_el    = dot(up, LIGHT0_DIRECTION);        // +1 = sun directly overhead
    float altitude  = length(POSITION) - planet_radius; // 0 at surface, positive above
    float ceiling   = planet_radius * 0.12;             // atmosphere layer thickness
    float thickness = 1.0 - clamp(altitude / ceiling, 0.0, 1.0);

    // Full atmosphere: day side + near surface. Reaches 100% right at the
    // horizon (eye_up = 0) so no stars bleed through the horizon line.
    float atmos = smoothstep(-0.40, 0.05, eye_up)
                * smoothstep(-0.1,  0.35, sun_el)
                * thickness;

    // Dusk/dawn: horizon warms when sun is near the horizon line
    float horizon_t      = smoothstep(-0.1, 0.45, eye_up);
    float sun_at_horizon = 1.0 - abs(sun_el);           // peaks when sun is at horizon
    vec3  horizon_tinted = mix(sky_horizon_color, vec3(1.0, 0.55, 0.20), sun_at_horizon * 0.5);
    vec3  sky_color      = mix(horizon_tinted, sky_zenith_color, horizon_t);

    // Stars wash out in daytime atmosphere
    color *= (1.0 - atmos * 0.97);

    // Blend atmosphere on top of space
    color = mix(color, sky_color, atmos);

    // Sun disc + corona — rendered on top of atmosphere so it's always visible
    float sun_cos = dot(dir, LIGHT0_DIRECTION);
    float sun_ang = acos(clamp(sun_cos, -1.0, 1.0));
    float disc    = 1.0 - smoothstep(sun_size * 0.88, sun_size, sun_ang);
    float inner   = pow(max(0.0, sun_cos), 80.0) * 0.8  * sun_glow;
    float outer   = pow(max(0.0, sun_cos), 10.0) * 0.12 * sun_glow;
    color += LIGHT0_COLOR * LIGHT0_ENERGY * (disc + inner + outer) * sun_visible;

    COLOR = color;
}
