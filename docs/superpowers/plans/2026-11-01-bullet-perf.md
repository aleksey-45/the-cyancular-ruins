# 子弹裁决与实体开销优化 Plan（先测量，再削峰）

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> ★ **写于 2026-11-01**。只出计划，**未开始实现**；用户已确认「先给猜测/证据，再跑测试」。
>
> ★ **开工前置**：`git status --short` 干净；`python tools/check_naming.py` 绿；本计划**不改协议语义**（除 O7 明确标注的计划外）。

**Goal:** 把服务器每 tick 的子弹裁决成本与“每发子弹一个节点”的实体开销降下来，同时**不改变任何玩法结果**（命中判定、拆砖、榴弹引信/反弹、水面阻力都要逐位不变）。目标场景是 8~16 人局（§四十八 实测 8 人 ≈10ms/tick）。

**Architecture:** 三步走，每一步都有独立验收，后一步依赖前一步的数据：
1. **测量**：给服务器 tick 加分段计时（物理/裁决/快照/广播），先确认“子弹裁决”到底占多少；
2. **零风险削峰**：裁决宽相位 AABB 粗筛（复用每 tick 已有的 hurt 列表）+ 客户端视觉子弹对象池；
3. **结构性优化（可选，需数据支撑）**：服务器“纯数据弹”（无节点）或空间哈希；kd-tree 明确不采用（见 §1.3）。

**Tech Stack:** Godot 4.7.1 标准版 / GDScript。

**Spec / 必读：**
- [`docs/eng/netcode-at-16-players.md`](../../eng/netcode-at-16-players.md) §5（8/16 人负载实测）
- [`docs/eng/registered-debt.md`](../../eng/registered-debt.md) §四十八（多人局诊断：capture_state / 裁决 / 逐 peer RPC 的读数）
- [`core/sim/hit_shape.gd`](../../../core/sim/hit_shape.gd)（`segment_hits_rect` 是唯一命中几何）
- [`server/match/match_combat.gd`](../../../server/match/match_combat.gd)（`_adjudicate_bullets` / `_push_lag_frame`）
- [`scenes/weapons/bullet_base.gd`](../../../scenes/weapons/bullet_base.gd)（`_ready` 每次建 Line2D/爆炸标记 —— 池化必须注意）

---

## 0. 现状事实（写计划时点，行号引用前先 grep 复核）

| 事实 | 位置 |
|---|---|
| 服务器每 tick：`_adjudicate_bullets` 对每颗子弹 × 每个玩家做线段扫掠；命中面取 lag 历史 `rect_for` | `server/match/match_combat.gd` |
| 每 tick 已先跑 `_push_lag_frame()`，为每个玩家算一次 `hurt_rect` 并入历史 | 同上 |
| 客户端视觉弹：服务器 `bullet_spawn` 广播 → `instantiate()` + `_ready()` 建 Line2D/爆炸标记 | `server/match/match_combat.gd::_broadcast_bullet_spawn` / `scenes/weapons/bullet_base.gd::_ready` |
| 客户端 cull 的受击候选已改成“每物理帧缓存一次”（本轮小结，非本计划内容） | `scenes/pvp_match_client.gd::_contact_targets_now` |
| 客户端预测开火也 instantiate 一颗本地弹 | `scenes/weapons/weapon_base.gd::_spawn_projectiles` |
| 回滚/网络侧成本（capture_state、逐 peer RPC）也可能大于裁决 —— 未分段计时前不可下结论 | §四十八 |

---

## 1. 已拍板 / 关键设计决定

### 1.1 先测量再改（硬要求）
没有分段数据前**不动**裁决结构、不做纯数据弹。理由：8 人局 10ms/tick 的构成里，`capture_state` 每 tick 每人、逐 peer 结构化 RPC、lag 历史写入都可能是大头；把子弹裁决优化 80% 也可能只省 1ms。

### 1.2 顺序
O0 测量 → O1 AABB 粗筛 → O2 客户端弹池 → O3 服务器弹池 →（数据驱动）O4 纯数据弹 / O5 空间哈希。
★ 2026-11-02 实际进度：**O0 / O1 / O2+O3 已落地**（O0 数据在跑）；**O5 已评估不采用**；**O4 数据门禁未开 ⇒ 现在不做**（见 §O4 的三条启动门禁）。
**O6 已实测为“非 bug”，降为可选（P3）**；O7 其它候选只登记。

### 1.3 kd-tree 不采用（结论写死，避免反复讨论）
- **不用 kd-tree**：节点每帧移动会破坏结构，重建/平衡成本 > 查询收益；本仓要查的是“线段 vs 少量矩形”，不是最近邻。
- **推荐顺序**：AABB 粗筛（近零成本）→ 均匀网格/spatial hash（对象多且分布均匀时）→ sweep-and-prune（少量动态 AABB）→ 四叉树/BVH（只对**静态**世界几何）。kd-tree 只适合静态点集近邻（如瞄准辅助找最近敌人）。

### 1.4 不改变玩法结果
所有优化必须满足：同一输入/同一状态，**命中集合、拆砖结果、榴弹引信与反弹、水面阻力**逐位一致。守卫用“新旧两条路径对同一批随机/构造用例输出相同”的等价性断言。

### 1.5 池化不改变确定性
池化只影响“节点何时创建/复用”，不得改变 tick 语义；reset 必须完整（§1.6）。

### 1.6 池化 reset 清单（写死在任务里）
`BulletBase` 至少：`global_position/prev_pos/velocity_vec/speed/max_range/fuse_time/hit_fuse_time/explodes/direct_hit_damage/explosion_radius/explosion_damage/explosion_knockback/hit_damage/hit_impact/shooter/apply_damage/source/_aiming 类计时器/modulate/visible/set_physics_process(true)/yield 状态/CollisionShape2D 尺寸（hit_grow 依赖）/meta("scene_path")`；
以及**子节点只建一次**：`_laser`、`_explosion_marker`（`_ready` 里 `call_deferred` 建的那两个）。

---

## Global Constraints

- 判据一律 **grep 判词文本**；退出码不是判据。
- 所有新探针/烟测自带**条数闸**；新增脚本要同步 `allscript_probe.EXPECTED_SCRIPTS` 与 `tests/README.md` 计数。
- 跑测试先问用户；占 7777 的步骤先查 `lobby_alive`；真链路批前后 Godot 进程为 0；时序类结论同配置跑两次。
- 逐文件 `git add`；`python tools/check_naming.py`；提交信息 `type(scope): 中文一句话`；**推送先问用户**。
- 档位：O0/O1/O2/O3 档 2（单系统 + 性能，不动协议）；O4 档 3（改服务器模拟结构，需逐任务评审 + 真链路）；O6 档 1（显示）。

---

## 任务

### O0 · 服务器 tick 分段计时（只加诊断，不改行为）—— **已完成 2026-11-02，数据待跑**

**猜测：** 8 人局 10ms/tick 里，子弹裁决可能只占一小部分；`capture_state`/快照编码/逐 peer RPC 可能更大。没有分段数据前任何结构优化都是猜。

**落地（子代理实现，Lead 复跑 `ALLSCRIPT` 复核）**
- 新建 `server/match/tick_timing.gd`（132 行，`RefCounted`、**无 `class_name`**、`preload` 使用）；`server/match/match_host.gd` **纯追加 21 行**（`git diff -U0` 全为 `+`，现有语句一字未动）：1 处成员声明 + 6 处紧贴被测调用的 mark。
- 段：`adjudicate`（含 `_push_lag_frame`）/ `world_snap`（`encode_world` + 单次广播 rpc）/ `own_snap`（`capture_state` + `encode_own` + **逐 peer `rpc_id`**，在帧末 deferred，不计入 tick 窗口）/ `rewind`（Beta 时间玩法才有）+ 整 tick；附带 `players` / `bullets_avg` / `bullets_max`。
- 落盘：`event=tick_sections` 进**心跳指标文件**（`NetDiag.log_metric`，1 行/窗口；窗口跟随 `NetDiag.metric_interval_ms()`：默认 10s、`--diag-verbose` 1s —— 1s 窗口若不跟随会被 10s 节流吞掉）。不新增常驻生产日志。
- **关闭 diag 的开销**：判据收在类内（`on == false` ⇒ 立即 return），不读时钟/不分配/不拼串/不写盘；实测 100k 次 mark 减空循环 = 0.41~0.50 µs/2 次 ⇒ 每 tick 10 次 ≈ **2~2.5 µs（10ms tick 的 0.02%）**。是"空实现级"，不是数学 0（要严格 0 只能复制一份 `_physics_process`，重排，不做）。
- 口径三条（别混读）：`*_avg_us` 是**均摊到每 tick**（sum/ticks，与 `tick_avg_us` 可比）；`*_max_us` 是**单次**最长；`own_snap` 在 deferred 里跑，**不与 tick 窗口相加对账**。

**数据跑法（还没跑：7777 当轮被另一会话占着）**
```
CYR_DIAG=1 CYR_DIAG_VERBOSE=1 CYR_LOG_DIR="$PWD/gamelogs/o0_8pa" \
  bash tests/probe/royale_soak_probe.sh 8 60 90      # 2/4/8 人 × 各两次
grep -h '"tick_sections"' "$LOGDIR"/metrics-server-*.jsonl | tail -20
```
★ 必须用 `CYR_DIAG=1`（worker 是子进程，命令行由 WorkerLauncher 固定拼、不带 `--diag`）。

**验收（部分）**：关闭 diag 行为逐字不变（纯追加 + 空实现可复核）；分段字段与落盘已由临时 `-s` 烟测验（`O0 TIMING SMOKE: OK(16 项)`，已删）；**2/4/8 人读数表未填**（见 §结果表）。
**不做：** 不加每帧字符串拼接/日志；不改裁决逻辑。

---

### O1 · 裁决宽相位 AABB 粗筛（零风险削峰）—— **已完成 2026-11-02，Lead 复跑确认**

**猜测：** `_adjudicate_bullets` 对每颗子弹 × 每个玩家都进 `segment_hits_rect`；先用"子弹本帧扫掠 AABB vs 玩家 hurt rect"做矩形判交，能砍掉绝大多数"明显不可能命中"的精确计算。

**落地（子代理实现 + Lead 复跑 `BULLET SWEEP PROBE: ALL-OK`）**
- `core/sim/hit_shape.gd`：新增 `sweep_may_hit(a,b,rect,w,h,grow)`（扫掠 AABB vs **最近环面副本**、**含边界** `<=`/`>=`、**含 grow**）与 `candidate_hits(..., exact_only=false)`（粗筛是**纯门** → 精确）。
- `server/match/match_combat.gd`：`adjudicate_exact_only`（生产默认 false，只给守卫切新旧路径）；**每颗子弹只算一次** `prev/cur/grow`（`hit_grow()` 要查碰撞体 + 三角函数，原来是每候选算一次）；回放受击面按 **(射手 role, 受害者 role) 每 tick** 缓存（`_hurt_rect_cache` + `_hurt_rect_cache_tick`，随 `_srv_tick` 自愈）。
- **与计划原文的两处必要偏离（不改会变成行为 bug）**：
  1. **不能"每玩家每 tick 取一份 rect"** —— 回放 tick 依赖**射手**自己的 `_client_snap_tick`，逐射手不同 ⇒ 必须按 (射手, 受害者) 缓存；
  2. **回退支（现时 `hurt_rect()`）与 `HitShape.hurtable()` 刻意不缓存** —— 同帧 `take_hit` 可能击倒/击退，缓存会让"同帧先被打死的人还吃后续子弹"，那是行为改变。
- 命中顺序为何不变（可证）：生产顺序 = `for role in players` 插入序 + 首个命中 `break`；粗筛不把任何数值喂给精确那一步（无 ULP 漂移），且真命中 ⇒ 必过粗筛（保守），被拒者原本也判 false 并 `continue` ⇒ 首个 true 下标不变。

**守卫**：`tests/probe/bullet_sweep_probe.gd` `EXPECTED_CHECKS 6 → 15`：构造 6 例两路径逐例一致 / 粗筛从未否掉精确判中 / 贴边相切必须放行（只许"多放过"）/ 擦边必须算 grow / 跨环面缝按最近副本对齐 / 粗筛不是恒真 / 随机 400 例（固定种子）两路径一致 / 随机用例分布有效（真命中 104、否掉 274 都不为 0）/ **tick 模拟 200 颗弹**：命中集合与命中顺序（首个命中索引序列）一致。
**变异（逐字）**：漏 grow ⇒ `✗ 擦边…` + `✗ 随机 400 例…(不一致 23)` + `FAIL`；改用 `encloses` ⇒ `✗ 贴边相切…` + `✗ 跨环面缝…` + `✗ 随机…(不一致 99)` + `✗ tick 模拟…(命中 23 颗)` + `FAIL`；各自还原后 `BULLET SWEEP PROBE: ALL-OK`。
**测不到什么**：守卫把生产决策函数 `HitShape.candidate_hits` 当被测对象（`_adjudicate_bullets` 是破坏性的，同一状态跑不了两遍）；若有人把粗筛从生产里整个删掉（只留精确），探针不会红 —— 那是纯性能回退、行为不变。**O0 的"裁决分段下降"读数未取**（7777 当轮被占）。

---

### O2 · 客户端视觉子弹对象池（档 2）—— **已完成 2026-11-02**

**猜测：** 每发子弹 `instantiate()` + `_ready()` 建两个子节点 + `queue_free()`，在高射速/多人局下是可见开销；池化能省掉节点创建与释放。

**落地**
- 新建 `core/present/bullet_pool.gd`（`class_name BulletPool`，`MAX_PER_SCENE = 64`）：按 `scene_path` 分池，`acquire()/release()/idle_count()`；场景 `PackedScene` 缓存；**同一物理帧归还的实例不借出**（`_released_frame` + `Engine.get_physics_frames()`）；双 release 幂等；超上限 `queue_free`、缺货回落 `instantiate()`。
- `scenes/weapons/bullet_base.gd`（+126/−5）：`_ready` 幂等化（拖尾节点复用不重建）；池生命周期 `despawn / set_pool / remember_scene_defaults / reset_for_pool / _despawn_after`；5 处 `queue_free()` → `despawn()`。
- `scenes/weapons/weapon_base.gd` `_spawn_projectiles` 走池（**两端同路**，服务器权威弹与客户端视觉弹同一份 reset）。
- `scenes/pvp_match_client.gd`：`_take_visual_bullet` 唯一取弹入口；爆炸回收 / 接触剔除改 `despawn()`。
- 守卫：新建 `tests/smoke/bullet_pool_smoke.gd`（5 条闸：逐字段等价 / 榴弹场景初值 / meta 清零 / 双 release 幂等 / 上限回落）+ `tests/probe/bullet_pool_probe.gd`（9 条闸：武器与网络入口走池 / 归还后离树且物理关 / 旧定时器不误伤 / 子节点不增长 / 拖尾清空+弹色 / 首帧扫掠起点 = 出膛位置 / 物理回调内回池 / 同帧隔离）。
- 判词：`BULLET POOL SMOKE OK(5 checks)`、`BULLET POOL PROBE: ALL-OK`；回归 `BULLET SWEEP PROBE: ALL-OK`、`gun_ammo_independence` / `wheel_switch` ALL-OK。
- 变异 6 组（`apply_damage` / meta 清空 / 缺 `request_ready` / 定时器令牌 / 武器绕池 / 同帧隔离）逐组红、还原回绿。

**两个必须记住的坑（已写进代码注释 + 探针）**
1. **`_ready()` 只在首次入树时跑** ⇒ 池必须 `request_ready()`：否则 `prev_pos` 停在上一次（服务器首帧扫掠线段横穿全图）、拖尾点集/弹色不上新。
2. **服务器按实例 id 判"这颗弹广播过没有"**（`_seen_bullets`）⇒ 同帧"死一颗→借给下一发"会被当成同一颗而**不再广播**（客户端少看见一发、不报错）。池已加"同帧归还的不借出"缓解；结构修复（每发 use generation）在 `server/match/**`，**未做**（登记为已知边界）。

**边界（照实）：** headless 测不到渲染开销；观感（拖尾一帧残影）要真机看；**性能收益未实测**（`royale_soak` 未跑，见 O0 数据）。

---

### O3 · 服务器侧子弹池（档 2，数据驱动）—— **已完成（与 O2 同一组件，2026-11-02）**

**猜测：** 服务器同样每发 instantiate + `_ready`（虽然 headless 不渲染，但节点/信号/物理体创建与释放仍有成本）。

**落地**：`weapon_base._spawn_projectiles` 的**服务器路径走同一个池**（同一份 reset）。服务器侧**只跳过 1 项**：`Sprite2D.modulate`（tint）—— 服务器上该节点无任何读者（不画、不进快照、不参与 `hit_grow()`）；`visible` / 拖尾 / 玩法字段两端完全同一份 reset（避免"客户端绿、服务器红"的分叉）。
**已知风险**：见 O2 的坑 2（实例 id 广播判据）——**缓解**已在池内，结构修复未做。
**验收**：等价性由池探针 + 既有 `pvp_match_smoke` 覆盖；**tick 成本下降无数据**（未跑 `royale_soak`，等 O0 读数表）。

---

### O4 · 服务器“纯数据弹”（**数据门禁未开：现在不做，2026-11-02 裁定**）

**猜测：** 若子弹裁决仍是 tick 大头，最大的结构性收益是把服务器子弹从 `CharacterBody2D + move_and_slide` 改成纯数据（位置/速度/寿命/引信）+ 格点 raycast 判地形，去掉每颗子弹的节点与物理体。

**为什么现在不做（用户 + Lead 一致裁定，理由逐条）**
1. **违反 §1.1 自己的硬规则**：没有 O0 分段数据就不动裁决结构。O0 代码 2026-11-02 才落地，数据刚在跑。
2. **收益上限本来就不大**：8 人局 tick ≈10ms（预算 16.6ms），还没超；子弹实体优化省的是每颗几十微秒，而 O0 要验证的恰恰是"大头可能根本不在子弹"。
3. **收益玩家不可感知**：改的是服务器内部结构（线上格式、命中几何、体验都不变），只有 tick 逼近/超过 16.6ms 时才有意义。
4. **成本/风险本批最高**：档 3 —— 弹道、地形判定、引信、反弹、命中几何（仍须 `HitShape`）、拆砖、8 人局行为逐项一致，都要金标准钉住 + 真链路 + 逐任务评审。
5. **当前真正的痛点是正确性**（R1/R2/R3/R7 的回滚与两端对齐），不是吞吐。

**启动门禁（三条同时满足才允许开工）**
- O0 数据：8 人档 `tick_avg_us` **≥ 14000**（逼近 16.6ms 预算）**或** `adjudicate_pct ≥ 20`；
- 且 O1（粗筛）与 O2/O3（池化）已落地并被数据证明"仍不够"；
- 且改动范围能分批（先只做"无爆炸直弹"，分批对金标准），任何一批对不上就停。
→ 否则本任务**结案"不采用"**，不再排期。

**金标准探针暂不入库**：2026-11-02 曾有子代理写 `tests/probe/bullet_golden_probe.*`（29 条闸），中途被停、**停在 parse error**（`Unindent doesn't match…`:468），已移到 `.superpowers/sdd/_gen/o4_shelved/`（gitignore）备查。**不留进仓库**：没有 O4 就没有消费者，且半成品会让 `allscript_probe` 条数闸多一个未知变量。若门禁真被触发，再把它修好后入库。

**验收（若将来启动）：** 行为逐项一致；8 人局 tick 成本显著下降（目标写进 O0 结果表）；回滚频率不变差。

**不做：** 不改客户端表现、不改命中几何（仍用 `HitShape`）、不改拆砖数值。

**不做：** 不改客户端表现、不改命中几何（仍用 `HitShape`）、不改拆砖数值。

---

### O5 · 空间哈希（**已评估：不采用，2026-11-02**）

**猜测：** 人数/子弹数上升后（16 人 × 上百发），O1 的 AABB 粗筛仍是 O(子弹×玩家)；空间哈希把候选降到常数级。

**评估结论（不采用，理由逐条）**
1. **量级本来就小**：O1 之后每 tick 的工作是"子弹 × 玩家"次**矩形判交**。16 人 × 上百发 ≈ 1600 次矩形相交 ≈ 微秒级（单次矩形判交是十几条比较），远小于 1ms，也远小于 O4 要动的"整弹物理（节点 + `move_and_slide`）"。
2. **哈希的重建成本抵掉收益**：要查的对象是**玩家**（每 tick 位置都在变），哈希每 tick 都要重建/更新；16 个条目的插入 ≈ 16 次线性扫的成本 —— 换不来常数级收益。
3. **动态 AABB 的合适结构不是哈希**：真要继续压，按 §1.3 的排序应是 sweep-and-prune（少量动态 AABB），而不是空间哈希；而它同样受第 1 条量级限制。
4. **真正的结构收益在 O4**：把服务器子弹从节点/物理体改成纯数据，省的是每颗子弹的节点与 `move_and_slide`，不是"候选筛选"。

**验收（本轮）**：结论写入本计划（本节）与 §不做；**不写代码、不写守卫**（性能项没有行为判据，按 `test-economy` 不写"零断言守卫"）。
**翻案条件**：O0 数据显示"裁决段仍占 tick >20%"**且** O4 已落地、子弹数/玩家数再上一个量级（如 16 人 + 数百发常驻）时，重开本任务，先做 sweep-and-prune 而不是哈希。

---

### O6 · PvP 延迟显示口径（**已评估：不是 bug；降级为可选统一口径**）

**原猜测（已被实测否定）：** HUD 的 ms 是“走游戏循环的 RPC 往返”，会比真实 RTT 高 1~2 帧（+17~33ms）。

**实测（2026-11-01，公网 120.53.107.140，第一版代码，真实客户端探针）：**

| 采样 | HUD `NetBus.ping_ms` | ENet `PEER_ROUND_TRIP_TIME` |
|---|---|---|
| 10s | 52 ms | 53 ms |
| 20s | 53 ms | 49 ms |
| 30s | 46 ms | 41 ms |
| 40s | 36 ms | 40 ms |
| 结束 | 35 ms | 40 ms |

**结论：** 两个口径差 ≤5ms ⇒ **公网显示 50ms 是真实 RTT，不是代码自带的固定值**，Godot 每帧 flush + 服务器即时回包使循环开销只有几 ms。
唯一异常是 ENet 的**首样**（1427ms，平滑前），HUD 那边首样是 0ms —— 都不是缺陷。

**补充实测（2026-11-01，本机 loopback，§R6 的 13 局里每局都打了 `LDIAG ROLLBACK … ping(hud=… enet=…)`）：**
HUD **18~19ms** / ENet **13~23ms**，差值 ≤5ms 且方向随机 ⇒ 与公网结论一致；本机之所以看起来"19ms"而不是 0，
是**一帧（16.7ms）+ 平滑/采样粒度**的测量下限，不是网络延迟。**因此 O6 维持"不是 bug"**，
若要统一口径只做下面那条 P3。

**若仍要做（可选，P3）：**
- [ ] `core/net/net_bus.gd`：`ping_ms` 优先取 ENet 统计（消除首样噪声、语义更明确），RPC ping 兜底。
- [ ] `--diag` 同时打两个口径（本机/公网各一次），把差值写进 docs。
- [ ] 无自动守卫（网络读数天然不稳）；文档登记边界。

**验收（若做）：** 两口径读数并列（应一致）；不要把“显示 50ms”当 bug 处理。

---

### O7 · 其它候选（只登记，不承诺）

- 逐 peer 结构化 RPC 合并/压缩（§四十八 提到命中广播逐 peer）；
- `capture_state` 每 tick 每人的字典分配复用；
- 大乱斗 1Hz `round_state` 载荷裁剪（名字/统计字段）。

这些需要 O0 数据指出大头后再排期。

---

## 结果表（2026-11-02 实测，`royale_soak` 2/4/8 人 × 各 2 次，全部 `SOAK: ALL-OK`）

`CYR_DIAG=1 CYR_DIAG_VERBOSE=1`（1s 窗），取 `event=tick_sections` 的窗口均值/最大值：

| 人数 | tick_avg µs | tick_max µs | 裁决 avg µs (pct) | 本人包 avg µs (pct) | 世界包 avg µs (pct) | 子弹 avg / max |
|---|---|---|---|---|---|---|
| 2 (r1 / r2) | 427 / 406 | 24535 / 27761 | 78 / 68 (18.5 / 17.0) | 159 / 156 (37.5 / 38.9) | 212 / 205 (50.1 / 50.8) | 0.1 / 5 · 0.0 / 0 |
| 4 (r1 / r2) | 545 / 642 | 26150 / 26353 | 109 / 145 (19.9 / 21.7) | 256 / 303 (47.6 / 47.3) | 277 / 322 (51.3 / 51.2) | 0.2 / 9 · 0.6 / 17 |
| 8 (r1 / r2) | 846 / 892 | 25235 / 26878 | 232 / 244 (26.3 / 26.7) | 472 / 488 (56.5 / 55.1) | 414 / 439 (49.8 / 49.7) | 0.7 / 11 · 0.7 / 11 |

**口径三条（读前必看）**
- `*_avg_us` = 本窗口**均摊到每 tick**；`*_pct` = avg / `tick_avg`。
- `own_snap`（本人包 = `capture_state` + 编码 + **逐 peer RPC**）在**帧末 deferred** 跑，**不进** `tick_avg` 窗口 ⇒ 它的 pct 不能与 tick 相加对账；三段 pct 相加 >100% 属正常。
- `adjudicate` 段**含** `_push_lag_frame`（每 tick 每人写历史环）与子弹组扫描 —— 不是"逐弹判定"。

**结论（回答计划 §O0 的"裁决占多少"）**
1. **tick 总量远低于预算**：8 人才 **0.85–0.89 ms**（16.6ms 预算的 ~5%）。计划 §现状里"8 人 ≈10ms/tick"这一次**没复现**（那次是带真实战斗的读数）。
2. **在 tick 内部，最大项是"世界包广播"（~50%），裁决第二（17%→27%，随人数涨）**；裁决的成本**几乎全是每 tick 固定开销**（lag 历史 + 组扫描），因为本批 soak 的 **子弹数 avg ≤0.7**（客户端基本不开火）。
3. **尖峰存在**：`tick_max` **25–28ms** 在 2/4/8 人都有（> 16.6ms 预算），说明存在偶发长 tick（嫌疑：关键帧编码 / 启动首 tick / 逐 peer 发送抖动），**还没定位**——但它是"尖峰"不是稳态。
4. ⇒ **O4 的门禁两条都不成立**：tick 远没逼近预算；`adjudicate_pct` 虽到 26% 但那是"固定开销"而非"子弹实体"，而 O4 动的恰恰是子弹实体。**O4 结案"不采用"**（除非将来有"弹幕满载"读数翻案）。
5. ⇒ **本批数据回答不了 O1/O2/O3 的收益**（子弹太少）。下一轮测量的正确做法：**让客户端开火**（`bot_*` 探针或带射击的 soak 夹具）压出几十发常驻弹幕，再读 `adjudicate_pct` 与 `tick_avg` 的差；顺带定位 25ms 尖峰。

**跑法（复现）**
```
CYR_DIAG=1 CYR_DIAG_VERBOSE=1 CYR_LOG_DIR="<win 绝对路径>" \
  bash tests/probe/royale_soak_probe.sh 8 60 90      # 2/4/8 各两次
grep -h '"tick_sections"' "$LOGDIR"/metrics-server-*.jsonl | tail -20
```

## 不做（明确排除）

- 不用 kd-tree/四叉树做动态子弹宽相位（§1.3）；
- **不做空间哈希 / sweep-and-prune（O5 已评估：量级不够，见 §O5 的翻案条件）**；
- 不改客户端/服务器命中几何（`HitShape` 单一真相源）；
- 不改协议语义（O6 只改显示；O4 是服务器内部结构）；
- 不为了性能牺牲确定性（池化必须完整 reset，且不进 `capture_state` 语义）；
- **O4 纯数据弹在 O0 数据出来之前不启动**（§1.1 硬要求）。
