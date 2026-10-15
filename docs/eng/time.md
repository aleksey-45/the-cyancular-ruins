# 时间玩法（回溯 / 加速 / 颗粒账户 / 怀表 / 世界重绕）

> **本文件覆盖**：时间玩法的**入口与文件清单**、**不变量**、**关键常量与其唯一来源**、**已知边界（登记指针）**。
> ★ **不写设计史 / 批次 / 日期** —— 那些在 [`kh-line-log.md`](../archive/kh-line-log.md)（**已封存，勿当现行规范**；
> 与本文件或源码冲突时**以源码为准**）。
> ★ 文档会过期 —— **任何冲突以源码为准**，读之前先 `grep` 复核。
> 返回索引：[`CLAUDE.md`](../../CLAUDE.md)。

---

## 1. 入口与文件清单（谁负责什么）

### 1.1 单机（SP）

入口是 `scenes/level_0.gd`：

| 落点 | 职责 |
|---|---|
| `scenes/level_0.gd:222-227` | `pvp_mode` 早退（`:216-217`）**之后**建 `GrainAccount` / `TimeField`（并写 `TimeField.current`）/ `WorldRewind` / `TileLedger` |
| `_process`（`:317-322`） | `time_field != null and not pvp_mode` 时每帧：`_drive_time(_delta, Input.is_action_pressed("rewind"), Input.is_action_pressed("haste"))` → `_tick_rewind(_delta)` → `_tick_time_visuals(_delta)` |
| `_drive_time`（`:701`） | 按键**边沿**的 deny 音效 + 把按键态交给 `TimeField.update()` —— 时间场驱动的唯一缝（探针直调的就是它） |
| `_tick_rewind`（`:713`） | 录制 ↔ 回放状态机（状态沿是 `WorldRewind.was_rewinding`）+ 尸体保留/过期 + 瓦片账本入账/裁剪/还原 |
| `_tick_time_visuals`（`:626`） | 底片/加速压暗 ramp、贷款深度、`Sfx.pitch_mult`、`_sync_time_glows()` |
| `_rewind_elite_hits`（`:341`） | 回放弹 × 精英的**二次伤害**（每颗弹对同一精英只结算一次，meta `rw_hit_ids`） |
| `_sync_time_glows`（`:651`） | 高亮规则：加速 = 主角 + 场上敌人（近处 `GLOW_RADIUS`）；回溯 = **只有精英** |
| `_restore_sub`（`:372`） | 还原一个 16px 子格（网格 + 9 环面副本 + 持久子格 + 格级 HP + 脏块标记） |
| `ui/hud/hud.gd:59-63` | 挂 `WatchHud`（血条/氧条下方）+ `TimeSymbolHud`（屏幕中心） |

### 1.2 PvP（Beta）

| 落点 | 职责 |
|---|---|
| `server/time_economy.gd` | `TimeEconomy`：**服务器权威**颗粒经济 —— 每 role 一份 `GrainAccount` + 四条结算缝（击杀/伤害/拆砖/回复）+ 10Hz 镜像载荷 |
| `server/match/match_host.gd:286-330` | `_tick_beta_rewind()`：每 role **各自**的回溯机（环缓/倒放/免伤/轨迹），他人不受影响 |
| 同上 `:360-404` `_record_rw_frame` | 录制一帧（20Hz）：位置/速度/HP/朝向/倒地/武器弹量 + **自己的**子弹 |
| 同上 `:408-471` `_apply_rw_frame` | 把实体置回目标帧（位置/速度/HP/朝向/弹量/自己的子弹位置与引信） |
| 同上 `:336-356` `_finish_rw` | 退出回溯（松手 / 颗粒耗尽两条路共用）：裁掉"被复写的未来" |
| 同上 `:203-218` | 加速态在快照**之前**定格（快照的 `haste` 位读的就是它）；裁决在服务器，只乘自己 |
| `server/match/match_snapshot.gd:30-33` | 线上三件：`haste` 布尔 / `rewind` 布尔 / `trail`（回溯轨迹点） |
| `scenes/pvp_match_client.gd:108-114` | `_setup_beta_time_hud()`：挂 `WatchHud`（与单机同位）+ 订阅 `NetBusExt.local_time_state` |
| 同上 `:117-133` `_on_time_state` | 首包到时把**镜像账户**挂进 `Level0.grain_account` 并点亮怀表；此后每包刷 `cap/window/balance/short_used/loan_used/locked` |
| 同上 `:137-150` `_tick_beta_time` | 本地预测**加速**（倍率写 `player.pvp_haste_mult`）+ 压暗 ramp；**不本地扣颗粒** |
| 同上 `:154-180` `_tick_beta_rewind` | 本地预测**回溯**：冻结自己的 `input_source`、置免伤 meta `time_rewinding`、世界+自己上底片。**位置不本地预测** |
| 同上 `:184-207` `_apply_own_film` | 底片只作用于世界图层 + 自己（敌方单位颜色不变） |
| 同上 `:211-306` `_tick_time_fx` | 双侧视效：自己 = 加色高亮 + 红蓝残影；他人 = 回溯优先（底片 + trail 残像），否则加速高亮 + `▶▶ 3x` 标签 |
| `scenes/lobby_page.gd:342-358` | 建房页的 PvP 时间参数滑条（`TimeRules` 实例；`_beta_payload()` 先 `clamp_self()` 再上报 `{"beta":true,"time":…}`） |

### 1.3 纯逻辑层（两侧共用；`-s` 可直接跑）

| 文件 | 一句话职责 |
|---|---|
| `core/config/time_params.gd` | 单机 `TimeParams`：时间玩法的 **const 参数总表 / 代码单一来源** |
| `core/config/time_rules.gd` | PvP `TimeRules`：每局可调的实例数据 + 服务器钳制 + `make_account()` / `rewind_buffer_seconds()` |
| `core/sim/grain_account.gd` | `GrainAccount` 记账芯：总余额 / 短时窗 / 贷款 / 锁定，五个信号 |
| `core/sim/time_field.gd` | `TimeField`：模式 → 各实体 delta / 速度倍率的**唯一查询口**（静态 `current`） |
| `core/sim/world_rewind.gd` | `WorldRewind`：单机定频快照环缓 + 反向应用器 + 尸体保留（不碰 UI 与 shader） |
| `core/sim/tile_ledger.gd` | `TileLedger`：单机拆砖账本（记**改前值**，回拨按 t 降序还原） |
| `server/time_economy.gd` | `TimeEconomy`：PvP 服务器权威颗粒经济（纯逻辑、零 `NetBus`） |

### 1.4 表现层

| 文件 | 一句话职责 |
|---|---|
| `ui/watch_hud.gd` | `WatchHud` 怀表：程序化像素表盘；白短针 = 总量/上限、红长针 = 短时窗 + 贷款、右侧 96px 大数字 = 总余额 |
| `ui/time_symbol_hud.gd` | `TimeSymbolHud` 屏幕中心模式标志（回溯 `◁ ◁` 浅色快闪 / 加速 `▶ ▶` 紫色） |
| `scenes/effects/time_glow.gd` | `TimeGlow`：实体视觉节点下叠**加色混合**副本（`passes` 可两层）—— 替代 `modulate>1` |
| `scenes/effects/after_image.gd` | `AfterImage`：加速红/蓝交替残影，0.26s 淡出自毁 |
| `scenes/effects/grain_crystal_fx.gd` | `GrainCrystalFx`：精英击杀结晶 → 炸开 → 飞向怀表 → **入账**（兜底超时也必入账） |
| `scenes/effects/time_film.gdshader` | PvP 底片材质（`_apply_own_film` 用 `coverage` 参数） |
| `core/present/post_process.gd` + `core/present/post_process.gdshader` | 单机三 uniform，统一入口 `set_time_effects(film, loan, haste)` |
| `core/present/sfx.gd` | `Sfx.pitch_mult` 全局音调系数（贷款越深越尖 / 加速略升 / 回溯略降） |
| `scenes/beta_menu.gd:71` | Beta 入口页复用 `WatchHud.build_dial_texture()` 当卡片图标（静态、无实例依赖） |

### 1.5 消费点（实体脚本各一行 / 各一个注入成员）

| 落点 | 吃什么 |
|---|---|
| `scenes/player/player.gd:171-185` | 速度域倍率（`TimeField.player_speed_mult()` 或 `pvp_haste_mult`）+ `weapons.tick(delta * tm)` + 回溯整帧早退 |
| `scenes/player/player.gd:418-421` | `take_hit()` 回溯期**免伤**早退 |
| `scenes/player/player.gd:796` | `rewind_restore()`：位置/速度/HP(+`hp_changed`)/朝向/倒地/武器弹量 |
| `scenes/player/player.gd:155-168` | `pvp_haste_mult` 是 PvP 的**唯一分发源**，由 `_push_haste_mult()` 每帧推给攀爬/武器 |
| `scenes/player/swim_component.gd:45`、`scenes/player/climb_component.gd:108` | 游泳 / 攀爬吃同一倍率（漏了这条 ⇒ 一下水/上梯加速就没了） |
| `scenes/enemies/enemy_base.gd:103-106` | delta 域 + 回溯整帧早退（**精英除外**） |
| `scenes/enemies/enemy_base.gd:165` | 速度域 `velocity.x *= TimeField.enemy_speed_mult(self)`（**必须在 `move_and_slide()` 之前**） |
| `scenes/enemies/enemy_base.gd:423` | `rewind_restore()`：位置/速度/HP/存亡/可见性，**含复活时还原碰撞层** |
| `scenes/enemies/enemy_base.gd:260-262`、`:141-151` | 录制期保留尸体：死亡时打 `rw_death_ms` meta；白闪结束后**隐藏 + 停物理 + 摘碰撞层** |
| `scenes/enemies/enemy_bullet.gd:44-46` | **自己覆写**了基类 `_physics_process` ⇒ 必须自己调 `TimeField.bullet_delta`（否则加速时敌弹一点没慢） |
| `scenes/weapons/bullet_base.gd:62-64` | 子弹 delta + 回溯整帧早退；`:203/:219` `rewind_state()` / `apply_rewind_state()` |
| `scenes/enemies/enemy_bullet.gd:24-36` | 覆写读写口，补自己的 `damage` / `water_mult` |
| `scenes/weapons/weapon_base.gd:120/280` | `haste_mult` 注入成员：PvP 射手加速 ⇒ 出膛弹速 ×同倍率（**单机恒 1**，避免与 `TimeField.bullet_delta` 双乘）；`max_range` 不动 |
| `scenes/weapons/weapon_pickup.gd:119` | `TimeField.world_delta`（掉落武器等世界物件） |

---

## 2. 不变量

1. **单机闸门**：时间系统只在 `Level0` 的非 PvP 路径建立 —— `TimeField.current` 的**唯一赋值点**是 `scenes/level_0.gd:225`，而 `:216-217` 在 `pvp_mode` 时提前 `return`。`TimeField.current == null` 时六个静态查询口（`player_delta` / `enemy_delta` / `bullet_delta` / `world_delta` / `player_speed_mult` / `enemy_speed_mult`）**首行早退、恒等**。
   ★ **例外（未核）**：全仓**没有一处**把 `TimeField.current`（或 `Level0.grain_account`）置回 `null`（`grep TimeField.current\s*=` 只有那 1 处赋值、`grep time_field = null` 0 命中）⇒ 头注里"PvP/菜单为 null"只在**进程内从未进过单机**时成立；同进程内「菜单 → 单机 → 回菜单 → PvP」这条路径上的残留影响**未核**（要真跑才知道）。
2. **时间由调用方传入，纯逻辑类不读时钟，且单位是「秒」**：`GrainAccount` 的全部输入是调用方的 `delta`(秒) / `rate` / `amount`；`TimeField.update(delta, want_rewind, want_haste)`；`TileLedger.record(t, cells)` 的 `t` 由 `Level0` 传 `WorldRewind.recorded_seconds()`；`TimeEconomy.tick(delta)`。
   ★ **两处例外**（读的是 `Time.get_ticks_msec()` 系）：`WorldRewind.expire_corpses()` 用**墙钟 ms** 与尸体 meta `rw_death_ms` 比；`MatchHost._tick_beta_rewind()` / `_record_rw_frame()` 的环缓时间轴是 `Time.get_ticks_msec() / 1000.0`（**不是**帧 delta）。
3. **`TimeField` 只给倍率，绝不动 `Engine.time_scale`**（物理/tween/网络不受扰）。倍率分两域：**delta 域**（缩放 delta：重力、计时器、AI 节拍、动画、子弹位移）与**速度域**（`*_speed_mult`：水平运动与武器 tick）。`move_and_slide()` 用引擎自己的 delta ⇒ **"快/慢"必须落在速度域**，只缩放 delta 会变成"坠落变快、跳跃变低、移速不变"。
4. **模式优先级与当帧停**：`TimeField.update()` 里 `want_rewind and not want_haste` 才是 REWIND（回溯优先）；`can_spend()` 为假时按键**空转**（不结算、不改模式）；结算后若 `balance <= 0.0` 则**当帧**回落 NONE（否则会出现"空账还在回溯"的一帧）。按键空转的**边沿反馈**（`Sfx.play("deny")`）在 `Level0._drive_time`。
5. **回溯期 = 冻结 + 免伤**（判据分单机/联机两条）：普通敌整帧早退（`scenes/enemies/enemy_base.gd:105`，**精英例外**）、子弹不自步进（`scenes/weapons/bullet_base.gd:63` / `scenes/enemies/enemy_bullet.gd:45`）、玩家整帧早退（`scenes/player/player.gd:175`）且 `take_hit` 直接返回（`scenes/player/player.gd:420`）。玩家免伤判据 = 单机看 `TimeField.current.is_rewinding()`，联机看节点 meta `time_rewinding`。
6. **回放期伤害口径**：普通实体之间**不结算**伤害；**回放弹穿过精英照常结算二次伤害**（`Level0._rewind_elite_hits`，按 meta `rw_hit_ids` 去重，每颗弹对同一精英只结算一次）。
7. **精英的定义与三处特权**：`set_meta("elite", true)`。① **不入单机快照**（`WorldRewind.record` 按 meta 跳过）、② **回溯期照常行动**（两条 delta 与速度口都为它返回 1×）、③ 加速时**与玩家同倍率**，且高亮是**两层亮黄**。击杀掉 `TimeParams.ELITE_GRAIN_DROP`。
8. **颗粒账户口径**（`GrainAccount`，纯逻辑零场景依赖）：一笔 `spend(delta, rate)` **同时**扣总余额与短时窗（`short_used`）；短时窗满 ⇒ 溢出进贷款（`loan_used`）；贷款达 `loan_max` ⇒ `locked = true` 且 `can_spend()` 恒假；`regen(delta)` **无论是否在消耗都照走**，**先还贷后回窗**，贷满锁定者还清那一刻自动解锁；`deposit(amount)` **只进总余额**并夹 `cap`（返回实际入账量）；`loan_depth() = loan_used / loan_max ∈ [0,1]`（`loan_max <= 0` 时返回 0）。
9. **单机"录像带"模型**：`WorldRewind.finish()` 把"过去的将来"从 `_frames` 上裁掉（裁完若一帧不剩**至少留 1 帧**），磁带钟退回出口、之后 `record()` 从这里续录；`TileLedger.prune_after(exit_t)` 同裁 ⇒ **两次回溯互不串带**。PvP 侧同一语义在 `MatchHost._finish_rw`（两条退出路径共用）。
10. **PvP 环缓只存该 role 自己**：`_rw_buf[role]` = 该 role 的位置/速度/HP/朝向/倒地/**自己的武器弹量** + **`b.shooter == p` 的自己的子弹**（`server/match/match_host.gd:389-397`）。**不重建已消亡的弹**（已爆的榴弹不复活）。回溯期间：输入源 frozen、`take_hit` 免伤，**自己的子弹随历史倒放且照常伤害他人**。
11. **弹药回溯的语句序**（单机 `Player.rewind_restore` 与服务器 `_apply_rw_frame` **逐字对齐**）：**切枪必须排在条目写回之前**（`_equip_index` 会把走掉那把的出膛实弹写回条目）；手持实弹走 `WeaponComponent.apply_mag()`（未入树窗口写 pending，由 `WeaponBase._ready` 消费），**不直接写 `mag_ammo`**；`wlive`（手持实弹）与 `wmags`（各槽条目）**各自照抄快照**，不许"以条目为准"。
12. **回溯重建的子弹必须补 `scene_path` meta**（`core/sim/world_rewind.gd:268-270`）：写这份 meta 的唯一地方是**出膛那一刻**，重建弹绕过它 ⇒ 再录进快照时 `sp` 是空串 ⇒ 下次回溯该弹凭空消失（单次回溯的探针照不到）。
13. **单机录制期保留尸体**：`WorldRewind.hold_corpses`（静态）由 `Level0._tick_rewind` **每帧同步**（录制 = true / 回放 = false）；保留下来的尸体**隐藏的同时必须摘碰撞层**（`scenes/enemies/enemy_base.gd:145-148`，还原走 `_rw_held_layer`），否则就是玩家眼里的虚空碰撞箱；过期由 `WorldRewind.expire_corpses()` 按 `rw_death_ms` 清理。**精英不保留**（杀了就是杀了）。
14. **进/出回溯必须读同一个输入源**：单机状态沿是 `WorldRewind.was_rewinding`，PvP 是 `_rw_on[role]`；置 `src.frozen = true` 与解冻必须是**宿主自己那一个 `input_source` 对象** —— 换成另一个对象 ⇒ `want` 恒假、回溯出不来（这条不变量的登记见 `registered-debt.md` §六 第 7 条）。
15. **PvP 数值权威在服务器，客户端只做预测**：客户端拿到的只是 10Hz `TimeState` 镜像（`TimeEconomy.state_payload()`），**本地不扣颗粒**（避免双份漂移）；本地加速只写 `pvp_haste_mult`，本地回溯只做"冻结输入源 + 免伤 + 底片"，**位置由快照权威写回**。客户端上报的建房参数**不可信** —— 服务器走 `TimeRules.from_dict()`，其内部调 `clamp_self()`。
16. **瓦片回溯的粒度是"子格死亡事件"，不是 HP 变化量**：记账点在 `Level0._on_sub_destroyed`（`:408-411`），**不按破坏来源过滤**（`_owner` 形参被忽略），而 `core/sim/tile_ledger.gd` 头注声明的口径是"只记**玩家造成**的破坏" —— 单机今天没有第二个破坏来源，故两者无差别。同一格可多次入账，还原必须 **t 降序**（最新破坏先还原 = LIFO）。
17. **PvP 的开局复位必须同时还两套表**：`Level0.reset_destructibles()`（客户端）与 `MatchRound._reset_world_and_clear_dynamics`（服务器）都要复位格级 HP 表**与**子格 HP 表；漏一套 ⇒ 下一局"客户端有墙、服务器没有"⇒ 可穿墙。

---

## 3. 关键常量与其唯一来源

### 3.1 单机 `TimeParams`（`core/config/time_params.gd`，全 `const`）

| 常量 | 值 | 含义 |
|---|---|---|
| `GRAIN_INITIAL` | `1000` | 初始颗粒 |
| `GRAIN_CAP` | `5000` | 颗粒额度上限（怀表白短针一圈） |
| `SHORT_WINDOW` | `400.0` | 短时间额度（红长针一圈） |
| `SHORT_REGEN` | `50.0` | 短时额度恢复速率（颗粒/秒，先还贷后回窗） |
| `LOAN_LIMIT` | `100.0` | 贷款限额 = 短时窗的 **1/4** |
| `COST_REWIND` | `120.0` | 回溯：颗粒/秒（按住 `rewind`） |
| `COST_HASTE` | `80.0` | 加速：颗粒/秒（按住 `haste`） |
| `SNAP_HZ` | `20` | 单机快照采样频率（Hz） |
| `SNAP_SECONDS` | `40.0` | 单机环缓容量（秒）≈ 可回溯的最大时长 |
| `REWIND_START_MULT` | `3.0` | 倒放起步倍速（随后落回 1×） |
| `REWIND_RAMP_TIME` | `0.35` | 起步倍速 → 1× 的过渡时长（秒） |
| `HASTE_PLAYER` | `2.0` | 玩家与**精英**的行动倍率 |
| `HASTE_WORLD` | `0.5` | 其余一切实体（普通敌 / 敌弹 / 世界物件）的倍率 |
| `LOAN_ENEMY_SPEED_BONUS` | `0.5` | 贷款深度给普通敌的表现速度加成上限（深度 1 → ×1.5） |
| `LOAN_PITCH_RANGE` | `0.5` | `Sfx` 全局音调加成上限（深度 1 → pitch ×1.5） |
| `LOAN_BRIGHT_RANGE` | `0.35` | 画面变亮上限（shader 亮度叠加） |
| `LOAN_ABERRATION_PX` | `5.0` | 色差偏移上限（像素） |
| `ELITE_GRAIN_DROP` | `300` | 击杀一次精英掉落颗粒 |

★ **唯一来源的边界**：`TimeParams` 是时间玩法的**代码单一来源** —— `GrainAccount` 的五个字段初值与 `_init` 默认值、`WorldRewind` 的采样频率/容量/ramp、`TimeField` 的**全部**倍率与消耗速率、`GrainCrystalFx.amount` 的初值都读它。
★ **PvP 也读它的两个 ramp 常量**：`server/match/match_host.gd:319-320` 的 `lerpf(TimeParams.REWIND_START_MULT, 1.0, …REWIND_RAMP_TIME…)` ⇒ PvP 的倒放起步手感与单机**同源**（但 PvP 的采样间隔与容量**不**读 `SNAP_HZ` / `SNAP_SECONDS`，见 3.3）。

### 3.2 PvP `TimeRules`（`core/config/time_rules.gd`：默认值 + 服务器钳制）

| 字段 | 默认 `DEF_*` | 钳制 `R_*` | 备注 |
|---|---|---|---|
| `initial` | `1000.0` | `[0, 5000]` | |
| `cap` | `1800.0` | `[100, 9999]` 且 **≥ `initial`** | |
| `rewind_burn` | `150.0` | `[10, 500]` | 回溯：颗粒/秒 |
| `haste_burn` | `70.0` | `[10, 500]` | 加速：颗粒/秒 |
| `window` | `250.0` | `[0, 1000]` | 短时额度；**也是贷款上限** |
| `regen` | `50.0` | `[0, 300]` | 短时回复：颗粒/秒 |
| `kill_ratio` | `0.5` | `[0, 1]` | 击杀获取 = **被击杀者账户总额度** × 此比例（被击杀者**不减少**） |
| `block_gain` | `10` | `[0, 200]`（int） | 每摧毁一个 16px 子格 |
| `damage_gain` | `4` | `[0, 50]`（int） | 每造成 1 点伤害（仅对敌方） |
| `haste_mult` | `3.0` | `[1, 10]` | 加速倍率；**用户裁定固定 ×3、不进建房页** |

★ `clamp_self()` **顺序有讲究**：先钳 `window`（**贷款上限由它推出** —— `loan_limit()` 返回 `window`），再钳 `cap ≥ initial`。
★ `make_account()` = `GrainAccount.new(initial, cap, window, regen, loan_limit())` ⇒ **PvP 的贷款上限 = 整个短时额度**（单机是短时窗的 1/4）。
★ **第二真相源（照实记）**：建房页 `scenes/lobby_page.gd:350-358` 的滑条初值是**手抄的字面量**（`1000` / `1800` / `150` / `70` / `250` / `50` / `10` / `4`），与 `TimeRules.DEF_*` 数值相同但**不是引用** ⇒ 改 `DEF_*` **不会**同步滑条初值。`kill_ratio` 那一行例外：它以 **%** 展示（滑条范围 `[0,100]`、`as_percent=true`，回调里 `v / 100.0`）。
★ `TimeRules` **零 autoload / 零场景依赖**（服务器与客户端共用，`-s` 可直接测）。

### 3.3 环缓窗口（`rewind_buffer_seconds` 与单机 `SNAP_SECONDS`）

- **PvP**：`TimeRules.rewind_buffer_seconds() = minf(cap / rewind_burn, 15.0)`；`rewind_burn <= 0.0` 时返回 `0.0`。语义 = **从满额烧到空**需要多少秒，硬顶 **15 秒**。唯一消费点是 `server/match/match_host.gd:402`（`_record_rw_frame()` 用它裁 `_rw_buf`）。按 `DEF_*` 默认值算 = `min(1800/150, 15)` = **12.0 秒**（**由常量推出，不是一个另写的常量**）。
- **单机**：容量是**写死的** `TimeParams.SNAP_SECONDS = 40.0` 秒，两处消费：`WorldRewind.record()` 裁 `_frames`、`Level0._tick_rewind` 调 `TileLedger.prune(recorded_seconds() - TimeParams.SNAP_SECONDS)`。
- **采样间隔**：单机 `TimeParams.SNAP_HZ = 20`；PvP `MatchHost.RW_SNAP_DT = 1.0 / 20.0` —— ★ **同一个 20Hz 抄了两处**，改一处不会同步另一处。

### 3.4 其它落点（各自唯一来源 = 所处文件）

| 落点 | 常量 |
|---|---|
| `ui/watch_hud.gd:13-25` | `DIAL = 84.0`、`BIG_FONT = 96`、`SMALL_FONT = 32`、`CAP_FONT = 16`、表盘冷灰阶色板 + 红长针 / 白短针 / 贷款深红 |
| `ui/watch_hud.gd:112-135` | 大数字**定长 0.2s** 滚动（不是指数逼近）；大数字即时色：回溯 `Color8(210,62,62)` / 加速 `Color8(168,96,216)` / 常态白 |
| `scenes/level_0.gd:630-649` | 底片 ramp ≤ `0.2`、压暗 ramp `0.1`；`GLOW_PLAYER` / `GLOW_ENEMY` / `GLOW_ELITE` / `GLOW_RADIUS = 1500.0` |
| `scenes/level_0.gd:636-641` | `Sfx.pitch_mult = clampf(1 + LOAN_PITCH_RANGE·depth (+0.12 加速 / −0.15 回溯), 0.7, 1.8)` |
| `scenes/effects/grain_crystal_fx.gd:9-20` | `SHARD_COUNT = 10`、`SCATTER_TIME = 0.28`、`ARRIVE_RATE = 16.0`、`MAX_FLY_SPEED = 4200.0`、`ABSORB_RADIUS = 16.0`、`ABSORB_TIMEOUT = 1.6`、`ABSORB_TAIL = 0.8` |
| `scenes/pvp_match_client.gd:103-106` | 两个节拍计时器的声明（值在别处赋：自己 `0.03` @`:218`、他人 `0.06` @`:270`）；`TIME_GLOW_SELF` / `TIME_GLOW_OTHER`；`:102` `_time_haste_mult` 默认 `3.0`（首包后被服务器下发值覆盖） |
| `server/match/match_host.gd:7/13` | `TIME_SYNC_INTERVAL = 0.1`（10Hz 镜像）、`RW_SNAP_DT = 1/20` |
| `server/match/match_host.gd:325-330` | 轨迹**每 3 物理帧**一点、`_rw_trail` 上限 **10** 点（**字面量，没有名字**） |
| `core/net/snapshot_codec.gd:60` | `TRAIL_WIRE_MAX := 4` —— 线上**只带最近 4 点**（`_put_trail` 取尾部、多余截断，不报错） |

---

## 4. 已知边界与登记

★ **本文件不复述内容**，只给指针。时间玩法的功能性已知边界登记在
[`registered-debt.md`](registered-debt.md)（2026-10-13 起各节正文搬进 [`debt/`](debt/)）：

- **§六 功能性已知边界**（正文 [`debt/functional-boundaries.md`](debt/functional-boundaries.md)）：
  第 **1** 条「回溯不还原被打磨、但还没碎的砖血」· 第 **2** 条「格级 HP 基线的纹路口径两侧不一致（仅混纹理格）」·
  第 **7** 条「回溯退出必须读未被冻结的输入：形状与行为两侧都没有守卫」·
  第 **13** 条「武器子字典经 `record()` → `rewind_restore()` 的端到端写回没有守卫」·
  第 **14** 条「`WorldRewind` 的 `push_error` 在完全取不到 `weapons` 时也会报」·
  第 **15** 条「玩家根那 5 处反射只有计数上界、不逐名」· 第 **21** 条「`haste_probe` 6 次里 1 次真红：加速把跳跃高度改了」。
  （第 3/4 条是**已修**的回溯弹量缺陷，留作销账记录。）
- **§八 2026-10-09 测试面削减新增/改口**（正文 [`debt/test-cut-2026-10-09.md`](debt/test-cut-2026-10-09.md)）：
  第 **8.9** 条「线上 `trail` 截到最近 4 点 ⇒ 回溯残像变短，取图探针已全删 ⇒ **唯一判据是人眼**」·
  第 **8.1** 条「默认批的条数闸归零 ⇒ 现存守卫的 `ALL-OK` 只证明『没有断言失败』」。

### 4.1 守卫现状（照实）

★ **2026-10-09 测试面削减后，本域没有专属守卫。** 曾经的 `time_field_smoke` / `time_economy_smoke` /
`time_rules_smoke` / `grain_account_smoke` / `haste_probe` / `rewind_probe` / `rewind_weapon_probe` /
`tile_rewind_probe` / `elite_drop_probe` **都已删**。今天能碰到本域的只有两支：

| 守卫 | 覆盖 | 覆盖不到 |
|---|---|---|
| `tests/probe/tile_collision_probe.gd` | 相④ / 相④b：回溯后瓦片的**网格 + 碰撞 + 格级 HP** 复原（现网唯一碰 `WorldRewind` / `TileLedger` 的守卫） | 玩家/敌人/子弹的倒退、免伤、弹量、贷款、加速倍率 |
| `tests/probe/snapshot_size_probe.gd:167-168` | 线上快照里的 `haste` / `rewind` **位**（线格式对齐与预算） | 任何**行为** |

### 4.2 未核（照实标，别当结论用）

1. **`TimeField.current` 永不置 `null` 的后果**（见 §2 不变量 1 的例外）：同进程内「菜单 → 单机 → 回菜单 → PvP」
   这条路径上，PvP 的 `player.pvp_haste_mult` 会不会被 `TimeField.player_speed_mult()` 顶掉、
   残留 `loan_depth` 会不会给 PvP 的普通敌加倍速 —— **静态可推、未实跑**。
2. **`TileLedger` 不按来源过滤**：头注写"只记玩家造成的破坏"，代码只看 `not is_rewinding()`。今天单机无第二个
   破坏来源，故无差别；将来新增来源（系统/事件破坏）时两者会分叉 —— **未核**是否会真分叉。
3. **PvP 侧回溯的端到端行为**（免伤、倒放、弹量）在 headless 里够不到：服务器回溯机的代码路径今天**没有任何**
   行为守卫；`MatchHost._apply_rw_frame` 与 `Player.rewind_restore` 的"逐字对齐"是**注释声明**，不是断言。
