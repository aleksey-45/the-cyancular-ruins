# 16 人规模下的联机：命中补偿 / 带宽与分片预算 / 渲染插值

> **仓主裁定（2026-10-09）**：设计上限按 **16 人**做（现行 `ROYALE_MAX_PLAYERS = 8`）。
> **这份文档是什么**：那三份计划的 **spec** —— 事实、实测账、缺口与裁定依据都在这里；计划只讲怎么做。
> **计划**：[命中补偿](../superpowers/plans/2026-10-09-lag-compensation.md) ·
> [16 人预算](../superpowers/plans/2026-10-09-snapshot-budget-16p.md) ·
> [playout 插值](../superpowers/plans/2026-10-09-replica-playout-interpolation.md)（互不依赖，可任意顺序）。
> **真相源**：源码 > 探针实测 > 本文档 > 其它。行号只在写下那天成立。

---

## 1. 账：16 人到底要多少（实测 + 算术）

| 量 | 值 | 出处 |
|---|---|---|
| 服务器上行 | **143.85 KB/s（1.15 Mbit/s）** | `snapshot_size_probe` N 表（2026-10-09） |
| 单端下行 | **54.20 KB/s（0.43 Mbit/s）** | 同上 |
| 世界包（典型，trail 2 点） | 7 + 16×51 = **823 B** ⇒ **1 片** | 同上（★ 那张表的分片折算只跑到 N=8，823 是算出来的） |
| **最坏：16 人全在回溯** | **实测 1847 B ⇒ 2 片**（算术先估 1831 B）★ **已修**：线上 trail 截到最近 4 点 ⇒ **1079 B ⇒ 1 片** | 探针 ④（2026-10-09） || 本人包 | 16 × 102 B = 1632 B/帧 = **98 KB/s**（占上行 68%） | 探针 |
| 分片后果 | 快照走 `unreliable` = `UNSEQUENCED｜UNRELIABLE_FRAGMENT` ⇒ **丢一片 = 整帧丢** | [`netcode-snapshots.md`](netcode-snapshots.md) §2.3 |

★★ **结论一：16 人不需要兴趣管理/相关性系统。** 1.15 Mbit/s 对自建服务器是可接受的量级；
O(N²) 的成因是本人包（N×102 B/帧），在 16 人下也只是 98 KB/s。
**需要的是"最坏情况不许分片"** —— 那是一条真正的合同（丢一片 = 整帧丢），不是数值调参。

★ **结论二：现行上限是 8**（`server/lobby/lobby_rooms.gd:21`）⇒ "按 16 人做"的第一件事是**改上限并排查
假设 8 人的地方**（HUD/出生点/计分/房间校验），不是加带宽优化。

---

## 2. 命中补偿：**先钉伤害路径**（★ 订正我 2026-10-09 的口头结论）

**读码所得**：伤害**全走服务器模拟的实体子弹**（`server/match/match_combat.gd` 的子弹裁决，
`weapon_base.gd` 的 `bullet_scene`）；`beam_fired`（`match_combat.gd:171-189`）只 `_rpc_all` **广播视觉**，
客户端据此画光束。

⇒ **我先前把"即时光束"当成 hitscan、并据此建议"回退命中盒"——前提不成立**（激光不裁决伤害）。
"回退命中盒"是给**开火即判定**的武器用的标准解法（Valve《Lag Compensation》），
本仓没有那条路径 ⇒ 那个方案**无处可施**。

**真正会"打中没伤害"的机制**（本仓确实存在）：客户端看到的目标是**滞后的**
（追赶滞后实测 ±0ms 22.6 / ±8ms 29.7 / ±16ms 37.2 px）+ 单向延迟。射手朝**看到的旧位置**开火，
服务器让子弹从**权威位置**飞 ⇒ **落点在目标身后**。300px/s 的横向目标 + 40px 判定半径 ⇒ 足以打空。

**三条候选（按代价排）**：
1. **把视图滞后压下去** —— 计划 C（playout 插值）把"低通滞后 22.6~37.2px"换成"选出来的常量延迟"。
2. **接受它** —— 实体弹游戏本来就要求提前量，这是设计选择而非缺陷。
3. **按射手视图时刻回退命中测试** —— 少见、且会引入"拐角被击中"的观感；只在 1 不够时才考虑。

⇒ 计划 A **先量后定**：先用代理/真局把"缺口有多大、多常发生"读出来，再选 1/2/3。**不预先承诺实现回退。**

---

## 3. 渲染插值：playout 缓冲（接 `netcode-snapshots.md` §4.3/§5.3）

- **已做（2026-10-09）**：大跳变阈值（回溯/重生/换局 ⇒ 一帧直落），判据在 `replica_smoothness_probe` 相 D。
- **没做**：抖动。现状是指数追赶（低通）：恒速时**永久滞后 `v/k`**（实测 22.6~37.2px，抖动越大越滞后），
  且把丢包/迟到转成**速度尖峰**。
- **该做的**：**位置历史 + 固定 playout 延迟**，在夹住渲染时刻的两个快照之间**线性插值**
  （Gaffer：缓冲 = 3× 发送间隔 ⇒ 60Hz 下 3 tick = **50ms**；Valve 默认 100ms）。
  ⇒ 延迟变成**选出来的常量**（50ms ≈ 15px @300px/s，**比今天的 22.6~37.2px 还小**），且平滑是真线性。
- **必须一起做的**：**客户端 playout 时钟**（按世界包的 `tick` 计;快/慢用 ±5% 微调 = time dilation 的最小形态）。
  没有它,"渲染在多久之前"是不可控的 —— 这也正是当年那套 alpha 插值退化成"贴最新"的根因
  （`push()` 每包把时钟重置到 `latest-1` ⇒ 缓冲深度 0）。
- **不能顺手丢的**：幽灵体继续跟**未经平滑的最新权威值**（预测面零回归）;大跳变仍走直落
  （插值**不许**横穿一次瞬移）。

---

## 4. 来源

- [Gaffer《Snapshot Interpolation》](https://gafferongames.com/post/snapshot_interpolation/)（**读了全文**：10~30Hz、缓冲 ≈3× 间隔、"60pps 收益不大"）
- [Gaffer《State Synchronization》](https://gafferongames.com/post/state_synchronization/)（**读了全文**：接收侧抖动缓冲 4~5 帧）
- [Gaffer《What Every Programmer Needs To Know About Game Networking》](https://gafferongames.com/post/what_every_programmer_needs_to_know_about_game_networking/)（**读了全文**）
- Valve《Lag Compensation》/ Overwatch time dilation（**只有指针，未读正文** —— 该站被 Anubis 挡 / 只有二手摘要）
- 本仓实测：[`netcode-snapshots.md`](netcode-snapshots.md) §2 · [`netcode-input-uplink.md`](netcode-input-uplink.md) §2 · `replica_smoothness_probe` 的相 A/C 读数
