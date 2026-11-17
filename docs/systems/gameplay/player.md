# 玩家

> 与源码冲突时以源码为准,读前先 `grep` 复核。

## 结构

- `scenes/player/player.gd`(CharacterBody2D):根只留**物理帧编排 + 门面**(受击/朝向/瞄准/拾取转发)。攀爬、战斗、武器、游泳分别抽成 `ClimbComponent` / `CombatComponent` / `WeaponComponent` / `SwimComponent`(`player.tscn` 子节点),组件不写自己的 `_physics_process`。
- 移动 / 姿态 / 物理 = [`scenes/player/player_motor.gd`](../../../scenes/player/player_motor.gd)(`PlayerMotor`):**帧内顺序的唯一真相**,顺序写在 `tick()` 一处 —— `swim.update → 水下计时 → climb.update → 垂直 → 蹲/冲 → 水平 → 朝向 → 姿态+碰撞 → 迈台阶/自动跳 → 击退 → 记 _pre_move_vy → move_and_slide → 贴地 → 台沿抬升 → 滑面反应 → 环面回绕`。迈台阶必须在 `move_and_slide` 之前、`_pre_move_vy` 必须在它之前取值:这两条以前只活在阅读顺序里,现在是一份可 diff 的清单。Motor 只拥有只被移动读写的字段(计时器/姿态锁/碰撞箱表/本帧倍率);`facing` / `state` / `is_squat` / `is_charge` / `charge_timer` 仍归 Player(武器、快照、远端副本都读)。
- 表现 / 拾取 = [`player_present.gd`](../../../scenes/player/player_present.gd)(发光、换弹圆环、残影、朝向 flip;`headless` 下不创建 —— 权威端不再给每个玩家建圆环)与 [`player_pickup.gd`](../../../scenes/player/player_pickup.gd)(F/Q 长按 + 两个方法名的端口;单机由 `Level0` 在出生时注入,联机不绑 = 本端不执行,删掉了旧的 `host_level()` 向上找场景类)。
- 整态(回滚/权威同步)编解码 = [`scenes/player/player_net_state.gd`](../../../scenes/player/player_net_state.gd)(`PlayerNetState`):`capture` 装配根本体字段 + `motor` 的时间字段 + `climb` / `swim` / `combat` / `weapons` 各自的 `capture_state()`,`restore` 反向按序回灌。字段键名的唯一 schema 是 `NetCodec` 的 `C2_SCHEMA` / `WEAPON_SCHEMA`,本模块**不另立键清单**;加字段 = 加在有所有权的组件里 + 改 schema。根只留 `capture_self_state` / `restore_self_state`(位置 / 速度 / 朝向 / 姿态 / 蹲冲)与不可序列化的收尾 `_after_state_restore`(碰撞箱、朝向贴图、贴地重判)。`apply_authoritative_state` 也在这里,与整态恢复共用"倒地不顶满 hp"的判据。
- 根公开 `take_hit` / `get_facing` / `set_facing` / `is_downed` / `apply_recoil` / `drop_hold_progress`、信号 `hp_changed` / `waterproof_changed`、只读 `hp` / `max_hp` / `waterproof`。
- 输入可注入:根读输入走 `core/net/player_input.gd` 的 `PlayerInput`(纯接口);本地实现 `LocalInputSource`、网络包 `PacketInputSource`;`source_kind()` 自报 `LOCAL` / `PACKET` / `AI`。PvP 服务器注入包驱动远端玩家;瞄准有 `get_aim_dir_override()` 覆盖钩子。

## 移动与姿态

移动 / 跳跃 / 冲刺 / 攀爬 / 游泳 / 镜头 / 战斗的**可调数值唯一真相源** = [`core/config/player_config.tres`](../../../core/config/player_config.tres);schema 与默认值在 [`player_config.gd`](../../../core/config/player_config.gd)(`class_name PlayerConfig extends Resource` + `@export_range` + `@export_group`)。**改 `.tres` 即调参,不用改代码**;本文不再复述数值(抄一份就会漂)。

| 分组 | 涵盖 |
|---|---|
| 移动 / 跳跃 | 移速 / 加减速 / 急停 / 起跳 / 土狼时间 / 跳跃缓冲 / 松键截断 / 蹲走 |
| 冲刺 | 冲刺距离与速度(`charge_duration = charge_distance / charge_velocity`,派生不抄)/ 空中重力倍率 / 下冲 / 方向窗 |
| 游泳 | 游速 / 上浮 / 下沉 / 防水值上限与没顶伤害 |
| 相机 | 横向前瞻 / 纵向偏移 / 指数平滑 / 死区 / 缩放 |
| 攀爬 / 弹跳 | 梯子与锁链速度 / 弹性面反冲 |
| 生命 / 受击 | 最大血量 / 无敌帧 / 击退 / 受击震屏 |
| 爆炸 | 爆炸震屏 |
| 武器拾取 / 掉落 | 拾取半径 / 长按丢弃 / 掉落初速与重力 / 摩擦 |
| 补间形变 | squash & stretch 全套 |

- `PlayerParams` 退成**访问入口**:`static var move_speed: float = _CFG.move_speed` 在类加载时读一次,不是逐次 getter→Resource —— 实测后者每次读比 `const` 慢 13.8×(200 万次 319ms vs 23ms),而这些值在 `player.gd` / `camera_2d.gd` 里每帧读。代价:改 `.tres` 要重启进程生效。`const _CFG := preload(...)` 保证缺文件是加载期硬失败。守卫:[`tests/smoke/player_config_smoke.gd`](../../../tests/smoke/player_config_smoke.gd)(5 条:`.tres` 可加载 / 62 个可调值全部来自 `.tres` / `_CFG` 接线 / 没有值搬回 `const` / `charge_duration` 派生)。

- 默认键位(2026-11 用户改令):`left` / `right` = A / D(**双击 = 左冲 / 右冲**),`up` = **空格单键**(跳跃 + 上爬,原 W 撤掉),`down` = S,`attack` = 鼠标左键,时间回溯 / 加速 = Shift / 鼠标右键;冲刺**没有独立键**。可重绑清单 = `Settings.REMAPPABLE_ACTIONS`(冲刺不在其中),设置页捕获态允许 Shift / Ctrl / Alt / Tab,Esc 只用来取消,落盘一律单键。守卫:`tests/smoke/binding_contract_smoke.gd`(7 条)。
- 移动走指数缓动;跳跃有土狼时间、跳跃缓冲与可变高度(上升中松键,向上速度 × `jump_cut_factor`)。
- **相机跟随([`core/present/camera_2d.gd`](../../../core/present/camera_2d.gd))**:横向 = 位置 + 速度前瞻(`cam_lookahead_x`) + 死区 + 指数平滑(`cam_smooth_x`);纵向 = 死区 + 指数平滑(`cam_smooth_y`),**不做垂直前瞻**。死区 `cam_deadzone`(值见 `.tres`;≥ 一步迈上去的台阶高度)⇒ 上楼梯/自动跳的 1~2 子格抬升完全不推画面 —— 旧实现是每帧直接把相机设成玩家位置(`PlayerParams` 里四个跟随参数一个都没用上),所以台阶/自动跳的瞬时 y 变化会整屏抖。★ **环面**:玩家坐标是取模的,跨接缝一帧差整张图;实现把玩家位移按「最短取模差」累积成**连续坐标**,死区/平滑全在连续空间做,镜头节点 = 玩家当前取模坐标 + 连续偏移 ⇒ 跨接缝时镜头与玩家同帧一起跳、偏移不变(不露馅、不像瞬移)。一帧内最短取模位移 > `SNAP_DIST = 400px` 判为真传送(复活/回退/换边)⇒ 重锚不做平移。零守卫(原 `torus_camera_probe` 已按仓主裁定删除)⇒ 改跟随/死区只能人眼试玩;瞄准换算用平滑后的基位置(`get_base_global_position()`)。
- ★★ **自动跳跃(2026-11-01 用户要求「小于等于一格会自动跳跃」)**:地面朝前走、前方是 **≤1 格(64px)** 高的台阶时自动起跳;更高的墙**不**跳(否则对着墙会反复起跳),冲刺中**不**跳(冲刺有低重力可跨沟,跳会打断冲刺),水中/攀爬/下蹲中也不跳。判据在纯逻辑 [`core/sim/step_jump.gd`](../../../core/sim/step_jump.gd):`low_step_height(feet_sub, dir, solid_at)` 返回 0(没挡路)/ 1..4 子格(≤1 格 ⇒ 跳)/ -1(墙高于一格 ⇒ 不跳)。**数据源必须是两端同一份**:只读 cyrm v4 的 16px 子格纹理(经 `TileDefs.type_id_of == TYPE_WALL`,并像 `CollisionBuilder.build_sub` 一样跳过已摧毁的可破坏子格),不读碰撞体/射线 —— 客户端预测与服务器重放要得出同一个结论。**跳跃高度 = 台阶高度**:起跳速度按 `v = -sqrt(2·g·h)` 给(峰值恰好到台阶顶,不是满力跳;+4px 是 60Hz 离散化的落地余量),这段小跳不参与「松上键截断」。**≤2 子格(32px)的矮台阶不起跳,直接迈上去**(`_try_step_or_jump` + `StepJump.is_walk_up_step` + `_step_up_headroom_clear`):★ 必须在 **`move_and_slide` 之前**用 `test_move` 探「这一帧的水平位移会不会被台阶挡住」,挡住就先抬到台面、同一帧的 `move_and_slide` 直接迈上去(抬完 `apply_floor_snap()` 吸地);旧写法是「撞上之后下一帧才抬」⇒**每级台阶固定丢一帧水平位移**(700px/s ≈ 12px),连续台阶就是"走一下顿一下"(用户第四轮报的卡顿来源)。`_auto_jump_assist` 的 0.25s 满速窗口是**本地表现量**,不进 `capture_state`/不上线 —— 回滚重放时窗口最多偏几帧、偏差 ≤0.25s 的补速,自愈。★ **2026-11-01(R1)已把它删掉**:实测(回放确定性探针)证明这个"本地表现量"正是重放分歧源 —— 第一遍空中 18 帧把它从 0.25 衰减到 0,`restore_state` 不会恢复它 ⇒ 第二遍走 `approach_air` 而不是强制满速,横移速度从第 1 帧就不同(重放变成"新历史"而不是复现)。现在只保留「**起跳 / 迈台阶那一瞬间**把 `velocity.x` 拉满」(velocity 本来就在整态里),空中横移回到正常的 `approach_air` 缓动。守卫:`tests/probe/stair_climb_probe.tscn`(**7 条**:爬上、无掉速帧、位移 90%+、不腾空、不下坠 + **⑥ 非空转前提** + **⑦ 回放确定性**:一格高墙触发自动跳 → 跳起后空中窗口 capture_state → 跑 18 帧记轨迹 → `restore_state` → 同一串输入重放 18 帧 ⇒ 逐帧 pos/vel **精确相等**)。——连续台阶如果每级都起跳,人就会一路上下颠(用户第三轮报的"连续上台阶抖动");只有 48/64px 才起跳。**上台阶不再掉速/卡脚**(用户实测反馈,通用修法):① 起跳瞬间把横移拉回地面满速(**只这一帧**;原先那套 `AUTO_JUMP_ASSIST_S=0.25s` 窗口式强制满速已在 2026-11-01 按 R1 删除,见上条 —— 它让回滚重放不可复现);② `_try_ledge_nudge`:空中撞墙且有横移输入、台沿顶面在脚上方 ≤1 子格且头顶有净空时,直接抬到台沿上(矩形碰撞箱同时接触"地板+竖墙"两面会把人卡在台沿角上);③ `_ready` 里 `floor_snap_length=4.0` / `max_slides=6`(tile 接缝贴地余量与复杂接触解算次数,参考 [CharacterBody2D 卡角修法](https://bugnet.io/blog/fix-godot-character-body-2d-stuck-on-tile-corners))。守卫:`tests/smoke/step_jump_smoke.gd`(10 条);**跳速/卡脚的手感只能试玩**。⚠ 覆盖上限:探针只钉判据;「实际跳得上去/手感」只能试玩(跳跃高度 ≈ `jump_velocity²/(2g)`)。
- 冲刺 = **双击左 / 右走**(键位表里没有独立冲刺键,原 X 键作废;边沿由 `LocalInputSource` 合成,动作名仍是 `charge`,PvP 上行位不变):方向沿用最近移动方向(`charge_dir_window`),`charge_velocity` 与 `charge_distance` 见 `.tres`,`charge_duration = charge_distance / charge_velocity` ⇒ **冲刺距离 = `charge_distance`**(2026-10-29 由 640 调到 60% 再到 40%;60Hz 离散取整实测比目标多约一帧位移)。倍率与准入的唯一算式在纯逻辑 [`core/sim/dash_rule.gd`](../../../core/sim/dash_rule.gd):**速度 × 时间倍率 × 武器移速倍率、计时 ÷ 时间倍率** ⇒ 时间加速只让冲刺更快、**不改变冲刺距离**(实测 tm=2 时速度翻倍、位移只差几 px),武器减速只缩短冲刺距离;当前 `|vx|` 已经比冲刺速度还快时该次冲刺**无效**(否则冲刺变成刹车)。空中冲刺重力 × `charge_air_gravity_mult`。冲刺与**下冲**(空中按 S:`charge_down_velocity` 2000;下落速度已超过它时同样无效)都在渲染帧发射残影(`AfterImage`,见 [render.md](../presentation/render.md)),纯表现、不进整态。守卫:`tests/smoke/dash_rule_smoke.gd`(9 条)。
- 攀爬(`climb_ladder_up_speed` / `climb_ladder_down_speed` / `climb_chain_up_speed`,绝对值,见 `.tres`;2026-10-28 用户指定):梯子上 / 下、锁链上各按配置值 px/s;锁链下行仍是自由落体(解除攀附交重力)。不再乘瓦片倍率/`climb_vertical_mult`,只乘时间场倍率。
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
