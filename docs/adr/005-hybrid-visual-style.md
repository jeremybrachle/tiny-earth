# ADR 005 — Visual Style: Hybrid Voxel + Low-Poly

**Status:** Accepted
**Date:** 2026-06-02

## Context

The planet needs two kinds of visual elements:
1. **Terrain** — the continuous surface (land, ocean, mountains, biomes)
2. **Landmarks** — iconic structures (Eiffel Tower, Great Pyramid, Statue of Liberty)

The visual style must make landmarks instantly recognizable while keeping the terrain feel consistent with a voxel aesthetic. Three approaches were considered:

| Approach | Terrain | Landmarks | Problem |
|---|---|---|---|
| Pure voxels | Voxel | Voxel | "Sad rectangle Eiffel Tower" — iconic silhouettes are unrecognizable at voxel resolution |
| Pure low-poly meshes | Mesh | Mesh | Loses the mineable, blocky character that makes the planet feel like a toy |
| Hybrid | Voxel | Low-poly mesh | Landmark identity is preserved; terrain character is preserved |

## Decision

**Hybrid approach:** fully voxelized terrain (cube sphere chunk system) with hand-crafted low-poly meshes (`.glb`) for iconic landmarks, placed by the pipeline at correct geographic coordinates.

## Rationale

- **The Bowerbyte problem.** The Bowerbyte "Blocky Planet" article explicitly documents that pure voxels fail to represent landmark silhouettes recognizably at small scales. This is not an aesthetic preference — it is a documented technical failure mode that would undermine the project's core research question.
- **Landmark recognition is the point.** If a player cannot identify the Eiffel Tower, the experiment yields no signal. Landmark meshes solve this definitively.
- **Terrain voxels preserve the artifact.** The planet should feel walkable and toy-like — a voxel surface is the right aesthetic for that. Mesh terrain would lose this character.
- **Low mesh complexity.** Landmark meshes are kept under 500 triangles each. At planet scale, they read as iconic silhouettes rather than detailed models.

## Consequences

- All terrain is voxel data: land mask, elevation, biomes, cities rendered as material ID clusters.
- Landmarks are `.glb` assets in `engine/assets/landmarks/`. They are placed in Godot scenes by reading `cube_face`, `face_u`, `face_v` from `features.geojson` and instantiating the mesh at the projected surface position.
- Landmark mesh authoring is manual work — approximately 20–30 assets targeted for Phase 7.
- The pipeline does not voxelize landmark geometry; it only computes their surface coordinates.
