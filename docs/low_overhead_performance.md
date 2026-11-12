# 性能观测

`PerfMonitor` 默认关闭采样。`--perf`、`--perf-summary` 或 `--corr-trace` 启用采样，`--no-perf` 停用采样。调试构建在 Godot 中提供 `Game/` 监视项。

```sh
godot --path . -- --perf
godot --headless --path . res://server/server_main.tscn -- --perf-summary server-perf.json
godot --path . -- --corr-trace corrections.jsonl
```

`--perf` 每秒打印窗口、样本数、主要阶段耗时和校正摘要。`--perf-summary` 在正常退出时写累计 JSON。`--corr-trace` 将校正样本写成 JSONL，否则样本以 `PERF correction_samples=…` 输出。每条校正记录包含权威 tick、本地预测末端、差异字段、环面位置偏差、角色、运行时间和物理帧。 [监视入口](../core/config/perf_monitor.gd)

`PerformanceStats` 为 25 个指标累计样本数、总量、最大值、最大值时间及直方图。`snapshot(false)` 取最近发布窗口，`snapshot(true)` 取累计值。耗时单位为微秒，`over_16667_us` 统计超过 16,667 μs 的样本。`physics_ticks_per_frame` 和 `replay_ticks_per_frame` 的单位为 tick。 [聚合实现与分桶](../core/config/performance_stats.gd)

| 指标 | 测量范围 |
|---|---|
| `server_tick` · `server_simulation` | 服务端物理回调全段 · 快照发送前的模拟阶段 |
| `state_encode_peer` · `state_fanout` | 单连接编码 · 整批准备、编码与发送 |
| `network_poll` · `network_dispatch` · `transport_send` | 原生轮询 · 脚本解码与派发 · 封装和提交 |
| `client_authority` · `client_tick` · `client_present` | 权威接纳 · 客户端物理回调 · 脚本表现 |
| `replay` · `history_save` | 预测恢复与重放 · 检查点保存 |
| `terrain_commit` · `physics_motion` · `physics_ray` · `physics_shape` | 脏地形提交 · 各类物理查询 |
| `callback_interval` | 两次普通帧回调之间的墙钟间隔，包含等待 |

耗时以墙钟计，父阶段会包含子阶段。直方图给出分位数所在区间，校正偏差的精确分位数可从样本计算。`callback_interval` 表示脚本回调间隔，画面呈现间隔由显示侧测量。
