shader_type sky;

uniform float planet_radius    = 256.0;  // set by world.gd from planet_config.json
uniform float star_scale       : hint_range(5.0, 40.0) = 18.0;
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

// --- Milky Way band ---
// A great circle whose plane is perpendicular to mw_axis (in celestial coords).
// The axis is deliberately tilted off +Y so the band sweeps dramatically across
// the sky as sky_rotation advances (a band aligned with +Y would barely move).
uniform vec3  mw_axis        = vec3(0.84, 0.30, 0.45);
uniform float mw_strength    : hint_range(0.0, 1.0) = 0.0;  // 0 = no Milky Way band
uniform vec3  mw_color       : source_color = vec3(0.70, 0.74, 0.82);

float hash3(vec3 p) {
    p = fract(p * vec3(443.9, 441.4, 437.2));
    p += dot(p, p.zyx + 19.19);
    return fract((p.x + p.y) * p.z);
}

// Rotate a direction about the +Y (polar) axis. Used to carry the star sphere
// and Milky Way with the sun.
vec3 rotate_y(vec3 v, float a) {
    float c = cos(a);
    float s = sin(a);
    return vec3(v.x * c + v.z * s, v.y, -v.x * s + v.z * c);
}

// 3D value noise + fbm for the mottled Milky Way glow.
float vnoise(vec3 p) {
    vec3 i = floor(p);
    vec3 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float n000 = hash3(i + vec3(0.0, 0.0, 0.0));
    float n100 = hash3(i + vec3(1.0, 0.0, 0.0));
    float n010 = hash3(i + vec3(0.0, 1.0, 0.0));
    float n110 = hash3(i + vec3(1.0, 1.0, 0.0));
    float n001 = hash3(i + vec3(0.0, 0.0, 1.0));
    float n101 = hash3(i + vec3(1.0, 0.0, 1.0));
    float n011 = hash3(i + vec3(0.0, 1.0, 1.0));
    float n111 = hash3(i + vec3(1.0, 1.0, 1.0));
    float nx00 = mix(n000, n100, f.x);
    float nx10 = mix(n010, n110, f.x);
    float nx01 = mix(n001, n101, f.x);
    float nx11 = mix(n011, n111, f.x);
    float nxy0 = mix(nx00, nx10, f.y);
    float nxy1 = mix(nx01, nx11, f.y);
    return mix(nxy0, nxy1, f.z);
}

float fbm(vec3 p) {
    float v = 0.0;
    float a = 0.5;
    float amp = 0.0;
    for (int i = 0; i < 4; i++) {
        v += a * vnoise(p);
        amp += a;
        p *= 2.03;
        a *= 0.5;
    }
    return v / amp;  // normalized to [0,1], smoother than a raw sum
}

// Blackbody-ish stellar color from a temperature param t in [0,1]
// (0 = cool red dwarf, 1 = hot blue giant). Desaturated so most stars read
// near-white, with only the extremes showing obvious tint.
vec3 star_color(float t) {
    vec3 red    = vec3(1.00, 0.72, 0.52);
    vec3 orange = vec3(1.00, 0.85, 0.68);
    vec3 white  = vec3(1.00, 0.97, 0.94);
    vec3 bwhite = vec3(0.88, 0.92, 1.00);
    vec3 blue   = vec3(0.72, 0.82, 1.00);
    if (t < 0.25)      return mix(red,    orange, t / 0.25);
    else if (t < 0.50) return mix(orange, white,  (t - 0.25) / 0.25);
    else if (t < 0.75) return mix(white,  bwhite, (t - 0.50) / 0.25);
    else               return mix(bwhite, blue,   (t - 0.75) / 0.25);
}

// One grid layer of stars. density_boost lowers the threshold locally (used to
// cluster extra stars along the Milky Way). mag_pow shapes the magnitude
// distribution: a higher power means most stars are faint with a rare few bright.
vec3 star_layer(vec3 dir, float scale, float threshold, float density_boost,
                float min_r, float max_r, float mag_pow, float bright_mul) {
    vec3 color = vec3(0.0);
    vec3 sd = dir * scale;
    vec3 si = floor(sd);
    float thr = clamp(threshold - density_boost, 0.0, 0.999);
    for (int x = -1; x <= 1; x++) {
    for (int y = -1; y <= 1; y++) {
    for (int z = -1; z <= 1; z++) {
        vec3 cell = si + vec3(float(x), float(y), float(z));
        float h = hash3(cell);
        if (h < thr) continue;
        vec3 jitter = vec3(hash3(cell + 13.1), hash3(cell + 7.3), hash3(cell + 21.5));
        vec3 star_dir = normalize(cell + jitter);
        float ang = acos(clamp(dot(dir, star_dir), -1.0, 1.0));
        // Power-law magnitude: many dim, few bright.
        float m   = pow((h - thr) / (1.0 - thr), mag_pow);
        float r   = mix(min_r, max_r, m);          // brighter stars are a touch larger
        // Crisp round point. A soft tail within the same radius keeps the edge
        // smooth without a wide halo (a wide halo gets clipped at the cell
        // neighborhood boundary, which reads as a straight-edged "cut" star).
        float core = smoothstep(r, 0.0, ang) + smoothstep(r * 0.5, 0.0, ang) * 0.5;
        float bright = core * m * bright_mul;
        vec3 col = star_color(hash3(cell + 55.5));
        color += col * bright;
    }}}
    return color;
}

void sky() {
    vec3 dir   = EYEDIR;

    // Star sphere lives in celestial coordinates: undo the sky rotation so that a
    // star fixed in the sky appears to sweep across the view as sky_rotation
    // advances (rising east / setting west with the sun). Flip the sign here if
    // east/west reads reversed for your map orientation.
    vec3 cdir = rotate_y(dir, -sky_rotation);

    // Milky Way: a faint, smooth band around the galactic plane (perpendicular to
    // mw_axis). It is mostly an INCREASE IN STAR DENSITY along the band (what a real
    // Milky Way is) plus only a whisper of diffuse glow — a strong glow term reads
    // as a painted gray streak, which we deliberately avoid.
    float gal_lat = abs(dot(cdir, normalize(mw_axis)));        // 0 on band, 1 at galactic poles
    float band    = smoothstep(0.40, 0.06, gal_lat);           // soft band, never fully solid
    float clouds  = 0.55 + 0.45 * fbm(cdir * 5.0);             // gentle mottling, low contrast
    float mw      = band * clouds * mw_strength;

    // Two layers: a dense faint haze + a sparse bright scatter. Density boosted
    // inside the Milky Way so stars visibly cluster along it. Small radii keep
    // stars crisp and round; the brightest bloom via the environment's glow.
    vec3 stars  = star_layer(cdir, star_scale * 2.2, 0.62, mw * 0.20,
                             0.0006, 0.0015, 5.0, 1.4);          // faint haze
    stars      += star_layer(cdir, star_scale,        0.88, mw * 0.06,
                             0.0012, 0.0030, 3.5, 3.0);          // bright scatter

    vec3 color = space_tint + mw_color * mw * 0.12 + stars;

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
