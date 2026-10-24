# 副本插值与输入上行的细节：一手来源调研（增量）

> 现行实现：远端玩家副本走 **playout 缓冲插值**（渲染「最新快照 − `PLAYOUT_TICKS`」那一刻的夹逼插值位置）；幽灵碰撞体仍直出最新快照。相关文件：`scenes/player/player_replica.gd`、`core/net/playout_clock.gd`、`core/net/packet_input_source.gd`、`server/match/match_host.gd`。

## 1. 副本：playout 缓冲插值

- `_process`：`_clock.advance(delta)` ⇒ `global_position = _sample_history(_clock.render_tick)`，再把取样点 `anchor_to_nearest(...)` 回本地玩家最近的副本。
- 位置历史环 `place_history`（元素 `{tick, pos}`，pos 是 canonical，定长 `HISTORY_MAX = 12`）；`PLAYOUT_TICKS = 4` —— 60Hz tick 域、下行 30Hz ⇒ **2 个发包间隔 ≈ 67ms 缓冲**。
- `apply_snapshot(data, local_anchor, tick)` 的第三参参与计算：喂 `PlayoutClock.on_snapshot(tick)` 与 `_push_history(tick, pos)`。
- 取样两侧冻结：比最新还新（underrun）冻在最新、**不外插**；比最老还老冻在最老、不倒退。跨接缝的那一对样本必须**先锚进同一个副本空间再 lerp**，否则差量是一整幅地图。
- 相邻样本的环面距离 > `SNAP_DIST`（128 px）⇒ 清历史、一帧落位（回溯 / 重生 / 换边本来就是瞬移）。
- 幽灵体 `_ghost` 不跟插值：它跟**未经平滑**的 `target`（预测面要最小陈旧）；`_ghost.global_rotation = 0.0` 抵消倒地转体。
- `aim` / `pose` / `facing` 逐包瞬跳：`_aim`、`_aim_facing`、`animator.flip_h`、`animator.play(POSE_ANIM[...])`。
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
