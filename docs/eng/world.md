# 世界与地形系统

> 本文档属于 [`CLAUDE.md`](../../CLAUDE.md) 架构分域文档。
> 涵盖范围：环面拓扑世界 · 地图数据格式（v3 与 v4）· 参数体系（Autoload 与常量）· 瓦片属性与 16px 子格破坏 · 水体物理环境 · 物理碰撞图层规范。

---

## 一、 环面世界拓扑与地图系统

### 1. 环面拓扑几何（Toroidal Topology）
游戏世界在水平和垂直方向均呈现环面闭合拓扑（左右连通、上下连通）：
- **坐标规范化（Canonical Coordinate）**：角色的物理位置在经过位移计算后，每物理帧通过 `GridPathfinder.wrap_to_range()` 取模约束在 `[0, MAP_WIDTH)` 与 `[0, MAP_HEIGHT)` 范围内。
- **就近副本锚定（Anchor to Nearest Replica）**：世界图层按 3×3 环面铺贴以保证摄像机跨接缝时画面连续。对于子弹、敌方实体及远端对手副本，不得直接取模回规范区间，必须使用 `GridPathfinder.anchor_to_nearest()` 锚定至相对本地玩家最近的副本坐标，防止跨越接缝时视觉实体突兀消失。
- **最短向量与测距**：所有实体间的距离判定、射线检测（LOS）以及受击击退向量计算，必须统一调用 `GridPathfinder.toroidal_delta_px(from, to, map_w, map_h)` 取得环面最短位移向量。

### 2. 地图数据格式与加载体系
- **地图格式支持**：
  - **cyrm v3 格式**：ASCII 文本格式，标记行包含 `# cyrm-v3`。地图标准网格尺寸为 125×75（每个大格 64px，对应 8000×4800 像素世界空间）。每个单元格由 4 个字符编码：`[3位纹理编码][十六进制形状掩码]`（纹理 `000` 表示空气，`001`-`022` 对应各材质；形状掩码 `0`-`F` 对应 2×2 的 32px 子格状态）。
  - **cyrm v4 二进制格式**：由关卡编辑器生成并支持游戏运行时解析（`core/sim/map_format_v4.gd`）。文件包含 20 字节明文头部（Magic `"CYRM"`、版本 4、Deflate 压缩标识、CRC32 校验、子格行列数及图层标志位）。包含前景、场景（带物理碰撞）、后景与背景 4 个图层。每个宏观 64px 大格细分为 4×4 的 16px 子格，每个子格包含独立材质纹理与辅码着色数据。
  - **旧版 v2 格式兼容**：历史单字符地图在加载时自动由 `MapFormat.convert_old_grid()` 展开并转为等效尺寸。
- **核心模块职责**（均继承自 `RefCounted`，非 Autoload）：
  - `MazeGenerator`（[`core/sim/maze_generator.gd`](../../core/sim/maze_generator.gd)）：管理当前选中的地图路径（`map_file_path()` 优先读取可执行文件同级的外部 `.cyrm`，其次从 `maps/` 目录下匹配）及全局静态网格数据引用 `current_grid`。
  - `MapFormat`（[`core/sim/map_format.gd`](../../core/sim/map_format.gd)）：无状态纯逻辑，负责地图文本格式编解码、瓦片打包解包与出生点元数据解析（`# player` 与 `# player2`）。
  - `MapFormatV4`（[`core/sim/map_format_v4.gd`](../../core/sim/map_format_v4.gd)）：负责 cyrm v4 二进制地图的流式解压、CRC32 校验及 16px 子格数据装填。
  - `GridPathfinder`（[`core/sim/grid_pathfinder.gd`](../../core/sim/grid_pathfinder.gd)）：无状态几何与寻路计算器，提供环面拓扑距离、最短位移、地板检测、Bresenham 视线检测及 A* 寻路。

---

## 二、 全局参数体系

### 1. 全局单例（Autoload，配置于 `project.godot`）
1. `GameLog`（[`core/config/game_log.gd`](../../core/config/game_log.gd)）：接管控制台日志输出并持久化写入 `log/client.log` 或 `log/server.log`。
2. `GameParameters`（[`core/config/game_parameters.gd`](../../core/config/game_parameters.gd)）：定义基础重力、瓦片物理尺寸（`TILE_SIZE = 64`）及世界像素边界。地图加载后动态调用 `refresh_map_size()` 更新世界尺寸。
3. `NetBus`（[`core/net/net_bus.gd`](../../core/net/net_bus.gd)）：PvP 专用网络 RPC 通道单一收口，服务端与客户端保持一致。
4. `NetBusExt`（[`core/net/net_bus_ext.gd`](../../core/net/net_bus_ext.gd)）：扩展旁路协议（对局选项、角色配色、命中确认与大乱斗 RPC）。
5. `Settings`（[`core/config/settings.gd`](../../core/config/settings.gd)）：本地用户设置持久化（存储于 `user://settings.cfg`）。

### 2. 无状态配置类
- 玩家与敌人基础属性通过静态常量类统一管理：`PlayerParams`（[`core/config/player_params.gd`](../../core/config/player_params.gd)）与 `EnemyParams`（[`core/config/enemy_params.gd`](../../core/config/enemy_params.gd)）。

---

## 三、 瓦片属性与 16px 子格破坏机制

### 1. 瓦片属性定义（单一来源 `data/tile_defs.json`）
- 瓦片属性由 `data/tile_defs.json` 唯一定义（包含类型 `wall/passage/liquid/gas`、生命值、爆炸衰减率、子弹与爆炸可破坏性、弹性、攀爬速度与摩擦力）。编辑器同步脚本 `node level_editor/sync-tiles.js` 用于校验一致性。
- 纹理 1-10 为不可破坏基础墙体；11-14 为梯子与锁链（攀爬通道）；15-18 为树叶（可破坏，弱弹性）；19-20 为树干（爆炸可破坏）；21-22 为水体与水面（液体，无阻挡）。

### 2. 16px 子格物理破坏与碰撞重构
- **16px 子格生命值管理**：运行时由 `TileDefs` 维护每个 16px 子格的生命值数据（`sub_hp`）。支持单点子格受损（`damage_sub`）与回溯还原（`restore_sub`）。
- **宏观网格与微观子格关系**：当某个 64px 大格内的子格受到破坏时，局部更新 16px 碰撞体；**只有当大格内的全部 16 个子格均被完全摧毁时，才将上层宏观网格标记为空空气**。
- **碰撞构建机制 (`CollisionBuilder`)**：
  - 静态墙体采用贪心算法合并生成矩形碰撞箱，并按 3×3 环面副本实例化（共享同一个 Shape）。
  - 可破坏层按区块（Chunk）划分节点，局部瓦片受损时仅对所在区块执行局部增量重建，大幅降低物理引擎重建开销。
- **攀爬机制**：
  - 玩家中心或脚底进入梯子或锁链单元格时，按“上”键主动抓取（脱离常规重力）。上爬与下滑根据瓦片配置缩放垂直速度。
  - 到达梯子顶端且脚底脱离后，按“上”键跳离攀爬。锁链仅在顶底两端建有薄碰撞承托台。在攀爬通道上禁止触发空中下冲。

---

## 四、 水体物理环境

1. **瓦片与渲染**：
   - 地图原生绘制纹理 21（水体）；水面（纹理 22）由渲染逻辑自动根据上方是否有液体自动派生。
   - `WaterSurfaceLayer` 挂载 `water_surface.gdshader` 着色器，实现逐格正弦波动态起伏与拉伸。
2. **物理交互 (`core/sim/water.gd`)**：
   - 玩家进入水体后脱离重力与冲刺，切换为水平游动与垂直浮沉；呼吸（氧气）判定参考线位于胸口高度（中心偏下 10px），没入参考线以下开始消耗氧气，浮出后平滑回升。
   - 普通敌人落水后具有浮力，没顶超时后受到溺水伤害（每秒扣除固定生命值）。
   - 水体内弹道阻力按指数衰减：`velocity *= exp(-water_bullet_drag * delta)`。爆炸伤害在水下经衰减系数缩放（0.25）。

---

## 五、 物理碰撞图层规范（按位定义）

| 图层编号 | 二进制位 | 语义定位 | 交互掩码与说明 |
|---|---|---|---|
| **Layer 1** | `1` | 地形碰撞层（Solid Terrain） | 永久墙体与可破坏结构层。 |
| **Layer 2** | `2` | 玩家物理实体（Player） | 本地玩家及远端对手刚体层。 |
| **Layer 3** | `4` | 敌方生物实体（Enemies） | 普通敌人与精英怪物层。 |
| **Layer 4** | `8` | 地面掉落物（Pickups / Dropped Weapons） | 地面武器（`WeaponPickup`）占用该层。 |

- **子弹碰撞掩码**：常规子弹 `collision_mask = 5`（检测 Layer 1 地形与 Layer 3 敌人）。
- **掉落物隔离机制**：地面武器 `collision_layer = 8`，`collision_mask = 9`（仅与地形及其他掉落物发生碰撞），玩家与子弹掩码不包含 Layer 4，从而天然杜绝物理碰撞干扰，仅通过触发区域执行拾取判定。
