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
> ★ **删了什么 = 欠了什么**：删除清单、覆盖缺口与翻案条件登记在 [`docs/eng/registered-debt.md`](../docs/eng/registered-debt.md) §九。
> ★ 仓规未变：**一条判定类别 = 一条守卫**、**新守卫必须自带条数闸**、**先答三问再写**（[`docs/eng/test-economy.md`](../docs/eng/test-economy.md)）。

## 文件分层

一个 stem 的 `.gd` / `.tscn` / `.sh` 伴随文件同桶。

- `smoke/` —— `-s` 冒烟：`net_wire`（线格式）/ `input_queue`（输入队列）/ `pvp_match_smoke.gd`（**真链路客户端**，只是被 `pvp_match_smoke.sh` 拉起，不走 `-s`）。
- `probe/` —— 单点诊断与真链路探针：
  - **默认批 4 支**：`allscript_probe.tscn` · `path_integrity_probe.gd`（无 `.tscn`，按 `-s` 跑）· `snapshot_size_probe.tscn` · `rollback_fidelity_probe.tscn`；
  - **真链路（默认批排除）**：`rejoin_probe.tscn` / `royale_soak_probe.tscn` / `team_match_probe.tscn` + 对应 `.sh`。
- `harness/` —— 被 spawn 的辅助：`pvp_smoke_client` / `rejoin_watcher` / `soak_bot_input` / `team_match_watcher` / `team_bot_input` / `menu_autotest`。`menu_autotest` 是**唯一被产品代码 `load()`** 的测试文件（产品侧钩子 = [`scenes/main_menu.gd`](../scenes/main_menu.gd) 的 `-- --autotest-*`）。
- `scripts/` —— 独立诊断 / 迁移工具（**不是测试**，各有登记）：`convert_map` / `convert_map_v4` / `seam_analyze` / `seam_screenshot`。它们**不在**任何 glob 直径内（加进去等于让以后任何写盘工具自动进回归批）。
- 顶层只留基础设施：`env.sh`（共享环境 + kill 助手）、`lib/`（`scan_util.gd` / `probe_base.gd`）、`known_red.txt`（已知红基线）、`path_integrity_allow.txt`、`run_all.sh`、`run_real.sh`。

注意：`-s` 阶段 autoload 尚未实例化；测试脚本若静态引用会连带预加载“引用 autoload 的脚本”会在编译期出错。

## 聚合入口

两个入口，**判据同上（文本，不看退出码）**：

| 入口 | 跑什么 | 逐支判词 | 全批判词（纯 ASCII） | 占 7777? | 拉子进程? |
|---|---|---|---|---|---|
| `bash tests/run_all.sh` | **headless 默认批**：自动枚举 `smoke/*.gd` + `probe/*.tscn` + `probe/*.gd`（无同名 `.tscn` 的） | `OK` / `OK+RC` / `FAIL` / `NO-VERDICT` / `TIMEOUT` / `KNOWN-RED` | `RUN_ALL OK(n runs / m gated-assertions)` / `RUN_ALL OK-WITH-KNOWN-RED(n runs, k registered)` / `RUN_ALL FAIL(r new-red + k registered)` | **不** | **不** |
| `bash tests/run_real.sh` | **真链路批**：6 支多进程 `.sh` | 同上（除 `KNOWN-RED`） | `RUN_REAL OK(n entries)` / `RUN_REAL FAIL(...)` | **是**（池内那几支） | 是 |

### `run_all.sh` —— 默认批

- `--list` 打印“跑哪些 + 排除哪些 + 每条理由 + 已知红基线”；`--only <子串>` 跑便宜的子集；`--classify-check` 跑**分类器自检**。
- **自动枚举，清单不写死**（三个 glob）；落选走 `EXCLUDED` 显式清单 + 每条理由。当前排除 4 支：
  `smoke/pvp_match_smoke.gd` + `probe/{rejoin,royale_soak,team_match}_probe.tscn`（它们仍在枚举集里，清掉规则会让承重安全检查 FATAL 或让它们悄悄占 7777）。**枚举 / 排除的实时数字以 `--list` 为准。**
- **入口自己会红的九种情形**：glob 空转 / 过期排除项 / `probe/*.gd` 既没跑也没排除 / 默认批里出现开端口或拉子进程的支 / 新红 / 基线条目过期 / 基线路径不在候选面 / 基线文件本身写错 / 某支声明了 `EXPECTED_CHECKS` 却没用于比较。
- ★★ **单支 `OK` 只证明“没有失败输出”，不证明“每条断言都跑过”**（权威：[`lib/probe_base.gd`](lib/probe_base.gd) 文件头）。`--list` 的 `GATE` 栏是 `-` 就表示那一支**没有条数闸**；带闸的支与闸值以 `GATE` 栏为准。
  - 现有带 `EXPECTED_CHECKS` 的支：`net_wire_smoke`(4) · `input_queue_smoke`(4) · `snapshot_size_probe`(5)。**`gated-assertions` 的实时数以 `--list` 为准。**
  - ★ `allscript_probe` 有自己的条数闸 `EXPECTED_SCRIPTS`（当前 **174**），但 `run_all` 的 `gate_of()` 只认 `EXPECTED_CHECKS` ⇒ 它的 `GATE` 栏是 `-`。**别把 `-` 读成“没有闸”**。
- ★★ **已知红基线 [`known_red.txt`](known_red.txt)**：每行 `路径 类别 理由…`（理由必填；`#` 是注释；空行 / 类别非法 / 路径不存在 / 同一路径两行都**红**）。基线内的红 = `KNOWN-RED`：不进新红计数、但永远印出文件名，全批判词改 `OK-WITH-KNOWN-RED`。**当前基线为空（0 条）**；加行**不是**让检查变绿的手段，修好了要删行。

### `run_real.sh` —— 真链路批

| # | 脚本 | 端口 | 耗时估计 | 判词 | 池内回收 |
|---|---|---|---|---|---|
| 1 | `smoke/pvp_match_smoke.sh` | 7777 + pool | ~20s | `SMOKE PASS` | 扫 `[7800,8300)` |
| 2 | `smoke/pvp_room_smoke.sh` | 7777 + pool | ~40s | `SMOKE PASS` | 扫 `[7800,8300)` |
| 3 | `probe/rejoin_probe.sh` | 29300 / 29350（池外） | 60~110s | `REJOIN PROBE: ALL-OK` | **不扫池** |
| 4 | `probe/royale_soak_probe.sh` | 7777 + pool | ~150~200s | `SOAK: ALL-OK` | 扫 `[7800,8300)` |
| 5 | `probe/royale_role_cap_probe.sh` | 7777 + pool | ~3~5min | `ROLE CAP PROBE: ALL-OK(9/9)` | 扫 `[7800,8300)`（由 soak 自己清） |
| 6 | `probe/team_match_probe.sh` | 29200 / 29250（池外） | 3~10min | `TEAM MATCH PROBE: ALL-OK` | **不扫池** |

- **四道闸**：① `lobby_alive` 为真 ⇒ 拒绝；② 无 `--yes` 且 stdin 非交互 ⇒ 拒绝；③ **R20 锁**（`tests/.run_all.lock`）+ 前后进程检查；④ **清单不许烂**（`tests/{smoke,probe}/*.sh` 每一支必须在 `ENTRIES` 或 `WRAPPERS` 里，两边每条都要匹配到真实文件）。
- `WRAPPERS` 当前为空数组（`WRAPPERS=()`）；**别删这个数组** —— 闸四同时遍历 `ENTRIES` 与 `WRAPPERS`，`set -u` 下数组不存在会炸。
- ★ `team_match_probe.sh` 在 [`docs/eng/registered-debt.md`](../docs/eng/registered-debt.md) 仍登记为**不可信**：它绿了也不构成 3v3 的可信端到端守卫。

### 默认批绿 ≠ 真链路绿

两条链路覆盖**不相交**：前者是纯逻辑 + in-process 场景，后者要真端口、真子进程、真对局协议。改到**联机权威 / 协议 / 回滚 / 输入包**必须**两边都看**。默认批不拉子进程、不开端口，真链路批只有上表 6 支 ⇒ 玩法、手感、数值、AI 行为、视觉**只能靠人眼与试玩**。
