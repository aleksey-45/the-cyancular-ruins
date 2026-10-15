# 玩家

> ★ **2026-10-09 测试面削减 90%**:本文件里凡标着 `（已删·2026-10-09）` 的守卫**都已不存在**。
> 那一批删了什么、留了什么、代价是什么 —— 台账
> [`docs/superpowers/specs/2026-10-09-test-surface-cut-90-design.md`](../superpowers/specs/2026-10-09-test-surface-cut-90-design.md)。
> ★ 读法:**不要**因为路径还在句子里就以为守卫还在 —— 标了就是没有了。

> 从 [`CLAUDE.md`](../../CLAUDE.md) 拆出(2026-10-03,**原文逐字未改**)。返回索引:[`CLAUDE.md`](../../CLAUDE.md)。
> 本文件覆盖:玩家(scenes/player/player.gd)。
> ★ 文档会过期 —— **任何冲突以源码为准**,读之前先 `grep` 复核。

### 玩家(scenes/player/player.gd)

CharacterBody2D:指数缓动移动手感、土狼时间/跳跃缓冲/可变高度、冲刺(沿用最近移动方向;0.4s,空中冲刺重力×`charge_air_gravity_mult`=0.35)、下蹲(**逐帧推导**:在地面且按住 S 才蹲,非边沿触发——空中松开不卡蹲;蹲态可蹲走;空中按 S=下冲)、姿态碰撞箱(Pose→CollisionPolygon2D,运行时只启用当前姿态的箱子)、iframes/击退(爆炸=独立 `knock_velocity` 向量)/倒地(倒地**不取消物理**,仍受重力/击退,只是不吃输入;**单机**按 R 调 `Level0.restart_single()`——**原地复位,不是场景重载**:可破坏砖/瓦片/碰撞整层还原为建图基线 + 清子弹/敌人后重刷 + 玩家满血满氧回出生点;旧实现走场景重载,在引擎原生层偶发段错误。PvP/大乱斗**不走这条**)。移动/跳跃/冲刺/镜头/战斗数值全在 `PlayerParams`。**加新武器 = 改 1 个 `data/weapons.json` + 加 1 个 `.tscn`,零 GDScript**(唯一来源/查询口/守卫见 §武器注册表)。★ 它当年记的**失效模式**仍值得留:`scene` 路径错 → 切枪 `load("")`(响);`name` 错 → 菜单/HUD 显示错(看得见);**`tier` 与 tscn 的 `tier` export 不一致 → 容量算错** —— 前两条有守卫,**第三条只在"json 与 tscn 各写各的"时才红**,两者**一致地**填错没有守卫拦得住。★ 数字键**只剩 `1`-`4`**,但**键位 ≠ `type_id`**(1-4 是**背包位置**)。

- **★ 残弹的写入口只有一个:`WeaponComponent.apply_mag(w, mag)`** —— 按 `is_inside_tree()` 分两路:已入树 ⇒ 同步写 `w.mag_ammo`;未入树 ⇒ 写 `w.pending_mag`,由 `WeaponBase._ready()` **一次性**消费(消费后复位哨兵 `MAG_UNSET = -2`。★ 0 是合法弹数、哨兵不能用 0,而 `WeaponInventory.MAG_FULL` 是 -1)。**删掉的是帧末延迟写回 `_restore_mag.call_deferred`**:它在 C2 回滚里**按值捕获** restore 那一刻的旧弹数、到帧末才执行 ⇒ 覆盖掉重放期间打出的每一发,客户端弹数**只增不减**(用户报的"子弹剩余量不对")。守卫:`ammo_rollback_probe.tscn`（已删·2026-10-09）(同一物理帧内 restore → 开火;修复前红「期望 3、实得 4」)。★ **`pvp_twin_smoke`（已删·2026-10-09）照不出这条**(它的 sabotage 每轮清空背包 ⇒ 每次 restore 都重建实例,而开火周期与 `RESTORE_EVERY` 有公因子 ⇒ 开火与 restore **永不同帧**)。故孪生里那条 mag 断言已**撤掉**(用户裁定),别因为"少了条断言"再加回去。
- **弹数仍没有常规纠正路径**(登记,不修):`_close_enough` 不比 `mag`,`sync_soft_state` 的指纹只比 `wslot`/`winst`/背包结构。本次删掉的是**误差的产生源**,**没有**新增纠正路径 ⇒ 非回滚来源的弹数分歧仍会静默保留(已知候选:榴弹的 `max_live_projectiles`)。诊断入口:给 `pvp_match_client` 加一条 `-- --wepdiag`,每 30 帧打本端/上一条权威的 `mag`。
- **两条登记不修的边界**:① `player._apply_weapon_state` 里 `int(st.get("mag", w.mag_ammo))` 的兜底在**实例刚重建**那一帧读到的是未 `_ready` 的 0 ⇒ `apply_mag` 会记下 `pending_mag = 0`;今天**不可达**。② `apply_mag` 的 else 分支**没有直接断言**。③ **`_equip_index` 重建那一帧 `get_viewport()` 为 null 的推断仍未被复现**(孪生的开火与 restore 永不同帧,"重建 + 同帧开火"那个组合照不到)。
- **★ 未入树时 `_update_reload_pose` 空引用 `sprite`(已修)**:该函数原先无条件写 `sprite.rotation`/`sprite.position`,而 `@onready var sprite` 在**未入树**时仍是 `null`(武器实例经 `weapon_slot.call_deferred("add_child", …)` 入树,deferred 到**帧末**才跑)⇒ 每条打一行 `SCRIPT ERROR`。**修法 = 首行** `if sprite == null: return`(姿势下一帧补算)。★ **与 `mag_ammo` 走 `pending_mag` 不是一回事**:`mag_ammo` 是**权威态**、入树时会被 `_ready()` 重置,故必须提前落盘;姿势是**纯表现**。★ 该错误**只在 debug 构建可见**:release 里那条赋值 opcode 是**静默 no-op**,从来不是"玩家看得见的故障"。
- **★ 同窗口的残留 → 已修(`_mag_ready`)**:未入树的 `tick()` 会把权威的 `_reloading = false` 冲成 true —— 重建 → `_apply_weapon_state` 写 `w._reloading = st["rld"]` → **同一帧** `WeaponComponent.tick()` 在**未入树**的实例上跑 → `fire()` 的 `if mag_ammo <= 0`(`_ready` 没跑 ⇒ `mag_ammo` **恒 0**)→ `start_reload()` 见 `_reloading == false` ⇒ **置 true**。★ 后果:`fire()` 直接 return(**打不出枪**)、并播一次没按键的 `Sfx.play("reload")`。★ **修法 = `WeaponBase._mag_ready`**(声明初值 false,**只在 `_ready()` 末尾置真一次**),`fire()` 的空弹夹那一支改成 `if _mag_ready: start_reload()` —— 只让**依赖弹数的那个判断**在弹数未落定前失效,`tick()` 其余部分照跑。★ **为什么不是 `is_inside_tree()` 守卫**:那条守卫会**丢帧**,并会把 `_auto_aim()` 的朝向一起冻住 ⇒ 那本身造成**真分歧**,比它修掉的问题更坏。★ 这条**否决状态本身原有一条守卫**:`ammo_rollback_probe`（已删·2026-10-09 ⇒ 这条否决状态今天**零守卫**） 相② 的第三个鉴别点(步进前 `fire_cd_timer = 0.5`、步进后断言它被递减)在**被否决的那版**会红;同一相的**正向对照**钉住另一半:入树之后空弹夹**仍然**会自动换弹。★ 别把 `_mag_ready` 用到别的判断上。
- **结构(轻量拆分)**:根 `player.gd` 只留移动/姿态/物理帧编排;攀爬、战斗、武器分别抽成 `ClimbComponent`/`CombatComponent`/`WeaponComponent`(scenes/player/player.tscn 子节点)。组件**不写自己的 `_physics_process`**,由根每帧显式按顺序调用(`climb.update → 移动 → combat.apply_knock → move_and_slide`)。根公开接口 `take_hit/get_facing/set_facing/is_downed/apply_recoil`、信号 `hp_changed`、只读 `hp/max_hp` 原样保留。契约守卫 `player_contract_smoke.gd`（已删·2026-10-09）(源码级)。
- **输入可注入**:根读输入走 `core/net/player_input.gd` 的 `PlayerInput`(**纯接口**;本地那份是 `local_input_source.gd` 的 `LocalInputSource`,网络包那份是 `packet_input_source.gd` 的 `PacketInputSource`)。三种实现以 `source_kind()` 的枚举(`LOCAL`/`PACKET`/`AI`)自报家门。PvP 服务器注入包驱动远端玩家;瞄准有 `get_aim_dir_override()` 覆盖钩子。

---

## 实测读数与不变量（2026-10-13 从**代码注释**搬出）

> 原始台账（带原行号与出处）：[`2026-10-13-comment-diet-ledger.md`](../2026-10-13-comment-diet-ledger.md) §3 / §7 / §11 / §12。
> ★ 这里是**手感与保真的实测依据** —— 改移动/回溯/换弹前先在这里查"为什么是这个数"。

### 1. squash 的两条路径：一条真违规，一条根本不存在

- **梯子下行**：k ≈ **0.735** 被钳到满幅 **−10%**（`scale = (1.1000, 0.9000)`）—— 这是**真违规且每帧**
  （爬梯本来就不该有落地挤压）。
- **水中那条**：**不重叠**。`Water.feet_offset` 取的是碰撞箱底边 ⇒ 脚底探针**恒落在 wall 支撑格里**
  ⇒ `in_water ∧ on_floor` 重叠 **0 帧** ⇒ 当年登记的"站池底永久 ~9% 挤压"**并不存在**。
  **过滤它**买到的是另一种观感：下沉窗口的 `_air`（320/700 × 0.30 ≈ 0.137 ⇒ `scale = (0.9863, 1.0137)`）。
- **副本侧的账**：同口径项已于 2026-09-20 补上（`player_replica._in_water`，走**本地网格查询**、**零协议字段**）；
  ★ **爬梯那一半仍是残留**（spec §4.3）⇒ 本体与副本在爬梯时的形变仍可能不一致。

### 2. 加速为什么走"速度域"而不是"缩放 delta"

实测手感：**缩放 delta** 会让**坠落变快、跳跃变低、移速不变**（三个都变 ⇒ 手感崩）；
**缩放速度域**（水平速度目标 × tm、重力/跳跃保持）才对。
`_push_haste_mult` 有**三个消费点**（游泳走调用参数、攀爬/武器走注入成员）；
服务端写点在 `server/match/match_host.gd`（`haste` 字段），快照读点在 `match_snapshot.gd`。

### 3. 按名访问（反射）的三种失败形态 —— 都**不报错**

| 写法 | 拼错时的行为 |
|---|---|
| `get("x")` | **静默返回 null** |
| `set("x", v)` | **静默不写** |
| `call("x")` | 报**通用错误**，并**中止整个 `rewind_restore`** |

★ Godot 4.7.1 对 `class_name` 类型的未知成员只当**警告级** unsafe 访问（`project.godot` 没把
`unsafe_*` 升成错误）⇒ 类型化买到的是"**当场点名成员带行号**"，**不是编译期红**。
★ **同族真事故**（`core/sim/world_rewind.gd`）：`_current_slot` 改名 ⇒ 快照变空字典 ⇒ **第一个键就早退**
⇒ 位置/HP/武器**全不还原**；改回退役名后 `rewind_probe` **7 条红**（位置差 **276px**、HP **30≠50**、
HUD 血量通知未触发），同一跑引擎每帧报 `Nonexistent 'int' constructor`（**83 行**）。

### 4. 回溯保真的两处缺陷（发现 A / B）与它们的覆盖上限

- **发现 A**：切枪帧 `index=1 mag=9` ⇒ 入树后 `mag=4`。
- **发现 B**：快照 `wmags=[11,1]` / `widx=1` ⇒ 切枪后 `held[0].mag=3`。
- 覆盖它的 S8-A/B/C/D 四条变异各有对应关系（见 `docs/eng/debt/` 的登记）。
  ★ **覆盖上限照实写**：S8 **直调本函数**、**不覆盖真回溯的帧选择**；PvP 那份 `MatchHost._apply_rw_frame`
  的**行为侧没有 headless 守卫**（归"真链路批 A"，而批 A 结构上碰不到它）。
- **`apply_mag` 顺带钳位 `[0, mag_size]`**：其中"范围内逐位等价"是**推理不是实测**；
  越界档（"快照之后那槽换型号"）**没有任何断言**（债 §六.3）。

### 5. 复活与换弹语义（和旧版不同，别按旧文档改）

- **背包化前的旧语义**：`reset_mag_state → equip_type(default_type()) → refill_current_weapon`
  ＝"**复活即回默认枪 + 满弹**"。
- **今天**：单机重开由 `Level0.restart_single` **统一重置**；联机复活是"**除随机一把外全丢**"。
- **联机长按丢弃曾形同虚设**：早先 `if pvp_mode: return` 直接返回（当时阈值 2s，现 **0.6s**）；
  而 `LocalInputSource` 的 drop 读口当时报"Q 按着" ⇒ **碰一下 Q 就丢、按住每 tick 丢一把**。

### 6. 两个"换场景"的坑（都会表现为崩溃或黑屏）

- `host_level` 的实测：**探针里给 `current_scene` 赋值不生效**。
- **重建世界会偶发原生段错误**（重启后蓝屏 / 地图未加载）。**推迟一帧**与 `safe_change_scene` **同因**：
  立刻摘树会触发 CanvasItem 的 `EXIT_TREE`。

