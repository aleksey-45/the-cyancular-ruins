# 时间玩法（回溯 / 加速 / 颗粒账户 / 怀表 / 世界重绕）

> 与源码冲突时以源码为准，读前先 `grep` 复核。

## 1. 入口与文件清单

### 1.1 单机（SP）

| 落点 | 职责 |
|---|---|
| `scenes/level_0.gd` | 非 PvP 时建 `GrainAccount` / `TimeField`（写 `TimeField.current`）/ `WorldRewind` / `TileLedger`；`pvp_mode` 早退 |
| `_process` / `_drive_time` | `time_field != null and not pvp_mode` 时每帧 `_drive_time(...)` → `_tick_rewind(...)` → `_tick_time_visuals(...)`;`_drive_time` 是按键边沿 deny 音效 + 把按键态交给 `TimeField.update()` —— 时间场驱动的唯一缝（探针直调它） |
| `_tick_rewind` / `_restore_sub` | 录制 ↔ 回放状态机（状态沿 `WorldRewind.was_rewinding`）+ 尸体保留/过期 + 瓦片账本入账/裁剪/还原;`_restore_sub` 还原一个 16px 子格（网格 + 9 环面副本 + 持久子格 + 格级 HP + 脏块标记） |
| `_tick_time_visuals` | 底片/加速压暗 ramp、贷款深度、`Sfx.pitch_mult`、`_sync_time_glows()` |
| `_rewind_elite_hits` / `_sync_time_glows` | 回放弹 × 精英的二次伤害（每颗弹对同一精英只结算一次，meta `rw_hit_ids`）;高亮:加速 = 主角 + 近处 `GLOW_RADIUS` 内敌人，回溯 = 只有精英 |
| `ui/hud/hud.gd` | 挂 `WatchHud`（血条/氧条下方）+ `TimeSymbolHud`（屏幕中心） |

### 1.2 PvP（Beta）

| 落点 | 职责 |
|---|---|
| `server/time_economy.gd` | `TimeEconomy`：服务器权威颗粒经济 —— 每 role 一份 `GrainAccount` + 四条结算缝（击杀/伤害/拆砖/回复）+ 10Hz 镜像载荷 |
| `server/match/match_host.gd` | `_tick_beta_rewind()` 每 role 各自的回溯机（环缓/倒放/免伤/轨迹）；`_record_rw_frame`（20Hz）；`_apply_rw_frame`；`_finish_rw`（松手 / 颗粒耗尽共用）；加速态在快照之前定格。线上三件（`match_snapshot.gd`）:`haste` 布尔 / `rewind` 布尔 / `trail`（回溯轨迹点） |
| `scenes/pvp_match_client.gd` | `_setup_beta_time_hud()` 挂 `WatchHud` + 订阅 `NetBusExt.local_time_state`；`_on_time_state` 挂镜像账户并点亮怀表；`_tick_beta_time` 本地预测加速（写 `player.pvp_haste_mult`，不本地扣颗粒）；`_tick_beta_rewind` 本地预测回溯（冻结 `input_source`、置免伤 meta `time_rewinding`、世界 + 自己上底片，位置不本地预测）；`_apply_own_film` 只作用于世界图层 + 自己；`_tick_time_fx` 双侧视效 |
| `scenes/lobby_page.gd` | 建房页时间参数滑条（`TimeRules` 实例；`_beta_payload()` 先 `clamp_self()` 再上报 `{"beta":true,"time":…}`） |

### 1.3 纯逻辑层（两侧共用，`-s` 可直接跑）

| 文件 | 职责 |
|---|---|
| `core/config/time_params.gd` / `time_rules.gd` | 单机 `TimeParams`（全 `const`，时间玩法参数的代码单一来源）/ PvP `TimeRules`（每局可调的实例数据 + 服务器钳制 + `make_account()` / `rewind_buffer_seconds()`） |
| `core/sim/grain_account.gd` | `GrainAccount` 记账芯：总余额 / 短时窗 / 贷款 / 锁定，五个信号 |
| `core/sim/time_field.gd` | `TimeField`：模式 → 各实体 delta / 速度倍率的唯一查询口（静态 `current`） |
| `core/sim/world_rewind.gd` | `WorldRewind`：单机定频快照环缓 + 反向应用器 + 尸体保留（不碰 UI 与 shader） |
| `core/sim/tile_ledger.gd` | `TileLedger`：单机拆砖账本（记改前值，回拨按 t 降序还原） |
| `server/time_economy.gd` | `TimeEconomy`：PvP 服务器权威颗粒经济（纯逻辑、零 `NetBus`） |

### 1.4 表现层

| 文件 | 职责 |
|---|---|
| `ui/watch_hud.gd` | `WatchHud` 怀表：程序化像素表盘；白短针 = 总量/上限、红长针 = 短时窗 + 贷款、右侧 96px 大数字 = 总余额 |
| `ui/time_symbol_hud.gd` | `TimeSymbolHud` 屏幕中心模式标志（回溯 `◁ ◁` 浅色快闪 / 加速 `▶ ▶` 紫色） |
| `scenes/effects/time_glow.gd` / `after_image.gd` | `TimeGlow`:实体视觉节点下叠加色混合副本（`passes` 可两层），替代 `modulate > 1`;`AfterImage`:加速红/蓝交替残影，0.26s 淡出自毁 |
| `scenes/effects/grain_crystal_fx.gd` | `GrainCrystalFx`：精英击杀结晶 → 炸开 → 飞向怀表 → 入账（兜底超时也必入账） |
| `scenes/effects/time_film.gdshader` + `core/present/post_process.gd(.gdshader)` | PvP 底片材质（`_apply_own_film` 用 `coverage` 参数）;单机三 uniform，统一入口 `set_time_effects(film, loan, haste)` |
| `core/present/sfx.gd` | `Sfx.pitch_mult` 全局音调系数（贷款越深越尖 / 加速略升 / 回溯略降） |

### 1.5 消费点

| 落点 | 吃什么 |
|---|---|
| `scenes/player/player.gd` | 速度域倍率（`TimeField.player_speed_mult()` 或 `pvp_haste_mult`）+ `weapons.tick(delta * tm)` + 回溯整帧早退；`take_hit()` 回溯期免伤早退；`rewind_restore()` 写回位置/速度/HP/朝向/倒地/武器弹量。`pvp_haste_mult` 是 PvP 唯一分发源，由 `_push_haste_mult()` 每帧推给攀爬/武器 |
| `scenes/player/swim_component.gd`、`climb_component.gd` | 游泳 / 攀爬吃同一倍率 |
| `scenes/enemies/enemy_base.gd` | delta 域 + 回溯整帧早退（精英除外）；速度域 `velocity.x *= TimeField.enemy_speed_mult(self)`，必须在 `move_and_slide()` 之前；`rewind_restore()` 写回位置/速度/HP/存亡/可见性，含复活时还原碰撞层。录制期保留尸体走 `rw_death_ms` meta：白闪结束后隐藏 + 停物理 + 摘碰撞层 |
| `scenes/enemies/enemy_bullet.gd` | 自己覆写 `_physics_process`，必须自己调 `TimeField.bullet_delta`；读写口补自己的 `damage` / `water_mult` |
| `scenes/weapons/bullet_base.gd` | 子弹 delta + 回溯整帧早退；`rewind_state()` / `apply_rewind_state()` |
| `scenes/weapons/weapon_base.gd` | `haste_mult` 注入成员：PvP 射手加速 ⇒ 出膛弹速 × 同倍率（单机恒 1，避免与 `TimeField.bullet_delta` 双乘）；`max_range` 不动 |
| `scenes/weapons/weapon_pickup.gd` | `TimeField.world_delta`（掉落武器等世界物件） |

## 2. 不变量

1. **单机闸门**：时间系统只在 `Level0` 的非 PvP 路径建立；`TimeField.current` 的唯一赋值点在建场处，`pvp_mode` 时提前 return。`TimeField.current == null` 时六个静态查询口（`player_delta` / `enemy_delta` / `bullet_delta` / `world_delta` / `player_speed_mult` / `enemy_speed_mult`）首行早退、恒等。
2. **时间由调用方传入，纯逻辑类不读时钟，单位是秒**：`GrainAccount` 的输入全是调用方的 `delta` / `rate` / `amount`；`TimeField.update(delta, want_rewind, want_haste)`；`TileLedger.record(t, cells)` 的 `t` 由 `Level0` 传 `WorldRewind.recorded_seconds()`；`TimeEconomy.tick(delta)`。例外：`WorldRewind.expire_corpses()` 用墙钟 ms 与 `rw_death_ms` 比；`MatchHost._tick_beta_rewind()` / `_record_rw_frame()` 的环缓时间轴是 `Time.get_ticks_msec() / 1000.0`。
3. **`TimeField` 只给倍率，绝不动 `Engine.time_scale`**。倍率分两域：delta 域（重力、计时器、AI 节拍、动画、子弹位移）与速度域（`*_speed_mult`：水平运动与武器 tick）。`move_and_slide()` 用引擎自己的 delta ⇒ 快/慢必须落在速度域。
4. **模式优先级与当帧停**：`want_rewind and not want_haste` 才是 REWIND；`can_spend()` 为假时按键空转（不结算、不改模式）；结算后若 `balance <= 0.0` 则当帧回落 NONE。按键空转的边沿反馈（`Sfx.play("deny")`）在 `Level0._drive_time`。
5. **回溯期 = 冻结 + 免伤，回放期只结算精英二次伤害**：普通敌整帧早退（精英例外）、子弹不自步进、玩家整帧早退且 `take_hit` 直接返回；普通实体之间不结算伤害，回放弹穿过精英照常结算（`Level0._rewind_elite_hits`，按 meta `rw_hit_ids` 去重，每颗弹对同一精英只结算一次）。玩家免伤判据：单机看 `TimeField.current.is_rewinding()`，联机看节点 meta `time_rewinding`。
6. **精英 = `set_meta("elite", true)`**：① 不入单机快照（`WorldRewind.record` 按 meta 跳过）；② 回溯期照常行动（两条 delta 与速度口都返回 1×）；③ 加速时与玩家同倍率，高亮两层亮黄。击杀掉 `TimeParams.ELITE_GRAIN_DROP`。
7. **颗粒账户口径**（`GrainAccount`，纯逻辑零场景依赖）：一笔 `spend(delta, rate)` 同时扣总余额与短时窗（`short_used`）；短时窗满 ⇒ 溢出进贷款（`loan_used`）；贷款达 `loan_max` ⇒ `locked = true` 且 `can_spend()` 恒假；`regen(delta)` 无论是否在消耗都照走，先还贷后回窗，贷满锁定者还清那一刻自动解锁；`deposit(amount)` 只进总余额并夹 `cap`；`loan_depth() = loan_used / loan_max ∈ [0,1]`（`loan_max <= 0` 时返回 0）。
8. **单机「录像带」模型**：`WorldRewind.finish()` 把过去的将来从 `_frames` 裁掉（至少留 1 帧），磁带钟退回出口，之后 `record()` 从这里续录；`TileLedger.prune_after(exit_t)` 同裁 ⇒ 两次回溯互不串带。PvP 同一语义在 `MatchHost._finish_rw`。
9. **PvP 环缓只存该 role 自己**：位置 / 速度 / HP / 朝向 / 倒地 / 自己的武器弹量 + `b.shooter == p` 的自己的子弹；不重建已消亡的弹。回溯期间输入源 frozen、`take_hit` 免伤，自己的子弹随回放倒放且照常伤害他人。回溯重建的子弹必须补 `scene_path` meta：写这份 meta 的唯一地方是出膛那一刻，重建弹绕过它 ⇒ 再录进快照时 `sp` 是空串 ⇒ 下次回溯该弹凭空消失。
10. **弹药回溯的语句序**（单机 `Player.rewind_restore` 与服务器 `_apply_rw_frame` 逐字对齐）：切枪必须排在条目写回之前（`_equip_index` 会把走掉那把的出膛实弹写回条目）；手持实弹走 `WeaponComponent.apply_mag()`（未入树窗口写 pending，由 `WeaponBase._ready` 消费），不直接写 `mag_ammo`；`wlive`（手持实弹）与 `wmags`（各槽条目）各自照抄快照。
11. **单机录制期保留尸体**：`WorldRewind.hold_corpses` 由 `Level0._tick_rewind` 每帧同步（录制 = true / 回放 = false）；保留下来的尸体隐藏时必须同时摘碰撞层（还原走 `_rw_held_layer`），否则是虚空碰撞箱；过期由 `WorldRewind.expire_corpses()` 按 `rw_death_ms` 清理。精英不保留。
12. **进/出回溯必须读同一个输入源**：单机状态沿是 `WorldRewind.was_rewinding`，PvP 是 `_rw_on[role]`；置 `src.frozen = true` 与解冻必须是宿主自己那一个 `input_source` 对象（换对象 ⇒ `want` 恒假、回溯出不来）。
13. **PvP 数值权威在服务器，客户端只做预测**：客户端拿 10Hz `TimeState` 镜像（`TimeEconomy.state_payload()`），本地不扣颗粒；本地加速只写 `pvp_haste_mult`，本地回溯只做冻结输入源 + 免伤 + 底片，位置由快照权威写回。建房参数走 `TimeRules.from_dict()`，其内部调 `clamp_self()`。
14. **瓦片回溯的粒度是「子格死亡事件」，不是 HP 变化量**：记账点在 `Level0._on_sub_destroyed`，不按破坏来源过滤；同一格可多次入账，还原必须 t 降序（最新破坏先还原 = LIFO）。PvP 开局复位必须同时还两套表：`Level0.reset_destructibles()`（客户端）与 `MatchRound._reset_world_and_clear_dynamics`（服务器）都要复位格级 HP 表与子格 HP 表；漏一套 ⇒ 下一局客户端有墙、服务器没有。

## 3. 关键常量与唯一来源

### 3.1 单机 `TimeParams`（`core/config/time_params.gd`，全 `const`）

| 常量 | 值 | 含义 |
|---|---|---|
| `GRAIN_INITIAL` | `1000` | 初始颗粒 |
| `GRAIN_CAP` | `5000` | 颗粒额度上限（怀表白短针一圈） |
| `SHORT_WINDOW` | `400.0` | 短时间额度（红长针一圈） |
| `SHORT_REGEN` | `50.0` | 短时额度恢复速率（先还贷后回窗） |
| `LOAN_LIMIT` | `100.0` | 贷款限额 = 短时窗的 1/4 |
| `COST_REWIND` | `120.0` | 回溯：颗粒/秒（按住 `rewind`） |
| `COST_HASTE` | `80.0` | 加速：颗粒/秒（按住 `haste`） |
| `SNAP_HZ` | `20` | 单机快照采样频率（Hz） |
| `SNAP_SECONDS` | `40.0` | 单机环缓容量（秒） |
| `REWIND_START_MULT` | `3.0` | 倒放起步倍速（随后落回 1×） |
| `REWIND_RAMP_TIME` | `0.35` | 起步倍速 → 1× 的过渡时长（秒） |
| `HASTE_PLAYER` | `2.0` | 玩家与精英的行动倍率 |
| `HASTE_WORLD` | `0.5` | 其余实体（普通敌 / 敌弹 / 世界物件）的倍率 |
| `LOAN_ENEMY_SPEED_BONUS` | `0.5` | 贷款深度给普通敌的表现速度加成上限 |
| `LOAN_PITCH_RANGE` | `0.5` | `Sfx` 全局音调加成上限 |
| `LOAN_BRIGHT_RANGE` | `0.35` | 画面变亮上限（shader 亮度叠加） |
| `LOAN_ABERRATION_PX` | `5.0` | 色差偏移上限（像素） |
| `ELITE_GRAIN_DROP` | `300` | 击杀一次精英掉落颗粒 |

- `GrainAccount` 五个字段初值与 `_init` 默认值、`WorldRewind` 的采样频率/容量/ramp、`TimeField` 的全部倍率与消耗速率、`GrainCrystalFx.amount` 初值都读 `TimeParams`;PvP 也读两个 ramp 常量(`REWIND_START_MULT` / `REWIND_RAMP_TIME`),但采样间隔与容量不读 `SNAP_HZ` / `SNAP_SECONDS`。

### 3.2 PvP `TimeRules`（`core/config/time_rules.gd`：默认值 + 服务器钳制）

| 字段 | 默认 `DEF_*` | 钳制 `R_*` | 备注 |
|---|---|---|---|
| `initial` | `1000.0` | `[0, 5000]` | |
| `cap` | `1800.0` | `[100, 9999]` 且 ≥ `initial` | |
| `rewind_burn` | `150.0` | `[10, 500]` | 回溯：颗粒/秒 |
| `haste_burn` | `70.0` | `[10, 500]` | 加速：颗粒/秒 |
| `window` | `250.0` | `[0, 1000]` | 短时额度,也是贷款上限 |
| `regen` | `50.0` | `[0, 300]` | 短时回复（颗粒/秒） |
| `kill_ratio` | `0.5` | `[0, 1]` | 击杀获取 = 被击杀者账户总额度 × 此比例（被击杀者不减少） |
| `block_gain` / `damage_gain` | `10` / `4` | `[0, 200]` / `[0, 50]`（int） | 每摧毁一个 16px 子格 / 每造成 1 点伤害（仅对敌方） |
| `haste_mult` | `3.0` | `[1, 10]` | 加速倍率;固定 ×3,不进建房页 |

- `clamp_self()` 顺序:先钳 `window`(贷款上限由它推出 —— `loan_limit()` 返回 `window`),再钳 `cap >= initial`。
- `make_account()` = `GrainAccount.new(initial, cap, window, regen, loan_limit())` ⇒ PvP 的贷款上限 = 整个短时额度;单机是短时窗的 1/4。
- 建房页 `scenes/lobby_page.gd` 的滑条初值是手抄字面量(`1000` / `1800` / `150` / `70` / `250` / `50` / `10` / `4`),与 `DEF_*` 数值相同但不是引用;`kill_ratio` 以 % 展示(滑条 `[0,100]`,`as_percent = true`,回调里 `v / 100.0`)。
- `TimeRules` 零 autoload / 零场景依赖（服务器与客户端共用，`-s` 可直接测）。

### 3.3 环缓窗口

- **PvP**：`TimeRules.rewind_buffer_seconds() = minf(cap / rewind_burn, 15.0)`;`rewind_burn <= 0.0` 时返回 `0.0`。语义 = 从满额烧到空需要多少秒,硬顶 15 秒;唯一消费点是 `MatchHost._record_rw_frame()`。按 `DEF_*` 默认值算 = `min(1800/150, 15)` = **12.0 秒**。
- **单机 / 采样**：容量是 `TimeParams.SNAP_SECONDS = 40.0` 秒，两处消费：`WorldRewind.record()` 裁 `_frames`、`Level0._tick_rewind` 调 `TileLedger.prune(recorded_seconds() - TimeParams.SNAP_SECONDS)`。采样间隔：单机 `SNAP_HZ = 20`；PvP `MatchHost.RW_SNAP_DT = 1.0 / 20.0`（同一个 20Hz 抄了两处）。

### 3.4 其它落点（唯一来源 = 所处文件）

| 落点 | 常量 |
|---|---|
| `ui/watch_hud.gd` | `DIAL = 84.0`、`BIG_FONT = 96`、`SMALL_FONT = 32`、`CAP_FONT = 16`、表盘冷灰阶色板 + 红长针 / 白短针 / 贷款深红;大数字定长 0.2s 滚动(不是指数逼近),即时色:回溯 `Color8(210,62,62)` / 加速 `Color8(168,96,216)` / 常态白 |
| `scenes/level_0.gd` | 底片 ramp ≤ `0.2`、压暗 ramp `0.1`;`GLOW_PLAYER` / `GLOW_ENEMY` / `GLOW_ELITE` / `GLOW_RADIUS = 1500.0`;`Sfx.pitch_mult = clampf(1 + LOAN_PITCH_RANGE·depth (+0.12 加速 / −0.15 回溯), 0.7, 1.8)` |
| `scenes/effects/grain_crystal_fx.gd` | `SHARD_COUNT = 10`、`SCATTER_TIME = 0.28`、`ARRIVE_RATE = 16.0`、`MAX_FLY_SPEED = 4200.0`、`ABSORB_RADIUS = 16.0`、`ABSORB_TIMEOUT = 1.6`、`ABSORB_TAIL = 0.8` |
| `scenes/pvp_match_client.gd` | 两个节拍计时器(自己 `0.03`、他人 `0.06`);`TIME_GLOW_SELF` / `TIME_GLOW_OTHER`;`_time_haste_mult` 默认 `3.0`(首包后被服务器下发值覆盖) |
| `server/match/match_host.gd` | `TIME_SYNC_INTERVAL = 0.1`(10Hz 镜像)、`RW_SNAP_DT = 1/20`;轨迹每 3 物理帧一点,`_rw_trail` 上限 10 点(字面量) |
| `core/net/net_codec.gd` | `TRAIL_WIRE_MAX := 4`:线上只带最近 4 点(`_put_trail` 取尾部、多余截断) |

## 4. 怀表口径

| 字段 | 怀表上的对应 | 域 |
|---|---|---|
| `balance` | 白短针一圈 | `0..GRAIN_CAP`(结晶入账只进这里) |
| `short_used` | 红长针主圈(消耗顺时针推进、恢复逆时针拨回) | `0..SHORT_WINDOW` |
| `loan_used` | 红长针额外 1/4 圈(窗满后继续消耗即借入) | `0..LOAN_LIMIT` |
| `loan_depth` | `loan_used / loan_max` ∈ [0,1] | 世界反馈的驱动量:变亮 / 色差 / 敌加速 / 变调 |
| `locked` | 贷满即锁:长针以 50/s 回拨、还清为止 | 期间任何技能都取不出颗粒(按了也空转) |

- 恢复 50/s，先还贷后回窗；还清瞬间解锁。`deposit` 只加总余额并夹上限（不动指针）；精英击杀 +300。

## 5. 已知边界

- 回溯不还原「被打磨、但还没碎」的砖血;格级 HP 基线的纹路口径只在混纹理格上两侧不一致。`TimeField.current` 是 static 且从不置回 `null`;同一进程内「菜单 → 单机 → 回菜单 → PvP」这条路径上的残留影响未核。
- `TileLedger` 只看 `not is_rewinding()`,不按破坏来源过滤;今天单机没有第二个破坏来源。
- PvP 侧回溯的端到端行为(免伤 / 倒放 / 弹量)在 headless 里够不到;`MatchHost._apply_rw_frame` 与 `Player.rewind_restore` 的「逐字对齐」是注释声明,不是断言。线上 `trail` 只带最近 4 点 ⇒ 回溯残像比完整轨迹短;唯一判据是人眼。
