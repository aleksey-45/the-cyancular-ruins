# 上游 siri 分支迁移计划（非渲染部分）

> 日期: 2026-11-22 · 状态: 待执行
> 目标分支：从 `github-ssh/siri`（HEAD `3be5037d`）新建的 `feat/upstream-main-migration`
> 当前版本：本地 `siri`（`9ea28c76`，33 个迁移提交）只归档，不再继续开发。
> **本文不含渲染管线改动**；normal/material/emissive、FormLight 删除、视口重构见 [渲染管线计划](2026-11-22-render-pipeline-normal-material-plan.md)。

## 1. 背景与版本策略

两条线从 `9bdb8303` 分叉：

- **本地 siri**：33 个提交，完成了 main→siri 的配置/渲染/碰撞/键位迁移；
- **远端 siri**：17 个提交，完成了编辑器、昼夜/视差、水纹、输入时钟、武器手感、网络修复等。

决定：**以远端 siri 为新基座**，本计划把本地迁移中的**非渲染部分**重放到新基座上。

版本操作：

1. 本地 `siri` 当前 HEAD 建立归档分支 `archive/siri-migration-2026-11-22` 并推送远端；
2. 从 `github-ssh/siri` 新建 `feat/upstream-main-migration`；
3. 新分支上按 W0–W6 分阶段提交；
4. 归档分支只读，不 merge、不 rebase。

## 2. 要求范围

| 编号 | 要求 | 目标 |
|---|---|---|
| R1 | Player/World/Enemy/Time 四个配置 Resource | 数值从代码常量迁到 `.tres`，保持访问 API 尽量不变 |
| R2 | `WeaponDef.tres` / main 数值 | 8 把武器从代码表迁到 Resource；数值按 main；保留上游新增武器手感 |
| R3 | 玩家/敌人不互挡、自动跳、台沿 nudge | 碰撞按 main 语义；48/64px 自动跳；贴台沿上挤 |
| R4 | 键位迁移 | 输入映射对齐 main；保留上游双击横冲/修饰键绑定修复 |
| R5 | 局域网房间发现 | LAN 广播、房间卡片列表、直连加入、测试 |

明确不做：渲染管线、FormLight、normal/material/emissive、视口重构、录像/回溯回放、编辑器。

## 3. 上游现状与差异

| 系统 | 上游现状 | 迁移动作 |
|---|---|---|
| 玩家配置 | `core/config/player_params.gd` 代码常量 | 新建 `PlayerConfig.tres`，B 方案：删除 `PlayerParams`，消费点改 `const CFG` |
| 世界配置 | `game_parameters.gd` 里的重力/水体 | 新建 `WorldConfig.tres`，`GameParameters` 只留 `TILE_SIZE` 等结构常量 |
| 敌人配置 | `enemy_params.gd` 内层类常量 | 新建 `EnemyConfig.tres`；保留 `EnemyParams` 转发层（内层类命名空间） |
| 时间配置 | `time_params.gd` 代码常量 | 新建 `TimeConfig.tres`；保留 `TimeParams` 转发层与 `rewind_delta` |
| 武器 | `weapon_registry.gd` 的 `DEFAULTS`/`WEAPONS` 代码表 | 新建 `WeaponDef`/`WeaponCatalog` + 8 个 `.tres`；保留上游弓/M82/M249 改动字段 |
| 碰撞 | 玩家 mask 含 `LAYER_ENEMY`，敌人 mask 含队伍 | 按 main 改为不互挡；接触伤害查询 A/B 两队 |
| 跳跃/台阶 | 只支持 16–64px 直接抬升，无自动跳/台沿 nudge | 移植本地的自动跳（≤32 抬升，48/64 按高度跳）与台沿 nudge |
| 键位 | 已有双击横冲、无 `charge` 键、修饰键绑定 | 与 main 输入表逐项核对；补设置/文档/重绑列表 |
| 局域网 | 无 LAN 发现；大厅仍是 `LIST` 单卡 | 移植 LAN discovery/beacon/大厅多卡/直连/测试 |
| 地图 | `CyrmMap`（16px 子格）+ 编辑器 | 新代码用 `CyrmMap`/`Terrain` API，不依赖旧 `MapFormat` |

## 4. 阶段与验收

### W0 基线

- 从 `github-ssh/siri` 建分支；
- 重建 native（上游新增 `CyrmStorage`，旧 DLL 不可用）；
- 跑通上游 7 组测试，记录基线；
- 把本计划文件带入新分支。

验收：`run_checks` 全绿，场景启动无错误。

### W1 配置 Resource（R1）

- 新增 `core/config/player_config.gd` + `.tres`（含相机/攀爬/游泳/血/武器掉落/补间等）；
- 新增 `world_config.gd` + `.tres`（重力 + 水体）；
- 新增 `enemy_config.gd` + `.tres`（扁平 prefix 字段 + 上游 animation 计时扩展）；
- 新增 `time_config.gd` + `.tres`；
- Player/World 用 B 方案直接 `const CFG/WCFG`；Enemy/Time 保留转发层，避免 100+ 嵌套调用点改动；
- 删除对应代码常量，保留派生值（如 `SNAP_INTERVAL`、`charge_duration`）。

验收：全部测试绿；改 `.tres` 重启生效；无重复真相源。

### W2 武器 Resource（R2）

- 新增 `WeaponDef`/`WeaponCatalog`、`data/weapons/*.tres`、`catalog.tres`；
- `WeaponRegistry` 从 catalog 加载只读 Dictionary，保留 `definition()` API；
- 把 main 的 8 武器数值写入 `.tres`（弓 speed 2400/mag 1/charge .75/…；M249 kick 9/shake 6/…）；
- **保留上游已有改动**：M82 瞄准线、M249 开火反馈、复合弓搭箭拉弦所需字段；
- 校验 `catalog.tres` 引用外部 `.tres`，不内嵌副本。

验收：`simulation/prediction` 全绿；8 武器数值逐键核对。

### W3 碰撞与移动手感（R3）

- 玩家 mask 改为只撞地形（可选对方队伍）；敌人 mask 只撞地形/敌人；
- 敌人接触伤害 `touches_player()` 查询 A/B 两队；
- 自动跳：≤32px 抬升；48/64px 按 `sqrt(2g(height+clearance))` 起跳；x 速度保留；
- 台沿 nudge：空中贴台沿 ≤16px 时向上挤出；
- 使用上游 `Terrain.SUB_SIZE`/`CyrmMap` 子格 API，替换旧 `MazeGenerator` 调用；
- 更新 `simulation_case`/`prediction_case` 的 mask、48px 台阶和回放断言。

验收：移动/台阶/回放测试全绿；玩家可穿过敌人但受接触伤害。

### W4 键位迁移（R4）

- 对比 main 与上游 `project.godot` 的 actions/events；
- 保留上游双击横冲（15 帧窗口）、无 `charge` 键、修饰键可单独绑定；
- 核对 `up/down/left/right/attack/R/F/Q/rewind/haste` 是否与 main 一致；
- `Settings.REMAPPABLE_ACTIONS` 去掉 `charge`；
- 更新 `docs/player.md`、设置菜单说明。

验收：键位表无差异；双击横冲/攀爬/下冲可用；重绑不破坏保留键。

### W5 局域网发现（R5）

- 新增 `core/net/lan_discovery.gd` + `core/net/lan_beacon.gd`（UDP 7788，1 Hz，TTL 3s，JSON）；
- `RoomSession` 建房启动 beacon、关房停止，`lan_public` 默认 true；
- `NetBus.connect_remote`、`NetSession.join_room(code, endpoint)` 直连优先、隧道回退；
- 上游大厅从 `LIST` 单卡改为 LAN 多卡片列表（筛选/空态/轮询），保留手动房码和重连；
- 新增 `tests/lan_case.gd` 与 `tests/run.gd` 的 `lan` 组，更新 `tools/run_checks.py`、`docs/netplay.md`、`docs/ui.md`、`docs/tests.md`、`RELEASE.md`。

验收：`lan` 组全绿；局域网双机手动验收清单（广播/直连/私密房/关房消失）。

### W6 集成与验收

- 全量 `run_checks` + `check_naming`；
- 上游编辑器/输入时钟/昼夜等原功能回归；
- 双机 LAN 测试；
- 更新 `docs/construction` 迁移状态；
- 合并到工作分支，归档分支保持只读。

## 5. 依赖与顺序

```
W0 → W1 → W3 → W4
      └→ W2
      └→ W5（只依赖大厅/房间，可与 W3/W4 并行）
```

W1 是 W3 的前置（步高/重力/相机参数）；W2 与 W1/W3 无强依赖，可并行；W5 与 W1–W4 独立，可最后做。

## 6. 关键文件映射

| 目标 | 主要文件 |
|---|---|
| 配置 | `core/config/player_config.gd/.tres`、`world_config.*`、`enemy_config.*`、`time_config.*`、`enemy_params.gd`、`time_params.gd`、`game_parameters.gd` |
| 武器 | `core/config/weapon_def.gd`、`weapon_catalog.gd`、`core/sim/weapon_registry.gd`、`data/weapons/*.tres` |
| 碰撞/移动 | `scenes/player/player.gd`、`scenes/enemies/enemy_base.gd`、`tests/simulation_case.gd`、`tests/prediction_case.gd` |
| 键位 | `project.godot`、`core/net/local_input_source.gd`、`core/config/settings.gd`、`docs/player.md` |
| LAN | `core/net/lan_discovery.gd`、`lan_beacon.gd`、`server/room_session.gd`、`scenes/mp_lobby.gd`、`ui/screens/lobby_view.gd`、`lobby_room_card.gd`、`tests/lan_case.gd` |

上游与本地同名但实现不同的文件（`player.gd`、`match_view.gd`、`world_view.gd`、`weapon_registry.gd`、`mp_lobby.gd`）**以本地迁移逻辑为参考、以上游结构为准**，不要整文件覆盖。

## 7. 风险

| 风险 | 处理 |
|---|---|
| 上游 `CyrmMap`/编辑器重构，旧 `MapFormat` 调用不存在 | 新代码只用 `CyrmMap`/`Terrain` API；逐文件编译验证 |
| 本地与上游同名文件冲突 | 按功能小提交重放，不整文件 cherry-pick |
| 上游已有弓/M82/M249 改动 | W2 先读上游 `weapon_registry`/`gun_body`，把新字段并入 `WeaponDef` |
| 本地迁移测试基于旧断言 | W3 同步更新 mask/48px/回放测试，不放水 |
| native 需重建 | W0 先 `python tools/build_native.py`，CI/本地一致 |
| LAN 与上游大厅改动冲突 | 以本地上游 lobby 结构为准，W5 单独立项 |

## 8. 验收清单

- [ ] 归档分支已推送远端，当前 `siri` 不再提交；
- [ ] 新分支 7 组上游测试全绿；
- [ ] 4 个配置 `.tres` 生效，无代码常量重复源；
- [ ] 8 武器 `.tres` 数值与 main 一致，上游武器改动保留；
- [ ] 玩家/敌人不互挡、48/64 自动跳、台沿 nudge 通过；
- [ ] 键位表与 main 一致，双击横冲可用；
- [ ] LAN 测试组 + 双机手动验收通过；
- [ ] `check_naming` 通过，文档同步。
