# 统一击退预测验证

本文保留 2026-10-23 的统一击退验证结果。最新实现与实测见[完整受击预测验证](combat_outcome_validation.md)。

## 当前实现

[CombatPrediction](../../core/net/combat_prediction.gd) 保存已知攻击的模拟状态。普通弹丸、霰弹与榴弹触碰共用服务端的 `BulletBase.player_contact` 连续检测和 `WeaponBase.projectile_specs` 散射初态；激光共用 `LaserWeaponBase.path_contact`；爆炸共用范围、掩体和水体计算。命中调用同一 `apply_impulse`，角色步进负责位移、碰撞与衰减。激光在对应射手的角色步进后生效，弹丸与爆炸在所有角色移动后生效。

收到权威状态后，角色恢复到该 tick，弹丸恢复相应运动状态，随后重放未来输入与攻击。`HIT` 携带攻击 ID、命中 tick、来源与权威向量；已包含在 STATE 中的冲量不再施加。榴弹直接触碰标记与引信共用一个状态字节，直接触碰已确认后继续推进引信。Beta 暂停、恢复、换回合与重连重建对应预测状态。

`BULLET_SPAWN` 包含出生 tick，发送给包括射手在内的客户端并按 ID 合并。当前 `HIT` 为 44 字节，包含命中后的权威 HP 和死亡朝向。持续 STATE 不增加弹丸列表。客户端预测已知攻击的 HP、倒地碰撞与受力，确认 HIT 按 tick 覆盖，完整 STATE 还原后重放；最终伤害、地形、弹药与胜负由服务端结算。

参考 [DDNet 预测弹丸](https://github.com/ddnet/ddnet/blob/master/src/game/client/prediction/entities/projectile.cpp)、[预测光束](https://github.com/ddnet/ddnet/blob/master/src/game/client/prediction/entities/laser.cpp)与[预测世界爆炸](https://github.com/ddnet/ddnet/blob/master/src/game/client/prediction/gameworld.cpp)。预测使用已经获知的攻击；未收到开火信息的远端瞬发攻击，以及零到一 tick 内命中的近距离弹丸，无法保证在命中前获知。统一预测入口并不意味着能预知对手的新输入。

## 既有 31 次校正的复核

`gns_blast_prediction_ordered_relay_8` 的 31 次 ≥32 px 包含一次开局时钟重置，战斗内为 30 次。旧日志每秒限频，只留下 20 次战斗现场，另外 10 次无法逐条定因。

已保留现场中：10 次与普通弹丸的权威命中同 tick，客户端此前没有预测对应击退；8 次攀爬现场尚未确认客户端已预测的上、下键切换，存在输入晚到，但缺少逐包收发时间，不能区分中继抖动、发送调度与主线程派发；另两次发生在加速和攀爬运动，证据不足以定因。不能把这 30 次统称为网络波动。

例如重狙 tick 524 的初始冲量为 1800 px/s，未来重放 6 tick，在 10/s 指数衰减下产生约 123.53 px 位移，与该现场的 123.53 px 校正一致。这里缺失的是受击预测；正常 RTT 同样会暴露该缺失。

## 验证范围

12 项针对性检查通过：`authority_probe`、`playback_lifecycle_probe`、`protocol_probe`、`transport_probe`、`explosion_pipeline_probe`、`grenade_smoke`、`ammo_rollback_probe`、`laser_weapon_smoke`、`beam_trace_smoke`、`bullet_tile_fx_smoke`、`enemy_logic_smoke`、`pvp_twin_smoke`。这不是全量回归通过声明。

`authority_probe` 循环六种真实武器，对照权威世界与预测角色，覆盖低血量致死和存活、八颗霰弹、榴弹直接触碰及爆炸、已知激光、确认前后的重复重放、引信阶段中间 ACK 和已覆盖命中去重。纯逻辑对照不能代替对手未知输入和动态碰撞的实战检验。

公开中继每场 24 秒，8 个独立客户端、Beta 大乱斗、一次 token 重连。使用官方 EasyTier 的三个 UDP 中继候选并轮换连接顺序。三场对局的房间、对局和重连断言均通过，最终同 tick 收敛误差均为 0 px，武器不一致采样为 0。

| 运行目录后缀 | 全流程 ≥32 px | 开局时钟重置 | 战斗内 ≥32 px | 战斗内 ≥128 px | 战斗内 >50 ms 卡顿 |
|---|---:|---:|---:|---:|---:|
| `unified_impact_relay_8` | 8 | 6 | 2 | 0 | 0 |
| `unified_impact_final_relay_8` | 7 | 4 | 3 | 0 | 46 |
| `unified_impact_verified_relay_8`，最终源码 | 13 | 8 | 5 | 1 | 4 |

每场的加入顺序、实际战斗结果与网络不同，不能将计数差写成改善百分比。当前日志完整保留每次 ≥32 px 的现场，原始计数没有放宽阈值或排除战斗中的大误差。第二场的高耗时数据保留；最终源码的阻挡体使用即时物理提交。

## 最终场的命中与连接

- 58 次权威弹丸命中中，54 次在收到 HIT 前已经预测到相同 tick；5 次范围爆炸全部提前预测到相同 tick。另有 3 条预测命中没有权威对应，仍存在误预测。
- 9 次激光命中没有在 HIT 前预测到相同 tick。激光发射即命中，远端首次开火信息到达后才可进入本地时间线，不能将收到命中确认后的重放算成提前预测。
- RTT 采样中位数 57 ms、P95 68 ms、最大 124 ms；HIT 派发延迟中位数约 48 ms、最大约 63 ms。它包含隧道、GNS、主线程轮询和调度耗时。
- 43 个目标路由采样全部为 `relay(2)`，直接邻居协议的 98 个采样全部为 UDP。GNS 采样发送排队及待发事件字节最大为 0，发送错误、STATE 缺基线和过期计数为 0。
- STATE 最大接收间隔采样为 150 ms。同期存在本机卡顿，接收间隔不能单独视为公网断流。每秒传输采样也不能排除未采到的短时抖动。

## 仍未通过的部分

最终场的 5 次战斗校正发生在加速或跳跃期间，没有对应的新权威命中：role 1/tick 1266 为 178.91 px，role 3/tick 1266 为 34.36 px，role 5/tick 1266、1268 为 33.94、34.36 px，role 6/tick 1422 为 60.44 px。

178.91 px 现场在加速启用时，校正前角色水平速度为 0，权威初态速度为 826.29 px/s，重放后恢复前进；前后击退向量接近 0。这是移动预测/接触上下文分歧，不能解释为遗漏子弹击退。对手同时启用加速，碰撞预测是排查方向；现有现场没有逐 tick 接触法线，尚不足以将具体碰撞路径定死。

接入场另有一次 81.73 px 的致死爆炸现场：预测与权威的爆炸 tick、受力位置、3000 px/s 初始向量一致；权威同时确认 HP 从 20 变为 -14 并旋转倒地碰撞体。预测保留存活状态，后续碰撞运动因此不同。它不能算成击退未预测，也不能算成网络抖动。该场另一次 71.06 px 发生在跳跃与邻近角色阻挡预测之间。

最终场记录 846 次超过 16.7 ms 的处理阶段卡顿、4 次 >50 ms 的帧间隔卡顿，最长完整战斗区间帧耗时为 64.78 ms，处理卡顿主要发生在权威恢复和重放区间。单机同时运行 8 个客户端与服务端，当时尚未分离主机调度和各模拟函数的耗时。此项是该阶段未解决的非网络性能问题，该场不能作为无卡顿或整体性能验收通过的依据。

## 证据

- `.test_logs/network/gns_unified_impact_verified_relay_8/`：最终场的游戏、Godot 与 EasyTier 原生日志、结果、逐条校正及命中分析。
- 每场 `unified_impact_analysis.json` 保存逐次 ≥32 px 现场、权威命中和提前预测时序，带原始日志路径和行号。
- `.test_logs/unified_impact_comparison.json`：旧场与三个新场的统计，包含性能不佳的运行。
- `.test_logs/network/gns_unified_impact_verified_relay_8_source_sha256.json`：最终场 145 个源码及夹具文件校验和。
- `.test_logs/unified_impact_logs_20261023.zip`：全部上述日志、分析脚本、目标检查结果与测试源码快照。
