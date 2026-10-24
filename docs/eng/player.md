# 玩家

> 与源码冲突时以源码为准,读前先 `grep` 复核。

## 结构

- `scenes/player/player.gd`(CharacterBody2D):根只留移动 / 姿态 / 物理帧编排;攀爬、战斗、武器分别抽成 `ClimbComponent` / `CombatComponent` / `WeaponComponent`(`player.tscn` 子节点)。组件不写自己的 `_physics_process`,由根每帧按序调用:`climb.update → 移动 → combat.apply_knock → move_and_slide`。根公开 `take_hit` / `get_facing` / `set_facing` / `is_downed` / `apply_recoil`、信号 `hp_changed`、只读 `hp` / `max_hp`。
- 输入可注入:根读输入走 `core/net/player_input.gd` 的 `PlayerInput`(纯接口);本地实现 `LocalInputSource`、网络包 `PacketInputSource`;`source_kind()` 自报 `LOCAL` / `PACKET` / `AI`。PvP 服务器注入包驱动远端玩家;瞄准有 `get_aim_dir_override()` 覆盖钩子。

## 移动与姿态

移动 / 跳跃 / 冲刺 / 镜头 / 战斗数值全在 `PlayerParams`:

| 常量 | 值 |
|---|---|
| `move_speed` | 700.0 |
| `accel_ground` / `accel_air` | 30.0 / 9.0 |
| `brake_ground` / `brake_air` | 16.0 / 6.0 |
| `jump_velocity` | -1000.0 |
| `coyote_time` / `jump_buffer_time` | 0.1 / 0.12 |
| `jump_cut_factor` | 0.5 |
| `crouch_walk_speed` | 245.0 |
| `charge_velocity` / `charge_duration` | 1900.0 / 0.4 |
| `charge_dir_window` | 0.3 |
| `charge_down_velocity` | 2000.0 |
| `charge_air_gravity_mult` | 0.35 |
| `climb_vertical_mult` | 1.2 |
| `player_max_hp` / `iframes_time` | 50 / 0.25 |
| `player_hit_knockback` / `player_hit_knockback_up` | 400.0 / 200.0 |
| `player_knock_decay_rate` | 10.0 |
| `weapon_pickup_radius` / `weapon_drop_hold_time` | 64.0 / 0.6 |
| `squash_amount` | 0.06 |

- 移动走指数缓动;跳跃有土狼时间、跳跃缓冲与可变高度(上升中松键,向上速度 × `jump_cut_factor`)。
- 冲刺沿用最近移动方向(`charge_dir_window`),`charge_duration` 0.4s;空中冲刺重力 × `charge_air_gravity_mult`。
- 下蹲:在地面且按住 S 才蹲(逐帧判定,非边沿触发);蹲态可蹲走;空中按 S = 下冲。
- 姿态碰撞箱:Pose → CollisionPolygon2D(共 5 个),运行时只启用当前姿态的箱子。
- 受击:iframes / 击退 / 倒地;爆炸击退是独立 `knock_velocity` 向量。倒地不取消物理(仍受重力/击退),只是不吃输入。单机倒地后按 R 调 `Level0.restart_single()`:原地复位,不是场景重载 —— 可破坏砖 / 瓦片 / 碰撞整层还原为建图基线 + 清子弹/敌人后重刷 + 玩家满血满氧回出生点。PvP / 大乱斗不走这条。

## 残弹与换弹

- 残弹唯一写入口:`WeaponComponent.apply_mag(w, mag)`。已入树 ⇒ 同步写 `w.mag_ammo`;未入树 ⇒ 写 `w.pending_mag`,由 `WeaponBase._ready()` 一次性消费并复位哨兵 `MAG_UNSET = -2`。0 是合法弹数,哨兵不能用 0;`WeaponInventory.MAG_FULL = -1`。
- 弹数没有常规纠正路径:`_close_enough` 不比 `mag`,`sync_soft_state` 的指纹只比 `wslot` / `winst` / 背包结构。
- `WeaponBase._mag_ready` 声明初值 false,只在 `_ready()` 末尾置真;`fire()` 空弹夹那一支用 `if _mag_ready: start_reload()`。不可换成 `is_inside_tree()` 守卫,否则会丢帧并把 `_auto_aim()` 的朝向一起冻住。`_update_reload_pose` 首行 `if sprite == null: return`:未入树时 `@onready` 的 `sprite` 仍是 null,姿势下一帧补算。
- 换弹对全模式开放(含 1v1 / 大乱斗);`mag_ammo` / `_reloading` / `_reload_t` 进 `Player.capture_state()`,不进 `_close_enough` 比对。
- 复活/重开口径:单机重开由 `Level0.restart_single` 统一重置;联机复活 = 除随机一把外全丢。`player.restart_at()` 不动背包。

## 武器接入

- 加新武器 = 改 1 个 `data/weapons.json` + 加 1 个 `.tscn`,零 GDScript;`tier` 必须与 tscn 的 `tier` export 一致,否则容量算错。
- 数字键 `1`-`4` 是背包位置,与 `type_id` 无关。
