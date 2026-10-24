# 副本插值与输入上行的细节：一手来源调研（增量）

> 现行实现没有插值缓冲：远端玩家副本直接渲染最新快照。相关文件：`scenes/player/player_replica.gd`、`core/net/packet_input_source.gd`、`server/match/match_host.gd`。

## 1. 副本：直出最新快照

- `_process`：`global_position = target`，`target = MazeGenerator.anchor_to_nearest(_opponent_canonical, _local_anchor, MAP_WIDTH, MAP_HEIGHT)`。
- 无位置历史环、无 `PLAYOUT_TICKS`、无 `PlayoutClock`、无外插、无大跳变阈值（`SNAP_DIST` 不存在）。
- `apply_snapshot(data, local_anchor, tick)` 的第三个参数不参与渲染。
- `aim` / `pose` / `facing` 逐包瞬跳：`_aim`、`_aim_facing`、`animator.flip_h`、`animator.play(POSE_ANIM[...])`。
- 幽灵体 `_ghost` 跟同一个 `target`；`_ghost.global_rotation = 0.0` 抵消倒地转体。
- 丢弃：`pvp_game.gd` 里 `tick < _last_snap_tick` ⇒ 丢。
- `_aim` 是单位向量：若要插值必须 `slerp` 或 `lerp_angle`，直接 `lerp` 会在跨 ±x 时穿过原点。
- 离散状态（`pose` / `facing` / `type_id` / `downed`）不插值，按包切换。

## 2. 输入上行

`PacketInputSource.pack_record()` 产出**单 tick 记录**（9 字段）；`pack_pair()` 把它与上一 tick 的记录装成 30Hz 线上包（`INPUT_BATCH_TICKS = 2`，46 B/包）。

| 字段 | 含义 |
|---|---|
| `seq` | 单调输入序号 |
| `ax` | 水平轴（服务端收口为 `[-1,1]`，非有限值 → 0） |
| `held` | 按住位掩码 |
| `pressed` / `released` | 边沿位掩码 |
| `winst` | 切枪目标 inst；0 = 本包无请求 |
| `aim` | 世界坐标瞄准方向（30Hz 取样，两条记录共用） |
| `st` / `ct` | 只落位的扩展字段（见 `netcode-input-uplink.md`） |

位定义：`BIT_UP 1` / `BIT_DOWN 2` / `BIT_CHARGE 4` / `BIT_ATTACK 8` / `BIT_RELOAD 16` / `BIT_PICKUP 32` / `BIT_DROP 64` / `BIT_HASTE 128` / `BIT_REWIND 256`。加位 = 改协议，两端必须同版本。

- 频率：**采样 60Hz**（一条记录 = 1 tick，`TICKS_PER_RECORD := 1`）；**发包 30Hz**，一包装两条 tick 记录（`INPUT_BATCH_TICKS := 2`，流水线：本包 = 上一 tick + 本 tick）。客户端本地预测与 C2 重放**不锁存**，逐 tick 1:1。
- 通道：`send_input` 是 `reliable`、用户通道 1（ENet 道 2）。
- `pressed` / `released` 是边沿语义，靠 reliable 的保序 + 重传保证不丢。

## 3. 服务端消费

- **每物理 tick 恰 `pop_front()` 一条**（一包到两条）；`ack_seq = pkt.seq`（逐 tick 前进）；广播仍 30Hz。
- 队列空 ⇒ 沿用上一条记录的 `held` / `axis` / `aim`；`clear_edges()` 在每个 tick 末清 `pressed` / `released` / `winst`。
- 饥饿期不记账：没有"猜了哪一帧"的记录，也不专门回滚；分歧只在收到权威 `c2` 时由 C2 纠正。
- 上限与丢弃（`PacketInputSource`，单位 = 条 tick 记录）：`cap = clamp(peak + 2, 4, 16)`；`peak` 每 tick 衰减 1；丢最旧一条并把边沿并入队首；`reset_input_queue()` 连包络一起清。

## 4. ack 与时钟

- 服务器在本人包回带 `ack_seq` + `q`；客户端只把它们喂 `PredictionRollback` 与 `--netstat` 读数，不据此调时钟。
- 丢弃：`ack > _input_seq`（跨纪元残留）与 `ack <= _acked`（同纪元旧包）。
- 上行不带客户端时间戳 / `tick_count`；没有"客户端领先服务器多少 tick"的参数。
- 客户端没有播放时钟、没有时钟同步、没有速率纠偏；世界包 `tick` 只用于乱序丢弃。

## 5. 静默 bug 清单（现行代码的约束）

| 现象 | 约束 |
|---|---|
| 一次性输入"取后不清" ⇒ 被 tick loop 每个 tick 用一遍 | 边沿由 `MatchHost.clear_edges()` 每 tick 末清；`held` 保留 |
| 只压上行量化 ⇒ 重放对不上 | 量化必须两端同口径（`c2` 是回滚锚点） |
| 欧拉角 / 单位向量线性插值 | 角度走 `lerp_angle`，方向向量走 `slerp` |
| 幽灵体跟平滑值 ⇒ 预测面被污染 | 幽灵体跟未平滑的 `target` |
| 跨接缝时最短向量为 0 ⇒ 副本留在远副本 | 两个 `anchor_to_nearest` 不许简化 |
