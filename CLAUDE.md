# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概览

Godot 4.7(标准版,非 mono)做的 2D 横版(平台跳跃)射击 demo「The Cyancular Ruins」。1920×1440 视口、`rendering/mobile`。核心特色:

- **环面世界**:地图左右/上下无缝回绕,敌人/子弹/镜头跨接缝连续。
- 单关卡(Level0)从 ASCII 地图文件加载,无运行时随机生成(生成逻辑已注释)。

## 常用命令

Godot 不在 PATH,用绝对路径。**4.7.1 标准编辑器**是当前主用版本(详见 `RELEASE.md`;4.4.1 mono 已弃用,仅在需要兼容旧脚本时用其 console 版)。

```bash
# 冒烟测试(唯一的"测试",SceneTree 脚本;成功打印 SMOKE OK 退出 0)
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s res://tests/enemy_logic_smoke.gd

# headless 启动游戏 90 帧后退出(看脚本报错)
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . --quit-after 90

# PvP 服务端(headless,监听 7777;保持终端开着=运行中)。更省事:双击仓库根 start_server.bat。
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . res://server/server_main.tscn

# 导出单 exe 发布版
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64.exe" --headless --path . --export-release "Windows Desktop" "The Cyancular Ruins.exe"
```

约定:**测试由用户自己跑,不要代跑**。发布/裁剪模板细节见 `RELEASE.md`(单 exe 靠自定义裁剪模板,勿用 UPX,保留 webp 模块)。模板重编只在**改裁剪 profile(增删类/模块)**时需要,单次≈10~15 分钟近全量(RELEASE.md §2.4);平时改 GDScript 只需重导出,别去重编模板。

## 架构

### 环面世界与地图
- 地图:ASCII 文本 **`.cyrm`**(如 `maps/demo.cyrm`)。**v3 格式**(带 `# cyrm-v3` 标记):125×75 格 × 64px 瓦片 = 8000×4800 世界像素;每格 **4 字符 = [纹理 3 位 0xx][形状hex]**(纹理 `000`=空气/`001`-`022`=1-22,structure.png 两行各 10 块 + 第3行两块水;形状 hex `0`-`F` = 2×2 子格掩码,15=全砖,0=空气占位)。纹理用 3 位数字、不用字母。**旧格式**(250×150 单字符,无标记)加载时自动 2×2 转换(packed 值 + spawn 坐标 ÷2)。`#` 开头的行是注释(含出生点 `# player <col> <row>`;`# player2 <col> <row>` 为双人第二出生点,PvP 用)。加载:`MazeGenerator.map_file_path()` 优先随机取 exe 旁 `.cyrm`,否则随机取 `maps/*.cyrm`(**同目录多份随机读一份**,会话内固定);`maps/*.cyrm` 已在导出 include_filter 里。编辑器输出 `.cyrm`、可导入 `.cyrm`/`.txt`。
- `MazeGenerator`(core/maze_generator.gd,`RefCounted`,非 autoload)是地图与环面核心:
  - 格值 = packed `texture*16 + shape`(0-335,`pack/texture_of/shape_of`);`EMPTY=0`、`SOLID=31`(纹理1 全砖);挡路判定走 `TileDefs.is_blocked`(非 0 且 type=wall);
  - 读图:`load_map_file()` / `map_size()`(v3 与旧格式都返回转换后 125×75;行宽不一致的抬头行会被跳过);`convert_old_grid()` / `serialize_v3_grid()` 是单一转换源(旧 v2 字母版地图用 `tests/convert_map.gd` 转 v3);
  - 环面数学:`toroidal_dist`(格级)、`toroidal_delta_px`(像素最短向量)、`anchor_to_nearest`(实体锚到玩家最近副本)、`wrap_to_range`(取模回中间副本);
  - 寻路:`bfs_path` / `bfs_path_nearest` / `astar_path_nearest` / `has_line_of_sight`(Bresenham)。`current_grid` 静态变量由 Level0 赋值,空网格一律无路。
- **关键区分**:玩家每帧 `wrap_to_range`(只留中间副本);敌人/子弹用 `anchor_to_nearest`(锚定到玩家附近的副本)。墙体按 3×3 铺贴,相机跨接缝才能看到另一侧——实体若取模回 `[0,MAP)` 会在接缝处"消失"。

### 参数体系(重要约定)
- **autoload 四个**(project.godot):`GameParameters`(core/game_parameters.gd):gravity0、TILE_SIZE=64、地图像素尺寸、敌人数/出生距离。`_ready()` 里从 `MazeGenerator.map_size()` 回写 `MAP_WIDTH/HEIGHT`;`NetBus`(core/net_bus.gd,PvP 网络 RPC 唯一收口):服务器/客户端共用 `/root/NetBus` 跨场景常驻,RPC 才能路由;建房/加入/断线经转交信号给 RoomManager;`NetBusExt`(core/net_bus_ext.gd,旁路扩展协议:对局选项/角色色/`hit_confirm`/大乱斗房 RPC。**与原版 NetBus 刻意分离**——原 NetBus 保持与原版服务端逐字节一致,改它的方法表会让与之的 RPC 全部失联;对原版 worker 本节点不存在 → 扩展 RPC 静默丢弃、优雅降级。★ 激光 `beam_fired` **不走这里**:它是 KH 遗留重复,收上去静默 no-op);`Settings`(core/settings.gd,持久化设置:音量/键位重映射/滚轮切枪/血条显示/换弹开关,落盘 `user://settings.cfg`)。
- 玩家/敌人参数**不是** autoload:`PlayerParams`、`EnemyParams` 是 `RefCounted` + `const`,静态访问(如 `EnemyParams.FlyBird.wake_radius`)。加新敌人 = 在 `EnemyParams` 加一个嵌套类。

### 敌人(scenes/enemies/)
继承链 `EnemyBase → EnemyFlyBase → EnemyFlyBird`;JumpBird 直接继承 `EnemyBase`:
- `EnemyBase`(CharacterBody2D):`hp/contact_damage/knockback_strength/knock_decay_rate` 导出参数;统一状态机 `state`(int,各子类自带 `enum State`);子类覆写 `_ai(delta)`/`_anim_update()`;受击白闪+击退在 `_apply_hit`(枪击击退叠加原速度;爆炸 `set_velocity=true` 设独立 `knock_velocity` 向量,每帧叠加 `move_and_slide` 后指数衰减 `knock_decay_rate`,不覆盖移动速度);**受击/死亡白闪统一在基类**:`_hit_flash_time`(0.1s)与 `_begin_death()`(死亡白闪 `shared.death_flash_time`=0.5s 后销毁)统一计时,渲染走 `_flash_update()`(默认 modulate 纯白;黑鸟因 silhouette shader 覆写 COLOR 而 modulate 失效,覆写本方法改走 shader 参数);`_set_facing()` 锁转向频率(两次翻转至少间隔 `shared.turn_min_interval`=0.5s,防来回抖);**死亡物理与生前完全一致**——尸体继续走同一套 `_physics_process`(重力/摩擦/击退衰减/碰撞),只是 AI 不行动;尸体被后续命中只吃击退不吃伤(`hurt` 的 `is_dead` 分支走 `_apply_knock_only`),基础速度也按 `knock_decay_rate` 指数衰减(滑行逐渐停住);每帧 `move_and_slide()` 后 `_wrap()`;接触伤害走 ContactArea + 环面距离兜底。入 `enemies` 组。
- `EnemyFlyBase`:飞行寻路。A* 按**鸟自身飞行碰撞箱 + 场上实体碰撞箱**判可走(`_bird_can_pass`);空路径直线兜底;被悬挑墙压到(死区)时水平逃逸;站/飞碰撞箱切换(`_apply_flight_collision`)。寻路参数耦合 `EnemyParams.FlyBird`(当前唯一飞行敌人,接受该耦合)。
- `EnemyFlyBird`:状态机 SLEEP/TAKE_OFF/FLY/SHOOT/CHARGE/RETURN。平抛投弹(玩家速度预测);HP<25% 单向切 CHARGE 冲撞(穿透无敌帧、撞后自毁);死亡白闪后销毁(物理与生前一致,保留碰撞);返程回家落地入睡。
- `EnemyJumpBird`:近战跳跃怪(跳/后跳/扑击);死亡物理与生前一致、保留碰撞(与飞鸟统一,不再清碰撞箱)。
- `EnemyBlackBird`:绕背瞬移刺客(睡眠→随机游走→周期性判定玩家另一侧、距玩家 2~4 格(随机)的地板格落点(地板格 + LOS)→起飞上跳→落地播 disappear→白闪→传送→闪后空中播 appear→落地→带跳跃冲锋打 6 伤(穿透无敌帧)→大后跳(命中/未命中都)→回游走,玩家远离入睡);死亡白闪后销毁。数值在 `EnemyParams.BlackBird`。
- **加新敌人** = 一个 .tscn + `EnemySpawner.TYPES` 加一行(键名 → 场景路径),spawner 随机取"地板格"(EMPTY 且正下方 SOLID)布点。

### 武器与子弹(scenes/weapons/)
- `WeaponBase`(Node2D):数值全是 `@export`(fire_cooldown、bullet_speed/range/size/color、pellet_count/spread、damage/impact、recoil_push/kick、cam_shake、move/jump_penalty、heavy_aim 激光、pitch_clamp_deg)。`fire()` 按 pellet_count 从 `bullet_scene`(@export,默认 bullet.tscn)出弹并注入 `bullet_gravity`;`apply_hit()` 调敌人 `hurt()`;heavy_aim 按住预瞄、松开发射;`preview_arc=true` 时预瞄画**抛物线弧线 + 末端爆点标记**(参考,用 `preview_time`,与子弹 fuse 解耦)。**弹道方向与走路朝向解耦**:`_auto_aim` 用鼠标推导瞄准侧(近垂直瞄沿用上次明确侧,`_aim_facing`/`_current_aim_facing`),`fire()` 开火瞬间先 `_auto_aim()` 再出弹——所有开火路径(直接/缓冲/连发/重武器)都取本帧鼠标方向,不再读被走路输入覆盖的 `get_facing()`(否则后退时朝反方向开枪,`clamp_pitch` 把子弹折到走路侧)。
- 现有武器:手枪/步枪/m82a1(重狙,heavy_aim)/s686(霰弹 8 丸 ±5°、射程700)/grenade_launcher(第5槽,重型)/laser_gun(第6槽,中型即时光束)。
- **即时光束武器(`LaserWeaponBase`,scenes/weapons/laser_weapon_base.gd,extends WeaponBase)**:不开物理子弹——`WeaponBase.fire()` 内衬的出弹循环抽成虚钩 `_spawn_projectiles(base_dir)`,本基类整体接管为"开火瞬间几何追踪一束 + 一次性结算"。**三个可覆写缝**(后续其他行为模式的激光据此扩展,见下方 `laser_gun`):缝1 光束几何 `_emit_beam(origin,dir)`(基类默认=直线 hitscan,`BeamTrace.trace(...,0)` 第一面墙即吸收/到射程);缝2 命中结算 `_apply_beam_damage`(默认=`_damage_path_targets` 扫路径 + `_damage_tiles` 磨可破坏砖;持续/灼烧型覆写);缝3 视觉 `_spawn_beam_visual`/`_beam_style`(默认=单发瞬光;视觉节点统一走 **`core/laser_visual.gd`** 静态工具 `spawn_beam`/`spawn_muzzle_orb`,本地开火与 PvP 远端共用同一"光束语言")。现 **`laser_gun`**(第6槽,中型)是反射参考子类:只覆写 `_emit_beam`(`max_bounces` 次镜面反射,tscn 当前 5),开火编排/伤害/磨砖/PvP 全走基类。核心几何 `core/beam_trace.gd`(纯静态、preload 引用、不引 autoload、可 -s 空跑):DDA 走 32px 子格(64px 格→2×2 形状掩码,语义同 CollisionBuilder.build_sub,只认 type=wall → 光穿水/梯),遇墙翻对应轴反射、超反射额度或累计 ≥ bullet_range(2000)即消失,返回世界折线点集 + 碰墙 64px 格(可破坏砖) + 碰面点。**命中判据**:折线线段与目标**实际身体 AABB**(启用中的碰撞多边形扫世界框,含 2.5x 缩放)外扩 `beam_half_width×HIT_MULT(1.75)` 后 `_segment_rect_hit`(Liang-Barsky)相交即中,每段各结算一次(反射折返扫到同一目标可叠加);敌人 `hurt(damage,dir,impact)`、玩家 `take_hit`(激光可被无敌帧挡);环面把目标 AABB 中心锚到段起点近副本量距。**PvP**:`_authoritative()` 与出弹同 gate(`not Level0.pvp_mode`,客户端视觉副本不裁决);权威开火记入 `pending_beam_report` → 服务器 MatchHost 每帧轮询 `collect_pending_beam_report()`(读到即清)经 `beam_fired` 广播给**非射手端**画光束视觉副本(射手自己客户端已本地预测画自己的光束,再收会双光束),见 §网络。`laser_color` 复用为光束色,`laser_beam.tscn`(双层 Line2D:Glow 光晕 + Core 亮芯,round 关节)淡出自毁。
- 子弹:玩家 `BulletBase`(伤害由 WeaponBase 管;`fire()` 注入 `hit_damage/hit_impact`,切枪后旧武器已 free 时子弹自带参数兜底直接结算);**爆炸弹**(如 `grenade_bullet.tscn`)在 BulletBase 加 @export `explodes/direct_hit_damage/fuse_time/explosion_radius/damage/knockback/visual` —— `explodes=true` 时撞墙/命中敌人一律反弹(衰减0.6),首次碰撞后 `fuse_time`(撞墙)/`hit_fuse_time`(命中敌人)引信爆炸(命中敌人另加 10 直接伤立即结算)、超射程兜底爆炸。AoE 判定在 `core/explosion.gd`(`Explosion.apply_aoe`:内圈 40% 满伤+二次方平缓衰减/LOS遮挡(墙后保留 75%,走纯函数 `Explosion.cover_multiplier(d, radius, blocked)`;**内圈免疫遮挡**——否则贴脸目标被墙棱角判"无视线"扣 25%,出现"爆心比开阔边缘伤害低"的倒挂;不变量:任意距离伤害随距离不增,`tests/explosion_falloff_probe` 钉住)/友伤/击退独立向量纯径向——敌人走 `set_velocity=true`、玩家经 `take_hit` 传击退,爆炸穿透无敌帧 + 爆心越近相机震得越猛),爆炸特效 = `explosion.tscn`(AnimatedSprite2D 多帧,`_explode` 按 `explosion_radius/帧宽` 缩放,`explosion_fx.gd` 播完自毁)。敌人子弹 `enemy_bullet.gd` 是带重力抛物线弹(`launch()`)。
- 碰撞层:子弹 mask=5(地形+敌人),榴弹不含玩家 → 友伤只来自爆炸。

### 玩家(scenes/player/player.gd)
CharacterBody2D:指数缓动移动手感、土狼时间/跳跃缓冲/可变高度、冲刺(沿用最近移动方向;0.4s,空中冲刺重力×`charge_air_gravity_mult`=0.35,跳跃/撞水平墙可提前打断、收尾平滑)、下蹲(**逐帧推导**:在地面且按住 S 才蹲,非 just_pressed/released 边沿——空中松开不卡蹲;蹲态可蹲走 `crouch_walk_speed`≈245;空中按 S=下冲)、姿态碰撞箱(Pose→CollisionPolygon2D,运行时只启用当前姿态的箱子)、iframes/击退(爆炸=独立 `knock_velocity` 向量,衰减率 `player_knock_decay_rate`)/倒地(倒地**不取消物理**,仍受重力/击退,只是不吃输入;**单机**按 R 调 `Level0.restart_single()`——**原地复位,不是场景重载**:可破坏砖/瓦片/碰撞整层还原为建图基线 + 清子弹/敌人后重刷 + 玩家满血满氧回出生点;旧实现走场景重载(第二份完整世界 + 退役拆旧世界),在引擎原生层偶发段错误(表象:重启后蓝屏/地图未加载),故从机制上绕开「新建/拆毁大世界」。PvP/大乱斗**不走这条**——服务器权威管复活)。移动/跳跃/冲刺/镜头/战斗数值全在 `PlayerParams`。**加新武器** = 一个继承 WeaponBase 的 .tscn + `weapon_component.gd` 的 `WEAPONS` 注册表加一行(键对应输入动作;project.godot 已注册 1~0,第5槽=榴弹发射器)。
- **结构(轻量拆分)**:根 `player.gd` 只留移动/姿态/物理帧编排;攀爬(梯/锁链)、战斗(生命/无敌/击退/倒地)、武器(注册表/换枪/后坐)分别抽成 `ClimbComponent`/`CombatComponent`/`WeaponComponent`(Player.tscn 子节点)。组件**不写自己的 `_physics_process`**,由根每帧显式按顺序调用(`climb.update → 移动 → combat.apply_knock → move_and_slide`),避免调度乱序。跨组件状态经根传参;根公开接口 `take_hit/get_facing/set_facing/is_downed/apply_recoil`、信号 `hp_changed`、只读 `hp/max_hp` 原样保留(HUD/敌人/武器零改动)。契约守卫 `tests/player_contract_smoke.gd`(源码级)保接口不漂。
- **输入可注入**:根读输入走 `core/input_source.gd` 的 `InputSource`(默认委托真实 Input,行为不变;PvP 服务器可注入网络输入驱动远端玩家);瞄准有 `get_aim_dir_override()` 覆盖钩子(本地返回 ZERO → 武器落回鼠标,网络返回注入方向)。

### 渲染管线(Level0.tscn)
根节点把未处理输入手动转发进 `WorldViewport`(SubViewport);世界(墙体/玩家/敌人)渲染进 SubViewport,`PostProcess`(post_process.gd)做像素缩放裁切 + 倒地暗角。相机 `camera_2d.gd` 带前瞻/死区。注意:冒烟测试把武器挂到根 Window 而非 SubViewport(见 weapon_base 的鼠标坐标注释)。
- **墙体 64px 砖块渲染**:`_create_wall_tileset()` 运行时把 structure.png 两行 20 块 32px 砖最近邻 2× 放大成 64px,对每(纹理×形状)生成 16×20 atlas(空气象限透明),TileSet tile_size=64,`_paint_maze` 按 `Vector2i(shape, texture-1)` 铺 125×75 ×3×3 环面。
- **碰撞**:`core/collision_builder.gd`(`class_name CollisionBuilder`,静态可测)把形状掩码展开成 250×150 的 32px 子格(每 64px 格 → 2×2),贪心合并矩形(ts=32)后按 **9 环面副本偏移**实例化(每块矩形 ×9,共享同一 shape)。**永久墙(不可破坏)建一个整图节点、建一次不动;可破坏层按分块存节点**(块边长 12 格 ≈ √地图边长,块内一次贪心 + 9 副本),摧毁时只重建所在块 → 重建成本 O(块面积)。**只有 type=wall 产生碰撞**,通道(梯子/锁链)可走/可爬。
- **世界构建**:`core/world_builder.gd`(`class_name WorldBuilder`,静态):`load_grid()`(地图→current_grid/TileDefs/地图像素尺寸)、`build_sim(parent, grid)`(碰撞:永久墙+可破坏分块+攀爬基座条)。单人 Level0 与 PvP 客户端/服务器共用。

### 砖块属性与破坏(core/tile_defs.json)
- **属性表** `core/tile_defs.json` 是单一来源:每块 name/type(墙/通道/液体/气体)/hp/explosion_decay/bullet_destroyable/explosion_destroyable/elastic/climb_speed/friction。编辑器副本 `level_editor/tile_defs.js` 由 `node level_editor/sync-tiles.js` 生成(file:// 下可靠)。
- 纹理 1-10 墙(hp1,不可破坏);11 梯子、12-14 锁链上中下 = 通道(climb_speed 1.6× 最快);15-18 树叶(墙,hp20,子弹/爆炸可破,弹性弱弹玩家);19-20 树干竖/横(墙,hp80,爆炸可破);21 水、22 水面 = 液体(无碰撞,可游)。爆炸衰减统一 0.75(水 0.25)、摩擦 1.0(现状不变)。
- 加载:`TileDefs.load_defs()`(level_0._ready);挡路 = `TileDefs.is_blocked`(非 0 且 type=wall),寻路/LOS/碰撞共用。
- **破坏**:`TileDefs.damage_tile(cell, dmg, "bullet"/"explosion")` → hp≤0 变空气(改 `MazeGenerator.current_grid` + `Level0.on_tile_destroyed` 清 3×3 瓦片 + 持久可破坏子格 2×2,标记所在分块下帧重建)。子弹撞树叶扣血;爆炸对树叶/树干按距离衰减×0.75 扣血。
- **攀爬**:玩家中心(或脚底)在通道格(梯子/锁链)「**刚按上**」主动攀附(不受重力):上爬 ×`tile.climb_speed`(梯 1.6/锁链 2.0),下降 ×`tile.climb_descent_speed`(梯 2.0);**锁链无下降倍率 → 按下自由落体**(解除攀附交给重力,不被空中抓回);松开挂住不坠落;**到顶 = 脚底进入梯子上方一格**(以脚底为参考格),再按上 = 跳离梯子;进入靠「刚按下上」而非按住 → 跳离后按着上也抓不回;攀附空闲可水平走离梯子;**仅锁链顶/底基座有薄碰撞条**(`CollisionBuilder.build_climb_ledges`,全宽 64×6px;梯顶不加,避免挡爬升)。上爬与梯子下行再整体 × `PlayerParams.climb_vertical_mult`(1.2;锁链下行=自由落体不受影响);**身在梯/链格上不能空中下冲**(`climb.is_over_climb_tile()`:中心或脚底在通道格即判,按↓只能下移/下落,不能 charge_down 快速下坠穿过梯/链)。
- **弹性**:碰树叶(elastic)被弱弹(PlayerParams.elastic_bounce=150)。

### 水
- **瓦片**:纹理 21 水 / 22 水面,`type=liquid`(无碰撞,`is_blocked`=false)。地图只画 21;水面(22)由 `Level0._paint_water` 自动派生(该格上方非 liquid → 水面层)。`WaterLayer`(水体)与 `WaterSurfaceLayer`(水面)两个 TileMapLayer;**水面起伏**由 `water_surface.gdshader` 做逐格正弦上下拉伸(锚底无缝、相位逐格错开,`amp/speed` 沿用 `GameParameters.water_sway_amp/speed`),水体层不挂 shader(水不流动)。
- **`Water` 助手**(core/water.gd,静态,不引 autoload,-s 可测):`is_in_water` / `surface_y_at`(所在列向上扫到最顶液体格的顶边) / `submerged`(中心低于水面线=没顶) / `feet_offset` / `water_mult`(爆炸×水格 decay) / `bullet_drag_factor`(子弹阻力系数)。约定:脚底(中心+半身)在水格 = 在水中。
- **主角**(`scenes/player/swim_component.gd`):水中跳过攀爬/重力/跳跃/下蹲/冲刺;左右=水平游(×`player_swim_speed`),按上=上浮(`player_swim_up`)、不按=下沉(`player_swim_down`);不做水面悬停/浮力弹簧——出水(脚底离开水格)由 `in_water` 判回 false 自动恢复普通物理(重力)。水下扣血未做。**呼吸(氧气)按「大部分没入」扣**:判定参考线比中心低 `PlayerParams.water_breath_line_offset`(10px,≈胸口下沿)——水面到胸口(约 2/3 没入、头能露出)就开始扣,要浮到水面低于此线才回气(比原"中心没入"更早扣、更难回气;可调)。
- **敌人**(`EnemyBase._apply_water`):落水浮力回水面;水平朝 `_water_swim_dir()` 游(JumpBird/BlackBird 覆写为朝玩家,基类=漂着);**溺水**:没顶累计,`drown_delay`(5s)后每 `drown_interval`(1s)扣 `drown_damage`(5),浮在水面不算。FlyBird 寻路把水当障碍(`_bird_can_pass` 遇 liquid 不可走),但正下方是水仍可飞越。
- **爆炸衰减**:目标所在格是水 → 爆炸伤害/击退 × 该水格 `explosion_decay`(0.25,`Water.water_mult`)。LOS 遮挡 75% 不变(仅墙后掩体;梯/链是 passage 不挡也不减,玩家站梯/链上吃爆炸 = 满伤,与空气一致)。
- **子弹阻力**:子弹在水里 `velocity_vec *= exp(-water_bullet_drag·Δt)`(`Water.bullet_drag_factor`),玩家 + 敌人子弹共用。
- **水粒子**(`scenes/effects/water_fx.gd`,运行期挂主角 + 敌人):水中**移动**才喷;中心贴水面 → 溅水花,没入深 → 上浮气泡。

### 碰撞层(按位)
层1=地形、层2=玩家、层3=敌人。玩家/玩家子弹 mask=5(1+3);敌人占层 3(值4)、mask 侦测玩家。

### 编辑器工具
`editor/structure-editor.html` + `editor/smoke.js` 是独立浏览器地图编辑器(大图缩放/画笔),与 Godot 引擎无关。编辑 125×75 网格,**砖块纹理调色板(0-22)+ 2×2 砖形面板**(点四象限翻转或选预设 1/4/半/3/4/全砖);导入旧格式自动 2×2 转换,导出写 v3(`# cyrm-v3` + 每格 4 字符 [纹理 3 位 0xx][形状hex])。工具栏含 画笔/矩形/油漆桶/橡皮/选框/直线(直线跟随画笔大小);选框支持框选后整体移动、Del/Backspace 删除、油漆桶点在选区内=填整个选区(点外清选区+正常连通填充)、Esc 取消。`node editor/smoke.js` 跑 Core 测试。

### 网络与 PvP(阶段 1 + 2 + 4:匹配进图 + 对局互通 + 回合制)
- 服务器:`server/server_main.tscn` 入口(headless)。**双模式**:无参=大厅(默认 7777),`--worker --port P`=对局 worker。**一服多局**:大厅 `server/room_manager.gd`(`RoomManager`)只做建房/配对(房间注册表,2 人就绪)→ 给每局拉起一个独立 worker 子进程(`OS.create_process`,同 exe `--headless --worker --port P`;开发=editor 带 `--path`+场景,导出 exe 靠 `main_scene.dedicated_server`)→ 发 `go_match(role,port)` 让两端转连。**worker 内跑 `server/server_main.gd`(worker 分支)**:独占 UDP 端口,等两客户端 `claim_role` 收齐 role1/2 → `RoomManager.start_match_on`(static:重算地图尺寸、给两端 `match_start`、建 `server/match_host.gd`)→ `MatchHost` 权威对局;任一方离开 → 拆局退出释放端口。各局=独立进程 → **内存隔离**,共享全局(current_grid/TileDefs)不跨局互踩。端口分配用「唯一递增 + 占用集合」(`_pick_worker_port`,基准 7800)——**不要**在本进程 bind 探测空闲(worker 是独立进程,大厅探测看不到别的进程已占端口,并发会把同端口发给两个 worker)。大厅在玩家转连后断开即关房归还端口。
- **`MatchHost`(每房间一个)**:建世界(WorldBuilder 只碰撞不渲染)+ 两个 `Player.tscn` 实例注入 `NetworkInputSource` 权威模拟;**每物理 tick 每 role 恰好消费 1 个 FIFO 输入包**(按 seq 序,1:1 同序 = C2 rollback 锚点;队列空=缺包沿用上一包 held)并回带 `ack_seq`、60Hz 广播快照(带 `tick` 序 + `ack_seq` + `c2` 权威整态 `capture_state()`)、裁决子弹命中并广播 `bullet_spawn`/`hit_event`;**爆炸弹(榴弹)不走玩家半径补刀**(子弹碰撞掩码不含玩家层、伤全靠落地引信爆炸 AoE——若按普通弹半径补刀结算+销毁会吞掉引信致无爆炸,故 `_adjudicate_bullets` 对 `explodes` 弹直接跳过);即时光束武器(激光)权威开火经 `_broadcast_pending_beams()`(紧挨 `_adjudicate_bullets`)轮询各角色当前武器的 `collect_pending_beam_report()` → `beam_fired` 广播给**非射手端**(射手自己客户端已本地预测画自己的光束)。开局 pin PvP 地图后要调 `GameParameters.refresh_map_size()` 重算世界尺寸(_ready 启动时算的是随机 demo 图,工厂图 9600 宽不同,不重算则环面回绕按错边界出现空气墙)。**回合制**:`_match_round_tick` 状态机 COUNTDOWN→PLAYING→ROUND_OVER→MATCH_OVER;**击杀定义:对方死亡都算**——每物理帧倒地转换检测(`is_downed` 边沿)不分死因(枪杀/爆炸/溺水/自伤/无射手)一律给对方 +1(弃用旧 pvp_killer 射手归因);局内死亡 2s 复活(`_respawn_player`:死者回本方出生点、满血/防水、武器回 1);**每次击杀后活着的胜方也立刻回本方出生点但保留当前血量、不回血**(`_reset_survivor`,防复活点连杀);每局先到 5 击杀赢、三局两胜、局间 `_side_swap` 换边。**换局纪律**:进新局前 `_reset_world_and_clear_dynamics()` 把可破坏砖/碰撞整层还原为建局基线(`_base_grid` 深拷贝)+ 清光场上子弹(`bullet` 组)+ 重置 `_seen_bullets`;客户端收到新一轮 COUNTDOWN 同刻 `Level0.reset_destructibles()`(用 `_pristine_grid` 重铺)+ 清本地视觉子弹 → 两端每局从同一基线出发,无幽灵墙/跨局残留。**COUNTDOWN 3 秒双端禁移动/开火**:服务器不喂输入(清空缓冲 + `NetworkInputSource.reset_state()` 连 held/axis 一起清,防上一包方向让冻结期漂移);客户端 `player.set_controls_locked` 现在**连带冻结整个 input_source**(`InputSource.frozen`),锁住移动+开火——C2 下本地预测倒计时里不自走(C2 关时本地玩家本就服务器渲染、自然不动);进 PLAYING 解锁。局内击杀→复活/活方复位不动砖。
- 客户端流程:`main_menu`(默认场景)→ `matchmaking`(建房/输房间号;配对完成收到大厅 `go_match` 后**断开大厅、`start_client(server_address, worker_port)` 转连该局 worker 并 `claim_role`**,再等 worker 的 `match_start`)→ `pvp_game`(`pvp_client.gd`:Level0 pvp_mode 世界 + 补后处理 + 每 tick 上报输入 + 快照消费)。**本地玩家 = C2 客户端预测(rollback,`LOCAL_PREDICTION_ENABLED=true`)**:不 `set_server_rendered`,玩家由引擎自步进读真实 Input(aim/手感=单机);`pvp_client` 每帧在玩家步进前 `note_post_step(prev_seq)` + `reconcile()`(见 `core/prediction_rollback.gd`),输入包带单调 `seq`,服务器每物理 tick FIFO 消费 1 包并回带 `ack_seq` + 权威整态 `capture_state()`;分歧 → `restore_state` 权威态 + 重放未确认输入(错在哪补哪,非橡皮筋拉拢)。复盘见 `docs/pvp-c2-retrospective.md`(P1–P7,2026-09-06 P1/P2/P5 冒烟钉死、其余按实现落实)。**保底路径(开关关掉即回落)**:`server_rendered` 下玩家跳过全部移动物理,位置/姿态/朝向由快照插值(`apply_server_snapshot` + `_update_server_rendered`),血量/防水/倒地直接采纳;只保留鼠标瞄准/开火/受击反馈等本地视觉。远端对手 = `PlayerReplica` 纯视觉副本(显示对手当前武器并按快照 `aim` 摆枪,经 `weapon_base.drive_remote_visual` 驱动朝向/枪口仰角,不开火不读鼠标)。**★ 对手的预瞄红线看不到**(用户裁定 2026-09-11):heavy_aim 预瞄线**只有使用者本人可见**,`drive_remote_visual` 显式把副本武器的 `_aiming` 压回 false;服务端快照仍带 `previewing` 字段但客户端刻意不消费(留作日后换成音效/轮廓等提示形式的接点)。回归钉在 `tests/preview_visibility_probe.tscn`(双向:本人必须看得到 + 副本必须看不到)。**副本位置插值(重要)**:`player_replica` 位置走**双快照 tick 域 alpha 插值**——缓冲最近若干 canonical,渲染时钟落后最新 1 tick、按真实时间在相邻两快照间线性插值(`apply_snapshot` 带 tick 入缓冲;姿态/朝向/aim/倒地/武器仍按最新快照即时,只有位置平滑落后);时钟只在 tick 域走、不依赖两端时钟同步,丢包/卡顿冻结在最新已收位置,快照续上把时钟重置到最新窗口继续,不回退。插值结果跨接缝取 `toroidal_delta_px` 最短向量后取模回 canonical,再 `anchor_to_nearest` 锚到本地玩家最近副本渲染——每帧直接归位到可见副本,无旧指数/差分追赶(旧法:渲染位置与目标相隔整幅地图时最短向量=0,副本一旦落远副本就永远留在那 → 对手渲染到屏幕外「看不见」)。
- 协议(经 `NetBus` autoload RPC;对局权威=该局 **worker**,非 7777 大厅):握手——大厅→客户端 `go_match(role,port)`(配对完转连),客户端→worker `claim_role(role)`(报到,worker 据此建 role→peer 映射);输入包(60Hz reliable,`send_input`:轴/held/pressed/released 位掩码+切枪+瞄准方向)、快照包(60Hz unreliable,`snapshot`:每玩家 pos/vel/facing/pose/weapon/hp/waterproof/downed/aim/previewing)、事件包(reliable,`bullet_spawn`/`beam_fired`(即时光束权威开火,带折线 pts/origin/canonical/color/half_width/lifetime/style/shooter_role;接收端把 pts **逐点锚到对手副本渲染位置**再画,见 §武器)/`hit_event`/**`tile_destroyed`**——服务器拆墙广播,客户端 `TileDefs.damage_tile(cell,大伤,"explosion")` 触发 Level0 清瓦片渲染,否则建筑"看着没被炸坏"、**`round_state`**/`kill_event`——回合制状态/击杀广播)。**环面纪律**:协议只传 canonical 坐标、渲染各端归最近副本、插值走 `toroidal_delta_px` 最短路径。**击退方向走 toroidal 最短向量**:命中源(服务器子弹/爆心)锚在射手副本、可能与该玩家 canonical 相差整幅地图,`combat.take_hit` 里绝对相减会得出**反向击退**(跨接缝对枪被打向射手)——统一用 `toroidal_delta_px(source_pos, body)` 求推离方向(直击/爆炸/本地反馈同源)。
- 输入抽象:`InputSource` 基类(本地委托真实 Input;`frozen`=PvP 冻结时所有读口返回中性值)+ `NetworkInputSource`(消费输入包,服务器唯一消费方;`reset_state()` 连 held/axis 一起清)。`NetworkInputSource.get_axis` **垂直轴由 held 位推导、水平轴返回 `ax`**(输入包只传水平轴,`climb_component` 用 `get_axis("up","down")` 读垂直——曾一律返回水平轴致服务器挂梯不动)。`weapon_base` 攻击经 player 查询(`is_attack_pressed` 等,has_method 守卫回退 Input);`BulletBase.apply_damage=false` = 客户端视觉副本(不裁决,伤害由服务器裁决)。
- PvP 固定地图 `factory_1V1(260827).cyrm`(150×100,`# player 17 65` + `# player2 133 64`;两出生点相距约 2200px 超视野,走近才互见)。
- PvP HUD:`ui/pvp_hud.tscn`(`class_name PvpHud`,CanvasLayer layer=130 盖在 PostProcess 128 / 单机 HUD 129 之上)显示双方击杀/局胜/局号 + 中央状态(准备倒计时/胜局/获胜),MATCH_OVER 后 `pvp_client` 延时回主菜单。复活视觉:`combat.revive()` 已补 `post_process.set_downed(false)`(复活后屏幕不再变灰)。
- 测试:`tests/pvp_room_smoke.sh` 断言建房/加入/开局;`tests/pvp_match_smoke.sh` 断言输入→模拟→快照→子弹广播链路 + **round_state 广播** + **ack_seq 推进 + 快照 c2 全态与散字段一致**(loopback);`tests/pvp_reconcile_smoke.sh` = rollback 控制器 in-process 冒烟(权威/预测双 sim + 人工 ack 延迟 + 外部传送事件,断言一次性 rollback 收敛、常态无橡皮筋);`tests/pvp_twin_smoke.sh` = capture/restore 完整性冒烟。脚本收尾用 `taskkill` 按 PID + `kill_port`(netstat 找 7777 持有者)强杀——**Windows 下 bash `kill` 杀不死 headless Godot,会留僵尸占 7777**。

### 大乱斗(Royale,L5 层搬入)

- **入口与场景**:主菜单「大乱斗」按钮(`main_menu.gd`)→ `scenes/royale_lobby.tscn`(`royale_lobby.gd`:公开/私密房、邀请码、人数与限时、禁用武器与角色色、房间列表自动拉取、「一键起本服」)。`PvpSession.royale = true` 标记分支。UI 一律走 `UiFactory`,字号 16 倍数。
- **一局是怎么起来的(大厅 → worker 子进程 → `RoyaleHost`)**:
  1. 大厅(`server/server_main.tscn` 无参 = 7777)的 `RoomManager` 多出一张 **`RoyaleRoom` 注册表**,与 1v1 的 `rooms` 并存且互斥(两条 Start 路径互相拒斥)。建房/加入/状态广播经 `NetBusExt` 的 `royale_*` RPC。
  2. 房主发 `royale_start`(或 `royale_start_ai`)→ `_spawn_royale_worker(port, players, max_role, ai_roles)` 用 `OS.create_process` 拉起**独立 worker 子进程**,命令行 = `--headless [--path . res://server/server_main.tscn] -- --worker --royale --port P --players N --max-role R [--ai-roles r,r]`(**每个开关一个独立 argv 项**,`--ai-roles` 的值是逗号串;editor/template_debug 下必须带 `--path`+场景,仅导出 exe 可省。与 `server_main.gd` `_ready` 里的 argv 解析**逐字对应**——`--players`/`--max-role` 都被 `clampi(..., 2, 8)`,`--ai-roles` 逐 token 取 1..8;两边改一处必须同步改另一处)。进程隔离 = 各局内存隔离,共享全局 `current_grid`/`TileDefs` 不跨局互踩。
     - **`--players N` 与 `--max-role R` 是两个语义,别合并**:`N` = 预期报到总人数(收齐判据 `_claims.size() >= N - AI 数`、AI 数减法);`R` = **合法 role 号上界**(claim 越界判据)。role 由 `royale_join` 的「最小空闲号」分配且**有人退出后不重排** → 编号会留空洞(3 人房里中间那位退出 → 房里是 `{1,3}`,成员数 2 < 最高 role 3);拿人数当上界会把手持 3 号的**真客户端**当串线踢掉(只剩 1 个 claim → 超时梯走完 worker 退出 → 两名客户端卡在「连接对局服务器超时」)。上界由 `RoomManager._royale_role_bound` 取**实际最高 role**(AI 号也算在内)。AI 补位号由 `_royale_free_roles` 取 `1..max_players` 内**人类未占用**的空闲号(不能用「人数 + 1 + i」——空洞时会撞上仍在房里的高号真人)。
  3. worker 的 `--royale` 分支:`_on_role_claimed` 收齐 **`_expected_players - _ai_roles.size()`** 个人类 `claim_role` 即开局(其余角色由 AI 补位);`_process` 另有两条超时梯——**已到 ≥2 人但 20s 仍收不齐** → 按已到人数降级开局(缺席 role 不入局,`RoyaleHost.plan_spawns` 按实际键返回散点以容忍不连续 role);**可用玩家 <2 人**(开局前全掉线)→ **10s 宽限后退出释放端口**(否则 worker 僵死占端口、大厅回收后撞车新对局)。`_on_role_claimed` 另有**报到串线防护**:对局已开始/role **越界(用 `_role_bound`,不是人数)**/该 role 已被别的 peer 占用 → 直接 `disconnect_peer`(端口复用竞态下迟到的客户端会连到旧 worker,不能让它静默留在局里收快照)。`_begin_match` 是抽出来的函数,1v1 走 `RoomManager.start_match_on`、大乱斗走 **`RoyaleHost.start_on`**。
     - **开局经 `_defer_begin_match()` 延到帧末**:每个客户端都是「`claim_role` 紧接 `player_options`」两条包(同一次 poll 到达),而收齐判据由**最后一个** claim 满足 → 同步开局会在同一次 poll 里抢先建局,那个客户端的 `player_options`(角色颜色)还没归档;它恰是 role1(2 人局常态)时整局规则项(禁武器)也拿不到。延到帧末 = 同一次 poll 的选项先全部归档再建局(重入由 `_begin_match` 自身的守卫兜住)。
  4. 端口归还延迟:`ROYALE_PORT_REUSE_DELAY`=**360s**(1v1 的 `WORKER_PORT_REUSE_DELAY`=30s 不够一局,沿用会让对局中途端口被发给新 worker → 串线/bind 冲突);`royale_rooms` 已纳入 **`_sweep_stale_rooms`**(大乱斗 `worker_port` 只在开局时分配,归还路径 = `on_peer_left` 空房分支 + `royale_leave` 空房分支(「退出房间」按钮**不断开大厅 peer**,不会触发前者 → 原先这条路径直接把房摘掉,端口从此无人归还)+ sweep;在局中的大乱斗房另加 **`SWEEP_INTERVAL + RoyaleHost.MATCH_TIME`** 宽限(推导见 `_sweep_stale_rooms` 的 royale 分支注释;**已知边界**:宽限与端口延迟里的「一局」都取 `RoyaleHost.MATCH_TIME` 的**默认值** 300s,而 `royale_lobby.gd` 建房页的「一局限时」滑块会把 `Settings.royale_match_min`(钳在 1~30 分钟)经 `player_options` 的 `match_time` 送进 `RoyaleHost._cfg_match_time`,一局最长 1800s —— 于是**一个等了近 2h 才开局、又配了长时长的房**,其对局进行到 300s 之后的那次 tick 仍会判超龄并连 worker 一起杀掉(缺口最大约 1500s),端口延迟也同样短于一局。本次**不放宽**:触发它还需房龄近 2h(正常房建房后几分钟内就开局),而正确的界要读**本局实际时长**(该值只在 worker 的 `RoyaleHost` 里,sweep 手里没有),属另行评估。等待中的房不占端口,仍按裸 `MAX_ROOM_AGE` 清)。
- **权威:`server/royale_host.gd`(`RoyaleHost extends MatchHost`)**——**覆写** `_init` / `_spawn_cell` / `_ready` / `_match_round_tick` / `_match_winner` / `_broadcast_round_state` / `_on_bullet_hit` / `_respawn_player`;**自有**(不在基类,不属「`match_host` 扩展点」)`set_display_names` / `mark_disconnected` / `request_suicide_role` / `_finish_match` / `_attributed_killer`。`MatchHost` 这一侧只**追加**了 `_broadcast_match_options` 与 `notify_direct_hit` 两个方法,外加 `_init` 签名(`options`/`ai_roles`)、`_ready` 应用禁用槽、`_on_bullet_hit` 追加 hit_confirm、`_round_full_heal`、`_respawn_player` 的 `equip(default_slot())` 五处就地改动——**C2 四条一行未动**(见下「已知风险」与 `tests/kh_l5_probe.gd` 第 1 条)。
  - **`_init` 顺序不可"整理"**:必须先 `plan_spawns` 再 `super._init`——父类 `_init` 摆位会**虚调** `_spawn_cell(role)`,反了则首次摆位拿到 `(-1,-1)` 且被 `_spawned_once` 闩锁,全体挤到地图回卷角落。
  - 规则:限时 **`MATCH_TIME`=300s** 死斗,击杀最多者胜(榜首并列返回 0 = 平局);死亡 **2s 复活**;**开局散点**两两环面距 ≥ `SPAWN_CLEARANCE`=15 格、**复活点**动态选「离所有存活敌人 ≥ `RESPAWN_CLEARANCE`=8 格」的开阔格;出生候选要求头顶 2 格净空 + 左右邻格空 + 同层连通区 ≥ `OPEN_AREA_MIN`=20 格(防出生在走不出去的密封小间,不足逐级回退)。中途掉线 `mark_disconnected` = 节点释放 + 排行榜标「离开」,剩余 <2 人即终局。
  - **击杀归因**:`_on_bullet_hit` 覆写先 `CombatFeedback.attribute(victim, bullet.shooter)`(写 `last_damager` + `last_damager_time` meta)**再** `super`;倒地边沿 `_attributed_killer` 读 meta 计分,时效 `ATTRIB_WINDOW = CombatFeedback.ATTRIB_WINDOW_MS`(**3s**,用户 2026-09-11 裁定与单机播报同口径;原 KH 值 10000ms 已弃用)。无源死亡(溺水/坠落)不计分;自杀 `request_suicide_role` 先清 meta,不算任何人的击杀。
  - `round_state` 载荷(大乱斗版)= `scores`/`deaths`/`names`/`alive`/`left`/`timer`/`match_winner`,昵称行覆盖真人 + 已离开者 + **AI 补位**。
- **客户端:`scenes/royale_game.gd/tscn`**——Level0(`pvp_mode`)+ PostProcess + **N-1 个 `PlayerReplica`(按快照 roles 动态建)** + `RoyaleHud` + Minimap + 血条 + 拖尾。**本地玩家走 `set_server_rendered(true)`——这是**临时方案**(规格 D2):KH 大乱斗客户端本来就是 server_rendered 写法,1v1 仍是 C2 客户端预测,后续可把大乱斗单独接回 C2。** 消费 `NetBus.local_*`(snapshot/bullet_spawn/**beam_fired**/hit_event/tile_destroyed/round_state/peer_info/kill_event)与 `NetBusExt.local_*`(match_options/peer_hues/hit_confirm)。
  - **开局三载荷的跨场景交接(自检 B2)**:`peer_info`(昵称表)/`peer_hues`(角色色相)/`match_options`(禁武器等)与 `match_start` 由 worker 在同一帧发出,而大厅收到 `match_start` 后是**帧末**才切场景(栈内切实测段错误,见 `royale_lobby._on_match_start`)→ 三者落在同一次 poll 时新场景还不存在,订阅方一个都没有(对手颜色不生效、昵称表空到连自己头顶 ID 都建不出来、禁武器闸门没上)。修法:那一刻还活着的**大厅**先接住并缓存进 `PvpSession.pending_peer_info/pending_peer_hues/pending_match_options`,新场景 `_ready` 里 `_consume_pending_payloads()` 取用;晚到的(分帧到达)仍走新场景自己的订阅,两条路径进同一组 handler、重复应用幂等。`pending_*` 在**进大厅**与**每次 `go_match`** 都清空 → 不跨局残留。大厅另有 `_return_to_lobby` 兜底(转连 worker 12s 无连接 / claim 后 25s 无 `match_start` → 断连重连大厅并刷新列表;原先 worker 死掉时只能干等在等待室)。
  - 复现/守卫:`tests/royale_bound_probe.tscn`(`-- --payload` 模式确定性造「同一次 poll」;无参模式走真大厅+真 worker 全链路)与 `tests/royale_bound_watcher.gd`。
- **AI 补位:代码就位,不接界面**(D13,用户明确)。`core/ai_input_source.gd`(`AIInputSource extends InputSource`)+ `server/ai_player.gd`(`class_name AINavigator`)是被搬入并整理的服务端链路,`--ai-roles=r,r` 是唯一入口(客户端按钮族已删)。
  - `MatchHost._init` 为每个 AI role 实例化**同一份 `Player.tscn`**,注入 `AIInputSource`,加 `AINavigator` 子节点驱动;**不入 `input_sources`**(不走网络包),入 `players` 即自动获得快照/命中裁决/计分/复活的全部覆盖 → **客户端副本零改动**。
  - ★ **`AIInputSource.is_network_driven()` 必须返回 `true`**(已覆写并附长注释):否则服务器侧 AI 被 `WeaponBase.reload_active()` 的第二判据 `player.input_is_network()` 判成「本地单机」→ 打空弹夹后**静默**进换弹停火 `reload_time` 秒(霰弹 2.2s / 榴弹 2.8s)。不造成客户端分歧(AI 无预测端),只是手感莫名变差且无报错。
  - **`--ai-roles` 首次实跑待用户验收**(`AINavigator` 用 `host.RoundState.PLAYING` 动态查表,未经真机跑过)。

#### ★ 本层新引入的已知风险(实测观察,未压测)

1. **快照体积随人数线性增长**:大乱斗快照每个玩家都带一份**权威整态 `c2`**(`capture_state()`)+ 散字段,60Hz `unreliable` 广播,N 人 = **N 份整态 × 60Hz**。8 人时的带宽/丢包表现(以及 unreliable 通道被撑爆后快照乱序/丢弃的次生影响)未实测。
2. **输入队列积压(每 tick 恰好消费 1 包的下游代价)**:每个物理 tick 每 role **只消费一个** FIFO 输入包(C2 rollback 的锚点,不可改)。客户端 60Hz 上行 + 网络抖动时,**到达速度可能短时超过消费速度**,而 `_pending_input[role]` **无长度上限、无丢弃策略** → 理论上积压会表现为延迟单调增长(不丢包,只是越玩越滞后)。N 人(8 人 × 60Hz)时未压测;若真机出现"越玩越卡",这里是第一嫌疑点。

### 测试
无单测框架。`tests/*.gd` 是 `extends SceneTree` 的冒烟/诊断脚本,用 `-s` 跑:`enemy_logic_smoke.gd` 为主(覆盖敌人 AI、环面数学、武器参数/命中、碰撞层、寻路/LOS、多弹丸),其余 seam_analyze/seam_screenshot/wrap_probe 是环面接缝诊断;`laser_weapon_smoke.gd` 验 LaserWeaponBase 三缝/默认直线几何/反射子类可解析/权威门控(源码)/上报 round-trip/跨接缝粘副本公式。写新测试注意: `-s` 阶段 autoload 尚未实例化,避免静态引用会连带预加载引用 autoload 的脚本(见 smoke 内注释);laser 脚本链须在 `_initialize()` 内 `load()`。
**两种跑法,按脚本首行区分**:`extends SceneTree` → `-s res://tests/<名>.gd`(autoload 不存在);`extends Node` → `--quit-after <帧数> res://tests/<名>.tscn`(`--quit-after` 的单位是**帧**不是秒;它是安全网——脚本解析失败时场景根没脚本、一行不打印且不退出)。L1~L5 的层验收探针 `kh_l1/l3/l4/l5_probe.tscn` 都是场景模式,判据必须是 **grep 文本 `ALL-OK`**(中途报错时 `--quit-after` 仍 exit 0 且不打印 ALL-OK,只看退出码会把"没跑完"读成"通过")。`tests/royale_probe.tscn` 是大乱斗全链路端到端探针(自当大厅/裁判 + 拉两个 headless 客户端走完整建房→转连→开局链路;**跑前先确认 7777 空闲**)。`tests/kh_l5_probe.gd` 是源码级机械扫描仪:C2 四条在位 / main 的 sweep 族在位 / 无演示残留 / 字号规范 / 新接口归属(含反向断言:基类不得含子类方法)。
