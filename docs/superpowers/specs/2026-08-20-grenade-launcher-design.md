# 榴弹发射器设计

日期: 2026-08-20
状态: 待实现
相关系统: `WeaponBase`(武器基类 + 抛物线预览)、`BulletBase`(子弹物理 + 爆炸判定)、`player.gd` 武器槽位、`MazeGenerator.has_line_of_sight`(遮挡检测)

## 概述

新增第 5 把武器榴弹发射器(重型武器)。子弹为榴弹:轻微重力抛物线飞行、命中敌人直接 10 伤并立即爆炸、未命中则**碰撞停驻后**延时 0.5s 爆炸(**引信碰撞后才开始计时**,不在飞行中累计)。爆炸:中心 35 伤、圆形范围、向外冲击波、分段函数衰减、遮挡检测、**有友伤**。使用 heavy_aim 预瞄(狙击同款按住-松开发射),但预瞄画的是**抛物线轨迹弧线 + 爆炸点标记**,取代直线激光。

直接命中敌人的榴弹: 10(直接) + 爆炸中心 35 = **45 总伤**。

设计原则(本次会话已与用户确认):
- **一脚本多场景**: `BulletBase`/`WeaponBase` 加 @export 参数,榴弹/榴弹发射器各为一个新 .tscn 填参,不新增子类。
- **爆炸特效 = 独立纯视觉场景**(`explosion.tscn`),不含伤害逻辑;伤害判定在子弹侧。
- **爆炸动画先占位**(程序化白闪光),用户后补手绘 `FX_Explosion.png` 六帧,届时替换视觉节点,判定代码不改。
- 初速/重力是发射参数,归武器(与现有 `bullet_speed` 同惯例),发射时注入子弹;爆炸特性(`explodes`/引信/爆炸威力)归子弹。
- **预瞄只是参考**: 弧线用武器自己的参考时长 `preview_time` 绘制,不读子弹引信;真实爆炸时机由子弹 `fuse_time` 决定,两者允许有偏差(玩家按预览适应)。

## 1. `BulletBase` 爆炸支持(`bullet_base.gd`)

新增 @export(默认值保证现有武器/敌方子弹行为不变):

- `@export var explodes: bool = false` — 是否爆炸弹
- `@export var direct_hit_damage: int = 10` — 命中敌人的直接伤害
- `@export var fuse_time: float = 0.5` — 未命中时的延时引信(秒)
- `@export var explosion_radius: float = 128.0` — 爆炸范围(圆形半径)
- `@export var explosion_damage: int = 35` — 爆炸中心伤害
- `@export var explosion_knockback: float = 900.0` — 爆炸中心冲击力
- `@export var explosion_visual: PackedScene = null` — 爆炸特效场景(占位 `explosion.tscn`)

`_physics_process` 改造:

- 重力上移: `if gravity_factor > 0.0: velocity_vec.y += GameParameters.gravity0 * gravity_factor * delta`(原只在 EnemyBullet;EnemyBullet 覆写 `_physics_process` 且不调 super,行为不变,保持原样)。
- 引爆时序(**引信碰撞后才开始计时**,不在飞行中累计):
  1. `move_and_collide` 命中敌人且 `explodes` → `hurt(direct_hit_damage, 弹道方向)` 直接伤 + **立即** `_explode()` + `queue_free()`(命中敌人无延时)。
  2. `move_and_collide` 撞墙且 `explodes` → **停住**(`velocity_vec = Vector2.ZERO`),置引信开启标记,**此刻才开始累计** `fuse_time`,到点 `_explode()` + `queue_free()`。
  3. 飞行中不累计引信;兜底: `traveled >= max_range` 时 `_explode()` + `queue_free()`(bullet_range 填很大,正常情况撞墙先到)。
  4. `explodes=false` 时走原逻辑(命中敌人 `source.apply_hit`、其他撞墙消失、超射程消失),逐位不变。

`_explode()`:
- `explosion_visual` 非空 → 在 `global_position` 实例化特效(纯视觉,自毁)。
- `Explosion.apply_aoe(global_position, explosion_radius, explosion_damage, explosion_knockback)`。

## 2. 爆炸 AoE 判定(`Globals/explosion.gd`)

`class_name Explosion extends RefCounted`,静态方法,可被冒烟测试直接调用:

```
static func apply_aoe(center: Vector2, radius: float, max_damage: int, max_knockback: float) -> void
```

- **遍历敌人**: `get_nodes_in_group("enemies")`,环面距离 `toroidal_delta_px(center, e.pos).length()` ≤ radius 才结算。
- **分段函数**(伤害与冲击力共用形状,数值独立):
  - `d < 内圈(=0.35×radius)` → 满值(35)
  - `内圈 ≤ d < radius` → 线性衰减到 0
  - `d ≥ radius` → 0
- **遮挡检测**: `MazeGenerator.has_line_of_sight(cell_of(center), cell_of(target))` 不通 → **0 伤害(硬掩体)**。`current_grid` 为空(离线/测试无地图)时跳过遮挡判定,避免误全挡。
- **冲击波**: 方向 = `toroidal_delta_px(center, target).normalized()`(向外),力度按同一分段。敌人走 `hurt(dmg, dir, knock)`。
- **友伤**: 玩家在半径内且 LOS 通且未倒地 → `player.take_hit(center, dmg)`(take_hit 按 source 方向推 = 天然向外冲击波,玩家也被推)。

## 3. 新场景 `Scenes/Weapons/grenade_bullet.tscn`

`CharacterBody2D` + `bullet_base.gd`。节点:`Sprite2D`(**榴弹贴图先占位**——小圆点/复用 Bullets.png 区域染色,用户后画)、`CollisionShape2D`(小圆 `CircleShape2D`)。

检查器(爆炸特性,属子弹):
`explodes=true`、`direct_hit_damage=10`、`fuse_time=0.5`(爆炸属性,纯属子弹,武器不注入)、`explosion_radius=128`、`explosion_damage=35`、`explosion_knockback=900`、`explosion_visual=explosion.tscn`。`collision_mask=5`(地形+敌人,不含玩家 → 榴弹本体不直击玩家,友伤只来自爆炸)。

初速/重力由武器发射时注入(`bullet_speed`/`bullet_gravity`);引信与爆炸威力是子弹自身属性,不受武器影响。

## 4. 新场景 `Scenes/Weapons/grenade_launcher.tscn`

`Node2D` + `weapon_base.gd`,参数(参考 m82a1):

| 参数 | 值 | 说明 |
|---|---|---|
| tier | 2 (HEAVY) | 重型武器 |
| weapon_name | "Grenade Launcher" | 显示名 |
| full_auto | false | 半自动 |
| heavy_aim | true | 按住预瞄、**松开发射**(同狙击) |
| preview_arc | true | 弧线轨迹预览(取代直线激光) |
| bullet_scene | `grenade_bullet.tscn` | 发射自己的子弹 |
| bullet_speed | 1500.0 | 榴弹初速(比子弹慢,0.5s 引信内水平约 750px) |
| bullet_range | 2000.0 | 射程填很大,防提前消失 |
| bullet_gravity | 0.3 | 轻微重力下坠 |
| damage | 10 | 与 direct_hit_damage 一致(爆炸弹不走 weapon.apply_hit,仅占位/显示) |
| recoil_push | 900.0 | 重后坐 |
| recoil_kick | 10.0 | 枪口上跳 |
| cam_shake | 8.0 | 镜头抖动 |
| cam_shake_time | 0.2 | 抖动时长 |
| move_penalty | 0.5 | 预瞄或冷却中减速 |
| jump_penalty | 0.6 | |
| penalty_mode | WHILE_AIM_OR_COOLDOWN (2) | 同狙击 |
| pitch_clamp_deg | 80.0 | 可大幅上抛 |

节点:`Sprite2D`(**发射器贴图先占位**,复用 Weapons.png 某区域,用户后画)、`Muzzle`(Marker2D)。

## 5. `WeaponBase` 弹道预览(`weapon_base.gd`)

- `const BULLET_SCENE` → `@export var bullet_scene: PackedScene`(默认仍 `bullet.tscn`,现有武器不变)。
- 新增 `@export var bullet_gravity: float = 0.0`、`@export var preview_arc: bool = false`、`@export var preview_time: float = 0.5`(预瞄参考时长,仅供画弧线;真实爆炸时机由子弹 `fuse_time` 决定,预瞄只是参考)。
- `fire()`: `var b = bullet_scene.instantiate(); b.setup(...); b.gravity_factor = bullet_gravity`(初速/重力由武器注入;爆炸属性走子弹场景)。
  **不注入 fuse_time** —— 引信是子弹的爆炸属性,预瞄用 `preview_time` 画弧,二者允许偏差。
- `_update_laser()`: `preview_arc=true` 时改画弧线:
  - 采样: `p0 = muzzle.global_position`, `v0 = _clamped_aim_dir() * bullet_speed`, `g = bullet_gravity * gravity0`,步长 1/60s,采样到 `t = preview_time`,途中任一格 SOLID 即截断(榴弹撞墙停住,停在爆炸点)。转武器局部坐标填入 `Line2D.points`。
  - 弧线末端画**爆炸点标记**(小 Sprite2D/ColorRect),让玩家看清落点。
  - `preview_arc=false` 时维持原直线激光,逐位不变。

## 6. 第 5 槽接入

- `player.gd`: `WEAPONS` 加 `"5": "res://Scenes/Weapons/grenade_launcher.tscn"`;切枪循环 `["1","2","3","4"]` → `["1","2","3","4","5"]`。
- `project.godot` `[input]`: 加动作 `"5"`(键盘 5,physical_keycode=53)。

## 7. 爆炸动画占位(`explosion.tscn`)

纯视觉节点,播完自毁,不含伤害逻辑:
- `Node2D` + `Sprite2D`(程序生成软圆白贴图,`Image.create` 径向渐变)+ `Tween`:scale 0.4→1.6、modulate.a 1→0,~0.35s → `queue_free`。
- 用户后补 `FX_Explosion.png`(200×200 画布、64×64 帧区、6 帧 3×2 排列)后,将 `Sprite2D` 换成 `AnimatedSprite2D + SpriteFrames`(一次性不循环),判定代码零改动。

## 8. 不改的文件

- `enemy_bullet.gd`(覆写 `_physics_process` 不调 super,保持原样)。
- 现有四把武器场景(`bullet_scene` 默认 `bullet.tscn` 不变)。
- `enemy_base.gd` / `player.gd` 移动与战斗逻辑(除 6 节切枪循环)。

## 9. 验证

1. `Godot 4.7.1 --headless --import` 构建检查(weapon_base/bullet_base 改动解析)。
2. 冒烟测试新增(纯函数,直接调 `Explosion.apply_aoe`):
   - 中心敌人 = 35,半径边缘 ≈ 0,墙后敌人 = 0(LOS 遮挡),范围内玩家掉血(友伤)。
   - `BulletBase` 默认 `explodes=false` 行为不变 → SMOKE OK。
3. playtest: 按 5 切枪 → 按住看弧线 + 爆炸点标记 → 松开发射抛物线 → 命中敌人 10+立即爆炸 → 撞墙停驻 0.5s 后才炸(飞行中不炸) → 墙后敌人不受伤 → 自己站在爆炸范围内掉血被推。
