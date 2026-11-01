# 联机快照：现状、实测、与主流做法的对照

> 真相源：源码 > 探针实测 > 本文档。行号只在写下那天成立，引用前先 `grep` 复核。
> 结构化诊断（`--diag` / `CYR_DIAG=1`）与运维审计口径见 [`tests.md`](tests.md)。

## 1. 频率与载荷

### 1.1 下行 60Hz，tick 域也是 60Hz

`server/match/match_state.gd`：

| 常量 | 值 |
|---|---|
| `SNAPSHOT_HZ` | `60`（所有人数的对局） |
| `SNAPSHOT_INTERVAL` | `1.0 / SNAPSHOT_HZ` |
| `SNAPSHOT_STRIDE` | `60 / SNAPSHOT_HZ` = `1` |

- 物理模拟 60Hz。快照 `tick` 是 60Hz 物理 tick 域的时间戳，每包 `+= 1`，一个包跨 1 个物理 tick。
- 触发：`server/match/match_host.gd` 的整数相位 `_snapshot_tick_phase`，满 `SNAPSHOT_STRIDE` 广播一次（浮点累加在整除边界会漂）。
- stride 必须整除 60；发包率变化不改协议、不改客户端 playout/历史环的 tick 刻度。
- 同一相位决定"本 tick 是否消费一条输入记录"（见 §3）；输入上行自 2026-11-01 改回 60Hz 单记录包（`INPUT_BATCH_TICKS=1`，一包一条记录），与下行发包率无关（此前的 30Hz 一包两条已废弃）。
- ★ 2026-10-30：从"≤6 人 60Hz / >6 人 30Hz"改为**全部 60Hz**（用户指定）—— 样本间隔一律 16.7ms；代价见 [`netcode-at-16-players.md`](netcode-at-16-players.md) §1（16 人局服务端上行 ≈0.6 MB/s）。

### 1.2 世界包：一次广播，13 字段

`server/match/match_snapshot.gd::_broadcast_snapshot()`：

```gdscript
var world := {"tick": _snap_tick, "players": {}}
# 每个 role 一条：pos / vel / facing / pose / type_id / hp / waterproof /
#                  downed / aim / previewing / haste / rewind / trail
NetBus.rpc("snapshot_world", NetCodec.encode_world(world))
```

- 世界包含自己那一份；客户端**刻意不消费**（C2 下本地玩家自步进，权威整态走本人包）。
- `previewing` 服务端带、客户端不消费（预瞄线只有本人可见）。
- `trail` 是回溯轨迹点数组（每 3 帧一个点），线上最多 `NetCodec.TRAIL_WIRE_MAX := 4` 点。
- 传输：`snapshot_world` 是 `unreliable`、`transfer_channel = 0`（ENet 道 1）。通道契约见 [`netplay-rpc-channels.md`](netplay-rpc-channels.md)。

### 1.3 本人包：逐 peer，`ack` + `q` + 权威整态

同一函数后半段，对每个 live peer 定向：

```gdscript
NetBus.rpc_id(peer, "snapshot_own",
        NetCodec.encode_own({"ack_seq": _ack_seq.get(role, 0), "q": q.size(), "c2": c2}))
```

- `ack_seq` = 该 role 已消费输入记录的 seq。
- `q` = 该 role 已到达但未消费的输入**记录**数。
- `c2` = `player.capture_state()`：**25 个标量 + 武器块 8 个（仅手持非空时）+ 整个背包表**。字段表在 `core/net/net_codec.gd` 的 `C2_SCHEMA` / `WEAPON_SCHEMA` / `INV_SCHEMA`。
- `c2` 是 C2 回滚的锚点：客户端 `restore_state()` 后用未确认输入重放。
- ★ **S1（2026-10-24）发送时机**：本人包不在世界包广播里发，而是 MatchHost 在**消费完本 tick 输入后 call_deferred**、由 `send_own_snapshots()` 在帧末（Player 子节点步进完之后）发。⇒ `ack` 与 `c2` 是同一 tick 的最新权威态（旧实现落后一拍且要等下一次 30Hz 广播）；代价是**世界包里自己那份比本人包旧 1 tick**（客户端本来就不消费世界包的自己那份）。
- 传输：`snapshot_own` 是 `unreliable`、`transfer_channel = 0`（ENet 道 1）。

### 1.4 线格式与载荷

- `core/net/net_codec.gd` 用一张 schema 表 + 手打包成 `PackedByteArray`（快照 + 输入同模块）。首字节 `PROTO_VERSION := 8`（**7→8 两端必须同版**：2026-11-01 输入上行改回 60Hz 单记录包；**6→7** 是 DELTA 编解码删除 + trail 改定点），第二字节种类（`KIND_WORLD` / `KIND_OWN` / `KIND_INPUT`）。
- ★ 2026-10-24 bool 打包：bool 按**记录**打包成 1 B 标志字节（`T_BOOLS`；世界 4 个 / `c2` 7 个 / 武器块 3 个）。**不是跨字段位流** —— 收益等价（世界条目当时 51→48 B、本人包 102→94 B）但不需要 bit 游标与 padding 校验，解码也不会因尾部 padding 判据制造误红/误绿；代价是组内对齐浪费 ≤7 bit。小整数位宽 / 真位流留给后续（要先登记每字段值域）。
- ★ 2026-10-26 **P1 字段定点化**（`PROTO_VERSION 4→5`）：世界包 `pos` / `vel` → 2×i16（**0.5px** / 0.5px·s⁻¹ 步长；i16 只有 ±32767，0.1px 步长装不下 9600px 地图）、`aim` → u8 角度（256 向）；输入包 `aim` → 2×i16（1e-4 定点，解码后 normalize）。★ `c2` / 本人包**不动** —— 它是 C2 回滚锚点，单方面量化会让每次重放判分歧；世界包字段都是渲染量，量化是两端同版一起换。误差与方案见 [`netcode-delta-and-quantization-details.md`](netcode-delta-and-quantization-details.md) §6。
- ★ 2026-10-30 **DELTA 删除 + trail 定点化**（`PROTO_VERSION 6→7`）：生产 2026-10-28 已回退全量，差分只剩探针在养 ⇒ 这次把差分编解码**整体删除**（线格式真相从 3 份回到 1 份）；`trail` 从 2×float32 改 2×i16（0.5px 步长，与 pos/vel 同 Q_SCALE）⇒ 世界条目 33→25 B、最坏世界包 791→536 B。
- ★ 2026-10-24 编码侧性能：解码仍表驱动（`_unpack` 逐字段守边界），**编码侧手写内联**（`out.encode_float(i, v)` + 下标写，一次性按 `_schema_bytes()` 预算容量、末尾 `resize(i)` 收尾）。实测 `encode_world`（N=16）**304 → 40~49 µs/包**（一次性量具 `.superpowers/net/encode_timing.gd`；同文件的剖面实测「只 resize」= 0.2 µs ⇒ 瓶颈是**逐字段 GDScript 调用**，不是分配）。代价：编码顺序/宽度与 schema 成了两份 —— 漂移由 `snapshot_size_probe` 的往返判据抓（解码按 schema 读，顺序/宽度错 = 值必不对）。★ v7 起只剩 FULL 一条路径，编码与解码各只有一种形状。
- 两端版本不一致 ⇒ 解码返回空字典、调用方不 emit，`net_bus.gd` 的输入解码口只报一次错。
- v7 之后：世界包 `pos`/`vel`/`trail` 定点（2×i16，0.5px 步长）、`aim` u8 角度；`c2` 仍 float32 全量。

载荷口径（trail 2 点、装枪 + 1 件背包）：

| 包 | 载荷 |
|---|---|
| 世界包 FULL 头 | 8 B（版本 1 + 种类 1 + flags 1 + tick 4 + 人数 1） |
| 世界包每人条目 | **25 B**（role 1 + bool 标志 1 + 定长 14 + trail(1+8)；trail 2 点）；不在回溯时 **17 B** |
| 本人包 | **99 B**（头 13：版本/种类/flags/tick/ack/q/武器标志 + `c2` 67 + 武器 12 + 背包 7） |
| 输入包 | **42 B**（头 2 + 记录 40 = **两条连续 tick 记录**；`held` 必须 u16，见 [`netcode-input-uplink.md`](netcode-input-uplink.md)）。P1 前 46 B |

按 60Hz 折算（v7：世界包每人条目 25 B、本人包 99 B/包；服务器上行按扇出算，世界包每个 peer 一份）：

| N | 世界包/包（trail 2 点） | 服务器上行 | 单端下行 |
|---|---|---|---|
| 2 | 58 B | ≈18.8 KB/s | ≈9.4 KB/s |
| 8 | 208 B | ≈147 KB/s | ≈18.4 KB/s |
| 16 | 408 B | ≈487 KB/s | ≈30 KB/s |

★ 对比：v6 同口径（trail float32）N=16 世界包 536 B、上行 ≈610 KB/s；v7 因 trail 定点化降到 408 B / ≈487 KB/s。空 trail 时 N=16 世界包 280 B ⇒ 上行 ≈364 KB/s。★ `snapshot_size_probe` 的 N 表把世界包只计一份（不乘接收端数），引用它的"服务器上行"列时先换算。

### 1.4.1 DELTA 已删除（v7）
- 2026-10-26 的 P1.5 差分（世界包滚动关键帧 + 逐玩家 mask、本人包 60 tick 错峰全量）在 2026-10-28 就因 unreliable 乱序/丢包下 RTT 级冻结而**生产停用**；2026-10-30（v7）连同 `encode_world(...,false)` / `encode_own(...,false)` / `apply_world` / `apply_own` / mask 机制一起**从代码删除**。
- 现在只有一种形态：每包全量、自包含 —— 乱序只丢旧 tick、丢包只损失那一帧；没有 `base_tick` 链、没有 `BIT_NEED_FULL` 请求路径（输入包里的 512 位保留但恒不置位）。
- 历史细节（差分协议本身）保留在本文 git 历史与 [`netcode-delta-and-quantization-details.md`](netcode-delta-and-quantization-details.md) §7（已标注"已删除"）。

### 1.5 分片

- ENet MTU 预算 1400 B（`tests/probe/snapshot_size_probe.gd` 的 `WORLD_PACKET_BUDGET`）。`unreliable` = `UNSEQUENCED | UNRELIABLE_FRAGMENT` ⇒ 丢任意一片 = 整帧丢。
- 世界包 = `8 + N × 25`（trail 2 点）：16 人 **408 B**、空 trail **280 B**；最坏（16 人各 4 点 trail）= `8 + 16 × 33 = **536 B**`，都恒 1 片（v6 为 791 B、P1 前 1031 B）。
- 本人包 **99 B**、输入包 **42 B**，都不分片。
- `NetCodec.TRAIL_MAX := 16` 是解码侧硬顶（长度是不可信输入），与发送侧 `TRAIL_WIRE_MAX` 不是同一个数。
- 改世界字段 / `TRAIL_WIRE_MAX` 前先跑 `tests/probe/snapshot_size_probe.tscn`（判词 `SNAPSHOT SIZE PROBE: ALL-OK`，量真实产出并带条数闸）。

### 1.6 客户端消费与丢弃

| 包 | 处理 | 丢弃规则 |
|---|---|---|
| 世界包 | `net_bus.snapshot_world` 解码后 emit 完整 `{tick, players}` → 三模式 `_on_snapshot_world` 只喂对手副本 | `tick <= 已应用 tick` ⇒ 丢（新的赢） |
| 本人包 | `net_bus.snapshot_own` 解码后 emit 完整 `c2` → [`pvp_match_client.gd`](../../scenes/pvp_match_client.gd) `_on_snapshot_own` → `_rollback.on_authoritative(ack, c2)` | ① `ack > seq`（判据在 `InputUplink.accept_ack`）⇒ 丢（跨纪元残留）；② `ack <= _acked` 由 [`prediction_rollback.gd`](../../core/net/prediction_rollback.gd) 挡 |

`unreliable` 不保证顺序，"新的赢"是唯一正确的做法；丢弃不产生延迟累加。重连时 `NetBus.reset_snapshot_state()` 作废合并基准。

## 2. 远端副本：playout 缓冲插值

> **实现细节的权威**:[`netcode-client-interp-and-input-details.md`](netcode-client-interp-and-input-details.md)(playout 缓冲、夹逼/Hermite、`SNAP_DIST`、幽灵体、锚定)。本节只留下面的服务器侧命中回放时间域(本文件独有)。


### 2.1 时间域解耦：服务器命中回放（2026-10-26）

- 同一个 `PLAYOUT_TICKS` 用在两处：客户端**渲染**远端副本时的延迟，和服务器**裁决命中**时的回放深度（`core/net/lag_comp.gd` 单一来源）。
- 服务器 tick 域对齐：`MatchHost._physics_process` 每 tick 起始 `_srv_tick += 1`；`_broadcast_snapshot` 里 `_snap_tick = _srv_tick`（2026-10-30 起每 tick 都广播 ⇒ tick 数值序列连续）。客户端输入包里的 `st` 从此与服务器 tick **同一刻度**。
- 裁决路径（`server/match/match_combat.gd`）：`st = _client_snap_tick[shooter]`（射手最近解码的快照 tick）⇒ `want = clamp(st - PLAYOUT_TICKS, _srv_tick - MAX_REWIND_TICKS, _srv_tick)` ⇒ 用 `HitLagHistory.rect_for(victim, want)` 取**射手观看时刻**的对手受击面，再走 `HitShape` 线段扫掠（含子弹体积 grow）。榴弹直击同一路径。
- 历史环 `core/sim/hit_lag_history.gd`：每 tick 存 `role → {p: canonical 位置, r: 相对受击面的 Rect2}`，容量 24 tick（400ms），超限丢最老；无该 tick/该 role 时回退现时受击面。
- **不动的部分**：移动预测继续吃最新态（幽灵体不接插值、位置照旧）；爆炸 AoE **不回放**（现时位置，见 registered-debt §十五）。协议字节零改动。

### 2.2 受击事件时刻对齐（2026-10-28）

- **锚点**：`hit_event` 携带 `seq` = **受击方上一条已完成步进的输入记录 seq**（`MatchState._stepped_seq`，帧末 `call_deferred("_record_stepped_seq")` 记录；首帧无记录时退回 `max(ack−1, 0)`）。★ 不是当帧 `_ack_seq`：命中裁决在 `MatchHost._physics_process` 回调里跑，而 `Player` 是**子节点**、本帧步进在父回调返回之后（父先于子）⇒ 被击中的是 ack−1 那一步之后的状态；传当帧 ack 会让注入晚一步（评审实测差 3.03px / 43.4px·s⁻¹ ⇒ 超 `_close_enough`、仍回滚）。★ 也不用 `_srv_tick`：输入饥饿时它与 ack 脱钩。
- **客户端**：`PvpMatchClient._apply_local_hit_event` 调 `PredictionRollback.apply_external_event(seq, take_hit)`：恢复 `_captures[seq]` → 执行 `take_hit` → 重放 `(seq, last_applied]`（与 `_handle_ack` 共用 `_replay_steps_after`）⇒ 本地击退曲线与服务器同源，不必等下一个 ack 再 restore。该注入**不计入** `_rollbacks`（不是"预测被证伪"）。
- **事件重放**：注入的 callable 存进 `_events[seq]`，之后任何一次回滚重放跨过该 seq 时会重新应用（否则迟到旧 ack 的 restore 会把这一发抹掉）。同 seq 多发的第二发只应用"新来的那一发"（`_captures[seq]` 已含该 seq 更早事件的效果，避免重复扣血）。
- **物理帧注入**：网络回调跑在 idle 帧，而注入的重放内部是 `move_and_slide()` —— 物理帧外它按**渲染帧 delta** 缩放（实测同一速度跨 idle 帧位移 0.01~2px 不等；首帧前才是 0）⇒ 帧外重放随帧率变、会算错轨迹。故回调只把事件压进 `_pending_hit_events`，由下一个物理帧开头的 `_drain_hit_events()` 注入（排在 `note_post_step` 之前）。代价：受击反馈最多晚 1 帧（≈16.7ms）。重连重建 C2 时队列一起清空（旧 seq 空间作废）。
- **兜底**：`seq` 不可注入（来自未来 / 已 ack / 环外 / 乱序 / callable 失效）⇒ 只播反馈 `take_hit(..., feedback_only=true)`（白闪 / 震屏 / 音效 / 挤压），**不**扣血 / 不击退 / 不设无敌帧：权威 c2 可能已包含这一发，二次应用会在下一个 ack 再判一次分歧。
- **读数**：`-- --netstat` 打印 `事件对齐=累计(+N/s) 拒绝=累计(+N/s)`（`rollback_count()` 之外的独立计数）；`royale_soak` 的每端结果行打 `C2:回滚=… 事件对齐=… 拒绝=…(ack/future/missing/order 分解)` —— 真链路里唯一能证明"注入真的生效了 vs 一直走兜底"的读数。
- **边界**（照实）：① `_captures` 环 256 tick（4.3s），超出只能走兜底；② 服务器饥饿 k tick 时玩家状态比 `_stepped_seq` 前进 k 步（held 输入），注入会**早** k 步（不是保守方向，只是近似）；③ 落水窒息是客户端已预测的伤害 ⇒ 服务端**不**为它广播 `hit_event`（`take_hit(..., cause="water")` → `_on_player_hit` 跳过），客户端因此不会二次应用（2026-10-29 修，见 [`registered-debt.md`](registered-debt.md) §二十三）；④ 事件按 seq 递增到达是契约（reliable 保序），seq 回退一律拒绝。
- **守卫**：[`tests/probe/rollback_fidelity_probe.tscn`](../../tests/probe/rollback_fidelity_probe.tscn) 的 D 组（注入 / **真实服务器顺序**的黄金轨迹 / 越界 / 同 seq 双发 / 乱序 / 注入后 reconcile 对独立黄金权威 / 迟到旧 ack 重放带回事件 / 计数）与 E 组（反馈-only），外加源码守卫：客户端 5 条（入队 / 物理帧消费 / 物理帧接线 / 注入唯一 / 兜底第 5 参）+ 服务器 3 条（`_stepped_seq` 锚点 / 帧末记录调度 / 记录写入）。

## 3. 输入队列

`core/net/packet_input_source.gd` + `server/match/input_intake.gd`：

- 上限：`cap = clamp(peak + QUEUE_CAP_MARGIN, QUEUE_CAP_MIN, QUEUE_CAP_MAX)`，即 `[4, 16]`（单位 = 条 tick 记录；U1 后一条 = 1 tick，数值翻倍以保住 [66,266] ms 时间缓冲）。
- `peak` = 最近一次轮询到的**原始**深度（丢之前），每 tick 衰减 1 ⇒ 网络安静时上限自己缩回。
- 满上限时丢**最旧**一条，`pressed` / `released` / `winst` 边沿并入队首。
- `push_pending()` 返回**丢之前**的深度（包络靠它学习）。
- `reset_input_queue(role)` 队列与包络一起清（掉线 / 重连重开纪元）。
- 服务端**每物理 tick 恰消费一条记录**（U1；一包到两条）；队列空 ⇒ 沿用上一包的 held；`clear_edges()` 清边沿。

## 4. 判据与读数

| 数据源 | 在哪 | 读数 |
|---|---|---|
| `snapshot_own.q` | 本人包 | 服务器侧已到达未消费的记录数 |
| `InputUplink` 的 `seq - _last_ack`（S-17 后读数在 `core/net/input_uplink.gd`） | `pvp_match_client.gd` 的 `-- --netstat`（1Hz） | 未确认记录数（在途 + 在队） |
| 服务端 `--netstat` / `--netstat-trace` | `input_intake.gd` | 队列长度 · 抖动上限 · 累计丢弃（1Hz / 前 600 tick 逐帧） |
| `--diag` / `CYR_DIAG=1` | `NetDiag` | `snap_gap`（>150ms）、`snap_rx`、`snapshot_tx`、`queue`、`queue_drop` |

- 正常形状：队列贴近 `QUEUE_CAP_MIN`（= 4 条 = ~67ms），上限在衰减，累计丢弃只在突发后跳一次。
- 坏形状：上限一路顶到 16 不回，或累计丢弃几乎每 tick 都涨。
- 判据一律 grep 判词文本 + 条数闸，不看退出码。

## 5. 与主流做法的对照

| 维度 | 本仓 | 主流 |
|---|---|---|
| 状态发送频率 | 60Hz + 客户端 playout 插值（`PLAYOUT_TICKS = 2` ≈ 33ms 缓冲）+ 服务器按射手观看时刻回放命中 | 10~128Hz + 客户端插值缓冲 |
| 编码 | schema 表手打包（世界 `pos`/`vel`/`trail` 与输入 `aim` 定点化；v7 起先版本字节守门） | 绑定 + 量化 + 位打包 |
| 增量 | 全量自包含（v7 起 DELTA 编解码已删除） | 对已 ack 的基线增量 |
| 客户端时钟 | 本地播放时钟（窗口最小延迟选样），不与服务器做显式时钟同步 | 播放时钟跟服务器时钟 |

## 6. 已知边界

- `c2`（本人包，C2 回滚锚点）仍是 float32 全量；世界包的 `trail` 在 v7 起也已是 i16 定点。量化必须两端同口径（`c2` 只压上行会让每次重放都对不上）。
- ★ 2026-10-26 **P1 定点化**：世界包 `pos`/`vel` 用 **0.5px** 步长（不是 0.1px —— i16 的 ±32767 装不下 9600px×10），量化误差 ≤0.25px/0.25px·s⁻¹；`aim` u8 角度误差 ≤π/256≈0.70°；输入 `aim` 1e-4 定点。位宽/误差详情与风险见 [`netcode-delta-and-quantization-details.md`](netcode-delta-and-quantization-details.md) §6。
- ★ 2026-10-30 **v7 删除 DELTA 的边界**：
  - 世界包/本人包都每包全量自包含 ⇒ 丢包/乱序不再产生"基准断"状态，客户端只需按 tick 去重（`tick <= 已应用` 丢）。
  - 输入包 `BIT_NEED_FULL = 512` 位保留但恒不置位；服务器不再有"补发 FULL"路径（也没有差分状态可补）。
  - **不要把世界包挪到 reliable**（队头阻塞会让整局滞后）。
  - trail 量化误差 ≤0.25px（纯表现，残像点），与 pos/vel 同 Q_SCALE；往返容差见 `net_wire_smoke` / `snapshot_size_probe`。
- ★ 2026-10-24 **U1 上行去锁存**：输入记录 = 1 tick（60Hz 采样），30Hz 包内装两条（流水线），服务器每 tick 消费一条 ⇒ 本地手感不再有 30Hz 锁存延迟。**S1** 把本人包挪到"消费并步进完当帧"发（③ 固定回带已消）；客户端 U1 起本来就每 tick 对账（④ 已消）。**剩下的**只是 30Hz 发包/广播节拍的量化（`--netstat` 的 `gap` 仍有 1~2 条 ×16.7ms 的偏置），不是"等一拍广播"。见 `netcode-input-uplink.md` §5。
- 上行 `st` / `ct`：`ct`（客户端物理帧号）仍**无消费者**；`st` 自 2026-10-26 起是**命中回放的时间基准**（`match_combat._replay_hurt_rect`），不再是"只落位"。
- 没有丢包 / 抖动注入路径 ⇒ 队头阻塞、丢弃率、手感都没有真对局读数。
- 探针量的是**载荷**字节，不含 ENet 分片头 / RPC 方法名 / IP·UDP 头。`royale_soak_probe` 的 KB/s 是解码后 `Dictionary` 的 `var_to_bytes`，不是线上字节，对线格式改动不可见。
- `snapshot_size_probe` 的每秒折算列按 `SNAP_HZ := 60` 算，下行也是 60Hz(v7) ⇒ 单包字节与每秒列都可引用。
- 应用层没有拥塞控制；ENet 自带 throttle 会主动丢 `unreliable` 包（见 [`netcode-delta-and-quantization-details.md`](netcode-delta-and-quantization-details.md)）。
- 人数上限 `ROYALE_MAX_PLAYERS := 16`（`server/lobby/lobby_rooms.gd`）。