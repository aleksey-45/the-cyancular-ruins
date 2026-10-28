# 爆炸击退同步与校正

2026-10-23。本记录为接入爆炸推力预测之前的验证，区分模拟位置的权威校正和画面上的反向跳动。后续实现与实测见 [爆炸推力预测验证](blast_prediction_validation.md)。

## 成熟游戏的处理

| 项目 | 源码或文档中的做法 | 适用范围 |
|---|---|---|
| Quake III | 从权威状态重放输入，在相同命令时间比较预测误差；视图单独衰减误差；服务端发送弹丸爆炸事件，客户端按事件位置播放 | 运动校正和爆炸结果分别有明确的时间与位置 |
| DDNet | 客户端预测弹丸、爆炸及作用力；预测侧 `TakeDamage` 修改速度 | 预测世界需要掌握弹丸与角色的共同时间线；该函数不负责权威扣血和死亡 |
| Unreal CMC | 未预测的服务器外力会产生前向校正；只建议预测已确定、无法取消的他人移动效果 | 他人命中尚未发生时不能保证预测正确；关键状态可以及时促发更新 |

来源：[Quake III 预测](https://github.com/id-Software/Quake-III-Arena/blob/master/code/cgame/cg_predict.c)、[视图误差衰减](https://github.com/id-Software/Quake-III-Arena/blob/master/code/cgame/cg_view.c)、[服务端爆炸事件](https://github.com/id-Software/Quake-III-Arena/blob/master/code/game/g_missile.c)、[客户端事件表现](https://github.com/id-Software/Quake-III-Arena/blob/master/code/cgame/cg_event.c)；[DDNet 爆炸预测](https://github.com/ddnet/ddnet/blob/master/src/game/client/prediction/gameworld.cpp)、[预测侧受击](https://github.com/ddnet/ddnet/blob/master/src/game/client/prediction/entities/character.cpp)；[Unreal 移动能力实践](https://dev.epicgames.com/community/learning/tutorials/ywD1/unreal-engine-best-practices-for-networked-movement-abilities)、[AActor.ForceNetUpdate](https://dev.epicgames.com/documentation/unreal-engine/API/Runtime/Engine/AActor)。

结合这些实现可以推断：预测侧尚不知道的爆炸结果仍需要权威校正；共享弹丸预测能减少已知轨迹造成的误差，但也需要一致的角色、地形和引信时间。运动重放、视图误差衰减与爆炸结果事件应分别保持一致。

## 当前实现

### 预测重放与画面插值

`PredictionRollback.reconcile` 只重放模拟状态。完成后，使用校正前最后一个真实预测 tick 的位移重新对齐插值起点；`begin_visual_step` 由正常预测推进调用。相同渲染时间下，首次收到强击退不会让画面先向击退反方向跳动。

行为探针覆盖静止、700 px/s 移动两种状态：收到 3000 px/s 冲量后，模拟位置正确前进；保持渲染时间不变时，可见位置误差小于 0.01 px；下一真实预测 tick 显示击退移动。修改前该断言失败，修改后通过。原始日志为 `.test_logs/explosion_visual_replay_before.log` 和 `explosion_visual_replay_after.log`。

### 当前 tick 的击退状态

显式击退命中造成伤害或改变冲量时，将受影响角色记入本 tick 的集合。地形变更和碰撞提交完成后发送完整 STATE：偶数 tick 使用普通 30 Hz 更新，奇数 tick 只对集合内的玩家补发一次。STATE、差量 ACK、重连及地形版本流程共用现有实现。`impact_state` 日志记录 tick、角色、是否额外更新及地图版本；普通弹丸的显式击退也计入该日志。

真实计时榴弹探针验证：奇数 tick 的两次爆炸只生成一次定向更新；只有冲量、没有 HP 损失时仍及时更新；偶数 tick 无重复更新；后续无爆炸时恢复普通频率。这消除了奇数 tick 最多 16.67 ms 的固定等待，不包含传播或客户端轮询时间。

击退强度、碰撞、误差计数阈值和 50 ms 视觉平滑时长保持当前配置。伤害、死亡和地形仍由服务端结算。

### 权威爆炸结果与动画

`EXPLOSION` 走现有可靠 EVENT lane，每次爆炸向全部客户端发送一次。包体含弹丸 ID（U64）、武器类型（U8）、位置（两个 F32）和 tick（U32），加事件标识共 22 字节，随后使用现有传输压缩。客户端按环面最近副本定位爆炸、结束仍存活的视觉弹丸，并使用武器场景配置播放完整动画和碎屑。

多人视觉弹丸本地引信结束飞行；爆炸表现由权威事件触发。客户端不结算伤害和地形。单人弹丸继续在本地结算时调用同一表现函数。`explosion` 日志以稳定弹丸 ID 关联权威结算与客户端表现，并记录客户端收到的服务端 tick。

行为探针验证权威位置、结束飞行弹丸、动画推进和正常结束，检查 HP 与地形不被视觉事件修改；协议探针验证 22 字节往返。另使用实际 OpenGL 渲染保存爆炸前后截图，确认榴弹和爆炸可见。

## 实测记录

两次对局均为正式游戏路径、八人 Beta 大乱斗、强制公网 UDP 中继，包含移动、跳跃、攀爬、互射、地形破坏和一次主动重连。先做 60 秒验证定位剩余问题，再对新增的爆炸结果同步做一次 24 秒定向验证。没有重复运行网络矩阵。

| 指标 | 插值与击退状态修复后，60 秒 | 加入权威爆炸事件后，24 秒 |
|---|---:|---:|
| RTT 中位数 / P95 | 49 / 52 ms | 51 / 57 ms |
| 权威爆炸 / 客户端表现数 | 18 / 144 | 6 / 48 |
| 同弹丸 ID 的表现延迟中位数 / P95 / 最大值 | 51 / 1602 / 2502 ms | 36 / 40 / 40 ms |
| 同弹丸 ID 的环面爆炸位置误差 P95 | 656.61 px | 日志精度下 0 px |
| 重复爆炸表现 | 0 | 0 |
| ≥8 / ≥32 / ≥128 px 物理校正 | 187 / 48 / 15 | 72 / 22 / 3 |
| 已记录的校正前后表现步长对比数 / 最大差 | 81 / 0.00006 px | 26 / 0 px |
| 对战阶段 >50 ms 卡顿 / 处理阶段卡顿 | 0 / 0 | 0 / 0 |
| 对战阶段完整采样窗口的最大帧耗时 | 30.96 ms | 27.81 ms |
| 八端最终同 tick 收敛误差 | 全部 0 px | 全部 0 px |

时间差使用同机各进程记录的 UTC 时间；爆炸以稳定实体 ID 配对，几何误差使用测试地图 2048×2560 px 的环面最短距离。位置误差只表示日志精度下的结果。帧耗时排除启动、地图初始化和结算；原始日志保留这些阶段的慢记录。60 秒场包含 35 秒正式网络计量窗口，合计 280 客户端秒，网络播放断供为 0；24 秒场未启用该窗口，不给它套用网络断供百分比。

24 秒场全部中继路由检查通过，直接相邻链路均为 UDP；GNS 发送排队、待发可靠事件、发送错误、缺失差量基线的采样均为 0，武器不一致采样为 0。7 项相关逻辑/场景探针通过：`authority_probe`、`playback_lifecycle_probe`、`protocol_probe`、`explosion_pipeline_probe`、`grenade_smoke`、`bullet_tile_fx_smoke`、`weapon_inventory_smoke`；实际渲染捕获另通过一次。

### 剩余的物理校正

24 秒场的 3 次 ≥128 px 校正分别为 143.93、164.48、153.21 px。均在首次收到新增约 2694–3000 px/s 冲量时发生，重放 4–5 tick；对应命中结算到校正间隔为 45–46 ms。同次命中分组内没有第二次大幅校正。60 秒场的 15 次也均伴随新冲量。

这支持“新增外力到达前存在预测误差”的解释，不能据此证明所有碰撞和命中预测都正确。这两场的客户端只预测弹丸飞行，推力由权威状态确认，因此存在物理校正，不能归咎于网络波动。两场长度、命中和地形不同，不能把 15 与 3 的差异写成校正次数改善比例。这一阶段验证了插值连续性、奇数 tick 更新等待和爆炸表现的时空一致性。

### 日志与源码

- `.test_logs/network/gns_explosion_response_relay_8/`：60 秒场的游戏、EasyTier、引擎日志、结果及分析。
- `.test_logs/network/gns_explosion_outcome_relay_8/`：24 秒场的对应日志；`explosion_timing.json` 含逐弹丸时延，`hit_timing.json` 含 3 次校正的时间和冲量。
- `.test_logs/network/gns_explosion_outcome_source_sha256.json`：144 个运行和夹具文件的 SHA-256；测试后复核全部一致。
- `.test_logs/explosion_knockback_validation.json`：两场汇总、逐条表现与卡顿记录。
- `.test_logs/explosion_knockback_logs_20261023.zip`：本轮两场原始日志、汇总、源码校验和定向探针证据。
