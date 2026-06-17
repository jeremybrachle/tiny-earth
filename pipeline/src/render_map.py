"""
Render a 1024×512 equirectangular biome map PNG from biomes.npy.

Reads data/cache/biomes.npy, converts each pixel's lat/lon → cube-sphere
(face, col, row) → biome material ID → RGB colour, and saves the result
as engine/planet/earth_biome_map.png for use as the inner sphere texture.

Usage:
    source pipeline/.venv/bin/activate
    python pipeline/src/render_map.py --root .
"""

import argparse
import sys
from pathlib import Path

import numpy as np
import yaml
from PIL import Image

sys.path.insert(0, str(Path(__file__).parent))
from cube_sphere import face_uv_to_grid, latlon_to_xyz, xyz_to_face_uv  # noqa: E402

# RGB values matching cube_face.gd / inner_cube_face.gd MAT_COLORS
MAT_COLORS_RGB = {
    1: (64, 140, 51),  # land fallback
    2: (26, 89, 166),  # ocean
    3: (217, 191, 115),  # desert
    4: (102, 166, 64),  # temperate
    5: (38, 102, 38),  # forest
    6: (230, 237, 247),  # snow/ice
    7: (26, 122, 31),  # tropical
    8: (173, 158, 56),  # savanna
    9: (133, 122, 112),  # mountain/rock
    10: (71, 56, 41),  # seafloor
}
DEFAULT_COLOR = (100, 100, 100)

OUTPUT_REL = Path("engine/planet/earth_biome_map.png")
BIOMES_CACHE_REL = Path("data/cache/biomes.npy")


def generate(config: dict, repo_root: Path, width: int = 1024, height: int = 512) -> Path:
    resolution = config["planet"]["resolution"]

    biomes = np.load(repo_root / BIOMES_CACHE_REL)
    if biomes.shape[1] != resolution:
        step = biomes.shape[1] // resolution
        biomes = biomes[:, ::step, ::step][:, :resolution, :resolution]

    img = Image.new("RGB", (width, height))
    pixels = img.load()

    for j in range(height):
        lat = 90.0 - j * 180.0 / height
        for i in range(width):
            lon = i * 360.0 / width - 180.0
            x, y, z = latlon_to_xyz(lat, lon)
            face, u, v = xyz_to_face_uv(x, y, z)
            col, row = face_uv_to_grid(u, v, resolution)
            mat = int(biomes[face, col, row])
            pixels[i, j] = MAT_COLORS_RGB.get(mat, DEFAULT_COLOR)

    out = repo_root / OUTPUT_REL
    out.parent.mkdir(parents=True, exist_ok=True)
    img.save(out)
    print(f"Saved {width}×{height} biome map → {out}")
    return out


def main() -> None:
    parser = argparse.ArgumentParser(description="Render equirectangular biome map PNG.")
    parser.add_argument("--root", default=".")
    parser.add_argument("--config", default="pipeline/config/planet.yaml")
    parser.add_argument("--width", type=int, default=1024)
    parser.add_argument("--height", type=int, default=512)
    args = parser.parse_args()

    root = Path(args.root).resolve()
    with open(Path(args.config)) as f:
        cfg = yaml.safe_load(f)

    generate(cfg, root, args.width, args.height)


if __name__ == "__main__":
    main()
