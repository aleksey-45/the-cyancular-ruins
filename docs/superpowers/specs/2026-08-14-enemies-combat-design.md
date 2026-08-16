# Enemies + Player Combat of CyR — Design

**Date:** 2026-08-14
**Status:** approved

## Purpose

Add an enemy system to *The Cyancular Ruins* with random spawning, the first enemy
type **Jump_Bird**, and the player combat loop: pistol shooting, a health bar,
contact damage with knockback, and a downed/gray-screen/R-restart state.

The architecture is built to scale to **dozens of enemy types** later (the user
explicitly asked "what if I have tens of enemy types"): a shared `EnemyBase` with
behavior hooks + a type registry in the spawner, so adding a type = one `.tscn` +
one `.gd` + one registry line.

## Scope

In scope:

- Enemy spawner (random empty cells, fixed count, min distance from player, type registry).
- `EnemyBase` shared base class.
- `Jump_Bird` enemy with a full state machine.
- Player pistol: mouse-aim shooting, recoil, bullet projectile.
- Player HP / contact damage / knockback / i-frames / downed state.
- Post-process desaturation on downed; HUD health bar; R to restart.

Out of scope:

- Map-generation rewrite, new enemy types beyond Jump_Bird, enemy death animation
  (enemies just `queue_free` for now), healing, ammo/resource management.

## Explicit user decisions (recorded)

- **Aim:** left mouse shoots; mouse movement controls pitch only, clamped to
  **-45°…+45°** from horizontal; horizontal direction always follows the player's
  `facing_direction` (mouse never flips the facing).
- **Pistol is a light weapon:** shooting does **not** affect movement speed.
  Recoil is visual only (gun kick + tiny camera shake).
- **Player death (HP = 0):** rotate 90° opposite the facing direction, screen turns
  gray (desaturate), controls disabled, press **R** to reload the current level.
- **HUD:** health bar only. **No crosshair** (explicitly rejected).
- **Spawning:** fixed count generated once at level start, at random empty cells,
  at least `spawn_min_dist` from the player.
- **Scaling:** modular per-type scenes + type registry + base-class behavior hooks
  (approach A), not a behavior-tree framework.

## Jump_Bird sprite frames

`AssetBundle/Sprites/Jump_Bird.png` is 200×200; frames are 48×48 in 2 rows × 4 cols.
Let top row = `t0 t1 t2 t3`, bottom row = `b0 b1 b2 b3` (x = 0,48,96,144).

| Animation | Frames (in order) | Notes |
|-----------|-------------------|-------|
| Sleep (dormant) loop | `t0 b3 b2 b1` | reverse of wake |
| Wake-up (once) | `b1 b2 b3 t0` | played on spawn-awake transition |
| Alert / flashing | `t0 t1` | "light flashing", used during chase |
| Lunge windup (once) | `t1 t2 t3` | then the dash |
| Dash / lunge | `t3` | straight horizontal dash |
| Back-hop | reuse `t2` | recovery hop after lunge |

## Architecture & files

```
Scenes/
├── Enemies/                      # new directory
│   ├── enemy_base.gd             # abstract CharacterBody2D base
│   ├── EnemyJumpBird.tscn        # Jump_Bird scene
│   ├── enemy_jump_bird.gd        # Jump_Bird state machine
│   └── enemy_spawner.gd          # spawner (Node2D): type registry + spawn_all()
├── bullet.gd                     # Area2D bullet
├── Bullet.tscn
├── player_gun.gd                 # Gun node script: aim / fire / recoil
├── hud.gd                        # health-bar HUD
└── (existing) Player.tscn, player.gd, level_0.gd, post_process.gd
```

### EnemyBase (abstract, CharacterBody2D)

Common plumbing all enemy types share:

- `hp`, `hurt(damage: int, knock_dir: Vector2)`, hit-flash, knockback impulse,
  `queue_free()` on death.
- Contact damage: an `Area2D` child that monitors overlap with the `player` group
  and emits a signal / calls back to damage the player once (respecting i-frames).
- Toroidal wrap (same mod-map logic as the player).
- Toroidal distance helper to the player (`toroidal_delta`).
- Behavior hooks, empty by default, overridden per type:
  - `_ai(delta)` — per-type AI main loop
  - `_anim_update()` — animation driving
  - `_wake_range()` / `_give_up_range()` — used by types with a dormant state

### Type registry + spawner (`enemy_spawner.gd`)

```gdscript
const TYPES := {
    "jump_bird": preload("res://Scenes/Enemies/EnemyJumpBird.tscn"),
    # future: "flyer": preload("res://Scenes/Enemies/Flyer.tscn"),
}
```

- `spawn_all(grid: Array[Array], player_pos: Vector2)` — called by `Level0._ready`
  after placing the player. Collects empty cells, samples `enemy_count` distinct
  cells at least `enemy_spawn_min_dist` (toroidal) from `player_pos`, instantiates a
  random type from the registry at each cell.
- Enemies added to the `enemies` group (bullets hit this group).

### Jump_Bird state machine (`enemy_jump_bird.gd`)

All distances are toroidal distance to the player.

```
SLEEP ──enter wake_radius──▶ WAKE ──anim done──▶ CHASE
  ▲                                               │
  │ player > give_up_radius                     │ player ≤ lunge_range
  └──────────────◀ landing / cooldown ◀ BACK_HOP ◀ LUNGE_DASH ◀ LUNGE_WINDUP
```

| State | Behavior | Animation |
|-------|----------|-----------|
| `SLEEP` | gravity, stand still, no horizontal | sleep loop |
| `WAKE` | stand still, play once | `b1 b2 b3 t0` |
| `CHASE` | gravity; every `hop_interval` jump toward player (toroidal dir) | `t0↔t1` |
| `LUNGE_WINDUP` | stand still ~`lunge_windup`, lock player direction | `t1 t2 t3` |
| `LUNGE_DASH` | straight dash at `lunge_speed`, no gravity, cap at `lunge_max_dist` or wall | `t3` |
| `BACK_HOP` | jump up + away from player, brief cooldown on landing, re-evaluate | reuse `t2` |

Transitions:
- `SLEEP → WAKE`: `toroidal_dist ≤ wake_radius`.
- `WAKE → CHASE`: wake animation finished.
- `CHASE → LUNGE_WINDUP`: `toroidal_dist ≤ lunge_range`.
- `CHASE → SLEEP`: `toroidal_dist > give_up_radius` (give up, return to dormant).
- `LUNGE_WINDUP → LUNGE_DASH`: windup anim finished.
- `LUNGE_DASH → BACK_HOP`: reached `lunge_max_dist`, or collided with a wall.
- `BACK_HOP → CHASE`: landed + `back_hop_cooldown` elapsed (re-evaluate; also
  re-checks wake/give-up and lunge range).

### Combat flow

**Shooting** (`player_gun.gd` on the `Gun` node):
- Convert mouse screen position to world (window and `WorldViewport` share the 4:3
  aspect, so screen-space angle ≈ world-space angle under uniform scaling).
- `pitch = atan2(mouse_world.y - player.y, mouse_world.x - player.x)` relative to
  the horizontal, clamped to **[-45°, +45°]**; horizontal base = `facing_direction`.
- `Gun` node rotates to the aim angle; `Muzzle` (Marker2D) is the bullet spawn.
- Left mouse fires (semi-auto, `fire_cooldown`). Recoil: gun sprite kicks back
  ~4px for 60ms + tiny camera shake ~2px for 100ms. **No movement-speed impact.**

**Bullet** (`bullet.gd`, Area2D):
- Travels straight along aim direction at `bullet_speed`; swept `move_and_collide`
  (no tunneling through 16px tiles).
- On hit: collider in `enemies` group → `enemy.hurt(bullet_damage, bullet_dir)`;
  wall → despawn; past `bullet_range` → despawn.
- Toroidal wrap (consistent with the world).

**Enemy hurt:** `hp -= damage`; knockback impulse away from the bullet; white hit
flash ~`hit_flash_time`; `hp ≤ 0` → `queue_free()`.

**Player hurt** (from enemy contact `Area2D`):
- If not invincible and not downed: `hp -= enemy_contact_damage`; knockback away
  from the enemy; i-frames (`iframes_time`, sprite flashes); update HUD bar.
- `hp ≤ 0` → **downed**.

**Downed:**
- Rotate 90° opposite facing, disable movement/shoot input, post-process `desat`
  → 1 (screen gray), HUD bar stays visible. Press **R** →
  `get_tree().reload_current_scene()`.

**HUD:** health bar in top-left on a `CanvasLayer` (layer 129, above the
post-process layer so barrel/CRT/desaturation never affect it).

## Post-process

`Shaders/post_process.gdshader` gains a `desat` uniform (0 = normal, 1 = fully
gray); `Scenes/post_process.gd` exposes `set_downed(bool)` and drives it with the
existing `time` pattern.

## Parameters (`Globals/gameParameters.gd`)

Initial values; all tunable:

| Group | Parameter | Initial |
|-------|-----------|---------|
| Spawn | `enemy_count` | 12 |
| Spawn | `enemy_spawn_min_dist` | 300 px |
| Jump_Bird | `jb_hp` | 3 |
| Jump_Bird | `jb_knockback` | 150 px/s |
| Jump_Bird | `jb_hit_flash` | 0.1 s |
| Jump_Bird AI | `jb_wake_radius` | 350 px |
| Jump_Bird AI | `jb_give_up_radius` | 600 px |
| Jump_Bird AI | `jb_lunge_range` | 130 px |
| Jump_Bird AI | `jb_lunge_max_dist` | 140 px |
| Jump_Bird AI | `jb_lunge_speed` | 900 px/s |
| Jump_Bird AI | `jb_lunge_windup` | 0.25 s |
| Jump_Bird AI | `jb_hop_interval` | 0.55 s |
| Jump_Bird AI | `jb_hop_horizontal_speed` | 220 px/s |
| Jump_Bird AI | `jb_hop_jump_velocity` | -620 px/s |
| Jump_Bird AI | `jb_back_hop_up` / `jb_back_hop_away` | -520 / 320 px/s |
| Bullet | `bullet_damage` | 1 |
| Bullet | `bullet_speed` | 1000 px/s |
| Bullet | `bullet_range` | 700 px |
| Bullet | `bullet_radius` | 5 px |
| Gun | `fire_cooldown` | 0.15 s |
| Gun | `aim_pitch_deg` | 45 (clamp ±) |
| Gun | `recoil_kick` / `recoil_time` | 4 px / 60 ms |
| Gun | `cam_shake` / `cam_shake_time` | 2 px / 100 ms |
| Player | `player_max_hp` | 5 |
| Player | `iframes_time` | 1.0 s |
| Player | `player_hit_knockback` / up | 380 / 200 px/s |
| Contact | `enemy_contact_damage` | 1 |

## Verification

1. Headless Godot run (`--headless --path . --quit-after 30`) — no script errors.
2. Screenshot sanity via the existing headless `Tests/shot` + PIL preview pattern.
3. Manual playtest checklist:
   - Spawn count and min-distance from player hold.
   - Sleep → wake animation → flashing idle → jump chase → lunge (capped) →
     back-hop → re-evaluate; give-up returns to sleep.
   - Shoot: bullet spawns from muzzle at aim angle, hits enemies (flash/knockback/
     death), hits walls, despawns at range.
   - Contact damage: i-frames + knockback + HUD updates.
   - Downed: 90° rotation, gray screen, controls off, R restarts.
   - Toroidal wrap for enemies and bullets across the seam.
   - HUD health bar visible and unaffected by post-process.
4. All numbers live in `gameParameters.gd` for quick tuning.
