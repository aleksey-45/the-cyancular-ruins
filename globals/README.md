# globals/ — 跨场景共享逻辑

这里混放了三类"全局",README 记一下,避免随手乱塞:

- **autoload**(项目唯一两个,注册在 `project.godot` 的 `[autoload]`):
  - `gameParameters.gd`(`GameParameters`)——共享常量 + 世界尺寸等少量可变全局状态,`_ready` 按地图回写 `MAP_WIDTH/HEIGHT`。
  - `net_bus.gd`(`NetBus`)——PvP 网络 RPC 唯一收口,客户端/服务器共用。
- **纯静态助手**(`class_name`,不依赖 autoload,可用 `-s` 直测):`water.gd`、`tile_defs.gd`、`collision_builder.gd`、`world_builder.gd`、`maze_generator.gd`、`explosion.gd`、`input_source.gd`、`network_input_source.gd`、`pixel_font.gd` 等。
- **会话/状态类**与数据:如 `pvp_session.gd`;`tile_defs.json` 是砖块属性**单一来源**(`editor/tile_defs.js` 是它给浏览器编辑器用的生成副本)。

约定:文件用 snake_case;新增"跨场景但要按需常驻的东西"先想清楚它是 autoload、静态助手还是数据,别都堆在这里。
