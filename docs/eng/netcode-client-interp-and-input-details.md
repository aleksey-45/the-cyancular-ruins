# 副本插值与输入上行的细节：一手来源调研（增量）

> **这份文档是什么**：只回答 7 个**细到实现层**的问题（丢包冻结 vs 外插、大跳变判据、瞄准/姿态插值、客户端领先量、输入上行细节、速率调整、静默 bug 清单）。互链：[`netcode-playout-clock-sync-sources.md`](netcode-playout-clock-sync-sources.md)（时钟目标该是什么）·[`netcode-jitter-buffer-practice.md`](netcode-jitter-buffer-practice.md)（深度与速率的主流实现）·[`netcode-input-uplink.md`](netcode-input-uplink.md)（上行现状与冗余经济学）·[`netcode-snapshots.md`](netcode-snapshots.md) §5.3（副本插值现状与读数）—— **本文件只做增量**，不重复那四份的结论与实测。
> **纪律**：只引一手（官方文档 / 官方开源仓库源码与注释 / spec / 原作者本人文章）；每条标 **读了全文** / **只拿到片段** / **取不到**；与我们的关系（支持 / 无关 / 相反）都明说；来源之间矛盾**不调和**；取不到的逐个列原因（§10）。**真相源排序**：源码 > 探针实测 > 本文档 > 其它。
> **我们的现状（本次读码确认，引用处不重复）**：[`player_replica.gd`](../../scenes/player/player_replica.gd) `PLAYOUT_TICKS = 4` / `SNAP_DIST = 128` / `HISTORY_MAX = 12`、夹逼线性插值**两端都冻结**、aim/pose/facing **逐包瞬跳**；[`playout_clock.gd`](../../core/net/playout_clock.gd) `WINDOW = 8` 取 `o_min`、`DEPTH_COMP_MAX = 4`、死区 1.5 tick、±10%、`render_tick` 单调不减。

---

## 1. 结论（先说）

1. **"外插若干毫秒再冻结"确实有一手依据，而且给的是硬上限**：Unity Netcode for Entities 有 `MaxExtrapolationTimeSimTicks`（**默认 20 tick**，"the maximum time (in simulation ticks) which the client can extrapolate ahead, when data is missing"）。**反向的一手依据同样存在**：Gaffer 明说外插在**会碰撞/非线性**的物体上会坏掉，只在"mostly linear motion（飞机/船/飞船）"上能用**50–250ms**。⇒ 我们的"冻结"不是缺省，是**选择**；选它的代价与收益在 §2、§9 第 1 行。
2. **大跳变判据的主流是"固定距离阈值 + 显式状态标志"，不是速度上限**：Unreal 给了一对阈值（`NetworkMaxSmoothUpdateDistance = 256`、`NetworkNoSmoothUpdateDistance = 384`，单位 uu）与一个标志位（`bJustTeleported`）；netfox 给的是**显式 API** `TickInterpolator.teleport()`。**没有找到"位移 > 最大移速 × Δt 就不可能是真的"这种速度判据的一手来源**（§3）。
3. **朝向/瞄准该走最短弧，这一点有官方原句**：Godot 官方 `@GlobalScope.lerp_angle`（"interpolates correctly when the angles wrap around TAU"）与 `cubic_interpolate_angle`（"shortest path"）；netfox 明说欧拉角插值在整圈时会出错、要用四元数或整个 transform；Gaffer 说朝向**用 slerp 就够**、不必传角速度。⇒ 我们将来若要给 aim 加插值，**不能**对 `_aim` 直接 `lerp`（单位向量跨 ±x 时会穿原点）——要么 `slerp`，要么 `lerp_angle`（§4）。
4. **"客户端只领先一个常数"有官方参数名与默认值**：Unity Entities `TargetCommandSlack`（默认 **2 tick**，"the number of simulation ticks that the client tries to stay ahead of the server"）。**Overwatch 的"半个 RTT + 一帧"仍然取不到一手出处**（GDC Vault 正文需登录/付费；本次也没找到任何官方英文文稿）；Source 的 `cl_interp`/`cl_interp_ratio` 官方关系**仍然取不到**，本次新增一条硬证据：**Valve 官方 SDK 里根本没有 `cl_interp` 本体**（§5）。
5. **输入饥饿有两派一手做法且方向相反**：netfox **默认不模拟**（"If there's no input, the node simply isn't simulated"）；GGPO 在预测模式下**重复上一帧输入**（"Predict that the user will do the same thing they did last time"）并**记账第一个预测错的帧**再回滚。我们做的是第三形态（沿用 held、**不记账**）（§6.1）。
6. **上行该"序号 + 时间"两个都带**：Valve 官方 `CUserCmd` 同时有 `command_number`（"For matching server and client commands"）与 `tick_count`（"the tick the client created this command"），外加一个 `hasbeenpredicted` 位。我们**只有 `seq`**（§6.2）。
7. **"时钟不得倒退"有一手原句（Unity Entities、netfox），但 RFC 5905 的口径相反**：NTP 的 STEP 分支只说"降低倒退的概率"（"lessen the chance the clock might be stepped backwards"）⇒ 它**允许**倒退。两者字面相反，照实写不调和（§7）。
8. **本次最有价值的一手清单是 netfox 的两页**：`interpolation-caveats`（欧拉角插值 / 只插外观 / 突跳要显式 `teleport()`）与 `input-gathering-tips-and-tricks`（**一次性输入若"取后不清"会被 tick loop 里的每个 tick 用一遍** —— 这就是"输入被应用多次"的一手形态）。逐条进了 §9 的表。

---

## 2. 丢包时冻结还是外插（问 1）

**主张"可以有界外插"的一手来源**

- Unity **Netcode for Entities**：`ClientTickRate.MaxExtrapolationTimeSimTicks` 原文 *"The maximum time (in simulation ticks) which the client can extrapolate ahead, when data is missing. **Defaults to 20.**"*（[API 文档](https://docs.unity3d.com/Packages/com.unity.netcode@7.1/api/Unity.Netcode.ClientTickRate.html)，**读了全文**）。⇒ **一段明确的时间上限**；同页把"插值窗口太短"的症状也点名了（见 §8）。
- Unity **NGO**：`BufferedLinearInterpolatorQuaternion` 类摘要 *"Solves for incoming values that are jittered. **Partially solves for message loss. Unclamped lerping helps hide this, but not completely**"*（[官方 API 文档](https://docs.unity.cn/Packages/com.unity.netcode.gameobjects@1.5/api/Unity.Netcode.BufferedLinearInterpolatorQuaternion.html)，**读了全文**，Unity 中国站官方镜像）。⇒ 它的默认插值器是**不夹紧**的，即过最新样本后继续外推——**与我们"冻结"相反**。★ 照实说：该页**没有给上限数值**。
- Gaffer《Snapshot Interpolation》：外插能换延迟，但 *"if your simulation is mostly linear motion, eg. fast moving planes, boats, space ships – you may find that a simple extrapolation works well for **short time periods (50-250ms or so)**, but in my experience as soon as objects start colliding with other non-stationary objects, extrapolation starts to break down."*（[原文](https://www.gafferongames.com/post/snapshot_interpolation/)，**读了全文**）。⇒ **可照抄的边界：50–250ms，且条件显式（近似线性运动）**。

**主张"别外插"的一手来源（与上面并存，不调和）**

- 同一篇 Gaffer：*"One technique that people often use to hide the delay … is to use extrapolation. But in my experience, extrapolation doesn't work very well for rigid bodies because their motion is non-linear and unpredictable."*，并逐条列了它坏在哪（穿地板、"不知道弹簧力"、碰撞响应预测错、附着物切向速度错）。
- Unity Entities 手册把两类对象**分开**：*"You should only use prediction time for a predicted object like the local player. For interpolated objects, the client should present them in a state it has received data for."*（[官方手册](https://docs.unity3d.com/Packages/com.unity.netcode@7.1/manual/time-synchronization.html)，**读了全文**）。
- Unity Entities 手册同页另给丢包时的**首选**做法（不是外插）：插值延迟本身*"calculated by taking into account round trip time, jitter and packet arrival rate"*，并*"add some additional time … to make sure we can handle some packets being lost"*。

⇒ **关系**：外插派**支持**"外插要有硬上限、且只在特定运动形态下用"；反外插派**支持**我们"冻结"的选择，同时也**相反**于 NGO 的 unclamped 默认。★ 与我们的差别：我们**连上限都没有**（因为完全不外插），所以 §9 第 1 行的代价是"丢包期对手静止"。

## 3. 大跳变的判据（问 2）

| 判据类型 | 一手来源与原句 | 数值 |
|---|---|---|
| **固定距离阈值（双档）** | Unreal `UCharacterMovementComponent`：`NetworkMaxSmoothUpdateDistance` *"Maximum distance character is allowed to lag behind server location when interpolating between updates."*；`NetworkNoSmoothUpdateDistance` *"Maximum distance beyond which character is **teleported** to the new server location **without any smoothing**."*（[Epic 官方类页](https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/GameFramework/UCharacterMovementComponent?application_version=5.0)，**读了全文**） | 官方页**未给默认值**；默认值在源码：`256.f` / `384.f`（**只拿到片段**：Ue4 源码的第三方镜像 `CharacterMovementComponent.cpp:385-386`） |
| **固定距离阈值（错误门控）** | Unreal `AGameNetworkManager`：*"MAXPOSITIONERRORSQUARED is the square of the max position error that is **accepted (not corrected)** in net play"*；`ExceedsAllowablePositionError()` 即 `(LocDiff\|LocDiff) > MAXPOSITIONERRORSQUARED`（**只拿到片段**：UE 源码第三方镜像 `GameNetworkManager.h:100`、`GameNetworkManager.cpp:156`；另见第三方自动生成 wiki [页](https://indxzero.github.io/ue544cvarwiki/articles/maxpositionerrorsquared/)，**读了全文**） | 源码默认 **3.0**（⇒ &#124;误差&#124; > √3 ≈ 1.73 uu 才算错） |
| **"接近静止"速度阈值** | 同上头文件：*"MAXNEARZEROVELOCITYSQUARED is the square of the max velocity that is considered **zero (not corrected)** in net play"* | 源码默认 **9.0**（⇒ &#124;v&#124; < 3 uu/s 视为静止） |
| **显式状态标志（推荐形态）** | netfox `TickInterpolator`：*"When a node makes a sudden change, like teleporting from one place to another, interpolation may not be desired. **Call `teleport()` in these cases to avoid interpolation and just jump to the current state.**"*（[官方文档](https://github.com/foxssake/netfox/blob/74af631f57de6a105978d2d71af26d313ca5fc4d/docs/netfox/nodes/tick-interpolator.md)，**读了全文**） | 无阈值 —— **由调用方声明** |
| **显式状态标志（引擎侧）** | Unreal `bJustTeleported`：*"Used by movement code to determine if a change in position is based on normal movement or a teleport."*（Epic 官方类页，**读了全文**） | 布尔 |
| **速度上限（"超出最大移速×Δt"）** | **未找到一手来源**。★ 相关但**不是**同一件事：`MAXNEARZEROVELOCITYSQUARED` 判的是"速度≈0"，不是"速度过大"。 | — |

⇒ **关系**：**支持**我们"距离阈值 + 一帧直落"这一形态（Unreal 是同一形态、且有**两档**）；**相反**于我们**没有显式 teleport 标志**（netfox 的形态更省事也更准：由产生瞬移的那段代码**声明**，而不是事后猜距离）。

## 4. 插值只做位置吗：瞄准 / 朝向 / 姿态（问 3）

- **角度插值必须走最短弧（官方原句）**：Godot 官方文档源码 `@GlobalScope.xml`：`lerp_angle` *"Linearly interpolates between two angles (in radians) … Similar to lerp, but **interpolates correctly when the angles wrap around TAU**."*；`cubic_interpolate_angle` / `cubic_interpolate_angle_in_time` *"Cubic interpolates between two rotation values **with shortest path**"*（[`@GlobalScope.xml`](https://cdn.jsdelivr.net/gh/godotengine/godot@4.4-stable/doc/classes/@GlobalScope.xml)，**读了全文**）。`Vector2` 另有 `slerp`：*"This method also handles interpolating the lengths if the input vectors have different lengths."*（[`Vector2.xml`](https://cdn.jsdelivr.net/gh/godotengine/godot@4.4-stable/doc/classes/Vector2.xml)，**读了全文**）。★ 我们是 Godot 项目 ⇒ **这条可以直接用现成 API**，不必自己写最短弧。
- **欧拉角插值会坏在哪（一手原句）**：netfox *"Interpolating `rotation` may lead to glitchy results when an object makes a full turn … **Using Euler angles to interpolate rotations doesn't work well**, as they can end up interpolating from -180 degrees to +180 numerically."*；处方是 *"Interpolate the whole `transform`"* 或 *"Interpolate `quaternion`"*（[官方文档](https://github.com/foxssake/netfox/blob/74af631f57de6a105978d2d71af26d313ca5fc4d/docs/netfox/tutorials/interpolation-caveats.md)，**读了全文**）。
- **朝向用 slerp 就够、不必传角速度**：Gaffer *"All that was needed to achieve an acceptable result was to switch from linear interpolation + normalize (nlerp) to **spherical linear interpolation (slerp)** to ensure constant angular speed for orientation interpolation."*（**读了全文**）。⇒ 与"只插值位置"**相反**：一手来源都把朝向当作**要插值**的量。
- **精度决定 slerp 还是 lerp（一手，且与量化耦合）**：Unity NGO `BufferedLinearInterpolatorQuaternion.IsSlerp` 备注 *"When using **half precision** (due to the imprecision) using **Lerp** is less processor intensive … When using **full precision** … using **Slerp** is more processor intensive yet yields more precise results."*（**读了全文**）。⇒ 若把 aim 量化成 1 字节角度，**来源支持**降级成普通插值。
- **离散状态（姿态/武器/布尔）**：**没有找到"不许插值"的明确禁令**，但有一条正面口径：netfox *"Since interpolation matters only for the game's visuals, it's enough to interpolate only the properties that affect the game's visuals."*，并明说 **headless 下默认关掉插值**（同上，**读了全文**）。
- ⇒ **关系**：我们"位置插值 + aim/pose/facing 瞬跳"**部分支持、部分相反**：来源支持"离散状态不必插值"，但**相关**的是一手来源普遍认为**朝向是外观量、应当插值**；我们没做的代价见 §9 第 5 行。

## 5. 客户端领先量与 Source 的 `cl_interp`（问 4）

- **领先量是显式参数（一手，有默认值）**：Unity Entities `ClientTickRate.TargetCommandSlack` *"Specifies the number of simulation ticks that the client tries to **stay ahead of the server**, to try to make sure the commands are received by the server before they are actually consumed. **Defaults to 2.** Higher values increase command arrival reliability, at the cost of a longer client prediction window"*（**读了全文**）。⇒ **支持**"早多少是参数而不是涌现量"，**但**它给的是 **tick 数**，不是"半个 RTT"。
- **Overwatch 的"半个 RTT + 一帧"——仍然没有一手出处**：GDC Vault 的《'Overwatch' Gameplay Architecture and Netcode》正文页本次实测重定向到 `/play/1024001/contactUs`（**取不到**：需登录/付费）；本次也没找到任何 Blizzard 官方英文文稿或官方博文。★ 前一份文档引的是转载中译（二手）⇒ **数值不可钉**，本次结论不变。
- **Source `cl_interp` / `cl_interp_ratio` ——本次新增一条硬证据，结论仍是取不到**：Valve 官方仓库 `ValveSoftware/source-sdk-2013` 的客户端文件里 grep `cl_interp` 只命中三个**别的** cvar：`cl_interp_npcs`（`"cl_interp_npcs", "0.0"`）、`cl_interp_all`（`"cl_interp_all", "0"`）、`cl_interpolate`（`"cl_interpolate", "1.0f", FCVAR_USERINFO|FCVAR_DEVELOPMENTONLY`）（[`c_baseentity.cpp`](https://cdn.jsdelivr.net/gh/ValveSoftware/source-sdk-2013@master/src/game/client/c_baseentity.cpp)，**读了全文**（grep 全文件））⇒ **`cl_interp` 本体在引擎侧、不在公开 SDK 里**，所以"官方关系式"这条在 Valve 公开的一手材料里**根本没有**。⇒ **不引**任何数值或公式。

## 6. 输入侧（问 5）

### 6.1 服务器"输入饥饿"（队列空）时主流怎么做 —— 两派，方向相反

- **派 A：不模拟（stall）**。netfox：*"By default, nodes are only simulated for ticks that we currently have enough information for - i.e. the input for the current tick. **If there's no input, the node simply isn't simulated**, as we can't know what the player intended to do."*；并把它做成**显式开关**（`Enable Prediction`：*"will simulate all the nodes it manages even for ticks that it doesn't have input for"*），配 `has_input()` / `get_input_age()` / `ignore_prediction(target)` 三个 API（[官方文档](https://github.com/foxssake/netfox/blob/74af631f57de6a105978d2d71af26d313ca5fc4d/docs/netfox/tutorials/predicting-input.md)，**读了全文**）。
- **派 B：重复上一帧输入，并记账**。GGPO `InputQueue::GetInput()`：*"The requested frame isn't in the queue. Bummer. This means we need to return a **prediction** frame. **Predict that the user will do the same thing they did last time.**"*；预测帧入队时逐位比对，不一致就记下 `_first_incorrect_frame`，由 `Sync::CheckSimulationConsistency()` 触发 `AdjustSimulation(seek_to)` 回滚（[`input_queue.cpp`](https://cdn.jsdelivr.net/gh/pond3r/ggpo@master/src/lib/ggpo/input_queue.cpp)、[`sync.cpp`](https://cdn.jsdelivr.net/gh/pond3r/ggpo@master/src/lib/ggpo/sync.cpp)，**读了全文**）。
- **派 C（我们）**：沿用上一包的 held、**丢掉边沿**（[`match_host.gd`](../../server/match/match_host.gd)）。★ 与 B 的关键差别：GGPO **记得**自己猜过哪一帧、并在真输入到达时**校验**；我们**不记账**（见 §9 第 9 行）。
- ⇒ **矛盾（不调和）**：netfox vs GGPO 对"没有输入"的默认答案相反，两者都是生产级回滚实现。**未找到**任何一手来源给出"何时该 stall、何时该猜"的统一判据。

### 6.2 上行该发帧号还是时间戳：**两个都发**

- Valve 官方 `CUserCmd`（[`src/game/shared/usercmd.h`](https://cdn.jsdelivr.net/gh/ValveSoftware/source-sdk-2013@master/src/game/shared/usercmd.h)，**读了全文**）：`int command_number;` 注释 *"For matching server and client commands for debugging"*；`int tick_count;` 注释 ***"the tick the client created this command"***；`bool hasbeenpredicted;` 注释 *"Client only, tracks whether we've predicted this command at least once"*。
- Quake 3 的 `usercmd` 走的是另一条路：`cl_packetdup`（钳到 **0..5**）决定"把最近几个包里生成的 usercmds 一起发"，源码注释 *"so even if a couple packets are dropped in a row, all the cmds will make it to the server"*（[`cl_input.c`](https://cdn.jsdelivr.net/gh/id-Software/Quake-III-Arena@master/code/client/cl_input.c)，**读了全文**）。
- ⇒ **关系**：**相反**于我们"只发 `seq`"。带 `tick_count` 的意义写在注释里：让两端能对**同一帧**达成一致（这正是我们今天缺的那一环，见 [`netcode-snapshots.md`](netcode-snapshots.md) §8 第 3 条）。

### 6.3 ack 该怎么用

- **服务器 → 客户端 ack 用来释放已确认输入（一手）**：GGPO 有专门的 `InputAck` 消息与 `int ack_frame:31` 字段（[`udp_msg.h`](https://cdn.jsdelivr.net/gh/pond3r/ggpo@master/src/lib/ggpo/network/udp_msg.h)，**读了全文**），收到后 `Sync::SetLastConfirmedFrame(frame)` → `_input_queues[i].DiscardConfirmedFrames(frame - 1)`（`sync.cpp`，**读了全文**）。
- **Quake 3 把"我收到的最后一条消息"回写进每个上行包**：*"write the last message we received, which can be used for **delta compression**, and is also used to tell if we dropped a gamestate"*（`cl_input.c`，**读了全文**）。
- **客户端侧"这条命令我预测过没有"是独立的一位**：Source 的 `hasbeenpredicted`（§6.2）。
- **服务端回传"命令在缓冲里待了多久"，客户端据此调自己的时间**：Unity Entities 手册 *"the server tracks how long it keeps commands in a buffer before it uses them. This is sent back to the client and the client adjusts its time so it receives commands just before it needs them."*（**读了全文**）。★ 我们**没有**这一项（我们只回传 `ack_seq` 与 `q`，客户端不据此调时钟）。
- ⇒ **关系**：我们"ack → 丢弃已确认命令 + 挡旧包"**与一手形态一致**（**支持**）；缺的是"用缓冲时长反馈调时间"（**没做**，§9 第 11 行）。

### 6.4 冗余窗口该按什么定

- Unity Entities 给了一组**官方默认值**：`NumAdditionalCommandsToSend` *"The `CommandSendSystem` will send `TargetCommandSlack` + `NumAdditionalCommandsToSend` commands in each input packet (**default of 2 and 2, thus 4**), as a packet loss recovery mechanism (hard max: 32) … **Min value is 1, as sending zero additional inputs can cause input loss, even on connections with zero packet loss.** … Higher values incur more server ingress bandwidth consumption, but can be useful when dealing with unstable connections. **However, you may just be re-sending commands that are already too old to be used.**"*（**读了全文**）。
- Quake 3 的规则是**"覆盖最近几个包"**而不是固定条数：`count = cl.cmdNumber - cl.outPackets[oldPacketNum].p_cmdNumber`，`oldPacketNum` 由 `cl_packetdup`（0..5）回看（`cl_input.c`，**读了全文**）。
- **没有找到"按丢包率算冗余条数"的一手公式**。能引的定量规则只有两类：① 定性 —"要能扛住**连续丢 N−1 个包**"（Gaffer《Snapshot Interpolation》对**缓冲深度**的同一口诀）；② 官方默认值 —**4 条**（Entities）。
- ⇒ 我们的"最近 3 条"**量级上与官方默认（4）同档**，但**没有公式能证明 3**。

## 7. 时间膨胀 / 速率调整 / "时钟不得倒退"（问 6）

- **"不得倒退"的明确原句（一手，两条）**：
  - Unity Entities 手册：`NetworkTimeSystem` *"slowly adjusts both `prediction tick` and `interpolation delay` in small increments to keep them advancing at a smooth rate and **ensure that neither the interpolation tick nor the prediction tick goes back in time**."*（**读了全文**）。
  - netfox：Simulation clock *"is **guaranteed to only move forwards in time**"*；参考钟的调整 *"to avoid large jumps in time, and to - when possible - **only go forward in time, not backwards**"*，偏移过大时 *"a **panic** occurs and the reference clock is **reset**."*（[官方文档](https://github.com/foxssake/netfox/blob/74af631f57de6a105978d2d71af26d313ca5fc4d/docs/netfox/guides/network-time-synchronizer.md)，**读了全文**）。
- **速率上限的两条一手数值**：Unity Entities `InterpolationTimeScaleMax = 1.1` / `InterpolationTimeScaleMin = 0.85`（*"The maximum/minimum value for the InterpolateTimeScale"*，**读了全文**）；Unity NGO `NetworkTimeSystem` 的 `adjustmentRatio = 0.01` 与 `hardResetThresholdSec = 0.2`（前一份文档已读，本次未重读）。
- ★ **RFC 5905 的口径不是"绝不倒退"**：STEP 分支原句 *"The step threshold can be changed in the reference implementation **in order to lessen the chance the clock might be stepped backwards**. However, there may be serious consequences"*（[RFC 5905](https://www.rfc-editor.org/rfc/rfc5905.txt)，**读了全文**（grep `backward`/`slew` 全文件））⇒ **NTP 允许向后跳，只是降低概率**；全文**没有**"never set backward"这样的句子。
- **矛盾（不调和）**：Unity/netfox 说播放时钟**不得倒退**；RFC 5905 说系统时钟**可以**倒退（并给出降概率的手段）。两者对象不同（本地播放时钟 vs 系统墙钟），但字面相反 —— 照实写，不调和。我们**站在 Unity/netfox 一侧**（`render_tick` 单调不减）。

## 8. 经典静默 bug 清单（问 7）—— 本次最有用的一批

| 现象（原文） | 类别 | 来源（读级） |
|---|---|---|
| 一次性输入若"取后不清"，会被 tick loop 里的**每个** tick 用一遍：*"this single recorded input was used for each tick in the tick loop. Resulting in the player trying to **jump for multiple ticks**, even though they pressed the button only on a single frame."* 处方：*"reset the input value after it's gathered - this way, the input will be true for **at most a single tick**"* | **输入被应用多次** | [netfox `input-gathering-tips-and-tricks`](https://github.com/foxssake/netfox/blob/74af631f57de6a105978d2d71af26d313ca5fc4d/docs/netfox/tutorials/input-gathering-tips-and-tricks.md)（全文） |
| 只在**一端**量化状态：*"the state that arrives on the right side is slightly different from the left side, leading to a slightly different extrapolation and **a pop** when the next state update arrives"* | **量化两端不一致** | [Gaffer `State Synchronization`](https://www.gafferongames.com/post/state_synchronization/)（全文） |
| 没有抖动缓冲：*"you'll have a **poor quality extrapolation and pops** in stacks of objects because objects in different state update packets are **slightly out of phase** with each other with respect to time"* | 其他（参考系/相位不一致） | 同上（全文） |
| 在**模拟层**对状态更新做平滑：*"I recommend **against** trying to apply some smoothing between the state update and the current state at the simulation level … you want to make sure it **extrapolates from a valid physics state**, rather than some smoothed, total bullshit made-up one."* | **预测与权威用了不同插值** | 同上（全文） |
| 外插不知道物理：*"Extrapolation doesn't know about collision with the floor so cubes extrapolate **down through the floor** and then spring back up"* | 其他（外插的假位移） | [Gaffer `Snapshot Interpolation`](https://www.gafferongames.com/post/snapshot_interpolation/)（全文） |
| 插值窗口太短会**静默**表现为"预测对象分类不了"：*"If you frequently encounter client predicted ghosts which fail to classify within the Interpolation Window, this may indicate that said window is too short."* | 其他（深度不足的症状） | [Unity Entities `ClientTickRate`](https://docs.unity3d.com/Packages/com.unity.netcode@7.1/api/Unity.Netcode.ClientTickRate.html)（全文） |
| 突跳不显式声明 ⇒ 插值会**演出一段没发生的位移**：*"Call `teleport()` … to avoid interpolation and just jump to the current state."* | 其他（瞬移被插值） | [netfox `TickInterpolator`](https://github.com/foxssake/netfox/blob/74af631f57de6a105978d2d71af26d313ca5fc4d/docs/netfox/nodes/tick-interpolator.md)（全文） |
| 欧拉角插值在整圈时静默错：*"they can end up interpolating from -180 degrees to +180 numerically"* | 其他（角度长弧） | [netfox `Interpolation caveats`](https://github.com/foxssake/netfox/blob/74af631f57de6a105978d2d71af26d313ca5fc4d/docs/netfox/tutorials/interpolation-caveats.md)（全文） |
| 回滚下"状态机"会静默错：*"Safeguards that implement a **cooldown** to changes … Transitions that enforce a specific order"* | 其他（回滚 × 状态机） | [netfox `Rollback caveats`](https://github.com/foxssake/netfox/blob/74af631f57de6a105978d2d71af26d313ca5fc4d/docs/netfox/tutorials/rollback-caveats.md)（全文） |

★ **没有找到**任何一手来源给出一份"**按类别编号**的联机静默 bug 大全"（Valve wiki 的整站都被 Anubis 拦，本次实测的是 `Talk:Interpolation`，见 §10）。上面这张表是**本次能从一手材料里拼出的最大集合**；"用最新帧当增量基线"与"时钟被每包重置"这两类，本次**仍未找到**一手来源点名，只能挂本仓自己的复盘（[`netcode-playout-clock-sync-sources.md`](netcode-playout-clock-sync-sources.md) §1、[`player_replica.gd`](../../scenes/player/player_replica.gd) 文件头的历史记录）。

---

## 9. ★ 我们可能漏掉的细节（本次最重要产出）

| # | 细节 | 来源（读级） | 我们现在 | 若不做的代价 |
|---|---|---|---|---|
| 1 | 外插要有**硬上限**（Entities 默认 20 tick；Gaffer 50–250ms 且限线性运动） | [Entities `MaxExtrapolationTimeSimTicks`](https://docs.unity3d.com/Packages/com.unity.netcode@7.1/api/Unity.Netcode.ClientTickRate.html)（全文）；[Gaffer](https://www.gafferongames.com/post/snapshot_interpolation/)（全文） | **没做**（丢包 = 冻结） | 丢包期对手"停住"而不是继续走；但换来的好处是**永不演出没发生的位移**——对会碰撞的 2D 角色，Gaffer 的结论站在我们这边 |
| 2 | 瞬移该由**产生它的代码显式声明**（`teleport()` / `bJustTeleported`），而不是事后按距离猜 | [netfox](https://github.com/foxssake/netfox/blob/74af631f57de6a105978d2d71af26d313ca5fc4d/docs/netfox/nodes/tick-interpolator.md)（全文）；Epic 官方类页（全文） | **没做**（只有 `SNAP_DIST = 128` 距离判定） | 回溯一小步 / 重生点离得近 / 换边距离 < 128px 时**漏判** ⇒ 演出一次没发生的位移；反之正常抖动若超阈值会被硬跳 |
| 3 | 阈值主流是**两档**（允许滞后的上限 256 / 超过就直落 384） | Epic 官方类页（全文）+ UE 源码第三方镜像（片段） | **没做**（只有一档 128px） | 没有 128px 与"几百 px"之间的中间档可调，抖动尖峰只能靠冻结吞 |
| 4 | 判据里还有一条**"接近静止"速度阈值**（`MAXNEARZEROVELOCITYSQUARED = 9.0`） | UE 源码第三方镜像（片段）+ 第三方 wiki（全文） | **没做**（不用速度门控） | 对副本渲染影响小；但幽灵体/预测面在对手急停时会把"低速残差"当真实误差处理 |
| 5 | 朝向/瞄准是**外观量、应当插值**，且必须走**最短弧 / slerp** | [Godot `@GlobalScope.lerp_angle`](https://cdn.jsdelivr.net/gh/godotengine/godot@4.4-stable/doc/classes/@GlobalScope.xml)、[`Vector2.slerp`](https://cdn.jsdelivr.net/gh/godotengine/godot@4.4-stable/doc/classes/Vector2.xml)（全文）；netfox（全文）；Gaffer（全文） | **没做**（aim/pose/facing 逐包瞬跳） | 低刷新/丢包下枪口方向阶跃（"瞄准在抖"）。★ **将来加的时候别直接 `lerp(_aim, ...)`**：`_aim` 是单位向量，跨 ±x 时线性插值会穿过原点 ⇒ 必须 `slerp` 或 `lerp_angle` |
| 6 | 若把朝向**量化**，插值算子该跟着降级（半精度用 Lerp、全精度用 Slerp） | [Unity NGO `BufferedLinearInterpolatorQuaternion`](https://docs.unity.cn/Packages/com.unity.netcode.gameobjects@1.5/api/Unity.Netcode.BufferedLinearInterpolatorQuaternion.html)（全文） | **不适用**（2D，`_aim` 是 `Vector2`，未量化） | 一旦把 aim 量化成 1B 角度，若仍强上精确算子，白付 CPU 且不改善观感 |
| 7 | **插值只做外观；预测面用未平滑的权威值** | netfox（全文）；[Unity Entities 手册](https://docs.unity3d.com/Packages/com.unity.netcode@7.1/manual/time-synchronization.html)（全文）；Gaffer（全文） | **已做**（位置插值；幽灵体跟 `target`；探针相C 0.000 px） | —— （这一条是对我们现有切分的**正面确认**，别推翻） |
| 8 | 客户端领先量该是**显式参数**（`TargetCommandSlack` 默认 2 tick / NGO `serverBufferSec = 0.05`） | Entities `ClientTickRate`（全文） | **没做**（上行不领先；只有渲染侧的 playout） | 服务器"输入饥饿"的频率完全由网络决定，抖一次饿一次；没有任何旋钮能换"更早到达" |
| 9 | 输入饥饿该有**显式策略**，且"猜"要**记账**（GGPO 记 `_first_incorrect_frame` 再回滚） | netfox `predicting-input`（全文）；GGPO（全文） | **部分做**（沿用 held；**不记账**） | 饥饿期的输入是猜的，而**没有任何机制知道猜错了** —— C2 对账只在收到权威态时纠，不专门针对饥饿期 |
| 10 | 上行应同时带**序号与客户端时间**（`command_number` + `tick_count`） | Valve 官方 [`usercmd.h`](https://cdn.jsdelivr.net/gh/ValveSoftware/source-sdk-2013@master/src/game/shared/usercmd.h)（全文） | **只带 `seq`** | 服务器无法把命令映射到"客户端认为的哪一帧" ⇒ 做不了客户端-服务器时间对齐，也分不清"命令在队列里等了多久"与"命令生成得晚" |
| 11 | 服务端应回传**"命令在缓冲里待了多久"**，客户端据此调自己的时间 | Unity Entities 手册（全文） | **没做**（只回传 `ack_seq` / `q`，客户端不据此调时钟） | 客户端 playout 只能感知"到达时刻" ⇒ **把服务器侧排队当成路径延迟吃掉**，深度补偿永远看不见积压 |
| 12 | 冗余窗口的官方默认是 **4 条**（`TargetCommandSlack` 2 + `NumAdditionalCommandsToSend` 2，最小 1 条） | Entities `ClientTickRate`（全文） | **计划中**（最近 3 条） | 量级同档，但**没有公式**支撑"3"；留一条判据：**改不可靠通道后必须去重**（见 13） |
| 13 | 改不可靠 + 冗余之后，**必须先去掉重复命令**（一次性输入"取后即清"） | netfox `input-gathering-tips-and-tricks`（全文）；GGPO `DiscardConfirmedFrames`（全文） | **没做**（今天靠 reliable 天然不重复；[`netcode-input-uplink.md`](netcode-input-uplink.md) §5.2 已登记） | 漏了 = 同一条输入被模拟多次 = 静默分歧（C2 的前提"1 seq = 1 tick"被打破） |
| 14 | 播放时钟**不得倒退**（局部：参考钟可 panic 重置，但 Simulation/插值 tick 只前进） | Entities 手册（全文）；netfox `network-time-synchronizer`（全文） | **已做**（`render_tick` 单调不减，步长恒 1±10%） | —— （★ 顺带：RFC 5905 对**系统钟**说的是"降低倒退概率"，不要拿它当"绝不倒退"的依据） |
| 15 | 深度补偿该挂"**抖动乘子**"——官方有 `InterpolationDelayJitterScale = 1.25` | Entities `ClientTickRate`（全文） | **已做**（`_depth_comp` = 窗口展布 × **1.5**，上限 4） | 形态对、**系数是自定的**：来源给 1.25，我们给 1.5（1.5 是本仓实测选的，见 [`playout_clock.gd`](../../core/net/playout_clock.gd) 注释）——引用时别把 1.5 说成有出处 |
| 16 | 插值窗口太短会**静默**表现为异常（Entities 把症状都写出来了） | Entities `ClientTickRate`（全文） | **不适用**（我们只有一层副本，没有"分类进插值窗口"的机制） | —— |

---

## 10. 来源清单

**读了全文（正文 / 官方源码）**
- netfox 官方文档：`tutorials/interpolation-caveats.md`、`nodes/tick-interpolator.md`、`guides/network-time-synchronizer.md`、`tutorials/predicting-input.md`、`tutorials/input-gathering-tips-and-tricks.md`、`tutorials/rollback-caveats.md`、`guides/network-time.md`（均在 commit `74af631f`）
- Unity 官方文档：Entities 手册 [`time-synchronization.html`](https://docs.unity3d.com/Packages/com.unity.netcode@7.1/manual/time-synchronization.html)、Entities API [`ClientTickRate`](https://docs.unity3d.com/Packages/com.unity.netcode@7.1/api/Unity.Netcode.ClientTickRate.html)、[`ENetworkSmoothingMode`](https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/ENetworkSmoothingMode?application_version=5.6)、NGO API [`BufferedLinearInterpolatorQuaternion`](https://docs.unity.cn/Packages/com.unity.netcode.gameobjects@1.5/api/Unity.Netcode.BufferedLinearInterpolatorQuaternion.html)
- Epic 官方文档：[`UCharacterMovementComponent`（5.0 类页）](https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/GameFramework/UCharacterMovementComponent?application_version=5.0)
- Gaffer：[`Snapshot Interpolation`](https://www.gafferongames.com/post/snapshot_interpolation/)、[`State Synchronization`](https://www.gafferongames.com/post/state_synchronization/)、[`Deterministic Lockstep`](https://www.gafferongames.com/post/deterministic_lockstep/)、[`What Every Programmer Needs To Know…`](https://www.gafferongames.com/post/what_every_programmer_needs_to_know_about_game_networking/)、[文章索引](https://www.gafferongames.com/)
- Valve 官方仓库：`source-sdk-2013` 的 [`src/game/shared/usercmd.h`](https://cdn.jsdelivr.net/gh/ValveSoftware/source-sdk-2013@master/src/game/shared/usercmd.h)、[`src/game/client/c_baseentity.cpp`](https://cdn.jsdelivr.net/gh/ValveSoftware/source-sdk-2013@master/src/game/client/c_baseentity.cpp)
- id Software 官方仓库：Quake 3 的 [`code/client/cl_input.c`](https://cdn.jsdelivr.net/gh/id-Software/Quake-III-Arena@master/code/client/cl_input.c)、`code/client/cl_main.c`
- GGPO 官方仓库：`src/lib/ggpo/sync.cpp`、`input_queue.cpp`、`network/udp_msg.h`（`pond3r/ggpo@master`）
- Godot 官方文档源码：`doc/classes/@GlobalScope.xml`、`doc/classes/Vector2.xml`（`godot@4.4-stable`）
- [RFC 5905（NTPv4）](https://www.rfc-editor.org/rfc/rfc5905.txt)（grep `backward` / `slew` 全文件）

**只拿到片段 / 只有元数据**
- Unreal 源码**第三方镜像**（★ 非 Epic 托管）：`CharacterMovementComponent.h`（`NetworkMaxSmoothUpdateDistance` / `NetworkNoSmoothUpdateDistance` 注释）、`Private/Components/CharacterMovementComponent.cpp:385-386`（默认值 `256.f` / `384.f`）、`GameNetworkManager.h:100`、`Private/GameNetworkManager.cpp:21,156`（`3.0f` / `9.0f`）
- 第三方自动生成 wiki [`MAXPOSITIONERRORSQUARED`](https://indxzero.github.io/ue544cvarwiki/articles/maxpositionerrorsquared/)（**读了全文**，但它本身不是一手）
- Unity NGO 的 `.cs` 源码：**未读**（jsDelivr 对 `.cs` 返回 `application/octet-stream`，抓取工具拒收）

**取不到（逐个原因）**
- `developer.valvesoftware.com/wiki/Source_Multiplayer_Networking`（及 `Talk:Interpolation`）—— **Anubis v1.23.1 反爬**（返回 Proof-of-Work 页），本次实测重定向到 `/.within.website/?redir=…`
- `web.archive.org/web/2023id_/https://developer.valvesoftware.com/…` —— **`fetch failed`**（本机解析到非公网 IP，工具直接拒绝；前一份文档同样结论）
- `cl_interp` / `cl_interp_ratio` 的官方关系 —— **不存在于公开一手材料**：Valve 官方 SDK 里只有 `cl_interp_npcs` / `cl_interp_all` / `cl_interpolate`（§5）
- GDC Vault `play/1024001/…` 正文 —— **重定向到 `/play/1024001/contactUs`（需登录/付费）**；未找到任何 Blizzard 官方英文文稿
- `riotgames.com/en/news/peeking-valorants-netcode`、`/valorants-128-tick-servers` —— **curl 取不到**（`FAIL`，疑似反爬/超时），本次未能读到 Riot 官方工程博客正文
- `counter-strike.net/cs2`、`counter-strike.net/news/updates` —— **JS 空壳**（分别为 5.9 KB / 5.8 KB，无正文）；改用 Steam 官方 news API（`appid=730`，取最近 200 条）——**零命中 `sub-tick`**（该公告早于这 200 条）
- Epic 官方 API **子页**（`…/NetworkSmoothingMode`、`…/NetworkMaxSmoothUpdateDistance`）—— 返回 **JS 空壳**（只有 `Table of Contents`）⇒ 改用**官方类页**（读到两条描述）+ 源码第三方镜像（读到默认值）
- `MAXPOSITIONERRORSQUARED` 的 Epic 官方页 —— **不存在**（该宏未进官方 API 文档）⇒ 只能挂第三方 wiki 与源码镜像

## 11. 边界与未验证（照实）

1. 本文档是**来源调研**，不是方案设计；任何改动（`player_replica` / `playout_clock` / 输入协议）**都属联机承重面**，按 [`AGENTS.md`](../../AGENTS.md) 档 3 走。
2. Unreal 的两组阈值（256/384、3.0/9.0）本次**只有第三方镜像**读到的源码原文，**Epic 官方文档只给了描述、没给数值** ⇒ 数值可作形态参照，**不可**当成有官方出处的常数引用。
3. "冗余按丢包率定"这条**仍然没有一手公式**（§6.4）；"Overwatch 半个 RTT + 一帧"**仍然没有一手出处**（§5）。
4. ★ 顺手记录一处**源码内部注释漂移**：[`player_replica.gd`](../../scenes/player/player_replica.gd) 第 53 行与第 388–389 行都写 `PLAYOUT_TICKS = 3 tick = 50ms`，而常量本身是 **4**（[`playout_clock.gd`](../../core/net/playout_clock.gd) 的实例化处传的就是这个常量）⇒ 按真相源排序**以源码为准**；本文件未改动那两处注释（本次是纯调研）。
