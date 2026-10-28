# Minecraft 的复杂交互与预测边界

调研日期：2026-10-27。本轮阅读 Mojang 官方协议文档，并静态读取官方 Java 26.1 客户端归档中的关键方法；没有运行 Minecraft、本项目游戏或性能测试，没有修改模拟代码。

## 判断与证据范围

Minecraft 的方块、活塞、流体、红石、角色和载具有复杂依赖，但已公开或本轮核对的路径没有要求客户端为了修复一次局部预测，重演所有参与者和整个环境。

- **基岩版**明确提供本地玩家及受控载具的移动历史重放，同时用带输入 tick 的状态更新、局部方块校正和物品请求确认处理其他依赖。
- **Java 26.1**中核对到的方块预测是按坐标和操作序号结清的待确认状态。远端玩家采用插值；普通玩家位置校正路径直接设置位置和速度，不能把它称为基岩版式输入历史重放。
- **复杂环境不等于严格的客户端因果重算**。文档明确承认击退、活塞等交互存在时间认知差异，并提供校正容忍策略。

这些证据限定于相应版本和方法。不能由协议字段推断全部内部实现，也不能把 Java 与基岩版混成一种架构。

## 一手来源与版本

| 来源 | 本轮使用范围 |
|---|---|
| [Mojang：PlayerMovementOverview.md](https://github.com/Mojang/bedrock-protocol-docs/blob/main/additional_docs/PlayerMovementOverview.md) | 客户端移动历史、携带 tick 的外部状态、服务端比较、载具及物品使用的顺序 |
| [Mojang：CorrectPlayerMovePredictionPacket](https://mojang.github.io/bedrock-protocol-docs/latest/packets/correct-player-move-prediction-packet/) | 校正的对象类型、位置、速度、接地与输入 tick |
| [Mojang：SetActorMotionPacket](https://mojang.github.io/bedrock-protocol-docs/latest/packets/set-actor-motion-packet/) | 对本地玩家或受控载具施加权威速度及时间标记 |
| [Mojang：BlockBreakingOverview.md](https://github.com/Mojang/bedrock-protocol-docs/blob/main/additional_docs/BlockBreakingOverview.md) | 方块破坏预测、物品耐久确认、与移动输入绑定的处理顺序 |
| [Mojang：Build action simulation rate](https://mojang.github.io/bedrock-protocol-docs/guides/build-action-simulation-rate/) | 固定模拟步处理方块动作、积累及合并渲染采样 |
| [Microsoft：Bedrock Dedicated Server Properties](https://learn.microsoft.com/en-us/minecraft/creator/documents/bedrockserver/server-properties?view=minecraft-bedrock-stable) | 活塞、击退造成的差异容忍；移动、下车和实体交互的严格度选项 |
| [Mojang：Movement protocol deprecation](https://mojang.github.io/bedrock-protocol-docs/guides/movement-protocol-deprecation/) | 旧客户端权威协议迁移到 ServerAuthoritativeV3 的范围 |
| [Java 26.1 官方版本元数据](https://piston-meta.mojang.com/v1/packages/b85db8efa37dc2e9d5cb12ee324a42d22fd98c08/26.1.json)、[官方客户端归档](https://piston-data.mojang.com/v1/objects/191771837687b766537a8c4607cb6fad79c533a1/client.jar) | 本轮使用 javap 静态读取的原始实现，不使用第三方复刻替代原版 |

Java 26.1 发布于 2026-03-24；本轮选取它作为固定审阅版本，不称它为最新版。归档大小为 38,113,398 字节，SHA-1 为 `191771837687b766537a8c4607cb6fad79c533a1`，下载后与官方元数据一致。

读取时基岩版协议门户标示 `1.26.70-beta.21`、协议 `2238`、2026-10-20。其中指南保留旧协议迁移背景和功能开关分支，不能把指南历史配置示例视作全部现行版本的默认配置。网页渲染的移动指南未展示完整后半段，本轮同时阅读了官方仓库 Markdown 原文。

[基岩版 1.21.70 官方更新说明](https://feedback.minecraft.net/hc/en-us/articles/35256043330189-Minecraft-Bedrock-Edition-1-21-70-Spring-to-Life)已注明移除旧 `server-authoritative-movement` 参数、统一使用 `server-auth-with-rewind`。这与旧指南中“默认关闭”的历史表述需分开理解。

## 基岩版：把外部影响接入本地移动时间线

### 本地移动与受控载具

官方移动指南描述：客户端发送输入、预测位置和输入 tick；服务器按该输入推进相应玩家并比较结果，必要时返回同 tick 校正。客户端恢复该玩家的移动历史、应用校正，再重放后续预测。骑乘受客户端预测的马或船时，对照和校正针对载具。

保存范围被描述为移动相关数据。指南没有要求为一次玩家移动校正回滚所有生物、其他玩家、红石及整张地图。它也没有公开内部所有碰撞历史的存储方式，不能据此声称外部世界的每个历史几何都被精确还原。

### 影响运动的外部状态也有时间归属

`PlayerInputTick` 对应服务器最近处理的该玩家输入，并非本项目共享的全局服务器 tick。权威速度包对本地玩家或受控载具也携带这个时间标记。移动指南把角色数据和属性更新列为可进入移动历史的状态，举了潜行状态迟到及未知击退的例子。

这使客户端可以修复“过去的本地运动受到什么影响”，而不必重新推导“谁在过去完整执行了什么攻击”。超出历史窗口的更新可以立即应用，不再无限延长历史。

指南并未证明客户端对每个相同值更新都做无效操作剪枝；其潜行示例甚至包含设置相同值后重放的说明。因此不能把它作为“每条相关消息都先比较并完全跳过重放”的实现证据。

### 对环境时间差采用容忍与校正

Microsoft 的服务器属性文档明确以**受击击退、活塞推动**为例解释：两端对运动起始时间的认知可能不同，轻微位置差异不应导致过多校正。严格移动、下车和实体交互也有单独选项。

移动指南另说明服务端使用阈值，避免微小误差或第一条校正尚未有机会生效时继续发送校正。这体现对误差与交互体验的取舍，没有给出全局因果依赖图。具体容忍值不能直接照搬到本项目的横版碰撞和战斗规则。

## 基岩版：方块和物品分别确认

启用服务端权威挖掘时，客户端可先表现方块消失、挥动与工具耐久变化，服务器验证操作并按需要校正方块和物品。耐久请求使用稀疏预测容器：接受后提交到底层容器，拒绝则丢弃预测。

顺序敏感的方块动作、物品操作与移动输入合并进 `PlayerAuthInputPacket`，延后统一消费；指南对同帧挖掘验证的说明明确依赖可靠有序收包。这里不能跨用到 GNS 不同 lane 的到达顺序上。

这套分工支持即时本地反馈和局部确认，没有要求客户端重演整条环境连锁反应。指南同时保留创造模式等例外，不能概括成所有方块操作都完全由服务器按射线重算。

## 方块动作怎样与表现解耦

[Build action simulation rate](https://mojang.github.io/bedrock-protocol-docs/guides/build-action-simulation-rate/)讨论高速飞行时连续挖掘、搭建：它把渐进方块逻辑及计时器放到固定模拟步；渲染帧仍可采集光标命中的 `HitResult`，积累到下一模拟步消费，并合并同一方块上的重复结果。

其目的既包括不漏过两个模拟步之间扫过的方块，也包括避免客户端在渲染帧提前开始冷却、服务器却只能按模拟步计时。这是明确的“采样频率可以不同，规则推进和输入归属必须清楚”的案例，并非通过增加世界重放来补偿表现层时序。

## Java 26.1：实际核对的局部预测路径

以下来自官方归档的静态字节码阅读，不是根据玩家观感反推实现。审阅输出保存在工作区 `work/minecraft_research_20261027/`，未将归档或反编译结果加入项目源码。

### 方块预测记录按坐标保存

`BlockStatePredictionHandler` 保存按 `BlockPos` 索引的 `ServerVerifiedState`，包含操作序号、已知服务器方块状态及预测时的本地玩家位置。

1. `MultiPlayerGameMode.startPrediction()` 分配操作序号，执行局部预测并发送请求。
2. `ClientLevel.setBlock()` 在预测期间修改客户端方块，同时保留已知服务器状态；同坐标后续预测会推进该记录的序号。
3. `setServerVerifiedBlockState()` 遇到待确认方块时更新记录中的服务器值；没有对应预测时直接更新方块。
4. 方块 ACK 进入 `endPredictionsUpTo(n)`，结清序号不大于 `n` 的记录，把保存的服务器值交给 `syncBlockState()`。

**ACK 本身是处理到哪个操作序号的确认，不包含挖掘成功/失败布尔值。** 最终方块值来自记录中的已知服务器状态；如果没有更新，它仍可能是预测前保留的值。不能把 ACK 简化成“确认就保留客户端猜测”。

### 恢复方块后，只在必要时处理本地角色

`ClientLevel.syncBlockState()` 先比较当前方块与保存的服务器值；相同则不改。需要恢复时更新该方块；如果保存位置有效、玩家仍在该世界，且恢复后的方块与本地玩家相交，则直接调用 `absSnapTo()` 拉回保存位置。

此方法没有进入整段输入历史或所有角色重放。`BlockStatePredictionHandler.onTeleport()` 还记录序号屏障：ACK 序号不晚于最近传送标记时，不再向上述恢复传入旧玩家位置。它没有为消除所有视觉跳变建立完整因果图。

这也是一个明确的代价：少算很多关联逻辑，但某些失败预测通过直接位置修复解决。本项目是否接受相同行为，需要按平台跳跃和竞技体验判断。

### 远端玩家、红石、流体具有不同执行边界

| 核对方法 | 直接证据 | 能支持的判断 |
|---|---|---|
| `RemotePlayer` 构造与 `aiStep()` | 设置 `noPhysics`；推进位置、头部及速度插值 | 远端玩家没有作为本地输入预测角色完整重算；不表示它没有碰撞箱或不会被查询 |
| `LocalPlayer.sendPosition()`、服务器 `handleMovePlayer()` | 上报位置/方向；服务器检查速度、移动结果与碰撞，必要时校正 | Java 这条路径与基岩版发送输入后由服务器复算的描述不同 |
| 客户端 `handleMovePlayer()`、`setValuesFromPositionPacket()` | 应用位置/速度/方向，发送传送确认与当前位置，并标记方块预测的传送屏障 | 这里没有基岩版式的输入队列恢复重放 |
| `RedStoneWireBlock.neighborChanged()` | 客户端世界直接返回，服务器才推进相应更新 | 客户端不会为本地一次误预测重新运行该红石传播路径 |
| `FlowingFluid.tick(ServerLevel, ...)` | 流体推进明确以服务器世界为参数 | 不能因为客户端呈现流体，就认为它也重放流体的权威扩散逻辑 |

这些事实不等于客户端什么都不计算。碰撞查询、实体插值、流体表现以及局部交互仍有工作；区别在于它们不被统一纳入每次预测修复的全世界重演。

### 静态阅读位置

以下行号属于本轮保存的 javap 文本，便于复查，不是 Mojang 原始 Java 文件行号：

- `BlockStatePredictionHandler.javap.txt`：全部 161 行，特别是 `endPredictionsUpTo()` 与 `onTeleport()`。
- `ClientLevel.javap.txt`：61 行起的 ACK 处理；103 行起的服务器方块更新；120 行起的 `syncBlockState()`。
- `ClientPacketListener.javap.txt`：1320 行起的玩家位置校正；6423 行起的方块 ACK。
- `ServerGamePacketListenerImpl.javap.txt`：2825 行起的玩家移动处理；4329 行起的 ACK 序号合并；166 行起的 ACK 发送。
- `RemotePlayer.javap.txt`：构造与 `aiStep()`。
- `RedStoneWireBlock.javap.txt`：891 行起的邻居变更处理。
- `FlowingFluid.javap.txt`：1114 行起的流体推进。

## 对本项目的含义

以下是设计推论，尚未实现或测试。

1. **先界定客户端预测什么。** 需要即时响应的本地移动、开火和必要地形反馈，可以与完整远端战斗、其他角色资源和环境连锁结算分开；交互复杂本身不证明后者必须全部预测。
2. **外部影响可以作为本地模拟的权威输入。** 击退、移动限制、支撑变化等应带明确生效时间与版本；本地不一定需要重跑造成该结果的所有上游攻击者。仍须检查后续路径是否真的失效。
3. **地形采用权威基础加局部待确认变更，是可考虑的边界。** 已确认操作结清对应记录；失败操作撤销相关变更，再处理确受影响的本地历史。一次远处方块更新不应仅因“世界改变了”就必然触发全部角色重放。
4. **阻挡依赖依然要正确。** 远端角色或变化地形若参加本地预测碰撞，需要明确使用哪个时间的状态。Minecraft 的容忍、直接拉回与有限预测是取舍，不能证明“删除远端步进但继续用当前完整战斗逻辑”必然正确。
5. **采用 GNS 时显式保证语义顺序。** 本项目需要自己的 tick、epoch、地形版本与事件屏障；Minecraft 合包及可靠有序协议的前提不能自动迁移。

综合本轮与 [LoL / CS:GO 调研](lol_cs_prediction_boundaries.md)，更值得优先评估的是预测职责和确认边界，再决定哪些残留依赖值得做[选择性重放](selective_replay_research.md)。这些资料没有提供本项目卡顿的测量证据，也不能替代后续实现的正确性与性能验证。
