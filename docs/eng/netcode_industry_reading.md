# 大型游戏联机技术资料：扩展阅读与实现取舍

阅读日期：2026-10-24。项目背景：`siri_v0.5.0` 的服务端权威、八人硬阻挡、强击退、可破坏地形和 Beta 时间玩法。

本文记录资料阅读阶段；后续代码实施与检查边界见[联机重构说明](netcode_refactor.md)。

本文最初记录只查资料、阅读源码和整理方案的阶段；后续补充按日期单列。本文补充[源码审计](netcode_source_audit.md)，不将资料阅读当成项目缺陷已复现或优化已验收。

资料优先采用开发者本人发布的 GDC 讲义、游戏公司技术文章和引擎官方文档。年代描述的是资料对应的实现，不据此断言这些游戏在 2026 年仍采用完全相同的架构。讲座阅读以可访问讲义及讲者备注为依据；没有获得录像正文的条目单独列在文末。

## 1. 阅读后对方案的主要调整

1. **把比较历史和恢复检查点分开设计。** 每 tick 需要可追溯的必要状态与事件，但完整检查点的保存频率需要权衡恢复成本、内存和重算量。全量保存、只保存确认帧和额外中间检查点分别有代价。
2. **先定义一次交互所需的最小完整状态。** 角色运动、武器后坐力、账户与命中结果存在依赖；音画、计分显示和无交互对象不必因为同处一个场景就全部重放。
3. **把对象生命周期作为回滚协议的一部分。** 出生、确认、结束、撤销与最终释放不能只依赖当前节点是否存在。窗口内保留逻辑状态或复用对象是值得评估的优化。
4. **时间、输入到达顺序和场景外部查询都是潜在输入。** 固定步长只解决其中一部分；模拟预算不足时按墙钟随意退出角色循环，也会改变结果。
5. **缓存要覆盖正确的层级。** 客户端预测后缀复用、服务器复制列表共享、编码状态缓存是不同机制，不能用其中一个替代另外两个。

以上是结合资料与本项目源码作出的推论，具体实现和收益尚未验证。

## 2. 优先精读的讲座讲义

### 2.1 NetherRealm：8 Frames in 16ms

Michael Stallone，NetherRealm Studios，GDC 2018。主题是《Mortal Kombat》和《Injustice 2》的回滚改造。[原始讲义](https://media.gdcvault.com/gdc2018/presentations/Stallone_Michael_8FramesIn16ms.pdf)。

重点页码为 PDF 第 19–22、34–38、45、55–62 页：

- 用环形缓冲保存可变状态，并记录对象创建和销毁；恢复后的引用修正有独立成本。
- 比较窗口内延迟删除与删除后重建；声音、粒子等可以通过身份匹配复用。
- 将与玩法无关的工作移出重放，减少重复轮询、分配和稀疏列表遍历。
- 第 45 页只保存确认帧的方案降低最坏情况保存成本，却增加平均重算；第 57 页再引入少量额外检查点。
- 第 55 页报告了预测领先、持续最大回滚和性能之间的反馈问题。

**对本项目的推论**：`CombatPrediction._make_bullet/prepare/_plan` 的节点创建、释放与弹丸身份值得先审计；历史缓冲应同时考虑保存成本和重算成本。该讲座是 1v1、严格确定性的输入同步，不能直接套用它的网络模型或检查点间隔。

### 2.2 Ubisoft：Back to the Future! Working with Deterministic Simulation in For Honor

Jennifer Henry，Ubisoft Montreal，GDC 2019。[原始讲义](https://media.gdcvault.com/gdc2019/presentations/Henry_Jennifer_BackToTheFuture.pdf)。

重点为 PDF 第 11–14、28、30–40、44–50 页：

- 明确区分需要确定性的玩法和表现；浮点、物理、并发、时间、动态生成都需处理。
- 为一帧内多次玩法步进安排 Prepare、Simulation 和 Finalize 阶段。
- 通过阶段性移出模拟、休眠、降低非关键 AI 更新频率及简化求解降低成本。
- 状态访问约束和自动生成的数据描述帮助避免遗漏。

**对本项目的推论**：重放入口应有明确阶段和状态读写契约。先保留八人硬阻挡依赖，再考虑减少参与对象；直接跳过远端玩法分支或并行执行有先后依赖的角色移动，可能改变结果。

讲座介绍的是非权威确定性模拟。本文不从这一点推断其当前部署拓扑，也不建议改变本项目的服务器权威。

### 2.3 Blizzard：Networking Scripted Weapons and Abilities in Overwatch

Dan Reed，Blizzard Entertainment，GDC 2017。[原始讲义](https://media.gdcvault.com/gdc2017/Presentations/Reed_Dan_NetworkingScriptedWeapons.pdf)。

重点为 PDF 第 21–25、43–47、51–60、63–66 页：

- Statescript 以 Command Frame 驱动，变量、状态与动作有同步、恢复接口。
- 本地实例保存输入及预测，恢复后重新模拟；远端实例走复制路径。
- 第 60 页明确列出历史范围：本地脚本状态、输入与瞄准、实体位置与姿态；并未保存所有远端脚本或其他组件数据。
- 复制负载按本地/远端所需字段分别构建，保留确认范围。

**对本项目的推论**：应明确“哪些远端状态影响本地硬阻挡”，为这些状态提供可重放的等价输入和规则。它不支持“所有大型游戏都会完整模拟所有远端武器、HP 和死亡”的说法；也不能据此忽略本项目特有的交互依赖。

### 2.4 Bungie：Shared World Shooter: Destiny's Networked Mission Architecture

Justin Truman，Bungie，GDC 2015。[含讲者备注的原始讲义](https://media.gdcvault.com/gdc2015/presentations/Truman_Justin_Shared_World_Shooter.pdf)。

重点为 PDF 第 31–38、60–77、80–90 页：

- Bubble 限定一次自主模拟、资源加载和匹配的范围。
- 主机迁移可能把分别复制的状态拼成不满足脚本约束的组合。
- Activity State 提取任务脚本所需的最小状态，并在 Activity Host 上原子协调；完整物理实体仍是另一层。

**对本项目的推论**：应先列出命中、死亡、碰撞、账户和地形之间必须共同成立的约束，再确定恢复单元。这里的“最小完整”指依赖范围完整，并非备份整个场景树；该混合主机架构也不能直接作为本项目传输方案。

### 2.5 Psyonix：It IS Rocket Science! The Physics of Rocket League

Jared Cone，Psyonix，GDC 2018。[原始讲义](https://media.gdcvault.com/gdc2018/presentations/Cone_Jared_It_Is_Rocket.pdf)。

复核重点为 PDF 第 133–138、155–177 页：输入缓冲与调速、对应历史帧比较、相互作用物理实体的恢复与追赶，以及未知车辆操作和重放成本的限制。

**对本项目的推论**：硬阻挡和击退需要一致的模拟时间。本地预测碰撞体与远端插值画面的职责应继续分开；同输入实现分歧与未知操作引起的预测误差也应分别处理。

## 3. Riot 的确定性与服务器工程报告

### 3.1 League of Legends：Implementation

Riot Games，2017-06-20。[正文](https://www.riotgames.com/en/news/determinism-league-legends-implementation)。重点阅读 Identifying Inputs、Recording Inputs、Taking Control of Inputs。

文章以可重复的服务器玩法状态为目标，记录按帧到达的输入、启动配置等不可控信息，并隔离底层连接状态。其当时实现保留可变帧间隔并记录时间，说明确定性不能简单等同于固定步长。

**推论**：本项目夹具还需保存实际调度顺序和外部状态。`target_tick`、实际可用 tick 和本地收到提示的时间具有不同含义；本项目现有固定 60 Hz 可以保留。

### 3.2 League of Legends：Unified Clock

Rick Hoskinson，Riot Games，2017-10-10。[正文](https://www.riotgames.com/en/news/determinism-league-legends-unified-clock)。重点为 Problems in LoL Time APIs、API Design 与时钟实例设计。

报告分析多种时钟实现、不同时间域和浮点累计误差，建立统一接口，并区分帧开始时间与即时采样。

**推论**：武器、引信、账户和角色计时都应消费重放 tick 的时间；性能计时和重连超时可以使用墙钟，但不应改变同一 tick 内执行哪些玩法工作。现有连续预测时钟不应因新增历史缓存而重新引入时间戳跳变。

### 3.3 League of Legends：Fixing Divergences

Rick Hoskinson，Riot Games，2018-05-01。[正文](https://www.riotgames.com/en/news/determinism-league-legends-fixing-divergences)。重点为 Detecting Divergences 与 Case Study。

文章使用分层字段日志定位第一个分歧，而非只比较总校验和；案例追溯到了网络 LOD 中的未初始化值，最后污染路径和技能目标。

**推论**：后续诊断应输出最早变化的 tick、阶段、角色和字段。网络相关性及表现状态也需要防止反向影响玩法；只比较最终位置无法确定根因。本文仅学习该方法，没有运行它描述的测试流程。

### 3.4 VALORANT：Peeking into VALORANT's Netcode

Matt deWet、David Straily，Riot Games，2020-07-28。[正文](https://www.riotgames.com/en/news/peeking-valorants-netcode)。重点为 Buffering Incoming Data、Minimizing Simulation Divergence。

报告将移动预测、固定步长、客户端呈现和服务端战斗裁决区分开，并把输入收取到输出之间的处理等待计入延迟。

**推论**：本项目应分别观察收包、应用、重放和画面输出；低 RTT 不能单独证明处理链路没有延迟。射击者的历史命中查询与受击者的当前运动状态也需要明确契约。

### 3.5 VALORANT：How We Got to the Best-Performing Servers Since Launch

Aaron Cheney，Riot Games，2023-03-09。[正文](https://playvalorant.com/en-us/news/dev/how-we-got-to-the-best-performing-valorant-servers-since-launch/)。重点为 Server Performance Targets、Fixing the Degradation。

案例中，一次引擎升级使属性比较被过度触发，成本随连接数非线性增长；团队通过版本与调用频率对照找到根因。报告还为操作系统调度和多实例部署保留帧预算余量。

**推论**：审查本项目逐连接重复比较世界、复制和排序的次数，不能只看单次函数耗时；客户端的完整 16.7 ms 也不能全部分配给重放。文中性能数字不代表本项目可获得相同比例收益。

## 4. Epic 的大规模复制与物理预测文档

### 4.1 Fortnite 的专用服务器优化

Nick Penwarden，Epic Games，2017-10-04。[Unreal Engine Improvements for Fortnite: Battle Royale](https://www.unrealengine.com/tech-blog/unreal-engine-improvements-for-fortnite-battle-royale)。重点为 Dedicated Server Performance。

报告记录了合批连接 RPC、限制移动上行频率、减少分配与字符串比较、按相关性减少复制等改动。

**推论**：本项目可以共享同一服务器 tick 的状态收集与编码准备，再保留逐连接基线差异。文中的频率、人数和更新批量都是当时项目参数，不能直接作为当前配置。

### 4.2 Replication Graph

Epic Games，2018-12-05。[Replication Graph overview and proper replication methods](https://www.unrealengine.com/tech-blog/replication-graph-overview-and-proper-replication-methods)。

其主要方法是使用持续存在的节点、空间列表和跨连接共享数据，减少每帧逐实体逐连接重复判断。

**推论**：将来扩大人数时可建立相关性索引。复制相关性与回滚依赖不是同一列表：一个对象即使暂时不可见，仍可能通过碰撞或爆炸影响本地角色。

### 4.3 Iris：复制状态与玩法对象解耦

[Introduction to Iris](https://dev.epicgames.com/documentation/unreal-engine/introduction-to-iris-in-unreal-engine)，本次访问为 UE 5.8 文档。重点为 Design、Pre-Send Update、Send Update。

Iris 保存独立复制状态、共享类型描述，分离状态变更准备和逐连接发送，并按优先级与依赖调度。

**推论**：本项目可借鉴独立、不可变的网络帧和共享描述，减少嵌套字典反复遍历。它是复制管线设计，不能直接代替预测历史；网络量化若重新参与物理，还需单独满足双端一致性。

文档访问时标记该系统为 Experimental；本文不依据版本名称推断其产品部署情况。

### 4.4 Networked Physics：历史比较与按需重模拟

[Networked Physics Overview](https://dev.epicgames.com/documentation/en-us/unreal-engine/networked-physics-overview)，本次访问为 UE 5.8 文档。重点为 Predictive Interpolation、Resimulation。

Resimulation 保存物理历史，对应帧状态出现足够差异时恢复和重算，渲染再平滑；文档同时说明不同复制模式有不同性能和交互取舍。

**推论**：支持为本项目建立同 tick 比较与条件重算，但不能只比较位置。武器、账户、角色接触和地形改变都可能使缓存后缀失效；混合模式也不意味着可以把任意插值对象直接放进预测碰撞。

### 4.5 Gameplay Ability 的预测身份和副作用

[FPredictionKey](https://dev.epicgames.com/documentation/en-us/unreal-engine/API/Plugins/GameplayAbilities/FPredictionKey)，重点为 Prediction Key、Ability Activation、GameplayEffect Prediction、Attribute Prediction。

文档分别处理预测失败撤销、权威回传去重、属性基值覆盖和依赖；Key 的确认范围及预测窗口均有限制。

**推论**：本项目的攻击、单个受击者、账户交易和地形变化应有明确身份与确认范围。ACK 输入不等于确认全部副作用；这一能力系统也不是跨任意 tick 的通用物理回滚器。

## 5. 其他大型射击游戏的边界说明

### 5.1 Respawn：What Makes Apex Tick

Apex Legends 首席工程师 Ricklesauceur 的[官方深度报告](https://www.ea.com/games/battlefield/news/servers-netcode-developer-deep-dive)。重点为 slow motion、RPROF、hit registration 和 tickrate 章节；该文章讨论 Legacy 赛季时期实现。

报告既有网络问题，也有服务器负载与非点状弹丸计算缺陷；还举出不可见的重叠出生角色触发物理尖峰的案例。

**推论**：不可见不代表无模拟成本。候选体顺序、弹丸尺寸和出生/恢复后的碰撞状态应单独审计，不能用平均 RTT 排除这类分歧；提高 tick 率也会增加处理量和带宽。

### 5.2 343：Halo Infinite 的旧模型与后续更换

Richard Watson 的[Online Experience](https://www.halowaypoint.com/news/closer-look-halo-infinite-online-experience)讨论历史命中查询、输入缓冲和处理等待；后续[March Update Preview](https://www.halowaypoint.com/news/march-update-preview)明确宣布更换网络模型。

**推论**：受害者收到伤害晚、模拟本身错误和发送状态不足需要分开处理。旧文章不能证明当前 Halo 的全部内部规则；公告也没有公开足以照搬的新模型细节。

## 6. MMO 的扩容方法与本项目的关系

### 6.1 CCP：EVE Online 的 Time Dilation

CCP Veritas，2011-04-22，[Introducing Time Dilation](https://www.eveonline.com/news/view/introducing-time-dilation-tidi)。

文章讨论服务器过载时任务等待队列和模拟时钟的关系，以减慢游戏时间控制负载；并说明有些长期计时应继续使用现实时间。

**推论**：需要观察等待队列和计算成本两部分。但这是明确的玩法降级策略，本项目的 Beta 加速/回溯是权威玩法状态，不应被用来让各客户端自行补偿 CPU 不足。

### 6.2 ArenaNet：Guild Wars 2 的 Megaserver 与事故报告

[Introducing the Megaserver System](https://www.guildwars2.com/en-gb/news/introducing-the-megaserver-system/)介绍 2014 年的动态地图副本与玩家分配；Robert Neckorcuk 的[Live Game Outage Analysis](https://www.guildwars2.com/en-gb/news/inside-arenanet-live-game-outage-analysis/)复盘 2020 年数据库事件。

前者处理人口与地图实例，后者强调队列增长、环境规模和实际恢复路径。

**推论**：可用于将来房间调度、部署和运维设计；它们不直接解释当前一次角色预测的恢复字段与碰撞时序。

## 7. 与源码审计对照后的改造优先级

| 优先级 | 本项目入口 | 根据资料细化的工作 | 关键边界 |
|---|---|---|---|
| P0 | `ActorStep`、`PlayerReplica`、`AuthorityWorld` | 声明参与硬阻挡的运动驱动状态；统一已知输入下的规则与 tick 阶段 | 完整的是依赖范围，不要求所有远端表现和无关组件全量重演 |
| P0 | `CombatPrediction`、`TimeEconomy`、地形 | 为命中、收益、弹丸出生/结束和破坏定义身份、时点及撤销规则 | 一个受击者确认不覆盖其他受击者；移动 ACK 不覆盖所有副作用 |
| P1 | `PvpMatchClient._apply_authority` | 在破坏当前整组预测状态前完成历史有效性判断 | 不能只在本地 `reconcile` 提前返回，留下已回滚的远端角色 |
| P1 | `PredictionRollback` | 对照必要字段的逐 tick 历史，并选择恢复检查点策略 | 保存和比较也占 CPU；只保存确认帧可能增加平均重算量 |
| P1 | `_make_bullet/prepare/_plan` | 分开弹丸身份、出生 tick、检查点 tick 和节点资源；评估窗口内保留或复用 | 逻辑结束的弹丸不能因节点保留而重新参与接触 |
| P2 | 重放循环、攻击/输入集合 | 去除每角色每 tick 重复准备、排序和分配，保持必要查询 | 移出表现工作之前要证明玩法不依赖其结果 |
| P2 | `NetCodec`、状态收集与发送 | 尽量让一帧的公共计算只做一次，再应用逐连接差异 | 共享计算、预测缓存和有序事件是三套不同契约 |
| P3 | 扩容后的相关性与部署 | 使用空间/玩法相关性、休眠和房间实例调度 | 对象进入预测依赖范围时需要完整基线和时间对齐 |

### 7.1 历史结构应比较三种候选

| 候选 | 收益 | 成本或限制 |
|---|---|---|
| 每个完整 tick 保存完整预测组检查点 | 可直接回到精确 tick，便于比较 | 保存、复制和内存成本最高；地形宜使用日志/分块结构 |
| 只保存权威/确认锚点 | 保存量小 | 新信息经常迫使从较早位置重算，可能放大平均工作量 |
| 必要的逐 tick 比较数据与事件日志，结合少量完整检查点 | 可控制备份成本及最远重算距离 | 要明确检查点覆盖的依赖和失效条件，实现更复杂 |

这些只是设计候选。NetherRealm 的报告支持检查点策略值得权衡，Source 的[预测源码](https://github.com/ValveSoftware/source-sdk-2013/blob/master/src/game/client/prediction.cpp)支持无误差时复用后缀；两者不能混为“只要新增缓存就会更快”。

### 7.2 后续实现所需的最小契约

- **时间契约**：模拟 tick/阶段、真实时间和表现时间有各自的用途。
- **状态契约**：所有会影响下一次玩法分支的状态均可恢复，外部查询的时间和环境版本明确。
- **输入契约**：持续值、动作、到达时点、实际可用 tick 和确认范围可追溯。
- **生命周期契约**：出生、匹配、拒绝、结束、回滚撤销及最终释放各有明确条件。
- **复用契约**：新输入、碰撞依赖、战斗、账户和地形变化使对应历史后缀失效。
- **表现契约**：被重复模拟的玩法不重复执行不可撤销的音画与外部副作用。

## 8. 访问状态与本地阅读材料

以下两份公开原始 PDF 已下载至 `.test_logs/research_sources/`，提取相关章节并渲染检查关键页。目录为阅读缓存，不作为游戏发布资源：

| 资料 | 页数 | SHA256 |
|---|---:|---|
| `rollback_8_frames_gdc2018.pdf` | 65 | `13ea6c38e5204bb7f806c49a1624496b65a8dd828fc4d399c0c83a93c49ba210` |
| `destiny_mission_gdc2015.pdf` | 133 | `819da00d37968cb904ab90185adb90769082a41cafc262394764419f5394e108` |

讲义页码均按 PDF 文件物理页序，从 1 开始；Destiny 的文档包含讲者备注，不能把单张幻灯片上的短句当作完整设计说明。

下列条目只核对了官方目录/摘要，未获得足以支持细节判断的正文，不能声称已看完讲座：

- [Timothy Ford：Overwatch Gameplay Architecture and Netcode，GDC 2017](https://www.gdcvault.com/play/1024001/-Overwatch-Gameplay-Architecture-and)：目录和摘要确认，访问录像正文受当日页面状态限制。
- [Bradley Pollard：Cross-Platform Determinism in Warhammer Age of Sigmar: Realms of Ruin，GDC 2024](https://gdcvault.com/play/1034321/Cross-Platform-Determinism-in-Warhammer)：官方摘要确认；公开 PDF 链接下载返回 403，本文未采用其实现细节。
- [David Aldridge：I Shot You First: Networking the Gameplay of Halo: Reach，GDC 2011](https://www.gdcvault.com/play/1014346/I-Shot-You-First-Networking)：官方目录确认，本文未用二手转述替代讲座正文。

## 9. 最初资料阅读阶段的边界

最初资料补充形成了更具体的架构选择和源码改造顺序。当时已有审计发现仍是静态代码结论或待验证推论，没有新增实测，也没有宣称性能问题已经解决。此后实施和实测分别记录于重构说明与测试结果，不回写为资料本身的结论。

## 10. 2026-10-25：减少重放工作，而非继续扩大查询结果缓存

### 10.1 Unity：保留有效备份与交互时间线

精读 [Netcode for Entities 1.5.1 优化文档](https://docs.unity3d.com/Packages/com.unity.netcode@1.5/manual/optimizations.html)的 prediction、structural changes、serialization cost 章节。文档讨论复用有效预测备份、降低重复调度和序列化成本，也明确说明结构变化后保留备份可能产生的状态恢复差异。因此，不能把“少做重放”实现为无条件保留旧状态。

[Prediction edge cases](https://docs.unity3d.com/Packages/com.unity.netcode@1.5/manual/prediction-details.html)用 A/B 回退至 tick 10、C/D 留在 tick 20 的例子说明：只重放部分实体时，碰撞会遇到处于另一时间线的冻结对象；`GhostGroup` 可以使有依赖的实体共同更新。

Unity 团队 [2026-05-14 DevLog Entry 4](https://discussions.unity.com/t/prediction-in-gameobject-netcode-devlog-entry-4/1719927)进一步讨论整组回退、预测范围切换及相等检查跳过重放。其“快照足够相等时跳过重放”等内容以当时的开发计划表述，不能据此宣称已在所有版本交付。该文也报告其测试中系统调度的占比，不能直接推断 Godot/GDScript 的开销结构。

**本项目应用**：保持交互角色、弹丸和账户在同一 tick；在权威锚点完全一致时，逐 tick 重建命令，保留首个不同命令之前的整组检查点。新可靠事件和不同的回溯阻挡轨迹同样截断前缀。没有采用模糊位置阈值，也没有跳过可能参与交互的远端角色。

### 10.2 Valve：选择第一条必须重新执行的命令

再次核对 [Source `ComputeFirstCommandToExecute`](https://github.com/ValveSoftware/source-sdk-2013/blob/master/src/game/client/prediction.cpp#L1329)。实现会恢复已预测结果、推进历史槽位，在符合确认与误差条件时跳过已完成的命令。它复用的是预测状态，不是碰撞查询结果；本项目的“完整锚点验证 + 命令前缀 + 整组检查点”是结合自身依赖作出的实现，不是照搬 Source 的实体模型。

此前本项目只支持整个 STATE 后缀全部等价时复用；任一命令变化便退回权威锚点。本次增加 STATE 与新输入同批到达时的前缀复用，并提交前缀的新 ACK 游标。部分复用不能安装已经消费了首条错误命令的临时队列，必须从前缀检查点重建后续输入。

### 10.3 Riot：先确认重复工作从哪里触发

[VALORANT's 128-Tick Servers](https://www.riotgames.com/en/news/valorants-128-tick-servers)说明分系统计时和可复现负载的重要性；[2022 年服务器性能报告](https://playvalorant.com/en-us/news/dev/how-we-got-to-the-best-performing-valorant-servers-since-launch/)记录了 UE 升级后重复触发属性比较的案例，连接数上升时退化更加明显。

**本项目应用**：为复用失败按完整状态字段、角色集合、地形版本、弹丸、账户、命令或事件分类记录。新增 `reuse_counts`（日志区间计数）、`reuse_totals`（累计完整/前缀复用次数、跳过 tick、前缀路径重放 tick），避免把缓存命中率当作 CPU 收益。首个拒绝原因只说明检查在哪里停止，不代表该条件是唯一差异。

### 10.4 PhysX：局部几何缓存仍是另一层优化

[PhysX CCT 几何缓存](https://nvidia-omniverse.github.io/PhysX/physx/5.4.1/docs/CharacterControllers.html#invalidating-internal-geometry-caches)保留运动包围盒附近的几何候选，移动仍执行碰撞计算。它与本项目完整运动结果的哈希缓存不同。局部候选收集需要接入具体碰撞实现，不能仅在脚本外包一层字典就获得相同算法。

本次没有扩大完整查询缓存，也没有证明它优于局部几何缓存；优先减少不必执行的模拟 tick。是否保留该缓存及其实际 CPU 收益，仍需要同负载开关对照，既有命中率不构成这项证据。八人运行结果另记于[实测记录](netcode_test_results.md)。
