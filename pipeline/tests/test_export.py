"""
Unit tests for export.py Phase 0: empty planet structure.
"""

import zlib

import pytest
import yaml

from export import export_empty_planet, load_config, make_chunk, make_empty_chunk

CHUNK_SIZE = 16
NUM_FACES = 6


@pytest.fixture
def minimal_config(tmp_path):
    cfg = {
        "planet": {"resolution": 32, "chunk_size": 16},
        "compression": {"top_n": 200, "min_per_continent": 1},
        "scoring": {"w_pop": 0.4, "w_sal": 0.3, "w_uniq": 0.2, "w_conn": 0.1},
        "output": {"geojson": "data/exports/features.geojson", "chunks": "engine/planet/faces"},
        "cache": {"osm_ttl_days": 7, "wiki_ttl_days": 30},
    }
    config_path = tmp_path / "planet.yaml"
    config_path.write_text(yaml.dump(cfg))
    return cfg, tmp_path


def test_make_empty_chunk_decompresses_to_correct_size():
    data = make_empty_chunk(CHUNK_SIZE)
    raw = zlib.decompress(data)
    assert len(raw) == CHUNK_SIZE**3


def test_make_empty_chunk_all_zeros():
    data = make_empty_chunk(CHUNK_SIZE)
    raw = zlib.decompress(data)
    assert all(b == 0 for b in raw)


def test_make_empty_chunk_is_compressed():
    data = make_empty_chunk(CHUNK_SIZE)
    # Compressed all-zeros should be much smaller than raw
    assert len(data) < CHUNK_SIZE**3


def test_export_creates_all_faces(minimal_config):
    config, repo_root = minimal_config
    export_empty_planet(config, repo_root)
    for face in range(NUM_FACES):
        assert (repo_root / "engine" / "planet" / "faces" / f"face_{face}").is_dir()


def test_export_correct_chunk_count(minimal_config):
    config, repo_root = minimal_config
    export_empty_planet(config, repo_root)

    resolution = config["planet"]["resolution"]
    chunk_size = config["planet"]["chunk_size"]
    chunks_per_edge = resolution // chunk_size
    expected = NUM_FACES * chunks_per_edge * chunks_per_edge

    base = repo_root / "engine" / "planet" / "faces"
    actual = sum(1 for _ in base.rglob("chunk_*.bin"))
    assert actual == expected


def test_export_chunk_filenames(minimal_config):
    config, repo_root = minimal_config
    export_empty_planet(config, repo_root)

    resolution = config["planet"]["resolution"]
    chunk_size = config["planet"]["chunk_size"]
    chunks_per_edge = resolution // chunk_size

    base = repo_root / "engine" / "planet" / "faces"
    for face in range(NUM_FACES):
        for cx in range(chunks_per_edge):
            for cy in range(chunks_per_edge):
                path = base / f"face_{face}" / f"chunk_{cx}_{cy}.bin"
                assert path.exists(), f"Missing: {path}"


def test_export_chunks_are_valid_zlib(minimal_config):
    config, repo_root = minimal_config
    export_empty_planet(config, repo_root)

    base = repo_root / "engine" / "planet" / "faces"
    for chunk_path in base.rglob("chunk_*.bin"):
        raw = zlib.decompress(chunk_path.read_bytes())
        assert len(raw) == CHUNK_SIZE**3


def test_export_rejects_misaligned_resolution(tmp_path):
    config = {
        "planet": {"resolution": 30, "chunk_size": 16},  # 30 not divisible by 16
        "output": {"chunks": "engine/planet/faces"},
    }
    with pytest.raises(ValueError, match="divisible"):
        export_empty_planet(config, tmp_path)


def test_make_chunk_land_correct_size():
    data = make_chunk(CHUNK_SIZE, material=1)
    raw = zlib.decompress(data)
    assert len(raw) == CHUNK_SIZE**3


def test_make_chunk_land_all_ones():
    data = make_chunk(CHUNK_SIZE, material=1)
    raw = zlib.decompress(data)
    assert all(b == 1 for b in raw)


def test_make_chunk_air_matches_make_empty_chunk():
    assert make_chunk(CHUNK_SIZE, material=0) == make_empty_chunk(CHUNK_SIZE)


def test_export_solid_all_land(minimal_config):
    config, repo_root = minimal_config
    export_empty_planet(config, repo_root, solid=True)
    base = repo_root / "engine" / "planet" / "faces"
    for chunk_path in base.rglob("chunk_*.bin"):
        raw = zlib.decompress(chunk_path.read_bytes())
        assert all(b == 1 for b in raw), f"Expected all Land in {chunk_path.name}"


def test_export_default_still_air(minimal_config):
    config, repo_root = minimal_config
    export_empty_planet(config, repo_root)  # solid defaults to False
    base = repo_root / "engine" / "planet" / "faces"
    for chunk_path in base.rglob("chunk_*.bin"):
        raw = zlib.decompress(chunk_path.read_bytes())
        assert all(b == 0 for b in raw)


def test_load_config_roundtrip(tmp_path):
    cfg = {"planet": {"resolution": 256, "chunk_size": 16}}
    config_path = tmp_path / "planet.yaml"
    config_path.write_text(yaml.dump(cfg))
    loaded = load_config(config_path)
    assert loaded["planet"]["resolution"] == 256
    assert loaded["planet"]["chunk_size"] == 16
