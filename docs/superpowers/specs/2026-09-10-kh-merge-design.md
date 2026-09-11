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
- `scenes/player/player.gd`：站立 R=换弹（仅单机 + `Settings.reload_enabled`）+ 滚轮切枪；**倒地 R 保持 main 的 `reload_current_scene()` 不动**——`restart_single()` 是 L4 的产物，L3 引用即**编译错误**；「倒地 R = `restart_single()`」整体并入 L4（见下）
- `scenes/level_0.gd`（**+1 行**）：建好玩家后应用禁用武器闸门 —— `$WorldViewport/Player.weapons.set_enabled_slots(RunOptions.disabled_weapons)`。**不加这一行，本层做出的闸门就是没有调用方的死代码**（侦察发现：规格原先在 L3/L4/L5 里都没写这个调用点）
- `ui/hud.gd` 换成 KH 版（`scenes/hud.gd` 移植过来，落 `ui/`）
- ⚠️ **保留** `weapon_base.tick(delta)` 的物理 tick 驱动（C2 确定性）

### L4 场景生命周期与 UI

- `scenes/level_0.gd`：加静态 `safe_change_scene(tree, path)`（旧世界摘树挂起、稳态最多一具 `_retired`）与 `restart_single()`（砖/碰撞回基线、清子弹与敌人并无难度重刷、玩家满血满氧回出生点）；**不加** menu_demo / revive_demo / build_permanent_region / _apply_difficulty
- 新增 `ui/pause_menu.gd`（KH `pause_menu` 移植，落 `ui/`）；退役 `ui/esc_menu.*`
- `scenes/main_menu.gd` 换 KH 版，但：删演示世界加载与 `_leave_menu` 保活；删 `_build_old_ui`；删难度行；单人进图改回普通 `change_scene_to_file`（菜单已是纯 UI）
- 新增 `scenes/settings_menu.tscn/gd`（键位重映射 / 音量 / 滚轮切枪 / 换弹开关；**删 old_ui 与难度**）
- `scenes/matchmaking.tscn/gd` 换 KH 版（含大乱斗入口、连接健壮性、一键起本服）
- `scenes/player/player.gd`：「倒地 R」由 `reload_current_scene()` 改为 `Level0.restart_single()`（**仅单机**；PvP 倒地仍交给服务器权威复活，沿用 main 的 `not Level0.pvp_mode` 守卫）。**该项原列在 L3，因依赖本层新增的 `restart_single()` 而移到这里**
- ⚠️ **carry-forward（本层新引入的残弹/滚轮交互，做 `restart_single()` / `restart_at()` 与滚轮开关时必须一并处理）**：
  - **(a) `restart_at` / `restart_single` 必须清 `_mag_state`**（或至少不得与 `_restore_mag.call_deferred` 抢 `mag_ammo`）：`weapon_component.gd:174` 的 `_restore_mag.call_deferred` 在**帧末** flush，排在调用方**同帧同步**写的 `w.mag_ammo = w.mag_size` 之后 → 会用复活前的旧残弹把"复活满弹"覆盖掉（复活了仍只有 3 发，且无报错）。清 `weapon_component._mag_state` 是最省事的对齐方式。
  - **(b) ✅ 已修（2026-09-10，提前于本层落地）：`weapon_component.gd:156` 一带残弹记账处的 `is_inside_tree()` 守卫已就位**——`_mag_state[old_slot] = _weapon.mag_ammo` 只在旧枪**已入树**时执行（`if _weapon.reload_active() and _weapon.is_inside_tree()`）。原缺陷：同帧两次 `equip()`（一帧内收到两个滚轮事件即可）会把旧枪"还没 `_ready`（`mag_ammo` 为 0）"的残弹记进 `_mag_state`，再被 `_restore_mag` 覆盖回新枪 → **被略过的那个中间槽残弹被抹成 0**（不是回满；`fire()` 靠 `start_reload()` 自愈 = 交火中白交一次装填）。**回归钉在 `tests/kh_l3_probe.gd::_check_same_frame_cycle()`**（不插 `await`、同帧连调两次 `cycle_slot`，断言被略过槽的残弹未被抹成 0）。**注意：滚轮开关（`Settings.wheel_switch`）本身仍是本层的 UI 产物**（默认 `false`，今天无 UI 可打开）——该守卫修的是同一个开关打开后的可达路径，不必再回来改。

### L5 大乱斗

- 新文件照搬：`scenes/royale_lobby.tscn/gd`、`scenes/royale_game.tscn/gd`、`scenes/royale_hud.gd`、`server/royale_host.gd`
- **手工合并**：
  - `server/room_manager.gd` = main 的健壮性（端口 30s 延迟归还、僵尸房清理、`started` 标志、杀端口修正）+ KH 的 `RoyaleRoom` 注册表、`ai_duel`/`royale_start_ai`、1v1 与大乱斗互斥
  - `server/server_main.gd` = main 的 `_kill_port_holder` 修正 + KH 的 `--royale --players N [--ai-roles]` 分支与大乱斗报到超时
  - `server/match_host.gd` = main 的 C2（ack/c2、每 tick 1 包、快照在消费前）+ KH 给 `RoyaleHost` 的扩展点：`_match_round_tick` / `_spawn_cell` / `_attributed_killer` / `_finish_match` / `_match_winner` / `_broadcast_round_state` / `_on_bullet_hit` / `_respawn_player` / `request_suicide_role` / `set_display_names` / `mark_disconnected`，以及 `_init(..., options, ai_roles)` 与 `start_on(...)`
- AI 补位代码就位（`core/ai_input_source.gd`、`server/ai_player.gd`、`--ai-roles`），**不接按钮**
- ⚠️ **AI 补位与换弹闸的交互（L5 必读）**：`weapon_base.reload_active()` 现在的第二条判据是「输入源不是网络驱动」（`player.input_is_network()`），用来挡住权威服务器与远端副本。**L5 的 AI 补位若用非 network-driven 的 `AISource`，服务器侧的 AI 会被判成"本地单机"从而进入换弹** —— 打空弹夹后停火 `reload_time` 秒（霰弹 2.2s / 榴弹 2.8s）。落地时必须让 `AISource.is_network_driven()` 返回 **true**（或给 `reload_active()` 换一个更贴语义的判据），否则 AI 手感会莫名变差、且是静默的。（不会造成客户端分歧——AI 无预测端。）
- 大乱斗客户端走 `server_rendered`；地图沿用 `maps/factory1v1.cyrm`（KH `room_manager.PVP_MAP` 即此图，与 main 同字节；落地时确认 `royale_start` 传的也是它，若 8 人散点不够再议）

### L6 PvP 客户端合流（最高风险）

- `scenes/pvp_client.gd`：以 main 的 C2 版本为基底，**只做加法**接入 KH 的反馈/选项/血条/小地图/拖尾/暂停菜单/`safe_change_scene`；`hit_confirm` / `match_options` / `peer_hues` 经 `NetBusExt` 消费；**`beam_fired` 不在此列**——main 现役激光链路走 `NetBus`（发送端 `server/match_host.gd:391` 的 `NetBus.rpc_id(..., "beam_fired", ...)`，接收端 `scenes/pvp_client.gd:79` 的 `NetBus.local_beam_fired`），`core/net_bus_ext.gd` 里的同名 RPC 是 KH 遗留重复。**L6 必须沿用 main 现役 `NetBus`，不得启用 `NetBusExt.beam_fired`**；若确要启用，必须同步把 `match_host` 的发送端一起迁过去，否则收发落在不同节点 = 对手端激光视觉静默 no-op
- 服务器渲染保底路径（`server_rendered`）保持可用
- **禁用武器闸门在 PvP 侧必须两端都接（不是「唯一调用点」）**：`server/match_host.gd`（按 role）与 `scenes/pvp_client.gd` **两处**各调一次 `weapons.set_enabled_slots(PvpSession.disabled_weapons)`，且**必须是同一份** `match_options`（L3 只接了单机侧 `level_0`，不做这一步则 PvP 的禁用武器不生效）
  - **只接客户端 = C2 永久分歧（必须按上面两端接）**：`pvp_client.gd:153` 把 `src.get_weapon_slot_pressed()` **无条件**打进输入包（不管本地闸门是否拒绝）；客户端 `weapon_component.gd:140-142` 对禁用槽 `Sfx.play("deny"); return`（本地留在旧槽）；服务器若没同步禁用表（`set_enabled_slots` 在 `server/` 侧无调用方），`equip("1")` 会**成功** → 服务器在槽 1、客户端在槽 3；随后每帧 `restore_state`（`player.gd:508`）又去 `equip("1")` → 再次被拒 → **每帧重试、永久错位**（冷却/散布/伤害全不对，且看不到任何报错）。
  - **不要**改 `core/net_bus_ext.gd` 或任何逐字节照搬的文件来「顺手」接这个闸门。
- **★ 换场机制收口（L4 终审登记，必须做）**：`scenes/pvp_client.gd` 有**三条离开对局世界的路径，只有一条受保护**——
  - `:97-101`（ESC → 回到主菜单）经 `PauseMenu.go_menu` → `ui/pause_menu.gd` 的 `Level0.safe_change_scene` ✓ **已保护**
  - **`:311`（MATCH_OVER 的 5s 定时器）与 `:328`（`_on_opponent_left` 的 2.5s 定时器）仍是裸 `get_tree().change_scene_to_file("res://scenes/main_menu.tscn")`** ← 正是 KH 实测会同步 `memdelete` 数万碰撞体、`safe_change_scene` 被造出来规避的那条路径。
  **两处都要改成 `Level0.safe_change_scene(get_tree(), "res://scenes/main_menu.tscn")`。**
  次生风险：两条机制**无互斥**——`safe_change_scene` 首行 `await tree.process_frame`，若"点「回到主菜单」"与"对手离开定时器"在**同一帧**触发，后者先销毁当前场景，前者恢复时 `old = tree.current_scene` 会拿到**刚建出来的 main_menu**，于是再实例化第二份菜单、把旧的塞进 `_retired`（不崩，但建出两份菜单且污染 `_retired` 语义）。收成同一机制后该竞态自然消失。
- **★ `player_options` 与 `claim_role` 的乱序竞态（L5 T5 评审登记，用户裁定「记为 L6 待办」——必须做）**：`scenes/matchmaking.gd` 先发 `claim_role` 再发 `player_options`（**同一 reliable 通道 → 每个 peer 内部 claim 先到**）；而 `server/server_main.gd` 的 `_on_role_claimed` 在**收齐法定人数的那一包上同步调 `_begin_match()`**，后者立刻读 `_claim_opts.get(1, {})` / `_claim_hues()` —— **此时 role 1 的 `player_options` 包还没被派发**。
  → **每当 role 1 的 claim 最后到达**（连接顺序决定，约五成概率），**房主的规则选项被静默丢弃**：`round_full_heal` / `disabled_weapons` 不生效，且 `NetBusExt.rpc_id(..., "peer_hues", {})` 把**空色表**发给两端。`_on_player_options` 随后把迟到的包归档进 `_claim_opts`，但已无人读取。
  **为什么必须在 L6 收口**：本层（L5）的 `_begin_match` 同时服务 1v1（`else` 分支走 `RoomManager.start_match_on`），而 L6 的「禁用武器闸门」正依赖这份 `match_options`（规格 §3 L6 上一段要求两端各调一次 `set_enabled_slots` 且**必须是同一份** options）→ **不修则 L6 的禁用武器本身就不生效**，且是静默的。L6 落消费端时一并收口，才能端到端验证。
  **修法二选一（L6 定）**：① 把 `_begin_match` 延后到各 human claim 的 options 都到齐（带宽限超时兜底）；② 在 `_on_player_options` 里**按 caller 缓冲**先到的 opts，并把 claim→caller 的映射留在开局前可查。
  **另注**：`_on_player_options` 目前**会丢弃先于 claim 到达的 opts**，与它自己 docstring 写的「可能先于/晚于 claim 到达，按 caller 归档」**自相矛盾**——修法 ② 正是把它兑现。
- **`royale_rooms` 纳入超龄清扫（L5 T4 评审登记，用户裁定「现在补」）**：见 `server/room_manager.gd` 的 `_sweep_stale_rooms`。原 sweep 只遍历 `rooms`；大乱斗房若开局后客户端保持大厅连接却既不发言也不断开（ENet 不超时静默 peer），`worker_port` **永久不归还**（未开局的等待房不占端口，`worker_port` 只在开局时分配）。**阈值安全性**：单局上限 `RoyaleHost.MATCH_TIME`=300s ≪ `MAX_ROOM_AGE`=7200s → 创建满 2h 仍在 `in_match` 的房绝不可能是进行中的对局，故**全部 `royale_rooms` 同一阈值扫**，不为 in_match 单设例外。

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
