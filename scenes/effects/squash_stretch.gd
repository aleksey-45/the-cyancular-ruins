class_name SquashStretch
extends Node

enum Profile { PLAYER, ENEMY }

enum Impulse { JUMP, HURT, DASH, TAKE_OFF, CHARGE }

var _animator: AnimatedSprite2D = null
var _gain: Dictionary = {}

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


func tick(delta: float, vel_y: float, on_floor: bool, suppressed: bool) -> void:
	if suppressed:
		_air = 0.0
		_impulse = 0.0
		_apply()
		return

	_air = 0.0
	if not on_floor:
		_air = clampf(absf(vel_y) / maxf(_air_ref_vy, 1.0), 0.0, 1.0) * _air_gain

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
	_animator.scale = Vector2(1.0 - _amount * v, 1.0 + _amount * v)
