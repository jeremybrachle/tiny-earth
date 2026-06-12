# ADR 004 — Voxel Chunk Serialization Format

**Status:** Accepted
**Date:** 2026-06-02

## Context

The pipeline must write voxel data to disk in a format that Godot can load at runtime. The format must be:
- Trivially parseable in GDScript or C#
- Compact enough that a full planet (~1,500 chunks) fits in a reasonable download
- Simple enough to write correctly in a first pass

Candidates evaluated:

| Format | Parse complexity | Size | Notes |
|---|---|---|---|
| JSON array of material IDs | Trivial | Large | 4,096 integers × 2+ chars each = ~10 KB/chunk uncompressed |
| SQLite per face | Moderate | Compact | Runtime dependency; harder to stream |
| Raw uint8 + zlib | Trivial | Compact | 4,096 bytes → ~100–400 bytes compressed; no dependencies |
| Custom binary with header | Low | Compact | Adds version/metadata overhead; not needed for v1 |

## Decision

**Raw `uint8` array, row-major XYZ order, one file per chunk, zlib compressed.**

File path: `engine/planet/faces/face_{N}/chunk_{X}_{Y}.bin`

## Rationale

- **Zero parse overhead.** In GDScript: `var data = voxels.decompress(4096); var mat = data[x + y*16 + z*256]`. No schema, no headers, no library.
- **Compact.** An empty/uniform chunk compresses to under 50 bytes. A typical surface chunk compresses to 100–500 bytes. Full planet at 1,500 chunks is under 1 MB compressed.
- **zlib is everywhere.** Python `zlib` module and Godot's built-in `compress/decompress` both support zlib with no additional dependencies.
- **Chunk size: 16³ (fixed).** 16 is the conventional voxel game chunk size — cache-friendly, small enough for fast load/unload, large enough to amortize filesystem overhead.

## Consequences

- **Chunk size is frozen after Phase 2.** Changing `CHUNK_SIZE` after chunks are written to disk requires regenerating every chunk file. This is documented as a constraint in the Phase 2 completion criteria.
- Material IDs are `uint8`, giving 256 possible materials. Material 255 is reserved. Current allocation uses IDs 0–10.
- Chunk indexing within a face: chunk `(X, Y)` covers voxels `[X*16, (X+1)*16)` × `[Y*16, (Y+1)*16)` in face UV space.
- Planet resolution of 256 voxels per face edge → 16 chunks per edge → 256 chunks per face → 1,536 total chunks at base resolution.
