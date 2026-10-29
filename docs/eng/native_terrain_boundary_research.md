# 地形计算与脚本边界资料

## 资料与可参考部分

| 资料 | 可参考部分 |
|---|---|
| Godot：[CPU Optimization](https://docs.godotengine.org/en/stable/tutorials/performance/cpu_optimization.html)、[Using Servers](https://docs.godotengine.org/en/stable/tutorials/performance/using_servers.html) | 高频规则和数据一起集中，减少细粒度跨边界调用；绕过节点时明确生命周期责任 |
| Voxel Tools：[源码](https://github.com/Zylann/godot_voxel)、[VoxelTool](https://voxel-tools.readthedocs.io/en/latest/api/VoxelTool/)、[Efficient Editing](https://voxel-tools.readthedocs.io/en/latest/performance/#editing-voxels-efficiently) | 区域批量编辑、集中提交和局部更新，避免逐体素脚本调用；3D 数据结构不直接照搬 |
| Box2D：[Events](https://box2d.org/documentation/group__events.html) | 步进后批量消费事件，降低逐接触回调成本；会影响后续查询的地形提交仍需及时 |
| Unity Entities：[Entity Command Buffer](https://docs.unity3d.com/Packages/com.unity.entities@1.0/manual/systems-entity-command-buffer-use.html) | 命令与执行点分离；不意味着所有指令都必须异步或延迟到帧末 |
| PhysX：[Invalidating Geometry Caches](https://nvidia-omniverse.github.io/PhysX/physx/5.4.1/docs/CharacterControllers.html#invalidating-internal-geometry-caches) | 几何修改和查询缓存失效范围应配套设计 |
| Photon Quantum：[Game Events](https://doc.photonengine.com/quantum/v3/manual/quantum-ecs/game-events)、[View Framework](https://doc.photonengine.com/quantum/v3/video-tutorials/view-framework) | 模拟数据为权威来源，表现读取事件和快照，不持有另一份可写模拟 |

## 可参考的判断

地形热路径需要共同访问材质、HP、占用和历史。分散在脚本与原生两侧会增加同步和调用成本。以领域指令集中计算，按局部变化输出事件、快照和脏区，可以保留场景管理而避免双份可变状态。

命令接口不必建立后台队列。爆炸影响同 tick 后续弹丸时，碰撞必须同步提交；显示、网络增量和收益可以按批合并。

### 所有权与物理提交细节

[Godot CowData](https://github.com/godotengine/godot/blob/a13da4feb/core/templates/cowdata.h) 的可写访问在共享缓冲下可能触发整份分离复制；少量 HP 改动并不保证少量复制。当前采用原生独占可变地形，边界导出只读视图和快照。

[Box2D 碰撞](https://box2d.org/documentation/md_collision.html)、[模拟](https://box2d.org/documentation/md_simulation.html)与[确定性报告](https://box2d.org/posts/2024/08/determinism/)可参考形状、步进与顺序约束；[Godot 物理介绍](https://docs.godotengine.org/en/stable/tutorials/physics/physics_introduction.html)可核对引擎对象职责。项目继续使用 Godot 物理，没有切换 Box2D 或据此宣称跨平台位级确定性。

## 当前采用

NativeTerrain 独占地形、历史和缓存；脚本提交伤害、补丁和恢复指令，消费批量变化和只读快照。单人、权威与预测共用计算。HP-only 变化不重建形状，存亡变化只更新脏块，后续查询前提交碰撞，模拟后提交显示。没有另建第二套物理引擎或可写脚本地形。接口见[原生地形](native_terrain.md)。
