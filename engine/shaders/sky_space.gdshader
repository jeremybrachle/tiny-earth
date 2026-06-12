shader_type sky;

uniform float planet_radius    = 256.0;  // set by world.gd from planet_config.json
uniform float star_threshold   : hint_range(0.0, 1.0) = 0.90;
uniform float star_scale       : hint_range(5.0, 40.0) = 18.0;
uniform float sun_size         : hint_range(0.005, 0.08) = 0.018;
uniform float sun_glow         : hint_range(0.0, 2.0)   = 0.6;
uniform vec3  space_tint       : source_color = vec3(0.0, 0.0, 0.012);
uniform vec3  sky_zenith_color : source_color = vec3(0.20, 0.45, 0.90);
uniform vec3  sky_horizon_color: source_color = vec3(0.80, 0.62, 0.38);

float hash3(vec3 p) {
    p = fract(p * vec3(443.9, 441.4, 437.2));
    p += dot(p, p.zyx + 19.19);
    return fract((p.x + p.y) * p.z);
}

vec3 star_field(vec3 dir) {
    vec3 color = vec3(0.0);
    vec3 sd = dir * star_scale;
    vec3 si = floor(sd);
    for (int x = -1; x <= 1; x++) {
    for (int y = -1; y <= 1; y++) {
    for (int z = -1; z <= 1; z++) {
        vec3 cell = si + vec3(float(x), float(y), float(z));
        float h = hash3(cell);
        if (h < star_threshold) continue;
        vec3 jitter = vec3(hash3(cell + 13.1), hash3(cell + 7.3), hash3(cell + 21.5));
        vec3 star_dir = normalize(cell + jitter);
        float ang = acos(clamp(dot(dir, star_dir), -1.0, 1.0));
        float r = mix(0.0015, 0.0045, hash3(cell + 99.9));
        float bright = smoothstep(r, 0.0, ang) * (h - star_threshold) / (1.0 - star_threshold);
        float tint = hash3(cell + 55.5);
        vec3 star_col = mix(vec3(1.0, 0.85, 0.70), vec3(0.70, 0.85, 1.0), tint);
        color += star_col * bright * 4.0;
    }}}
    return color;
}

void sky() {
    vec3 dir   = EYEDIR;
    vec3 color = space_tint + star_field(dir);

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
    color += LIGHT0_COLOR * LIGHT0_ENERGY * (disc + inner + outer);

    COLOR = color;
}
