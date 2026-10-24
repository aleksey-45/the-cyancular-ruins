# 联机输入上行：现状、实测、与主流做法的对照

## 1. 载荷

`core/net/packet_input_source.gd::pack_record()` 是发送侧唯一编码端，产出 7 字段 `Dictionary`：

| 字段 | 类型 | 说明 |
|---|---|---|
| `seq` | int | 单调输入序号 |
| `ax` | float | 水平轴 |
| `held` | int | 按住位掩码 |
| `pressed` | int | 按下边沿 |
| `released` | int | 抬起边沿 |
| `winst` | int | 切枪目标 inst；0 = 无请求 |
| `aim` | Vector2 | 世界坐标瞄准方向 |

位：`BIT_UP 1` / `BIT_DOWN 2` / `BIT_CHARGE 4` / `BIT_ATTACK 8` / `BIT_RELOAD 16` / `BIT_PICKUP 32` / `BIT_DROP 64` / `BIT_HASTE 128` / `BIT_REWIND 256`。加位 = 改协议，两端必须同版本。

## 2. 频率与通道

- 采样 30Hz、上行 30Hz，一包一条记录；`TICKS_PER_RECORD := 2`。`SampledInput` 在 60Hz 每 tick 累积边沿，到配对起点（30Hz）才锁存成记录。
- 发送点：`scenes/pvp_match_client.gd::_physics_process`，只在"输入对"起点 `_input_seq += 1` → `NetBus.rpc_id(1, "send_input", pkt)`。
- 通道：`send_input` 是 `reliable`、用户通道 1（ENet 道 `SYSCH_MAX(2) + 1 - 1` = 2），有序 + 重传。
- 选 reliable 的约束：`pressed` / `released` 是边沿语义，丢边沿 = 两端脱节（抓梯 / 跳跃 / 开火）。

## 3. 消费

- `server/match/match_host.gd`：每 `SNAPSHOT_STRIDE` 个物理 tick 恰 `pop_front()` 一条（1:1 同序是 C2 的前提）；`ack_seq = pkt.seq`。
- 队列空 ⇒ 沿用上一条 `held` / `axis` / `aim`；`clear_edges()` 每个 tick 末清边沿与切枪。
- 上限（`PacketInputSource.adapted_cap` / `push_pending`）：`cap = clamp(peak + 1, 2, 8)`；`peak` 每 tick 衰减 1；丢最旧一条并把边沿并入队首；返回值是丢之前的深度。
- `reset_input_queue(role)`：队列与包络一起清。

## 4. 读数（默认关）

- 客户端 `-- --netstat`（1Hz）：`_input_seq` / `_last_ack` / `gap` / `lag_ms`（= gap × 16.67ms × `TICKS_PER_RECORD`）/ `NetBus.ping_ms` / 扣网后积压 / 回滚累计 / 物理步每秒 / 渲染 fps。
- `gap` 有 0~1 条记录的量化偏置（ack 只在 30Hz 本人包回带，0~33ms）；判趋势不看绝对值。
- 服务端 `--netstat` / `--netstat-trace`（前 600 tick 逐帧）：队列长度 / 抖动上限 / 累计丢弃。
- `--diag` / `CYR_DIAG=1`：`queue`（1Hz）、`queue_drop` 事件。

## 5. 边界

- 载荷仍是 `Dictionary`：≈164 B/包（`var_to_bytes` 口径），30Hz ⇒ ≈4.8 KB/s/客户端。手打包未做。
- 无冗余命令窗口：每包一条记录，丢包靠 reliable 重传。
- reliable 有序 ⇒ 丢一个包时该通道后续包排队等重传（队头阻塞）。没有丢包注入路径，影响量没有实测。
- 输入包不含量化（`ax` / `aim` 是 4 字节浮点），不含客户端时间戳。
- 边沿语义依赖可靠通道；若改用不可靠通道，必须先加去重（同一 `seq` 只应用一次）与冗余。
