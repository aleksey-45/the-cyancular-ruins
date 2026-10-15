# 增量与量化的细节：一手源码调研（Q3 / DarkPlaces / Teeworlds / Source / Gaffer / ENet）

> **互链**：现状与实测 [`netcode-snapshots.md`](netcode-snapshots.md)（§5.4 = 手打包 vs zstd）·
> 16 人预算 [`netcode-at-16-players.md`](netcode-at-16-players.md) ·
> 前三轮不重复的调研 [`netcode-playout-clock-sync-sources.md`](netcode-playout-clock-sync-sources.md)（NTP/RTP）、
> [`netcode-jitter-buffer-practice.md`](netcode-jitter-buffer-practice.md)（NetEq）、
> [`netcode-tick-rates-survey.md`](netcode-tick-rates-survey.md)（各家频率）·
> **本次要落地的计划** [`2026-10-13-stream-merge-metrics-and-delta.md`](../superpowers/plans/2026-10-13-stream-merge-metrics-and-delta.md)。
> **分工**：只做那四份没做的 —— 增量的完整语义、量化的具体位数、量化×命中、增量×不可靠、拥塞控制。
> **纪律**：只引一手（源码/spec/官方文档）；每条标 **读全文** / **只片段**；与我们是「支持/无关/相反」都明说；取不到的在 §7。
> **真相源**：源码 > 探针实测 > 本文档 > 其它。★ 本次是**纯调研**，未改代码、未跑测试。

## 1. 结论（先说，每条挂来源）

1. **Q3 的基线 = 客户端确认过的服务器包序号**：客户端在**每个**包头部写 `clc.serverMessageSequence`（`cl_input.c`
   `CL_WritePacket` 原句 *"write the last message we received, which can be used for delta compression, and is also used to tell
   if we dropped a gamestate"*），服务器 `SV_UserMove` 里 `cl->deltaMessage = cl->messageAcknowledge`（**读全文**）。⇒ **支持**既有判断。
2. ★★ **我们缺这条回路的另一半**：客户端只在**收**时记 `_last_snap_tick`，**从不外发**；而 `ack_seq` 是**服务器已消费的输入序**
   （`match_host.gd:289`）⇒ 计划 T3 说的「ack 管线已有」**把方向搞混了**（§2.6）。
3. **新实体走第三条路 `baseline`**：gamestate 里 `MSG_WriteDeltaEntity(&msg, &nullstate, base, qtrue)` 全量下发一次，之后新实体相对它增量。
   我们**没有** baseline 概念。
4. **消失实体写 NULL**（实体号 + 1 bit）；`lc == 0 && !force` 时**一字节都不发**（原句 *"this will not result in any bytes being emited
   if the entity has not changed at all"*，★ 原文拼写 `emited`）。
5. ★★ **Q3 标量用「末位变化序号 `lc` 一字节」，不是定长掩码**：客户端读 `lc` 后**只读前 `lc` 个字段**、其余从基线**整段拷** ⇒
   计划的 `DELTA_MASK_BYTES` **更胖**；对照我们实测变更率（世界 2.0/13、本人 4.1/34），`lc` 型**明显更省**（§2.3）。
6. **基线过期退回全量 = 服务器丢 + 客户端主动改发 `clc_moveNoDelta` 两半**：服务器窗口 `PACKET_BACKUP - 3 = 29` 包
   （`qcommon.h`：`#define PACKET_BACKUP 32 // number of old messages that must be kept on client and server for delta comrpession`），
   且**实体环本身也可能滚出去**（`Delta request from out of date entities`）；客户端更狠 —— 解不了就 `newSnap.valid = qfalse`、
   **整帧不落地**，下包改 `clc_moveNoDelta`（读全文）。见 §2.4/§4.1。
7. **实体必须排序 = 两端都是「双指针归并走」**：`newnum < / == / > oldnum` 三分支决定「新实体 / 增量 / 消失」，顺序一乱**该删的不会删**。
   Q3 自己的注释点名：*"there may be out of order entities … which will need to be resorted for the delta compression to work correctly"*（§2.5）。
8. **量化**：Q3 **没有 `COORD_INT`**。坐标走 float 字段分支：可整数值落在 `[-4096,4095]` ⇒ **13 bit**（`FLOAT_INT_BITS 13`、bias `1<<12`），
   否则 **32 bit** 原样 float（⇒ 整数值**无损**）。角度：`ANGLE2SHORT` = **16 bit**（**0.0055°**）、`MSG_WriteAngle` = **8 bit**（**1.40625°**）。DP/Teeworlds/Source 见 §3。
9. ★★ **「两端必须同量化」有源码级依据，比 Gaffer 更具体**：Teeworlds 有具名原语
   `void CCharacterCore::Quantize() { CNetObj_CharacterCore Core; Write(&Core); Read(&Core); }`（§3.3）—— 把"每步前把整态按线格式往返一遍"做成了函数。
10. ★★ **量化误差 vs 判定半径：本轮没找到任何一手来源**（§4.4 列了口径与失败原因）⇒ **这一格留空**，只能自己算几何，**不许**写成某来源的主张。
11. **PVS 在小局值不值：没有一手来源讨论"≤16 人时相关性剔除的收益"** ⇒ 我们的结论**既未被检验也未被反驳**，只能挂本仓实测。
    Q3 的 PVS 是**渲染可见性的前置**（`frame->areabits` 是给渲染器的），发包白名单只是副作用（§5）。
12. ★★ **我们不是"没有拥塞控制"——ENet 自带一层，且它丢的正是我们的不可靠快照**：`enet_peer_throttle()` 按**可靠包**的 RTT
    波动调 `packetThrottle` 概率并据此丢不可靠包 ⇒ `netcode-snapshots.md` §3 那格「拥塞控制：没做」应**订正为「应用层没做，传输层有一层」**（§6.2）。
13. **Gaffer《Reliability and Congestion Avoidance over UDP》（读全文）也只给「简易二值」**：RTT 超阈值（他举例 250ms）立刻降到 10pps，
    好条件持续 `t` 秒才回升，`t` **翻倍/减半**（夹 1~60s）。不做会怎样的**原句**：*"we risk flooding the connection and inducing severe
    latency (2 seconds plus!)"*（§6.1）。
14. **u32 回绕 60Hz = 2.27 年**（Gaffer 明算 30pps 是 *"over four and a half years"*）；★ **但先回绕的是 ENet 自己的 16 bit**
    （`reliableSequenceNumber` 等全是 `enet_uint16`）⇒ 60Hz 下 **18 分 12 秒**一轮（§7.1）。
15. **重连复位基线四个引擎四个做法，都不是"客户端自己重置"**：Q3 `client->deltaMessage = -1`（服务器主动）· DP
    `EntityFrame4_ResetDatabase`/`EntityFrame_ClearDatabase` · Teeworlds 靠显式 ack 全量发新增项。★ Q3 另有一条我们没想到：
    **丢包后要把"空档期"的 snapshot 标成 `valid = qfalse`**，否则它们会被当成合法基线（§7.2）。

## 2. Quake 3：增量的完整语义（**源码读全文**，`id-Software/Quake-III-Arena@master` 经 jsDelivr）

文件：`server/sv_snapshot.c`·`qcommon/msg.c`·`client/cl_parse.c`·`server/sv_client.c`·`qcommon/qcommon.h`·`game/q_shared.h`·`client/cl_input.c`。

**2.1 `svc_snapshot` 线格式**（`sv_snapshot.c` 文件头注释逐行照抄）：`4 sequence number` / `<reliable commands>` / `1 svc_snapshot` /
`4 last client reliable command` / `4 serverTime` / **`1 lastframe for delta compression`** / `1 snapFlags` / `1 areaBytes` / `<areabytes>` /
`<playerstate>` / `<packetentities>`。★ `lastframe` 只 **1 字节**；客户端还原绝对序号 `newSnap.deltaNum = newSnap.messageNum - deltaNum`。

**2.2 基线从哪来**：客户端 `CL_WritePacket` 写 `clc.serverMessageSequence`（注释见 §1.1）；服务器 `SV_ExecuteClientMessage`
`cl->messageAcknowledge = MSG_ReadLong(msg);` → `SV_UserMove` 里 `if (delta) { cl->deltaMessage = cl->messageAcknowledge; } else {
cl->deltaMessage = -1; }`；同一 ack 还喂 ping（`cl->frames[cl->messageAcknowledge & PACKET_MASK].messageAcked = svs.time;`）⇒ **1 次 ack 三用**。

**2.3 变化怎么组织：`lc`（末位变化序号）**
- **实体** `MSG_WriteDeltaEntity`：先扫一遍求 `lc = i+1`（最后一个不同字段下标+1）。`lc==0 && !force` ⇒ **`return`，0 bit**；
  `lc==0 && force` ⇒ `number`+`0`(未删)+`0`(无 delta) = **2 bit**；否则 `number`+`0`+`1`+**`MSG_WriteByte(msg, lc)`**，再对 `[0, lc)` 每字段 1 bit「变了没有」。
- **玩家状态** `MSG_WriteDeltaPlayerstate`：同样 `lc` + 逐字段 1 bit；**数组另算** —— 先 1 bit「四组有没有任何变化」，没变 `return`，
  变了每组 1 bit + `MSG_WriteShort(bits)` 掩码 + 逐项值。⇒ ★ **同一文件里两套掩码策略并存**：标量用 `lc`（省），16 项数组用位掩码（值）。
- `force` 的用处：**新实体与删除必须 `qtrue`**（否则 `lc==0` 什么都不发，客户端以为没变）。

**2.4 新实体 / 消失 / 过期**

| 情形 | 服务端 `SV_EmitPacketEntities` | 客户端 `CL_ParsePacketEntities`+`CL_DeltaEntity` |
|---|---|---|
| 相同 | `MSG_WriteDeltaEntity(msg, oldent, newent, qfalse)`（可能 0 bit） | `oldnum == newnum` ⇒ 读 delta（可能只 2 bit） |
| **新实体** | `newnum < oldnum` ⇒ 相对 **`sv.svEntities[newnum].baseline`**，`qtrue` | `oldnum > newnum` ⇒ 相对 `cl.entityBaselines[newnum]` |
| **消失** | `newnum > oldnum` ⇒ `MSG_WriteDeltaEntity(msg, oldent, NULL, qtrue)` | 读到 remove bit ⇒ `Com_Memset(to,0,…); to->number = MAX_GENTITIES-1`，**不入 frame** |
| 结束 | `MSG_WriteBits(msg, (MAX_GENTITIES-1), GENTITYNUM_BITS)` | 遇 `MAX_GENTITIES-1` ⇒ break；**旧帧剩下的按"不变"拷过去** |
| 过期 | `oldframe=NULL; lastframe=0;` + `Com_DPrintf("…out of date packet.\n")` / `"…out of date entities.\n"` | `newSnap.valid=qfalse` ⇒ **整帧丢弃**，下包 `clc_moveNoDelta` |

- 服务器窗口判据：`outgoingSequence - deltaMessage >= (PACKET_BACKUP - 3)` = **29 包**（Q3 20 包/s ⇒ ≈**1.45 s**；我们 60Hz 同窗口数 ⇒ ≈**0.48 s**）。
- 客户端另有三条否决：`!old->valid` · `old->messageNum != newSnap.deltaNum` · `parseEntitiesNum - old->parseEntitiesNum > MAX_PARSE_ENTITIES-128`
  ⇒ 分别打印 `Delta from invalid frame` / `Delta frame too old` / `Delta parseEntitiesNum too old`。

**2.5 为什么必须排序**（`SV_QsortEntityNumbers`）：调用点在 `SV_BuildClientSnapshot` 末尾，注释 *"if there were portals visible,
there may be out of order entities in the list which will need to be resorted for the delta compression to work correctly. This also
catches the error condition of an entity being included twice."*；比较函数还会报错 `if (*ea == *eb) Com_Error(ERR_DROP,
"SV_QsortEntityStates: duplicated entity");`。两端各有一对 `(newindex/newent/newnum)`、`(oldindex/oldent/oldnum)` 双指针归并，哨兵 `9999`(sv)/`99999`(cl)。
★ 我们的"实体号"是玩家 `role`（字典键）⇒ **必须定义并钉死一个全序**。

**2.6 ★ 对我们的直接后果（本次最重要）**：计划 T3 写「基线 = 客户端确认过的 tick（**管线已有** —— 输入包与本人包都带 `ack_seq`）」，**不成立**。
`snapshot_own` 的 `ack_seq` 是服务器回带的"已消费输入序"（`match_snapshot.gd` → `encode_own({"ack_seq": _ack_seq.get(role,0),…})`，喂 `prediction_rollback`）；
客户端侧唯一"收没收到世界包"的地方是 `_last_snap_tick`，它**只被比较**。⇒ 要做 T3 必须先加一条**新的上行字段**（Q3 的做法：塞进**每个**输入包头部）。这是协议改动，属**档 3**。

## 3. 量化的位数

**3.1 Q3（读全文）**：坐标 → `bits==0` float 分支，**13 bit**（可整数值且 `trunc+4096 ∈ [0,8192)`）否则 **32**；`trTime`/`trDuration`/`time`/`apos.*Time`
字段表 `bits=32`；usercmd 角度 `ANGLE2SHORT(x)=(int)(x*65536/360)&65535` = **16 bit / 0.0055°**；`MSG_WriteAngle` = **8 bit / 1.40625°**；整数 `*toF==0` 只 1 bit。
注释原文：*"if (int)f == f and (int)f + (1<<(FLOAT_INT_BITS-1)) < (1<<FLOAT_INT_BITS) the float will be sent with FLOAT_INT_BITS, otherwise all 32 bits will be sent"*。
★ **预测用不用量化值**：**确定的两条** —— ① 客户端预测的**输入**在发包前就已是 16 bit（`CL_FinishMove` → `cmd->angles[i] = ANGLE2SHORT(cl.viewangles[i]);`）
⇒ **输入侧两端同量化是硬事实**；② 客户端**不在本地重算权威态**，直接用收到的 `cl.snap.ps` 校正 ⇒ 没有第二个真相源。
★ **照实说：`bg_pmove.c` 本轮没读** ⇒ 对 Q3 的**位置**预测不下断言。要害差别：Q3 是"独立前推 + 事后校正"，我们是"回滚重放" ⇒ **只压上行在我们这里才真会永久分歧**。

**3.2 DarkPlaces / Xonotic（读全文，`protocol.h` 把位数写成了文档注释）**：`E5_ORIGIN32=0: short[3] = origin*8` ⇒ **3×16 bit、步长 0.125 单位**，`=1: float[3]`；
`E5_ANGLES16=0: byte[3] = angle*256/360` ⇒ **8 bit(1.40625°)**，`=1: short[3] = angle*65536/360` ⇒ **16 bit(0.0055°)**；
`E5_ALPHA/E5_SCALE` = `bound(0, alpha*255, 255)` / `bound(0, scale*16, 255)`；`EF_LOWPRECISION` = *"integer coordinates to save network bandwidth"*。
★ **`U_DELTA` 注释是本次最接近"增量语义"的一手定义**：*"uses previous frame as a baseline … **except for the forced full update every half second**"*
⇒ **DP 有 0.5 s 周期全量，Q3 没有**。ack 基线：`clc_ackframe` = *"[int] framenumber"*；`entityframe_database_t` 有 `latestframenum` 与 **`ackframenum`**；
`EntityFrame_AckFrame` = *"removes frames older than 'frame'"*；`MAX_ENTITY_HISTORY 64`。全丢复位：`EntityFrame4_ResetDatabase`（*"resets compression…"*）·
`EntityFrame_ClearDatabase`（*"compresses against nothing"*）· `EntityFrame5_LostFrame`。

**3.3 Teeworlds（读全文）**：量化写在「状态 ↔ 线格式」的转换里（`gamecore.cpp` `Write`/`Read`）：`m_X = round_to_int(m_Pos.x)` ·
`m_VelX = round_to_int(m_Vel.x*256.0f)` · `m_Angle = (int)(angle(...)*256.0f)`（字段位宽在 `snap_obj.h`，★ **未读** ⇒ 不写它是几位）。
★★ `void CCharacterCore::Quantize(void) { CNetObj_CharacterCore Core; Write(&Core); Read(&Core); }` —— 「两端必须同量化」的**代码级原语**，无注释，但**存在本身就是答案**。
增量**不用掩码**（`snapshot.cpp`）：`DiffItem` 逐 int 相减，`UndiffItem` 只用 `*pDiff != 0` 判"变了"、变了才 `CVariableInt::Pack`；**删项显式列出**
（`m_NumDeletedItems` 后跟被删项的 **Key**）；新增项 `mem_copy` 全量；`SetStaticsize` 让定长类型连长度都不发。`protocol.h`：`MAX_SNAPSHOT_PACKSIZE=900`、`SERVER_TICK_SPEED=50`、`MAX_PLAYERS=16`。

**3.4 Source SDK 2013（`bitbuf.h` 读全文，实现在 `bitbuf.cpp`）**：★ **位数取不到**（§7）。头文件能给的两条：① `ZigZagEncode32/64` + `kMaxVarint32Bytes = 5`；
② `WriteUBitVar()` 的**参考实现写在注释里**：`<0x10 → 2+4 bit`、`<0x100 → 2+8`、`<0x1000 → 2+12`、否则 `2+32`。接口侧只有名字：
`WriteBitCoord`/`WriteBitCoordMP(f, bIntegral, bLowPrecision)`/`WriteBitAngle(f, numbits)`/`WriteBitVec3Coord`。

## 4. 增量 × 不可靠传输

**4.1 Q3 的三条应对（全部由客户端发起，读全文）**
1. **解码不了就整帧不落地**：原句 *"If the frame is delta compressed from data that we no longer have available, we must suck up the rest of the
   frame, but not use it, then ask for a non-compressed message"*；代码 `newSnap.valid = qfalse; … if (!newSnap.valid) return;`。
2. **下包改 `clc_moveNoDelta`**：`if (cl_nodelta->integer || !cl.snap.valid || clc.demowaiting || clc.serverMessageSequence != cl.snap.messageNum)
   MSG_WriteByte(&buf, clc_moveNoDelta);` ⇒ 服务器 `deltaMessage = -1` ⇒ 下一帧全量。
3. ★★ **把空档期的 snapshot 全部作废**：注释 *"clear the valid flags of any snapshots between the last received and this one, so if there was a
   dropped packet it won't look like something valid to delta from next time we wrap around in the buffer"*，代码
   `for ( ; oldMessageNum < newSnap.messageNum; oldMessageNum++ ) cl.snapshots[oldMessageNum & PACKET_MASK].valid = qfalse;`
   ⇒ ★ 这条我们**没有**：若客户端 ack 的是"**最近收到的**包"（哪怕没解码成功）而不是"**最近成功解码的**"，就会拿解不出的帧当基线。

**4.2 Gaffer《Snapshot Compression》（读全文）**：原句 *"it is of course essential that the sender only encodes snapshots relative to baselines
that **the other side has received** … Therefore, to handle packet loss **the receiver has to continually send 'ack' packets back**"*；
收敛形态 *"the steady state becomes the sender encoding snapshots relative to a baseline that is roughly **RTT in the past**"*
⇒ ★ **基线比"最新帧"旧约 1 个 RTT** ⇒ T3 的 "−68%" 若按"对上一帧求差"算会**偏乐观**（变更率随时间增长）。
首连无基线：*"I handle this by adding a single flag … 'this snapshot is encoded relative to the initial state of the simulation'"*（我们**没有**初始态 ⇒ 只能全量）。
**索引位 vs 变化位有交叉点**：*"With 10 bit indices … more efficient to use indices if we are sending **90 cubes or less (900 bits)**"* ⇒ 我们 13/34 字段的规模下**掩码侧永远赢**。
量化粒度是他**试出来的**：位置 *"512 values per-meter (roughly 2mm precision)"*、四元数 *"minimum sufficient precision … 9 bits"*、速度 *"32 distinct values per-meter per-second"* ⇒ **支持**「精度按观感试」。
★ 反直觉一条：*"Sometimes the best bandwidth optimizations aren't about optimizing what you send, they're about what you **don't** send"* —— 他在 60Hz 下**干脆不发速度**。

**4.3 有没有专门讲"delta + unreliable 的坑"的来源**：**有，但都是"通过设计规避"而非批判** —— Gaffer 整段的前提就是"不可靠 + ack 回带"；
Q3/DP 把"解不出来 ⇒ 丢弃 + 请求全量"写成正常路径；DP 用 0.5 s 周期全量兜底。★ **没找到**任何一手来源论证"delta 天生不适配不可靠"或"必须做 NAK"
⇒ 若写"delta + unreliable 是坑"，**那是自己的推论**；准确表述是「代价 = 一次全量往返」。

**4.4 ★ 量化与命中判定：没找到一手来源。** 试过的口径全部失败：Valve wiki（**Anubis 1.23.1**，连 `/wiki/Es/Lag_Compensation` 与 `/.within.website` 中转都被拦，实测 3 次）·
`doc.photonengine.com`（**浏览器校验页**）· 通用检索命中 Reddit/论坛/二手博客（**不值一引**）。⇒ **本问题无一手来源可引**。能做的只有**自己算**：
步长 `q` 的最大位置误差 `q/2`；判定为"圆 vs 圆"时最坏是半径方向 `q/2` 偏移 —— **这是几何，不是来源**。★ 落地前**不要**写"某来源建议 `q ≤ r/10`"这种话。

## 5. 兴趣管理 / PVS：小局（≤16）值不值
- Q3 的 PVS 在发包路径上是**白名单的一半**（`CM_ClusterPVS(clientcluster)` + `CM_AreasConnected` + `SVF_*` 标志），但 `frame->areabits` 的用途是
  *"a mask vector, which is what the renderer wants"* ⇒ **PVS 的立项理由是渲染可见性，省带宽是副作用**。说"Q3 靠 PVS 省带宽"是**把目的与副作用弄反**。
- 量级：`MAX_CLIENTS 64`、`GENTITYNUM_BITS 10`（`MAX_GENTITIES 1024`）、`MAX_SNAPSHOT_ENTITIES 1024`、满了 *"silently discard entities"* ⇒ 在**上千实体**上收益。
- 唯一沾边"小局也要裁"的一手是 **Halo 官方博客（读全文）**：*"Even in a 4v4 arena match there is too much data to send the entire state of the game world
  every server tick, so we only send the information we deem most relevant"* —— 但同文 FAQ 明写 **4v4=60Hz / BTB=30Hz** 且**没给状态量级** ⇒
  **不能**反驳我们（前提不同），**也不支持**我们（它没说"16 人以下不需要"）。
- ⇒ 我们「16 人不需要兴趣管理」**既未被检验也未被反驳**；能支撑的只有**本仓实测**（`netcode-at-16-players.md` §1：7+16×51=823 B ⇒ 1 片、上行 1.15 Mbit/s）。

## 6. 拥塞控制与速率自适应

**6.1 Gaffer《Reliability and Congestion Avoidance over UDP》（2008-10-20，读全文）**：**不做会怎样（原句）** *"If we just send packets without some
sort of flow control, we risk flooding the connection and inducing severe latency (**2 seconds plus!**) as routers … become congested and buffer up
packets."*；**ack 的可达性** = `[uint ack]` + **`[uint ack bitfield]`**（*"Let's include **33 acks per-packet**"*，一个 uint 表示 `ack-1…ack-32`）；
**丢包判定** *"if you don't get an ack for a packet within **one second**, it is very likely that packet was lost"*（★ 可作"基线彻底过期"的一手锚点）；
**RTT 平滑** *"**10%** seems to work well for me in practice"*；**简易二值**：好 = **30 pps**、坏 = **10 pps**，RTT 超 **250 ms** ⇒ 立刻掉 bad，
回 good 需连续好 **`t` 秒**，**10 秒内又掉 bad ⇒ `t` 翻倍**（上限 60 s）、**每好 10 秒 ⇒ `t` 减半**（下限 1 s）。他也点名更贪心的选项**有风险**。

**6.2 ★ ENet 自己给了什么（改变了我们的自我描述）** —— 机制（`enet_peer_throttle()`，`peer.c`，读全文）：
```c
if (peer->lastRoundTripTime <= peer->lastRoundTripTimeVariance) peer->packetThrottle = peer->packetThrottleLimit;
else if (rtt <= peer->lastRoundTripTime) { peer->packetThrottle += peer->packetThrottleAcceleration;
    if (peer->packetThrottle > peer->packetThrottleLimit) peer->packetThrottle = peer->packetThrottleLimit; return 1; }
else if (rtt >= peer->lastRoundTripTime + 2 * peer->lastRoundTripTimeVariance) {
    if (peer->packetThrottle > peer->packetThrottleDeceleration) peer->packetThrottle -= peer->packetThrottleDeceleration;
    else peer->packetThrottle = 0; return -1; }
return 0;
```
函数头注释：*"**Unreliable packets are dropped by ENet** … When the throttle has a value of 0, **all unreliable packets are dropped** by ENet."*

Godot 4.7 官方门面（`class_enetpacketpeer.rst`/`class_enetconnection.rst`，读全文）：

| API | 默认 | 原话要点 |
|---|---|---|
| `create_host(max_peers=32, max_channels=0, in_bandwidth=0, out_bandwidth=0)` | 带宽 0 = 不限 | *"optionally limiting bandwidth to in_bandwidth and out_bandwidth (if greater than zero)"* |
| `bandwidth_limit(in, out)` | — | *"Adjusts the bandwidth limits of a host."* |
| `compress(mode)` | 5 档 | ★ *"**Zstandard** … not very efficient on packets **smaller than 4 KB**"* + *"must be set to the same value on both … Clients will fail to connect if … differs"* |
| `set_timeout(t, t_min, t_max)` | `ENET_PEER_TIMEOUT_*` | ★ *"control how and when a peer will timeout from a **failure to acknowledge reliable traffic**"* ⇒ **只管可靠流** |
| `throttle_configure(interval, accel, decel)` | `interval` **5000**、`accel`/**`decel` 2** | 见上；*"The default value is 2"* / *"…5000"* |
| `PEER_PACKET_THROTTLE_LIMIT` | 初值 = `PACKET_THROTTLE_SCALE` = **32** | *"maximum number of unreliable packets that should not be dropped"* |
| `PEER_PACKET_THROTTLE_COUNTER` | 硬编码 **7** | *"cannot be changed"* |
| `set_ping_interval()` | **500 ms** | *"also to dynamically adjust the throttle during periods of low traffic"* |
| ENet `protocol.h`（读全文） | MTU 576–4096 · window 4096–65536 · fragment ≤ 1024×1024 | ★ `reliableSequenceNumber`/`unreliableSequenceNumber`/`unsequencedGroup` **全 `enet_uint16`** |

⇒ ★★ **两条直接影响**：① **我们的 `unreliable` 世界包会被 ENet 按概率丢弃**，判据是**可靠包**的 RTT 波动（不可靠包自己从不产生 RTT 样本）
⇒ 「丢一个增量包」的主因可能**不是网络**；T2 的字节/包数仪器**看不到这一层**，须读 `PEER_PACKET_THROTTLE`/`PEER_PACKET_LOSS` 才分得清。
② **`COMPRESS_ZSTD` 在 < 4 KB 上官方明说不划算** ⇒ 给 `netcode-snapshots.md` §5.4 的实测（N≤4 手打包更小）补一条**官方依据**（我们单端下行 54 KB/s ÷ 60 ≈ **900 B/帧**，正在那条区间里）。

## 7. 序号回绕与重连
**7.1 回绕**：Gaffer（读全文）*"if you sent **30 packets per-second**, it would take **over four and a half years**"* ⇒ 我们 60Hz：`2^32/60/86400/365 ≈ **2.27 年**`；
同文给了通用比较函数（16 bit），原句 *"Make sure you include this in any sequence number processing you do."*：`sequence_greater_than(s1,s2) = ((s1>s2)&&(s1-s2<=32768)) || ((s1<s2)&&(s2-s1>32768))`。
★ **先回绕的不是我们的 u32，是 ENet 的 u16**（§6.2 表末行）⇒ `2^16/60 = 1092 s` = **18 分 12 秒一轮** ⇒ **我们的 60Hz/60pps 落在 ENet 设计区间的上沿**（也解释 Gaffer 为何建议 30pps）。
DP 对照：`svs.nextSnapshotEntities >= 0x7FFFFFFE` 才 `Com_Error(ERR_FATAL, "svs.nextSnapshotEntities wrapped")`（**31 bit 单调环下标**）。

**7.2 重连复位基线**（四个一手做法，**都不是"客户端自己重置"**）：Q3 `SV_ClientEnterWorld` → `client->deltaMessage = -1;`（**服务器**在 "first usercmd
this gamestate" 清）· Q3 `SV_UserMove` `else { cl->deltaMessage = -1; }`（客户端改发 `clc_moveNoDelta`），`state != CS_ACTIVE` 时也置 -1 ·
Q3 `SV_WriteSnapshotToClient` `if (client->deltaMessage <= 0 || client->state != CS_ACTIVE) { oldframe = NULL; lastframe = 0; }` ·
DP `EntityFrame4_ResetDatabase`/`EntityFrame_ClearDatabase` · Teeworlds 删项显式列出 + 新增项全量（"没有合法基线"由**服务器**自然表达）。
★ 我们**已有同族先例可挂**：`server_main.gd:509` `_host._ack_seq[role] = 0  # C2 锚点重协商:客户端 rollback ring 已失` ⇒ T3 应照此：断线/换边/换局时**服务器侧清空该 peer 的 delta 基线**并**强制下一帧全量**。

## 8. 取不到的 URL（逐个原因）
| URL | 结果 |
|---|---|
| `developer.valvesoftware.com/wiki/Lag_Compensation`（含 `/wiki/Es/`、`/.within.website/?redir=` 中转） | ★ **Anubis 1.23.1 反爬**，返回 `Making sure you're not a bot!`（实测 3 次） |
| `cdn.jsdelivr.net/gh/ValveSoftware/source-sdk-2013@master/**/bitbuf.cpp` | **404**（该仓体积超 jsDelivr 50 MB 索引上限：`data.jsdelivr.com` 直接 `403 Package size exceeded`）⇒ **Source 的 `WriteBitCoord`/`WriteBitAngle` 位数取不到** |
| 同上 `{src,mp/src}/public/bitbuf.h` | **404** ⇒ 真路径是 `src/public/tier1/bitbuf.h`（**已取到**，§3.4） |
| `sources.debian.org/src/godot/4.6.3+ds-2/…enet/include/enet/protocol.h/`（及 `3.2.3-stable-1` 同路径、`/data/main/…` 直链） | **404** ⇒ 改用**上游** `cdn.jsdelivr.net/gh/lsalzman/enet@master/include/enet/protocol.h`（**已取到**） |
| `doc.photonengine.com/.../replication/interest-management` | **浏览器校验页**（`Browser Validation Page`，非正文）⇒ 兴趣管理**没拿到商业引擎一手** |
| `docs.godotengine.org/en/4.7/classes/class_enet{connection,packetpeer}.html` | HTTP 200 但正文被**导航外壳淹没**（两份抓取件里 grep 不到任何 `bandwidth`/`timeout`）⇒ 改用同一文档的 **RST 源**（**已取到全文**） |
| **量化 vs 命中判定半径** 的一手来源 | ★ **未找到**（口径见 §4.4）⇒ 本文**不写**任何数值建议 |

**已读全文的一手来源**：Q3 `sv_snapshot.c`/`msg.c`/`cl_parse.c`/`sv_client.c`/`qcommon.h`/`q_shared.h`/`cl_input.c` · DP `protocol.h` ·
Teeworlds `network.h`/`protocol.h`/`snapshot.cpp`/`compression.h`/`gamecore.cpp` · Source SDK 2013 `src/public/tier1/bitbuf.h` ·
ENet `peer.c` + `include/enet/protocol.h` · Godot 4.7 `class_enetconnection.rst` + `class_enetpacketpeer.rst` ·
Gaffer《Reliability and Congestion Avoidance over UDP》+《Snapshot Compression》（《Snapshot Interpolation》已在前文读过）。
**只片段/未读**：Q3 `bg_pmove.c`（⇒ §3.1 不对位置预测下断言）· Teeworlds `snap_obj.h`（⇒ 不写字段位宽）· Source `bitbuf.cpp`（取不到）。

## 9. ★★ 我们可能漏掉的细节（**本次最重要的产出**）
「来源」一律给**一手**。🔴 = 本次新发现、有源码级依据。

| # | 细节 | 来源 | 我们现在 | 若不做的代价 |
|---|---|---|---|---|
| 1 | 🔴 **客户端要回带"已收到的服务器快照 tick"** —— 与输入 `ack_seq` 是**两个方向两件事**；须由**每个**上行包携带 | Q3 `cl_input.c`/`sv_client.c`（全文）· Gaffer《Snapshot Compression》（全文） | **没做**（`_last_snap_tick` 只被比较、从不外发） | ★ **T3 做不下去**：基线无从确定；拿输入 `ack_seq` 顶替 ⇒ 语义错位 ⇒ **静默错位**（抽搐且不报错） |
| 2 | 🔴 **丢包后把"空档期"的快照标成不可用**，否则会被当成合法基线 | Q3 `cl_parse.c`（全文，原句 §4.1） | **没做**（只 `if tier < _last_snap_tick: return`，不 ack 也不作废） | 拿解不出来的帧当基线 ⇒ **静默错位** |
| 3 | 🔴 **整帧解码失败要"丢弃 + 显式请求全量"**，而非等下一帧自然修好 | Q3 `cl_parse.c`（`valid=false` + 下包 `clc_moveNoDelta`，全文） | **没做**（计划只写"退回全量"，没写**谁发现、怎么请求**） | 丢一个增量包 ⇒ 客户端**不知道自己丢了** ⇒ 对手副本冻结到下次全量（≥1 RTT） |
| 4 | 🔴 **新实体需要一条 `baseline` 支路**（进场全量一次，之后相对它增量） | Q3 `sv_client.c` `SV_SendClientGameState` + `sv_snapshot.c`（全文） | **没做** | 进场瞬间只能整包全量 ⇒ 突增；有它才能只发一次 |
| 5 | 🔴 **掩码用「末位变化序号 `lc`」比定长掩码省**；Q3 **同时**用两套（标量 `lc` / 16 项数组位掩码） | Q3 `msg.c`（全文）+ 本仓变更率 2.0/13、4.1/34（`netcode-snapshots.md` §5.1b） | **计划里是 `DELTA_MASK_BYTES`** | 世界包白付 ~11 bit、本人包白付 ~30 bit/帧 ⇒ 60Hz×N 人上**吃掉这次收益的一大块** |
| 6 | 🔴 **消失实体要显式写 NULL**（实体号 + 1 bit），不是靠"包变小"推出来 | Q3 `MSG_WriteDeltaEntity(to==NULL)` / Teeworlds `m_NumDeletedItems`（全文） | **无增量语义** ⇒ 倒地/离开/换边只能整包重发表达 | 客户端**不知道该人从此不在包里** ⇒ 幽灵实体残留，或另开事件补偿 |
| 7 | 🔴 **实体顺序必须是两端钉死的全序** | Q3 `SV_QsortEntityNumbers` 注释 + `CL_ParsePacketEntities` 归并（全文） | **未定义**（世界包是 `Dictionary`，键是 role 字符串） | 顺序不一致 ⇒ 归并走错分支 ⇒ **该删的不删、该增的当增量** |
| 8 | 🔴 **基线窗口要有具体长度**（Q3 `PACKET_BACKUP-3 = 29` 包；DP `MAX_ENTITY_HISTORY 64` + ack 裁撤） | Q3 `qcommon.h`/`sv_snapshot.c` · DP `protocol.h`（全文） | **没定义**（只说"过期退回全量"） | 无法判定"过期"；服务器保留基线的内存/生命周期**无处约束** |
| 9 | 🔴 **周期性全量刷新**是可选兜底（DP：*"except for the forced full update every half second"*） | DP `protocol.h` `U_DELTA` 注释（全文） | **没做** | ack 回路一出问题，错误**永久累积**（无自愈点）；有它则最坏 0.5 s 收敛 |
| 10 | 🔴 **ENet 自带 throttle，会主动丢我们的 unreliable 包**（RTT 波动驱动；interval 5000ms、accel/decel 2、上限 32） | ENet `peer.c` + Godot 4.7 `class_enetpacketpeer.rst`（全文） | **不知道**（`netcode-snapshots.md` §3 写"没做"） | 误诊：把 ENet 的主动丢包当"网络差"；T2 的字节仪器**测不到**这层 ⇒ 读数与现象不符。**需订正 §3 那格** |
| 11 | **应用层拥塞控制**（Gaffer 简易二值：30↔10pps、RTT 阈值、`t` 翻倍/减半） | Gaffer 上文（全文） | **没做**（ENet 那层不算"我们的"） | 原句代价：*"risk flooding … severe latency (**2 seconds plus!**)"* ⇒ 上行是**服务器**发的，受害的是所有 peer |
| 12 | **带宽上限**（`create_host(in,out)` / `bandwidth_limit()`） | Godot 4.7 `class_enetconnection.rst`（全文） | **没设**（默认 0 = 不限） | 对照 Q3 的 `sv_maxRate`/`client->rate`，我们是**唯一没有速率上限**的一侧 |
| 13 | **量化必须两端同口径，且最好做成具名原语**（Teeworlds `Quantize() = Write(); Read();`） | Teeworlds `gamecore.cpp`（全文）· Gaffer《State Synchronization》（前文已读） | **没做**（`c2` 是回滚锚点） | 只压上行 ⇒ `restore_state()` 后重放**每次都对不上** ⇒ 静默抽搐 |
| 14 | **量化位数可抄**：DP `origin=short[3]×8`（0.125 单位）/`angles=byte[3]`(1.40625°) 或 `short[3]`(0.0055°)；Q3 角度 16bit；Teeworlds 位置取整、速度 ×256 | DP `protocol.h` · Q3 `q_shared.h`/`msg.c` · Teeworlds `gamecore.cpp`（全文） | **没做量化**（§5.1b 只测了字节收益 −8%~−16%） | 每帧 24 B/人的连续量硬付；★ **但仓主已裁定"量化碰回滚面"** ⇒ 本轮**不加戏** |
| 15 | 🔴 **增量与"世界包一次广播"互斥**：按 peer 增量后，每个 peer 的基线不同 ⇒ 不能再广播 | 本仓 `match_snapshot.gd` + `netcode-snapshots.md` §1.2 | **现状是广播**（含自己那份、客户端刻意不消费） | 广播优化与增量**二选一**；计划 T1（合包）与 T3（增量）**有隐藏冲突**，需先定 |
| 16 | **u16 才是先回绕的那层**（ENet 序号 16bit；60Hz ⇒ 18 分 12 秒） | ENet `protocol.h`（全文）· Godot `class_enetpacketpeer.rst`（全文） | **不知道**（只关心自己的 u32 = 2.27 年） | 自建应用层序号时**别**照抄 u32 的结论去用 u16 |
| 17 | **重连由服务端显式清基线**（Q3 `deltaMessage = -1`；我们已有 `_ack_seq[role] = 0` 先例） | Q3 `sv_client.c`（全文）· 本仓 `server_main.gd:509` | **有先例可挂**，但没有"delta 基线"这个概念 | 重连后拿旧基线 ⇒ 解出来是**两个纪元的混合**（与 `reclaim` 治的是同一种病） |
| 18 | 🔴 **zstd 在 < 4 KB 上官方明说不划算** —— 给 §5.4 的实测补官方依据 | Godot 4.7 `class_enetconnection.rst` `COMPRESS_ZSTD`（全文） | 已实测（N≤4 手打包更小）但**未引官方口径** | 若照那条独立线全面上 zstd ⇒ 在 ~900 B/帧的量级上**可能净亏** |

★ **反面清单（别做的）**：① 别把「量化误差 vs 判定半径」写成有来源的结论（§4.4：**没有**一手来源）；
② 别把「16 人不需要兴趣管理」挂到外部来源（§5：没有来源讨论这个规模，只能挂本仓实测）；
③ 别说「delta + unreliable 是坑」（§4.3：没有来源这样论证，准确表述是"代价 = 一次全量往返"）。

## 10. 与计划（`2026-10-13-stream-merge-metrics-and-delta.md`）的逐条对账
| 计划 | 核实 |
|---|---|
| 引 Q3「包头 `lastframe for delta compression`」 | ✅ 正确（文件头注释原文，§2.1） |
| 引 *"this will not result in any bytes being emitted…"* | ✅ 正确（原文拼写 `emited`，§2.3） |
| 引 `Delta request from out of date packet/entities` ⇒ 退回全量 | ✅ 正确（两条 `Com_DPrintf` 都在 `sv_snapshot.c`） |
| T3 前提「基线 = 客户端确认过的 tick（**管线已有**：带 `ack_seq`）」 | ❌ **不成立**（§2.6）：那是**反方向**的 ack ⇒ **把 T3 从"改编码"升级为"改协议+改输入包"** |
| T3「`lastframe` + 每位一字段的掩码 + 过期退回全量」 | ⚠️ 语义**齐全但偏重**：Q3 用 `lc`（更省）+ `baseline`（新实体）+ 客户端**主动请求全量**（细节表 #1/#4/#5） |
| T1「世界 + 本人合包，每客户端每帧一条」 | ⚠️ 与 T3 **有隐藏冲突**（细节表 #15）⇒ **T1 动手前先定这一条**，否则 T3 会推翻 T1 的合包方式 |
| T1 Interfaces「不变：…输入包」 | ⚠️ T3 会碰**输入包**（§2.6）⇒ **需订正** |
| T2「量测含线上字节」 | ✅ 方向对；★ **补充**：还要读 `PEER_PACKET_THROTTLE`/`PEER_PACKET_LOSS`/`PEER_ROUND_TRIP_TIME`，否则分不清"网络丢的"与"ENet 主动丢的"（§6.2） |
| T2「口径对齐 `tunnel_feel_report.py`」 | ⚠️ 那是**二手**（另一条线自研工具，**不在本仓**）⇒ 可作线索、**不作来源**；一手口径用 Gaffer §6.1（RTT 平滑 10%、1 s 未 ack 判丢、二值速率） |
