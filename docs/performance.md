# 性能监测

`PerfMonitor` 默认关闭性能采样。`--perf` 在控制台输出统计信息，`--perf-summary` 和 `--corr-trace` 分别指定性能汇总和预测校正记录的文件路径。`--no-perf` 覆盖其他选项，关闭采样。调试构建在 Godot 性能监视器中提供 `Game/` 指标。

```sh
godot --path . -- --perf
godot --headless --path . res://server/server_main.tscn -- --perf-summary server-perf.json
godot --path . -- --corr-trace corrections.jsonl
```

监测节点约每秒发布一次统计。`--perf` 输出统计窗口时长、样本数、部分阶段的平均和最大耗时，以及校正摘要。`--perf-summary` 在正常退出时将累计统计写入 JSON 文件。`--corr-trace` 将校正样本逐条写入 JSONL 文件，文件未打开时输出到控制台。每条样本包含服务器模拟帧号、校正后的本地预测帧号、校正原因、位置偏差、角色 ID、进程启动后的耗时（毫秒）和引擎物理帧计数。[PerfMonitor](../core/config/perf_monitor.gd)

`PerformanceStats` 使用固定大小的数组保存计数、总量、最大值、最大值出现时间和直方图。`snapshot(false)` 读取最近发布的统计，`snapshot(true)` 读取累计值。耗时以微秒计，`over_16667_us` 统计耗时超过 16,667 微秒的样本。`physics_ticks_per_frame` 和 `replay_ticks_per_frame` 则记录相邻两次 `_process()` 回调之间执行的物理步数和重放步数。[PerformanceStats](../core/config/performance_stats.gd)

| 指标 | 测量范围 |
|---|---|
| `server_tick` · `server_simulation` | 服务器轮询后处理一个模拟步的总耗时，以及其中推进模拟的耗时 |
| `state_encode_peer` · `state_fanout` | 单个连接的快照编码耗时，以及整批快照的准备、编码和提交发送耗时 |
| `network_poll` · `network_dispatch` · `transport_send` | 轮询并整理新消息、脚本解码和分发、封装并提交待发消息 |
| `client_authority` · `client_tick` · `client_present` | 应用服务器快照、处理客户端物理帧回调，以及在脚本中更新画面和界面 |
| `replay` · `history_save` | 恢复服务器快照并重放未确认输入，以及记录时间技能历史 |
| `terrain_commit` · `physics_motion` · `physics_ray` · `physics_shape` | 更新地形碰撞、运动查询、射线查询和形状查询 |
| `callback_interval` | 相邻两次 `_process()` 回调之间的间隔，包含等待时间 |

各阶段记录实际经过的时间，外层阶段的耗时包含内部阶段。耗时直方图可用来估计分位数所在的区间，校正位置偏差的精确分位数可从逐条样本计算。
