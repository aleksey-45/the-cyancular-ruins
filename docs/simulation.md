# 模拟与战斗

GDScript 持有模拟状态，Godot 场景组织节点、资源和物理空间。`ServerBody` 管理实体 RID，`ActorBody` 持有位置、姿态、移动和生命值，`GunBody` 推进手持装备的计时，并读取和更新背包槽位的弹药。`ActorStep` 用同一种输入记录推进单人角色、服务端角色和联机本地预测。 [角色步进](../core/sim/actor_step.gd) · [物理体](../core/sim/server_body.gd)

单人 `Level0` 和服务端 `AuthorityWorld` 各持有一个 `CombatSimulator`。服务端每个 tick 先推进掉落物，再按角色 ID 处理输入、拾取、丢弃与移动，收集动作。Beta 回溯与账户推进完成后，统一处理出手、弹丸运动和到期爆炸。最后提交地形和回合变化，采集权威状态。单人在物理步进开始时提交上一 tick 的地形与历史，并为当前 tick 结算时间场。角色、敌人和弹丸读取当前关卡的时间场。 [战斗模拟](../core/sim/combat_simulator.gd) · [服务端步进](../server/authority_world.gd)

`PlayerStateSchema` 集中定义联机角色快照的槽位、编码类型和预测校正诊断名。单人世界回溯只采集位置、速度、朝向、生命、倒地、装备实例、背包和手持装备状态。 [联机快照](../core/sim/player_state_schema.gd) · [单人记录](../scenes/player/player.gd)

## 物理查询

`CollisionWorld` 复用 Godot 查询参数。角色按 X、Y 轴依次调用 `PhysicsServer2D.body_test_motion()`，弹丸按本步位移扫掠。光束、爆炸和遮挡使用物理空间的形状与射线查询。实体的碰撞 RID 关联其节点身份。角色有四个形状槽，当前姿态占本体槽，其余供接缝副本使用。 [碰撞查询](../core/sim/collision_world.gd)

| 物理层 | 位值 | 对象 |
|---|---:|---|
| 1 | 1 | 地形 |
| 2 | 2 | A 队及未分队玩家 |
| 3 | 4 | 单人敌人 |
| 4 | 8 | 地面武器 |
| 5 | 16 | B 队 |

## 伤害结算

出手动作记录武器类型、射击序号、枪口、方向、蓄力与速度倍率。散射用角色和射击序号生成种子。`ShotRules` 判定弹丸、光束与近战的命中，`CombatSimulator` 统一应用伤害和击退，`CombatProfiles` 提供目标关系、无敌帧、水体与击退规则。普通弹丸与光束跳过自身和队友，爆炸可造成自伤与友伤。光束每次出手按实体和宏观瓦片去重。榴弹首次触碰时开始引信，射程耗尽也会引爆。 [弹道规则](../core/sim/shot_rules.gd) · [接触规则](../core/sim/combat_profiles.gd)

爆炸开始时发出表现事件。单人在当步结算范围伤害，多人在触发后第 3 个 tick 结算，按到期 tick 和爆炸 ID 排序。实体伤害考虑距离和遮挡，地形损伤由 `Terrain` 处理。联机客户端从出手动作推进同一战斗模拟并预测击退，服务端确认实际命中、生命值、倒地和地形变化。 [地形](terrain.md) · [联机系统](netplay.md)
