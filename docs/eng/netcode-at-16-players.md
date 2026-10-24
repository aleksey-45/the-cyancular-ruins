# 16 人规模下的联机：命中补偿 / 带宽与分片预算 / 渲染插值

> 设计上限 16 人；现行上限 `ROYALE_MAX_PLAYERS := 16`（`server/lobby/lobby_rooms.gd`）。

## 1. 带宽与分片预算

载荷按 `core/net/net_codec.gd` 的 schema 折算（trail 2 点、装枪 + 1 件背包、30Hz）：

| 量 | 值 |
|---|---|
| 世界包 | `7 + N × 48` B/包，扇出到 N 个 peer |
| 本人包 | 94 B × N（各一份，定向） |
| 服务器上行（N=16） | `(16 × 775 + 1504) × 30 ≈ 407.3 KB/s`（≈3.3 Mbit/s） |
| 单端下行（N=16） | `(775 + 94) × 30 ≈ 25.5 KB/s` |

- 服务器上行是 O(N²)：世界包载荷 ∝ N 且每个 peer 收一份。16 人下世界包占上行 92%（`16 × 775 = 12400 B` vs 本人包 `1504 B`）。
- 现状没有兴趣管理 / PVS：世界包含全部玩家（含自己那份）。
- 合同：**世界包必须恒 1 片**。`unreliable` = `UNSEQUENCED | UNRELIABLE_FRAGMENT` ⇒ 丢一片 = 整帧丢。
- 最坏（16 人各 4 点 trail）：`7 + 16 × 64 = 1031 B` ⇒ 1 片（`TRAIL_WIRE_MAX := 4`，MTU 预算 1400 B）。
- 改世界字段或 `TRAIL_WIRE_MAX` 前跑 `tests/probe/snapshot_size_probe.tscn`（判词 `SNAPSHOT SIZE PROBE: ALL-OK`）。
- ★ 2026-10-24:世界条目 51→**48 B**、本人包 102→**94 B** 是 bool 打包（`T_BOOLS`，按记录 1 B 标志字节）带来的;上表已按新尺寸重算。

## 2. 命中补偿：现状 = 没有

- 伤害全走服务器模拟的实体子弹：`server/match/match_combat.gd::_adjudicate_bullets()` 用 `MazeGenerator.toroidal_delta_px(...)` 与 `HIT_RADIUS`（= `BulletBase.PLAYER_HIT_RADIUS` = **40.0**）判命中。
- `beam_fired` 只 `_rpc_all` 广播视觉，不裁决伤害；没有 hitscan 路径。
- 没有回退命中盒、没有 lag compensation、没有按射手视图时刻回退。
- 客户端看到的对手位置是插值后的历史位置（比权威晚约 67ms，`PLAYOUT_TICKS = 4`）⇒ 射手除了提前量还要把这段显示延迟算进去；300px/s 的横向目标在 40px 判定半径下足以打空。

## 3. 远端副本：playout 缓冲插值

- `player_replica.gd`：快照位置进定长历史环（`HISTORY_MAX = 12`），`_process` 在播放时钟的 `render_tick` 处夹逼插值，再把取样点锚到本地玩家最近的环面副本。
- `PLAYOUT_TICKS = 4`（60Hz tick 域）；下行 30Hz ⇒ 2 个发包间隔 ≈ **67ms 缓冲**，也是画面相对权威的滞后量。
- 大跳变（回溯 / 重生 / 换边，`SNAP_DIST = 128 px`）清历史一帧落位；正常位移走插值。
- 幽灵体跟**未经平滑**的最新快照锚点（预测面最小陈旧）。
- 两个 `anchor_to_nearest` 是承重的：渲染位置与目标相隔整幅地图时最短向量为 0。
- 16 人下每个客户端各跑 15 份历史环 + 15 个播放时钟；都是定长、无分配热点。

## 4. 边界

- `snapshot_size_probe` 的 N 折算表只到 N=8；16 人的每秒读数是由 schema 算术折算，不是探针产出。
- 抖动 / 丢包 / 命中缺口的真链路读数没有仪器：无丢包注入路径，无取图探针。
