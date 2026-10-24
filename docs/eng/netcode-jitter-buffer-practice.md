# 目标延迟与播放速率：主流实现的源码级调研（增量）

> 本仓没有抖动缓冲、没有目标延迟、没有播放速率控制：远端玩家副本直接渲染最新快照（`scenes/player/player_replica.gd::_process` 里 `global_position = target`）。不存在 `PlayoutClock` 与 `PLAYOUT_TICKS`。

## 1. 本仓的现行机制

- 副本位置 = 最近一个 30Hz 快照的权威位置，锚到本地玩家最近的环面副本；两包之间不动。
- 没有位置历史、没有夹逼插值、没有外插、没有 underrun 处理。
- 没有播放时钟：世界包 `tick`（60Hz 物理 tick 域）只用于丢弃乱序旧快照。
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

- 本仓没有这些参数对应的实现：目标延迟、深度补偿、速率纠偏、硬重置都不存在。
- 30Hz 直出 ⇒ 两包之间副本静止，单步位移 = 对手速度 × 33ms；丢包 ⇒ 冻结到下一包。
- 抖动 / 丢包读数没有仪器：没有丢包注入路径，没有取图探针。
