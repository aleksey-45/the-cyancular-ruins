# 项目架构总览（新手向）

> 本文面向**第一次接手本仓库的人**：讲清"这个项目长什么样、每个文件干什么、改动该去哪找"。
>
> 与 `AGENTS.md` 的分工：`AGENTS.md` 是给 AI 编码代理的**纪律与约定**（必须遵守的约束）；
> 本文是**地图**（结构是什么）。两者有冲突时**以代码为准**，并请顺手订正文档。
>
> 最后校准：2026-09-11，分支 `KH_v1_1_3_PubServer`。

---

## 0. 五分钟速览

**The Cyancular Ruins** 是一个 Godot 4.7（标准版，非 mono）做的 2D 横版平台跳跃射击 demo。

三个必须知道的特点：

1. **环面世界**——地图左右、上下无缝回绕。走到最右边会从最左边出来。所有"距离/方向"计算都必须用环面数学，不能用坐标直接相减。
2. **三种玩法**——单机、1v1 联机、大乱斗（2~8 人限时死斗）。三条路径是**独立代码线**，不是一套代码三个配置。
3. **联机是服务器权威**——联机时你的电脑只是"显示终端"，真正算伤害的是那台没画面的服务器。

| 规模 | 数量 |
|---|---|
| GDScript 脚本 | 113 个 |
| 场景文件 `.tscn` | 36 个 |
| 视口 / 帧率 | 1920×1440，60 FPS，`rendering/mobile` |

### 四层结构

| 层 | 目录 | 通俗解释 |
|---|---|---|
| 公共零件库 | `Globals/` | 地图数学、碰撞、参数、网络——所有系统共用的地基 |
| 游戏本体 | `Scenes/` | 菜单、关卡、玩家、敌人、武器、特效 |
| 服务器 | `server/` | 联机时的"后厨"，裁决谁打中了谁 |
| 施工工具箱 | `Tests/` `tools/` `editor/` `DevTools/` | 测试、打包、地图编辑器、AI 施工工具（玩家看不到） |

---

## 1. 启动链路

### 1.1 四个 autoload（永不销毁的全局对象）

启动时 Godot 先创建这四个对象，之后任何场景都能直接按名字访问。定义在
[project.godot](../project.godot) 的 `[autoload]` 段：

| 名字 | 文件 | 作用 |
|---|---|---|
| `GameParameters` | `Globals/gameParameters.gd` | 共享物理/网格参数：重力、`TILE_SIZE=64`、地图像素尺寸 |
| `NetBus` | `Globals/net_bus.gd` | 联机通信总机。**⚠️ 必须与原作者的版本逐字节一致**，改它的 RPC 方法表会导致新旧版本之间所有通信静默失联 |
| `NetBusExt` | `Globals/net_bus_ext.gd` | 我们新增的联机功能全在这里（大乱斗、能力协商）。只暴露两个 RPC，靠 `kind` 分派 |
| `Settings` | `Globals/settings.gd` | 玩家偏好持久化（音量/键位/各种开关），存 `user://settings.cfg` |

> **只有这四个是 autoload。** 其他"全局"都是静态类（见 §4.5），不要往 autoload 里加东西。

### 1.2 场景流程

主场景是 `run/main_scene = res://Scenes/main_menu.tscn`。服务器构建的主场景是
`run/main_scene.dedicated_server = res://server/server_main.tscn`。

```
                        ┌─ 单机 ────────→ Scenes/Level0.tscn        (Scenes/level_0.gd)
main_menu.tscn ─────────┼─ 1v1 联机 ────→ Scenes/matchmaking.tscn → Scenes/pvp_game.tscn   (Scenes/pvp_client.gd)
  (Scenes/main_menu.gd) └─ 大乱斗 ──────→ Scenes/royale_lobby.tscn → Scenes/royale_game.tscn (Scenes/royale_game.gd)
                                              │                              │
                                              └────── 都连到 ────→ server/server_main.tscn (server/server_main.gd)
```

纯 UI 场景之间用 `change_scene_to_file` 切换（无风险）；**进出带大量碰撞体的游戏世界**
必须走 `Level0.safe_change_scene()`——原因见 `AGENTS.md` 的「场景切换纪律」节
（反复同步释放带数万静态碰撞体的物理世界会偶发原生段错误）。

---

## 2. 三条游玩路径

| | 单机 | 1v1 联机 | 大乱斗 |
|---|---|---|---|
| 入口界面 | `main_menu.tscn` | `matchmaking.tscn` | `royale_lobby.tscn` |
| 对局场景 | `Level0.tscn` | `pvp_game.tscn` | `royale_game.tscn` |
| 对局脚本 | `level_0.gd` | `pvp_client.gd` | `royale_game.gd` |
| 服务器裁决者 | 无（本地算） | `server/match_host.gd` | `server/royale_host.gd`（继承 `MatchHost`） |
| 谁说了算 | 你的电脑 | 服务器 | 服务器 |
| 人数 | 1 | 2 | 2~8 |

**关键点：三条路径共享"世界搭建"和"玩家场景"，但对局逻辑各自独立。**
所以改 `level_0.gd` 不会影响联机，改 `pvp_client.gd` 也不会影响大乱斗。

### 联机时的"实体 vs 替身"

联机时，你屏幕上看到的对手和敌人**只是纯视觉替身**（`player_replica.gd` /
`enemy_replica.gd`）：没有 AI、没有物理，位置由服务器快照插值出来。真正的它们活在那台
没画面的服务器上（由 `MatchHost` / `RoyaleHost` 用 `Player.tscn` + 网络输入源权威模拟）。

### 服务器双模式

`server/server_main.gd` 按命令行参数分两种身份：

| 启动方式 | 身份 | 作用 |
|---|---|---|
| 无参数（默认） | **大厅** | 端口 7777。只做建房/配对（`room_manager.gd`），不跑对局 |
| `--worker --port P` | **对局 worker** | 独占一个 UDP 端口，跑一场具体的对局（`match_host.gd`） |
| `--worker --royale --port P --players N` | **大乱斗 worker** | 同上，但用 `royale_host.gd` |
| `--ai-roles 2,3` | AI 补位 | 让服务器用 `ai_player.gd` 顶替指定角色 |

**一服多局**：大厅给每场对局拉起一个**独立子进程**（worker），所以各局内存隔离，
拆墙/回合状态不会互相污染。端口从 7800 起递增分配。

---

## 3. 目录与文件地图

### 3.1 `Globals/` —— 全局零件库

#### 地图与环面世界（最核心）

| 文件 | 作用 |
|---|---|
| `maze_generator.gd` | **全项目最核心的地图大脑**。读 `.cyrm` 地图文件、格值编解码、环面数学（`toroidal_dist` / `toroidal_delta_px` / `anchor_to_nearest` / `wrap_to_range`）、BFS/A* 寻路、视线判定。`current_grid` 静态变量是全局当前地图 |
| `world_builder.gd` | 从地图搭出可玩世界：永久墙碰撞 + 可破坏分块 + 攀爬基座。单机与联机客户端/服务器共用 |
| `collision_builder.gd` | 把砖形掩码展开成 32px 子格、贪心合并矩形、按 9 份环面副本实例化。负责"性能"和"可破坏砖只重建所在分块" |
| `water.gd` | 水判定：`is_in_water` / `surface_y_at` / `submerged` / `water_mult`（爆炸衰减）/ `bullet_drag_factor` |

#### 参数（分层见 §5）

| 文件 | 作用 |
|---|---|
| `gameParameters.gd` | 共享参数（autoload）：重力、瓦片尺寸、地图像素尺寸、水面起伏 |
| `playerParams.gd` | 玩家手感数值（移动/跳跃/冲刺/镜头/战斗）。`RefCounted` + `const`，静态访问 |
| `enemyParams.gd` | 敌人数值，每种敌人一个嵌套类（如 `EnemyParams.FlyBird.wake_radius`） |
| `tile_defs.gd` + `tile_defs.json` | 砖块属性表（墙/通道/液体/气体；血/衰减/可破坏/弹性/摩擦）。**json 是单一数据源** |
| `run_options.gd` | 单机开局选项（难度、禁用武器）。静态会话，菜单→关卡传递 |
| `pvp_session.gd` | 联机会话配置（地图路径、出生点、房间信息）。静态会话 |
| `settings.gd` | 玩家偏好持久化（autoload） |

#### 战斗

| 文件 | 作用 |
|---|---|
| `explosion.gd` | 爆炸 AoE 结算：内圈满伤 + 二次方衰减、LOS 墙后减伤、友伤、独立击退向量、水中衰减 |
| `beam_trace.gd` | 激光几何追踪（纯静态）。沿方向逐 32px 子格走，遇墙镜面反射，最多 `max_bounces` 次，返回折线点集 |
| `laser_visual.gd` | 把算好的光束折线画成视觉节点（本地开火与 PvP 远端副本共用同一套） |

#### 网络与输入

| 文件 | 作用 |
|---|---|
| `net_bus.gd` | 原版通信总机（autoload）⚠️ 勿动 |
| `net_bus_ext.gd` | 扩展通信（autoload）。信封化设计：加功能不改 RPC 方法表，旧服务器最多"不认识某个 kind"，不会整体失联 |
| `input_source.gd` | 抽象"手柄"基类。本地玩家委托真实键盘鼠标 |
| `network_input_source.gd` | "网络手柄"：服务器用收到的输入包驱动远端玩家 |
| `ai_input_source.gd` | "AI 手柄"：让电脑玩家冒充真人，走与真人完全相同的一条输入消费路径 |
| `local_server.gd` | 局域网模式下"启动/重启本机服务器"按钮的实现（Windows：taskkill + netstat） |
| `prediction_rollback.gd` | 客户端预测回滚控制器。**已开启**（仅 1v1），见 `pvp_client.gd` 顶部 `LOCAL_PREDICTION_ENABLED`；改回 false 即退回纯服务器渲染 |

#### 其他

| 文件 | 作用 |
|---|---|
| `sfx.gd` | 程序合成的 8-bit 音效（方波/噪声/滑音），零素材 |

### 3.2 `Scenes/` 根目录 —— 界面与关卡

| 文件 | 作用 |
|---|---|
| `level_0.gd` / `Level0.tscn` | **单机关卡本体**。搭世界、放玩家敌人、铺瓦片/水、渲染管线（世界画进 SubViewport 再后处理）、`safe_change_scene` 静态工具 |
| `main_menu.gd` / `main_menu.tscn` | 主菜单，三玩法入口；背景是真实玩家在地图里跑的宣传片 |
| `menu_demo_ai.gd` | 上面那个背景演示的 AI：驱动一个真 Player 追打鸟，死光自动补 |
| `matchmaking.gd` / `matchmaking.tscn` | 1v1 的建房 / 输房间号 / 加入界面 |
| `pvp_client.gd` / `pvp_game.tscn` | **1v1 对局场景**。上报输入、消费快照、渲染对手副本、小地图/血条/ID |
| `pvp_hud.gd` | 1v1 HUD：双方击杀 / 局胜 / 局号 / 中央倒计时 |
| `royale_lobby.gd` / `royale_lobby.tscn` | 大乱斗大厅：房间列表（2.5s 静默自刷）、创建（公开/私密+邀请码）、等待室 |
| `royale_game.gd` / `royale_game.tscn` | **大乱斗对局场景**：N 个对手副本、头顶 ID/血条、小地图多目标 |
| `royale_hud.gd` | 大乱斗 HUD：左上排行榜 + 中央倒计时/胜负 |
| `settings_menu.gd` / `settings_menu.tscn` | 设置页：键鼠重映射、音量、滚轮切枪、各种实验性开关 |
| `pause_menu.gd` | Esc 暂停菜单（回主菜单走 `safe_change_scene`） |
| `hud.gd` | 单机 HUD：血量、武器剪影、残弹、换弹进度 |
| `post_process.gd` | 后处理：像素缩放裁切、倒地暗角、受击红闪 |

### 3.3 `Scenes/Player/` —— 玩家

玩家被拆成"根 + 三个零件"，分工明确：

| 文件 | 作用 |
|---|---|
| `player.gd` / `Player.tscn` | **玩家根节点**。只留移动/姿态/物理帧编排，按顺序显式调用各组件 |
| `climb_component.gd` | 攀爬：梯子/锁链的挂附、上爬、下降、到顶跳离 |
| `combat_component.gd` | 战斗：生命、无敌帧、击退、倒地、复活 |
| `weapon_component.gd` | 武器：注册表（槽位 1~6）、换枪、禁用槽位闸门、武器剪影生成 |
| `swim_component.gd` | 游泳：水中跳过攀爬/重力/跳跃，上浮下潜 |
| `camera_2d.gd` | 镜头跟随，带前瞻与死区 |
| `player_replica.gd` / `player_replica.tscn` | **对手替身**：纯视觉，双快照 tick 域 alpha 插值 + 环面锚定 |
| `enemy_hp_bar.gd` | 对手头顶血条（可选视觉） |
| `world_label.gd` | 头顶 ID 文字（世界空间，每帧贴到头顶） |
| `player_p2_hue.gdshader` | 2P 色相区分 |

### 3.4 `Scenes/Enemies/` —— 敌人

继承链：`EnemyBase → EnemyFlyBase → EnemyFlyBird`；`EnemyJumpBird` / `EnemyBlackBird` 直接继承 `EnemyBase`。

| 文件 | 作用 |
|---|---|
| `enemy_base.gd` | **敌人基类**：血量、受击/死亡白闪、死亡物理与生前一致、落水浮力与溺水、击退衰减、环面回绕 |
| `enemy_fly_base.gd` | 飞行寻路基类：A*（按鸟自身碰撞箱判可走）、空路径直线兜底、悬挑墙死区逃逸 |
| `enemy_fly_bird.gd` | 飞鸟：平抛投弹（预测玩家速度）、残血单向切冲刺自爆、返程回家睡觉 |
| `enemy_jump_bird.gd` | 跳跳鸟：近战跳跃/后跳/扑击 |
| `enemy_black_bird.gd` | 黑鸟刺客：绕背瞬移、周期性判定落点、突袭冲锋、大后跳 |
| `enemy_bullet.gd` / `enemy_bullet.tscn` | 敌人的抛物线子弹 |
| `enemy_spawner.gd` | 按注册表随机取地板格刷怪（`editor/enemies.json` 是唯一来源） |
| `enemy_replica.gd` | 联机时的敌人视觉替身 |
| `EnemyFlyBird.tscn` / `EnemyJumpBird.tscn` / `EnemyBlackBird.tscn` | 三种敌人的场景 |
| `black_bird_silhouette.gdshader` | 黑鸟纯黑剪影效果 |

### 3.5 `Scenes/Weapons/` —— 武器

| 文件 | 作用 |
|---|---|
| `weapon_base.gd` | **武器基类**。数值全是 `@export`；开火、后坐、预瞄弧线/激光、弹道方向与走路朝向解耦 |
| `bullet_base.gd` | 玩家子弹基类：伤害、爆炸弹（引信/反弹）、水中阻力、`apply_damage=false` 的视觉副本模式 |
| `bullet.tscn` | 普通子弹 |
| `grenade_bullet.tscn` | 榴弹（反弹 + 引信爆炸） |
| `pistol_test.tscn` | 手枪（槽 1） |
| `rifle_test.tscn` | 步枪（槽 2） |
| `m82a1.tscn` | 重狙（槽 3，重型预瞄） |
| `s686.tscn` | 霰弹（槽 4，8 丸散射） |
| `grenade_launcher.tscn` | 榴弹发射器（槽 5） |
| `laser_weapon_base.gd` | **激光武器基类**：不开实体子弹，开火瞬间算一条光束并一次性结算。留了三个可覆写缝（几何/结算/视觉） |
| `laser_gun.gd` / `laser_gun.tscn` | 激光枪（**槽 6**）：沿瞄准方向反射折线（默认 2 次反射） |
| `laser_beam.gd` / `laser_beam.tscn` | 光束的视觉节点 |

> 加新武器 = 一个继承 `WeaponBase` 的 `.tscn` + `weapon_component.gd` 的 `WEAPONS` 注册表加一行。

### 3.6 `Scenes/Effects/` —— 特效

| 文件 | 作用 |
|---|---|
| `explosion.tscn` / `explosion_fx.gd` | 爆炸动画（按半径缩放，播完自毁） |
| `combat_feedback.gd` | **打击反馈**：命中打叉标记 + "击杀 XXX" 像素播报 + 击杀音效。`current` 为 null 时全部静默空转 |
| `bullet_trail.gd` | 子弹拖尾线（可选） |
| `tile_hit_fx.gd` | 可破坏砖受击碎片粒子 |
| `water_fx.gd` | 水花 / 气泡粒子 |
| `water_surface_batch.gd` | 水面起伏渲染（合批成 1 个 draw call） |
| `minimap.gd` | 小地图（可选） |

### 3.7 `server/` —— 服务器

| 文件 | 作用 |
|---|---|
| `server_main.gd` / `server_main.tscn` | **服务器入口**。解析命令行，分派为大厅 / 1v1 worker / 大乱斗 worker |
| `room_manager.gd` | **大厅逻辑**：房间注册表、建房/配对、给每局拉起 worker 子进程、端口分配与归还、僵尸房定时清扫 |
| `match_host.gd` | **1v1 权威对局**：权威模拟双方玩家、60Hz 广播快照、裁决命中、回合制（先到 5 杀、三局两胜、局间换边） |
| `royale_host.gd` | **大乱斗权威对局**（继承 `MatchHost`）：开局散点出生、无限复活、限时 5 分钟击杀最多者胜、击杀归因 |
| `ai_player.gd` | `AINavigator`：AI 玩家控制器，每物理帧写 `AIInputSource` 字段 |

### 3.8 其他目录

| 目录 | 内容 |
|---|---|
| `Shaders/` | `post_process.gdshader`（红闪 `hit_red`、像素缩放） |
| `Tests/` | 33 个冒烟/诊断脚本，多为 `extends SceneTree` 用 `-s` 跑。详见 §3.9 |
| `tools/` | `start_server.bat`（双击开服）、`build_release.py`（打包）、`docs_sync.py`、`make_server_console.py`、若干 PowerShell 排障脚本 |
| `editor/` | **独立浏览器地图编辑器**（HTML + JS，与 Godot 无关）：画 `.cyrm` 地图、砖块调色板、导入旧格式 |
| `DevTools/` | 干员卡/武器卡编辑器（填表 → 生成提示词 → 自动调 Claude Code）。玩家包通过 `exclude_filter` 排除 |
| `map/` | `demo.cyrm`（单机随机取）、`factory1v1.cyrm`（1v1 固定图）、`old_map.txt`（旧格式样例） |
| `docs/` | 本文档 + `RELEASE.md`（发布手册）+ PvP 网络架构 + 历史 plans/specs |
| `assets/` | 贴图（`structure.png` 砖块图集、角色/敌人/武器/子弹/特效）、字体 |

### 3.9 `Tests/` 脚本一览

**约定：冒烟测试由用户自己跑；代理只跑"诊断探针"**（`menu_autotest` / `lobby_*_probe` /
`royale_probe` 等）。

| 类别 | 文件 |
|---|---|
| 主冒烟（覆盖最广） | `enemy_logic_smoke.gd` |
| 契约守卫 | `player_contract_smoke.gd`（源码级，保玩家公开接口不漂） |
| 菜单/GUI 自动流转 | `menu_autotest.gd`（`-- --autotest-sp\|mp\|set\|level`）、`ui_audit.gd`、`mm_bot.gd` |
| 联机链路探针 | `lobby_ping_probe.gd`、`lobby_create_probe.gd`、`pvp_match_smoke.gd` + `.sh`、`pvp_room_smoke.sh`、`pvp_smoke_client.gd`、`royale_probe.gd`、`royale_bot.gd` |
| 客户端预测（C2） | `c2_reconcile_probe.gd`、`c2_twin_probe.gd` |
| 环面接缝诊断 | `seam_analyze.gd`、`seam_screenshot.gd`、`wrap_probe.gd` |
| 战斗/武器探针 | `aim_probe.gd`、`aim_direction_probe.gd`、`muzzle_probe.gd`、`preview_probe.gd`、`grenade_smoke.gd`、`laser_probe.gd`、`explosion_falloff_probe.gd`、`feedback_probe.gd` |
| 世界/瓦片/水 | `tile_destroy_probe.gd`、`water_probe.gd`、`climb_probe.gd`、`perf_probe.gd` |
| 其他 | `network_input_smoke.gd`、`order_probe.gd`、`restart_probe.gd`、`convert_map.gd`（地图格式转换工具） |

---

## 4. 五个最容易迷路的概念

### 4.1 实体 vs 替身（replica）

联机时屏幕上的人/鸟分两种：

- **实体**（`Player.tscn` / `Enemy*.tscn`）：有物理、有 AI。跑在**服务器**上，以及单机里。
- **替身**（`player_replica.gd` / `enemy_replica.gd`）：纯视觉，位置靠快照插值。跑在**你的客户端**上。

所以"为什么我改敌人 AI，联机里对手的鸟没反应？"——因为联机里你看到的是替身，AI 在服务器上。

### 4.2 `NetBus` 不能动，新功能加 `NetBusExt`

Godot 按**节点**做 RPC 方法表校验。改动 `net_bus.gd` 的 `@rpc` 方法列表，会让新旧构建互连时
该节点**所有** RPC 一起失效（现象：游戏一更新，旧服务端就不能用）。

因此 `NetBusExt` 设计了**信封**：只暴露 `ext_c2s(kind, payload)` / `ext_s2c(kind, payload)` 两个
RPC，功能靠 `kind` 分派。以后加功能不改方法表，旧服务器只是"不认识某个 kind"，忽略即可。

### 4.3 单机 / 1v1 / 大乱斗 是三条独立路径

共享：`Level0` 世界搭建、`Player.tscn`、武器、敌人、地图。
不共享：对局规则与流程（各自在 `level_0.gd` / `pvp_client.gd`+`match_host.gd` /
`royale_game.gd`+`royale_host.gd`）。

新增实验性开关请走 `Settings` / `RunOptions` / `PvpSession`，**不要**再加全局散变量。

### 4.4 环面纪律（最容易写出 bug 的地方）

地图是环面，所以：

- 实体间**方向/距离/插值**一律用 `MazeGenerator.toroidal_*`，**禁止裸坐标相减**。
- 跨接缝时，玩家每帧 `wrap_to_range` 回中间副本；敌人/子弹用 `anchor_to_nearest` 锚到玩家附近的副本。
- 网络协议**只传 canonical 坐标**，各端自己归到最近副本渲染。
- 击退方向也走最短向量，否则跨接缝对枪会被推向射手。

### 4.5 autoload vs 静态类 vs `preload` 静态

| 形式 | 例子 | 什么时候用 |
|---|---|---|
| autoload | `GameParameters` / `NetBus` / `NetBusExt` / `Settings` | 需要跨场景常驻 + 存可变状态。**只有这四个** |
| `class_name` + 静态 | `MazeGenerator` / `TileDefs` / `Water` / `CollisionBuilder` | 无状态工具函数。可直接 `-s` 测 |
| 无 `class_name`，`preload` 引用 | `BeamTrace` / `LaserVisual` / `TileHitFx` | 同静态工具，但避免新增类名刷新全局缓存 |

**写新测试注意**：`-s` 阶段 autoload 尚未实例化，避免静态引用会连带预加载 autoload 的脚本。

---

## 5. 参数改在哪里（分层约定）

| 想改什么 | 去哪 |
|---|---|
| 共享物理/网格（重力、瓦片尺寸） | `Globals/gameParameters.gd` |
| 玩家手感（移动/跳跃/冲刺/镜头/战斗） | `Globals/playerParams.gd` |
| 敌人数值 | `Globals/enemyParams.gd` 的嵌套类 |
| 武器数值 | 对应 `.tscn` 的 `@export`（`weapon_base.gd` 定义字段） |
| 砖块属性（血/弹性/摩擦/是否可破坏） | `Globals/tile_defs.json` |
| 玩家偏好（音量/键位/开关） | `Globals/settings.gd`（持久化到 `user://settings.cfg`） |
| 单机开局选项（难度/禁用武器） | `Globals/run_options.gd` |
| 联机会话（地图/出生点） | `Globals/pvp_session.gd` |

---

## 6. 已知文档漂移（代码为准）

以下内容历史上与文档不一致，本文档已按**当前代码**校准：

| 项 | 旧描述 | 现状 |
|---|---|---|
| 武器数量 | 5 把（1~5） | **6 把**，槽 6 = 激光枪（`laser_gun.tscn`） |
| C2 客户端预测 | "已放弃" | 代码完整（`prediction_rollback.gd`）；`pvp_client.gd` 里 `LOCAL_PREDICTION_ENABLED := true`，**1v1 已开启**（2026-09-11）。大乱斗无此链路，仍纯服务器渲染 |
| `DevTools/` | "只在 KH-char-weap 分支存在" | 当前分支也存在（卡编辑器） |
| AI 补位 | 只在分支章节提及 | `ai_input_source.gd` + `server/ai_player.gd` 完整存在 |
| 小地图 / 子弹拖尾 / 对手血条 | 一笔带过 | 均为完整实现（`Scenes/Effects/`） |
| 树叶/树干 hp | 20 / 80 | 代码为 **8 / 30**（`tile_defs.json`） |
| 黑鸟瞬移距离 | 3~8 格 | 实际 **2~6 格** |
| 加敌人注册表 | `TYPES` 加一行 | 实际在 `editor/enemies.json` |
| 防水注释 | 0.5s | 实际 `water_drain_interval = 1.0s` |

---

## 7. 下一步该看什么

1. 想改玩法数值 → §5 的表格直接定位。
2. 想理解某条链路 → 先看 §1.2 的场景流程图，再进对应 `.tscn` 看节点树。
3. 想动手前 → 读 `AGENTS.md` 的「重要决策与约定」和「场景切换纪律」，那是踩过坑总结的硬约束。
4. 发布相关 → `docs/RELEASE.md`（单 exe 靠自定义裁剪模板，改代码后必须重导出 exe 再实测）。
