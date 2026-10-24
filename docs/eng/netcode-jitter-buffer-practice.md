# 目标延迟与播放速率：主流实现的源码级调研（增量）

> 本仓有**固定 playout 缓冲 + 本地播放时钟**，没有自适应目标延迟、没有抖动驱动的深度控制律之外的速率调控：远端玩家副本渲染「最新快照 − `PLAYOUT_TICKS`」那一刻的夹逼插值位置（`scenes/player/player_replica.gd` + `core/net/playout_clock.gd`）。

## 1. 本仓的现行机制

- 副本位置 = 两条相邻 30Hz 快照之间的夹逼插值，取样时刻由本地播放时钟决定；延迟 = 选择的常量 `PLAYOUT_TICKS = 4`（≈67ms）+ 抖动驱动的深度补偿（窗口展布 × 1.5，上限 4 tick）。
- 位置历史环定长（`HISTORY_MAX = 12`）；两端冻结（不外插、不倒退）。
- 时钟参考取窗口内**最小到达延迟**的观测（NTP §10 式），自己不跟服务器做显式时钟同步；漂移靠纠偏（死区 1.5 tick、每秒最多 ±10%）。
- 输入侧有界队列：`cap = clamp(peak + 2, 4, 16)`（单位 = 条 tick 记录，U1 后一条 = 1 tick）、`peak` 每 tick 衰减 1、丢最旧一条并合并边沿、`reset_input_queue()` 连包络一起清。

## 2. 主流实现的默认值

| 参数 | 默认值 |
|---|---|
| WebRTC NetEq `quantile` | 0.95 |
| NetEq `kBucketSizeMs` / `kDelayBuckets` | 20 ms / 100（上限 2000 ms） |
| NetEq `forget_factor` / `resample_interval_ms` | 0.983 / 500 |
| NetEq `kStartDelayMs` | 80 |
| NetEq `ms_per_loss_percent` | 20（丢包概率每 1% 值 20 ms） |
| NetEq 时标上限 | ≈100 ms/s（±10%），`kMinTimescaleInterval = 5` |
| Unity Entities `InterpolationDelayJitterScale` | 1.25 |
| Unity Entities `InterpolationDelayCorrectionFraction` | 0.10 |
| Unity Entities `InterpolationTimeScaleMax` / `Min` | 1.1 / 0.85 |
| Unity Entities `TargetCommandSlack` | 2 tick |
| Unity Entities `NumAdditionalCommandsToSend` | 2（硬上限 32、最小 1） |
| Unity NGO `serverBufferSec` / `hardResetThresholdSec` / `adjustmentRatio` | 0.05 s / 0.2 s / 0.01 |
| netfox 时钟 | Remote → Reference（nudge，超阈值 panic 重置）→ Simulation（只前进） |

## 3. 边界

- 本仓没有这些参数对应的实现：自适应目标延迟（NetEq 那套分位选样）、显式时钟同步、硬重置都不存在；只有「窗口最小延迟 + 固定 playout + 深度补偿上限」这一档。
- 30Hz + 67ms 缓冲 ⇒ 画面比权威晚约 2 个发包间隔；幽灵碰撞体不跟这段延迟（它直出最新权威位置），故「看得见的对手」与「挡你的对手」之间有 ≤ 67ms 的位置差，属于设计交换。
- 抖动 / 丢包读数没有仪器：没有丢包注入路径，没有取图探针；插值观感只能靠人眼。
