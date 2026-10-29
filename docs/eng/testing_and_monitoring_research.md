# 自动化测试与低开销监视资料

## 测试资料与可参考部分

| 资料 | 可参考部分及边界 |
|---|---|
| Rare，Robert Masella，GDC 2019：[Automated Testing of Gameplay Features in Sea of Thieves](https://media.gdcvault.com/gdc2019/presentations/Masella_Robert_AutomatedTestingOf.pdf) | 小型真实组件/角色夹具，少量慢速整局和图像用例；超时、失败责任与不稳定用例治理。团队规模和重试策略不直接照搬 |
| Riot：[Automated Testing of League of Legends](https://www.riotgames.com/en/news/automated-testing-league-legends) | 分阶段观察与阻断、开发者维护关键行为；测试数量不是目标 |
| Factorio：[FFF-60](https://factorio.com/blog/post/fff-60)、[FFF-315](https://factorio.com/blog/post/fff-315) | 单元/小地图集成各有用途；每 tick 保存和 CRC 属于专项重型验证，不能作为默认性能负载 |
| Epic：[Automation Test Framework](https://dev.epicgames.com/documentation/unreal-engine/automation-test-framework-in-unreal-engine)、[Automation Spec](https://dev.epicgames.com/documentation/unreal-engine/automation-spec-in-unreal-engine) | Smoke 是快速执行承诺，测试行为契约而非函数逐行镜像 |
| DDNet 固定源码：[snapshot_test](https://github.com/ddnet/ddnet/blob/049b000c005728ba3b24f65c187e49756baa09c2/src/test/snapshot_test.cpp)、[packer_test](https://github.com/ddnet/ddnet/blob/049b000c005728ba3b24f65c187e49756baa09c2/src/test/packer_test.cpp)、[gameworld_test](https://github.com/ddnet/ddnet/blob/049b000c005728ba3b24f65c187e49756baa09c2/src/test/gameworld_test.cpp) | 快照、打包和小世界契约在低层验证，不依赖完整大厅和公网 |
| OpenRA 固定源码：[OrderTest](https://github.com/OpenRA/OpenRA/blob/cd207614b55d53bd2897408386fcec8a1f48cce0/OpenRA.Test/OpenRA.Game/OrderTest.cs) | 指令序列化、边界与往返等价，用小输入直接保护协议 |

避免过度测试的取舍：优先不可逆数据损坏、双端契约、时间顺序和恢复等高风险边界；合并重复覆盖，测试真实组件，小夹具不能替代会话验收。没有明确风险不追加整局，不为覆盖率补实现镜像。必要检查通过即停止，不靠自动重试掩盖失败。

## 监视资料与可参考部分

| 资料 | 可参考部分及边界 |
|---|---|
| Guerrilla，Michiel van der Leeuw，CEDEC 2019：[Making Tools for Big Games](https://www.guerrilla-games.com/read/making-tools-for-big-games)、[讲义](https://d3d3g8mu99pzk9.cloudfront.net/MichielVanDerLeeuw/CEDEC%202019%20-%20Making%20Tools%20for%20Big%20Games.pdf) | 生产环境秒级性能趋势与 AutoBot 专项截图/视频分开，低频监视不等于零成本 |
| Riot：[Measurement and Analysis](https://www.riotgames.com/en/news/profiling-measurement-and-analysis)、[Missing Milliseconds](https://www.riotgames.com/en/news/profiling-case-missing-milliseconds)、[Real-World Performance](https://www.riotgames.com/en/news/profiling-real-world-performance-league) | 考虑采样噪声、埋点开销和硬件分组；未标记时间可能在代码中，回放也不天然等于真实游戏负载 |
| 0 A.D. 固定源码：[Profiler2.h](https://github.com/0ad/0ad/blob/61a3b9507d974084e6badb88a0826bd89a6d5b8b/source/ps/Profiler2.h)、[Profiler2.cpp](https://github.com/0ad/0ad/blob/61a3b9507d974084e6badb88a0826bd89a6d5b8b/source/ps/Profiler2.cpp) | 粗粒度事件、每线程固定环；该实现约 4 MiB/线程，导出仍有复制和 JSON 成本，预算不能盲抄 |
| Microsoft：[CPU Analysis](https://learn.microsoft.com/en-us/windows-hardware/test/wpt/cpu-analysis)、[Logging Mode](https://learn.microsoft.com/en-us/windows-hardware/test/wpt/logging-mode) | Sampled 看热点，Precise 看运行/Ready/等待；环形内存、调用栈、记录时长和丢事件都会影响分析 |
| PresentMon：[Console Application](https://github.com/GameTechDev/PresentMon/blob/main/README-ConsoleApplication.md) | Present、显示持续时间和 CPU/GPU 指标分开；按进程/时长采集并检查指标可用性，显示值才直接关联可见停顿 |
| Godot 4.7：[Performance](https://docs.godotengine.org/en/4.7/classes/class_performance.html)、[Profiler](https://docs.godotengine.org/en/4.7/tutorials/scripting/debug/the_profiler.html)、[Tracy](https://docs.godotengine.org/en/4.7/engine_details/development/profiling/tracy.html) | 引擎粗粒度监视、自耗时/包含耗时、专项原生追踪；部分监视在 release 不可用，Tracy 持续记录需注意未连接时的内存增长与按需配置 |
| Perfetto：[Track Events](https://perfetto.dev/docs/instrumentation/track-events)、[Buffers](https://perfetto.dev/docs/concepts/buffers) | 静态名称、关闭时不准备载荷、所有层级缓冲按字节计，记录丢弃且不阻塞游戏等待消费者 |
| Apple：[Instruments / Metal Performance](https://developer.apple.com/documentation/xcode/analyzing-the-performance-of-your-metal-app/) | macOS 的专项 CPU/GPU 分析工具；工具选择不代表项目已完成该平台采集 |

低成本监视适合固定阶段、标量聚合和秒级趋势；完整逐帧追踪按问题短时启用。所有容量层级和导出临时数据都要纳入成本。墙钟间隔不等于 CPU 工作或实际显示间隔，异步写盘也不免除主线程采集、分配和数据保留。

### 引擎时序与专项分析入口

[Godot C++ Profiler 文档](https://docs.godotengine.org/en/4.7/engine_details/development/profiling/index.html)说明优化构建和符号的用途；[Quantum Profiling](https://doc.photonengine.com/quantum/v3/manual/profiling)也区分分析器开销和帧等待。[WPR 命令选项](https://learn.microsoft.com/en-us/windows-hardware/test/wpt/wpr-command-line-options)用于限制专项采集。

Godot 的 [main.cpp](https://github.com/godotengine/godot/blob/4.7-stable/main/main.cpp)、[OS 等待实现](https://github.com/godotengine/godot/blob/4.7-stable/core/os/os.cpp)、[物理步进](https://github.com/godotengine/godot/blob/4.7-stable/modules/godot_physics_2d/godot_step_2d.cpp)可用于核对回调、补步和限帧顺序。这些源码帮助解释计时边界，不能单凭回调间隔证明某一帧 CPU 或画面停顿。

## 当前采用

少量 net、terrain、simulation、monitor 行为组和独立地图编辑器契约检查；一次进程按需运行，不自动重试，测试不随游戏导出。会话、传输和负载风险才选择代表性真实对局。入口见[关键行为检查](tests.md)。

主线程原生固定容量标量聚合，默认不记录状态、包和逐帧对象。每秒发布窗口，控制台输出和退出汇总按参数启用；可停用采样作对照。CPU、调度与显示需要时使用外部工具短时分析。没有内置持续事件环、常驻采样器或后台全状态写盘。容量和指标见[性能观测](low_overhead_performance.md)。
