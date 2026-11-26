class_name SquashTracker
extends RefCounted

# 按动作事件和空中竖直速度计算实体的挤压与拉伸，参数来自 PlayerConfig 和 EnemyConfig。
# 缩放只影响精灵的局部坐标轴。角色锚点、碰撞形状、武器挂点和瞄准方向沿用原变换。
# 动作形变按指数曲线衰减。新的形变事件覆盖旧事件，例如落地后立即起跳时以起跳为准。

const PLAYER_CFG: PlayerConfig = preload("res://core/config/player_config.tres")
const ENEMY_CFG: EnemyConfig = preload("res://core/config/enemy_config.tres")

var _settings: SquashConfig
var _impulse := 0.0
var _at := -INF

func _init(enemy: bool) -> void:
	_settings = ENEMY_CFG.squash if enemy else PLAYER_CFG.squash

## 记录动作触发的形变。落地强度按竖直速度插值，低于阈值时不触发形变。其他动作使用配置值。
func impulse(kind: StringName, now: float, speed := 0.0) -> void:
	var strength := 0.0
	match kind:
		&"land": strength = -_settings.land * clampf(inverse_lerp(_settings.land_min_vy, _settings.land_ref_vy, speed), 0.0, 1.0)
		&"hurt": strength = -_settings.hurt
		&"jump", &"take_off": strength = _settings.jump
		&"dash", &"charge": strength = _settings.dash
	if is_zero_approx(strength):
		return
	_impulse = clampf(strength, -1.0, 1.0)
	_at = now


## 返回精灵局部坐标轴的缩放系数。动作形变随时间指数衰减，空中形变取决于当前竖直速度。
func sample(now: float, air_speed: float) -> Vector2:
	var air := clampf(absf(air_speed) / _settings.air_ref_vy, 0.0, 1.0) * _settings.air
	var age := maxf(now - _at, 0.0)
	var value := clampf(air + _impulse * exp(-_settings.recover * age), -1.0, 1.0)
	return Vector2(1.0 - _settings.amount * value, 1.0 + _settings.amount * value)


func reset() -> void:
	_impulse = 0.0
	_at = -INF
