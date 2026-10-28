# 16 人规模下的联机：命中补偿 / 带宽与分片预算 / 渲染插值

> 设计上限 16 人；现行上限 `ROYALE_MAX_PLAYERS := 16`（`server/lobby/lobby_rooms.gd`）。

## 1. 带宽与分片预算

载荷按 `core/net/net_codec.gd` 的 schema 折算（trail 2 点、装枪 + 1 件背包、30Hz；**P1.5 起为稳态帧**——世界包滚动关键帧 DELTA、本人包差分）：

| 量 | 值 |
|---|---|
| 世界包（稳态 keyframe 帧） | `12 + 35 + (N-1) × 7` B/包（N=16 ⇒ **152 B**），扇出到 N 个 peer |
| 世界包（FULL：请求修补 / 换局 / 名单变化） | `8 + N × 33` B/包（N=16 ⇒ **536 B**） |
| 本人包 | 全量 **99 B**（每 role 每 60 tick 错峰一次）/ 差分典型 **36 B**，30Hz |
| 服务器上行（N=16） | 世界 `152 × 16 × 30 ≈ 71.3 KB/s` + 本人 `16 × ≈1.14 KB/s ≈ 18.2 KB/s` ⇒ **≈89 KB/s**（≈0.71 Mbit/s） |
| 单端下行（N=16） | `(152 + 36) × 30 ≈ 5.5 KB/s` |

- 服务器上行仍是 O(N²)：世界包载荷 ∝ N 且每个 peer 收一份；N=16 下世界包占上行约 80%（P1.5 前约 92%）。
- 现状没有兴趣管理 / PVS：世界包含全部玩家（含自己那份）。
- 合同：**世界包必须恒 1 片**。`unreliable` = `UNSEQUENCED | UNRELIABLE_FRAGMENT` ⇒ 丢一片 = 整帧丢。
- 最坏（FULL、16 人各 4 点 trail）：`8 + 16 × 49 = 792 B` ⇒ 1 片（`TRAIL_WIRE_MAX := 4`，MTU 预算 1400 B）；稳态 keyframe 帧远低于此。
- 改世界字段 / 差分位序 / `TRAIL_WIRE_MAX` 前跑 `tests/probe/snapshot_size_probe.tscn`（判词 `SNAPSHOT SIZE PROBE: ALL-OK`，含 ⑥~⑨ 的增量尺寸/峰值断言）。
- 历史：2026-10-24 bool 打包把世界条目 51→48 B、本人包 102→94 B；2026-10-26 P1 定点化把世界条目 48→33 B、输入包 46→42 B；P1.5 增量/差分把稳态世界包再降到 ≈28%（见上表）。

## 2. 命中补偿：现状 = 没有

- 伤害全走服务器模拟的实体子弹：`server/match/match_combat.gd::_adjudicate_bullets()` 用子弹上一位置→当前位置的线段与玩家受击面（`Player.hurt_rect()`，经 `core/sim/hit_shape.gd`）判命中。
- `beam_fired` 只 `_rpc_all` 广播视觉，不裁决伤害；没有 hitscan 路径。
- 没有回退命中盒、没有 lag compensation、没有按射手视图时刻回退。
- 客户端看到的对手位置是插值后的历史位置（比权威晚约 50ms，`PLAYOUT_TICKS = 3`）⇒ 射手除了提前量还要把这段显示延迟算进去；300px/s 的横向目标在 50ms 内位移约 15px，足以让"看着中/服务器不中"分家。

## 3. 远端副本：playout 缓冲插值

- `player_replica.gd`：快照位置进定长历史环（`HISTORY_MAX = 12`），`_process` 在播放时钟的 `render_tick` 处夹逼插值，再把取样点锚到本地玩家最近的环面副本。
- `PLAYOUT_TICKS = 3`（60Hz tick 域）；下行 30Hz ⇒ 1.5 个发包间隔 ≈ **50ms 缓冲**，也是画面相对权威的滞后量。
- 大跳变（回溯 / 重生 / 换边，`SNAP_DIST = 128 px`）清历史一帧落位；正常位移走插值。
- 幽灵体跟**未经平滑**的最新快照锚点（预测面最小陈旧）。
- 两个 `anchor_to_nearest` 是承重的：渲染位置与目标相隔整幅地图时最短向量为 0。
- 16 人下每个客户端各跑 15 份历史环 + 15 个播放时钟；都是定长、无分配热点。

## 4. 边界

- `snapshot_size_probe` 的 N 折算表只到 N=8；16 人的每秒读数是由 schema 算术折算，不是探针产出。
- 抖动 / 丢包 / 命中缺口的真链路读数没有仪器：无丢包注入路径，无取图探针。
