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
