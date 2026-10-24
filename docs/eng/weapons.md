# 武器、子弹与背包

> 与源码冲突时以源码为准,读前先 `grep` 复核。

## 武器与子弹(scenes/weapons/)

- `WeaponBase`(Node2D):数值全是 `@export`(fire_cooldown、bullet_speed / range / size / color、pellet_count / spread、damage / impact、recoil_push / kick、cam_shake、move / jump_penalty、heavy_aim 激光、pitch_clamp_deg)。`fire()` 按 `pellet_count` 从 `bullet_scene`(默认 `bullet.tscn`)出弹并注入 `bullet_gravity`;`apply_hit()` 调敌人 `hurt()`;heavy_aim 按住预瞄、松开发射;`preview_arc = true` 时预瞄画抛物线弧线 + 末端爆点标记。
- 弹道方向与走路朝向解耦:`fire()` 开火瞬间先 `_auto_aim()`(由鼠标推导瞄准侧,近垂直瞄沿用上次明确侧)再出弹;所有开火路径都取本帧鼠标方向,不读 `get_facing()`。
- 术语:`type_id` = 武器类型 id(整数 1–N,与键位、背包位置无关);`inst` = 逐把唯一,进输入包与 `capture_state`;`index` = 背包位置(0-based,只在本地用于按键解析 / HUD 行号)。`slot` 只保留在三处:`Player.weapon_slot` 挂点、容量格 UI(`WeaponSlots` / `C_SLOT_*`)、`capture_state()` 的 `wslot` 键。
- 上行传解析结果:输入包带 `"winst"` = 目标那把的 `inst`。客户端本地解析(数字键按 `index`、滚轮按相对位置)出 `inst`;服务器 `equip_inst(inst)`,`index_of_inst` 找不到就静默不动。下行世界包的枪型字段是 `type_id`。改这个键 = 改协议,两端必须同一 build。
- `equip_type` 对「背包里没有这个类型」`push_error` 且不加入。发放走 `pick_up(type_id, MAG_FULL)` 或 `set_initial_inventory([...])`。
- 现有武器:手枪 / 步枪 / m82a1(重狙,heavy_aim)/ s686(霰弹 8 丸 ±3°、射程 1100)/ 榴弹发射器(重型)/ 激光枪(中型即时光束)。

**即时光束(`LaserWeaponBase extends WeaponBase`)**:

- 不开物理子弹:`WeaponBase.fire()` 的出弹循环抽成虚钩 `_spawn_projectiles(base_dir)`,本基类接管为「开火瞬间几何追踪一束 + 一次性结算」。三个可覆写缝:几何 `_emit_beam(origin, dir)`(默认直线 hitscan)、命中结算 `_apply_beam_damage`(默认扫路径 + 磨可破坏砖)、视觉 `_spawn_beam_visual` / `_beam_style`(统一走 `core/present/laser_visual.gd` 的 `spawn_beam` / `spawn_muzzle_orb`)。`laser_gun` 只覆写 `_emit_beam`(镜面反射,`max_bounces` 当前 5)。
- 几何 `core/sim/beam_trace.gd`(纯静态、不引 autoload):DDA 走 32px 子格(64px 格 → 2×2 形状掩码,只认 type=wall ⇒ 光穿水/梯),遇墙翻对应轴反射,超反射额度或累计 ≥ `bullet_range`(2000)即消失,返回折线点集 + 碰墙 64px 格 + 碰面点。
- 命中:折线线段与目标实际身体 AABB(`_body_rect`:取整框并锚到段起点近副本,中心不在节点原点)外扩 `beam_half_width × 1.75` 后 `_segment_rect_hit`(Liang-Barsky)相交即中,每段各结算一次(反射折返可叠加)。
- PvP:权威开火记入 `pending_beam_report`,服务器每帧 `collect_pending_beam_report()`(读到即清)经 `beam_fired` 广播给非射手端;`laser_beam.tscn`(双层 Line2D:Glow + Core)淡出自毁。

**子弹**:

- 玩家 `BulletBase`:伤害由 WeaponBase 注入(`hit_damage` / `hit_impact`)。爆炸弹(`explodes = true`)撞墙/命中一律反弹(衰减 0.6),`fuse_time`(撞墙)/ `hit_fuse_time`(命中敌人)引信,命中敌人另加 10 直接伤,超射程兜底爆炸。
- PvP 命中玩家:`_check_player_contact` 按 `PLAYER_HIT_RADIUS = 40`(单一来源,`MatchHost.HIT_RADIUS` 引用它)对 `player` + `player_replica` 组(排除射手)判接触,只起短引信、不改轨迹;权威直接伤由 `MatchHost._adjudicate_grenade` 结算(5 伤 + 归因 + `notify_direct_hit` X 标记),不销毁子弹。首次碰撞决定引信时长、不刷新。
- AoE 在 `core/sim/explosion.gd`:`Explosion.apply_aoe` 内圈 40% 满伤 + 二次方衰减,LOS 墙后保留 75%(纯函数 `cover_multiplier`,内圈免疫遮挡),友伤,击退独立径向,穿透无敌帧。不变量:伤害随距离不增。
- 客户端视觉子弹:`PvpMatchClient._cull_bullet_contacts()` 对 `apply_damage == false` 且非榴弹的子弹,按 `PLAYER_HIT_RADIUS` + 同一套环面最短距离判接触,命中即 `queue_free()`;榴弹跳过(引信/反弹由 `_check_player_contact` 管)。子弹的 `shooter` 来自 `bullet_spawn` 的 `shooter_role`。3v3 队友穿透由 `_bullet_hits_entity(b, ent)` 覆写保证。碰撞层:子弹 mask = 5(地形 + 敌人),榴弹不含玩家 ⇒ 友伤只来自爆炸。

## 武器背包与地面拾取

- 背包两条并行闸门:8 格容量预算 + 4 把上限(tier 成本:轻 2 / 中 3 / 重 4)。
- `WeaponInventory.capacity` / `max_weapons` 是实例字段(构造参数 + `set_capacity()` / `set_max_weapons()`,钳到 ≥ 1);默认值常量 `DEFAULT_CAPACITY = 8` / `DEFAULT_MAX_WEAPONS = 4`。`ui/hud/weapon_slots.gd` 的 `capacity` / `rows` / `panel_h` 由容量派生(`COLS` 恒 4)。
- `core/sim/weapon_inventory.gd`(`WeaponInventory`,纯逻辑、无 autoload、`-s` 可测):持有表 `Array[Dictionary]`,每条 `{type, inst, mag}`;残弹按 `inst` 记(允许同类型多把);不 import `weapon_base.gd`。
- `_current_type` 是武器类型 id,不是背包位置:快照的 `type_id`、`capture_state` 的 `wslot`、`PlayerReplica._swap_weapon` 全按类型 id;`index` 只在本地用。
- 拾取:按 F 一次只捡最近的一把;放不下(容量或 4 把上限)时替换手上当前那把,被换下的掉在脚下(残弹跟着枪走)。`pick_up()` 返回 `0` = 成功无替换 / `>0` = 被替换掉的 type_id / `PICKUP_DENIED = -1` = 闸门拒绝,三者必须分开。
- 诊断:`-- --pickup-diag`(默认关;必须写在 `--` 之后)。覆盖 `_spawn_pickup_node` 三条静默早退与 `canonical_pos` 漂移。
- 丢弃:长按 Q ≥ `PlayerParams.weapon_drop_hold_time`(0.6s)。计时在客户端本地做,满阈值才把一次 `BIT_DROP` 边沿上行;HUD 有 `C_DANGER` 进度条。
- 地面武器 `WeaponPickup`(CharacterBody2D,`scenes/weapons/weapon_pickup.tscn`):视觉 = 把 `WeaponRegistry.scene_of(type_id)` 的场景实例化当哑子节点(不驱动 `tick()` 即静止);碰撞箱由 `SpriteBounds.from_sprite` 按像素 alpha 求;`WORLD_SCALE = 2.5` 只此一处。必须挂在 `$WorldViewport` 下。`configure()` 必须在 `add_child` 之前;重建先 `remove_child` 再 `queue_free`。
- 落体摩擦是速度衰减 + 阈值置零(`weapon_stop_eps = 6.0`),不可改为滑固定时长,否则客户端(晚一个 RTT 才开始模拟)与服务器落点发散。
- `core/sim/ground_weapon_field.gd`(`GroundWeaponField`):场上地面武器的纯逻辑表;距离与半径走环面最短,并列按 `inst` 升序。
- 布点:`GridPathfinder.spread_cells(cells, count, clearance, cols, rows)`,大乱斗与单机共用;内部有 `shuffle()`,不得在广播之后再调一次。开阔地板格扫描在 `EnemySpawner.open_floor_cells`。
- 联机权威 `server/match/match_ground.gd`(`MatchGround`,继承链中间层,不得定义生命周期钩子;由 `MatchHost._physics_process` 每帧显式调 `_sync_ground_positions()` + `_handle_ground_actions(role, src)`)。
- `weapon_spawned` / `weapon_removed` 只走 `NetBus`,不在 `NetBusExt` 里加同名;开局那批走 `match_sync` 进场拉取。`_build_collision` 把 Visual 反向平移,让画出来的枪中心落在 body 原点上;`vel` 必须保持生成时那一份。权威位置 `canonical_pos` 恒在 `[0,MAP)`,每帧由 `set_anchor(玩家位置)` + `sync_render_from_canonical()` 锚到最近副本。
- 换局 `_reset_ground_weapons` 清的与铺的都必须广播,`_next_ground_inst` 不得重置;客户端不要在 `round_state` 里自己清空。
- 不做客户端预测:按 F/Q 只上行(`BIT_PICKUP = 32` / `BIT_DROP = 64`),服务器裁决后广播;落体视觉由客户端用事件带的 `pos` + `vel` 本地模拟。背包进 `capture_state("inv")`;`restore_state` 必须先读 `wslot`、再 `restore_inventory`、最后 equip;`inv` 不进 `_close_enough`。
- 服务器玩家必须有枪:`MatchHost._ready` 的 `_setup_ground_weapons()`(铺 12 把 + 每人随机拿 1)是唯一来源。掉落发生在「倒地边沿」(`_drop_all_but_one`,除随机一把外全丢在倒地位置;`MatchRound` / `RoyaleHost` / `TeamHost` 各一处);换局 = 清空重铺 + 各人背包重置为随机一把。
- 初始状态:单机开局玩家带手枪(`Level0._give_starting_weapon`,必须排在 `set_enabled_types` 之后,用 `default_type()`),12 把(每种 2 把)随机散落;按 R = 完全重开。`player.restart_at()` 不动背包;`player.tscn` 的 `_ready` 是空背包。`RunOptions.disabled_weapons` 不出现在分布里。
- 武器精灵必须显式设 `texture_filter = 1`(nearest)。
- 键位:数字键 1-4 = 背包位置(`5`-`0` 的输入动作不存在);滚轮在背包位置间循环,`Settings.wheel_switch` 默认 true;`F` / `Q` 在 `Settings.REMAPPABLE_ACTIONS` 里。上行切枪 = `winst`。容量 > 4 时第 5 把只能靠滚轮;要开数字键得同时改 `project.godot` 的 `[input]`、`LocalInputSource._switch_index_raw()` 的 `range(1, 5)` 与动作表。

## 武器注册表(data/weapons.json)

- 单一来源:`weapons` 数组,每条 `{id, name, tier, scene}`。`id` 就是整数 `type_id`;`tier` 是三值字符串(`light` / `medium` / `heavy`),由 `WeaponRegistry` 映射回整数;数组顺序 = 菜单顺序 = 散落顺序;`id` 空间不设上界。
- `core/sim/weapon_registry.gd`(`WeaponRegistry`,纯静态、无 autoload、`-s` 可测)是唯一读者:`all_ids()` / `has()` / `scene_of()` / `name_of()` / `tier_of()` / `tiers_map()`。`tier_of()` 返回裸 `int`,不返回 `WeaponBase.Tier`(引那个类会把 autoload 拖进 `-s`)。本文件不 `load()` 武器场景,只用 `ResourceLoader.exists()` 查路径。
- 加第 N 把枪 = 改 1 个 json + 加 1 个 tscn,零 GDScript 改动。
- 加载校验:文件级格式错 → `push_error` + 整表留空;逐条不合格(缺字段 / 非对象 / `id` 非正整数 / `id` 重复 / `tier` 非三值 / `scene` 不存在)→ `push_error` + 跳过该条。
- 发布产物:`tools/build_release.py` 的产物冒烟多跑一趟客户端开关 `-- --registry-report`(默认关),客户端打一行 `[registry] weapons=N ids=[…]`,脚本拿仓库 `data/weapons.json` 当期望值逐条对账(期望值不写死数字;开关丢了也红)。
