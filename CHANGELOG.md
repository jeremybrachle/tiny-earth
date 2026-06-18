# Changelog

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

Repository polish + an engineering-hygiene pass. No gameplay changes beyond two reworded UI strings.

### Added
- Project `LICENSE` (all rights reserved) for the game/pipeline code; third-party licenses stay in `LICENSES.md`.
- `.gitattributes` — line-ending normalization plus binary markers for the baked chunks, audio, and images.
- CI: **Python** (ruff lint + format + pytest with coverage), **GDScript** (gdlint + gdformat).
- GUT unit tests for the cube-sphere projection and voxel-address math (`engine/test/`), runnable locally (headless GUT-on-Godot-4.6 isn't run in CI yet — see the note in `gdscript.yml`).
- Tooling config: ruff (in `pyproject.toml`), `.gdlintrc`, `.editorconfig`.

### Changed
- Reworded the main-menu subtitle and one loading-screen phase label.
- Consolidated three `requirements*.txt` files into one; dropped unused deps (gdal, geopandas, httpx) and added the ones actually imported (scipy, netCDF4, pyshp).
- Corrected attribution: credit Köppen-Geiger (Beck et al. 2018, **CC BY 4.0**) — the biome source actually used — and removed sources the current build does not use (WWF, OpenStreetMap, Wikipedia).
- Rewrote the README for accuracy (real pipeline diagram, real repo layout, play-first Getting Started) and added a Development section.

### Fixed
- `pyproject.toml` build backend (`setuptools.build_meta`).

## [1.1.0] - 2026-06-17

First release with a proper front-end (menu, loading screen, music, pause/settings) and a
polished ocean. Merges the `architecture-revamp` branch into `main`.

### Added
- **Main menu** — an instant title screen (`main_menu.tscn`); the planet no longer builds
  before the first frame renders. Play → world.
- **Progressive loading screen** — the planet builds across frames (meshing batched per frame),
  spiralling out from the spawn point so it visibly assembles. A bottom overlay shows live phase
  text and a progress bar, watched from a fixed space camera framed on North America. One
  continuous progress bar now spans all build phases — data load, meshing, and seam stitching —
  with the mesh phase split into **surface** then **subsurface** passes so the bar reflects
  real work instead of the mesh phase owning the entire percentage.
- **Ambient music** — Clair de Lune (Debussy, public-domain recording) loops under gameplay via
  a `Music` autoload that persists across scene changes. Starts once the world is explorable, and
  keeps playing (at a reduced level) while the game is paused.
- **Pause menu** (Esc) — Resume / Settings / Quit-to-Menu / Quit, with **Audio** and **Graphics**
  sub-pages and Esc-to-go-back page navigation. Pauses the world while staying responsive.
- **Water appearance settings** — five live sliders (brightness, roughness, specular, opacity,
  emission) plus "Reset to Default" under Settings → Graphics.
- **Settings persistence** — Graphics (water) choices are written to `user://settings.cfg` and
  restored on relaunch; they apply from the first frame, not just after opening the menu.

### Changed
- **Ocean visuals** — brighter, more reflective water with a real daytime sun glint. New
  `albedo_mult` (HDR brightness) and `water_alpha` shader uniforms; tuned defaults baked in
  (`roughness 0.28`, `specular_str 0.48`, `emission_str 0.36`).
- **Snow/ice** no longer blows out under an overhead sun — snow albedo is scaled by a new
  `snow_albedo` uniform in `voxel.gdshader`.
- **Crosshair** is now hidden while the pause menu is open (previously visible behind the menu).
- **Internal** — outer shell rewritten to a per-voxel mesher with cross-face neighbour stitching
  (no adjacency table); aim-based left-click digging; equiangular cube-sphere distortion fix
  (`tan(s·α)/tan(α)` remap) cutting face cell-area variation 5.16× → 1.41×. (Landed on the
  `architecture-revamp` branch this release merges.)

### Fixed
- **Ocean "dark circles" artifact** — overlapping transparent wave fragments compounded into
  dark concentric rings. Fixed in `water.gdshader` with `depth_draw_always` and a single colour
  uniform (wave displacement no longer feeds fragment colour).
- **Subsurface dig black-screen** — digging straight down through the crust (no fly/noclip) used
  to black the screen out; the opaque `_solid_overlay` that caused it was removed.
- **Loading-screen HUD leaks** — the crosshair is gated off until the world is ready, and the
  mouse can no longer be captured mid-load.

### Removed
- The throwaway F3 water-tuning debug overlay (`water_debug.gd`), once its values were chosen
  and baked into the shader defaults.


## [1.0.0] - 2026-06-11

Initial release to github