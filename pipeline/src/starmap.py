"""
Bake a real night-sky star map from a bright-star catalog.

Renders the HYG star database (real RA/Dec positions, visual magnitude, B-V
colour) into an equirectangular PNG. The HYG database is compiled by David Nash
(https://www.astronexus.com/hyg) and licensed CC BY-SA 4.0 — see ATTRIBUTION.md.
Both shaders sample it by view direction so
the in-game sky AND the hollow cavity's ocean-ceiling projection show REAL
constellations, in lockstep (engine/shaders/sky_space.gdshader and
inner_voxel.gdshader). No Milky Way band is painted — the natural density of real
stars along the galactic plane is the only "Milky Way", which is what we want.

The equirect uses the SAME direction→UV convention the shaders invert:
    u = atan2(dir.z, dir.x) / TAU + 0.5      (RA)
    v = acos(dir.y) / PI                       (Dec, 0 at +Y pole = top row)

Usage (run in WSL, per the pipeline gotcha):
    wsl bash -lc 'cd ~/programming/tiny-earth && source pipeline/.venv/bin/activate \
        && python pipeline/src/starmap.py --root .'

Options:
    --mag-limit 6.5   faintest star to include (6.5 ≈ naked-eye, ~9000 stars;
                      bump to 7.5–8 for a richer, denser sky)
    --width 4096      output width (height = width/2)
"""

import argparse
import csv
import math
import time
from pathlib import Path

import numpy as np
import requests
from PIL import Image

# HYG database v4.1 (compiled by David Nash / astronexus, CC BY-SA 4.0 —
# attribution + share-alike required; see ATTRIBUTION.md). Columns include
# ra (hours), dec (degrees), mag (visual magnitude), ci (B-V colour index).
# Repo: https://www.astronexus.com/hyg  (now mirrored at codeberg.org/astronexus/hyg)
HYG_URL = (
    "https://raw.githubusercontent.com/astronexus/HYG-Database/main/hyg/CURRENT/hygdata_v41.csv"
)
HYG_CACHE_REL = Path("data/cache/hygdata_v41.csv")

TAU = math.tau


def _is_fresh(path: Path, ttl_days: int) -> bool:
    if not path.exists():
        return False
    return (time.time() - path.stat().st_mtime) / 86400 < ttl_days


def download_hyg(repo_root: Path, ttl_days: int = 365) -> Path:
    """Download + cache the HYG star catalog CSV. Returns the path."""
    cache = repo_root / HYG_CACHE_REL
    if _is_fresh(cache, ttl_days):
        print(f"Cache hit: {cache}")
        return cache

    cache.parent.mkdir(parents=True, exist_ok=True)
    print(f"Downloading HYG star catalog (~34 MB) from {HYG_URL} ...")
    with requests.get(HYG_URL, stream=True, timeout=300, allow_redirects=True) as resp:
        resp.raise_for_status()
        with cache.open("wb") as f:
            for chunk in resp.iter_content(chunk_size=1024 * 1024):
                f.write(chunk)
    size = cache.stat().st_size
    if size < 1024 * 1024:  # < 1 MB → almost certainly an error page
        cache.unlink(missing_ok=True)
        raise RuntimeError(
            f"Download too small ({size} bytes) — the HYG URL may have moved.\n"
            f"Download hygdata_v41.csv manually to {cache} from\n"
            f"  https://codeberg.org/astronexus/hyg  (or the GitHub mirror)"
        )
    print(f"Saved {size // (1024 * 1024)} MB to {cache}")
    return cache


def _mix(a, b, f):
    return tuple(a[i] + (b[i] - a[i]) * f for i in range(3))


def star_color(t: float):
    """Blackbody-ish stellar colour ramp — identical to the shaders' star_color
    so the catalog's colours match what the shaders would otherwise pick.
    t: 0 = cool red, 1 = hot blue."""
    red = (1.00, 0.72, 0.52)
    orange = (1.00, 0.85, 0.68)
    white = (1.00, 0.97, 0.94)
    bwhite = (0.88, 0.92, 1.00)
    blue = (0.72, 0.82, 1.00)
    if t < 0.25:
        return _mix(red, orange, t / 0.25)
    elif t < 0.50:
        return _mix(orange, white, (t - 0.25) / 0.25)
    elif t < 0.75:
        return _mix(white, bwhite, (t - 0.50) / 0.25)
    return _mix(bwhite, blue, (t - 0.75) / 0.25)


def bake(
    csv_path: Path,
    out_path: Path,
    width: int = 4096,
    mag_limit: float = 6.5,
    mag_bright: float = -1.5,
    peak: float = 3.0,
) -> None:
    """Render the catalog into an equirect float buffer and save as 8-bit PNG."""
    height = width // 2
    buf = np.zeros((height, width, 3), dtype=np.float32)

    rng_span = mag_limit - mag_bright
    n = 0
    with csv_path.open(newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            try:
                mag = float(row["mag"])
            except (ValueError, KeyError):
                continue
            if mag > mag_limit:
                continue
            try:
                ra_h = float(row["ra"])
                dec = float(row["dec"])
            except (ValueError, KeyError):
                continue

            # Skip the Sun (dist 0 / mag very negative blows out the buffer).
            if row.get("proper", "").strip().lower() == "sol":
                continue

            # Direction→UV convention shared with the shaders.
            u = (ra_h / 24.0 + 0.5) % 1.0
            v = (90.0 - dec) / 180.0
            cx = u * width
            cy = v * height

            # Brightness + size from magnitude (brighter = bigger, blooms in-game).
            norm = max(0.0, min(1.0, (mag_limit - mag) / rng_span))
            inten = (norm ** 1.6) * peak
            radius = 0.7 + norm * 1.8  # pixels
            sigma = max(radius * 0.6, 0.5)

            # Colour from B-V index (blue/hot = low ci, red/cool = high ci).
            try:
                ci = float(row["ci"])
            except (ValueError, KeyError):
                ci = 0.6  # ~sun-like default
            t = max(0.0, min(1.0, (1.5 - ci) / 2.0))
            col = star_color(t)

            # Splat a small Gaussian disc, wrapping in u (longitude seam).
            rad_px = int(math.ceil(radius * 2.0))
            ix = int(round(cx))
            iy = int(round(cy))
            for dy in range(-rad_px, rad_px + 1):
                yy = iy + dy
                if yy < 0 or yy >= height:
                    continue
                for dx in range(-rad_px, rad_px + 1):
                    xx = (ix + dx) % width
                    d2 = (cx - (ix + dx)) ** 2 + (cy - yy) ** 2
                    w = math.exp(-d2 / (2.0 * sigma * sigma))
                    if w < 0.01:
                        continue
                    contrib = inten * w
                    buf[yy, xx, 0] += col[0] * contrib
                    buf[yy, xx, 1] += col[1] * contrib
                    buf[yy, xx, 2] += col[2] * contrib
            n += 1

    print(f"Rendered {n} stars (mag ≤ {mag_limit}) into {width}×{height}.")
    img8 = (np.clip(buf, 0.0, 1.0) * 255.0 + 0.5).astype(np.uint8)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    Image.fromarray(img8, mode="RGB").save(out_path)
    print(f"Saved star map to {out_path}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Bake a real star map for tiny-earth.")
    parser.add_argument("--root", default=".")
    parser.add_argument("--width", type=int, default=4096)
    parser.add_argument("--mag-limit", type=float, default=6.5)
    args = parser.parse_args()

    repo_root = Path(args.root).resolve()
    csv_path = download_hyg(repo_root)
    out_path = repo_root / "engine" / "planet" / "star_map.png"
    bake(csv_path, out_path, width=args.width, mag_limit=args.mag_limit)


if __name__ == "__main__":
    main()
