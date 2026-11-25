# 性能监测

`PerfMonitor` 默认关闭性能采样。`--perf` 打印控制台统计，`--perf-summary` 和 `--corr-trace` 分别指定汇总文件和校正记录文件。`--no-perf` 停止采样。调试构建在 Godot 性能监视器中提供 `Game/` 指标。

```sh
godot --path . -- --perf
godot --headless --path . res://server/server_main.tscn -- --perf-summary server-perf.json
godot --path . -- --corr-trace corrections.jsonl
```

监测节点每秒发布一轮统计。`--perf` 输出采样周期、样本数、各阶段耗时和校正摘要。`--perf-summary` 在正常退出时写出累计 JSON。校正样本保存为 JSONL，没有打开跟踪文件时输出到控制台。每个样本包含服务器模拟帧、本地预测最后一帧、校正原因、位置偏差、角色 ID、运行时间和物理帧。[PerfMonitor](../core/config/perf_monitor.gd)

`PerformanceStats` 使用固定大小的数组保存计数、总量、最大值、最大值出现时间和直方图。`snapshot(false)` 读取最近发布的统计，`snapshot(true)` 读取累计值。经过时间以微秒计，`over_16667_us` 统计超过 16,667 微秒的样本。`physics_ticks_per_frame` 和 `replay_ticks_per_frame` 记录每次帧回调之间的物理步数和重放步数。[PerformanceStats](../core/config/performance_stats.gd)

| 指标 | 测量范围 |
|---|---|
| `server_tick` · `server_simulation` | 服务器轮询后处理本步的耗时及采集快照前的模拟耗时 |
| `state_encode_peer` · `state_fanout` | 单个连接的快照编码及整批快照的准备、编码和发送 |
| `network_poll` · `network_dispatch` · `transport_send` | 轮询并整理新消息、脚本解码和分发、封装并提交待发消息 |
| `client_authority` · `client_tick` · `client_present` | 选择并采用权威状态、客户端物理回调、脚本更新画面和界面 |
| `replay` · `history_save` | 恢复服务器快照并重新模拟未确认的输入、记录时间技能历史 |
| `terrain_commit` · `physics_motion` · `physics_ray` · `physics_shape` | 更新地形碰撞、运动查询、射线查询和形状查询 |
| `callback_interval` | 相邻两次普通帧回调之间的间隔，包含等待时间 |

各阶段以实际经过时间计量，外层阶段的耗时包含内部阶段。直方图可定位分位数所在的区间，校正偏差的精确分位数可从逐条样本计算。
