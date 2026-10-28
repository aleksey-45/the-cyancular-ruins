# 角色校正与碰撞验证

2026-10-22，Windows x64、Godot 4.7.1、GNS。后续接触时刻、击退状态、收包顺序与卡顿验证见 [预测与卡顿验证](prediction_stall_validation.md)。

## 当前实现

- 服务端和客户端共用 `ActorCollider`。角色之间保留阻挡，服务端运动体通过遮罩查询地形和对手的静态阻挡体。
- 每次角色步进前更新姿态、倒地旋转和最近环面位置，通过 `force_update_transform()` 立即提交物理变换。
- 客户端从权威快照恢复对手阻挡体，按普通速度及击退逐 tick 推进到对应接触时刻；推进检测地形和本地角色锚点。表现节点使用独立的播放缓冲。
- 角色使用各姿态的凸轮廓，保留原有外接矩形。移动后按接触法线消除向内速度，地面判定通过实际接触生成；`floor_block_on_wall` 为 false。
- 击退位移非零时才执行独立移动。视觉校正为 50 ms；校正计数阈值为 8、32、128 px，排除控制阶段切换和 Beta 回溯。

## 行为复现

自动化测试覆盖立即更新阻挡位置、释放旧位置、接缝两侧阻挡、顶头碰撞、同速跟随、迎面相撞、沿途地形、落地接触缓存、普通夹缝及 16px 残留子格。

实局捕获的破坏后地形与角色状态为 `gns_contact_velocity_capture_8/server/diagnostics/physics/1_3387.bin`。相同现场离线重放 180 tick：

| 指标 | 捕获现场的复现 | 当前实现 |
|---|---:|---:|
| 第一个采样的接触法线 | (0, 1) | (0, -1) |
| 第一个采样的地面判定 | false | true |
| 第 150 tick 的垂直速度 | 8026.647 px/s | 10.000 px/s |
| 当前实现的后续采样速度 | — | ≤150 px/s，正常弹性反弹 |

角色的运动参数保持在 `PlayerParams`，移动速度由输入、加速倍率和碰撞约束决定。

## 两轮八人公网中继

两轮采用相同参数：120 秒真实 Beta 大乱斗、三台公网 UDP 中继候选、禁用 P2P、客户端轮换候选顺序、一次 token 重连、60 秒墙钟网络计量。八端均完成移动、跳跃、攀爬和射击，自然结束并回到原房间。

| 指标 | 第一轮 | 重复轮 |
|---|---:|---:|
| ≥8 / ≥32 / ≥128 px 校正 | 635 / 199 / 30 | 638 / 181 / 9 |
| ≥128 px 中带 >100 px/s 权威击退 | 24 | 8 |
| ≥128 px 中其余样本 | 6 | 1 |
| 停止输入后的误差 | 八端均 0 px | 八端均 0 px |
| GNS RTT 中位数 / P95 / 最大 | 55 / 74 / 373 ms | 53 / 72 / 227 ms |
| 有效网络计量 | 6/8 端，360 客户端秒 | 7/8 端，420 客户端秒 |
| 有效计量中的网络播放断供 | 0.181110 s（0.05031%） | 0.015035 s（0.00358%） |
| 服务端 tick 最大耗时 | 30.402 ms | 25.143 ms |
| 角色速度每秒采样最大值 | 2425.4 px/s | 2392.7 px/s |
| 榴弹爆炸次数 / 最大处理耗时 | 33 / 7.343 ms | 8 / 5.965 ms |
| 武器不一致样本 / 发送错误 | 0 / 0 | 0 / 0 |

校正计数覆盖整局。两轮到房主的路由各有 200 条 `relay(2)` 采样，直接邻居的协议各有 450 条 UDP 采样；可靠队列积压采样均为 0。

第一轮两个客户端的最大帧间隔为 56.849 ms、51.335 ms；重复轮一个客户端为 54.355 ms。这些客户端按既有统计规则排除出网络断供计量，不计为网络卡顿。

校正没有归零。重复轮剩余 1 条非明显击退的 ≥128 px 样本，发生在加速起步时（tick 1270，180.676 px）。第一轮其余 6 条样本保存在逐次日志中。击退幅度分类不能单独证明校正原因；对手后续输入和伤害由服务端确认，客户端的对手碰撞预测使用已知速度。两轮实际到包顺序与对局过程不同，以上计数不是固定负载性能对照。

## 回归与原始记录

- 网络探针 6/6，视觉探针 8/8，Python 网络统计 4/4，命名及路径检查通过。
- 单元与场景测试 63/64；`elite_drop_probe` 输出成功后以 3221225477 退出，仍按失败记录。
- 双人 120fps：40–100 ms 波动 RTT、0.1%–0.5% 波动丢包；六人：80–200 ms 波动 RTT、0.2%–1% 波动丢包。两场均通过，重连完成，停止输入后所有客户端误差为 0 px。
- 原始目录：`.test_logs/network/gns_convex_correction_fix_relay_8/`、同名 `_repeat/`、`gns_correction_fix_2_100ms/` 和 `gns_correction_fix_6_200ms/`。
- 汇总为 `.test_logs/correction_validation.json`。离线重放记录为 `.test_logs/velocity_snapshot_baseline.log`、`.test_logs/velocity_snapshot_final.log`，逐次校正为各八人目录中的 `stutter_causes.json`。

参考：[Godot 2D 碰撞形状](https://docs.godotengine.org/en/stable/tutorials/physics/collision_shapes_2d.html)、[CanvasItem 变换提交](https://docs.godotengine.org/en/stable/classes/class_canvasitem.html#class-canvasitem-method-force-update-transform)、[CharacterBody2D 移动实现](https://github.com/godotengine/godot/blob/4.6-stable/scene/2d/physics/character_body_2d.cpp)、[物理后端变换处理](https://github.com/godotengine/godot/blob/4.6-stable/modules/godot_physics_2d/godot_body_2d.cpp)。行为结论由本机 Godot 4.7.1 探针和实局重放验证。
