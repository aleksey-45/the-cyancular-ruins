# 目标延迟与播放速率：主流实现的源码级调研（增量）

> **与 [`netcode-playout-clock-sync-sources.md`](netcode-playout-clock-sync-sources.md) 的分工**：那一份查**规范与游戏博客**（RFC 5905/3550、Gaffer、Valve/Bernier、Overwatch），结论是"没有任何来源主张目标 = 最新收到的样本"；本份**只做增量** —— 查**主流实现里目标延迟（深度）与播放调度/速率到底怎么定**，并给出能落地的公式与常数。两份都**不重复** [`netcode-snapshots.md`](netcode-snapshots.md) §5.3 的现状与实测。
> **纪律**：只引一手（源码 / 官方 API 文档 / spec）；每条标 **读了全文** / **只片段** / **取不到**；与我们的关系（支持 / 无关 / 相反）都明说；取不到的逐个列在 §7。**真相源排序**：源码 > 探针实测 > 本文档 > 其它。

---

## 1. 结论（先说）

1. ★★ **主流里有两派，且互相矛盾（不调和）**：
   - **自适应深度派（WebRTC NetEq）**：目标延迟 = **到达延迟分布的分位数**（默认 **95 分位**），由**直方图 + 指数遗忘**在线估计；另有**丢包/乱序**项、**上下界**与**起步值**。
   - **常量深度派（Unity、netfox）**：缓冲深度是**显式参数/常量**，自适应的是**时钟速率**而不是深度。
   ⇒ 上一份说的"游戏 netcode 文献空白"，在**实现**层面并不空白，只是**答案不是一个数**。
2. **"按分位数定深度"确有原句**（上一份没找到）：NetEq 头文件 *"The optimal delay is decided such that the probability of underrun is lower than `1 - histogram_quantile`"*，`histogram_quantile` 默认 **0.95**（§2）。
3. **WebRTC 的"到达延迟"是相对量**：`PacketArrivalHistory::GetDelayMs()` 归一化到 **2 秒窗口内最早到达的包** ⇒ 与我们 `o_min` 是**同一参考系**（**支持**我们 2026-10-09 那次改动）。
4. **速率上限是共识**：WebRTC "**about 100 ms/s**"（= ±10%），Unity `InterpolationTimeScaleMax/Min = 1.1 / 0.85`、每帧最多纠 **10%** 误差，NGO `AdjustmentRatio = 0.01`。⇒ 我们 `DRIFT_MAX = 0.10` **有据**（**支持**）。
5. **现在的"展布折半"（`_depth_comp`）没有来源**；最接近的一手规则是"**对到达延迟分布取 95 分位**"（WebRTC）或"**常量 × 抖动乘子 1.25**"（Unity）。§8 给照搬式。
6. **Ramjee 1994 正文仍然取不到**（本次用 OpenAlex + Semantic Scholar 核实：`oa_status=closed`、`any_repository_has_fulltext=false`）⇒ **不引**它的 fast/slow 公式（§6.1）。
7. **Source 引擎 `cl_interp` 的官方关系仍取不到**（Valve wiki 仍是 **Anubis 反爬**；AlliedModders wiki 搜 `cl_interp` **零结果**，§6.2）。★ 但同族参数在 Unity NGO 有**官方默认值**，可替代使用。

---

## 2. WebRTC NetEq：目标延迟怎么定（**源码全文已读**）

**读的是什么**：libwebrtc 源码，取 **Firefox 内置的 libwebrtc 快照**（`mozilla/gecko-dev` master，`third_party/libwebrtc/modules/audio_coding/neteq/`，经 jsDelivr 直取原文）；`delay_manager.cc` 最后一次上游同步 = **2025-02-19，upstream `dadb9f4643`**（GitHub API commits 核实）。★ **照实说**：`webrtc.googlesource.com` 在本机**取不到**（`fetch failed`），所以引的是**上游代码的 vendored 副本**，不是上游站本身。

| 环节 | 文件 · 函数 | 规则与常数（原文数值） |
|---|---|---|
| 深度（主项） | `underrun_optimizer.cc` `UnderrunOptimizer::Update()` | 直方图取分位数：`optimal_delay_ms_ = (1 + bucket_index) * kBucketSizeMs`；`kBucketSizeMs = 20`、`kDelayBuckets = 100`（⇒上限 **2000 ms**） |
| 分位数 | `delay_manager.h` `DelayManager::Config` | `quantile = 0.95`、`forget_factor = 0.983`、`start_forget_weight = 2`、`resample_interval_ms = 500` |
| 语义（为什么是分位数） | `underrun_optimizer.h` 头注释 | *"Estimates probability of buffer underrun due to late packet arrival. The optimal delay is decided such that the probability of underrun is lower than `1 - histogram_quantile`."* |
| 量化步长 / 遗忘 | `histogram.cc` `Histogram::Add()` | 桶概率 Q30；每次入桶**全体 × `forget_factor`**，再把命中桶 `+= 32768 - forget_factor`（Q15）；`Reset()` 初值是 `0.5^(i+1)` 指数分布、`forget_factor_ = 0`（**头几个包快速收敛**） |
| 采样方式 | `underrun_optimizer.cc` | 有 `resample_interval_ms`（默认 **500 ms**）时，**只把该区间内的最大延迟**入桶（`max_delay_in_interval_ms_`）⇒ 95 分位是**"每 500 ms 的峰值延迟"的 95 分位**，比"每包延迟的 95 分位"**更保守** |
| 起步值 | `delay_manager.cc` | `kStartDelayMs = 80`（没有统计时用它，`Reset()` 也回到它） |
| 乱序/丢包项 | `reorder_optimizer.cc` `MinimizeCostFunction()` | 只对**被判定为 reordered** 的包入桶；最小化 `cost = delay_ms + 100 * ms_per_loss_percent * loss_probability`（Q30）；`ms_per_loss_percent = 20` ⇒ **丢包概率每 1% 值 20 ms** |
| 两项合成 | `delay_manager.cc` `DelayManager::Update()` | `target = max(underrun 项, reorder 项)`；乱序包**不进** underrun 直方图 |
| 上下界 | `delay_constraints.cc` `Clamp()` | 夹到 `[effective_min, maximum]`，再夹 `3 * max_packets_in_buffer * packet_len_ms / 4`（`max_packets_in_buffer = 200`、20ms 包 ⇒ **3000 ms**）；`kMaxBaseMinimumDelayMs = 10000` |
| 参考系（**与我们的 `o_min` 同构**） | `packet_arrival_history.cc` `GetDelayMs()` | `delay = max(0, (arrival − min_arrival) − (rtp − min_rtp))`，窗口 `kPacketHistorySizeMs = 2000` ⇒ **相对"窗口内最早到达的包"**，不是绝对延迟 |
| 缓冲水平平滑 | `buffer_level_filter.cc` `SetTargetBufferLevel()` | 目标 ≤20 / ≤60 / ≤140 / >140 ms ⇒ `level_factor_ = 251/252/253/254`（Q8）⇒ τ = `256/(256−f)` ≈ **51 / 64 / 85 / 128 次更新**（每次输出 10ms 音频 ⇒ 约 0.5~1.3 s）**目标越深、平滑越慢** |

⇒ 关系：**支持**"深度按到达延迟的鲁棒统计量设定"，且**直接给出**了一个可计算的规则（§8 第 1、2 条）。**相反**于"深度固定/追最新"。

## 3. WebRTC NetEq：播放速率怎么调（**源码全文已读**）

- **不调时钟，调音频**：加速/减速是时标（time-stretch）——`accelerate`（丢样本）/`preemptive_expand`（插样本）/`expand`（丢包时的 PLC）/`merge`，都在 `NetEq::Operation`（`api/neteq/neteq.h`）。
- **上限**：`decision_logic.h` `kMinTimescaleInterval = 5`，注释原句 *"The value 5 sets maximum time-stretch rate to about **100 ms/s**"* ⇒ **±10%**。两次时标操作之间必须等这个冷却时间（`TimescaleAllowed()`）。
- **触发阈值**（`decision_logic.cc` `ExpectedPacketAvailable()`）：`low_limit = TargetLevelMs()`，`high_limit = low_limit + packet_arrival_history_->GetMaxDelayMs() + 20ms`（`kDelayAdjustmentGranularityMs = 20`），`playout_delay_ms` 是**要播的那一点上的到达延迟估计**：
  - `>= high_limit * 4` ⇒ `kFastAccelerate`（狠追）；`>= high_limit` ⇒ `kAccelerate`；`< low_limit` ⇒ `kPreemptiveExpand`；否则 `kNormal`。
  - ⇒ **只在越过阈值时才动**，而不是每帧都动（**与我们的"每帧比例纠偏"不同**）。
- **没追上就真的丢**：缓冲不设上限式的"膨胀"，`delay_constraints_` 封顶（§2 表）。
- ⇒ 关系：**支持**"速率纠偏要有硬上限"；**无关**于"深度"；**相反**于"无阈值连续纠偏"。

## 4. Unity（**官方 API 文档全文已读**；两套 netcode 都给数）

### 4.1 Netcode for Entities（`ClientTickRate`，官方 API 文档，docfx 生成）

- `InterpolationDelayJitterScale`：*"Multiplier used to compensate received snapshot rate jitter when calculating the Interpolation Delay. **Default Value: 1.25.**"* ⇒ ★ **一条"× 抖动"的显式规则**。
- `InterpolationDelayCorrectionFraction`：**每帧**可纠正的插值延迟误差比例，默认 **10%**（"Good ranges: [0.075 - 0.2]"）；`InterpolationDelayMaxDeltaTicksFraction`：插值延迟**每帧变化**上限 = **10%** 的帧 deltaTicks（Good range [0.10 - 0.3]）。
- `InterpolationTimeNetTicks` / `InterpolationTimeMS`：**深度是常量参数**（一个覆盖另一个）。
- `InterpolationTimeScaleMax = 1.1`、`InterpolationTimeScaleMin = 0.85` ⇒ **播放速率被夹在 [0.85, 1.1]**；`PredictionTimeScaleMax/Min = 1.1 / 0.9`。
- 手册（`time-synchronization.html`）：*"The `interpolation delay` is calculated by taking into account **round trip time, jitter and packet arrival rate**, all data that is generally available on the client. We also add some additional time, based on the network tick rate, to make sure we can handle some packets being lost."* + *"slowly adjusts both `prediction tick` and `interpolation delay` in small increments … ensure that neither … goes back in time."*
  ★ **不支持**照抄成公式：这段是**散文**，**没有**给系数（1.25 那个乘子在 API 文档里，不在手册里）。
- 服务端回传"命令在缓冲里待了多久"，客户端据此调时间（同页）⇒ **深度有一个闭环反馈项**。

### 4.2 Netcode for GameObjects（`NetworkTimeSystem` 官方 API 文档）

构造签名与默认值（原文）：`NetworkTimeSystem(double localBufferSec, double serverBufferSec = 0.05, double hardResetThresholdSec = 0.2, double adjustmentRatio = 0.01)`

| 参数 | 默认 | 文档原话要点 |
|---|---|---|
| `serverBufferSec` | **0.05 s（50 ms）** | "the amount of time the client should buffer incoming messages from the server… A higher value increases latency but makes the game look more smooth in bad networking conditions. This value must be higher than the tick length client side." |
| `hardResetThresholdSec` | **0.2 s（200 ms）** | "used to force a hard catchup of network time"（**时钟层**的硬重置阈值） |
| `adjustmentRatio` | **0.01（1%）** | "the ratio at which the NetworkTimeSystem speeds up or slows down time" |
| `LocalBufferSec` | — | 服务端缓冲客户端消息的量（反方向） |

类摘要：*"local time is based on the server time as last received from the server plus an offset based on the current RTT"* ⇒ **深度显式、速率微调、超阈值硬重置**三者分开。
★ **照实说**：`com.unity.netcode.gameobjects` 的 `BufferedLinearInterpolator.cs` **源码没读到**（jsDelivr 对 `.cs` 返回 `application/octet-stream` 被工具拒收；`raw.githubusercontent.com` 在本机不可达，§7）⇒ 该文件里有没有别的常数，**未知**。

## 5. netfox（Godot rollback 插件，**官方文档全文已读**；`.gd` 源码没读到）

- **三个时钟**（`guides/network-time-synchronizer/`）：**Remote**（host 的钟）→ **Reference**（客户端上被"nudge"的钟，"unsuitable to use for gameplay, as it being regularly adjusted"）→ **Simulation**（**保证只前进**，驱动 tick loop）。
- 参考钟同步：定期 ping，得 offset / RTT / **jitter** 三件统计；*"used to **slowly adjust (nudge)** the reference clock … iteratively, to avoid large jumps in time, and to - when possible - **only go forward in time**… When the offset gets too significant … a **panic** occurs and the reference clock is **reset**."* 原句 *"This process is **inspired by the NTPv4**（RFC 5905）"*。
- **速率（stretch）**：*"Whenever the Simulation clock is ahead of the Reference clock, it will slightly **slow down**… When the Reference clock is ahead…, it will run slightly **faster**."* ⇒ ★ 与我们的"死区 + 比例纠偏"同族（**支持**）。
- 相关设置名（官方文档）：`Recalibrate Threshold`（超了就重置参考钟）、`Stall Threshold`、`Sync Interval`、`Sync Samples`、`Sync Adjust Steps`（*"Larger values result in more stable clocks but slower convergence"*）。**文档没有给这些设置的默认数值**。
- `TickInterpolator`（节点页）：*"Interpolates between network ticks to smooth out motion"*，每个 tick loop 后记一次快照并向它插值；有 `teleport()` 走"不插值直落"。★ **文档没说缓冲深度是多少**（既没给 tick 数也没给公式）⇒ **不能说 netfox 有一个自适应抖动缓冲**，只能说它**按 tick 插值 + 时钟被统一到同步时间**。
- tickrate 不一致是**配置错误**（warn / disconnect / adjust / signal），不是靠缓冲吸收。
⇒ 关系：**支持**"速率纠偏是正统做法 + 参考钟要慢调、只前进、超阈值硬重置"；**无关**于"深度怎么算"（netfox 不解决这一层）。

## 6. 两项"仍然取不到"的东西（照实）

### 6.1 Ramjee 1994 的 fast/slow adaptation —— **正文仍取不到**

- 核实方式：**OpenAlex API**（`https://api.openalex.org/works/doi:10.1109/INFCOM.1994.337672`）⇒ `"open_access": {"is_oa": false, "oa_status": "closed", "any_repository_has_fulltext": false}`；**Semantic Scholar API** ⇒ `"isOpenAccess": false, "openAccessPdf": {"status": "CLOSED"}`。⇒ **没有任何免费正文**（上一份只拿到摘要，本次多拿到了摘要全文索引，但**算法步骤依然无来源可引**）。
- ⇒ **纪律**：本文档**不写**它的 fast/slow 公式、不写 talkspurt 首包估计、不写 spike 阈值。要写只能等拿到正文（IEEE 付费墙）。

### 6.2 Source 引擎 `cl_interp` / `sv_client_min_interp_ratio` / `cl_updaterate` 的官方关系 —— **取不到**

- `developer.valvesoftware.com` 实测仍返回 **Anubis 挑战页**（`Making sure you're not a bot!`，Anubis v1.23.1）——连 `?action=raw` 也被拦。
- `wiki.alliedmods.net`：`Latency_compensation` 页 **HTTP 404**（页面不存在）；站内搜索 `cl_interp` **零结果**。⇒ 该 wiki **不覆盖**这组 cvar。
- ⇒ 本节**没有**任何一手关系式可引（上一份引的是中译二手本，本份不重复）。**同族替代**：Unity NGO 的 `serverBufferSec = 0.05` / `hardResetThresholdSec = 0.2` / `adjustmentRatio = 0.01`（§4.2）是**有官方出处的同族参数**。

## 7. 术语：有没有现成说法？（第 5 问）

| 说法 | 出处（一手） | 说明 |
|---|---|---|
| **`histogram_quantile` / `quantile`=0.95 的"最优延迟"** | `underrun_optimizer.h`（头注释）+ `delay_manager.h`（field trial 名 `WebRTC-Audio-NetEqDelayManagerConfig`） | ★ **最贴近我们问题的现成说法**：目标延迟就是"到达延迟分布的分位数"，只是它把目标表述成"**欠载概率 < 1 − q**" |
| **`TargetDelayMs()` / `preferred_buffer_size_ms`** | `api/neteq/neteq.h`（*"preferred_buffer_size_ms: Target buffer size in ms"*、*"Returns the current target delay in ms"*） | 目标延迟是**一等 API** |
| **`jitter_buffer_target_delay_ms` / `jitterBufferTargetDelay`** | 同上头文件（*"Stats below correspond to similarly-named fields in the WebRTC stats spec: https://w3c.github.io/webrtc-stats/…"*） | ★ **标准化术语**；但 **W3C 规范原文本次未读**（只有 WebRTC 头文件的指向） |
| **`InterpolationDelayJitterScale`（×1.25 抖动）** | Unity 官方 API 文档（§4.1） | "抖动乘子"是官方参数名 |
| `dejitter` / `playout buffer level target` | **未找到一手出处** | 本文档**不使用**这两个词 |

## 8. 来源清单（读了什么、没读到什么）

**读了全文（正文/源码原文）**
- libwebrtc（Firefox vendored 快照，经 jsDelivr 取上游副本）：`neteq/underrun_optimizer.h/.cc`、`neteq/histogram.cc`、`neteq/delay_manager.h/.cc`、`neteq/reorder_optimizer.cc`、`neteq/packet_arrival_history.cc`、`neteq/delay_constraints.cc`、`neteq/buffer_level_filter.cc`、`neteq/decision_logic.h/.cc`、`api/neteq/neteq.h`
- Unity 官方 API 文档：`ClientTickRate`（Entities 1.1.0-pre.3）、`NetworkTimeSystem`（GameObjects 2.0.0）；Unity 官方手册 `time-synchronization.html`（Entities 1.1.0-pre.3）
- netfox 官方文档：`guides/network-time/`、`guides/network-time-synchronizer/`、`nodes/tick-interpolator/`、`tutorials/interpolation-caveats/`
- OpenAlex API、Semantic Scholar API（用于核实 Ramjee 的开放获取状态）

**只拿到片段 / 只有元数据**
- Ramjee 1994（IEEE）：**摘要 + 元数据**（两份索引均确认 closed）
- `netfox` 的 `.gd` 源码（`network-time.gd` / `network-time-synchronizer.gd` / `tick-interpolator.gd`）：**未读**（见下）
- `com.unity.netcode.gameobjects` 的 `.cs` 源码：**未读**（见下）

**取不到（逐个原因）**
- `webrtc.googlesource.com` —— 本机 `fetch failed`（换 `chromium.googlesource.com` 同样失败）⇒ 改用 Firefox vendored 副本
- `raw.githubusercontent.com` —— 本机 `fetch failed`（各处一致）；由此 `.gd` / `.cs` 的 raw 全部不可达
- jsDelivr 直取 `.gd` / `.cs` —— **HTTP 200 但 `content-type: application/octet-stream`**，抓取工具拒收（`.cc`/`.h`/`.md`/`.html` 正常）
- `sourcegraph.com/.../-/raw/...`、`cdn.statically.io`、`raw.githack.com`、`api.codetabs.com`、`api.allorigins.win`、`r.jina.ai` —— 依次为 **403 防火墙** / fetch failed / fetch failed / **522** / **522** / fetch failed ⇒ 无可用 CORS/镜像中转
- `github.com/.../blob/...` 源码页 —— 一次 **30 s 超时**，一次返回的 50 KB 全是被截断的导航壳
- `developer.valvesoftware.com`（含 `?action=raw`）—— **Anubis 反爬**
- `wiki.alliedmods.net/Latency_compensation` —— **404**；站内搜 `cl_interp` —— **零结果**
- GDC Vault / IEEE Xplore 正文 —— 上一份已核实为付费墙，本份不重复尝试

---

## 9. 我们能直接照搬的规则（每条挂来源）

1. **深度改用"到达延迟分布的高分位"**（**新**）。把 `_depth_comp()` 从"窗口展布折半"换成：`d_i = o_i − o_min`（ms，**就是 WebRTC 的 `relative_delay_ms`**）入直方图，取 **95 分位**、**桶宽 20 ms**、**100 桶**（上限 2000 ms）、**每 500 ms 只用该区间内的最大值入桶**、每次入桶全体乘 `forget_factor = 0.983`（≈59 次更新 ≈ **29.5 s** 记忆）、无数据时用 **80 ms** 起步；换 tick 即 `20ms = 1.2 tick`、`500 ms = 30 个快照 @60Hz`。
   来源：`underrun_optimizer.h/.cc`、`histogram.cc`、`delay_manager.h/.cc`（**读了全文**）。★ 与我们现有实现的差别：**分位数对尾部敏感、有明确语义（欠载概率 < 5%）**，而"折半"没有来源。
2. **参考系与窗口：保留 `o_min`（已做），把窗口从"8 个包"改成"时间窗"**（**部分已做**）。WebRTC 用 `kPacketHistorySizeMs = 2000` 的**时间**窗取最小到达时刻；我们的 8 包窗 @60Hz 只有 **133 ms** ⇒ 参考容易被一次突发顶走。来源：`packet_arrival_history.cc`（**读了全文**）。
3. **给深度加上下界、起步值与"丢包项"**（**新**）。`target = max(underrun 项, reorder 项)`，reorder 项最小化 `delay + 100 * ms_per_loss_percent * loss_probability`、`ms_per_loss_percent = 20`（**丢包概率每 1% 值 20 ms**）；整体夹到 `[min, max]` 且不超过 `3/4 × 缓冲容量`（WebRTC 默认 ⇒ 3000 ms）。我们的现状是"只有下限 0、上限 4 tick（66.7 ms）、无丢包项"。来源：`reorder_optimizer.cc`、`delay_constraints.cc`、`delay_manager.cc`（**读了全文**）。
4. **速率纠偏加阈值与冷却，上限保持 ±10%**（**±10% 已做；阈值/冷却是新的**）。WebRTC：两次时标操作之间等 `kMinTimescaleInterval = 5`（注释：*"about 100 ms/s"* ≈ ±10%），且只在 `playout_delay` 越过 `[target, target + maxdelay + 20ms]` 时才加速/减速（`×4` 以上才狠追）；Unity 把速率夹在 `[0.85, 1.1]`、每帧最多纠 **10%** 误差、插值延迟每帧变化 ≤ **10%** 帧 deltaTicks、偏差超 **200 ms** 硬重置（NGO `hardResetThresholdSec = 0.2`）。
   来源：`decision_logic.h/.cc`（**读了全文**）、Unity `ClientTickRate` 与 `NetworkTimeSystem` 官方 API 文档（**读了全文**）。

★ **一句话**：**深度该由"到达延迟的高分位"定，速率该由"有上限、有阈值、有冷却的微调"定**；我们现在的参考系（`o_min`）和速率上限（±10%）**已经对**，缺的是**深度的分位数规则**与**上下界/丢包项**。


---

## 9. 实测落地结果（2026-10-09，本仓；**照实记：原样照搬会更差**）

按 §规则 1 + 2 落地成真代码后，用 `replica_smoothness_probe`（±0/±8/±16ms 抖动夹具）实测：

| 配置 | ±0 滞后 | ±8 滞后 | ±16 滞后 | ±8 单帧最大 | 闸 |
|---|---|---|---|---|---|
| 旧追赶（基线） | 22.6 | 29.7 | 37.2 | 6.578 | ★ ±16 那档 **8.242 已超 8.0，但该档未被判** |
| 展布折半 k=0.5（现行提交） | 25.0 | 28.0 | 46.0 | 6.008 | ALL-OK |
| 展布折半 k=1.5（名义 4） | **20.0** | **27.5** | 50.4 | 5.500 | ALL-OK |
| **95 分位（窗 2000ms，规则原样）** | 24.1 | 33.5 | **55.0** | 6.500 | ALL-OK |
| 95 分位（窗 300ms、上限 2 tick —— **偏离来源**） | 24.1 | 32.0 | 45.3 | 7.520 | ALL-OK |

★ **为什么原样照搬会更差（这是本次最有用的一条）**：我们的观测 `o` 是**帧量化**的（16.667ms 粒度、
快照只有 60Hz），而 WebRTC 那边有高精度到达时间戳与它自己的包率。于是 2000ms 窗口里的 `o_min` 是
**极端最小值** ⇒ `d = o − o_min` 被整体抬高 ⇒ 95 分位**每次都顶到上限** ⇒ 有效深度 = playout + 6 tick
⇒ ±16ms 滞后 55px（比展布折半还差 9px）。⇒ **规则可以借形，数值不能照抄。**

★ **前沿（本次结论）**：`滞后 ≥ playout + 必须吸收的抖动`。上表里**没有任何 playout 配置同时赢过旧追赶**：
最好的（k=1.5）在 ±0/±8 赢、在 ±16 输 13px；而且旧追赶在 ±16 的**最差帧步长 8.242 已经越线**
（那一档没被判，见下）。⇒ 要两边都赢，只能**减小"必须吸收的抖动"本身**（主动调速率 / time dilation），
不是继续调深度。
★ **顺带发现的守卫缺口**：`replica_smoothness_probe` 的 `ASSERT_CASE := 1` 只把单帧最大位移那条闸
压在 **±8ms** 档 ⇒ **±16 那档无论多糟都不会红**。已单独登记。


---

## 10. 规则 4（速率阈值/冷却/硬重置）的实测裁定：**两半都不采纳**（2026-10-09）

按 WebRTC `kMinTimescaleInterval = 5` 实现"速率每 5 帧才更新一次、中间保持"后实测：

| 口径 | 改前 | 改后 |
|---|---|---|
| 探针 ±0 / ±8 / ±16 滞后 | 25.0 / 28.0 / 46.0 px | 25.0 / **27.5** / **46.5** px |
| 探针 **±8 单帧最大位移** | **6.008 px** | **7.500 px** ← 闸是 8.0 ⇒ **余量变窄** |
| 仪器（名义 4，±16）p95 / max / 冻结率 | 6.67 / 11.45 tick / 22.3% | **7.00 / 12.00 tick / 23.0%** |
| 仪器（名义 4，±8）p95 / max | 4.55 / 6.10 tick | 4.60 / 6.50 tick |

⇒ **收益为零、代价是一致变差**（尤其把单帧最大位移推向闸线）⇒ **不采纳、已回退**。
**为什么在本仓不成立**：WebRTC 的包率低得多，而我们是 **60Hz**；且我们的**死区**已经提供了
"只在需要时才动速率"的性质，再加"保持"只会让纠偏量**陈旧**最多 5 帧。

**硬重置（Unity NGO `hardResetThresholdSec = 0.2` ≈ 12 tick）**：仪器实测 `err_max ≈ 8 tick`
（名义 4，±16ms）⇒ 阈值**摸不到**。原因是我们的参考随**本地时间**一起走 —— 停流时 `render_tick`
和参考**一起**停/走，误差不增长（只有参考自身跳变才会）。⇒ 按本仓纪律（真机不可达的防御分支
不写守卫）**不实现**，只留这条判据：**若哪天 `err` 真的越过 12 tick，先查"参考为什么会跳"**。
