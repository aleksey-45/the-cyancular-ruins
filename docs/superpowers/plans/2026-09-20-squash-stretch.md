# Squash & Stretch Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 给玩家与三种敌鸟增加 squash & stretch 补间形变，让起跳/落地/受击/冲刺/起飞/冲撞有弹性反馈 —— 不新增任何逐帧贴图。

**Architecture:** 一个纯表现层的 `SquashStretch` 组件（`scenes/effects/squash_stretch.gd`），挂到玩家、三只敌鸟、对手副本上。计算模型是**两个标量相加**：`_air`（每帧由 `vel_y` 重算，无状态）+ `_impulse`（事件累加 + 指数回归，有状态）。最终 `animator.scale = (1 - amount·v, 1 + amount·v)`，`v` 被钳在 `[-1,1]`，所以幅度**永远不超过 ±10%**。

**Tech Stack:** Godot 4.7.1 标准版（GDScript）。无测试框架 —— 用 `extends SceneTree` 的 `-s` 冒烟脚本 + 真渲染场景探针。

**Spec:** `docs/superpowers/specs/2026-09-20-squash-stretch-design.md`（本节所有"见 spec §N"都指它）

## Global Constraints

- **只写 `animator.scale`**。不写 `self.scale`（玩家根 `scale = 2.5` 是世界缩放，写了整个角色会缩），不写 `flip_h`（朝向归 `_set_facing` / `_tick_pose_and_collision`）。
- **不进 `capture_state()`（`scenes/player/player.gd:449`）/ `restore_state()`（`:499`）**。squash 状态住在组件里、不在 `Player` 上 —— 实现时**不要**顺手把它加进捕获字典。
- **不碰任何碰撞体**。`Pose → CollisionPolygon2D` 那套（`player.gd:348-349`）完全不动。
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
	# ★ 符号:正 v = 拉伸(窄高),负 v = 挤压(宽矮)。x 与 y 反向变化。
	#   别写成 `1.0 - _amount * v` 配 `1.0 + ...` —— 那是反的,会让"起跳"变成压扁。
	_animator.scale = Vector2(1.0 + _amount * v, 1.0 - _amount * v)
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

	# ② 落地冲击 → 挤压(x<1, y>1)
	var b: Array = _mk()
	(b[0] as SquashStretch).tick(DT, 1200.0, true, false)
	var bs: Vector2 = (b[1] as AnimatedSprite2D).scale
	_ok(bs.x < 1.0 and bs.y > 1.0, "落地冲击 → 挤压方向,实测 %s" % str(bs))
	# 且不得越过 amount 上限
	_ok(absf(bs.x - 1.0) <= PlayerParams.squash_amount + 0.0001,
			"落地挤压不越上限(%.3f)" % PlayerParams.squash_amount)

	# ③ 低落速不触发:100 < squash_land_min_vy(220)
	var c: Array = _mk()
	(c[0] as SquashStretch).tick(DT, 100.0, true, false)
	_ok(_near((c[1] as AnimatedSprite2D).scale.x, 1.0, 0.0005),
			"落速 100(< 下限 220)不触发挤压,实测 %s" % str((c[1] as AnimatedSprite2D).scale))

	# ④ 起跳冲击 → 拉伸(x>1, y<1)
	var d: Array = _mk()
	(d[0] as SquashStretch).impulse(SquashStretch.Impulse.JUMP)
	(d[0] as SquashStretch).tick(DT, 0.0, true, false)
	var ds: Vector2 = (d[1] as AnimatedSprite2D).scale
	_ok(ds.x > 1.0 and ds.y < 1.0, "起跳冲击 → 拉伸方向,实测 %s" % str(ds))

	# ⑤ 空中连续项:在空中且 |vel_y| 大 → 拉伸
	var e: Array = _mk()
	(e[0] as SquashStretch).tick(DT, -700.0, false, false)
	_ok((e[1] as AnimatedSprite2D).scale.x > 1.0,
			"空中(vel_y=-700)→ 拉伸,实测 %s" % str((e[1] as AnimatedSprite2D).scale))

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
	_ok(espr.scale.x > 1.0, "敌人 profile 响应 TAKE_OFF,实测 %s" % str(espr.scale))

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

	# 落地冲击。站立时宿主不施重力(_tick_vertical 在 is_on_floor() 时跳过/敌人同理),
	# 故地面上 vel_y 恒为 0 —— 本条只在**落地那一帧**成立,天然只触发一次,不需要跨帧边沿变量。
	if on_floor and vel_y > _land_min_vy:
		var k := clampf((vel_y - _land_min_vy) / maxf(_land_ref_vy - _land_min_vy, 1.0), 0.0, 1.0)
		_impulse -= _land_gain * k

	_impulse = MathUtil.approach(_impulse, 0.0, _recover, delta)
	_apply()
```

- [ ] **Step 8: 运行冒烟，确认变绿**

```bash
"$GODOT" --headless --path . -s res://tests/squash_stretch_smoke.gd
```

Expected: 九条全 `ok`，末行 `SQUASH SMOKE: ALL-OK`，退出码 0。

- [ ] **Step 9: 提交**

```bash
git add core/config/player_params.gd core/config/enemy_params.gd scenes/effects/squash_stretch.gd tests/squash_stretch_smoke.gd
git commit -F - <<'EOF'
feat(squash): SquashStretch 组件 + 参数常量 + 纯逻辑冒烟

两个标量相加的模型:_air 每帧重算(无状态,回滚安全) + _impulse 事件累加
指数回归(有状态,重放会重播一次,见 spec §5.4)。单标量让"冲刺中落地"这类
同时事件天然叠加,不需要优先级状态机。

落地挤压由 vel_y 无状态推导:站立时宿主不施重力 → vel_y 恒 0,故该条只在
落地那一帧成立,不需要 _was_on_floor。

冒烟九相:静止/落地挤压/低落速不触发/起跳拉伸/空中连续项/指数回归/
多事件叠加不越上限/强制中性/敌人 profile 不认玩家的 Impulse。
EOF
```

---

## Task 2: 玩家接入

**Files:**
- Modify: `scenes/player/player.gd`（声明区 `:44` 后、`_ready` `:156` 后、`_physics_process` `:159`、`_tick_vertical` `:249`、`_tick_crouch_and_dash` `:276-278`、`take_hit` `:412`、`move_and_slide` `:219` 前）

**Interfaces:**
- Consumes: `SquashStretch.setup/impulse/tick`、`SquashStretch.Profile.PLAYER`、`SquashStretch.Impulse.JUMP/DASH/HURT`（Task 1）
- Produces: `player.gd` 上的 `var squash: SquashStretch` 与 `var _pre_move_vy: float`（Task 5 的探针会读 `squash`）

- [ ] **Step 1: 加字段**

在 `scenes/player/player.gd` 的 `@onready var swim: SwimComponent = $Swim`（`:44`）之后追加：

```gdscript
# 补间形变(squash & stretch)。运行期创建,不是场景子节点 —— 与 _reload_ring 同款。
# ★ 纯表现层:不进 capture_state()/restore_state(),不碰碰撞箱。
var squash: SquashStretch = null
# move_and_slide() **之前**的 velocity.y。与帧首的 is_on_floor() 配对,供 squash 无状态推导落地。
# ★ 不得进 capture_state(),不得被任何模拟逻辑读取 —— 只喂 squash(见 spec §5.1)。
var _pre_move_vy: float = 0.0
```

- [ ] **Step 2: 在 `_ready` 里创建组件**

在 `scenes/player/player.gd` 的 `_ready` 里，`call_deferred("add_child", WaterFx.new())`（`:156`）之后追加：

```gdscript
	# 补间形变:挂在**自己**身上(与 _reload_ring 同款的一个接入点覆盖单机/PvP/大乱斗)。
	# animator 是 @export 引用,场景实例化时就已就位,`_ready` 里可用。
	squash = SquashStretch.new()
	squash.setup(animator, SquashStretch.Profile.PLAYER)
	add_child(squash)
```

- [ ] **Step 3: 帧首 tick**

把 `scenes/player/player.gd:159-162` 改成：

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

把 `scenes/player/player.gd:218-219` 改成：

```gdscript
	# ---------- 执行移动 ----------
	# ★ 必须在 move_and_slide() **之前**:落地那一帧它在调用后就被清零了。
	# ★ 且必须**滤掉不是摔下来的下坠速度**(spec §2.4):
	#   水中 swim_component.gd:26 每帧无条件写 player_swim_down(320 > 落地下限 220),
	#   站在水下实心地面上时 in_water 与 is_on_floor() 同时为真 → 不滤的话每帧触发落地分支,
	#   稳态把玩家永久压在 ~9% 挤压上。梯子下行(720)同理,虽然它只触发一帧。
	_pre_move_vy = 0.0 if (in_water or latched) else velocity.y
	move_and_slide()
```

> `in_water`(`:196`)与 `latched`(`:202`)在本行之前都已就位。

并且把 `_physics_process` 的倒地早退分支改成**同时**把该值归零（否则倒地期间它变陈旧 —— `_tick_downed` 不更新它 —— 复活首帧会与地面态配对出一个满幅假挤压）：

```gdscript
	if combat.is_downed():
		_pre_move_vy = 0.0
		_tick_downed(delta)
		return
```

- [ ] **Step 5: 起跳钩子**

在 `scenes/player/player.gd` 的 `_tick_vertical` 里，`jump_cut_applied = false`（`:252`）之后追加：

```gdscript
		squash.impulse(SquashStretch.Impulse.JUMP)
```

> ⚠️ 缩进必须与 `jump_cut_applied = false` 同级（它在 `if jump_buffer_timer > 0.0 ...:` 块内）。

- [ ] **Step 6: 冲刺钩子**

在 `scenes/player/player.gd` 的 `_tick_crouch_and_dash` 里，`charge_timer = charge_duration`（`:278`）之后追加：

```gdscript
		squash.impulse(SquashStretch.Impulse.DASH)
```

- [ ] **Step 7: 受击钩子**

把 `scenes/player/player.gd:412-413` 改成：

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
- Modify: `scenes/enemies/enemy_base.gd`（字段区 `:48` 后、`_ready` `:64` 后、`_physics_process` `:91`、`_set_state` `:286`、`_apply_hit` `:150`、`move_and_slide` `:135` 前）
- Modify: `scenes/enemies/enemy_fly_bird.gd`
- Modify: `scenes/enemies/enemy_black_bird.gd`
- Modify: `scenes/enemies/enemy_jump_bird.gd`

**Interfaces:**
- Consumes: `SquashStretch.*`（Task 1）
- Produces:
  - `enemy_base.gd` 上的 `var squash: SquashStretch`、`var _pre_move_vy: float`
  - 虚钩 `func _on_state_entered(s: int) -> void`（基类空实现，三个子类覆写）

- [ ] **Step 1: `EnemyBase` 加字段**

在 `scenes/enemies/enemy_base.gd:48` 的 `var _anim: AnimatedSprite2D` 之后追加：

```gdscript
# 补间形变(squash & stretch)。纯表现层,不进任何网络同步、不碰碰撞箱。
var squash: SquashStretch = null
# move_and_slide() **之前**的 velocity.y,与帧首 is_on_floor() 配对(见 spec §2.4)。
var _pre_move_vy: float = 0.0
```

- [ ] **Step 2: `EnemyBase._ready` 创建组件**

把 `scenes/enemies/enemy_base.gd:61-64` 改成：

```gdscript
func _ready() -> void:
	add_to_group("enemies")
	_setup_contact_area()
	call_deferred("add_child", WaterFx.new())
	# 补间形变。★ 用 $AnimatedSprite2D 而不是 _anim:子类 `_ready` 是**先** super._ready()
	#   后才 `_anim = $AnimatedSprite2D`(见 enemy_jump_bird.gd:15/18),此处 _anim 还是 null。
	#   三个敌人的 .tscn 里该节点都叫 AnimatedSprite2D。
	squash = SquashStretch.new()
	add_child(squash)
	squash.setup(get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D,
			SquashStretch.Profile.ENEMY)
```

- [ ] **Step 3: `EnemyBase._physics_process` 帧首 tick**

把 `scenes/enemies/enemy_base.gd:91-96` 改成：

```gdscript
func _physics_process(delta: float) -> void:
	# squash 放在最首行(_is_far_sleeping 早退之前):睡眠时也走 tick → vel_y 小 → 回中性,
	# 正是想要的行为;否则睡眠中的鸟会卡在最后一个形变值上。
	squash.tick(delta, _pre_move_vy, is_on_floor(), is_dead)
	if _is_far_sleeping():
		_ai(delta)
		_wrap()
		return
```

> `is_dead`（`enemy_base.gd:28`）是敌人侧与玩家 `combat.is_downed()` 对应的"强制中性"信号 —— 尸体不该有弹性。

- [ ] **Step 4: `EnemyBase` 缓存 pre-move velocity**

把 `scenes/enemies/enemy_base.gd:133-135` 改成：

```gdscript
	# 爆炸击退位移:单独 move_and_collide(带碰撞),不污染 velocity
	# (地面把向下击退吃掉后再减回去会把身体弹起);主移动 move_and_slide 最后跑,地面状态以它为准。
	move_and_collide(knock_velocity * delta)
	knock_velocity *= exp(-knock_decay_rate * delta)
	# ★ 必须在 move_and_slide() **之前**,且必须滤掉不是摔下来的下坠速度(spec §2.4):
	#   `_apply_water`(:206)在水里写 buoyancy/swim 的 velocity.y,在水下实心地面上会与
	#   is_on_floor() 同时成立 → 每帧触发落地分支。玩家侧是同一个洞(见 Task 2 Step 4)。
	_pre_move_vy = 0.0 if _in_water else velocity.y
	move_and_slide()
```

- [ ] **Step 5: `EnemyBase._set_state` 加虚钩**

把 `scenes/enemies/enemy_base.gd:286-288` 改成：

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

在 `scenes/enemies/enemy_base.gd` 的 `_apply_hit`（`:150`）函数体末尾追加一行：

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
# ★ `_tick_chase` 里的小跳(enemy_jump_bird.gd:101-102)**刻意不挂钩** —— 它直接设 velocity、
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
- Modify: `scenes/player/player_replica.gd`（`_ready` `:57`、`apply_snapshot` `:109`、`_process` `:182`）

**Interfaces:**
- Consumes: `SquashStretch.*`（Task 1）
- Produces: `player_replica.gd` 上的 `var _vel: Vector2`、`var _pose: int`、`var squash: SquashStretch`

- [ ] **Step 1: 加字段**

在 `scenes/player/player_replica.gd` 的 `@onready var animator: AnimatedSprite2D = $AnimatedSprite2D`（`:34`）之后追加：

```gdscript
# 补间形变(squash & stretch)。副本复用与本体同一个组件,数据换成快照。
var squash: SquashStretch = null
# 快照里的速度与姿态。`vel` **本来就在服务器载荷里**(server/match_snapshot.gd:20),
# 副本此前只是没读它 —— 加这个字段是"客户端开始读一个已存在的字段",协议零改动。
var _vel: Vector2 = Vector2.ZERO
var _pose: int = 0
# 上一帧的 vel.y。组件靠"上次在下落 + 现在已经落地"这一**对**值推导落地冲击,单看当前的
# _vel.y 推不出来 —— 服务器在落地那一帧就把它清零了。与本体 "_pre_move_vy 配帧首
# is_on_floor()" 是同款配对(见 spec §2.4)。
var _prev_vel_y: float = 0.0
```

同时在 `const POSE_ANIM: Dictionary = {...}`（`:16-18`）之后追加：

```gdscript
# Pose.FLY 的值(= player.gd:103 的 `enum Pose { STAND, MOVE, FLY, CHARGE, SQUAT }`)。
# 本类 extends Node2D、不继承 Player,引用不到那个枚举 —— 而下面按 pose 分支需要它。
const POSE_FLY := 2
```

- [ ] **Step 2: 在 `_ready` 里创建组件**

在 `scenes/player/player_replica.gd` 的 `_ready`（`:57`）末尾追加：

```gdscript
	squash = SquashStretch.new()
	squash.setup(animator, SquashStretch.Profile.PLAYER)
	add_child(squash)
```

- [ ] **Step 3: `apply_snapshot` 记录 `vel` 与 `pose`**

在 `scenes/player/player_replica.gd` 的 `apply_snapshot` 里，`_have_data = true`（`:112`）之后追加：

```gdscript
	_vel = data.get("vel", Vector2.ZERO)
```

并在 `else:` 分支里 `var pose: int = clampi(...)`（`:135`）之后追加：

```gdscript
		_pose = pose
```

> `_pose` 只在非倒地分支更新 —— 倒地时姿态语义已由 `_downed` 接管，而 `suppressed` 会让形变归中性，两者不冲突。

- [ ] **Step 4: `_process` 里 tick**

在 `scenes/player/player_replica.gd` 的 `_process` 末尾追加：

```gdscript
	# 补间形变。放在 _process 而不是 apply_snapshot:后者没有 delta,而本函数是副本的
	# **表现层时钟**(插值推进与受击闪烁衰减都在这儿)。挂在快照回调上会与插值产生拍频。
	# ★ 参数必须**成对**:on_floor 取**当前**姿态,vel_y 取**上一帧**的值。这与本体
	#   "_pre_move_vy 配帧首 is_on_floor()" 是同款配对 —— 组件内部的落地判据是
	#   `on_floor and vel_y > squash_land_min_vy`,若把当前的 _vel.y 传进去,落地那一帧
	#   服务器已经把它清零了,挤压**永远不会触发**。
	var on_floor := (not _downed) and _pose != POSE_FLY
	squash.tick(delta, _prev_vel_y, on_floor, _downed)
	_prev_vel_y = _vel.y
```

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

vel 本来就在服务器载荷里(server/match_snapshot.gd:20),副本此前只是没读 ——
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

	# ② 落地冲击真的改了 scale
	s.tick(1.0 / 60.0, 1200.0, true, false)
	_ok(spr.scale.x < 1.0 and spr.scale.y > 1.0, "落地 → 挤压,实测 %s" % str(spr.scale))

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

- [ ] **Step 3: 跑探针并自己读图**

```bash
"$GODOT" --path . --quit-after 3600 res://tests/squash_stretch_probe.tscn
```

判据是输出里的文本 `SQUASH PROBE: ALL-OK`（**不要只看退出码** —— 探针挂住时 Godot 也可能退 0）。

然后把 `user://squash_stretch_probe.png` 找出来**自己读图**（用 Read 工具），确认形变方向符合预期、没有糊边或错位。路径用 `ProjectSettings.globalize_path("user://")` 打出来的那个。

- [ ] **Step 4: 更新 `CLAUDE.md`**

在 `## 渲染管线(Level0.tscn)` 一节之后新增一节（或并入"UI"节前）：

```markdown
### 补间形变(squash & stretch)
`scenes/effects/squash_stretch.gd`(`class_name SquashStretch extends Node`)—— 纯表现层组件,
挂到玩家 / 三只敌鸟 / 对手副本上,**只写 `animator.scale`**。计算模型是两个标量相加:
`_air`(每帧由 `vel_y` 重算,无状态)+ `_impulse`(事件累加 + `MathUtil.approach` 指数回归)。
**单标量**是刻意的 —— "冲刺中落地""起跳瞬间被击中"这类同时事件天然叠加,不需要优先级状态机。
幅度上限 `squash_amount` = **0.10**(用户裁定"不要太夸张"),`v` 钳在 `[-1,1]` 故永不越界。
★ **落地挤压由 `vel_y` 无状态推导**,不需要 `_was_on_floor`:宿主在 `is_on_floor()` 时不施重力,
故地面上 `vel_y` 恒 0 → `on_floor && pre_move_vy > 200` 只在落地那一帧成立。与之配套,
宿主必须在 `move_and_slide()` **之前**缓存 `_pre_move_vy`(它与帧首的 `is_on_floor()` 配对,
二者描述同一时刻)。敌人侧状态事件走 `_on_state_entered(s)` 虚钩 —— 三只鸟各有自己的
`enum State`(JumpBird 没有 TAKE_OFF),基类不能硬编码状态名。
★ **纯视觉:不进 `capture_state()`/`restore_state()`、不碰碰撞箱。** 玩家侧 `tick` 放
`_physics_process` **最首行**(倒地早退之前),否则倒地后 scale 会卡在最后一个形变值上;
敌人侧同理(放 `_is_far_sleeping()` 早退之前)。
★ **倒地必须 `suppressed = true`**:副本给根节点设了 `rotation = -90°`,而 animator 是其
**子节点** → 此时写 `scale` 会沿**转过的轴**挤压,尸体横着变宽。本地玩家虽不旋转,但两端
行为要一致、且尸体不该有弹性。
★ **已知边界(登记不修)**:`prediction_rollback.gd:114` 的重放是**直接调 `_physics_process`**,
而 `_impulse` 不在 `capture_state()` 里 → 回滚时挤压包络会**重播一次**。纯视觉、幅度 ±10%,
表现是"弹一下";要修就得把纯视觉状态塞进权威态,那是更坏的选择。`_air` 项无状态,不受影响。
守卫:`tests/squash_stretch_smoke.gd`(`-s`,九相纯逻辑)+ `tests/squash_stretch_probe.tscn`
(真渲染,含"形变不得改变全局位置"的硬约束断言,取图人眼验收)。
★ **对手副本**复用同一个组件,数据从快照的 `vel`/`pose` 本地推导 —— `vel` 本来就在载荷里
(`server/match_snapshot.gd:20`),只是副本此前没读,**协议零改动**。副本**不做受击挤压**
(快照里没有受击事件,从 `hp` 下降推会在 AoE 多段伤害时误触发)。tick 放副本的 `_process`
而非 `apply_snapshot`:后者没有 `delta`,而 `_process` 是副本的表现层时钟(插值推进与受击
闪烁衰减都在那儿),挂快照回调会与插值产生拍频。
```

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

# ④ 真渲染探针(不加 --headless)
"$GODOT" --path . --quit-after 3600 res://tests/squash_stretch_probe.tscn    # 期望 SQUASH PROBE: ALL-OK

# ⑤ 联机回归(本改动碰了副本,这条是关键)
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
