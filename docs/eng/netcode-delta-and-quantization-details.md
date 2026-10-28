# 增量与量化的细节：一手源码调研（Q3 / DarkPlaces / Teeworlds / Source / Gaffer / ENet）

## 1. 本仓现状

- 快照每包发全字段绝对值：世界包 13 字段、本人包 `c2` 全量（float32）。没有变更位、没有基线、没有增量。
- ★ 2026-10-26 P1 起世界包 `pos`/`vel`/`aim` 与输入 `aim` 已定点化（方案见 §6）；★ **P1.5 增量已于 2026-10-28 放弃（回退全量，理由：DELTA 链在乱序/丢包下 RTT 级冻结）**，编解码能力保留给探针；世界包滚动关键帧 + 逐玩家掩码、本人包 30Hz 差分 + 60 tick 错峰全量（方案见 §7）；`c2` 仍是 float32（回滚锚点，不与世界包同批量化，差分按字段覆盖）。
- `ack_seq` 是服务器已消费的输入序，不是"客户端已收到的快照 tick"。客户端收世界包时只比较 `_last_snap_tick`，从不外发 ⇒ 没有可用的 delta 基线回路（P1.5 起改为"基准断了置 `BIT_NEED_FULL` 请求位"）。
- 无兴趣管理 / PVS：世界包含全部玩家（含自己那份，客户端不消费）；16 人 1 片。
- 应用层无拥塞控制（ENet 自带一层，见 §2）。
- 带宽上限未设：`create_host()` 不传 in/out ⇒ 0 = 不限。`ENet_CHANNELS := 4`。
- 序号：本仓 u32（60Hz 下 2.27 年回绕）；先回绕的是 ENet 自己的 u16 序号（60Hz 下 18 分 12 秒）。
- 重连：服务器把 `_ack_seq[role]` 归 0 重协商锚点；输入队列与抖动包络一起清；客户端 `NetBus.reset_snapshot_state()` 作废合并基准并请求 FULL。
- 压缩：本仓单端下行约 0.61 KB/帧（N=16，P1 后：世界 535 B + 本人 99 B；P1.5 稳态更低，见 §7），落在 zstd 不划算的区间。

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

## 6. P1 已落地（2026-10-26，`PROTO_VERSION 4→5`）

| 字段 | 线格式 | 步长 / 分辨率 | 最大量化误差 | 端 |
|---|---|---|---|---|
| 世界 `pos` | 2×i16 | 0.5 px（`Q_SCALE = 2`） | ±0.25 px | 下行 |
| 世界 `vel` | 2×i16 | 0.5 px/s | ±0.25 px/s（先钳 ±6000） | 下行 |
| 世界 `aim` | u8 角度 | 2π/256 ≈ 1.40625° | ±π/256 ≈ 0.70° | 下行 |
| 输入 `aim` | 2×i16 | 1e-4（单位向量） | ≤1e-4（方向 ≈0.006°） | 上行 |
| `c2` / `trail` / `ax` / `st` / `ct` | 不动 | — | — | — |

- ★ **为什么不是 0.1px**：i16 值域只有 ±32767，最宽地图 9600 px ×10 = **96000** 装不下；取 0.5px（9600×2 = 19200，余量到 16383px 的地图）。超界一律 `clampi` 饱和，**绝不 wrap**。
- 字节（代码算式，`net_wire_smoke` / `snapshot_size_probe` 的 readout 会实测复核）：世界条目 48→**33 B**（trail 2 点，−31%）、无 trail 32→17 B、最坏包 1031→**791 B**；输入包 46→**42 B**（−8.7%）；本人包 94 B 不变（P1 批；P1.5 为携带 tick/flags 头加到 **99 B**，见 §7）；世界包 N=16 775→**535 B**；服务器上行（扇出算式）407.3→**294.8 KB/s**。
- 容差断言：`net_wire_smoke` ③ 与 `snapshot_size_probe` ③⑤ 的往返改成定点容差（pos/vel ≤0.2501、aim 点积 ≥0.9999 且解码长度 ≈1）；把定点舍入删掉或编码宽度/顺序写错 ⇒ 这些断言红。
- 边界（照实）：
  - 世界 `pos` 的 0.25px 阶梯 ⇒ 对手副本与幽灵体位置有亚像素量化（观感无变化）；不参与命中裁决（命中走服务器权威位置 + 回放历史）。
  - 世界 `aim` 只驱动枪口指向/朝向呈现，不进任何判定。
  - 输入 `aim` 的 1e-4 误差会进入服务器模拟的瞄准方向（客户端预测用全精度鼠标值）⇒ 理论上有极小的方向分歧；它**不在 c2 回账块**里，不触发 C2 回滚。
  - 改 `PROTO_VERSION` ⇒ **两端必须同包发布**，旧客户端连新服务器会被解码拒绝（大声失败，不是静默错位）。
- 未做（后续批）：`c2` 量化（必须两端一起，单方面量化 ⇒ 每次重放判分歧）、`trail` 量化（<1 B/点收益）、真位流打包。

## 7. P1.5 增量/差分已落地（2026-10-26，`PROTO_VERSION 5→6`）

**世界包**（`KIND_WORLD`）：`flags` bit0 = FULL。
- FULL：`8 B 头 + N×(role1 + 32 B 全字段 trail 2 点)`（N=16 ⇒ 536 B）。
- DELTA：`12 B 头（多 base_tick）+ N×(role1 + mask2 + 置位字段值)`；**mask bit i ↔ WORLD_SCHEMA[i]**（T_BOOLS/trail 各 1 位），`mask=0xFFFF` = **keyframe**（全字段绝对值，35 B/人）。整员省略 = 无变化。典型「全员只 pos 变 + 1 个 keyframe」= `12 + 35 + 15×7 = 152 B`（FULL 的 28%）。
- **滚动关键帧**：`k = max(1, ceil(N×SNAPSHOT_STRIDE/WORLD_KF_PERIOD))`（N=16 ⇒ k=1），每包刷新 k 人、游标轮转 ⇒ 每人 ≤60 tick 被绝对刷新；**没有周期性整包 FULL**（避免 60 tick 边界尖峰）。
- FULL 触发：客户端请求位 / 回合态变化 / 名单变化 / 首包。

**本人包**（`KIND_OWN`）：30Hz 发送，`flags` bit0 = FULL。
- FULL = `13 B 头 + 1 武器标志 + 67 B c2 + 12 B 武器块 + (1+6n) B inv`（n=1 ⇒ 99 B）。
- DELTA = `20 B 头（含 base_tick + mask u32）+ 变化字段值`；**mask 位序 = C2_SCHEMA 条目序 → WEAPON_SCHEMA → 末尾 inv**（`_own_unit_at` 派生，改 schema 自动跟着变）。典型「pos+vel 变」= 36 B；静止帧 = 20 B。
- 全量每 role 每 60 tick 一次、**相位错峰** `floor(idx×30/N)×2` tick（同一 tick 不会全员全量；N≤30 互不重合）；武器块存在性变化强制 FULL。

**修复路径**：客户端 `net_bus.gd` 在解码边界合并（下游仍收完整 `{tick, players}` / `{ack_seq, q, c2}`）；DELTA 的 `base_tick` 必须等于已应用的包 tick，否则置 `BIT_NEED_FULL`（输入 `held` 512 位，reliable）→ 服务器下一世界包 FULL / 该 role 下一本人包 FULL。本人包另有 **60 tick 兜底**；世界包只靠请求路径（滚动关键帧只管每人绝对刷新，整包基准仍要连续）。

**字节/带宽**（N=16，30Hz，典型帧）：世界包 FULL 536 B → 稳态 **152 B/包**；本人包全量 **99 B** / 差分典型 **36 B**（每 role 全量 1 次/秒，≈1.14 KB/s）；服务器上行约 294.8 → **≈89 KB/s**；单端下行 ≈5.5 KB/s。容差/风险见 `registered-debt.md` §十八。
