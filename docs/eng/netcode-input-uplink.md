# 联机输入上行：现状、实测、与主流做法的对照

> **这份文档是什么**:把「输入包怎么走」这件事**读码 + 实测 + 对照业界**查清后落纸。
> 它接在 [`netcode-snapshots.md`](netcode-snapshots.md) 后面 —— 那份治的是**下行快照**,这份治的是**上行输入**。
> **真相源排序**(与 [`CLAUDE.md`](../../CLAUDE.md) 同):**源码 > 探针实测 > 本文档 > 其它文档**。行号只在写下那天成立。
> **配套计划**:[`docs/superpowers/plans/2026-10-09-input-uplink-codec-and-redundancy.md`](../superpowers/plans/2026-10-09-input-uplink-codec-and-redundancy.md)。

---

## 1. 现状（逐条带位置）

### 1.1 载荷：**7 个字段的 `Dictionary`**（唯一编码端 = `pack_record`）

[`core/net/packet_input_source.gd`](../../core/net/packet_input_source.gd) 的 `pack_record()` 是**发送侧唯一来源**
（收口理由见该函数注释:此前 `pvp_client` 与 `royale_game` 各手抄一份位打包）:

```gdscript
{ "seq": int, "ax": float, "held": int, "pressed": int, "released": int, "winst": int, "aim": Vector2 }
```

### 1.2 频率与通道：**每物理 tick 一包、`reliable`、ENet 道 2**

- 发送点:[`scenes/pvp_match_client.gd`](../../scenes/pvp_match_client.gd) `_physics_process` ——
  `_input_seq += 1` → `NetBus.rpc_id(1, "send_input", pkt)`,**无节流、无未确认上限**。
- 通道:[`core/net/net_bus.gd`](../../core/net/net_bus.gd) `@rpc("any_peer", "call_remote", "reliable", 1)`
  ⇒ 用户通道 1 ⇒ **ENet 道 `SYSCH_MAX(2) + 1 - 1` = 2**,传输模式 **reliable(有序 + 重传)**。
- 选 reliable 的**理由写在注释里**:`pressed/released` 是**边沿**语义,丢了边沿 = 服务器与客户端脱节(抓梯/跳跃/开火)。

### 1.3 消费：服务器每 tick 恰一个 + 自适应抖动上限

- [`server/match/match_host.gd`](../../server/match/match_host.gd) `_physics_process`:每 role **恰 `pop_front()` 一个**
  （1:1 同序是 C2 回滚的前提）。
- 上限 = **实测抖动包络 + 1**、逐 tick 衰减（2026-10-09 改;`PacketInputSource.adapted_cap`）。
- 队列空 ⇒ 沿用上一包 held 输入（`clear_edges()` 不清 held）。

### 1.4 已有的读数（`--netstat`,默认关）

`pvp_match_client` 每 2 秒打一行,含 `_input_seq` / `_last_ack` / `gap`(= 未确认数) / `lag_ms`(= gap×16.67ms) /
`ping`(=`NetBus.ping_ms`,EWMA 平滑的纯网络 RTT)。**`lag_ms − ping` 就是"服务器侧积压"** ——
本文档下面所有"积累"类问题都能用这一个数在真对局里读出来,只是今天没人跑过。

---

## 2. 实测（2026-10-09,`var_to_bytes`,与 RPC 实际打包同一套变体编码）

```
输入包:Dictionary = 164 B | 手打包 = 23 B(省 86%)
每秒每客户端上行:9840 B/s vs 1380 B/s
N=8 服务器下行:76 KB/s vs 10 KB/s
带最近 3 条命令的冗余(手打包)= 69 B/包 ⇒ N=8 服务器下行 32 KB/s
带最近 3 条命令的冗余(仍是 Dictionary)= 492 B/包 ⇒ N=8 服务器下行 230 KB/s
```

★ **对照**:同一时刻的**快照**（下行,已手打包）在 N=8 时是 **72 KB/s**（[`netcode-snapshots.md`](netcode-snapshots.md) §2.1）。
⇒ **服务器为"输入"这一条上行付的账,和它发出去的全部快照一样大（76 vs 72 KB/s）**,而这条从来没被量过。
★ 164 B 里绝大部分是**键名与每个变体的 4 字节类型标签**,不是数值（同一份数据的 Bit 口径只有 ~23 B）。

---

## 3. 与主流的对照

| 维度 | 主流 | 本仓 | 判定 |
|---|---|---|---|
| 命令编码 | 定长/位打包（Source 的 `usercmd_t` 是定长结构） | 7 字段 `Dictionary` | **没打包** |
| 丢包 | **冗余命令** —— [Gaffer《State Synchronization》](https://gafferongames.com/post/state_synchronization/)原文:*"Like deterministic lockstep we send multiple redundant inputs so in the case of packet loss it is very unlikely that an input gets dropped"*;Valve 的 `cl_cmdbackup`（**只有指针,未读正文**）同思路 | 靠 **reliable 重传** | **机制不同,代价大不同** |
| 通道语义 | 输入走**不可靠**（延迟比正确性重要;要正确就冗余） | **可靠有序** ⇒ 队头阻塞 | **见 §4.2** |
| 客户端节奏 | 服务器驱动客户端 tick（"服务器告诉你跑几个命令"） | 客户端各自 60Hz 无条件发 | 未采用（见 [`netcode-snapshots.md`](netcode-snapshots.md) §5.2） |

**来源**:[Gaffer《What Every Programmer Needs To Know About Game Networking》](https://gafferongames.com/post/what_every_programmer_needs_to_know_about_game_networking/)（**读了全文**）·
[Gaffer《State Synchronization》](https://gafferongames.com/post/state_synchronization/)（**读了全文**;冗余输入 + 抖动缓冲两段）·
Valve `cl_cmdbackup` / `usercmd_t`（**只有搜索摘要与该站被 Anubis 挡的指针,未读原句**）。

---

## 4. 三个发现

### 4.1 输入包是"没被打包的第二份 164 B/包"

快照那条债（[`netcode-snapshots.md`](netcode-snapshots.md) §4.1）在**上行**原样存在一份,只是没人量过:
60Hz × 8 人 × 164 B = **服务器下行 76 KB/s**。手打包后 **10 KB/s(−86%)**。

### 4.2 ★ 可靠有序通道 ⇒ **队头阻塞**,与"队列无回复力"是**同族**

ENet 的 reliable 通道是**有序 + 重传**:丢一包 ⇒ 该通道后续包**全部压在缓冲里等重传**,
服务器看到的是"**断流 → 一坨**"。而"一坨"正好喂给 §1.3 那个队列 ⇒ 队列被顶上去 ⇒ **积压**。

⇒ 这就是 [`netcode-snapshots.md`](netcode-snapshots.md) §4.2 那条"缺回复力"的**第二个来源**,而且它是**自造的**:
本仓为了"不丢边沿"选了可靠性,可靠性又制造了突发,突发又制造了积压。
★ 主流解法是**冗余命令**:每个输入包带最近 N 条命令,丢包的洞由**后一包**补上 ——
边沿照样不丢,但**不必**牺牲时延换顺序。
★★ **诚实的量化缺口**:本仓**没有丢包/抖动注入路径**,所以"队头阻塞到底值多少 ms"**今天无法定案**
（§1.4 的 `lag_ms − ping` 是唯一能读出它的数,但没有仪器去制造丢包）。

### 4.3 冗余的代价被 4.1 放大了 ⇒ 顺序有依赖

⚠️ 这一条解释了"为什么不敢加冗余":**Dictionary 口径下** 3 条冗余 = 230 KB/s（不可接受）;
**手打包之后** 3 条冗余 = **32 KB/s**（比今天的 76 KB/s 还小一半）。
⇒ **必须先打包,冗余才划算** —— 两条不是并列的选项,是**有先后的一对**。

---

## 5. 修法（分两步,顺序不可交换）

### 5.1 第一步:输入包手打包（与快照同一套 schema 表模式）

- 载荷从 `Dictionary` 换成 `PackedByteArray`,**与快照共用同一个编解码模块与版本字节**（避免两份协议版本号)。
- **逐位无损**:`ax`/`aim` 保持 float32（`ax` 是连续手感想;`aim` 喂服务器武器朝向 = 玩法量),
  `seq/winst` 32 位、`held/pressed/released` 8 位（位掩码最大 256）。
- 收益:164 → **23 B**;服务器下行 76 → **10 KB/s**。

### 5.2 第二步:冗余命令 + 输入通道降为不可靠（依赖 5.1）

- 每包带**最近 N 条命令**（N = 3:0.05s 的保护;定量见 §2）⇒ 单包 ≤ 69 B。
- `send_input` 从 `reliable` 改 **`unreliable`** ⇒ **队头阻塞消失**（边沿改由冗余保证）。
- ★★ **消费端必须加去重**:同一 `seq` 会重复到达,而"1 seq = 1 服务器 tick"是 C2 的前提 ⇒
  **已应用过的 `seq` 必须整包丢弃,且不消耗这一 tick**。漏了这一步 = 同一条输入被模拟多次 = 静默分歧。

---

## 6. 要加的判据

1. **编码往返**:与快照同款 —— 用**真实** `pack_record()` 的产出过一遍编解码,逐字段一致 + schema 覆盖 + 条数闸。
2. **去重**:同一 `seq` 重复投递 ⇒ **只应用一次**(纯函数级,`-s` 可判);这条是 §5.2 的承重断言。
3. **丢包下的读数**:见 §8 —— 需要先有仪器。

---

## 7. 文档漂移（顺手订正）

| 位置 | 原写 | 实际 |
|---|---|---|
| [`docs/pvp-networking.md`](../pvp-networking.md) | "输入包 reliable:60Hz × **~20B** ≈ 1.2KB/s/玩家" | **164 B**（Dictionary 口径）⇒ 9.8 KB/s/玩家;20 B 是**位口径**,不是线上字节 |

---

## 8. 未验证 / 边界（照实）

1. **队头阻塞的影响量没有实测** —— 没有丢包注入路径;§4.2 是"读码 + ENet 语义"的推论,不是读数。
2. **冗余的收益同样没有实测** —— 同上,修完之后也需要仪器才能证明它有用。
3. **没有客户端时钟同步** ⇒ 输入这条线上"客户端跑在服务器的哪个 tick"不可算（快照那条线也一样）。
4. **输入包没有量化**:`ax`/`aim` 仍是 4 字节浮点。要不要量化属**手感决策**,不在本文范围。
5. §2 的量具是一次性的(`.superpowers/net/measure_input.gd`),**没有常驻探针**钉住这个读数 —— 计划里补。
