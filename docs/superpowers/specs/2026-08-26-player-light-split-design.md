# player.gd 轻量拆分设计

日期:2026-08-26
状态:已与用户确认

## 背景与目标

`Scenes/Player/player.gd` 现为 448 行,混合了 6 块职责:物理移动(约 170 行)、攀爬(~60)、战斗(生命/无敌/击退/倒地)、武器管理、姿态动画状态机、输入分发。

目标:把最自包含的 3 块(攀爬 / 战斗 / 武器)抽成 Player.tscn 子节点脚本,根脚本降到约 250 行。**保持行为与公开接口完全不变**。

## 方案:轻量拆分(用户已选定,不用完整组件化)

Player.tscn 新增 3 个空 Node 子节点:

```
Player (CharacterBody2D, player.gd 根 → ~250 行:移动+姿态+编排)
├── AnimatedSprite2D
├── CollisionShape2D_{stand,move,fly,charge,squat}
├── WeaponSlot
├── Climb    (climb_component.gd,  class_name ClimbComponent)    ~65 行
├── Combat   (combat_component.gd, class_name CombatComponent)   ~85 行
└── Weapons  (weapon_component.gd, class_name WeaponComponent)   ~45 行
```

新脚本放 `Scenes/Player/` 下。组件持有 `body`(父 Player)引用,在 `_ready` 里 `get_parent()` 获取。

## 组件职责与接口

### ClimbComponent(攀爬)
- 拥有:`_latched`(攀附状态,含脚底偏移)。
- `update(mult: Vector2, delta: float, is_squat: bool) -> bool`:返回是否正在垂直攀爬(与现 `_update_climb` 语义一致);内部写 `body.velocity`。
- `is_latched` 只读属性。
- 内部:原 `_foot_at_ladder_top`、`_climb_foot_offset`;私有 1 行 `_approach`(仅用于把横速归零,复制根的小工具,避免跨组件共享 Helper)。

### CombatComponent(战斗)
- 拥有:`hp`、`max_hp`、`iframes`、`downed`、`knock_velocity`。
- `take_hit(source_pos, damage, ignore_iframes=false, knockback=-1.0)`:取消冲刺(置 `body.is_charge=false` 需经根——见下)、扣血、无敌帧、击退、相机震动、`hp_changed` 发射、`_downed` 判定。签名与现公开接口一致。
- `apply_knock(delta)`:击退位移 `body.move_and_collide(knock_velocity*delta)` + 指数衰减(原根里两处重复逻辑的单一实现)。
- `is_downed() -> bool`。
- `_downed()`:`body.rotation`、animator.stop、post_process `set_downed(true)`。
- 信号 `hp_changed(current, max)`。根连接它并转发根自己的 `hp_changed`(保持 HUD 不改)。
- animator 经 `body.animator`(根是 @export)获取。

### WeaponComponent(武器)
- 拥有:`WEAPONS` 注册表、`_weapon`。
- `equip(slot: String)`:按注册表换枪,继承旧武器 `fire_cd_timer`,挂到 `body.weapon_slot`。
- `movement_multiplier() -> Vector2`:无武器返回 ONE。
- `apply_recoil(push: float, is_squat: bool, is_latched: bool)`:蹲/攀爬衰减后 `body.velocity.x -= body.facing_direction * push`。

## 根 player.gd 保留内容(约 250 行)

- 移动/跳跃/冲刺/下蹲全部逻辑、朝向(`facing_direction` + `get_facing`/`set_facing`,set_facing 的冲刺锁逻辑)、姿态状态机(Pose enum/state/POSE_ANIM/POSE_NODE/碰撞箱切换/state_lock)、土狼时间/跳跃缓冲/可变高度。
- 物理帧编排:`downed` 分支 → iframes 闪烁 → `weapons.movement_multiplier()` → `climb.update()` → 垂直/下蹲/冲刺/水平 → 朝向/动画翻转/姿态/碰撞箱 → `combat.apply_knock()` → `move_and_slide()` → 弹性检测 → 环面回卷。
- 倒地物理分支(重力/制动,在根,属于移动)。
- 公开接口转发:`take_hit`→combat、`is_downed`→combat、`apply_recoil`→weapons(参数带上根/攀爬的状态)、`hp_changed`→转发 combat 的信号。
- `_unhandled_input`:倒地 R 重载留根;武器数字键→`weapons.equip(slot)`。

## 物理帧顺序与共享状态(关键约束)

- 组件**不写自己的 `_physics_process`/`_process`**,根每帧显式按固定顺序调用,杜绝节点调度乱序。
- 跨组件状态全部经根显式传参,组件间不互相引用:
  - `is_squat`/`is_charge`/`facing_direction` 留根(移动在根);`set_facing` 冲刺锁在根。
  - `_latched` 属 climb、`knock_velocity` 属 combat、`_weapon` 属 weapons,各自私有。
  - `apply_recoil` 需要根/攀爬的 squat/latched → 根取来传给 weapons。
- `take_hit` 里的"取消冲刺"→ combat 需把 `is_charge` 清掉:由根在转发时先清 `is_charge`/`charge_timer`,再调 `combat.take_hit`(保持 is_charge 所有权在根)。

## 公开 API 契约(必须一字不改,外部调用方零改动)

- `take_hit(source_pos: Vector2, damage: int, ignore_iframes: bool = false, knockback: float = -1.0)`
- `get_facing() -> int` / `set_facing(v: int)`
- `is_downed() -> bool`
- `apply_recoil(push: float)`
- 信号 `hp_changed(current: int, max: int)`
- `player` 组、`collision_layer=2`、`collision_mask=5`、scale 2.5 不变。

外部调用方(不动):`enemy_base.gd`/`enemy_black_bird.gd`/`enemy_fly_bird.gd`/`enemy_bullet.gd` 的 `take_hit`、`weapon_base.gd` 的 `get_facing/set_facing/is_downed/apply_recoil`、`hud.gd` 的 `hp_changed`、`explosion.gd` 的 `take_hit/is_downed`。

## 场景变更

Player.tscn 加 3 个 Node 子节点 + 各挂新脚本,不改碰撞箱/动画/WeaponSlot/根导出参数。

## 验证

1. 重构后跑 `enemy_logic_smoke.gd`(确认共享依赖无回归)。
2. headless 启动 90 帧(查脚本报错/实例化)。
3. 手感/行为由用户进游戏验证(接口签名不变,预期零行为变化)。

## 不在范围

- 不抽移动逻辑、不完整组件化、不做玩家物理冒烟测试(避免扩 scope)。
- 不动敌人脚本(同为单体大文件,后续再议)。
