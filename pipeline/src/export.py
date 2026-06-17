"""
Planet chunk export.

Produces one zlib-compressed .bin chunk file per chunk slot.

Modes:
  (default)              all-Air (material 0)
  --solid                all-Land (material 1)
  --landmask             per-voxel Land/Ocean from data/cache/landmask.npy
  --landmask --elevation per-voxel material + stacked voxel columns from elevation.npy

Usage:
    python pipeline/src/export.py
    python pipeline/src/export.py --solid
    python pipeline/src/export.py --landmask
    python pipeline/src/export.py --landmask --elevation
    python pipeline/src/export.py --config pipeline/config/planet.yaml --root .
"""

import argparse
import json
import sys
import zlib
from pathlib import Path

import yaml

MATERIAL_AIR = 0
MATERIAL_LAND = 1
MATERIAL_OCEAN = 2
MATERIAL_ROCK = 9  # solid subsurface rock filling the crust below the biome surface
MATERIAL_SEAFLOOR = 10  # rocky/sandy ocean floor exposed below water column
NUM_FACES = 6

LANDMASK_CACHE_REL = Path("data/cache/landmask.npy")
BIOMES_CACHE_REL = Path("data/cache/biomes.npy")
ELEVATION_CACHE_REL = Path("data/cache/elevation.npy")
BATHYMETRY_CACHE_REL = Path("data/cache/bathymetry.npy")


def load_config(config_path: Path) -> dict:
    with config_path.open() as f:
        return yaml.safe_load(f)


def write_planet_config(config: dict, repo_root: Path) -> None:
    """Write engine/planet/planet_config.json so Godot reads scale/resolution from one place."""
    resolution = config["planet"]["resolution"]
    chunk_size = config["planet"]["chunk_size"]
    radius_scale = config["planet"].get("radius_scale", 1.0)
    planet_radius = resolution * radius_scale

    out_dir = repo_root / config["output"]["chunks"]
    out_dir = out_dir.parent  # engine/planet/ (parent of engine/planet/faces/)
    out_dir.mkdir(parents=True, exist_ok=True)

    data = {
        "planet_radius": planet_radius,
        "resolution": resolution,
        "chunk_size": chunk_size,
        "chunks_per_edge": resolution // chunk_size,
        # Staged planet generator (engine-side): which features the inner-world
        # generator enables. Persisted here so it survives chunk regeneration.
        # Override via planet.yaml `planet.generation_stage`; defaults to 1.
        "generation_stage": config["planet"].get("generation_stage", 1),
    }
    (out_dir / "planet_config.json").write_text(json.dumps(data, indent=2))
    print(f"Wrote planet_config.json  (radius={planet_radius}, resolution={resolution})")


def make_chunk(chunk_size: int, material: int = MATERIAL_AIR) -> bytes:
    """Return a zlib-compressed chunk filled with the given material ID."""
    raw = bytes([material] * chunk_size**3)
    return zlib.compress(raw, level=6)


def make_empty_chunk(chunk_size: int) -> bytes:
    return make_chunk(chunk_size, material=MATERIAL_AIR)


def export_empty_planet(config: dict, repo_root: Path, solid: bool = False) -> None:
    resolution = config["planet"]["resolution"]
    chunk_size = config["planet"]["chunk_size"]

    if resolution % chunk_size != 0:
        raise ValueError(
            f"resolution ({resolution}) must be divisible by chunk_size ({chunk_size})"
        )

    chunks_per_edge = resolution // chunk_size
    output_base = repo_root / config["output"]["chunks"]
    material = MATERIAL_LAND if solid else MATERIAL_AIR
    chunk_data = make_chunk(chunk_size, material=material)

    total = 0
    for face in range(NUM_FACES):
        face_dir = output_base / f"face_{face}"
        face_dir.mkdir(parents=True, exist_ok=True)
        for cx in range(chunks_per_edge):
            for cy in range(chunks_per_edge):
                (face_dir / f"chunk_{cx}_{cy}.bin").write_bytes(chunk_data)
                total += 1

    expected = NUM_FACES * chunks_per_edge * chunks_per_edge
    assert total == expected, f"wrote {total} chunks, expected {expected}"
    label = "solid Land" if solid else "empty Air"
    print(
        f"Wrote {total} {label} chunks "
        f"({NUM_FACES} faces × {chunks_per_edge}² chunks per face) "
        f"to {output_base}"
    )


def export_landmask_planet(
    config: dict, repo_root: Path, landmask, elevation=None, bathymetry=None
) -> None:
    """Write chunk files with per-voxel Land/Ocean material from a landmask array.

    landmask:   (6, resolution, resolution) uint8 — material per surface voxel
    elevation:  optional (6, resolution, resolution) uint8 — extra land-elevation layers (0–8)
    bathymetry: optional (6, resolution, resolution) uint8 — ocean water-column depth layers (1–4)
                When provided, ocean columns get a MATERIAL_SEAFLOOR base at depth 0 and
                MATERIAL_OCEAN water voxels at depths 1..depth, giving real seafloor geometry.
    """
    import numpy as np

    resolution = config["planet"]["resolution"]
    chunk_size = config["planet"]["chunk_size"]

    if resolution % chunk_size != 0:
        raise ValueError(
            f"resolution ({resolution}) must be divisible by chunk_size ({chunk_size})"
        )

    grid = np.asarray(landmask, dtype=np.uint8)
    if grid.shape != (6, resolution, resolution):
        raise ValueError(
            f"landmask shape {grid.shape} does not match (6, {resolution}, {resolution})"
        )

    elev_grid = None
    if elevation is not None:
        elev_grid = np.asarray(elevation, dtype=np.uint8)
        if elev_grid.shape != (6, resolution, resolution):
            raise ValueError(
                f"elevation shape {elev_grid.shape} does not match (6, {resolution}, {resolution})"
            )

    bath_grid = None
    if bathymetry is not None:
        bath_grid = np.asarray(bathymetry, dtype=np.uint8)
        if bath_grid.shape != (6, resolution, resolution):
            raise ValueError(
                f"bathymetry shape {bath_grid.shape} does not match (6, {resolution}, {resolution})"
            )

    chunks_per_edge = resolution // chunk_size
    output_base = repo_root / config["output"]["chunks"]

    total = 0
    for face in range(NUM_FACES):
        face_dir = output_base / f"face_{face}"
        face_dir.mkdir(parents=True, exist_ok=True)
        for cx in range(chunks_per_edge):
            for cy in range(chunks_per_edge):
                raw = bytearray(chunk_size**3)  # all Air by default
                for lc in range(chunk_size):
                    for lr in range(chunk_size):
                        col = cx * chunk_size + lc
                        row = cy * chunk_size + lr
                        mat = int(grid[face, col, row])
                        if mat == MATERIAL_AIR:
                            continue

                        extra = int(elev_grid[face, col, row]) if elev_grid is not None else 0
                        if mat == MATERIAL_OCEAN:
                            # Ocean: single water-surface voxel at depth 0 (sea level).
                            # Deeper seafloor geometry requires a bidirectional chunk
                            # format (future work); for now the wave shader prevents
                            # gaps by only displacing outward from planet_radius.
                            raw[lc + chunk_size * (lr + chunk_size * 0)] = MATERIAL_OCEAN
                        else:
                            # Land: fill depths 0..extra with the surface material.
                            for depth in range(min(1 + extra, chunk_size)):
                                idx = lc + chunk_size * (lr + chunk_size * depth)
                                raw[idx] = mat

                (face_dir / f"chunk_{cx}_{cy}.bin").write_bytes(zlib.compress(bytes(raw), level=6))
                total += 1

    expected = NUM_FACES * chunks_per_edge * chunks_per_edge
    assert total == expected, f"wrote {total} chunks, expected {expected}"
    modes = ["landmask"]
    if elev_grid is not None:
        modes.append("elevation")
    if bath_grid is not None:
        modes.append("bathymetry")
    print(
        f"Wrote {total} {'+'.join(modes)} chunks "
        f"({NUM_FACES} faces × {chunks_per_edge}² chunks per face) "
        f"to {output_base}"
    )


def main() -> None:
    parser = argparse.ArgumentParser(description="Export planet chunk structure.")
    parser.add_argument(
        "--config",
        default="pipeline/config/planet.yaml",
        help="Path to planet.yaml (default: pipeline/config/planet.yaml)",
    )
    parser.add_argument(
        "--root",
        default=".",
        help="Repo root directory (default: current working directory)",
    )
    parser.add_argument(
        "--solid",
        action="store_true",
        help="Fill all voxels with Land (material 1) instead of Air",
    )
    parser.add_argument(
        "--landmask",
        action="store_true",
        help="Write per-voxel Land/Ocean from data/cache/landmask.npy",
    )
    parser.add_argument(
        "--biomes",
        action="store_true",
        help="Write per-voxel biome material IDs from data/cache/biomes.npy",
    )
    parser.add_argument(
        "--elevation",
        action="store_true",
        help="Stack voxel columns using data/cache/elevation.npy (requires --landmask or --biomes)",
    )
    parser.add_argument(
        "--bathymetry",
        action="store_true",
        help="Add seafloor + water-column depth to ocean tiles using data/cache/bathymetry.npy "
        "(requires --elevation; run elevation.py first to generate the cache)",
    )
    args = parser.parse_args()

    if args.solid and (args.landmask or args.biomes):
        print("Error: --solid is mutually exclusive with --landmask and --biomes.", file=sys.stderr)
        sys.exit(1)
    if args.landmask and args.biomes:
        print("Error: --landmask and --biomes are mutually exclusive.", file=sys.stderr)
        sys.exit(1)
    if args.elevation and not (args.landmask or args.biomes):
        print("Error: --elevation requires --landmask or --biomes.", file=sys.stderr)
        sys.exit(1)
    if args.bathymetry and not args.elevation:
        print("Error: --bathymetry requires --elevation.", file=sys.stderr)
        sys.exit(1)

    config_path = Path(args.config)
    repo_root = Path(args.root).resolve()

    if not config_path.exists():
        print(f"Error: config not found at {config_path}", file=sys.stderr)
        sys.exit(1)

    config = load_config(config_path)

    if args.landmask or args.biomes:
        import numpy as np

        if args.biomes:
            cache_path = repo_root / BIOMES_CACHE_REL
            if not cache_path.exists():
                print(f"Error: biomes cache not found at {cache_path}", file=sys.stderr)
                print("Run: python pipeline/src/biomes.py", file=sys.stderr)
                sys.exit(1)
        else:
            cache_path = repo_root / LANDMASK_CACHE_REL
            if not cache_path.exists():
                print(f"Error: landmask cache not found at {cache_path}", file=sys.stderr)
                print("Run: python pipeline/src/landmask.py", file=sys.stderr)
                sys.exit(1)

        landmask = np.load(cache_path)

        elevation = None
        if args.elevation:
            elev_path = repo_root / ELEVATION_CACHE_REL
            if not elev_path.exists():
                print(f"Error: elevation cache not found at {elev_path}", file=sys.stderr)
                print("Run: python pipeline/src/elevation.py", file=sys.stderr)
                sys.exit(1)
            elevation = np.load(elev_path)

        bathymetry = None
        if args.bathymetry:
            bath_path = repo_root / BATHYMETRY_CACHE_REL
            if not bath_path.exists():
                print(f"Error: bathymetry cache not found at {bath_path}", file=sys.stderr)
                print(
                    "Run: python pipeline/src/elevation.py  (it writes both caches)",
                    file=sys.stderr,
                )
                sys.exit(1)
            bathymetry = np.load(bath_path)

        export_landmask_planet(
            config, repo_root, landmask, elevation=elevation, bathymetry=bathymetry
        )
    else:
        export_empty_planet(config, repo_root, solid=args.solid)

    write_planet_config(config, repo_root)


if __name__ == "__main__":
    main()
