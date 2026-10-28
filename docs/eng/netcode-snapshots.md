# 联机快照：现状、实测、与主流做法的对照

> 真相源：源码 > 探针实测 > 本文档。行号只在写下那天成立，引用前先 `grep` 复核。
> 结构化诊断（`--diag` / `CYR_DIAG=1`）与运维审计口径见 [`tests.md`](tests.md)。

## 1. 频率与载荷

### 1.1 下行 30Hz，tick 域仍是 60Hz

`server/match/match_state.gd`：

| 常量 | 值 |
|---|---|
| `SNAPSHOT_HZ` | `30` |
| `SNAPSHOT_INTERVAL` | `1.0 / SNAPSHOT_HZ` |
| `SNAPSHOT_STRIDE` | `60 / SNAPSHOT_HZ` = `2` |

- 物理模拟 60Hz。快照 `tick` 是 60Hz 物理 tick 域的时间戳，每包 `+= SNAPSHOT_STRIDE`，一个包跨 2 个物理 tick。
- 触发：`server/match/match_host.gd` 的整数相位 `_snapshot_tick_phase`，满 `SNAPSHOT_STRIDE` 广播一次（浮点累加在整除边界会漂成 3 tick 一次）。
- `SNAPSHOT_HZ` 必须是 60 的约数（30/20/15/12/10）。不整除会让 stride 被截断，tick 轴与包率同时错。
- 同一相位决定"本 tick 是否消费一条输入记录"（见 §3）。

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

- `core/net/net_codec.gd` 用一张 schema 表 + 手打包成 `PackedByteArray`（快照 + 输入同模块）。首字节 `PROTO_VERSION := 6`（P1.5 增量/差分起；**5→6 两端必须同版**），第二字节种类（`KIND_WORLD` / `KIND_OWN` / `KIND_INPUT`）。
- ★ 2026-10-24 bool 打包：bool 按**记录**打包成 1 B 标志字节（`T_BOOLS`；世界 4 个 / `c2` 7 个 / 武器块 3 个）。**不是跨字段位流** —— 收益等价（世界条目当时 51→48 B、本人包 102→94 B）但不需要 bit 游标与 padding 校验，解码也不会因尾部 padding 判据制造误红/误绿；代价是组内对齐浪费 ≤7 bit。小整数位宽 / 真位流留给后续（要先登记每字段值域）。
- ★ 2026-10-26 **P1 字段定点化**（`PROTO_VERSION 4→5`）：世界包 `pos` / `vel` → 2×i16（**0.5px** / 0.5px·s⁻¹ 步长；i16 只有 ±32767，0.1px 步长装不下 9600px 地图）、`aim` → u8 角度（256 向）；输入包 `aim` → 2×i16（1e-4 定点，解码后 normalize）。★ `c2` / 本人包**不动** —— 它是 C2 回滚锚点，单方面量化会让每次重放判分歧；世界包字段都是渲染量，量化是两端同版一起换。误差与方案见 [`netcode-delta-and-quantization-details.md`](netcode-delta-and-quantization-details.md) §6。
- ★ 2026-10-26 **P1.5 增量/差分**（`PROTO_VERSION 5→6`）：世界包改为**滚动关键帧 + 逐玩家字段掩码**（DELTA），FULL 只在请求/换局/名单变化时发；本人包每包全量(增量已于 2026-10-28 放弃)。协议细节见 §1.4.1，量化/差分边界见 `netcode-delta-and-quantization-details.md` §7。
- ★ 2026-10-24 编码侧性能：解码仍表驱动（`_unpack` 逐字段守边界），**编码侧手写内联**（`out.encode_float(i, v)` + 下标写，一次性按 `_schema_bytes()` 预算容量、末尾 `resize(i)` 收尾）。实测 `encode_world`（N=16）**304 → 40~49 µs/包**（一次性量具 `.superpowers/net/encode_timing.gd`；同文件的剖面实测「只 resize」= 0.2 µs ⇒ 瓶颈是**逐字段 GDScript 调用**，不是分配）。代价：编码顺序/宽度与 schema 成了两份 —— 漂移由 `snapshot_size_probe` 的往返判据抓（解码按 schema 读，顺序/宽度错 = 值必不对）。★ 差分路径（`_enc_value` / `_write_unit_value` / `_read_unit_into`）是**表驱动**的（要按 mask 跳字段，无法内联）；FULL 仍走内联路径。
- 两端版本不一致 ⇒ 解码返回空字典、调用方不 emit，`net_bus.gd` 的输入解码口只报一次错。
- P1.5 之后：世界包 `pos`/`vel`/`aim` 定点、`trail` float32；`c2` 仍 float32 全量。

载荷口径（trail 2 点、装枪 + 1 件背包）：

| 包 | 载荷 |
|---|---|
| 世界包 FULL 头 | 8 B（版本 1 + 种类 1 + flags 1 + tick 4 + 人数 1） |
| 世界包每人条目（FULL） | **33 B**（role 1 + bool 标志 1 + 定长 15 + trail(1+16)）；不在回溯时 **17 B** |
| 世界包 DELTA 头 | 12 B（FULL 头 + base_tick 4；`tick` 仍在） |
| 世界包每人条目（DELTA） | 3 B（role 1 + mask 2）+ 仅变化字段值（典型「只 pos 变」= 7 B/人）；keyframe 条目 = 3 + 32 = **35 B**（全字段） |
| 本人包 FULL | **99 B**（头 13：版本/种类/flags/tick/ack/q/武器标志 + `c2` 67 + 武器 12 + 背包 7） |
| 本人包 DELTA | 20 B（头 12 + base_tick 4 + mask 4）+ 仅变化字段值（典型「pos+vel 变」= 16 B ⇒ **36 B**；静止帧 20 B） |
| 输入包 | **42 B**（头 2 + 记录 40 = **两条连续 tick 记录**；`held` 必须 u16，见 [`netcode-input-uplink.md`](netcode-input-uplink.md)）。P1 前 46 B |

按 30Hz 折算（服务器上行按扇出算：世界包每个 peer 一份；本人包按"全量 1 次/秒 + 差分 29 次/秒、典型差分 36 B"折算）：

| N | 世界包/包（稳态 keyframe 帧） | 本人包/秒/role | 服务器上行 | 单端下行 |
|---|---|---|---|---|
| 2 | 54 B | ≈1.14 KB/s | ≈5.4 KB/s | ≈2.7 KB/s |
| 8 | 96 B | ≈1.14 KB/s | ≈31.4 KB/s | ≈3.9 KB/s |
| 16 | 152 B | ≈1.14 KB/s | ≈89.1 KB/s | ≈5.5 KB/s |

★ 对比：N=16 时 FULL 世界包 536 B ⇒ 稳态 keyframe 帧只有其 28%（增量前的 P1 读数 535 B/包、上行 294.8 KB/s）。★ `snapshot_size_probe` 的 N 表把世界包只计一份（不乘接收端数），引用它的"服务器上行"列时先换算。

### 1.4.1 增量/差分协议（P1.5）

- **世界包**（`KIND_WORLD`）：`flags` bit0 = FULL。FULL 每人定长全字段；DELTA 每人 `role(1) + mask(u16) + 置位字段的值`，
  **mask bit i ↔ `WORLD_SCHEMA[i]`**（单一来源；T_BOOLS / trail 各算 1 位），`mask = 0xFFFF` = 该玩家是 **keyframe**（全字段绝对值）。整员省略 = 本包无变化，客户端沿用上次合并值。
- **滚动关键帧**：`k = max(1, ceil(N × SNAPSHOT_STRIDE / WORLD_KF_PERIOD))`（`world_keyframe_quota`；N=16 ⇒ k=1），每包把 k 个玩家整份刷新、游标轮转 ⇒ 每人在 ≤`WORLD_KF_PERIOD`(60) tick 内被绝对刷新一次。**没有"每 60 tick 整包 FULL"**：那会在 60 tick 边界造出 16×FULL 的尖峰；滚动关键帧让包尺寸平滑（见 `snapshot_size_probe` ⑧的峰值/均值断言）。
- **FULL 触发**：① 任一客户端置 `BIT_NEED_FULL`（见下）；② 回合态变化（换局/复活重置）；③ 名单变化（有人离开/加入）；④ 首个世界包。FULL 之后基准重置。
- **本人包**（`KIND_OWN`）：**30Hz，每包全量**（2026-10-28 放弃增量,恢复 v0.5.1 口径）。
- **乱序/丢包**：全量包自包含 ⇒ 乱序只丢旧 tick、丢包只损失那一帧；不再有 `base_tick` 链与 FULL 请求路径（DELTA 编解码能力保留但生产不发）。FULL 每人每 `OWN_FULL_PERIOD`(60) tick 一次，**相位错峰**：`phase = floor(idx × (60/2) / N) × 2` tick（`own_full_phase`；N=16 ⇒ 0,2,…,仍互异），其余 DELTA；DELTA 覆盖 `capture_state()` 全部字段（**位序 = `C2_SCHEMA` 条目序 → `WEAPON_SCHEMA` → 末尾 `inv`**，见 `_own_unit_at`）——错一位 = C2 预测漂移。武器块存在性变化强制 FULL（差分表达不了"字段消失"）。
- **修复路径**：客户端 `net_bus.gd` 在**解码边界**合并（FULL 替换 / DELTA 覆盖），下游仍收完整 `{tick, players}` / `{ack_seq, q, c2}`（三模式客户端、探针、watcher 零改动）。`base_tick` 不连续（丢包/重连/乱序）⇒ 置 `BIT_NEED_FULL`（输入 `held` 的 512 位，走 reliable 输入通道）⇒ 服务器下一世界包发 FULL 给所有人 / 该 role 下一本人包发 FULL。本人包另有 60 tick 全量兜底；世界包**只有**上述请求路径（滚动关键帧只保证每人 ≤60 tick 的绝对刷新，整包基准仍必须连续）。

### 1.5 分片

- ENet MTU 预算 1400 B（`tests/probe/snapshot_size_probe.gd` 的 `WORLD_PACKET_BUDGET`）。`unreliable` = `UNSEQUENCED | UNRELIABLE_FRAGMENT` ⇒ 丢任意一片 = 整帧丢。
- 世界包 FULL = `8 + N × 33`（P1 后、trail 2 点）：16 人 **536 B**；稳态 keyframe 帧 = `12 + 35 + (N-1) × 7`（N=16 ⇒ **152 B**）；最坏（FULL、16 人各 4 点 trail）= `8 + 16 × 49 = **792 B**`，都恒 1 片（P1 前 FULL 1031 B）。
- 本人包 FULL **99 B**、差分典型 **36 B**，不分片。
- `NetCodec.TRAIL_MAX := 16` 是解码侧硬顶（长度是不可信输入），与发送侧 `TRAIL_WIRE_MAX` 不是同一个数。
- 改世界字段 / `TRAIL_WIRE_MAX` / 差分位序前先跑 `tests/probe/snapshot_size_probe.tscn`（判词 `SNAPSHOT SIZE PROBE: ALL-OK`，量真实产出并带条数闸）。

### 1.6 客户端消费与丢弃

| 包 | 处理 | 丢弃规则 |
|---|---|---|
| 世界包 | `net_bus.snapshot_world` **合并成完整 `{tick, players}`** 后 emit → 三模式 `_on_snapshot_world` 只喂对手副本（形状与增量前一致） | `tick <= 已应用 tick` ⇒ 丢（新的赢）；DELTA `base_tick ≠ 已应用 tick` ⇒ 请求 FULL 且**不 emit** |
| 本人包 | `net_bus.snapshot_own` 合并成完整 `c2` 后 emit → [`pvp_match_client.gd`](../../scenes/pvp_match_client.gd) `_on_snapshot_own` → `_rollback.on_authoritative(ack, c2)` | ① `ack > _input_seq` ⇒ 丢（跨纪元残留）；② `ack <= _acked` 由 [`prediction_rollback.gd`](../../core/net/prediction_rollback.gd) 挡；③ DELTA 基准断 ⇒ 请求 FULL |

`unreliable` 不保证顺序，"新的赢"是唯一正确的做法；丢弃不产生延迟累加。重连时 `NetBus.reset_snapshot_state()` 作废合并基准。

## 2. 远端副本：playout 缓冲插值

- [`player_replica.gd`](../../scenes/player/player_replica.gd) `apply_snapshot` 把快照位置塞进定长历史环并喂播放时钟；`_process` 在「最新 − `PLAYOUT_TICKS`」那一刻对两条相邻快照夹逼插值。
- `PLAYOUT_TICKS = 3`（60Hz tick 域；单一来源 `core/net/lag_comp.gd`）；下行 30Hz ⇒ **1.5 个发包间隔 ≈ 50ms 缓冲**，也是「画面比权威晚多少」的旋钮。
- 无外插：取样比最新还新（underrun）冻在最新；比最老还老冻在最老。跨接缝那一对样本先锚进同一副本空间再 lerp。
- `SNAP_DIST = 128 px`：相邻样本的环面距离超它 ⇒ 清历史、一帧落位（回溯 / 重生 / 换边）。
- [`player_replica.gd`](../../scenes/player/player_replica.gd) 的 `_clock` 是 `core/net/playout_clock.gd`（窗口最小延迟选样的本地播放时钟，不与服务器做时钟同步、不做速率纠偏以外的动作）。
- 幽灵体（`_build_ghost_body`，`StaticBody2D`，层按队配）**不跟插值**：跟未经平滑的 `target`，预测面要最小陈旧。
- 两个 `anchor_to_nearest` 是承重的：渲染位置与目标相隔整幅地图时最短向量为 0 ⇒ 副本会永远留在远副本。
- `aim` / `pose` / `facing` 逐包瞬跳。`_aim` 是单位向量，若加插值必须 `slerp` 或 `lerp_angle`（直接 `lerp` 会穿原点）。

### 2.1 时间域解耦：服务器命中回放（2026-10-26）

- 同一个 `PLAYOUT_TICKS` 用在两处：客户端**渲染**远端副本时的延迟，和服务器**裁决命中**时的回放深度（`core/net/lag_comp.gd` 单一来源）。
- 服务器 tick 域对齐：`MatchHost._physics_process` 每 tick 起始 `_srv_tick += 1`；`_broadcast_snapshot` 里 `_snap_tick = _srv_tick`（广播相位仍每 2 tick ⇒ tick 数值序列不变）。客户端输入包里的 `st` 从此与服务器 tick **同一刻度**。
- 裁决路径（`server/match/match_combat.gd`）：`st = _client_snap_tick[shooter]`（射手最近解码的快照 tick）⇒ `want = clamp(st - PLAYOUT_TICKS, _srv_tick - MAX_REWIND_TICKS, _srv_tick)` ⇒ 用 `HitLagHistory.rect_for(victim, want)` 取**射手观看时刻**的对手受击面，再走 `HitShape` 线段扫掠（含子弹体积 grow）。榴弹直击同一路径。
- 历史环 `core/sim/hit_lag_history.gd`：每 tick 存 `role → {p: canonical 位置, r: 相对受击面的 Rect2}`，容量 24 tick（400ms），超限丢最老；无该 tick/该 role 时回退现时受击面。
- **不动的部分**：移动预测继续吃最新态（幽灵体不接插值、位置照旧）；爆炸 AoE **不回放**（现时位置，见 registered-debt §十五）。协议字节零改动。

### 2.2 受击事件时刻对齐（2026-10-28）

- **锚点**：`hit_event` 携带 `seq` = **受击方已消费输入记录的 seq**（服务器广播前读 `_ack_seq[victim]`），与快照 `ack`、客户端 `_captures` 同一 seq 空间。★ 不用 `_srv_tick`：服务器输入饥饿（队列空、沿用上一条 held）时 `_ack_seq` 不前进而 `_srv_tick` 每 tick +1，两者会漂。
- **客户端**：`PvpMatchClient._apply_local_hit_event` 调 `PredictionRollback.apply_external_event(seq, take_hit)`：恢复 `_captures[seq]` → 执行 `take_hit` → 重放 `(seq, last_applied]`（与 `_handle_ack` 同一条 `_step` 路径）⇒ 本地击退曲线与服务器同源，不必等下一个 ack 再 restore。该注入**不计入** `_rollbacks`（不是"预测被证伪"）。
- **兜底**：`seq` 不可注入（来自未来 / 已 ack / 环外 / 乱序）⇒ 只播反馈 `take_hit(..., feedback_only=true)`（白闪 / 震屏 / 音效 / 挤压），**不**扣血 / 不击退 / 不设无敌帧：权威 c2 可能已包含这一发，二次应用会在下一个 ack 再判一次分歧。
- **边界**（照实）：① `_captures` 环 256 tick（4.3s），超出只能走兜底；② 服务器饥饿时 seq 指向上一条记录，注入差 1 tick（方向偏保守）；③ 落水窒息是客户端已预测的伤害，`hit_event` 仍会二次应用（见 [`registered-debt.md`](registered-debt.md) §二十三）；④ 事件按 seq 递增到达是契约（reliable 保序），seq 回退一律拒绝。
- **守卫**：[`tests/probe/rollback_fidelity_probe.tscn`](../../tests/probe/rollback_fidelity_probe.tscn) 的 D 组（注入 / 黄金轨迹 / 越界 / 同 seq 双发 / 乱序）与 E 组（反馈-only），外加三条源码守卫（本人分支 → `_apply_local_hit_event`、注入唯一、兜底第 5 参 true）。

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
| `_input_seq - _last_ack` | `pvp_match_client.gd` 的 `-- --netstat`（1Hz） | 未确认记录数（在途 + 在队） |
| 服务端 `--netstat` / `--netstat-trace` | `input_intake.gd` | 队列长度 · 抖动上限 · 累计丢弃（1Hz / 前 600 tick 逐帧） |
| `--diag` / `CYR_DIAG=1` | `NetDiag` | `snap_gap`（>150ms）、`snap_rx`、`snapshot_tx`、`queue`、`queue_drop` |

- 正常形状：队列贴近 `QUEUE_CAP_MIN`（= 4 条 = ~67ms），上限在衰减，累计丢弃只在突发后跳一次。
- 坏形状：上限一路顶到 16 不回，或累计丢弃几乎每 tick 都涨。
- 判据一律 grep 判词文本 + 条数闸，不看退出码。

## 5. 与主流做法的对照

| 维度 | 本仓 | 主流 |
|---|---|---|
| 状态发送频率 | 30Hz + 客户端 playout 插值（`PLAYOUT_TICKS = 3` ≈ 50ms 缓冲）+ 服务器按射手观看时刻回放命中 | 10~30Hz + 客户端插值缓冲 |
| 编码 | schema 表手打包（P1 世界 `pos`/`vel`/`aim` 与输入 `aim` 定点化；P1.5 世界/本人包差分） | 绑定 + 量化 + 位打包 |
| 增量 | 全量自包含（世界/本人包；增量 P1.5 已于 2026-10-28 放弃） | 对已 ack 的基线增量 |
| 客户端时钟 | 本地播放时钟（窗口最小延迟选样），不与服务器做显式时钟同步 | 播放时钟跟服务器时钟 |

## 6. 已知边界

- `c2`（本人包，C2 回滚锚点）仍是 float32 全量；世界包的 `trail` 也仍是 float32。渲染字段只剩 `trail` 未量化 —— 它是变长数组、重复度低，量化收益 <1 B/点。量化必须两端同口径（`c2` 只压上行会让每次重放都对不上）。
- ★ 2026-10-26 **P1 定点化**：世界包 `pos`/`vel` 用 **0.5px** 步长（不是 0.1px —— i16 的 ±32767 装不下 9600px×10），量化误差 ≤0.25px/0.25px·s⁻¹；`aim` u8 角度误差 ≤π/256≈0.70°；输入 `aim` 1e-4 定点。位宽/误差详情与风险见 [`netcode-delta-and-quantization-details.md`](netcode-delta-and-quantization-details.md) §6。
- ★ 2026-10-26 **P1.5 增量/差分边界**（详表见 `registered-debt.md` §十八）：
  - 世界包 DELTA 走 unreliable：丢 1 包 ⇒ 客户端 `base_tick` 断 ⇒ 丢包 + 请求 `BIT_NEED_FULL` ⇒ 服务器下一 30Hz 广播发 FULL（**RTT + ≤33ms**，不是等周期）。没有周期性整包 FULL；滚动关键帧只兜"每个玩家 ≤60 tick 被绝对刷新"。
  - 本人包 DELTA 丢：下一包基准断 ⇒ 请求 FULL；即使请求路径失效也有 **60 tick（1s）全量兜底**。
  - `BIT_NEED_FULL = 512`（输入 `held` 保留位，reliable 通道）：位重复发送无害，FULL 到达后清除。**不要把世界包挪到 reliable**（队头阻塞会让整局滞后）。
  - 差分判等：世界按量化后整数（pos/vel 定点整数、aim 角度字节、bool 逐位）；本人包 float 字段用 **1e-4 容差**（被省略的字段客户端最多陈旧 1e-4，远小于 C2 对账的 pos 2px / vel 20 容差）。武器块存在性变化强制 FULL。
  - 相位：本人包 FULL 相位 = `floor(idx×30/N)×2` tick，N≤30 时互不重合（N>30 才可能重合，仍 ≤1s 周期）。
- ★ 2026-10-24 **U1 上行去锁存**：输入记录 = 1 tick（60Hz 采样），30Hz 包内装两条（流水线），服务器每 tick 消费一条 ⇒ 本地手感不再有 30Hz 锁存延迟。**S1** 把本人包挪到"消费并步进完当帧"发（③ 固定回带已消）；客户端 U1 起本来就每 tick 对账（④ 已消）。**剩下的**只是 30Hz 发包/广播节拍的量化（`--netstat` 的 `gap` 仍有 1~2 条 ×16.7ms 的偏置），不是"等一拍广播"。见 `netcode-input-uplink.md` §5。
- 上行 `st` / `ct`：`ct`（客户端物理帧号）仍**无消费者**；`st` 自 2026-10-26 起是**命中回放的时间基准**（`match_combat._replay_hurt_rect`），不再是"只落位"。
- 没有丢包 / 抖动注入路径 ⇒ 队头阻塞、丢弃率、手感都没有真对局读数。
- 探针量的是**载荷**字节，不含 ENet 分片头 / RPC 方法名 / IP·UDP 头。`royale_soak_probe` 的 KB/s 是解码后 `Dictionary` 的 `var_to_bytes`，不是线上字节，对线格式改动不可见。
- `snapshot_size_probe` 的每秒折算列按 `SNAP_HZ := 60` 算，下行实际 30Hz ⇒ 只看它的单包字节，别引用每秒列。
- 应用层没有拥塞控制；ENet 自带 throttle 会主动丢 `unreliable` 包（见 [`netcode-delta-and-quantization-details.md`](netcode-delta-and-quantization-details.md)）。
- 人数上限 `ROYALE_MAX_PLAYERS := 16`（`server/lobby/lobby_rooms.gd`）。
