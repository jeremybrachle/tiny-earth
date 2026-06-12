# ADR 001 — Game Engine: Godot 4.x

**Status:** Accepted
**Date:** 2026-06-02

## Context

The project needs a 3D game engine capable of rendering a voxel planet with custom gravity, a chunk-based terrain system, and data-driven object placement from GeoJSON. The engine must be compatible with the project's open-source posture and legal constraints.

Candidates evaluated:

| Engine | License | Notes |
|---|---|---|
| Godot 4.x | MIT | Fully open source; GDScript + native C# |
| Unity 6 | Proprietary | Runtime fee history; `josebasierra/voxel-planets` (MIT) is Unity-based |
| Custom (raw OpenGL/Vulkan) | N/A | Weeks of boilerplate before any planet work |

## Decision

**Godot 4.x**, using GDScript for game logic and C# for performance-critical systems (chunk generation, gravity physics).

## Rationale

- **No licensing risk.** MIT license means no runtime fees, no revenue thresholds, no surprise policy changes. A public portfolio demo will never trigger a fee.
- **Native C# for hot paths.** Chunk mesh generation and physics are the two systems most likely to need low-level optimization. Godot's C# integration covers this without leaving the engine.
- **GDScript for everything else.** Player controller, scene management, and data-driven placement are rapid to prototype in GDScript and easy for reviewers to read.
- **Strong voxel community.** Chunk-based terrain plugins and cube sphere references exist in the Godot ecosystem.
- **`josebasierra/voxel-planets` doesn't port directly regardless.** That reference implementation is Unity/C# — the architectural patterns are reusable but the code is not, so the engine choice doesn't change how we reference it.

## Consequences

- The chunk system, cube sphere mesh generation, and local gravity must be implemented from scratch in Godot — no Unity code can be imported.
- `engine/` is the Godot 4 project root. The directory name is intentionally generic.
- All performance profiling and optimization will target Godot's rendering pipeline and C# GC behavior.
