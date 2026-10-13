# 把网流量收成三条流 + 上量测 + 只发变化 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ① 把每帧几十条 `@rpc` **合并成三条流**(省掉"每条消息自带的抬头"); ② 把**量测**补上(尤其"线上字节"——本仓至今没有这条仪器); ③ 在①的基础上**只发变化**(字段级增量 + 客户端确认过的基线)。

**Architecture:** 现在每帧的消息是:1 条世界广播 + N 条本人包 + 若干事件(每条一个 `@rpc`,每次都带方法名/节点路径 + 参数包装)。改成**三条流**:`快照流`(每客户端每帧**一条**:世界 + 本人合包)、`事件流`(同帧多个事件合一条)、`控制流`(握手/低频)。量测就挂在流上(字节/条数/积压/回滚)。最后把"快照流"从**全量**改成**字段级增量**:包内带 `lastframe`(基线 = 客户端确认过的 tick,**管线已有**——输入包与本人包都带 `ack_seq`),没变的字段**一个字节都不发**;基线过期就退回全量。

**Tech Stack:** Godot 4.7.1 / GDScript / ENet

**Spec / 依据:**
- 增量是主流且 1999 年就定型:[Quake 3 `sv_snapshot.c`](https://cdn.jsdelivr.net/gh/id-Software/Quake-III-Arena@master/code/server/sv_snapshot.c)(**读了源码**):包头 `lastframe for delta compression`、实体走 `MSG_WriteDeltaEntity`(原句:*"this will **not result in any bytes being emitted if the entity has not changed at all"*)、玩家状态走 `MSG_WriteDeltaPlayerstate`、基线过期(`Delta request from out of date packet/entities`)⇒ 退回全量。
- 量测口径来自另一位作者那条线(`origin/siri_v0.5.0`,`2e338d2`):延迟分位 / **输入未确认积压** / **预测回滚次数** / **服务端输入队列深度**。
- 本仓现状与实测:[`netcode-snapshots.md`](../../eng/netcode-snapshots.md) §2/§5.4 · [`netcode-input-uplink.md`](../../eng/netcode-input-uplink.md) · [`netcode-at-16-players.md`](../../eng/netcode-at-16-players.md)

**Global Constraints:** 见 [`2026-10-09-input-uplink-codec-and-redundancy.md`](2026-10-09-input-uplink-codec-and-redundancy.md) 的「Global Constraints」一节(逐字适用:grep 判词、条数闸、档 3 变异 + 真链路、逐个文件 `git add`、禁用 `RegEx`、先查 `lobby_alive`、批前后本线进程为 0、不 `--amend`)。

## Review Focus

1. **基线与 ack 必须配对**:基线 = 客户端**确认过**的 tick。**配对错就是静默错位**(客户端拿 A 帧当基线、服务器按 B 帧算增量 ⇒ 画面抽搐且不报错)。判据要能回答"去掉什么才红"。
2. **变化掩码漏一个字段 = 该字段永远不再更新**(静默)。⇒ 判据必须是"**表驱动**":掩码的位数与 schema 的字段数**对齐**,且每个字段都要有"变了才置位"的证明。
3. **全量回退必须可达**:客户端刚进场/断线重连/基线滚出缓冲 ⇒ 必须能退回全量。★ 按本仓纪律,**可达性要实测**(造一个"基线过期"的夹具),不可达的防御分支不写(D7)。
4. **合并后的顺序语义变了**:现在"事件"与"快照"各自的到达顺序由通道保证;合并成流之后,**同帧内的多个事件顺序**要显式定义(先发生先写)。
5. **量测必须含线上字节**:现有 `royale_soak` 的"快照 KB/s"是 `var_to_bytes(解码后的 Dictionary)`(见 `netcode-snapshots.md` §8.3、债单 §8.11)⇒ **它看不见这次改动的效果**。T2 的存在就是为了让 T1/T3 有数可读。

---

### Task 1: 把每帧消息收成三条流

**Files:**
- Modify: `core/net/net_bus.gd`(三条流的入口 + 同帧事件合包)
- Modify: `server/match/match_snapshot.gd`(世界包与本人包**合成一个包**发出)
- Modify: `core/net/net_bus_ext.gd`(事件类 RPC 改走事件流)
- Modify: `docs/eng/netplay.md`(通道/流表当单一来源)
- Modify: `tests/smoke/rpc_channel_contract_smoke.gd`(流表契约)

**Interfaces:**
- Produces: `NetBus.send_frame(peer_packets: Dictionary)`(每客户端一条:世界 + 本人)· `NetBus.send_events(events: Array)`(同帧事件合成一条,内含 (kind, payload) 序列)
- 不变:对局逻辑、快照内容、输入包(**T1 只动"怎么发",不动"发什么"**)

- [ ] **Step 1: 数清楚现在每帧几条**(改之前必须先有基线读数)
  在服务端加临时计数(跑批时打印):每帧 `rpc` 调用条数、每类各几条。
  Run: `bash tests/probe/royale_soak_probe.sh`(4 客户端,先查 `lobby_alive`)
  Expected: 拿到"每帧 X 条"的基线数(写进 T1 的提交信息与 T2 的读数表)。

- [ ] **Step 2: 写失败的判据**(条数闸)
  `rpc_channel_contract_smoke` 加一条:**每帧对每个客户端的 RPC 条数 ≤ 2**(快照 1 + 事件 ≤1),且事件流在"同帧 3 个事件"时必须**只发 1 条**。
  ★ 这条能红:回到旧的"一事件一 RPC"⇒ 条数变 4 ⇒ 红。

- [ ] **Step 3: 实现合包**(不动载荷内容)
  世界 + 本人合成一条 `send_frame`;事件按到达顺序写入一条 `send_events`。

- [ ] **Step 4: 跑默认批 + 真链路 + 数条数**
  Run: `bash tests/run_all.sh`;`bash tests/probe/royale_soak_probe.sh`;`bash tests/smoke/pvp_match_smoke.sh`(先查 `lobby_alive`)
  Expected: 三档全绿;**每帧 RPC 条数从 X 降到 ≤3**;对局行为一致(快照/事件计数与改前同量级)。

- [ ] **Step 5: 变异验证(2 条)**
  M1 把合包拆回"世界、本人各一条" ⇒ 条数判据红;M2 事件不平铺而是每条一包 ⇒ 同帧 3 事件时红。

- [ ] **Step 6: 提交**(逐个文件 `git add`;提交信息里写清"每帧 X→Y 条")

---

### Task 2: 量测口径(含**线上字节**,还掉债单 §8.11)

**Files:**
- Create: `core/net/net_stats.gd`(**纯逻辑**,`-s` 可判:按 peer 累计 发送字节/包数/未确认输入/队列深度/回滚次数,窗口内求分位)
- Modify: `core/net/net_bus.gd` / `server/match/match_host.gd`(每个出包处累加**真实出包字节**)
- Modify: `--netstat` 打印(服务端;**开关写在 `--` 之后**)
- Create: `tests/smoke/net_stats_smoke.gd`(+ `.gd.uid`)

**Interfaces:**
- Produces: `NetStats.record_send(peer, bytes)` · `record_rx_ack(peer, seq)` · `summary(peer) -> Dictionary`(含 `bytes_per_s`、`pkts_per_s`、`unacked_input`、`queue_depth`、`rollbacks`)
- ★ 口径对齐另一位作者的 `tunnel_feel_report.py`(延迟分位 / 未确认积压 / 回滚次数 / 队列深度)

- [ ] **Step 1: 写失败的判据(3 条 + 条数闸)**
  ① 累加与窗口分位正确(喂已知序列 ⇒ p50/p95 对得上);② **未确认积压** = 已发未 ack 的输入条数,ack 到达后归零;③ 回滚计数只在真正回滚时 +1。

- [ ] **Step 2: 实现 `NetStats` 并接进出包处**(只加计数,不改行为)

- [ ] **Step 3: `--netstat` 打印并**用真链路读一次**
  Run: `bash tests/probe/royale_soak_probe.sh`(先查 `lobby_alive`)
  Expected: 打出**每客户端每秒字节/包数**(这才是"线上字节";`royale_soak` 那个 KB/s 是解码后的 Dictionary,不算)。
  ★ 这一步的读数会成为 T3 的判据基线。

- [ ] **Step 4: 变异验证(1 条)**:把"出包处累加"改成"累加载荷长度而不是真实出包" ⇒ 字节数对不上 ⇒ 红。

- [ ] **Step 5: 提交**

---

### Task 3: 只发变化(**字段级增量 + 客户端确认过的基线**)

**Files:**
- Modify: `core/net/snapshot_codec.gd`(世界包加 `lastframe` + 每实体的**变化掩码**;新增 `encode_world_delta` / `decode_world_delta`)
- Modify: `server/match/match_snapshot.gd`(按 peer 保存"已确认基线"的快照内容)
- Modify: `scenes/pvp_game.gd` / `royale_game.gd` / `team_game.gd`(客户端保存基线并按 `lastframe` 解码;**基线过期 ⇒ 请求全量**)
- Modify: `tests/probe/snapshot_size_probe.gd`(+ 断言:变化率低时增量包显著小于全量)
- Modify: `docs/eng/netcode-snapshots.md`(§5.4 后新增"增量"一节 + 读数)

**Interfaces:**
- Consumes: T2 的 `NetStats`(字节读数)· 现有的 `ack_seq`(输入包与本人包都带,**管线已有**)
- Produces: `encode_world_delta(world, baseline) -> PackedByteArray`(`PROTO_VERSION` +1)· `decode_world_delta(payload, baseline) -> Dictionary`
- 协议常量:`KIND_WORLD_DELTA`、`DELTA_MASK_BYTES`(每位一个字段,表驱动)

- [ ] **Step 1: 写失败的判据(3 条 + 条数闸)**
  ① **没变的字段一个字节都不发**:构造"零变化"世界 ⇒ 增量包 ≤ 头 + 掩码(实测**远小于**全量);② **往返保真**:增量解码后的世界与编码前**逐字段一致**(含"掩码漏字段"必须红);③ **基线过期退回全量**:给一个过期基线 ⇒ 走全量且能解码。
  ★ ①的红线:把"变了才置位"改成"永远置位" ⇒ 包大小退回全量 ⇒ 红。

- [ ] **Step 2: 跑红**,再实现编码/解码(表驱动:掩码位数 = schema 字段数,写出/读入都用**同一张表**)

- [ ] **Step 3: 接服务器与三个客户端场景**(服务器按 peer 存基线;客户端 ack 后推进基线)

- [ ] **Step 4: 量效果(T2 的读数)**
  Run: `bash tests/probe/royale_soak_probe.sh`(先查 `lobby_alive`)
  Expected: **每客户端每秒字节数**显著下降(本仓早先估过"只发变化"能到 **−68%**:72 → ≈24 KB/s @N=8;这次用**真链路读数**验。

- [ ] **Step 5: 变异验证(逐条承重判据)**:① 掩码永远置位 ⇒ 判据①红;② 基线用"最新一帧"而不是"已确认帧" ⇒ 判据②红(错位);③ 去掉全量回退 ⇒ 判据③红。

- [ ] **Step 6: 跑默认批 + 真链路批 + 提交**
  Run: `bash tests/run_all.sh`;`bash tests/run_real.sh --yes`(R20 锁那一套)
  Expected: `RUN_ALL OK(…)` + 真链路 5 支;读数写进 `netcode-snapshots.md`。

## Self-Review

- **顺序**:T2 的仪器先于 T3 —— 否则 T3"省了多少"没有判据(这正是债单 §8.11 的教训)。
- **不动协议语义**:T1 只改"怎么发";T3 才碰线格式(带 `PROTO_VERSION` +1 与全量回退)。
- **可达性**:T3 的全量回退**有夹具**(刚进场/基线过期),不是 D7 那种不可达分支。
- **未决(不藏)**:T1 之后"事件与快照是否还需要分通道"(一个可靠有序、一个不可靠)要在 Step 4 的真链路里确认;**若合并后事件被迫走不可靠,则不合并事件流** —— 留待读数。


---

## 订正与补充（2026-10-13，调研后；**动手前必读**）

一手依据与全表：[`netcode-delta-and-quantization-details.md`](../../eng/netcode-delta-and-quantization-details.md)。

### ★★ 推翻本计划的一条前提：T3 的基线**不能用** `ack_seq`

本计划原写"基线 = 客户端确认过的 tick（`ack_seq` 管线已有）"——**错了**。实测核对：`ack_seq` 是**服务器已消费的输入序**（上行的反方向），
客户端的 `_last_snap_tick` **只被自己比较、从不外发**。⇒ **必须先在输入包里加一个"我最近成功解码的服务器快照 tick"字段**（Q3 的 `clc_move` 里就带着它）。
⇒ **T3 的前置任务 = 改输入包线格式**（档 3；与 [`2026-10-09-input-uplink-codec-and-redundancy.md`](2026-10-09-input-uplink-codec-and-redundancy.md) 的 T1 合并做，别分两次改线格式）。

### ★★ 另一条硬冲突：**广播** 与 **按 peer 增量** 只能选一个

各 peer 的确认基线不同 ⇒ 世界包**不能再广播**（现状是 1 条广播 + N 条本人包）。⇒ T1 与 T3 合起来的目标形态是
**每客户端一条包**（内含"你的世界增量 + 你自己的状态"），总数 = N 条（今天的 1+N 条里省掉广播那一跳，但服务器要编 N 份不同的包 ⇒ **CPU 付 N 倍**）。
⚠️ 本计划 T1 Step 4 的"每帧消息条数 ≤ 2"要改成"**每客户端每帧 1 条**"。

### T3 必须补齐的细节（全部有 Q3/DP/Teeworlds 一手来源）

1. **实体全序**：世界包现在用 `Dictionary`（role 字符串当键）⇒ 顺序未定义。必须**两端钉死按 role 升序**，否则归并走错分支（该删的不删）。
2. **消失实体要显式写删除**（实体号，不写 NULL 就没有"这个人不在包里了"）⇒ 否则倒地/离开/换边会留下**幽灵实体**。
3. **新实体走 `baseline` 支路**（进场全量一次，之后相对它增量），否则进场瞬间只能整包全量。
4. **整帧解码失败 ⇒ 显式请求全量**（Q3 是 `valid=false` + 下包 `clc_moveNoDelta`），**不是**"等下一帧自然修好"。
5. **丢包后的空档帧要标记为不可用**，不许被当成合法基线（Q3 `cl_parse.c`）。
6. **基线窗口要有具体长度**（Q3 `PACKET_BACKUP-3 = 29` 包；DarkPlaces `MAX_ENTITY_HISTORY = 64`）—— 我们得自己定一个并写进注释。
7. **周期性强制全量兜底**（DarkPlaces 原句 *"forced full update every half second"*）⇒ 给 ack 回路一个自愈点。
8. **重连由服务器显式清基线**（Q3 `deltaMessage = -1`；本仓已有 `_ack_seq[role] = 0` 的先例可挂）。
9. **掩码别用定长**：我们实测变更率只有世界 2.0/13、本人 4.1/34 字段/帧 ⇒ Q3 的两套里**标量"末位变化序号 `lc`"** 更适合我们，
   定长掩码会白付（世界 ~11 bit、本人 ~30 bit/帧）。T3 Step 1 的 `DELTA_MASK_BYTES` 要改。
10. **量化（T3 之外的收益）本轮不加戏**：仓主已裁定"量化碰回滚面"；细节与可抄位数（DP `short[3]`×0.125 / Teeworlds `Quantize()`）都记在调研里，留待专批。

### T2 要补的量（否则读数与现象对不上）

- ★ ENet **自带 throttle，会主动丢我们的 `unreliable` 包**（RTT 波动驱动；interval 5000ms、accel/decel 2、上限 32）⇒
  必须同时读 `PEER_PACKET_THROTTLE` / `PEER_PACKET_LOSS` / `PEER_ROUND_TRIP_TIME`，才能分清"网络丢的"与"ENet 主动丢的"。
- **带宽上限**：我们用 `create_host()` 没传带宽（0 = 不限）⇒ 对照 Q3 的 `sv_maxRate`/`client->rate`，**我们是唯一没有速率上限的一侧**。
  ★ 顺手可做（一行）：给 host 设一个入/出上限，并把它当 T2 的一个读数。
- ★ 订正：本仓 `netcode-snapshots.md` §3 写"没做拥塞控制"只在**应用层**成立 —— ENet 那一层是**有**的（见上）；本计划 T2 的读数要能分开这两层。

### 别做的（调研给的反面清单）

① 别把"量化误差 vs 判定半径"写成有来源的结论（**没有**一手来源）；② 别把"16 人不需要兴趣管理"挂外部来源（**没有**来源谈这个规模，只能挂本仓实测）；③ 别说"delta + unreliable 是坑"（没有来源这样论证；准确说法是"**代价 = 丢一次就要一次全量往返**"）。


### 补充（2026-10-13 第二路调研：客户端插值/时钟/输入）

一手依据与 16 行全表：[`netcode-client-interp-and-input-details.md`](../../eng/netcode-client-interp-and-input-details.md)。

**已经对了、别推翻的**：插值只做外观、预测面（幽灵体）用**未平滑**权威值（netfox + Unity Entities + Gaffer 三条一手正面确认）；播放时钟**不得倒退**（Unity/netfox 都要求；★ 但**别拿 RFC 5905 当依据**——NTP 说的是"降低倒退概率"，允许倒退）。

**该补进 T1/T2/T3 的**：

1. ★★ **上行必须带"客户端 tick"**（不只是 `seq`）—— Valve 官方 `CUserCmd` 同时有 `command_number` 与 `tick_count`。
   ⇒ 与第一路调研的"要带'我最近解码的服务器快照 tick'"是**同一批改动**：**输入包一次性扩字段**，别改两次线格式。
2. ★★ **瞬移要由"产生它的代码"显式声明**（netfox `teleport()`、UE `bJustTeleported`），不要靠距离猜。
   我们现在只有"相邻样本差 > 128px"一档 ⇒ **回溯一小步 / 重生点很近 / 换边 <128px 会漏判**，把瞬移演成滑动。落地时给 `player_replica` 加一个 `declare_teleport()`，由回溯/重生/换边的**调用点**显式调它。
3. **阈值主流是两档**（UE：小误差允许滞后 / 大误差直落 256-384），外加"接近静止"速度阈值。我们现在一档 ⇒ 尖峰只能靠冻结吞。
4. **瞄准/朝向是外观量、要插值、且走最短弧**（`Vector2.slerp` / `lerp_angle`；netfox 与 Gaffer）。我们现在瞬跳（60Hz 看不出，降频就"枪口一跳一跳"）。
   ★ **别直接 `lerp(_aim, …)`** —— 单位向量跨 ±x 会**穿原点**。
5. **饥饿策略要显式 + "猜"要记账**：netfox"不模拟" vs GGPO"重复上一帧并**记下第一个猜错的帧**"（两派相反，我们选后者更稳，但**必须记账**，否则猜错无人知）。我们现在沿用 `held` **不记账**。
6. **服务器回传"你的命令在缓冲里等了多久"**（Unity Entities 做法）⇒ 客户端才能把**服务器排队**与**路径延迟**分开；我们现在把两者一起吃掉了。
7. **外插（如果做）必须有硬上限**：Unity 默认允许 **20 tick**；Gaffer 反对（只对近似线性运动有效、50-250ms）。⇒ 我们选"冻结"**合法且保守**，不是漏做；要补的是"若外插，写死上限"。

**命名/引用口径（防以后引错）**：
- 深度补偿系数 **1.5 是我们自定的**（官方是 Unity `InterpolationDelayJitterScale = 1.25` 的抖动乘子）⇒ **别写"1.5 有出处"**。
- 冗余 **3 条是我们自定的**（Unity 官方默认 4 = 2+2；Q3 是 `cl_packetdup`；**没有"按丢包率"的公式**）⇒ 同上。
