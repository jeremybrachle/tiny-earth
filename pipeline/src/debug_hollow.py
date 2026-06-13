"""
Diagnostic for Issue 3: ~10 hollow voxels under the outer surface.

Loads biomes.npy and inner_chunk_*.bin files, and for each column in each face,
checks whether the inner chunk depth-0 mat value matches the biomes.npy classification.

Expected:
  biomes == 2 (ocean)  → inner depth 0 = 2 (water)  — expected hollow at depths 0..N-1
  biomes != 2 (land)   → inner depth 0 = 9 (rock)   — should be solid, NO hollow

Reports columns where a land column (biomes != 2) has a non-rock mat at depth 0,
plus a summary of what mat values those columns actually contain at depth 0.
"""

import argparse
import sys
import zlib
from pathlib import Path
from collections import Counter

import numpy as np
import yaml

CHUNK_SIZE = 16
NUM_FACES  = 6
MATERIAL_OCEAN = 2
MATERIAL_ROCK  = 9


def voxel(data: bytes, lc: int, lr: int, depth: int) -> int:
    return data[lc + CHUNK_SIZE * (lr + CHUNK_SIZE * depth)]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=".")
    parser.add_argument("--config", default="pipeline/config/planet.yaml")
    parser.add_argument("--max-report", type=int, default=20,
                        help="Max mismatch columns to print per face")
    args = parser.parse_args()

    repo_root   = Path(args.root).resolve()
    config_path = Path(args.config)
    with config_path.open() as f:
        config = yaml.safe_load(f)

    resolution      = config["planet"]["resolution"]
    chunk_size      = config["planet"]["chunk_size"]
    chunks_per_edge = resolution // chunk_size
    chunks_dir      = repo_root / config["output"]["chunks"]

    biomes_path = repo_root / "data/cache/biomes.npy"
    biomes = np.load(biomes_path)
    if biomes.shape[1] != resolution:
        step   = biomes.shape[1] // resolution
        biomes = biomes[:, ::step, ::step][:, :resolution, :resolution]

    total_land_cols    = 0
    total_hollow_land  = 0

    for face in range(NUM_FACES):
        face_dir = chunks_dir / f"face_{face}"
        hollow_count = 0
        depth0_mats  = Counter()

        for cx in range(chunks_per_edge):
            for cy in range(chunks_per_edge):
                path = face_dir / f"inner_chunk_{cx}_{cy}.bin"
                if not path.exists():
                    continue
                raw = zlib.decompress(path.read_bytes())

                for lc in range(chunk_size):
                    for lr in range(chunk_size):
                        col = cx * chunk_size + lc
                        row = cy * chunk_size + lr
                        bio = int(biomes[face, col, row])
                        if bio == MATERIAL_OCEAN:
                            continue  # ocean hollow is expected
                        total_land_cols += 1
                        m0 = voxel(raw, lc, lr, 0)
                        if m0 != MATERIAL_ROCK:
                            depth0_mats[m0] += 1
                            hollow_count += 1
                            if hollow_count <= args.max_report:
                                # Print full depth profile for this column.
                                depths = [voxel(raw, lc, lr, d) for d in range(chunk_size)]
                                print(
                                    f"  face={face} col={col} row={row} "
                                    f"biome={bio} depth0={m0} "
                                    f"profile={depths}"
                                )

        total_hollow_land += hollow_count
        print(
            f"Face {face}: {hollow_count} land columns have non-rock at depth 0  "
            f"(depth-0 mat distribution: {dict(depth0_mats)})"
        )

    print(
        f"\nSummary: {total_hollow_land} / {total_land_cols} land columns have "
        f"non-rock at inner depth 0 ({100*total_hollow_land/max(total_land_cols,1):.1f}%)"
    )


if __name__ == "__main__":
    main()
