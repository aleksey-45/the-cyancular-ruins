# 联机快照：现状、实测、与主流做法的对照

> **这份文档是什么**:把「联机模式怎么处理快照」这件事**读码 + 实测 + 对照业界**查清后落纸,供动手改之前先看一遍。
> **怎么用**:要改快照/输入/回滚之前读 §1(现状)、§4(三个发现)、§5(修法取舍);要拿数字说话看 §2。
> **真相源排序**(与 [`CLAUDE.md`](../../CLAUDE.md) 同):**源码 > 探针实测 > 本文档 > 其它文档**。
> 本文档里的行号**只在写下的那一天成立**(2026-10-08);引用前先 `grep` 复核。
>
> ★ **配套**:债单 [`registered-debt.md`](registered-debt.md) **§六.28**(快照编码)与 **§六.29**(输入队列/丢弃)
> 是这两条债的**登记行**,已收敛为指向本文档的入口 —— 免得同一份分析在两处各写一遍。

---

## 1. 现状（逐条带位置）

### 1.1 频率：**60Hz**

`server/match/match_state.gd` 的 `SNAPSHOT_INTERVAL := 1.0 / 60.0`，由 `server/match/match_host.gd` 的
`_snapshot_accum >= SNAPSHOT_INTERVAL` 触发。★ **文档原先写 30Hz（8 处）**，2026-10-08 已按源码订正
（见 §7）；旁证：soak 实测的 `57.5 KB/s ÷ 0.96 KB = 60Hz`，**实测本身就证明是 60Hz**。

### 1.2 世界包：**一次广播**，含全部玩家 **13 个字段**（字符串键的 `Dictionary`）

[`server/match/match_snapshot.gd`](../../server/match/match_snapshot.gd) `_broadcast_snapshot()`：

```gdscript
var world := {"tick": _snap_tick, "players": {}}
for role in players:
    world["players"][str(role)] = {
        "pos", "vel", "facing", "pose", "type_id", "hp", "waterproof", "downed",
        "aim", "previewing", "haste", "rewind", "trail"   # 共 13 个
    }
if NetBus.all_peers_sendable():
    NetBus.rpc("snapshot_world", world)        # ← 一次广播（不是逐 peer 循环）
```

★ **世界包里也含自己那份**，而客户端**刻意不消费**它（权威态走本人包，见 §1.4）。
★ `trail`（回溯轨迹点，每 3 帧一个）是**数组**，每帧随包发。
★ `previewing` 服务端**带**、客户端**刻意不消费**（用户 2026-09-11 裁定：预瞄线只有本人可见）。

### 1.3 本人包：**逐 peer、每帧每人一份**，`c2` = 权威整态

同文件后半段：

```gdscript
for role in peer_by_role:
    if not NetBus.is_peer_live(peer_by_role[role]): continue
    var c2 := p.capture_state() if p.has_method("capture_state") else {}
    NetBus.rpc_id(peer_by_role[role], "snapshot_own", {"ack_seq": _ack_seq.get(role, 0), "c2": c2})
```

[`scenes/player/player.gd`](../../scenes/player/player.gd) 的 `capture_state()` = **26 个字段 + 整个背包表**
（`pos/vel/facing/state/slock/coyote/jbuf/jcut/squat/charge/ct/lmv_d/lmv_t/wp/wp_t/wp_s/wp_d/clatch/swim/hp/ifr/down/knock/wslot/winst` + 背包）。
它是 **C2 回滚的锚点**（客户端拿它恢复权威态后重放未确认输入）。

### 1.4 客户端消费与**丢弃规则**

| 包 | 处理 | 丢弃规则 |
|---|---|---|
| 世界包 | [`scenes/pvp_game.gd`](../../scenes/pvp_game.gd) `_on_snapshot_world` → 只喂**对手副本** | **`tick < _last_snap_tick` ⇒ 丢掉**（"新的赢"） |
| 本人包 | [`scenes/pvp_match_client.gd`](../../scenes/pvp_match_client.gd) `_on_snapshot_own` → `_rollback.on_authoritative(ack, c2)` | ① 跨纪元：**`ack > _input_seq` ⇒ 丢**（重连后旧 seq 空间的残留）；② 同纪元旧包：由 [`core/net/prediction_rollback.gd`](../../core/net/prediction_rollback.gd) 的 **`if ack <= _acked: return`** 挡住 |

★ **两条丢弃规则本身都是对的**：Godot 的 `"unreliable"` = `MultiplayerPeer.TRANSFER_MODE_UNRELIABLE` =
ENet **`UNSEQUENCED`**（**不保证顺序**，见引擎源码 `modules/enet/enet_multiplayer_peer.cpp::put_packet`），
所以"新的赢"是唯一正确的做法；本人包没有 `tick` 也不致命，因为回滚端自己就是**单调**的。
⇒ **"丢弃"不产生延迟累加**（这一条查过、可以放心）。

### 1.5 对手副本：**朝最新目标点指数追赶**（没有插值缓冲）

[`scenes/player/player_replica.gd`](../../scenes/player/player_replica.gd) `_process`：

```gdscript
global_position += (target - current) * (1.0 - exp(-INTERP_RATE * delta))
```

- 目标 = **最新**一次世界快照里的对手位置（锚到本地玩家最近副本空间）。
- **没有位置历史、没有 playout 缓冲**：来一帧就跟一帧。丢包 ⇒ 目标停在旧值，一直追；来新包 ⇒ 目标跳过去。
- 恒速运动时**永久滞后** `v / INTERP_RATE`（代码注释自己算过 ≈25px）。
- ★ **幽灵体例外**：它跟**未经平滑的原始权威位置**（同文件注释），理由是"预测所依据的世界要最小陈旧"——
  这一步是对的：把插值滞后**挡在预测面之外**，所以"画面变平滑"没有换来回滚面的分歧。

---

## 2. 实测（两处独立、互相吻合）

### 2.1 探针：`tests/probe/snapshot_size_probe.tscn`（量**载荷**字节）

```
[size] 单玩家条目(现方案,渲染散字段 + c2 整态)= 872 B
[size] 其中:渲染散字段 = 272 B, c2 权威整态 = 588 B        ← c2 占 67%
[size] c2 字段数 = 26, 渲染字段数 = 11
[size] 世界包瘦身版(短键 + 不带 vel/waterproof 的值)= 176 B/人   ← 现在约 265 B/人
[size]  N | 现方案:单帧载荷  单端下行  服务器上行 | 新方案:本人包  世界包  单端下行
[size]   2 |   1.70KB    102.19KB   204.38KB |  0.59KB  0.53KB   67.27KB
[size]   8 |   6.81KB    408.75KB  3270.00KB |  0.59KB  2.13KB  162.89KB
```

> 探针的列含义以它自己的打印为准;"瘦身版"= 短键 + 去掉 `vel`/`waterproof` 的**世界包**。

### 2.2 真客户端 soak：`docs/royale-soak-2026-09-12.md` §2.2

| 客户端数 | 每端下行 | 每快照载荷 | 折算每人每快照 |
|---|---|---|---|
| 4 | ≈230 KB/s | 3.83 KB | 0.96 KB |
| 6 | ≈345 KB/s | 5.75 KB | 0.96 KB |
| **8** | **≈460 KB/s（3.7 Mbps）** | — | — |

⇒ **每人每快照恒为 ≈0.96 KB**、每端下行 ≈ **57.5 × N KB/s**、**服务器总上行 ∝ N²**（8 人 **≈29 Mbps**）。
★ **一处必须说清的演化**：soak 文档当时把成因写成"同一份 N 人整态，**对每个 peer 各 `rpc_id` 一次**"；
现在源码已经改成**一次 `NetBus.rpc()` 广播**（[`match_snapshot.gd`](../../server/match/match_snapshot.gd) 的注释：
"逐 `rpc_id` 循环会把 O(N²) 加回来"）⇒ **序列化次数不再是 O(N²)**，但**线上字节数仍是 O(N²)**
（世界包载荷 ∝ N，而每个 peer 都要收一份）—— 要压掉它只能靠 §5.1 的**增量 + 相关性**，不是靠少调几次 `rpc`。
★ 与探针的 N=8 数字（408 KB/s / 3270 KB/s）**吻合到 ~12%**（两个独立模型）。

### 2.3 次生后果：**不可靠分片**

探针还量了 MTU 折算（ENet MTU=1400）：

```
 N=2: 现方案 1.71KB → 2 片 | 世界包 0.53KB → 1 片
 N=5:       4.28KB → 4 片 |       1.33KB → 1 片
 N=8:       6.84KB → 6 片 |       2.13KB → 2 片
世界包仍在 1 片内的人数档:原字段表 4/7,瘦身后 6/7
```

- 快照走 `unreliable` ⇒ 引擎给的 flag 是 **`UNSEQUENCED | UNRELIABLE_FRAGMENT`**（同上引擎源码）
  ⇒ **分片各自独立**：**丢任意一片 = 整帧丢**（不是丢一片只损失一部分）。
- ⇒ N≥5 时一帧 3~6 片；按 1% 分片丢包估，6 片整帧存活率 ≈ **94%**。

---

## 3. 与主流的对照

| 维度 | 主流 | 本仓 | 判定 |
|---|---|---|---|
| 状态发送频率 | **10~30Hz + 客户端插值缓冲**（[Gaffer](https://www.gafferongames.com/post/snapshot_interpolation/)：缓冲 ≈ **3× 发送间隔**；Valve 默认 20 更新/s、插值 100ms） | **60Hz**，无缓冲 | **偏胖**：60Hz 只是"不靠插值、用高频掩盖抖动" |
| 编码 | **绑定 + 量化 + 位打包**（[Gaffer](https://www.gafferongames.com/post/snapshot_compression/)：位置 96→50 bit、四元数 128→29 bit） | Godot `Variant/Dictionary`：**字符串键每包重复**、32 位 float、无量化 | **明显浪费** |
| 增量 | **对"对方已 ack 的基线"做增量**（"未变 = 1 bit"），配 ack 驱动基线 | 每帧**全字段绝对值**；ack 只用于输入回滚 | **最大的一刀没做** |
| 渲染插值 | **位置历史 + playout 延迟**，前后夹逼查找；丢包则**保持/插值** | **朝最新目标点指数追赶** | ★ Valve 原文点过这种方案**在包间隔不固定时更差** |
| 客户端时钟 | 跟服务器时钟跑（"过去多少"是确定的） | 各自跑；世界包带 `tick`，本人包只有 `ack_seq` | 缺一环 |
| 输入积压 | **不许留着**：服务器告诉客户端跑几个命令 / 命令缓冲有界 + 丢最旧 + 让客户端**泄掉**积压 | 生产 1/tick、消费 1/tick，**无回复力**（见 §4.2） | **会累加** |

**来源**：
[Bernier/Valve《Latency Compensating Methods…》(2003) 中译](https://www.cnblogs.com/sun-shadow/p/19715823) ·
[Gaffer《Snapshot Interpolation》](https://www.gafferongames.com/post/snapshot_interpolation/) ·
[Gaffer《Snapshot Compression》](https://www.gafferongames.com/post/snapshot_compression/) ·
Overwatch 的 time dilation（**仅取到指针与二手摘要,未读原文正文**）：
[Edgegap 摘要](https://edgegap.com/zh/blog/game-backend-deep-dive-overwatch-2016-netcode-architecture-rollback) ·
[GDC 2025 论文](https://drops.dagstuhl.de/storage/00lipics/lipics-vol361-opodis2025/LIPIcs.OPODIS.2025/LIPIcs.OPODIS.2025.pdf) ·
[Unity Netcode 时间同步](https://docs.unity3d.com/Packages/com.unity.netcode@7.1/manual/time-synchronization.html)。

---

## 4. 三个发现

### 4.1 编码胖：**不是"愚蠢的模式",是"最省事的编码 + 优化没做"**

架构侧**是对的、而且和主流同族**：服务器权威 + **unreliable 状态与 reliable 事件/输入分道** +
本地玩家**预测/回滚对账(C2)** + 乱序丢弃 + canonical 坐标（环面）。
**胖的是编码**：把 60Hz 状态流交给通用 `Variant` 序列化 ⇒ 字符串键每包重复、无量化、无变更位、无增量基线。
Gaffer 对**同类数据**做绑定+量化+增量能把裸 60Hz 全量压到 **~1%**（17.37 Mbit/s → 目标 256 kbit/s）。
★ **仓库自己早就知道**：soak 文档 2026-09-12 就写了"每人每快照恒 0.96 KB、上行 ∝N²、8 人 29 Mbps"
并判为"本层最硬的扩展性瓶颈"；探针连"瘦身版 176 B/人"都算好了。**量了、登记了、没做** —— 这才是这条债的真相。

### 4.2 ★ 输入队列：**"每 tick 恰好消费一个"是没有回复力的**（延迟加上去不恢复）

| 端 | 行为 |
|---|---|
| 生产 | [`pvp_match_client.gd`](../../scenes/pvp_match_client.gd)：**每个物理 tick 无条件发一个**（`_input_seq += 1` → `rpc_id(1, "send_input", pkt)`），**无节流、无"未确认上限"** |
| 消费 | [`server/match/match_host.gd`](../../server/match/match_host.gd)：**每 tick 恰好 `pop_front()` 一个**（注释写明是为"C2 1:1 同序"） |

- 客户端与服务器是**两个独立时钟**（相位不对齐、负载不同）⇒"某个服务器 tick 到了 2 个包"必然经常发生，
  而消费端**永远不会补消费 2 个** ⇒ 队列长度是**没有回复力的有界随机游走**：`+1` 之后没有任何机制把它拉回 0。
- ⇒ 积压**长期停在几 tick 上**（Task 4 的 `MAX_PENDING_INPUT = 8` 只是把上限钉在 **≈133ms**，**没有消除它**）。
- ⇒ `ack_seq` 长期落后 `_input_seq` ⇒ **客户端每帧重放窗口永久变长** ⇒ **输入延迟加上去不恢复** + 重放 CPU 上升。
- ★ Valve 那篇里客户端"反复重放未确认命令"的窗口由 **RTT** 决定；我们是在 RTT 之上**再叠一层积压**。
- ★★ **诚实标注**：这是**从代码推出来的**，而且**今天没有判据能测它**（见 §6）。不要把它当成已实测的数字。

### 4.3 渲染侧：朝最新目标追赶 ⇒ 丢包被转成**速度误差**

指数追赶是一阶低通：恒速时永久滞后 `v/INTERP_RATE`；目标跳变时把"迟到/丢包"变成一帧内的速度尖峰。
Valve 明确写过这种方案不如**位置历史插值**。★ 好的一面：**幽灵体跟原始权威值**，所以预测面没有被污染。

---

## 5. 修法（分档 + 取舍）

### 5.1 编码（档 1~2，**不碰手感**）

| # | 动作 | 依据 | 风险 |
|---|---|---|---|
| 1 | **世界包去键名 + 量化**（短键/`PackedByteArray` + 固定 schema；位置按 1/4 像素量化） | 探针已量 **176 B/人 vs 265 B/人 ⇒ −34%** | 低（不动语义） |
| 2 | **世界包不发自己那份** | 客户端**明确不消费** | 低（省 1/N 的世界包） |
| 3 | **变更位**：`previewing/waterproof/haste/rewind/type_id/hp` 变化极慢；`trail` 改事件或降频 | "未变 = 1 bit" | 低~中 |
| 4 | **`snapshot_own` 降频 60→30Hz + 只发回滚需要的字段** | `c2` 占单玩家条目 **67%**（588/872 B） | **中**：重放窗口变长 ⇒ 必须过孪生/回滚冒烟 |

### 5.2 输入积压（§4.2；三条路，按"是否破坏 1:1 同序"排）

1. **服务端驱动客户端 tick**（Valve/Overwatch 正道：服务器告诉客户端"跑几个命令"，客户端按它步进/发包）
   ⇒ **生产 ≡ 消费**，零漂移，**不破坏 1:1 同序**（C2 的确定性前提保住）。★ 改动最大：输入时钟换主人，**档 3**。
2. **发前限流**（最便宜）：未确认数 ≥ N 就**不发**（丢**生产**端，不丢消费端）⇒ 队列排空、ack 追上。
   代价：那几帧服务器没模拟 ⇒ 回滚要纠正（**有界**橡皮筋），且 `seq` 出现空洞（C2 的"同序"仍在，但"同集合"不再）。
3. **消费端抽干 + 合并边沿**（"输入是状态,不是命令流"）⇒ 延迟不累加，但**放弃 1:1 同序**
   ⇒ 必须连带改回滚语义，且 [`tests/probe/kh_l5_probe.gd`](../../tests/probe/kh_l5_probe.gd) 那条
   "生产侧每 tick 消费一个"的判据会红（要一起改）。

### 5.3 渲染插值（§4.3，**会改延迟手感 ⇒ 要用户拍板**）

**位置历史 + 固定 playout 延迟**（Valve：100ms + 前后夹逼查找；Gaffer：缓冲 = 3× 发送间隔）⇒
丢包被缓冲吸收，**延迟是选出来的常量,不是累加出来的**；幽灵体继续跟原始权威值（保持预测面零回归）。
★ 顺带补 **客户端时钟跟服务器**（更新里带服务器时钟/tick）——没有它，"渲染在多久之前"是不可控的。

---

## 6. 要加的判据（可验）

★ **今天没有一条判据能回答"到底积压了几 tick / 未确认几个"** —— 所以 §4.2 只能是推理。要动它之前先加：

1. **`snapshot_own` 带上服务器 tick**（现在只有 `ack_seq`）⇒ 客户端就能算出"我收到的权威态落后服务器多少 tick"。
2. **探针读数**：逐帧打印「**未确认数**（`_input_seq - _ack_seq`）/ **队列积压 tick 数**」的**时间序列**（或峰值/均值/末值）。
   - **现在的预期形状**：在几 tick 上**长期徘徊**、**不回归 0**（有界随机游走）；
   - **修好后的预期形状**：长期**贴近 0**（或有界且**在衰减**）。
3. ★ 判据照样遵守本仓纪律：**grep 判词文本**、**计数闸**、能回答"去掉什么它才会红"。

---

## 7. 顺手订正的文档漂移（2026-10-08）

| 位置 | 原写 | 实际（源码） |
|---|---|---|
| [`docs/pvp-networking.md`](../pvp-networking.md)（**8 处**） | 快照 **30Hz** | **60Hz**（`SNAPSHOT_INTERVAL = 1/60`）★ 旁证：soak 的 57.5 KB/s ÷ 0.96 KB = 60Hz |
| 同上（字段表） | **8 个**字段 | **13 个**（多 `aim/previewing/haste/rewind/trail`） |
| 同上（发送方式） | "用 `rpc_id` **逐 peer** 发送" | 世界包 = **一次 `rpc()` 广播**；逐 peer 的是**本人包** |
| 同上 | **完全没提** `snapshot_own` | 逐 peer、每帧每人一份、`c2` = 26 字段 + 整背包 |

⇒ 已按源码订正（`docs/pvp-networking.md`）。★ 这也解释了为什么这条债被低估了很久:**读文档的人会以为流比实际轻一半**。

---

## 8. 未验证 / 边界（照实）

1. **积压的实际大小没有实测**（§4.2 是代码推理）⇒ 先加 §6 的判据再谈"多少 ms"。
2. **"分流到不同 channel 后有没有新的乱序症状"只在真链路里验过一轮**（`royale_soak` 2/2 `ALL-OK(4/4)`），
   没有做过**丢包/抖动注入**下的对照（今天没有这条路径）。
3. **没有做过带宽计量**（探针量的是**载荷字节**，不含 ENet 分片头 / RPC 方法名 / IP·UDP 头）。
4. **Overwatch 的 time dilation 未读原文**（只有二手摘要与指针）——若真要采用，先读一手来源。
5. `snapshot_size_probe` 的"新方案"列是**探针自己建模的**，不是已实现的代码。
