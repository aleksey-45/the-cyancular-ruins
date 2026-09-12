# AGENTS.md

本文件是仓库级 AI 编码代理指导(ZCode 自动读取仓库根 `AGENTS.md`;`CLAUDE.md` 仅含一行 `@AGENTS.md` 转发,供 Claude Code 共用同一来源,内容勿双写)。

> **只想知道"项目长什么样、每个文件干什么"→ 看 `docs/ARCHITECTURE.md`**(新手向结构地图:四层架构、三条游玩路径、逐文件职责、参数改在哪)。本文件侧重**纪律与约定**(必须遵守的硬约束),两者冲突以代码为准。

## 项目概览

Godot 4.7(标准版,非 mono)做的 2D 横版(平台跳跃)射击 demo「The Cyancular Ruins」。1920×1440 视口、`rendering/mobile`。核心特色:

- **环面世界**:地图左右/上下无缝回绕,敌人/子弹/镜头跨接缝连续。
- 单关卡(Level0)从 ASCII 地图文件加载,无运行时随机生成(生成逻辑已注释)。

## 常用命令

Godot 不在 PATH,用绝对路径。**4.7.1 标准编辑器**是当前主用版本(详见 `docs/RELEASE.md`;4.4.1 mono 已弃用,仅在需要兼容旧脚本时用其 console 版)。

```bash
# 冒烟测试(唯一的"测试",SceneTree 脚本;成功打印 SMOKE OK 退出 0)
"C:/Godot/Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s res://Tests/enemy_logic_smoke.gd

# headless 启动游戏 90 帧后退出(看脚本报错)
"C:/Godot/Godot_v4.7.1-stable_win64_console.exe" --headless --path . --quit-after 90

# PvP 服务端(headless,监听 7777;保持终端开着=运行中)。更省事:双击 tools/start_server.bat。
"C:/Godot/Godot_v4.7.1-stable_win64_console.exe" --headless --path . res://server/server_main.tscn

# 导出单 exe 发布版(导出前先关掉正在运行的游戏,否则 exe 写入失败)
"C:/Godot/Godot_v4.7.1-stable_win64.exe" --headless --path . --export-release "Windows Desktop" "The Cyancular Ruins.exe"
```

约定:**冒烟测试由用户自己跑,不要代跑**(诊断探针除外,见「测试」节)。发布/裁剪模板细节见 `docs/RELEASE.md`(单 exe 靠自定义裁剪模板,勿用 UPX,保留 webp 模块)。模板重编只在**改裁剪 profile(增删类/模块)**时需要,单次≈10~15 分钟近全量(docs/RELEASE.md §2.4);平时改 GDScript 只需重导出,别去重编模板。**改完代码必须重导出 exe 再让用户实测**——exe 内嵌 PCK(embed_pck=true),只跑旧 exe 会把已修复的 bug 当成"没修"(2026-09-05 多人建房事故即此因)。

## 架构

### 环面世界与地图
- 地图:ASCII 文本 **`.cyrm`**(如 `map/demo.cyrm`)。**v3 格式**(带 `# cyrm-v3` 标记):125×75 格 × 64px 瓦片 = 8000×4800 世界像素;每格 **4 字符 = [纹理 3 位 0xx][形状hex]**(纹理 `000`=空气/`001`-`022`=1-22,structure.png 两行各 10 块 + 第3行两块水;形状 hex `0`-`F` = 2×2 子格掩码,15=全砖,0=空气占位)。纹理用 3 位数字、不用字母。**旧格式**(250×150 单字符,无标记)加载时自动 2×2 转换(packed 值 + spawn 坐标 ÷2)。`#` 开头的行是注释(含出生点 `# player <col> <row>`;`# player2 <col> <row>` 为双人第二出生点,PvP 用)。加载:`MazeGenerator.map_file_path()` 优先随机取 exe 旁 `.cyrm`,否则随机取 `map/*.cyrm`(**同目录多份随机读一份**,会话内固定);`map/*.cyrm` 已在导出 include_filter 里。编辑器输出 `.cyrm`、可导入 `.cyrm`/`.txt`。
- `MazeGenerator`(Globals/maze_generator.gd,`RefCounted`,非 autoload)是地图与环面核心:
  - 格值 = packed `texture*16 + shape`(0-335,`pack/texture_of/shape_of`);`EMPTY=0`、`SOLID=31`(纹理1 全砖);挡路判定走 `TileDefs.is_blocked`(非 0 且 type=wall);
  - 读图:`load_map_file()` / `map_size()`(v3 与旧格式都返回转换后 125×75;行宽不一致的抬头行会被跳过);`convert_old_grid()` / `serialize_v3_grid()` 是单一转换源(旧 v2 字母版地图用 `Tests/convert_map.gd` 转 v3);
  - 环面数学:`toroidal_dist`(格级)、`toroidal_delta_px`(像素最短向量)、`anchor_to_nearest`(实体锚到玩家最近副本)、`wrap_to_range`(取模回中间副本);
  - 寻路:`bfs_path` / `bfs_path_nearest` / `astar_path_nearest` / `has_line_of_sight`(Bresenham)。`current_grid` 静态变量由 Level0 赋值,空网格一律无路。
- **关键区分**:玩家每帧 `wrap_to_range`(只留中间副本);敌人/子弹用 `anchor_to_nearest`(锚定到玩家附近的副本)。墙体按 3×3 铺贴,相机跨接缝才能看到另一侧——实体若取模回 `[0,MAP)` 会在接缝处"消失"。

### 参数体系(重要约定)
- **autoload 三个**:`GameParameters`(Globals/gameParameters.gd):gravity0、TILE_SIZE=64、地图像素尺寸、敌人数/出生距离。`_ready()` 里从 `MazeGenerator.map_size()` 回写 `MAP_WIDTH/HEIGHT`;`NetBus`(Globals/net_bus.gd,第二个 autoload,PvP 网络 RPC 唯一收口):服务器/客户端共用 `/root/NetBus` 跨场景常驻,RPC 才能路由;建房/加入/断线经转交信号给 RoomManager;`NetBusExt`(Globals/net_bus_ext.gd,第三个):实验扩展协议(player_options/match_options/peer_hues)——**原 NetBus 必须与原作者版本逐字节一致**(实测改动其 RPC 方法列表会让与原作者大厅的所有 RPC 失联、建房无应答),新协议一律加到 NetBusExt;`Settings`(Globals/settings.gd,第四个):持久化偏好 + 音频总线 + 键位重映射(`user://settings.cfg`)。
- 玩家/敌人参数**不是** autoload:`PlayerParams`、`EnemyParams` 是 `RefCounted` + `const`,静态访问(如 `EnemyParams.FlyBird.wake_radius`)。加新敌人 = 在 `EnemyParams` 加一个嵌套类。

### 敌人(Scenes/Enemies/)
继承链 `EnemyBase → EnemyFlyBase → EnemyFlyBird`;JumpBird 直接继承 `EnemyBase`:
- `EnemyBase`(CharacterBody2D):`hp/contact_damage/knockback_strength/knock_decay_rate` 导出参数;统一状态机 `state`(int,各子类自带 `enum State`);子类覆写 `_ai(delta)`/`_anim_update()`;受击白闪+击退在 `_apply_hit`(枪击击退叠加原速度;爆炸 `set_velocity=true` 设独立 `knock_velocity` 向量,每帧叠加 `move_and_slide` 后指数衰减 `knock_decay_rate`,不覆盖移动速度);**受击/死亡白闪统一在基类**:`_hit_flash_time`(0.1s)与 `_begin_death()`(死亡白闪 `shared.death_flash_time`=0.5s 后销毁)统一计时,渲染走 `_flash_update()`(默认 modulate 纯白;黑鸟因 silhouette shader 覆写 COLOR 而 modulate 失效,覆写本方法改走 shader 参数);`_set_facing()` 锁转向频率(两次翻转至少间隔 `shared.turn_min_interval`=0.5s,防来回抖);**死亡物理与生前完全一致**——尸体继续走同一套 `_physics_process`(重力/摩擦/击退衰减/碰撞),只是 AI 不行动;尸体被后续命中只吃击退不吃伤(`hurt` 的 `is_dead` 分支走 `_apply_knock_only`),基础速度也按 `knock_decay_rate` 指数衰减(滑行逐渐停住);每帧 `move_and_slide()` 后 `_wrap()`;接触伤害走 ContactArea + 环面距离兜底。入 `enemies` 组。
- `EnemyFlyBase`:飞行寻路。A* 按**鸟自身飞行碰撞箱 + 场上实体碰撞箱**判可走(`_bird_can_pass`);空路径直线兜底;被悬挑墙压到(死区)时水平逃逸;站/飞碰撞箱切换(`_apply_flight_collision`)。寻路参数耦合 `EnemyParams.FlyBird`(当前唯一飞行敌人,接受该耦合)。
- `EnemyFlyBird`:状态机 SLEEP/TAKE_OFF/FLY/SHOOT/CHARGE/RETURN。平抛投弹(玩家速度预测);HP<25% 单向切 CHARGE 冲撞(穿透无敌帧、撞后自毁);死亡白闪后销毁(物理与生前一致,保留碰撞);返程回家落地入睡。
- `EnemyJumpBird`:近战跳跃怪(跳/后跳/扑击);死亡物理与生前一致、保留碰撞(与飞鸟统一,不再清碰撞箱)。
- `EnemyBlackBird`:绕背瞬移刺客(睡眠→随机游走→周期性判定玩家另一侧、距玩家 2~4 格(随机)的地板格落点(地板格 + LOS)→起飞上跳→落地播 disappear→白闪→传送→闪后空中播 appear→落地→带跳跃冲锋打 6 伤(穿透无敌帧)→大后跳(命中/未命中都)→回游走,玩家远离入睡);死亡白闪后销毁。数值在 `EnemyParams.BlackBird`。
- **加新敌人** = 一个 .tscn + `editor/enemies.json` 注册表加一行(键名 → 场景路径),spawner 随机取"地板格"(EMPTY 且正下方 SOLID)布点。

### 武器与子弹(Scenes/Weapons/)
- `WeaponBase`(Node2D):数值全是 `@export`(fire_cooldown、bullet_speed/range/size/color、pellet_count/spread、damage/impact、recoil_push/kick、cam_shake、move/jump_penalty、heavy_aim 激光、pitch_clamp_deg)。`fire()` 按 pellet_count 从 `bullet_scene`(@export,默认 bullet.tscn)出弹并注入 `bullet_gravity`;`apply_hit()` 调敌人 `hurt()`;heavy_aim 按住预瞄、松开发射;`preview_arc=true` 时预瞄画**抛物线弧线 + 末端爆点标记**(参考,用 `preview_time`,与子弹 fuse 解耦)。**弹道方向与走路朝向解耦**:`_auto_aim` 用鼠标推导瞄准侧(近垂直瞄沿用上次明确侧,`_aim_facing`/`_current_aim_facing`),`fire()` 开火瞬间先 `_auto_aim()` 再出弹——所有开火路径(直接/缓冲/连发/重武器)都取本帧鼠标方向,不再读被走路输入覆盖的 `get_facing()`(否则后退时朝反方向开枪,`clamp_pitch` 把子弹折到走路侧)。
- 现有武器(槽位 1~6):手枪/步枪/m82a1(重狙,heavy_aim)/s686(霰弹 8 丸 ±5°、射程700)/grenade_launcher(第5槽,重型)/**激光枪(第6槽)**。
- **激光武器**(`Scenes/Weapons/laser_weapon_base.gd`,`class_name LaserWeaponBase extends WeaponBase`):不开实体子弹——开火瞬间用 `Globals/beam_trace.gd` 沿瞄准方向逐 32px 子格追踪,遇墙镜面反射至多 `max_bounces` 次(激光枪默认 2,tscn 可调),折线点集交 `Globals/laser_visual.gd` 画光束并一次性结算命中(含磨可破坏砖)。基类留三个可覆写缝(几何 `_emit_beam` / 结算 `_apply_beam_damage` / 视觉 `_spawn_beam_visual`+`_beam_style`),新激光武器 = 薄子类 + 场景调参;`laser_gun.gd` 是参考子类。PvP 下客户端只播视觉不裁决,服务器权威结算后经 `pending_beam_report` 广播给非射手客户端。
- 子弹:玩家 `BulletBase`(伤害由 WeaponBase 管;`fire()` 注入 `hit_damage/hit_impact`,切枪后旧武器已 free 时子弹自带参数兜底直接结算);**爆炸弹**(如 `grenade_bullet.tscn`)在 BulletBase 加 @export `explodes/direct_hit_damage/fuse_time/explosion_radius/damage/knockback/visual` —— `explodes=true` 时撞墙/命中敌人一律反弹(衰减0.6),首次碰撞后 `fuse_time`(撞墙)/`hit_fuse_time`(命中敌人)引信爆炸(命中敌人另加 10 直接伤立即结算)、超射程兜底爆炸。AoE 判定在 `Globals/explosion.gd`(`Explosion.apply_aoe`:内圈 40% 满伤+二次方平缓衰减/LOS遮挡(墙后保留 75%,内圈免疫掩护衰减)/友伤/击退独立向量纯径向——敌人走 `set_velocity=true`、玩家经 `take_hit` 传击退,爆炸穿透无敌帧 + 爆心越近相机震得越猛),爆炸特效 = `explosion.tscn`(AnimatedSprite2D 多帧,`_explode` 按 `explosion_radius/帧宽` 缩放,`explosion_fx.gd` 播完自毁)。敌人子弹 `enemy_bullet.gd` 是带重力抛物线弹(`launch()`)。
- 碰撞层:子弹 mask=5(地形+敌人),榴弹不含玩家 → 友伤只来自爆炸。

### 玩家(Scenes/Player/player.gd)
CharacterBody2D:指数缓动移动手感、土狼时间/跳跃缓冲/可变高度、冲刺(沿用最近移动方向)、下蹲、姿态碰撞箱(Pose→CollisionPolygon2D,运行时只启用当前姿态的箱子)、iframes/击退(爆炸=独立 `knock_velocity` 向量,衰减率 `player_knock_decay_rate`)/倒地(倒地**不取消物理**,仍受重力/击退,只是不吃输入;按 R 重载场景)。移动/跳跃/冲刺/镜头/战斗数值全在 `PlayerParams`。**加新武器** = 一个继承 WeaponBase 的 .tscn + `weapon_component.gd` 的 `WEAPONS` 注册表加一行(键对应输入动作;project.godot 已注册 1~0,现用槽位 1~6 = 手枪/步枪/重狙/霰弹/榴弹/激光枪)。
- **结构(轻量拆分)**:根 `player.gd` 只留移动/姿态/物理帧编排;攀爬(梯/锁链)、战斗(生命/无敌/击退/倒地)、武器(注册表/换枪/后坐)分别抽成 `ClimbComponent`/`CombatComponent`/`WeaponComponent`(Player.tscn 子节点)。组件**不写自己的 `_physics_process`**,由根每帧显式按顺序调用(`climb.update → 移动 → combat.apply_knock → move_and_slide`),避免调度乱序。跨组件状态经根传参;根公开接口 `take_hit/get_facing/set_facing/is_downed/apply_recoil`、信号 `hp_changed`、只读 `hp/max_hp` 原样保留(HUD/敌人/武器零改动)。契约守卫 `Tests/player_contract_smoke.gd`(源码级)保接口不漂。
- **输入可注入**:根读输入走 `Globals/input_source.gd` 的 `InputSource`(默认委托真实 Input,行为不变;PvP 服务器可注入网络输入驱动远端玩家);瞄准有 `get_aim_dir_override()` 覆盖钩子(本地返回 ZERO → 武器落回鼠标,网络返回注入方向)。

### 场景切换纪律(重要,防原生段错误)
**反复构建/同步释放含大量碰撞体(数万静态体)的物理世界,会在场景切换时偶发原生段错误(仅 GUI,headless 不复现)**。约定:
- **演示世界永不释放**:主菜单背景演示(Level0 menu_demo 分支,只建出生点周边小区域碰撞 `build_permanent_region`)回主菜单时由 `Level0.menu_demo_instance` 摘树保活、`revive_demo()` 复位重用;`main_menu._leave_menu` 切场景前先摘下挂起再 `await process_frame`。
- **游戏世界退役挂起**:`Level0.safe_change_scene(tree, path)`(静态,先 `await tree.process_frame` 脱离调用方的信号栈再动树)——新场景手动实例化接管 `current_scene`,旧世界摘树挂起**不再立即释放**;挂起世界存在静态 `_retired`(稳态最多一具,新世界退役时才释放更早的那一具)。**回主菜单/重载关卡一律走它**:`pause_menu.go_menu()`、单机按 R 重载(player.gd)、pvp_client 两处回菜单。注意菜单→游戏方向仍走 `_leave_menu`+change_scene(见下)。
- 纯 UI 场景(主菜单/匹配/设置)之间的切换继续用 `change_scene_to_file`(无大物理世界,无风险)。

### 渲染管线(Level0.tscn)
根节点把未处理输入手动转发进 `WorldViewport`(SubViewport);世界(墙体/玩家/敌人)渲染进 SubViewport,`PostProcess`(post_process.gd)做像素缩放裁切 + 倒地暗角 + 受击红闪(`flash_hit` 置峰后每帧衰减 `hit_red`)。相机 `camera_2d.gd` 带前瞻/死区。注意:冒烟测试把武器挂到根 Window 而非 SubViewport(见 weapon_base 的鼠标坐标注释)。
- **墙体 64px 砖块渲染**:`_create_wall_tileset()` 运行时把 structure.png 两行 20 块 32px 砖最近邻 2× 放大成 64px,对每(纹理×形状)生成 16×20 atlas(空气象限透明),TileSet tile_size=64,`_paint_maze` 按 `Vector2i(shape, texture-1)` 铺 125×75 ×3×3 环面。
- **碰撞**:`Globals/collision_builder.gd`(`class_name CollisionBuilder`,静态可测)把形状掩码展开成 250×150 的 32px 子格(每 64px 格 → 2×2),贪心合并矩形(ts=32)后按 **9 环面副本偏移**实例化(每块矩形 ×9,共享同一 shape)。**永久墙(不可破坏)建一个整图节点、建一次不动;可破坏层按分块存节点**(块边长 12 格 ≈ √地图边长,块内一次贪心 + 9 副本),摧毁时只重建所在块 → 重建成本 O(块面积)。**只有 type=wall 产生碰撞**,通道(梯子/锁链)可走/可爬。
- **世界构建**:`Globals/world_builder.gd`(`class_name WorldBuilder`,静态):`load_grid()`(地图→current_grid/TileDefs/地图像素尺寸)、`build_sim(parent, grid)`(碰撞:永久墙+可破坏分块+攀爬基座条)。单人 Level0 与 PvP 客户端/服务器共用。

### 砖块属性与破坏(Globals/tile_defs.json)
- **属性表** `Globals/tile_defs.json` 是单一来源:每块 name/type(墙/通道/液体/气体)/hp/explosion_decay/bullet_destroyable/explosion_destroyable/elastic/climb_speed/friction。编辑器副本 `editor/tile_defs.js` 由 `node editor/sync-tiles.js` 生成(file:// 下可靠)。
- 纹理 1-10 墙(hp1,不可破坏);11 梯子、12-14 锁链上中下 = 通道(climb_speed 1.6× 最快);15-18 树叶(墙,子弹/爆炸可破,弹性弱弹玩家);19-20 树干竖/横(墙,爆炸可破);21 水、22 水面 = 液体(无碰撞,可游)。爆炸衰减统一 0.75(水 0.25)、摩擦 1.0(现状不变)。
- 加载:`TileDefs.load_defs()`(level_0._ready);挡路 = `TileDefs.is_blocked`(非 0 且 type=wall),寻路/LOS/碰撞共用。
- **破坏**:`TileDefs.damage_tile(cell, dmg, "bullet"/"explosion")` → hp≤0 变空气(改 `MazeGenerator.current_grid` + `Level0.on_tile_destroyed` 清 3×3 瓦片 + 持久可破坏子格 2×2,标记所在分块下帧重建)。子弹撞树叶扣血;爆炸对树叶/树干按距离衰减×0.75 扣血。
- **攀爬**:玩家中心(或脚底)在通道格(梯子/锁链)「**刚按上**」主动攀附(不受重力):上爬 ×`tile.climb_speed`(梯 1.6/锁链 2.0),下降 ×`tile.climb_descent_speed`(梯 2.0);**锁链无下降倍率 → 按下自由落体**(解除攀附交给重力,不被空中抓回);松开挂住不坠落;**到顶 = 脚底进入梯子上方一格**(以脚底为参考格),再按上 = 跳离梯子;进入靠「刚按下上」而非按住 → 跳离后按着上也抓不回;攀附空闲可水平走离梯子;**仅锁链顶/底基座有薄碰撞条**(`CollisionBuilder.build_climb_ledges`,全宽 64×6px;梯顶不加,避免挡爬升)。上爬与梯子下行再整体 × `PlayerParams.climb_vertical_mult`(1.2;锁链下行=自由落体不受影响);**身在梯/链格上不能空中下冲**(`climb.is_over_climb_tile()`:中心或脚底在通道格即判,按↓只能下移/下落,不能 charge_down 快速下坠穿过梯/链)。
- **弹性**:碰树叶(elastic)被弱弹(PlayerParams.elastic_bounce=150)。

### 水
- **瓦片**:纹理 21 水 / 22 水面,`type=liquid`(无碰撞,`is_blocked`=false)。地图只画 21;水面(22)由 `Level0._paint_water` 自动派生(该格上方非 liquid → 水面层)。`WaterLayer`(水体)与 `WaterSurfaceLayer`(水面)两个 TileMapLayer;**水面起伏**由 `water_surface.gdshader` 做逐格正弦上下拉伸(锚底无缝、相位逐格错开,`amp/speed` 沿用 `GameParameters.water_sway_amp/speed`),水体层不挂 shader(水不流动)。
- **`Water` 助手**(Globals/water.gd,静态,不引 autoload,-s 可测):`is_in_water` / `surface_y_at`(所在列向上扫到最顶液体格的顶边) / `submerged`(中心低于水面线=没顶) / `feet_offset` / `water_mult`(爆炸×水格 decay) / `bullet_drag_factor`(子弹阻力系数)。约定:脚底(中心+半身)在水格 = 在水中。
- **主角**(`Scenes/Player/swim_component.gd`):水中跳过攀爬/重力/跳跃/下蹲/冲刺;左右=水平游(×`player_swim_speed`),按上=上浮(`player_swim_up`)、不按=下沉(`player_swim_down`);不做水面悬停/浮力弹簧——出水(脚底离开水格)由 `in_water` 判回 false 自动恢复普通物理(重力)。水下扣血未做。**呼吸(氧气)按「大部分没入」扣**:判定参考线比中心低 `PlayerParams.water_breath_line_offset`(10px,≈胸口下沿)——水面到胸口(约 2/3 没入、头能露出)就开始扣,要浮到水面低于此线才回气(比原"中心没入"更早扣、更难回气;可调)。
- **敌人**(`EnemyBase._apply_water`):落水浮力回水面;水平朝 `_water_swim_dir()` 游(JumpBird/BlackBird 覆写为朝玩家,基类=漂着);**溺水**:没顶累计,`drown_delay`(5s)后每 `drown_interval`(1s)扣 `drown_damage`(5),浮在水面不算。FlyBird 寻路把水当障碍(`_bird_can_pass` 遇 liquid 不可走),但正下方是水仍可飞越。
- **爆炸衰减**:目标所在格是水 → 爆炸伤害/击退 × 该水格 `explosion_decay`(0.25,`Water.water_mult`)。LOS 遮挡 75% 不变(仅墙后掩体;梯/链是 passage 不挡也不减,玩家站梯/链上吃爆炸 = 满伤,与空气一致)。
- **子弹阻力**:子弹在水里 `velocity_vec *= exp(-water_bullet_drag·Δt)`(`Water.bullet_drag_factor`),玩家 + 敌人子弹共用。
- **水粒子**(`Scenes/Effects/water_fx.gd`,运行期挂主角 + 敌人):水中**移动**才喷;中心贴水面 → 溅水花,没入深 → 上浮气泡。

### 碰撞层(按位)
层1=地形、层2=玩家、层3=敌人。玩家/玩家子弹 mask=5(1+3);敌人占层 3(值4)、mask 侦测玩家。

### 编辑器工具
`editor/structure-editor.html` + `editor/smoke.js` 是独立浏览器地图编辑器(大图缩放/画笔),与 Godot 引擎无关。编辑 125×75 网格,**砖块纹理调色板(0-22)+ 2×2 砖形面板**(点四象限翻转或选预设 1/4/半/3/4/全砖);导入旧格式自动 2×2 转换,导出写 v3(`# cyrm-v3` + 每格 4 字符 [纹理 3 位 0xx][形状hex])。工具栏含 画笔/矩形/油漆桶/橡皮/选框/直线(直线跟随画笔大小);选框支持框选后整体移动、Del/Backspace 删除、油漆桶点在选区内=填整个选区(点外清选区+正常连通填充)、Esc 取消。`node editor/smoke.js` 跑 Core 测试。

### 网络与 PvP(阶段 1 + 2 + 4:匹配进图 + 对局互通 + 回合制)
- 服务器:`server/server_main.tscn` 入口(headless)。**双模式**:无参=大厅(默认 7777),`--worker --port P`=对局 worker。**一服多局**:大厅 `server/room_manager.gd`(`RoomManager`)只做建房/配对(房间注册表,2 人就绪)→ 给每局拉起一个独立 worker 子进程(`OS.create_process`,同 exe `--headless --worker --port P`;开发=editor 带 `--path`+场景,导出 exe 靠 `main_scene.dedicated_server`)→ 发 `go_match(role,port)` 让两端转连。**worker 内跑 `server/server_main.gd`(worker 分支)**:独占 UDP 端口,等两客户端 `claim_role` 收齐 role1/2 → `RoomManager.start_match_on`(static:重算地图尺寸、给两端 `match_start`、建 `server/match_host.gd`)→ `MatchHost` 权威对局;任一方离开 → 拆局退出释放端口。各局=独立进程 → **内存隔离**,共享全局(current_grid/TileDefs)不跨局互踩。端口分配用「唯一递增 + 占用集合」(`_pick_worker_port`,基准 7800)——**不要**在本进程 bind 探测空闲(worker 是独立进程,大厅探测看不到别的进程已占端口,并发会把同端口发给两个 worker)。大厅在玩家转连后断开即关房归还端口(worker 端口 30s 延迟归还,防转连瞬间串线;worker 踢掉串线连接且 `_on_peer_left` 只认本局双方)。
- **`MatchHost`(每房间一个)**:建世界(WorldBuilder 只碰撞不渲染)+ 两个 `Player.tscn` 实例注入 `NetworkInputSource` 权威模拟;每物理帧消费双方输入包、60Hz 广播快照、裁决子弹命中并广播 `bullet_spawn`/`hit_event`。开局 pin PvP 地图后要调 `GameParameters.refresh_map_size()` 重算世界尺寸(_ready 启动时算的是随机 demo 图,工厂图 9600 宽不同,不重算则环面回绕按错边界出现空气墙)。**回合制**:`_match_round_tick` 状态机 COUNTDOWN→PLAYING→ROUND_OVER→MATCH_OVER;**击杀定义:对方死亡都算**——每物理帧倒地转换检测(`is_downed` 边沿)不分死因(枪杀/爆炸/溺水/自伤/无射手)一律给对方 +1(弃用旧 pvp_killer 射手归因);局内死亡 2s 复活(`_respawn_player`:死者回本方出生点、满血/防水、武器回 1);**每次击杀后活着的胜方也立刻回本方出生点但保留当前血量、不回血**(`_reset_survivor`,防复活点连杀);每局先到 5 击杀赢、三局两胜、局间 `_side_swap` 换边。**换局纪律**:进新局前 `_reset_world_and_clear_dynamics()` 把可破坏砖/碰撞整层还原为建局基线(`_base_grid` 深拷贝)+ 清光场上子弹(`bullet` 组)+ 重置 `_seen_bullets`;客户端收到新一轮 COUNTDOWN 同刻 `Level0.reset_destructibles()`(用 `_pristine_grid` 重铺)+ 清本地视觉子弹 → 两端每局从同一基线出发,无幽灵墙/跨局残留。**COUNTDOWN 3 秒双端禁移动/开火**:服务器不喂输入(只清空缓冲),客户端锁本地武器开火(`player.set_controls_locked`);进 PLAYING 解锁。局内击杀→复活/活方复位不动砖。
- 客户端流程:`main_menu`(默认场景)→ `matchmaking`(建房/输房间号;配对完成收到大厅 `go_match` 后**断开大厅、`start_client(server_address, worker_port)` 转连该局 worker 并 `claim_role`**,再等 worker 的 `match_start`)→ `pvp_game`(`pvp_client.gd`:Level0 pvp_mode 世界 + 补后处理 + 每 tick 上报输入 + 快照消费)。回菜单走 `Level0.safe_change_scene`(见「场景切换纪律」)。
- **本地玩家 = C2 客户端预测 + 回滚重放(已开启;仅 1v1)**:`player.gd` 的 `server_rendered` 模式下跳过全部移动物理,位置/姿态/朝向由快照插值(`apply_server_snapshot` + `_update_server_rendered`),血量/防水/倒地直接采纳;只保留鼠标瞄准/开火/受击反馈等本地视觉。历史根因:C2 对梯子等"边沿+位置敏感"机制与服务器权威打架 → 曾大量回拉,故此前默认关闭;2026-09-11 按用户要求开启。实现:`Globals/prediction_rollback.gd`(`class_name PredictionRollback`,移植自原作者 main `70e4c75`)+ `pvp_client.gd` 顶部 `LOCAL_PREDICTION_ENABLED := true`——**改回 false 即回到纯服务器渲染**(server_rendered 分支完整保留)。探针 `Tests/c2_reconcile_probe.tscn` / `c2_twin_probe.tscn` 实测 OK。**C2 链路只在 1v1(`pvp_client.gd`);大乱斗 `royale_game.gd` 无回滚代码,仍纯服务器渲染**。远端对手 = `PlayerReplica` 纯视觉副本(显示对手当前武器并按快照 `aim` 摆枪;**对手重武器预瞄中 → 副本也画出预瞄线**——M82A1 直线激光 / 榴弹抛物线弧,经 `weapon_base.drive_remote_visual` 驱动,不开火不读鼠标,`previewing` 为 false/倒地时收起)。**副本位置插值(重要)**:`player_replica` 位置走**双快照 tick 域 alpha 插值**——缓冲最近若干 canonical,渲染时钟落后最新 1 tick、按真实时间在相邻两快照间线性插值(`apply_snapshot` 带 tick 入缓冲;姿态/朝向/aim/倒地/武器仍按最新快照即时,只有位置平滑落后);时钟只在 tick 域走、不依赖两端时钟同步,丢包/卡顿冻结在最新已收位置,快照续上把时钟重置到最新窗口继续,不回退。插值结果跨接缝取 `toroidal_delta_px` 最短向量后取模回 canonical,再 `anchor_to_nearest` 锚到本地玩家最近副本渲染——每帧直接归位到可见副本,无旧指数/差分追赶。
- 协议(经 `NetBus` autoload RPC;对局权威=该局 **worker**,非 7777 大厅):握手——大厅→客户端 `go_match(role,port)`(配对完转连),客户端→worker `claim_role(role,name)`(报到,worker 据此建 role→peer 映射;**保持原版 2 参签名**,本端选项走 NetBusExt.player_options);输入包(60Hz reliable,`send_input`:轴/held/pressed/released 位掩码+切枪+瞄准方向)、快照包(60Hz unreliable,`snapshot`:每玩家 pos/vel/facing/pose/weapon/hp/waterproof/downed/aim/previewing)、事件包(reliable,`bullet_spawn`/`hit_event`/`tile_destroyed`——服务器拆墙广播,客户端 `TileDefs.damage_tile(cell,大伤,"explosion")` 触发 Level0 清瓦片渲染/`round_state`/`kill_event`——回合制状态/击杀广播)。**环面纪律**:协议只传 canonical 坐标、渲染各端归最近副本、插值走 `toroidal_delta_px` 最短路径。**击退方向走 toroidal 最短向量**:命中源(服务器子弹/爆心)锚在射手副本、可能与该玩家 canonical 相差整幅地图,`combat.take_hit` 里绝对相减会得出**反向击退**(跨接缝对枪被打向射手)——统一用 `toroidal_delta_px(source_pos, body)` 求推离方向(直击/爆炸/本地反馈同源)。
- 输入抽象:`InputSource` 基类(本地委托真实 Input)+ `NetworkInputSource`(消费输入包,服务器唯一消费方)。`NetworkInputSource.get_axis` **垂直轴由 held 位推导、水平轴返回 `ax`**(输入包只传水平轴,`climb_component` 用 `get_axis("up","down")` 读垂直——曾一律返回水平轴致服务器挂梯不动)。`weapon_base` 攻击经 player 查询(`is_attack_pressed` 等,has_method 守卫回退 Input);`BulletBase.apply_damage=false` = 客户端视觉副本(不裁决,伤害由服务器裁决)。
- PvP 固定地图 `factory_1V1(260827).cyrm`(150×100,`# player 17 65` + `# player2 133 64`;两出生点相距约 2200px 超视野,走近才互见)。
- PvP HUD:`Scenes/pvp_hud.gd`(`class_name PvpHud`,CanvasLayer layer=130 盖在 PostProcess 128 / 单机 HUD 129 之上)显示双方击杀/局胜/局号 + 中央状态(准备倒计时/胜局/获胜),MATCH_OVER 后 `pvp_client` 延时回主菜单。复活视觉:`combat.revive()` 已补 `post_process.set_downed(false)`(复活后屏幕不再变灰)。
- 测试:`Tests/pvp_room_smoke.sh` 断言建房/加入/开局;`Tests/pvp_match_smoke.sh` 断言输入→模拟→快照→子弹广播链路 + **round_state 广播**(loopback)。脚本收尾用 `taskkill` 按 PID + `kill_port`(netstat 找 7777 持有者)强杀——**Windows 下 bash `kill` 杀不死 headless Godot,会留僵尸占 7777**。
- **大乱斗模式(限时死斗,RoyaleServer 分支)**:主菜单「大乱斗」→ `Scenes/royale_lobby.tscn`(建房:公开/私密+邀请码/2~8 人上限/禁武器选项;房间列表点击加入;等待室显示房内成员,房主开局,房主掉线自动转移)。协议全走 NetBusExt(`royale_create/join/leave/list/start` → 广播 `royale_rooms`/`royale_room_state`),原版 NetBus 未动。开局:大厅 `RoomManager.royale_start`(≥2 人,`in_match` 防重入)拉起 `--headless --worker --royale --port P --players N` worker → `server_main` 收 claim(≥2 人且 20s 超时即开)→ `server/royale_host.gd`(`class_name RoyaleHost extends MatchHost`)N 人权威对局:**开局地板格散点**(两两环面距离 ≥15 格,不够放宽)、**死亡 2s 复活无限次**(复用 `MatchHost._handle_respawns`;复活点离存活敌人 ≥8 格)、**限时 5 分钟、击杀最多者胜**(平局无人胜)。**击杀归因**:命中瞬间把射手记到受害者 meta `last_damager`(RoyaleHost 覆写 `_on_bullet_hit` + `Explosion.apply_aoe` 玩家分支),倒地边沿读 meta 计分;无源死亡(溺水/环境)不计分。排行榜/比分/倒计时经 round_state 载荷扩展(`names/scores/alive/left/timer/match_winner`,签名不变)下发,客户端 `Scenes/royale_hud.gd` 左上角排行榜 + 中央倒计时/胜负广播。对局客户端 `Scenes/royale_game.tscn`(N 个 PlayerReplica 副本 + 头顶 ID/血条 + 小地图 `setup_multi` 多目标)。中途掉线 = 移出对局标「离开」,在线 <2 人提前终局。**RoyaleServer 分支不含 test-reload 的换弹内容**(两分支各自独立)。

### 大乱斗双模式:公网服务器 / 局域网(KH_v1_1_3_PubServer)
- **公网模式(默认)**:客户端连一个**固定公网服务器地址**(`Scenes/royale_lobby.gd` 顶部 `PUBLIC_SERVER_ADDR` 常量;玩家可用 `Settings.royale_pub_addr` 覆盖并记忆)。房间列表每 2.5s **静默自动刷新** → 有人「创建房间」后所有人几秒内可见、点列表即加入。
  - **开服方要求**:在那台公网机部署**本仓库的 Dedicated Server 构建**,放行 UDP **7777**(大厅)+ **7800~7910**(对局 worker)。公网机同时当大厅与对局主机 = 玩家侧无需任何端口映射(即"内网穿透"的落地点)。
  - 原作者云服(120.53.107.140)只有 1v1 协议,**不含**大乱斗:公网模式必须指向自建构建。
- **局域网模式**:维持旧流程(地址 `127.0.0.1` + 「启动/重启本机服务器」按钮;朋友填开服机 IP)。模式持久化在 `Settings.royale_public_mode`,切换模式会自动重连大厅。
- **僵尸房清扫**:`RoomManager._process` 每 10 分钟扫一次,清掉空置房与超龄(>2h)未开局房并归还 worker 端口(等效原作者 main 的 room_sweep)——公网长期开服必需。
- 已知噪音:开局转连瞬间向未完成转连的 peer 广播会刷 `Unable to send packet channel 0`(ENet 噪音,不影响对局)。

### 扩展协议信封 + 能力协商(兼容性,KH_v1_1_3_PubServer)
- **NetBusExt 只暴露两个 @rpc**:`ext_c2s(kind, payload)` / `ext_s2c(kind, payload)`;功能全部靠 `kind` 分派(原有 signal 名不变 → UI/消费端零改动)。发送一律用 `NetBusExt.c2s / s2c / s2c_all`。
  - **为什么**:Godot 按「节点」做 RPC 方法表校验和——以前每加一个功能就加一个 @rpc 方法,新旧构建互连即触发 `rpc node checksum failed`,本节点**所有** RPC 一起失效(现象就是"游戏一更新,旧服务端就不能用")。信封化后**加功能不再改方法表**:旧服务端只是"不认识某个 kind",忽略即可。
  - **注意**:这是一次性断点——本版本之前发布的旧服务端仍会 checksum 失败;从本版本起,后来的版本共用信封 → 旧服务端可长期使用(只缺新功能)。
- **能力协商**:客户端连上大厅/worker 后调 `NetBusExt.client_hello()`;服务器在收到 `hello` 时回 `welcome{build, caps}`。结果存 `NetBusExt.server_build / server_caps`,`NetBusExt.server_has(cap)` 查询。大乱斗大厅据此降级:服务器 `royale` 能力缺失(如原作者云服)→ **灰掉建房/加入**并给人话提示;2.5s 未收到 welcome 视为版本过旧。
- **移植原作者服务端优化**:① `server_main._kill_port_holder` 的 PowerShell 管道修正(`Select -ExpandProperty OwningProcess`;原 `% OwningProcess` 取不到属主进程 → 杀不掉,7777 被占新实例 bind 失败闪退);② 僵尸房清扫补齐"**杀 worker 进程 + 断开房内玩家 + 归还端口**"(`RoomManager._kill_port_process` / `_kick_room_players`,跨平台 lsof/pkill)。
- **测试脚本**:`Tests/pvp_match_smoke.sh` / `Tests/pvp_room_smoke.sh` 不再写死 Godot 路径(支持 `GODOT=` 环境变量 + 常见路径自动探测),并把 `res://tests/` 正名为 `res://Tests/`(大小写敏感系统必需)。

### 测试
无单测框架。`Tests/*.gd` 是 `extends SceneTree` 的冒烟/诊断脚本,用 `-s` 跑:`enemy_logic_smoke.gd` 为主(覆盖敌人 AI、环面数学、武器参数/命中、碰撞层、寻路/LOS、多弹丸),其余 seam_analyze/seam_screenshot/wrap_probe 是环面接缝诊断。写新测试注意: `-s` 阶段 autoload 尚未实例化,避免静态引用会连带预加载引用 autoload 的脚本(见 smoke 内注释)。**约定:冒烟测试由用户自己跑;代理只跑"诊断探针"**:`Tests/menu_autotest.gd`(GUI/HEADLESS 经 `-- --autotest-sp|mp|set|level` 自动流转主菜单,sp 含 Esc 暂停+回主菜单验证)、`Tests/lobby_ping_probe.gd`(大厅 UDP 可达性)、`Tests/lobby_create_probe.gd`(对大厅建房+列表全链路,场景模式跑)、`Tests/royale_probe.tscn`(大乱斗全链路,场景模式:本进程当大厅 + c1/c2 headless 子进程走私密建房→错邀请码应拒→对码加入→开局→转连 worker→断言 match_start/round_state/match_options/60Hz 快照 ≥30;子进程 stdout 不落父进程,排查看各自 `user://logs/` 轮转日志)。

### 干员卡/武器卡编辑器(DevTools)
开发专用 GUI 工具:「填卡 → 生成施工提示词 → 自动调 Claude Code 施工」。**当前分支(KH_v1_1_3_PubServer)与 KH-char-weap 分支均保留此工具**;`export_presets.cfg` 两处 `exclude_filter` 已含 `DevTools/*`,玩家包不可见。跑法:**双击 `DevTools/launch_card_editor.bat`**(启动器与工具同目录,内部自动切到仓库根再打开 `res://DevTools/card_editor.tscn`;带分支守卫:场景缺失时提示切分支,不会误启游戏)。

- 文件职责:`card_editor.gd`(装配根/AgentBar/LogPanel)| `card_schema.gd`(字段/默认值/校验)| `card_store.gd`(磁盘读写,卡目录 `DevTools/cards/{operators,weapons}/<id>.json` + 同名 PNG 头像)| `card_list_panel/card_form_panel/portrait_view/ui_kit`(UI)| `prompt_builder.gd`(卡→提示词)| `agent_runner.gd`(CLI 进程/日志)| `card_probe.gd`(headless 诊断:`-s res://DevTools/card_probe.gd`)。
- **卡数据**:示例卡 `op_vanguard`/`wp_machete` 可作字段参考;`cards/.state.json` 是游戏侧现状标记(`operator_skeleton_done`/`slot6_refactor_done`/`melee_branch_done`),决定提示词走 FIRST(搭骨架)还是 NEXT(增量)模板,agent 施工成功后由编辑器自动翻转。`cards/.prompts//.logs/` 已 gitignore。
- **提示词合同**(agent 收到后照做):四模板按卡与 state 分派(干员 FIRST/NEXT、武器 DESIGN[slot=0 纯设计稿]/FIRST[slot>5 首枪含扩槽重构]/NEXT);公共骨架 = 工程纪律 + **路径白名单(禁越界改文件)** + 卡 JSON + 程序化像素画合同(`gen_portrait.gd` 按 `--card=type/id` 分支产出 PNG,禁外部素材/禁 FastNoiseLite)+ headless 验证清单 + 提交规范(**开工先 `git rev-parse HEAD` 对不齐即停**;共享历史线纪律)+ 末行 `CARD-DONE <type>/<id> rev<N>` 回报。
- **agent 施工流程**:编辑器里选卡→[生成提示词→剪贴板]→[发送给 Claude Code](内部写 `.prompts/<tag>.md` + `.logs/<tag>.bat` 启动 `claude -p`,日志实时进 LogPanel;CLI 不在时用复制兜底到任意会话手工跑)→ [停止] = `taskkill /T /F`;「全自动」勾选默认**关**(默认 acceptEdits + git/Godot 白名单)。
- 纪律:游戏侧冒烟(enemy_logic_smoke 等)仍由用户自己跑,agent 只跑提示词里的 headless 验证;给本工具加功能时新字段先过 `card_schema.gd`(默认值+校验)再动表单,别在编辑器里散写字段。

## 进度与计划(2026-09-05 更新,KikuchiHeinr 实验分支)

### 大乱斗模式落地(2026-09-06,RoyaleServer 分支)
- 主菜单新入口「大乱斗」→ 大厅建房/公开房列表/等待室(公开或私密+邀请码、2~8 人上限、禁武器选项沿用 1v1 那套)→ 房主开局 → `--royale --players N` worker → `RoyaleHost` **限时 5 分钟死斗**:死无限复活、击杀最多者胜、左上角排行榜。协议全走 NetBusExt,原版 NetBus 逐字节未动;详见「网络与 PvP」末节。
- E2E 探针 `Tests/royale_probe.tscn` **ALL-OK**:私密房+邀请码(错码被拒)+开局+双端 claim+match_start/round_state/match_options/快照 153/134 全通过,进程干净退出。
- 期间修的三个真 bug:royale_probe 裸 `READ`/`WRITE` 枚举(解析失败→Godot 静默回退主菜单,headless 表现为「无输出挂死」,错误只在 `user://logs` 轮转日志里)、`RoyaleRoom` 漏声明 `worker_port` 字段(赋值即运行时报错,开局链路中断)、`toroidal_dist` 调用缺 cols/rows 参数(RoyaleHost 编译失败连带 worker 起不了局)。
- 注意:本分支不含 test-reload 的换弹内容;GUI 实测前需重导出 exe(embed_pck)——旧 exe 无大乱斗按钮/场景。

### 三个实测 bug 的排查结论(2026-09-05 第二轮,均已定位)
| 症状 | 根因 | 状态 |
|---|---|---|
| 多人建房停在「建房中…」 | **导出 exe 过期**:exe 导出于 17:08(≈a3aec8c),NetBus 建房协议修复(55c39e7,18:30)从未进过任何导出物;旧 exe 的坏 RPC 方法表连原作者大厅(120.53.107.140)所有 RPC 静默失联。HEAD 的 net_bus.gd 与原版逐字节一致(md5 相同),`lobby_create_probe` 实测对云大厅建房+列表成功 | 重新导出 exe 即修复 |
| 单人「简单」闪退(窗口消失) | exe 时代主菜单演示世界带**全量地图碰撞**(a3aec8c 未做小区域+保活),点开始探索随 change_scene 同步 memdelete → 已知原生段错误;HEAD 已修但 exe 没带。**代码无简单特有崩溃路径**(难度只做 0.5× 数量截半,纯内存操作);`sp_difficulty` 选一次永久记住 → 概率崩溃被贴「简单」标签 | 重新导出 + 本轮 safe_change_scene 加固 |
| 单机死亡退出卡退 | `pause_menu.go_menu()` 回主菜单、按 R 重载,把带全量碰撞的游戏世界同步 memdelete——HEAD 也没修(只保活了演示世界) | 本轮 `Level0.safe_change_scene` 修复 |

### 本轮修复(fix commit)
- `Level0.safe_change_scene(tree, path)`:先 `await process_frame` 脱离调用方信号栈,新场景手动实例化接管 current_scene,旧世界摘树挂起、不立即释放(静态 `_retired` 稳态最多一具,新退役时才释放上一具);接入 go_menu / R 重载 / pvp_client 两处回菜单。headless 验证:凡走到回主菜单的运行 100% 成功;立刻摘树(不 await)或 1s 延迟 free 都会概率性死亡。
- `matchmaking`:空地址回退默认云大厅(原 127.0.0.1 必失败且超时极慢);大厅连接 8s 超时明确提示(UDP 静默丢包时 connection_failed 要等很久)。
- **房间列表进页自动拉取**(原必须手点「刷新」,不点列表区一片空白;连上大厅也自动刷新),昵称已随 room_list.names 展示;headless 探针实测对云大厅全链路 OK。
- **go_match/房间已满 的断开重连延迟到帧末**:这些事件在大厅 peer 的 `poll()` 调用栈内作为 RPC/通知到达,栈内立刻 `NetBus.stop()` 会把正在 poll 的 peer 引用清零、在自己的调用栈内被 free → 偶发原生段错误(对应实测「对手连入配对完成的一瞬间」闪退);`_do_go_match`/`_request_list.call_deferred` 已脱离 poll 栈。本地 PvP 房间冒烟(建房→加入→双方 go_match→claim→match_start)通过。
- `menu_autotest` sp 分支追加「回到主菜单」验证步(覆盖 safe_change_scene);截图 headless 下安全跳过(get_image() 返回 null 而非 get_texture())。
- shader `post_process.gdshader` 补 `hit_red` uniform(受击红闪,上次会话遗留未提交)。
- 删 `_apply_difficulty` 末尾不可达死代码(单人白屏回归残骸)。

### 段错误排查重大进展(2026-09-05 第二轮,待续)
**WIP 段错误现在 headless 可稳定复现**(此前"headless 不复现"结论是样本太少):GUI/HEADLESS 跑 `-- --autotest-sp` 或 `-- --autotest-level`,约 50~60% 概率段错误(退出码 139),崩在进图后 0~2 秒。二分排除结论:
- **无关**:敌人数量(0 只也崩)、难度、碰撞构建(`--diag-nocollide` 跳过 build_sim 仍崩)、PostProcess(跳过仍崩)、演示世界是否存在(`--diag-nodemo` 仍崩)、我的全部本轮改动(stash 基线同样崩)。
- **强相关**:直接启动 Level0 场景(不经菜单/切换)**0/9 从不崩**;只要经过"主菜单→change_scene→游戏"流程就概率崩。即触发条件 ≈ change_scene 切换 + 新游戏世界运行,但把菜单→游戏也改成手动接管(safe_change_scene)并未消除 → 崩点在引擎原生层更深处,非脚本可完全规避。
- **第二轮二分(诊断开关 --diag-*)**:敌人(0 只也崩)/碰撞构建/瓦片+水铺图/HUD/暂停层/后处理 全部排除(关掉任意一项崩溃率仍 ~50%);Sfx 禁用两批 1/6 与 7/10 抽样噪声无法区分,暂列排除。**游戏侧已无可关的灯 → 炸点在引擎原生层**,唯一正解 = 带符号调试引擎拿调用栈。
- 已试未果:菜单→游戏改走 safe_change_scene(仍 6/8 崩);敌人生成延一帧(无效,已回退)。
- **进行中**:本机(VS18 + Python3.14)从 Gitee 克隆 4.7.1-stable 源码到 `C:\Users\21559\godot-4.7.1-src`,用仓库 `cyancular_build_profile.gdbuild` 编 `target=template_debug debug_symbols=yes`(build_debug.bat;注意 cmd 批处理必须 CRLF、路径不能含中文);跑 `-- --autotest-sp` 复现 → 崩溃处理器(Windows StackWalker + PDB)应输出符号化调用栈。
- 用户实测补充:困难单人进入后「蓝屏无渲染」= 崩溃发生在建图 deferred flush 内、PostProcess 首次绘制之前(清屏色已设、世界还没画出来),与 headless 复现的崩点一致。

### 实验分支已完成(commit 528f4e9 起,exe 已重导出并实测)
- **大厅 UI 改版**:像素标题+按钮浮现动画;背景=`Level0.menu_demo` 地图奔跑演示(镜头左移,主角纯视觉借 Player.tscn SpriteFrames)。`Settings.old_ui=true` 切回老版。
- **设置系统**:`Settings` autoload(`user://settings.cfg` 持久化)+ `Scenes/settings_menu.tscn`(键鼠重映射/主音量/音效/滚轮切枪/老版UI);运行时建 SFX/Music 总线。
- **8bit 音效**:`Globals/sfx.gd` 程序合成(方波/噪声/滑音,零素材);播放节点延迟入树(`add_child.call_deferred` + `call_deferred("play")`,启动链里直接播会被拒)。
- **受击反馈**:每次受击小震+红闪(shader `hit_red`),大伤害原强震保留。
- **单人开局选项**:`RunOptions`(禁武器+难度=鸟密度 0.5/1/1.5);`WeaponComponent.set_enabled_slots` 是数字键/滚轮/服务器三端共用的禁用闸门。难度持久化在 `Settings.sp_difficulty`(选简单后每次开局都是简单,排查崩溃时注意)。
- **多人选项**:协议扩参拆到 `NetBusExt`(player_options/match_options/peer_hues);规则项(回合回满血/禁武器)以房主 role1 为准;视觉项本地即选即用;房间列表点击即加入。
- **fix 爆炸衰减倒挂**:内圈(≤40% 半径)免疫 LOS 掩护衰减;`Tests/explosion_falloff_probe.gd` 可验(未代跑)。
- **fix 多房间串线**:worker 端口改 30s 延迟归还;worker 踢掉串线连接且 `_on_peer_left` 只认本局双方。
- **chore 路径大小写统一**:所有 `res://scenes|globals|shaders|tests/` 引用改为真实目录大小写,根治"Class X hides a global script class"解析错误。
- **Esc 暂停菜单 / 主菜单实机演示 / 版本号(分支+提交序号)/ 版本信息面板**(a3aec8c);**NetBus 协议兼容修复**(55c39e7)。

### 换弹实验玩法(test-reload 分支)
- `Settings.reload_enabled`(默认开,设置页「换弹装填(实验性,仅单机)」可关;关闭=旧版无限弹)。**仅单机生效**(`WeaponBase.reload_active()` = 开关且非 pvp_mode;PvP 服务器权威、输入包无换弹事件,不同步)。
- `WeaponBase` 新增 `@export mag_size/reload_time` + `mag_ammo/is_reloading()/start_reload()`;fire() 开火闸:装填中不开火、空夹自动换弹、每发 -1。per-枪数值在 5 个 tscn:手枪 12/1.0s、步枪 30/1.8s、重狙 5/2.6s、霰弹 2/2.2s、榴弹 4/2.8s。
- 手动换弹 = **R 键**(站立时;倒地时 R 仍是重载场景,见 player._unhandled_input);换弹音效 `Sfx.play("reload")`(两段咔哒),完成播 "switch"。
- **换弹动画**:`WeaponBase._update_reload_pose()`(_process 末尾、后坐复位之后调)——换弹期间精灵枪口下压(RELOAD_TILT≈51°,sin 包络 0→1→0)+ 回拉下沉 + 中段机械微抖,结束/切枪自动复位;作用于精灵局部坐标,与根节点瞄准旋转/镜像不冲突。HUD 残弹下方有换弹进度条(`reload_progress()` 0→1,非换弹=-1 隐藏)。
- HUD 左下角:剪影 + 武器名 + 残弹「12/30」/「装填中…」(关换弹时残弹隐藏;剪影名称始终显示)。
- **武器白剪影**:`WeaponComponent.silhouette(slot)` 程序化生成(weapons.png 图集切片→全白保 alpha→3× 最近邻),静态缓存;单人/多人武器选择栏 CheckButton 图标 + HUD 剪影共用;武器显示名统一 `WeaponComponent.DISPLAY_NAMES`。

### 重要决策与约定(继续遵守)
- **分支纪律(2026-09-09 用户明确要求)**:带版本名的分支(`KH_vX_Y_Z`,如 KH_v1_1_1/KH_v1_1_2)是**发布锚点,永久保留,任何分支清理都不得删除**;清理无用分支只删非版本名的实验分支。最新版本分支 = 当前主开发线(现为 KH_v1_1_2,已推 origin)。
- **环面纪律**:实体间方向/距离/插值一律 `MazeGenerator.toroidal_*`,禁止裸坐标相减。
- **单机/PvP 双路径分叉点**:`Level0.pvp_mode`、`CombatComponent.pvp_arena`、`BulletBase.apply_damage`、`player.server_rendered`,新增实验开关走 `Settings`/`RunOptions`/`PvpSession`,别再加全局散变量。
- **参数分层**:共享=`GameParameters`;玩家=`PlayerParams`;敌人=`EnemyParams` 嵌套类;武器=tscn @export;瓦片=`tile_defs.json`;持久偏好=`Settings`。
- **MatchHost._init 里不能碰玩家 @onready**(combat/weapons 未就绪),进树后(_ready)才能调。
- **PvPvE 中立鸟已实现但关闭**(`match_host.gd` `ENABLE_BIRDS=false`)。
- `GameParameters.enemy_count/enemy_spawn_min_dist`:前者已无引用;后者被单机难度补采复用。
- **段错误 WIP 认知**:仅 GUI、headless 不复现;概率曾观察"随敌机数上升"但与难度的对应关系被持久化设置污染,别按难度归因;疑似与打开中的 Godot 编辑器并发访问 .godot 缓存有关——**复测时让用户关掉编辑器**。

### 已知文档漂移
**结构性漂移(武器数量/C2 状态/DevTools 分支归属/小地图等件的归属)已校准并汇总在 `docs/ARCHITECTURE.md` §6,新增文件请同步登记到该文档。** 下列为**代码注释级**遗留:
1. 树叶/树干 hp:代码 `tile_defs.json` 为 8/30(旧文档写 20/80)。
2. 加敌人注册表在 `editor/enemies.json`(旧文档写 TYPES 加一行)。
3. `player.gd`/`enemy_base.gd` 防水注释写 0.5s,实际 `water_drain_interval=1.0s`。
4. 黑鸟瞬移距离实为 2~6 格(注释写 3~8)。

### 待完成/下一步
- **用户实测(重导出的新 exe,建议关 Godot 编辑器)**:版本信息面板显示新提交序号;单人简单/普通各连开 ≥5 次不闪退;死亡→Esc→回主菜单、按 R 重载不卡退;多人建房拿到房间号;PvP 各选项两端联机验证 match_options/peer_hues。
- 段错误遗留:进图方向(菜单→游戏)的约 50% headless 段错误未根治(见「段错误排查重大进展」)——用户 GUI 若仍偶发闪退属同一问题,下次专攻抓原生调用栈;回菜单/重载方向已由 safe_change_scene 治理(若 GUI 仍卡退,把 `_retired` 改为永不释放)。
- 跑冒烟(用户自己跑):`Tests/explosion_falloff_probe.gd`、`enemy_logic_smoke.gd`、PvP 两个 .sh(注意 `claim_role` 扩参后冒烟脚本若直接调 RPC 需同步签名)。
- 候选迭代:菜单背景主角遇墙的视觉处理、BGM(Music 总线已留)、键位组合键、小地图 destroyed 砖实时刷新。

### 大乱斗 5 机器人试玩(RoyaleServer-debug 分支)
- 试玩工具:`Tests/royale_bot.tscn`(--role=create|join --index=N)+ `royale_bot_helper.gd`(存活场景切换,挂 BotInputSource:随机走/跳/周期开火/旋转瞄准),1 大厅 + 1 worker + 5 客户端整局无脚本错误;击倒→自动复活链路实战验证。
- 试玩中发现并已修:worker 拉起分支缺 template_debug 支持(调试引擎下 worker 秒退,`_spawn_worker/_spawn_royale_worker` 已补 `OS.has_feature("template_debug")` 分支)。
- 已知非致命:worker 开局瞬间向未完成转连的 peer 广播会刷 "Unable to send packet channel 0"(ENet 噪音,不影响对局);机器人互射命中较低,击杀计分边沿仍靠探针覆盖。
- 运行限制:多会话并存时避免用 `taskkill //IM Godot*` 清场(会互杀),按端口/PID 清理。

### 多人模式 AI 补位(KH-Royale-reload-merge-ai 分支,实验性)
- `Globals/ai_input_source.gd`(AIInputSource,AI 的"手柄")+ `server/ai_player.gd`(AINavigator,每物理帧写输入:锁定最近存活对手→瞄准加抖动→有视线 620px 内节奏点射;远追/近拉/中距横移,卡墙跳)。服务端权威视角知道全场位置,与真人输入包走同一消费路径;COUNTDOWN/MATCH_OVER 待机。
- `MatchHost._init` 新增 ai_roles 参数:这些 role 同样建 Player.tscn(输入源换 AIInputSource+挂导航器),进 players 字典 → 快照/命中/计分/复活全自动;不在 peer_by_role(无网络 peer,快照只发给真人)。
- server_main:`--ai-roles 2,3` 解析;开局条件按"人类 claim 数 + AI 数 ≥ 2"判定;peer_info/排行榜给 AI 注入昵称「电脑玩家」。
- room_manager:`ai_duel`(1v1 房主改与 AI 对战,NetBusExt.ai_duel_requested)、`royale_start_ai`(大乱斗 AI 补到 max_players,NetBusExt.royale_start_ai_requested);`_spawn_worker/_spawn_royale_worker` 透传 `--ai-roles`。
- 客户端零改动:AI 对手靠快照副本自然显示(1v1 副本/大乱斗懒建副本)。1v1 与大乱斗等待 UI 各加「AI 补位开局(实验性)」按钮(仅自建服有效,云服不支持)。
- 验证:1v1 AI 对战(980 快照/20s,AI 移动 ✓);大乱斗 1 真人+7 AI 整局(快照 8 人,真人移动 ✓,零脚本错误)。

### 打击反馈三件套(KH-hit-feedback 分支)
- `Scenes/Effects/combat_feedback.gd`(`class_name CombatFeedback extends CanvasLayer`,layer 131 盖在 PvpHud/RoyaleHud 之上):**命中 X 标记**(内含 HitMarker 自绘控件:四段斜线白芯深描边,0.22s 缺口外扩+淡出)+ **「击杀 XXX」像素播报**(击杀者屏幕中央,金黄字+描边,pop 回落 + 0.9s 停留 + 0.35s 淡出,伴随 `Sfx.play("kill")`)。静态入口 `spawn/hit_marker/kill`,`current` 为 null(headless 服务器/主菜单)时全部静默空转,调用方无需判空。
- **单机接入**:`bullet_base._register_player_hit`(直击两分支+榴弹 `_direct_hit`)写受害者 `last_damager` meta + `CombatFeedback.hit_marker()`;`Explosion.apply_aoe` 敌人分支同;`EnemyBase._begin_death` 改走 `CombatFeedback.notify_enemy_killed(self)`——**只有玩家造成的死亡才播报**(读 meta 归因,溺水等环境死不再乱播 kill 音效);敌人中文名对照 `CombatFeedback.ENEMY_NAMES`(键=场景名去 Enemy 前缀)。挂载点:Level0 单机路径(menu_demo/pvp 早退不挂)。
- **联机接入**:MatchHost `_on_bullet_hit` 裁决命中后经 **NetBusExt 新 RPC `hit_confirm(shooter_role, victim_role)` 只发射手本人**(原 NetBus 未动;爆炸 AoE 不发——伤害方不明确,击杀仍有 kill_event);pvp_client/royale_game 消费:shooter==自己 → X 标记;`local_kill_event` killer==自己 → 「击杀 <名字>」+音效(1v1 名字来自 peer_info 存的 `_names`,大乱斗同)。
- **受击反馈增强**(原"每次受击小震+红闪"太弱):红闪强度下限 0.35→0.5、shader 混合 0.45→0.6、衰减 5.0→4.0(可感知 ~0.25s);小伤害震屏 4.0/0.12s→6.0/0.15s;大伤害强震不变。
- 验证:`Tests/feedback_probe.tscn`(场景模式,代理可跑)ALL-OK——无实例空转/X 标记显隐/击杀播报动画/归因(玩家杀才播、环境死与非玩家杀不播)/kill 音效流。注意探针时序:`process_frame` 信号先于节点 `_process`,动画断言要多等一帧。
