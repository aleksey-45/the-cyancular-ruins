class_name MatchCamera
extends Camera2D

const SHAKE_EPS := 0.0001

var _shake_amt: float = 0.0
var _shake_time: float = 0.0
var _shake_dur: float = 0.0
var _shake_offset: Vector2 = Vector2.ZERO
var base_position := Vector2.ZERO
var _bound := false
var _rng := RandomNumberGenerator.new()

func fire(weapon: int) -> void:
	var spec := WeaponRegistry.definition(weapon)
	if spec.has("shake"):
		shake(spec["shake"], spec.get("shake_time", 0.1))

func blast(distance: float, radius: float) -> void:
	var reach := maxf(radius * 2.5, 400.0)
	if distance <= reach:
		shake(PlayerParams.explosion_cam_shake * (1.0 - distance / reach), PlayerParams.explosion_cam_shake_time)

func hit(ratio: float) -> void:
	if ratio > 0.0:
		shake(PlayerParams.hit_cam_shake * (ratio / 0.25) if ratio > 0.25 else 6.0,
				PlayerParams.hit_cam_shake_time if ratio > 0.25 else 0.15)

## 新抖动至少与当前衰减后的抖动一样强时，才更新幅度。新抖动与原抖动的剩余时间取较长者。
func shake(amount: float, duration: float) -> void:
	var remaining := _shake_time
	var effective := 0.0
	if remaining > 0.0:
		effective = _shake_amt * (remaining / maxf(_shake_dur, SHAKE_EPS))
	if amount >= effective:
		_shake_amt = amount
		_shake_dur = maxf(duration, remaining)
		_shake_time = _shake_dur
	elif duration > remaining:
		_shake_dur = duration
		_shake_time = duration


func advance(delta: float, position_to_follow: Vector2, size: Vector2, speed_x: float = 0.0) -> void:
	var run_fraction := clampf(speed_x / PlayerParams.move_speed, -1.0, 1.0)
	var desired := position_to_follow + Vector2(run_fraction * PlayerParams.cam_lead_x, PlayerParams.cam_y_bias)
	if not _bound:
		base_position = desired
		_bound = true
	else:
		# 地图边缘相接。摄像机先移到离跟随目标最近的一侧，避免沿整个地图宽度或高度移动。
		base_position = GridPathfinder.anchor_to_nearest(base_position, desired, size)
		var dx := desired.x - base_position.x
		if absf(dx) > PlayerParams.cam_deadzone:
			base_position.x += (dx - signf(dx) * PlayerParams.cam_deadzone) \
					* (1.0 - exp(-PlayerParams.cam_smooth_x * delta))
		var dy := desired.y - base_position.y
		if absf(dy) > PlayerParams.cam_deadzone:
			base_position.y += (dy - signf(dy) * PlayerParams.cam_deadzone) \
					* (1.0 - exp(-PlayerParams.cam_smooth_y * delta))
	var margin := Vector2.ONE * PlayerParams.cam_seam_margin
	# 平滑跟随只使用没有抖动的摄像机位置，抖动偏移只影响本帧的画面。
	base_position = base_position.clamp(-margin, size + margin)
	_shake_offset = Vector2.ZERO
	if _shake_time > 0.0:
		_shake_time = maxf(_shake_time - delta, 0.0)
		var amount := _shake_amt * (_shake_time / maxf(_shake_dur, SHAKE_EPS))
		_shake_offset = Vector2(_rng.randf_range(-1.0, 1.0), _rng.randf_range(-1.0, 1.0)) * amount
	position = (base_position + _shake_offset).clamp(-margin, size + margin)
