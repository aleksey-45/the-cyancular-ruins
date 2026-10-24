# 联机输入上行：现状、实测、与主流做法的对照

> ★ **2026-10-24：输入包已手打包**（`164 B` 的 7 键 `Dictionary` → **34 B** 的 `PackedByteArray`），并顺带埋了 `st`/`ct` 两个扩展字段（只落位，增量批才消费）。线格式唯一来源 = [`core/net/net_codec.gd`](../../core/net/net_codec.gd) 的 `INPUT_SCHEMA` + `encode_input` / `decode_input`。

## 1. 载荷

`core/net/packet_input_source.gd::pack_record()` 是发送侧**唯一编码端**，产出 9 字段 `Dictionary`：

| 字段 | 类型 | 说明 |
|---|---|---|
| `seq` | int | 单调输入序号（每 2 个物理 tick 一条，见 §2） |
| `ax` | float | 水平轴 |
| `held` | int | 按住位掩码（**最大 415**，含 `BIT_REWIND = 256`） |
| `pressed` | int | 按下边沿 |
| `released` | int | 抬起边沿 |
| `winst` | int | 切枪目标 inst；0 = 无请求 |
| `aim` | Vector2 | 世界坐标瞄准方向 |
| `st` | int | ★ 本端**最近成功解码**的服务器世界快照 tick（不是"最后收到"） |
| `ct` | int | ★ 本帧客户端物理帧号（`Engine.get_physics_frames()`） |

位：`BIT_UP 1` / `BIT_DOWN 2` / `BIT_CHARGE 4` / `BIT_ATTACK 8` / `BIT_RELOAD 16` / `BIT_PICKUP 32` / `BIT_DROP 64` / `BIT_HASTE 128` / `BIT_REWIND 256`。加位 = 改协议，两端必须同版本。

**线格式**（`NetCodec.KIND_INPUT`）：头 2 B（`PROTO_VERSION` + 种类）+ 记录 32 B = **34 B/包**。实测 34 B（`net_wire_smoke.gd` 的 `[readout]` 行）。
- `held` 必须 **u16** —— `BIT_REWIND = 256` 装不进 u8（按 u8 打会静默截成 159，表现为"加速/回溯按住没反应"）。
- `pressed` / `released` 最大 127 / 31 ⇒ u8 够。
- `st` / `ct` 各 4 B。★ 本批**只落位**：服务器存进 `MatchState._client_snap_tick` / `_client_tick` 并由 `--netstat` 打印，**没有消费者**；它们是未来增量批的基线来源 —— 但线格式只改这一次。

## 2. 频率与通道

- 采样 30Hz、上行 30Hz，一包一条记录；`TICKS_PER_RECORD := 2`。`SampledInput` 在 60Hz 每 tick 累积边沿，到配对起点（30Hz）才锁存成记录。
- 发送点：`scenes/pvp_match_client.gd::_physics_process`，只在"输入对"起点 `_input_seq += 1` → `pack_record(...)` → **`NetBus.rpc_id(1, "send_input", NetCodec.encode_input(pkt))`**。
- 通道：`send_input` 仍是 `reliable`、用户通道 1（ENet 道 `SYSCH_MAX(2) + 1 - 1` = 2），有序 + 重传。★ 本批只改**载荷编码**，通道号/传输模式一个都没动。
- 选 reliable 的约束：`pressed` / `released` 是边沿语义，丢边沿 = 两端脱节（抓梯 / 跳跃 / 开火）。

## 3. 消费

- [`core/net/net_bus.gd`](../../core/net/net_bus.gd) 的 RPC 入口先 `NetCodec.decode_input(payload)` 再 emit `input_received(caller, pkt)` —— **解码失败返回空 + 只报一次 + 不喂进模拟**（两端版本不一致时现场会看到一条 `push_error`，而不是静默抽搐）。
- `server/match/match_host.gd`：每 `SNAPSHOT_STRIDE` 个物理 tick 恰 `pop_front()` 一条（1:1 同序是 C2 的前提）；`ack_seq = pkt.seq`。
- `st` / `ct` 在 `_on_input` 里**先落位**再入队（不进队列、不参与模拟）：后到的覆盖先到的 —— 它们本来就只代表"最近一次"。
- 队列空 ⇒ 沿用上一条 `held` / `axis` / `aim`；`clear_edges()` 每个 tick 末清边沿与切枪。
- 上限（`PacketInputSource.adapted_cap` / `push_pending`）：`cap = clamp(peak + 1, 2, 8)`；`peak` 每 tick 衰减 1；丢最旧一条并把边沿并入队首；返回值是丢之前的深度。
- `reset_input_queue(role)`：队列与包络一起清。

## 4. 读数（默认关）

- 客户端 `-- --netstat`（1Hz）：`_input_seq` / `_last_ack` / `gap` / `lag_ms`（= gap × 16.67ms × `TICKS_PER_RECORD`）/ `NetBus.ping_ms` / 扣网后积压 / 回滚累计 / 物理步每秒 / 渲染 fps。
- `gap` 有 0~1 条记录的量化偏置（ack 只在 30Hz 本人包回带，0~33ms）；判趋势不看绝对值。
- 服务端 `--netstat` / `--netstat-trace`（前 600 tick 逐帧）：队列长度 / 抖动上限 / 累计丢弃 / **客户端 `st`/`ct`**（后者是本批新增的落位读数）。
- `--diag` / `CYR_DIAG=1`：`queue`（1Hz）、`queue_drop` 事件。

## 5. 边界（照实）

- **载荷口径**：164 → **34 B/包**（−79%），30Hz ⇒ 4.9 → **1.0 KB/s/客户端**。★ 不含 RPC 信封 / ENet / IP·UDP 头；本仓至今**没有线上字节仪器**（真链路 `royale_soak` 报的 KB/s 是解码后 Dictionary 口径，对线格式改动完全看不见）。
- `st`/`ct` 本批**无消费者**：送达证据只有 `-s` 的往返断言（含非零值）；真链路只证明不回归。
- 无冗余命令窗口：每包一条记录，丢包靠 reliable 重传。
- reliable 有序 ⇒ 丢一个包时该通道后续包排队等重传（队头阻塞）。没有丢包注入路径，影响量没有实测。
- 输入包不含量化（`ax` / `aim` 仍是 float32）。
- 边沿语义依赖可靠通道；若改用不可靠通道，必须先加去重（同一 `seq` 只应用一次）与冗余。
