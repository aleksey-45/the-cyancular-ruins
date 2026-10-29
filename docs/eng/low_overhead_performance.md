# 性能观测

[PerfMonitor](../../core/config/perf_monitor.gd) 管理 [NativePerformanceStats](../../native/simulation/performance_stats.h) 的固定容量统计。默认采集阶段耗时与计数，每秒发布一个窗口；每个样本只更新标量，不构造世界、角色、数据包或逐帧记录。

## 使用

用户参数放在 Godot 的 `--` 后：

```bash
godot --path . -- --perf
godot --headless --path . res://server/server_main.tscn -- --perf-summary /path/to/server-perf.json
godot --path . -- --no-perf
```

`--perf` 每秒打印一次窗口时长、样本数、均值及最大值，时间单位为 us。`--perf-summary <path>` 在正常退出时写一次聚合 JSON；每个进程使用独立路径，异常退出不保证有汇总。`--no-perf` 停用原生采样和监视节点回调，调用点保留关闭检查。

调试构建提供 Godot `Game/` 自定义监视值。原生 `snapshot(false)` 读取最近发布窗口，`snapshot(true)` 读取累计值；`reset()` 清空统计。数据不包含玩法状态，可用于观察趋势和定位需要进一步分析的阶段。

## 容量与统计

21 个指标在主线程聚合，包含样本数、总量、最大值、最大值发生时间、超阈值数和固定直方图。原生聚合 Storage 以静态断言限制在 16 KiB 内；该预算不含引擎监视回调、导出临时数据或游戏本身。

时间桶上界为 100、250、500、1000、2000、4000、8000、16667、33334、66667 us，另有溢出桶。分桶只能提供范围，不能生成精确 p95/p99。计数指标以 tick 为单位，不能套用 us。

| 指标 | 口径 |
|---|---|
| server_tick / server_simulation | AuthorityWorld 物理回调（含同步发送），以及 STATE 捕获前的玩法；后者包含规则、地形和事件广播，并非纯物理核 |
| world_capture / state_prepare | 实际公共捕获、逐 peer 私有准备；首 peer 准备包含批次隔离复制，采样不额外调用捕获 |
| state_encode_peer / state_fanout | 每次单 peer 编码，以及每个有接收方的整批准备、编码和发送提交 |
| transport_send | 封装、压缩和 GNS 提交，排除网络传输时间 |
| network_poll / network_dispatch | 拉包及积压过滤，以及同步解码和事件消费者；派发时间包含业务工作 |
| client_authority / client_tick / client_present | 权威接纳（含空批次）、客户端物理回调、脚本表现准备；最后一项排除 GPU 与显示 |
| replay | 恢复与后缀重放；零步恢复也可能有样本，正常向前预测不计入 |
| actor_step / projectile_step / combat_step | 角色（含武器）、弹道物理、预测战斗；存在嵌套，不能直接相加 |
| history_save / terrain_commit | 历史保存、实际脏地形碰撞提交；没有脏地形不记录提交 |
| callback_interval | 连续普通回调的墙钟间隔，包含等待及其他工作，不是 CPU 用时或实际显示间隔 |
| physics_ticks_per_frame / replay_ticks_per_frame | 相邻普通回调间累计的物理 tick 和重放步数 |

单 peer 均值不能当整批耗时。`state_encode_peer.sum / state_fanout.samples` 可计算平均每批编码总量，不能得出最大批次。窗口均值的 p95 也不能当作单次调用 p95。包含子调用的指标不能与子指标重复累计。

## 定位流程

先根据聚合值选择阶段，再短时间采集对应进程的 CPU 和调度数据。Windows 用 WPR/WPA 区分运行、Ready 与等待；有符号的优化构建有助于识别原生热点。GDScript Profiler 只在需要脚本归因时短时开启。

若要判断玩家看到的卡顿，采集真实可见客户端的 PresentMon 显示指标，并检查丢弃帧和不可用值。无头进程及 `callback_interval` 不能证明画面显示间隔。

测量影响通过同负载、同构建、同限帧设置下的采样开关对照评估。外部工具也有缓冲、采样和符号开销；短时、单进程、限定类别。阶段计时是墙钟时间，CPU 归因需要采样或调度证据，不能将空档一律归因于调度器。

资料、可选工具与采用边界见[测试与监视调研](testing_and_monitoring_research.md)。
