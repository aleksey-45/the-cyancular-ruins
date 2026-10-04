# 聚合回归入口（audit §2.9）实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use `subagent-driven-development` (recommended) or `executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 本仓**没有 CI、也没有聚合回归入口** —— 判据靠"逐脚本自造文本行"、靠人记得跑哪些。本计划加**一个入口**：一条命令跑完**所有 headless 安全的**冒烟与探针，输出**一张表**并给出**唯一判词**；真链路那批**单独一条命令**、且**必须过用户的认领闸**。

**Architecture:** 纯新增（不动任何既有测试与守卫）。三个原则：① **判据文本化**（沿用 `SMOKE OK` / `ALL-OK`，不引入第二套判词）；② **不越权**（默认**不**跑占 7777 的真链路、**不**跑非 headless 的取图探针 —— 那两类要显式 flag + 用户认领）；③ **会红**（入口自己也有一条能红的自检：故意跑一个必败的假测试，入口必须报 FAIL 且退出码非 0）。

**Tech Stack:** Git Bash 脚本（本仓既有 `tests/*/*.sh` 的壳）、Godot headless、`tests/env.sh` 的 `$GODOT` 与 kill 助手。

**Spec:** [`docs/eng/audit-2026-10-04-design-conventions.md`](../eng/audit-2026-10-04-design-conventions.md) §2.9 + 用户裁定（"§2 也可以做，拆分细一点"）+ [`docs/eng/tests.md`](../eng/tests.md) 的判据纪律。

## Global Constraints

- ★★ **入口必须尊重既有纪律**，不许为了"一次跑完"破规矩：
  - **占 7777 的一律不进默认批**（大厅 `_ready` 会 `kill_udp_port(7777)`，会端掉用户正在跑的对局）；
  - **非 headless（取图/真渲染）一律不进默认批**（弹窗抢焦点）；
  - 每个 `-s` 套 `timeout`；每个场景探针 `--quit-after 3600`；
  - 跑批**前后** `tasklist | grep -i godot` 必须为空；收尾 `kill_port_range 7800 8300`（★ 且只在**真链路**批里扫，因为默认批根本不占那些端口）。
- **只新增文件**：不动任何既有测试/探针/守卫；不动 `tools/check_naming.py`。
- ★ **判据仍是 grep 文本**：入口自己的"通过"判定必须**基于被跑脚本打印的判词行**，而**不是**退出码（本仓的坑：`| tail` 报的是 `tail` 的退出码；`ALL-OK` 也可能只是"没有断言失败"）。
- 逐个文件点名 `git add`；**绝不** `git add -A`。
- ★ **本计划不引入 CI**（`Task 3` 只做决策记录）：本仓跑测试要 Windows + 两个 Godot 二进制的本机绝对路径，CI 是**项目级决策**，得用户拍。

## Review Focus

1. **"headless 安全"要按证据分桶，不按目录名**（Task 1）：`tests/README.md` 的四个 bucket 是按**角色**分的，不等于"headless 安全"。分桶依据 = **那个文件的跑法**（`extends SceneTree` + `-s` = 安全；`extends Node` + `.tscn` = 安全但慢；**非 headless 取图**、**占端口**、**多进程真链路** = 不进默认批）。★ 先 `grep` 每个候选的 `extends` 与头注里的跑法，别照抄文件名规则。
2. **判词与"跑全了没有"**（Task 1）：本仓已有教训 —— `ALL-OK` 只证明**没有断言失败**，不证明**每条断言都跑过**（脚本错误会静默跳过后续）。入口要**同时**检查：判词行**存在** + 该文件的期望断言数（若文件里有 `EXPECTED_CHECKS`）**对得上**。★ 对不上的要在表里单列一栏"判词在但计数可疑"。
3. **真链路批的闸**（Task 2）：`AGENTS.md` 要求"**先问用户认领**" ⇒ 脚本**不能**默默跑。形状：`--real` 时**先打印**将跑的清单 + 会占的端口 + 需要的时间，然后**要求交互确认**（非交互环境直接拒绝并提示手动跑）。
4. **入口自己要能被测**（Task 1 Step 4）：喂一个**必败的假测试**（临时文件：打印 `SMOKE FAILED`）⇒ 入口必须报 FAIL、退出码非 0、且**在表里点名那个文件**。★ 这条自检是"入口不是装饰品"的唯一证据。

---

### Task 1: 聚合入口（headless 默认批）

**Files:**
- Create: `tests/run_all.sh`
- Modify: `tests/README.md`（加"聚合入口"一节与它的判据/边界）
- Modify: `AGENTS.md`（§1 的跑法清单里加这一条 ★ **定点改**，别整段重写）

**Interfaces:**
- Consumes: `tests/env.sh`（`$GODOT`、`kill_port_range`、`lobby_alive`）；`tests/smoke/*.gd`（`-s`，判词 `SMOKE OK`）；`tests/probe/*.tscn`（`--quit-after 3600`，判词 `ALL-OK`）。
- Produces: `bash tests/run_all.sh` ⇒ 逐文件一行表格 + 末尾**唯一判词**（形如 `RUN_ALL OK(n 支 / m 断言)` 或 `RUN_ALL FAIL(k 支)`）+ 失败清单。

- [ ] **Step 1: 分桶（先取证，别照抄目录名）**

Run: `for f in tests/smoke/*.gd; do echo "$f: $(head -3 "$f" | tr '\n' ' ')"; done | head -40`
Run: `for f in tests/probe/*.tscn; do echo "$f"; done | head -40`
Run: `grep -rln "lobby_alive\|7777\|get_cmdline_user_args\|--headless" tests/smoke tests/probe | head -20`（**排掉**任何会占端口/非 headless 的）
★ 产出**三个清单**写进报告：**默认批**（headless 安全）、**排除**（为什么排）、**真链路**（交给 Task 2）。

- [ ] **Step 2: 写入口（先写成"能红"的形状）**

`tests/run_all.sh`：遍历默认批 → 每个套 `timeout` → **捕获输出到临时日志** → 从日志里 `grep` 判词 → 汇总表格。
★ 退出码：任一 FAIL ⇒ 非 0；★ **别**用 `| tail` 取判词（要留全文日志，并把日志路径打进表里）。
★ 顺手打印"环境口径"：`$GODOT` 的版本行、有没有活大厅（`lobby_alive`）、跑前的 godot 进程数。

- [ ] **Step 3: 跑它（第一次全量）**

Run: `bash tests/run_all.sh`（★ 可能几分钟；★ 全程 headless，**不弹窗、不占 7777**）
⇒ 把表格与判词原文写进报告；★ **任何一支红**都要在这份报告里如实列出（那可能是**既有红**，本任务不负责修，但要登记）。

- [ ] **Step 4: 自检（"能红"的证据）**

造一个临时必败测试（例：`tests/smoke/_tmp_always_fail.gd`，打印 `SMOKE FAILED: 自检`）⇒ 入口必须 **FAIL 且点名它**；删掉临时文件 ⇒ 入口回到 OK。★ 两步的输出都进报告。

- [ ] **Step 5: 文档**

`tests/README.md` 加一节（判据、边界、"哪些**不**在默认批里、为什么不"）；`AGENTS.md` §1 的跑法清单加一行（★ 定点改）。
★ 顺带把"**默认批不含真链路**"这条写进 `docs/eng/registered-debt.md` 的话术里不需要 —— 但要在 README 里说清"**默认批绿 ≠ 真链路绿**"。

- [ ] **Step 6: 提交**

```bash
git add tests/run_all.sh tests/README.md AGENTS.md
git commit -m "test: 加聚合回归入口 tests/run_all.sh(headless 默认批:逐文件判词表 + 唯一判词;真链路与非 headless 仍要显式跑)"
```

---

### Task 2: 真链路批的"认领闸"

**Files:**
- Create: `tests/run_real.sh`
- Modify: `tests/README.md`（同 Task 1 的那一节里补"真链路批"）

**Interfaces:**
- Consumes: `tests/scripts/*.sh`（会占 7777 / 7800~8299 的那批；★ **池外两支**（`rejoin_probe.sh` / `team_match_probe.sh`）**一律不扫** `[7800,8300)`，这条"不扫"是**实现事实**，别照文档改）；`tests/env.sh` 的 `lobby_alive`。
- Produces: `bash tests/run_real.sh [--yes]` ⇒ 先打印将跑的清单/端口/预计耗时 ⇒ 交互确认后逐个跑并按纪律收尾。

- [ ] **Step 1: 分工与顺序（先取证）**

Run: `ls tests/scripts/*.sh` + 逐个头注 `head -20`（看它占什么端口、多久、判词是什么）
Run: `grep -n "lobby_alive\|kill_port_range\|sleep" tests/env.sh tests/scripts/*.sh | head -30`
★ 产出"顺序表"写进报告（★ **同配置跑两次**是时序类结论的前置，跑两次的安排也写进去）。

- [ ] **Step 2: 写闸**

`run_real.sh`：① `lobby_alive` 为真 ⇒ **拒绝并打印**"7777 上有活大厅，先停它"；② 打印清单 + 每支的端口/耗时估计；③ 无 `--yes` 且 stdin 非交互 ⇒ **拒绝**并提示手动跑；④ 跑前/跑后 `tasklist | grep -i godot` 必须为空（有残留 ⇒ 打印并退出非 0）；⑤ 收尾 `kill_port_range 7800 8300`（★ 只对**池内**那几支）。

- [ ] **Step 3: 自检（"能红"的证据）**

① 先起一个假大厅（或直接构造 `lobby_alive` 为真）⇒ 脚本必须**拒绝**；② 让某一支失败（临时改它的判词期望）⇒ 汇总必须 FAIL 并点名；复原。

- [ ] **Step 4: 真链路跑批（**需用户认领**）**

★ 这一步**不是 agent 自己跑的**：把清单列给用户，让用户认领/自己跑。agent 只负责把结果写进账本（含"跑批环境"那条口径）。

- [ ] **Step 5: 提交**

```bash
git add tests/run_real.sh tests/README.md
git commit -m "test: 加真链路入口 tests/run_real.sh(lobby_alive 闸 + 前后进程检查 + 端口回收;非交互拒绝)"
```

---

### Task 3: CI 的决策记录（**不实现**）

- [ ] **Step 1: 把"要不要 CI"写成待裁决项**

在 `registered-debt.md` **§六** 追加一条：本仓**无 CI**；`tests/run_all.sh` 已经是可以被 CI 直接调用的形状，但**上 CI 需要项目级决策**（跑测试要 Windows + 两个 Godot 二进制的本机绝对路径；`.bat`/`proc_util.gd` 有 Windows-only 分支）。
★ 写清**翻案条件**：用户决定上（哪家 forge、哪几个 bucket、多久跑一次）⇒ 那时本任务只欠一个 workflow 文件。
★ **不要**在没有用户裁决的情况下新建 `.github/`。

- [ ] **Step 2: 提交**

```bash
git add docs/eng/registered-debt.md
git commit -m "docs(debt): 登记『无 CI』的现状与翻案条件(聚合入口已就绪,上 CI 属项目级决策)"
```

---

## 本计划**不含**

- **修既有红** —— 若 Task 1 Step 3 的全量跑暴露了红的支，**登记 + 报告**，修它们属各自域的批次。
- **改动任何既有测试/探针/守卫**。
- **CI 实现**（Task 3 只登记）。
- **§2 的其它条目**（2.1/2.10/2.11 → Plan C；2.2/2.3 → 另一份；2.4 → 单独一份；2.5/2.6 → Plan B；2.7/2.8 已判不做）。
