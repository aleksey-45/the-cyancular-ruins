# tests/ — 单元 / 场景 / 端到端(无测试框架)

没有单测框架。**判据一律 grep 脚本自己打的 OK 文本**(如 `… ALL-OK` / `… OK(…)`);**退出码从来不是判据**。引擎路径与单支跑法见根 [`AGENTS.md`](../AGENTS.md) §1「跑什么」。

> 本文件只讲**现在怎么跑**。历次批次增减（默认批 20→6→…→41 支的流水账）**已删除**（git log 里有；本仓不设归档目录）。
> **实时读数一律看 `bash tests/run_all.sh --list`**（有 `GATE` 栏与排除理由）；**本文件不抄支数与闸值**——抄过，漂过三次。
> 当前仍成立的覆盖缺口见 [`docs/registered-debt.md`](../docs/registered-debt.md)「零守卫面」表。

## 文件分层

**桶由"要什么资源"决定，目录名就是桶名**（2026-11-17 重构；`.sh` 只允许出现在 `e2e/`）：

| 目录 | 桶 | 要什么 |
|---|---|---|
| `unit/` | 单元（`-s`） | 单进程、autoload 未实例化、不碰网络/磁盘/真场景 |
| `scene/` | 场景探针 | 真实例化 `.tscn`、走 `_ready`/信号/资源加载 |
| `e2e/` | 端到端 | 真端口、真子进程、真协议（只在 `run_real.sh` 里跑） |
| `harness/` | 被 spawn 的辅助 | watcher / bot input / `menu_autotest`（`menu_autotest` 是唯一被产品代码 `load()` 的测试文件） |
| `lib/` | 夹具/基类 | `scan_util.gd` / `probe_base.gd` |
| `fixtures/` | 输入数据 | `.cyrm` 等 |

一个 stem 的 `.gd` / `.tscn` / `.sh` 伴随文件同桶。**桶内清单不写死**（以 `ls` 与 `--list` 为准）。写法规则见 [`docs/workflow/test-authoring.md`](../docs/workflow/test-authoring.md)。
顶层只留基础设施：`env.sh`（共享环境 + kill 助手）、`known_red.txt`（已知红基线）、`path_integrity_allow.txt`、`run_all.sh`、`run_real.sh`。

注意：`-s` 阶段 autoload 尚未实例化；测试脚本若静态引用会连带预加载"引用 autoload 的脚本"，会在编译期出错。

## 聚合入口

两个入口，**判据同上（文本，不看退出码）**：

| 入口 | 跑什么 | 逐支判词 | 全批判词（纯 ASCII） | 占 7777? | 拉子进程? |
|---|---|---|---|---|---|
| `bash tests/run_all.sh` | **headless 默认批**：自动枚举 `unit/*.gd` + `scene/*.tscn`（`scene/*.gd` 无同名 `.tscn` 的会按 `-s` 进批，今天为 0） | `OK` / `OK+RC` / `FAIL` / `NO-VERDICT` / `TIMEOUT` / `KNOWN-RED` | `RUN_ALL OK(n runs / m gated-assertions)` / `RUN_ALL OK-WITH-KNOWN-RED(n runs, k registered)` / `RUN_ALL FAIL(r new-red + k registered)` | **不** | **不** |
| `bash tests/run_real.sh` | **真链路批**：多进程 `.sh`（当前 3 支，见下表） | 同上（除 `KNOWN-RED`） | `RUN_REAL OK(n entries)` / `RUN_REAL FAIL(...)` | **是**（池内那几支） | 是 |

### `run_all.sh` —— 默认批

- `--list` 打印"跑哪些 + 排除哪些 + 每条理由 + 已知红基线 + `GATE` 闸值"；`--only <子串>` 跑便宜的子集；`--classify-check` 跑**分类器自检**。
- **自动枚举，清单不写死**（两个 glob：`unit/*.gd` + `scene/*.tscn`）；端到端在 `e2e/`，**结构上不在本入口的 glob 直径内**（不再靠"排除表"拦）。落选仍可走 `EXCLUDED` + 理由（今天为空）。**枚举 / 排除的实时数字以 `--list` 为准。**
- **入口自己会红的九种情形**：glob 空转 / 过期排除项 / `scene/*.gd` 既没跑也没排除 / 默认批里出现开端口或拉子进程的支 / 新红 / 基线条目过期 / 基线路径不在候选面 / 基线文件本身写错 / 某支声明了 `EXPECTED_CHECKS` 却没用于比较。
- ★★ **单支 `OK` 只证明"没有失败输出"，不证明"每条断言都跑过"**（权威：[`lib/probe_base.gd`](lib/probe_base.gd) 文件头）。`--list` 的 `GATE` 栏是 `-` 就表示那一支**没有条数闸**；带闸的支与闸值**一律以 `GATE` 栏为准**（本文件不抄那份清单 —— 抄过一次，漂过三次）。
- ★ `allscript_probe` 的条数闸叫 `EXPECTED_SCRIPTS`（不是 `EXPECTED_CHECKS`），故 `run_all` 的 `gate_of()` 只认后者 ⇒ 它的 `GATE` 栏是 `-`。**别把 `-` 读成"没有闸"**。
- ★★ **已知红基线 [`known_red.txt`](known_red.txt)**：每行 `路径 类别 理由…`（理由必填；`#` 是注释；空行 / 类别非法 / 路径不存在 / 同一路径两行都**红**）。基线内的红 = `KNOWN-RED`：不进新红计数、但永远印出文件名，全批判词改 `OK-WITH-KNOWN-RED`。**当前基线为空（0 条）**；加行**不是**让检查变绿的手段，修好了要删行。

### `run_real.sh` —— 真链路批

| # | 脚本 | 端口 | 耗时估计 | 判词 | 池内回收 |
|---|---|---|---|---|---|
| 1 | `e2e/pvp_match_smoke.sh` | 7777 + pool | ~20s | `SMOKE PASS` | 扫 `[7800,8300)` |
| 2 | `e2e/rejoin_probe.sh` | 29300 / 29350（池外） | 60~110s | `REJOIN PROBE: ALL-OK` | **不扫池** |
| 3 | `e2e/team_match_probe.sh` | 29200 / 29250（池外） | 3~10min | `TEAM MATCH PROBE: ALL-OK` | **不扫池** |

- ★ 2026-11-04:`royale_soak_probe`(大乱斗多人 soak)/ `royale_role_cap_probe`(9 人 role 上限,只是 soak 的包装)/ `bot_1v1_probe`(bot 端到端)三支已整支删除 ⇒ **大乱斗 8+ 人端到端与 bot 端到端覆盖归零**,只能靠历史读数 + 人工试玩;见 [`docs/registered-debt.md`](../docs/registered-debt.md) 零守卫面。
- **四道闸**：① `lobby_alive` 为真 ⇒ 拒绝；② 无 `--yes` 且 stdin 非交互 ⇒ 拒绝；③ **R20 锁**（`tests/.run_all.lock`）+ 前后进程检查；④ **清单不许烂**（`tests/e2e/*.sh` 每一支必须在 `ENTRIES` 或 `WRAPPERS` 里，两边每条都要匹配到真实文件；`unit/`、`scene/` 下出现 `.sh` 直接 FATAL）。
- `WRAPPERS` 当前为空数组（`WRAPPERS=()`）；**别删这个数组** —— 闸四同时遍历 `ENTRIES` 与 `WRAPPERS`，`set -u` 下数组不存在会炸。
- ★ `team_match_probe.sh` 在 [`docs/registered-debt.md`](../docs/registered-debt.md) 仍登记为**不可信**：它绿了也不构成 3v3 的可信端到端守卫。
- ★ 失败 entry 会残留 7777 大厅、连累后续 entry 假 FAIL（BUG-25，见 registered-debt §三十七）：串行跑前先确认 7777 空闲且无 godot 残留。

### 默认批绿 ≠ 真链路绿

两条链路覆盖**不相交**：前者是纯逻辑 + in-process 场景，后者要真端口、真子进程、真对局协议。改到**联机权威 / 协议 / 回滚 / 输入包**必须**两边都看**。默认批不拉子进程、不开端口，真链路批只有上表 3 支 ⇒ 玩法、手感、数值、AI 行为、视觉**只能靠人眼与试玩**。
