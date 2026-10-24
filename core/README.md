# core/ — 跨场景共享逻辑

四个子目录,按**关注点**分:

```
sim/      几何与模拟:与"世界怎么算"有关,不碰网络也不碰界面
net/      网络与联机:协议、输入源、会话、进程与端口
config/   配置与参数:常量表、可持久化设置、开局选项
present/  表现:字体、音效、视觉特效(与玩法无关的"给人看/听"那层)
```

新文件按「变更原因」归目录,不按名字像什么:

- `sim/`(12)`beam_trace` `collision_aabb` `collision_builder` `explosion` `grid_pathfinder`
  `map_format` `math_util` `maze_generator` `tile_defs` `tile_query` `water` `world_builder`
  —— 改地图格式 / 碰撞语义 / 环面数学时动这里。`maze_generator` 只留**会话状态**
  (选中的地图文件 + `current_grid`)并转发;`.cyrm` 格式在 `map_format`,环面几何与寻路在
  `grid_pathfinder`。
- `net/`(10)`ai_input_source` `local_input_source` `packet_input_source` `player_input`
  `net_bus` `net_bus_ext` `prediction_rollback` `pvp_session` `proc_util` `local_server`
  —— 改协议 / 联机 / 进程编排时动这里。输入源也在这里(`player_input` 纯接口 +
  `local_input_source` / `packet_input_source` / `ai_input_source` 三个实现):本地输入、网络包、
  AI 脚本三种来源可换。
- `config/`(6)`build_info` `enemy_params` `game_parameters` `player_params` `run_options`
  `settings` —— 改数值 / 选项时动这里。
- `present/`(3)`laser_visual` `pixel_font` `sfx` —— 改观感 / 听感时动这里。

## autoload(注册在 `project.godot` 的 `[autoload]`)

**四个**:

- `config/game_parameters.gd`(`GameParameters`)—— 共享常量 + 世界尺寸等少量可变全局状态,
  `_ready` 按地图回写 `MAP_WIDTH/HEIGHT`。
- `net/net_bus.gd`(`NetBus`)—— PvP 网络 RPC 唯一收口,客户端 / 服务器共用。**方法表与原版服务端
  逐字节兼容**,不改。
- `net/net_bus_ext.gd`(`NetBusExt`)—— 旁路扩展协议,与原版 worker 优雅降级(那边本节点不存在)。
- `config/settings.gd`(`Settings`)—— 持久化设置,落盘 `user://settings.cfg`。

★ 移动 autoload 文件时 `project.godot` 的 `[autoload]` 路径必须同步改 —— 改漏的表现是"整个游戏起不来"。

数据文件不在此目录:砖块属性在 `data/tile_defs.json`(`tile_defs.gd` 读它),敌人注册在
`data/enemies.json`(`EnemySpawner` 读它);`level_editor/` 里的 `tile_defs.js` 是给浏览器编辑器
用的生成副本。

约定:文件 snake_case(类名 Pascal,名字 = 类名转 snake);新增"跨场景但要常驻的东西"先定它属于
哪个子目录、是 autoload、静态助手还是数据。
