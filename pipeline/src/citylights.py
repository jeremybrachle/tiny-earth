"""
Fetch a real night-lights ("city lights") equirectangular image for the cavity
ceiling's land tiles.

The inner_voxel.gdshader land tiles sample this map by geographic direction (the
exact inverse of the cube_face.gd mapping), so the glowing "cities" land on the
real continents in the right places. The image is a standard equirect
(lon −180 at left → +180 right, lat +90 top → −90 bottom), matching
render_map.py / earth_biome_map.png, so it lines up with the ceiling geography.

Sources (both NASA, public domain — see ATTRIBUTION.md):
  default     "Earth's City Lights" 2000 (DMSP), 2400×1200 — small + canonical.
  --blackmarble  Black Marble 2016 (VIIRS), ~13500×6750 — sharper, downscaled.

Usage (run in WSL, per the pipeline gotcha):
    wsl bash -lc 'cd ~/programming/tiny-earth && source pipeline/.venv/bin/activate \
        && python pipeline/src/citylights.py --root .'

Options:
    --blackmarble   use the higher-res VIIRS Black Marble source
    --width 4096    downscale output to this width (height = width/2); 0 = native
"""

import argparse
import time
from pathlib import Path

import requests
from PIL import Image

# NASA "Earth's City Lights" (DMSP, 2000) — small canonical equirect.
CITY_DMSP_URL = "https://eoimages.gsfc.nasa.gov/images/imagerecords/55000/55167/earth_lights_lrg.jpg"
# NASA Black Marble 2016 (VIIRS) — sharper, much larger.
CITY_VIIRS_URL = "https://eoimages.gsfc.nasa.gov/images/imagerecords/144000/144898/BlackMarble_2016_3km.jpg"

CACHE_DIR_REL = Path("data/cache")
OUT_REL = Path("engine/planet/city_lights.png")

Image.MAX_IMAGE_PIXELS = None  # the VIIRS source is larger than Pillow's default guard


def _is_fresh(path: Path, ttl_days: int) -> bool:
    if not path.exists():
        return False
    return (time.time() - path.stat().st_mtime) / 86400 < ttl_days


def download(url: str, cache: Path, ttl_days: int = 365) -> Path:
    if _is_fresh(cache, ttl_days):
        print(f"Cache hit: {cache}")
        return cache
    cache.parent.mkdir(parents=True, exist_ok=True)
    print(f"Downloading night-lights image from {url} ...")
    with requests.get(url, stream=True, timeout=300, allow_redirects=True) as resp:
        resp.raise_for_status()
        with cache.open("wb") as f:
            for chunk in resp.iter_content(chunk_size=1024 * 1024):
                f.write(chunk)
    size = cache.stat().st_size
    if size < 50 * 1024:  # < 50 KB → almost certainly an error page
        cache.unlink(missing_ok=True)
        raise RuntimeError(f"Download too small ({size} bytes) — the NASA URL may have moved.")
    print(f"Saved {size // 1024} KB to {cache}")
    return cache


def process(src: Path, out_path: Path, width: int) -> None:
    img = Image.open(src).convert("RGB")
    print(f"Source night-lights image: {img.width}×{img.height}")
    if width > 0 and img.width != width:
        height = width // 2
        img = img.resize((width, height), Image.LANCZOS)
        print(f"Downscaled to {width}×{height}")
    out_path.parent.mkdir(parents=True, exist_ok=True)
    img.save(out_path)
    print(f"Saved city-lights map to {out_path}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Fetch a night-lights map for tiny-earth.")
    parser.add_argument("--root", default=".")
    parser.add_argument("--blackmarble", action="store_true", help="use higher-res VIIRS source")
    parser.add_argument(
        "--width",
        type=int,
        default=-1,
        help="downscale output width (height=width/2); default keeps native size "
        "for DMSP, downscales VIIRS to 4096",
    )
    args = parser.parse_args()

    repo_root = Path(args.root).resolve()
    if args.blackmarble:
        url = CITY_VIIRS_URL
        cache = repo_root / CACHE_DIR_REL / "blackmarble_2016_3km.jpg"
        default_width = 4096
    else:
        url = CITY_DMSP_URL
        cache = repo_root / CACHE_DIR_REL / "earth_lights_lrg.jpg"
        default_width = 0  # native 2400×1200 is already small

    width = default_width if args.width < 0 else args.width
    src = download(url, cache)
    process(src, repo_root / OUT_REL, width)


if __name__ == "__main__":
    main()
