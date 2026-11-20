# 渲染 / 武器 / 视口 / 物理迁移分析

> 日期: 2026-11-20 · 状态: 进行中
> 基座：siri `9bdb8303`；对照：main `668d5f6a`（worktree `the-cyancular-ruins-main`）。
> **已确认**：2.1 采用方案 A；2.3、2.4 的方案通过。**录像、回溯回放（recorder / rewind_tape）、编辑器不在本迁移范围**，另行 plan。
> 结论先行：**视口与后处理是最大缺口，必须专门设计；武器是“数据 + 规则”迁移，不能搬节点；物理不能搬，只能把规则重写进 siri 的 ActorStep/Terrain。**

## 1. 现状对照

### 1.1 着色器（全部文件与行数）

| 文件 | main | siri | 处置 |
|---|---|---|---|
| `post_process.gdshader` | 393 | 70 | **移植 main 版**（差异最大） |
| `form_light.gdshader` | 130 | — | 移植（依赖地形掩码） |
| `water_surface_batch.gdshader` | 30 | — | 移植或合并进 siri `WaterSurfaceBatch` |
| `black_bird_silhouette.gdshader` | 7 | — | 移植（小） |
| `rewind_tape.gdshader` | 97 | — | **不迁移**（录像不在范围） |
| `time_film.gdshader` | 12 | 9 | 按 main 对齐 |
| `player_p2_hue.gdshader` | 24 | 29 | 对齐 |
| `minimap_circle.gdshader` | 24 | 27 | 对齐 |
| `menu_fisheye.gdshader` | — | 86 | 保留 siri |
| `white_mask.gdshader` | — | 5 | 保留 siri |

main 后处理包含：天空/三套光照（斜投影影 + 压暗 + 迎光边）、发光通道、地形掩码/剪影、低血心跳、时间滤镜、桶形畸变、受击红闪、色差。
siri 后处理只有：桶形畸变、受击红闪、低血暗角、时间滤镜、色差。**不是同一套画面。**

### 1.2 视口

| | main | siri |
|---|---|---|
| 世界 | `WorldViewport` 1920×1440 | `WorldViewport` 1920×1440 |
| 发光 | `GlowViewport` 半分辨率 + `GlowCamera` | **无** |
| 地形剪影 | `TerrainViewport` 半分辨率 + `TerrainCamera` | **无** |
| UI 通道 | `UiViewport` + `UiCamera` | **无**（HUD/Feedback/Pause 是 CanvasLayer） |
| 背景 | 运行时创建的 `BgViewport`（四层视差） | **无** |

main 的 `PostProcess`（538 行）每帧同步各相机、烘地形掩码、把 glow/terrain/ui 三张纹理送进 shader；siri 的 `PostProcess`（93 行）只采样世界纹理。**没有这三个视口，main 的后处理无法直接工作。**

### 1.3 武器

| | main | siri |
|---|---|---|
| 定义 | `data/weapons.json` 只有 `{id,name,scene,tier}`；数值在各 `.tscn` 的导出属性 | `core/sim/weapon_registry.gd`：**8 种武器 + 全部数值在代码里** |
| 单武器逻辑 | `weapon_base.gd` 595 + `weapon_aim_fx.gd` 205 + `laser_weapon_base.gd` 175 | `gun_body.gd` 176 + `combat_simulator.gd` 361 |
| 子弹 | `bullet_base.gd` 493（节点、轨迹、命中、砖块） | `bullet_body.gd` 137（数据对象，模拟推进） |
| 弹药/背包 | `weapon_pickup.gd` 162 + `WeaponInventory`（main 也有） | `weapon_inventory.gd` 161 + `weapon_pickup.gd` 68 + `ground_weapon_field.gd` 81 |
| 触发 | `trigger_delay` / charge / beam / spread / recoil / mag / reload | 枚举 `Trigger{PRESS,AUTO,RELEASE,CHARGE_RELEASE}`、`Penalty`、`Attack{PROJECTILE,BEAM,MELEE}` |

初步对照：8 种武器两边都有（手枪/步枪/M82/S686/榴弹/激光/复合弓/M249），但 **main 的数值在场景覆盖里，siri 在代码表里**；两边都有蓄力弓、激光束、榴弹、弹夹/换弹。差异主要在：单发/连发细节、后坐与镜头抖动、子弹特殊行为、拾取/丢弃、网络权威下的射击结算。

### 1.4 物理

| | main | siri |
|---|---|---|
| 玩家/敌人 | `CharacterBody2D` + `move_and_slide` | `ServerBody`（`RefCounted` + `PhysicsServer2D` RID） |
| 地形碰撞 | `TileMapLayer` + `CollisionBuilder` 贪心合并静态体 + 可破坏砖分块重建 | `Terrain` 自建 `CollisionWorld` 空间、`_rebuild_walls/_rebuild_ledges/flush_collisions` |
| 移动 | 节点 `_physics_process` → `PlayerMotor.tick` | `CombatSimulator.step` → `ActorStep.step` → `Player.step_actor` |
| 命中 | `HitShape` 受击矩形 + Area2D/查询 | 受击矩形 + `CollisionWorld.ray/circle/shape/corridor` 查询 |
| 水体 | `Water` 采样 | `Terrain.water/depth/multiplier` |
| 攀爬/单向台 | `CollisionBuilder.build_climb_ledges` | `Terrain._rebuild_ledges`（已有同名概念） |

两边**都已经有“可破坏地形分块 + 攀爬边沿”**，但实现底座不同：main 用节点+TileMap，siri 用物理服务器 RID+自定义地形。

## 2. 迁移方案

### 2.1 视口与后处理（前置，决定着色器怎么搬）

**推荐方案 A：给 siri 补三个视口，再搬 main 的 PostProcess。**

- `scenes/match_view.tscn` 增加 `GlowViewport`（0.5×）、`TerrainViewport`（0.5×）、`UiViewport`（可选；若 HUD 仍用 CanvasLayer 可先不做）；
- `MatchView` 每帧同步 World/Glow/Terrain 相机（照 main `PostProcess` 的 `_sync` 逻辑）；
- `TerrainView` 负责把地形剪影画进 TerrainViewport（siri 已有 `TerrainView`，可扩）；
- 移植 main `core/present/post_process.gd`（538 行）到 siri `MatchView` 的节点结构；shader 用 main 的 393 行版本；
- 背景视口：若保留 main 的四层视差，再加 `BgViewport`；否则 siri 现有背景先不动。

**方案 B（备选）：不补视口，把 glow/地形受光改写成 `WorldCanvas` 内的多 pass。**
- 省节点与显存，但 main 的掩码/天空/三套光照要重写着色器；**不推荐**，除非移动端性能顶不住。

**决策点**：是否保留 main 的“天空 + 三套光照”视觉。保留 → 方案 A；只要 siri 现有观感 → 只搬时间滤镜/受击/低血，跳过 393 行 shader。

### 2.2 着色器迁移顺序

1. `time_film` / `player_p2_hue` / `minimap_circle`：按 main 对齐（差异小，先做）；
2. `post_process`：随视口方案 A 一起搬；
3. `form_light`：依赖地形掩码，放在 TerrainViewport 之后；
4. `water_surface_batch`：与 siri `WaterSurfaceBatch` 合并（siri 现在是绘制实现，无 shader）；
5. `black_bird_silhouette`：独立小项；
6. `rewind_tape`：**仅当保留录像**再做。

### 2.3 武器机制

**武器数值存哪：官方建议**

Godot 官方把 `Resource` 定义为 **data containers**，并明确自定义 Resource 相对 JSON/CSV/TXT 的优势：可定义常量/方法/信号、有确定的属性、内建序列化、可递归嵌套子资源、`.tres` 是**版本控制友好的文本**、Inspector 可直接编辑（[Resources](https://docs.godotengine.org/en/stable/tutorials/scripting/resources.html)）。
而 `Saving games` 文档把 **JSON 定位为“简单游戏状态/存档”的可读格式**，并列出 JSON 的类型限制（Vector2/Rect2/Color 等无法直接表达、自定义类要自己编解码）（[Saving games](https://docs.godotengine.org/en/stable/tutorials/io/saving_games.html)）。

武器数值属于**游戏内容/配置**，不是用户存档 ⇒ 按官方建议用**自定义 Resource**，而不是 JSON 或散落在场景里的导出属性：

- `WeaponDef extends Resource`：`@export var weapon_id` + `@export var data: Dictionary`。**没有拆成 40 个 typed 字段**，原因：现有定义里 `charge_time`/`arc_time`/`bounces`/`guide_color`/`speed` 等是**可选键**，拆字段会强行补默认值，改变 `definition().has()` 与 `.get()` 的语义；先保住键的存在性，字段化可后续再做；
- 每个武器一个 `.tres`（8 个），再加一个 `WeaponCatalog.tres`（`Array[WeaponDef]`）作为唯一目录；
- `WeaponRegistry` 退化为**加载器 + 校验器**：启动时校验 8 个 id 齐全、字段范围合法，不再内置数值；
- 导出时引擎会把 `.tres` 序列化成 `.res`（官方行为）；运行时**只读**——Resource 默认共享，若要每实例可变状态必须 `duplicate()`；
- `.tres` 文本可 diff/合并，适合版本控制；JSON 只保留给用户设置/存档（如 `settings.cfg`）。

**迁移原则：不搬 `weapon_base.gd` / 子弹节点；把“数值 + 规则”搬进 siri 的 `WeaponRegistry` / `GunBody` / `CombatSimulator`。**

**siri 的表现状（2026-11-20 盘点）**

- `core/` 里共 **64 个字典/数组常量**；最集中的是 `net_codec.gd` 16 个（协议 schema）、`combat_profiles.gd` 12 个（弹道/爆炸 profile）、`world_view.gd` 7 个（动画/特效表）。
- 武器：`weapon_registry.gd` 里 **1 张 `WEAPONS` 表（8 条）+ 1 张 `DEFAULTS`**；启动时 `merged` 后 `make_read_only()`，`definition(id)` 返回只读 Dictionary。
- 弹道：`combat_profiles.gd` **15 个 profile 常量**（DIRECT/BLAST/ROUND/GRENADE…），被武器表引用。
- 内容数据：`data/tile_defs.json`（15 个 tile）、`data/enemies.json`（3 条，指向 3 个 `EnemyType.tres`）。
- `.tres` 全仓只有 **6 个**：主题、字体、玩家帧图、3 个 `EnemyType`（视觉 + AI 脚本引用）；**没有任何武器/瓦片的 `.tres`**。
- 结论：siri 是**“代码表 + JSON”驱动的表驱动实现**，不是 Resource 驱动；武器迁移只是**换存储介质**，表结构本身不用重做。

**迁移时的兼容点（已落地）**：`WeaponRegistry.definition(id)` 的 Dictionary 契约保留；`_load_definitions()` 从 catalog 读出 `WeaponDef.data`，`duplicate(true)` 后 `make_read_only()`；`DEFAULTS` 只保留为**测试注入自定义武器**的模板（`simulation_case`/`prediction_case` 用），不再参与正式武器定义。

1. **数值单一来源**：从 main 各 `.tscn` 的导出属性提取到 `WeaponDef.tres`（8 个）+ `WeaponCatalog.tres`；删除 main 的 `data/weapons.json` 作为真相源（它现在只有 id/name/scene/tier）。
2. **行为映射**：
   - 触发：`trigger_delay`、PRESS/AUTO/RELEASE/CHARGE_RELEASE → siri `GunBody` 已有枚举，逐项对照；
   - 蓄力弓：`charge_time`、`charge_damage_min`、`charge_speed_min`、`charge_arrow_pull` → siri `charge_ratio()` + `presentation_events`（拉弓视觉由 WorldView 播）；
   - 激光：main `laser_weapon_base` 的 beam 半宽/寿命/反弹/砖块削切 → siri `Terrain.trace_beam` + `CombatProfiles`；
   - 子弹：main `bullet_base` 的轨迹/穿透/寿命/砖块伤害 → siri `BulletBody` 字段，补充缺失行为；
   - 后坐/镜头抖动：siri 现在有 `kick/shake/recoil` 字段，对照 main 数值；
   - 拾取/丢弃：siri `GroundWeaponField`+`WeaponPickup` 已具备，核对容量/自丢冷却/网络权威。
3. **权威**：siri 的射击在服务器 `CombatSimulator` 结算；main 的客户端本地开火/命中需改成“客户端发 `FIRE`，服务器结算 + 客户端预测视觉”。这是**行为差异**，不是代码搬运。
4. **验证**：每种武器一条 `simulation_case`（伤害/弹速/弹夹/蓄力/光束/榴弹），再加一条 `prediction_case`（本地预测与服务器一致）。

### 2.4 物理

**原则：不搬节点物理；把 main 的“手感规则”重写进 siri `ActorStep`/`Terrain`。**

1. **碰撞层/掩码**：main `Player collision_layer=2, mask=1`；siri 用 `CollisionWorld.LAYER_TERRAIN/ENEMY/TEAM_A/TEAM_B`。逐项建表：玩家/敌人/子弹/拾取物/地形各自的层与掩码，禁止沿用 main 的数字。
2. **地形碰撞**：两边都已有分块 + 攀爬边沿；对照 `CollisionBuilder._greedy_region` 与 siri `_rebuild_walls`，确认“贪心合并、单向台、可破坏砖重建”规则一致；不一致以 siri 为准，用行为用例锁住。
3. **移动**：main `move_and_slide` 的常量/姿态箱/squash/冲刺/攀爬/水体，逐条在 `Player.step_actor` 复核；**手感会漂**，必须用 siri `simulation_case` + 回放一致性测试，而不是靠肉眼。
4. **命中**：main 的 `HitShape.hurt_rect_of` 是 AABB；siri 已有受击矩形与 `CollisionWorld` 查询，逐武器核对命中范围（子弹半径/光束宽/爆炸）。
5. **水体**：siri `Terrain.water/depth/multiplier` 已完整；对照 main `Water` 的浮力/阻力/氧气。
6. **可破坏砖**：siri `Terrain.flush_collisions` + chunk 重建；核对 main `CollisionBuilder.rebuild_chunk` 的“只重建脏块”策略是否等价。

## 3. 依赖顺序与里程碑

| 阶段 | 内容 | 依赖 | 验收 |
|---|---|---|---|
| P0 | 数值/规则盘点（8 武器表、碰撞层表、移动常量表） | 无 | 表齐全、能逐项打勾 |
| P1 | 物理规则对齐（移动/碰撞/水体/砖块/命中） | P0 | `simulation_case` 全绿 + 回放一致 |
| P2 | 武器规则对齐（8 种 + 蓄力/光束/榴弹/弹夹/拾取） | P1 | 每武器 1 条 case + `prediction_case` |
| P3 | 视口 + PostProcess（方案 A） | P1 | 主菜单/对局启动无错；三通道出图 |
| P4 | 着色器对齐（form_light / water / blackbird / 小 shader） | P3 | 截图对比可接受 |
| P5 | 视觉验收（昼夜/水体/受击/回溯） | P4 | 人工验收清单 |

P1 与 P2 是玩法底座，P3–P4 可并行；P2 完成前不要删 main 的武器场景（对照用）。

## 4. 验证策略

- **自动**：`simulation_case`（移动/碰撞/伤害/弹道/时间回溯）、`prediction_case`（预测与校正）、`terrain_case`（砖块/水体/射线）；新增每武器 case。
- **确定性**：同一输入两跑，`CombatSnapshot` 逐字段相等；回滚重放逐帧一致。
- **视觉**：main/siri 同场景截图（白天/黄昏/夜、水面、发光、形体光、受击、回溯），人工对照；不做像素级自动断言（按 test-economy 不写）。
- **性能**：加视口后测帧率/显存；Mobile 渲染器下 0.5× 通道是否可接受。

## 5. 风险与已定决策

1. **视觉范围（已定）**：采用方案 A，保留 main 的天空/三套光照；成本 = 393 行 shader + 538 行 PostProcess + 3 个视口，不再讨论“是否值得”。
2. **物理手感**：`move_and_slide` → `test_motion` 的漂移不可避免，P1 必须重新调参并用回放一致性锁住；没有“逐字节一致”的捷径。
3. **武器数值（已定）**：自定义 `Resource`（`WeaponDef.tres` × 8 + `WeaponCatalog.tres`）为唯一来源；JSON 只用于用户设置/存档。
4. **网络权威**：main 本地开火/命中与 siri 服务器结算不同；按 siri 模型重做“客户端预测 + 服务器确认”，不是搬函数。
5. **不在范围**：录像、回溯回放（`recorder` / `rewind_tape`）、编辑器；三者另行 plan，本计划不为其预留实现。
6. **待估**：P0 的数值/规则表完成后，才能把 4–6 周收敛到具体排期。

## 6. 粗略工作量

- 视口 + PostProcess：**1–1.5 周**（含相机同步/掩码/性能）；
- 着色器对齐：**3–5 天**（form_light/water/blackbird/小项）；
- 武器规则：**1–1.5 周**（8 种 + 蓄力/光束/子弹/拾取 + 用例）；
- 物理规则：**1–2 周**（移动/碰撞/水体/砖块/命中 + 回放调参）；
- 总计：**4–6 周**（单人，不含编辑器与观战）。

> 注：以上为分析，不含实现；先做 P0 的数值/规则表，才能给更准的估时。
