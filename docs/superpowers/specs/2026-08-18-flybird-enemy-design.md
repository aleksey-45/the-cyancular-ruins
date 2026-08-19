# FlyBird 敌人设计

日期: 2026-08-18
状态: 待实现
相关敌人: EnemyJumpBird(现有参考)、EnemyFlyBird(本设计实现)

## 概述

FlyBird 是一只飞行敌人,睡眠于出生点;视野很远(屏幕外可见玩家),被玩家接近后起飞、
沿走廊寻路飞向玩家斜上方、抛射重力抛物线子弹;血量低于 25% 时转为自杀式冲撞;玩家
逃离追击范围或寻路失败时返程回家入睡。

设计原则: 与 EnemyJumpBird 同风格(EnemyBase 子类 + EnemyParams 参数 + `_ai(delta)`
状态机 + 场景 @export 战斗数值),复用 BulletBase 的子弹物理逻辑,新增碰撞层以分离
敌我子弹的命中目标。

## 1. 状态机

```
SLEEP ────(玩家距鸟 ≤ wake_radius, 播 wake_up 一次性动画)────▶ TAKE_OFF
TAKE_OFF ──(take_off 动画 + 斜上初速, 重力滑翔 take_off_time 秒)──▶ FLY
FLY ────(HP≥25% 且距玩家 ≤ shoot_range)────▶ SHOOT
FLY ────(HP<25% 且与玩家 LOS 无障碍 且 ≤ charge_range)────▶ CHARGE
SHOOT ────(距玩家 > shoot_range + 余量)────▶ FLY          (重新接近)
SHOOT ────(HP 跌穿 25%: LOS 通 → CHARGE; 否则 intent=CHARGE → FLY)
任何飞行状态 ──(玩家距出生点 > home_range 或 BFS 无路)──▶ RETURN
RETURN ──(BFS 回出生点 → 到达后重力下降、落地、播 fall_asleep)──▶ SLEEP
CHARGE ──(撞墙 / 撞玩家 / 超时 charge_timeout)──▶ 自毁
死亡 ──(重力开启坠落, 落地后消失)
```

- 行为开关 `intent: enum { SHOOT, CHARGE }`:血量低于 25% 是一次性的单向切换,
  一旦进入 CHARGE intent 不再回退(HP 只减不增)。
- 所有飞行状态 `use_gravity = false`;地面/起飞/坠落/返程落地 `use_gravity = true`。
- 面朝方向: 按水平方向 flip_h(与 JumpBird 一致,精灵帧朝右)。

### 1.1 SLEEP(默认)

- 地面: 播 `sleeping`,重力开启。出生时由 spawner 放在格中心,自然下落落地。
- 唤醒: `toroidal_dist_to_player() <= wake_radius` → 播 `wake_up`(一次性),
  计时结束后切 TAKE_OFF。

### 1.2 TAKE_OFF(起飞)

- 播 `take_off`,设初速 `(朝玩家水平分量, 上跳分量)`(斜上滑翔),重力开启。
- 计时 `take_off_time` 到 → `use_gravity = false`,播 `flying`,切 FLY。

### 1.3 FLY(飞行寻路)

- 悬停高度 = 路径格中心 − `hover_altitude`(≈40px;走廊净高对玩家角色足够,鸟占用
  同一垂直带,不会撞低天花板)。
- 沿 BFS 路径逐格飞,目标点 = 下一格中心 − `hover_altitude`,到格判定 `arrival_radius`。
- 按 `repath_interval` + 随机错峰重算路径(见 §2)。
- 出口:
  - `intent==SHOOT` 且 `toroidal_dist_to_player() <= shoot_range` → SHOOT
  - `intent==CHARGE` 且 LOS 通 且 ≤ `charge_range` → CHARGE
  - 玩家距出生点 > `home_range` 或 BFS 无路 → RETURN

### 1.4 SHOOT(斜上悬停抛弹)

- 锚点 = 玩家位置 + `Vector2(侧向 · hover_offset_x, −hover_offset_y)`。
  侧向在进入 SHOOT 时取鸟相对玩家所在的水平一侧(避免穿越玩家头顶),本次
  SHOOT 会话内固定。
- 锚点格为 SOLID(玩家贴墙)时换另一侧;两侧皆堵则原地悬停(已在射程内)。
- 每帧向锚点修正位置(限速 fly_speed),按 `shoot_cooldown` 抛平抛子弹(见 §3)。
- 出口:
  - `toroidal_dist_to_player() > shoot_range + 余量` → FLY(重新接近、重新选侧)
  - 玩家距出生点 > `home_range` → RETURN
  - HP 跌穿 25%: LOS 通 → CHARGE;否则 `intent=CHARGE` → FLY(拉距离找 LOS)

### 1.5 CHARGE(自杀冲撞)

- 锁定起冲方向 = 朝玩家当前坐标(冲撞期间不追踪预测),`charge_speed` 高速直线,
  无重力,播 `dashing`。
  (注:场景 `dashing` 动画帧需填充——复用 `flying` 的一帧,否则冲撞时不可见并报
  "frames is empty" 警告。)
- `_physics_process` 在 super 之后检查 `get_slide_collision_count() > 0`:
  - 撞到玩家组 → `player.take_hit(global_position, charge_damage=5)` → 自毁
  - 撞到地形 / 超时 `charge_timeout`(未撞到任何东西) → 自毁
- 冲撞即赴死,不回头。被玩家提前射杀仍走正常死亡(§5)。

### 1.6 RETURN(放弃返程)

- BFS 回出生点格,悬停高度同 FLY。
- 到达后 `use_gravity = true`,垂直下落,落地播 `fall_asleep`,计时结束 → SLEEP(播 `sleeping`)。
- 返程途中不因玩家重新接近而反悔(回家后 SLEEP 再自然唤醒)。

## 2. 寻路(BFS + 网格)

- `MazeGenerator` 新增:
  - `static var current_grid: Array[Array]` — `level_0._ready` 加载地图后赋值;
    空网格时 BFS 视为无路(冒烟测试/无地图环境安全)。
  - `static func bfs_path(grid, from_cell, to_cell, max_visit) -> Array[Vector2i]` —
    环面 4 邻居 BFS,EMPTY 可走,返回起点到目标的格序列(不含起点,含目标);
    **限量访问 max_visit**(默认 8000 格),超限或不可达返回空。
  - `static func has_line_of_sight(grid, from_cell, to_cell) -> bool` —
    网格 Bresenham(按环面最短方向步进),途中任何 SOLID 即阻断。用于冲撞判定。
- 性能: 每只鸟 `repath_interval`(0.5s)+ 每实例随机相位错峰重算;BFS 命中目标即
  早停,限量访问兜底最坏情况。40 只鸟同帧重算的最坏代价受 max_visit 上界约束。
- FLY 目标格 = 玩家所在格(玩家必在 EMPTY 格);玩家格异常(SOLID)时取最近的
  EMPTY 邻居格。

## 3. 敌方平抛子弹(新 EnemyBullet)

- 新脚本 `Scenes/Enemies/enemy_bullet.gd`(`class_name EnemyBullet extends BulletBase`),
  复用基类 `setup()/velocity_vec/_wrap()/gravity_factor`(基类注释"以后敌方弹药可>0"
  正是预留此用途)。
- 新场景 `Scenes/Enemies/enemy_bullet.tscn`: 镜像 bullet.tscn 的三节点结构
  (CharacterBody2D + RectangleShape2D + Sprite2D),`collision_mask = 3`(层1地形 +
  层2玩家,不含层3敌人 → 不撞自己/其他敌人),`collision_layer = 0`,贴图复用
  Bullets.png、染色 `EnemyParams.FlyBird.bullet_color`(橙色)。
- `launch(velocity, rng, col, dmg, grav)`: 直接设初速向量、射程、颜色、伤害、重力倍率。
- 覆写 `_physics_process`: 每帧 `velocity.y += GameParameters.gravity0 * gravity_factor * delta`
  → `move_and_collide` → 命中玩家组 → `take_hit(global_position, damage=2)` → 消失;
  命中地形 / 超射程 → 消失。伤害 2,纯普通投掷弹,无附加效果。
- 平抛落点计算(开火时,`SHOOT` 状态):
  - 落差 `drop = 玩家.y − 鸟.y`(玩家在鸟下方为正;玩家高于鸟时夹到下限,弹道偏近属预期);
  - 下落时间 `t = sqrt(2·dy / gravity0)`;
  - 预测落点 `pred = 玩家位置 + 玩家.velocity · t`(玩家"即时速度"超前量);
  - 水平环面位移 `dx = 鸟→pred 的水平分量`;
  - 初速 `v0 = dx / t`,夹 `[bullet_min_speed, bullet_max_speed]`;
  - 发射初速 = `Vector2(v0 · 方向符号, 0)`(纯水平平抛),`gravity_factor = 1.0`。

## 4. 碰撞层重构(敌我分层)

现状: 玩家和敌人同在层 2,玩家子弹 `mask=3`(层1+2)打敌人但无法区分敌我;
敌方子弹若用同样 mask 会打到所有敌人与自己。

改动(最小侵入):
- 敌人占层 **2 → 3**: `EnemyJumpBird.tscn`、`EnemyFlyBird.tscn` 的 `collision_layer = 3`。
- `Scenes/Player.tscn`: `collision_mask 3 → 5`(层1地形 + 层3敌人,玩家仍会撞敌人)。
- `Scenes/Weapons/bullet.tscn`: `collision_mask 3 → 5`(打地形 + 敌人,不再打玩家)。
- 敌方子弹 `collision_mask = 3`(层1地形 + 层2玩家)。
- `EnemyBase._setup_contact_area`: `collision_mask = 2`(检测玩家)不动。
- 副作用: 敌人之间不再互相物理碰撞(层3 互不可见)——对飞行鸟是利好(不互相卡住),
  对 JumpBird 无感知影响。

## 5. 受击 / 死亡

- `EnemyBase._physics_process` 加一行守卫: `contact_damage <= 0` 时跳过 `take_hit`
  (否则 0 伤害会消耗玩家 iframe 并击退玩家)。
- `EnemyFlyBird` 场景 `contact_damage = 0`: 鸟的威胁只来自投弹(2)与冲撞(5),不靠碰触。
- 覆写 `hurt()`: HP≤0 → `is_dead = true`,`collision_layer = 0`(不再被子弹/敌人碰撞),
  保留 `collision_mask = 3`(仍需落地),`use_gravity = true`,按击退方向坠落。
- 覆写 `_physics_process`: `is_dead` 时手动重力下坠 + `move_and_slide`,落地 → `queue_free()`。
  (基类 dead 时直接 return,不处理物理;JumpBird 以死亡动画覆盖,本设计以坠落替代。)

## 6. 参数表(EnemyParams.FlyBird,全部可调)

| 常量 | 值 | 说明 |
|---|---|---|
| wake_radius | 1500 | 视野半径,屏幕外可见 |
| home_range | 2200 | 玩家距出生点超此值 → 放弃返程 |
| hover_altitude | 40 | 巡航高度(路径格上方 px) |
| hover_offset_x | 260 | 斜上锚点水平偏移 |
| hover_offset_y | 240 | 斜上锚点垂直偏移(上) |
| fly_speed | 280 | 飞行移动速度 |
| take_off_speed | 480 | 起飞斜上初速 |
| take_off_time | 0.5 | 起飞滑翔时长 |
| shoot_range | 520 | 进入射击距离 |
| shoot_reacquire_margin | 160 | 出射程余量(重接近阈值) |
| shoot_cooldown | 1.4 | 抛弹间隔 |
| bullet_damage | 2 | 投弹伤害 |
| bullet_range | 1600 | 投弹射程 |
| bullet_gravity | 1.0 | 投弹重力倍率 |
| bullet_color | 橙 (1,0.6,0.2) | 投弹贴图染色 |
| bullet_min_speed | 260 | 平抛初速下限 |
| bullet_max_speed | 1400 | 平抛初速上限 |
| bullet_min_drop | 30 | 落点落差下限 |
| charge_hp_fraction | 0.25 | 冲撞血量阈值(HP<25%) |
| charge_range | 1300 | 冲撞触发距离(且需 LOS) |
| charge_speed | 950 | 冲撞速度 |
| charge_timeout | 2.5 | 冲撞超时 → 自毁 |
| charge_damage | 5 | 冲撞撞玩家伤害 |
| repath_interval | 0.5 | 重寻路间隔 |
| arrival_radius | 50 | 到路径格判定 |

场景 @export: `hp = 25`(25% = 6.25,即 HP≤6 冲撞)、`contact_damage = 0`、
`knockback_strength = 200`(同 JumpBird)、`scale = 2.0`(用户指定;节点缩放作用于
精灵与碰撞多边形)。

## 7. 文件改动清单

新建:
- `Scenes/Enemies/enemy_fly_bird.gd` — FlyBird 状态机(extends EnemyBase)
- `Scenes/Enemies/enemy_bullet.gd` — EnemyBullet(extends BulletBase)
- `Scenes/Enemies/enemy_bullet.tscn` — 敌方投弹场景

修改:
- `Scenes/Enemies/EnemyFlyBird.tscn` — 挂脚本、`collision_layer=3`、`collision_mask=3`、
  `hp=20`、`contact_damage=0`、`scale=2.0`、两个碰撞多边形(站立/飞行)按状态切换
- `Scenes/Enemies/EnemyJumpBird.tscn` — `collision_layer 2→3`
- `Scenes/Player.tscn` — `collision_mask 3→5`
- `Scenes/Weapons/bullet.tscn` — `collision_mask 3→5`
- `Scenes/Enemies/enemy_base.gd` — 接触伤害 `contact_damage<=0` 守卫
- `Scenes/Enemies/enemy_spawner.gd` — `TYPES` 注册 `"fly_bird"`
- `Globals/enemyParams.gd` — 新增 `class FlyBird`
- `Globals/maze_generator.gd` — `static current_grid` + `bfs_path` + `has_line_of_sight`
- `Scenes/level_0.gd` — `MazeGenerator.current_grid = grid`
- `Tests/enemy_logic_smoke.gd` — 增加 FlyBird 冒烟段(见 §8)

## 8. 冒烟测试扩展

在 `Tests/enemy_logic_smoke.gd` 追加(设 `MazeGenerator.current_grid` 为小型测试网格):
- FlyBird 场景加载 / 实例化 / 初始 `state == SLEEP` / `enemies` 组 / ContactArea 创建
- 敌方子弹: 加载、重力下坠(速度 y 随时间增大)、命中玩家组扣血 2、命中地形消失
- FlyBird 受击扣血 → HP≤0 进入死亡坠落,落地后消失
- BFS: 全通网格有路 / 墙隔断无路 / 限量访问不超预算
- LOS: 直线无阻挡 / 墙阻挡

测试由用户运行(项目惯例)。

## 9. 权衡与边界

- 玩家高于鸟(站在高处平台)时,`bullet_min_drop` 兜底下落时间偏小、落点偏近,
  抛弹大概率落空 —— 鸟随后会重新接近找更优高度,属预期。
- 冲撞未命中(玩家闪避)时超时自毁 —— 玩家风筝鸟即白赚击杀,属设计意图。
- 返程中不反悔: 避免 RETURN/SLEEP 与重新追踪反复横跳;回家后自然再唤醒。
- 敌人不再互相碰撞: 可接受,且避免飞行鸟互相堵路。
