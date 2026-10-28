# LoL 与 CS:GO 的复杂交互和预测边界

调研日期：2026-10-27。只整理公开资料与架构推论，没有修改游戏模拟代码或运行测试。历史文章按其发布时描述的系统理解，不把 Source SDK 当成 CS:GO 的完整源码。

## 本轮判断

复杂玩家交互并不自动要求客户端建立全世界因果图并反复重算。公开资料支持的另一条路径，是让服务端裁决完整交互，客户端分别处理本地预测、可撤销的局部状态和远端表现。

这需要收窄先前的建议：“保留即时反馈”不自动等于“客户端必须预测所有对象的完整战斗结果”。角色阻挡、受击后的本地运动和真实地形依赖仍需处理，但不能仅因存在这些交互，就决定采用整组世界重放。

目前没有找到足以证明 LoL 或 CS:GO 在普通对局中使用通用因果依赖图、由一次客户端预测错误递归重放全部关联玩家的公开资料。也没有找到 LoL 完整客户端回滚内核和窗口统计，不能编造其具体重放 tick 数。

## 三种不同的“回到过去”

| 机制 | 目的 | 范围 |
|---|---|---|
| 客户端预测校正与重放 | 保留尚未确认的本地操作响应 | 本地被预测状态及其必要依赖 |
| 服务端 lag compensation | 按射击者看到的历史几何裁决命中 | 临时恢复查询需要的目标位置、碰撞体、姿态等，查询结束后恢复 |
| LoL Chronobreak / 确定性重演 | 比赛故障恢复与开发验证 | 通过录制输入重建服务器；不是每次网络更新的客户端处理 |

此外，施法界面、资源显示等局部预测可以撤销或修正，不一定需要重跑人物移动和全局战斗。

## LoL：按子系统处理确认、预测与撤销

### 服务器裁决与信息边界

[Riot's Approach to Anti-Cheat](https://www.riotgames.com/en/news/riots-approach-anti-cheat)，2018-07-17，明确说明 LoL 让服务端模拟作权威玩法决定，并不向客户端分享所有其他玩家状态。

推论：客户端的已知信息不是服务器完整世界的副本，不能假定客户端需要精确重建所有隐藏玩家的交互。权威与可见性本身不证明具体预测算法，但限定了能要求客户端知道什么。

### Hwei：复杂输入先形成施法请求，最终有效性由服务器决定

[The Art of Spell Casting, Part 1](https://www.riotgames.com/en/news/art-of-spell-casting-part-1)，2024-02-27。文章解释施法请求的客户端与服务端检查，以及初次检查与真正执行时检查的差别。客户端即使以为蓝量不足，也可能发送请求，因为最终判断在服务器。

这说明本地请求生成、输入排队和真实技能执行是不同阶段，不能把本地检查当成最终结果。

[The Art of Spell Casting, Part 2](https://www.riotgames.com/en/news/art-of-spell-casting-part-2)，2024-02-27。Hwei 会预测施法成败、资源和距离条件，使 HUD 即时响应；确认不同时撤销局部状态。文章还说明控制效果等原因会清掉延后施法队列，服务器需通知客户端。它没有描述对整个团战进行客户端重放。

因此，“LoL 完全不预测技能相关状态”也不准确。该实例体现的是按系统规定哪些数据可以先猜、如何确认和撤销，并不能用来断言所有英雄的预测范围相同。

### 难以预测的投射物可以选择服务器路径

[2019 年 League Game Engineers AMA](https://www.reddit.com/r/leagueoflegends/comments/dib488/we_are_league_game_engineers_ama/)，关于 Yuumi Q 的答复说明：服务器根据鼠标样本决定轨迹后下发，客户端按路径绘制；该技能当时的方向预测尝试经常错误，因此没有采用。

这是单个技能、当时版本的设计例子，不能推广为 LoL 所有弹丸均不预测。该答复作者的账号现已删除，保留原讨论上下文作为历史材料，并以正式 Riot 文章交叉理解其权威边界。

### 确定性系列并非普通客户端全世界回滚的证据

- [Determinism: Introduction](https://www.riotgames.com/en/news/determinism-league-legends-introduction)，2017-06-20，介绍 Chronobreak 的服务器录制、快速重建及重连恢复。
- [Determinism: Implementation](https://www.riotgames.com/en/news/determinism-league-legends-implementation)，2017-06-20，讨论记录输入、确定性验证和服务器玩法状态；恢复时甚至无需保留原客户端连接。

这些资料对现场重演和首个分歧定位很有价值，但不能据此证明 LoL 客户端在每次控制效果、伤害或快照到达后重演全部英雄。

## CS:GO / Source：限制客户端预测域，服务器查询历史命中

### 本地输入预测与远端状态播放分开

[Source Multiplayer Networking](https://developer.valvesoftware.com/wiki/Source_Multiplayer_Networking?language=uk)介绍本地输入预测、远端插值、预测误差校正与服务端命中补偿。正文直接访问返回 403，本轮阅读了搜索服务返回的该原文索引内容。

文档明确允许因未知实体或环境信息产生预测误差，再由服务器校正；这不是要求客户端先精确预测每个远端玩家。其表格包含 CS:GO，但不能将页面内所有通用 Source 细节都视为每个 CS:GO 版本的独立保证。

Valve 的公开参考源码提供了进一步佐证：

- [`C_BasePlayer::ShouldPredict`](https://github.com/ValveSoftware/source-sdk-2013/blob/master/src/game/client/c_baseplayer.cpp)只为本地玩家返回 true。
- [`CPrediction::ComputeFirstCommandToExecute`](https://github.com/ValveSoftware/source-sdk-2013/blob/master/src/game/client/prediction.cpp)在满足确认与无误差条件时复用预测结果；`PerformPrediction`也会对脚下对象及父节点撤销插值位置，以处理特定运动依赖。

这支持“本地玩家加可预测实体、显式处理依赖”的引擎设计，不等于只恢复一个坐标，也不等于所有远端实体都要重跑完整输入。SDK 是 Source 家族公开实现，不能冒充 CS:GO 客户端逐行源码。

### lag compensation 不等于重算历史战斗

[Yahn Bernier，Latency Compensating Methods in Client/Server In-game Protocol Design and Optimization](https://www.gamedevs.org/uploads/latency-compensation-in-client-server-protocols.pdf)，Valve，2001。文章把本地移动与武器预测、远端插值和服务器历史命中查询分开。其处理流程临时恢复目标历史状态进行射线判定，随后恢复目标；文章也明确讨论了时间视角不同导致的体验取舍。

[`player_lagcompensation.cpp`](https://github.com/ValveSoftware/source-sdk-2013/blob/master/src/game/server/player_lagcompensation.cpp)中的 `StartLagCompensation`、`BacktrackPlayer`、`FinishLagCompensation`恢复目标位置、边界和动画等查询状态，再还原。该路径没有从历史 tick 起重新执行所有玩家的移动、开火与后续战斗。

CS:GO 自身的正式记录可验证该类机制确实存在：

- [2016-09-09 Beta 更新](https://blog.counter-strike.net/2016/09/15820/)修正补偿时的姿态参数和角色旋转，使服务器历史命中箱更接近客户端模型。
- [2016-10-28 更新](https://blog.counter-strike.net/2016/10/16846/)为特定队友视为敌人的规则补上队友命中补偿。

因此，命中查询会涉及多个玩家历史，但它的成本结构是历史查找、几何恢复和碰撞查询，不能直接按“玩家数乘重放 tick 数的完整角色战斗模拟”理解。

### 有飞行时间的弹丸还需单独选策略

Bernier 文章的脚注 9 专门提出：若弹丸在服务器独立飞行，它每次推进应与其他玩家的哪条时间线交互？文章描述的 Half-Life 实现选择不对这类弹丸做同样的 lag compensation。

这是历史 Half-Life 的决策，不是 CS:GO 全部手雷或其他弹体的实现说明。它证明不同攻击类型可以采用不同契约，不能从即时命中枪械推导出所有弹丸都要回退世界并追赶。

## 对本项目的架构推论

以下为建议，未实施或验证：

1. 先定义客户端预测的权责，而不是先构造全世界因果图。服务端已经负责完整战斗结算；客户端是否需要猜测其他角色的 HP、击退、倒地、武器与账户，应逐项判断。
2. 本地移动、跳跃、开火和必要资源可以保持即时响应；对其他角色的命中表现与真实伤害应区分，局部视觉预测不必反过来决定整个预测世界。
3. 外部命中、控制、资源和地形确认影响本地后续移动时，需要进入本地历史校验；这不自动要求再次执行攻击者及其他远端玩家的全部逻辑。
4. 人物相互阻挡、预测地形和弹丸反馈仍有依赖。可采用有效历史代理、相关弹丸的局部重算，或明确接受近似并等待权威状态；严格维持当前整组模拟的每一步结果时，仍需扩大到真实受影响的交互对象。
5. 只有决定继续预测的部分，才需要更细的依赖传播和结果复用。没有资料支持“交互多，所以客户端必须追求全世界预测一致”这一推导，也没有资料保证修改预测范围后不再有任何校正。

一个解释性的例子：A 的攻击给本地角色 B 施加减速。服务器决定命中与减速结果；B 收到必要状态后校验或修复自己的后续移动，A 及其他玩家可以继续按权威状态播放。该例是根据资料作出的架构推论，不是对 LoL 某个减速技能或 CS:GO tagging 源码的复述。

这批资料更支持优先缩小默认预测范围，再为少量必须即时生效的交互保留局部预测与依赖检查。完整因果图是一种可选优化工具，不应仅因为存在复杂玩家交互就成为前置条件。

本报告不判断哪个子系统造成既有卡顿，也不以其他游戏的设计替代本项目的正确性与性能验证。
