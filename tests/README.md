# tests/ — 冒烟 / 探针 / 真链路(无测试框架)

没有单测框架。**判据一律 grep 脚本自己打的 OK 文本**(如 `… ALL-OK` / `… OK(…)`);**退出码从来不是判据**。引擎路径与单支跑法见根 [`CLAUDE.md`](../CLAUDE.md)「常用命令」。

> ## ★★ 2026-10-24 默认批激进削减：20 → 6
>
> **保留 4 支**（承重 + 元闸）：`allscript_probe`（全仓 `.gd` 加载 + 脚本条数闸）· `path_integrity_probe`（`res://` 字面量存在性）·
> `snapshot_size_probe`（线格式体积/最坏包/容量）· `rollback_fidelity_probe`（C2 回放保真）。
> **删 16 支**（11 支冒烟 + 5 支探针）：`mode_context` / `mode_defs` / `mode_options` / `mode_room_rules` / `net_diag` /
> `network_input` / `ops_log` / `room_registry` / `rpc_channel_contract` / `server_input_sanitize` / `server_status` /
> `resync_world` / `tile_collision` / `map_catalog` / `map_format_v4` / `wrap_probe`。
> **重建 2 支编码面守卫**：`net_wire_smoke`（三 kind 头/往返/坏包 + schema 对齐）· `input_queue_smoke`（轴收口/有界/回复力/钳位）。
> ⇒ **默认批 = 6 支**；真链路批**未动**（6 条 entries）。
>
> **2026-10-26 追加 5 支**（水判定 / 命中几何 / 最小破坏单位 / 联机拆砖粒子 / 子弹扫掠）：
> `water_model_smoke`(13) · `hit_shape_smoke`(13) · `tile_break_unit_smoke`(10) · `net_tile_fx_probe`(9) · `bullet_sweep_probe`(4)
> ⇒ **默认批 = 11 支 / 62 条闸断言**（全批判词 `RUN_ALL OK(11 runs / 62 gated-assertions)`）。上面 2026-10-24 的"6 支"保留为历史记录。
>
> **2026-10-27 再追加 1 支**（服务器命中回放历史）：`lag_history_smoke`(8) ⇒ **默认批 = 12 支 / 74 条闸断言**（`RUN_ALL OK(12 runs / 74 gated-assertions)`）；`hit_shape_smoke` 13→14、`bullet_sweep_probe` 4→6。
>
> **2026-10-28 协议压缩两批 + 后续**：`net_wire_smoke` 5→7（增量已放弃，链三态断言随代码移除）、`snapshot_size_probe` 5→9、`tile_break_unit_smoke` 10→11 ⇒ **默认批 = 13 支 / 88 条闸断言**（`RUN_ALL OK(13 runs / 88 gated-assertions)`；新增 `prediction_contact_smoke` 7 条）。
> **2026-10-30 联机 bug 修复批（累计）**：+`net_metrics_smoke`(9) · `mvp_choice_smoke`(6) · `net_argv_port_smoke`(5) · `prediction_rollback_ring_smoke`(3) · `gun_ammo_independence_probe`(8) ⇒ **默认批 = 18 支 / 119 条闸断言**（`RUN_ALL OK(18 runs / 119 gated-assertions)`；`allscript_probe` 的 `EXPECTED_SCRIPTS` 同步 193→**195**）。
> **2026-10-30 B4 协议批（v7）**：删除 DELTA 编解码 ⇒ `net_wire_smoke` 7→**5**、`snapshot_size_probe` 9→**5**（两处差分能力断言随代码退役）；trail 改 2×i16 ⇒ 两支的世界往返对 trail 加 ≤0.25 容差 ⇒ **默认批 = 18 支 / 113 条闸断言**（`RUN_ALL OK(18 runs / 113 gated-assertions)`）。
> **2026-10-30 第五批**：`tile_break_unit_smoke` 口径改 32px（榴弹 `tile_break_unit` 0.25→**0.5** = 2×2 子格，用户裁定「榴弹最多破坏到 32px」）；新增 `resync_substate_smoke`(5，BUG-03 重连补子格）⇒ **默认批 = 19 支 / 118 条闸断言**（`RUN_ALL OK(19 runs / 118 gated-assertions)`；`EXPECTED_SCRIPTS` 197）。
> **2026-10-30 第六批（收尾 6 条）**：新增 `rejoin_mode_smoke`(4，BUG-14 回局凭据模式维度）⇒ **默认批 = 20 支 / 122 条闸断言**（`RUN_ALL OK(20 runs / 122 gated-assertions)`；`EXPECTED_SCRIPTS` 198）。BUG-04/05/09/10/12 为无自动断言项(真链路/人眼),见 `registered-debt.md` §三十三。
> **2026-10-30 结构重构第一刀（S-13①）**:`server_panel.gd` 的日志 tail 抽成纯逻辑 `server/gui/panel_log_tail.gd`(+`panel_log_tail_smoke` 6 条)⇒ **默认批 = 21 支 / 128 条闸断言**（`RUN_ALL OK(21 runs / 128 gated-assertions)`；`EXPECTED_SCRIPTS` 200）。
> **2026-10-30 结构重构第二刀（S-10/S-11/S-12）**:删 `ModeRoomRules` 的 8 个零调用函数与 `Room.options` 死字段;房主/名单收成 `ServerStatus.host_and_roster` 单一来源(+`room_view_smoke` 4 条)⇒ **默认批 = 22 支 / 132 条闸断言**（`RUN_ALL OK(22 runs / 132 gated-assertions)`；`EXPECTED_SCRIPTS` 201）。
> **2026-10-30 结构重构第三刀(S-09 第一片)**：3v3 纯判据(`team_ready`/`team_can_join`/`team_next_role`/`by_team`/`team_room_ready`/`team_counts_of`)从 `LobbyRooms`(Node、引 NetBus、**不可 `-s` 测**)挪进 `RoomTypes.static`;`room_view_smoke` 扩到 **7 条** ⇒ **默认批 = 22 支 / 135 条闸断言**(`RUN_ALL OK(22 runs / 135 gated-assertions)`)。
> **2026-10-30 守卫缺口批（01 审查 §9 G-01/G-02/G-04/G-05）**：新增 `grace_dispatch_smoke`(6，宽限到点三态/边界/排序) · `reclaim_rules_smoke`(5，重连拒绝判据，`_on_reclaim` 改用纯函数 `ReclaimRules`) · `rollback_fidelity_probe` 补条数闸(33，实测值) ⇒ **默认批 = 24 支 / 179 条闸断言**（`RUN_ALL OK(24 runs / 179 gated-assertions)`；`EXPECTED_SCRIPTS` 201→**208**，含并行批 4 支与守卫批 3 支）。G-04 只改真链路客户端 `pvp_match_smoke.gd`（`st` 改真实最近快照 tick；**不在默认批**），G-03（房间/端口回收梯）本轮未做。
> **2026-10-30 输入守卫补口（S-05 变异暴露）**：`net_wire_smoke` 5→**6**（包级 `seq/ct` 必须取高 tick 记录；旧断言只比"自洽" ⇒ `pack_pair` 取错也绿）· `input_queue_smoke` 4→**6**（`apply_packet` 边沿按位累积/winst>0 覆盖、`clear_edges` 连切枪一起清）⇒ **默认批 = 24 支 / 182 条闸断言**（`RUN_ALL OK(24 runs / 182 gated-assertions)`）。
> **2026-10-31 S 批（S-03/S-06/S-07/S-02/S-15）**：新增 `snapshot_rx_smoke`(7，下行接收：同 tick 幂等 / 坏包只警告一次 / reset 后重新接受 / 丢包估计 / 诊断键集) · `lan_ip_smoke`(5，LAN IP 纯解析:默认路由去重+metric 升序 / local_ip.txt 行解析 / 私有优先级 / 转发壳同源) · `down_edge_probe`(3，三模式倒地边沿:1v1 五杀记分条==结算 kills / 大乱斗无归因不计 kills / 3v3 队友误炸只给对方队加分) · `rollback_fidelity_probe` 33→**34**（PREDICTED_FIELDS ↔ 真 `capture_state()` 键集对账）⇒ **默认批 = 27 支 / 198 条闸断言**（`EXPECTED_SCRIPTS` 211→**216**）。S-02 的通道表对账不在默认批（工具 = `tools/gen_rpc_channel_table.py --check`）。
> **2026-10-31 日志分流 + 回滚率治理**：新增 `net_diag_split_smoke`(5，事件/心跳分文件 · 心跳 10s 节流 · `CYR_LOG_DIR` 覆盖) · `rollback_contact_vel_smoke`(5，接触期 vel 容差 400 / 非接触仍 20 / 位置容差解耦)，`prediction_contact_smoke` 7→**9**（锚点速度计入 + 150ms 迟滞）⇒ **默认批 = 29 支 / 210 条闸断言**（`EXPECTED_SCRIPTS` 216→**218**）。3 客户端 soak 实测回滚率 9.7~22.8% → **1.4~3.4%**（极端贴脸 bot 6~9.5%）。
> **2026-11-01 终局回收 + 倒计时**：新增 `match_exit_rules_smoke`(5，终局后全员离开⇒立刻退进程 / 终局有人⇒继续跑 / 未终局⇒宽限，`MatchExitRules` 纯分派) · `countdown_clock_smoke`(9，重复 start 不回拨 / 3→2→1 一个不落 / 换局重置 / 显示单调且不为 0) ⇒ **默认批 = 31 支 / 224 条闸断言**（`RUN_ALL OK(31 runs / 224 gated-assertions)`；`EXPECTED_SCRIPTS` 218→**222**）。同批:回收梯 `MATCH_SWEEP_INTERVAL` 30s→10s→**1s**、大厅列表每 1s 静默重拉、1v1/3v3 倒计时加就绪闸 + 每 0.5s 重播。
> **2026-11-01 联机收尾批（房间秒删 / 捡不动枪 / 出生点按侧地图数据 / 对抗模式）**：新增 `team_rules_smoke`(13，对抗模式目标与三种补贴) · `spawn_chooser_smoke`(**19**，按侧复活点解析/半区桶/随机/排除上一次/间距) · `ground_weapon_field_smoke`(5，落定重锚) · `map_spawn_data_probe`(**18**，真实地图按侧复活点数据) · `water_atlas_probe`(6，水图集) ⇒ **默认批 = 36 支 / 285 条闸断言**（`RUN_ALL OK(36 runs / 285 gated-assertions)`；`EXPECTED_SCRIPTS` 222→**230**）。同批:回收梯 10s→**1s**、拾取落定重锚 + 0.4s 意图重试、出生/复活点改写死在地图 meta 的 `# respawn <1|2>`（按阵营半区、每侧 ≥5 且 3×3 桶覆盖）、3v3 改名「对抗」并支持 2~10 人 + 目标/比分/血量/伤害补贴。
> ★ **删了什么 = 欠了什么**：删除清单、覆盖缺口与翻案条件登记在 [`docs/eng/registered-debt.md`](../docs/eng/registered-debt.md) §九。
> ★ 仓规未变：**一条判定类别 = 一条守卫**、**新守卫必须自带条数闸**、**先答三问再写**（[`docs/eng/test-economy.md`](../docs/eng/test-economy.md)）。

## 文件分层

一个 stem 的 `.gd` / `.tscn` / `.sh` 伴随文件同桶。

- `smoke/` —— `-s` 冒烟：`net_wire`（线格式）/ `input_queue`（输入队列）/ `water_model`（水判定查询）/ `hit_shape`（命中几何）/ `tile_break_unit`（最小破坏单位）/ `lag_history`（服务器命中回放历史）/ `grace_dispatch`（宽限到点分派三态）/ `reclaim_rules`（局内重连拒绝判据）/ `snapshot_rx`（下行接收：解码去重/坏包只警告一次/reset/丢包估计）/ `lan_ip`（局域网 IP 纯解析）/ `net_diag_split`（诊断事件/心跳分文件 + 心跳节流 + `CYR_LOG_DIR`）/ `rollback_contact_vel`（接触期速度容差）/ `match_exit_rules`（终局后 peer 离开该退进程还是继续跑）/ `countdown_clock`（开局倒计时走秒器：重播不回拨、3→2→1）/ `pvp_match_smoke.gd`（**真链路客户端**，只是被 `pvp_match_smoke.sh` 拉起，不走 `-s`）。
- `probe/` —— 单点诊断与真链路探针：
  - **默认批 8 支**：`allscript_probe.tscn` · `path_integrity_probe.gd`（无 `.tscn`，按 `-s` 跑）· `snapshot_size_probe.tscn` · `rollback_fidelity_probe.tscn` · `net_tile_fx_probe.tscn`（联机拆砖粒子表现层）· `bullet_sweep_probe.tscn`（高速弹扫掠命中）· `gun_ammo_independence_probe.tscn`（枪械残弹独立性：拾取替换 / 倒地保留不得串账）· `down_edge_probe.tscn`（三模式倒地边沿记分口径：1v1 五杀 / 大乱斗无归因 / 3v3 队友误炸）；
  - **真链路（默认批排除）**：`rejoin_probe.tscn` / `royale_soak_probe.tscn` / `team_match_probe.tscn` + 对应 `.sh`。
- `harness/` —— 被 spawn 的辅助：`rejoin_watcher` / `soak_bot_input` / `team_match_watcher` / `team_bot_input` / `menu_autotest`。`menu_autotest` 是**唯一被产品代码 `load()`** 的测试文件（产品侧钩子 = [`scenes/main_menu.gd`](../scenes/main_menu.gd) 的 `-- --autotest-*`）。
- `scripts/` —— 独立诊断 / 迁移工具（**不是测试**，各有登记）：`convert_map` / `convert_map_v4` / `seam_analyze` / `seam_screenshot`。它们**不在**任何 glob 直径内（加进去等于让以后任何写盘工具自动进回归批）。
- 顶层只留基础设施：`env.sh`（共享环境 + kill 助手）、`lib/`（`scan_util.gd` / `probe_base.gd`）、`known_red.txt`（已知红基线）、`path_integrity_allow.txt`、`run_all.sh`、`run_real.sh`。

注意：`-s` 阶段 autoload 尚未实例化；测试脚本若静态引用会连带预加载“引用 autoload 的脚本”会在编译期出错。

> ★ **2026-10-30 真链路首跑**:4 支 PASS(pvp_match_smoke / 
oyale_soak / 
oyale_role_cap / 	eam_match),
ejoin_probe 仍为已知红。★ 失败 entry 会残留 7777 大厅、连累后续 entry 假 FAIL(已登记 BUG-25):串行跑前先确认 7777 空闲且无 godot 残留。

## 聚合入口

两个入口，**判据同上（文本，不看退出码）**：

| 入口 | 跑什么 | 逐支判词 | 全批判词（纯 ASCII） | 占 7777? | 拉子进程? |
|---|---|---|---|---|---|
| `bash tests/run_all.sh` | **headless 默认批**：自动枚举 `smoke/*.gd` + `probe/*.tscn` + `probe/*.gd`（无同名 `.tscn` 的） | `OK` / `OK+RC` / `FAIL` / `NO-VERDICT` / `TIMEOUT` / `KNOWN-RED` | `RUN_ALL OK(n runs / m gated-assertions)` / `RUN_ALL OK-WITH-KNOWN-RED(n runs, k registered)` / `RUN_ALL FAIL(r new-red + k registered)` | **不** | **不** |
| `bash tests/run_real.sh` | **真链路批**：5 支多进程 `.sh` | 同上（除 `KNOWN-RED`） | `RUN_REAL OK(n entries)` / `RUN_REAL FAIL(...)` | **是**（池内那几支） | 是 |

### `run_all.sh` —— 默认批

- `--list` 打印“跑哪些 + 排除哪些 + 每条理由 + 已知红基线”；`--only <子串>` 跑便宜的子集；`--classify-check` 跑**分类器自检**。
- **自动枚举，清单不写死**（三个 glob）；落选走 `EXCLUDED` 显式清单 + 每条理由。当前排除 4 支：
  `smoke/pvp_match_smoke.gd` + `probe/{rejoin,royale_soak,team_match}_probe.tscn`（它们仍在枚举集里，清掉规则会让承重安全检查 FATAL 或让它们悄悄占 7777）。**枚举 / 排除的实时数字以 `--list` 为准。**
- **入口自己会红的九种情形**：glob 空转 / 过期排除项 / `probe/*.gd` 既没跑也没排除 / 默认批里出现开端口或拉子进程的支 / 新红 / 基线条目过期 / 基线路径不在候选面 / 基线文件本身写错 / 某支声明了 `EXPECTED_CHECKS` 却没用于比较。
- ★★ **单支 `OK` 只证明“没有失败输出”，不证明“每条断言都跑过”**（权威：[`lib/probe_base.gd`](lib/probe_base.gd) 文件头）。`--list` 的 `GATE` 栏是 `-` 就表示那一支**没有条数闸**；带闸的支与闸值以 `GATE` 栏为准。
  - 现有带 `EXPECTED_CHECKS` 的支：`net_wire_smoke`(6) · `input_queue_smoke`(6) · `snapshot_size_probe`(9) · `water_model_smoke`(13) · `hit_shape_smoke`(14) · `tile_break_unit_smoke`(11) · `net_tile_fx_probe`(9) · `bullet_sweep_probe`(6) · `lag_history_smoke`(8) · `net_metrics_smoke`(9) · `prediction_contact_smoke`(9) · `mvp_choice_smoke`(6) · `net_argv_port_smoke`(5) · `prediction_rollback_ring_smoke`(3) · `gun_ammo_independence_probe`(8) · `resync_substate_smoke`(5) · `rejoin_mode_smoke`(4) · `panel_log_tail_smoke`(6) · `room_view_smoke`(7) · `grace_dispatch_smoke`(6) · `reclaim_rules_smoke`(5) · `snapshot_rx_smoke`(7) · `lan_ip_smoke`(5) · `net_diag_split_smoke`(5) · `rollback_contact_vel_smoke`(5) · `down_edge_probe`(3) · `rollback_fidelity_probe`(34) · `team_rules_smoke`(13) · `spawn_chooser_smoke`(19) · `ground_weapon_field_smoke`(5) · `map_spawn_data_probe`(18) · `water_atlas_probe`(6)。**`gated-assertions` 的实时数以 `--list` 为准。**
  - ★ `allscript_probe` 有自己的条数闸 `EXPECTED_SCRIPTS`（当前 **230**；`res://docs` 已进 `SKIP_DIRS`，文档目录里的临时审计驱动不计入编译面），但 `run_all` 的 `gate_of()` 只认 `EXPECTED_CHECKS` ⇒ 它的 `GATE` 栏是 `-`。**别把 `-` 读成“没有闸”**。
- ★★ **已知红基线 [`known_red.txt`](known_red.txt)**：每行 `路径 类别 理由…`（理由必填；`#` 是注释；空行 / 类别非法 / 路径不存在 / 同一路径两行都**红**）。基线内的红 = `KNOWN-RED`：不进新红计数、但永远印出文件名，全批判词改 `OK-WITH-KNOWN-RED`。**当前基线为空（0 条）**；加行**不是**让检查变绿的手段，修好了要删行。

### `run_real.sh` —— 真链路批

| # | 脚本 | 端口 | 耗时估计 | 判词 | 池内回收 |
|---|---|---|---|---|---|
| 1 | `smoke/pvp_match_smoke.sh` | 7777 + pool | ~20s | `SMOKE PASS` | 扫 `[7800,8300)` |
| 2 | `probe/rejoin_probe.sh` | 29300 / 29350（池外） | 60~110s | `REJOIN PROBE: ALL-OK` | **不扫池** |
| 3 | `probe/royale_soak_probe.sh` | 7777 + pool | ~150~200s | `SOAK: ALL-OK` | 扫 `[7800,8300)` |
| 4 | `probe/royale_role_cap_probe.sh` | 7777 + pool | ~3~5min | `ROLE CAP PROBE: ALL-OK(9/9)` | 扫 `[7800,8300)`（由 soak 自己清） |
| 5 | `probe/team_match_probe.sh` | 29200 / 29250（池外） | 3~10min | `TEAM MATCH PROBE: ALL-OK` | **不扫池** |

- **四道闸**：① `lobby_alive` 为真 ⇒ 拒绝；② 无 `--yes` 且 stdin 非交互 ⇒ 拒绝；③ **R20 锁**（`tests/.run_all.lock`）+ 前后进程检查；④ **清单不许烂**（`tests/{smoke,probe}/*.sh` 每一支必须在 `ENTRIES` 或 `WRAPPERS` 里，两边每条都要匹配到真实文件）。
- `WRAPPERS` 当前为空数组（`WRAPPERS=()`）；**别删这个数组** —— 闸四同时遍历 `ENTRIES` 与 `WRAPPERS`，`set -u` 下数组不存在会炸。
- ★ `team_match_probe.sh` 在 [`docs/eng/registered-debt.md`](../docs/eng/registered-debt.md) 仍登记为**不可信**：它绿了也不构成 3v3 的可信端到端守卫。

### 默认批绿 ≠ 真链路绿

两条链路覆盖**不相交**：前者是纯逻辑 + in-process 场景，后者要真端口、真子进程、真对局协议。改到**联机权威 / 协议 / 回滚 / 输入包**必须**两边都看**。默认批不拉子进程、不开端口，真链路批只有上表 5 支 ⇒ 玩法、手感、数值、AI 行为、视觉**只能靠人眼与试玩**。
