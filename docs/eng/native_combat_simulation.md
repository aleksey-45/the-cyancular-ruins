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
| `NativeProjectileSnapshot` | 每个历史帧独占的有序弹丸数值数组，直接比较权威状态并批量恢复原生弹丸 |

武器参数来自 WeaponRegistry 和武器场景，C++ 不按 ID 维护另一张数值表。脚本管理背包、场景装配、输入时钟、账户、网络接纳、重放外层循环和表现。服务端共用角色与武器核，弹丸装配、广播、编码和战绩外围由脚本管理。

## 顺序与副作用

攻击按稳定身份和既定阶段推进。爆炸直接调用原生地形，同 tick 的后续接触必须看到已经提交的碰撞变化。模拟输出带攻击身份和 tick 的结果；外层根据首次预测、权威确认与静默重放决定音画。确认去重和权威覆盖在执行前判定。

节点归场景所有，原生记录以弱引用访问节点。网络锚点使用普通字典，不传输原生对象引用。本地检查点的弹丸部分为 `NativeProjectileSnapshot`，保存连续数值记录；脚本只在迟到弹丸独立追赶成功后补入对应帧。每帧独占数据，源字典和后续模拟不能改写已有历史。角色及其他检查点元数据使用 Array/Dictionary，低频元数据按只读约定共享。

弹丸推进与接触共用候选身份列表，分别复核所处阶段的生命周期，按攻击 ID 合并确认事件。权威 ACK 裁剪已覆盖的命中、爆炸和光束，未来确认保留。

源码：[combat_kernel.h](../../native/simulation/combat_kernel.h)、[combat_kernel.cpp](../../native/simulation/combat_kernel.cpp)、[prediction_history.cpp](../../native/simulation/prediction_history.cpp)。复用条件见[预测历史](prediction_reuse.md)，资料见[战斗预测调研](combat_prediction_research.md)。
