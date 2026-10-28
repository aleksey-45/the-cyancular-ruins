# 地形重放迁移到 C++ 的隔离验证

2026-10-27。结论：在固定爆炸重放案例里，把地形热路径作为一批工作迁入 GDExtension，完整重放耗时稳定减少约 23%。这是一个可行性原型，尚未接入生产代码，也没有运行新的八人对局。

## 选择迁移范围的依据

上一轮固定数据中，3 tick 重放约 7.111 ms；其中本地角色步进累计仅 0.448 ms，战斗/弹丸/地形阶段约 3.462 ms，恢复阶段约 1.135 ms。各项是独立中位数，不应精确相加。这说明只把本地角色的运动公式改成 C++，覆盖的工作量较小。

源码中的重放还会恢复检查点、两轮采样远端代理、处理所有已知弹丸、撤销和重新应用地形、提交碰撞形状，并保存新的历史。隐藏节点仍参与变换和碰撞状态更新。Godot 的 [Node2D 实现](https://github.com/godotengine/godot/blob/master/scene/2d/node_2d.cpp)显示变换修改会调用渲染服务并发出变换通知；[物理移动实现](https://github.com/godotengine/godot/blob/master/scene/2d/physics/physics_body_2d.cpp)本身已经是 C++。这些源码用于核对机制，并非本机版本的原生 CPU 采样。

因此，本轮迁移的是地形恢复与爆炸重放涉及的整批工作：历史差分更新、伤害核应用、HP 和宏观网格更新、碰撞子格更新、分块占用位图、贪心矩形布局及其缓存，以及实际 CollisionShape2D 的更新。没有替换 Godot 的碰撞规则或改变爆炸生效的 tick/攻击阶段。

## 原型与边界

原型放在工作区 `work/native_replay_20261027/`，没有改动生产 GDScript 或既有原生扩展。

- `replay_bench.cpp`：`ReplayTerrainBench`，Release GDExtension。复用既有 godot-cpp、LLVM MinGW 工具链，使用 `-O3`，没有启用 fast-math。
- `bench.gd`：在实际 Level0、PredictionRollback、CombatPrediction 和 BulletBase 上，通过两个诊断子类选择 GDScript 或原生地形实现。
- `bench_capture.gd`：独立运行中间状态和物理形状检查，不进入性能样本。
- `CMakeLists.txt`、`build_profile.json`、`replay_bench.gdextension`、`run_compare.py`：构建、加载与复现入口。

首次爆炸伤害核生成、历史锚点重建、确认/裁剪、角色和弹丸模拟仍沿用原有 GDScript；本轮只迁移地形重放热路径。原生版本依然使用部分 Godot Dictionary/Array，并经 godot-cpp 调用实际引擎节点，不是完全脱离引擎的纯数据模拟器。分块布局缓存与现有实现都最多保留四种占用状态。

godot-cpp [数据访问文档](https://docs.godotengine.org/en/stable/tutorials/scripting/cpp/core_types.html)指出，PackedArray 逐项索引仍调用 Godot，批量访问应使用 `ptr()/ptrw()`；脚本边界还可能产生 COW 副本。本原型使用指针处理 HP，并显式返回可能分离的 HP 数组，调用、转换、复制和真实碰撞提交全部计入整段耗时。

## 固定数据与结果

沿用[出生事件优化](spawn_replay_validation.md)的 client1 / frame 623 数据：恢复 tick 546，重放 547、548、549，再正常推进 550；tick 548 在同一位置爆炸并改变 172 个地形子格。这里故意保留完整的 3 tick 重放，用于测量必须重放时的成本，没有用跳过重放来替代原生迁移的收益。

测试顺序为 A1 → B1 → B2 → A2，每组预热 3 次、记录 30 次。A 是本轮开始时已经优化过的生产 GDScript，B 是原生地形批处理。两者使用同一 Godot 编辑器构建、地图、输入、弹丸和代理；stdout 经持续排空的 PIPE 写入，不启用 FrameTrace、脚本 profiler 或外部采样。整段计时包含检查点恢复和 3 tick 重放，不包含随后正常推进。

| 组别 | 完整重放中位耗时 | 恢复阶段中位耗时 | 3 tick 战斗/弹丸/地形阶段中位耗时 |
|---|---:|---:|---:|
| A1，GDScript | 7.343 ms | 1.307 ms | 3.516 ms |
| B1，C++ | 5.627 ms | 0.559 ms | 2.645 ms |
| B2，C++ | 5.721 ms | 0.564 ms | 2.688 ms |
| A2，GDScript | 7.332 ms | 1.309 ms | 3.510 ms |

两组中位数的平均值从 7.337 ms 降至 5.674 ms，减少 1.664 ms，约 22.7%。本地角色、代理准备和历史保存仍有原来的成本。随后正常推进的中位数分别约为 1.19～1.26 ms，未显示稳定改善；收益集中在这次含爆炸地形往返的重放。

这是同一算法/规则下的一种 C++ 批处理实现收益，包含原生位图、工作缓冲与布局存储的变化，不能解释为所有 GDScript 函数改写后都有相同比例收益。

## 一致性

每个性能样本在计时外比较完整本地角色状态、全部存活弹丸、HP 表、宏观网格、碰撞子格、账户、输入游标及各 tick 的角色/弹丸/账户检查点，均与先前生产实现的参考结果一致。

另用独立进程捕获五个边界：恢复地形后、三个重放 tick 各自提交后、正常 tick 550 提交后。逐项比较同样的逻辑状态，并检查实际 StaticBody2D 的变换、碰撞层/掩码、每个 CollisionShape2D 的位置、尺寸、禁用和单向属性，以及完整矩形布局，全部一致。该捕获不进入性能表。

`summary.json` 保存四组原始样本的统计，`manifest.json` 保存代码/DLL 哈希和测量口径，`checks/` 保留退出状态和日志。核对上一轮的 316 个运行源文件，均未改变。

## 对后续实现的判断

GDExtension 对当前热点有实测收益，优先迁移批量地形工作有依据。它没有消除所有约 5.7 ms 的剩余重放成本，也没有证明原生物理查询或线程等待是剩余瓶颈。

Godot 的[核心类型说明](https://docs.godotengine.org/en/stable/engine_details/architecture/core_types.html)区分了 Variant Array、TypedArray 和 PackedArray；[静态类型说明](https://docs.godotengine.org/en/stable/tutorials/scripting/gdscript/static_typing.html)也明确已有优化字节码。因此，应根据完整工作区间验证收益，不能笼统把全部时间归给动态属性查找。

[NetherRealm 的 GDC 报告](https://media.gdcvault.com/gdc2018/presentations/Stallone_Michael_8FramesIn16ms.pdf)强调批量恢复、复用对象，减少分配、指针追逐与重复更新。这与本例减少解释器循环、容器和引擎节点往返的方向一致。逐步让原生模块拥有紧凑状态、按 tick 或重放窗口批量调用，值得继续验证；仅将外围函数逐字翻译而保留所有逐字段调用，覆盖的成本会更少。

本原型只验证 Windows x64 和一个固定地形案例。正式接入仍需覆盖不同地形、冷缓存、权威补丁、历史裁剪和跨平台构建。涉及角色运动的进一步迁移应继续让服务端与客户端共用规则，检查浮点计算与执行顺序；[Box2D 的确定性分析](https://box2d.org/posts/2024/08/determinism/)说明了编译器优化和运算顺序对结果的影响，不能用另一个物理引擎的性能或确定性结论替代本项目验证。

后续代理采样、弹丸和历史构造的迁移结果见[原生热路径对照](native_hot_replay_validation.md)，其中单独说明了计时单位与未获收益的迁移部分。
