# 场景内原生模拟

高频模拟状态与规则由 C++ GDExtension 持有，Godot 场景负责层级、资源、物理空间和节点生命周期，GDScript 负责装配、会话与表现。模拟使用 Godot 物理 API，不另建独立物理引擎。

## 所有权与入口

| 范围 | 所有者与入口 |
|---|---|
| 角色状态、输入、运动 | `NativeActorBody : CharacterBody2D`；[ActorStep](../../core/sim/actor_step.gd) 准备输入及上下文后调用原生步进 |
| 武器计时、弹药、后坐力 | `NativeWeaponBody : Node2D`；武器场景提供注册表配置 |
| 弹道、预测战斗 | `NativeBulletBody`、`NativeCombatKernel`；[战斗模拟](native_combat_simulation.md) |
| 代理与预测历史 | `NativeMotionTrack`、`NativePredictionHistory`，有界保存模拟所需样本 |
| 地形 | `NativeTerrain` 独占可变地形与历史；[地形接口](native_terrain.md) |
| 节点与资源 | Godot 场景；脚本管理生成、装配、释放、账户和网络事件 |
| 显示与音画 | 脚本读取模拟结果，在表现阶段更新 |

原生循环通过类型明确的成员和对象调用访问状态；配置、输入和快照在边界转换。Dictionary/Array 仍用于网络和完整检查点，不能把这套边界描述成全游戏纯数据化。

## 执行顺序

服务端、本地预测和远端代理使用手动模拟，关闭相应节点自动物理步进。共享角色核按确定顺序推进武器与运动，Godot 处理地形物理查询，原生逻辑矩形处理角色阻挡。一次移动准备活动形状和查询上下文，两轴各读取实际变换，保持先 X 后 Y。

网络结果在每个 process frame 的接纳阶段合批，重放从同 tick 检查点恢复，读取对应阶段代理和地形。地形改变必须在依赖它的下一次查询前提交。当前模型在主线程执行，不能直接在后台线程访问活动场景树。

## 模拟与表现

模拟保存会影响下一步的状态；重放执行相同规则并抑制重复音画。动画、精灵变形、预瞄、HUD 和视觉平滑由最终模拟结果驱动。表现偏移不能改变碰撞、瞄准和出生位置。节点创建与销毁仍有真实成本，原生化不免除资源和生命周期管理。

源码：[simulation.h](../../native/simulation/simulation.h)、[actor_body.cpp](../../native/simulation/actor_body.cpp)、[weapon_body.cpp](../../native/simulation/weapon_body.cpp)。资料和未采用的替代方案见[模拟数据边界调研](pure_data_simulation_research.md)。
