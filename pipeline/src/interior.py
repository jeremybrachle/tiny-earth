"""
Inner shell chunk export.

Generates inner_chunk_{cx}_{cy}.bin files — one per chunk slot per face —
using the same zlib format as the surface chunks.  These are loaded by
InnerCubeFace in Godot to provide a SOLID subsurface voxel volume:

  Land columns:   depths 0..15 = Rock (mat 9)            — solid crust
  Ocean columns:  depths 0..N-1 = Water    (mat 2)
                  depth  N      = Seafloor  (mat 10)
                  depths N+1..15= Rock      (mat 9)        — solid crust below the floor
  where N = bathymetry[face, col, row] (1..chunk_size-1).

The rock fill below the seafloor is what makes ocean columns dig like land
(many voxels, not one click) and removes the "open straight to the surface"
gaps.  Digging removes the topmost solid voxel each press, so a deep trench
takes more digs than a shelf — matching the bathymetric data.

Reads data/cache/biomes.npy and data/cache/bathymetry.npy — no upstream
re-runs needed (run elevation.py first if bathymetry is stale).

Usage:
    source pipeline/.venv/bin/activate
    python pipeline/src/interior.py --root .
"""

import argparse
import sys
import zlib
from pathlib import Path

import numpy as np
import yaml

MATERIAL_AIR = 0
MATERIAL_OCEAN = 2
MATERIAL_ROCK = 9
MATERIAL_SEAFLOOR = 10
MATERIAL_OCEAN_CEILING = 11  # solid stand-in for mat 2 at cavity ceiling — diggable, same colour
NUM_FACES = 6

BIOMES_CACHE_REL = Path("data/cache/biomes.npy")
BATHYMETRY_CACHE_REL = Path("data/cache/bathymetry.npy")


def load_config(config_path: Path) -> dict:
    with config_path.open() as f:
        return yaml.safe_load(f)


def export_inner_chunks(config: dict, repo_root: Path) -> None:
    resolution = config["planet"]["resolution"]
    chunk_size = config["planet"]["chunk_size"]

    if resolution % chunk_size != 0:
        raise ValueError(
            f"resolution ({resolution}) must be divisible by chunk_size ({chunk_size})"
        )

    biomes_path = repo_root / BIOMES_CACHE_REL
    bath_path = repo_root / BATHYMETRY_CACHE_REL

    if not biomes_path.exists():
        print(f"Error: biomes cache not found at {biomes_path}", file=sys.stderr)
        print("Run: python pipeline/src/biomes.py", file=sys.stderr)
        sys.exit(1)
    if not bath_path.exists():
        print(f"Error: bathymetry cache not found at {bath_path}", file=sys.stderr)
        print("Run: python pipeline/src/elevation.py", file=sys.stderr)
        sys.exit(1)

    biomes = np.load(biomes_path)
    bath = np.load(bath_path)

    # Downsample cached grids to match config resolution if needed.
    if biomes.shape[1] != resolution:
        step = biomes.shape[1] // resolution
        biomes = biomes[:, ::step, ::step][:, :resolution, :resolution]
        print(f"  Downsampled biomes →{resolution}")
    if bath.shape[1] != resolution:
        step = bath.shape[1] // resolution
        bath = bath[:, ::step, ::step][:, :resolution, :resolution]
        print(f"  Downsampled bathymetry →{resolution}")

    chunks_per_edge = resolution // chunk_size
    output_base = repo_root / config["output"]["chunks"]

    max_n_seen = 0
    total = 0
    for face in range(NUM_FACES):
        face_dir = output_base / f"face_{face}"
        face_dir.mkdir(parents=True, exist_ok=True)
        for cx in range(chunks_per_edge):
            for cy in range(chunks_per_edge):
                raw = bytearray(chunk_size**3)
                for lc in range(chunk_size):
                    for lr in range(chunk_size):
                        col = cx * chunk_size + lc
                        row = cy * chunk_size + lr
                        mat = int(biomes[face, col, row])
                        if mat == MATERIAL_OCEAN:
                            # Water column down to the bathymetric depth, then a
                            # seafloor voxel, then solid rock to the cavity.
                            n = int(bath[face, col, row])
                            n = max(1, min(n, chunk_size - 1))
                            max_n_seen = max(max_n_seen, n)
                            for d in range(n):
                                raw[lc + chunk_size * (lr + chunk_size * d)] = MATERIAL_OCEAN
                            raw[lc + chunk_size * (lr + chunk_size * n)] = MATERIAL_SEAFLOOR
                            for d in range(n + 1, chunk_size - 1):
                                raw[lc + chunk_size * (lr + chunk_size * d)] = MATERIAL_ROCK
                            # Innermost depth = ocean ceiling art — solid so it's diggable.
                            raw[lc + chunk_size * (lr + chunk_size * (chunk_size - 1))] = (
                                MATERIAL_OCEAN_CEILING
                            )
                        else:
                            # Land: rock throughout, biome at the innermost layer (cavity ceiling).
                            for d in range(chunk_size - 1):
                                raw[lc + chunk_size * (lr + chunk_size * d)] = MATERIAL_ROCK
                            raw[lc + chunk_size * (lr + chunk_size * (chunk_size - 1))] = mat

                out_path = face_dir / f"inner_chunk_{cx}_{cy}.bin"
                out_path.write_bytes(zlib.compress(bytes(raw), level=6))
                total += 1

        print(f"  face {face} done")

    expected = NUM_FACES * chunks_per_edge * chunks_per_edge
    assert total == expected, f"wrote {total} chunks, expected {expected}"
    print(
        f"Wrote {total} inner chunks "
        f"({NUM_FACES} faces × {chunks_per_edge}² per face) to {output_base}  "
        f"[deepest ocean water column = {max_n_seen} voxels]"
    )


def main() -> None:
    parser = argparse.ArgumentParser(description="Export inner shell chunk files.")
    parser.add_argument("--config", default="pipeline/config/planet.yaml")
    parser.add_argument("--root", default=".", help="Repo root directory")
    args = parser.parse_args()

    config_path = Path(args.config)
    repo_root = Path(args.root).resolve()

    if not config_path.exists():
        print(f"Error: config not found at {config_path}", file=sys.stderr)
        sys.exit(1)

    config = load_config(config_path)
    export_inner_chunks(config, repo_root)


if __name__ == "__main__":
    main()
