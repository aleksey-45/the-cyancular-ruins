# P0 数据表：配置 / 武器 / 碰撞 / 移动

> 日期: 2026-11-20 · 状态: 进行中
> 基座：siri `9bdb8303`；对照：main `668d5f6a`。本文只做**数据与规则盘点**，不改玩法代码。
> 结论先行：**main 的配置已经 Resource 化，siri 还是代码常量；武器有 2 把数值不一致、13 个 main 字段在 siri 没有对应；碰撞层不是数字对照，玩家/敌人是否互相阻挡两边行为相反。**

## 1. 配置存储：main 已经是 Resource，siri 不是

| | main | siri |
|---|---|---|
| 玩家 | `core/config/player_config.tres` + `PlayerConfig`（123 行）；`PlayerParams` 只做转发 | `player_params.gd`：53 个 `const` |
| 敌人 | `enemy_config.tres` + `EnemyConfig`（116 行） | `enemy_params.gd` 常量 + `data/enemies.json` |
| 世界/水 | `world_config.tres` + `WorldConfig`（41 行，水体参数 11 项） | ~~`Terrain` / `Water` 里的常量~~ → 已迁到 `world_config.tres`（`Water` 的入水/出水阈值改为 `water_enter_depth/water_exit_depth`） |
| 时间 | `time_config.tres` + `TimeConfig`（50 行） | `time_params.gd` / `time_rules.gd` |
| 武器 | 场景导出属性（本次已迁到 siri 的 `data/weapons/*.tres`） | `data/weapons/*.tres`（本轮新建） |

main 的 `PlayerParams` 是一个值得照搬的适配层：

```gdscript
const _CFG: PlayerConfig = preload("res://core/config/player_config.tres")
static var move_speed: float = _CFG.move_speed
```

- 调用点写法完全不变；
- `.tres` 缺失/损坏是**加载期硬失败**，不会退化成 0；
- 代价：改 `.tres` 需重启进程（与 `world_config`/`enemy_config` 同口径）。

**建议**：P1 把 `PlayerConfig` / `WorldConfig` 的 `.tres` 与转发层搬进 siri；`EnemyConfig` / `TimeConfig` 随对应系统再搬。**不要**把 siri 的 53 个常量再复制一份到 `.tres`——那会变成双真相源。

## 2. 玩家/相机/攀爬差异

main 63 个键 vs siri 53 个键；大部分同名键数值相同，差异如下。

**同名但语义/数值不同**

| 键 | main | siri | 说明 |
|---|---|---|---|
| `cam_deadzone` | `Vector2(576, 432)` | `8.0` | main 是双轴死区矩形；siri 是单值阈值 |
| `cam_zoom` | `1.0` | `0.75` | main 相机缩放 1.0；siri 用 0.75 + 视口缩放，不能直接抄数 |

**main 独有（18 项）**

- 相机：`cam_lookahead_x` / `cam_lookahead_y`（siri 用 `cam_lead_x`）；
- 冲刺：`charge_distance`（siri 用 `charge_duration` 派生，等价需同初速）；
- 攀爬：`climb_ladder_up_speed` / `climb_ladder_down_speed` / `climb_chain_up_speed`（850 / 800 / 800；siri 是 `climb_speed=300` + `climb_vertical_mult=1.2` + `climb_foot_offset`，**两种模型**）；
- 挤压动画：`squash_amount` / `squash_jump` / `squash_land` / `squash_land_min_vy` / `squash_land_ref_vy` / `squash_air` / `squash_air_ref_vy` / `squash_dash` / `squash_hurt` / `squash_recover`（siri 没有节点挤压，表现走 `WorldView` 的 motion pulse）；
- 掉落：`weapon_drop_offset`。

**siri 独有（8 项）**：`cam_lead_x`、`cam_seam_margin`、`charge_duration`（派生）、`climb_foot_offset`、`climb_recoil_mult`、`climb_speed`、`climb_vertical_mult`、`step_max_height`。

**建议**：以 main 数值为准，但**按语义重写**：

- 相机：把 main 的 `cam_lookahead_x/y` + `Vector2` 死区映射到 siri `match_camera`；`cam_zoom` 与 siri 视口缩放一起调，不能只改数；
- 攀爬：main 的“梯子/铁链分速”要在 siri `Terrain.climb_speed`/`Player.step_actor` 里重新表达，不能把 850 直接填进 `climb_speed=300`；
- 挤压：siri 无节点 squash，映射到 `WorldView` 的 motion（起跳/落地/冲刺/受击已有脉冲），不要新增 8 个常量。

## 3. 武器字段映射与数值差异

### 3.1 可映射字段（main 导出 → siri key）

| main | siri | 备注 |
|---|---|---|
| `damage` | `damage` | |
| `bullet_speed` | `speed` | |
| `bullet_range` | `range` | |
| `pellet_count` | `count` | |
| `spread_deg` | `spread` | |
| `fire_cooldown` | `cooldown` | |
| `bullet_gravity` | `gravity` | |
| `max_live_projectiles` | `live_cap` | |
| `recoil_push` | `recoil` | |
| `recoil_kick` | `kick` | |
| `cam_shake` | `shake` | |
| `cam_shake_time` | `shake_time` | |
| `mag_size` | `mag` | |
| `reload_time` | `reload` | |
| `charge_time` | `charge_time` | |
| `charge_damage_min` | `min_damage` | 名字不同 |
| `charge_speed_min` | `min_speed` | 名字不同 |
| `charge_arrow_pull` | **siri 无** | 拉弓视觉 |
| `bullet_size` | `size` | |
| `weapon_name` | `name` | |
| `tier` | `tier` | |

### 3.2 main 独有、siri 没有对应（13 项）

`full_auto`、`heavy_aim`、`penalty_mode`、`move_penalty`、`jump_penalty`、`laser_length`、`laser_color`、`bullet_color`、`preview_arc`、`preview_time`、`pitch_clamp_deg`、`show_aim_laser`、`bullet_scene`。

siri 的近似表达：

- `full_auto` / `heavy_aim` / `penalty_mode` → `trigger` / `penalty`（0/1/2 已对得上）；
- `move_penalty` + `jump_penalty` → siri `move: Vector2`（水平/跳跃两个分量）；
- `live_cap` 已映射；
- `pitch_clamp_deg` → **siri 没有“瞄准俯仰夹角”限制**，是功能缺口；
- `laser_length` / `laser_color` / `show_aim_laser` / `bullet_color` / `preview_arc` / `preview_time` → siri 的 `range` / `guide_color` / `arc_time` 只能覆盖一部分；
- `bullet_scene` → siri 用 `projectile` profile，不需要场景。

**需要补到 siri 的字段**（按优先级）：`jump_penalty`（或并入 `move`）、`pitch_clamp_deg`、`laser_color`/`laser_length`、`charge_arrow_pull`、`bullet_color`。其余先走映射/表现层。

### 3.3 数值差异（已实测，按 main 为准）

| 武器 | 字段 | main | siri |
|---|---|---|---|
| 复合弓 (7) | `speed` | 2400 | 1500 |
| 复合弓 (7) | `mag` | 1 | 12 |
| 复合弓 (7) | `charge_time` | 0.75 | 0.8 |
| 复合弓 (7) | `min_speed` | 600 | 500 |
| 复合弓 (7) | `shake` | 1.0 | 1.5 |
| M249 (8) | `kick` | 9.0 | 4.0 |
| M249 (8) | `shake` | 6.0 | 2.5 |
| M249 (8) | `shake_time` | 0.12 | 0.08 |

其余 6 把在可映射字段上一致。**W5 榴弹的 `damage` 两边顶层都是 5**；`.tres` 里 `projectile` 子字典也有 `"damage": 35`，脚本比对时会被误读成顶层差异，迁移脚本必须只读顶层键。

**建议（已落地）**：P2 已把 main 的 8 个场景数值写进 `data/weapons/*.tres`（弓/M249 差异 + 缺失字段），并把 `catalog.tres` 改为**引用外部 `.tres`**（不再内嵌副本）。上面 13 个 main 字段的映射：`full_auto/heavy_aim/penalty_mode` → `trigger/penalty`；`move_penalty+jump_penalty` → `move`；`bullet_size` → `size`；`pitch_clamp_deg` → `pitch`（siri 的 `pitch` 就是仰角钳制）；`laser_color` → `guide_color`；`charge_arrow_pull` 已进数据（视觉 P4 用）；`laser_length/show_aim_laser/preview_arc/preview_time/bullet_color` 暂留 P4 表现层。

## 4. 碰撞层：不是数字对照，是语义对照

| 语义 | main | siri | 迁移 |
|---|---|---|---|
| 地形 | layer 1 | `LAYER_TERRAIN=1` | 同值 |
| 玩家 | layer 2 / mask 1（只撞地形） | `LAYER_TEAM_A=2` 或 `LAYER_TEAM_B=16`；mask = 地形 \| 敌人 \|（可选）对方队伍 | **语义不同**：siri 玩家会撞敌人；main 玩家穿过敌人 |
| 敌人 | layer 4 / mask 5（地形+敌人；不撞玩家） | `LAYER_ENEMY=4`；mask = 地形\|敌人\|A\|B | **语义不同**：siri 敌人会撞玩家；main 靠 contact Area（mask 2）做接触伤害 |
| 玩家子弹 | layer 0 / mask 1 | 无物理 body；命中用 `Terrain.trace/ray` + 受击矩形 | 不需要层；查询 mask 用 `LAYER_TERRAIN` |
| 敌方子弹 | layer 0 / mask 1 | 无物理 body；`BulletBody` 数据推进 | 同上 |
| 地面武器 | layer 8 / mask 9（地形+掉落物） | 无物理 body（`GroundWeaponField` 数据） | 不需要层 |
| 敌人接触 | Area2D layer 0 / mask 2 | `CollisionWorld.circle/rect` 查队伍层 | 用队伍层查询 |

**关键行为差异（已裁决：按 main）**：

1. **玩家是否被敌人挡住**：main 否（layer2/mask1），siri 原来是（mask 含 enemy）——已改为只撞地形；
2. **敌人是否被玩家挡住**：main 否（mask5 不含玩家），siri 原来是（mask 含 A/B）——已改为只撞地形/敌人。

接触伤害仍由 `touches_player()` 的矩形查询结算（已改为查询 A/B 两个队伍层）；「玩家碰撞」选项只影响玩家之间。`simulation_case` / `prediction_case` 的 mask 断言已同步。

## 5. P0 结论与下一步

**已完成**：武器表已 Resource 化（8+1 `.tres`）；本节给出配置/武器/碰撞/移动四张对照表。

**待办（按依赖）**：

1. ~~拍板：玩家/敌人是否互相物理阻挡~~——已按 main 落地（不阻挡，只做接触伤害）；
2. P1：`PlayerConfig.tres` 已落地（无转发层，直接 `const CFG`）；`WorldConfig.tres` 已落地（重力 + 11 项水体参数，`Water` 的入水/出水阈值改用 `water_enter_depth/water_exit_depth`）；相机已按 main 映射；squash 丢弃；攀爬保留 siri 模型、基础速度 375（梯子≈720、铁链≈900）；
3. ~~P2：把 main 的 8 场景数值写入 `data/weapons/*.tres`（弓/M249 差异 + 缺失字段）~~——已落地（弓 speed 2400/mag 1/charge .75/min_speed 600/size 1.3；M249 kick 9/shake 6/shake_time .12；激光 guide_color 蓝）；
4. P2 剩余：~~`laser_length`/`show_aim_laser`/`preview_arc`/`preview_time`/`bullet_color` 的表现层~~——`charge_arrow_pull`、预瞄直线、`bullet_color`、远端蓄力已接入；`preview_arc/preview_time` 作为数据保留（siri 用 `arc_time` 画弧）；FormLight 逐精灵形体光仍是接口桩（需要改 `WorldCanvas` 自绘材质，单列）；
5. P1/P2 各加一条 `simulation_case` 覆盖上述行为差异（弓的伤害/速度断言已按新数值更新）。

> 本文是数据盘点，不是实现；P1/P2 开工前先把“玩家/敌人阻挡”这一条裁决掉。
