class_name SquashStretch
extends Node
# 补间形变(squash & stretch):按物理状态对 AnimatedSprite2D 做程序化缩放。
# 挂到任意"有 AnimatedSprite2D 的角色"上(玩家 / 三只敌鸟),纯表现层。
#
# ★ **模式闸门 `set_landing_only(true)` = 只留落地那一下**(2026-09-21 用户裁定:形变只在**单机**
#   模式生效,联机模式全部取消,**例外是玩家落地那一下**)。用户原话:"把本次合并的优化在多人模式
#   都取消掉,仅在单人模式应用,除了玩家落地的优化"。故闸门落在**组件**而不是四个调用点:
#   - 要静音的有 **4 处**(`_air` 空中连续项 + JUMP/DASH/HURT 三个 `impulse()` 调用点),散在
#     `player.gd` 的 `_tick_pose_and_collision`、`take_hit` 与 `_process` 里;**漏掉任何一处都不报错**。
#   - 一个布尔闸门只有一处判断点,且 `-s` 的 `squash_stretch_smoke.gd` 能直接把它钉住。
#   闸门**只**关掉"事件 + 空中连续项",落地项照常 → 这正是用户要保留的那一条。
#   ⚠ 开关在 `setup()` 之后由宿主设置(单机不调 ⇒ 默认 false = 全功能,行为逐字不变)。
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

# 见文件头:true = 只保留落地挤压,事件脉冲与空中连续项整条不生效(联机模式用)。
# 默认 false —— 单机与三只敌鸟都不调本开关,行为与加闸门之前逐字相同。
var _landing_only: bool = false


# 模式闸门,见文件头。宿主在 `setup()` 之后调一次(模式是定值,不必每帧问)。
func set_landing_only(v: bool) -> void:
	_landing_only = v
	if v:
		# 切进来时把存量清零,否则"上一帧刚被 hurt/jump 推过"的那点残量会带进新模式。
		_air = 0.0
		_impulse = 0.0
		_apply()


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
	if _landing_only:
		# 拦在**写入口**(而不是让调用点各自判模式):调用点漏判是静默的,写入口不会漏。
		# ※ 残留:`player.gd` 的三处调用点(起跳/冲刺在 `_tick_pose_and_collision`、受击在
		#   `take_hit`)在联机下仍会**调**到这里(空转),但没有任何可观测后果 ——
		#   不产生形变,也不写任何别的状态。
		return
	_impulse = clampf(_impulse + float(_gain.get(kind, 0.0)), -1.0, 1.0)


# 宿主每帧调一次。vel_y / on_floor 必须来自**同一次** move_and_slide:
# 帧首的 is_on_floor() 是上一帧 move_and_slide 的结果,所以 vel_y 要传那次 move_and_slide
# **之前**缓存的 velocity.y。二者配对才能无状态推导落地 —— 见 spec §2.4。
func tick(delta: float, vel_y: float, on_floor: bool, suppressed: bool) -> void:
	if suppressed:
		# 倒地:强制中性。副本侧尤其必须 —— 它给根节点设了 rotation,而本节点是其子节点,
		# 写 scale 会沿转过的轴挤压(见 spec §5.2)。
		_air = 0.0
		_impulse = 0.0
		_apply()
		return

	# 空中连续项:**重新算**而不是累加(无状态,回滚重放结果一致)。
	# ★ 联机模式(`_landing_only`)整项跳过 —— 它就是用户要取消的"本次合并的优化"的一部分。
	_air = 0.0
	if not on_floor and not _landing_only:
		_air = clampf(absf(vel_y) / maxf(_air_ref_vy, 1.0), 0.0, 1.0) * _air_gain

	# 落地冲击。站立时宿主不施重力(_tick_vertical 在 is_on_floor() 时跳过/敌人同理),
	# 故地面上 vel_y 恒为 0 —— 本条只在**落地那一帧**成立,天然只触发一次,不需要跨帧边沿变量。
	if on_floor and vel_y > _land_min_vy:
		var k := clampf((vel_y - _land_min_vy) / maxf(_land_ref_vy - _land_min_vy, 1.0), 0.0, 1.0)
		_impulse -= _land_gain * k
		# ★ 减法之后必须**自己**再钳一次 —— `impulse()` 里那个 clampf 管不到这里:
		#   宿主违约(每帧喂同一个"不是摔下来的"下坠速度)时本条每帧重复减同一个满幅值,
		#   而指数恢复每帧只回 `1 - exp(-9/60) ≈ 14%` ⇒ `_impulse` 收敛到**定点**
		#   `-k·d/(1-d)`(睡眠鸟那一处实测 ≈ -6.19k,任何 k ≳ 0.16 都沉到 -1 以下),
		#   而不是停留在 -1。后果不是"更扁一点":之后任意一次 `impulse()` 的**正**增益都加在
		#   更负的基数上 ⇒ 起跳/冲刺的拉伸被压低、显形推后(约 0.1s 量级的包络),
		#   "冲刺中起跳""受击后立刻起跳"那几下招牌脆感随之消失。
		#   今天可达的路径只有**一次性叠加**(刚受击 -0.5 紧接着一次硬落地 -1.0 ≈ -1.4);
		#   而它是**状态量**:一旦漂下去,只能靠时间回来。钳在写入口,与 `impulse()` 同款约定。
		_impulse = clampf(_impulse, -1.0, 1.0)

	_impulse = MathUtil.approach(_impulse, 0.0, _recover, delta)
	_apply()


func _apply() -> void:
	if _animator == null:
		return
	var v := clampf(_air + _impulse, -1.0, 1.0)
	# ★ 符号:正 v = 拉伸(窄高:scale.x < 1, scale.y > 1),负 v = 挤压(宽矮)。
	#   x 与 y 反向变化。增益表跟着这条走:jump/dash/take_off/charge 为正(拉伸),
	#   land(减法)与 hurt(取负)为负(挤压)。
	# ★ 别"顺手"翻成 `1.0 + _amount * v` 配 `1.0 - ...`:那会让**每个**事件都反过来
	#   (起跳变压扁、落地变拉伸)。2026-09-20 真发生过一次 —— 当时有人把 (0.9, 1.1)
	#   (窄高 = 拉伸)误读成宽矮,进而"纠正"了本就正确的本行。
	_animator.scale = Vector2(1.0 - _amount * v, 1.0 + _amount * v)
