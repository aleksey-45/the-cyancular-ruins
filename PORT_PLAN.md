# 模拟与物理结构（索引）

本文只保留目录、所有权与必须保持的约束；行为细节见[场景内模拟](docs/eng/simulation.md)、[地形](docs/eng/terrain.md)、[战斗模拟](docs/eng/combat_simulation.md)、[联机](docs/eng/netplay.md)与[说明索引](CLAUDE.md)。不记录演进过程。

## 1. 运行形态与目录

- 引擎为 Godot 4.7.1 标准版；模拟逻辑全部是 GDScript。
- 仅有的原生扩展是 `native/gns/`（UDP 传输）与 `native/process_group/`（进程句柄），不参与模拟。
- 环形世界：逻辑坐标区间为 `[0, width) × [0, height)`，由 `GridPathfinder.wrap_to_range()` 与 `anchor_to_nearest()` 统一维护。
- 碰撞求解只有一套：Godot 物理。工程内不存在手写的角色矩形裁剪、弹丸中心距扫掠或激光矩形相交。

```text
core/sim/      角色、弹丸、武器、地形、战斗、爆炸、环面工具
core/net/      输入、编解码、预测回滚、历史帧、弹丸记录、会话
core/config/   参数、静态配置与固定容量性能统计
core/present/  相机、激光视觉、后处理、音效、字体
scenes/        场景与表现层脚本
server/        权威世界、房间会话、局规则、时间经济、Beta 回溯
tests/         无头行为检查与编辑器检查
tools/         构建、打包与规范检查脚本
native/        gns 与 process_group 扩展（不参与模拟）
data/          weapons.json / enemies.json / tile_defs.json
```

## 2. 核心所有权

| 类 | 文件 | 职责 |
|---|---|---|
| `ActorBody` | [actor_body.gd](core/sim/actor_body.gd) | 角色运动、输入、状态捕获与恢复 |
| `ServerBody` | [server_body.gd](core/sim/server_body.gd) | 自管 RID 的创建、空间挂接、层写入和释放；ActorBody 同步角色姿态与接缝镜像 |
| `CollisionWorld` | [collision_world.gd](core/sim/collision_world.gd) | 物理空间适配、层常量、RID→role、查询复用与碰撞层归属 |
| `BulletBody` | [bullet_body.gd](core/sim/bullet_body.gd) | 弹道运动、命中分类、引信、反弹、水阻 |
| `WeaponBody` | [weapon_body.gd](core/sim/weapon_body.gd) | 瞄准、冷却、装填、开火缓冲、散射规格 |
| `Terrain` | [terrain.gd](core/sim/terrain.gd) | 网格与 16px 子格 HP、碰撞分块、预测差分、权威基线、回溯 |
| `CombatSimulator` | [combat_simulator.gd](core/sim/combat_simulator.gd) | 弹丸/爆炸/光束推进、命中归属、确认结果与结算顺序 |
| `Explosion` | [explosion.gd](core/sim/explosion.gd) | 候选查询、遮挡、衰减、击退、水域与瓦片扫描 |
| `PredictionRollback` | [prediction_rollback.gd](core/net/prediction_rollback.gd) | 本地输入时钟、历史比较、后缀重放 |
| `PredictionWorld` | [prediction_world.gd](core/net/prediction_world.gd) | 唯一模拟 tick、稳定角色槽、按 role 推进和整世界捕获/恢复 |
| `PredictionHistory` | [prediction_history.gd](core/net/prediction_history.gd) | 全部角色和玩法预测域的有界世界检查点 |
| `CombatPrediction` | [combat_prediction.gd](core/net/combat_prediction.gd) | 本地攻击结果、确认与依赖复核 |

场景层继承关系：`Player : ActorBody`、`BulletBase : BulletBody`、`WeaponBase : WeaponBody`、`EnemyBase : ServerBody`。场景负责资源、节点生命周期与表现，模拟只读写同一份状态。

## 3. 坐标与碰撞

| 层值 | 用途 |
|---|---|
| 1 | 地形分块静态体 |
| 2 / 16 | 两支队伍的玩家代理 |
| 4 | 敌人物理体 |
| 8 | 地面掉落物 |

- 物理查询、命中结算与快照一律使用规范坐标；渲染才按最近展示副本平移，视觉偏移不写回参与碰撞的变换。
- 弹丸用 `PhysicsServer2D.body_test_motion()` 连续扫掠；位移超过 `SEAM_REACH` 时按接缝拆段，每个出口回绕到规范区间。
- 角色阻挡使用 `PhysicsServer2D.body_test_motion()`；爆炸/光束使用 `intersect_shape()` 与 `intersect_ray()`。光束接触由 `CollisionWorld.beam_contacts()` 唯一给出。
- 地形物理只补接缝附近的必要镜像；完整 3×3 平铺只属于 TileMapLayer 的可视副本。
- 静态 RID 体改动形状后必须重设自身变换，否则同一物理帧的查询仍是旧几何。

## 4. 每 tick 顺序

```text
恢复/接收该 tick 的权威状态
-> 恢复地形 HP 并提交增量 chunk
-> 同步角色规范位姿与姿态到碰撞代理
-> 按 role 固定顺序推进角色，推进后刷新其代理
-> Beta 回溯路径与弹丸恢复，再推进本地账户
-> 全部弹丸按 ID 升序推进并结算直接命中
-> 按 (due_tick, entity_id) 结算到期爆炸并更新地形 HP
-> 记录世界历史与网络快照
-> 渲染阶段同步视觉副本、动画与 FX
```

## 5. 预测与网络

- `PredictionWorld` 拥有唯一整数 tick，所有角色每轮每 tick 按 role 推进一次；`PredictionFrame` 保存完整预测世界，`ProjectileSnapshot` 保存每帧弹丸。
- 权威接纳只比较同 tick 的全部预测状态与控制，不改动物理空间。STATE 和事件失效都恢复整世界，经同一个循环重放。
- `NetCodec`：`WIRE_MAGIC=199`、`PROTOCOL_VERSION=7`；INPUT/STATE/EVENT 三条流，STATE 相对已确认基线做差分。
- `NetBus`：单进程单端口，UDP 经 GNS 扩展；STATE 按 peer 合并保留最大序号，可靠事件有序排队。
- `server/authority_world.gd` 以 60Hz 模拟，偶数 tick 广播全量目标、奇数 tick 只发给受影响角色。
- `scenes/pvp_match_client.gd` 在物理帧接纳权威状态并推进预测，在表现帧插值渲染远端与掉落物。

## 6. 验证与约束

```bash
python tools/check_naming.py
"$GODOT" --headless --editor --path . --import
"$GODOT" --headless --path . res://tests/run.tscn -- --groups terrain,simulation,net,monitor
"$GODOT" --headless --path . --quit-after 90
```

必须保持：

- 同一逻辑 tick 只有一个推进顺序定义，弹丸结算顺序按 entity ID 升序。
- 状态数组是唯一事实来源；物理空间只是当前 tick 的碰撞索引，回滚不等待下一引擎物理帧。
- 地形继续维护 16px HP、dirty chunk、贪心布局、占用签名与布局缓存；TileMapLayer 只负责渲染。
- 地形保持边界局部镜像，内部几何不复制九份。
- RID 所有权：`Terrain` 分配/释放地形分块与共享形状；`ServerBody` 创建/释放实体 RID，`ActorBody` 同步角色形状；`CollisionWorld` 持有查询参数；场景退出时按所有者释放。
- 固定槽位结构（`Packed*`、按索引读写、稳定 RID、复用查询参数）继续用于热路径，不改成每 tick 构造节点或 Dictionary 事件。
