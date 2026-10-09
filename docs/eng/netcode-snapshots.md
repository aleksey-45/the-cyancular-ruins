# 联机快照：现状、实测、与主流做法的对照

> **这份文档是什么**:把「联机模式怎么处理快照」这件事**读码 + 实测 + 对照业界**查清后落纸,供动手改之前先看一遍。
> **怎么用**:要改快照/输入/回滚之前读 §1(现状)、§4(发现与处置)、§5(剩余取舍);要拿数字说话看 §2。
> **真相源排序**(与 [`CLAUDE.md`](../../CLAUDE.md) 同):**源码 > 探针实测 > 本文档 > 其它文档**。
> 本文档里的行号**只在写下的那一天成立**;引用前先 `grep` 复核。
>
> ★ **配套**:债单 [`registered-debt.md`](registered-debt.md) **§六.28**(快照编码)与 **§六.29**(输入队列)
> 是这两条债的**登记行**;**两条都已在 2026-10-09 落地**(见 §5),登记行因此收敛为指向本文档的入口。
>
> ★★ **2026-10-09 状态**:§4.1(编码胖)与 §4.2(输入积压)**都已修**,判据与实测见 §2.4 / §5。
> **没做**的只剩 §5.3(渲染插值,会改延迟手感 ⇒ 要仓主拍板)与 §5.2 里那条**量化**(有它的前置条件)。

---

## 1. 现状（逐条带位置）

### 1.1 频率：**60Hz**

`server/match/match_state.gd` 的 `SNAPSHOT_INTERVAL := 1.0 / 60.0`，由 `server/match/match_host.gd` 的
`_snapshot_accum >= SNAPSHOT_INTERVAL` 触发。★ **文档原先写 30Hz（8 处）**，2026-10-08 已按源码订正
（见 §7）；旁证：soak 实测的 `57.5 KB/s ÷ 0.96 KB = 60Hz`，**实测本身就证明是 60Hz**。

### 1.2 世界包：**一次广播**，含全部玩家 **13 个字段**

[`server/match/match_snapshot.gd`](../../server/match/match_snapshot.gd) `_broadcast_snapshot()`：

```gdscript
var world := {"tick": _snap_tick, "players": {}}
for role in players:
    world["players"][str(role)] = {
        "pos", "vel", "facing", "pose", "type_id", "hp", "waterproof", "downed",
        "aim", "previewing", "haste", "rewind", "trail"   # 共 13 个
    }
if NetBus.all_peers_sendable():
    NetBus.rpc("snapshot_world", SnapshotCodec.encode_world(world))
```

★ **`Dictionary` 只是"内存里的形状"，线上不是它**（2026-10-09 起）：`SnapshotCodec`
（[`core/net/snapshot_codec.gd`](../../core/net/snapshot_codec.gd)）把手打包成 `PackedByteArray` 再发，
解码在 [`net_bus.gd`](../../core/net/net_bus.gd) 的 RPC 入口做 ⇒ **三个游戏场景与全部钩子一行没动**，
它们收到的仍是同形状的 `Dictionary`。量到的收益见 §2。
★ **世界包里也含自己那份**，而客户端**刻意不消费**它（权威态走本人包，见 §1.4）。
★ `trail`（回溯轨迹点，每 3 帧一个）是**数组**，每帧随包发。
★ `previewing` 服务端**带**、客户端**刻意不消费**（用户 2026-09-11 裁定：预瞄线只有本人可见）。

### 1.3 本人包：**逐 peer、每帧每人一份**，`c2` = 权威整态

同文件后半段：

```gdscript
for role in peer_by_role:
    if not NetBus.is_peer_live(peer_by_role[role]): continue
    var c2 := p.capture_state() if p.has_method("capture_state") else {}
    # "q" = 服务器侧该 role **已到达但未消费**的输入包数（2026-10-09 加,判据用,见 §6）
    NetBus.rpc_id(peer_by_role[role], "snapshot_own",
            SnapshotCodec.encode_own({"ack_seq": _ack_seq.get(role, 0), "q": q.size(), "c2": c2}))
```

[`scenes/player/player.gd`](../../scenes/player/player.gd) 的 `capture_state()` = **25 个标量 + 武器块 8 个
（仅手持非空时）+ 整个背包表**（`pos/vel/facing/state/slock/coyote/jbuf/jcut/squat/charge/ct/lmv_d/lmv_t/wp/wp_t/wp_s/wp_d/clatch/swim/hp/ifr/down/knock/wslot/winst` + 武器 + 背包）。
它是 **C2 回滚的锚点**（客户端拿它恢复权威态后重放未确认输入）。

★ **线格式只去开销、不动数值**：`SnapshotCodec` 用 float32 载荷，而 Godot 非 double 构建里
`encode_variant` **本来就把 FLOAT 收成 32 位、`Vector2` 收成 2×float32**（实测 `float(1.5)` = 8 B、
`Vector2` = 12 B）⇒ 与改动前的线上字节**逐位相同**，不是"差不多"。

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

## 2. 实测（三处：探针 / 真客户端 soak / 服务器自报）

### 2.1 探针：`tests/probe/snapshot_size_probe.tscn`（量**载荷**字节，2026-10-09 重写）

探针现在**同时量两种线格式**，并且用**真的装了枪**的玩家（`capture_state()` 的武器块只有手持非空时才存在；
不装枪时量到的本人包会少 14 B、且那 8 个字段的往返保真一条都验不到）：

```
[size] 世界包条目(13 字段)  旧(dict) = 368 B  →  新(手打包) = 51 B
[size]   ↳ 不在回溯时(空 trail)                        新 = 35 B
[size] 本人包(ack + c2 整态)  旧(dict) = 884 B  →  新(手打包) = 102 B
[size] c2 字段数 = 34, 世界字段数 = 13          ← 34 = 25 标量 + 8 武器 + inv
[size]  N |        旧(dict):单帧  单端下行  服务器上行 |        新(codec):单帧  单端下行  服务器上行
[size]   2 |    1.58KB   94.92KB   146.72KB |    0.21KB   12.36KB    18.34KB
[size]   8 |    3.74KB  224.30KB   586.88KB |    0.50KB   30.29KB    72.13KB
```

- **世界包条目 368 → 51 B（−86%）**；不在回溯时 35 B。省下来的不是数值，是**键名字符串 + 每个变体的
  4 字节类型标签**（实测：8 字段的 dict = 196 B、同数据的 `PackedByteArray` = 24 B）。
- **本人包 884 → 102 B（−88%）**。
- **N=8 服务器上行 586.88 → 72.13 KB/s（−88%，≈4.7 Mbps → 0.58 Mbps）**；单端下行 224.30 → 30.29 KB/s。

### 2.2 三个基线（同一件事的三代，别混用）

| 代 | 每人每帧载荷 | N=8 服务器上行 | 出处 |
|---|---|---|---|
| ① 拆包**前**（每个 peer 发全 N 人整态，逐 `rpc_id`） | ≈0.96 KB/人 | **≈3.6 MB/s（≈29 Mbps）** | soak 实测 2026-09-12（[`docs/royale-soak-2026-09-12.md`](../royale-soak-2026-09-12.md) §2.2） |
| ② 拆包**后**（世界包广播 + 本人包定向，但仍 `Dictionary`） | 世界 368 B/人 + 本人 884 B | **≈587 KB/s（≈4.7 Mbps）** | 本探针 2026-10-09 |
| ③ **手打包线格式**（`SnapshotCodec`，2026-10-09） | 世界 51 B/人 + 本人 102 B | **≈72 KB/s（≈0.58 Mbps）** | 本探针 2026-10-09 |

★ **必须说清的两处演化**（否则数字会互相打架）：

1. soak 当时把成因写成"同一份 N 人整态，**对每个 peer 各 `rpc_id` 一次**"；源码后来改成**一次 `NetBus.rpc()`
   广播**（[`match_snapshot.gd`](../../server/match/match_snapshot.gd) 的注释："逐 `rpc_id` 循环会把 O(N²) 加回来"）
   ⇒ **序列化次数不再是 O(N²)**，但**线上字节数仍是 O(N²)**（世界包载荷 ∝ N，而每个 peer 都要收一份）。
   要再压只能靠增量/相关性，不是靠少调几次 `rpc`。
2. [`net_bus.gd`](../../core/net/net_bus.gd) 里"拆包后估算 446 KB/s"这个数**偏乐观**：它用的是**没有武器块、
   只有 10 个渲染字段**的旧口径（`588 B` / `272 B`）。按今天真实的 13 字段 + 武器块量，拆包后是 **587 KB/s**。
   ⇒ 引用那个数之前先读本节。

### 2.3 次生后果：**不可靠分片**（这一条已被 ③ 消掉）

`unreliable` 在 ENet 给的 flag 是 **`UNSEQUENCED | UNRELIABLE_FRAGMENT`**
（引擎源码 `modules/enet/enet_multiplayer_peer.cpp::put_packet`）⇒ **分片各自独立**：
**丢任意一片 = 整帧丢**（不是丢一片只损失一部分）。

```
[size] N=8: 世界包 旧 2.88KB → 3 片 | 新 0.41KB → 1 片
[size]  新世界包仍在 1 片内?N=2..8 → true
```

⇒ ② 时代 N≥5 时世界包 2~3 片、本人包另算；**③ 之后世界包在全部人数档都恒为 1 片**，
"丢一片 = 整帧丢"这条风险对世界包**归零**（本人包本来就只有 102 B）。

### 2.4 输入队列的实测：**顶上去就永远停在那儿**（不是推理）

[`match_host.gd`](../../server/match/match_host.gd) 的 `--netstat-trace` 注释里记着当初的实测结论：

> `--netstat-trace`：逐帧打（只在前 600 tick ≈ 10 秒）……**实测队列在开局 1 秒内从 0 跳到 8 然后就永远
> 停在那儿（ρ=1，没有回复力）**，那一下只能逐帧看。

⇒ §4.2 那条"没有回复力"**有实测背书**（2026-10-09 之前就量到了，只是没被当成要修的账）。
`snapshot_own` 现在**带 `q`（服务器待消费队列深度）**，客户端侧因此可以把"在路上"与"堆在服务器"分开，
见 §6。

---

## 3. 与主流的对照

| 维度 | 主流 | 本仓 | 判定 |
|---|---|---|---|
| 状态发送频率 | **10~30Hz + 客户端插值缓冲**（[Gaffer](https://www.gafferongames.com/post/snapshot_interpolation/)：缓冲 ≈ **3× 发送间隔**；Valve 默认 20 更新/s、插值 100ms） | **60Hz**，无缓冲 | **偏胖**：60Hz 只是"不靠插值、用高频掩盖抖动" |
| 编码 | **绑定 + 量化 + 位打包**（[Gaffer](https://www.gafferongames.com/post/snapshot_compression/)：位置 96→50 bit、四元数 128→29 bit） | ✅ **2026-10-09 已去开销**：短 schema 表 + `PackedByteArray`（世界 368→51 B/人、本人 884→102 B/包） | 字节开销**已消**；**量化那半还没做**（§5.2 有它的前置条件） |
| 增量 | **对"对方已 ack 的基线"做增量**（"未变 = 1 bit"），配 ack 驱动基线 | 每帧**全字段绝对值**；ack 只用于输入回滚 | **没做**（要双向 ack 系统；Gaffer 明说这一步"复杂"） |
| 渲染插值 | **位置历史 + playout 延迟**，前后夹逼查找；丢包则**保持/插值** | **朝最新目标点指数追赶** | ★ Valve 原文点过这种方案**在包间隔不固定时更差** |
| 客户端时钟 | 跟服务器时钟跑（"过去多少"是确定的） | 各自跑；世界包带 `tick`，本人包只有 `ack_seq` | 缺一环 |
| 输入积压 | **不许留着**：抖动缓冲**有界**、超了**丢最旧**、并让它能**泄掉** | ✅ **2026-10-09 已补回复力**：上限跟着**实测抖动包络**走、每 tick 衰减 1（原为写死 8 ⇒ 实测顶上去就不回落，见 §2.4/§4.2） | 机制**已对齐**；`QUEUE_CAP_MIN/MAX` 的取值仍待真对局读数校准 |

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
★★ **2026-10-09 已做**：把编码开销这一半消掉（**−88%**，`N=8` 服务器上行 587→72 KB/s，见 §2.1/§5.1）。
**没做**的是同一族的另外两半：**量化**与**增量** —— 前者有"两端一起量化"的前置条件，后者要双向 ack。

### 4.2 ★ 输入队列：**"每 tick 恰好消费一个"是没有回复力的**（**2026-10-09 已修**，见 §5.2）

| 端 | 行为 |
|---|---|
| 生产 | [`pvp_match_client.gd`](../../scenes/pvp_match_client.gd)：**每个物理 tick 无条件发一个**（`_input_seq += 1` → `rpc_id(1, "send_input", pkt)`），**无节流、无"未确认上限"** |
| 消费 | [`server/match/match_host.gd`](../../server/match/match_host.gd)：**每 tick 恰好 `pop_front()` 一个**（注释写明是为"C2 1:1 同序"） |

- 客户端与服务器是**两个独立时钟**（相位不对齐、负载不同）⇒"某个服务器 tick 到了 2 个包"必然经常发生，
  而消费端**永远不会补消费 2 个** ⇒ 队列长度是**没有回复力的有界随机游走**：`+1` 之后没有任何机制把它拉回 0。
- ⇒ 积压**长期停在几 tick 上**（写死的上限 `MAX_PENDING_INPUT = 8` 只是把上界定在 **≈133ms**、**没有消除它**；
  2026-10-09 改成"跟着实测抖动包络走 + 逐 tick 衰减"，见 §5.2）。
- ⇒ `ack_seq` 长期落后 `_input_seq` ⇒ **客户端每帧重放窗口永久变长** ⇒ **输入延迟加上去不恢复** + 重放 CPU 上升。
- ★ Valve 那篇里客户端"反复重放未确认命令"的窗口由 **RTT** 决定；我们是在 RTT 之上**再叠一层积压**。
- ★★ **诚实标注**：这条**不是纯推理** —— `--netstat-trace` 的注释里记着实测（**开局 1 秒内 0→8，此后不回落到 0**，
  见 §2.4）。**修法之后的效果还没有真对局读数**（要读 `q` / 累计丢弃 / ack 落后量；数据源已就位，见 §6）。

### 4.3 渲染侧：朝最新目标追赶 ⇒ 丢包被转成**速度误差**

指数追赶是一阶低通：恒速时永久滞后 `v/INTERP_RATE`；目标跳变时把"迟到/丢包"变成一帧内的速度尖峰。
Valve 明确写过这种方案不如**位置历史插值**。★ 好的一面：**幽灵体跟原始权威值**，所以预测面没有被污染。

---

## 5. 修法（分档 + 取舍）

### 5.1 编码：**已去开销（2026-10-09）**，量化/增量**留给下一轮**

**已做**（`core/net/snapshot_codec.gd` + 两处发送点 + `net_bus` 解码口）：

| 动作 | 结果 | 判据 |
|---|---|---|
| 世界包与本人包改成**一张 schema 表驱动的 `PackedByteArray`** | 368→**51** B/人、884→**102** B/包 | `snapshot_size_probe` 的**真实产出往返逐键一致** + `schema 与 capture_state() 逐键对齐` |
| 首字节**版本号** + 种类字节 | 两端版本不一致时**解码返回空、调用方不 emit**（`net_bus` 只报一次） | 拿坏 buffer 解一次即空（`ALL-OK` 里含该路径） |
| 世界包从此**恒 1 片**（N≤8） | "丢一片 = 整帧丢"这条风险对世界包**归零** | 探针 MTU 折算 |
| `snapshot_own` 加 `q`（队列深度） | §6 的判据有了数据源 | 本人包往返含 `q` |

★ **为什么本版刻意不量化**（这是下一轮的前置条件，不是遗漏）：Gaffer《State Synchronization》里
"**两端一起量化**"那一段说的是：状态同步下只压发送侧会引入**永久分歧**。本仓的 `c2` 是 **C2 回滚的锚点**，
客户端会 `restore_state()` 后逐帧重放并与自己的预测态对账 ⇒ 只压上行 = **每次都对不上**。
所以量化的正确形态是"**先让客户端也用同一套量化**"（Gaffer 的做法：每步前把双方整态都量化一遍），
那是一处**会碰回滚面**的改动（档 3），要按档 3 走。

| # | 还没做 | 依据 | 风险 |
|---|---|---|---|
| 1 | **量化**（位置/速度/瞄准按位打包；世界包可粗一些，`c2` 必须与客户端同口径） | 现在是 float32：位置 8 B、速度 8 B、瞄准 8 B | **中~高**：必须"两端一起量化"（见上） |
| 2 | **变更位**：`previewing/waterproof/haste/rewind/type_id/hp` 变化极慢；`trail` 改事件或降频 | "未变 = 1 bit" | 低~中 |
| 3 | **增量（对已 ack 的基线）** | [Gaffer](https://www.gafferongames.com/post/snapshot_compression/) 说这是唯一还能再拿一个数量级的那一刀，但需要**双向 ack 系统**，且他自己评价"复杂度显著" | 高（本仓现在没有双向 ack） |
| 4 | **世界包不发自己那份** | 客户端**明确不消费** | 低（省 1/N）—— 但会打破"一次广播"，要权衡 |

### 5.2 输入积压：**已补回复力（2026-10-09）**

**已做**（`PacketInputSource.adapted_cap` / `push_pending` + `MatchHost._on_input`）：

| 动作 | 说明 |
|---|---|
| 上限 `cap = clamp(peak + 1, 2, 8)`，`peak` = 最近"一 tick 到过几包"的**原始**深度 | 缓冲跟着**实测抖动包络**走 |
| `peak` 每 tick 衰减 1 | ★ **这就是那个缺失的回复力**：网络一安静，上限自己缩回去，把堆着的陈旧包**释放**掉 |
| 丢的永远是**最旧**那包，`pressed/released/winst` 边沿**并入队首** | 玩家的按键/换枪不因为丢包而丢 |
| `push_pending` 返回**丢之前**的原始深度 | 包络靠它学习（返回丢后的深度 ⇒ 上限只降不升） |
| `reset_input_queue(role)` | 队列与包络**一起清**（掉线/重连重开纪元时） |
| `snapshot_own` 带 `q`；`--netstat` 打「队列/上限/累计丢弃」 | 现象**可观测**了 |

★★ **一件必须照实说的事**：这套机制**换的是另一种代价**，不是免费的。每丢一包 = 服务器少模拟一 tick 的
输入 ⇒ 客户端**靠 C2 回滚纠正一次**（单 tick 量级、有界）。原来的方案是"**零纠正、但永久 133ms 输入延迟**"；
现在换成"**低延迟 + 偶发单 tick 小纠正**"—— 这是主流（回滚网码）的选择，但**手感结论必须真对局读**，
而本仓今天没有"丢包/抖动注入"路径（见 §8）。

**还没做**：`QUEUE_CAP_MIN/MAX` 的取值是**按 60Hz 与单帧突刺量级**定的，不是按真对局读数定的。
要校准就得在真链路里读 `q` / 累计丢弃 / ack 落后量（数据源已就位，见 §6）。

### 5.3 渲染插值（§4.3，**未做 —— 会改延迟手感 ⇒ 要仓主拍板**）

**位置历史 + 固定 playout 延迟**（Valve：100ms + 前后夹逼查找；Gaffer：缓冲 = 3× 发送间隔）⇒
丢包被缓冲吸收，**延迟是选出来的常量,不是累加出来的**；幽灵体继续跟原始权威值（保持预测面零回归）。
★ 顺带补 **客户端时钟跟服务器**（更新里带服务器时钟/tick）——没有它，"渲染在多久之前"是不可控的。
★ 这条**没动**：它是**手感决策**（多 100ms 观感延迟换平滑），不是纯技术债，且今天**没有取图探针**可做前后对比（§8.5）。

---

## 6. 判据（2026-10-09：数据源已就位）

★ 2026-10-08 时"没有一条判据能回答积压了几 tick"；现在**数据源三处齐了**：

| 数据源 | 在哪 | 读数 |
|---|---|---|
| `snapshot_own.q` | 本人包字段（[`match_snapshot.gd`](../../server/match/match_snapshot.gd)） | 服务器侧该 role **已到达未消费**的包数 |
| 客户端 `_input_seq - _ack_seq` | [`pvp_match_client.gd`](../../scenes/pvp_match_client.gd) `-- --netstat` | **未确认数**（= 在途 + 在队，含 RTT 那一层） |
| 服务端 `--netstat` / `--netstat-trace` | [`match_host.gd`](../../server/match/match_host.gd) | 队列长度 · **抖动上限** · **累计丢弃**（逐帧或每秒） |

**要读出的形状**（动手校准前先读这个）：

- **修好后的预期**：队列长期贴近 `QUEUE_CAP_MIN`，**抖动上限在衰减**，累计丢弃**只在突发后小幅跳一次**；
- **坏形状**：上限一路顶到 8 不回、或累计丢弃**几乎每 tick 都涨**（那说明 `QUEUE_CAP_MIN` 定得比真实抖动还低 ⇒ 要上调）。

★ 判据照样遵守本仓纪律：**grep 判词文本**、**计数闸**、能回答"去掉什么它才会红"。

---

## 7. 顺手订正的文档漂移

| 位置 | 原写 | 实际（源码） |
|---|---|---|
| [`docs/pvp-networking.md`](../pvp-networking.md)（**8 处**，订正于 2026-10-08） | 快照 **30Hz** | **60Hz**（`SNAPSHOT_INTERVAL = 1/60`）★ 旁证：soak 的 57.5 KB/s ÷ 0.96 KB = 60Hz |
| 同上（字段表） | **8 个**字段 | **13 个**（多 `aim/previewing/haste/rewind/trail`） |
| 同上（发送方式） | "用 `rpc_id` **逐 peer** 发送" | 世界包 = **一次 `rpc()` 广播**；逐 peer 的是**本人包** |
| 同上 | **完全没提** `snapshot_own` | 逐 peer、每帧每人一份、`c2` = 25 标量 + 武器块 8 + 整背包 |
| [`net_bus.gd`](../../core/net/net_bus.gd) 的"拆包后 ≈446 KB/s"（**2026-10-09**） | 446 KB/s | **587 KB/s** —— 旧口径用的是"无武器块 + 10 个渲染字段"，见 §2.2 |

⇒ 已按源码订正。★ 这也解释了为什么这条债被低估了很久:**读文档的人会以为流比实际轻一半**。

---

## 8. 未验证 / 边界（照实）

1. **修法之后的输入延迟/丢弃率没有真对局读数**（机制在 `-s` 里验了,`q`/累计丢弃的数据源也接上了,
   但**没有跑过丢包/抖动注入**；今天的真链路批是"干净网络"）。
2. **"分流到不同 channel 后有没有新的乱序症状"只在真链路里验过一轮**（`royale_soak` 2/2 `ALL-OK(4/4)`），
   没有做过**丢包/抖动注入**下的对照（今天没有这条路径）。
3. **没有做过带宽计量**（探针量的是**载荷字节**，不含 ENet 分片头 / RPC 方法名 / IP·UDP 头）；
   所以"587→72 KB/s"是**载荷口径**，真实网卡字节数会高一些（每包约 28 B IP·UDP + ENet 头）。
4. **Overwatch 的 time dilation 未读原文**（只有二手摘要与指针）——若真要采用，先读一手来源。
5. **没有取图探针了**（2026-10-09 测试面削减 90% 时删掉了全部非 headless 取图探针）⇒
   线格式/量化这类改动的"看上去对不对"只能靠**人眼对局**；§5.3 那条因此更没有自动判据。
6. **量化（§5.1 表 1）的前提没做**：`c2` 现在仍是 float32 全量；要量化就得**两端一起量化**（见 §5.1 的说明）。
