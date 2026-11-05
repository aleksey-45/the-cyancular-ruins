# 场景内模拟

高频模拟状态与规则全部由 GDScript 持有，Godot 场景负责层级、资源、物理空间和节点生命周期。碰撞求解只使用 Godot 物理 API，不另建独立物理引擎，也没有第二套矩形判定。

## 所有权与入口

| 范围 | 所有者与入口 |
|---|---|
| 角色状态、输入、运动 | `ActorBody : ServerBody`；[ActorStep](../../core/sim/actor_step.gd) 准备输入及上下文后调用步进 |
| 输入字段与控制锁 | `ActorInput`；本地与网络输入都先打包再统一应用锁 |
| 实体物理体 | `ServerBody` 自管稳定 RID；ActorBody 持有姿态形状与接缝镜像 |
| 物理查询适配 | [CollisionWorld](../../core/sim/collision_world.gd)；碰撞层、复用查询参数、接缝几何与光束走廊采集；RID 通过 object instance ID 归属 |
| 武器计时、弹药、后坐力 | `WeaponBody : Node2D`；武器场景提供注册表配置 |
| 弹道与生命周期 | `BulletBody`；[战斗模拟](combat_simulation.md) |
| 世界预测与历史 | `PredictionWorld` 推进全部角色，`PredictionHistory` / `PredictionFrame` 保存有界世界检查点 |
| 地形 | `Terrain` 独占可变地形与历史；[地形](terrain.md) |
| 节点与资源 | Godot 场景；脚本管理生成、装配、释放、账户和网络事件 |
| 显示与音画 | 脚本读取模拟结果，在表现阶段更新 |

模拟通过类型明确的成员直接访问状态；配置、输入和网络快照在边界转换。角色状态与游标使用固定槽数组，账户、按身份索引及低频元数据保留 Dictionary。

## 物理查询

角色与弹丸都通过 PhysicsServer2D.body_test_motion() 求解，角色按 X/Y 两轴顺序移动，台阶候选只探测，选中后才提交实际运动。爆炸、光束、遮挡使用 intersect_shape() 与 intersect_ray()，命中身份通过实体 RID 的 object instance ID 归属。

## 规范坐标与视觉投影

物理查询和状态快照一律使用规范区间 `[0, width) × [0, height)`；弹丸的每一次推进，无论以移动、反弹、地形命中、角色命中还是射程结束收尾，都会回绕到规范区间。渲染才用 `GridPathfinder.anchor_to_nearest()` 取最近展示副本。视觉偏移只作用于渲染子节点，绝不写回参与碰撞的变换：弹丸平移 `Visual` 子节点，敌人只平移动画节点，角色副本本身是纯表现节点。

## 执行顺序

服务端、本地预测和远端代理使用手动模拟，关闭相应节点自动物理步进。

```text
恢复或接收该 tick 的权威状态
-> 恢复地形 HP 并提交增量 chunk
-> 同步角色（含远端）规范位姿与姿态到碰撞代理
-> 按 role 固定顺序推进角色，推进后立刻刷新其代理；该阶段开火的光束立即结算
-> Beta 阶段应用已知回溯路径及弹丸恢复，推进账户
-> 先按 projectile ID 升序推进全部弹丸与直接命中
-> 再按 (due_tick, entity_id) 结算到期爆炸并更新地形 HP
-> tick 末尾统一提交脏 chunk，记录本 tick 世界历史与网络快照
-> 渲染阶段同步视觉副本、动画、FX
```

代理是静态 RID 体，形状变化后必须重设自身变换才会进入宽相；`ActorBody.sync_collision_geometry()` 在每次写入形状后完成这一步，因此同一物理帧内的下一步查询能读到最新姿态与位置。该行为由 `tests/terrain_case.gd::_proxy_same_frame()` 逐项验证。

## 模拟与表现

模拟保存会影响下一步的状态；重放执行相同规则并抑制重复音画。动画、精灵变形、预瞄、HUD 和视觉平滑由最终模拟结果驱动。表现偏移不能改变碰撞、瞄准和出生位置。节点创建与销毁仍有真实成本。

源码：[actor_body.gd](../../core/sim/actor_body.gd)、[weapon_body.gd](../../core/sim/weapon_body.gd)、[collision_world.gd](../../core/sim/collision_world.gd)。资料和未采用的替代方案见[模拟数据边界调研](pure_data_simulation_research.md)。
