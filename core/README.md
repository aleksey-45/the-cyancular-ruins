# core/ — 跨场景共享逻辑

2026-09-15 按**关注点**分成四个子目录(阶段 4.6)。此前 29 个 `.gd` 平铺在一层,
"协议 / 几何 / 配置 / 表现"混在一起 —— 找东西只能靠字母序,而新文件该放哪没有任何依据。

```
sim/      几何与模拟:与"世界怎么算"有关,不碰网络也不碰界面
net/      网络与联机:协议、输入源、会话、进程与端口
config/   配置与参数:常量表、可持久化设置、开局选项
present/  表现:字体、音效、视觉特效(与玩法无关的"给人看/听"那层)
```

**分类是按"这个东西因为什么而改变"划的**,不是按名字像什么:

- `sim/`(12)`beam_trace` `collision_aabb` `collision_builder` `explosion` `grid_pathfinder`
  `map_format` `math_util` `maze_generator` `tile_defs` `tile_query` `water` `world_builder`
  —— 改地图格式/碰撞语义/环面数学时动这里。★ `maze_generator` 只留**会话状态**
  (选中的地图文件 + `current_grid`)并转发;`.cyrm` 格式进 `map_format`、环面几何与寻路进
  `grid_pathfinder`(阶段 5.7)。
- `net/`(11)`ai_input_source` `local_input_source` `packet_input_source` `player_input`
  `net_bus` `net_bus_ext` `prediction_rollback` `snapshot_interp` `pvp_session` `proc_util`
  `local_server`
  —— 改协议/联机手感/进程编排时动这里。★ **输入源放这里**(`player_input` 纯接口 +
  `local_input_source` / `packet_input_source` / `ai_input_source` 三个实现):
  它们的价值就体现在"本地输入 / 网络包 / AI 脚本"三种来源可换,与联机是同一条轴。
- `config/`(6)`build_info` `enemy_params` `game_parameters` `player_params` `run_options`
  `settings` —— 改数值/选项时动这里(都是"读出来就是个数"的东西)。
- `present/`(3)`laser_visual` `pixel_font` `sfx` —— 改观感/听感时动这里。

## autoload(注册在 `project.godot` 的 `[autoload]`)

**四个**(此前的 README 写"项目唯一两个"是过期说法:`NetBusExt` 与 `Settings` 漏登记了):

- `config/game_parameters.gd`(`GameParameters`)—— 共享常量 + 世界尺寸等少量可变全局状态,
  `_ready` 按地图回写 `MAP_WIDTH/HEIGHT`。
- `net/net_bus.gd`(`NetBus`)—— PvP 网络 RPC 唯一收口,客户端/服务器共用。**方法表与原版服务端
  逐字节兼容**,别动。
- `net/net_bus_ext.gd`(`NetBusExt`)—— 旁路扩展协议,与原版 worker 优雅降级(那边本节点不存在)。
- `config/settings.gd`(`Settings`)—— 持久化设置,落盘 `user://settings.cfg`。

★ **移动 autoload 文件时,`project.godot` 的 `[autoload]` 路径必须同步改** —— 改漏的表现是
"整个游戏起不来"而不是某个功能坏掉,别靠试。

数据文件不在此目录:砖块属性在 `data/tile_defs.json`(`tile_defs.gd` 读它),敌人注册在
`data/enemies.json`(`EnemySpawner` 读它);`level_editor/` 里的 `tile_defs.js` 是给浏览器编辑器
用的生成副本。

约定:文件用 snake_case(类名 Pascal,名字=类名转 snake);新增"跨场景但要常驻的东西"先想清楚
它属于哪个子目录、以及它是 autoload、静态助手还是数据。
