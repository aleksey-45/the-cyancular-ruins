# 世界与地形系统

本文档说明游戏的环面世界拓扑几何、`.cyrm` 地图格式规范、瓦片属性与 16px 子格破坏机制、水体物理环境以及碰撞图层划分。

---

## 一、 环面世界拓扑与地图系统

### 1. 环面拓扑几何（Toroidal Topology）
游戏世界在水平和垂直方向均首尾相连（即左右连通、上下连通的环面空间）：
- **坐标规范化**：角色的逻辑坐标始终约束在 `[0, MAP_WIDTH)` 与 `[0, MAP_HEIGHT)` 范围内。每物理帧通过 `GridPathfinder.wrap_to_range()` 处理越界取模。
- **就近副本锚定**：渲染世界采用 3×3 瓦片平铺，以确保摄像机跨越地图边界时画面无缝连续。对于子弹、敌人及远端联机对手副本，不能直接取模，必须通过 `GridPathfinder.anchor_to_nearest()` 锚定到距离本地玩家最近的环面副本位置，防止跨越边界时画面闪烁或瞬间消失。
- **环面最短距离与向量**：所有实体间的距离判定、射线检测（视线判定）及受击击退向量计算，必须统一调用 `GridPathfinder.toroidal_delta_px(from, to, map_w, map_h)` 获取环面上的最短位移向量，严禁直接使用两点坐标相减。

### 2. 地图数据格式与加载机制
- **地图格式支持**：
  - **cyrm v3 文本格式**：以 `# cyrm-v3` 为标记行。标准地图网格为 125×75（每个宏观大格 64px，对应 8000×4800 像素世界空间）。每格由 4 个字符编码：`[3位纹理编号][1位16进制形状掩码]`（纹理 `000` 表示空气，`001`-`022` 对应各材质；形状掩码 `0`-`F` 对应 2×2 的 32px 子格状态）。
  - **cyrm v4 二进制格式**：由关卡编辑器导出，通过 `core/sim/map_format_v4.gd` 解析。包含 20 字节未压缩文件头（Magic `"CYRM"`、版本 4、Deflate 压缩标识、解压后长度、CRC32 校验、行列数及图层标志位）。支持前景、场景（包含物理碰撞）、后景与背景 4 个图层。每个 64px 宏观网格细分为 4×4 的 16px 子格，支持独立材质与染色。
  - **旧版 v2 格式兼容**：历史单字符地图在加载时由 `MapFormat.convert_old_grid()` 自动转换。
- **核心模块职责**（均继承自 `RefCounted`）：
  - `MazeGenerator`（[`core/sim/maze_generator.gd`](../../core/sim/maze_generator.gd)）：管理当前选中的地图路径（优先读取与可执行文件同级的外部 `.cyrm`，若无则读取 `maps/` 目录下的内置地图），维护全局静态网格数据 `current_grid`。
  - `MapFormat`（[`core/sim/map_format.gd`](../../core/sim/map_format.gd)）：负责 v3 文本格式编解码、瓦片打包解包与出生点解析（`# player` 与 `# player2`）。
  - `MapFormatV4`（[`core/sim/map_format_v4.gd`](../../core/sim/map_format_v4.gd)）：负责 v4 二进制地图的流式解压、CRC32 校验与 16px 子格数据填充。
  - `GridPathfinder`（[`core/sim/grid_pathfinder.gd`](../../core/sim/grid_pathfinder.gd)）：无状态几何与寻路工具类，提供环面距离计算、最短位移、地板检测、Bresenham 视线检测与 A* 寻路。

---

## 二、 全局单例与配置体系

### 1. 全局单例（Autoload，配置于 `project.godot`）
1. `GameLog`（[`core/config/game_log.gd`](../../core/config/game_log.gd)）：接管引擎日志输出，分流持久化写入 `log/client.log` 或 `log/server.log`。
2. `GameParameters`（[`core/config/game_parameters.gd`](../../core/config/game_parameters.gd)）：定义基础重力、瓦片尺寸（`TILE_SIZE = 64`）及世界像素边界。地图加载后调用 `refresh_map_size()` 动态刷新世界尺寸。
3. `NetBus`（[`core/net/net_bus.gd`](../../core/net/net_bus.gd)）：网络 RPC 通道统一收口，服务端与客户端保持一致。
4. `NetBusExt`（[`core/net/net_bus_ext.gd`](../../core/net/net_bus_ext.gd)）：网络扩展通道，负责对局选项、角色颜色、命中确认及大乱斗模式 RPC。
5. `Settings`（[`core/config/settings.gd`](../../core/config/settings.gd)）：用户本地设置持久化（保存于 `user://settings.cfg`）。

### 2. 静态配置类
- 玩家与敌人的基础运动与战斗数值集中于静态类管理：`PlayerParams`（[`core/config/player_params.gd`](../../core/config/player_params.gd)）与 `EnemyParams`（[`core/config/enemy_params.gd`](../../core/config/enemy_params.gd)）。

---

## 三、 瓦片属性与 16px 子格破坏机制

### 1. 瓦片属性定义 (`data/tile_defs.json`)
- 瓦片属性统一配置于 `data/tile_defs.json`（包含类型 `wall/passage/liquid/gas`、生命值、爆炸抗性、可破坏性、弹性、攀爬速度与摩擦力）。通过 `node level_editor/sync-tiles.js` 与前端关卡编辑器保持同步。
- 材质分类：
  - `1-10`：不可破坏的基础墙体。
  - `11-14`：梯子与铁链（攀爬通道）。
  - `15-18`：树叶（可破坏，微弱弹性）。
  - `19-20`：树干（爆炸可破坏）。
  - `21-22`：水体与水面（液体，无碰撞阻挡）。

### 2. 16px 子格破坏与碰撞更新
- **子格生命值管理**：运行时由 `TileDefs` 记录每个 16px 子格的当前生命值（`sub_hp`）。支持单点子格受损（`damage_sub`）与回溯恢复（`restore_sub`）。
- **宏观网格与微观子格关系**：当 64px 大格内的某个 16px 子格被摧毁时，局部更新其碰撞体；**只有当该 64px 大格内的全部 16 个子格都被彻底破坏后，上层宏观网格才会被置为空格（空气）**。
- **碰撞体生成 (`CollisionBuilder`)**：
  - 静态墙体采用贪心算法合并生成矩形碰撞盒，按 3×3 环面铺贴实例化（共享碰撞形状）。
  - 可破坏层按区块（Chunk）划分节点，局部瓦片受损时仅局部重建对应区块的碰撞体，降低性能开销。
- **攀爬机制**：
  - 玩家角色中心或脚底进入梯子或铁链单元格时，按“上”键主动抓取并进入攀爬状态（不受重力影响）。上下移动速度按瓦片配置缩放。
  - 到达梯子顶端且脚底离开梯子后，按“上”键可跃离梯子。铁链顶底设有承托碰撞板。攀爬状态下禁止触发空中下冲。

---

## 四、 水体物理环境

1. **瓦片与渲染**：
   - 地图原生绘制纹理 21（水体）；水面（纹理 22）由渲染逻辑自动检测并在上方无液体时动态派生。
   - `WaterSurfaceLayer` 挂载 `water_surface.gdshader` 着色器，实现水面正弦波起伏效果。
2. **物理交互 (`core/sim/water.gd`)**：
   - 玩家进入水体后脱离常规重力与冲刺，切换为水平游动与垂直浮沉；胸口高度（角色中心偏下 10px）为氧气判定参考线，完全浸入参考线以下开始消耗氧气，浮出水面后平滑恢复。
   - 敌人落水后具有浮力，没顶超时会受到溺水伤害（按秒扣除生命值）。
   - 水下子弹受阻力影响指数衰减：`velocity *= exp(-water_bullet_drag * delta)`。水下爆炸伤害衰减为原来的 25%。

---

## 五、 物理碰撞图层规范（按位定义）

| 图层 | 二进制位 | 用途说明 | 交互掩码与机制 |
|---|---|---|---|
| **Layer 1** | `1` | 地形碰撞层（Solid Terrain） | 永久墙体与可破坏结构层。 |
| **Layer 2** | `2` | 玩家角色（Player） | 本地玩家角色及远端对手物理刚体。 |
| **Layer 3** | `4` | 敌人实体（Enemies） | 普通怪物与精英敌人。 |
| **Layer 4** | `8` | 地面武器掉落物（Weapon Pickups） | 地面武器实体（`WeaponPickup`）。 |

- **子弹碰撞掩码**：常规子弹设置 `collision_mask = 5`（检测 Layer 1 地形与 Layer 3 敌人）。
- **掉落物隔离机制**：地面武器设置 `collision_layer = 8`，`collision_mask = 9`（仅与地形及其他掉落物发生碰撞）。玩家与子弹的掩码均不包含 Layer 4，因此不会产生物理碰撞阻挡，玩家拾取武器完全通过触发区域（Area）检测。
