# Post-Process Effects: Barrel Distortion + CRT Terminal

**Date:** 2026-06-23
**Status:** approved

## Summary

Two independently toggleable screen-space post-processing effects applied via a single shader on a full-screen `ColorRect`:

| Effect | Toggle | Behavior |
|--------|--------|----------|
| Barrel distortion | F1 | Mild barrel warp near screen edges, revealing adjacent torus copies |
| CRT terminal | F2 | Fine scanlines + amber monochrome tint + vignette corners |

No scene flicker/brightness fluctuation.

## Architecture

```
Level0 (Node2D) — unchanged
└── PostProcessLayer (CanvasLayer, layer=128)
	├── BackBufferCopy (copy_mode=1, copies entire screen rect)
	└── ColorRect (fullscreen, ShaderMaterial → post_process.gdshader)
```

A single `.gdshader` handles both effects. Two `uniform bool` flags gate each channel. The accompanying GDScript reads keyboard input and pushes uniform values.

## Files

| File | Purpose |
|------|---------|
| `Shaders/post_process.gdshader` | Combined barrel + CRT screen shader |
| `Scenes/post_process.gd` | Toggle logic, uniform binding, input handling |
| `Scenes/Level0.tscn` | Append CanvasLayer sub-tree |

## Shader Details

**Barrel distortion:**
- UV remap: `r_new = r * (1 + k * r²)` with small `k ≈ 0.08`
- Center pixels untouched; edge pixels pull outward ~3-5%
- Sampling uses filtered screen texture for smooth result

**CRT terminal:**
- Scanlines: `1.0 - scanline_strength * sin(uv.y * screen_height * PI)` — thin, tight lines
- Amber tint: desaturate RGB → map to warm monochrome `vec3(0.9, 0.7, 0.3)` tones
- Vignette: `1.0 - vignette_strength * dist_from_center⁴`

**Uniforms:**

| Name | Type | Default |
|------|------|---------|
| `barrel_enabled` | bool | false |
| `crt_enabled` | bool | false |
| `barrel_strength` | float (hint_range 0–0.2) | 0.08 |
| `scanline_opacity` | float (hint_range 0–1) | 0.15 |
| `vignette_opacity` | float (hint_range 0–1) | 0.4 |
| `time` | float | driven by script |

## Input

- **F1** → toggle `barrel_enabled`
- **F2** → toggle `crt_enabled`

Processed in `_unhandled_input` so UI/console inputs are not consumed.

## What Does NOT Change

- Player physics, maze generation, toroidal wrapping, camera follow — all untouched
- Existing node hierarchy in Level0 remains as-is; only a new CanvasLayer is appended
