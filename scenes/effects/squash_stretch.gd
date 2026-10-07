class_name SquashStretch
extends Node
# 挤压与拉伸程序化形变组件：根据物理运动状态对 AnimatedSprite2D 进行动态缩放调节。
# 挂载于包含 AnimatedSprite2D 的角色实体上，属于纯视觉表现层。
# 由宿主在每物理帧显式调用 tick() 驱动。

enum Profile { PLAYER, ENEMY }

# 外部事件类型（着地挤压由垂直速度计算派生）
enum Impulse { JUMP, HURT, DASH, TAKE_OFF, CHARGE }

var _animator: AnimatedSprite2D = null
var _gain: Dictionary = {}          # Impulse -> 带符号增益(正=拉伸/负=挤压)

# 计算模型：空中速度项（无状态）与事件脉冲项（带指数衰减）叠加
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


# 每帧更新形变状态：结合 vel_y 与 on_floor 判定着地冲击
func tick(delta: float, vel_y: float, on_floor: bool, suppressed: bool) -> void:
	if suppressed:
		# 倒地状态强制维持中性无形变
		_air = 0.0
		_impulse = 0.0
		_apply()
		return

	# 空中速度连续拉伸项
	_air = 0.0
	if not on_floor:
		_air = clampf(absf(vel_y) / maxf(_air_ref_vy, 1.0), 0.0, 1.0) * _air_gain

	# 落地冲击挤压项
	if on_floor and vel_y > _land_min_vy:
		var k := clampf((vel_y - _land_min_vy) / maxf(_land_ref_vy - _land_min_vy, 1.0), 0.0, 1.0)
		_impulse -= _land_gain * k
		_impulse = clampf(_impulse, -1.0, 1.0)

	_impulse = MathUtil.approach(_impulse, 0.0, _recover, delta)
	_apply()


func _apply() -> void:
	if _animator == null:
		return
	var v := clampf(_air + _impulse, -1.0, 1.0)
	# 正 v 为拉伸（窄高：scale.x < 1, scale.y > 1），负 v 为挤压（宽矮：scale.x > 1, scale.y < 1）
	_animator.scale = Vector2(1.0 - _amount * v, 1.0 + _amount * v)
