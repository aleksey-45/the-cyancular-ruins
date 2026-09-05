# core/ — 跨场景共享逻辑

"全局"分三类,README 记一下,避免随手乱塞:

- **autoload**(项目唯一两个,注册在 `project.godot` 的 `[autoload]`):
  - `game_parameters.gd`(`GameParameters`)——共享常量 + 世界尺寸等少量可变全局状态,`_ready` 按地图回写 `MAP_WIDTH/HEIGHT`。
  - `net_bus.gd`(`NetBus`)——PvP 网络 RPC 唯一收口,客户端/服务器共用。
- **纯静态助手**(`class_name`,不依赖 autoload,可用 `-s` 直测):`water.gd`、`tile_defs.gd`、`collision_builder.gd`、`world_builder.gd`、`maze_generator.gd`、`explosion.gd`、`input_source.gd`、`network_input_source.gd`、`pixel_font.gd` 等。
- **会话/状态类**:如 `pvp_session.gd`。

数据文件不在此目录:砖块属性在 `data/tile_defs.json`(`tile_defs.gd` 读它),敌人注册在 `data/enemies.json`(`EnemySpawner` 读它);`level_editor/` 里的 `tile_defs.js` 是给浏览器编辑器用的生成副本。

约定:文件用 snake_case(类名 Pascal,名字=类名转 snake);新增"跨场景但要常驻的东西"先想清楚它是 autoload、静态助手还是数据。
