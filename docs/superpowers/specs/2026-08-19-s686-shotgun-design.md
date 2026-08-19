# S686 霰弹枪设计

日期: 2026-08-19
状态: 待实现
相关系统: `WeaponBase`(现有武器基类)、`BulletBase`(子弹物理)、`player.gd` 武器槽位

## 概述

新增第 4 把武器 S686 霰弹枪:轻武器、半自动、射程近、一次射出 8 颗弹丸(±8° 散布)、单丸 4 伤(贴脸全中 = 32)、中上后坐。不引入换弹系统(用户选定简化方案:半自动 + `fire_cooldown` 限速)。

设计原则: 复用现有 `WeaponBase`/`BulletBase`,不新增弹药系统。在 `WeaponBase.fire()` 加多弹丸支持(默认 `pellet_count=1` 行为不变),霰弹枪作为新场景用 @export 参数配置。

## 1. `WeaponBase` 多弹丸支持(`weapon_base.gd`)

新增 @export(默认值保证现有武器行为不变):

- `@export var pellet_count: int = 1` — 每次开火弹丸数(>1 为霰弹)
- `@export var spread_deg: float = 0.0` — 弹丸散布半角(度)

`fire()` 改为:

```
fire_cd_timer = fire_cooldown
base_dir = _clamped_aim_dir()          # 瞄准方向(含仰角钳制)
for i in range(pellet_count):
    ang = base_dir.angle() + randf_range(-spread_deg, spread_deg)
    dir = Vector2.from_angle(ang)
    生成 BulletBase, setup(dir, ...), 出生在 muzzle, add_child
# 后坐/枪口上跳/镜头抖动只触发一次(循环外,与旧版一致)
```

`pellet_count=1, spread_deg=0` 时 `randf_range(0,0)=0`,角度 = base_dir,与旧版逐位一致。

## 2. 新场景 `Scenes/Weapons/shotgun_s686.tscn`

`Node2D` + `weapon_base.gd`,参数:

| 参数 | 值 | 说明 |
|---|---|---|
| tier | 0 (LIGHT) | 轻武器 |
| weapon_name | "S686" | 显示名 |
| full_auto | false | 半自动 |
| fire_cooldown | 0.5 | 双管手感(慢射速,无换弹) |
| bullet_speed | 1100.0 | 弹丸速度 |
| bullet_range | 400.0 | 射程近 |
| bullet_size | 0.5 | 小弹丸 |
| pellet_count | 8 | 每发 8 丸 |
| spread_deg | 8.0 | ±8° 散布 |
| damage | 4 | 单丸 4 伤(贴脸 8 丸=32,一发带走 25hp FlyBird) |
| impact | 180.0 | 单丸小击退 |
| recoil_push | 450.0 | 中上后坐(玩家被推) |
| recoil_kick | 11.0 | 枪口上跳(视觉) |
| cam_shake | 5.0 | 镜头抖动 |
| cam_shake_time | 0.1 | 抖动时长 |
| move_penalty | 0.9 | 轻武器轻微减速 |
| penalty_mode | WHILE_FIRING | 开火冷却中减速 |
| pitch_clamp_deg | 55.0 | 仰角钳制(同步枪) |

节点: `Sprite2D`(复用步枪贴图区域 `Rect2(108,2,55,20)` 占位,后续换霰弹枪贴图)、`Muzzle`(Marker2D,枪口)。

## 3. 第 4 槽接入

- `player.gd` `WEAPONS` 加 `"4": "res://Scenes/Weapons/shotgun_s686.tscn"`;`_unhandled_input` 切枪循环 `["1","2","3"]` → `["1","2","3","4"]`。
- `project.godot` `[input]` 加动作 `"4"`(键盘 4,physical_keycode=52)。

## 4. 平衡说明

敌人无无敌帧(`EnemyBase.hurt` 即时扣血),8 丸全中会一次结算 32 伤害。为此单丸 4 伤、散布 ±8°、射程仅 400px —— 贴脸威慑强,中远命中率锐减,靠散布与短射程控制爆发。后续若要调,全部是武器场景 @export 参数。

## 5. 不改的文件

- `bullet_base.gd`、`enemy_base.gd`(敌人 iframes 不加,用户已确认)
- 现有三把武器场景

## 6. 验证

1. `Godot 4.7.1 --headless --import` 构建检查(weapon_base 改动解析)
2. 冒烟测试: weapon_base 默认 `pellet_count=1` 行为不变,应 SMOKE OK
3. playtest: 按 4 切枪,开火看 8 丸 ±8° 散布、短射程消失、中上后坐(玩家被推+枪口上跳+镜头抖)
