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
NetBus.rpc("snapshot_world", SnapshotCodec.encode_world(world))
```

- 世界包含自己那一份；客户端**刻意不消费**（C2 下本地玩家自步进，权威整态走本人包）。
- `previewing` 服务端带、客户端不消费（预瞄线只有本人可见）。
- `trail` 是回溯轨迹点数组（每 3 帧一个点），线上最多 `SnapshotCodec.TRAIL_WIRE_MAX := 4` 点。
- 传输：`snapshot_world` 是 `unreliable`、`transfer_channel = 0`（ENet 道 1）。通道契约见 [`netplay-rpc-channels.md`](netplay-rpc-channels.md)。

### 1.3 本人包：逐 peer，`ack` + `q` + 权威整态

同一函数后半段，对每个 live peer 定向：

```gdscript
NetBus.rpc_id(peer, "snapshot_own",
        SnapshotCodec.encode_own({"ack_seq": _ack_seq.get(role, 0), "q": q.size(), "c2": c2}))
```

- `ack_seq` = 该 role 已消费输入记录的 seq。
- `q` = 该 role 已到达但未消费的输入**记录**数。
- `c2` = `player.capture_state()`：**25 个标量 + 武器块 8 个（仅手持非空时）+ 整个背包表**。字段表在 `core/net/snapshot_codec.gd` 的 `C2_SCHEMA` / `WEAPON_SCHEMA` / `INV_SCHEMA`。
- `c2` 是 C2 回滚的锚点：客户端 `restore_state()` 后用未确认输入重放。
- 传输：`snapshot_own` 是 `unreliable`、`transfer_channel = 0`（ENet 道 1）。

### 1.4 线格式与载荷

- `core/net/snapshot_codec.gd` 用一张 schema 表驱动手打包成 `PackedByteArray`。首字节 `PROTO_VERSION := 1`，第二字节种类（`KIND_WORLD` / `KIND_OWN`）。
- 两端版本不一致 ⇒ 解码返回空字典、调用方不 emit，`net_bus.gd` 只报一次错。
- 数值全是 float32 全量，**无量化**；字段全是绝对值，**无增量**。

载荷口径（trail 2 点、装枪 + 1 件背包）：

| 包 | 载荷 |
|---|---|
| 世界包头 | 7 B（版本 1 + 种类 1 + tick 4 + 人数 1） |
| 世界包每人条目 | 51 B（role 1 + 字段 50）；不在回溯时 35 B |
| 本人包 | 102 B（头 8 + `c2` 73 + 武器 14 + 背包 7） |

按 30Hz 折算（服务器上行按扇出算：世界包每个 peer 一份）：

| N | 世界包/包 | 本人包合计 | 服务器上行 | 单端下行 |
|---|---|---|---|---|
| 2 | 109 B | 204 B | 12.4 KB/s | 6.2 KB/s |
| 8 | 415 B | 816 B | 121.2 KB/s | 15.2 KB/s |
| 16 | 823 B | 1632 B | 433.6 KB/s | 27.1 KB/s |

★ `snapshot_size_probe` 的 N 表把世界包只计一份（不乘接收端数），读数比上面小 `(N-1) × 世界包`；引用它的"服务器上行"列时先换算。

### 1.5 分片

- ENet MTU 预算 1400 B（`tests/probe/snapshot_size_probe.gd` 的 `WORLD_PACKET_BUDGET`）。`unreliable` = `UNSEQUENCED | UNRELIABLE_FRAGMENT` ⇒ 丢任意一片 = 整帧丢。
- 世界包 = `7 + N × 51`：16 人（trail 2 点）823 B ⇒ 1 片；最坏（16 人各 4 点 trail）= `7 + 16 × 66 = 1063 B`，仍 1 片。
- 本人包 102 B，不分片。
- `SnapshotCodec.TRAIL_MAX := 16` 是解码侧硬顶（长度是不可信输入），与发送侧 `TRAIL_WIRE_MAX` 不是同一个数。
- 改世界字段或 `TRAIL_WIRE_MAX` 前先跑 `tests/probe/snapshot_size_probe.tscn`（判词 `SNAPSHOT SIZE PROBE: ALL-OK`，量真实产出并带条数闸）。

### 1.6 客户端消费与丢弃

| 包 | 处理 | 丢弃规则 |
|---|---|---|
| 世界包 | [`pvp_game.gd`](../../scenes/pvp_game.gd) `_on_snapshot_world` → 只喂**对手副本** | `tick < _last_snap_tick` ⇒ 丢（新的赢） |
| 本人包 | [`pvp_match_client.gd`](../../scenes/pvp_match_client.gd) `_on_snapshot_own` → `_rollback.on_authoritative(ack, c2)` | ① `ack > _input_seq` ⇒ 丢（跨纪元残留）；② `ack <= _acked` 由 [`prediction_rollback.gd`](../../core/net/prediction_rollback.gd) 挡 |

`unreliable` 不保证顺序，"新的赢"是唯一正确的做法；两条丢弃都不产生延迟累加。

## 2. 远端副本：直接渲染最新快照

- [`player_replica.gd`](../../scenes/player/player_replica.gd) `_process`：`global_position = target`，`target = MazeGenerator.anchor_to_nearest(_opponent_canonical, _local_anchor, MAP_WIDTH, MAP_HEIGHT)`。
- 无位置历史、无插值缓冲、无外插、无 `PLAYOUT_TICKS` / `PlayoutClock`。副本按 30Hz 发包节奏落位，两包之间位置不变。
- `apply_snapshot(data, local_anchor, tick)` 的 `tick` 不参与渲染，只为不动调用面保留。
- 幽灵体（`_build_ghost_body`，`StaticBody2D`，层按队配）跟同一个 `target`：预测面要最小陈旧，不跟平滑。
- 两个 `anchor_to_nearest` 是承重的：渲染位置与目标相隔整幅地图时最短向量为 0 ⇒ 副本会永远留在远副本。
- `aim` / `pose` / `facing` 逐包瞬跳。`_aim` 是单位向量，若加插值必须 `slerp` 或 `lerp_angle`（直接 `lerp` 会穿原点）。

## 3. 输入队列

`core/net/packet_input_source.gd` + `server/match/input_intake.gd`：

- 上限：`cap = clamp(peak + QUEUE_CAP_MARGIN, QUEUE_CAP_MIN, QUEUE_CAP_MAX)`，即 `[2, 8]`。
- `peak` = 最近一次轮询到的**原始**深度（丢之前），每 tick 衰减 1 ⇒ 网络安静时上限自己缩回。
- 满上限时丢**最旧**一条，`pressed` / `released` / `winst` 边沿并入队首。
- `push_pending()` 返回**丢之前**的深度（包络靠它学习）。
- `reset_input_queue(role)` 队列与包络一起清（掉线 / 重连重开纪元）。
- 服务端每 `SNAPSHOT_STRIDE` 个 tick 恰消费一条记录；队列空 ⇒ 沿用上一包的 held；`clear_edges()` 清边沿。

## 4. 判据与读数

| 数据源 | 在哪 | 读数 |
|---|---|---|
| `snapshot_own.q` | 本人包 | 服务器侧已到达未消费的记录数 |
| `_input_seq - _last_ack` | `pvp_match_client.gd` 的 `-- --netstat`（1Hz） | 未确认记录数（在途 + 在队） |
| 服务端 `--netstat` / `--netstat-trace` | `input_intake.gd` | 队列长度 · 抖动上限 · 累计丢弃（1Hz / 前 600 tick 逐帧） |
| `--diag` / `CYR_DIAG=1` | `NetDiag` | `snap_gap`（>150ms）、`snap_rx`、`snapshot_tx`、`queue`、`queue_drop` |

- 正常形状：队列贴近 `QUEUE_CAP_MIN`，上限在衰减，累计丢弃只在突发后跳一次。
- 坏形状：上限一路顶到 8 不回，或累计丢弃几乎每 tick 都涨。
- 判据一律 grep 判词文本 + 条数闸，不看退出码。

## 5. 与主流做法的对照

| 维度 | 本仓 | 主流 |
|---|---|---|
| 状态发送频率 | 30Hz，无插值缓冲 | 10~30Hz + 客户端插值缓冲 |
| 编码 | schema 表手打包 | 绑定 + 量化 + 位打包 |
| 增量 | 全字段绝对值 | 对已 ack 的基线增量 |
| 客户端时钟 | 不跟服务器时钟，`tick` 只用于丢弃旧快照 | 播放时钟跟服务器时钟 |

## 6. 已知边界

- `c2` 与渲染字段都是 float32 全量，量化与增量都没做。量化必须两端同口径（`c2` 是回滚锚点，只压上行会让每次重放都对不上）。
- 没有丢包 / 抖动注入路径 ⇒ 队头阻塞、丢弃率、手感都没有真对局读数。
- 探针量的是**载荷**字节，不含 ENet 分片头 / RPC 方法名 / IP·UDP 头。`royale_soak_probe` 的 KB/s 是解码后 `Dictionary` 的 `var_to_bytes`，不是线上字节，对线格式改动不可见。
- `snapshot_size_probe` 的每秒折算列按 `SNAP_HZ := 60` 算，下行实际 30Hz ⇒ 只看它的单包字节，别引用每秒列。
- 应用层没有拥塞控制；ENet 自带 throttle 会主动丢 `unreliable` 包（见 [`netcode-delta-and-quantization-details.md`](netcode-delta-and-quantization-details.md)）。
- 人数上限 `ROYALE_MAX_PLAYERS := 16`（`server/lobby/lobby_rooms.gd`）。
