# 爆炸推力预测验证

2026-10-23，已知引信预测阶段的验证记录。当前全武器实现与最新测试见 [统一击退预测验证](combat_prediction_validation.md)。本组八人公网 UDP 中继短测记录 6098 次普通对账，≥128 px 校正为 0；全流程有 87 次 ≥8 px、31 次 ≥32 px 校正，其中一次 ≥32 px 属于开局时钟重置。短测结果不代表所有战局、网络条件下均无大幅校正。

## 模拟与命中判定

普通弹丸、激光、榴弹触碰及爆炸结算通过 `AuthorityWorld.damage → Player.take_hit → CombatComponent.take_hit → apply_impulse` 进入同一受击运动实现。已知爆炸的预测侧也调用 `apply_impulse`；位移、碰撞和指数衰减统一由 `ActorStep` 调用 `apply_knock` 推进，STATE 同步同一个 `knock` 向量。

命中判定保留武器各自的规则：普通弹丸进行连续碰撞检测，激光追踪光束路径，爆炸计算范围、掩体和水体衰减。本组测试的提前预测覆盖已知引信的爆炸；普通弹丸、激光命中在本组记录中由服务端确认。

参考 [DDNet 的爆炸预测](https://github.com/ddnet/ddnet/blob/master/src/game/client/prediction/gameworld.cpp)及[预测侧力的应用](https://github.com/ddnet/ddnet/blob/master/src/game/client/prediction/entities/character.cpp#L634)，将推力放进角色模拟时间线。DDNet 的[弹丸预测](https://github.com/ddnet/ddnet/blob/master/src/game/client/prediction/entities/projectile.cpp)也在预测世界中触发爆炸。网络外力校正的适用边界见 [Epic 移动能力实践](https://dev.epicgames.com/community/learning/tutorials/ywD1/unreal-engine-best-practices-for-networked-movement-abilities)。

## 引信与生命周期

1. 服务端在首次启动引信的 tick 结束时，将弹丸位置、速度、已飞行距离和引信进度组成 `BULLET_FUSE`。地形事件和碰撞提交先完成，同 tick 的多个引信共用一条可靠消息。一个弹丸的消息为 57 字节；持续 STATE 不增加弹丸数据。
2. 客户端提交地形碰撞后，以该种子复用真实 `BulletBase.simulate_tick` 推进剩余引信，得到爆点及绝对模拟 tick。临时弹丸只执行运动查询，不进入弹丸组，不产生伤害、动画、碎屑和弹道轨迹。
3. 在所有角色完成该 tick 移动后，使用共用的 `Explosion.player_effect` 和 `CombatComponent.apply_impulse` 修改本地角色及对手预测体的运动。服务端弹丸与客户端同 tick 爆炸均按实体 ID 递增处理，保持冲量覆盖顺序一致。
4. 首次预测在相同 tick 播放爆炸；重放只推进状态。服务端的 22 字节 `EXPLOSION` 确认爆点与 tick，按稳定弹丸 ID 合并表现。STATE 已覆盖的冲量从待重放集合移除，不再重复施加。
5. 重连基线恢复活动引信。Beta 暂停时取消该射手尚未确认的预报；恢复时发送新引信种子。仍存活弹丸的表现标记随 Beta 状态重建，房间和回合基线清空表现集合。

生命值、死亡和地形结算保持服务端权威。单人使用同一受击运动入口及本地爆炸结算。

## 定向复现

`authority_probe` 使用真实权威世界、真实榴弹及同一输入对照预测：在尚未收到命中确认时，预测运动与权威运动误差为 0；该场景省略爆炸推力会缺少 184.148 px 位移。验证恢复到爆炸前状态后重放、确认预测结果、以及恢复到爆炸后状态均不重复施力。

该探针还覆盖真实地形反弹、跨环面飞行、Beta 暂停及恢复后的新引信事件；逆序创建和逆序接收的同 tick 爆炸必须保持相同冲量覆盖顺序。`playback_lifecycle_probe` 验证预测动画与权威确认只播放一次，动画正常推进和结束。六项相关探针通过：`authority_probe`、`playback_lifecycle_probe`、`protocol_probe`、`explosion_pipeline_probe`、`grenade_smoke`、`ammo_rollback_probe`。

## 公网中继实测

每场为 24 秒八人 Beta 大乱斗，运行正式游戏、GNS 和官方 EasyTier，包含一次主动断线重连。分别验证推力接入、表现对齐及并发顺序，保留各阶段源码校验和原始日志。

联机场次以 headless 运行；另用单客户端 OpenGL 探针捕获预测爆炸与权威确认合并后的动画。下表帧耗时反映该模拟负载，不代表同时显示八个游戏窗口时的 GPU 性能。

| 指标 | 推力接入 | 推力与表现对齐 | 最终代码：统一并发顺序 |
|---|---:|---:|---:|
| RTT 中位数 / P95 / 最大值 | 60 / 70 / 71 ms | 50 / 54 / 60 ms | 58 / 94 / 133 ms |
| ≥8 / ≥32 / ≥128 px 校正 | 88 / 23 / 1 | 60 / 18 / 0 | 87 / 31 / 0 |
| 普通对账次数 | 5969 | 6296 | 6098 |
| 权威榴弹爆炸 / 客户端爆点预报 | 6 / 48 | 6 / 48 | 6 / 48 |
| 预报爆炸 tick 最大误差 | 0 | 0 | 0 |
| 预报爆点最大环面误差 | 0.0047 px | 0.0024 px | 0.0445 px |
| 客户端爆炸表现 / 重复表现 | 48 / 0 | 48 / 0 | 48 / 0 |
| 由预测触发的爆炸表现 | 0 | 48 | 48 |
| 单次预报 CPU 耗时 P95 / 最大值 | 未记录 | 0.287 / 1.284 ms | 0.352 / 0.854 ms |
| 对战阶段 >50 ms 卡顿 | 0 | 0 | 0 |
| 对战阶段超过一 tick 的处理记录 | 3 | 0 | 0 |
| 完整采样窗口最大帧耗时 | 44.80 ms | 32.04 ms | 27.75 ms |
| 八端最终同 tick 误差 | 全部 0 px | 全部 0 px | 全部 0 px |

第一场唯一的大幅校正为 role 3、tick 598、134.56 px。服务端 tick 597 记录射手 8 的重狙命中并致死，HP 从 20 降为 -10；该 tick 没有榴弹爆炸。该样本属于尚未预测的普通弹丸命中。第一场还有一次 1324 ms 的 HIT 到达间隔，以及集中收包时 18–20 ms 的派发记录，完整保留于日志，不能将其描述为全程无网络波动。

最终场 48 份预报均命中权威爆炸 tick；预报 CPU 最大 0.854 ms，未引入长时间阻塞。所有隧道路由检查通过，直接相邻链路均为 UDP；GNS 发送排队、待发可靠事件、发送错误和缺失快照基线的采样均为 0，武器不一致采样为 0。43 次详细对账中的校正前后表现步长差均为 0。

预测表现使用本地预测时间，最终场相对服务端结算墙钟的有符号时间差中位数为 -63 ms，表示客户端提前表现已知结果；这不是负的网络延迟。模拟时刻以 tick 对齐，不能用不同时间线的墙钟差替代位置和 tick 一致性检查。

三场长度相同，命中、角色分配、地形与链路仍有不同，不据此计算校正次数改善百分比。短场未开启正式网络断供统计窗口，不报告网络卡顿百分比；帧耗时排除启动和结算。未来地形变化、Beta 操作或未知命中仍可能改变预测结果，需要权威校正。

## 复核资料

- `.test_logs/blast_force_prediction_probe.log`：定向复现与一致性断言。
- `.test_logs/network/gns_blast_prediction_relay_8/`：推力接入场。
- `.test_logs/network/gns_blast_prediction_final_relay_8/`：表现对齐场。
- `.test_logs/network/gns_blast_prediction_ordered_relay_8/`：最终代码场。
- 每场的 `blast_prediction_analysis.json` 保留逐爆点预报、表现、确认、首次预测推力和校正现场。
- `.test_logs/network/gns_blast_prediction_ordered_source_sha256.json`：最终运行及夹具 143 个文件的校验和，测试后复核一致。
- `.test_logs/blast_prediction_validation.json`：三场原始指标汇总。
- `.test_logs/blast_prediction_logs_20261023.zip`：游戏、EasyTier、引擎日志、指标、源码校验、探针及渲染证据。
