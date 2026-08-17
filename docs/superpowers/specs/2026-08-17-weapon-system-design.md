# 武器系统重构设计（2026-08-17）

## 背景与动机

当前武器（枪）是硬编码在 `Player.tscn` 里的一个 `Gun` 节点（`player_gun.gd`），
参数全部堆在 `GameParameters`。未来会有多种可拾取/丢弃/替换的装备和武器，
需要把武器拆成独立系统。本次只做**架构 + 三种模板各一把枪**，捡拾/丢弃交互留到以后，
但架构需天然支持。

## 目录结构

```
Scenes/Weapons/
├─ weapon_base.gd       # WeaponBase extends Node2D —— 通用枪械逻辑
├─ bullet_base.gd       # BulletBase extends CharacterBody2D —— 统一子弹(物理体)
├─ bullet.tscn          # 通用子弹场景(CircleShape2D + script)
├─ pistol_test.tscn     # 轻模板：手枪,半自动
├─ rifle_test.tscn      # 中模板：步枪,全自动
└─ m82a1.tscn           # 重模板：狙击枪,激光预瞄单发
```

- `light_gun / medium_gun / heavy_gun` 是**模板(tier)**概念，不是文件名。
- 武器场景按实际枪名命名：`pistol_test`(轻)、`rifle_test`(中)、`m82a1`(重)。
- 旧 `Scenes/player_gun.gd`、`Scenes/bullet.gd`、`Scenes/Bullet.tscn` 被吸收删除。

## WeaponBase（武器场景 = WeaponBase + Sprite2D 本体 + Muzzle 枪口）

`class_name WeaponBase extends Node2D`，每把武器一个 `.tscn` 场景实例化它。

### @export 参数
| 参数 | 类型 | 说明 |
|---|---|---|
| `tier` | `enum Tier { LIGHT, MEDIUM, HEAVY }` | 模板分类（信息/分组用） |
| `weapon_name` | String | 显示名 |
| `full_auto` | bool | 是否按住连发（**每把枪独立**，不跟 tier 绑定） |
| `fire_cooldown` | float | 两次射击间隔 |
| `heavy_aim` | bool | 重武器：按住左键=激光预瞄，松开=发射 |
| `bullet_speed` | float | 弹速 |
| `bullet_range` | float | 子弹消失距离（射程） |
| `bullet_size` | float | 子弹体积（半径） |
| `bullet_color` | Color | 子弹外观颜色 |
| `damage` | int | 伤害（枪械管理） |
| `impact` | float | 子弹对敌人冲击力（击退力度，枪械管理） |
| `recoil_push` | float | 后坐力推角色向后的力度（蹲下时归零） |
| `recoil_kick` | float | 枪口上跳/精灵位移幅度 |
| `cam_shake` / `cam_shake_time` | float | 镜头抖动 |
| `move_penalty` | float | 移速倍率（0~1，1=不减） |
| `jump_penalty` | float | 跳跃速度倍率 |
| `penalty_mode` | `enum { NONE, WHILE_FIRING, WHILE_AIM_OR_COOLDOWN }` | 惩罚生效时机 |
| `laser_length` / `laser_color` | float / Color | 重武器激光线 |

### 行为
- `equip(player: Node2D)`：装备时缓存玩家引用、重置计时器、隐藏激光。
- `_process(delta)`：冷却倒计时；自动让玩家面向鼠标；计算瞄准俯仰；重武器更新激光；
  全自动按住时按冷却自动开火；枪口后坐复位。
- `_unhandled_input(event)`：
  - `heavy_aim`：`attack` 按下 → 进入预瞄（显示激光）；`attack` 松开 → 发射并退出预瞄。
  - 否则：`attack` 按下 → `try_fire()`。
- `try_fire()`：冷却就绪则 `fire()`。
- `fire()`：从枪口生成子弹（设 `bullet_speed/range/size/color` + `source=self`）；
  应用后坐力（推角色，蹲下时 `recoil_push=0` + 镜头抖动 + 枪口上跳）；重置冷却。
- `apply_hit(target, dir)`：`target.hurt(damage, dir, impact)` —— **伤害/冲击由枪械管理**。
- `cancel_aim()`：切枪/倒地时取消重武器预瞄。
- `get_movement_multiplier() -> Vector2`：返回 `(move_mult, jump_mult)`，玩家每帧读取。
- `clamp_pitch()` / `_aim_world_dir()`：从旧 `player_gun.gd` 迁入（含 `PostProcess.crop_scale`
  与相机基准位置）。

## BulletBase（统一子弹，玩家与未来敌人子弹共用）

`class_name BulletBase extends CharacterBody2D`。

### 子弹只管理物理属性（开火时由武器设置）
- `speed`（速度）
- `size`（体积）
- `gravity_scale`（重力下坠，枪械=0）
- `breaks_terrain`（能否破坏地形，当前否）
- `has_aoe`（是否有范围伤害，当前否）

**子弹不含伤害**。命中敌人时回调 `source.apply_hit(target, velocity_vec)`，
由发出它的武器决定伤害与冲击。这样敌方子弹以后用同一 BulletBase + 敌人自己的
`apply_hit`（对称）。

> ⚠ 边界：切枪时旧武器的在途子弹，其 `source` 可能已被 `free()`。
> 命中回调前用 `is_instance_valid(source)` 守卫——此时子弹无害消失，不报错。

### 行为
- `_ready`：按 `size`/`bullet_color` 生成简单子弹贴图。
- `_physics_process`：`move_and_collide`；命中敌人组 → `source.apply_hit(...)`；
  命中墙体且 `breaks_terrain=false` → 消失；超 `range` → 消失。
- 玩家锚定取模（沿用 `MazeGenerator.anchor_to_nearest`，与敌人一致）。

## 对敌伤害接口扩展

`EnemyBase.hurt(damage, knock_dir, knock_strength := 0.0)`：
`knock_strength <= 0` 时回落为敌人自身 `knockback_strength`。`_apply_hit` 同步扩展。
`enemy_jump_bird.gd` 的 `hurt` 覆写同步透传。

## Player 改造

- `Player.tscn`：删除硬编码 `Gun` 节点 → 新增 `WeaponSlot`（Node2D，原枪位置）。
- `player.gd`：
  - `@export var weapon_slot: Node2D`；`var _weapon: WeaponBase`。
  - 武器注册表：`{"1": pistol_test.tscn, "2": rifle_test.tscn, "3": m82a1.tscn}`。
  - `_ready` 默认装备 `pistol_test`。
  - `_equip_weapon(scene_path)`：释放旧武器、实例化新武器挂到 `WeaponSlot`、`equip(self)`。
  - `_unhandled_input`：`1/2/3` 动作按下 → 切枪（倒地时忽略）；保留 `R` 重开。
  - `_physics_process`：每帧读 `_weapon.get_movement_multiplier()` 应用移速/跳跃惩罚。
  - 后坐力：武器直接 `player.velocity.x -= facing * recoil_push`；蹲下(`is_squat`)时无。
  - 倒地：`_weapon.cancel_aim()` 并停止射击。

## 输入

- 开火：现有 `attack`（左键）。武器在 `_unhandled_input` 监听按下/松开（重武器需松开）。
- 切枪：新增输入动作 `1`/`2`/`3`（在 project.godot 加**空动作占位**，键位由用户映射）。
  风格与现有 `R`/`attack`/`toggle_barrel` 一致（`_unhandled_input` + `event.is_action_pressed`）。

## GameParameters 清理

- 删除已归武器的参数：`fire_cooldown`、`recoil_kick`、`recoil_time`、`cam_shake`、
  `cam_shake_time`、`bullet_damage`、`bullet_speed`、`bullet_range`、`bullet_radius`。
- 保留：`aim_pitch_deg`（公共俯仰钳制角）。

## 三把枪起始数值（手感后续调）

| | `pistol_test`(轻) | `rifle_test`(中) | `m82a1`(重) |
|---|---|---|---|
| 开火 | 半自动 | 全自动 | 激光预瞄单发 |
| fire_cooldown | 0.12s | 0.25s | 1.2s |
| bullet_speed | 900 | 1200 | 2400 |
| bullet_range | 600 | 1200 | 3000 |
| damage | 1 | 2 | 6 |
| impact | 60 | 150 | 500 |
| recoil_push | 0 | 30 | 160 |
| move/jump_penalty | 1.0(无) | 0.75(射击期间) | 0.55(瞄准+冷却期间) |

## 测试与验证

- 更新 `Tests/enemy_logic_smoke.gd`：子弹场景路径改 `Weapons/bullet.tscn`；
  `clamp_pitch` 断言改引用 `WeaponBase.clamp_pitch`。
- 新增武器冒烟测试：实例化三把武器场景、检查参数、装备后开火一发、
  验证子弹命中敌人应用 `damage`/`impact`。
- headless 全场景冒烟 + 真实渲染截图确认枪械正常渲染/开火。

## 不在本次范围

- 捡拾/丢弃/替换交互（架构已支持，交互后续做）。
- 敌方子弹（BulletBase 已支持，敌人目前无远程攻击）。
- 破坏地形 / 范围伤害子弹（字段已预留，置 false/无）。
