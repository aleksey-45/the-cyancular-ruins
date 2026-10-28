# 角色步进性能优化，2026-10-26

本轮针对固定模拟的 CPU 工作量，研究和修改角色步进，不调整输入到达、STATE 复用或重放调度。基于上一轮测量，20 个八角色世界 tick 的完整 reconcile 在关闭 profiler 的情况下约 11.2–11.7 ms；角色阶段占主要部分，但没有单个极慢的原生物理查询。Windows 调试版 stdout 写盘阻塞另有独立证据，不能把这类等待当作角色计算。

## 参考方案及适用边界

| 一手来源 | 设计或优化 | 本项目的取舍 |
|---|---|---|
| [Factorio FFF-271](https://www.factorio.com/blog/post/fff-271) | 把高频流体更新从各实体抽出，集中保存和迭代必要数据；相互独立的流体系统可以并行 | 借鉴减少对象访问和重复准备。当前八角色相互阻挡且按顺序结算，不能直接并行或使用整 tick 不变的位置表 |
| [Factorio FFF-209](https://www.factorio.com/blog/post/fff-209) | 按原型分组，组内公共参数只读取一次；为简单烟雾缩小数据结构 | 在一次移动内准备活动形状，两轴共享这些常量。保留角色现有组件和玩法，不为八个实体引入完整 ECS |
| [DDNet gamecore.cpp](https://github.com/ddnet/ddnet/blob/master/src/game/gamecore.cpp)、[gamecore.h](https://github.com/ddnet/ddnet/blob/master/src/game/gamecore.h) | 角色核心直接操作位置、速度和结构化输入；世界保存角色核心表，移动查询独立碰撞模块 | 固定输入直接按位查询，组件使用准确类型。学习数据和调用边界，不复制其碰撞算法或数值 |
| [Quake III bg_pmove.c](https://github.com/id-Software/Quake-III-Arena/blob/master/code/game/bg_pmove.c) | 客户端与服务端共用移动核心，以 playerstate 和 usercmd 为输入；使用命令轴与按钮位 | 保留 ActorStep 单一移动入口，消除固定输入再按动作字符串解码的路径；不照搬其子步长或空中移动规则 |
| [Riot：VALORANT's 128-Tick Servers](https://www.riotgames.com/en/news/valorants-128-tick-servers) | 按子系统测量和预算；减少无必要的轮询与动画工作；实机负载下再测缓存竞争 | 以未插桩完整重放确认收益，阶段计时只辅助定位。不照搬动画降频：本项目活动碰撞姿态仍逐 tick 生效 |
| [Box2D Simulation](https://box2d.org/documentation/md_simulation.html)、[Collision](https://box2d.org/documentation/md_collision.html) | 数据集中存储；碰撞几何可脱离渲染使用；AABB 代理组织大量形状 | 使用紧凑几何值处理已有矩形裁剪。八人场景不额外引入空间树，也不保留可能错过阶段内更新的整窗口角色边界 |
| [Godot 本机提交的 GDScript 说明](https://github.com/godotengine/godot/blob/a13da4feb/modules/gdscript/README.md)、[Node2D 实现](https://github.com/godotengine/godot/blob/a13da4feb/scene/2d/node_2d.cpp) | 类型已知时可直接编译成员与方法访问；变换 setter 会提交渲染变换并通知变换变化 | 消除组件中 CharacterBody2D/动态 get 的不必要路径；相同武器瞄准变换不重复提交 |

这些来源描述的是各自代码和工作负载，不代表同样的倍数收益可以移植到 GDScript。本文的收益只以本项目对照测量为准。

## 实现

1. 新增纯值对象 `ActorInput`，每角色复用一个，每 tick 从记录中准备一次轴、按键位、瞄准和武器实例。控制锁在准备阶段应用，模拟直接读字段；保留原始持续轴和按键供权威输入延续使用。按键常量单一维护，`PacketInputSource` 保留旧名别名。删除始终返回零的网络槽位查询，继续按记录中的 `winst` 切枪。
2. 游泳、攀爬、战斗组件明确使用 `Player`，直接读取 `pvp_haste_mult`，减少动态属性查找；游泳脚底计算只读一次当前位置。
3. `move_by` 在选定姿态后准备一次形状数据，每轴使用最新的全局变换。保留原来的矩阵乘法顺序，避免改变浮点舍入与轴向接触。
4. `ActorCollider.clip` 把本角色的边界和中心移到对手循环外；对手仍使用当时的最新矩形。
5. 地形结果缓存的容量、完整键和失效规则保持原状；用有界环形 FIFO 替换每次淘汰的 `keys()` 全量复制，哈希槽覆盖不改变队列次序。
6. 武器只在角度或缩放实际不同时写入 Node2D；蓄力分支复用当 tick 的攻击边沿，瞄准不再重复读取刚设置的朝向。开火前仍同步瞄准，枪口仍走原生变换；本轮没有宣称完成全部模拟数据与场景树隔离。
7. 攀爬复用本次查询的脚下／中心格爬速，浮点缓动直接使用 `lerpf`。本机引擎的泛型 `lerp` 浮点分支最终也调用同一个 `lerpf`，因此只减少类型分派，不改变插值公式或精度。[引擎实现](https://github.com/godotengine/godot/blob/a13da4feb/core/variant/variant_utility.cpp#L422)

## 验证口径

全部实现完成后统一验证：固定同一历史八角色片段、同一输入和地形；不启用脚本 profiler 或外部采样；计时只围住完整重放，区间内不输出日志，原始样本先存在内存中。对照包含前后交替运行与每个模拟 tick 的完整状态比较；正式功能探针覆盖控制锁、切枪、蹲伏、倒地、接缝、回滚和地形缓存容量／失效。

## 本轮结果

固定历史片段来自前轮八角色夹具：角色 3、tick 4388 的完整角色状态和地形，连续重放 20 个世界 tick；沿用该帧持续输入、默认时间账户且没有原始初始弹丸锚点。因此这是可重复的固定片段对照，不是上局完整网络到达序列的重演。每组热身 10 次、测量 160 次，按 A1 → B1 → B2 → A2 运行。

| 条件 | 中位数 | P95 | 最大 |
|---|---:|---:|---:|
| 改前 A1 | 12.407 ms | 19.192 ms | 22.196 ms |
| 改后 B1 | 10.658 ms | 12.308 ms | 14.246 ms |
| 改后 B2 | 11.237 ms | 16.408 ms | 16.909 ms |
| 改前 A2 | 12.310 ms | 18.096 ms | 21.717 ms |

两对中位数减少 14.1% 和 8.7%，约 9%–14%；这是完整 reconcile／重放的中位数收益，不能写成角色本体或平均 CPU 成本同样下降该比例。未插桩样本的 P95 两组也较低，但仍有系统波动。独立开启粗阶段计时的对照中，角色累计成本从 1537.240 ms 降到 1466.376 ms（各 3,200 个世界 tick、25,600 次角色步进，约 4.6%）；这个数字包含计时开销，仅作辅助，不与未插桩结果混算。

另外单独捕获 20 个 tick 的八角色完整状态、动作、碰撞矩形和逻辑弹丸状态，使用 `var_to_bytes` 保存后逐字节比较：完全一致，SHA-256 为 `751c639f6cebb382d9f7b983abab9c0ec1ee32aa5ca23687dd35ab8374555a10`。捕获轨迹的运行不进入性能表。

一场真实 GNS + EasyTier 本机中继、禁用 P2P 的八人 Beta 大乱斗，正式战斗 90.016 秒，含主动断线重连，8 人均自然结算并返回原房间，最终收敛误差全部为 0。共 151 条客户端到宿主的路由样本，错误路由 0。

- 正式战斗区间内 `long_frame`（帧间隔 >50 ms）为 **0**。
- 只统计整个采样区间均位于正式战斗中的每秒性能摘要：客户端最大帧间隔 **33.078 ms**，服务端 **26.198 ms**。这不等于所有帧都小于 16.667 ms。
- 排除 epoch 切换和 Beta 回溯重置，29,280 次校正检查中，≥8 px 的计数为 **0**。原始 `correction_max_px` 含回溯／复活位置重置，不能把其中上千像素的位移当作普通校正；对应详细事件按原因分类为 `{"epoch": 53, "rewind": 122}`。
- GNS RTT 的毫秒级报告为 0（722 个样本）。本轮走本机中继，不代表公网性能，也不代表物理延迟严格为零。

测试运行不启用脚本 profiler、外部采样或额外逐函数计时；Godot stdout 使用独立线程持续读取的管道，避免本机 Windows 编辑器构建逐条强制刷普通文件影响主线程。游戏已有的后台结构化日志保持启用。测试用 RenderWatch 观察器优先级仅在副本中设为 3，使其在游戏 1、远端副本 2 之后采样；移动断言未改，游戏调度未改。

## 回归与限制

六项网络回归全部通过：`authority_probe`、`input_playback_smoke`、`local_server_probe`、`playback_lifecycle_probe`、`protocol_probe`、`transport_probe`。控制锁比较、缓存超过 256 条后的逐次原生结果对照、蹲伏／倒地／接缝、回滚、武器与时间机制的既有用例均包含在上述回归及单机回归中。

单机／逻辑回归首轮 **61/66**，五项失败逐一用修改前源码复核，均复现：原来就有 236 个脚本但覆盖数量仍固定为 233；精英掉落用例打印 OK 后以 `0xC0000005` 退出；路径检查把临时输出位置当成已有资源；预瞄用例未兼容尚未创建的 `_laser`；设置页用例断言旧标签。新增 ActorInput 后脚本数为 237，已同步覆盖计数并单独重跑通过，当前合计 **62/66**；其余四项原有失败保留，不能称全套回归全绿。237 个脚本实际加载没有脚本错误。`check_naming.py` 与 `git diff --check` 通过。

没有修改网络协议、输入调度、STATE 复用判定或碰撞规则。未完成所有模拟数据与场景树的分离；武器开火仍依赖原生枪口变换。未做发布模板、GPU 或公网条件的性能验证。本轮不再扩展测试或追改四项历史失败。

## 证据与复现

- 工作报告：`work/actor_step_opt_20261026/report.md`，独立增量补丁：`work/actor_step_opt_20261026/changes.patch`。
- 原始证据目录：`D:\Codes\ChatGPT\cyr\the-cyancular-ruins\.test_logs\actor_step_opt_20261026_115934`。
- `value_before_1/2`、`value_after_1/2` 保存原始内存计时数组、命令与退出状态；`value_trace_before/after/trace.bin` 保存逐 tick 二进制轨迹。
- `functional_unit` 保存全部用例日志，`baseline_failures` 和 `baseline_failures.json` 保存改前对照；`functional_network` 保存六项网络回归；`match_8_relay` 保存整场结构化日志、官方 EasyTier 日志和路由验证。
- 前期原型运行及一份探针初始化解析失败已保留，均不混入上述最终 `value_*` 表；测量夹具、轨迹捕获、stdout 管道和阶段计时的区别见工作报告。
