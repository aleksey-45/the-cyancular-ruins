# 原生武器、战斗与历史

## 模块边界

| 模块 | 职责 |
|---|---|
| `NativeActorBody` | 一次调用推进角色计时器、武器和运动 |
| `NativeWeaponBody` | 弹药、冷却、换弹、瞄准、开火缓冲、后坐力和稳定弹丸初态 |
| `NativeBulletBody` | 弹道物理与碰撞步进 |
| `NativeProjectileEntry` | 类型明确的生存期、tick、确认字段和节点弱引用；锚点导出为快照数据 |
| `NativeCombatKernel` | 预测弹丸、接触、命中、爆炸、确认结果、代理依赖复核和远端弹丸追赶；光束路径由脚本构造，接触及伤害由原生计算 |
| `NativePredictionHistory` | 角色、弹丸、代理接触、碰撞姿态、游标和版本的捕获与恢复 |

武器参数来自 WeaponRegistry 和武器场景，C++ 不按 ID 维护另一张数值表。脚本管理背包、场景装配、输入时钟、账户、网络接纳、重放外层循环和表现。服务端共用角色与武器核，弹丸装配、广播、编码和战绩外围由脚本管理。

## 顺序与副作用

攻击按稳定身份和既定阶段推进。爆炸直接调用原生地形，同 tick 的后续接触必须看到已经提交的碰撞变化。模拟输出带攻击身份和 tick 的结果；外层根据首次预测、权威确认与静默重放决定音画。确认去重和权威覆盖在执行前判定。

节点归场景所有，原生记录以弱引用访问节点。协议和检查点导出普通数据，不传输原生对象引用。低频历史元数据按只读约定共享，变化时生成新记录；完整检查点仍使用 Dictionary/Array。

源码：[combat_kernel.h](../../native/simulation/combat_kernel.h)、[combat_kernel.cpp](../../native/simulation/combat_kernel.cpp)、[prediction_history.cpp](../../native/simulation/prediction_history.cpp)。复用条件见[预测历史](prediction_reuse.md)，资料见[战斗预测调研](combat_prediction_research.md)。
