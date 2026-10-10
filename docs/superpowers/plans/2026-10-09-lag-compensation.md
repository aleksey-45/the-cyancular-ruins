# 命中补偿：先钉伤害路径，再按读数裁定 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把「我打中了但没伤害」这条**先量清楚**（缺口多少 px、多常发生），再按实测裁定：压视图滞后 / 接受 / 按视图时刻回退命中测试。**不预先承诺实现哪一种。**

**Architecture:** 本仓**没有 hitscan 伤害路径** —— 伤害全走服务器模拟的实体子弹，`beam_fired` 只广播视觉（spec §2 有码位与订正）。所以标准那套"回退命中盒"**无处可施**。真正错的是**射手瞄准的是滞后的视图**。任务顺序：钉路径 → 量缺口（复用已有探针读数 + 一条换算打印）→ 裁定 → （仅当裁定选中时才做）回退命中测试。

**Tech Stack:** Godot 4.7.1 / GDScript；离线换算；可选：真链路 + `--netstat`

**Spec:** [`docs/eng/netcode-at-16-players.md`](../../eng/netcode-at-16-players.md) §2

**Global Constraints:** 见 [`2026-10-09-input-uplink-codec-and-redundancy.md`](2026-10-09-input-uplink-codec-and-redundancy.md) 的「Global Constraints」一节（逐字适用）。

## Review Focus

1. **"激光不裁决伤害"必须读码确认，不能靠本计划的转述**：`weapon_base.gd` 里可能有 `bullet_scene == null` 时的另一条分支（射线/即时命中）⇒ Task 1 的第一步就是**把它钉死**，钉不实就**停手**（前提没了，后面全是空转）。
2. **缺口是"位置差"不是"命中率"**：换算成"打空概率"必然带假设（目标横向速度、判定半径 40px）。**假设要写在打印里**，不能只给一个百分数。
3. **回退命中测试的副作用**："拐角被击中"（射手视图里目标还没露头，服务器按视图时刻判定命中）。若选这条路，**必须**同时给出一个可见的裁决口径（例如"回退不超过 100ms"）。
4. **多目标时回退谁**：16 人下一条弹道可能穿过多个目标；回退要对**每个候选目标**用同一个 `view_ms`，且只回退**位置**，不回退血量/姿态（那些必须用当前权威值）。
5. **与播放延迟的耦合**：计划 C（playout 插值）会把视图滞后从 22.6~37.2px 换成 50ms 常量 ⇒ **先做 C 再量 A 的缺口**，否则量到的是改造前的数。

---

### Task 1: 钉死伤害路径（读码 + 落纸；钉不实就停）

**Files:**
- Modify: `docs/eng/netcode-at-16-players.md` §2（把结论从"算术/转述"改成"逐条码位"）

**Interfaces:**
- Produces: 一句可引用的结论：**"本仓的伤害路径只有 __ 条，分别是 __；激光不裁决伤害（码位：__）"**

- [ ] **Step 1: 逐条读伤害路径**

```bash
grep -rn 'bullet_scene\|instantiate()' scenes/weapons/*.gd | head -20
grep -rn 'take_hit\|apply_damage\|hp -=' --include=*.gd server/ scenes/ | grep -v tests/ | head -20
grep -rn '_broadcast_beam_fired\|rep\[' --include=*.gd server/match/match_combat.gd | head -20
```
Expected: 一张"谁把血扣掉"的清单。**若出现 `bullet_scene == null` 的即时命中分支 ⇒ 停手**，
先把那条分支的裁决点找出来再继续（那时"回退命中盒"才有处可施）。

- [ ] **Step 2: 把结论写进 spec（含码位）**

Run: `python tools/check_naming.py`（改了文档路径引用）
Expected: OK。

- [ ] **Step 3: 提交**

```bash
git add docs/eng/netcode-at-16-players.md
git commit -m "docs(net): 钉死伤害路径 —— 只有实体子弹裁决伤害,激光只广播视觉"
```

---

### Task 2: 量缺口（复用已有读数 + 一条换算打印）

**Files:**
- Modify: `tests/probe/replica_smoothness_probe.gd`（相 C 已有 `_render_err_max`；加一行**换算**打印，**不加断言**）
- Modify: `docs/eng/netcode-at-16-players.md` §2（填读数）

**Interfaces:**
- Consumes: `replica_smoothness_probe` 的相 C 读数 `_render_err_max`（实测 ±0ms 22.6 / ±8ms 29.7 / ±16ms 37.2 px）
- Produces: 一行 `[net] 视图滞后 L px ⇒ 目标以 S px/s 横穿时,单发打空距离 ≈ L px(判定半径 40 px)`

- [ ] **Step 1: 加换算打印（读数不是判据）**

```gdscript
# ★ 这是**读数**,不是判据:它把"视图滞后"换算成"打空距离",假设写在行里。
#   判定半径来自 server/match/match_combat.gd 的 HIT_RADIUS(40px);横向速度取 300px/s(玩家移速量级)。
print("[net] 视图滞后 %.1f px ⇒ 若目标横向 300px/s,单发落点偏 %.1f px(判定半径 %.0f px)⇒ %s"
        % [_render_err_max, _render_err_max, HIT_RADIUS_LOCAL,
           "仍在半径内" if _render_err_max < HIT_RADIUS_LOCAL * 0.5 else "足以打空"])
```
（`HIT_RADIUS_LOCAL` 从 `match_combat` 的值抄一份**要在注释里写明来源**，或直接 `preload` 读——选后者，避免第二份真相源。）

- [ ] **Step 2: 跑探针记读数**

Run: `"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/replica_smoothness_probe.tscn`
Expected: `REPLICA SMOOTHNESS PROBE: ALL-OK` + 新那一行（断言条数**不变** = 7）。

- [ ] **Step 3: 提交**

```bash
git add tests/probe/replica_smoothness_probe.gd docs/eng/netcode-at-16-players.md
git commit -m "probe(net): 把副本滞后换算成打空距离(读数,不判) —— 给命中补偿的裁定提供依据"
```

---

### Task 3: 裁定点（**先做计划 C，再看这里的数**）

**Files:**
- Modify: `docs/eng/netcode-at-16-players.md` §2（把"三条候选"改成"选定 X，依据 Y"）

- [ ] **Step 1: 按读数选路（判据写死在这里，不留给执行者发挥）**

| 条件 | 裁定 |
|---|---|
| 做完计划 C 后缺口 **< 20px**（判定半径的一半） | ✅ **选 2：接受它** —— 实体弹游戏本就要求提前量；把读数写进 spec，不做代码 |
| 缺口 **≥ 20px** 且玩家报告"打中没伤害" | ✅ **选 3：做 Task 4**（回退命中测试） |
| 缺口 ≥ 20px 但计划 C 还没做 | ⚠️ **先做 C**（candidate 1），再回来重量 —— C 是廉价的那半 |

- [ ] **Step 2: 把裁定与依据写进 spec，提交**

```bash
git add docs/eng/netcode-at-16-players.md
git commit -m "docs(net): 命中缺口的裁定与依据(按实测定走哪条路)"
```

---

### Task 4（**条件任务：仅当 Task 3 裁定 = 选 3 时执行**）: 按射手视图时刻回退命中测试

**Files:**
- Create: `core/sim/pos_history.gd`（**纯逻辑**类：每 role 一个定长环 ⇒ `-s` 可判；★ 不要塞进 `MatchHost`——它引用 `NetBus`，`-s` 里加载不了）
- Modify: `server/match/match_state.gd` / `match_host.gd`（每物理 tick 记一次位置）
- Modify: `core/net/packet_input_source.gd`（`pack_record` 加 `"view": int` 毫秒；★ 若输入包已按另一份计划手打包，**必须同时登记进 `INPUT_SCHEMA`**）
- Modify: `server/match/match_combat.gd`（命中测试用回退位置）
- Modify: `tests/smoke/server_input_sanitize_smoke.gd`（+2 条：视图毫秒的**钳位**、历史的**越界返回最近帧**）

**Interfaces:**
- Produces:
  - `PosHistory.new(depth_ticks: int)` · `push(role: int, tick: int, pos: Vector2)` · `at(role: int, tick: int) -> Vector2`（越界返回最近帧）
  - `const VIEW_MS_MAX := 200`（回退上限；超过就钳到 200 —— 防止作弊客户端报一个巨大的 `view` 把命中盒拖到它想要的位置）

- [ ] **Step 1: 写失败的 `-s` 判据（2 条）**

① `PosHistory.at(role, tick)` 在**早于环内最老帧**时返回**最老那一帧**（不是黑帧/原点）——
去掉这条 ⇒ 长 RTT 的客户端会朝原点开枪；
② `view` 毫秒被钳在 `[0, VIEW_MS_MAX]` —— 去掉 ⇒ 伪造 `view=10000` 就能把命中盒拖回过去任意位置。

- [ ] **Step 2: 实现并接线**

服务器每 tick `push`；`match_combat` 的命中测试对**每个候选目标**用 `server_tick - view_ticks` 查历史位置，
只回退**位置**（血量/姿态/倒地用当前权威值 —— 见 Review Focus #4）。

- [ ] **Step 3: 变异验证（2 条）**

去掉回退（用当前位置）⇒ `-s` 判据仍绿但**真链路**出现"打中没伤害"回归？—— ★ 这一条**没有便宜的自动化判据**，
照实说：它的证据只能是**真链路 + 人眼**，并把它登记进 §八。

- [ ] **Step 4: 跑默认批 + 真链路 + 提交**

Run: `bash tests/run_all.sh`；`bash tests/smoke/pvp_match_smoke.sh`（先查 `lobby_alive`）
Expected: `RUN_ALL OK(13 runs / …)` / `SMOKE PASS`。
