extends Camera2D

@export var target: Node2D = null

const SHAKE_EPS := 0.0001

var _shake_amt: float = 0.0
var _shake_time: float = 0.0
var _shake_dur: float = 0.0
var _shake_offset: Vector2 = Vector2.ZERO
var _base_pos: Vector2 = Vector2.ZERO
var _bound := false

func _ready() -> void:
	zoom = Vector2(PlayerParams.cam_zoom, PlayerParams.cam_zoom)
	_bound = false

## 保留当前仍有效的较强震幅与较长持续时间，避免弱震覆盖强震。
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
		# 弱震只延长已有节奏，不改写更强的震幅。
		_shake_dur = duration
		_shake_time = duration

# 瞄准使用无抖动的镜头位置。
func get_base_global_position() -> Vector2:
	return _base_pos


func _process(delta: float) -> void:
	if target == null:
		return
	var size := CollisionWorld.acquire(self).terrain.map_size
	var desired := target.global_position + Vector2(0.0, PlayerParams.cam_y_bias)
	if not _bound:
		_base_pos = desired
		_bound = true
	else:
		# 角色回绕时先把相机切到同侧的副本，再继续平滑。
		_base_pos = GridPathfinder.anchor_to_nearest(_base_pos, desired, size)
		var dx := desired.x - _base_pos.x
		if absf(dx) > PlayerParams.cam_deadzone:
			_base_pos.x += (dx - signf(dx) * PlayerParams.cam_deadzone) \
					* (1.0 - exp(-PlayerParams.cam_smooth_x * delta))
		var dy := desired.y - _base_pos.y
		if absf(dy) > PlayerParams.cam_deadzone:
			_base_pos.y += (dy - signf(dy) * PlayerParams.cam_deadzone) \
					* (1.0 - exp(-PlayerParams.cam_smooth_y * delta))
	var margin := Vector2.ONE * PlayerParams.cam_seam_margin
	# 镜头滞后时把基准位置限制在铺好的接缝带内。
	_base_pos = _base_pos.clamp(-margin, size + margin)
	_shake_offset = Vector2.ZERO
	if _shake_time > 0.0:
		_shake_time = maxf(_shake_time - delta, 0.0)
		var amount := _shake_amt * (_shake_time / maxf(_shake_dur, SHAKE_EPS))
		_shake_offset = Vector2(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)) * amount
	global_position = (_base_pos + _shake_offset).clamp(-margin, size + margin)
