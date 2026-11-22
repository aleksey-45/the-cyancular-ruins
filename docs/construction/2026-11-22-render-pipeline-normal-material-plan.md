# 渲染管线重构计划：Lighting → Normal + Material + Emissive

> 日期: 2026-11-22 · 状态: 计划中 · 基座: `siri` 分支(当前 `9ea28c76`)
> 决策：**移除 FormLight**；改用 **normal map + 材质遮罩 + 自发光**；保留 siri 的批量绘制与多视口后处理；**不采用 Light2D/CanvasTexture 作为主光照**。

## 1. 目标与非目标

### 目标

- 去掉 main 式逐资产 FormLight，减少每精灵材质/节点依赖；
- 用 normal map 提供方向光所需的表面朝向，支持金属/石头/植被/木头/水等不同响应；
- 用独立 emissive 通道做可控发光与 bloom；
- 保持现有像素画风格：最近邻、色阶量化、Bayer 抖动、无子像素闪烁；
- 所有通道继续走 `SubViewport` + 自定义 `PostProcess`，保留确定性与性能控制。

### 非目标

- 不把 `WorldCanvas` 改成每精灵 `Sprite2D`/`AnimatedSprite2D`；
- 不引入 `Light2D`/`PointLight2D`/`DirectionalLight2D` 作为主光照；
- 不做 3D/2.5D sprite stacking；
- 不恢复被明确排除的录像、回溯回放、编辑器。

## 2. 当前状态审计

| 项 | 现状 | 处置 |
|---|---|---|
| `FormLight` | `core/present/form_light.gd` + `form_light.gdshader`，1 个共享材质 pass，alpha 梯度近似 | **删除** |
| `PostProcess` | main 393 行 shader，天空/环境光/斜影/地形受光/glow/UI 通道 | 保留框架，替换光照合成部分 |
| `BgViewport` | 已建节点，但 siri 地图无 `bgs` 数据，`bg_tex` 永远透明 | 暂删或在 M5 补背景数据 |
| 死 uniform | `sun_debug`、`dither_px`（无 setter） | 删除 |
| 常量 uniform | `loan_aberration`、`sun_warm_tint`（无 setter） | 内联为常量 |
| `time_film.gdshader` | 与 `PostProcess.rewind_film` 逻辑重复（一个用于 PvP 地形，一个用于 solo 全屏） | 保留，M0 评估合并 |
| `white_mask` / `player_p2_hue` / `minimap_circle` / `menu_fisheye` / 水体 shader | 均有明确用途 | 保留 |
| 地形材质 | `TileDefs.material_id` 已接入地形 mask G 通道 | 保留并扩展 |

## 3. 目标管线

```
WorldViewport         albedo / 角色 / 武器 / 地形 / 水
NormalViewport        RG = normal.xy，B = height/bump，A = material_id
MaterialViewport      R = roughness，G = specular/metal，B = emissive_mask，A = 预留
EmissiveViewport      RGB = emissive 颜色，A = 强度（也可并入 GlowViewport）
TerrainViewport       墙剪影（已有，遮挡用）
UiViewport            瞄准/装填/伤害文字（已有）
PostProcess           环境光 + 方向光 + 材质响应 + emissive + 量化/抖动
Hud / Feedback / Pause CanvasLayer（现有）
```

### 通道打包约定

| 纹理 | R | G | B | A |
|---|---|---|---|---|
| `normal_tex` | normal.x | normal.y | height/bump | material_id |
| `mat_tex` | roughness | specular/metal | emissive mask | 预留（AO 或第二材质 mask） |
| `emissive_tex` | emissive R | emissive G | emissive B | 强度 |
| `terrain_mask` | 实心 | 材质类 | — | 1 |

- normal 解码：`n = vec3(rg * 2.0 - 1.0, sqrt(1 - dot(rg,rg)))`；
- 法线贴图约定 **X+ / Y+ / Z+**（Godot 约定），flip 时 `n.x *= -1`；
- material_id：0 stone / 1 metal / 2 foliage / 3 wood / 4 water / 5 emissive。

### 材质响应表

| 材质 | 漫反射 | 高光 | 其他 |
|---|---|---|---|
| stone | 高 | 低/无 | 吃 AO/地形阴影 |
| metal | 中 | 高、带颜色 | 低 roughness，武器重点 |
| wood | 高 | 中低 | 暖色 diffuse |
| foliage | 中 | 低 | 边缘 rim/透光，可做风动 |
| water | 低 | 中高 | Fresnel/法线扰动/反射天空色 |
| emissive | 不参与 | — | 直接输出自发光 |

## 4. Shader / 代码改动

### 4.1 删除

- `core/present/form_light.gd`、`core/present/form_light.gdshader`、对应 `.uid`；
- `WorldCanvas` 的 `_normal` pass、`FormLight.attach/detach/push` 调用；
- `PostProcess` 中 `FormLight.set_*`、`FormLight.push`；
- `LightingParams` 的 `form_gain/boost/steps/dither/bulge/edge_lo/edge_hi`（或转为新管线参数）；
- `sun_debug`、`dither_px`、`loan_aberration`、`sun_warm_tint` 等死/常量 uniform；
- `BgViewport` + `bg_tex`（若不做背景数据）。

### 4.2 新增

- `core/present/normal_canvas.gd`：按图集绘制 normal pass；
- `core/present/material_canvas.gd`：绘制材质遮罩（或并入 normal pass 的 B/A 通道）；
- `core/present/emissive_canvas.gd`：绘制自发光（可复用现有 Glow pass）；
- `scenes/match_view.tscn`：`NormalViewport`/`NormalCamera`、`MaterialViewport`/`MaterialCamera`、`EmissiveViewport`/`EmissiveCamera`；
- `MatchView`：安装/同步这些 pass，相机每帧跟随世界相机；
- `PostProcess`：绑定 `normal_tex`/`mat_tex`/`emissive_tex`，新增 `normal_gain`/`mat_gain`/`emissive_gain` 降级开关。

### 4.3 `post_process.gdshader` 结构

```glsl
// 1. 采样 albedo / normal / material
// 2. 环境光 + 太阳方向
// 3. 逐材质：diffuse、specular、rim
// 4. emissive 加法
// 5. 地形受光（现有 terrain_mask 逻辑）
// 6. 时间/受击/低血/桶形等现有后处理
// 7. 色阶量化 + Bayer 抖动
```

参数来源：`DayCycle` 提供太阳/环境光；`LightingParams` 提供观感（新增 normal/material/emissive 参数，删除 form_*）；具体材质数值放 shader 常量或材质 LUT。

## 5. 美术规范

### Normal map

- 与精灵同像素网格（1:1），最近邻采样；
- 每帧/每武器区域留 padding，防止 atlas 串色；
- 不从 albedo 亮度硬生成；优先手绘或高度图生成（Sprite Lamp / Sprite DLight / Materialize / Blender 正交）；
- flip 时 normal.x 取反；
- 不做 mipmap/filter，避免光斑蠕动。

### 材质遮罩

- 每个图集一张 companion（`_mat.png`），与 diffuse/normal 同区域布局；
- 像素级遮罩，允许粗糙度/高光在小范围内变化；
- 地形使用 `TileDefs.material_id` 生成，不额外画。

### Emissive

- `RGB` 自发光颜色，`A` 强度；
- 值可 >1（HDR 2D），交给后处理阈值 bloom；
- 发光区域不参与 ambient/直射光。

## 6. 实施阶段

| 阶段 | 内容 | 验收 |
|---|---|---|
| M0 清理 | 删 FormLight、BgViewport/`bg_tex`、死 uniform；保留现有画面作 baseline | `run_checks` 全绿；场景启动无 shader 错误 |
| M1 Normal 通道 | NormalViewport + 相机同步 + normal atlas 采样；方向光 diffuse 替换 FormLight | 玩家/武器/敌人有稳定方向明暗；无 atlas 串色 |
| M2 材质通道 | 材质遮罩 + 材质响应表 + 高光/rim；战士/武器/鸟先接 | 金属高光、木头暖色、植被 rim 可辨 |
| M3 Emissive/Glow | emissive 通道 + bloom；与现有 GlowViewport 合并或替换 | 发光可控、不过曝、像素色阶保留 |
| M4 地形/水 | 地形 normal/材质扩展；水面 normal 扰动/Fresnel | 水体高光/流动自然；地形侧面受光 |
| M5 调优/验收 | 移动端性能、半分辨率对比、视觉验收、文档 | 60Hz 稳定；main/siri 截图对照 |

建议先 M0→M1 做一个小切片（player 图集），验证 normal 朝向/flip/串色后再推广。

## 7. 风险与缓解

| 风险 | 缓解 |
|---|---|
| atlas normal 串色 | 每帧区域 padding；生成时复制边界 |
| flip 后光反向 | shader 用 `flip` 参数取反 `n.x` |
| 像素画闪烁 | 最近邻；光照按美术像素块量化；避免半像素抖动 |
| 多视口带宽 | Normal/Material 先 0.5×；移动端实测；必要时只对 actor/武器全分辨率 |
| 美术成本 | 先做 player/武器；地形/水用程序生成；特效可继续 flat |
| 观感过暗/过亮 | 保留 `LightingParams` 调参；先在 1× 视野验收 |
| 与现有 Glow/UI/Terrain 冲突 | 每个通道都有 `*_gain` 降级开关，可单独关闭 |

## 8. 回滚策略

- 在独立分支/多个小提交上做；M0 后打 tag；
- 保留旧 `post_process` 版本直至 M1 通过；
- 如需回退，恢复 FormLight 文件与 `WorldCanvas` normal pass 即可；
- 不修改确定性模拟/网络代码，渲染改动不影响 `simulation/prediction`。

## 9. 验证清单

- `python tools/run_checks.py --godot <godot>` 全绿；
- `python tools/check_naming.py` 通过；
- 场景启动无 `SHADER ERROR`；
- 手动截图：白天/黄昏/夜、金属武器、植被、水体、发光、受击、低血；
- 性能：1920×1440 下 60Hz；Normal/Material 半分辨率/全分辨率对比；
- 像素检查：1× 视野下无光斑蠕动、无色带断裂、flip 后光向正确。

## 10. 待确认

1. Normal/Material 通道用全分辨率还是先 0.5×？
2. normal map 由美术手绘/工具生成，还是先从高度图自动生成过渡？
3. emissive 独立视口，还是并入现有 GlowViewport？
4. 是否保留 `WorldEnvironment` 官方 glow 作为 bloom 方案（需 HDR 2D）？
5. BgViewport 是补地图 `bgs` 数据，还是暂时删除？
