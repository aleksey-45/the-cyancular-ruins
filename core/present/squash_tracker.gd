class_name SquashTracker
extends RefCounted

# 按动作事件和空中竖直速度计算实体的挤压与拉伸，参数来自 PlayerConfig 和 EnemyConfig。
# 缩放只影响精灵的局部坐标轴。角色锚点、碰撞形状、武器挂点和瞄准方向沿用原变换。
# 动作形变按指数曲线衰减。新的形变事件覆盖旧事件，例如落地后立即起跳时以起跳为准。

const PLAYER_CFG: PlayerConfig = preload("res://core/config/player_config.tres")
const ENEMY_CFG: EnemyConfig = preload("res://core/config/enemy_config.tres")

var _amount: float
var _recover: float
var _land_min_vy: float
var _land_ref_vy: float
var _land: float
var _air: float
var _air_ref_vy: float
var _impulses: Dictionary[StringName, float]
var _impulse := 0.0
var _at := -INF

func _init(enemy: bool) -> void:
	if enemy:
		_amount = ENEMY_CFG.shared_squash_amount
		_recover = ENEMY_CFG.shared_squash_recover
		_land_min_vy = ENEMY_CFG.shared_squash_land_min_vy
		_land_ref_vy = ENEMY_CFG.shared_squash_land_ref_vy
		_land = ENEMY_CFG.shared_squash_land
		_air = ENEMY_CFG.shared_squash_air
		_air_ref_vy = ENEMY_CFG.shared_squash_air_ref_vy
		_impulses = {
			&"hurt": -ENEMY_CFG.shared_squash_hurt,
			&"take_off": ENEMY_CFG.shared_squash_take_off,
			&"charge": ENEMY_CFG.shared_squash_charge,
			# 敌人的起跳和冲刺沿用起飞和突进的形变强度。
			&"jump": ENEMY_CFG.shared_squash_take_off,
			&"dash": ENEMY_CFG.shared_squash_charge,
		}
	else:
		_amount = PLAYER_CFG.squash_amount
		_recover = PLAYER_CFG.squash_recover
		_land_min_vy = PLAYER_CFG.squash_land_min_vy
		_land_ref_vy = PLAYER_CFG.squash_land_ref_vy
		_land = PLAYER_CFG.squash_land
		_air = PLAYER_CFG.squash_air
		_air_ref_vy = PLAYER_CFG.squash_air_ref_vy
		_impulses = {
			&"jump": PLAYER_CFG.squash_jump,
			&"dash": PLAYER_CFG.squash_dash,
			# 玩家开始冲刺时使用冲刺形变。
			&"charge": PLAYER_CFG.squash_dash,
			&"hurt": -PLAYER_CFG.squash_hurt,
		}


## 记录动作触发的形变。落地强度按竖直速度插值，低于阈值时不触发形变。其他动作使用配置值。
func impulse(kind: StringName, now: float, speed := 0.0) -> void:
	var strength := 0.0
	if kind == &"land":
		strength = -_land * clampf(inverse_lerp(_land_min_vy, _land_ref_vy, speed), 0.0, 1.0)
	else:
		strength = _impulses[kind]
	if is_zero_approx(strength):
		return
	_impulse = clampf(strength, -1.0, 1.0)
	_at = now


## 返回精灵局部坐标轴的缩放系数。动作形变随时间指数衰减，空中形变取决于当前竖直速度。
func sample(now: float, air_speed: float) -> Vector2:
	var air := clampf(absf(air_speed) / _air_ref_vy, 0.0, 1.0) * _air
	var age := maxf(now - _at, 0.0)
	var value := clampf(air + _impulse * exp(-_recover * age), -1.0, 1.0)
	return Vector2(1.0 - _amount * value, 1.0 + _amount * value)


func reset() -> void:
	_impulse = 0.0
	_at = -INF
