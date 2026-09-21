# Squash & Stretch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 给玩家与三种敌鸟增加 squash & stretch 补间形变，让起跳/落地/受击/冲刺/起飞/冲撞有弹性反馈 —— 不新增任何逐帧贴图。

**Architecture:** 一个纯表现层的 `SquashStretch` 组件（`scenes/effects/squash_stretch.gd`），挂到玩家、三只敌鸟、对手副本上。计算模型是**两个标量相加**：`_air`（每帧由 `vel_y` 重算，无状态）+ `_impulse`（事件累加 + 指数回归，有状态）。最终 `animator.scale = (1 - amount·v, 1 + amount·v)`，`v` 被钳在 `[-1,1]`，所以幅度**永远不超过 ±10%**。

**Tech Stack:** Godot 4.7.1 标准版（GDScript）。无测试框架 —— 用 `extends SceneTree` 的 `-s` 冒烟脚本 + 真渲染场景探针。

**Spec:** `docs/superpowers/specs/2026-09-20-squash-stretch-design.md`（本节所有"见 spec §N"都指它）

## Global Constraints

- **只写 `animator.scale`**。不写 `self.scale`（玩家根 `scale = 2.5` 是世界缩放，写了整个角色会缩），不写 `flip_h`（朝向归 `_set_facing` / `_tick_pose_and_collision`）。
- **不进 `Player.capture_state()` / `restore_state()`**。squash 状态住在组件里、不在 `Player` 上 —— 实现时**不要**顺手把它加进捕获字典。
- **不碰任何碰撞体**。`Pose → CollisionPolygon2D` 那套（`POSE_NODE` 表 + `_coll_by_pose`）完全不动。
- ★ **本文件一律用符号指代，不写行号**（2026-09-20 订正）—— 这条约束原先自己就违反约定：Global Constraints 与本文件各处引用的 `:449`/`:499`/`:348-349` 等一整套行号在本轮落地后**全部**漂了（`capture_state` 从 `:449` 漂到 `:490`、`restore_state` 从 `:499` 漂到 `:540`）。密集改动区里行号是负资产（spec §2.4 末、`CLAUDE.md` 的 squash 节），而这份计划是**生成 brief 的源头** —— 漂一行就会让重跑者改错函数。
- **组件不引 autoload**。只静态引用 `PlayerParams` / `EnemyParams` / `MathUtil`（三者都是 `RefCounted`，非 autoload），保住 `-s` 可测。
- **组件不写自己的 `_physics_process`**。由宿主每帧显式调 `tick()`（沿用 `ClimbComponent`/`CombatComponent` 约定）。
- **幅度上限 ±10%**（用户裁定"不要太夸张"）。任何新常量不得把 `squash_amount` 抬高。
- **测试由用户自己跑**（`CLAUDE.md` 硬约定）。每条"运行"步骤都给了确切命令 —— 执行 agent 应把命令交给用户跑；经用户明确同意后可代跑。
- **Godot 不在 PATH**。所有命令用环境变量 `$GODOT`（console 版），未设时回落本机默认路径；命令里的 `"$GODOT"` 与 `tests/env.sh` 同源。
- **新建 `class_name` 文件后必须 `--import` 刷全局类缓存**，否则引用处 Parse Error。

---

## File Structure

| 文件 | 动作 | 职责 |
|---|---|---|
| `core/config/player_params.gd` | Modify | 玩家侧 squash 参数常量 |
| `core/config/enemy_params.gd` | Modify | `shared` 里加敌人侧 squash 参数常量 |
| `scenes/effects/squash_stretch.gd` | **Create** | 组件本体。唯一计算实现 |
| `scenes/player/player.gd` | Modify | 玩家接入（tick / 起跳 / 冲刺 / 受击） |
| `scenes/enemies/enemy_base.gd` | Modify | 敌人基类接入（tick / 虚钩 / 受击） |
| `scenes/enemies/enemy_fly_bird.gd` | Modify | 覆写虚钩：TAKE_OFF / CHARGE |
| `scenes/enemies/enemy_black_bird.gd` | Modify | 覆写虚钩：TAKE_OFF / CHARGE |
| `scenes/enemies/enemy_jump_bird.gd` | Modify | 覆写虚钩：LUNGE_DASH / BACK_HOP |
| `scenes/player/player_replica.gd` | Modify | 对手副本接入（读 `vel` + `_process` 里 tick） |
| `tests/squash_stretch_smoke.gd` | **Create** | `-s` 纯逻辑冒烟 |
| `tests/squash_host_water_probe.gd` / `.tscn` | **Create** | 玩家侧宿主守卫（水中站底 / 梯底按住 S / 干地反例 / **倒地两件事**），Task 2 Step 8b |
| `tests/squash_host_enemy_probe.gd` / `.tscn` | **Create** | **敌鸟侧**宿主守卫（状态映射 / SLEEP 不挂钩 / `_apply_hit` / 睡眠缓存归零与醒来首帧） |
| `tests/squash_replica_probe.gd` / `.tscn` | **Create** | 副本行为守卫（**相⓪ 生产端字段表对账** + 水中下沉中性 / 干地落地仍挤压 / 落地判据两半 / 倒地中性），Task 5 Step 2b |
| `tests/squash_stretch_probe.gd` / `.tscn` | **Create** | 真渲染探针 |
| `CLAUDE.md` | Modify | 记录新组件与约定 |

---

## Task 1: 参数常量 + 组件本体 + 纯逻辑冒烟

先立参数与组件，再让冒烟变绿。参数放本任务是因为 `setup()` 要读它们 —— 拆到后面会让本任务无法测。

**Files:**
- Modify: `core/config/player_params.gd`
- Modify: `core/config/enemy_params.gd`
- Create: `scenes/effects/squash_stretch.gd`
- Test: `tests/squash_stretch_smoke.gd`

**Interfaces:**
- Consumes: 无（第一个任务）
- Produces:
  - `class_name SquashStretch extends Node`
  - `enum SquashStretch.Profile { PLAYER, ENEMY }`
  - `enum SquashStretch.Impulse { JUMP, HURT, DASH, TAKE_OFF, CHARGE }`
  - `func setup(animator: AnimatedSprite2D, profile: int) -> void`
  - `func impulse(kind: int) -> void`
  - `func tick(delta: float, vel_y: float, on_floor: bool, suppressed: bool) -> void`
  - `PlayerParams.squash_amount / squash_recover / squash_jump / squash_land_min_vy / squash_land_ref_vy / squash_land / squash_hurt / squash_dash / squash_air / squash_air_ref_vy`（全 `const float`）
  - `EnemyParams.shared.squash_amount / squash_recover / squash_take_off / squash_charge / squash_land_min_vy / squash_land_ref_vy / squash_land / squash_hurt / squash_air / squash_air_ref_vy`（全 `const float`）

- [ ] **Step 1: 加玩家参数常量**

在 `core/config/player_params.gd` 末尾追加（该文件是 `class_name PlayerParams extends RefCounted`，全部是 `const`）：

```gdscript
# ── 补间形变(squash & stretch,见 scenes/effects/squash_stretch.gd) ──
# 上限 0.10 = 满冲击时最少 0.90 / 最多 1.10 —— 用户裁定"不要太夸张"。
# 任何一项都是**在 [-1,1] 的合成量上相乘**,叠加多少事件都不会超过这个上限。
const squash_amount: float = 0.10          # 满冲击形变量
const squash_recover: float = 9.0          # 冲击回归速率(指数,越大回正越快)
const squash_jump: float = 0.75            # 起跳拉伸
const squash_land_min_vy: float = 220.0    # 落速低于此不挤压(下小台阶不触发)
const squash_land_ref_vy: float = 900.0    # 达到此落速 = 满挤压
const squash_land: float = 1.00            # 落地挤压上限
const squash_hurt: float = 0.50            # 受击挤压
const squash_dash: float = 0.80            # 冲刺拉伸
const squash_air: float = 0.30             # 空中连续项上限
const squash_air_ref_vy: float = 700.0     # 空中连续项参考速度
```

- [ ] **Step 2: 加敌人参数常量**

在 `core/config/enemy_params.gd` 的 `class shared:` 块内追加（`shared` 已有 `hit_flash` / `turn_min_interval` / `bird_*` 等常量，追加在它们之后即可）：

```gdscript
	# ── 补间形变(squash & stretch) ── 与 PlayerParams 同名同值,但刻意不共享常量:
	# 两个参数类互不依赖(spec §3)。改一侧要问自己另一侧是否也该改。
	const squash_amount: float = 0.10
	const squash_recover: float = 9.0
	const squash_take_off: float = 0.80        # 鸟起飞(FlyBird / BlackBird TAKE_OFF)
	const squash_charge: float = 0.90          # 冲撞(FlyBird/BlackBird CHARGE、JumpBird LUNGE_DASH/BACK_HOP)
	const squash_land_min_vy: float = 220.0
	const squash_land_ref_vy: float = 900.0
	const squash_land: float = 1.00
	const squash_hurt: float = 0.50
	const squash_air: float = 0.30
	const squash_air_ref_vy: float = 700.0
```

> ⚠️ `class shared:` 块内的常量是**缩进一层 Tab** 的。别顶格写，否则会变成文件级常量、`EnemyParams.shared.squash_amount` 解析失败。

- [ ] **Step 3: 创建组件文件（骨架即可，tick 体留中性）**

创建 `scenes/effects/squash_stretch.gd`。**本步故意只写骨架** —— `tick()` 体先返回中性，让下一阶段的冒烟能真变红：

```gdscript
class_name SquashStretch
extends Node
# 补间形变(squash & stretch):按物理状态对 AnimatedSprite2D 做程序化缩放。
# 挂到任意"有 AnimatedSprite2D 的角色"上(玩家 / 三只敌鸟 / 对手副本),纯表现层。
#
# ★ 只写 animator.scale。不写 self.scale(玩家根 scale=2.5 是世界缩放,写了整个角色会缩),
#   不写 flip_h(朝向归 _set_facing / _tick_pose_and_collision)。
# ★ 不进 capture_state()/restore_state()、不碰任何碰撞体(见 spec §5/§6)。
# ★ 不写自己的 _physics_process —— 由宿主每帧显式调 tick(),与 ClimbComponent/CombatComponent 同款。
# ★ 参数走静态 const(PlayerParams / EnemyParams 都是 RefCounted,非 autoload),保住 `-s` 可测。

enum Profile { PLAYER, ENEMY }

# 外部事件。落地的挤压**不在这里** —— 它由 tick() 从 vel_y 无状态推导(见 tick 注释)。
enum Impulse { JUMP, HURT, DASH, TAKE_OFF, CHARGE }

var _animator: AnimatedSprite2D = null
var _gain: Dictionary = {}          # Impulse -> 带符号增益(正=拉伸/负=挤压)

# 计算模型 = 两个标量相加,不是状态机:
#   _air     每帧由 vel_y 重算 —— **无状态**,回滚重放结果一致
#   _impulse 事件累加 + 指数回归 —— 有状态(回滚重放会重播一次,见 spec §5.4 的已知边界)
# 用单标量(而不是分开记拉伸/挤压)是刻意的:"冲刺中落地""起跳瞬间被击中"这类同时事件
# 天然叠加,不需要优先级状态机 —— 这正是选纯代码方案(而非 AnimationPlayer)的核心收益。
var _air: float = 0.0
var _impulse: float = 0.0

var _amount: float = 0.10
var _recover: float = 9.0
var _land_min_vy: float = 220.0
var _land_ref_vy: float = 900.0
var _land_gain: float = 1.0
var _air_gain: float = 0.30
var _air_ref_vy: float = 700.0


func setup(animator: AnimatedSprite2D, profile: int) -> void:
	_animator = animator
	if profile == Profile.ENEMY:
		_amount = EnemyParams.shared.squash_amount
		_recover = EnemyParams.shared.squash_recover
		_land_min_vy = EnemyParams.shared.squash_land_min_vy
		_land_ref_vy = EnemyParams.shared.squash_land_ref_vy
		_land_gain = EnemyParams.shared.squash_land
		_air_gain = EnemyParams.shared.squash_air
		_air_ref_vy = EnemyParams.shared.squash_air_ref_vy
		_gain = {
			Impulse.HURT: -EnemyParams.shared.squash_hurt,
			Impulse.TAKE_OFF: EnemyParams.shared.squash_take_off,
			Impulse.CHARGE: EnemyParams.shared.squash_charge,
		}
	else:
		_amount = PlayerParams.squash_amount
		_recover = PlayerParams.squash_recover
		_land_min_vy = PlayerParams.squash_land_min_vy
		_land_ref_vy = PlayerParams.squash_land_ref_vy
		_land_gain = PlayerParams.squash_land
		_air_gain = PlayerParams.squash_air
		_air_ref_vy = PlayerParams.squash_air_ref_vy
		_gain = {
			Impulse.JUMP: PlayerParams.squash_jump,
			Impulse.DASH: PlayerParams.squash_dash,
			Impulse.HURT: -PlayerParams.squash_hurt,
		}
	_apply()


func impulse(kind: int) -> void:
	_impulse = clampf(_impulse + float(_gain.get(kind, 0.0)), -1.0, 1.0)


# 宿主每帧调一次。vel_y / on_floor 必须来自**同一次** move_and_slide:
# 帧首的 is_on_floor() 是上一帧 move_and_slide 的结果,所以 vel_y 要传那次 move_and_slide
# **之前**缓存的 velocity.y。二者配对才能无状态推导落地 —— 见 spec §2.4。
func tick(delta: float, vel_y: float, on_floor: bool, suppressed: bool) -> void:
	# TODO(骨架): 本步先返回中性,下一步实现
	_apply()


func _apply() -> void:
	if _animator == null:
		return
	var v := clampf(_air + _impulse, -1.0, 1.0)
	# ★ 符号:正 v = 拉伸(窄高:scale.x < 1, scale.y > 1),负 v = 挤压(宽矮)。
	#   x 与 y 反向变化。增益表跟着这条走:jump/dash/take_off/charge 为正(拉伸),
	#   land(减法)与 hurt(取负)为负(挤压)。
	#   别"顺手"翻成 `1.0 + _amount * v` 配 `1.0 - ...` —— 那会让每个事件都反过来。
	_animator.scale = Vector2(1.0 - _amount * v, 1.0 + _amount * v)
```

- [ ] **Step 4: 刷全局类缓存**

新建 `class_name` 文件后**必须**刷缓存，否则下一步的测试会 Parse Error（"Could not find type SquashStretch"）。

```bash
"$GODOT" --headless --path . --import
```

Expected: 退出码 0。若报 `Could not resolve class SquashStretch`，先确认文件确实带 `class_name SquashStretch` 且 `extends Node`。

- [ ] **Step 5: 写冒烟测试**

创建 `tests/squash_stretch_smoke.gd`：

```gdscript
extends SceneTree
# SquashStretch 纯逻辑冒烟(不建场景、不渲染)。
# 判据:SQUASH SMOKE: ALL-OK
# 跑法:"$GODOT" --headless --path . -s res://tests/squash_stretch_smoke.gd
#
# ★ 组件只静态引用 PlayerParams / EnemyParams / MathUtil(三者都是 RefCounted、非 autoload),
#   故 `-s` 阶段(autoload 尚未实例化)可以安全静态引用本类。

const DT: float = 1.0 / 60.0

var _fail: int = 0


func _ok(cond: bool, msg: String) -> void:
	if cond:
		print("  ok   ", msg)
	else:
		_fail += 1
		print("  FAIL ", msg)


func _near(a: float, b: float, eps: float) -> bool:
	return absf(a - b) <= eps


func _mk() -> Array:
	# 返回 [组件, 精灵]。精灵不入树 —— scale 是 Node2D 属性,不入树也能读写。
	var spr := AnimatedSprite2D.new()
	var s := SquashStretch.new()
	s.setup(spr, SquashStretch.Profile.PLAYER)
	return [s, spr]


func _initialize() -> void:
	print("== SquashStretch 纯逻辑冒烟 ==")

	# ① 静止:(vel_y=0, on_floor) 多帧后必须是单位缩放
	var a: Array = _mk()
	for i in 30:
		(a[0] as SquashStretch).tick(DT, 0.0, true, false)
	_ok(_near((a[1] as AnimatedSprite2D).scale.x, 1.0, 0.001)
			and _near((a[1] as AnimatedSprite2D).scale.y, 1.0, 0.001),
			"静止 → scale == (1,1),实测 %s" % str((a[1] as AnimatedSprite2D).scale))

	# ② 落地冲击 → 挤压(宽矮:x>1, y<1)
	var b: Array = _mk()
	(b[0] as SquashStretch).tick(DT, 1200.0, true, false)
	var bs: Vector2 = (b[1] as AnimatedSprite2D).scale
	_ok(bs.x > 1.0 and bs.y < 1.0, "落地冲击 → 挤压方向(宽矮),实测 %s" % str(bs))
	# 且不得越过 amount 上限
	_ok(absf(bs.x - 1.0) <= PlayerParams.squash_amount + 0.0001,
			"落地挤压不越上限(%.3f)" % PlayerParams.squash_amount)

	# ③ 低落速不触发:100 < squash_land_min_vy(220)
	var c: Array = _mk()
	(c[0] as SquashStretch).tick(DT, 100.0, true, false)
	_ok(_near((c[1] as AnimatedSprite2D).scale.x, 1.0, 0.0005),
			"落速 100(< 下限 220)不触发挤压,实测 %s" % str((c[1] as AnimatedSprite2D).scale))

	# ④ 起跳冲击 → 拉伸(窄高:x<1, y>1)
	var d: Array = _mk()
	(d[0] as SquashStretch).impulse(SquashStretch.Impulse.JUMP)
	(d[0] as SquashStretch).tick(DT, 0.0, true, false)
	var ds: Vector2 = (d[1] as AnimatedSprite2D).scale
	_ok(ds.x < 1.0 and ds.y > 1.0, "起跳冲击 → 拉伸方向(窄高),实测 %s" % str(ds))

	# ⑤ 空中连续项:在空中且 |vel_y| 大 → 拉伸(窄高:x<1)
	var e: Array = _mk()
	(e[0] as SquashStretch).tick(DT, -700.0, false, false)
	_ok((e[1] as AnimatedSprite2D).scale.x < 1.0,
			"空中(vel_y=-700)→ 拉伸(窄高),实测 %s" % str((e[1] as AnimatedSprite2D).scale))

	# ⑥ 指数回归:30 帧后 < 0.01,60 帧后 < 0.001
	#    按 squash_recover=9.0 + squash_amount=0.10 推:exp(-4.5)*0.10≈0.0011、exp(-9)*0.10≈1.2e-5
	var f: Array = _mk()
	(f[0] as SquashStretch).tick(DT, 1200.0, true, false)   # 先制造一个大冲击
	for i in 30:
		(f[0] as SquashStretch).tick(DT, 0.0, true, false)
	_ok(absf((f[1] as AnimatedSprite2D).scale.x - 1.0) < 0.01,
			"30 帧后回归到 <0.01,实测 %.5f" % absf((f[1] as AnimatedSprite2D).scale.x - 1.0))
	for i in 30:
		(f[0] as SquashStretch).tick(DT, 0.0, true, false)
	_ok(absf((f[1] as AnimatedSprite2D).scale.x - 1.0) < 0.001,
			"60 帧后回归到 <0.001,实测 %.6f" % absf((f[1] as AnimatedSprite2D).scale.x - 1.0))

	# ⑦ 多事件叠加不爆:同时起跳 + 冲刺 + 落地大冲击,仍不得越过 amount 上限
	var g: Array = _mk()
	(g[0] as SquashStretch).impulse(SquashStretch.Impulse.JUMP)
	(g[0] as SquashStretch).impulse(SquashStretch.Impulse.DASH)
	(g[0] as SquashStretch).tick(DT, 2000.0, true, false)
	var gs: Vector2 = (g[1] as AnimatedSprite2D).scale
	_ok(absf(gs.x - 1.0) <= PlayerParams.squash_amount + 0.0001
			and absf(gs.y - 1.0) <= PlayerParams.squash_amount + 0.0001,
			"多事件叠加不越上限,实测 %s" % str(gs))

	# ⑧ suppressed → 立刻中性(倒地)
	var h: Array = _mk()
	(h[0] as SquashStretch).tick(DT, 1200.0, true, false)   # 先挤压
	(h[0] as SquashStretch).tick(DT, 1200.0, true, true)    # 再抑制
	_ok(_near((h[1] as AnimatedSprite2D).scale.x, 1.0, 0.0005)
			and _near((h[1] as AnimatedSprite2D).scale.y, 1.0, 0.0005),
			"suppressed → 立刻回中性,实测 %s" % str((h[1] as AnimatedSprite2D).scale))

	# ⑨ 敌人 profile 不得认玩家的 Impulse(增益表里没有 → no-op)
	var espr := AnimatedSprite2D.new()
	var es := SquashStretch.new()
	es.setup(espr, SquashStretch.Profile.ENEMY)
	es.impulse(SquashStretch.Impulse.JUMP)     # 敌人侧没有 JUMP
	es.tick(DT, 0.0, true, false)
	_ok(_near(espr.scale.x, 1.0, 0.0005),
			"敌人 profile 对 JUMP 无响应,实测 %s" % str(espr.scale))
	es.impulse(SquashStretch.Impulse.TAKE_OFF)  # 敌人侧有 TAKE_OFF
	es.tick(DT, 0.0, true, false)
	_ok(espr.scale.x < 1.0, "敌人 profile 响应 TAKE_OFF(拉伸,窄高),实测 %s" % str(espr.scale))

	if _fail == 0:
		print("SQUASH SMOKE: ALL-OK")
	else:
		print("SQUASH SMOKE: FAIL | %d 条" % _fail)
	quit(1 if _fail > 0 else 0)
```

- [ ] **Step 6: 运行冒烟，确认变红**

把命令交给用户跑（Global Constraints：测试由用户跑）：

```bash
"$GODOT" --headless --path . -s res://tests/squash_stretch_smoke.gd
```

Expected: **FAIL** —— 因为 `tick()` 还是骨架、`_air`/`_impulse` 永不被写，①③ 会过，但 ②④⑤⑦⑧⑨ 全红。
若一条都不红，说明骨架已经把逻辑写进去了 —— 回 Step 3 把 `tick()` 体清成中性。

- [ ] **Step 7: 实现 `tick()`**

把 `scenes/effects/squash_stretch.gd` 里的 `tick()` 整体替换为：

```gdscript
func tick(delta: float, vel_y: float, on_floor: bool, suppressed: bool) -> void:
	if suppressed:
		# 倒地:强制中性。副本侧尤其必须 —— 它给根节点设了 rotation,而本节点是其子节点,
		# 写 scale 会沿转过的轴挤压(见 spec §5.2)。
		_air = 0.0
		_impulse = 0.0
		_apply()
		return

	# 空中连续项:**重新算**而不是累加(无状态,回滚重放结果一致)
	_air = 0.0
	if not on_floor:
		_air = clampf(absf(vel_y) / maxf(_air_ref_vy, 1.0), 0.0, 1.0) * _air_gain

	# 落地冲击。★ 判据是 `vel_y > _land_min_vy`(阈值是常量,不是字面量 —— 2026-09-20 订正:
	# 这里曾写作 `> 200`,而两侧参数都是 `squash_land_min_vy = 220.0`,差 20 px/s)。
	# ★★ "地面上 vel_y 恒为 0 ⇒ 本条只在落地那一帧成立"这个前提**只对重力路径成立** ——
	#   水中下沉(320)与梯子下行(720)都是"站在地面/水里仍然写正 velocity.y",宿主必须自己
	#   把"不是摔下来的"下坠速度滤掉(见 Task 2 Step 4 与 spec §2.4),本条才有那个性质。
	if on_floor and vel_y > _land_min_vy:
		var k := clampf((vel_y - _land_min_vy) / maxf(_land_ref_vy - _land_min_vy, 1.0), 0.0, 1.0)
		_impulse -= _land_gain * k
		# ★ 减法之后必须**自己**再钳一次 —— `impulse()` 里那个 clampf 管不到这里:
		#   宿主违约时本条每帧重复减同一个满幅值,而指数恢复每帧只回 ~14% ⇒ `_impulse`
		#   收敛到定点 `-k·d/(1-d)`(而不是停在 -1),之后任意一次 `impulse()` 的**正**增益
		#   都加在更负的基数上 ⇒ 起跳/冲刺的拉伸被压低、显形推后。钳在写入口,与 `impulse()` 同款。
		_impulse = clampf(_impulse, -1.0, 1.0)

	_impulse = MathUtil.approach(_impulse, 0.0, _recover, delta)
	_apply()
```

> ★ 上面那条 `clampf` 是 **2026-09-20 终审修复**加的（见 spec §3 末那条补记）：初稿只有
> `impulse()` 里那一个钳位，减法这一侧是裸的。**别"顺手"删掉** —— 冒烟 ⑦c/⑦d 会红。

- [ ] **Step 8: 运行冒烟，确认变绿**

```bash
"$GODOT" --headless --path . -s res://tests/squash_stretch_smoke.gd
```

Expected: 全部 `ok`（含 ⓪ 的参数镜像组与 ⑦c/⑦d 的下行饱和组），末行 `SQUASH SMOKE: ALL-OK`，退出码 0。

- [ ] **Step 9: 提交**

```bash
git add core/config/player_params.gd core/config/enemy_params.gd scenes/effects/squash_stretch.gd tests/squash_stretch_smoke.gd
git commit -F - <<'EOF'
feat(squash): SquashStretch 组件 + 参数常量 + 纯逻辑冒烟

两个标量相加的模型:_air 每帧重算(无状态,回滚安全) + _impulse 事件累加
指数回归(有状态,重放会重播一次,见 spec §5.4)。单标量让"冲刺中落地"这类
同时事件天然叠加,不需要优先级状态机。

落地挤压由 vel_y 无状态推导(判据 `vel_y > squash_land_min_vy`),不需要 _was_on_floor;
"只在落地那一帧成立"是**宿主过滤掉非坠落下坠速度之后**的结论,不是判据本身的性质。

冒烟:参数镜像(两侧 8 个同名常量同值 + 幅度 == 用户裁定的 0.10)/静止/落地挤压/
低落速不触发/起跳拉伸/空中连续项/指数回归/多事件叠加不越上限(上下行各一组)/
强制中性/敌人 profile 不认玩家的 Impulse。
EOF
```

---

## Task 2: 玩家接入

**Files:**
- Modify: `scenes/player/player.gd`（字段声明区、`_ready()`、`_physics_process()` 首行与 `move_and_slide()` 之前、`_tick_vertical()` 的起跳段、`_tick_crouch_and_dash()` 的冲刺段、根部 `take_hit()`）
  - ★ **一律符号指代，不写行号**（2026-09-20 订正）：本文件所在的密集改动区里行号是负资产（spec §2.4 末有这条约定，`CLAUDE.md` 的 squash 节也照办）。原文写的是 `:44`/`:156`/`:159`/`:249`/`:276-278`/`:412`/`:219` 一串 —— 在 Task 2 自己落地之后就**全部**漂了（`_physics_process` 从 `:159` 漂到 `:171`、`move_and_slide` 从 `:219` 漂到 `:259`），照它做会改到隔壁函数里。

**Interfaces:**
- Consumes: `SquashStretch.setup/impulse/tick`、`SquashStretch.Profile.PLAYER`、`SquashStretch.Impulse.JUMP/DASH/HURT`（Task 1）
- Produces: `player.gd` 上的 `var squash: SquashStretch` 与 `var _pre_move_vy: float`（Task 5 的探针会读 `squash`）

- [ ] **Step 1: 加字段**

在 `scenes/player/player.gd` 的字段声明区，`@onready var swim: SwimComponent = $Swim` 那一行之后追加：

```gdscript
# 补间形变(squash & stretch)。运行期创建,不是场景子节点 —— 与 _reload_ring 同款。
# ★ 纯表现层:不进 capture_state()/restore_state(),不碰碰撞箱。
var squash: SquashStretch = null
# move_and_slide() **之前**的 velocity.y。与帧首的 is_on_floor() 配对,供 squash 无状态推导落地。
# ★ 不得进 capture_state(),不得被任何模拟逻辑读取 —— 只喂 squash(见 spec §5.1)。
var _pre_move_vy: float = 0.0
```

- [ ] **Step 2: 在 `_ready` 里创建组件**

在 `scenes/player/player.gd` 的 `_ready()` 里，`call_deferred("add_child", WaterFx.new())` 之后追加：

```gdscript
	# 补间形变:挂在**自己**身上(与 _reload_ring 同款的一个接入点覆盖单机/PvP/大乱斗)。
	# animator 是 @export 引用,场景实例化时就已就位,`_ready` 里可用。
	squash = SquashStretch.new()
	# ★ 顺序与另**两个**宿主统一:`add_child()` 之后才 `setup()`(三只敌鸟 / 对手副本都是这个序)。
	#   两种序今天**等价**(`SquashStretch` 没有 `_ready`),但本仓对"配置与入树谁先"另有一条
	#   **相反**的规矩(`WeaponPickup.configure()` 必须**先于** `add_child()`),同仓两种序并存
	#   会让将来加 `_ready` 的人无从判断 —— 届时三处一起倒过来。
	add_child(squash)
	squash.setup(animator, SquashStretch.Profile.PLAYER)
```

- [ ] **Step 3: 帧首 tick**

把 `scenes/player/player.gd` 的 `_physics_process()` **首行**（`if combat.is_downed():` 那次倒地早退之前）改成：

```gdscript
func _physics_process(delta: float) -> void:
	# squash 放在**最首行**(倒地早退之前):否则倒地后 animator.scale 会卡在最后一个
	# 挤压值上(明显的视觉 bug)。参数成对读 —— is_on_floor() 是上一帧 move_and_slide 的
	# 结果,_pre_move_vy 是那次 move_and_slide 之前缓存的 velocity.y(见 spec §2.4)。
	squash.tick(delta, _pre_move_vy, is_on_floor(), combat.is_downed())
	if combat.is_downed():
		_tick_downed(delta)
		return
```

- [ ] **Step 4: 缓存 pre-move velocity**

把 `scenes/player/player.gd` 的 `_physics_process()` 里 `move_and_slide()` 之前那两行（`---------- 执行移动 ----------` 那个小标题下方）改成：

```gdscript
	# ---------- 执行移动 ----------
	# ★ 必须在 move_and_slide() **之前**:落地那一帧它在调用后就被清零了。
	# ★ 且必须**滤掉不是摔下来的下坠速度**(squash 的调用契约 = "地面真正吸收掉的坠落速度"):
	#   它一并覆盖的两条路径**性质不同**,别当成同一个病(spec 初稿说"两条同形",实测后不成立;
	#   见 tests/squash_host_water_probe):
	#   · 梯子下行(720)是**真违规**,且是**每帧**不是一帧 —— `_tick_crouch_and_dash` 攀附时首行
	#     整体早退 ⇒ is_squat 冻结、攀附永不解除,k≈0.735 被钳到满幅 10%(实测 scale = (1.1000, 0.9000))。
	#   · 水中那条**不重叠**:Water.feet_offset 取碰撞箱底边 ⇒ 站在水下实心地面上时脚底探针
	#     恒落在**支撑格自己**里、而支撑格是 wall 不是 liquid ⇒ in_water 恒假(实测
	#     in_water∧on_floor 重叠 **0 帧**),"站池底永久 ~9% 挤压"并不存在。过滤它买到的是
	#     **下沉窗口**那 30 帧的连续项 `_air`(320/700 × 0.30 ≈ 0.137 → **拉伸**;按组件的
	#     `scale = (1−0.10v, 1+0.10v)` 读出来是 **scale = (0.9863, 1.0137)** —— 拉伸那一侧是
	#     **y**(1.0137),x 是 0.9863;过滤后 1.0000)⇒ 这一条是**落实设计取舍**("游泳不该有自由落体那种弹感"),不是修 bug。
	_pre_move_vy = 0.0 if (in_water or latched) else velocity.y
	move_and_slide()
```

> `in_water`(由 `swim.update` 返回)与 `latched`(由 `climb.is_latched()` 取得)在本行之前都已就位。
> **本节刻意不写行号** —— 密集改动区里行号是负资产(项目既有约定),一律用符号指代。

并且把 `_physics_process` 的倒地早退分支改成**同时**把该值归零（否则倒地期间它变陈旧 —— `_tick_downed` 不更新它 —— 复活首帧会与地面态配对出一个满幅假挤压）：

```gdscript
	if combat.is_downed():
		_pre_move_vy = 0.0
		_tick_downed(delta)
		return
```

- [ ] **Step 5: 起跳钩子**

在 `scenes/player/player.gd` 的 `_tick_vertical()` 里，起跳段末尾那句 `jump_cut_applied = false` 之后追加：

```gdscript
		squash.impulse(SquashStretch.Impulse.JUMP)
```

> ⚠️ 缩进必须与 `jump_cut_applied = false` 同级（它在 `if jump_buffer_timer > 0.0 ...:` 块内）。

- [ ] **Step 6: 冲刺钩子**

在 `scenes/player/player.gd` 的 `_tick_crouch_and_dash()` 里，冲刺段那句 `charge_timer = charge_duration` 之后追加：

```gdscript
		squash.impulse(SquashStretch.Impulse.DASH)
```

- [ ] **Step 7: 受击钩子**

把 `scenes/player/player.gd` 根部的 `take_hit()` 整个换成：

```gdscript
func take_hit(source_pos: Vector2, damage: int, ignore_iframes: bool = false, knockback: float = -1.0) -> void:
	# 前后比对 hp:只有**真吃到伤害**才挤压。无敌帧挡下 / 已倒地时 combat.take_hit 不改 hp,
	# 这条判据天然把它们排除 —— 比在 combat 里回调更省事(不动组件接口)。
	var before := combat.hp
	combat.take_hit(source_pos, damage, ignore_iframes, knockback)
	if combat.hp < before:
		squash.impulse(SquashStretch.Impulse.HURT)
```

- [ ] **Step 8: 编译检查**

```bash
"$GODOT" --headless --path . --quit-after 90
```

Expected: 无 `SCRIPT ERROR` / `Parse Error`。游戏跑 90 帧后退出。若报 `Identifier "squash" not declared`，回 Step 1 确认字段加在了 `player.gd` 里（不是别的文件）。

> ⚠️ 这条**只是解析检查** —— 主场景是 `main_menu`，90 帧内不跑任何玩法代码。它通过只说明"没有脚本错误"。

- [ ] **Step 8b: 宿主级行为守卫（`tests/squash_host_water_probe`）**

**为什么必须有**：Step 4 那个谓词（`0.0 if (in_water or latched) else velocity.y`）是本任务唯一"改了没人会发现"的地方 ——
`tests/squash_stretch_smoke.gd` 自建裸 `AnimatedSprite2D`、**从不加载 `player.gd`**；`enemy_logic_smoke` 的玩家实例站在**干**地上；
而 `tests/pvp_twin_smoke.gd` 虽然真驱动水中物理，但它比对的是孪生态，squash/`_pre_move_vy` **刻意在 `capture_state()` 之外**，结构上看不见。
把 Step 4 改回裸 `velocity.y`，上述三条全部照绿。

**做法**：新建 `tests/squash_host_water_probe.gd` + `.tscn`，`extends Node`、**scene 模式 headless**（autoload 在）。
脚手架照 `tests/pvp_twin_smoke.gd` 自己的建图/驱动那一段的先例 —— 它已经造好了「合成网格 + 一个水池 + 一条梯 + 真 `player.tscn` + 真物理步进」这一整套，照抄那份的最小版本即可
（该文件的 `COLS/ROWS/WATER_X0/WATER_X1/LADDER_X` 常量就是现成的形状）。

四相：

1. **水中站底** —— 玩家落到水池**实心底**上，按住 S（下）步进 ~60 物理帧，断言 `player.animator.scale ≈ Vector2.ONE`
   （不按 `_pre_move_vy == 0.0`，那是内部量；按**可观测的渲染结果**断，且它同时验证了 `suppressed`/钳位链没被绕开）。
2. **梯底按住 S** —— 同款，断言 `scale ≈ Vector2.ONE`（这条幅度更大：`k≈0.735`，坏了会读到接近 `(1.1, 0.9)`）。
3. **反例（必须有）** —— 在**干**地面上从高处落下，断言**真的挤压**了（挤压 = 宽矮 ⇒ `scale.x > 1.0`）。没有它，前两相可以靠"永不挤压"作弊通过。
4. **正向对照** —— 干地面上静止，断言 `scale == Vector2.ONE`。

**变异验证（必做，写进报告）**：把 Step 4 改回 `_pre_move_vy = velocity.y`，跑本探针 → 相 ①、② 必须变红。
**实测读数**（2026-09-20，容差已收到 `WET_EPS = 1e-3`）：
- 相 ① —— `in_water 帧上 max dev 0.0137`（该帧 `scale = (0.9863, 1.0137)`；末值仍是 `(0.9997, 1.0003)`，
  因为触底后指数恢复已经把它拉回来了 —— 故断言按 **in_water 帧**取极值，不按整个窗口）。
- 相 ② —— `max dev 0.1000`，末值 `scale = (1.1000, 0.9000)`。
恢复 → 全绿。**若变不红，本守卫无效，继续迭代。**

判据文本：`SQUASH HOST PROBE: ALL-OK`（读文本，不看退出码 —— `--quit-after` 挂住时也可能退 0）。
`--quit-after` 给足 **3600 帧**（安全网，只在挂住时才用得上）。

```bash
"$GODOT" --headless --path . --quit-after 3600 res://tests/squash_host_water_probe.tscn
```

- [ ] **Step 9: 提交**

```bash
git add scenes/player/player.gd
git commit -F - <<'EOF'
feat(squash): 玩家接入起跳/落地/受击/冲刺形变

tick 放 _physics_process 最首行(倒地早退之前),否则倒地后 scale 会卡在
最后一个挤压值上。落地靠 _pre_move_vy + 帧首 is_on_floor() 配对无状态推导。

_pre_move_vy 只喂 squash,不进 capture_state、不被任何模拟逻辑读取。
EOF
```

---

## Task 3: 敌鸟接入

三只鸟共用 `EnemyBase`，差异只在"哪个状态算起飞/冲撞"，走虚钩分发。

**Files:**
- Modify: `scenes/enemies/enemy_base.gd`（字段声明区 `var _anim` 之后、`_ready()` 末尾、`_physics_process()` 首行与 `move_and_slide()` 之前、`_set_state()`、`_apply_hit()` 末尾）
  - ★ 符号指代（理由同 Task 2 的 Files 行）：原文那串 `:48`/`:64`/`:91`/`:286`/`:150`/`:135` 在 Task 3 自己落地后全部漂了（`_physics_process` `:91`→`:102`、`_set_state` `:286`→`:327`、`_apply_hit` `:150`→`:201`）。
- Modify: `scenes/enemies/enemy_fly_bird.gd`
- Modify: `scenes/enemies/enemy_black_bird.gd`
- Modify: `scenes/enemies/enemy_jump_bird.gd`

**Interfaces:**
- Consumes: `SquashStretch.*`（Task 1）
- Produces:
  - `enemy_base.gd` 上的 `var squash: SquashStretch`、`var _pre_move_vy: float`
  - 虚钩 `func _on_state_entered(s: int) -> void`（基类空实现，三个子类覆写）

- [ ] **Step 1: `EnemyBase` 加字段**

在 `scenes/enemies/enemy_base.gd` 的字段声明区，`var _anim: AnimatedSprite2D` 那一行之后追加：

```gdscript
# 补间形变(squash & stretch)。纯表现层,不进任何网络同步、不碰碰撞箱。
var squash: SquashStretch = null
# move_and_slide() **之前**的 velocity.y,与帧首 is_on_floor() 配对(见 spec §2.4)。
var _pre_move_vy: float = 0.0
```

- [ ] **Step 2: `EnemyBase._ready` 创建组件**

把 `scenes/enemies/enemy_base.gd` 的 `_ready()` 整个换成：

```gdscript
func _ready() -> void:
	add_to_group("enemies")
	_setup_contact_area()
	call_deferred("add_child", WaterFx.new())
	# 补间形变。★ 用 $AnimatedSprite2D 而不是 _anim:子类 `_ready` 是**先** super._ready()
	#   后才 `_anim = $AnimatedSprite2D`,此处 _anim 还是 null。三个敌人的 .tscn 里该节点都叫
	#   AnimatedSprite2D。
	squash = SquashStretch.new()
	add_child(squash)
	# ★ 查不到 animator 就**当场报错**,不让它静默降级:组件侧容忍 null animator(`_apply()`
	#   直接 return),于是查表失败的表现是"这只鸟永远不变形",一个字都不打。
	var anim := get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
	if anim == null:
		push_error("EnemyBase: 找不到 AnimatedSprite2D 节点,补间形变将静默失效(节点名 = %s)"
				% name)
	squash.setup(anim, SquashStretch.Profile.ENEMY)
```

- [ ] **Step 3: `EnemyBase._physics_process` 帧首 tick**

把 `scenes/enemies/enemy_base.gd` 的 `_physics_process()` **开头**（原 `if _is_far_sleeping()` 早退那一段）改成：

```gdscript
func _physics_process(delta: float) -> void:
	# squash 放在最首行(_is_far_sleeping 早退之前):睡眠时也走 tick,
	# 否则睡眠中的鸟会卡在最后一个形变值上。
	# ★★ 睡眠那一支**必须清零 `_pre_move_vy` 本身**,而不能只是"这一次调用喂 0":
	#   它不跑 move_and_slide ⇒ 缓存永不刷新 ⇒ 醒来首帧走的是醒着分支、拿到"上一次落地帧
	#   写进缓存的落速" ⇒ 同一个满幅落地项在**醒来那一刻**重触发,`_impulse` 压向 -1.0。
	#   后果:鸟按几秒前那次落地满幅挤压;更糟的是 TAKE_OFF 的 +0.80 加进已饱和的负值
	#   ⇒ **起飞拉伸被抵消甚至反向成压扁**。只把实参改 0 是**半个修法**,漏掉醒来首帧。
	# ★ 玩家侧倒地早退是同一契约的另一处落点,形态相同(那边也是 `_pre_move_vy = 0.0`)。
	#   两处的契约都不是"缓存里存的是什么",而是 **tick() 消费什么**。
	# ★ `sleeping` 必须只求值一次:让"喂进去的值"与"走哪条分支"必然同源,边缘帧上不会漂。
	var sleeping := _is_far_sleeping()
	squash.tick(delta, _pre_move_vy, is_on_floor(), is_dead)
	if sleeping:
		_pre_move_vy = 0.0
		_ai(delta)
		_wrap()
		return
```

> `EnemyBase.is_dead` 是敌人侧与玩家 `combat.is_downed()` 对应的"强制中性"信号 —— 尸体不该有弹性。

- [ ] **Step 4: `EnemyBase` 缓存 pre-move velocity**

把 `scenes/enemies/enemy_base.gd` 的 `_physics_process()` 末尾那段（`move_and_collide(knock_velocity …)` 起）改成：

```gdscript
	# 爆炸击退位移:单独 move_and_collide(带碰撞),不污染 velocity
	# (地面把向下击退吃掉后再减回去会把身体弹起);主移动 move_and_slide 最后跑,地面状态以它为准。
	move_and_collide(knock_velocity * delta)
	knock_velocity *= exp(-knock_decay_rate * delta)
	# ★ 必须在 move_and_slide() **之前**:落地那一帧它在调用后就被清零了。
	# ★ 敌人侧**不做任何过滤**,就是裸值 —— 这是实测后的裁定(spec §2.4):
	#   `_in_water ∧ is_on_floor()` 在敌人身上**确实会重叠**(239/1350 帧;玩家侧是 0,
	#   因为敌人的身体停在池底上方 0.02~0.18px,探针落进水格而玩家落在支撑格),
	#   但过滤想防的幽灵**结构上不可达**(浮力钳在 -260/+160,下沉侧 160 < 阈值 220),
	#   而过滤会**吃掉 13 次真实落水挤压**(有过滤 max scale.x=1.0000,去掉后 1.0861;
	#   挤压方向是 x>1 ⇒ 看的是**最大** scale.x)。
	#   ⇒ 净有害。敌人不爬梯,没有玩家侧那条真违规可类比。
	_pre_move_vy = velocity.y
	move_and_slide()
```

- [ ] **Step 5: `EnemyBase._set_state` 加虚钩**

把 `scenes/enemies/enemy_base.gd` 的 `_set_state()`（加号后面那几行是新增的虚钩）改成：

```gdscript
func _set_state(s: int) -> void:
	state = s
	_state_timer = 0.0
	_on_state_entered(s)


# 状态进入虚钩:基类默认空实现。三个子类各有自己的 `enum State`(JumpBird 根本没有
# TAKE_OFF),故基类**不能**硬编码状态名 —— 只能往下派发,由子类映射。
func _on_state_entered(_s: int) -> void:
	pass
```

- [ ] **Step 6: `EnemyBase._apply_hit` 受击钩子**

在 `scenes/enemies/enemy_base.gd` 的 `_apply_hit()` 函数体末尾（`_hit_flash_time = EnemyParams.shared.hit_flash` 之后）追加一行：

```gdscript
	squash.impulse(SquashStretch.Impulse.HURT)
```

> ⚠️ 必须加在 `_apply_hit`（真吃到伤害才走）里，**不是** `hurt`（`is_dead` 分支会走 `_apply_knock_only`）。加错地方 = 尸体被后续命中也会挤压。

- [ ] **Step 7: FlyBird 覆写虚钩**

在 `scenes/enemies/enemy_fly_bird.gd` 末尾追加：

```gdscript
# 状态进入 → 形变事件。enum State { SLEEP, TAKE_OFF, FLY, SHOOT, CHARGE, RETURN }
func _on_state_entered(s: int) -> void:
	match s:
		State.TAKE_OFF:
			squash.impulse(SquashStretch.Impulse.TAKE_OFF)
		State.CHARGE:
			squash.impulse(SquashStretch.Impulse.CHARGE)
```

- [ ] **Step 8: BlackBird 覆写虚钩**

在 `scenes/enemies/enemy_black_bird.gd` 末尾追加：

```gdscript
# 状态进入 → 形变事件。enum State { SLEEP, WAKE, WANDER, TAKE_OFF, CHARGE, BACK_HOP }
func _on_state_entered(s: int) -> void:
	match s:
		State.TAKE_OFF:
			squash.impulse(SquashStretch.Impulse.TAKE_OFF)
		State.CHARGE:
			squash.impulse(SquashStretch.Impulse.CHARGE)
```

- [ ] **Step 9: JumpBird 覆写虚钩**

在 `scenes/enemies/enemy_jump_bird.gd` 末尾追加：

```gdscript
# 状态进入 → 形变事件。enum State { SLEEP, WAKE, CHASE, LUNGE_WINDUP, LUNGE_DASH, BACK_HOP }
# ★ `_tick_chase` 里的小跳**刻意不挂钩** —— 它直接设 velocity、
#   不经过 _set_state,状态虚钩接不到;不为它另加钩子(用户 2026-09-20 裁定)。那一下的
#   hop_jump_velocity = -750 会让空中连续项直接给出拉伸,只是没有事件那一下"脆感"。
func _on_state_entered(s: int) -> void:
	match s:
		State.LUNGE_DASH:
			squash.impulse(SquashStretch.Impulse.CHARGE)
		State.BACK_HOP:
			squash.impulse(SquashStretch.Impulse.CHARGE)
```

- [ ] **Step 10: 编译检查 + 冒烟回归**

```bash
"$GODOT" --headless --path . --quit-after 90
"$GODOT" --headless --path . -s res://tests/enemy_logic_smoke.gd
```

Expected: 第一条无 `SCRIPT ERROR`；第二条仍打印 `SMOKE OK`（Task 3 不得弄坏既有敌人逻辑）。
若 `enemy_logic_smoke` 报错，**先查 `_set_state` 是否被改坏**（它只该多一行调用）。

- [ ] **Step 11: 提交**

```bash
git add scenes/enemies/enemy_base.gd scenes/enemies/enemy_fly_bird.gd scenes/enemies/enemy_black_bird.gd scenes/enemies/enemy_jump_bird.gd
git commit -F - <<'EOF'
feat(squash): 三只敌鸟接入起飞/落地/冲撞/受击形变

状态事件走 _on_state_entered 虚钩:三只鸟各有自己的 enum State(JumpBird
根本没有 TAKE_OFF),基类不能硬编码状态名,只能往下派发。

用 $AnimatedSprite2D 而非 _anim:子类 _ready 是先 super._ready() 后才赋值 _anim,
基类 _ready 里 _anim 还是 null(三个 .tscn 里节点名都是 AnimatedSprite2D)。

受击挂在 _apply_hit(真吃到伤害)而不是 hurt(is_dead 分支会走 _apply_knock_only)
—— 挂错地方会让尸体被后续命中也挤压。

JumpBird 的小跳刻意不挂钩(不经过 _set_state),靠空中连续项盖。
EOF
```

---

## Task 4: 对手副本

**Files:**
- Modify: `scenes/player/player_replica.gd`（`_ready()`、`apply_snapshot()`、`_process()`）
  - ★ 符号指代（理由同 Task 2 的 Files 行）：原文那串 `:57`/`:109`/`:182` 在 Task 4 自己落地后
    全部漂了（`_ready` `:57`→`:94`、`apply_snapshot` `:109`→`:152`、`_process` `:182`→`:241`）。

**Interfaces:**
- Consumes: `SquashStretch.*`（Task 1）
- Produces: `player_replica.gd` 上的 `var _vel: Vector2`、`var _pose: int`、`var _prev_vel_y: float`、
  `var squash: SquashStretch`、`var _water_feet_off: float`、`func _in_water() -> bool`，
  以及 `const POSE_FLY := 2` 与 `const LAND_VEL_EPS := 1.0`（后两者见 Step 1/Step 4）
  - ★ `_in_water()` 是**本地**水查询（读 `MazeGenerator.current_grid`），**不是**协议字段 ——
    Task 5 Step 2b 的变异 ① 正是删掉调用点的 `_in_water()` 分支。

- [ ] **Step 1: 加字段**

在 `scenes/player/player_replica.gd` 的字段声明区，`@onready var animator: AnimatedSprite2D = $AnimatedSprite2D` 那一行之后追加：

```gdscript
# 补间形变(squash & stretch)。副本复用与本体同一个组件,数据换成快照。
var squash: SquashStretch = null
# 快照里的速度与姿态。`vel` **本来就在服务器载荷里**(MatchSnapshot._broadcast_snapshot),
# 副本此前只是没读它 —— 加这个字段是"客户端开始读一个已存在的字段",协议零改动。
var _vel: Vector2 = Vector2.ZERO
var _pose: int = 0
# 上一帧的 vel.y。组件靠"上次在下落 + 现在已经落地"这一**对**值推导落地冲击,单看当前的
# _vel.y 推不出来 —— 服务器在落地那一帧就把它清零了。与本体 "_pre_move_vy 配帧首
# is_on_floor()" 是同款配对(见 spec §2.4)。
var _prev_vel_y: float = 0.0
```

同时在 `const POSE_ANIM: Dictionary = {...}` 那张表之后追加：

```gdscript
# Pose.FLY 的值(与 player.gd 的 `enum Pose { STAND, MOVE, FLY, CHARGE, SQUAT }` 里 FLY 一致)。
# 本类 extends Node2D、不继承 Player,引用不到那个枚举 —— 而下面按 pose 分支需要它。
# ★ 刻意**不写行号**:该枚举在密集改动区,写死的行号漂过两次(见 spec「行号是负资产」)。
const POSE_FLY := 2
```

- [ ] **Step 2: 在 `_ready` 里创建组件**

在 `scenes/player/player_replica.gd` 的 `_ready()` 末尾追加：

```gdscript
	# ★ 脚底探针偏移:一次性问幽灵体(Step 4 会用到)。**别漏这一行** ——
	#   漏了 `_water_feet_off` 就永远是它声明时的兜底值 24.0,水查询会整体错位。
	#   放在建幽灵体之后(_build_ghost_body 已把 stand 那份多边形留作启用态)。
	_water_feet_off = Water.feet_offset(_ghost) if _ghost != null else 24.0
	squash = SquashStretch.new()
	squash.setup(animator, SquashStretch.Profile.PLAYER)
	add_child(squash)
```

> ★ 顺序与本文件另两处宿主一致（`add_child()` 之后才 `setup()`，Task 2 Step 2 有完整理由）。

- [ ] **Step 3: `apply_snapshot` 记录 `vel` 与 `pose`**

在 `scenes/player/player_replica.gd` 的 `apply_snapshot()` 里，`_have_data = true` 之后追加：

```gdscript
	_vel = data.get("vel", Vector2.ZERO)
```

并在同一个函数的 `else:` 分支里 `var pose: int = clampi(...)` 之后追加：

```gdscript
		_pose = pose
```

> `_pose` 只在非倒地分支更新 —— 倒地时姿态语义已由 `_downed` 接管，而 `suppressed` 会让形变归中性，两者不冲突。

- [ ] **Step 4: `_process` 里 tick**

在 `scenes/player/player_replica.gd` 的 `_process()` 末尾追加：

```gdscript
	# 补间形变。放在 _process 而不是 apply_snapshot:后者没有 delta,而本函数是副本的
	# **表现层时钟**(插值推进与受击闪烁衰减都在这儿)。挂在快照回调上会与插值产生拍频。
	# ★ 参数必须**成对**:on_floor 取**当前**姿态,vel_y 取**上一帧**的值。这与本体
	#   "_pre_move_vy 配帧首 is_on_floor()" 是同款配对 —— 组件内部的落地判据是
	#   `on_floor and vel_y > squash_land_min_vy`,若把当前的 _vel.y 传进去,落地那一帧
	#   服务器已经把它清零了,挤压**永远不会触发**。
	# ★ on_floor 的**两半都不能省**。`pose != FLY` 只是"站在地上"的**代理**,它在两种
	#   `_vel.y` 并不趋于 0 的状态下**同样为真**:
	#     ① 水中下沉(本图最常见):姿态被强制成 MOVE/STAND,而 `velocity.y` **恒为**
	#        player_swim_down(=320,一个常量);
	#     ② 空中冲刺:本体的姿态逻辑把 `is_charge` 判在 `not is_on_floor()` **之前**,故下落
	#        途中起步的冲刺给出 on_floor=true,而冲刺只改 velocity.x。
	#   代理单独成判 ⇒ 落地项**每帧重触发**,指数恢复把 `_impulse` 压到 ≈ -0.91:
	#   ① 让对手**下沉期间持续** ~9% 挤压,② 更是满幅 -10%;而本体在这两种状态里都是中性的
	#   (水中 `_pre_move_vy` 被清零、冲刺只走拉伸),即两端出现本体**从不显示**的持续/反向形变。
	#   (另有一次性小项:带速入水那一帧 pose 先翻、`_prev_vel_y` 还攥着落速 → 假的水花挤压;
	#    本判据把它一并挡掉,因为入水帧的当前 `_vel.y` 已不是 ≈0。)
	#   ★ 历史:这半在计划初稿里就有,Task 2 阶段因"与 `vel_y > squash_land_min_vy` 互斥"
	#     被删 —— 那个理由只在调用点传**当前** `_vel.y` 时成立;现在传的是 `_prev_vel_y`
	#     (见上),故必须加回。**别删第三次。**
	var on_floor := (not _downed) and _pose != POSE_FLY \
			and absf(_vel.y) < LAND_VEL_EPS
	# ★ 爬梯那一半**刻意不在这里补**:本体的 `latched` 是**闩锁**,客户端手里只有无状态的位置
	#   代理("中心/脚底落在通道格"),拿它当判据会对"路过梯子/贴梯走过"误触发 ⇒ 那是**引入
	#   一类本体从不显示的新形变**,比留着残留更坏(用户裁定:本轮只修水中那一半)。
	#   残留据此**如实登记**(spec §4.3):空中爬梯持续 2.5~3.0% 拉伸、梯底停下那一下 ~6.3% 挤压。
	# ★ 水里传 0 —— 与本体同款。本体在 player.gd 对 (in_water or latched) 都清零 `_pre_move_vy`,
	#   故水里精确中性;副本没有该信号,只能本地查。
	#   ★★ **不需要协议字段**:本体的 `in_water` 本身就是**纯位置网格查询**
	#     (swim_component.gd 读 MazeGenerator.current_grid),而 PvP 客户端也建同一张图 ⇒
	#     跑同一个查询即可。水格不可破坏(tile_defs 里 destroyable 全 false)⇒ 两端不会漂。
	#     ★ 别去加 `in_water` 字段 —— 那是本 spec 曾经写错的地方。
	var vel_y := _prev_vel_y
	if _in_water():
		vel_y = 0.0
	squash.tick(delta, vel_y, on_floor, _downed)
	# ★ `_prev_vel_y` 记的是**原始** `_vel.y`(与本体记原始 velocity.y 同款):过滤只发生在
	#   **传参那一刻**,出水的下一帧宿主也立刻回到原始值,故两侧同相位。
	_prev_vel_y = _vel.y
```

并在 `const POSE_FLY := 2`（Step 1）之后补上 `LAND_VEL_EPS`，以及水查询的字段与函数：

```gdscript
# 副本的"站在地上"判据里,「当前 _vel.y 已骤降到 ≈0」那一半的容差。
# ★ 本体的等价性由**一次配对的取读**保证(在 move_and_slide 之前缓存 velocity.y + 帧首的
#   is_on_floor()),**不是**"地面上 velocity.y 恒 0" —— 那个前提只对重力路径成立(水中下沉
#   320 / 梯子下行 720 都在地面上写正 velocity.y,见 spec §2.4)。副本没有物理,故"当前
#   `_vel.y` 已骤降到 ≈0"必须**显式判**;而水里的那一档由 `_in_water()` 单独处理。
const LAND_VEL_EPS := 1.0
```

```gdscript
# 脚底探针偏移(世界 px):水中查询要与本体同口径 —— 本体走 `Water.is_in_water(脚底)`,
# 脚底 = 原点 + `Water.feet_offset(自己)`。取值在 _ready 里**一次性**问幽灵体(见下)。
# ★ 为什么一次性问幽灵体、而不是写死一个数:幽灵体的 5 份姿态多边形是从 player.tscn **现抄**的、
#   根同样是 scale 2.5 ⇒ `to_global` 出来的底边与本体逐像素相同(实测 stand = 57.0)。写死数会随
#   player.tscn 的碰撞箱改动**静默漂**(水花线那种"看着没事、其实偏了"的错)。
# ★ 为什么是**常量**而不是逐帧按姿态重算:本体那边实际也是常量 —— `Water.feet_offset` 的缓存
#   签名只数 `CollisionShape2D` 子节点(water.gd:_feet_signature),而玩家 5 份姿态箱全是
#   `CollisionPolygon2D`(player.tscn)⇒ 签名恒为 0、缓存永不失效 ⇒ 逐帧问与问一次同值。
# ★ 与本体那 1px 的差(如实登记):本体**首帧**调用时 5 个姿态箱在场景里全是启用态
#   (player.tscn 不带 disabled,而 `swim.update` 排在 `_tick_pose_and_collision` **之前**)
#   ⇒ 它缓存的是**5 箱合并**底边 = 58.0;副本这里是幽灵体当时启用的 stand 那一份 = 57.0。
#   差 1px。**刻意不去逐像素对齐它**:那等于把本体的缓存口径抄进第二个地方,而那份缓存哪天
#   被修成"跟着姿态走"时,抄来的 58 会朝**反**方向漂 1px。57 才是 feet_offset 的语义值
#   ("启用中的碰撞箱底边")。1px 在 64px 量化的格查询里最多让判据在下沉的一帧内(320px/s
#   ≈ 5.3px/帧)提前/延后一次,可感度为零。
var _water_feet_off: float = 24.0   # 24 = Water.feet_offset 的兜底值(幽灵体取不到时同款)
```

⚠️ 上面只是**声明**。真正的取值在 `_ready` 里 —— 忘了这一行，`_water_feet_off` 就永远是兜底的 24.0，
水查询会整体错位。**Step 2 的 `_ready` 里要一并加**（放在建幽灵体之后）：

```gdscript
	_water_feet_off = Water.feet_offset(_ghost) if _ghost != null else 24.0
```

```gdscript
# ★ 用**渲染**用的 `global_position`(已锚到最近副本、可能不在 [0,MAP))**是安全的**:
#   `Water.is_in_water` → `GridPathfinder.cell_of` 两端都 `posmod`,而 MAP_WIDTH/HEIGHT
#   由 `GameParameters.refresh_map_size()` 按 `格数 × TILE_SIZE` 算出 ⇒ 恒为 64 的整数倍
#   ⇒ 整幅平移一个副本后落回**同一格**。
func _in_water() -> bool:
	var gp := global_position
	return Water.is_in_water(Vector2(gp.x, gp.y + _water_feet_off))
```

> ⚠️ 成本：每个副本每帧一次 `cell_of` + 一次网格索引 + 一次 `is_liquid`，无多边形/物理计算、无分配。

- [ ] **Step 5: 编译检查**

```bash
"$GODOT" --headless --path . --quit-after 90
```

Expected: 无 `SCRIPT ERROR`。

- [ ] **Step 6: 联机回归（**由用户跑**）**

```bash
bash tests/pvp_reconcile_smoke.sh
```

Expected: 通过。本任务只加了一个 `data.get("vel")` 读取与一个纯视觉写入，**不得**影响 rollback 行为。若失败，先确认没有把 `_pre_move_vy` / `_vel` 之类加进任何 `capture_state()`。

- [ ] **Step 7: 提交**

```bash
git add scenes/player/player_replica.gd
git commit -F - <<'EOF'
feat(squash): 对手副本本地推导形变,协议零改动

vel 本来就在服务器载荷里(MatchSnapshot._broadcast_snapshot),副本此前只是没读 ——
这是"客户端开始读一个已存在的字段",不动协议、不动服务器。

tick 放 _process 而非 apply_snapshot:后者没有 delta,而 _process 是副本的表现层
时钟(插值推进与受击闪烁衰减都在那儿),挂快照回调会与插值产生拍频。

倒地 suppressed:副本给根节点设了 rotation(-90°),animator 是其子节点,写 scale
会沿转过的轴挤压 —— 尸体横着变宽。
EOF
```

---

## Task 5: 真渲染探针 + 文档

**Files:**
- Create: `tests/squash_stretch_probe.gd`
- Create: `tests/squash_stretch_probe.tscn`
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: `player.gd` 的 `var squash`（Task 2）
- Produces: 无

- [ ] **Step 1: 建探针场景**

创建 `tests/squash_stretch_probe.tscn`（照 `tests/destroyed_cells_probe.tscn` 的最简格式）：

```
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://tests/squash_stretch_probe.gd" id="1"]

[node name="SquashStretchProbe" type="Node"]
script = ExtResource("1")
```

- [ ] **Step 2: 写探针**

创建 `tests/squash_stretch_probe.gd`：

```gdscript
extends Node
# SquashStretch 真渲染探针。判据:SQUASH PROBE: ALL-OK
# 跑法:"$GODOT" --path . --quit-after 3600 res://tests/squash_stretch_probe.tscn
#      ★ 不要加 --headless —— 本探针要取图,headless 下截图链给 null。
#
# 两个目的:
#   ① 断言形变真的发生了、且**没有**影响碰撞箱与世界位置(Global Constraints 的硬约束)
#   ② 存一张图给**人眼**验收观感 —— 图要自己读,别推回给用户(历史上这一步抓到过两个
#      数值全绿的 bug)

const SHOT_PATH := "user://squash_stretch_probe.png"

var _fail: int = 0


func _ok(cond: bool, msg: String) -> void:
	if cond:
		print("  ok   ", msg)
	else:
		_fail += 1
		print("  FAIL ", msg)


func _ready() -> void:
	var SS = load("res://scenes/effects/squash_stretch.gd")
	var PP = load("res://core/config/player_params.gd")
	if SS == null or PP == null:
		print("SQUASH PROBE: FAIL | 加载失败")
		get_tree().quit(1)
		return
	print("== SquashStretch 真渲染探针 ==")

	var spr := AnimatedSprite2D.new()
	spr.sprite_frames = SpriteFrames.new()
	spr.sprite_frames.add_animation("idle")
	add_child(spr)

	var s = SS.new()
	add_child(s)
	s.setup(spr, SS.Profile.PLAYER)

	var base_pos: Vector2 = spr.global_position

	# ① 静止
	for i in 10:
		s.tick(1.0 / 60.0, 0.0, true, false)
	_ok(is_equal_approx(spr.scale.x, 1.0), "静止 → 单位缩放")

	# ② 落地冲击真的改了 scale(挤压 = 宽矮:x>1, y<1)
	s.tick(1.0 / 60.0, 1200.0, true, false)
	_ok(spr.scale.x > 1.0 and spr.scale.y < 1.0, "落地 → 挤压,实测 %s" % str(spr.scale))

	# ③ ★ 硬约束:形变**不得**移动节点、不得改变全局变换的位置部分
	_ok(spr.global_position == base_pos,
			"形变不改位置(实测 %s,基线 %s)" % [str(spr.global_position), str(base_pos)])

	# ④ 等一帧后取图(让人眼看到挤压那一刻)
	await get_tree().process_frame

	var img: Image = get_viewport().get_texture().get_image()
	if img == null:
		_ok(false, "截图失败 —— 是不是误加了 --headless?(真渲染是本探针的前提)")
	else:
		img.save_png(SHOT_PATH)
		print("  取图 → ", ProjectSettings.globalize_path(SHOT_PATH))
		_ok(true, "截图非空")

	if _fail == 0:
		print("SQUASH PROBE: ALL-OK")
	else:
		print("SQUASH PROBE: FAIL | %d 条" % _fail)
	get_tree().quit(1 if _fail > 0 else 0)
```

- [ ] **Step 2b: 副本行为守卫（`tests/squash_replica_probe`）**

**为什么必须有**（Task 4 复审指出）：Task 4 给副本加的**水查询**与**落地判据**目前**没有任何守卫** ——
`tests/squash_host_water_probe` 只驱动**玩家本体**，而本 Step 2 的真渲染探针只消费 `player.gd` 的 `var squash`。
把副本调用点里的 `_in_water()` 删掉、或把 `vel_y` 还原成 `_vel.y`，**现有测试一条都不会红**。

**为什么放这里**：这是最后一个任务，而副本是本特性唯一"没有物理可对照、只能从快照推导"的一环 ——
Task 4 三轮发现的问题**全部**发生在这一环（落地判据只做了一半、水查询被误判为"不可能"、爬梯残留漏登记）。
给它一个守卫的边际收益最高。

**做法**：新建 `tests/squash_replica_probe.gd` + `.tscn`，`extends Node`、**scene 模式 headless**
（autoload 在；副本与 `PlayerReplica` 都需要）。**不要**再加第三个合成网格 —— 照
`tests/squash_host_water_probe.gd` 的建图函数取一份（若两地形状不同，各留各的，别硬并）。
造一个真 `PlayerReplica`（或直接 `PlayerReplica.new()` + 手工 `_ready` 所需），**喂真快照字典**
（键与 `server/match_snapshot.gd` 一致），逐帧驱动 `apply_snapshot` + `_process`。

★ **五相**（断言都落在**可观测的** `animator.scale` 上）。**相⓪ 不是"附加项"，它守的是本探针
自己的夹具**（2026-09-20 补，原文只有四相、漏了它）：

0. **相⓪ 生产端字段表对账**（**源码级**，跑在其余四相之前）：拿夹具字典（`_snapshot_dict()`，
   唯一构造点）的**键集**与 `server/match_snapshot.gd` 里 `world["players"][str(role)] = {…}`
   那张字面量表的**键集双向对账**（生产端缺 = 探针在喂不存在的字段；夹具漏喂 = 头注那句
   "逐字一致"已经不成立）。★ **为什么不能省**：四个行为相喂的快照是**手写**的，而
   `MatchSnapshot._broadcast_snapshot()` 是"构造 + 广播"一体的、载荷不外流 —— 把生产端的
   `"vel": p.velocity` 删掉/改名，**四相全绿**，而对局里对手的形变**静默消失**（副本的
   `_prev_vel_y` 恒 0 ⇒ 空中项恒 0、落地项永不触发，一个字都不打）。判据要读**真源码**
   （用 `ScanUtil.code_only` 剥注释，否则一句提到字段名的注释会把被删掉的键重新喂绿），
   且**读不到源文件/定位不到那张表时必须报红**，不许静默跳过 —— 源码级守卫最典型的失明方式
   就是"文件改名 ⇒ 什么都没读到 ⇒ 断言恒真"。
1. **水中下沉 → 中性**：`pose` 取 `MOVE/STAND`（水里本体的姿态）、`vel.y` 恒为 `player_swim_down`（320），
   跑 ~45 帧，断言 `scale == Vector2.ONE`（水查询生效时 `vel_y` 被置 0 ⇒ `_air == 0`）。
2. **干地真落地 → 仍挤压**：前一快照 `vel.y = 900`、当前 `0`，断言 `scale.x > 1.0`（宽矮 = 挤压）。**这条是反例**，
   没有它，相 1 可以靠"永远中性"作弊通过。
3. **落地判据的两半都在**：`pose != FLY` 但当前 `vel.y` 仍大（模拟**空中冲刺**：姿态非 FLY、`vel_y` 大）
   ⇒ 断言**不**触发落地项（`scale.x` 不越 1.0）。这条专钉"只做 pose 那一半"的旧 bug。
4. **倒地 → 强制中性**：`downed = true` 时断言 `scale == Vector2.ONE`（副本倒地会给**根节点**设
   `rotation = -PI/2`，把 scale 写进去会沿**转过的轴**挤压）。

★ 每相都要带**前提断言**（"把守的那一行若删掉，这一相会真的变红"这件事本身）：相1 前提 = 喂进
`_prev_vel_y` 的确实是 320；相2 前提 = 上一帧落速确实是 900；相3 前提 = 姿态确实不是 FLY 且上一帧
是 900。没有这些前提，几何一漂（例如位置挪进了水里）这相就变成"什么都没测"却照样全绿的**假绿**。
★ 每一相换**一个全新的副本实例**：`_impulse` 是组件内部累计量、没有公开复位口，复用会把上一相的
指数尾巴带进本相窗口。

**变异验证（必做，写进报告）**：分别把 ① `_in_water()` 那一段去掉 → 相 1 必须红（复现 ~1.37% 拉伸）；
② 把 `vel_y` 换回 `_vel.y` → 相 2 必须红（复现"静默永不触发"，`scale.x == 1.0000`）；
③ 把落地判据的 `absf(_vel.y) < LAND_VEL_EPS` 去掉 → 相 3 必须红；
④ **把 `server/match_snapshot.gd` 里的 `"vel": p.velocity` 那一行删掉（或改名） → 相⓪ 必须红**
（四相**全绿**，这正是相⓪ 存在的理由）。**任一不变红即守卫无效，继续迭代。**

判据文本 `SQUASH REPLICA PROBE: ALL-OK`；`--quit-after` 给足 **3600 帧**（安全网，只在挂住时才用得上）。

```bash
"$GODOT" --headless --path . --quit-after 3600 res://tests/squash_replica_probe.tscn
```

- [ ] **Step 3: 跑探针并自己读图**

```bash
"$GODOT" --path . --quit-after 3600 res://tests/squash_stretch_probe.tscn
```

判据是输出里的文本 `SQUASH PROBE: ALL-OK`（**不要只看退出码** —— 探针挂住时 Godot 也可能退 0）。

然后把 `user://squash_stretch_probe.png` 找出来**自己读图**（用 Read 工具），确认形变方向符合预期、没有糊边或错位。路径用 `ProjectSettings.globalize_path("user://")` 打出来的那个。

- [ ] **Step 4: 更新 `CLAUDE.md`**

★★ **本 Step 现在只是"核对"，不是"重写"**（2026-09-20 订正）。此处原先内嵌了一整段
```markdown
### 补间形变(squash & stretch) …
```
的**待粘贴文本**，而那段文本在写下的当天就被 `a805246` 改掉了两处 —— 于是"照计划重跑 Step 4"
等于**把已经修好的两处缺陷重新写回 `CLAUDE.md`**：

1. **常量写错**：那段写 `on_floor && pre_move_vy > 200`，而两侧参数都是
   `squash_land_min_vy = 220.0`（判据在组件里是 `vel_y > _land_min_vy`，**不是字面量**）。
2. **前提写得太宽**：那段写"宿主在 `is_on_floor()` 时不施重力 ⇒ 地面上 `vel_y` 恒 0 ⇒ 该条只在
   落地那一帧成立"。这个前提**只对重力路径成立** —— 水中下沉（320）与梯子下行（720）都是
   "站在地面/水里仍然写正 `velocity.y`"，所以宿主的契约是"传进 `tick()` 的必须是地面真正
   吸收掉的那个下坠速度，否则传 0"，而"只在落地那一帧"是**过滤之后**的结论。

⇒ **做法**：`CLAUDE.md` 的 `## 渲染管线(Level0.tscn)` 之后**已有**这一节（Task 2/4/5 分批写入，
最后在 `a805246` 订正过）。本 Step 只做一件事：**逐条核对它是否仍然与 `scenes/effects/squash_stretch.gd`
与五个守卫一致**，不一致就改 `CLAUDE.md`（**以代码与守卫为准**，不以本文档里的旧文本为准）。
本节**不再内嵌**待粘贴文本 —— 内嵌副本正是这个缺陷的成因（同一份约定存两处，必漂）。

核对清单（这七条是那一节的骨架，缺一条就补）：

1. 组件位置/`class_name`/只写 `animator.scale`/两个标量相加的模型；
2. 落地判据 = `vel_y > _land_min_vy`（**符号名，不是 `> 200`**）+ `_pre_move_vy` 必须与帧首
   `is_on_floor()` **配对**（在 `move_and_slide()` 之前缓存）；
3. **宿主的过滤契约**（"不是摔下来的下坠速度要传 0"）+ 玩家侧过滤、**敌人侧刻意不过滤**（各有实测理由）；
4. 纯视觉：不进 `capture_state()`/`restore_state()`、不碰碰撞箱；两侧 `tick` 都放 `_physics_process`
   最首行（各自早退之前）；
5. 倒地/死亡 ⇒ `suppressed = true`（副本根节点带 `rotation`，写 scale 会沿转过的轴挤压）；
6. 已知边界（登记不修）：回滚重放会重播挤压包络；绕**中心**缩放导致挤压时底边上抬 ~4~5px
   （真现象、非缺陷）；
7. 守卫清单：`tests/squash_stretch_smoke.gd`（`-s`）+ 四条场景探针
   （`squash_stretch_probe` 真渲染 / `squash_host_water_probe` / `squash_host_enemy_probe` / `squash_replica_probe`）。

- [ ] **Step 5: 提交**

```bash
git add tests/squash_stretch_probe.gd tests/squash_stretch_probe.tscn CLAUDE.md
git commit -F - <<'EOF'
test(squash): 真渲染探针 + CLAUDE.md 记录组件约定

探针含"形变不得改变全局位置"的硬约束断言(Global Constraints 里那几条
"改了不报错"的),并取图供人眼验收观感。
EOF
```

---

## 全量验收（跑完五个任务后）

按顺序全跑一遍，**全部交给用户跑**：

```bash
# ① 新冒烟
"$GODOT" --headless --path . -s res://tests/squash_stretch_smoke.gd          # 期望 SQUASH SMOKE: ALL-OK

# ② 既有敌人逻辑没被弄坏
"$GODOT" --headless --path . -s res://tests/enemy_logic_smoke.gd             # 期望 SMOKE OK

# ③ 开局 90 帧无脚本错误
"$GODOT" --headless --path . --quit-after 90

# ④ 四条场景守卫(①玩家侧 ②敌鸟侧 ③副本侧,均 headless;--quit-after 只是安全网)
"$GODOT" --headless --path . --quit-after 3600 res://tests/squash_host_water_probe.tscn   # SQUASH HOST PROBE: ALL-OK
"$GODOT" --headless --path . --quit-after 3600 res://tests/squash_host_enemy_probe.tscn   # SQUASH HOST ENEMY PROBE: ALL-OK
"$GODOT" --headless --path . --quit-after 3600 res://tests/squash_replica_probe.tscn      # SQUASH REPLICA PROBE: ALL-OK

# ⑤ 真渲染探针(**不加 --headless**,加了截图链给 null)
"$GODOT" --path . --quit-after 3600 res://tests/squash_stretch_probe.tscn    # 期望 SQUASH PROBE: ALL-OK

# ⑥ 联机回归(本改动碰了副本,这条是关键)
bash tests/pvp_reconcile_smoke.sh
bash tests/pvp_twin_smoke.sh
```

**跑前先确认 7777 空闲**（联机探针会自己拉起大厅）。收尾按 PID 杀子进程 —— 只按端口杀会留残留。

## 明确不做（YAGNI）

- **不给 JumpBird 的小跳单独挂钩**（用户裁定，见 Task 3 Step 9 的注释）。
- **不给副本做受击挤压**（需要加协议字段，与本轮"协议不改"矛盾）。
- **不引入 AnimationPlayer / AnimationTree**（spec §2.1 的六条理由）。
- **不把 squash 状态放进 `capture_state()`**（会污染 C2 权威态，且回滚重播的已知边界不值得这个代价）。
- **不做 `Settings` 开关**（用户没要；幅度已锁在 ±10% 的轻微档）。
