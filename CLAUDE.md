# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

### 项目概览

基于 Godot 4.7（标准版）开发的 2D 横版平台跳跃射击演示项目「The Cyancular Ruins」。视口分辨率 1920×1440，渲染后端使用 `rendering/mobile`。核心机制：

- **环面世界**：地图水平与垂直方向无缝回绕，敌人、弹丸与镜头平滑跨越地图接缝。
- 单关卡（Level0）通过 ASCII 文本地图文件加载，运行时不执行随机地图生成。

## 常用命令

若 Godot 未加入系统 PATH，需使用绝对路径调用。当前主用版本为 **Godot 4.7.1 标准编辑器**（详见 `RELEASE.md`）。

**引擎路径配置**：`tests/*.sh` 与 `start_server.bat` 读取环境变量 `GODOT`（控制台版），`tools/build_release.py` 读取 `GODOT_EDITOR`（标准编辑器版，用于导出与自动化构建）。未设置时回退至本地默认路径，各脚本入口统一定义默认值（`tests/env.sh`、`start_server.bat`、`build_release.py`）。Shell 脚本统一通过 `source "$(dirname "$0")/env.sh"` 引入 `$GODOT` 与进程管理辅助函数。默认路径下的常用命令如下：

```bash
# 冒烟测试（SceneTree 脚本执行，通过时输出 SMOKE OK 并以代码 0 退出）
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s res://tests/enemy_logic_smoke.gd

# 无头模式启动游戏并在 90 帧后退出（用于捕获脚本运行时异常）
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . --quit-after 90

# PvP 服务端（无头模式监听 7777 端口，终端保持开启代表运行中；亦可直接运行仓库根目录的 start_server.bat）
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . res://server/server_main.tscn

# 导出单可执行文件发布版本
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64.exe" --headless --path . --export-release "Windows Desktop" "The Cyancular Ruins.exe"
```

说明：测试与发布构建由开发者按需执行。发布与导出模板裁剪细节参见 `RELEASE.md`（采用自定义模板单文件导出，保留 WebP 模块）。常规 GDScript 代码修改仅需重新导出可执行文件，无需重新编译引擎模板。

**版本号管理**：版本号单一来源为 `project.godot` 中的 `application/config/version`，格式遵循数字与点分规范（如 `1.1.4`）。`tools/build_release.py` 在导出前会将版本号与构建时间戳写入 `core/config/build_info.gd`，导出完成后恢复为开发占位符以保持工作区整洁。版本信息展示于主菜单与服务端启动日志。构建产物输出至 `builds/` 下独立版本目录（包含客户端与服务端可执行文件以及 `easytier/` 运行依赖组件）。构建脚本包含产物冒烟测试，验证服务端端口监听与隧道建立，确保发布包逻辑完整性。服务端口参数需置于 `--` 之后传递（`server_main.gd` 读取 `OS.get_cmdline_user_args()`）。日志路径规范与详细配置参见 `docs/netplay.md`，由全局单例 `GameLog` (`core/config/game_log.gd`) 统一落盘。

## 架构

### 环面世界与地图
- 地图格式：文本格式 `.cyrm`（如 `maps/demo.cyrm`）。v3 格式包含 `# cyrm-v3` 标识：125×75 瓦片网格 × 64px = 8000×4800 像素世界空间；每个单元格由 4 字符组成：`[3位纹理编码][十六进制形状掩码]`（纹理 `000` 为空气，`001`-`022` 对应各材质；形状掩码 `0`-`F` 对应 2×2 子格状态）。旧格式在加载时自动进行 2×2 坐标转换。注释行以 `#` 开头，包含出生点元数据（`# player <col> <row>` 及 PvP 模式的 `# player2 <col> <row>`）。加载逻辑：`MazeGenerator.map_file_path()` 优先读取可执行文件同级目录的 `.cyrm` 文件，其次从 `maps/` 目录中选择。
- **地图与环面核心架构**（均为 `RefCounted` 实现，非单例）：
  - `MazeGenerator` (`core/sim/maze_generator.gd`)：维护对局会话状态（当前选中的地图路径与静态 `current_grid`），并向底层组件提供统一的调用转发接口。新地图格式由 `MapFormat` 处理，几何运算与寻路由 `GridPathfinder` 负责。
  - `MapFormat` (`core/sim/map_format.gd`)：无状态纯逻辑，负责 `.cyrm` 格式的编解码、瓦片数据打包与解包、地图尺寸查询与出生点解析。
  - `GridPathfinder` (`core/sim/grid_pathfinder.gd`)：无状态纯逻辑，提供环面拓扑距离计算、最短位移向量、坐标回绕、实体就近锚定、地板格检测以及基于 Bresenham 算法的视线与 A* 寻路计算。
  - 阻挡检测统一调用 `TileDefs.is_blocked`。测试脚本若未固定指定地图，每次运行会随机选择地图，导致跨进程测试输出不具备可比性。
- **坐标回绕与就近锚定原则**：玩家每帧通过 `wrap_to_range` 将坐标限制在主副本区间；敌人与子弹等实体则通过 `anchor_to_nearest` 锚定至相对玩家最近的环面副本，配合 3×3 瓦片渲染确保跨接缝视野连续。

### 参数体系（重要约定）
- **Autoload 全局单例**（共五个）：
  - `GameLog` (`core/config/game_log.gd`)：接管引擎全部输出日志并写入 `log/client.log` 或 `log/server.log`。
  - `GameParameters` (`core/config/game_parameters.gd`)：维护重力、瓦片尺寸、地图尺寸等全局常量与配置，在 `_ready()` 中根据地图尺寸更新 `MAP_WIDTH/HEIGHT`。
  - `NetBus` (`core/net/net_bus.gd`)：PvP RPC 网络通信统一接口，保持服务端与客户端接口定义严格一致。
  - `NetBusExt` (`core/net/net_bus_ext.gd`)：扩展协议路由，支持对局选项同步、角色染色等附加功能，在旧版服务端上优雅降级。
  - `Settings` (`core/config/settings.gd`)：本地设置持久化（音量、按键映射、换弹与界面选项等，存储于 `user://settings.cfg`）。换弹机制对全部模式默认启用，弹药与装填状态已纳入玩家状态快照管理。
- 玩家与敌人参数配置采用无状态常量类 `PlayerParams` 与 `EnemyParams` 统一管理。

### 敌人系统 (scenes/enemies/)
继承关系：`EnemyBase` → `EnemyFlyBase` → `EnemyFlyBird`；`EnemyJumpBird` 直接继承 `EnemyBase`：
- `EnemyBase` (`CharacterBody2D`)：导出基础属性（生命值、接触伤害、击退强度与衰减率）；统一状态机管理；受击与死亡闪白统一由基类实现；限制转向翻转频率以避免视觉抖动；敌人阵亡后保留物理实体与碰撞，仅禁用 AI 行为，后续受击仅计算击退，移速自然衰减并最终停止。
- `EnemyFlyBase`：飞行敌人寻路基类，基于实体碰撞箱执行 A* 寻路，处理死区逃逸及飞行/站立碰撞箱切换。
- `EnemyFlyBird`：飞行敌人状态机实现（睡眠、起飞、巡逻飞行、平抛射击、蓄力冲撞、返航落地）。
- `EnemyJumpBird`：地面跳跃近战敌人，包含跳跃、后撤与扑击动作。
- `EnemyBlackBird`：瞬移突袭刺客，包含随机游走、视线检测、跃起瞬移、突进冲锋与大后撤逻辑。
- 敌人配置由 `data/enemies.json` 集中维护，包含标识、名称、对应场景与代表色。地图生成时通过 `EnemySpawner` 随机选择地板格生成。网页端编辑器注册表由 `node level_editor/sync-enemies.js` 同步生成。中文显示名称链已完整移除（2026-09-17），PvP 播报直接使用 `kill_event` 载荷中携带的玩家名称。

### 武器与子弹系统 (scenes/weapons/)
- `WeaponBase` (`Node2D`)：通过导出参数配置射速、弹速、射程、伤害、冲击力、后坐力及镜头震动等；开火逻辑将鼠标瞄准方向与角色移动朝向解耦，统一取开火瞬间的鼠标朝向生成弹丸。
- 现有武器：手枪、步枪、M82A1（重型狙击）、S686（霰弹枪）、榴弹发射器（重型爆炸武器）、激光枪（即时光束反射武器）。
- `LaserWeaponBase` (`scenes/weapons/laser_weapon_base.gd`，继承 `WeaponBase`)：即时光束武器抽象基类，将传统弹丸循环重构为瞬时光束追踪与单次判定结算。提供光束几何追踪（`_emit_beam`）、伤害结算（`_apply_beam_damage`）与视觉表现（`_spawn_beam_visual`）三个扩展接口。衍生类 `laser_gun` 实现镜面反射光束（DDA 子格扫描，支持多次反射与瓦片破坏）。PvP 模式下服务端统一裁决并广播光束数据，远端客户端渲染对应的视觉光线。
- 弹丸类 `BulletBase`：支持常规物理弹丸与投掷爆炸弹（如榴弹）。爆炸弹撞击反弹，到达引信时间或射程上限时触发范围爆炸；命中玩家时通过 `PLAYER_HIT_RADIUS` 检测触发接触引信；服务端由 `MatchHost._adjudicate_grenade` 裁决直接伤害与爆炸伤害；爆炸范围伤害与遮挡衰减计算由 `core/sim/explosion.gd` 负责。
- 客户端视觉弹丸碰撞优化：本地客户端通过 `_cull_bullet_contacts` 检测非榴弹视觉弹丸与远端玩家幽灵体的接触，并在命中时立即销毁本地弹丸副本，消除视觉穿透感，权威伤害判定仍由服务端执行。

#### 武器背包与地面拾取
- 背包容量规则：支持 8 格容量预算与最多 4 把武器上限（轻型 2 格 / 中型 3 格 / 重型 4 格）。
- `WeaponInventory` (`core/sim/weapon_inventory.gd`)：无状态背包逻辑，持有项维护武器类型、实例 ID（`inst`）与弹夹剩余弹药，支持同类型多把武器的独立状态跟踪。
- 拾取与丢弃：按键拾取优先选取最近的武器实体；容量不足时替换当前手持武器；长按 Q 键触发丢弃并更新 HUD 进度条。
- 地面武器实体 `WeaponPickup`：独立实体场景，包围盒基于精灵像素生成；统一对齐局部中心，使渲染位置、碰撞体与拾取判定圆心保持一致；模拟落体采用速度指数衰减与阈值清零，保证客户端与服务端在不同网络时延下模拟落点收敛一致。必须挂载于 `$WorldViewport` 节点下以确保渲染正常。
- 服务端权威管理（`MatchGround`）：地面武器生成与移除通过 `NetBus` 广播事件；开局及重连时通过 `match_sync` 全量下发；回合切换时重置并重新下发全场地面武器。掉落判定在角色进入倒地状态瞬间触发。
- 键位映射：数字键 1-4 对应背包槽位，支持滚轮循环切换手持武器。输入数据包中的 `weapon` 字段统一为 1-based 的背包索引。

### 玩家系统 (scenes/player/player.gd)
- `CharacterBody2D` 实现：平滑移动曲线、土狼时间（Coyote time）、跳跃输入缓冲、可变跳跃高度、冲刺（继承最近水平朝向，支持空中冲刺重力缩放与打断机制）、逐帧推导下蹲状态与下蹲移动、多姿态动态碰撞多边形切换、受击无敌帧与击退位移结算。
- 倒地状态：保留重力与击退等基础物理模拟，仅禁用玩家输入操作。单人模式下按 R 键调用 `Level0.restart_single()` 进行就地状态重置，将瓦片网格与碰撞重置为初始基线，清理弹丸与敌人后重新生成，玩家恢复满状态返回出生点，避免重复加载场景产生底层异常。PvP 与大乱斗模式下由服务端权威仲裁复活逻辑。
- 武器槽位注册：在 `weapon_component.gd` 中统一维护 `WEAPONS`、`DISPLAY_NAMES` 与 `TIERS` 常量表。
- **模块架构解耦**：根节点 `player.gd` 维护移动、姿态与物理帧调度编排；攀爬、战斗与武器管理分别拆分为独立组件（`ClimbComponent`、`CombatComponent`、`WeaponComponent`）。组件不单独注册 `_physics_process`，由根节点按序显式调度，保证调度顺序稳定与接口兼容。
- **输入抽象**：输入读取依赖 `core/net/player_input.gd` 的 `PlayerInput` 接口，支持本地输入（`LocalInputSource`）、网络数据包输入（`PacketInputSource`）与 AI 输入源（`AiInputSource`）无缝替换。PvP 服务端通过数据包注入驱动远端玩家。

### 渲染管线 (Level0.tscn)
根节点将未处理输入转发至 `WorldViewport`（SubViewport）；游戏世界渲染进 SubViewport，通过 `PostProcess` 执行像素缩放裁切与倒地暗角特效。相机使用 `camera_2d.gd`，支持前瞻与死区平滑。
- **瓦片渲染**：`_create_wall_tileset()` 运行时将 32px 材质最近邻放大为 64px 瓦片，生成 16×20 图集并铺设 3×3 环面网格。
- **碰撞构建**：`CollisionBuilder` 将形状掩码展开为 32px 子格，执行贪心矩形合并后按 9 环面副本实例化。永久墙构建单一静态节点，可破坏瓦片按区块分块维护，瓦片破坏时仅局部重建对应区块。
- **包围盒计算**：`CollisionAabb` 静态提供启用中碰撞体的世界坐标 AABB 计算，为激光判定、水体检测与避障提供统一几何来源。
- **重叠脱困检测**：`Unstick` 静态计算嵌入实心格矩形的向上最小修正位移，探测矩形四边设置 0.5px 内缩，避免边界重合误判。
- **世界构建**：`WorldBuilder` 统一负责地图网格数据加载与碰撞实体构建，单人模式与联机端共用。

### 挤压与拉伸补间形变 (squash & stretch)
组件 `SquashStretch` (`scenes/effects/squash_stretch.gd`) 为纯表现层实现，挂载于玩家、敌方实体及远端副本上，仅修改动画节点的 `scale` 属性：
- 计算模型：由垂直速度推导的连续项 `_air` 与事件触发的瞬时冲量 `_impulse` 叠加计算，并通过指数衰减回归中性状态。
- 参数设定：最大形变量 `squash_amount` 设定为 0.06，恢复速度 `squash_recover` 为 16，形变标量严格钳制在 `[-1, 1]` 区间。
- 落地检测：基于 `vel_y > _land_min_vy` 阈值（默认 220.0）进行无状态推导。宿主在调用 `move_and_slide()` 之前缓存 `_pre_move_vy`，并过滤非自由落体产生的下落速度（如水中移动或梯子攀爬），避免持续产生形变异常。
- 倒地表现：倒地状态下禁用形变（`suppressed = true`），避免身体旋转与缩放叠加产生异常变形。
- 副本同步：远端副本基于快照数据推导垂直速度与落地状态，结合客户端本地网格水体检测，在表现层平滑推进形变动画。
- 宿主水域过滤策略：玩家侧过滤 `in_water` 与攀附状态以避免非下落速度触发落地形变；敌人侧直接使用 `velocity.y`，确保真实落水挤压表现正常触发。配套测试包含纯逻辑测试 `tests/squash_stretch_smoke.gd` 及相关场景验证用例。

### 界面系统 (UI)

界面开发遵循统一规范：

- **控件工厂与调色板**：`ui/ui_factory.gd` 是界面样式的统一入口与全局调色板。颜色定义集中于常量（`C_BG`, `C_SURFACE`, `C_ROW`, `C_FIELD`, `C_BTN_FILL`, `C_BORDER`, `C_ACCENT`, `C_DANGER`, `C_TEXT`, `C_WARN` 等），严禁在业务界面中散落 `Color(...)` 字面量。字号必须为 16 的倍数以保持硬边缘像素对齐。
- **控件样式规范**：
  - 按钮统一采用描边样式（`style_button`），确保描边对比度达标；
  - 面板底色使用不透明填充（`panel_box`），防止下层菜单内容穿透重影；
  - 开关控件（`style_check`）采用自绘状态图标，并在布局上使用固定宽度的标签列与开关并排（`HBoxContainer`），避免开关被容器拉伸分离。
- **字体规范**：西文字体使用 `assets/fonts/less_perfect_dos_vga.ttf`（8×16 DOS 位图字体）；中文字体使用开源 GNU Unifont (`assets/fonts/unifont-17.0.05.otf`)，统一通过 `PixelFont.shared()` 禁用抗锯齿与微调，保证 16 像素网格硬边缘对齐。
- **HUD 视觉层级**：HUD 信息面板统一采用半透明深色底板（默认 `Color(0, 0, 0, 0.1)`，大乱斗排行榜因对比度需要设为 `0.25`）。右上角击杀计数器不使用底板（通过 `draw_center = false` 实现完全透明）。低弹量警示色统一采用金色（`C_WARN`），装填进度条使用主强调色，长按丢弃进度条使用危险警示色（`C_DANGER`）。
- **武器槽位控件**：`ui/weapon_slots.gd` (`WeaponSlots`) 为自包含控件，挂载于单人、1v1 及大乱斗 HUD，分为未占用、已占用与手持三种透明度层级表现。
- **圆形小地图**：`ui/minimap.gd` 采用以玩家为中心的圆形雷达视野（`CanvasLayer` 层级 131），覆盖 50 格探测半径。利用着色器纹理重复采样实现环面无缝回绕，通过 `GridPathfinder.toroidal_delta_px` 计算最短位移向量。3v3 模式下根据队伍颜色渲染全部实体，且所有数据源统一通过 `team_game._minimap_entries()` 过滤，防止跨帧销毁引起下标错位。
- **大厅基类抽象**：`scenes/lobby_page.gd` (`LobbyPage`) 提供 1v1、大乱斗与 3v3 房间列表、连接状态机与通用配置组件的统一抽象，子类仅保留特定模式的布局与协议差异。

### 瓦片属性与地图破坏 (data/tile_defs.json)
- **数据驱动定义**：`data/tile_defs.json` 为瓦片属性的单一数据源，配置材质类型（墙体、通道、液体、气体）、耐久度（HP）、爆炸衰减、破坏条件、弹力与摩擦系数等。网页编辑器通过同步脚本生成副本。
- **材质特性**：纹理 1-10 为不可破坏墙体；11 为梯子、12-14 为锁链通道（提升攀爬速度）；15-18 为树叶（可破坏墙体，受击微弹）；19-20 为树干（爆炸可破坏）；21 与 22 分别为水体与水面（液体无碰撞）。
- **破坏结算**：`TileDefs.damage_tile` 结算伤害，瓦片耐久耗尽后置为空白，同步通知 `Level0.on_tile_destroyed` 清除渲染层与子格数据，标记所在区块在下一帧重建碰撞体。
- **攀爬机制**：角色中心或脚底进入通道瓦片时，按上键进入攀附状态（不受重力影响），梯子与锁链分别应用独立的移动速度倍率；锁链下行直接解除攀附自由落体；脚底移出通道顶端后按上键跳离；锁链顶底基座生成薄碰撞边缘防止穿透。

### 水体环境与物理模拟
- **瓦片配置**：水体（21）与水面（22）属于 `type=liquid`，不产生物理阻挡。水面起伏通过 `water_surface.gdshader` 实现逐格正弦波动。
- **水体工具类**：`Water` (`core/sim/water.gd`) 静态提供水体浸入检测、水面高度计算、淹没状态判定、水体阻力系数与爆炸衰减系数。
- **角色游泳与呼吸**：主角进入水体后由 `swim_component.gd` 接管物理逻辑，禁用跳跃、下蹲与冲刺，转换为水平游动、上浮与下沉控制。水下呼吸检测参考线设于胸口下方，进入深度超过该线时持续消耗氧气。
- **敌人与弹丸影响**：敌人在水中根据重力与浮力平衡移动，沉没超时后持续扣除溺水伤害；水体中爆炸伤害与击退强度按衰减系数结算（0.25）；水下弹丸受指数级流体阻力衰减速度。

### 碰撞分层设计（位掩码）
- 层位定义：层 1 = 地形环境、层 2 = 玩家实体、层 3 = 敌人实体、层 4 = 地面掉落物（值 8）。
- 掩码规划：玩家与子弹检测掩码为 5（地形 1 + 敌人 4）；敌人位于层 3 且掩码检测玩家；地面掉落物位于层 4（值 8），掩码设为 9（地形 1 + 其他掉落物 8），与玩家及子弹自然穿透，无需额外动态开关。

### 编辑器工具
`level_editor/structure-editor.html` 为独立网页地图编辑器，支持 125×75 网格绘制、瓦片调色板与 2×2 子格形状掩码编辑，导出标准的 v3 格式 `.cyrm` 文件。测试验证通过 `node level_editor/smoke.js` 执行。

#### 网络通信与 PvP 机制 (阶段 1 + 2 + 4: 匹配进图、对局互通与回合制)

当前服务端采用**单进程、单端口架构**（2026-09-29 重构）：
- 大厅与对局在同一进程内运行，每场对局由 `server/match_session.gd`（`MatchSession`）实例化驱动并挂载为节点。客户端全程连接同一服务端，`go_match` 表示进入对局场景，`claim_role` 在既有连接上发送，无需断开转连。
- 服务端端口由客户端动态分配（`core/net/local_server.gd::launch_and_connect()`，范围 20000~59999），通过 `--port P` 传参启动 `Server.exe`；远程联机基于 EasyTier 虚拟局域网隧道（`core/net/tunnel.gd` 与 `core/config/tunnel_meta.gd`，房间码为 5 位数字）。
- 连接参数统一由 `PvpSession` 维护，来源仅包含本地自建房与隧道加入。详细网络架构与日志规范参见 `docs/netplay.md`。

**远程联机 (EasyTier 隧道) 核心约束**：
1. 依赖完整性：必须完整包含 `easytier-core.exe`、`easytier-cli.exe`、`Packet.dll` 与 `wintun.dll`（位于游戏目录下 `easytier/` 目录）。缺少依赖库会导致进程异常退出。
2. 会合节点：依赖公网中继节点建立初始会合（`TunnelMeta.RELAYS`），支持通过游戏目录下的 `easytier/relay.txt` 统一配置自定义中继。
3. 地址规范：回环地址 `127.0.0.1` 无法作为隧道对端绑定地址。
4. P2P 直连：中继节点协助完成 NAT 打洞后，数据平面优先通过 P2P（UDP）直连传输，打洞失败时由公共中继转发保底。

**服务端架构与会话隔离**：
- 服务端入口为 `server/server_main.tscn`（无头模式运行），通过 `RoomManager` 编排大厅（`LobbyRooms`）与各对局（`MatchSession`）。
- 单端口会话隔离：为防止同端口下不同房间请求冲突，`MatchSession` 在开局时冻结玩家名册（`roster`），在 `_on_role_claimed` 中校验身份，非名册调用者直接拒绝连接并断开该非法 peer，保障会话隔离安全。

**权威对局仲裁 (`MatchHost`)**：
- 负责世界碰撞构建与各角色权威物理模拟，每物理帧严格按 FIFO 顺序消费 1 个输入包并回传确认序号（`ack_seq`），以 60Hz 频率广播状态快照。
- 爆炸弹丸（如榴弹）命中玩家时不执行接触判定销毁，确保延时引信与范围爆炸正常触发；即时光束武器权威开火结果经 `beam_fired` 广播至非射手端。
- 回合制状态机（COUNTDOWN → PLAYING → ROUND_OVER → MATCH_OVER）管理比分与胜负。换局时通过 `_reset_world_and_clear_dynamics` 重置可破坏瓦片与碰撞体，清理遗留弹丸，双端同步回到初始基线。
- 倒计时阶段（COUNTDOWN 3秒）双端冻结输入与开火，避免状态漂移。

**客户端预测 (C2 Rollback) 与视觉表现**：
- 本地玩家基于 `PredictionRollback` 进行输入预测与权威快照回滚校正。
- 远端对手通过 `PlayerReplica` 渲染视觉表现，挂载幽灵碰撞体（层 2）参与本地滑动碰撞，消除贴身时的预测分歧振荡。
- 对手预瞄线仅使用者本人可见。远端副本渲染位置基于差分指数追赶进行平滑表现插值，而幽灵碰撞体始终追踪未平滑的原始权威位置，保证物理判定精确。
- **接触期自适应容差**：`Player.touching_player()` 检测当前物理帧是否与远端实体接触；接触期位置容差放宽至 8.0px（非接触期为 2.0px），有效抑制贴身缠斗时的高频预测回滚。
- 场景退出保护：所有离开对局世界的路径统一通过 `Level0.safe_change_scene` 执行分帧节点拆除，防止批量析构引起底层异常。

#### 断线重连机制（阶段 1：局内快速重连）

- **网络闪断恢复**：客户端检测到底层连接中断后，自动尝试在原端口重新建立连接并认领角色席位，无需重新加载场景或重建世界实体。
- **内存状态保留**：断线期间服务端保留玩家实体对象与内存状态，仅将输入源重置并清空待处理队列，玩家在场上处于宽限冻结状态。
- **宽限期管理**：默认宽限期为 60 秒（`GraceWindow.DEFAULT_SECONDS`）。超时未恢复则判定离场。
- **状态重新咬合**：重连成功后，客户端重置预测序列号与回滚控制器，丢弃跨越断线周期的陈旧 ack，并通过 `match_sync` 全量补发掉线期间被破坏的瓦片（`destroyed`）与地面武器列表（`ground_weapons`）。
- **地面武器与瓦片同步**：客户端收到 `match_sync` 补态数据后，先重置基线再应用破坏瓦片，地面武器先清空本地表再重新实例化，确保本地与服务端世界完全对齐。配套测试包括真链路验证 `tests/reconnect_probe.tscn`。

#### 对局房间的生命周期、资源回收与准入控制

- **对局中房间的生命周期管理**：处于进行中状态（`started` / `in_match`）的房间不再在客户端转连 Worker 进程时被销毁，其生命周期与 Worker 进程的实际存活性严格绑定。
- **双重回收机制**：
  - **主动进程轮询回收**：`RoomManager._reclaim_finished_matches()` 每 30 秒执行一次周期性扫描（`MATCH_SWEEP_INTERVAL`），通过 `WorkerLauncher.pid_alive(pid)` 检查 Worker 进程的存活状态。当 Worker 进程由于对局正常结算、断线宽限期超时或全员离线等原因自主退出时，大厅层即可通过 `RoomManager._match_over(port, pid)` 精确判定对局结束并回收房间资源。
  - **超龄超时安全兜底**：系统保留原有的 2 小时超龄清扫机制（`_sweep_stale_rooms`），以强行终止僵尸 Worker 进程并回收端口，形成双重防泄漏屏障。
  - **解耦断线宽限期**：断线宽限期属于 Worker 进程内部会话状态，大厅服务不直接感知。大厅层不依据固定宽限时间注销房间，确保中途断线的玩家能够持续基于原有房间信息完成重连。
- **已知边界与系统代价**：
  - 若对局双方在接收 `go_match` 指令后立即全部断开连接，Worker 进程及分配端口将被保留直至 2 小时超时兜底（客户端具有 12 秒连接超时及 25 秒席位认领超时，不会发生永久阻塞）。
  - PID 复用边界：`WorkerLauncher.pid_alive` 依赖 `OS.is_process_running(pid)`。在操作系统较短时间内发生 PID 复用的情况下，判定逻辑会误认为 Worker 依然存活，从而延迟至 2 小时兜底回收。该异常仅导致资源回收滞后，不会误销毁正在进行的对局。
- **列表可见性与准入控制**：
  - 房间列表载荷统一扩展 `in_match` 字段，通过 `LobbyRooms.room_list_payload()` / `royale_list_payload()` / `team_list_payload()` 纯函数集中构造。
  - 对于已开局的房间，未持有该局凭证的玩家尝试加入时将被统一拒绝，反馈标准化提示文案：“该房间的对局已进行中,无法加入”。
  - 客户端界面响应：`matchmaking._on_server_message` 仅将特定旧文案（如“房间已满”、“房间不存在”）映射为自动刷新列表行为，新文案落入常规提示分支，避免产生异常刷新抖动。
- **房间元数据扩展**：
  - `worker_pid`：Worker 进程成功拉起后由 `RoomManager` 注册（覆盖 `_start_match`、`royale_start`、`royale_start_ai`、`team_start`），初始为 `0`（表示正在拉起）。
  - `roster`：开局时刻由 `LobbyRooms.freeze_roster(room)` 冻结的成员快照 `[{role, name}]`。由于成员转连后大厅连接断开，列表展示的人数与玩家名称一律取自冻结的 `roster`，确保信息展示稳定。
- **Worker 端口与进程映射表**：`WorkerLauncher` 维护端口与 PID 映射关系，提供 `pid_of(port)` 与 `static pid_alive(pid)`。在 `release_now` 释放端口时同步清理 PID 记录，防止端口复用后产生状态脏读。
- **模式隔离与多表维护**：1v1、大乱斗与 3v3 各自维护独立的房间注册表。由于不同模式的 4 位房间号可能碰撞，房间销毁判定严格依赖类型断言（`room is RoyaleRoom` / `room is TeamRoom`），严禁跨表按 code 检索销毁。
- **测试断言与假阳性防护**：
  - 脚本执行异常导致的假阳性防范：GDScript 运行时异常不会赋予失败标记，可能导致断言被跳过仍输出通过。在 `tests/room_sweep_smoke` 中，各检查函数通过注册执行状态 `_done`，由 `_finish()` 与 `CHECK_NAMES` 严格核对，避免检查函数中途跳出造成漏检。
  - 源码级接线断言：在 `tests/room_sweep_smoke._check_reclaim_ladder` 中通过源码解析，强制校验 `_process` 必须调用 `_reclaim_finished_matches()`，且统一通过 `teardown_room` 遍历三张注册表执行回收。

#### 断线重连机制（阶段 2-B：退回大厅后的房间断线重连）

- **机制与恢复路径**：
  - **路径对比**：阶段 1（局内快速恢复）适用于底层网络短时闪断，客户端直接在原端口重新握手，不切换客户端场景；阶段 2-B（跨场景会话恢复）适用于玩家在局内按 ESC 返回主菜单后，凭借客户端保留的会话凭据（Token）重新进入原对局房间。
  - **流程重建**：跨场景恢复会重新经历完整的场景加载与初始化生命周期（`go_match` → `match_start` → 加载对局场景）。其前提是服务端保留的玩家实体与内存会话未被销毁。
  - **协议复用**：该恢复路径完全复用既有的 RPC 管道（`go_match`、`claim_role`/`reclaim_role`），无需新增专门的方法定义。
- **交互入口与准入逻辑**：
  - 入口复用房间列表中的所属房间行。
  - 列表行渲染（`_on_room_list`、`_on_royale_rooms`、`_on_team_rooms`）与行点击处理共享统一判定：`PvpSession.can_rejoin_to(code)`（校验是否为所属房间且凭证有效）。对于正在对局中的房间，持有效凭据的本人允许交互并触发重连，其他玩家保持禁用状态（`disabled`）。
  - **判定顺序约束**：必须先判定“是否为本人所属房间且凭据有效”，再判定“是否处于对局中禁用”。若逻辑顺序颠倒，会导致合法重连入口被对局状态直接禁用。
- **会话凭据生命周期**：
  - `PvpSession` 维护 `room_code` 与 `rejoin` 凭证字段，提供 `can_rejoin()`、`can_rejoin_to()` 与 `clear_rejoin()`。凭据清理与常规连接重置 `reset()` 解耦，防止玩家从对局返回主菜单并重新进入大厅页面时凭据被意外抹除。
  - 凭据作废触发时机严格收敛于 `clear_rejoin()` 的四个显式调用点：
    1. 切换对局模式（`enter_mode`）；
    2. 大厅明确拒绝重连请求（`_on_rejoin_denied`）；
    3. 重连请求响应超时（15 秒未响应，`_tick_rejoin_timeout`）；
    4. 玩家主动创建或加入其他房间（`note_room`）。
  - `PvpSession.mode` 记录当前模式常量（`MODE_PVP`、`MODE_ROYALE`、`MODE_TEAM`）。由于不同模式的房间号空间独立且可能重叠，模式变更时必须作废凭据，同模式重进则予以保留。
- **重连协议流转与认领机制**：
  - 点击房间行触发 `LobbyPage.try_rejoin_row(code, in_match)`。仅当“所属房间且处于对局中”时执行重连流程（返回 `true`，拦截常规加入）。
  - 客户端向大厅发送 `rejoin_request(room_code, token)`，大厅通过 `LobbyRooms.on_rejoin_request` 查询凭据注册表，校验通过后回复 `go_match(role, port)`。
  - 客户端连接 Worker 进程后，依据 `PvpSession.rejoin` 发送 `reclaim_role`（而非初始加入的 `claim_role`）。开局后服务端已断开常规认领监听，迟到的 `claim_role` 不会被响应。
  - 客户端在重连的 `_do_go_match` 处理中，仅在接收到非空新 Token 时才更新，防止大厅未下发新 Token 时覆写原有凭证，导致 Worker 校验失败。
- **凭据注册表 `server/rejoin_registry.gd` (`RejoinRegistry`)**：
  - 映射结构：Token 映射至 `(code, role, worker_port, worker_pid, expires_at)`。注册表脱离房间对象独立存活，确保房间在大厅注销后凭据查询依然可完成。
  - 纯函数判定 `RejoinRegistry.decision(entry, code, worker_alive)`：返回空字符串表示放行，非空则为标准化拒绝原因。
  - 凭据过期与垃圾回收：默认过期上限为 1 小时（`TOKEN_TTL_SECONDS`），对局存续以 Worker 进程活跃度（`WorkerLauncher.pid_alive`）为准。垃圾回收复用 `RoomManager._reclaim_finished_matches` 的 30 秒轮询梯次，无额外定时器开销。
  - 凭据作废键：作废特定房间凭据通过 `rejoin.drop_port(worker_port)` 按 Worker 端口执行清理。严禁按房间号反查作废，避免多模式 4 位房间号碰撞导致误伤其他模式的同号房间。
- **已知边界与系统约束**：
  - 重连仅在 Worker 的断线宽限期（默认 60 秒）内有效。若宽限期超时导致席位标记离线，即使凭据尚在大厅 TTL 内，Worker 仍会拒绝席位认领。
  - 私密房间不进入大厅公开列表，因此当前阶段私密房间玩家退出至主菜单后无法通过列表卡片重连。
  - AI 对战（`ai_duel`）拉起 Worker 时不登记凭据，开局后房间即注销，不开放重连机制。
- **测试与验证套件**：
  - `tests/rejoin_registry_smoke.gd`：验证凭据注册、校验与超时垃圾回收逻辑。
  - `tests/rejoin_keying_probe.tscn`：验证以端口为键清理凭据的精确性，防止多模式同号房间凭据被误伤。
  - `tests/rejoin_probe.tscn`：全链路跨端验证（包含客户端离场重连、对局见证端与外部观察端）。
  - 执行规范：Agent 可执行 `-s` 纯逻辑冒烟及静态扫描；涉及全链路拉起子进程及独占端口的测试由开发者本地运行。

#### 3v3 团队对抗模式架构与规则规范

- **服务端与规则层（A 册）**：
  - **启动契约**：`server_main.gd` 接收启动参数 `--headless ... -- --worker --team --port P --roles r,... --teams t,...`。`roles` 与 `teams` 同序等长，满员方可启动，不支持降级开局；同时传入 `--royale` 与 `--team` 时直接拒绝启动。队伍表经 `match_sync` 的 `teams` 字段（`TeamHost.team_map()` 只读副本）下发，仅在非空时携带，不重复混入高频的 `round_state`。
  - **队伍映射单一数据源**：队伍归属严格来自 `--teams` 参数映射，严禁从角色 ID 推导。满员判定基准为去重后的队伍表大小 `_team_of_role.size()`，而非可能存在重复项的参数列表长度。
  - **队伍判定边界**：`same_team(a, b)` 遵循严格防御逻辑，当任一方为 `0` 时均返回 `false`（`0` 表示非团队模式或未分配队伍），防止 1v1 或无队伍实体互判为友方导致攻击穿透。
  - **友军伤害与直击判定**：子弹物理穿透队友，爆炸范围伤害（AOE）对全员（包含队友）满效生效。子弹与直击伤害的友方校验集中在 `server/match_combat.gd` 的 `_adjudicate_bullets` 与 `_adjudicate_grenade`。
  - **击杀后位置保持**：废除击杀者强制回传己方出生点的旧规则，击杀后全员保持当前站位与战斗状态。为防止出生点压制，复活选点机制 `TeamHost._respawn_cell_for` 严格校验开阔连通区与敌方避让半径（`RESPAWN_CLEARANCE = 8` 格）。
  - **终局判定与断线管理**：整队全员离线方判定终局。单人断线进入会话宽限期，若整队离线则判定对方获胜；若双队均全员离线则判定为平局（胜者为 0）。宽限到期处理由 `GraceWindow.expire_action` 统一路由。
  - **友军物理穿透（分队碰撞层）**：
    - 1 队：`layer = 2`, `mask = 1 | 4 | 16`（地形 1、环境敌方 4、2 队 16）。
    - 2 队：`layer = 16`, `mask = 1 | 2 | 4`（地形 1、1 队 2、环境敌方 4）。
    - 双方掩码中必须严格保留地形（1）与环境敌方（4），防止实体穿墙；远端副本幽灵碰撞体掩码置 0，层级按对应队伍设置。
  - **自毁机制（K 键）**：支持 `TeamHost.request_suicide_role`，触发后对方队伍得分 +1，击杀归因元数据清空，无击杀者复位。
- **大厅选边与客户端实现（B 册）**：
  - **多协议互斥隔离**：1v1（`rooms`）、大乱斗（`royale_rooms`）与 3v3（`team_rooms`）大厅注册表共存且双向互斥，所有创建与加入接口均相互校验，防止多重绑定与幽灵房间泄漏。
  - **房间生命周期**：进行中的 3v3 房间持续存活直至 Worker 进程退出，延迟回收时间配置为 `TEAM_PORT_REUSE_DELAY = 360s`（匹配长局时需求），房间销毁严格依据类型断言（`room is TeamRoom`），严禁跨表按房间码检索。
  - **队伍着色机制**：3v3 模式中队伍颜色覆盖个人色相。着色公式规范为 `modulate = 队色 / 本体主色`（基准颜色 `BODY_BASE_COLOR = #639BFF`），避免直接相乘导致纹理发灰暗沉；`player_p2_hue.gdshader` 仅用于个人自定义色相，不干涉队伍着色。
  - **局间换边同步**：每小局结束后两队对调出生点（`TeamHost._start_next_round`），客户端在新一轮倒计时（`COUNTDOWN`）阶段通过 `match_sync` 重新拉取对局状态，并通过 `_resync_pull_pending` 标记区分常规进场与局间换边同步，避免触发瞬移告警。
  - **赛后结算数据载荷**：服务端在 `round_state` 中附带 `stats` 与 `mvp` 数据，客户端在进入结算页时消费展示。

#### 结算页面设计与交互流程

- **交互模式**：对局结束（`MATCH_OVER`）统一呈现结算界面，由玩家主动点击“返回主菜单”或按 ESC 键退出，取消倒计时自动跳转机制。
- **解耦架构**：`ui/match_result.gd` (`class_name MatchResult`, extends `CanvasLayer`) 为模式无关的通用容器，负责视图渲染与输入处理；数据转换由 `ui/match_result_payload.gd` 的适配器函数（`for_duel` / `for_royale` / `for_team`）将各模式状态统一转换为结算载荷字典。
- **视图层级**：UI 场景层级设定为 150，高于常规 HUD（130）与暂停菜单（145）。必须通过场景实例化（`load(...).instantiate()`）挂载，禁止直接 `MatchResult.new()` 以免丢失层级配置。
- **退出与场景安全**：退出请求通过 `Level0.safe_change_scene` 异步分帧销毁物理与渲染实体，防止场景硬切引发底层异常。
- **客户端基类封装**：结算页挂载与退出流程收敛于基类 `PvpMatchClient`（`_show_result` / `_leave_to_main_menu`），子类仅覆写 `_build_result_payload()`。

### 大乱斗模式架构与规则规范 (Royale)

- **场景与导航流**：
  - 入口：主菜单“大乱斗”按钮（`main_menu.gd`）导航至 `scenes/royale_lobby.tscn`（`royale_lobby.gd`：支持公开/私密房间、邀请码复制、人数与时限配置、禁用武器、角色颜色自选、房间列表自动拉取与一键启动本地服）。
  - 路由判定由场景加载上下文决定（`royale_lobby` → `royale_game`），无需静态全局标记。UI 排版遵循 `UiFactory` 规范（字号严格为 16 的倍数）。
- **对局启动与生命周期流程**：
  1. 大厅注册表管理：大厅服务（`server/server_main.tscn` 默认端口 7777）中的 `LobbyRooms` 维护独立的 `RoyaleRoom` 注册表，与 1v1 的 `rooms` 及 3v3 的 `team_rooms` 保持互斥。房间生命周期 RPC 统一经由 `NetBusExt` 的 `royale_*` 接口派发。
  2. 独立 Worker 进程拉起：房主触发开局后，大厅通过 `_spawn_royale_worker(port, roles, ai_roles)` 使用 `OS.create_process` 拉起独立的无头 Worker 进程：
     - 命令行格式：`--headless [--path . res://server/server_main.tscn] -- --worker --royale --port P --roles 1,3 [--ai-roles r,r]`。
     - 进程隔离保证各对局内存完全独立，跨房间共享的静态网格与瓦片定义互不干扰。
     - 角色白名单集合传递：大厅显式传入角色 ID 集合（如 `--roles 1,3`），彻底避免基于总人数推导在出现空洞时（中途退房）导致高位角色被误判定为非法会话。AI 补位角色通过 `_royale_free_roles` 获取未被人类占用的空闲 ID 并统一下发。
  3. Worker 席位认领与降级启动：
     - 开局门禁：`_on_role_claimed` 收齐预期人类席位（`_human_role_count()`）后开局，其余席位由 AI 补位。
     - 超时降级策略：实到人数 ≥ 2 且等待超时 20 秒时，按实到人数降级开局（缺席角色不进入对局，出生点生成器按实到键值分布）；开局前可用玩家 < 2 人时，宽限 10 秒后退出并释放端口。
     - 会话隔离保护：对局已开始、角色不在白名单或角色已被占用时，直接执行 `disconnect_peer`，避免端口复用竞态引起的脏连接。
     - 帧末延迟启动：开局逻辑通过 `_defer_begin_match()` 延迟至物理帧末尾执行，确保首轮网络轮询中包含的角色选项（`player_options`，如颜色配置、禁用武器等）全部归档后再启动对局。
  4. 端口复用延迟与超时回收：
     - 端口复用安全间隔设定为 `ROYALE_PORT_REUSE_DELAY = 360s`（与断线宽限期错开，防止旧端口重连冲突）。
     - 超龄回收机制：`_sweep_stale_rooms` 覆盖大乱斗房间，在局房间配置 `SWEEP_INTERVAL + RoyaleHost.MATCH_TIME` 宽限时间，空房间未开局按 `MAX_ROOM_AGE` 清理。
- **服务端权威规则 (`server/royale_host.gd`: `RoyaleHost extends MatchHost`)**：
  - 构造时序规范：必须先执行 `plan_spawns` 完成出生点预计算，再调用 `super._init`。父类在 `_init` 中会调用 `_spawn_cell(role)`，若时序颠倒将导致坐标初始化异常。
  - 死斗规则体系：限时 300 秒（`MATCH_TIME`），击杀数最高者胜（并列第 1 时为平局，胜者返回 0）；死亡后 2 秒动态复活。
  - 出生点与复活点选点算法：
    - 开局出生点：两两环面距离保持 ≥ `SPAWN_CLEARANCE = 15` 格。
    - 动态复活点：基于 `SpawnPicker.respawn_pools()` 三级动态候选池（开阔候选池、降级备用池、极限连通池），要求连通区域大于自适应门槛 `SpawnPicker.area_threshold()`（根据地图最大连通块动态缩放，防止出生在封闭空间），且与所有存活对手保持避让半径（`RESPAWN_CLEARANCE = 8` 格）。
  - 击杀归因机制：子弹命中记录 `last_damager` 与时间戳（有效窗口 3 秒，`ATTRIB_WINDOW_MS`）。玩家倒地瞬间触发 `_attributed_killer` 计分，环境死亡（坠落、溺水）不计分，K 键自毁清空归因且无人得分。
  - 会话同步：`round_state` 全局广播包含积分榜、死亡数、玩家名称、存活状态与比赛倒计时。
- **客户端架构 (`scenes/royale_game.gd`)**：
  - 场景构成：包含基础对局环境（`pvp_mode`）、后处理效果、动态实例化的远端玩家副本（`PlayerReplica`）、大乱斗专用 HUD（`RoyaleHud`）与小地图。
  - 客户端预测：本地玩家完全接入 C2 权威预测与 `PredictionRollback` 回滚系统，与 1v1 预测模型保持一致。
  - 主动拉取同步（Pull 模式）：客户端场景加载就绪（`_ready`）末尾主动发起 `NetBus.rpc_id(1, "match_sync")` 拉取对局配置，服务端统一回复 `match_sync_data`（包含玩家名册、色相表、选项与出生点），消除切场景阶段推式同步产生的异步竞态丢失。

#### 已知边界与架构风险

1. **快照广播体积随人数线性增长**：大乱斗快照每物理帧包含全员的权威整态数据（`capture_state()`），在高人数（如 8 人）与 60Hz 不可靠广播下对上行带宽要求较高，需在局域网或低延迟高带宽网络下运行。
2. **输入队列积压与消费时序**：每个物理帧按单包速率消费输入队列。若网络抖动导致接收速率短时激增，`_pending_input` 队列可能产生暂态积压，表现为输入延迟上升。

### 测试体系与测试套件规范

- **测试脚手架与共享工具 (`tests/lib/`)**：
  - `scan_util.gd` (`class_name ScanUtil`)：纯静态语法解析与代码审查工具，提供文件遍历、注释剥离、AST 结构提取与函数体截取功能，无 Node 运行时依赖。
  - `probe_base.gd` (`class_name ProbeBase extends Node`)：测试基类，统一封装断言账本（`_failures`）、自动化检查点上报（`_check`）、执行汇总（`_summary`）与标准化退出裁决（`_finish`，格式为 `KH <id> PROBE: ALL-OK`）。
  - 约束规范：新增源码级探针统一继承 `ProbeBase`，禁止重复手写扫描与断言逻辑；测试库代码严禁包含非 16 倍数的 UI 字号常量。
- **测试运行模式分类**：
  - **纯逻辑无头冒烟测试 (`extends SceneTree`)**：
    - 运行指令：`godot -s res://tests/<name>.gd`。
    - 运行特征：Autoload 单例未加载。禁止在顶层变量静态预加载依赖 Autoload 的脚本，必须在 `_initialize()` 内部动态 `load()`。
    - 安全防御：脚本必须包含加载空值校验与异常退出守卫，避免初始化崩溃导致进程永久挂起。
  - **场景级端到端探针 (`extends Node`)**：
    - 运行指令：`godot --headless --quit-after <帧数> res://tests/<name>.tscn`。
    - 帧数安全网：场景探针必须配置充足的最大运行帧数安全网（统一建议 `--quit-after 3600` 帧）。探针正常运行完成后主动调用 `quit()`，安全网仅用于防止测试挂起，避免因机器负载波动导致提前截断。
- **断言完整性与假阳性防护**：
  - **断言覆盖率约束**：`ALL-OK` 仅证明“未记录到失败断言”，不能证明“预期断言已全部执行”。为防止 GDScript 运行时错误导致函数提前跳出并产生假阳性，所有探针必须引入计数核对机制（如 `_checks >= EXPECTED_CHECKS` 或 `_done` 函数名对账），未达标一律判定失败。
  - **测试结果判定**：自动化脚本统一基于控制台输出文本进行模式匹配，严禁单独依赖进程退出码作为判据。
- **网络测试运行环境卫生纪律**：
  - **残留子进程清理**：多实例真链路测试启动前与结束时，必须确保环境清理干净（通过 `kill_port_range` 按 UDP 端口检索并终止残留的孤儿 Godot 进程），防止端口被旧进程持续占用导致新 Worker 绑定失败并引发客户端超时。
  - **UDP 端口监听检测**：ENet 运行在 UDP 协议栈，系统网络工具（如 netstat）中不呈现 TCP 的 `LISTENING` 状态。端口检测统一基于无状态筛选与 PID 精确匹配（参考 `tests/env.sh` 的 `lobby_alive()`）。
  - **已知待修复测试边界记录**：
    - `tests/team_match_probe.sh`：3v3 六人真链路测试中，偶发存在客户端握手瞬断导致房间状态未被探针捕获的问题，归档待进一步跟进。
    - `tests/ground_net_probe.tscn`：寻路机器人在特定随机地图连通区上存在偶发走位超时抖动。
