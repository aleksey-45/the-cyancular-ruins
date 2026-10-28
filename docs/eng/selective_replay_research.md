# 按因果依赖缩小重放范围的资料调研

调研日期：2026-10-26。本轮只阅读资料、核对既有实现并整理设计建议，没有修改模拟代码或运行测试。这里的网络回滚与 Beta 玩法中的时间回溯是两个概念。

## 结论及证据范围

按对象之间的依赖传播，只修复受影响的预测历史，有研究、引擎机制和开源实现可以参考。检索词包括 selective rollback、dependency-based rollback、incremental resimulation、simulation islands、prediction culling。

这些名称覆盖的能力不同：空间裁剪只选择预测对象；部分快照回滚只选择更新对象；物理岛表达物理约束连接；完整因果重算还需要追踪跨 tick 的读取、写入和新出现的交互。不能把前几种机制当成最后一种机制的完整正确性证明。

## 一手资料

### Roblox：明确讨论依赖图与因果传播

[Flexible netcode architecture，US20260108808A1](https://patents.google.com/patent/US20260108808A1/en)，公开日期 2026-04-23，Roblox 的公开申请文件。重点是图 2、block 206 附近的技术描述。

文件讨论了误预测对象对其他对象的影响，例如球的错误轨迹导致瓶子被撞碎；修正球后，需要同时修复瓶子的状态。文中明确提出可根据依赖图或逐对象检查选择回滚对象，而非固定回滚整个模拟。

这是与本次设想非常直接对应的公开设计，但该文件不能证明 Roblox 已部署其中每一种可选实现，也没有给出可直接移植的完整算法和性能数据。

### netfox：对象级影响通知及开源实现

- [Modifying objects during rollback](https://foxssake.github.io/netfox/latest/netfox/tutorials/modifying-objects-during-rollback/)
- [NetworkRollback 源码](https://github.com/foxssake/netfox/blob/main/addons/netfox/rollback/network-rollback.gd)
- [RollbackSimulationServer 源码](https://github.com/foxssake/netfox/blob/main/addons/netfox/servers/rollback-simulation-server.gd)

文档以玩家推动、爆炸和车辆碰撞为例：对象在历史 tick 被其他对象修改后，调用 `NetworkRollback.mutate(target)`，记录该 tick 的新状态，并要求目标从变更处继续重算。源码维护各对象的输入关系、参与模拟条件和 mutation 起点。

这证明 Godot 中已有相关实现，但依赖需要业务代码显式通知，文档仍将 Mutations 标为实验性；它不是自动追踪所有属性读取的通用因果引擎。

[问题 #383](https://github.com/foxssake/netfox/issues/383)记录了非常重要的边界：B 单独重放后，A 之前对 B 的推动可能丢失；B 修正后新进入推动范围时，也可能漏掉原本未发生的推动。该问题说明，仅记实际写入或过去发生的交互不足以保证局部重放正确。这里引用的是公开问题中的反例，不将该讨论当成当前所有版本的缺陷判定。

### Unreal Chaos：交互岛、历史播放与重算切换

- [UE 5.4 Release Notes](https://dev.epicgames.com/documentation/en-us/unreal-engine/unreal-engine-5.4-release-notes?application_version=5.4)，NetPhysics resim improvements。
- [FPBDIslandManager](https://dev.epicgames.com/documentation/en-us/unreal-engine/API/Runtime/Chaos/FPBDIslandManager)
- [UE 5.5 SetUseCollisionResimCache](https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Chaos/Chaos/Framework/FPhysicsSolverBase/SetUseCollisionResimCache?application_version=5.5)

物理岛以物体为节点、约束为边。5.4 更新记录说明：对象与重算对象交互时可切入重算；寻找岛内所有物体都有有效恢复目标的帧；处于同一重算岛时停用预测插值。5.5 API 说明还区分失同步物体与保持同步的物体：后者可按已有历史状态推进。

可借鉴的是“变化对象重算，其他对象按同 tick 历史提供环境，交互扩大参与范围”。物理约束图本身不覆盖伤害、资源账户、射线遮挡等业务依赖，不能直接当成本项目的完整因果图。

### 并行离散事件仿真：真正沿 trace 选择回滚事件

[Bauer 等，Efficient Inter-Process Synchronization for Parallel Discrete Event Simulation on Multicores，SIGSIM-PADS 2015](https://user.it.uu.se/~bengt/Papers/Full/pads15.pdf)，第 4 节，PDF 第 4 页。

作者实际实现了 selective rollback：收到迟到事件或撤销消息后，先根据执行 trace 查找因果依赖，只回滚相关的已处理事件。论文比较了选择性与非选择性回滚。

这提供了依赖传播、历史记录及撤销旧输出的研究依据；其模型是离散事件仿真，并非八人连续碰撞游戏，不能直接套用论文的性能结果。

### Photon Quantum：预测裁剪，可参考但不是精确因果追踪

[Quantum 3 Prediction Culling](https://doc.photonengine.com/quantum/v3/manual/prediction-culling)。预测帧只推进选定区域内或重要的实体，区域外实体在输入已确认的帧仍正常模拟；支持自定义选择方式。文档还指出，共享随机数流会使被裁剪与未裁剪实体互相影响，可按实体隔离 RNG。

这证明减少预测对象数量是一条产品级优化路径，但“在区域外”不能证明实体不会通过弹丸、光束或地形影响本地角色。

### Unity Netcode：部分重放不自动解决交互正确性

- [Introduction to prediction，1.5](https://docs.unity.cn/Packages/com.unity.netcode@1.5/manual/intro-to-prediction.html)
- [Prediction edge cases，1.3](https://docs.unity.cn/Packages/com.unity.netcode@1.3/manual/prediction-details.html)

部分快照只回滚其中的预测对象；文档明确举例说明，重放中的旧 tick 对象与停在新 tick 的对象碰撞会产生错误。其缓解方法包括交互对象成组发送等。这是时间一致性约束，不是“只更新收到的对象就一定正确”的保证。

## 对本项目的推论

以下为根据资料与源码提出的设计建议，尚未实现或验证。

### 目标应限定到预测窗口内

可判断的是某次差异在当前预测窗口内是否改变本地角色所需的结果，不能保证它永远不会产生影响。跳过的远端对象若历史已失效，需要保留失效标记或改用权威播放；未来进入本地交互范围时必须先补齐，不能继续把旧轨迹当成有效环境。

依赖单元至少包含对象、tick 和模拟阶段。我们按角色顺序处理移动和攻击，之后还有弹丸、地形、账户与规则阶段；只记“角色 A 影响 B”会丢失真实执行顺序。

### 需要同时考虑旧交互和新交互

例如旧预测是“弹丸命中远端 B 后消失”；修正后 B 躲开，弹丸继续飞行并命中本地角色。旧历史没有弹丸到本地角色的命中边，只遍历旧命中图会错误跳过。

同样，旧路径上的墙阻挡了爆炸或光束，修正地形后遮挡消失，也会产生新影响。因此需检查查询范围、扫掠区域、空查询结果和遮挡依赖；仅保存成功命中的对象列表不够。

重新计算时既要撤销已不成立的旧命中、旧地形写入和旧奖励，也要发现新的命中和写入。只传播新结果会残留旧结果，只传播旧依赖会漏掉新结果。

### 可采用有限范围的依赖传播

1. 同 tick 比较权威数据与预测数据，得到真正变化的数据块和起始阶段；重复确认只更新元数据。
2. 通过历史依赖及保守的空间查询找候选消费者。对本项目，应涵盖人物阻挡、弹丸轨迹与引信、爆炸半径与遮挡、光束路径、局部地形读取、账户影响的加速和回溯许可。
3. 从候选对象的首个失效阶段重算。未失效对象提供对应 tick、对应阶段的历史状态，不能停在当前预测末端参与旧 tick 碰撞。
4. 比较重算输出与旧输出。某个消费者所依赖的输出相同时，不向该消费者继续传播；对象自身仍变化的后续状态不能因此提前判为有效。
5. 新轨迹发现额外交互时扩大集合，并恢复被影响对象的正确历史边界。必要时重新处理更早的阶段，直到当前窗口内的交互依赖闭合。
6. 历史缺失、动态依赖无法确定或影响扩展过大时，回退到已有整组恢复路径。回退是明确条件，不把未知依赖当成无影响。

人物、弹丸和地形之间会有跨阶段的双向影响，因而不能仅从“当前本地状态”沿旧图反向查一次就结束。保守候选集可以先包含不会真正变化的对象，再用实际结果比较截断传播。

### 可以从现有代码衔接，但当前还没有完整依赖图

- [PredictionRollback](../../core/net/prediction_rollback.gd)已有逐 tick 角色、命令、弹丸和账户历史，但 STATE 校验和世界重放仍以整组为单位。
- [CombatPrediction](../../core/net/combat_prediction.gd)已有命中、爆炸、光束结果记录，可作为输出比较的基础；还需覆盖未命中查询、新路径以及撤销旧输出。
- [PredictionEconomy](../../core/net/prediction_economy.gd)已体现有限的依赖检查：先重算账户，只有实际加速或回溯行为变化才要求世界重放。它不是整套对象因果重放的实现。
- [原生地形（替代旧模块）](../../native/simulation/terrain.cpp)记录局部地形变化，不能据此推断已有全部角色、弹丸与射线的地形读取依赖。
- [ActorCollider](../../core/sim/actor_collider.gd)可提供人物阻挡检查的接入点；只记录碰撞成功的对象会漏掉后来新出现的阻挡。

初步更适合按角色运动、攻击、账户和地形局部块记录显式依赖，而不是拦截每一个 GDScript 属性读取。全局实体 ID 分配、角色处理顺序、共享随机数等也需要审计，否则看似独立的对象可能仍有隐藏依赖。环形地图的查询区域必须按环面几何处理，不能直接用普通欧氏距离裁剪。

这种设计的收益取决于真实对局的影响集合大小，以及记录和检查依赖的成本。无法从资料推断本项目能减少多少耗时，也不能据此确定上局 231 ms 卡顿的完整原因。后续若实施，需要用相同输入和事件夹具逐 tick 对照整组重放，验证局部结果，再比较计算与记录的总成本；本轮没有进行这些测试。

2026-10-27 补充：LoL 的施法与局部预测实例、CS:GO / Source 的预测范围及服务器历史命中查询，见 [LoL 与 CS:GO 的复杂交互和预测边界](lol_cs_prediction_boundaries.md)。复杂交互不能单独作为客户端必须建立完整因果图或整组重放的理由，应先判断哪些结果确实需要客户端预测。

## 补充：只重放本地角色的适用边界

“只重新执行本地角色的移动逻辑”可以是一种完整架构；“只恢复本地角色，却让其依赖的角色、弹丸和地形停在别的时刻”不能保证与原模拟等价。选择性重算所需的外部历史，不一定要通过再次执行外部对象的全部逻辑取得，也可以读取已验证的历史，或使用明确接受近似结果的权威播放方案。

### 新查阅的资料

[Epic：Best Practices for Networked Movement Abilities (CMC)](https://dev.epicgames.com/community/learning/tutorials/ywD1/unreal-engine-best-practices-for-networked-movement-abilities)。正文直接打开时解析器未提取到内容，本次阅读了搜索服务返回的该原文索引段落。其讨论了重放读取的历史角色和世界状态，以及不同世界时间带来的阻挡差异；还建议通常不要预测对其他玩家的移动作用，除非作用已确定、无法再被阻止。这是控制预测范围的工程取舍，不是所有动态交互都能精确预测的承诺。

[Epic：Character Movement 网络流程](https://dev.epicgames.com/documentation/en-us/unreal-engine/understanding-networked-movement-in-the-character-movement-component-for-unreal-engine)。本地 autonomous proxy 在校正后重放保存的移动，远端 simulated proxy 按复制状态执行简化移动和平滑。这里减少的是远端完整输入重放，远端代理本身仍可能执行简化运动。

[Photon Fusion 2：Networked Physics](https://doc.photonengine.com/fusion/v2/manual/physics/physics-overview)。目前页面区分三种成本与精度取舍：权威同步且远端为运动学代理、外推到本地时间并近似交互，以及预测并重放物理。它说明本地交互响应、交互精度与重算成本可以分开选择，不是所有对象都必须采用同一种模式。

[Unity 1.5：Prediction edge cases](https://docs.unity.cn/Packages/com.unity.netcode@1.5/manual/prediction-details.html)。只恢复 A、B 到 tick 10，却将 C、D 冻结在 tick 20，重算中的碰撞与后续速度应用可能错误；该问题与是否只预测本地输入是不同层面。

### 当前源码中的具体依赖

| 场景 | 只删掉其他角色步进时的缺口 | 可采用的边界处理 |
|---|---|---|
| 人物相互阻挡 | `ActorCollider` 读取其他角色的位置与碰撞姿态；错误时间的矩形会改变位移、接地、速度和冲刺 | 使用对应 tick、对应角色阶段的代理；若修正本地轨迹也改变了远端后续阻挡，扩大重算范围，或明确接受代理近似带来的校正 |
| 射击、弹丸与引信 | 本地轨迹会改变发射位置，角色接触又改变弹丸结束和引信状态 | 相关弹丸单独恢复重算；已确认的外部事件作为历史输入处理，无关弹丸可继续播放 |
| 爆炸与击退 | 当前攻击预测会修改多个角色的 HP、击退等状态；目标变化可能反过来改变后续交互 | 限制客户端实际预测的作用范围，或沿受影响对象传播；旧作用需要撤销或重新校验 |
| 地形破坏 | 当前地形可能已不同于重算 tick 的地形，进而改变接地、弹道和遮挡 | 提供对应历史地形或经校验的局部查询结果；真实依赖变化时重算相关部分 |
| 本地账户与武器 | 本地移动还读取加速、锁定、武器移速等状态，不能只恢复坐标与速度 | 恢复本地完整模拟状态和相关历史；可复用已有账户轻量检查 |

本项目人物阻挡是按角色顺序进行的矩形裁剪，不是完整刚体推挤求解。虽然一次本地移动不直接给远端施加碰撞冲量，本地位置改变仍可能改变后续角色的可移动距离，再在下一 tick 影响本地角色。因此，“读取旧远端轨迹”只有在该轨迹的依赖仍有效时才是精确复用。

若选择以本地移动为核心的较小预测范围，可以将远端角色按权威状态播放，把未确认的对外伤害、击退等交给服务端，客户端保留即时音画反馈。若继续要求客户端即时预测多角色战斗、相互阻挡及地形反馈，则需要补齐这些依赖的历史或选择性重算，不能仅修改角色循环。本次仅补充资料与分析，没有改变这一架构或执行测试。
