# Natural Movement Feel (Walking + Camera)

**Date:** 2026-08-13
**Status:** implemented (方案 A)

## Summary

Improve overall game feel so walking no longer feels stiff and the camera no longer feels rigid. Three areas: horizontal movement model, camera follow, and light jump quality-of-life. Pure tuning — no animation, maze, or scene-hierarchy changes.

The feel semantic chosen is **exponential easing** (`lerp(current, target, 1 - exp(-rate * delta))`): the `rate` constants below are *easing rates*, not px/s². Higher rate = snappier. Start is quick then eases off; releasing the key coasts a little; reversing direction passes smoothly through zero instead of flipping instantly.

## 1. Horizontal Movement — Exponential Approach (Four States)

Replace the single `acceleration/friction` pair with per-state easing rates in `Scenes/player.gd` (`_approach()`).

| Param | State it drives | Rate |
|-------|-----------------|------|
| `move_speed` | max horizontal speed (px/s) | 300 |
| `accel_ground` | input held, on ground | 20 |
| `accel_air` | input held, airborne | 9 |
| `brake_ground` | no input / squat, on ground | 16 |
| `brake_air` | no input, airborne | 6 |

Behavior:
- Input held → `velocity.x = _approach(velocity.x, dir * move_speed, rate, delta)` (ground `accel_ground`, air `accel_air`).
- Reversing direction → same `_approach`, passes through 0 smoothly (no instant flip).
- No input → `_approach(velocity.x, 0, rate)` toward 0 (ground `brake_ground`, air `brake_air`); on ground, snap to exactly 0 when `|vx| < 1` so the character doesn't crawl forever under an exponential asymptote.
- Squatting → treated as no-input on ground, brakes to 0.

## 2. Camera — Look-Ahead + Dual-Axis Smoothing + Deadzone

`Scenes/camera_2d.gd` rewritten; built-in smoothing disabled, smoothing driven by script.

```
focus = player.position
      + (clamp(vx / move_speed, -1, 1) * cam_lookahead_x,                       # lead in facing direction
         cam_y_bias + clamp(vy / 1200, -1, 1) * cam_lookahead_y)               # base up-bias + air look up/down
```

- Per-axis exponential smoothing: `pos = lerp(pos, focus, 1 - exp(-smooth_axis * delta))` — X snappier (`cam_smooth_x`), Y floatier (`cam_smooth_y`).
- Deadzone: when `distance_to(focus) < cam_deadzone`, the camera does not move at all (no micro-jitter).

| Param | Meaning | Value |
|-------|---------|-------|
| `cam_lookahead_x` | horizontal lead at full speed (px) | 90 |
| `cam_lookahead_y` | vertical lead at full fall/jump (px) | 60 |
| `cam_y_bias` | base up-shift, keeps original -100px | -100 |
| `cam_smooth_x` / `cam_smooth_y` | easing rates per axis | 10 / 8 |
| `cam_deadzone` | px below which camera holds still | 8 |

## 3. Jump QoL (light)

- **Coyote time** `coyote_time` 0.1s: jumping still allowed briefly after leaving a ledge.
- **Jump buffer** `jump_buffer_time` 0.12s: pressing jump just before landing fires on landing.
- **Variable height**: releasing jump while rising multiplies `velocity.y` by `jump_cut_factor` 0.5 (once, on the release frame).

Fixes an existing bug where "up" in mid-air re-applied jump velocity (infinite air jump) — the jump now only fires when `is_on_floor() or coyote_timer > 0`, and is suppressed while squatting.

## 4. Params & Files

All tunables live in `Globals/gameParameters.gd`. Files touched:

| File | Change |
|------|--------|
| `Globals/gameParameters.gd` | add movement/camera/jump constants |
| `Scenes/player.gd` | new horizontal model + jump QoL |
| `Scenes/camera_2d.gd` | look-ahead + dual-axis smoothing + deadzone |

Not touched: animations, maze generator, viewport/fisheye pipeline, scene hierarchy.

## Verification

- Headless run: no script errors.
- Screenshot sanity: scene still renders through fisheye post-process.
- Feel: manual playtest by user (all constants adjustable in `gameParameters.gd`).
