# 游戏公司联机技术资料

## 资料与可参考部分

| 资料 | 可参考部分及适用边界 |
|---|---|
| NetherRealm，Michael Stallone，GDC 2018：[8 Frames in 16ms](https://media.gdcvault.com/gdc2018/presentations/Stallone_Michael_8FramesIn16ms.pdf) | 可恢复状态、检查点环、对象创建/销毁和表现副作用管理；在保存成本与重算成本间取舍。背景是格斗游戏，不能直接推出八人游戏必须重放全部世界 |
| Ubisoft，Jennifer Henry，GDC 2019：[Back to the Future! For Honor](https://media.gdcvault.com/gdc2019/presentations/Henry_Jennifer_BackToTheFuture.pdf) | Prepare / Simulation / Finalize，显式时间、随机、物理和生命周期依赖，排除不参与玩法的工作 |
| Blizzard，Dan Reed，GDC 2017：[Networking Scripted Weapons and Abilities in Overwatch](https://media.gdcvault.com/gdc2017/Presentations/Reed_Dan_NetworkingScriptedWeapons.pdf) | CommandFrames，脚本能力的保存恢复、本地输入与状态边界；不等于所有远端角色都完整回滚 |
| Bungie，Justin Truman，GDC 2015：[Shared World Shooter Destiny](https://media.gdcvault.com/gdc2015/presentations/Truman_Justin_Shared_World_Shooter.pdf) | 按活动和职责分配权威、控制复制范围；共享世界后端与小型对战的规模不同 |
| Psyonix，Jared Cone，GDC 2018：[It IS Rocket Science!](https://media.gdcvault.com/gdc2018/presentations/Cone_Jared_It_Is_Rocket.pdf) | 预测与插值时间不同会影响物理接触，完整物理交互和简化代理有不同精度与成本 |
| Riot：[LoL determinism 实现](https://www.riotgames.com/en/news/determinism-league-legends-implementation)、[统一时钟](https://www.riotgames.com/en/news/determinism-league-legends-unified-clock)、[定位分歧](https://www.riotgames.com/en/news/determinism-league-legends-fixing-divergences) | 明确模拟输入、统一时钟、检测分歧；Chronobreak 的服务端恢复不能当作普通客户端全世界回滚的证据 |
| Riot：[Peeking into VALORANT's Netcode](https://www.riotgames.com/en/news/peeking-valorants-netcode)、[128-Tick Servers](https://www.riotgames.com/en/news/valorants-128-tick-servers) | 输入缓冲、模拟差异、分系统预算及可重复负载 |
| Riot：[VALORANT 服务器性能报告](https://playvalorant.com/en-us/news/dev/how-we-got-to-the-best-performing-valorant-servers-since-launch/) | 重复属性比较会随连接数放大，先识别重复工作和实际热点 |
| Epic：[Fortnite Battle Royale 优化](https://www.unrealengine.com/tech-blog/unreal-engine-improvements-for-fortnite-battle-royale)、[Replication Graph](https://www.unrealengine.com/tech-blog/replication-graph-overview-and-proper-replication-methods)、[Iris](https://dev.epicgames.com/documentation/unreal-engine/introduction-to-iris-in-unreal-engine) | 公共准备、复制数据所有权和接收者分组；空间兴趣管理与公共编码复用是不同层级 |
| EA：[Apex 服务器与 netcode 深度报告](https://www.ea.com/games/battlefield/news/servers-netcode-developer-deep-dive) | 区分服务器计算、网络等待、命中判定，使用可分析的性能数据；文章描述 Legacy 赛季时期设计 |
| 343：[Halo Infinite Online Experience](https://www.halowaypoint.com/news/closer-look-halo-infinite-online-experience)、[March Update Preview](https://www.halowaypoint.com/news/march-update-preview) | 输入缓冲和历史命中查询；后者说明网络模型有更换，不能把前文当作持续不变的现状 |
| CCP：[Introducing Time Dilation](https://www.eveonline.com/news/view/introducing-time-dilation-tidi) | 明确过载策略和玩家可见后果；主动放慢模拟不适合作为本项目的默认处理 |
| ArenaNet：[Megaserver](https://www.guildwars2.com/en-gb/news/introducing-the-megaserver-system/)、[Live Game Outage Analysis](https://www.guildwars2.com/en-gb/news/inside-arenanet-live-game-outage-analysis/) | 地图副本分配、服务隔离和运维证据；不能直接解决单场战斗的重放成本 |

### 其他部署与演进资料

| 资料 | 可参考部分及边界 |
|---|---|
| AWS：[Game Server Processes](https://docs.aws.amazon.com/wellarchitected/latest/games-industry-lens/game-server-processes.html)、[Persistent World Hosting](https://aws.amazon.com/blogs/gametech/hosting-persistent-world-games-on-amazon-gamelift/) | 区分游戏实例、对局进程和玩家会话；多进程编排解决总体并发，不能代替单场模拟优化。本项目按房间组织会话，没有实现持续世界后端 |
| Unity：[Prediction DevLog Entry 4](https://discussions.unity.com/t/prediction-in-gameobject-netcode-devlog-entry-4/1719927) | 讨论整组回退、预测范围切换和相等检查；开发计划不等于所有发布版已经交付，文中的调度占比也不能套到 Godot |

## 当前采用

采用固定 tick 与显式输入、可恢复历史、模拟和表现分离、按身份确认副作用、按实际依赖限制重放范围。公共事件和 STATE 复用公共准备，连接的 ACK 与私有状态独立。性能按阶段聚合并区分 CPU、等待和显示。

实现分别见[预测域](local_prediction_design.md)、[历史复用](prediction_reuse.md)、[编码调研](state_encode_performance_review.md)和[性能观测](low_overhead_performance.md)。没有引入大型共享世界后端、Replication Graph、全世界确定性锁步或时间膨胀。

## 阅读范围

[Overwatch Gameplay Architecture and Netcode](https://www.gdcvault.com/play/1024001/-Overwatch-Gameplay-Architecture-and)、[Cross-Platform Determinism in Warhammer](https://gdcvault.com/play/1034321/Cross-Platform-Determinism-in-Warhammer)、[I Shot You First: Halo Reach](https://www.gdcvault.com/play/1014346/I-Shot-You-First-Networking)仅以目录/摘要确认主题，不据此声称采用了讲座正文中的实现。用户提供的资料入口也不能自动视为正文已阅读。
