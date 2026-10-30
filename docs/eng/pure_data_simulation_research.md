# 高频模拟状态与场景边界

## 资料与可参考部分

| 资料 | 可参考部分 |
|---|---|
| Godot：[CPU Optimization](https://docs.godotengine.org/en/stable/tutorials/performance/cpu_optimization.html)、[Data Preferences](https://docs.godotengine.org/en/stable/tutorials/best_practices/data_preferences.html) | 对象访问、容器、动态调用和数据布局的成本，应按实际热点选择数据表示 |
| Godot：[Using Servers](https://docs.godotengine.org/en/stable/tutorials/performance/using_servers.html)、[Thread-safe APIs](https://docs.godotengine.org/en/stable/tutorials/performance/thread_safe_apis.html) | 绕过节点可减少管理成本，但 RID 和资源生命周期需自行负责；活动场景树不能任意跨线程访问 |
| Backroll：[Development Guide](https://github.com/provencher/Backroll/blob/master/Documentation/DevelopmentGuide.md) | 固定步进、明确可保存状态、纯模拟重放和表现副作用隔离；连续结构有利于恢复 |
| NetherRealm：[8 Frames in 16ms](https://media.gdcvault.com/gdc2018/presentations/Stallone_Michael_8FramesIn16ms.pdf)、Ubisoft：[For Honor](https://media.gdcvault.com/gdc2019/presentations/Henry_Jennifer_BackToTheFuture.pdf) | 限制重放工作、检查点布局、生命周期和模拟前后阶段 |
| Photon Quantum：[DSL](https://doc.photonengine.com/quantum/v3/manual/quantum-ecs/dsl)、[View Framework](https://doc.photonengine.com/quantum/v3/video-tutorials/view-framework)、[Game Events](https://doc.photonengine.com/quantum/v3/manual/quantum-ecs/game-events) | 模拟数据、只读显示和事件分别组织，避免显示回写模拟 |
| Factorio：[FFF-302](https://factorio.com/blog/post/fff-302) | GameState 与 LatencyState 分工，预测范围按即时交互需求选择 |
| Factorio：[FFF-271](https://www.factorio.com/blog/post/fff-271)、[FFF-209](https://www.factorio.com/blog/post/fff-209) | 高频数据集中迭代，公共参数准备与简单对象的数据缩减；独立系统的并行条件不能套用于相互阻挡的角色 |
| DDNet：[gamecore.h](https://github.com/ddnet/ddnet/blob/master/src/game/gamecore.h)、Quake III：[bg_pmove.c](https://github.com/id-Software/Quake-III-Arena/blob/master/code/game/bg_pmove.c) | 用结构化输入和明确状态共享移动规则，避免双端各维护一份玩法 |
| Epic：[TNetworkPredictionBuffer](https://dev.epicgames.com/documentation/unreal-engine/API/Plugins/NetworkPrediction/TNetworkPredictionBuffer)、[TNetSimOutput](https://dev.epicgames.com/documentation/unreal-engine/API/Plugins/NetworkPrediction/TNetSimOutput) | 有界历史、同步状态与低频辅助数据分开保存 |
| SnapNet：[Rollback Architecture](https://snapnet.dev/blog/netcode-architectures-part-2-rollback/)、Quantum：[3.1 SDK Notes](https://doc.photonengine.com/quantum/v3/getting-started/preview-3-1/sdk-download) | 估算快照/恢复成本和写时复制的适用范围；引擎级 CoW 不是零成本通用替代 |

## 可参考的判断

完全脱离场景是一种选择，代价是自行管理对象身份、层级、资源和调度。只分离高频模拟状态同样可以建立清晰边界：保留场景和 Godot 物理，把热循环需要的状态与规则放在原生类型中。C++ 减少解释、反射和边界转换，但不会自动消除算法、分配或物理查询成本。

### 引擎调用与数据成本

| 资料 | 可参考部分 |
|---|---|
| Godot：[CharacterBody2D](https://docs.godotengine.org/en/stable/classes/class_characterbody2d.html)、[PhysicsBody2D](https://docs.godotengine.org/en/stable/classes/class_physicsbody2d.html)、[PhysicsServer2D](https://docs.godotengine.org/en/stable/classes/class_physicsserver2d.html) | CharacterBody2D 提供运动和查询接口，角色玩法仍由调用方定义；保留节点不妨碍原生调用物理 API |
| Godot：[位姿实现](https://github.com/godotengine/godot/blob/4.6-stable/modules/godot_physics_2d/godot_body_2d.cpp)、[同帧运动学查询问题 #76256](https://github.com/godotengine/godot/issues/76256) | 手动多 tick 查询须核对物理空间实际采用的变换，不能只写场景变换就假定查询同步；源码和问题有版本适用范围 |
| Godot：[Core Types](https://docs.godotengine.org/en/stable/engine_details/architecture/core_types.html)、[C++ Core Types](https://docs.godotengine.org/en/stable/tutorials/scripting/cpp/core_types.html)、[Static Typing](https://docs.godotengine.org/en/stable/tutorials/scripting/gdscript/static_typing.html) | 分清 Variant、引用容器、打包数组与准确类型调用，避免无依据地认为每份引用都是深复制 |
| Godot 4.7.1：[Dictionary 实现](https://github.com/godotengine/godot/blob/4.7.1-stable/core/variant/dictionary.cpp)、[Dictionary 接口](https://docs.godotengine.org/en/stable/classes/class_dictionary.html) | 带类型字典仍使用 Variant 哈希表和类型校验，不等同于 C++ 数值结构；适用于按身份查找，固定字段热记录可使用结构体或连续数组 |
| Godot：[SceneTree](https://docs.godotengine.org/en/stable/classes/class_scenetree.html)、[CanvasItem](https://docs.godotengine.org/en/stable/classes/class_canvasitem.html)、[Collision Shapes](https://docs.godotengine.org/en/stable/tutorials/physics/collision_shapes_2d.html) | 回调、变换传播、可见性和形状管理属于引擎成本；移入 C++ 后这些职责仍存在 |

## 当前采用

原生角色、武器、弹丸、预测战斗、代理、历史和地形。原生热循环直接访问明确类型，输入及快照在边界转换。预测检查点使用明确字段，弹丸、接触历史和查询依赖使用连续数值；查询历史以带 tick 的有界槽复用容量。低频历史元数据变化时生成，实体身份索引和协议适配保留字典。Godot 保留节点生命周期、资源和物理空间，脚本管理会话、装配和表现，模拟在主线程执行。

没有实现独立物理引擎、全游戏 ECS、通用内存页 CoW 或后台场景模拟。当前职责见[场景内原生模拟](native_scene_simulation.md)和[原生战斗](native_combat_simulation.md)。
