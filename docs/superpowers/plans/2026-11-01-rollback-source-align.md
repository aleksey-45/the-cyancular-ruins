# 回滚源头治理 Plan（时间线/事件/本地状态对齐）

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> ★ **写于 2026-11-01**。只出计划，**未开始实现**；用户已明确「每个任务先给猜测/证据，再跑测试」。
>
> ★ **开工前置**：`git status --short` 干净；`python tools/check_naming.py` 绿。本轮触碰**回滚环 / 预测状态 / 事件时刻**（档 3），工作区若有他人在飞改动，等其提交后再动手（逐 hunk 认领）。

**Goal:** 把「代码层面可以消掉的回滚」逐个从源头消掉：不再让客户端/服务器在同一 tick、同一输入下算出不同结果。目标不是「零回滚」（网络抖动/迟到包/服务器少 tick 天然会触发一次），而是**消灭“持续/每帧”回滚**，并把剩余回滚压到“与网络状况同阶”。

**Architecture:** 三条主线，全部围绕「两端用同一份状态 + 同一份事件时间线」：
1. **本地独有状态清零**：凡影响 `_physics_process` 结果、又不在 `capture_state()` 里的字段，一律删掉或进整态；
2. **事件按 tick/seq 对齐**：命中已有 `apply_external_event(seq)` 先例；拆砖/拾取/换武器目前是“到达即应用”，要与服务器 tick 对齐；
3. **权威态应用单一实现**：单机 `Player.rewind_restore` / 服务器 `match_host` 的回溯恢复 / 客户端 `restore_state` 现在是三份复制，合并成一份（差异用参数表达）。

**Tech Stack:** Godot 4.7.1 标准版（非 GDExtension）/ GDScript / ENet。

**Spec / 必读：**
- [`docs/eng/netcode-snapshots.md`](../../eng/netcode-snapshots.md)（`ack`/`c2`/整态）
- [`core/net/prediction_rollback.gd`](../../../core/net/prediction_rollback.gd)（`_close_enough` / `_handle_ack` / `apply_external_event`）
- [`server/match/match_combat.gd`](../../../server/match/match_combat.gd)（命中回放与 `_stepped_seq`）
- [`docs/superpowers/plans/2026-10-28-hit-event-align.md`](./2026-10-28-hit-event-align.md)（**已落地**的事件 seq 对齐先例，本计划照它的形状做拆砖）
- [`docs/eng/registered-debt.md`](../../eng/registered-debt.md) §四十九（`_auto_jump_assist` 本地表现量当时被“文档化”成边界，本计划把它改回源头解决）

---

## 0. 现状事实（写计划时点，行号引用前先 grep 复核）

| 事实 | 位置 |
|---|---|
| 回滚 = `restore_state(权威 c2)` + 重放 `(ack, last_applied]`；`_close_enough` 比 pos/vel/hp/down | `core/net/prediction_rollback.gd::_handle_ack` / `_close_enough` |
| `_auto_jump_assist` 只在「有横向输入 + 空中」分支递减；**站在地上永不衰减**；且不在 `capture_state()` | `scenes/player/player.gd`（grep `_auto_jump_assist`） |
| 拆砖在客户端**到达即应用**：`TileSync.on_cell/on_sub` 直接改 `MazeGenerator.current_subgrid` / `TileDefs` / 碰撞 | `scenes/mp_client/tile_sync.gd` |
| 单机已有“按时间回放地形”的机器：`TileLedger`（拆砖账本）+ `WorldRewind`（世界快照/回放），PvP 不建 | `scenes/level_0.gd`（`_tile_ledger` / `_rewind`） |
| 权威态应用有三份：单机 `Player.rewind_restore`、服务器 `match_host` 回溯恢复、客户端 `Player.restore_state` | 三处 grep `rewind_restore` / `restore_state` |
| 服务器输入队列溢出 = 丢最旧一条（真丢一个 tick 的输入） | `core/net/packet_input_source.gd::push_pending` |
| 回滚计数可观测：`PredictionRollback.rollback_count()`；`--diag` 会记 `rollback` 事件 | `core/net/prediction_rollback.gd` / `core/net/net_diag.gd` |

**为什么这套能消掉“持续回滚”：** 持续回滚的形态是「每次 ack 都判分歧」——只可能来自「重放用的状态/世界与预测时不同」。上面三类源头（本地独有状态、事件时刻、三份实现漂移）都会制造这个形态；网络抖动型回滚是偶发的，不在此列。

---

## 1. 已拍板 / 关键设计决定

1. **范围** = 非 beta 的 1v1/对抗/大乱斗回滚源头；**不含** beta 时间玩法（回溯/加速）、不含传输层冗余策略的最终选型（只做测量与最小改动）。
2. **不新增线格式字段**（`PROTO_VERSION` 不动）：`_auto_jump_assist` 走“删除”而不是“加进 c2”；拆砖对齐优先用**服务器已有的 tick/seq 域**，不新造时钟。
3. **每个任务都先给“猜测 + 证据”，再动手、再跑测试**（用户明确要求）。
4. **守卫按档位**：本轮触碰回滚环（档 3）⇒ 每条承重断言做变异验证 + 真链路跑批 + 逐任务评审；纯性能项按档 2。
5. **不碰** beta 时间玩法、不碰房间/端口/版本号、不顺手重构无关文件。

---

## Global Constraints

- 判据一律 **grep 判词文本**（`ROLLBACK FIDELITY PROBE: ALL-OK` / `ALLSCRIPT: OK(...)` / `RUN_ALL OK(...)` / `SOAK: ALL-OK`），退出码不是判据。
- 新断言必须自带**条数闸**（`EXPECTED_CHECKS` / `_require_ran`），否则 `ALL-OK` 只等于“没有失败输出”。
- 跑测试先问用户；任何占 **7777** 的步骤先查 `lobby_alive`；真链路跑批前后本线 Godot 进程必须为 0；时序类结论**同配置跑两次**。
- 逐个文件 `git add`（新 `.gd` 连 `.gd.uid`），绝不 `git add -A`；提交信息 `type(scope): 中文一句话`；**推送先问用户**（本机公网不稳，2026-11-01 曾连续 3 次 push 失败）。
- 每次提交前 `python tools/check_naming.py`；注释额度按 `docs/eng/comment-style.md`。
- 每次任务收尾：更新 `docs/eng/registered-debt.md` 的对应小节 + `tests/README.md` 的计数口径（若新增/删除支）。

---

## 任务

### R0a · 公网实测基线（已完成，2026-11-01，第一版代码）

**方法（可复现）：** `git worktree` 检出 `ce092f9b`（= 构建 `RoF_v0.5.3_202611011137` 的源码）→ 探针
`tests/probe/cloud_rollback_probe.tscn`（**只在 worktree 里，未入库**）连公网大厅 `120.53.107.140`：
create 建房 → join 加入 → 房主自动 `pvp_start` → 两端实例化**真实客户端** `pvp_game`（本地预测 + `PredictionRollback`）。
输入注入 `PacketInputSource`：`ax` 恒 0（**不按方向键 ⇒ 自动跳跃/迈台阶不可能触发**）+ 周期开火 + 可选原地跳。

**读数（1v1，60s/局；每端 `rollback_count()`）：**

| 场景 | A（房主） | B | 失败字段 |
|---|---|---|---|
| 站桩开火 · 第 1 局 | 4 | 20 | 未采集 |
| 站桩开火 · 第 2 局 | 4 | 2 | `vel` 全占 |
| 站桩开火 + 原地跳 · 第 1 局 | 1 | 1 | `vel` |
| 站桩开火 + 原地跳 · 第 2 局 | 0 | 1 | `vel` |
| 站桩开火 + 原地跳 + **被打中**（45s） | 3 | 9 | `pos` / `hp` / `down` |

**结论（据此修正本计划的后继假设）：**
1. 排除自动跳跃后**没有持续回滚**：量级 0~20 次/分钟/端，两局波动大 ⇒ 网络抖动/丢 tick 型，不是结构性预测错误。
2. `vel`-only 分歧（站桩/跳）与 `hp`/`down` 分歧（挨打）要**分开看**：
   - `hp`/`down` = 受击不可预测、服务器权威纠正，**设计内行为，不算要消灭的回滚**；
   - `pos`（跳/落地）量级 0~4/局，属跳落那一 tick 的容差问题；
   - `vel` = 最可能的残余源头是**服务器输入队列丢 tick / ack 与预测 tick 错位**（R4），待 `--diag` 验证。
3. 因此后续“回滚率”**必须分类统计**（movement / combat / unknown），目标只针对 movement 类。

### R0 · 基线测量（不改产品代码）

**状态：** 第一版公网基线见 §R0a（已完成）；本任务剩余“当前版本对照 + `--diag` 事件级验证”，拆到 R0b / R0c。


**猜测：** 当前“上楼梯”场景的持续回滚主要来自 R1（本地独有状态）与 R2（拆砖时刻）；1v1 平地对枪主要是正常网络抖动型回滚。

**做什么：**
- [ ] 在 `--diag` 下跑一局 1v1（真链路），记录 `rollback` 事件频率；再跑一局“沿台阶上下 + 打穿掩体”的场景（manual 或探针驱动），记录频率。
- [ ] 记录同配置两次（噪声/信号）；把两组数字写进本计划的 §2 结果表。
- [ ] 确认 `rollback_count()` 与 diag 事件计数对得上（避免两个口径）。

**验收：** 两行基线数字（场景 / rollback每局 / 每分钟），写进计划文件；不改代码。

**不做：** 不为了让数字好看而先改代码。

---

### R0b · 当前版本对照（同探针）

**要回答：** 上面那些非自动跳跃回滚，在当前版本（含 `a46f0323..83fe9487` 的修复）里变好/持平/变差？

**做什么：**
- [ ] 用同一探针、同场景（站桩开火 / 原地跳 / 挨打）跑**当前版本**（另建 worktree），各两次。
- [ ] 把数字并进 §R0a 的表（新增一列或一张表），标注 build 与日期。
- [ ] 结论写进本计划；**不允许**只报好看的场景。

### R0c · `--diag` 事件级验证（验证/否定 R4 假设）

**要回答：** `vel`-only 分歧是不是“服务器丢 tick / ack 错位”造成的？

**做什么：**
- [ ] 探针加 `--diag`：记录每条 `rollback` 事件的 `field` / `pos_err` /（若载荷有）`vel_err`，以及服务器侧 `queue_drop` 计数（探针读不到服务器日志 ⇒ 用 `CYR_LOG_DIR` 收集服务器 diag，或在探针里统计 `ack` 跳变）。
- [ ] 若“每次 `vel` 分歧前 1~2 tick 内出现过 ack 跳变/丢包”占比高 ⇒ 确认 R4；否则重新标定（比如受击事件时序）。
- [ ] 把逐字读数写进本计划。

### R1 · 删除 `_auto_jump_assist`（P0，源头清零）

**猜测（已由代码确认）：** 它只在「有横向输入 + 空中」递减 ⇒ 站在地上永不衰减；且不在 `capture_state()` ⇒ 回滚重放时该值与原预测不同 ⇒ 横移速度不同 ⇒ 再回滚。上台阶/自动跳反复触发它，所以是“疯狂回滚”的最强候选。

**做什么：**
- [ ] `scenes/player/player.gd`：删掉 `_auto_jump_assist` 字段、`AUTO_JUMP_ASSIST_S` 常量、`_tick_horizontal` 里的强制满速分支、`_try_step_or_jump` 里的两处赋值。
- [ ] 保留「起跳/迈台阶瞬间把 `velocity.x` 拉满」（`velocity` 本来就在整态里），不改任何其它手感参数。
- [ ] 给 `tests/probe/stair_climb_probe.tscn` 加**回放确定性**断言（新 `EXPECTED_CHECKS`）：
  跑到第 K 帧 capture → 继续 30 帧记轨迹 → `restore_state(capture)` → 用同样输入重放 30 帧 → 轨迹**逐帧一致**（pos/vel 精确相等）。
- [ ] 变异验证：把 assist 的“空中强制满速”加回去（或在删之前先跑）⇒ 该断言红；还原 ⇒ 绿。把红绿原文写进报告。

**验收：** `KH stair_climb PROBE: ALL-OK`；变异红/绿原文；R0 场景的回滚频率前后对比（同配置两次）。

**边界（照实）：** 48/64px 大台阶起跳时若贴墙，横移会被物理吃掉一点（两端一致的物理，不会回滚）；手感只能试玩。

---

### R2 · 拆砖事件按服务器 tick/seq 对齐（P1，收益最大）

**猜测：** 客户端收到拆砖事件就改地形，回滚重放用“更新后的地形”⇒ 重放结果 ≠ 原预测 ⇒ 在刚打穿的砖附近反复回滚（尤其楼梯/掩体）。

**两个候选方案（先写设计再选一个）：**
- **方案 A（小、先上）**：事件到达时把**预测环的 capture 清到事件锚点之后**，并让下一次 ack 走“权威锚定”而不是重放旧输入。
  实现点：`PredictionRollback` 加 `drop_before(seq)`；`TileSync` 拿到事件带的服务器 tick/seq（需服务器补字段）后调用。
  代价：事件到达那一下会接受一次“小橡皮筋”（≤ playout），但不会形成循环。
- **方案 B（正确、后做）**：复用单机 `TileLedger`：PvP 客户端也记“每 tick 的地形变更账本”，回滚重放前把地形回退到该 capture 的 tick，回放后前滚。
  代价：要定义 PvP 的“tick↔事件”映射与内存上限；单机的 `WorldRewind` 依赖 `TimeField`，必须做适配层，不能把时间玩法语义带进来。

**做什么：**
- [ ] 先写 §设计附录（两方案的影响面、字段、失败形态），用户拍板选 A 或 B。
- [ ] 服务器：拆砖广播补“服务器 tick/seq”（只加载荷字段，不改通道、不升 PROTO_VERSION；两端同 build）。
- [ ] 客户端：按选中方案实现；`TileSync` 不直接改地形的地方要抽成“按 tick 应用”的口。
- [ ] 守卫：新增场景探针（或扩展 `resync_*`）：模拟「先预测 10 帧 → 到达一条拆砖事件 → 下一次 ack 恰好在事件锚点」⇒ 断言**不产生连续两次以上回滚**（`rollback_count()` 增量 ≤1）。
- [ ] 变异：把事件改成“到达即应用但不清 capture” ⇒ 断言红。

**验收：** 守卫绿 + 变异红/绿原文；R0 场景（打穿掩体后跑过去）回滚频率前后对比；真链路批绿。

**边界：** 方案 A 的一次性小橡皮筋不可避免；方案 B 的内存与实现复杂度要登记。

---

### R3 · 权威态应用合并为单一实现（P2，防漂移）

**猜测：** 三份复制（单机回溯恢复 / 服务器回溯恢复 / 客户端 `restore_state`）已经出现过“只在一端修好”的缺陷（`mag/rld`、同型号 `winst` 都是这一类）⇒ 这类漂移会表现为“持续回滚”。

**做什么：**
- [ ] grep 三处函数体，列出**字段级差异表**（哪些字段写、哪些不写、哪些走 `apply_mag` 之类的分流）。
- [ ] 抽一个 `PlayerState.apply(player, st, opts)`（或等价的最小公共层），三处改为调用它；差异用 `opts` 表达（如 `flush_inventory=false`、`weapons=mode`）。
- [ ] 守卫：新增纯逻辑/场景探针，用**同一份 payload** 分别走三处入口，断言得到的 `capture_state()` 相等（除时间相关字段）。
- [ ] 变异：把其中一处改回旧写法 ⇒ 探针红。

**验收：** 三处入口 payload→state 一致；`rollback_fidelity_probe` 仍 ALL-OK；全量批绿。

**风险：** 档 3——三处入口各有微妙时序（`sync_soft_state` 早退、回滚重放中调用），必须先列差异表再动。

---

### R4 · 输入不丢 tick（P3，需先测量）

**猜测：** 服务器队列溢出丢最旧 = 真丢一个 tick ⇒ 必回滚；多人局 worker CPU 高时（§四十八：8 人 ≈10ms/tick）会变频繁。

**做什么：**
- [ ] 用 `--diag` 的 `queue_drop` 事件统计每局丢包次数（1v1 / 4 人 / 8 人，各两次）。
- [ ] 若丢包确实存在：先试**最保守**的两条（不改协议语义）：① `QUEUE_CAP` 上限放宽（代价：输入延迟增加，必须用 playout/延迟读数证明可接受）；② 客户端把**最近 2 条记录**都带上（现有 pair 已覆盖 2 tick，评估加到 3 条）。
- [ ] 若仍丢：写“丢包时通知客户端按服务器已消费数重放”的设计（改协议，档 3，单独评审）。

**验收：** 丢包次数前后对比；若不动协议必须有数据支撑。

**边界：** 只有数据表明丢包频繁才做；不为了让计数器归零而牺牲延迟。

---

### R5 · 跨平台浮点差异（只测量，不盲改）

**猜测：** 公网测试若是“Windows 客户端 + Linux 云服务器”，`move_and_slide` 浮点结果可能极小量不同，长期累积成周期性回滚。

**做什么：**
- [ ] 记录测试拓扑（两端 OS/同一台机器？），跑 R0 场景看“静止对枪时也回滚”是否出现。
- [ ] 若确认：选项是①放宽 `_close_enough` 的 pos 容差（有误判风险）②统一物理步长/固定点（大改，先不做）③服务端同平台化部署。**只出结论与建议，不在本计划里动手。**

---

## 结果表

**已填（2026-11-01，第一版 `ce092f9b` / 公网 120.53.107.140，详见 §R0a）**

| 场景 | 修前 rollback/局 | 修后 | 配置/日期 |
|---|---|---|---|
| 1v1 站桩开火（60s） | A4 / B20（第 1 局）、A4 / B2（第 2 局） | 待 R0b | 公网 / 2026-11-01 |
| 1v1 站桩+原地跳（60s） | A1 / B1、A0 / B1 | 待 R0b | 公网 / 2026-11-01 |
| 1v1 站桩+跳+挨打（45s） | A3 / B9（pos/hp/down） | 待 R0b | 公网 / 2026-11-01 |
| 上楼梯（16px×10） | 待测（本轮刻意排除自动跳跃） | — | 本机 |
| 打穿掩体后跑过去 | 待测 | — | 本机 |

**待填（后续任务）：** 上表后两行 + R0b/R0c 的读数与分类统计。

| 场景 | 修前 rollback/局 | 修后 | 配置/日期 |
|---|---|---|---|
| 1v1 平地对枪 | | | |
| 上楼梯（16px×10） | | | |
| 打穿掩体后跑过去 | | | |

## 不做（明确排除）

- 不改 beta 时间玩法；不改命中事件（已对齐）；不改房间/端口/版本号；不改相机/表现层。
- 不引入「客户端也不预测、等服务器」这类大改（会直接毁手感）。
