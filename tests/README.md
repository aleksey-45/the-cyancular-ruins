# tests/ — 冒烟 / 诊断(无测试框架)

没有单测框架。运行命令见根 `CLAUDE.md`「常用命令」(headless + `-s`),成功以打印 `SMOKE OK` / `... OK` 为准。

> ## ★★ 2026-10-09:本目录已按「测试经济学」削减到原来的 ~10%
>
> **默认批 111 支 → 14 支;删除 git 跟踪的 345 个文件;`tests/manual/` 整个删除。**
> ★ **2026-10-13 订正**:本节原写"**12 支**"—— 实测(`bash tests/run_all.sh --list`)是
> `enumerated 18 / excluded 4 / **running 14**`;删除文件数 **345** 已用
> `git show --diff-filter=D --name-only 4ae7eed | wc -l` 复核(同一句在 `AGENTS.md` 里曾写 343,已一并订正)。
> 判据(外部证据 + 本仓 D1–D9/K1–K5)、保留清单、逐目录删除清单、爆炸半径与**代价**
> 全在台账:[`docs/superpowers/specs/2026-10-09-test-surface-cut-90-design.md`](../docs/superpowers/specs/2026-10-09-test-surface-cut-90-design.md)。
>
> ★ **读旧材料前先看这一条**:`docs/superpowers/` 里的历史 spec/plan、以及各域文档里标着
> `（已删·2026-10-09）` 的守卫,**都已经不存在**。别把"路径还在句子里"读成"守卫还在"。

## 文件分层(四个 bucket)

一个 stem 的 `.gd` / `.tscn` / `.sh` / `.log` 伴随文件同桶。

- `smoke/`——**行为回归主入口**,5 支:四支 `-s`(`network_input_smoke` 输入包 /
  `server_input_sanitize_smoke` 服务端输入收口 / `rpc_channel_contract_smoke` RPC 通道契约 /
  `playout_clock_smoke` 参考时钟) + 一支真链路客户端 `pvp_match_smoke`(`extends Node`,走同名 `.tscn`,要 `--role`)。
  ★ **2026-10-13 订正**:原写"4 支",漏了 `playout_clock_smoke`(它**是**带 `EXPECTED_CHECKS` 的支,见下文)。
  ★ **`smoke/*.sh` 现在只剩 2 支,都是真链路包装**(`pvp_match_smoke.sh` / `pvp_room_smoke.sh`);
  原来那 4 支"单进程 + tee"的包装(`bullet_tile_fx` / `move_feel` / `pvp_reconcile` / `pvp_twin`)
  连同它们的被测脚本一起删了。
- `probe/`——单点诊断与真链路探针。现存 **13 支**(9 支场景 `.tscn` + 4 支无同名 `.tscn` 的 `-s`),
  其中 3 支(`rejoin` / `royale_soak` / `team_match`)是真链路、**不在默认批**(见 `EXCLUDED`)⇒ 默认批里 **10 支**;
  另有 3 支真链路 `.sh` 包装(见下 `run_real.sh`)。★ **2026-10-13 订正**:原写"12 支 + 3 支",与实际枚举不符。
  - 承重面守卫:`tile_collision_probe`(命中/碰撞)· `wrap_probe`(环面几何)·
    `rollback_fidelity_probe`(回滚等价)· `resync_world_probe`(重同步)· `snapshot_size_probe`(快照/带宽)·
    `map_format_v4_probe`(cyrm v4 往返/CRC)· `map_catalog_probe`(目录/联机定图);
  - **元闸两支**:`allscript_probe`(全仓 `.gd` 编译面计数,`EXPECTED_SCRIPTS`)·
    `path_integrity_probe`(代码 → 文件系统的路径存在性);
  - 真链路三支:`rejoin_probe.sh` / `royale_soak_probe.sh` / `team_match_probe.sh`。
- `harness/`——被 spawn 的辅助。现存 6 支,判据是"**谁在用**":
  `pvp_smoke_client`(← `pvp_room_smoke.sh`)· `rejoin_watcher`(← `rejoin_probe.gd`)·
  `soak_bot_input`(← `royale_soak_probe.gd`)· `team_match_watcher` + `team_bot_input`(← `team_match_probe.gd`)·
  ★ `menu_autotest`(← **产品代码** [`scenes/main_menu.gd`](../scenes/main_menu.gd) 的 `-- --autotest-*` 钩子 ——
  它是**唯一一个被产品 `load()` 的测试文件**;该依赖是 [`registered-debt.md`](../docs/eng/registered-debt.md) §七 第 3 条的开放决策,本次削减**有意没动它**)。
- `scripts/`——四个独立诊断工具(**不是测试**,各有债单登记):`convert_map.gd` / `convert_map_v4.gd` /
  `seam_analyze.gd` / `seam_screenshot.gd`。它们**不在**任何 glob 直径内 —— 加进去等于让以后任何一个
  新工具脚本(可能原地写盘)**自动进回归批**。

`tests/` 顶层只留基础设施:`env.sh`(共享环境)、`lib/`(`scan_util.gd` / `probe_base.gd`)、
`path_integrity_allow.txt` 与 `README.md`。

注意:`-s` 阶段 autoload 尚未实例化;测试脚本若静态引用会连带预加载"引用 autoload 的脚本"会在编译期出错。

## 聚合入口

两个入口:**判据一律 grep 文本,退出码从来不是判据**。

| 入口 | 跑什么 | 逐支判词 | 全批判词(纯 ASCII) | 占 7777? | 拉子进程? |
|---|---|---|---|---|---|
| `bash tests/run_all.sh` | **headless 默认批**:自动枚举 `smoke/*.gd` + `probe/*.tscn` + `probe/*.gd`(无同名 `.tscn` 的) | `OK` / `OK+RC` / `FAIL` / `NO-VERDICT` / `TIMEOUT` / `KNOWN-RED` | `RUN_ALL OK(n runs / m gated-assertions)` / `RUN_ALL OK-WITH-KNOWN-RED(n runs, k registered)` / `RUN_ALL FAIL(r new-red + k registered)` | **不** | **不**(现在一支都不拉) |
| `bash tests/run_real.sh` | **真链路批**:5 支多进程 `.sh` | 同上(除 `KNOWN-RED`) | `RUN_REAL OK(n entries)` / `RUN_REAL FAIL(...)` | **是**(3 支) | 是 |

**当前枚举账(可复算)**:`smoke/*.gd` **5** + `probe/*.tscn` **9** + `probe/*.gd` 无同名 `.tscn` **4**
= **枚举 18**;减 `EXCLUDED` **4** ⇒ **跑 14**。
被排除的 4 支 = `smoke/pvp_match_smoke.gd` + `probe/{rejoin,royale_soak,team_match}_probe.tscn`
(它们都还在枚举集里,所以**必须**留在 `EXCLUDED` —— 清掉规则会让承重安全检查 FATAL 或让它们悄悄占 7777)。
★ **2026-10-13 订正**:原写"枚举 16 / 跑 12",`smoke` 与 `probe/.tscn` 各少算 1
(`playout_clock_smoke` 与 `resync_world_probe.tscn`);现行账以 `bash tests/run_all.sh --list` 的
`[enum]` 三行为准 —— **别手抄这份数字**,它会漂。

### `run_all.sh` —— 默认批

- `--list` 打印"跑哪些 + 排除哪些 + 每条理由 + 已知红基线";`--only <子串>` 跑便宜的子集;
  `--classify-check` 跑**分类器自检**(24 例)。
- ★★ **自动枚举,清单不写死**(三个 glob)。写死会让**新探针永不进默认批**而入口照样打 OK。
  落选一律走 `EXCLUDED` 显式清单 + 每条理由。
- **判词分五类**,`rc` 只用来把"判词肯定"那一类再分一层:`OK`(判词肯定且 `rc==0`)、
  `OK+RC`(**不算红**,但单独成类印出)、`FAIL`、`NO-VERDICT` / `TIMEOUT`(**归红**:安全网耗尽与真失败
  在输出上长得一样)。
- ★★ **已知红基线 [`tests/known_red.txt`](known_red.txt)**:每行 `路径 类别 理由…`。
  ★ **2026-10-09 起基线是空的(0 条)** —— 原来唯一那条(`reconnect_smoke.gd`)随该支被删除而销账,
  **不是修好了**。加行**不是**让检查变绿的手段。
- ★★ **入口自己会红的九种情形**:glob 空转 / 过期排除项 / `probe/*.gd` 既没跑也没排除 /
  默认批里出现开端口或拉子进程的支 / 新红 / 基线条目过期 / 基线路径不在候选面 / 基线文件本身写错 /
  某支声明了 `EXPECTED_CHECKS` 却没用于比较。逐条的"去掉什么才红"写在 [`run_all.sh`](run_all.sh) 文件头。
- ★★ **单支 `OK` 只证明"没有失败输出",不证明"每条断言都跑过"**(权威:[`lib/probe_base.gd`](lib/probe_base.gd) 文件头)。
  表里 `GATE` 栏是 `-` 就表示"**这一支没有条数闸**"。
  ★★ **2026-10-09 后的新边界(照实写)**:默认批带 `m gated-assertions = **16**` ——
  **三支**有可用的 `EXPECTED_CHECKS` 闸(`playout_clock_smoke` 4 / `replica_smoothness_probe` 8 /
  `snapshot_size_probe` 4),其余 **11 支没有条数闸** ⇒ 它们只能自证"没有失败输出",不能自证
  "每条断言都跑过了"。抽查时按 [`docs/eng/tests.md`](../docs/eng/tests.md) 末节的"看 stderr 有没有
  `SCRIPT ERROR`"兜;要补闸请先读 [`test-economy.md`](../docs/eng/test-economy.md) §5.3 第 8 条的裁决
  (本仓**有意不逐支补闸** —— 那是 10 份新增,与削减方向相反)。
  ★ **2026-10-13 订正**:原写"`m gated-assertions = 0`、唯一带 `EXPECTED_CHECKS` 的
  `settings_display_smoke` 被删了、这 **10** 支没有一支能自证" —— 三处都不对:
  `settings_display_smoke` 确实已删,但**另有 3 支在用 `EXPECTED_CHECKS`**(上面那三支),
  `m` 是 **16** 不是 0,支数是 **14** 不是 10。
  (复算法 = 照 `run_all.sh` 的 `gate_of()` 离线跑一遍:`EXPECTED_CHECKS := N` **且**同文件里出现
  拿它比较的表达式才计入 —— 只声明不算闸,见 `run_all.sh:526-544`。)

### `run_real.sh` —— 真链路批

| # | 脚本 | 端口 | 耗时估计 | 判词 | 池内回收 |
|---|---|---|---|---|---|
| 1 | `smoke/pvp_match_smoke.sh` | 7777 + pool | ~20s | `SMOKE PASS` | 扫 `[7800,8300)` |
| 2 | `smoke/pvp_room_smoke.sh` | 7777 + pool | ~40s | `SMOKE PASS` | 扫 `[7800,8300)` |
| 3 | `probe/rejoin_probe.sh` | 29300 / 29350(**池外**) | 60~110s | `REJOIN PROBE: ALL-OK` | **不扫池** |
| 4 | `probe/royale_soak_probe.sh` | 7777 + pool | ~150~200s | `SOAK: ALL-OK` | 扫 `[7800,8300)` |
| 5 | `probe/team_match_probe.sh` | 29200 / 29250(**池外**) | 3~10min | `TEAM MATCH PROBE: ALL-OK` | **不扫池** |

- ★★ **`WRAPPERS` 现在是空的**(`WRAPPERS=()`)。原来那 4 支"单进程 + tee"的包装随被测脚本一起删了。
  ★ **别把空数组删掉**:闸四同时遍历 `ENTRIES` 与 `WRAPPERS`,数组不存在会在 `set -u` 下炸;
  空数组让"现在一支包装都没有"这件事**看得见**。
- ★★ **四道闸**:① `lobby_alive` 为真 ⇒ 拒绝;② 无 `--yes` 且 stdin 非交互 ⇒ 拒绝;
  ③ **R20 锁**(`run_all.sh` 运行期持 `tests/.run_all.lock`)+ 前后进程;④ **清单不许烂**
  (`tests/{smoke,probe}/*.sh` 每一支必须在 `ENTRIES` 或 `WRAPPERS` 里,且两边每条都要匹配到真实文件)。
- ★ `team_match_probe.sh` 在 [`registered-debt.md`](../docs/eng/registered-debt.md) §一第 1 行**仍登记为不可信**:
  根因已修(`9003dae`);★ **2026-10-13 订正**:原写"修复后没有留下六人整跑的判决"—— 那次判决
  **2026-10-08 补上了:手工单跑 ⇒ FAIL(8 条)**(见 [`debt/known-red.md`](../docs/eng/debt/known-red.md) 首行)
  ⇒ 它绿了**也不改变**"3v3 今天没有可信端到端守卫"这句,但**理由从"没跑过"变成"它真红"**。

### ★★ 默认批绿 ≠ 真链路绿(两条链路覆盖**不相交**)

前者是纯逻辑 + in-process 场景;后者要真端口、真子进程、真对局协议。改到**联机权威 / 协议 / 回滚 /
输入包**的改动必须**两边都看**。

★ **2026-10-09 之后还有一条更要紧的**:默认批里**一支也不拉子进程、一支也不开端口**,
而真链路批只有 5 支 —— ⇒ **本仓今天的自动化回归面合计只有这 19 支**(默认批 14 + 真链路 5);
玩法、手感、数值、AI 行为、视觉**全部只能靠人眼与试玩**。这不是意外,是那一批的**有意代价**。
★ **2026-10-13 订正**:原写"17 支"(= 12 + 5),随默认批订正为 **14 + 5 = 19**。
