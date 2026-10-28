# 运动轨迹与整帧记录

2026-10-27。本轮将逻辑运动代理与显示外推分开，并为尚未归因的约 30 ms 帧间隔增加精确记录。没有调整输入调度、收包预算、帧率上限或本地重放窗口。

## 运动代理

[Epic CMC](https://dev.epicgames.com/documentation/en-us/unreal-engine/understanding-networked-movement-in-the-character-movement-component-for-unreal-engine)的简化远端运动仍处理模式、落地与速度；[Fusion Forecast](https://doc.photonengine.com/fusion/v2/manual/physics/physics-forecast)明确区分外推目标与本地物理约束。本项目据此采用共享运动核心与轨迹缓存，不再把穿过地形的线性外推位置直接当作碰撞体。

[PlayerReplica](../../scenes/player/player_replica.gd)只延续权威持续输入和已知运动模式。共享运动函数的 `motion_only` 分支不更新氧气、HP 或任何武器/账户。新跳跃、冲刺、攻击和新的输入变化都等待权威状态。轨迹按实际查询延伸，重放同一窗口只读取缓存；地形几何版本变化后重建受影响的锚点轨迹。同 tick 同内容的锚点确认保留轨迹。

`MOTION_HORIZON=32` 是与本地恢复窗口一致的容量上限，不是把整个窗口每次重算，也不是资料承诺的可靠外推时长。超限保持终点、速度归零并标记过期；显示仍独立保持 6 tick 上限。没有引入代理间的完整角色世界模拟，未知输入与交互仍会产生近似误差。

## 帧记录口径

[FrameTrace](../../core/config/frame_trace.gd)由 `--frame-trace` 开启，默认关闭。相邻 `SceneTree.process_frame` 信号定义记录区间；由于该信号在 idle 回调前发出，区间包含本轮 idle/渲染提交/等待以及下一轮物理回调。使用单调微秒时间和引擎 process/physics 编号，不把引擎上一轮监视器采样当成峰值帧分解。[Godot SceneTree 文档](https://docs.godotengine.org/en/stable/classes/class_scenetree.html#signals)给出了两个信号的时点。

记录内容包括：

- 全部帧的开始、结束、物理回调次数，physics/idle 节点回调区间；若实际渲染，另记录 RenderingServer 提交区间。渲染信号不是 GPU 完成计时。
- GNS poll、合并、派发；权威应用、逐步本地角色/弹丸/检查点保存、代理采样；主线程 CLI 启动与轮询；服务端角色、攻击、地形/规则和 STATE 生成。
- 整个区间累计的前进/重放 tick、权威应用次数、代理轨迹新生成步数，而非只保留最后一次回调结果。
- 本地 tick/clock/输入 ACK、地图版本、弹丸数量、代理年龄及过期数量；每次权威应用的原因、失效点、复用结果和校正距离。
- `--frame-trace-packets` 额外保存发送和派发的原始游戏报文、派发时间及原生接收时间。报文在后台转换为 base64。被接收合并器淘汰的原生报文不在派发记录中；该文件不是 UDP 抓包。

阶段允许嵌套。只能按区间并集计算覆盖，不能把 `authority_apply`、`prediction_step`、`local_actor` 等累计后称作整帧 CPU 时间。外层区间以外的时间包含引擎工作、帧率等待与 OS 调度；没有 CPU 采样证据时不继续细分归因。

主线程交接已封口的记录，后台编码、写入；队列最多 600 帧，溢出明确累计丢弃数。记录主线程观察器耗时，以及后台批次编码/I/O 最大耗时。`observer_us` 只覆盖已计量的观察器路径，不代表所有插桩和线程竞争开销。需要比较有/无记录的同类场次才能估计总扰动。正常退出时排空队列；最后不完整区间标记 `partial`。

GameLog 的普通日志也增加 process/physics 帧编号；每秒性能摘要保存最大间隔结束时的精确单调时间与帧编号。默认日志不再丢失约 30 ms 峰值的定位信息。

## 首场定位到的进程启动阻塞

`match_8_relay_trace` 为 90.014 s 的八人 Beta 大乱斗，本机 EasyTier UDP 中继且禁用 P2P，包含重连。runner 全部通过。每秒摘要中的客户端最大间隔为 33.133 ms；相邻 `process_frame` 信号的同一区间为 33.075 ms，两者观测点略有差异。

`client4` 的 frame 1411 / tick 约 1354 中，主线程 `cli_launch` 占 **27.149 ms**，idle 节点区间 28.130 ms、后续 physics 节点区间 4.579 ms。该区间本地角色合计 0.200 ms，2 个重放 tick 加 1 个前进 tick，记录观察器为 0.181 ms。原生进程启动是该峰值的主要耗时，不能再用先前隔离环境的约 2 ms 启动样本排除它。

另两处超过 30 ms 的区间各有不同组成：`client1` frame 765 为重连基线处理，派发包含创建/初始化对局，耗时 12.322 ms；`client7` frame 680 的 physics 节点耗时 15.661 ms，包括 3 个重放 tick 和 1 个前进 tick。相邻 idle 边界之间还包含帧率等待等时间，不能把这些峰值一概归因于 CLI 或网络。首场普通校正日志 ≥32 px 为 22 条、最大 64.074 px，位置收敛最大 1 px；没有把这些近似交互误差改称性能故障。与上轮场次并非固定消息时序 A/B，不能从次数变化得出统一改善或退化倍数。

[NetSession](../../core/net/net_session.gd)据此将 CLI 请求交给常驻工作线程。启动、管道读取、超时和子进程回收均由该线程独占自己的 `OwnedProcessGroup`；主线程通过互斥保护的请求队列和结果交接，不共享原生进程表，也不在每次采样时新建线程。会话关闭取消未完成请求，代际检查阻止旧结果进入新会话，应用退出时等待工作线程完成清理。

遵循 [Godot 线程安全边界](https://docs.godotengine.org/en/stable/tutorials/performance/thread_safe_apis.html)，工作线程不访问活动场景树，也不写 FrameTrace 的主线程区间；主线程收到结果时记录带 `thread=cli_worker` 的原始工作线程时间。此时间不得计入主线程 span。

Windows 六种进程生命周期场景全部通过：正常退出、窗口关闭、离开并重新打开会话、场景切换、强制退出、启动期间强制退出。检查了所属 server、EasyTier、CLI 与后代进程均退出，并确认独立的 EasyTier 控制进程仍存活。未在本机声称完成 macOS 运行验证。

## 运行与分析

```powershell
python tests/network/run_matches.py --godot $env:GODOT --count 8 --mode royale --tunnel relay --local-relay --easytier-dir ../easytier-windows-x86_64 --battle-seconds 90 --network-seconds 30 --drop --no-trace --frame-trace-packets --output .test_logs/network/motion_trace
python tools/gamelog/analyze_frame_trace.py .test_logs/network/motion_trace --battle-only
```

`--no-trace` 关闭旧服务端全世界回放记录，与新增帧记录开关独立。Windows 调试引擎的 stdout 应通过持续排空的 PIPE 写入文件，避免同步控制台文件刷新干扰测量。

[分析器](../../tools/gamelog/analyze_frame_trace.py)按正式战斗完整区间过滤，输出分位数、各进程峰值、嵌套阶段及前后四帧。完整原始报文、固定输入、场地、源码哈希与源码副本一起保留，便于构造相同消息顺序的后续回放；不据此承诺能够复现 OS 调度或原始墙钟峰值。

## 验证

[运动探针](../../tests/probe/local_prediction_scope_probe.gd)覆盖第 8 tick 重力、墙/地板、落地模式、轨迹复用、地形失效、超限标记、接缝与复活；[帧记录探针](../../tests/probe/frame_trace_probe.gd)插入已知 35 ms 工作，检查其精确区间、报文字节和后台排空。[权威探针](../../tests/network/authority_probe.gd)的 tick 103 新锚点现在携带对应时刻的远端运动状态，仍要求本地状态、弹丸、账户与完整恢复一致。

全量逻辑/场景回归在修正时间不一致的权威夹具后为 67/70，三项原有失败仍为精英掉落退出崩溃、预瞄探针空节点、设置页旧文案断言。六项基础网络检查及弹丸迟到专项合计 7/7，全脚本加载 244/244。CLI 线程修改后另复核脚本加载、运动域、帧记录、本地服务、传输和权威恢复，并运行上述六种生命周期检查；没有掩盖首轮夹具失败。

## 最终详细记录场

`match_8_relay_final_trace` 同样采用 90 秒八人 Beta 大乱斗、本机官方 EasyTier UDP 中继、禁用 P2P、断线重连与持续排空的 stdout PIPE。实际战斗为 90.014 s，runner 通过，八人均自然结算回到原房间，最终位置收敛误差均为 0 px。722 个 GNS RTT 样本均为 0 ms，152 个中继路由样本没有异常；这不是公网高 RTT 测试。

| 指标 | 最终场结果 |
|---|---:|
| 每秒摘要中的客户端最大帧间隔 | 32.237 ms |
| 每秒摘要中的服务端最大帧间隔 | 24.455 ms |
| 正式战斗逐帧记录 | 48,600 个完整区间，九个进程各 5,400 |
| 逐帧区间 ≥30 ms / ≥50 ms | 3 / 0 |
| 主线程 CLI 启动次数 | 0 |
| 主线程 CLI 提交最大耗时 | 0.048 ms |
| 后台 CLI 完成 / 启动最大耗时 | 164 次 / 26.556 ms |
| 已计量观察器平均 / 各进程 p99 最大值 | 0.068 / 0.154 ms |
| 已计量观察器单区间最大值 | 0.868 ms |
| 原始游戏报文记录 | 287,684 条发送或派发记录，包含两端重复观察 |
| 帧队列丢弃 / 文件结束完整性 | 0 / 九个进程均正常排空 |
| 普通校正日志 ≥32 px / 最大距离 | 15 条 / 65.178 px |

全部详细文件约 316.7 MB，包含对局前后阶段。观察器耗时是插桩路径的实测子集，不能把 0.068 ms 当作整个记录系统的完整开销；没有另跑关闭记录的八人场，尚未估计后台线程竞争的总扰动。本轮最终源码的 316 个文件哈希与测试前一致。

**CLI 阻塞已经移出主线程，但尚未消除全部约 30 ms 区间。** 三个峰值分别为：

| 进程 / frame | 信号间隔 | 主要记录 |
|---|---:|---|
| client1 / 783 | 32.199 ms | 重连 BASELINE；解码 0.935 ms、事件处理 11.049 ms，physics 节点合计 13.732 ms。外层区间以外 18.096 ms，包含帧率等待及尚未拆分的引擎/OS 时间 |
| client4 / 2402 | 31.332 ms | 正常战斗；physics 节点 23.114 ms，其中权威应用 19.630 ms，3 tick 重放加 1 tick 前进。本地角色合计 0.463 ms，代理采样 6.689 ms、77 个新运动步，弹丸阶段 10.019 ms |
| client5 / 2395 | 31.091 ms | 正常战斗；physics 节点 19.606 ms，4 tick 重放加 1 tick 前进。本地角色合计 0.543 ms，代理采样 5.317 ms、91 个新运动步，弹丸阶段 6.842 ms |

表中的“弹丸阶段”是 `combat_prediction.step()` 起至保存本地检查点之前的区间，包含奖励处理与 `tick_finished` 触发的地形碰撞提交，不能仅归为弹道计算。两个正常战斗峰值处于相邻的地形变化阶段；锚点/几何版本改变后，轨迹必须重新生成，不能把 77/91 步解释成 77/91 个本地重放 tick。只有实际几何依赖相同时才可保留缓存。

上述版本的剩余工作应沿保存的弹丸/地形提交区间及轨迹版本失效继续定位。后续已经复现并修改分块实体生命周期与轨迹失效范围，详见[地形与轨迹热点](terrain_replay_hotspots.md)；没有据此修改输入或重放调度。

证据目录为工作区 `work/proxy_trace_20261027/`：`verification.json` 汇总结果，`regression.json` 保留原回归失败与夹具修正前结果，`checks/` 和 `process_lifecycle/` 为专项输出。两场分别保存 `result.json`、诊断与报文、`manifest.json` 和源码；各自 `frame_analysis/summary.json`、`client*-peak*-frame*.json` 保存峰值与前后四帧。最终场分析另为 `match_8_relay_final_trace.analysis.json`。默认不再追加其他八人场。
