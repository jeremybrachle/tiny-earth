# ADR 002 — Planet Geometry: Cube Sphere

**Status:** Accepted
**Date:** 2026-06-02

## Context

The voxel planet needs a sphere geometry that:
1. Has uniform voxel density across the entire surface (no pole pinching)
2. Supports a clean chunk system with predictable chunk sizes
3. Has well-documented mathematical foundations

Candidates evaluated:

| Approach | Voxel density | Chunk complexity | Notes |
|---|---|---|---|
| UV sphere (lat/lon grid) | Degenerates at poles | Simple grid | Polar voxels are tiny; equatorial voxels are large |
| Icosphere | Approximately uniform | Complex seams | Triangular faces; difficult chunk alignment |
| Cube sphere (6 faces) | Uniform | Simple grid per face | Mild distortion at face corners; well-documented |

## Decision

**Cube sphere:** six square faces projected onto a sphere surface, each subdivided into an N×N grid of surface voxels.

## Rationale

- **Uniform density.** Every surface voxel covers approximately the same solid angle — no pathological behavior at poles.
- **Clean chunk system.** Each face is a regular grid, so chunk boundaries are axis-aligned and seam handling is limited to the 12 face edges and 8 corners.
- **Established math.** The cube-to-sphere projection and its inverse are documented in the academic reference at `docs/REFERENCES.md` (mathproofs.blogspot.com). No novel mathematics required.
- **Confirmed feasible.** Both `ddupont808/planetcraft` and `josebasierra/voxel-planets` use this approach successfully.
- **Bowerbyte informed.** The Bowerbyte "Blocky Planet" article specifically documents the distortion problem and practical limits of this approach, so the known failure modes are documented before implementation begins.

## Consequences

- All internal coordinates use `(face: int, u: float, v: float, depth: int)`. Raw WGS84 lat/lon is converted entirely within the Python pipeline — Godot never handles geographic coordinates.
- Planet resolution is set in `planet.yaml` as `resolution` (voxels per face edge). The initial value is 256.
- Face seam handling (12 edges + 8 corners) is the highest-risk implementation challenge in Phase 2.
- The mild distortion at face corners (~40% area variation) is acceptable at this scale.
