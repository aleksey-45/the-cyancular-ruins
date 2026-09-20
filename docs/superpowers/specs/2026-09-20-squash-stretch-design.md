# 2026-09-20 Squash & Stretch 设计：玩家与敌鸟的补间形变

给玩家与三种敌鸟增加 squash & stretch 表现。**不新增任何逐帧贴图**，只对现有 `AnimatedSprite2D` 的 `scale` 做程序化补间。

**范围裁定**（用户 2026-09-20 逐条选定）：

| # | 问题 | 裁定 |
|---|---|---|
| 1 | 覆盖哪些动作 | **全选**：玩家起跳/落地 + 受击/冲刺；三只鸟起飞/落地 + 冲撞 |
| 2 | 远端副本要不要同款 | **要**，且**副本本地推导、协议不改** |
| 3 | 载体 | **纯代码组件**（否决 AnimationPlayer 资源） |
| 4 | 强度 | **不要太夸张** —— 幅度锁在 ±10% 量级 |

⚠️ 裁定 3 是**推翻我本人前一轮建议**的结果。我最初推的是 `AnimationPlayer`，探完代码后改推纯代码。理由见 §2.1，**别照"用户一开始说用 AnimationPlayer"改回去** —— 用户当时的"使用这个"是在两个方案摆开之前说的。

---

## 1. 现状（全部为代码证据，非推测）

### 1.1 `scale` 在所有角色上都是空闲的

| 证据 | 内容 |
|---|---|
| `enemy_base.gd:277-281` | 敌人朝向走 `_anim.flip_h`，**不碰 scale** |
| `player.gd:325`、`:540` | 玩家朝向走 `animator.flip_h` |
| `player_replica.gd:116` | 副本朝向走 `animator.flip_h` |

`scenes/**/*.tscn` 里 `scale` 只出现在武器（`weapon_base.gd:348/397` 的 `scale.x = facing`）与其他节点上，**没有任何角色用 scale 做镜像**。所以写 `animator.scale` 不会与朝向打架 —— 这是本设计最大的前置风险，已排除。

### 1.2 项目里零 AnimationPlayer

`scenes/**/*.tscn` 中 `AnimationPlayer` / `AnimationTree` / `Tween` **一个都没有**（仅出现在 `RELEASE.md` 与 `cyancular_build_profile.gdbuild` 的类列表里）。动画一律是 `AnimatedSprite2D` + 状态机 `play()`。

### 1.3 玩家 `_physics_process` 的挂点顺序（`player.gd:159-222`）

```
159  func _physics_process(delta):
160      if combat.is_downed(): _tick_downed(delta); return     ← 早退
163      weapons.tick / combat.update_iframe_blink
167-187  切枪 / 换弹 / 拾取丢弃
196-206  swim.update / climb.update
208      _tick_vertical(delta, ...)      ← 起跳发生在这里（:244-252）
209-212  crouch / horizontal / facing / pose
216      combat.apply_knock
219      move_and_slide()                ← 落地判定的事实来源
221-222  _tick_slide_reactions / _wrap_position
```

### 1.4 敌人 `_physics_process` 的挂点（`enemy_base.gd:91-136`）

```
91   func _physics_process(delta):
93       if _is_far_sleeping(): _ai(delta); _wrap(); return     ← 早退
98-106   gravity（is_on_floor() 时跳过）/ 地面摩擦
108-116  _ai / _anim_update / 接触伤害
118-125  受击/死亡白闪
130      _apply_water
133-135  move_and_collide(knock_velocity) / move_and_slide()
```

`_set_state()` 在 `enemy_base.gd:286-288`，只有两行（`state = s` + `_state_timer = 0.0`），是全部状态切换的唯一收口。

### 1.5 三只鸟的状态枚举各不相同

| 敌人 | 枚举 | 本设计关心的状态 |
|---|---|---|
| FlyBird | TAKE_OFF / FLY / SHOOT / CHARGE / RETURN … | TAKE_OFF、CHARGE |
| BlackBird | … TAKE_OFF、CHARGE … | TAKE_OFF、CHARGE |
| JumpBird | `{SLEEP, WAKE, CHASE, LUNGE_WINDUP, LUNGE_DASH, BACK_HOP}` | LUNGE_DASH、BACK_HOP |

⚠️ JumpBird **没有 TAKE_OFF**。所以基类**不能**硬编码状态名，必须走虚钩（见 §4.2）。

### 1.6 敌人只存在于单机

`EnemySpawner` 的引用方只有 `level_0.gd` / `hud.gd` / `combat_feedback.gd` / 敌人自身 / 测试。
`level_0.gd:236` 在 `pvp_mode` 时**早退**，`EnemySpawner.load_types()` 与 `spawn_all()`（`:238-243`）都在早退之后。

→ **PvP / 大乱斗不生成任何敌人**，敌人侧 squash 无联机影响。

---

## 2. 方案：纯代码组件

### 2.1 为什么否决 AnimationPlayer

| # | 理由 | 证据 |
|---|---|---|
| 1 | 引入**第二套并行动画驱动范式** | §1.2：项目零 AnimationPlayer；CLAUDE.md 反复要求"只留一条路径""别再加一套" |
| 2 | 同一个节点附近出现两个 `play()` 语义 | `animator.play("flying")` 管帧、`AnimationPlayer.play("squash")` 管 scale |
| 3 | AnimationPlayer 一次只跑一个 animation | 而"同时发生"（冲刺中落地、起跳瞬间被击中）在本项目是常态，叠加/打断要自写优先级机，代码反而更多 |
| 4 | 强度必须动态 | 落地挤压量该由落速决定；AnimationPlayer 是固定曲线，要动态只能 `seek()` 手控，把它的优势全用掉 |
| 5 | 副本要复用同一套逻辑 | 纯代码下副本直接传快照数据跑同一组件 |
| 6 | 项目已有三个对应物 | `ClimbComponent`/`CombatComponent`/`WeaponComponent`（约定"组件不写自己的 `_physics_process`，由根显式按序调"）、`MathUtil.approach`（`math_util.gd:11`，指数缓动的单一来源）、`PlayerParams`/`EnemyParams` 参数体系 |

AnimationPlayer 唯一真优势是"曲线在编辑器可视化调、美术能参与"。用户已知悉并选择了纯代码。

### 2.2 文件位置

**`scenes/effects/squash_stretch.gd`** —— `class_name SquashStretch extends Node`

放 `scenes/effects/` 是因为已有同款先例：`water_fx.gd` 就是"运行期挂到主角 + 敌人身上"的纯表现节点。本组件完全同构 —— 挂到任意"有 `AnimatedSprite2D` 的角色"上，玩家与三只鸟共用一份。

### 2.3 计算模型：两个标量相加，不是状态机

```gdscript
func setup(animator: AnimatedSprite2D) -> void
func tick(delta: float, vel_y: float, on_floor: bool, suppressed: bool) -> void
func impulse(kind: int, strength: float = 1.0) -> void
```

| 标量 | 来源 | 有无状态 |
|---|---|---|
| `_air` | 每帧由 `vel_y` **重算**（下坠略拉伸） | **无状态** —— 回滚重放结果一致 |
| `_impulse` | 事件累加，按 `MathUtil.approach` 指数回归 0 | 有状态 |

```
final = clampf(_air + _impulse, -1.0, 1.0)
scale = Vector2(1.0 - AMOUNT * final, 1.0 + AMOUNT * final)
```

**正 = 窄高（拉伸），负 = 宽矮（挤压）**，x 与 y 反向变化：`final = +1` → `(0.90, 1.10)` 是**拉伸**（窄高），`final = -1` → `(1.10, 0.90)` 是**挤压**（宽矮）。

⚠️ 符号方向以**增益表**为准（`squash_jump` / `squash_dash` / `squash_take_off` / `squash_charge` 为正 = 拉伸；落在 `tick()` 里的 `_impulse -= squash_land * k` 与增益表里的 `-squash_hurt` 为负 = 挤压）。

★★ **（2026-09-20 订正，Task 3 审查）这段曾在实现期被反过来。** 当时有人把 `(0.90, 1.10)`（窄高 = 拉伸）误读成"宽矮"，于是把本行改成 `Vector2(1.0 + AMOUNT * final, ...)`，还在此处写下"初稿公式是撰写时的笔误"一段 —— **那一段才是错的**，公式与那段说明现已一并订回。**别照那段话再翻一次**：翻过去会让**每个**事件都反（起跳变压扁、落地变拉伸），而当时的四个测试是照着翻转后的公式写的，于是全绿通过 —— 变异验证验的是**一致性**，不是**方向**（`tests/squash_stretch_smoke.gd` 的断言方向与标签本轮同步翻正）。

**用单标量而不是双标量**（分开记拉伸/挤压）是刻意的："冲刺中落地""起跳瞬间被击中"这类同时事件天然叠加，不需要优先级状态机 —— 这正是选纯代码方案的核心收益。

`suppressed = true` 时强制回归中性 (1,1)（倒地用，见 §5.2）。

### 2.4 落地判定：无状态推导，不用 `_was_on_floor`

`_tick_vertical` 在 `is_on_floor()` 时**不施重力**（`player.gd:229-235` 的 if/else），所以：

- **站立时** `velocity.y` 恒为 0
- **落地那一帧** `move_and_slide()` 之前的 `velocity.y` 必然是个大正数

于是落地判定 = `on_floor && pre_move_vy > LAND_MIN_VY`，**不需要任何跨帧变量**。

★★ **但这个前提只对重力路径成立 —— 宿主必须自己把关，把"不是摔下来的"下坠速度滤掉。**（2026-09-20 由 Task 2 审查发现并修正；初稿漏了这条。）

已知的违规写入者（都是"在地面上仍然写正 `velocity.y`"）：

| 位置 | 写入 | 值 | 水面/地面上会怎样 |
|---|---|---|---|
| `swim_component.gd:26` | `velocity.y = player_swim_down` | **320** > 220 | ⚠️ **实测：不会重叠**（见下），本条不构成每帧违规；过滤它买到的是别的（见下） |
| `climb_component.gd:91` | 梯子下行速度 | `300×2.0×1.2` = **720** | 梯底按住 S 时**每帧**触发 |

⚠️ **梯子那行不是"只触发一帧"**（本 spec 初稿如此写，2026-09-20 由复审读码推翻）：初稿的理由是"下一帧 `is_squat` 使其解除攀附"，但 `_tick_crouch_and_dash` **首行就 `if latched or in_water: return`**，而 `is_squat` 的唯一赋值点在该早退**之后** → 攀附期间 `is_squat` 冻结在攀附前的值，**永远不会**变 true，攀附不解除。

★ 本节**刻意不写行号**（用函数名/符号指代）：本文件所在的密集改动区里行号是负资产 —— 初稿此处写过的 `player.gd:287-289` / `:299` 在 Task 2 落地后已漂到 `:293-294` / `:301`,`:287-289` 那一段甚至落进了 `_tick_vertical` 的尾部，会误导核对者。

代入 `k = (720-220)/680 ≈ 0.735` → 稳态被 `_apply()` 钳到**满幅 −10%**，比水中那条更狠。同样是"只要按着 S 站在梯底就一直压着"。

★★ **梯子这条才是真正的每帧违规** —— 实测 `k≈0.735` 被钳到满幅 10%，`scale = (1.1000, 0.9000)`（挤压 = 宽矮），与预测逐位吻合（`tests/squash_host_water_probe` 相 ②）。

★ 两条**形状并不相同**（初稿说"同形"，实测后不成立）：梯子是"宿主持续写正 `velocity.y` **且** `is_on_floor()` 为真"的真违规；水里则连重叠都不发生（见上）。但**同一个谓词 `in_water or latched` 一并覆盖**两者 —— 梯子那条是修 bug，水里那条是落实取舍。谓词不必拆开。

★★★ **实测更正（2026-09-20，`tests/squash_host_water_probe` 跑出来的）：上面"水里每帧触发、稳态 ≈ -0.91"的推理是错的。**

`Water.feet_offset` 取的是**碰撞箱底边**（57px），所以脚底探针在"站在水下实心地面"时**永远落在支撑格**里，而支撑格是 `wall` 不是 liquid ⇒ **`in_water` 恒为 false**，`in_water` 与 `is_on_floor()` 的重叠是 **0 帧**（探针把这一行当证据打印）。预测的"站池底永久 ~9% 挤压"**不存在**。

那么过滤 `in_water` 到底买到了什么？**下沉窗口**（探针实测 **30 帧**；探针打印的原话是 `water 帧 30 / 60`，即相①窗口 60 帧里有 30 帧 `in_water` 为真）：玩家在水中下沉、尚未触底时 `in_water = true` 且 `is_on_floor() = false` —— 落地项本来就不成立，但**连续项 `_air` 成立**。不过滤时 `_air = (320/700)×0.30 ≈ 0.137` → `scale.x = 0.9863`（一个**拉伸** —— 窄高即 x < 1）；过滤后 = 1.0000。

★ 也就是说：`in_water` 那一半过滤**不是在修 bug，而是在落实一个设计取舍** —— "游泳时不要有自由落体那种弹感"（本 spec 上文已把这个代价记为"已确认接受"）。它的价值是真的，但性质与梯子那条**不同**，别把两者说成同一个病。

⚠️ 本 spec 初稿还写过"稳态 ≈ -k·d/(1-d) 代入得 ≈ -0.91"的算式。那个算式本身没错，**错的是它假设的重叠会发生**。留此存照，避免有人照旧算式重新推出那个不存在的结论。

**因此宿主的契约是：传进 `tick()` 的 `vel_y` 必须是"地面真正吸收掉的"那个下坠速度**，否则传 0：

```gdscript
# player.gd（move_and_slide 之前）—— 有过滤
_pre_move_vy = 0.0 if (in_water or latched) else velocity.y
# enemy_base.gd（同上）—— ★ 不要过滤，直接用裸值
_pre_move_vy = velocity.y
```

★★★ **敌人侧刻意不过滤 —— 实测证明过滤在那边是净有害的（2026-09-20，Task 3 实现期的 A/B）。**

| 项 | 敌人侧实测 |
|---|---|
| `_in_water ∧ is_on_floor()` 重叠 | **真实存在**：239/1350 帧（玩家侧是 **0**） |
| 成因 | 敌人的身体停在池底上方 **0.02~0.18px**，`Water.feet_offset` 把探针放进它**上面那个水格**（玩家侧那个偏移落在支撑格里，故玩家侧为 0） |
| 过滤想防的"幽灵挤压" | **结构上不可达**：浮力被钳在 −260/+160，**下沉侧最大 160 < 阈值 220** ⇒ 落地分支永远不会被水的写入触发 |
| 过滤实际做了什么 | **吃掉 13 次真实的落水挤压**（原始 vy 246~1189 px/s；有过滤时 `max scale.x` 恒 1.0000，去掉后 1.0861 —— 挤压方向是 x > 1，故看的是**最大** scale.x） |

⇒ 敌人侧那一行"既不防幽灵、又抹掉真落地"，净效果是让入水那一下**变哑**。敌人不会爬梯（玩家侧那个**真**违规的来源），没有对应的第二条。

★ 玩家侧**保持过滤不变**：那边重叠为 0，所以它不会吃掉任何落水挤压 —— 实际效果只是关掉下沉时的 `_air` 拉伸，而那已记为"已接受的设计取舍"。两侧结论不同是**实测差异**（探针落在哪个格），不是不一致。

⚠️ **别把两侧写成"同款过滤"** —— 本 spec 初稿正是那么写的（"enemy_base.gd（同上）"），实测推翻了它。

★ 代价（已确认接受）：水中 `_air` 也一并读 0 → **游泳时没有连续项拉伸**。这被认为是**正确**的 —— 游泳不该有自由落体那种弹感，且"空中连续项"的语义本就指空中。
★ 另一条约束：倒地期间 `_pre_move_vy` 会变陈旧（`_tick_downed` 不更新它），复活首帧会与地面态配对出一个满幅假挤压 —— 故倒地分支要把它归 0。
★ **同类第二条（2026-09-20，Task 3 审查）**：敌人的 `_is_far_sleeping()` 早退**不跑 `move_and_slide`** ⇒ 那一支里 `_pre_move_vy` 同样**永不刷新**，而 `tick()` 在它之前跑 ⇒ 陈旧值（上一次非睡眠帧的落速）让落地项**每帧重触发**，指数恢复每帧只回 `1 - exp(-9/60) ≈ 14%` ⇒ 定点 ≈ `-6.19k`（任何 `k ≳ 0.16` 都被钳到 `-1`）⇒ 被垂直击退打飞、落地时 `|vx| ≤ 5` 的远鸟**永久**保持满幅挤压。故那一支的 `vel_y` 显式喂 0（`0.0 if sleeping else _pre_move_vy`）。

⚠️ 但 `is_on_floor()` 在帧首读到的值是**上一帧** `move_and_slide()` 的结果。所以读取时必须与**同一次** `move_and_slide()` 之前的 `velocity.y` 配对：

```gdscript
# 在 move_and_slide() 之前缓存（player.gd / enemy_base.gd 的 move_and_slide 之前）
# ★ 已被上面的宿主契约取代 —— 不要再写成裸的 `velocity.y`（那是本节初稿，有洞）。
_pre_move_vy = 0.0 if (in_water or latched) else velocity.y
```

帧首的 `is_on_floor()` 与 `_pre_move_vy` 因此描述**同一时刻**，二者一致。

不用 `_was_on_floor` 的第二个理由：它是跨帧状态，回滚重放时会与权威态脱节；而无状态推导在重放时给出相同结果。

---

## 3. 数值（轻微档，全部进参数文件）

**共同项**（两边同名同值，各自定义在自己的参数文件里 —— 两个参数类互不依赖，不建共享常量）：

```gdscript
const squash_amount: float = 0.10          # 满冲击形变量 → 最多 0.90 / 1.10
const squash_recover: float = 9.0          # 冲击回归速率（指数）
const squash_land_min_vy: float = 220.0    # 落速低于此不挤压（下小台阶不触发）
const squash_land_ref_vy: float = 900.0    # 达到此落速 = 满挤压
const squash_land: float = 1.00            # 落地挤压上限
const squash_hurt: float = 0.50            # 受击挤压
const squash_air: float = 0.30             # 空中连续项上限
const squash_air_ref_vy: float = 700.0     # 空中连续项参考速度
```

**差异项**：

| 落点 | 常量 | 值 | 对应事件 |
|---|---|---|---|
| `PlayerParams` | `squash_jump` | `0.75` | 起跳 |
| `PlayerParams` | `squash_dash` | `0.80` | 冲刺 |
| `EnemyParams.shared` | `squash_take_off` | `0.80` | 鸟起飞（FlyBird / BlackBird） |
| `EnemyParams.shared` | `squash_charge` | `0.90` | 冲撞（FlyBird / BlackBird CHARGE、JumpBird LUNGE_DASH / BACK_HOP） |

玩家**没有** take_off/charge，敌人**没有** jump/dash —— 不是漏写。

⚠️ 两处参数文件里若已有同名常量需先查重（见 §8）。

**`0.10` 是上限，不是每项的幅度** —— `final` 被钳在 `[-1, 1]`，所以实际形变永远不超过 `0.90 / 1.10`。叠加多少项都不会爆。

---

## 4. 挂点

### 4.1 玩家（`player.gd`）

`tick` 放在 `_physics_process` **第一行**（`:160` 的倒地早退**之前**），不是末尾。三个理由：

1. 倒地早退（`:160-162`）不会漏掉 tick —— 否则 `animator.scale` 会**卡在最后一个挤压值**上（明显的视觉 bug）
2. `is_on_floor()` 与 `_pre_move_vy` 在帧首是配对的（§2.4）
3. 与 `move_and_slide()` 解耦，重放时顺序稳定

```gdscript
func _physics_process(delta: float) -> void:
    squash.tick(delta, _pre_move_vy, is_on_floor(), combat.is_downed())   # ← 新增，最首行
    if combat.is_downed():
        _tick_downed(delta)
        return
    ...
```

新增字段：`var _pre_move_vy: float = 0.0`，在 `move_and_slide()`（`:219`）**之前**赋值。

事件钩子：

| 事件 | 位置 |
|---|---|
| 起跳 | `_tick_vertical` `:249` 之后 |
| 冲刺 | `_tick_crouch_and_dash` `:276-278`（`is_charge = true` 处） |
| 受击 | 根 `take_hit`（公开接口，已保留） |

### 4.2 敌鸟（`EnemyBase` + 三个子类）

`tick` 同样放 `_physics_process` **第一行**（`:93` 的 `_is_far_sleeping()` 早退**之前**），这样睡眠时也走 tick（睡眠 → `vel_y` 小 → 自然回中性，正是想要的行为）。

```gdscript
func _physics_process(delta: float) -> void:
    squash.tick(delta, _pre_move_vy, is_on_floor(), is_dead)   # ← 新增，最首行
    if _is_far_sleeping():
        ...
```

`_pre_move_vy` 在 `move_and_slide()`（`:135`）之前赋值。

**状态事件走虚钩**（因为三只鸟枚举不同，见 §1.5）。基类 `_set_state()`（`:286-288`）加一行：

```gdscript
func _set_state(s: int) -> void:
    state = s
    _state_timer = 0.0
    _on_state_entered(s)        # ← 新增虚钩，基类默认空实现

func _on_state_entered(_s: int) -> void:
    pass
```

三个子类各自覆写，映射自己的枚举：

| 子类 | 覆写内容 |
|---|---|
| FlyBird | `TAKE_OFF` / `CHARGE` → 拉伸 |
| BlackBird | `TAKE_OFF` / `CHARGE` → 拉伸 |
| JumpBird | `LUNGE_DASH` / `BACK_HOP` → 拉伸 |

受击挂 `_apply_hit`（`enemy_base.gd:150`）。

⚠️ **JumpBird 的小跳（`enemy_jump_bird.gd:101-102`）刻意不挂钩**（用户 2026-09-20 裁定）：它是 `_tick_chase` 里直接设 `velocity`，**不经过 `_set_state()`**，所以状态虚钩接不到。不为此另加钩子 —— 小跳的 `hop_jump_velocity = -750` 会让 §2.3 的**空中连续项**直接给出拉伸，只是没有事件那一下"脆感"。这是有意的取舍，不是遗漏。

### 4.3 对手副本（`player_replica.gd`）

复用同一个 `SquashStretch` 组件，数据换来源。

**`vel` 已经在服务器载荷里**：`server/match_snapshot.gd:20` 发 `"vel": p.velocity`。副本当前**没读**它（`apply_snapshot`）：`player_replica.gd:109-147` 只读 `pos/facing/aim/weapon/previewing/downed/pose`。

→ 在 `apply_snapshot` 里加一行 `_vel = data.get("vel", Vector2.ZERO)` 即可。**这是客户端开始读一个本来就存在的字段，协议零改动、服务器零改动**。先例：`tests/reconnect_watcher.gd:292` 早就在读 `pl.get("vel", Vector2.ZERO)`。

**tick 放在 `_process(delta)`（`:182`）末尾，不是 `apply_snapshot`。** 两个理由：

1. `apply_snapshot` **没有 `delta`** —— 包络衰减需要它
2. `_process` 正是副本的**表现层时钟**：插值推进（`:186` `_interp.advance(delta)`）与受击闪烁衰减（`:197-202`）都在那里。挤压包络若挂在快照回调上（60Hz 物理时钟），会与插值（渲染时钟）产生拍频

⚠️ `_process` 里那段受击闪烁（`:197-202`）就是**同款先例** —— 一个按 `delta` 衰减的视觉包络。照它写。

`apply_snapshot` 只负责**记录数据**（新增字段 `_vel`；`_pose` 与 `_downed` 已在函数内可读），衰减与写 scale 全在 `_process`。

| 事件 | 副本的推导方式 |
|---|---|
| 空中连续项 | `_vel.y` 直接可用 |
| 起跳 | `pose` 进 `FLY` 且 `_vel.y < 0` |
| 落地 | `_vel.y` 从大正数骤降到 ≈0，且 `pose` 离开 `FLY` |
| 受击 | ❌ **不做** |

**副本不做受击挤压**的理由：快照里没有受击事件。从 `hp` 下降推会在 AoE 多段伤害时误触发（一次爆炸可能连扣数帧）。要做就得加协议字段，与本轮"协议不改"矛盾。

**副本在 `_downed` 时强制 `suppressed = true`** —— 见 §5.2，这是必须的，不是优化。

---

## 5. 联机安全（本条为用户点名要求）

用户原话：**"小心联机出问题"**。以下五条逐条查证。

### 5.1 `animator.scale` 不参与任何模拟

| 检查 | 结论 |
|---|---|
| 是否进 `capture_state()`（`player.gd:449`） | ❌ 不进。squash 状态住在组件里，不在 `Player` 上 |
| 是否被 `restore_state()`（`player.gd:499`）重置 | ❌ 被碰的是 `velocity`/`animator.flip_h`（`:502`、`:540`），**不含 scale** |
| 是否影响碰撞箱 | ❌ 碰撞走 `Pose → CollisionPolygon2D`（`player.gd:348-349`），是独立的世界空间多边形，与 `animator.scale` 无关 |
| 是否影响 `CollisionAabb.world_rect` | ❌ 它读 `CollisionPolygon2D` / `CollisionShape2D`，不读精灵 |
| 是否影响 `SpriteBounds.from_sprite`（`WeaponPickup` 用） | ❌ 那是武器自己的 sprite，角色 scale 不参与 |
| `_pre_move_vy` 是否进 `capture_state()` | ❌ **不得进**，且**不得被任何模拟逻辑读取**（只喂 squash） |

### 5.2 倒地必须强制中性 —— 副本会沿转过的轴挤压

`player_replica.apply_snapshot` 倒地时给**根节点**设旋转：

```
player_replica.gd:128-130
    if _downed:
        animator.stop()
        rotation = -PI / 2.0 * float(_facing)
```

而 `animator` 是**根节点的子节点** → 此时写 `animator.scale` 会作用在**旋转 90° 后的局部轴**上，尸体横着变宽。

（注意 `:138-144` 有同款先例：幽灵体正因这个旋转而被单独压回 `global_rotation = 0`。）

→ **两边都要 `suppressed = true`**：副本（因为旋转轴）与本地玩家（虽然本地玩家不旋转 —— `player.gd` 全文件零 `rotation` —— 但尸体弹跳本身不合理，且两端行为应一致）。

### 5.3 `move_and_slide()` 跨接缝与环面无关

squash 只读 `velocity.y` 的标量，不做任何位置/距离计算 → 天然不涉及环面最短向量，不存在跨接缝出错的可能。

### 5.4 回滚重放会重播挤压包络（已读代码证实，登记不修）

`core/net/prediction_rollback.gd:114` → `_p._physics_process(PHYS_DT)`

**重放是直接调玩家的 `_physics_process`**。而 `_impulse` 不在 `capture_state()` 里、`restore_state()` 也不会重置它 → 重放时事件钩子（起跳/冲刺）会重新触发，挤压包络**重播一次**。

- 影响：纯视觉，幅度上限 ±10%，表现是"弹一下"
- 不修的代价 vs 修的代价：修就要把纯视觉状态塞进权威态（污染 C2 快照、增加每帧字节），**是更坏的选择**
- `_air` 项无状态，重放结果一致，不受此影响

### 5.5 副本落地时机略钝（用户已接受的代价）

副本位置走**双快照 tick 域插值**、渲染时钟落后最新 1 tick，而 §4.3 的落地推导读的是 `_vel`/`pose` 的**最新**快照值（这两个字段是即时套用的，不插值 —— 见 `player_replica.gd:145-147` 的注释）。

所以姿态切换是即时的、位置是插值的 → 推导出的落地**瞬时性**与本体一致，但配合上位置滞后，视觉上会比本体**略钝**。这是用户选"本地推导、协议不改"时接受的代价。

---

## 6. 硬约束（实现时不得越线）

1. **只写 `animator.scale`**。不写 `self.scale`（玩家根 `scale = 2.5` 是世界缩放，写了整个角色会缩），不写 `flip_h`（朝向归 `_set_facing` / `_tick_pose_and_collision`）。
2. **不进 `capture_state()` / `restore_state()`**。
3. **不碰任何碰撞体**（`Pose → CollisionPolygon2D` 那套完全不动）。
4. **组件不引 autoload** —— 参数读静态 `const`（`PlayerParams` / `EnemyParams` 都是 `RefCounted` + `const`，静态访问安全）。保住 `-s` 可测，这是项目反复强调的纪律。
5. **组件不写自己的 `_physics_process`** —— 由宿主每帧显式调 `tick()`，沿用 `ClimbComponent`/`CombatComponent` 的既有约定。

---

## 7. 测试

### 7.1 `tests/squash_stretch_smoke.gd`（`-s`，纯逻辑）

直接 `new()` 组件 + 假 animator，断言：

- 静止（`vel_y = 0`、`on_floor`）→ `scale == Vector2.ONE`
- 落地冲击 → 挤压方向（宽矮：`scale.x > 1 && scale.y < 1`）
- 起跳冲击 → 拉伸方向（窄高：`scale.x < 1 && scale.y > 1`）
- 指数回归：固定喂 `delta = 1/60`，断言 **30 帧后** `absf(scale.x - 1.0) < 0.01`、**60 帧后** `< 0.001`。
  按 `squash_recover = 9.0` + `squash_amount = 0.10` 推算：`exp(-9×0.5)×0.10 ≈ 0.0011`、`exp(-9×1.0)×0.10 ≈ 1.2e-5`，阈值留了宽裕余量。
  阈值**不要**写成"精确等于 `Vector2.ONE`" —— 指数回归是渐近的，永不精确到达
- 夹取：叠加多项后 `|scale.x - 1| <= squash_amount`
- **低落速不触发**：`vel_y = 100`（< `squash_land_min_vy`）不产生挤压
- **`suppressed = true` → 立刻中性**
- 多事件叠加不爆

⚠️ 写这条冒烟时注意项目既有纪律：`_initialize()` 里 `load()` 之后立刻判空并 `quit(1)`（否则抛错会永久挂起），且跑的时候套 `timeout`。

### 7.2 `tests/squash_stretch_probe.tscn`（真渲染）

照 `hue_tint_probe` 先例：

- **必须真实渲染**（headless 下截图链给 null，要判在 `.get_image()` 的返回值上并 FAIL）
- 断言 `animator.scale` 真被改过、且**碰撞箱世界 AABB 与世界位置未受影响**（对照 §5.1）
- 存图供**人眼**验收 —— 图要**自己读**，不推回给用户（这一步在历史上抓到过两个数值全绿的 bug）

---

## 8. 未决 / 留给实现计划的事

- JumpBird 的实际状态转换点需要逐个核对（grep 只看到 `_set_state(State.SLEEP)` 一处显式调用，其余跳跃可能是直接设 `velocity.y`）—— §4.2 的虚钩映射以实际代码为准。
- `PlayerParams` 与 `EnemyParams.shared` 里是否已有同名常量需先查重（避免重复定义）。
- 敌人侧 `_downed` 无对应概念，用 `is_dead` 代替（`enemy_base.gd:28`）—— 语义一致（尸体不该弹）。
