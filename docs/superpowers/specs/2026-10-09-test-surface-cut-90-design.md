# 测试面削减 90% —— 设计（2026-10-09）

> 本文是**执行前的设计**，也是 [`docs/eng/test-economy.md`](../../eng/test-economy.md) §5 要求的那本
> **删除台账**的续篇。执行完成后，本文的「保留清单 / 删除清单 / 同步清单」三节就是这篇改动的全部事实。

## 0. 一句话

默认批 **111 支 → 12 支**（枚举 16 / 排除 4 / 跑 12）、真链路 **5 支不动**、`tests/manual/` **清空**、
`tests/harness/` **只留真链路依赖**：删除 git 跟踪的 **345 个文件**，
同步 **6 处机械闸（5 处需改 + 1 处经核无需改，见 §9）**、**9 份现行文档的 59 个失效路径 token** 与
**38 个产品 `.gd` 的 63 处注释**。

> ★ **2026-10-13 追注(读到上面那个 12 时必看)**:12 / 枚举 16 是**当天**的账;**现行默认批是 14 支**
> (2026-10-10 有两支回归/新增,见 §10 头的追注与 [`tests/README.md`](../../../tests/README.md))。
> 下文所有"12 支""枚举 16"都请按当年读数读,**别当现状**。

## 1. 判据来源

**外部证据**（2026-10-09 检索，全文读过）：

| 来源 | 关键结论 |
|---|---|
| [MSR 2026 · Are Coding Agents Generating Over-Mocked Tests?](https://2026.msrconf.org/details/msr-2026-technical-papers/29/Are-Coding-Agents-Generating-Over-Mocked-Tests-An-Empirical-Study) | 代理提交 **23%** 动测试文件（非代理 13%）；**36%** 加 mock（非代理 26%）⇒ 代理本能地往测试面堆东西 |
| [CMU · Speed at the Cost of Quality（arXiv 2511.04427）](https://arxiv.org/abs/2511.04427) | 代理带来的速度提升**短暂**，复杂度与告警**持久上升**并反过来拖慢长期速度 |
| [Typemock · We Need Garbage Collection for Test Suites](https://www.typemock.com/garbage-collection-for-unit-tests/) | *"Tests Are Easy to Add and Hard to Remove"*；套件缺一个垃圾回收器 |
| [André Arko · You should delete tests](https://andre.arko.net/2025/06/30/you-should-delete-tests/) | 判据只有一条：**凡让信心下降的测试就该删**。*"it is blasphemy to delete a test" 这个信条不只是错，而且有害* |
| [grugbrain · on testing](https://grugbrain.dev/#grug-on-testing) | 要的是**一小撮精心维护的高层测试**；同时警告"E2E 多到被集体无视"是反面教材 |

**本仓判据**：[`test-economy.md`](../../eng/test-economy.md) 的 D1–D9（删）/ K1–K5（留）。
**核心结论**：删的标准是**信心**，不是覆盖率；证据支持"砍到只剩一小撮**高层**守卫"，
**不支持**"只留不测行为的元闸、把真链路也砍掉"——后者留下的是维护费最高、信心最低的一档。
⇒ 本设计按"**每类承重面至少留一支、且尽量留高层的那一支**"取名单。

## 2. 范围

**做**

- 默认批（`run_all.sh` 枚举到的）从 111 支砍到 12 支。
- `tests/manual/`（18 支仪器 + 11 `.tscn` + README）整个删除。
- `tests/harness/` 只保留真链路 5 支实际用到的 5 个脚本。
- 同步所有会因此变红/失效的机械闸与文档（§5）。

**不做**

- `tests/lib/`（`probe_base.gd` / `scan_util.gd`）：保留下来的探针在用 ⇒ 留。
- `tests/scripts/`（4 支迁移/诊断工具）：本来就不在 glob 直径内，不属于"冒烟与探针" ⇒ 留（各自有债单登记）。
- 真链路 5 支：按证据保留。
- 不重写 git 历史。"永远删除" = 从工作树与 git 跟踪里删掉，**不是**从历史里抹掉。

## 3. 保留清单（决定性）

### 3.1 默认批：12 支（每类承重面 ≥1）

| # | 支 | 覆盖的承重面 |
|---|---|---|
| 1 | `tests/smoke/network_input_smoke.gd` | 输入包（`get_axis` 由 held/ax 推导） |
| 2 | `tests/smoke/server_input_sanitize_smoke.gd` | 输入包 · 服务端收口（产品代码点名 **7** 处，全仓最高） |
| 3 | `tests/smoke/rpc_channel_contract_smoke.gd` | 协议 · RPC 通道契约 |
| 4 | `tests/probe/map_format_v4_probe.gd` | 存档与地图格式（cyrm v4 往返 / 压缩 / CRC 破坏检测） |
| 5 | `tests/probe/map_catalog_probe.gd` | 地图目录 · 联机定图校验 |
| 6 | `tests/probe/tile_collision_probe.gd` | 命中与碰撞判定 |
| 7 | `tests/probe/wrap_probe.gd` | 环面几何 |
| 8 | `tests/probe/rollback_fidelity_probe.tscn` | 回滚与快照 · 回滚等价 |
| 9 | `tests/probe/resync_world_probe.tscn` | 回滚与快照 · 重同步 |
| 10 | `tests/probe/snapshot_size_probe.tscn` | 快照管线 · 带宽 |
| 11 | `tests/probe/allscript_probe.gd` | **元闸**：全仓 `.gd` 编译面计数 |
| 12 | `tests/probe/path_integrity_probe.gd` | **元闸**：代码 → 文件系统的路径存在性 |

★ 11/12 是元闸，本身不测行为；留下它们的**唯一**理由是：删掉 345 个文件之后，
"没静默少编译 / 没留死路径"这两件事需要有人盯着。它们**不构成**行为回归网。

**`run_all.sh` 的枚举账（可复算）**：`smoke/*.gd` **4** + `probe/*.tscn` **8** + `probe/*.gd`（无同名 `.tscn`）**4**
= **枚举 16**；减去 `EXCLUDED` **4** ⇒ **跑 12**。被排除的 4 支 = 上面 §3.1 之外的
`smoke/pvp_match_smoke.gd` 与 §3.2 的 `rejoin_probe.tscn` / `royale_soak_probe.tscn` / `team_match_probe.tscn`。

### 3.2 真链路：5 支不动

`smoke/pvp_match_smoke.sh` · `smoke/pvp_room_smoke.sh` · `probe/rejoin_probe.sh` ·
`probe/royale_soak_probe.sh` · `probe/team_match_probe.sh`（外加各自的 `.gd` / `.tscn` / `pvp_match_smoke.tscn`）。

★ `team_match_probe` 在 [`registered-debt.md`](../../eng/registered-debt.md) §一仍登记为**不可信** ——
这次削减**不改变**该登记，也不销它。

### 3.3 harness：5 支（真链路依赖闭包，实测得来）

`pvp_smoke_client.gd/.tscn`（← `pvp_room_smoke.sh`）· `rejoin_watcher.gd`（← `rejoin_probe.gd`）·
`soak_bot_input.gd`（← `royale_soak_probe.gd` `preload`）· `team_match_watcher.gd` + `team_bot_input.gd`
（← `team_match_probe.gd`，其中 watcher 再 `preload` 后者）。

## 4. 删除清单（精确，`git ls-files` 口径）

| 目录 | `.gd` | `.tscn` | `.sh` | 其它 | `.gd.uid` | 小计 |
|---|---|---|---|---|---|---|
| `tests/smoke/` | 36 | 4 | 4 | — | 36 | **80** |
| `tests/probe/` | 68 | 63 | 0 | — | 67 | **198** |
| `tests/harness/` | 8 | 1 | 0 | `net_lag_proxy.py` ×1 | 8 | **18** |
| `tests/manual/` | 18 | 11 | 0 | `README.md` ×1 | 18 | **48** |
| `tests/scripts/` | 0 | 0 | 0 | — | 0 | **0**（不在范围） |
| **合计** | **130** | **79** | **4** | **3** | **129** | **345** |

（`.gd.uid` 数 ≠ `.gd` 数，因为 `rpc_channel_contract_smoke` / `server_input_sanitize_smoke` /
`score_rules_smoke` 三个 `.gd` 的 `.uid` 尚未进库 —— 这是既有事实，不在本次改动内。）

## 5. 连带同步（爆炸半径）

| # | 位置 | 现状 → 目标 | 不做的后果 |
|---|---|---|---|
| 1 | [`run_all.sh`](../../../tests/run_all.sh) `EXCLUDED` | 9 条 → **4 条**（删掉指向已删文件的 5 条；**保留** `pvp_match_smoke.gd` / `rejoin_probe.tscn` / `royale_soak_probe.tscn` / `team_match_probe.tscn` 这 4 条 —— 那 4 支都还在枚举集里、仍会占 7777 / 拉子进程） | 过期排除项 ⇒ **入口自己红**（`STALE` 致命，L764）；反过来误删那 4 条 ⇒ 承重安全检查（`DANGER_RE`）**FATAL** |
| 2 | `run_all.sh` `OUT_OF_SCOPE` | 4 条**保留**（`tests/scripts/*.gd` 未删） | — |
| 3 | [`run_real.sh`](../../../tests/run_real.sh) `WRAPPERS` | 4 条 → **0 条**（4 个 `.sh` 全删） | 闸四匹配不到文件 ⇒ 红 |
| 4 | [`known_red.txt`](../../../tests/known_red.txt) | 删**唯一**一行（`reconnect_smoke.gd` 已不存在） | 基线幽灵路径 ⇒ 红 |
| 5 | [`allscript_probe.gd`](../../../tests/probe/allscript_probe.gd) `EXPECTED_SCRIPTS` | `288` → **`158`**（= 288 − 130 个被删 `.gd`；两条独立核法：`git ls-files '*.gd' \| wc -l` 与探针自打的 `_total`。`SKIP_DIRS` 不含 `tests/`，故是直接相减） | 编译面闸立刻红 —— **这是要的**：它是"删干净了"的独立证据 |
| 6 | [`path_integrity_allow.txt`](../../../tests/path_integrity_allow.txt) | **经核：无需改动**（实测 0 处引用待删路径 —— 里面那条 `res://__l5_synthetic__.gd` 是**合成串**，不是 `kh_l5_probe` 的文件路径；只有注释里的名字提到它） | ——（第一版设计写"删一行"是错的，见 §9） |
| 7 | [`tests/README.md`](../../../tests/README.md) | 整节重写（枚举数、桶说明、入口表、排除清单） | 文档说谎 |
| 8 | 9 份 `DOC_FILES` 的 **59 个**失效 token | 逐处订正（见 §5.1） | `python tools/check_naming.py` **红** |
| 9 | 产品源码注释里点名的测试 | 逐处改口（见 §5.2） | 不触发任何闸，但注释指向不存在的文件 |
| 10 | [`AGENTS.md`](../../../AGENTS.md) / [`CLAUDE.md`](../../../CLAUDE.md) 的分档表 | 档 3 的"必做"改口 | **文档说谎**：档 3 从此没有可执行的验证手段 |

### 5.1 文档失效 token（`check_naming.py` 会红，59 处）

`docs/eng/`：weapons **4** · player **2** · render **2** · ui **2** · netplay **12** · modes **5** · tests **9** ·
registered-debt **23**。根三份（README / CLAUDE / RELEASE）**0 处**。
（`AGENTS.md` 不在 `DOC_FILES` 里，不会被闸抓，但按 §5 **#10** 仍需改。）

### 5.2 产品源码注释点名（不触发闸，但要改口）

**实测**（`git ls-files` 全仓逐文件数待删路径的出现次数，2026-10-09）：

| 区域 | 文件 | 处数 | 处置 |
|---|---|---|---|
| 产品 `.gd`（`core/ scenes/ server/ ui/ tools/`） | **38** | **63** | **改口**（点名最密：`core/config/settings.gd` 4 · `scenes/player/player.gd` 4 · `server/hosts/team_host.gd` 4 · `core/sim/score_rules.gd` 3 · `core/sim/world_rewind.gd` 3 · `scenes/pvp_match_client.gd` 3 · `server/server_main.gd` 3 · `ui/hud/status_banner.gd` 3） |
| 根三份 + `docs/`（现行规范） | **15** | **129** | 改口（其中 **59** 个 token 被 `check_naming.py` 抓，见 §5.1） |
| `docs/superpowers/`（历史 spec/plan） | 14 | 251 | **有意不动** —— 它们是**历史记录**，不是现行规范 |
| `AGENTS.md` / `CLAUDE.md` / `README.md` | 3 | 3 | 改口（三者**各 1 处**，都是同一条示例命令里的 `tests/smoke/enemy_logic_smoke.gd`；`RELEASE.md` **0 处**） |

★ 第一版设计写的"约 50 个产品文件 / 200 处"是**估的**；实测产品侧是 **38 / 63**。按实际数改。
★ §5.1 的"根三份 0 处"与上表最后一行**不矛盾**：前者数的是 `check_naming.py` 口径（**反引号 + 带扩展名 +
首段是真实目录**），`AGENTS.md` 根本不在 `DOC_FILES` 检查面内；后者的 3 处是**裸文本形态**，闸抓不到。

## 6. R2 红线：唯一的例外点（测量台）

**红线原文**："被产品源码注释点名的**测量台**不许裸删 —— 必须先改产品注释，或先转换成别的可复测手段。"

本次命中的只有一处：[`tests/manual/brawl_rollback_probe`](../../../tests/manual/brawl_rollback_probe.gd)。
点名它的是 [`core/net/prediction_rollback.gd`](../../../core/net/prediction_rollback.gd)（*"要动它得重跑
`brawl_rollback_probe`"*）与 [`scenes/player/player.gd`](../../../scenes/player/player.gd)。
它是 `PredictionRollback._close_enough` **容差常数的唯一测量台** —— 本仓为它付过一次学费
（[`test-economy.md`](../../eng/test-economy.md) §5.1 结尾：先 `git rm` 又 `git checkout` 恢复）。

**处置（Task 0，前置）**：删它**之前**先跑一次，把**实测容差**写进
`core/net/prediction_rollback.gd` 的注释（值在，测量台不在），并在 `registered-debt.md` 登记
"该常数从此不可复测"。**不**保留文件本体（用户口径：`manual/` 清空）。

## 7. 验证

1. `python tools/check_naming.py` ⇒ `命名检查 OK`（基线已实测为绿）。
2. `bash tests/run_all.sh` ⇒ 判词应为 `RUN_ALL OK(...)` 或 `RUN_ALL OK-WITH-KNOWN-RED(...)`；
   ★ **判据是 grep 判词文本，不是退出码**。
3. `bash tests/run_real.sh --list` ⇒ 闸四通过、`ENTRIES` 5 条、无 `WRAPPERS`。
4. `path_integrity_probe` 在批内 ⇒ 它自己就是"没留死路径"的判据。
5. `git status --short` + 逐文件 `git diff` **认领每个 hunk**（共享工作树纪律）。

## 8. 风险与"测不到什么"（照实写）

- ★★ **从此本仓没有任何自动化行为回归网**。剩下 10 支域守卫 + 2 支元闸 + 5 支真链路，
  覆盖的是"恰好可纸面判定"的一小撮；**玩法、手感、数值、AI 行为全部只能靠人工试玩**。
- **档 3 的执行手段被削薄**：改协议 / 回滚 / 快照时，可用的只有 5 支真链路 + `rollback_fidelity` /
  `resync_world` / `snapshot_size` 三支。这比现在弱得多，且**不可逆**（要恢复得从 git 历史里捞）。
- **产品与现行文档的注释会大面积指向不存在的文件**：产品 `.gd` **38 个文件 / 63 处**、
  现行 `docs/` **15 个文件 / 129 处**（§5.2）。本次**全部改口**；
  只有历史 spec/plan（`docs/superpowers/`，14 文件 / 251 处）**有意不动** —— 那是历史记录，不是现行规范。
- **`move_feel` / `enemy_logic` 这类"最广覆盖"的支一删**，AI 与手感的回归只能靠人。
  这与 §1 的证据一致（游戏里自动化收益面窄），但**代价是真实的**，不粉饰。
- **`tools/room_sweep_lint.gd`**（827 行 / 83 处 `_fail`）不在本次范围（它在 `tools/` 下、不在 glob 内），
  但它唯一的**行为替代** `pvp_room_smoke.sh` **保留** ⇒ 该项不受影响。

## 9. 出击前复核（只读，2026-10-09；执行前的最后一道对账）

对**整仓**逐文件扫过一遍"待删 345 个路径被谁引用"，结论四条：

| # | 检查 | 结果 |
|---|---|---|
| ① | **保留的支是否依赖待删文件** | 59 个保留文件里命中 **10 处**，**逐处核过：全部是注释/文本引用，没有一处 `load()` / `preload()` / `extends`** ⇒ **依赖安全**。其中两处最像真依赖、已单独验明：`team_bot_input.gd` 只在一句"与 `ground_bot_input.gd` 逐字同款的理由"里提到它；`team_match_watcher.gd` 两处都是"范本：`royale_c2_probe.gd::_run_client`" |
| ② | **`tests/env.sh`**（保留的基础设施） | **0 处**引用待删路径 ⇒ 不用改 |
| ③ | **`path_integrity_allow.txt`** | **0 处** ⇒ **推翻第一版设计的"删一行"**（§5 #6 已订正）。原因：里面那条 `res://__l5_synthetic__.gd` 是**合成串**，`kh_l5_probe` 只出现在注释文字里 |
| ④ | **`tests/run_all.sh` / `run_real.sh` / `known_red.txt`** | 分别 **8 / 4 / 1** 处，与 §5 的 1/3/4 行**逐条对上**（`run_all.sh` 的 8 = 9 条 `EXCLUDED` 里的 5 条待删 + `OUT_OF_SCOPE` 注释 3 处；`run_real.sh` 的 4 = `WRAPPERS` 4 条） |

★ 这条复核的意义：**"删掉 345 个文件"最大的风险不是闸变红（那些都是显式、可见的），而是某个保留的支
在运行时 `load()` 一个被删的 helper —— 那会静默变成 `null` 再解引用**（正是 `probe_base.gd` 文件头那段
说的"假绿"形状）。① 已把这条风险关掉。

## 10. 执行结果（2026-10-09；设计与实际逐项对账）

> ★★ **2026-10-13 追注 —— 读这张表前必看**:本表是**切割当天(2026-10-09)的实测**,数字**已不是现状**:
> 之后 **2026-10-10** 有两支回归/新增(`dcb8c57` 新增 `tests/smoke/playout_clock_smoke.gd`、
> `db6e124` 把 `tests/probe/replica_smoothness_probe.tscn` 从历史取回)⇒ 默认批 **12 → 14 支**;
> 其中 3 支带 `EXPECTED_CHECKS` ⇒ `m gated-assertions` 由 **0 → 16**。
> ⇒ **现行数字以 `bash tests/run_all.sh --list` 与 [`tests/README.md`](../../../tests/README.md) 为准**;
> 本表的"删 345 → 恢复 2 → **净 343**"仍是**权威**(那是历史事实,也是 `AGENTS.md` 里那个 343 的出处)。

| 项 | 设计说 | **实际** | 差在哪 |
|---|---|---|---|
| 删除的跟踪文件 | 345 | **345 删 → 恢复 2 → 净 343** | 见 10.1 |
| `EXPECTED_SCRIPTS` | 158 | **159** | 恢复 1 个 `.gd` ⇒ 288 − 129 |
| 默认批 | 枚举 16 / 排除 4 / 跑 12 | **完全一致** | —— |
| 判词 | —— | **`RUN_ALL OK(12 runs / 0 gated-assertions)`** | ★ `m = 0` 是**新边界**,不是笔误:见 §8/§10.2 |
| `run_real` 闸四 | 5 条 ENTRIES / 0 条 WRAPPERS | **一致,通过** | —— |
| `known_red.txt` | 删唯一一行 | **一致 ⇒ 基线现为空(0 条)** | —— |
| `path_integrity_allow.txt` | 无需改动 | **一致(0 处引用)** | —— |
| `check_naming.py` 红点 | 59 个 token | **47 条**(每个 token 只报**首个**引用它的文档;且在 9 份 `DOC_FILES` 之外还有同名引用) | 见 10.3 |
| 产品注释 | 38 文件 / 63 处 | **36 文件 / 59 处**(46 反引号 + 13 裸文本) | 估算偏差 |

### 10.1 ★★ 设计漏了一整类依赖：**产品代码 `load()` 测试文件**

**实况**:按 §3.3 的闭包删掉 `tests/harness/menu_autotest.gd` 之后,本批**留下的** `path_integrity_probe`
当场报红:

```
[FAIL] [res://scenes/main_menu.gd] res://tests/harness/menu_autotest.gd
```

[`scenes/main_menu.gd`](../../../scenes/main_menu.gd) 的 `-- --autotest-*` 钩子在 `:164-166` **真的
`load()`** 它（外面套着 `ResourceLoader.exists()` 的 fail-open 守卫 ⇒ 不崩,但**静默失效**）。

**根因(设计的错)**:§9 的复核①只查了「**保留的测试** → 待删文件」,没有查
「**产品代码** → 待删文件」的**代码依赖**;§5.2 把产品侧的引用**一律当注释**处理了 —— 那是个**未验证的假设**。

**处置**:恢复该文件（它是产品依赖的驱动库,不是冒烟/探针,不在"删测试"的射程内）,并把那条产品依赖
**留成开放决策**（[`registered-debt.md`](../../eng/registered-debt.md) §八 8.5 / §七 第 3 条）——
摘钩子是产品行为改动,不由本批代拍。

**教训(值得单独记一句)**:`path_integrity_probe` **就是为此留下的** —— 这次它是唯一抓住该错的守卫。
**"只留 2 支元闸"那个更狠的方案会让这个错直接进库**(那 2 支里只有它扫这个方向)。

### 10.2 ★ 新增边界：默认批的条数闸归零

`RUN_ALL OK(12 runs / 0 gated-assertions)` —— 全批再无一支带 `EXPECTED_CHECKS`。
⇒ 这 10 支域守卫的 `ALL-OK` **只证明"没有断言失败"**,如下已登记:
[`registered-debt.md`](../../eng/registered-debt.md) §八 8.1。**本批不补闸**(补闸 = 10 份新增,与削减方向相反)。

### 10.3 机械订正的做法(可复算)

- **判据**:待删路径 ⇒ `` `basename`（已删·2026-10-09） ``,并在每份现行文档头部加一条读法横幅。
- **代码安全的两道守卫**(只对 `.gd` 用):① 命中必须落在行内 `#` 之后;② 不得落在双引号字符串内。
  ⇒ 实测 **0 处被跳过**(即所有命中都在注释里),59 增 / 59 删,**无整文件重写**。
- **`docs/superpowers/`(历史 spec/plan,14 文件 / 251 处)有意不动** —— 历史记录不是现行规范。

### 10.4 收尾验证(全部实测,不是推断)

| 判据 | 结果 |
|---|---|
| `python tools/check_naming.py` | **命名检查 OK**（削减前:FAIL 47 条） |
| `bash tests/run_all.sh` | **`RUN_ALL OK(12 runs / 0 gated-assertions)`** |
| `ALLSCRIPT` | **`ALLSCRIPT: OK(159)`** —— 全部脚本仍可加载/实例化(即 36 个产品文件的注释改动**没改坏语法**) |
| `PATH INTEGRITY` | **`ALL-OK 209`** |
| `bash tests/run_real.sh --list` | **闸四通过**,ENTRIES 5 / WRAPPERS 0 |
| 真链路批实跑 | **未跑** —— 见下 |

★ **真链路批没有真跑**:`run_real.sh` 闸三要求机上 Godot 进程连续为空,而实测**用户有一个 1GB 的
Godot 实例在跑**（`tasklist` 两个进程）。按 AGENTS.md 硬线**不许端掉用户的对局** ⇒ 只做了 `--list`
（闸四)验证,**5 支真链路脚本本次没有实跑判决**。这与
[`registered-debt.md`](../../eng/registered-debt.md) §一第 1 行"3v3 没有可信端到端守卫"是同一条口径。

