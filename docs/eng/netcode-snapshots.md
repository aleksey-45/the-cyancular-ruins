# 联机快照：现状、实测、与主流做法的对照

> 真相源：源码 > 探针实测 > 本文档。行号只在写下那天成立，引用前先 `grep` 复核。
> 结构化诊断（`--diag` / `CYR_DIAG=1`）与运维审计口径见 [`tests.md`](tests.md)。

## 1. 频率与载荷

### 1.1 下行:世界包 30Hz、本人包 60Hz(v5),tick 域仍是 60Hz

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

### 1.2 世界包：v5 起逐 peer 组帧(字段级 delta × AOI 过滤;v4 是一次广播全量)

`server/match/match_snapshot.gd::_broadcast_snapshot()`：

```gdscript
var world := {"tick": _snap_tick, "players": {}}
# 每个 role 一条：pos / vel / facing / pose / type_id / hp / waterproof /
#                  downed / aim / previewing / haste / rewind / trail
Wire.rpc("snapshot_world", NetCodec.encode_world(world))
```

- 世界包含自己那一份；客户端**刻意不消费**（C2 下本地玩家自步进，权威整态走本人包）。
- `previewing` 服务端带、客户端不消费（预瞄线只有本人可见）。
- `trail` 是回溯轨迹点数组（每 3 帧一个点），线上最多 `NetCodec.TRAIL_WIRE_MAX := 4` 点。
- 传输：`snapshot_world` 是 `unreliable`、`transfer_channel = 0`（ENet 道 1）。通道契约见 [`netplay-rpc-channels.md`](netplay-rpc-channels.md)。

### 1.3 本人包：逐 peer，`ack` + `q` + 权威整态

同一函数后半段，对每个 live peer 定向：

```gdscript
Wire.rpc_id(peer, "snapshot_own",
        NetCodec.encode_own({"ack_seq": _ack_seq.get(role, 0), "q": q.size(), "c2": c2}))
```

- `ack_seq` = 该 role 已消费输入记录的 seq。
- `q` = 该 role 已到达但未消费的输入**记录**数。
- `c2` = `player.capture_state()`：**25 个标量 + 武器块 8 个（仅手持非空时）+ 整个背包表**。字段表在 `core/net/net_codec.gd` 的 `C2_SCHEMA` / `WEAPON_SCHEMA` / `INV_SCHEMA`。
- `c2` 是 C2 回滚的锚点：客户端 `restore_state()` 后用未确认输入重放。
- ★ **S1（2026-10-24）发送时机**：本人包不在世界包广播里发，而是 MatchHost 在**消费完本 tick 输入后 call_deferred**、由 `send_own_snapshots()` 在帧末（Player 子节点步进完之后）发。⇒ `ack` 与 `c2` 是同一 tick 的最新权威态（旧实现落后一拍且要等下一次 30Hz 广播）；代价是**世界包里自己那份比本人包旧 1 tick**（客户端本来就不消费世界包的自己那份）。★ v5(P3) 起本人包**每个物理 tick 都发**（60Hz,`_flush_own_snapshots` 不再受 30Hz 相位门):ack 回带间隔均值 ~25ms → ~8ms,成本 ≈ +2.8 KB/s/客户端。
- 传输：`snapshot_own` 是 `unreliable`、`transfer_channel = 0`（ENet 道 1）。

### 1.4 线格式与载荷

- `core/net/net_codec.gd` 用一张 schema 表 + 手打包成 `PackedByteArray`（快照 + 输入同模块）。首字节 `PROTO_VERSION := 4`，第二字节种类（`KIND_WORLD` / `KIND_OWN` / `KIND_INPUT`）。
- ★ 2026-10-24 bool 打包：bool 按**记录**打包成 1 B 标志字节（`T_BOOLS`；世界 4 个 / `c2` 7 个 / 武器块 3 个）。**不是跨字段位流** —— 收益等价（世界条目 51→48 B、本人包 102→94 B）但不需要 bit 游标与 padding 校验，解码也不会因尾部 padding 判据制造误红/误绿；代价是组内对齐浪费 ≤7 bit。小整数位宽 / 真位流留给后续（要先登记每字段值域）。
- ★ 2026-10-24 编码侧性能：解码仍表驱动（`_unpack` 逐字段守边界），**编码侧手写内联**（`out.encode_float(i, v)` + 下标写，一次性按 `_schema_bytes()` 预算容量、末尾 `resize(i)` 收尾）。实测 `encode_world`（N=16）**304 → 40~49 µs/包**（一次性量具 `.superpowers/net/encode_timing.gd`；同文件的剖面实测「只 resize」= 0.2 µs ⇒ 瓶颈是**逐字段 GDScript 调用**，不是分配）。代价：编码顺序/宽度与 schema 成了两份 —— 漂移由 `snapshot_size_probe` 的往返判据抓（解码按 schema 读，顺序/宽度错 = 值必不对）。★ 这一版**只改 CPU、不改字节**（bool 打包是同一批的另一条，字节变化见上一条）。
- 两端版本不一致 ⇒ 解码返回空字典、调用方不 emit，`net_bus.gd` / `net_bus` 的输入解码口各只报一次错。
- 数值全是 float32 全量，**无量化**；字段全是绝对值，**无增量**。

载荷口径（trail 2 点、装枪 + 1 件背包）：

| 包 | 载荷 |
|---|---|
| 世界包头 | FULL 8 B（版本 1 + 种类 1 + mode 1 + tick 4 + 人数 1）；DELTA 13 B（tick 4 + base 4 + 变更数 1 + 消失数 1 + 同 FULL 头 3） |
| 世界包每人条目 | **48 B**（role 1 + bool 标志 1 + 定长 29 + trail(1+16)）；不在回溯时 **32 B** |
| 本人包 | **94 B**（头 8 + `c2` 67 + 武器 12 + 背包 7） |
| 输入包 | **46 B**（头 2 + 记录 44 = **两条连续 tick 记录**；`held` 必须 u16，见 [`netcode-input-uplink.md`](netcode-input-uplink.md)） |

按 30Hz 折算（服务器上行按扇出算：世界包每个 peer 一份）：

| N | 世界包/包 | 本人包合计 | 服务器上行 | 单端下行 |
|---|---|---|---|---|
| 2 | 103 B | 188 B | 11.5 KB/s | 5.8 KB/s |
| 8 | 391 B | 752 B | 113.7 KB/s | 14.2 KB/s |
| 16 | 775 B | 1504 B | 407.3 KB/s | 25.5 KB/s |

★ `snapshot_size_probe` 的 N 表把世界包只计一份（不乘接收端数），读数比上面小 `(N-1) × 世界包`；引用它的"服务器上行"列时先换算。

### 1.5 分片

- ENet MTU 预算 1400 B（`tests/probe/snapshot_size_probe.gd` 的 `WORLD_PACKET_BUDGET`）。`unreliable` = `UNSEQUENCED | UNRELIABLE_FRAGMENT` ⇒ 丢任意一片 = 整帧丢。
- 世界包 = `7 + N × 48`：16 人（trail 2 点）**775 B** ⇒ 1 片；最坏（16 人各 4 点 trail）= `7 + 16 × 64 = **1031 B**`，仍 1 片。
- 本人包 **94 B**，不分片。
- `NetCodec.TRAIL_MAX := 16` 是解码侧硬顶（长度是不可信输入），与发送侧 `TRAIL_WIRE_MAX` 不是同一个数。
- 改世界字段或 `TRAIL_WIRE_MAX` 前先跑 `tests/probe/snapshot_size_probe.tscn`（判词 `SNAPSHOT SIZE PROBE: ALL-OK`，量真实产出并带条数闸）。

### 1.6 客户端消费与丢弃

| 包 | 处理 | 丢弃规则 |
|---|---|---|
| 世界包 | [`pvp_game.gd`](../../scenes/pvp_game.gd) `_on_snapshot_world` → 只喂**对手副本** | `tick < _last_snap_tick` ⇒ 丢（新的赢） |
| 本人包 | [`pvp_match_client.gd`](../../scenes/pvp_match_client.gd) `_on_snapshot_own` → `_rollback.on_authoritative(ack, c2)` | ① `ack > _input_seq` ⇒ 丢（跨纪元残留）；② `ack <= _acked` 由 [`prediction_rollback.gd`](../../core/net/prediction_rollback.gd) 挡 |

`unreliable` 不保证顺序，"新的赢"是唯一正确的做法；两条丢弃都不产生延迟累加。

## 2. 远端副本：playout 缓冲插值

- [`player_replica.gd`](../../scenes/player/player_replica.gd) `apply_snapshot` 把快照位置塞进定长历史环并喂播放时钟；`_process` 在「最新 − `PLAYOUT_TICKS`」那一刻对两条相邻快照夹逼插值。
- `PLAYOUT_TICKS = 4`（60Hz tick 域）；下行 30Hz ⇒ 2 个发包间隔 ≈ **67ms 缓冲**，也是「画面比权威晚多少」的旋钮。
- 无外插：取样比最新还新（underrun）冻在最新；比最老还老冻在最老。跨接缝那一对样本先锚进同一副本空间再 lerp。
- `SNAP_DIST = 128 px`：相邻样本的环面距离超它 ⇒ 清历史、一帧落位（回溯 / 重生 / 换边）。
- [`player_replica.gd`](../../scenes/player/player_replica.gd) 的 `_clock` 是 `core/net/playout_clock.gd`（窗口最小延迟选样的本地播放时钟，不与服务器做时钟同步、不做速率纠偏以外的动作）。
- 幽灵体（`_build_ghost_body`，`StaticBody2D`，层按队配）**不跟插值**：跟未经平滑的 `target`，预测面要最小陈旧。
- 两个 `anchor_to_nearest` 是承重的：渲染位置与目标相隔整幅地图时最短向量为 0 ⇒ 副本会永远留在远副本。
- `aim` / `pose` / `facing` 逐包瞬跳。`_aim` 是单位向量，若加插值必须 `slerp` 或 `lerp_angle`（直接 `lerp` 会穿原点）。

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
| 状态发送频率 | 30Hz + 客户端 playout 插值（`PLAYOUT_TICKS = 4` ≈ 67ms 缓冲） | 10~30Hz + 客户端插值缓冲 |
| 编码 | schema 表手打包 | 绑定 + 量化 + 位打包 |
| 增量 | 全字段绝对值 | 对已 ack 的基线增量 |
| 客户端时钟 | 本地播放时钟（窗口最小延迟选样），不与服务器做显式时钟同步 | 播放时钟跟服务器时钟 |

## 6. 已知边界

- `c2` 与渲染字段都是 float32 全量，量化与增量都没做。量化必须两端同口径（`c2` 是回滚锚点，只压上行会让每次重放都对不上）。
- ★ 2026-10-24 **U1 上行去锁存**：输入记录 = 1 tick（60Hz 采样），30Hz 包内装两条（流水线），服务器每 tick 消费一条 ⇒ 本地手感不再有 30Hz 锁存延迟。**S1** 把本人包挪到"消费并步进完当帧"发（③ 固定回带已消）；客户端 U1 起本来就每 tick 对账（④ 已消）。**剩下的**只是 30Hz 发包/广播节拍的量化（`--netstat` 的 `gap` 仍有 1~2 条 ×16.7ms 的偏置），不是"等一拍广播"。见 `netcode-input-uplink.md` §5。
- 上行的 `st` / `ct` 两个扩展字段（2026-10-24 随输入手打包埋入）**只落位、无消费者**：真链路只证明不回归，送达证据只有 `-s` 往返断言；真正的消费者是未来的增量批。
- 没有丢包 / 抖动注入路径 ⇒ 队头阻塞、丢弃率、手感都没有真对局读数。
- 探针量的是**载荷**字节，不含 ENet 分片头 / RPC 方法名 / IP·UDP 头。`royale_soak_probe` 的 KB/s 是解码后 `Dictionary` 的 `var_to_bytes`，不是线上字节，对线格式改动不可见。
- `snapshot_size_probe` 的每秒折算列按 `SNAP_HZ := 60` 算，下行实际 30Hz ⇒ 只看它的单包字节，别引用每秒列。
- 应用层没有拥塞控制；ENet 自带 throttle 会主动丢 `unreliable` 包（见 [`netcode-delta-and-quantization-details.md`](netcode-delta-and-quantization-details.md)）。
- 人数上限 `ROYALE_MAX_PLAYERS := 16`（`server/lobby/lobby_rooms.gd`）。
