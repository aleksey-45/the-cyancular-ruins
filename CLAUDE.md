# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概览

Godot 4.7(标准版,非 mono)做的 2D 俯视角射击 demo「The Cyancular Ruins」。1920×1440 视口、`rendering/mobile`。核心特色:

- **环面世界**:地图左右/上下无缝回绕,敌人/子弹/镜头跨接缝连续。
- 单关卡(Level0)从 ASCII 地图文件加载,无运行时随机生成(生成逻辑已注释)。

## 常用命令

Godot 不在 PATH,用绝对路径。**4.7.1 标准编辑器**是当前主用版本(详见 `RELEASE.md`;4.4.1 mono 已弃用,仅在需要兼容旧脚本时用其 console 版)。

```bash
# 冒烟测试(唯一的"测试",SceneTree 脚本;成功打印 SMOKE OK 退出 0)
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s res://Tests/enemy_logic_smoke.gd

# headless 启动游戏 90 帧后退出(看脚本报错)
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . --quit-after 90

# 导出单 exe 发布版
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64.exe" --headless --path . --export-release "Windows Desktop" "The Cyancular Ruins.exe"
```

约定:**测试由用户自己跑,不要代跑**。发布/裁剪模板细节见 `RELEASE.md`(单 exe 靠自定义裁剪模板,勿用 UPX,保留 webp 模块)。

## 架构

### 环面世界与地图
- 地图:ASCII 文本 `map/demo.txt`,`1`=墙(SOLID)、`0`=空(EMPTY),`#` 开头的行是注释。当前 500×300 格 × 16px 瓦片 = 8000×4800 世界像素。改了地图 → 记得 `map/*.txt` 已在导出 include_filter 里。
- `MazeGenerator`(Globals/maze_generator.gd,`RefCounted`,非 autoload)是地图与环面核心:
  - 读图:`load_map_file()` / `map_size()`(行宽不一致的抬头行会被跳过);
  - 环面数学:`toroidal_dist`(格级)、`toroidal_delta_px`(像素最短向量)、`anchor_to_nearest`(实体锚到玩家最近副本)、`wrap_to_range`(取模回中间副本);
  - 寻路:`bfs_path` / `bfs_path_nearest` / `astar_path_nearest` / `has_line_of_sight`(Bresenham)。`current_grid` 静态变量由 Level0 赋值,空网格一律无路。
- **关键区分**:玩家每帧 `wrap_to_range`(只留中间副本);敌人/子弹用 `anchor_to_nearest`(锚定到玩家附近的副本)。墙体按 3×3 铺贴,相机跨接缝才能看到另一侧——实体若取模回 `[0,MAP)` 会在接缝处"消失"。

### 参数体系(重要约定)
- **唯一 autoload 是 `GameParameters`**(Globals/gameParameters.gd):gravity0、TILE_SIZE=16、地图像素尺寸、敌人数/出生距离。`_ready()` 里从 `MazeGenerator.map_size()` 回写 `MAP_WIDTH/HEIGHT`。
- 玩家/敌人参数**不是** autoload:`PlayerParams`、`EnemyParams` 是 `RefCounted` + `const`,静态访问(如 `EnemyParams.FlyBird.wake_radius`)。加新敌人 = 在 `EnemyParams` 加一个嵌套类。

### 敌人(Scenes/Enemies/)
继承链 `EnemyBase → EnemyFlyBase → EnemyFlyBird`;JumpBird 直接继承 `EnemyBase`:
- `EnemyBase`(CharacterBody2D):`hp/contact_damage/knockback_strength/knock_decay_rate` 导出参数;统一状态机 `state`(int,各子类自带 `enum State`);子类覆写 `_ai(delta)`/`_anim_update()`;受击白闪+击退在 `_apply_hit`(枪击击退叠加原速度;爆炸 `set_velocity=true` 设独立 `knock_velocity` 向量,每帧叠加 `move_and_slide` 后指数衰减 `knock_decay_rate`,不覆盖移动速度);**死亡物理与生前完全一致**——尸体继续走同一套 `_physics_process`(重力/摩擦/击退衰减/碰撞),只是 AI 不行动;尸体被后续命中只吃击退不吃伤(`hurt` 的 `is_dead` 分支走 `_apply_knock_only`),基础速度也按 `knock_decay_rate` 指数衰减(滑行逐渐停住);每帧 `move_and_slide()` 后 `_wrap()`;接触伤害走 ContactArea + 环面距离兜底。入 `enemies` 组。
- `EnemyFlyBase`:飞行寻路。A* 按**鸟自身飞行碰撞箱 + 场上实体碰撞箱**判可走(`_bird_can_pass`);空路径直线兜底;被悬挑墙压到(死区)时水平逃逸;站/飞碰撞箱切换(`_apply_flight_collision`)。寻路参数耦合 `EnemyParams.FlyBird`(当前唯一飞行敌人,接受该耦合)。
- `EnemyFlyBird`:状态机 SLEEP/TAKE_OFF/FLY/SHOOT/CHARGE/RETURN。平抛投弹(玩家速度预测);HP<25% 单向切 CHARGE 冲撞(穿透无敌帧、撞后自毁);死亡白闪后销毁(物理与生前一致,保留碰撞);返程回家落地入睡。
- `EnemyJumpBird`:近战跳跃怪(跳/后跳/扑击);死亡物理与生前一致、保留碰撞(与飞鸟统一,不再清碰撞箱)。
- **加新敌人** = 一个 .tscn + `EnemySpawner.TYPES` 加一行(键名 → 场景路径),spawner 随机取"地板格"(EMPTY 且正下方 SOLID)布点。

### 武器与子弹(Scenes/Weapons/)
- `WeaponBase`(Node2D):数值全是 `@export`(fire_cooldown、bullet_speed/range/size/color、pellet_count/spread、damage/impact、recoil_push/kick、cam_shake、move/jump_penalty、heavy_aim 激光、pitch_clamp_deg)。`fire()` 按 pellet_count 从 `bullet_scene`(@export,默认 bullet.tscn)出弹并注入 `bullet_gravity`;`apply_hit()` 调敌人 `hurt()`;heavy_aim 按住预瞄、松开发射;`preview_arc=true` 时预瞄画**抛物线弧线 + 末端爆点标记**(参考,用 `preview_time`,与子弹 fuse 解耦)。
- 现有武器:手枪/步枪/m82a1(重狙,heavy_aim)/s686(霰弹 8 丸 ±5°、射程700)/grenade_launcher(第5槽,重型)。
- 子弹:玩家 `BulletBase`(伤害由 WeaponBase 管;`fire()` 注入 `hit_damage/hit_impact`,切枪后旧武器已 free 时子弹自带参数兜底直接结算);**爆炸弹**(如 `grenade_bullet.tscn`)在 BulletBase 加 @export `explodes/direct_hit_damage/fuse_time/explosion_radius/damage/knockback/visual` —— `explodes=true` 时撞墙/命中敌人一律反弹(衰减0.6),首次碰撞后 `fuse_time`(撞墙)/`hit_fuse_time`(命中敌人)引信爆炸(命中敌人另加 10 直接伤立即结算)、超射程兜底爆炸。AoE 判定在 `Globals/explosion.gd`(`Explosion.apply_aoe`:内圈 40% 满伤+二次方平缓衰减/LOS遮挡(墙后保留 75%)/友伤/击退独立向量纯径向——敌人走 `set_velocity=true`、玩家经 `take_hit` 传击退),爆炸特效 = `explosion.tscn`(AnimatedSprite2D 多帧,`_explode` 按 `explosion_radius/帧宽` 缩放,`explosion_fx.gd` 播完自毁)。敌人子弹 `enemy_bullet.gd` 是带重力抛物线弹(`launch()`)。
- 碰撞层:子弹 mask=5(地形+敌人),榴弹不含玩家 → 友伤只来自爆炸。

### 玩家(Scenes/Player/player.gd)
CharacterBody2D:指数缓动移动手感、土狼时间/跳跃缓冲/可变高度、冲刺(沿用最近移动方向)、下蹲、姿态碰撞箱(Pose→CollisionPolygon2D,运行时只启用当前姿态的箱子)、iframes/击退(爆炸=独立 `knock_velocity` 向量,衰减率 `player_knock_decay_rate`)/倒地(倒地**不取消物理**,仍受重力/击退,只是不吃输入;按 R 重载场景)。移动/跳跃/冲刺/镜头/战斗数值全在 `PlayerParams`。**加新武器** = 一个继承 WeaponBase 的 .tscn + `player.gd` 的 `WEAPONS` 注册表加一行(键对应输入动作;project.godot 已注册 1~0,第5槽=榴弹发射器)。

### 渲染管线(Level0.tscn)
根节点把未处理输入手动转发进 `WorldViewport`(SubViewport);世界(墙体/玩家/敌人)渲染进 SubViewport,`PostProcess`(post_process.gd)做像素缩放裁切 + 倒地暗角。相机 `camera_2d.gd` 带前瞻/死区。注意:冒烟测试把武器挂到根 Window 而非 SubViewport(见 weapon_base 的鼠标坐标注释)。

### 碰撞层(按位)
层1=地形、层2=玩家、层3=敌人。玩家/玩家子弹 mask=5(1+3);敌人占层 3(值4)、mask 侦测玩家。

### 编辑器工具
`editor/structure-editor.html` + `editor/smoke.js` 是独立浏览器地图编辑器(大图缩放/画笔),与 Godot 引擎无关。

### 测试
无单测框架。`Tests/*.gd` 是 `extends SceneTree` 的冒烟/诊断脚本,用 `-s` 跑:`enemy_logic_smoke.gd` 为主(覆盖敌人 AI、环面数学、武器参数/命中、碰撞层、寻路/LOS、多弹丸),其余 seam_analyze/seam_screenshot/wrap_probe 是环面接缝诊断。写新测试注意: `-s` 阶段 autoload 尚未实例化,避免静态引用会连带预加载引用 autoload 的脚本(见 smoke 内注释)。
