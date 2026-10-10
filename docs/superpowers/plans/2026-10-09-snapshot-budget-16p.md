# 16 人上限与快照分片预算 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把联机人数上限从 8 提到 **16**，并把「世界包在 N≤16 恒为**单个 ENet 包**」钉成合同 —— 因为快照走 `unreliable` 分片，**丢一片 = 整帧丢**。

**Architecture:** 先改上限（`ROYALE_MAX_PLAYERS`）并排查假设 8 人的代码；再用探针把 N=16 的**典型**与**最坏**（全员回溯 ⇒ trail 10 点/人）分片数读出来；若最坏超 MTU，就把 `trail` 在**包内**有界化（保留最近 K 点）而不是砍掉这个特性。**不做**兴趣管理 —— 16 人的上行 143.85 KB/s 不需要它。

**Tech Stack:** Godot 4.7.1 / GDScript / ENet

**Spec:** [`docs/eng/netcode-at-16-players.md`](../../eng/netcode-at-16-players.md) §1 · 另见 [`netcode-snapshots.md`](../../eng/netcode-snapshots.md) §2.3

**Global Constraints:** 见 [`2026-10-09-input-uplink-codec-and-redundancy.md`](2026-10-09-input-uplink-codec-and-redundancy.md) 的「Global Constraints」一节（逐字适用：grep 判词、条数闸、档 3 变异验证 + 真链路、逐个文件 `git add`、禁用 `RegEx`、开关写在 `--` 之后、先查 `lobby_alive`、批前后进程为 0、不推送）。

## Review Focus

1. **本机跑不动 16 人真链路**：16 个 headless 客户端 + worker 会打满一台机器 ⇒ 真链路只能跑 4~8 人，**16 人是算术 + 探针读数**。这条必须写进结论，不能假装验过。
2. **假设 8 人的代码**：`ROYALE_MAX_PLAYERS` 只是**校验**那一处；HUD（血条/排行/昵称表）、出生点表、计分分母（ACS）、观战布局都可能假设 8 ⇒ 改上限后要看**第 9 个玩家**进来时界面是否还成立。
3. **`trail` 有界化的观感**：残像点数从 10 降到 K，是**看得见**的表现改动（回溯残像变短）⇒ 按 `AGENTS.md` 档 1 处理：人眼是唯一判据（取图探针已删）。
4. **最坏情况不是"全员回溯"而是"回溯 + 大乱斗换场"**：换场时 `_rw_trail` 被清空，但**换场那一帧**可能同时有旧 trail 与新玩家 ⇒ 边界要看一眼。
5. **探针的 MTU 折算口径**：它按 `MTU=1400 / 每片头 8 B` 粗估，**不是** ENet 实际分片实现 ⇒ 合同应写成"payload ≤ 1400 B"（留有真实分片头的余量），不是"恰好 1 片"。

---

### Task 1: 上限 8 → 16（含"假设 8 人"的排查）

**Files:**
- Modify: `server/lobby/lobby_rooms.gd:21`（`ROYALE_MAX_PLAYERS`）
- Modify: 任何硬编码 8 的注释/表（由 Step 1 的 grep 结果定）
- Modify: `docs/eng/modes.md`（上限与已知差异）

**Interfaces:**
- Produces: `ROYALE_MAX_PLAYERS := 16`（`ROYALE_DEFAULT_MAX` / `ROYALE_MIN_PLAYERS` 不变）

- [ ] **Step 1: grep 出所有"8"的用法，逐条判定**

```bash
grep -rn 'ROYALE_MAX_PLAYERS\|ROYALE_DEFAULT_MAX\|ROYALE_MIN_PLAYERS' --include=*.gd --include=*.md .
grep -rn 'players.size()\|8 人\|8人' --include=*.gd scenes/ server/ ui/ | grep -v tests/
```
Expected: 一张清单，每条标"只是校验 / 假设人数 / 无关"。★ 清单进 Step 4 的提交信息。

- [ ] **Step 2: 改常量并跑默认批**

Run: `bash tests/run_all.sh`
Expected: `RUN_ALL OK(13 runs / 10 gated-assertions)`（改一个常量不该动任何支）。

- [ ] **Step 3: 真链路回归（**本机能跑多少就跑多少**）**

Run: `bash tests/probe/royale_soak_probe.sh`（4 客户端，先查 `lobby_alive`）
Expected: `SOAK: ALL-OK(4/4)`；若机器有余量再跑一次 `--clients=8`（`royale_soak_probe.sh` 支持），
**16 人跑不动 ⇒ 照实写**。

- [ ] **Step 4: 提交**

```bash
git add server/lobby/lobby_rooms.gd docs/eng/modes.md
git commit -m "feat(lobby): 大乱斗人数上限 8→16(逐条排查假设 8 人的代码)"
```

---

### Task 2: 把「世界包 @N≤16 = 单个包」钉成合同（含最坏情况）

**Files:**
- Modify: `tests/probe/snapshot_size_probe.gd`（N 表扩到 16 已有；补 **最坏 trail** 一行 + 1 条断言）
- Modify: `docs/eng/netcode-snapshots.md` §2.3（补最坏情况读数）

**Interfaces:**
- Consumes: 既有 `_frags(payload)`、`SnapshotCodec.WORLD_SCHEMA`、`_t_bytes(t, trail_n)`
- Produces: `const WORLD_PACKET_BUDGET := 1400`（= ENet MTU；★ 判据是 **payload ≤ 这个数**，不是"恰好 1 片"）

- [ ] **Step 1: 写失败的断言（1 条，带条数闸 3 → 4）**

★ **判据形式很要紧**：**不许**写成 `7 + 16 * _schema_bytes(WORLD_SCHEMA, 10) <= 1400` 这种**算术自证** ——
那种写法里"发送侧到底截没截"根本没进判据（改 `TRAIL_SEND_MAX` 它不动 ⇒ 变异时抓不到），
而且 `TRAIL_SEND_MAX` 一变就两边一起变（**镜像守卫**，本仓 `gen_menu_theme` 那条老账）。
⇒ 判据要**量真实产物**：拿一个最坏的世界 dict 过一遍**真的编码**，断言**编码出来的字节数**：

```gdscript
# ④ 世界包在最坏情况下也必须装进**一个** ENet 包:16 人 × 全员回溯(trail 10 点)。
#    量的是**真的 encode_world 产出**,所以"发送侧忘了截断"和"表里加了字段"两种都会红。
var worst_players := {}
for i in 16:
    worst_players[str(i + 1)] = _entry_world(_trail_pts(10))     # 10 点 = match_host 的 trail 上限
var worst_bytes := SnapshotCodec.encode_world({"tick": 0, "players": worst_players}).size()
_check(worst_bytes <= WORLD_PACKET_BUDGET,
    "最坏世界包(N=16 × trail 10 点)必须 ≤ %d B(实得 %d B = %d 片)" % [
        WORLD_PACKET_BUDGET, worst_bytes, _frags(worst_bytes)])
```
（`_trail_pts(n)` = 造 n 个点的辅助函数，探针本地；并把这行读数打进 N 表旁边，让**读数**常在。）

- [ ] **Step 2: 跑它，确认红**

Run: `"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/snapshot_size_probe.tscn`
Expected: `✗ 最坏世界包 … 实得 1831 B = 2 片`（spec §1 的算术，这里变成**实测**）。

- [ ] **Step 3: 提交（先留红？不 —— 与本批的规矩一致：Step 3 在同一次提交里带修复，见 Task 3）**

★ 本仓不做"红着提交"：**Task 2 与 Task 3 合成一次提交**（判据 + 修复 + 读数一起进），Task 2 的 Step 2 只是**确认判据真的会红**。

---

### Task 3: `trail` 包内有界化（把最坏情况压回一个包）

**Files:**
- Modify: `server/match/match_snapshot.gd`（世界包只带最近 `TRAIL_SEND_MAX` 个点）
- Modify: `core/net/net_codec.gd`（`TRAIL_MAX` 与发送上限对齐；超出即截断，**不是**报错）
- Modify: `tests/probe/snapshot_size_probe.gd`（最坏那条断言转绿）

**Interfaces:**
- Produces: `MatchSnapshot.TRAIL_SEND_MAX := 4`（依据：33 + 1 + 8×4 = 66 B/人 ⇒ 16 人 = 1063 B ≤ 1400，留 24% 余量；10 点保留在**服务器录像**里，只是不上行)

- [ ] **Step 1: 按标称值算出每条目字节并写进常量注释**

`TRAIL_SEND_MAX = 4` ⇒ 7 + 16×66 = 1063 B（余量 337 B）。★ 若想保 5 点：7+16×74=1191 B（余量 209 B）—— 由人眼按残像观感挑，**读数已给出两种选择**。

- [ ] **Step 2: 实现截断**

`match_snapshot` 组包时 `trail = trail.slice(maxi(0, trail.size() - TRAIL_SEND_MAX))`（**取最近的**，不是最早的 —— 残像要看最新的段）。

- [ ] **Step 3: 跑探针 + 默认批**

Run: `"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/snapshot_size_probe.tscn`；`bash tests/run_all.sh`
Expected: `✓ 世界包最坏 … ≤ 1400 B` / `SNAPSHOT SIZE PROBE: ALL-OK` / `RUN_ALL OK(13 runs / …)`。

- [ ] **Step 4: 变异验证（1 条）**

把 `TRAIL_SEND_MAX` 调到 10（= 不截断）⇒ 最坏那条断言**必须红**（因为判据量的是**真实编码产出**，
不是自证的算术）；还原后回绿。

- [ ] **Step 5: 提交（含 Task 2 的判据）**

```bash
git add server/match/match_snapshot.gd core/net/net_codec.gd tests/probe/snapshot_size_probe.gd \
  docs/eng/netcode-snapshots.md
git commit -m "fix(net): 世界包的 trail 有界化(最近 4 点) —— 16 人全员回溯时不再分片"
```

## 测试面自审（本计划**只加 1 条断言 + 1 条变异**）

| 曾打算 | 处置 | 理由 |
|---|---|---|
| 算术式预算断言（自证） | **改写**为"量真实编码产出" | 自证式是**镜像守卫**：改常量两边一起变、变异抓不到 |
| 加"每字段字节数"的分解断言 | 不做 | 那是**读数**（已在 N 表里打印），钉死 = `D3` |
| 16 人真链路断言 | 不做 | 本机跑不动；**登记**为边界（Task 4） |
| 相关性/兴趣管理的守卫 | 不做 | 裁定**不做**该功能 ⇒ 无代码可守 |

---

### Task 4: 16 人下**不做**的两件事（登记，不写代码）

**Files:**
- Modify: `docs/eng/registered-debt.md`（§八 追加两行）

- [ ] **Step 1: 登记两行**

| # | 项 | 状态 | 说明与翻案条件 |
|---|---|---|---|
| 8.x | **16 人真链路没有跑过** | 新登记 | 本机跑不动 16 个客户端；16 人的结论来自探针读数 + 算术。**翻案条件**：换一台机器或分布式起客户端，跑一次 16 人整局 |
| 8.y | **事件通道（`bullet_spawn`/`hit_event`）的队头阻塞在 16 人下放大** | 新登记 | 它们是 `reliable` **有序**通道（与输入包同族，见 [`netcode-input-uplink.md`](../../eng/netcode-input-uplink.md) §4.2）：丢一包 ⇒ 后续事件排队等重传。16 人事件量翻倍 ⇒ 观感上"命中反馈/子弹延迟出现"。**不修**（事件是离散的、影响是观感）；**翻案条件**：真链路在 16 人下出现"事件成串迟到"，那时改成 unreliable + 冗余（与输入包同一套做法） |
| 8.z | **兴趣管理/相关性明确不做** | 裁定 | 16 人上行 143.85 KB/s（1.15 Mbit/s），O(N²) 的 68% 是本人包且只有 98 KB/s ⇒ **不值得**。**翻案条件**：上限再提到 32 人以上 |

- [ ] **Step 2: 提交**

```bash
git add docs/eng/registered-debt.md
git commit -m "docs(debt): 登记 16 人规模的三条边界(真链路未跑/事件通道 HoL/相关性不做)"
```
