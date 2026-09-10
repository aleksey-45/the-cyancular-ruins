# KH_v1_1_3 → main 合并设计

> 日期：2026-09-10 · 状态：待审 · 下一步：writing-plans 出实施计划

## 0. 背景与两版关系（已按 git 级别核实）

- `origin` = `github.com/aleksey-45/the-cyancular-ruins`。KH（KikuchiHeinrich）是**同一仓库上的协作者分支线**，不是独立工程。
- `../the-cyancular-ruins-KH_v1_1_3` 目录 = **`origin/KH_v1_1_3`（`6f83352`）的逐文件快照**（抽查 8 文件 md5 全一致）。
- 分叉点 `014f2ea`（2026-09-04）。此后 **main 独有 38 条提交，KH 独有 65 条**。
- KH 回移 main 更新的方式是**逐条 cherry-pick**（提交信息写「移植上游 `<hash>`」），已移植：`c53da5b` 激光枪、`f19e226`+`7e0b5ee` 冲刺手感、`51cbe3e` 下蹲、`5c1ebc0` 榴弹爆炸修复、`fc914da` 黑鸟调强。
- 两侧**美术资源、地图 `.cyrm`、`tile_defs.json` 逐字节相同**；差异全在代码、场景与文档。

## 1. 目标与范围

### 1.1 搬入（KH → main）

| # | 项目 | 落地方式 |
|---|---|---|
| 1 | 主菜单（**去演示世界**，保留标题/按钮浮现动画）+ 版本信息面板 | 照搬 + 删演示接线 |
| 2 | 单人开局面板（**只留禁用武器**） | 照搬 + 删难度 |
| 3 | 设置菜单 `settings_menu` + `Settings` autoload | 整套照搬 |
| 4 | 多人匹配整版（房主规则 / 视觉选项 / 连接健壮性 / 一键起本服） | 整套照搬 |
| 5 | 暂停菜单（KH `pause_menu`） | 照搬；main `EscMenu` 退役 |
| 6 | HUD（武器剪影 / 名称 / 残弹 / 换弹进度条） | 照搬 |
| 7 | 大乱斗（lobby / game / hud / host） | 新文件照搬；`room_manager` / `server_main` / `match_host` 手工合并 |
| 8 | 反馈层：命中 X / 击杀播报 / 骷髅连杀 / 受击红闪 / 对手血条 / 小地图 / 子弹拖尾 | 照搬 + 接线到 main 的 `pvp_client` |
| 9 | 换弹（弹夹 + 5 把枪数值 + 装填动画 + R 键，仅单机，有开关） | 手工叠加 |
| 10 | `safe_change_scene` + `restart_single` | 照搬 |
| 11 | DevTools 卡编辑器整套 + 卡数据 + 2 张程序化 PNG | 照搬 + 修 3 处路径 |
| 12 | 爆炸内圈免疫掩护（`cover_multiplier`） | 叠加 |
| 13 | 多人边缘态修复（幽灵房 / 陈旧列表 / 配对取消 / 房主掉线） | 随 #4、#7 进来 |
| 14 | 测试探针全部搬 | 照搬 + 路径改写 |
| 15 | 8bit 音效 `Sfx`（`class_name`，**不是** autoload） | 照搬 |
| 16 | AI 补位（`ai_input_source` / `ai_player` / `ai_roles` 链路） | 搬入并整理，**不接界面** |

autoload 由 main 的 2 个增至 4 个（+`NetBusExt`、+`Settings`）。

### 1.2 保持 main（不采用 KH 版本）

- **C2 客户端预测**：1v1 保留；大乱斗**临时**走 `server_rendered`。
- 小写目录命名（`core/ scenes/ ui/ render/ shaders/ data/ maps/ level_editor/ tests/`）。
- 发布工具链：`tools/build_release.py`、`tools/archive_build.py`、`tools/build_cyancular.bat`、`RELEASE.md`。
- `ui/pvp_hud.tscn` 的声明式布局（KH 是 170 行代码建节点）。
- 激光相关测试用 main 的 `laser_weapon_smoke` / `beam_trace_smoke`。
- `bullet_base` 撞砖碎片「无条件播放」语义。
- `weapon_base.tick(delta)` 物理 tick 驱动（C2 确定性）。
- 文档用 main 的 `CLAUDE.md`（把 KH 的段错误排查结论并入，不搬 `AGENTS.md` 本身）。

### 1.3 删除清单（过时 / 废弃）

**main 侧删除**
- `ui/esc_menu.gd`、`ui/esc_menu.tscn`、`tests/esc_menu_smoke.gd`
- `project.godot` 的 `esc` 输入动作
- `scenes/main_menu.gd` 的 `_on_single_pressed` / `_on_multi_pressed` 之外的旧逻辑（整文件被 KH 版替换）

**不搬的 KH 侧**
- `Scenes/menu_demo_ai.gd`（演示 AI）
- `Level0.menu_demo` / `menu_demo_instance` / `revive_demo()` / `_leave_menu()` 保活链路
- `CollisionBuilder.build_permanent_region()`（专为演示世界的小区域碰撞）
- `_apply_difficulty()`、`RunOptions.difficulty`、`Settings.sp_difficulty`
- `Settings.old_ui`、`main_menu._build_old_ui()`、设置页的老版 UI 开关
- `Tests/laser_probe.gd`（被 main 的 `laser_weapon_smoke` 完全覆盖）
- `.tmp_proc_list.ps1`、`.tmp_srv_check.ps1`、`backup/editor.rar`、`map/_preview_compare.png`
- `build_exe.bat`（main 已有发布工具链）

### 1.4 明确不做（YAGNI）

- 不接 AI 补位的界面入口（1v1「与 AI 对战」、大乱斗「AI 补齐」两个按钮）
- 不把 C2 接进大乱斗
- 不带 old_ui、不带难度系统
- 不搬 KH 的 `AGENTS.md` 本身

## 2. 已定决策（含理由）

| # | 决策 | 理由 |
|---|---|---|
| D1 | **逐子系统手工移植**，不做 git merge | main 的 C2 与命名整改恰好压在 KH 特性要动的文件上；手工移植每层可独立验证/回退，且不会误覆盖 |
| D2 | 大乱斗走 `server_rendered`，1v1 保留 C2 | KH 大乱斗客户端是 server_rendered 写法的；已验证 main `MatchHost` 对无 `seq` 输入包容错（`pkt.get("seq", ...)`）。**临时方案**，后续可单独接 C2 |
| D3 | 主菜单只去掉演示世界，保留浮现动画 | 用户明确；连带 `_leave_menu` 保活链路可整个删除 |
| D4 | 站立 R=换弹（单机）、倒地 R=`restart_single()` | `safe_change_scene` 修不了重启崩溃（KH 实测：旧实现走场景重载仍偶发崩溃，表象为重启后蓝屏/地图未加载），故用 `restart_single` 从机制上绕开 |
| D5 | 难度相关代码全部删除 | 用户明确 |
| D6 | 单人开局面板保留，只留禁用武器 | 用户明确 |
| D7 | `matchmaking` 整个用 KH 版 | 含房主规则 / 视觉选项 / 连接健壮性 / 一键起本服；随之引入 `NetBusExt` 与 `LocalServer` |
| D8 | 暂停菜单用 KH `pause_menu` | 功能更全（继续/回主菜单 + 单机真暂停），且「回主菜单」是 `safe_change_scene` 的落地点 |
| D9 | HUD 用 KH 版；`pvp_hud` 保持 main | 残弹/换弹进度是换弹玩法的必要搭配；pvp_hud 的 tscn 分层是 main 的成果 |
| D10 | DevTools 整套搬，修 3 处 | 见 §3 L7；不修则工具会指挥 agent 去改不存在的路径 |
| D11 | 测试探针全搬 | 用户明确，顺带去掉过时废弃 |
| D12 | main 当唯一基线，KH 侧后续对齐命名 | 免除今后双向移植的路径改写成本 |
| D13 | AI 补位代码搬入并整理，不接界面 | 用户明确 |
| D14 | 老版 UI 内容与开关全部删除 | 用户明确 |
| D15 | 全程**本地提交**，每层一个，不 push | 用户事后再组织提交（`git reset --soft <基线>` 可一次压回暂存区） |

**归因口径说明**：main 的计分规则（「对方死亡都算」）不变；KH 的 `last_damager` meta 只服务*反馈层*（击杀播报归因、骷髅连杀），二者不冲突。大乱斗的计分按 KH 规则（`last_damager` 归因），与 1v1 不同属预期。

## 3. 分层落地方案

每层结束时工程都能 headless 启动、单机可跑；**一层一个提交**。

### L0 规格（本文件）

### L1 基础设施（不改变任何现有玩法）

- 新增 autoload：`core/settings.gd`（`Settings`）、`core/net_bus_ext.gd`（`NetBusExt`）→ `project.godot` [autoload] 2→4
- 新增普通脚本：`core/sfx.gd`（`class_name Sfx`，程序合成方波/噪声/滑音）、`core/run_options.gd`（**只保留 `disabled_weapons`**）、`core/local_server.gd`（`LocalServer`，Windows 专属）
- `core/pvp_session.gd` 补 `disabled_weapons: Array[int]`、`royale: bool` 两个字段（`reset()` 一并清）
- `export_presets.cfg` 的 `exclude_filter` 加 `DevTools/*`
- 验证：headless 启动无报错

### L2 反馈层（纯新增 + 小叠加）

- 新增：`scenes/effects/combat_feedback.gd`（`CombatFeedback`，layer 131：命中 X /「击杀 XXX」播报 / 骷髅连杀）、`scenes/effects/bullet_trail.gd`、`scenes/effects/minimap.gd`、`scenes/player/enemy_hp_bar.gd`
- `render/post_process.gd` + `shaders/post_process.gdshader`：加 `flash_hit(strength)` 与 `hit_red` uniform
- `scenes/player/combat_component.gd`：`take_hit` 调 `flash_hit` / 小伤害震屏
- `core/explosion.gd`：加 `cover_multiplier(d, radius, blocked)`（**内圈 ≤40% 半径免疫 LOS 遮挡**）+ `last_damager` 写入
- `scenes/weapons/bullet_base.gd`：`_register_player_hit`（写 `last_damager` meta + 命中反馈）；**保持** main 的无条件撞砖碎片
- `scenes/enemies/enemy_base.gd`：`_begin_death` 调 `CombatFeedback.notify_enemy_killed(self)`

### L3 换弹 / 禁武器 / HUD

- `scenes/weapons/weapon_base.gd`：`mag_size` / `reload_time` / `mag_ammo` / `start_reload()` / `reload_active()` / `reload_progress()` / `_update_reload_pose()` + 开火闸（装填中不开火、空夹自动换弹）
- 5 把枪 `.tscn` 补弹夹数值：手枪 12/1.0s、步枪 30/1.8s、重狙 5/2.6s、霰弹 2/2.2s、榴弹 4/2.8s；榴弹另加 `max_live_projectiles = 3`
- `scenes/player/weapon_component.gd`：`DISPLAY_NAMES`、`silhouette(slot)`、`enabled_slots` 闸门、滚轮切枪、`_mag_state` 残弹记忆
- `scenes/player/player.gd`：站立 R=换弹（仅单机 + `Settings.reload_enabled`）；倒地 R=`restart_single()`（**仅单机**；PvP 倒地仍交给服务器权威复活，沿用 main 的 `not Level0.pvp_mode` 守卫）
- `ui/hud.gd` 换成 KH 版（`scenes/hud.gd` 移植过来，落 `ui/`）
- ⚠️ **保留** `weapon_base.tick(delta)` 的物理 tick 驱动（C2 确定性）

### L4 场景生命周期与 UI

- `scenes/level_0.gd`：加静态 `safe_change_scene(tree, path)`（旧世界摘树挂起、稳态最多一具 `_retired`）与 `restart_single()`（砖/碰撞回基线、清子弹与敌人并无难度重刷、玩家满血满氧回出生点）；**不加** menu_demo / revive_demo / build_permanent_region / _apply_difficulty
- 新增 `ui/pause_menu.gd`（KH `pause_menu` 移植，落 `ui/`）；退役 `ui/esc_menu.*`
- `scenes/main_menu.gd` 换 KH 版，但：删演示世界加载与 `_leave_menu` 保活；删 `_build_old_ui`；删难度行；单人进图改回普通 `change_scene_to_file`（菜单已是纯 UI）
- 新增 `scenes/settings_menu.tscn/gd`（键位重映射 / 音量 / 滚轮切枪 / 换弹开关；**删 old_ui 与难度**）
- `scenes/matchmaking.tscn/gd` 换 KH 版（含大乱斗入口、连接健壮性、一键起本服）

### L5 大乱斗

- 新文件照搬：`scenes/royale_lobby.tscn/gd`、`scenes/royale_game.tscn/gd`、`scenes/royale_hud.gd`、`server/royale_host.gd`
- **手工合并**：
  - `server/room_manager.gd` = main 的健壮性（端口 30s 延迟归还、僵尸房清理、`started` 标志、杀端口修正）+ KH 的 `RoyaleRoom` 注册表、`ai_duel`/`royale_start_ai`、1v1 与大乱斗互斥
  - `server/server_main.gd` = main 的 `_kill_port_holder` 修正 + KH 的 `--royale --players N [--ai-roles]` 分支与大乱斗报到超时
  - `server/match_host.gd` = main 的 C2（ack/c2、每 tick 1 包、快照在消费前）+ KH 给 `RoyaleHost` 的扩展点：`_match_round_tick` / `_spawn_cell` / `_attributed_killer` / `_finish_match` / `_match_winner` / `_broadcast_round_state` / `_on_bullet_hit` / `_respawn_player` / `request_suicide_role` / `set_display_names` / `mark_disconnected`，以及 `_init(..., options, ai_roles)` 与 `start_on(...)`
- AI 补位代码就位（`core/ai_input_source.gd`、`server/ai_player.gd`、`--ai-roles`），**不接按钮**
- 大乱斗客户端走 `server_rendered`；地图沿用 `maps/factory1v1.cyrm`（KH `room_manager.PVP_MAP` 即此图，与 main 同字节；落地时确认 `royale_start` 传的也是它，若 8 人散点不够再议）

### L6 PvP 客户端合流（最高风险）

- `scenes/pvp_client.gd`：以 main 的 C2 版本为基底，**只做加法**接入 KH 的反馈/选项/血条/小地图/拖尾/暂停菜单/`safe_change_scene`；`hit_confirm` / `match_options` / `peer_hues` 经 `NetBusExt` 消费；**`beam_fired` 不在此列**——main 现役激光链路走 `NetBus`（发送端 `server/match_host.gd:391` 的 `NetBus.rpc_id(..., "beam_fired", ...)`，接收端 `scenes/pvp_client.gd:79` 的 `NetBus.local_beam_fired`），`core/net_bus_ext.gd` 里的同名 RPC 是 KH 遗留重复。**L6 必须沿用 main 现役 `NetBus`，不得启用 `NetBusExt.beam_fired`**；若确要启用，必须同步把 `match_host` 的发送端一起迁过去，否则收发落在不同节点 = 对手端激光视觉静默 no-op
- 服务器渲染保底路径（`server_rendered`）保持可用

### L7 工具、探针与收尾

- DevTools 整套搬（`DevTools/*`、`assets/operators/op_vanguard.png`、`assets/weapons/wp_machete.png`、`launch_card_editor.bat`），修三处：
  1. `launch_card_editor.bat` 的 Godot 路径 → 本机 `D:\Program Files\Godot_v4.7.1-stable_win64\...`
  2. `prompt_builder.gd` 内嵌的 Godot 路径同样修正
  3. `prompt_builder.gd` 提示词模板里的目录名 → main 布局（`Tests/`→`tests/`、`Scenes/`→`scenes/`、`Globals/`→`core/`），autoload 数量说明改对
- 测试探针全搬 + 路径改写；执行 §1.3 删除清单
- `CLAUDE.md` 更新：autoload 4 个、大乱斗=临时 `server_rendered`、`restart_single` 语义、`cover_multiplier` 不变量、KH 段错误排查结论并入
- 全库 `res://` 引用扫描 + `.godot` 重建 + `--import` 验证零 hides / 零 case mismatch

## 4. 路径映射表（机械改写用）

| KH | main |
|---|---|
| `Globals/*.gd` | `core/*.gd` |
| `Globals/gameParameters.gd` / `enemyParams.gd` / `playerParams.gd` | `core/game_parameters.gd` / `enemy_params.gd` / `player_params.gd` |
| `Globals/tile_defs.json` | `data/tile_defs.json`（保持 main 同字节副本） |
| `Scenes/Enemies|Player|Weapons|Effects/*` | `scenes/enemies|player|weapons|effects/*` |
| `Scenes/hud.gd`、`Scenes/pvp_hud.gd`、`Scenes/pause_menu.gd` | `ui/hud.gd`、`ui/pvp_hud.gd`、`ui/pause_menu.gd` |
| `Scenes/post_process.gd` | `render/post_process.gd` |
| `Scenes/*`（其余） | `scenes/*` |
| `Shaders/*` | `shaders/*` |
| `Tests/*` | `tests/*` |
| `editor/*` | `level_editor/*`；`editor/enemies.json` → `data/enemies.json` |
| `map/*.cyrm` | `maps/*.cyrm`（保持 main 同字节副本） |
| `DevTools/*` | `DevTools/*`（新增顶层目录） |

## 5. 四个手工合并守卫点

1. `weapon_base` 的 `tick(delta)` + `player.gd` 每物理 tick 驱动 **必须保留**；KH 的 `_process` idle 驱动会让 C2 失去确定性。
2. `bullet_base` 撞可破坏砖的碎片播放保留 main 的「无条件」版；KH 版塞在 `if apply_damage` 内，会让 PvP 客户端视觉副本撞墙无反馈。
3. `match_host` 的快照广播必须留在「消费输入之前」，`ack_seq`/`c2` 与「每 tick 恰好消费 1 包」不能被 KH 的「整队列应用」覆盖。
4. `pvp_client` 全部 KH 接线以 main 的 C2 版为基底做加法，禁止整文件替换。

## 6. 验证策略

**本任务由用户明确授权代理代跑测试**（一次性授权，不改变项目"测试由用户自己跑"的默认约定）。

| 验证 | 执行者 |
|---|---|
| headless 启动 90 帧无脚本错误；`.godot` 重建 + 项目级 `--import`（零 hides / 零 case mismatch / 零解析错误） | 代理 |
| L2 后：`explosion_falloff_probe` + `feedback_probe`<br>L3 后：`enemy_logic_smoke` + `move_feel_smoke`<br>L4 后：`menu_autotest` + `player_contract_smoke`<br>L5/L6 后：`pvp_match_smoke` + `pvp_reconcile_smoke` + `pvp_twin_smoke` + `royale_probe` | **代理**（本任务授权） |
| 真机手感与 GUI 表现（换弹手感、大乱斗联机、菜单进出、段错误复测） | **用户**（代理无法替代） |

## 7. 风险与缓解

| 风险 | 缓解 |
|---|---|
| `pvp_client` / `match_host` 的 C2×KH 合流（最高） | 单独成层（L6）、以 main 为基底只做加法、C2 三个冒烟保持绿 |
| 大乱斗 `server_rendered` 与 1v1 C2 双机制 | 写入 `CLAUDE.md` 标为临时方案，避免日后误判为 bug |
| `restart_single` 复用同一 Level0 实例，少数状态不重置 | 落地后逐项核对 HUD 计数、水面、相机、可破坏表基线，缺的补上 |
| 换弹改动单机手感（R 键 + 弹夹） | `Settings.reload_enabled` 可一键关回无限弹 |
| **去掉演示世界后，「菜单→游戏」改回普通 `change_scene_to_file` 是否真的不再崩** | KH 实测「直接启动 Level0 从不崩，只有经过主菜单→change_scene→游戏才概率崩」，而那批测试是在**演示世界仍存在**时做的；演示世界拿掉后预期风险消失但**未实测**。L4 落地后必须让你实测连续进出主菜单 ≥5 次；若仍有段错误，退路是把 KH 的 `enter_game_staged`（错帧接管 + 稳定数帧）补回来 |
| 路径改写遗漏 | 全库 `res://` 扫描 + `--import` 零 case mismatch 兜底 |
| DevTools 的 `agent_runner` 会起 `claude -p` | 默认 `acceptEdits`，仅手动勾「全自动」才是 `bypassPermissions` |

## 8. 提交与回退

- 整案在 main 工作区推进；**每层一个本地提交，全程不 push**。
- 用户事后 `git reset --soft <基线>` 可把全部提交压回暂存区，自行组织提交。
- 落地：L0 规格一个提交，L1–L7 各一个提交。

## 9. 关于实施计划的粒度

本规格覆盖 7 个层、约 40 个文件，对单一实施计划偏大。实施阶段建议**按层拆成独立计划**（L1–L2 一个、L3 一个、L4 一个、L5–L6 一个、L7 一个），每份计划产出后即可落地并交你实测，不必等全部写完。
