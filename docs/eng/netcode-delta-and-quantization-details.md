# 增量与量化的细节：一手源码调研（Q3 / DarkPlaces / Teeworlds / Source / Gaffer / ENet）

## 1. 本仓现状

- 快照每包发全字段绝对值：世界包 13 字段、本人包 `c2` 全量（float32）。没有变更位、没有基线、没有增量。
- `ack_seq` 是服务器已消费的输入序，不是"客户端已收到的快照 tick"。客户端收世界包时只比较 `_last_snap_tick`，从不外发 ⇒ 没有可用的 delta 基线回路。
- 无兴趣管理 / PVS：世界包含全部玩家（含自己那份，客户端不消费）；16 人 1 片。
- 应用层无拥塞控制（ENet 自带一层，见 §2）。
- 带宽上限未设：`create_host()` 不传 in/out ⇒ 0 = 不限。`ENet_CHANNELS := 4`。
- 序号：本仓 u32（60Hz 下 2.27 年回绕）；先回绕的是 ENet 自己的 u16 序号（60Hz 下 18 分 12 秒）。
- 重连：服务器把 `_ack_seq[role]` 归 0 重协商锚点；输入队列与抖动包络一起清。
- 压缩：本仓单端下行约 0.9 KB/帧（N=16），落在 zstd 不划算的区间。

## 2. ENet / Godot 传输层默认值

| API / 常量 | 默认 |
|---|---|
| `create_host(max_peers=32, max_channels=0, in_bandwidth=0, out_bandwidth=0)` | 带宽 0 = 不限 |
| `throttle_configure(interval, accel, decel)` | 5000 ms / 2 / 2 |
| `PEER_PACKET_THROTTLE_LIMIT` | 32（初值 = `PACKET_THROTTLE_SCALE`） |
| `PEER_PACKET_THROTTLE_COUNTER` | 7（硬编码，不可改） |
| `compress(mode)` | `COMPRESS_ZSTD` 在 < 4 KB 不划算；两端必须同值，否则连不上 |
| `set_timeout(t, t_min, t_max)` | 只管可靠流的 ack 超时，不管不可靠包 |
| `set_ping_interval()` | 500 ms |

- ENet 自身序号（`reliableSequenceNumber` 等）是 `enet_uint16`；MTU 576–4096，分片上限 1024×1024。

## 3. 若做增量：必须满足的契约

| 契约 | 本仓现状 |
|---|---|
| 基线 = 客户端确认过的快照 tick，由**每个**上行包携带 | 没做（`_last_snap_tick` 只被比较） |
| 实体全序（Q3 用双指针归并，顺序一乱该删的不删） | 未定义（world 是 `Dictionary`，键是 role 字符串） |
| 新实体有一条 `baseline` 支路（进场全量一次，之后相对它增量） | 没做 |
| 消失实体显式写 NULL（实体号 + 1 bit） | 没做 |
| 标量用"末位变化序号 `lc`"，数组用位掩码 | 没做 |
| 基线窗口有具体长度（Q3 `PACKET_BACKUP - 3 = 29` 包；DP `MAX_ENTITY_HISTORY 64`） | 未定义 |
| 过期退回全量，并由客户端显式请求（Q3 `clc_moveNoDelta`） | 没做 |
| 周期性全量兜底（DP `U_DELTA`：每 0.5 s 强制全量） | 没做 |
| 增量与"世界包一次广播"二选一（按 peer 增量后基线不同） | 现状是广播 |

- 变更率读数（合成输入、无战斗、30 tick）：世界 2.0/13 字段每 tick（峰 3）、本人 4.1/34（峰 8）。
- 基线比"最新帧"旧约 1 个 RTT ⇒ 按"对上一帧求差"算收益会偏乐观。

## 4. 量化的位数

| 实现 | 位置 | 角度 | 备注 |
|---|---|---|---|
| Q3 | 整数值 `[-4096,4095]` ⇒ 13 bit，否则 32 bit float | `ANGLE2SHORT` 16 bit（0.0055°）/ `MSG_WriteAngle` 8 bit（1.40625°） | 整数值无损 |
| DarkPlaces | `short[3] × 8` = 0.125 单位，或 `float[3]` | `byte[3]`（1.40625°）或 `short[3]`（0.0055°） | `U_DELTA` 另有每 0.5 s 全量 |
| Teeworlds | 位置取整、速度 `×256` 后取整 | `angle × 256` | `Quantize() = Write(); Read();` |
| Source | `WriteBitCoord` / `WriteBitCoordMP(f, bIntegral, bLowPrecision)` | `WriteBitAngle(f, numbits)` | 位数在 `bitbuf.cpp` |

- 本仓 `c2` 是 float32 全量。量化必须"每步前把双方整态按线格式往返一遍"（Teeworlds 的 `Quantize()` 形态），否则 C2 重放每次都对不上。
- 量化步长 `q` 的最大位置误差 = `q/2`（几何结论）。没有现成取值可抄。

## 5. 边界

- 没有"按丢包率算冗余条数"的现成公式。
- 没有现成论证支持"delta + unreliable 必须做 NAK"；准确表述是"代价 = 一次全量往返"。
- ≤16 人的兴趣管理收益没有现成数据。
- ENet throttle 与真实丢包是两回事：读数要分开 `PEER_PACKET_THROTTLE` / `PEER_PACKET_LOSS` / `PEER_ROUND_TRIP_TIME`。
