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
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . -s res://Tests/enemy_logic_smoke.gd

# headless 启动游戏 90 帧后退出(看脚本报错)
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64_console.exe" --headless --path . --quit-after 90

# 导出单 exe 发布版
"D:/Program Files/Godot_v4.7.1-stable_win64/Godot_v4.7.1-stable_win64.exe" --headless --path . --export-release "Windows Desktop" "The Cyancular Ruins.exe"
```

约定:**测试由用户自己跑,不要代跑**。发布/裁剪模板细节见 `RELEASE.md`(单 exe 靠自定义裁剪模板,勿用 UPX,保留 webp 模块)。

## 架构

### 环面世界与地图
- 地图:ASCII 文本 **`.cyrm`**(如 `map/demo.cyrm`)。**v3 格式**(带 `# cyrm-v3` 标记):125×75 格 × 64px 瓦片 = 8000×4800 世界像素;每格 **4 字符 = [纹理 3 位 0xx][形状hex]**(纹理 `000`=空气/`001`-`022`=1-22,structure.png 两行各 10 块 + 第3行两块水;形状 hex `0`-`F` = 2×2 子格掩码,15=全砖,0=空气占位)。纹理用 3 位数字、不用字母。**旧格式**(250×150 单字符,无标记)加载时自动 2×2 转换(packed 值 + spawn 坐标 ÷2)。`#` 开头的行是注释。加载:`MazeGenerator.map_file_path()` 优先随机取 exe 旁 `.cyrm`,否则随机取 `map/*.cyrm`(**同目录多份随机读一份**,会话内固定);`map/*.cyrm` 已在导出 include_filter 里。编辑器输出 `.cyrm`、可导入 `.cyrm`/`.txt`。
- `MazeGenerator`(Globals/maze_generator.gd,`RefCounted`,非 autoload)是地图与环面核心:
  - 格值 = packed `texture*16 + shape`(0-335,`pack/texture_of/shape_of`);`EMPTY=0`、`SOLID=31`(纹理1 全砖);挡路判定走 `TileDefs.is_blocked`(非 0 且 type=wall);
  - 读图:`load_map_file()` / `map_size()`(v3 与旧格式都返回转换后 125×75;行宽不一致的抬头行会被跳过);`convert_old_grid()` / `serialize_v3_grid()` 是单一转换源(旧 v2 字母版地图用 `Tests/convert_map.gd` 转 v3);
  - 环面数学:`toroidal_dist`(格级)、`toroidal_delta_px`(像素最短向量)、`anchor_to_nearest`(实体锚到玩家最近副本)、`wrap_to_range`(取模回中间副本);
  - 寻路:`bfs_path` / `bfs_path_nearest` / `astar_path_nearest` / `has_line_of_sight`(Bresenham)。`current_grid` 静态变量由 Level0 赋值,空网格一律无路。
- **关键区分**:玩家每帧 `wrap_to_range`(只留中间副本);敌人/子弹用 `anchor_to_nearest`(锚定到玩家附近的副本)。墙体按 3×3 铺贴,相机跨接缝才能看到另一侧——实体若取模回 `[0,MAP)` 会在接缝处"消失"。

### 参数体系(重要约定)
- **唯一 autoload 是 `GameParameters`**(Globals/gameParameters.gd):gravity0、TILE_SIZE=64、地图像素尺寸、敌人数/出生距离。`_ready()` 里从 `MazeGenerator.map_size()` 回写 `MAP_WIDTH/HEIGHT`。
- 玩家/敌人参数**不是** autoload:`PlayerParams`、`EnemyParams` 是 `RefCounted` + `const`,静态访问(如 `EnemyParams.FlyBird.wake_radius`)。加新敌人 = 在 `EnemyParams` 加一个嵌套类。

### 敌人(Scenes/Enemies/)
继承链 `EnemyBase → EnemyFlyBase → EnemyFlyBird`;JumpBird 直接继承 `EnemyBase`:
- `EnemyBase`(CharacterBody2D):`hp/contact_damage/knockback_strength/knock_decay_rate` 导出参数;统一状态机 `state`(int,各子类自带 `enum State`);子类覆写 `_ai(delta)`/`_anim_update()`;受击白闪+击退在 `_apply_hit`(枪击击退叠加原速度;爆炸 `set_velocity=true` 设独立 `knock_velocity` 向量,每帧叠加 `move_and_slide` 后指数衰减 `knock_decay_rate`,不覆盖移动速度);**受击/死亡白闪统一在基类**:`_hit_flash_time`(0.1s)与 `_begin_death()`(死亡白闪 `shared.death_flash_time`=0.5s 后销毁)统一计时,渲染走 `_flash_update()`(默认 modulate 纯白;黑鸟因 silhouette shader 覆写 COLOR 而 modulate 失效,覆写本方法改走 shader 参数);`_set_facing()` 锁转向频率(两次翻转至少间隔 `shared.turn_min_interval`=0.5s,防来回抖);**死亡物理与生前完全一致**——尸体继续走同一套 `_physics_process`(重力/摩擦/击退衰减/碰撞),只是 AI 不行动;尸体被后续命中只吃击退不吃伤(`hurt` 的 `is_dead` 分支走 `_apply_knock_only`),基础速度也按 `knock_decay_rate` 指数衰减(滑行逐渐停住);每帧 `move_and_slide()` 后 `_wrap()`;接触伤害走 ContactArea + 环面距离兜底。入 `enemies` 组。
- `EnemyFlyBase`:飞行寻路。A* 按**鸟自身飞行碰撞箱 + 场上实体碰撞箱**判可走(`_bird_can_pass`);空路径直线兜底;被悬挑墙压到(死区)时水平逃逸;站/飞碰撞箱切换(`_apply_flight_collision`)。寻路参数耦合 `EnemyParams.FlyBird`(当前唯一飞行敌人,接受该耦合)。
- `EnemyFlyBird`:状态机 SLEEP/TAKE_OFF/FLY/SHOOT/CHARGE/RETURN。平抛投弹(玩家速度预测);HP<25% 单向切 CHARGE 冲撞(穿透无敌帧、撞后自毁);死亡白闪后销毁(物理与生前一致,保留碰撞);返程回家落地入睡。
- `EnemyJumpBird`:近战跳跃怪(跳/后跳/扑击);死亡物理与生前一致、保留碰撞(与飞鸟统一,不再清碰撞箱)。
- `EnemyBlackBird`:绕背瞬移刺客(睡眠→随机游走→周期性判定玩家另一侧、距玩家 2~4 格(随机)的地板格落点(地板格 + LOS)→起飞上跳→落地播 disappear→白闪→传送→闪后空中播 appear→落地→带跳跃冲锋打 6 伤(穿透无敌帧)→大后跳(命中/未命中都)→回游走,玩家远离入睡);死亡白闪后销毁。数值在 `EnemyParams.BlackBird`。
- **加新敌人** = 一个 .tscn + `EnemySpawner.TYPES` 加一行(键名 → 场景路径),spawner 随机取"地板格"(EMPTY 且正下方 SOLID)布点。

### 武器与子弹(Scenes/Weapons/)
- `WeaponBase`(Node2D):数值全是 `@export`(fire_cooldown、bullet_speed/range/size/color、pellet_count/spread、damage/impact、recoil_push/kick、cam_shake、move/jump_penalty、heavy_aim 激光、pitch_clamp_deg)。`fire()` 按 pellet_count 从 `bullet_scene`(@export,默认 bullet.tscn)出弹并注入 `bullet_gravity`;`apply_hit()` 调敌人 `hurt()`;heavy_aim 按住预瞄、松开发射;`preview_arc=true` 时预瞄画**抛物线弧线 + 末端爆点标记**(参考,用 `preview_time`,与子弹 fuse 解耦)。
- 现有武器:手枪/步枪/m82a1(重狙,heavy_aim)/s686(霰弹 8 丸 ±5°、射程700)/grenade_launcher(第5槽,重型)。
- 子弹:玩家 `BulletBase`(伤害由 WeaponBase 管;`fire()` 注入 `hit_damage/hit_impact`,切枪后旧武器已 free 时子弹自带参数兜底直接结算);**爆炸弹**(如 `grenade_bullet.tscn`)在 BulletBase 加 @export `explodes/direct_hit_damage/fuse_time/explosion_radius/damage/knockback/visual` —— `explodes=true` 时撞墙/命中敌人一律反弹(衰减0.6),首次碰撞后 `fuse_time`(撞墙)/`hit_fuse_time`(命中敌人)引信爆炸(命中敌人另加 10 直接伤立即结算)、超射程兜底爆炸。AoE 判定在 `Globals/explosion.gd`(`Explosion.apply_aoe`:内圈 40% 满伤+二次方平缓衰减/LOS遮挡(墙后保留 75%)/友伤/击退独立向量纯径向——敌人走 `set_velocity=true`、玩家经 `take_hit` 传击退,爆炸穿透无敌帧 + 爆心越近相机震得越猛),爆炸特效 = `explosion.tscn`(AnimatedSprite2D 多帧,`_explode` 按 `explosion_radius/帧宽` 缩放,`explosion_fx.gd` 播完自毁)。敌人子弹 `enemy_bullet.gd` 是带重力抛物线弹(`launch()`)。
- 碰撞层:子弹 mask=5(地形+敌人),榴弹不含玩家 → 友伤只来自爆炸。

### 玩家(Scenes/Player/player.gd)
CharacterBody2D:指数缓动移动手感、土狼时间/跳跃缓冲/可变高度、冲刺(沿用最近移动方向)、下蹲、姿态碰撞箱(Pose→CollisionPolygon2D,运行时只启用当前姿态的箱子)、iframes/击退(爆炸=独立 `knock_velocity` 向量,衰减率 `player_knock_decay_rate`)/倒地(倒地**不取消物理**,仍受重力/击退,只是不吃输入;按 R 重载场景)。移动/跳跃/冲刺/镜头/战斗数值全在 `PlayerParams`。**加新武器** = 一个继承 WeaponBase 的 .tscn + `weapon_component.gd` 的 `WEAPONS` 注册表加一行(键对应输入动作;project.godot 已注册 1~0,第5槽=榴弹发射器)。
- **结构(轻量拆分)**:根 `player.gd` 只留移动/姿态/物理帧编排;攀爬(梯/锁链)、战斗(生命/无敌/击退/倒地)、武器(注册表/换枪/后坐)分别抽成 `ClimbComponent`/`CombatComponent`/`WeaponComponent`(Player.tscn 子节点)。组件**不写自己的 `_physics_process`**,由根每帧显式按顺序调用(`climb.update → 移动 → combat.apply_knock → move_and_slide`),避免调度乱序。跨组件状态经根传参;根公开接口 `take_hit/get_facing/set_facing/is_downed/apply_recoil`、信号 `hp_changed`、只读 `hp/max_hp` 原样保留(HUD/敌人/武器零改动)。契约守卫 `Tests/player_contract_smoke.gd`(源码级)保接口不漂。

### 渲染管线(Level0.tscn)
根节点把未处理输入手动转发进 `WorldViewport`(SubViewport);世界(墙体/玩家/敌人)渲染进 SubViewport,`PostProcess`(post_process.gd)做像素缩放裁切 + 倒地暗角。相机 `camera_2d.gd` 带前瞻/死区。注意:冒烟测试把武器挂到根 Window 而非 SubViewport(见 weapon_base 的鼠标坐标注释)。
- **墙体 64px 砖块渲染**:`_create_wall_tileset()` 运行时把 structure.png 两行 20 块 32px 砖最近邻 2× 放大成 64px,对每(纹理×形状)生成 16×20 atlas(空气象限透明),TileSet tile_size=64,`_paint_maze` 按 `Vector2i(shape, texture-1)` 铺 125×75 ×3×3 环面。
- **碰撞**:`Globals/collision_builder.gd`(`class_name CollisionBuilder`,静态可测)把形状掩码展开成 250×150 的 32px 子格(每 64px 格 → 2×2),贪心合并矩形(ts=32)后按 **9 环面副本偏移**实例化(每块矩形 ×9,共享同一 shape)。**永久墙(不可破坏)建一个整图节点、建一次不动;可破坏层按分块存节点**(块边长 12 格 ≈ √地图边长,块内一次贪心 + 9 副本),摧毁时只重建所在块 → 重建成本 O(块面积)。**只有 type=wall 产生碰撞**,通道(梯子/锁链)可走/可爬。

### 砖块属性与破坏(Globals/tile_defs.json)
- **属性表** `Globals/tile_defs.json` 是单一来源:每块 name/type(墙/通道/液体/气体)/hp/explosion_decay/bullet_destroyable/explosion_destroyable/elastic/climb_speed/friction。编辑器副本 `editor/tile_defs.js` 由 `node editor/sync-tiles.js` 生成(file:// 下可靠)。
- 纹理 1-10 墙(hp1,不可破坏);11 梯子、12-14 锁链上中下 = 通道(climb_speed 1.6× 最快);15-18 树叶(墙,hp20,子弹/爆炸可破,弹性弱弹玩家);19-20 树干竖/横(墙,hp80,爆炸可破);21 水、22 水面 = 液体(无碰撞,可游)。爆炸衰减统一 0.75(水 0.25)、摩擦 1.0(现状不变)。
- 加载:`TileDefs.load_defs()`(level_0._ready);挡路 = `TileDefs.is_blocked`(非 0 且 type=wall),寻路/LOS/碰撞共用。
- **破坏**:`TileDefs.damage_tile(cell, dmg, "bullet"/"explosion")` → hp≤0 变空气(改 `MazeGenerator.current_grid` + `Level0.on_tile_destroyed` 清 3×3 瓦片 + 持久可破坏子格 2×2,标记所在分块下帧重建)。子弹撞树叶扣血;爆炸对树叶/树干按距离衰减×0.75 扣血。
- **攀爬**:玩家中心(或脚底)在通道格(梯子/锁链)「**刚按上**」主动攀附(不受重力):上爬 ×`tile.climb_speed`(梯 1.6/锁链 2.0),下降 ×`tile.climb_descent_speed`(梯 2.0);**锁链无下降倍率 → 按下自由落体**(解除攀附交给重力,不被空中抓回);松开挂住不坠落;**到顶 = 脚底进入梯子上方一格**(以脚底为参考格),再按上 = 跳离梯子;进入靠「刚按下上」而非按住 → 跳离后按着上也抓不回;攀附空闲可水平走离梯子;**仅锁链顶/底基座有薄碰撞条**(`CollisionBuilder.build_climb_ledges`,全宽 64×6px;梯顶不加,避免挡爬升)。
- **弹性**:碰树叶(elastic)被弱弹(PlayerParams.elastic_bounce=150)。

### 水
- **瓦片**:纹理 21 水 / 22 水面,`type=liquid`(无碰撞,`is_blocked`=false)。地图只画 21;水面(22)由 `Level0._paint_water` 自动派生(该格上方非 liquid → 水面层)。`WaterLayer`(水体)与 `WaterSurfaceLayer`(水面)两个 TileMapLayer;**水面起伏**由 `water_surface.gdshader` 做逐格正弦上下拉伸(锚底无缝、相位逐格错开,`amp/speed` 沿用 `GameParameters.water_sway_amp/speed`),水体层不挂 shader(水不流动)。
- **`Water` 助手**(Globals/water.gd,静态,不引 autoload,-s 可测):`is_in_water` / `surface_y_at`(所在列向上扫到最顶液体格的顶边) / `submerged`(中心低于水面线=没顶) / `feet_offset` / `water_mult`(爆炸×水格 decay) / `bullet_drag_factor`(子弹阻力系数)。约定:脚底(中心+半身)在水格 = 在水中;浮力弹簧把「身体中心」拉回水面线(半没入)。
- **主角**(`Scenes/Player/swim_component.gd`):水中跳过攀爬/重力/跳跃/下蹲/冲刺;左右=水平游(×`player_swim_speed`),上=上浮、下=下沉,无输入=浮力弹簧回水面。出水恢复普通物理。水下扣血未做。
- **敌人**(`EnemyBase._apply_water`):落水浮力回水面;水平朝 `_water_swim_dir()` 游(JumpBird/BlackBird 覆写为朝玩家,基类=漂着);**溺水**:没顶累计,`drown_delay`(5s)后每 `drown_interval`(1s)扣 `drown_damage`(5),浮在水面不算。FlyBird 寻路把水当障碍(`_bird_can_pass` 遇 liquid 不可走),但正下方是水仍可飞越。
- **爆炸衰减**:目标所在格是水 → 爆炸伤害/击退 × 该水格 `explosion_decay`(0.25,`Water.water_mult`)。LOS 遮挡 75% 不变。
- **子弹阻力**:子弹在水里 `velocity_vec *= exp(-water_bullet_drag·Δt)`(`Water.bullet_drag_factor`),玩家 + 敌人子弹共用。
- **水粒子**(`Scenes/Effects/water_fx.gd`,运行期挂主角 + 敌人):水中**移动**才喷;中心贴水面 → 溅水花,没入深 → 上浮气泡。

### 碰撞层(按位)
层1=地形、层2=玩家、层3=敌人。玩家/玩家子弹 mask=5(1+3);敌人占层 3(值4)、mask 侦测玩家。

### 编辑器工具
`editor/structure-editor.html` + `editor/smoke.js` 是独立浏览器地图编辑器(大图缩放/画笔),与 Godot 引擎无关。编辑 125×75 网格,**砖块纹理调色板(0-22)+ 2×2 砖形面板**(点四象限翻转或选预设 1/4/半/3/4/全砖);导入旧格式自动 2×2 转换,导出写 v3(`# cyrm-v3` + 每格 4 字符 [纹理 3 位 0xx][形状hex])。`node editor/smoke.js` 跑 Core 测试。

### 测试
无单测框架。`Tests/*.gd` 是 `extends SceneTree` 的冒烟/诊断脚本,用 `-s` 跑:`enemy_logic_smoke.gd` 为主(覆盖敌人 AI、环面数学、武器参数/命中、碰撞层、寻路/LOS、多弹丸),其余 seam_analyze/seam_screenshot/wrap_probe 是环面接缝诊断。写新测试注意: `-s` 阶段 autoload 尚未实例化,避免静态引用会连带预加载引用 autoload 的脚本(见 smoke 内注释)。
