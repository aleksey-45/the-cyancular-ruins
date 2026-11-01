# 受击事件时刻对齐（非 beta 回滚预测修缮）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> ★ **写于 2026-10-28**。**已拍板（用户，2026-10-28）**：本计划**不含 beta 时间玩法**（回溯 / 加速）；只做非 beta 的回滚预测修缮；本轮只出计划，**未开始实现**。
>
> ★ **开工前置**：`git status --short` 干净。本计划触碰**协议 / 回滚环 / 输入消费时序**（档 3），工作区里若有他人在飞改动，等其提交后再动手（逐 hunk 认领会把别人的改动带走）。
>
> ★ **执行方式未定**：写完本计划后由用户选（推荐 Subagent-driven —— 档 3 要求逐任务评审）。

**Goal:** 把"受击 / 击退"类回滚从"事件到达就应用、下一个 ack 必然判分歧"改成"按服务器真正命中的那个输入 seq 注入预测历史再重放"，消除对枪期每中一发就 restore+replay、以及本地击退曲线被权威 c2 截断的问题。事件不可安全注入时只播反馈、不改状态。

**Architecture:** 服务器广播 `hit_event` 时附上**受击方已消费的输入 seq**（与 `ack_seq` 同域 ⇒ 客户端 `_captures` 直接按它取历史）。客户端 `PredictionRollback` 新增 `apply_external_event(seq, apply)`：把玩家恢复成 `_captures[seq]` → 执行事件（`take_hit`）→ 按序重放 `(seq, last_applied]` 的未确认输入 → 刷新 `_captures`。seq 环外 / 已 ack / 乱序到达时返回 `false`，调用方只播受击反馈（白闪 / 震屏 / 音效 / 挤压），hp / 击退 / 无敌帧全部交给权威 c2。

**Tech Stack:** Godot 4.7.1 标准版（非 mono）/ GDScript / ENet。

**Spec:** 无独立 spec 文件；设计事实来自 2026-10-28 会话的回滚来源分析，以及三处必读：
- [`docs/eng/netcode-snapshots.md`](../../../eng/netcode-snapshots.md) §1.3（本人包 `ack` / `c2`）、§2.1（服务器命中回放）
- [`docs/eng/netcode-client-interp-and-input-details.md`](../../../eng/netcode-client-interp-and-input-details.md) §3（服务器每 tick 恰消费一条记录）、§4（ack）
- [`docs/eng/registered-debt.md`](../../../eng/registered-debt.md) §二十二（接触回滚：扫描结论 + 边界照实写的先例）

---

## 0. 现状（写计划时点的代码事实，行号引用前先 grep 复核）

| 事实 | 位置 |
|---|---|
| 服务器每 tick 消费一条输入记录后才步进玩家；`_ack_seq[role]` = 刚消费的 seq | `server/match/match_host.gd` `_physics_process`（消费循环） |
| 命中裁决在**本帧消费完输入、但玩家子节点步进之前**（`_adjudicate_bullets` 跑在宿主回调里；父先于子）⇒ 受击作用于 ack−1 那一步之后的状态 | `server/match/match_host.gd` / `server/match/match_combat.gd` |
| 当前 `hit_event` 三参：`(victim_role, damage, source_pos)`，**不带时刻** | `core/net/net_bus.gd` `hit_event` RPC + `local_hit_event` signal |
| 客户端收到就 `_local.take_hit(...)`（事件到达时刻），服务器是在命中 tick 应用的 | `scenes/pvp_match_client.gd::_on_hit_event` |
| `_close_enough` 只比 `down` / `hp` / `pos`(2px；贴身 8–48px) / `vel`(<20)；击退速度是几百 px/s ⇒ **必然判分歧** | `core/net/prediction_rollback.gd::_close_enough` |
| 回滚 = `restore_state(权威态)` + 重放 `(ack, last_applied]` 未确认输入（U1 后 0–2 条） | `core/net/prediction_rollback.gd::_handle_ack` |
| 客户端每个 tick 都存 `_captures[seq] = capture_state()` 与 `_inputs[seq]`；`KEEP = 256`（4.27s） | 同上 `note_post_step` / `note_input` |
| 事件锚点必须用**受击方上一条完成步进的 seq**（`_stepped_seq`，≈ack−1），不能用当帧 `_ack_seq`（晚一步）也不能用 `_srv_tick`（饥饿时与 ack 脱钩） | `server/match/match_state.gd` + `match_host.gd::_record_stepped_seq` |
| 网络回调跑在 idle 帧；物理帧外 `move_and_slide()` 按**渲染帧 delta** 缩放（实测 0.01~2px/帧不等，首帧前才是 0）⇒ 注入不能在回调里重放 | 评审实测（2026-10-28） |

**为什么能对齐：** 服务器裁决命中时，玩家状态是"用记录 S（= ack−1）步进完"的整态；客户端 `_captures[S]` 恰好是同一时刻的整态。客户端恢复 `_captures[S]`、在该点上执行 `take_hit`、再重放 S 之后的输入，得到的轨迹就与服务器同源（★ 2026-10-28 评审更正：原稿写成"步进完之后才裁决"，方向反了）。确定性由现有 C2 重放机制保证（武器 tick 已固定到物理 tick 上，见 `scenes/weapons/weapon_base.gd` 的 `_physics_process` 驱动注释）。

**为什么回退路径不能调 `take_hit`：** 权威 c2 可能已经把这一发的 hp/击退包含进去了（事件晚于 c2 到达）。此时再完整 `take_hit` 会**双计**，下一 ack 又要 restore。所以兜底只播反馈，不动任何可被 `_close_enough` 比较的字段。

---

## 1. 已拍板 / 关键设计决定

1. **范围** = 受击/击退的"事件时刻对齐" + 兜底反馈。**不含** beta（回溯/加速）、传输层冗余、拆砖事件对齐（见 §2）。
2. **事件锚点 = 受击方上一条完成步进的输入 seq**（`_stepped_seq[role]`，≈`_ack_seq−1`），不是当帧 ack、不是服务器 tick、也不是"当前快照 tick"。★ 2026-10-28 评审更正：初稿写的是 `_ack_seq[victim]`，实测晚一步（差 3.03px / 43.4px·s⁻¹，仍回滚）。理由见 §0。
3. **不可注入即只播反馈**：`seq > _last_applied` / `seq <= _acked` / `_captures` 里没有该 seq / 乱序（`seq < 上次已对齐事件的 seq`）⇒ 客户端不扣血、不给击退、不设无敌帧，只播白闪 / 震屏 / 音效 / 挤压，其余交给权威 c2。
4. **不改通道号、不改传输模式**：`hit_event` 仍在用户通道 3、reliable；**不升 `PROTO_VERSION`**（该常量只管 `NetCodec` 线格式；RPC 参数属于 Godot 序列化，两端同源构建，参数不符会当场报错）。
5. **本批不新建 `.gd` 文件**（测试全部加进既有 `rollback_fidelity_probe`）⇒ `allscript_probe.EXPECTED_SCRIPTS` 不变（当前 190）。
6. **不新写一条独立的"事件重放"路径**：注入用现有 `_step()`，与 `_handle_ack` 的重放完全同一条代码路径。

---

## Global Constraints

- **档 3**（协议 / 回滚 / 输入时序）：每条承重断言做**变异验证**（删什么它才红）+ **真链路跑批** + **逐任务评审**。
- **判据一律 grep 判词文本**，退出码从来不是判据：`ROLLBACK FIDELITY PROBE: ALL-OK` / `RUN_ALL OK(...)` / `SOAK: ALL-OK`。
- **新断言自带条数闸**：本批加进 `rollback_fidelity_probe.gd` 的每组断言都用既有的 `_require_ran("<组名>")` 完成戳（中途报错 ⇒ 缺戳 ⇒ 红），不要只靠 `_check`。
- **跑测试先问用户**；任何占 **7777** 的步骤先查 `lobby_alive`；真链路跑批**前后**本线 Godot 进程必须为 0；时序类结论**同配置跑两次**；非 headless 步骤跑前告知。
- **逐个文件 `git add`**，绝不 `git add -A`；新建 `.gd` 连 `.gd.uid` 一起加；提交信息 `type(scope): 中文一句话`；**不推送**。
- 每次提交前 `python tools/check_naming.py`；`.ps1/.bat` 的 CRLF 规则不涉及本批。
- **注释额度**：>100 行的 `.gd` 注释 ≤15%（`docs/eng/comment-style.md`）；本批新增注释只写"为什么 + 边界"，不写逐行复述。
- **共用工作树**：提交前 `git status --short` + 逐文件 `git diff` 认领每个 hunk。
- **单一真相源**：`seq` 只在服务端产生一次；客户端只透传，不重新推导。
- **文档同步**：改协议就同步 `docs/pvp-networking.md` §10；新增边界写进 `docs/eng/registered-debt.md`。

## Review Focus

以下五类输入/失败形态是本设计最容易被写错的点，分别由对应任务的断言钉住：

1. **事件 seq 不可注入**（环外 / 已 ack / 掉线重连后残留）：必须走反馈-only，**不能**本地扣血或给击退 —— 否则 hp 双计，下一 ack 再回滚一次。→ Task 2 断言②、Task 4 源码守卫。
2. **同一 tick 多次受击**（两发子弹同 tick / 爆炸+直击）：第二次必须基于**刷新后的** `_captures[seq]` 叠上去，不能丢第一次。→ Task 2 断言③。
3. **事件乱序**（reliable 保序假设被破坏）：必须拒绝注入并回退，不能静默丢事件。→ Task 2 断言④。
4. **注入刷新 `_captures` 后同一帧的 reconcile**：注入不能把回滚计数算进去，也不能让随后的权威 ack 误判。→ Task 2 断言①⑤（`rollback_count()` 必须不变）。
5. **反馈时机与重复**：白闪 / 震屏 / 音效在事件到达当帧播放**一次**；反馈-only 路径不得再触发 `took_hit` 的统计/连锁消费者。→ Task 3 断言（`took_hit` 不 emit）+ Task 4 人眼验收。

---

### Task 1: `hit_event` 追加受击方已消费 seq（协议）

**Files:**
- Modify: `server/match/match_combat.gd`（`_on_player_hit`：广播前取 `_ack_seq` 并加参数）
- Modify: `core/net/net_bus.gd`（`local_hit_event` signal + `hit_event` RPC 增加第 4 参）
- Modify: `scenes/pvp_match_client.gd`（`_on_hit_event` 签名加 `seq`，**行为不变**）
- Modify: `tests/probe/royale_soak_probe.gd`（受击回调改 4 参，`_mark` 里带 seq）
- Modify: `docs/pvp-networking.md` §10 协议汇总表（`hit_event` 字段）

**Interfaces:**
- Consumes: `MatchState._ack_seq: Dictionary`（role → 已消费输入的 seq），由 `server/match/match_host.gd` 消费循环维护；`MatchCombat` 经 `MatchSnapshot extends MatchState` 直接可读。
- Produces:
  - `net_bus.hit_event(victim_role: int, damage: int, source_pos: Vector2, seq: int) -> void`（RPC，reliable 通道 3）
  - `NetBus.local_hit_event(victim_role: int, damage: int, source_pos: Vector2, seq: int)`（signal）
  - `PvpMatchClient._on_hit_event(victim_role: int, damage: int, source_pos: Vector2, seq: int) -> void`

- [ ] **Step 1: 服务端取锚点并广播**

`server/match/match_combat.gd::_on_player_hit`：在 `for r in peer_by_role:` 广播循环**之前**加一行，并把 rpc 调用改成 4 参：

```gdscript
var seq := int(_ack_seq.get(int(role), 0))
NetBus.rpc_id(peer_by_role[r], "hit_event", role, damage, source_pos, seq)
```

注释写明：`seq` = 受击方**已消费输入记录的 seq**（不是服务器 tick）；理由（饥饿时两者会漂）一句话带过。

- [ ] **Step 2: NetBus 信号 + RPC 加参**

`core/net/net_bus.gd`：

```gdscript
signal local_hit_event(victim_role: int, damage: int, source_pos: Vector2, seq: int)

@rpc("authority", "call_remote", "reliable", 3)
func hit_event(victim_role: int, damage: int, source_pos: Vector2, seq: int) -> void:
	local_hit_event.emit(victim_role, damage, source_pos, seq)
```

★ 通道号/传输模式一个字都不改。

- [ ] **Step 3: 客户端签名跟上（行为仍为旧路径）**

`scenes/pvp_match_client.gd::_on_hit_event` 加第 4 参 `seq: int`；本任务内仍执行原来的 `_local.take_hit(...)`，并加一行 `# seq 从 Task 4 起用于事件时刻对齐`。三个子类（`pvp_game.gd` / `royale_game.gd` / `team_game.gd`）都连到基类这个方法，**不需要改**。

- [ ] **Step 4: 更新探针与文档**

- `tests/probe/royale_soak_probe.gd`：受击回调改 4 参，`_mark` 文本加 `seq=%d`。
- `docs/pvp-networking.md` §10 表：`hit_event` 行改为 `victim_role / damage / source_pos / seq`（seq = 受击方已消费输入 seq）。

- [ ] **Step 5: 真链路验证（需用户认领）**

命令（先 `lobby_alive` 为假、本线无 Godot 进程；**跑前问用户**）：

```bash
bash tests/run_real.sh --only soak --yes
```

预期：判词 `SOAK: ALL-OK`；`tests/.run_real_logs/royale_soak_probe.log` 里出现 `受击` 行且带 `seq=`；**没有** `Invalid call` / `Error calling from signal` / `Too many arguments` 一类运行期错误。若整段窗口一次 `受击` 都没有 ⇒ 该次读数**不结论**（同配置再跑一次），照实写进报告。

- [ ] **Step 6: 提交**

```bash
git add server/match/match_combat.gd core/net/net_bus.gd scenes/pvp_match_client.gd tests/probe/royale_soak_probe.gd docs/pvp-networking.md
git commit -m "feat(net): hit_event 携带受击方已消费输入 seq"
```

**此任务没有自动化守卫**（真链路 soak 只证明不炸；命中不可确定性构造）——覆盖缺口在 Task 4 Step 6 登记。理由：参数不符是**响亮**失败（运行期报错），不是静默形态。

---

### Task 2: `PredictionRollback.apply_external_event(seq, apply)`

**Files:**
- Modify: `core/net/prediction_rollback.gd`
- Test: `tests/probe/rollback_fidelity_probe.gd`（新增 D 组；`.tscn` 不变）

**Interfaces:**
- Produces:
  ```gdscript
  ## 把一次服务器外部事件（受击）注入预测历史：恢复 _captures[seq] → apply() → 重放 (seq, last_applied]。
  ## 返回 true = 已按历史对齐（调用方不要再应用一次）；false = 不能安全注入（过旧/来自未来/已 ack/乱序），调用方走兜底。
  func apply_external_event(seq: int, apply: Callable) -> bool
  ```
- 内部新增两个字段：`_last_event_seq: int = 0`（已对齐事件的最大 seq，用于乱序拒绝）、`_event_aligns: int = 0`（诊断计数，可暂不暴露）。

- [ ] **Step 1: 写失败测试（D 组）**

在 `tests/probe/rollback_fidelity_probe.gd` 加 `_test_event_alignment()`，`_ready()` 里调用并 `_require_ran("event_align")`。夹具复用 C 组手法（真 `player.tscn` + `PredictionRollback` + 20~30 条固定输入记录 `{ax: 1.0, held: 0, ...}`）。

断言（断言文本自己起名，用 `[fid]` 前缀）：

1. **主判据 / 黄金对照**：造两份夹具 c1（先 `advance` 30 次，再 `apply_external_event(20, func(): p1.take_hit(p1.global_position, 10, true))`）与 c2（`advance` 20 次 → `p2.take_hit(p2.global_position, 10, true)` → 继续 `advance` 10 次）。断言：
   - `apply_external_event` 返回 `true`；
   - `c1.rollback_count()` 在调用前后**不变**；
   - `c1._captures[30].hp == c2._captures[30].hp`（精确）；
   - `c1._captures[30].pos.distance_to(c2._captures[30].pos) < 0.01`、`vel` 同容差（`restore_state` 的 0.001px 触地重判可能带来极小差）。
2. **越界拒绝**：`apply_external_event(31, ...)`（未来）返回 `false`；先 `on_authoritative(25, c._captures[25])` + `reconcile()` 把 `_acked` 推到 25，再 `apply_external_event(25, ...)` 返回 `false`；两种情况玩家整态不变。
3. **同 seq 两次事件**：同一 seq=20 连续注入两次 10 伤 ⇒ `hp == max_hp - 20`（第二次基于刷新后的 `_captures[20]`）。
4. **乱序拒绝**：先注入 seq=20，再注入 seq=19 ⇒ 返回 `false`。
5. **注入后紧接 reconcile**：注入完成后把 `c1._captures[30]` 当权威喂 `on_authoritative(30, ...)` + `reconcile()` ⇒ `rollback_count()` 不变（证明刷新后的捕获与"注入→重放"结果自洽，不会同一帧自打脸）。
6. 完成戳 `_ran["event_align"] = true` 放函数最后一行。

- [ ] **Step 2: 跑探针确认红**

```bash
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/rollback_fidelity_probe.tscn
```

预期：`apply_external_event` 未定义 ⇒ 报错 ⇒ `event_align` 缺完成戳 ⇒ `ROLLBACK FIDELITY PROBE: FAIL`。

- [ ] **Step 3: 实现 API**

`core/net/prediction_rollback.gd`：按 Interfaces 的语义实现；`_step()` / `restore_state()` / `_seqs` / `_inputs` / `_captures` 全部复用现成机制。判定顺序固定为：`_p == null` → `seq > _last_applied` → `seq <= _acked` → `not _captures.has(seq)` → `seq < _last_event_seq`，任一成立返回 `false`。成功路径：

```gdscript
_p.restore_state(_captures[seq])
apply.call()
_captures[seq] = _p.capture_state()
for s in _seqs:
	if s > seq and s <= _last_applied:
		var rec: Dictionary = _inputs.get(s, {})
		if rec.is_empty():
			continue
		_step(rec)
		_captures[s] = _p.capture_state()
_last_event_seq = seq
_event_aligns += 1
return true
```

注释必须写清两条边界：① 事件必须按 seq 递增到达（reliable 保序）；乱序返回 `false`，调用方兜底；② 本 API 不碰 `_rollbacks` 计数（事件对齐不是"预测被证伪"）。

- [ ] **Step 4: 跑探针确认绿**

同一命令，预期 `ROLLBACK FIDELITY PROBE: ALL-OK`。

- [ ] **Step 5: 变异验证（档 3，逐条）**

- 删 `_p.restore_state(_captures[seq])`（改成直接 `apply`）⇒ 断言①（黄金对照）必红；
- 删重放循环 ⇒ 断言①必红；
- 删 `seq <= _acked` 判断 ⇒ 断言②必红；
- 删 `seq < _last_event_seq` 判断 ⇒ 断言④必红；
- 不刷新 `_captures[seq]` 及其后（只在末尾重放不写回）⇒ 断言③⑤必红。
每次只改一处、验完复原，报告写"红在哪条断言"。

- [ ] **Step 6: 跑默认批**

```bash
bash tests/run_all.sh --only rollback
```

预期 `RUN_ALL OK(1 runs / ...)`（条数按输出照抄）。

- [ ] **Step 7: 提交**

```bash
git add core/net/prediction_rollback.gd tests/probe/rollback_fidelity_probe.gd
git commit -m "feat(net): PredictionRollback 支持按事件 tick 注入并重放"
```

---

### Task 3: `take_hit(..., feedback_only)` 只播反馈

**Files:**
- Modify: `scenes/player/combat_component.gd`（`take_hit` 加第 5 参 + 把反馈段抽成 `play_hit_feedback`）
- Modify: `scenes/player/player.gd`（`take_hit` 转发第 5 参；feedback-only 时补挤压，不碰 hp/击退/took_hit）
- Test: `tests/probe/rollback_fidelity_probe.gd`（同一 D 组内追加，或新 E 组 + `_require_ran("feedback_only")`）

**Interfaces:**
- Produces:
  - `CombatComponent.take_hit(source_pos: Vector2, damage: int, ignore_iframes: bool = false, knockback: float = -1.0, feedback_only: bool = false) -> void`
  - `CombatComponent.play_hit_feedback(source_pos: Vector2, damage: int) -> void`（把 Sfx / 红闪 / 震屏从 `take_hit` 里原样搬出；`take_hit` 自己仍调用它 ⇒ 正常路径行为逐字不变）
  - `Player.take_hit(source_pos: Vector2, damage: int, ignore_iframes: bool = false, knockback: float = -1.0, feedback_only: bool = false) -> void`

- [ ] **Step 1: 写失败测试**

探针 D/E 组追加：
- `p.take_hit(p.global_position, 10, false, -1.0, true)` ⇒ `p.combat.hp` 不变、`p.velocity` 不变、`p.combat.took_hit` 信号**不**触发（接一个计数器），`p.combat.iframes` 不变；
- 随后正常 `p.take_hit(p.global_position, 10)` ⇒ hp 减 10 且 `took_hit` 触发一次（证明 ① 不是恒真断言）。

- [ ] **Step 2: 跑探针确认红**

同 Task 2 Step 2 命令；预期第 5 参不存在 ⇒ 运行期报错 ⇒ 该组缺完成戳 ⇒ FAIL。

- [ ] **Step 3: 实现**

`combat_component.gd`：`feedback_only` 分支放在 `downed` 早退之后、扣血之前：`play_hit_feedback(source_pos, damage); return`。`play_hit_feedback` 内容 = 现在 `take_hit` 里的 `Sfx.play("hurt")` + post-process `flash_hit` + `cam.shake` 三段，**原样搬移**（正常路径的调用点时序不变）。
`player.gd`：转发 `feedback_only`；为 `true` 时走 `combat.take_hit(..., true)` + `squash.impulse(HURT)` 后 `return`，不进入 hp / 击退 / 无敌帧 / `took_hit` 那段。

- [ ] **Step 4: 跑探针确认绿**

同 Task 2 Step 2 命令，预期 `ROLLBACK FIDELITY PROBE: ALL-OK`。

- [ ] **Step 5: 变异验证（档 3）**

- 删 `feedback_only` 早退 ⇒ 断言①（hp 不变）必红；
- 把正常路径的 `play_hit_feedback` 调用删掉 ⇒ 单机受击反馈消失（本批无自动断言，靠人眼；在注释里登记为"测不到"）。

- [ ] **Step 6: 提交**

```bash
git add scenes/player/combat_component.gd scenes/player/player.gd tests/probe/rollback_fidelity_probe.gd
git commit -m "feat(player): take_hit 支持只播受击反馈"
```

---

### Task 4: 客户端接入事件时刻对齐

**Files:**
- Modify: `scenes/pvp_match_client.gd`（`_on_hit_event` → 新私有方法 `_apply_local_hit_event`）
- Modify: `tests/probe/rollback_fidelity_probe.gd`（源码守卫：接线 + 兜底形态）
- Modify: `docs/eng/netcode-snapshots.md` §2.1（补一段"受击事件时刻对齐"）
- Modify: `docs/eng/registered-debt.md`（新增一节：本批边界）

**Interfaces:**
- Consumes: Task 1 的 `seq`（`_on_hit_event` 第 4 参）、Task 2 的 `apply_external_event`、Task 3 的 `feedback_only`。
- Produces: `PvpMatchClient._apply_local_hit_event(source_pos: Vector2, damage: int, seq: int) -> void`。

- [ ] **Step 1: 实现接线**

```gdscript
func _apply_local_hit_event(source_pos: Vector2, damage: int, seq: int) -> void:
	if _rollback != null and _rollback.apply_external_event(seq, func() -> void:
			_local.take_hit(source_pos, damage, false, -1.0)):
		return
	# 兜底：权威态可能已包含这一发 ⇒ 只播反馈，绝不二次扣血/击退。
	_local.take_hit(source_pos, damage, false, -1.0, true)
```

`_on_hit_event` 的本人分支只剩一行 `_apply_local_hit_event(source_pos, damage, seq)`；非本人分支（副本 `play_hit`）不动。

- [ ] **Step 2: 源码守卫（沿用既有 `_check_source_guard` 手法）**

在 `rollback_fidelity_probe.gd` 里加三条（写法参考现有 `in_contact` 接线守卫：按 `func ` 切块、跳过整行注释、只认代码行）：

1. `pvp_match_client.gd` 全文 `apply_external_event(` 只出现 **1 处**，且位于 `func _apply_local_hit_event(` 的块内；
2. 同一块内含 `feedback_only` 兜底形态（即 `_local.take_hit(` 那次调用带第 5 参 `true`）；
3. `_on_hit_event` 块内 `_apply_local_hit_event(` 只出现 1 处（本人分支），防止有人把两个分支合并写错。

守卫注释写明："删掉注入 = 静默退回旧行为（不报错、回滚变多），所以只能靠源码守卫。"

- [ ] **Step 3: 跑探针确认绿**

同 Task 2 Step 2 命令，预期 `ROLLBACK FIDELITY PROBE: ALL-OK`。

- [ ] **Step 4: 变异验证（档 3，三条）**

- 删 `apply_external_event` 调用 ⇒ 守卫①红；
- 兜底改回 `_local.take_hit(source_pos, damage, false, -1.0)`（去掉 feedback_only）⇒ 守卫②红；
- 把 `_on_hit_event` 的本人分支改成直接 `take_hit` ⇒ 守卫③红。

- [ ] **Step 5: 真链路 + 人眼验收（需用户认领）**

```bash
bash tests/run_real.sh --only soak --yes        # 判据 SOAK: ALL-OK
```

人眼（非 headless，跑前告知）：1v1 对枪 5 分钟，验收三条 —— ① 中弹时白闪/震屏**立刻**有；② 击退方向与幅度和服务器一致（不再出现"被拉直/弹一下又回去"）；③ `-- --netstat` 的 `回滚累计 (+N/s)` 在对枪期明显低于改前（**动手前**先按同一方法记一份基线，不靠记忆）。

- [ ] **Step 6: 登记文档与边界**

- `docs/eng/netcode-snapshots.md` §2.1 追加：`hit_event` 带受击方 seq；客户端按 seq 注入再重放；不可注入时只播反馈。
- `docs/eng/registered-debt.md` 新增一节（照实）：
  1. 本批**没有**自动化真链路命中守卫（soak 只证明不炸，命中不可确定性构造）⇒ 改 `hit_event` 参数只靠人眼与日志；
  2. 服务器输入饥饿时 `_ack_seq` 不前进，事件 seq 会"指向上一 tick"⇒ 注入会差 1 tick，方向偏保守（照实写的近似）；
  3. **落水窒息伤害是客户端已预测的伤害** ⇒ **2026-10-29 已修**：`cause="water"` 透传到服务端,`_on_player_hit` 跳过回声（见 registered-debt §二十三 #3）；
  4. `_captures` 环 256 tick（4.3s）：ping/重传导致事件超出环时只能走兜底（不扣血），观感上该次受击没有本地击退。

- [ ] **Step 7: 全量收口**

```bash
"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/rollback_fidelity_probe.tscn   # ROLLBACK FIDELITY PROBE: ALL-OK
bash tests/run_all.sh --only rollback                                                          # RUN_ALL OK(...)
python tools/check_naming.py
```

- [ ] **Step 8: 提交**

```bash
git add scenes/pvp_match_client.gd tests/probe/rollback_fidelity_probe.gd docs/eng/netcode-snapshots.md docs/eng/registered-debt.md
git commit -m "feat(pvp): 受击效果按服务器命中 tick 回放"
```

---

## 2. 本计划不覆盖（照实登记，别顺手做）

| 项 | 为什么不在本计划 | 去向 |
|---|---|---|
| **beta 时间玩法**（回溯期位置、加速开关时刻、颗粒镜像） | 用户 2026-10-28 明确排除 | 另立计划 |
| **输入冗余 + 输入通道改 unreliable** | 独立的传输层子系统（协议 + 队列 + 去重 + 丢包注入），与本批无共享代码；LAN 收益 0，公网才有 | 另立计划（档 3） |
| **拆砖 `tile_destroyed` 事件时刻对齐** | 需要客户端保留"碰撞世界历史"（`capture_state` 不含瓦片），且"脚下砖被拆"频次极低 | 暂缓；先登记 |
| **接触外推 horizon 精度**（用快照到达时刻替代 RTT/2） | 收益低（动态容差已消化 ~95%），且碰调优过的接触面（registered-debt §二十二） | 暂缓 |
| **落水窒息双重应用**（客户端已预测的伤害被 `hit_event` 再应用一次） | 本计划排除了它，但用户 2026-10-29 要求先修 ⇒ 已补做：`take_hit/took_hit` 加 `cause`、溺水标 `water`、服务端跳过回声（registered-debt §二十三 #3） | ✅ 已修（2026-10-29） |
| **拾取/切枪/残弹预测、对手位置更强外推、本地命中裁决** | 服务器权威面/防作弊面；现有 `sync_soft_state` 与 lag comp 已覆盖 | 不做 |

## 3. 验收总表（判据一律 grep 文本）

| 任务 | 命令 | 判词 / 读数 |
|---|---|---|
| T1 | `bash tests/run_real.sh --only soak --yes`（需认领） | `SOAK: ALL-OK` + 日志有 `受击 … seq=` + 无 RPC 参数错误 |
| T2 | `"$GODOT" --headless --path . --quit-after 3600 res://tests/probe/rollback_fidelity_probe.tscn` | `ROLLBACK FIDELITY PROBE: ALL-OK` |
| T2 | 变异五处（Step 5） | 每条指定断言红（报告写红在哪条） |
| T3 | 同上探针 | `ROLLBACK FIDELITY PROBE: ALL-OK` + 变异必红 |
| T4 | 探针 + `bash tests/run_all.sh --only rollback` | `ROLLBACK FIDELITY PROBE: ALL-OK` / `RUN_ALL OK(...)` |
| T4 | 真链路 soak + 人眼 1v1 | `SOAK: ALL-OK` + 三条人眼结论 + `--netstat` 回滚计数对比 |
| 全部 | `python tools/check_naming.py` | 检查器自己的 OK 文本 |

## 4. 执行顺序

T1 → T2 → T3 → T4。T1 只动协议面，可与 T2 并行；**T2 与 T3 都改同一个探针文件（`rollback_fidelity_probe.gd`）⇒ 必须串行**（共用工作树，同文件并发编辑会互相覆盖）；T4 同时吃三者。**档 3 要求逐任务评审**：每个 Task 的「确认绿 + 变异验证」通过、评审签字后再进下一个；T4 完成后做一次整体评审（协议、回滚环、文档三处对照）。
