# 服务端广播与日志性能优化

2026-10-27。接续[物理回调峰值调查](server_physics_peak_20261027.md)，工作产物位于工作区 `work/server_fanout_20261027/`。此次保留模拟、伤害、消息协议及回调调度，修改同一结果向多个接收者发送时的重复准备工作。

## 新查阅资料与采用范围

| 一手资料 | 设计与本项目的对应关系 |
|---|---|
| Epic：[Components of Iris](https://dev.epicgames.com/documentation/unreal-engine/components-of-iris-in-unreal-engine?lang=en-US) | pre-send 阶段处理公共数据，昂贵操作只执行一次并跨连接共享。此处共享同一事件的编码与 Zstd 压缩；逐连接的 ACK、重传队列和加密继续独立。 |
| Epic：[Replication Graph](https://dev.epicgames.com/documentation/en-us/unreal-engine/replication-graph?application_version=4.27) | Fortnite 的逐对象、逐连接重复判断会造成 CPU 瓶颈，公共准备结果可跨连接复用。此处采用复用原则，没有为八人地图引入空间复制图。 |
| Unity：[GhostSendSystemData.ForcePreSerialize](https://docs.unity3d.com/Packages/com.unity.netcode@1.10/api/Unity.NetCode.GhostSendSystemData.html) | 预序列化让公共部分从逐连接执行改为执行一次；简单或罕发对象未必获益，需要实测。此处只有同一广播内复用，不新增永久缓存。 |
| Riot：[Determinism in League of Legends: Fixing Divergences](https://www.riotgames.com/en/news/determinism-league-legends-fixing-divergences) | JSON 状态日志即使只记录变化也可能有显著成本，采用采样、分级和离线排查。此处先保留原有明细，把格式化与 JSON 工作移出主线程。 |
| Valve：[ISteamNetworkingSockets 接口](https://github.com/ValveSoftware/GameNetworkingSockets/blob/master/include/steam/isteamnetworkingsockets.h) | 消息有独立开销；`SendMessages` 是高效提交接口，可靠消息仍需保证顺序。原生适配器已经使用它，本轮在适配器入口批量交接接收者和共享压缩数据，没有把多个逻辑事件拼成新格式。 |
| Godot：[Thread-safe APIs](https://docs.godotengine.org/en/stable/tutorials/performance/thread_safe_apis.html) | 活跃场景树不能直接在线程中操作；数组和字典跨线程交接需要保护。日志在调用点捕获独立值快照，队列持锁交换，后台不访问场景节点。 |
| Godot：[CPU optimization](https://docs.godotengine.org/en/stable/tutorials/performance/cpu_optimization.html) | 先测瓶颈，同时考虑分析工具成本。本轮基准关闭 FrameTrace，保持日志和 Zstd 开启；实际对局再开启帧记录。 |
| Godot：[Optimization using Servers](https://docs.godotengine.org/en/stable/tutorials/performance/using_servers.html) | 场景层有管理成本，低层 API 可绕过它。原调查尚未独立量出弹丸实例化成本，因此先处理已测出的广播和日志，不用整个动作阶段的时间替代实例化时间。 |

这些资料支持公共准备复用、数据交接和测量方法，没有证明本项目某个未计时函数的具体成本。

## 实现

- `RoomSession._broadcast → NetBus.broadcast_event → GnsEndpoint.send_many`：同一事件编码一次、添加协议头一次、压缩一次；每个有效接收者仍独立入队和发送。一个接收者无效时，其他接收者照常入队，错误按原路径记录。没有跨 tick 延迟或重排事件。
- `BASELINE` 会修改 codec 的角色表、history 与 ACK，仍逐连接调用原有编码入口。`STATE` 保留逐连接序号、基线与 own；此前的公共 STATE 区块复用保持原实现。
- `broadcast_input_hints` 在一次广播中为每个角色编码一块，再为各接收者拼装排除自身的整包。八人全部有提示时，完整角色记录编码从 56 次降为 8 次。每份包仍包含另外七人的完整有界冗余；持续输入、动作、epoch、`available_tick` 和独立解码不变。
- `GameLog.record` 在调用线程捕获 UTC 原始时间、单调时间、角色及帧号，并深拷贝日志数据；后台线程格式化时间、生成 JSON、批量写盘。UTC 秒级前缀复用，普通队列达到 128 行时提前唤醒，原有紧急唤醒、周期刷新和关闭排空保留。日志级别、每接收者 `net_event` 明细与文件字段保留。
- `performance.log_writer` 增加队列水位与后台编码批次峰值；其墙钟时间不能当作主线程 CPU 时间。FrameTrace 新增 `server_input_hints`、`input_hint_encode`、`input_hint_send`，事件阶段增加实际编码次数，消除此前输入提示只能从回调间隙估计的问题。

后台日志仍可能在写盘受阻时积压；本轮没有增加丢日志或阻塞游戏线程的策略。队列水位用来核实实际运行是否持续积压。

## 固定负载对照

`fanout_bench.gd` 使用八个真实 GNS 连接，在同一进程中执行正式的 `RoomSession` 广播路径，Zstd 与正式游戏日志开启，FrameTrace 关闭。每轮重建原峰值的事件数量组合：13 次出生、6 次开火、9 次命中、1 次结束、2 次奖励，共向接收者发送 242 条事件；另发送八份完整输入提示和 29 条带嵌套输入数据的日志。载荷为固定夹具，并非原对局逐包录制，不能称为完整重现原 tick。

按修改前 A、修改后 B、B、A 的顺序各运行 30 个计量样本，每次另有 3 次预热；每侧合计 60 个样本。每轮都核对全部接收者的报文字节、排除开火者的规则、完整输入内容，以及 EVENT lane 内的可靠顺序。INPUT 与 EVENT 的到达顺序不作跨 lane 假设。每轮收完消息再进入下一轮，不把发包队列积压混入下一样本。

| 主线程区间 | 修改前中位数 ms | 修改后中位数 ms | 修改前 P95 ms | 修改后 P95 ms |
|---|---:|---:|---:|---:|
| 242 次事件发送与对应日志 | 11.727 | 4.666 | 13.692 | 5.168 |
| 八份输入提示准备与发送 | 1.598 | 0.471 | 1.903 | 0.551 |
| 29 条额外嵌套日志 | 1.393 | 0.675 | 1.691 | 0.916 |
| 整段 | 14.699 | 5.809 | 16.801 | 6.524 |

整段中位数减少约 60.5%。表中各区间中位数不要求相加等于总中位数。原始 JSON 字段单位为 us，表格仅除以 1000；后台日志处理和接收端解码不包含在主线程区间中。八个接收端和发送端共处一进程，无法把这张表直接当成整场服务器帧间隔的改善比例。

原始样本、逐次结果、代码与 DLL 哈希见 `comparison_sources.json`、`before_a*.json`、`after_b*.json`、`performance_summary.json`。对照程序在 `finally` 中恢复修改后源码和 DLL，并检查切换期间没有其他编辑。

## 八人中继实测

再运行一场 90.032 秒八人 Beta 大乱斗，本机 EasyTier 中继、禁用 P2P，全部无头，开启 FrameTrace；不与其他测试同时运行。runner 无失败，正常结束，八个客户端最终位置误差均为 0。154 条路径样本均为 `relay(2)`；不把路径 RTT 摘要中的初始化值当成真实端到端延迟。

| 正式战斗区间指标 | 结果 |
|---|---:|
| 八客户端记录数 | 43,210 |
| 客户端最大 process_frame 间隔 | 29.778 ms |
| 服务端最大 process_frame 间隔 | 26.014 ms |
| 客户端及服务端 ≥30 ms 记录 | 0 |
| 服务端物理节点回调中位数 / P95 / 最大值 | 4.266 / 6.659 / 11.548 ms |
| 服务端输入提示整个回调中位数 / P95 / 最大值 | 0.407 / 0.614 / 1.986 ms |
| FrameTrace 丢弃记录 | 0 |
| 服务端游戏日志队列最大水位 | 136 行 |

服务端最重物理回调 frame 4238、tick 4102，291 次事件发送仅执行 37 次编码，总回调 11.548 ms。包含 12 发新弹丸、5 次开火、12 次命中、一名玩家死亡和奖励；日志中 `net_event` 不记录 ROUND/TERRAIN，因此日志分类与阶段发送总量可不同。事件阶段累计编码 0.416 ms、发送 1.334 ms、日志入队 1.992 ms；都已包含在物理回调内。输入提示另为 0.441 ms。该场与原场战斗结果不同，不能把物理最大值 18.107 → 11.548 ms 当成固定场景的精确提速比例。

后台 JSON 编码批次峰值 5.917 ms，服务端每秒采样的队列水位没有持续增长；移到后台减少的是主线程成本，不代表这些工作消失。日志记录调用的最大墙钟值为 0.896 ms，没有 CPU 采样可进一步归因其极值。

原始数据见 `match_8_relay/`、`frame_analysis/summary.json`、`server_analysis.json` 和 `live_summary.json`。这是无头主循环记录，没有测量屏幕实际呈现。

## 客户端 29.778 ms 的组成

client1 frame 4395，UTC 15:03:25.900 结束，仅一次物理回调，五个网络消息，重放 5 tick、正常推进 1 tick。

| 相对 process_frame 开始 | 内容 | ms |
|---|---|---:|
| 0 → 1.012 | 普通节点回调，含表现更新 | 1.012 |
| 1.012 → 14.343 | 回调外区间 | 13.331 |
| 14.343 → 29.292 | 物理节点回调 | 14.949 |
| 29.292 → 29.778 | 物理结束到下次 process_frame | 0.486 |

回调外区间包含引擎限帧、调度与未细分工作，未直接记录 sleep，不能精确叫作“等待 13.817 ms”。这四个区间互不重叠，总计 29.778 ms。

物理回调内，收包和预处理 0.072 ms、消息解码/派发 1.985 ms、权威批次应用 10.169 ms、正常预测 2.198 ms，其余边界与节点 0.525 ms。权威批次中，`authority_apply` 为 10.083 ms：进入第一个重放 tick 前的审核/恢复/准备 4.034 ms，五步重放合计 5.900 ms，其他边界 0.149 ms。重放时间已经包含其中的历史保存 1.604 ms，禁止重复相加。

触发来自 STATE tick 4326，复用失败类别为 `suffix_projectile_contact`。按代码路径，本地权威锚点比较已通过，后续弹丸接触或射手回溯状态依赖审核失败；再尝试从历史检查点恢复时也被拒绝，最终从 STATE 重算 5 tick。类别同时涵盖射手回溯状态不匹配，不能仅凭名字断定是哪发弹丸命中变化。当前日志未保存具体查询 ID、首次失效 tick 或检查点拒绝条件，不能据此断言本次重放一定必要或一定多余。

当帧 `proxy_geometry_invalidations` 计数为 7、代理运动步进为 42；地形网络版本保持 1614，未重建碰撞分块。该计数混合了首次初始化：`apply_snapshot` 为新 STATE 追加的帧没有 geometry/motion，`_motion_sample` 按 geometry=-1 进入同一分支并初始化轨迹，也增加此计数。因此不能直接称为七次已有缓存失效，更不能据此推断有新地形破坏。客户端这一审核和恢复区间仍有独立优化空间；下一帧也有一次 4 tick 重放，间隔为 11.771 ms，不是同一帧重复回放。

### 14.949 ms 物理回调成本复核

后续根据此分析完成了[代理轨迹与快照复制优化](proxy_state_storage_optimization.md)。下文保留修改前原始记录与计数语义。

复用同一原始记录，不重跑对局。`analyze_client_physics.py` 按起止时间将每个子 span 归到对应步骤，结果见 `client_physics_analysis.json`。无重叠的分解如下：

| 工作区间 | ms |
|---|---:|
| 收包、预处理、解码和派发 | 2.057 |
| 第一次重放步进之前的审核、恢复与准备 | 4.034 |
| 五步重放 | 5.900 |
| 正常预测推进一次 | 2.198 |
| 其余节点与边界 | 0.760 |
| 合计 | 14.949 |

五步重放各自为 0.886、1.456、1.494、0.704、1.360 ms，平均 1.180 ms。继续按互不重叠的子区间拆分：

| 五步重放内部 | ms |
|---|---:|
| 本地角色步进，含 ActorStep 与本地 haste 准备 | 0.312 |
| 代理采样与恢复 | 1.265 |
| 弹丸阶段，含接触/结算、地形提交及命令记录 | 1.990 |
| 保存预测历史 | 1.604 |
| 其余步骤代码和边界 | 0.729 |
| 合计 | 5.900 |

这里的 `projectile_step` 包含 `combat_simulation` 和 `terrain_collision_commit`，没有将它们再次相加。`remember_state` 也已从步骤总耗时中拆出。本地角色步进仅约占这五步总量的 5.3%，不能把本例解释为角色运动核消耗了十几毫秒。

源码与记录揭示的成本来源：

1. 整个物理回调调用 `anchor_collision` 140 次，累计 3.567 ms：重放之前 56 次、五步内 70 次、正常一步 14 次。140 次采样不是 140 次物理积分；实际生成运动样本为 42 步。每次采样仍有帧表查找、字典读取、节点运动状态恢复和碰撞状态更新。两个采样阶段用于对齐服务端按角色顺序移动前后的查询时刻，不能不检查语义就合并删除。
2. 新 STATE 建立新的代理运动锚点，旧锚点的未来运动样本不会自动成为新锚点的有效后缀。因此即使地形没变化，也仍需按新权威输入和状态生成代理轨迹。实际几何失效与首次初始化应区分计数。
3. 历史保存已经由 C++ `NativePredictionHistory.remember` 执行，但仍为本地角色、远端碰撞/回溯元数据及活跃弹丸创建 Dictionary/Array 快照。迁移消除了部分脚本循环，没有消除容器分配和状态构造。本例五次历史保存为 0.179、0.237、0.132、0.114、0.942 ms；最后一次明显偏高，不能据此把每步历史成本都当成约 1 ms。
4. 收到的一份 STATE 解码占 1.075 ms，包含基线 world 的深拷贝、字段增量重建及再次深拷贝保存 codec 历史；现有 span 没有进一步区分这几项。三个事件的解码/处理合计 0.475 ms，STATE handler 为 0.070 ms，其余网络派发代码为 0.365 ms。
5. 重放前 4.034 ms 中，已知代理采样占 1.586 ms，剩余 2.448 ms 未细分，包含锚点/命令/交互复核、检查点可用性判断、状态与输入恢复、弹丸准备等调用。不能把剩余部分全部归给某个函数。

本例整帧的已计量 FrameTrace 观察器成本为 0.234 ms，仅覆盖工具已计量的操作，不是全部测量开销上限。所有区间都是墙钟；没有线程 CPU 采样，不能从某次 0.942 ms 的历史保存判断其中多少是分配器工作、锁等待或被系统抢占。当前有证据优先关注审核/恢复、代理反复采样、历史容器构造和状态解码，尚不能认定重放触发一定必要或多余。

## 验证边界

- Windows Release GNS 扩展构建通过，全部 244 个脚本加载通过。
- 固定负载 120 个计量样本通过逐接收者字节、可靠顺序和 INPUT 完整性检查；协议探针新增八角色分块编码对照原布局检查。
- 日志探针通过多线程、暂停后台期间继续运行、嵌套数组/字典与 Packed 数组快照、关闭排空检查。
- GNS 压缩/未压缩、三条 lane、大基线、单个无效接收者不影响其余发送、广播与单发可靠顺序检查通过。
- 全量普通回归 67/70：原有 `elite_drop_probe` 退出访问冲突、`preview_visibility_probe` 的空预瞄节点断言、`settings_display_section_probe` 的旧文案断言仍失败。
- 网络探针回归 5/6：`playback_lifecycle_probe` 在 897 行直接读取尚未派发的弹丸时失败。使用本轮修改前四个运行时脚本及 DLL 复核，同一 ID、同一行失败，证明不是本轮新增；该探针没有算通过，见 `baseline_failure.json`。八人实际对局独立通过。
