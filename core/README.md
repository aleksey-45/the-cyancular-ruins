# core/ — 跨场景共享逻辑

模块按照**关注点分离原则**划分为四个子目录：

```
sim/      几何与模拟：世界状态演进、碰撞计算、寻路与几何，独立于网络与 UI
net/      网络与联机：通信协议、输入源抽象、会话管理、进程与端口编排
config/   配置与参数：常量定义、持久化设置、对局运行选项
present/  表现层：字体渲染、音效播放、视觉特效等纯展示逻辑
```

各子目录职责划分如下：

- `sim/`: `beam_trace`, `collision_aabb`, `collision_builder`, `explosion`, `grid_pathfinder`,
  `map_format`, `math_util`, `maze_generator`, `tile_defs`, `tile_query`, `water`, `world_builder` 等。
  维护地图格式解析、碰撞语义与环面几何算法。其中 `maze_generator` 仅维护**对局会话状态**
  （选中的地图与 `current_grid`）并提供接口转发；`.cyrm` 二进制格式交由 `map_format` 处理，环面拓扑与 A* 寻路由 `grid_pathfinder` 负责。
- `net/`: `ai_input_source`, `local_input_source`, `packet_input_source`, `player_input`,
  `net_bus`, `net_bus_ext`, `prediction_rollback`, `pvp_session`, `proc_util`, `local_server` 等。
  维护网络协议、客户端预测与进程生命周期管理。输入系统基于统一接口抽象（`player_input`），
  通过 `local_input_source`、`packet_input_source` 与 `ai_input_source` 分别支持本地操作、网络同步与 AI 驱动。
- `config/`: `build_info`, `enemy_params`, `game_parameters`, `player_params`, `run_options`,
  `settings` 等。集中维护数值常数、平衡性参数及用户配置项。
- `present/`: `laser_visual`, `pixel_font`, `sfx` 等。实现视听表现及辅助渲染逻辑。

## Autoload 全局单例（注册于 `project.godot` 的 `[autoload]`）

当前共注册四个全局单例：

- `config/game_parameters.gd` (`GameParameters`) —— 共享全局常量与世界尺寸状态，在 `_ready` 中根据地图数据更新 `MAP_WIDTH/HEIGHT`。
- `net/net_bus.gd` (`NetBus`) —— PvP 网络 RPC 统一入口，客户端与服务端共用。**RPC 方法签名与原版服务端保持严格兼容**。
- `net/net_bus_ext.gd` (`NetBusExt`) —— 扩展协议路由，在旧版服务端节点不存在时优雅降级。
- `config/settings.gd` (`Settings`) —— 本地持久化配置，保存至 `user://settings.cfg`。

注意：修改 Autoload 脚本路径时，必须同步更新 `project.godot` 中的 `[autoload]` 配置，否则会导致引擎初始化阶段解析失败。

数据文件不存放在此目录：瓦片定义位于 `data/tile_defs.json`（由 `tile_defs.gd` 加载），敌人配置位于 `data/enemies.json`（由 `EnemySpawner` 读取）；`level_editor/` 下的 `tile_defs.js` 为网页地图编辑器的定义副本。

代码规范：文件名统一使用 `snake_case`，类名使用 `PascalCase`。新增跨场景共享逻辑时，请根据职责划分归入对应子目录，并明确其作为单例、静态工具类或数据载体的定位。
