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
| `charge_distance` / `charge_velocity` / `charge_duration` | 256.0 / 3000.0 / 0.0853（2026-10-29 用户把距离改为原 640 的 40%） |
| `charge_dir_window` | 0.3 |
| `charge_down_velocity` | 2000.0 |
| `charge_air_gravity_mult` | 0.35 |
| `climb_ladder_up_speed` / `climb_ladder_down_speed` / `climb_chain_up_speed` | 850.0 / 800.0 / 800.0（绝对值，2026-10-28 用户指定；时间场倍率照乘） |
| `player_max_hp` / `iframes_time` | 50 / 0.25 |
| `player_hit_knockback` / `player_hit_knockback_up` | 400.0 / 200.0 |
| `player_knock_decay_rate` | 10.0 |
| `weapon_pickup_radius` / `weapon_drop_hold_time` | 64.0 / 0.6 |
| `squash_amount` | 0.06 |

- 移动走指数缓动;跳跃有土狼时间、跳跃缓冲与可变高度(上升中松键,向上速度 × `jump_cut_factor`)。
- **相机跟随([`core/present/camera_2d.gd`](../../core/present/camera_2d.gd))**:横向 = 位置 + 速度前瞻(`cam_lookahead_x`) + 死区 + 指数平滑(`cam_smooth_x`);纵向 = 死区 + 指数平滑(`cam_smooth_y`),**不做垂直前瞻**。死区 `cam_deadzone = 32px`(≥ 一步迈上去的台阶高度)⇒ 上楼梯/自动跳的 1~2 子格抬升完全不推画面 —— 旧实现是每帧直接把相机设成玩家位置(`PlayerParams` 里四个跟随参数一个都没用上),所以台阶/自动跳的瞬时 y 变化会整屏抖。★ **环面**:玩家坐标是取模的,跨接缝一帧差整张图;实现把玩家位移按「最短取模差」累积成**连续坐标**,死区/平滑全在连续空间做,镜头节点 = 玩家当前取模坐标 + 连续偏移 ⇒ 跨接缝时镜头与玩家同帧一起跳、偏移不变(不露馅、不像瞬移)。一帧内最短取模位移 > `SNAP_DIST = 400px` 判为真传送(复活/回退/换边)⇒ 重锚不做平移。守卫:`tests/probe/torus_camera_probe.tscn`(8 条,含跨接缝/真传送不变量);瞄准换算用平滑后的基位置(`get_base_global_position()`)。
- ★★ **自动跳跃(2026-11-01 用户要求「小于等于一格会自动跳跃」)**:地面朝前走、前方是 **≤1 格(64px)** 高的台阶时自动起跳;更高的墙**不**跳(否则对着墙会反复起跳),冲刺中**不**跳(冲刺有低重力可跨沟,跳会打断冲刺),水中/攀爬/下蹲中也不跳。判据在纯逻辑 [`core/sim/step_jump.gd`](../../core/sim/step_jump.gd):`low_step_height(feet_sub, dir, solid_at)` 返回 0(没挡路)/ 1..4 子格(≤1 格 ⇒ 跳)/ -1(墙高于一格 ⇒ 不跳)。**数据源必须是两端同一份**:只读 cyrm v4 的 16px 子格纹理(经 `TileDefs.type_id_of == TYPE_WALL`,并像 `CollisionBuilder.build_sub` 一样跳过已摧毁的可破坏子格),不读碰撞体/射线 —— 客户端预测与服务器重放要得出同一个结论。**跳跃高度 = 台阶高度**:起跳速度按 `v = -sqrt(2·g·h)` 给(峰值恰好到台阶顶,不是满力跳;+4px 是 60Hz 离散化的落地余量),这段小跳不参与「松上键截断」。**≤2 子格(32px)的矮台阶不起跳,直接迈上去**(`StepJump.is_walk_up_step` + `_step_up_headroom_clear`:抬起=台阶高+1px、横移补满速、vy 清零;`_auto_jump_assist` 的 0.25s 满速窗口是**本地表现量**,不进 `capture_state`/不上线 —— 回滚重放时窗口最多偏几帧、偏差 ≤0.25s 的补速,自愈)——连续台阶如果每级都起跳,人就会一路上下颠(用户第三轮报的"连续上台阶抖动");只有 48/64px 才起跳。**上台阶不再掉速/卡脚**(用户实测反馈,通用修法):① 起跳瞬间把横移拉回地面满速,并在 `AUTO_JUMP_ASSIST_S=0.25s` 窗口内强制满速(否则贴墙时 `velocity.x` 被接触解算清零、空中加速度又低 ⇒ 越过台沿的前半秒明显慢);② `_try_ledge_nudge`:空中撞墙且有横移输入、台沿顶面在脚上方 ≤1 子格且头顶有净空时,直接抬到台沿上(矩形碰撞箱同时接触"地板+竖墙"两面会把人卡在台沿角上);③ `_ready` 里 `floor_snap_length=4.0` / `max_slides=6`(tile 接缝贴地余量与复杂接触解算次数,参考 [CharacterBody2D 卡角修法](https://bugnet.io/blog/fix-godot-character-body-2d-stuck-on-tile-corners))。守卫:`tests/smoke/step_jump_smoke.gd`(10 条);**跳速/卡脚的手感只能试玩**。⚠ 覆盖上限:探针只钉判据;「实际跳得上去/手感」只能试玩(跳跃高度 ≈ `jump_velocity²/(2g)`)。
- 冲刺沿用最近移动方向(`charge_dir_window`):`charge_velocity` 3000、`charge_duration` = 256/3000 ≈ 0.0853s ⇒ **距离 256px**(2026-10-29 由 640 → 60% → 40%);空中冲刺重力 × `charge_air_gravity_mult`。冲刺时渲染帧发射残影(`AfterImage`,见 [render.md](render.md)),纯表现。
- 攀爬(绝对值,2026-10-28):梯子 上 **850** / 下 **800**、锁链 上 **800** px/s;锁链下行仍是自由落体(解除攀附交重力)。不再乘瓦片倍率/`climb_vertical_mult`,只乘时间场倍率。
- 下蹲:在地面且按住 S 才蹲(逐帧判定,非边沿触发);蹲态可蹲走;空中按 S = 下冲。
- 姿态碰撞箱:Pose → CollisionPolygon2D(共 5 个),运行时只启用当前姿态的箱子。
- 水中:判定只在 `Water.sample_body`(见 [`world.md`](world.md) 的「水」);入水 / 出水用 `GameParameters.water_enter_depth`=8px / `water_exit_depth`=-2px **滞回**;呼吸按 `head_under`(头低于水面线)扣氧。`SwimComponent.sample` 是本帧水状态的唯一来源,根不再自己查水面。
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
