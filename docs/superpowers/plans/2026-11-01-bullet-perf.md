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
O0 测量 → O1 AABB 粗筛 → O2 客户端弹池 → O3 服务器弹池 →（数据驱动）O4 纯数据弹 / O5 空间哈希。**O6 已实测为“非 bug”，降为可选（P3）**；O7 其它候选只登记。

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

### O0 · 服务器 tick 分段计时（只加诊断，不改行为）

**猜测：** 8 人局 10ms/tick 里，子弹裁决可能只占一小部分；`capture_state`/快照编码/逐 peer RPC 可能更大。没有分段数据前任何结构优化都是猜。

**做什么：**
- [ ] `server/match/` 内加**默认关闭**的计时（`--diag` 才开）：每 tick 累计 `_adjudicate_bullets` / `_push_lag_frame` / 快照编码 / 逐 peer 发送的微秒数 + 子弹数、玩家数；1Hz 打一行到 diag 日志（**不要**新增常驻生产日志）。
- [ ] 用 `royale_soak`（`--clients=2/4/8`，同配置两次）跑，记录分段占比。
- [ ] 数据写进本计划 §结果表；并回答：裁决占 tick 的百分比是多少？

**验收：** 分段读数表（2/4/8 人各两次）；代码默认路径行为不变（关闭 diag 时零计时开销 —— 用 `if NetDiag.enabled()` 包住或等价开关）。

**不做：** 不加每帧字符串拼接/日志；不改裁决逻辑。

---

### O1 · 裁决宽相位 AABB 粗筛（零风险削峰）

**猜测：** `_adjudicate_bullets` 对每颗子弹 × 每个玩家都进 `segment_hits_rect`（内部可能没有 AABB 早退）；先用“子弹本帧扫掠 AABB vs 玩家 hurt rect”做矩形判交，能砍掉绝大多数“明显不可能命中”的精确计算。

**做什么：**
- [ ] 读 `HitShape.segment_hits_rect`：若内部已有 AABB 早退，则本任务改成“复用 `_push_lag_frame` 已算好的 rect 列表”，避免每子弹重复取 rect（减少函数调用与 rect 构造）。
- [ ] `_adjudicate_bullets`：每 tick 先把“每个玩家在 replay tick 的 hurt rect”取一次进局部数组（避免每子弹每玩家都查历史表），再对每颗子弹：
  1. 子弹本帧扫掠 AABB（`Rect2(prev_pos, global_position)` grow `hit_grow()`）与每个候选 rect `intersects` 粗筛；
  2. 通过者才做精确 `segment_hits_rect`。
- [ ] 守卫：扩展 `tests/probe/bullet_sweep_probe`（或新增等价性探针）：对**构造用例 + 随机用例**（固定随机种子）跑“粗筛路径”与“直接精确路径”（代码里留一个 `_adjudicate_exact_only()` 或 debug 开关），断言命中集合**完全一致**。
- [ ] 变异：把粗筛判据写错（如用 `encloses` 或漏 grow）⇒ 等价性断言红。

**验收：** `BULLET SWEEP PROBE: ALL-OK`；O0 读数的裁决分段下降；全量批绿。

**边界：** 单机模式不跑这条（单机命中在 `bullet_base` 侧），本任务只动 PvP 服务器裁决。

---

### O2 · 客户端视觉子弹对象池（档 2）

**猜测：** 每发子弹 `instantiate()` + `_ready()` 建两个子节点 + `queue_free()`，在高射速/多人局下是可见开销；池化能省掉节点创建与释放。

**做什么：**
- [ ] 新组件 `core/present/bullet_pool.gd`（或 `scenes/weapons/` 下的组合件，按仓规放对层）：按 `scene_path` 分池；`acquire(scene_path) -> BulletBase` / `release(bullet)`。
- [ ] `BulletBase` 加 `reset_for_pool()`：按 §1.6 清单完整复位；`_ready` 的子节点创建改成“只在首次创建”。
- [ ] 客户端两处接入：`_on_bullet_spawn`（他人子弹）与 `weapon_base._spawn_projectiles`（自己子弹）**只改客户端路径**（服务器先不动，见 O3）。
- [ ] 守卫：新增 `bullet_pool_smoke`（`-s`，纯逻辑可跑的部分）+ 场景探针：① 复用后的子弹状态与“新建一颗”等价（逐字段比较）；② 复用 3 次后子节点数量不增长（Line2D/爆炸标记各 1）；③ 归还后节点不在树/不参与物理；④ 池上限外的请求回落到 instantiate。
- [ ] 变异：reset 清单里删一项（如 `apply_damage` 或 `_laser` 重建保护）⇒ 探针红。

**验收：** 探针 `ALL-OK` + 变异红/绿；客户端 8 人局帧 p95 不升（`royale_soak` 读数）；全量批绿。

**边界（照实）：** headless 测不到渲染开销，只能测节点/状态；观感（拖尾、爆炸标记残留）要真机看。

---

### O3 · 服务器侧子弹池（档 2，数据驱动）

**猜测：** 服务器同样每发 instantiate + `_ready`（虽然 headless 不渲染，但节点/信号/物理体创建与释放仍有成本）。

**做什么：**
- [ ] 服务器 `_adjudicate`/`_broadcast_bullet_spawn` 路径接入同一池组件（服务器没有渲染，池化 reset 清单里与表现相关的项可跳过，但要写清）。
- [ ] 守卫：`server` 侧等价性 —— 同一批射击序列，池化前后的 `capture`/命中事件序列一致（用现有 `pvp_match_smoke`/探针覆盖）。
- [ ] 先看 O0/O1 数据：若裁决+实体开销 <2ms/tick，则本任务降级为“可选”。

**验收：** 8 人 `royale_soak` tick 成本下降；无 new-red。

---

### O4 · 服务器“纯数据弹”（可选，档 3，需 O0 数据支撑）

**猜测：** 若子弹裁决仍是 tick 大头，最大的结构性收益是把服务器子弹从 `CharacterBody2D + move_and_slide` 改成纯数据（位置/速度/寿命/引信）+ 格点 raycast 判地形，去掉每颗子弹的节点与物理体。

**做什么（只在 O0 数据支持时启动）：**
- [ ] 先写**行为钉住探针**：子弹撞地形（普通/可破坏砖/32px 块）、入水阻力、榴弹反弹与引信、`max_live_projectiles` 上限 —— 用现有服务器路径跑出“金标准”序列存档。
- [ ] 实现纯数据弹（可先只对“无爆炸弹”分批做），逐项对金标准；不一致就停。
- [ ] 全量批 + 真链路批 + 逐任务评审；`PROTO_VERSION` 不动（线上格式不变，变的只是服务器内部结构）。

**验收：** 行为逐项一致；8 人局 tick 成本显著下降（目标写进 O0 结果表）；回滚频率不变差。

**不做：** 不改客户端表现、不改命中几何（仍用 `HitShape`）、不改拆砖数值。

---

### O5 · 空间哈希（只在 O4 之后仍不够时）

**猜测：** 人数/子弹数上升后（16 人 × 上百发），O1 的 AABB 粗筛仍是 O(子弹×玩家)；空间哈希把候选降到常数级。

**做什么：**
- [ ] 只在 O0 数据显示裁决仍占 >tick 20% 时启动；先做**玩家 16 个**的哈希（小规模，其实线性扫也快）——**大概率不值得做**，写明即可。

**验收：** 若无收益，本任务标记“已评估不采用”并写入债务。

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

## 结果表（执行时填写）

| 人数 | tick/ms | 裁决 µs | lag 历史 µs | 快照编码 µs | 逐 peer RPC µs | 子弹数 | 备注 |
|---|---|---|---|---|---|---|---|
| 2 | | | | | | | |
| 4 | | | | | | | |
| 8 | | | | | | | |

## 不做（明确排除）

- 不用 kd-tree/四叉树做动态子弹宽相位（§1.3）；
- 不改客户端/服务器命中几何（`HitShape` 单一真相源）；
- 不改协议语义（O6 只改显示；O4 是服务器内部结构）；
- 不为了性能牺牲确定性（池化必须完整 reset，且不进 `capture_state` 语义）。
