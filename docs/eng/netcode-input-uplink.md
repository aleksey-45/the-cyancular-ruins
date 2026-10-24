# 联机输入上行：现状、实测、与主流做法的对照

> ★ **2026-10-24 U1：上行去锁存 —— 本地 60Hz 真输入、30Hz 包内装两条 tick 记录（46 B/包）**。
> 此前是"30Hz 采样 + 本地也锁存"（34 B/包）：本地手感与服务器输入都被锁在 30Hz；现在一条记录 = **1 个物理 tick**，本地预测按 60Hz 现读真输入，服务器**每 tick 消费一条**，两端逐 tick 同序。
> 线格式唯一来源 = [`core/net/net_codec.gd`](../../core/net/net_codec.gd) 的 `INPUT_SCHEMA` + `encode_input` / `decode_input`；组包/拆包在 [`core/net/packet_input_source.gd`](../../core/net/packet_input_source.gd) 的 `pack_record` / `pack_pair` / `unpack_pair`。

## 1. 载荷

发送侧分两层：

- `pack_record(src, seq, aim, st, ct)`：**单 tick 记录**（9 字段 `Dictionary`，发送侧唯一编码端；服务器拆包后也用它这组键）。
- `pack_pair(lo, hi, aim, st, ct)`：把**上一 tick + 本 tick** 两条记录装成线上包（`INPUT_SCHEMA` 的 14 键）。

单 tick 记录字段：

| 字段 | 类型 | 说明 |
|---|---|---|
| `seq` | int | 单调输入序号（**每物理 tick 一条**） |
| `ax` | float | 水平轴 |
| `held` | int | 按住位掩码（**最大 415**，含 `BIT_REWIND = 256`） |
| `pressed` | int | 按下边沿（该 tick） |
| `released` | int | 抬起边沿（该 tick） |
| `winst` | int | 切枪目标 inst；0 = 无请求 |
| `aim` | Vector2 | 世界坐标瞄准方向（30Hz 取样，两条记录共用） |
| `st` | int | ★ 本端**最近成功解码**的服务器世界快照 tick（不是"最后收到"） |
| `ct` | int | ★ 该 tick 的客户端物理帧号；低 tick 记录 = `ct - 1` |

位：`BIT_UP 1` / `BIT_DOWN 2` / `BIT_CHARGE 4` / `BIT_ATTACK 8` / `BIT_RELOAD 16` / `BIT_PICKUP 32` / `BIT_DROP 64` / `BIT_HASTE 128` / `BIT_REWIND 256`。加位 = 改协议，两端必须同版本。

**线格式**（`NetCodec.KIND_INPUT`，`PROTO_VERSION = 4`）：头 2 B + 记录 44 B = **46 B/包**。实测 46 B（`net_wire_smoke.gd` 的 `[readout]` 行）。布局：

```
头: 版本 1B | 种类 1B
seq(4) | held0(2) | held1(2) | ax0(4) | ax1(4) | pressed0/1(各1) | released0/1(各1)
        | winst0(4) | winst1(4) | aim(8) | st(4) | ct(4)
```

- ★ **包级 `seq` = 高 tick 记录的 seq，低 tick 记录 = `seq - 1`**（拆包由 `unpack_pair` 还原；`ct` 同理差 1）。
- `held` 必须 **u16** —— `BIT_REWIND = 256` 装不进 u8（按 u8 打会静默截成 159，表现为"加速/回溯按住没反应"）。
- `pressed` / `released` 最大 127 / 31 ⇒ u8 够。
- `aim` / `st` / `ct` 两条记录共用（30Hz 取样；`st`/`ct` 仍**只落位**，服务器存档 + `--netstat` 打印，没有消费者）。

## 2. 频率与通道

- **采样 60Hz**：每条记录 = 1 个物理 tick；`TICKS_PER_RECORD := 1`。本地玩家**不再吃锁存输入**（`SampledInput` 已删除），`player.gd` 与自己那份模拟都现读真输入。
- **发包 30Hz**：`INPUT_BATCH_TICKS := 2`，一包装两条记录（相对"每 tick 一包"省一半包头与共享字段）。
- **流水线（关键）**：包在**本 tick** 发出，装 `[上一 tick, 本 tick]`；本 tick 记录由下一包补发。若改成"等两个 tick 都发生再发"，整包会晚 16.7ms ⇒ 服务器生效反而变慢（已否决不采用）。
- 发送点：`scenes/pvp_match_client.gd::_physics_process`（每 tick）：`_input_seq += 1` → `pack_record(...)`（切枪 `winst` 也逐 tick 填）→ C2 `note_input`；到发包拍再 `pack_pair(...)` → **`NetBus.rpc_id(1, "send_input", NetCodec.encode_input(pair))`**。
- 通道：`send_input` 仍是 `reliable`、用户通道 1（ENet 道 2），有序 + 重传。★ U1 只改**载荷内容/记录粒度**，通道号/传输模式一个都没动。
- 选 reliable 的约束：`pressed` / `released` 是边沿语义，丢边沿 = 两端脱节（抓梯 / 跳跃 / 开火）。

## 3. 消费

- [`core/net/net_bus.gd`](../../core/net/net_bus.gd) 的 RPC 入口先 `NetCodec.decode_input(payload)` 再 emit `input_received(caller, pkt)` —— **解码失败返回空 + 只报一次 + 不喂进模拟**（两端版本不一致时现场会看到一条 `push_error`，而不是静默抽搐）。
- `server/match/match_host.gd::_on_input`：`PacketInputSource.unpack_pair(pkt)` 拆成**连续两条**入队（低 tick 在前）。
- `_physics_process`：**每物理 tick 恰 `pop_front()` 一条**（广播仍 30Hz，且仍在"消费本帧输入"之前 ⇒ ack 与状态配对）；`ack_seq = pkt.seq`（逐 tick 前进）。
- `st` / `ct` 在 `_on_input` 里**先落位**再入队（不进队列、不参与模拟）：后到的覆盖先到的 —— 它们本来就只代表"最近一次"。
- 队列空 ⇒ 沿用上一条 `held` / `axis` / `aim`；`clear_edges()` 每个 tick 清边沿与切枪。
- 上限（`PacketInputSource.adapted_cap` / `push_pending`，单位 = **条 tick 记录**）：`cap = clamp(peak + 2, 4, 16)`（U1 后一条 = 1 tick，MIN/MAX/MARGIN 翻倍以保住同样的时间缓冲 [66, 266] ms）；`peak` 每 tick 衰减 1；丢最旧一条并把边沿并入队首；返回值是丢之前的深度。
- `reset_input_queue(role)`：队列与包络一起清。

## 4. 读数（默认关）

- 客户端 `-- --netstat`（1Hz）：`_input_seq` / `_last_ack` / `gap` / `lag_ms`（= gap × 16.67ms × `TICKS_PER_RECORD`，U1 下即 gap × 16.67ms）/ `NetBus.ping_ms` / 扣网后积压 / 回滚累计 / 物理步每秒 / 渲染 fps。
- `gap` 有 0~2 条记录的量化偏置（ack 只在 30Hz 本人包回带，0~33ms）；判趋势不看绝对值。本地理论：gap ≥ 1~2（服务器每 tick 消费，但 ack 30Hz 回带）。
- 服务端 `--netstat` / `--netstat-trace`（前 600 tick 逐帧）：队列长度（条记录）/ 抖动上限 / 累计丢弃 / **客户端 `st`/`ct`**。
- `--diag` / `CYR_DIAG=1`：`queue`（1Hz）、`queue_drop` 事件。

## 5. 边界（照实）

- **载荷口径**：164 B（7 键 Dictionary）→ 34 B（单条锁存记录）→ **46 B/包（U1 两条 tick 记录）**；30Hz ⇒ **1.38 KB/s/客户端**（比 34 B 版 +35%；相对 164 B 仍 −72%）。★ 不含 RPC 信封 / ENet / IP·UDP 头；本仓至今**没有线上字节仪器**（真链路 `royale_soak` 报的 KB/s 是解码后 Dictionary 口径，对线格式改动完全看不见）。
- **本地手感**：轴 / held / 边沿现在是 60Hz（0~1 帧），不再有 30Hz 锁存的 0~33ms；**瞄准一直不锁存**（每 tick 现读鼠标），上行 aim 仍是 30Hz 取样。
- **服务器权威回声仍受 30Hz 快照/ack 限制**（U1 只动上行；`snapshot_own` 仍 30Hz）⇒ 端到端"输入→服务器确认"仍是几十 ms 量级，见 `netcode-snapshots.md` §4。
- `st`/`ct` 本批**无消费者**：送达证据只有 `-s` 的往返断言（含非零值）；真链路只证明不回归。
- 无冗余命令窗口：每包两条记录，丢包靠 reliable 重传。
- reliable 有序 ⇒ 丢一个包时该通道后续包排队等重传（队头阻塞）。没有丢包注入路径，影响量没有实测。
- 输入包不含量化（`ax` / `aim` 仍是 float32）；`winst` 两条各 4 B，切枪是稀事件但没做变长编码。
- 客户端侧边沿行为（按一次数字键只切一次 / F 只拾取一次 / Q 长按只丢一次）**没有自动化守卫**：默认批只剩 6 支，真链路 soak 只证明"不崩"。已登记 `registered-debt.md` §十。
