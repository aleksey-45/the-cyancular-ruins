# 玩家互相碰撞 + 榴弹命中玩家 + 大乱斗压力勘察（设计）

> 日期：2026-09-12 · 状态：已定稿（用户 2026-09-12 口头确认 A/B/C/D 四块）· 分支：`refactor/abstraction-batch01`
> 前置阅读：`CLAUDE.md` §网络与 PvP / §武器与子弹、`docs/superpowers/plans/2026-09-11-royale-netplay-1v1-alignment.md` §3.2b
> 需求来源（用户原话）：
> 1. 「多人模式：让玩家和玩家可以互相碰撞，让榴弹可以击中其他玩家后应用那个时间更短的引爆，而不是 0.4s」
> 2. 「再次测试大乱斗，勘察卡顿情况和所有局内行为会不会导致崩溃或大卡顿」

---

## 0. 动工前的代码级复核（先纠正两处与计划文档不符的记法）

复核 `server/match_host.gd` / `scenes/pvp_client.gd` / `scenes/player/player_replica.gd` /
`scenes/weapons/bullet_base.gd` / `scenes/player/player.gd` / `scenes/royale_game.gd` 后：

1. **服务器侧玩家碰撞早就存在**：`match_host.gd:81` 与 `:99` 对每个（含 AI）玩家做了
   `p.collision_mask |= 2`。缺的**只有客户端**——`PlayerReplica` 是 `extends Node2D`、**零碰撞体**，
   而客户端本地玩家的 mask 仍是 `Player.tscn` 的 `5`。

2. **★ 计划文档 §3.2b 有一处事实错误**：
   `docs/superpowers/plans/2026-09-11-royale-netplay-1v1-alignment.md` 第 96 行写
   「本地玩家 `collision_mask = 5` 已含 2」——**错的**。碰撞层是位标志：层1=1、层2=2、层3=4，
   故 `5 = 0b101` = **层1（地形）+ 层3（敌人）**，**不含层2（玩家）**。
   照那句话做，会得到一个"本地玩家永远不会撞上去"的幽灵体（看起来做了、实际无效）。
   本设计按正确值处理，并回头修正该计划文档。

3. **榴弹对玩家完全无感**：`match_host.gd:365` 的 `if bullet.explodes: continue` 让爆炸弹
   整条跳过玩家判定；同时子弹碰撞掩码 = 5（不含层2），物理上也碰不到玩家身体。
   故榴弹穿过对手、一路飞到墙才起 `fuse_time = 0.4` 引信。
   现成的短引信参数：`grenade_bullet.tscn` 的 `hit_fuse_time = 0.15`、`direct_hit_damage = 5`。

4. **`apply_damage` 在 PvP 客户端恒为 false**：`weapon_base.gd:315` 是
   `b.apply_damage = not Level0.pvp_mode`，即 PvP 客户端上**所有**玩家子弹（含自己开的）都不裁决伤害。
   服务器侧 `Level0.pvp_mode == false` → 服务器子弹 `apply_damage == true`。
   这条是 B 块"权威/视觉"分流判据的基础。

---

## A. 玩家互相碰撞（1v1 与大乱斗两端都加）

### A1 幽灵碰撞体（`PlayerReplica`）

给副本挂一个**只参与碰撞、不参与任何逻辑**的幽灵体：

- **节点**：`StaticBody2D`（副本自身不由物理驱动，位置由 `_process` 的插值决定；用 `CharacterBody2D`
  会引入它自己的物理步进与 `move_and_slide` 竞争）。作为副本子节点 → 位置、朝向、环面回绕自动跟随。
- **层**：`collision_layer = 2`（与 `Player.tscn` 一致）、`collision_mask = 0`（它不需要感知任何东西，
  只被本地玩家的 `move_and_slide` 撞到）。
- **形状**：5 个 `CollisionPolygon2D`（stand/move/fly/charge/squat），**多边形与偏移从 `Player.tscn` 现抄**——
  `player_replica.gd._ready()` 本来就已经为了拿 `sprite_frames` 实例化了一份 `Player.tscn`，
  复用它再 `free()`，于是形状与 `Player.tscn` **同源**，日后改玩家碰撞箱不会与副本漂移。
- **姿态切换**：`apply_snapshot` 按快照 `pose` 启用对应那一份（与 `player.gd` 的 `_coll_by_pose` 同款）；
  **`downed` 时不切换**——与服务器一致（`player.gd` 的倒地分支在碰撞箱切换代码之前就 `return`，
  碰撞箱停在上一个姿态）。
- 副本同时入 **`player_replica` 组**（B3 的视觉判定要用）。

### A2 本地玩家 mask

`scenes/pvp_client.gd._ready()` 与 `scenes/royale_game.gd._ready()` 各补一行
`_local.collision_mask |= 2`（与 `match_host.gd:81` 同款）。

**不改 `Player.tscn`**：`tests/enemy_logic_smoke.gd:324` 有 `_check(pc2.collision_mask == 5, ...)` 断言，
改场景常量会让它变红；运行期改也与服务器侧的做法对称。

### A3 为什么这样能治"贴身回滚"

C2 下客户端只预测**自己的**玩家（`PredictionRollback._step()` 只调 `_p._physics_process`）。
在此之前，客户端预测所依据的世界里**没有对手身体**——"对手挡住我"这件事在信息上就不存在：
本地预测直接穿过去，服务器却把你挡住 → 每帧分歧 → 每帧 `restore_state` + 重放 → 重放又没有障碍
→ 结果仍落在穿过去的位置 → 下一帧再分歧。**这是无限回滚循环，不是调参能缓解的**。
补上幽灵体后两端世界一致，分歧消失。

### A4 明确不消除的残余（验收不能按"归零"）

幽灵体的位置是**插值后、落后约一 tick** 的视觉位置，不是服务器那一 tick 的精确位置 →
贴身高速相对运动时仍有残余分歧与回滚，只是频率与幅度大幅下降。
**验收按"回滚次数下降多少"量**（`PredictionRollback.rollback_count()`），不按"是否归零"。

### A5 副作用清单（逐条核过）

| 项 | 结论 |
|---|---|
| 敌人 mask 含层2（会盯玩家） | 1v1 的 `MatchHost.ENABLE_BIRDS = false`；大乱斗 `RoyaleHost` 继承同一开关且未覆写 → **当前无鸟**。另外客户端上的"敌人"是 `EnemyReplica`（纯视觉、无碰撞）→ 结构性无交互。 |
| 子弹 mask = 5（地形+敌人） | 不含层2 → 子弹不会打在幽灵体上，**无需处理**。写下来避免后人误加。 |
| `Explosion.apply_aoe` 遍历 `player` 组 | 副本**不入** `player` 组（只入 `player_replica`）→ 不会被 AoE 当作玩家结算。 |
| `BulletBase._wrap()` 取 `player` 组第一个节点当锚点 | 同上，副本不入该组 → 锚点不受影响。 |
| 「纯视觉副本」这一既有契约 | **不再成立**（副本现在有一个只碰撞的体）→ 必须同步改 `player_replica.gd` 头注释与 `CLAUDE.md`，否则后人会把幽灵体当 bug 删掉。 |
| 副本的姿态碰撞箱管理 | **不**把 `Player` 那套姿态启停逻辑整套复制过来；只按快照 pose 切 5 份中的一个，`downed` 不动。 |

---

## B. 榴弹命中玩家 → 直接伤 5 + 短引信 0.15s

### B1 权威侧（`MatchHost._adjudicate_bullets`）

把 `if bullet.explodes: continue` 换成 `if bullet.explodes: _adjudicate_grenade(bullet); continue`。

`_adjudicate_grenade`：对**非射手**玩家做环面距离判定（半径与普通弹同源，见 B4）；
命中**一次性**（子弹 meta `grenade_direct_hit` 闩住——榴弹穿过 40px 判定圈会连续命中好几帧）：

- `victim.take_hit(bullet.global_position, bullet.direct_hit_damage, false, bullet.hit_impact)`；
- `CombatFeedback.attribute(victim, bullet.shooter)`（**先于**伤害：一击致死时倒地边沿同帧读 meta，
  大乱斗靠它计分）；
- `notify_direct_hit(bullet.shooter, victim)`（复用激光那条：给射手端发 `hit_confirm` X 标记）。

**不销毁子弹**（原注释已写明：销毁会把引信吞掉、爆炸永不触发）。子弹继续飞、到点爆炸，
爆炸 AoE（`Explosion.apply_aoe`）照旧把爆心半径内的对手算进去。
无射手的爆炸弹（理论上只有敌方弹药）直接跳过，与普通弹的 `shooter == null` 分支同纪律。

### B2 引信（`BulletBase`）

新增公开口 `start_player_fuse()` → `_start_fuse(hit_fuse_time)`。
**纪律不变：首次碰撞决定引信时长、之后不刷新**（撞墙已起 0.4s 的不再因碰人缩短——
用户选的选项没有要打破这条）。直接伤独立于引信闩，碰一次人结算一次。

### B3 两端视觉同步（都靠视觉副本自行判定，无协议改动）

`BulletBase._physics_process` 里，对 `explodes` 且**引信尚未启动**的子弹做一次"碰到玩家"检测：

- 候选 = `player` 组（服务器上=全部玩家；客户端上=本地玩家）∪ `player_replica` 组（客户端上的对手副本）；
- **排除 `shooter`**（否则自己的榴弹一出膛就在自己身上起爆）；
- 命中 → `start_player_fuse()`。

于是：射手端看到自己的榴弹贴到对手就炸；对手端看到飞来的榴弹贴到自己就炸。
服务器与客户端用的是**同一段代码 + 同一半径常量**，只有判定对象随所在端不同。

服务器上这段与 B1 是"两次检测"，但同半径、同候选集，不会给出不同结论；引信侧本身幂等
（`_start_fuse` 只在未启动时定时长），伤害侧由 B1 的 meta 闩独管。**1 帧的顺序差可忽略**
（子弹在树里是 `get_viewport()` 的子节点，与 `MatchHost` 的步进顺序不固定；0.15s 引信对 16ms 不敏感）。

### B4 半径单一来源

新增 `BulletBase.PLAYER_HIT_RADIUS := 40.0`（原 `MatchHost.HIT_RADIUS` 的值与语义），
`MatchHost.HIT_RADIUS` 改为引用它。现在两处各写一遍 `40.0`，将来只改一处。

### B5 不做

- **榴弹不因碰人反弹**：轨迹不变 → 服务器与客户端视觉副本不会因"反弹法线取自不同位置"而发散。
- **不做"已起长引信也立刻缩短"**（见 B2 纪律）。
- **不给榴弹加物理碰撞层 2**：那会让服务器弹与视觉副本弹在不同位置反弹，且会与射手自己碰撞。

---

## C. 验证

### C1 新探针 `tests/replica_ghost_probe.tscn`（场景模式；判据 grep `REPLICA GHOST PROBE: ALL-OK`）

1. **几何/行为**：本地 `Player` 朝副本推进 → 被挡住（不越过）。
   **反证**：把幽灵体的 `collision_layer` 置 0 → 直接穿过去。两条一起才说明是"幽灵体在挡"。
2. **C2 判据（这条才是"贴身回滚治好了"的证据）**：同一世界里放两具占位体，
   A（权威）的 mask 含**备用层**、只被层 X 的占位体挡住；P（预测）的 mask 含层 2、只被幽灵体挡住；
   两者占位体放在**同一坐标**→ A 与 P 的轨迹应逐 tick 一致 → 持续顶住时 `rollback_count()` ≈ 0。
   **反证**：把幽灵体层清零 → P 穿过去 → `rollback_count()` 显著上升。
3. **源码守卫**：`scenes/pvp_client.gd` 与 `scenes/royale_game.gd` 里各存在一行
   `collision_mask |= 2`（这条是"不许被静默删掉"的钉子，不是实现细节）。

### C2 榴弹（扩 `tests/grenade_smoke.gd`）

- 碰玩家起 **0.15s** 短引信（约 9 帧内爆），而非撞墙的 0.4s；
- 已起 0.4s 长引信时再碰玩家**不缩短**，但直接伤照结算；
- 视觉副本（`apply_damage = false`）同样会起短引信。

### C3 回归硬门

`enemy_logic_smoke`（`player mask == 5` 仍成立）、`player_contract_smoke`、
`pvp_match_smoke` / `pvp_reconcile_smoke` / `pvp_twin_smoke` 任何一条绿变红即停。

---

## D. 大乱斗压力勘察（先诊断不修）

### D1 新探针 `tests/royale_soak_probe.tscn`（自当大厅/裁判）

- `-- --clients=N`（默认 4）。**N 个客户端跑真 `royale_game` 场景**（不是轻量计数客户端——
  卡顿就发生在建图/副本/HUD 这个世界里），全链路走真流程：
  `start_client(大厅) → lobby_name → royale_create/royale_join → go_match → 转连 worker
  → claim_role + player_options → match_start → royale_game`。
- 每个客户端把本地玩家的 `input_source` 换成脚本机器人（`tests/soak_bot_input.gd extends InputSource`），
  按脚本循环走完局内行为：移动 / 跳 / 冲刺 / 下蹲 / 爬梯链 / 下水 / 切枪 / 各武器开火 /
  榴弹 / 激光 / K 自杀 / 被击杀后复活。机器人**遵守 `frozen`**（COUNTDOWN 冻结期返回中性值）。
- 埋点（每客户端写一份结果文件）：
  - 墙钟帧时间（`_process` 间隔）avg / p95 / max；
  - **>33ms 帧数**、**>100ms 卡顿次数**（含发生时刻，便于对回对局事件）；
  - 收到快照**字节/秒**（`var_to_bytes(snap).size()` 累加）；
  - **快照到达间隔的 max / p95**（这条量的是"worker 侧是否卡"——从客户端视角看服务器停顿）；
  - 收到的 `round_state` / `kill_event` / `snapshot` 计数；
  - 进程正常退出与否。
- 裁判汇总各客户端结果 + 是否在限定时间内跑完 + worker 子进程是否存活。

### D2 源码审计（与 D1 并行）

逐条走查并给出**行号级定位**：快照体积与分片、输入队列无上限、`_seen_bullets` 不清理、
开局 N-1 个副本集中实例化（每个都全量实例化 `Player.tscn` 再 `free`）、minimap/HUD 每帧成本、
`round_state` 广播频率与载荷、回合/拆除/换场路径、客户端 `_local` 的失效引用检查。

### D3 产出

一份「实测数字 + 源码定位 + 分级（崩溃 / 大卡顿 / 轻微）」的文档放 `docs/`。
**先诊断不修**——用户已裁定大乱斗联机要整套换成 1v1 那套，原生方案的问题不单独修。
真出现**崩溃级**问题单独拎出来问用户。

### D4 边界（先说清，不许含糊）

- headless 客户端**没有渲染**：量到的是**网络 + 模拟 + 场景树**成本，**不含画面**。
  报告里明确标出"这栏 headless 量不到"；判渲染卡顿必须用户自己开真客户端连同一局。
- **输入积压（`_pending_input` 无上限）在 localhost 压测里量不到**：大乱斗客户端的输入包**不带 `seq`**
  （`royale_game.gd` 的 `pkt` 无该字段，`match_host._on_input` 读 `pkt.get("seq", ...)` 恒取默认），
  故 `ack_seq` 在快照里恒为 0、客户端无从推算积压；且本机 60Hz 上行不会超过 60Hz 消费。
  这条只能作为**代码级发现**给出机制与触发条件，不作实测数字上报。

---

## E. 不做的事

- 不动 C2 四条不变量（`tests/kh_l5_probe.gd` 守着）。
- 不给大乱斗接 C2（那是 `2026-09-11-royale-netplay-1v1-alignment.md` 的整批工作，本设计只把
  幽灵碰撞体这一块**提前**做掉，因为它对 1v1 是即刻收益）。
- 不为兼容 KH 原生流程保留其结构；不顺手清大乱斗其余小毛病。
- 不加新的 `class_name`（新全局类需 `--import` 刷缓存，本设计一律用 `preload`）。
