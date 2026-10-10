# 副本渲染：playout 缓冲插值 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把对手副本的位置从「朝最新目标指数追赶（低通，恒滞后 `v/k` 实测 22.6~37.2px，且把丢包转成速度尖峰）」改成「位置历史 + 固定 playout 延迟 + 夹逼线性插值」—— 延迟从**涌现量**变成**选出来的常量**（3 tick = 50ms ≈ 15px @300px/s，比今天还小），抖动被缓冲吸收。

**Architecture:** 客户端维护一个**共享的 playout 时钟**（按世界包的 `tick` 计，±5% 微调纠偏），每个 role 一个定长位置历史环；渲染时取 `render_tick` 前后两帧做线性插值。**两条不许动**：① 幽灵体继续跟**未经平滑的最新权威值**（预测面零回归）；② 大跳变（回溯/重生/换边）仍走**一帧直落**，且**必须清掉该 role 的历史** —— 否则插值会横穿一次瞬移。

**Tech Stack:** Godot 4.7.1 / GDScript

**Spec:** [`docs/eng/netcode-at-16-players.md`](../../eng/netcode-at-16-players.md) §3 · 另见 [`netcode-snapshots.md`](../../eng/netcode-snapshots.md) §4.3/§5.3

**Global Constraints:** 见 [`2026-10-09-input-uplink-codec-and-redundancy.md`](2026-10-09-input-uplink-codec-and-redundancy.md) 的「Global Constraints」一节（逐字适用）。

## Review Focus

1. **当年那套插值退化成"贴最新"的根因是缓冲深度为 0**（`push()` 每包把时钟重置到 `latest-1`，`advance()` 每帧只推 1 tick）⇒ **时钟绝不许被"每包重置"**；这是本计划最容易被复制回来的错误。
2. **underrun（缓冲被吃穿）不许让它倒退**：宁可**冻结**在最新样本，也不能回退到更老的样本"凑一次插值" —— 玩家会看到对手倒着走。
3. **播放在越界附近**：`tick` 是 32 位、会跨接缝/换场重置；跨 reset 时历史必须**整段作废**（否则插值用的是上一局的坐标）。
4. **32 个副本身份（16 人）下的开销**：每帧 15 个 role × 2 次查找是常数级；但历史环要**定长**（不许 append 不裁剪）。
5. **观感类改动的判据只有探针 + 人眼**：取图探针 2026-10-09 已全删 ⇒ "看起来顺不顺"仍需人眼；探针只能证"零位移帧 / 单帧最大位移 / 滞后 px"。

---

### Task 1: playout 时钟 + 每 role 位置历史（含大跳变清历史）

**Files:**
- Create: `core/net/playout_clock.gd`（**纯逻辑**、`RefCounted` ⇒ `-s` 里可判：喂 tick 序列，读 `render_tick`）
- Modify: `scenes/player/player_replica.gd`（历史环 + 插入时按 `SNAP_DIST` 清历史）
- Modify: 三个调用点（`pvp_game` / `team_game` / `royale_game` 的 `apply_snapshot` 调用）—— **只传 tick，签名不变**（`_tick` 早就在传了，只是被忽略）

**Interfaces:**
- Consumes: `scenes/player/player_replica.gd` 既有 `SNAP_DIST`（128px）· `INTERP_RATE`（**本计划落地后可删，删前先确认零引用**）
- Produces:
  - `PlayoutClock.new(playout_ticks: int)` · `on_snapshot(tick: int)` · `advance(delta: float) -> void` · `var render_tick: float`
  - `PlayerReplica.place_history: Array`（元素 `{tick:int, pos:Vector2}`，容量 `HISTORY_MAX := 12`）
  - `const PLAYOUT_TICKS := 3`（Gaffer：缓冲 = 3× 发送间隔 ⇒ 60Hz 下 3 tick = 50ms）

- [ ] **Step 1: 写失败的 `-s` 判据（3 条，新建 `tests/smoke/playout_clock_smoke.gd`）**

★ 这里**必须**新建文件：`PlayoutClock` 是**核心新的纯逻辑件**，而现有 `-s` 冒烟都不覆盖它。
① `render_tick` 恒落在 `latest_tick - playout_ticks` 附近（**去掉"不重置" ⇒ 每包重置 ⇒ 红**）；
② 丢 10 个 tick 的包后，`render_tick` **不许倒退**（**去掉单调性 ⇒ 红**）；
③ 60 帧喂 61 个 tick（服务器快一点）⇒ `render_tick` 在一秒内**追上**（**去掉 ±5% 纠偏 ⇒ 红**）。

- [ ] **Step 2: 跑它确认红**（`Identifier "PlayoutClock" not declared`）

- [ ] **Step 3: 实现 `PlayoutClock`**

`on_snapshot(tick)` 只**记录最新 tick**（**不重置 `render_tick`**）；`advance(delta)` 按
`1 + clampf(err, -0.05, 0.05)` 推进（`err = (latest - playout) - render_tick`）⇒ 就是 time dilation 的最小形态。

- [ ] **Step 4: 接进 `player_replica`**

`apply_snapshot` 里：算 `target` 与当前渲染位置的误差；`> SNAP_DIST` ⇒ **清空 `place_history` 且 `_placed` 语义照旧**；
否则 `place_history.append({tick, pos: target})` 并裁到 12。★ **幽灵体那一行一个字不改。**

- [ ] **Step 5: 跑默认批 + 真链路**

Run: `bash tests/run_all.sh`；`bash tests/smoke/pvp_match_smoke.sh`（先查 `lobby_alive`）
Expected: `RUN_ALL OK(14 runs / …)`（新增 1 支冒烟 ⇒ 支数 +1）/ `SMOKE PASS`。
★ **先读当前值再 +1**：`grep -n EXPECTED_SCRIPTS tests/probe/allscript_probe.gd`（现为 **161**），
改完在提交信息里点名"新增 1 个 `.gd` ⇒ 161 → 162"。**不许写死数字**（本批别的计划也会加文件，落地顺序不定）。
★ 这一步**还不许改渲染** ⇒ 位置表现应与改动前一致（回归对照）。

- [ ] **Step 6: 提交**

```bash
git add core/net/playout_clock.gd core/net/playout_clock.gd.uid \
  tests/smoke/playout_clock_smoke.gd tests/smoke/playout_clock_smoke.gd.uid \
  scenes/player/player_replica.gd tests/probe/allscript_probe.gd
git commit -m "feat(replica): playout 时钟(不随每包重置) + 每 role 位置历史 —— 插值的地基"
```

---

### Task 2: 渲染改成夹逼线性插值（幽灵体不动）

**Files:**
- Modify: `scenes/player/player_replica.gd`（`_process` 的位置那一段）
- Modify: `tests/probe/replica_smoothness_probe.gd`（相 C 的对照读数语义更新）

**Interfaces:**
- Consumes: Task 1 的 `place_history` / `PlayoutClock.render_tick`
- Produces: `PlayerReplica._sample_history(t: float) -> Vector2`（夹逼；**只有一侧** ⇒ 冻结在那一侧，**不回退**）

- [ ] **Step 1: 写失败的判据（探针 += 1 条断言，7 → 8）**

`_sample_history` 的 underrun 行为：给历史 `[t=100, t=102]`、请求 `t=104` ⇒ 返回 `t=102` 的样本
（**不许**外插、**不许**回退到 `t=100`）。这条是 Review Focus #2 的钉子。

- [ ] **Step 2: 跑它确认红**

- [ ] **Step 3: 实现 `_sample_history` 并替换位置推进**

`_process`：`global_position = _sample_history(clock.render_tick)`；`_placed` 的首次直落逻辑保留；
`anchor_to_nearest` 那两处**保留**（承重，见文件头）。

- [ ] **Step 4: 跑探针 + 默认批，比对读数**

Run: `"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/replica_smoothness_probe.tscn`；`bash tests/run_all.sh`
Expected: 相 A 零位移帧 **仍为 0**；相 C 的**渲染滞后 ≤ 今天的 22.6~37.2px**（目标 ≈15px @playout 3 tick）；
相 D（大跳变阈值）**仍绿**；`REPLICA SMOOTHNESS PROBE: ALL-OK`。

- [ ] **Step 5: 变异验证（2 条）**

M1 `playout_ticks` 设 0 ⇒ 相 A 的零位移帧回升 ⇒ 红（证明"缓冲是必需的"，不是装饰）；
M2 大跳变时**不清历史** ⇒ 相 D2 红（插值横穿瞬移 ⇒ 一帧到不了位）。

- [ ] **Step 6: 提交**

```bash
git add scenes/player/player_replica.gd tests/probe/replica_smoothness_probe.gd
git commit -m "feat(replica): 位置改夹逼线性插值(playout 3 tick) —— 滞后从 22.6~37.2px 的涌现量变成 50ms 常量"
```

---

### Task 3: 调 playout 并把人眼结论落纸

**Files:**
- Modify: `docs/eng/netcode-snapshots.md` §4.3/§5.3（把"没做"改成"已做 + 读数"）
- Modify: `docs/eng/netplay.md`（副本位置平滑那一节）
- Modify: `tests/probe/replica_smoothness_probe.gd`（打印 `playout_ticks × 滞后 px` 的小表）

- [ ] **Step 1:（**可整段砍**）打印"playout tick 数 ⇒ 滞后 px / 零位移帧"的读数表**

★ **先问值不值**：这只是**读数**，不是判据；而为了拿到它要么给产品加一个可注入参数（**产品代码被测试牵着走**），
要么手工改常量跑六次。**人眼一遍就能定案的话，这一步整段不做。**
真要做，也**只许在探针里临时改常量跑几档**，**不许**为它给 `player_replica` 加 `set_playout_ticks()`
（读数不值得换一个产品 API）。
★ **这张表永远不加断言**（D3：把 px 数钉死）。

- [ ] **Step 2: 人眼过一遍对局（**必须，且是唯一判据**）**

Run: 起服务端 + 两个客户端（**跑前告知用户会弹窗**），左右横移看对手副本。
Expected: "对手不抖、不忽快忽慢"；★ 取图探针已全删 ⇒ **这是唯一**能判"手感"的手段。

- [ ] **Step 3: 把 `PLAYOUT_TICKS` 定下来并写清依据，提交**

```bash
git add docs/eng/netcode-snapshots.md docs/eng/netplay.md tests/probe/replica_smoothness_probe.gd
git commit -m "docs(net): playout 插值落地 —— 读数 + 人眼结论 + 常量依据"
```

★ **收尾**：`INTERP_RATE` 若不剩任何引用，随最后一次提交删掉（`grep -rn INTERP_RATE` 必须为空），
并在 `netplay.md` 里把"指数追赶"整段改写成"历史 + playout"，注明 **2026-09-22 的裁定为何被推翻**
（当年坏在缓冲深度 0，不是机制错 —— 见本计划 Review Focus #1）。

## 测试面自审（本计划 **+3 条纯逻辑断言 + 1 条探针断言 + 2 条变异**）

| 曾打算 | 处置 | 理由 |
|---|---|---|
| 新建 `playout_clock_smoke.gd` | ✅ **保留（唯一值得新建文件的场合）** | `PlayoutClock` 是**新的纯逻辑件**、现有 4 支冒烟都不覆盖；三条规则各自治一个**真实发生过**的缺陷（"每包重置时钟"正是 2026-09-22 那次退化的根因） |
| playout 档位读数表 | ⏸ **降为可整段砍** | 读数不是判据；且为它加产品 API 不值得 |
| 把"滞后 px ≤ 15"写成断言 | 不做 | 那是**读数**（探针只打印 `_render_err_max`）；钉死 = `D3`，且手感归人眼 |
| 相 E"underrun 不许倒退" | ✅ 保留（探针 7 → 8 条） | 与冒烟那条不同层：一个在时钟、一个在取样器；玩家会看到"对手倒着走" |
| 新取图探针判"顺不顺" | 不做 | 取图探针 2026-10-09 已全删；`AGENTS.md` §2：观感不归自动化 |
