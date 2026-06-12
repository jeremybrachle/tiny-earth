# Phase 1 Handoff — Walkable Sphere

**Goal:** A player walks around a tiny sphere with correct local gravity. No Earth data. No voxels. Just physics working right.

**Done when:** Player completes a full orbit on foot in under 2 minutes without losing orientation or clipping.

---

## Godot Setup

1. Install Godot 4.x from https://godotengine.org/
2. Open the `engine/` folder as a new Godot 4 project
3. Create `engine/project.godot` by opening Godot → New Project → select the `engine/` directory

---

## Scene Structure

Create one scene: `engine/scenes/world.tscn`

```
World (Node3D)  ← world.gd
├── Planet (StaticBody3D)  ← planet.gd
│   ├── MeshInstance3D       [SphereMesh, radius=10]
│   └── CollisionShape3D     [SphereShape3D, radius=10]
└── Player (CharacterBody3D)  ← player.gd
    ├── MeshInstance3D        [CapsuleMesh]
    ├── CollisionShape3D      [CapsuleShape3D, height=1.8, radius=0.4]
    └── Camera3D              [positioned at (0, 2, 4) relative to player]
```

**Planet radius:** 10 Godot units. Small enough to see curvature while walking.

**Player start position:** `Vector3(0, 11.9, 0)` — just above the surface.

Set **World → Planet** as an `@export` on the Player node in the inspector.

---

## Scripts

### `engine/scripts/world/world.gd`

```gdscript
extends Node3D
# Scene root — no logic needed in Phase 1.
# Planet and Player are placed as children in the scene editor.
```

### `engine/scripts/planet/planet.gd`

```gdscript
extends StaticBody3D
# Phase 1: static sphere, no logic.
# Gravity is computed by the player relative to this node's global_position.
```

### `engine/scripts/player/player.gd`

```gdscript
extends CharacterBody3D

const GRAVITY_STRENGTH := 20.0
const WALK_SPEED       := 5.0
const JUMP_VELOCITY    := 8.0

@export var planet: StaticBody3D
@onready var camera: Camera3D = $Camera3D

func _physics_process(delta: float) -> void:
    var gravity_dir    := (planet.global_position - global_position).normalized()
    var surface_normal := -gravity_dir

    # Tell move_and_slide() which direction is "up" for this frame
    up_direction = surface_normal

    # Apply gravity when airborne
    if not is_on_floor():
        velocity += gravity_dir * GRAVITY_STRENGTH * delta

    # Align player upright to planet surface
    _align_to_surface(surface_normal)

    # Movement relative to camera's projected horizontal axes
    var cam_fwd   := _project_to_plane(-camera.global_basis.z, surface_normal)
    var cam_right := _project_to_plane( camera.global_basis.x, surface_normal)

    var input := Vector2(
        Input.get_action_strength("ui_right") - Input.get_action_strength("ui_left"),
        Input.get_action_strength("ui_down")  - Input.get_action_strength("ui_up")
    )
    var wish_dir := (cam_fwd * -input.y + cam_right * input.x)

    # Decompose velocity into gravity-axis and horizontal components
    var vert_vel  := velocity.project(gravity_dir)
    var horiz_vel := velocity - vert_vel

    if wish_dir.length() > 0.01:
        horiz_vel = wish_dir.normalized() * WALK_SPEED
    else:
        horiz_vel = horiz_vel.lerp(Vector3.ZERO, 0.25)  # surface friction

    velocity = vert_vel + horiz_vel

    if Input.is_action_just_pressed("ui_accept") and is_on_floor():
        velocity += surface_normal * JUMP_VELOCITY

    move_and_slide()


func _align_to_surface(surface_normal: Vector3) -> void:
    # Smoothly rotate the player so their local +Y aligns with the surface normal.
    var current_up := global_basis.y
    if current_up.dot(surface_normal) < 0.9999:
        var rot_axis  := current_up.cross(surface_normal).normalized()
        var rot_angle := current_up.angle_to(surface_normal)
        if rot_axis.length() > 0.001:
            global_basis = global_basis.rotated(rot_axis, rot_angle * 0.3)


func _project_to_plane(v: Vector3, normal: Vector3) -> Vector3:
    # Project vector onto the plane defined by normal, then normalize.
    var projected := v - v.dot(normal) * normal
    return projected.normalized() if projected.length() > 0.001 else Vector3.ZERO
```

---

## Camera Setup

In the scene editor, position `Camera3D` as a child of Player at:
- **Position:** `(0, 1.6, 4)` — slightly above and behind
- **Rotation:** `(-15°, 0, 0)` — angled slightly down toward planet

Do **not** use a `SpringArm3D` yet — add that in Phase 2 if clipping becomes a problem.

For a basic orbital view (optional), add a second Camera3D as a child of World at `(0, 30, 0)` looking down, toggled with a key.

---

## Input Map

In **Project → Project Settings → Input Map**, confirm these actions exist (they're Godot defaults):

| Action | Key |
|---|---|
| `ui_up` | W / Arrow Up |
| `ui_down` | S / Arrow Down |
| `ui_left` | A / Arrow Left |
| `ui_right` | D / Arrow Right |
| `ui_accept` | Space |

---

## Validation Checklist

Run the scene and verify each before moving to Phase 2:

- [ ] Player spawns on the surface without falling through
- [ ] Gravity pulls toward planet center from any position on the sphere
- [ ] Player's feet always point toward the planet — no "upside down" feeling
- [ ] Walking north from the equator eventually brings you back to your start
- [ ] Full orbit on foot completes in under 2 minutes at default speed
- [ ] Jumping feels right — player lands back on the sphere, not floating away
- [ ] No orientation glitch when crossing from one side of the planet to the other

---

## Common Pitfalls

**Player falls through the sphere:** Check that `CollisionShape3D` radius on Planet matches the `SphereMesh` radius exactly (both = 10).

**Player flips upside down:** The `_align_to_surface` lerp factor (0.3) may be too fast on the first frame — add a `_ready()` that sets `global_basis` to the correct orientation at spawn.

**`move_and_slide()` ignores gravity:** You must set `up_direction` every physics frame before calling `move_and_slide()`, not just once in `_ready()`.

**Camera clips into the planet:** Temporarily position the camera further back (increase Z from 4 to 8). Fix properly with a `SpringArm3D` in Phase 2.

---

## What Phase 2 Adds

Phase 1 uses a smooth `SphereMesh` — there's nothing to mine or walk "on" in a tactile way. Phase 2 replaces this with a voxelized cube sphere: six faces, each an N×N grid of cube voxels, loaded from the binary chunk files already produced by `export.py`. The gravity and player controller from Phase 1 carry forward unchanged.
