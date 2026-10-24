# playout 时钟的目标该是什么：一手来源调研

> 现行实现：**固定 playout 缓冲 + 本地播放时钟**。远端玩家副本渲染「最新快照 − `PLAYOUT_TICKS`」那一刻的夹逼插值位置（`scenes/player/player_replica.gd`，时钟本体 `core/net/playout_clock.gd`）。
> 时钟的参考**不是**最新收到的包：观测 `o = local_ms − tick × TICK_MS`，取最近 8 个观测的最小值（NTP RFC 5905 §10 选最小 delay 的样本）；迟到包只给更大的 `o`，动不了参考。
> `PLAYOUT_TICKS = 4`（60Hz tick 域）＝ 下行 30Hz 的 2 个发包间隔 ≈ 67ms 缓冲；抖动深度按窗口展布 × 1.5 补偿（上限 4 tick）。
> 世界包的 `tick` 既用于丢弃乱序旧快照（`tick < _last_snap_tick` ⇒ 丢），也是播放时钟与位置历史的时标。

## 1. 为什么不是「向最新包追」

- 「渲染最新样本」= 缓冲深度 0，平滑度等于包的到达平滑度（抖动原样透传到画面）。Valve / Bernier 2003 的结论是：包间隔不固定时，「向最新目标移动」比「固定延迟 + 插值」更差。
- NTP §10 的做法（窗口内挑最小 delay 的样本）保证迟到包不会把参考往回拽；长期漂移本身就是两端速率差，故不需要显式的频率状态。
- 本仓另有一条硬约束：副本的**幽灵碰撞体**不跟这个时钟（它直出最新权威位置）—— 预测面要最小陈旧，观感面才要平滑。

## 2. 一手来源

| 来源 | 取什么 |
|---|---|
| NTP RFC 5905 §10（clock filter algorithm） | 用窗口内最小 delay 的样本做参考 |
| RTP RFC 3550 §6.4.1（interarrival jitter） | 一阶平滑、抖动指标口径 |
| Valve《Source Multiplayer Networking》 | 客户端时间 − 插值延迟 |
| Bernier, Y. 2001 / 2003（Valve 网络同步文） | 固定延迟 + 插值优于追最新样本 |
| WebRTC NetEq / Unity Entities / netfox | 目标延迟与速率纠偏的默认值（本仓只用了其中的固定 playout + 深度补偿一档） |
