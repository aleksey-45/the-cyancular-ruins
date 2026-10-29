# 调研资料索引

各报告只记录资料能支持的结论、可参考的做法及当前采用情况。商业游戏报告反映其公开时的设计；讲座摘要、专利或开发计划不能作为已经落地的实现证据。

| 主题 | 报告 |
|---|---|
| 大型游戏、游戏公司讲座与技术报告 | [行业资料](netcode_industry_reading.md) |
| 输入、状态、时效、复用与传输 | [联机基础](netcode_architecture_research.md) |
| 武器、爆炸、受击和表现确认 | [战斗预测](combat_prediction_research.md) |
| 因果依赖、局部重放与交互时间线 | [局部重放](selective_replay_research.md) |
| LoL、CS 与客户端预测范围 | [预测边界](lol_cs_prediction_boundaries.md) |
| Minecraft 的移动、方块与实体同步 | [Minecraft](minecraft_prediction_boundaries.md) |
| 高频状态、原生代码与场景所有权 | [模拟数据边界](pure_data_simulation_research.md) |
| 地形指令、批量事件与局部失效 | [地形边界](native_terrain_boundary_research.md) |
| 公共编码、差分和快照所有权 | [STATE 编码](state_encode_performance_review.md) |
| 测试取舍、轻量聚合与专项采样 | [测试与监视](testing_and_monitoring_research.md) |

实现规则见[联机系统](netplay.md)、[本地预测](local_prediction_design.md)、[原生模拟](native_scene_simulation.md)和[原生地形](native_terrain.md)。测试命令与指标口径分别见[检查说明](tests.md)和[性能观测](low_overhead_performance.md)。
