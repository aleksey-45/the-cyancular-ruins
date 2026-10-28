# 联机架构调研与可复现性约束

调研日期：2026-10-24。对象为 `siri_v0.5.0`，本轮阅读起点 `0f6cf07`。本文件区分资料中的设计、对本项目的推论和实际验证结果；历史报告中的计时不作为本轮结果。

## 一、架构选择

| 场景 | 一手资料中的方法 | 对本项目的意义 |
|---|---|---|
| 大量独立对局 | AWS 将匹配、会话管理与实时游戏进程分开；一台主机可运行多个对局进程 | 当前房间与权威世界属于对局型架构；部署扩容不能直接修复单个客户端的重放开销 |
| 持续世界 | AWS 区分持续运行、可随时进出的世界与短时会话，并单独管理持久化 | 分区、存档与跨区迁移是另一类问题，不能据此把当前八人对战改成分布式物理 |
| 大量玩家与复制对象 | Fortnite 的 Replication Graph 缓存并共享复制列表，减少逐对象、逐连接的重复相关性计算 | 兴趣管理解决复制规模；参与本地接触的对象仍需处于正确模拟 tick，不能只依据屏幕可见性裁掉 |
| 即时人物控制 | Unreal CMC 保存输入和运动状态，服务端确认；有校正时恢复对应历史并重放后续移动 | ACK 的输入序号和快照的模拟 tick 是不同坐标；比较应在同一 tick，恢复必须覆盖运动依赖 |
| 高度交互的物理 | Rocket League 保存物理历史，校正时还原交互对象并追赶；其他车辆的新操作难预测 | 硬阻挡、击退、地形和弹丸之间有依赖，不能只还原本地坐标再与“现在”的其他对象碰撞 |
| 高 tick 率与高密度部署 | Riot 分解移动、物理、复制等成本并给各子系统预算 | 必须测量每次重放的 tick 数、角色数、查询与恢复成本，区分运算和调度等待 |

资料：

- [AWS：游戏进程与会话](https://docs.aws.amazon.com/wellarchitected/latest/games-industry-lens/game-server-processes.html)
- [AWS：持续世界](https://aws.amazon.com/blogs/gametech/hosting-persistent-world-games-on-amazon-gamelift/)
- [Epic：Replication Graph](https://dev.epicgames.com/documentation/en-us/unreal-engine/replication-graph-in-unreal-engine)
- [Epic：Character Movement 的网络流程](https://dev.epicgames.com/documentation/en-us/unreal-engine/understanding-networked-movement-in-the-character-movement-component-for-unreal-engine)
- [Psyonix：It IS Rocket Science，GDC 2018](https://media.gdcvault.com/gdc2018/presentations/Cone_Jared_It_Is_Rocket.pdf)，第 149–176 页的历史比较、恢复与追赶。
- [Riot：VALORANT 128 tick 服务端](https://www.riotgames.com/en/news/valorants-128-tick-servers)

## 二、直接影响校正与重放的设计

### 历史复用需要证明状态一致

[Source SDK 的 `ComputeFirstCommandToExecute`](https://github.com/ValveSoftware/source-sdk-2013/blob/master/src/game/client/prediction.cpp) 实现两类复用：没有新世界更新时，从已有预测结果续算；新 ACK 没有预测字段误差时，复用已有后续结果。存在误差则重新预测。这里比较的是历史预测数据，不能把“当前位置误差较小”当作所有状态一致。

对本项目的推论：任何历史复用必须校验完整运动状态及输入调度；武器、账户、角色接触、地形和新战斗事件都可能使旧结果失效。只比较位置，或在有新输入提示时继续使用旧轨迹，都不能证明安全。

### 相互作用对象必须共用模拟时间

[Unity 的预测边界文档](https://docs.unity.cn/Packages/com.unity.netcode%401.3/manual/prediction-details.html)明确举出：部分对象回到旧 tick，其他对象停在新 tick 时，双方碰撞会产生错误。其建议包括将依赖对象成组发送和模拟，但每种方法都有适用范围。

对本项目的推论：先审计每个角色的运动、接地、倒地、无敌时间、加速账户和动作边沿是否都在同一阶段推进，再讨论选择性重放。角色编号顺序、复活边界和地图接缝也属于复现条件。

### 固定步进之外仍有输入与状态完整性

[Unity 的预测流程](https://docs.unity.cn/Packages/com.unity.netcode%401.5/manual/intro-to-prediction.html)将完整 tick 的状态备份与重放分开，并说明重放会在一帧内多次执行模拟。[Gaffer 的状态同步说明](https://gafferongames.com/post/state_synchronization/)要求同步外推需要的速度等状态；如果量化后的值会重新参与模拟，双端也需要相同量化规则。

对本项目的推论：即使两端都用 `1/60`，只要分支、计时器、碰撞几何、输入实际执行 tick 或状态精度不同，仍会分歧。须逐字段找出第一个不同的 tick，不能用最终收敛代替一致性证明。

### 网络传播与应用缓冲分别归因

[Riot 的一致性复盘](https://playvalorant.com/en-us/news/game-updates/valorant-gameplay-consistency-update-2/)说明低帧率、切出窗口和缓冲恢复逻辑都可能扩大处理延迟；RTT 不能完整描述输入与敌方移动的处理延迟。[DDNet 的客户端源码](https://github.com/ddnet/ddnet/blob/master/src/engine/client/client.cpp)使用输入到达余量反馈调整预测时间。

对本项目的推论：必须分别保留原生收包时间、主线程派发时间、目标 tick、实际消费 tick 与重放耗时。固定注入 RTT 只固定代理传播时延，不保证进程调度恒定。尚未知的远端操作会改变未来轨迹，但不能因此把已知输入下的重复校正归因于网络。

### 表现不应污染模拟

[Gaffer 的视觉平滑](https://gafferongames.com/post/state_synchronization/)将校正偏移留在渲染侧。[Godot 4.7 的插值说明](https://docs.godotengine.org/en/4.7/tutorials/physics/interpolation/physics_interpolation_introduction.html)也区分固定物理 tick 与渲染时间，指出联网程序可能需要自己的时间插值。

对本项目的推论：重放读取的弹丸存活、武器条件、碰撞体和角色姿态应来自模拟状态。当前画面的节点、插值位置、动画或粒子只能作为表现输出。

## 三、代码审计顺序

1. 服务端一个 tick 的阶段顺序，以及 STATE、输入提示和战斗事件各自对应哪个阶段。
2. 编解码后的状态完整性：角色运动、生命、无敌时间、武器、账户、控制阶段和输入确认。
3. 本地玩家与远端阻挡预测体的步进分支，尤其是是否共享同一套计时器和受击语义。
4. 输入的目标 tick、到达 tick、实际消费 tick、持续输入与单次动作去重。
5. 恢复边界：是否撤销上一轮预测的地形、弹丸、命中与临时状态。
6. 重放工作量：重复排序、分配、节点创建、原生查询、碰撞提交及可证明有效的历史复用。

## 四、复现材料的最低要求

每个待修问题保存一个独立夹具，包含：

- 起始 tick、控制 epoch、角色顺序、游戏参数及源码版本/哈希。
- 实际初始地图或完整毁后地形，不能仅保存地图版本号。
- 所有参与接触角色的运动状态、HP、无敌时间、账户及影响移动的武器状态。
- 本地输入、远端提示及其服务端到达 tick；移动 ACK 与动作 ACK 分别保存。
- 弹丸出生/结束、引信、光束、命中、爆炸与地形事件的时间及应用顺序。
- 确定的执行 tick 数和不依赖墙钟的驱动方式。
- 首个分歧 tick、字段与前后值；重复运行的结果散布。

复现分三层：

1. **机制复现**：只改变被怀疑的分支或状态，其他输入一致。用于确认因果，不冒充原对局重演。
2. **现场重演**：完整恢复原始地形、状态和消息时间线；材料缺失时明确标记无法完整重演。
3. **性能对照**：同一夹具、相同 tick 数与角色数，热身后交错计时；先逐 tick 比较结果，再讨论耗时。

当前阶段只完成资料阅读与复现约束整理，尚未新增本轮实测结论。
