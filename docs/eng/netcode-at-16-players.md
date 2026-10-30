# 16 人规模下的联机：命中补偿 / 带宽与分片预算 / 渲染插值

> 设计上限 16 人；现行上限 `ROYALE_MAX_PLAYERS := 16`（`server/lobby/lobby_rooms.gd`）。

## 1. 带宽与分片预算

载荷按 `core/net/net_codec.gd` 的 schema 折算（trail 2 点、装枪 + 1 件背包，世界与本人包；**每包全量自包含**，v7 起 DELTA 编解码已删）。**2026-10-30 起所有人数的下行都是 60Hz**（用户指定），下表按 60Hz 重算：

| 量 | 值 |
|---|---|
| 世界包（每包全量） | `8 + N × 25` B/包（trail 2 点；N=16 ⇒ **408 B**；空 trail = 280 B），60Hz，扇出到 N 个 peer |
| 本人包 | 全量 **99 B**，每 tick 一包（≈5.9 KB/s/role） |
| 服务器上行（N=16） | 世界 `408 × 16 × 60 ≈ 392 KB/s` + 本人 `16 × 5.9 KB/s ≈ 95 KB/s` ⇒ **≈487 KB/s**（≈3.9 Mbit/s；trail 2 点/多人回溯时；常态 ≈364 KB/s） |
| 单端下行（N=16） | `(408 + 99) × 60 ≈ 30 KB/s` |

- 服务器上行仍是 O(N²)：世界包载荷 ∝ N 且每个 peer 收一份；N=16 下世界包占上行约 84%。
- 现状没有兴趣管理 / PVS：世界包含全部玩家（含自己那份）。
- 合同：**世界包必须恒 1 片**。`unreliable` = `UNSEQUENCED | UNRELIABLE_FRAGMENT` ⇒ 丢一片 = 整帧丢。
- 最坏（16 人各 4 点 trail）：`8 + 16 × 33 = 536 B` ⇒ 1 片（`TRAIL_WIRE_MAX := 4`，MTU 预算 1400 B）；v6 同形是 792 B。
- 改世界字段 / `TRAIL_WIRE_MAX` 前跑 `tests/probe/snapshot_size_probe.tscn`（判词 `SNAPSHOT SIZE PROBE: ALL-OK`，5 条断言）。
- 历史：2026-10-24 bool 打包把世界条目 51→48 B、本人包 102→94 B；2026-10-26 P1 定点化把世界条目 48→33 B、输入包 46→42 B；2026-10-30 v7 把 trail 定点化 ⇒ 世界条目 33→**25 B**、最坏包 792→**536 B**；P1.5 增量/差分曾把稳态世界包降到 ≈28%，但 2026-10-28 因乱序/丢包下 RTT 级冻结而**整体放弃、回退全量**，v7 把差分代码一起删除。

## 2. 命中补偿：现状 = 没有

- 伤害全走服务器模拟的实体子弹：`server/match/match_combat.gd::_adjudicate_bullets()` 用子弹上一位置→当前位置的线段与玩家受击面（`Player.hurt_rect()`，经 `core/sim/hit_shape.gd`）判命中。
- `beam_fired` 只 `_rpc_all` 广播视觉，不裁决伤害；没有 hitscan 路径。
- 没有回退命中盒、没有 lag compensation、没有按射手视图时刻回退。
- 客户端看到的对手位置是插值后的历史位置（比权威晚约 33ms，`PLAYOUT_TICKS = 2`）⇒ 射手除了提前量还要把这段显示延迟算进去；300px/s 的横向目标在 33ms 内位移约 10px。

## 3. 远端副本：playout 缓冲插值

> playout 机制(缓冲 / 夹逼 / `SNAP_DIST` / 幽灵体 / 锚定)的权威见 [`netcode-client-interp-and-input-details.md`](netcode-client-interp-and-input-details.md);本节只留 16 人规模与代价读数。

- 16 人下每个客户端各跑 15 份历史环 + 15 个播放时钟；都是定长、无分配热点。
- ★ 2026-10-30 全 60Hz + playout 2 的代价：16 人局服务端上行 ≈487 KB/s（trail 2 点；§1 表）；好处是样本间隔与画面滞后都只有 16.7/33ms，对手观感最接近本地玩家。

## 4. 边界

- `snapshot_size_probe` 的 N 折算表只到 N=8；16 人的每秒读数是由 schema 算术折算，不是探针产出。
- 抖动 / 丢包 / 命中缺口的真链路读数没有仪器：无丢包注入路径，无取图探针。