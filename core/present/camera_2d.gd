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
	# 视野大小由 zoom 决定：窗口固定为 1920×1440，当 zoom < 1 时可视范围为窗口分辨率 / zoom
	# （如 0.75 对应 2560×1920 视野）。参数由 PlayerParams 统一管理。
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

# 获取无抖动时的基准位置（weapon_base 瞄准换算使用，避免镜头抖动干扰准星）。
func get_base_global_position() -> Vector2:
	return _base_pos


func _process(delta: float) -> void:
	if target == null:
		return
	if not _bound:
		# 首次绑定初始化基准位置（保留规范坐标）；此后才按相机位置做环形副本对齐。
		_base_pos = target.global_position + Vector2(0.0, PlayerParams.cam_y_bias)
		_bound = true
	else:
		var target_pos := target.global_position
		# 以相机当前位置为锚点取目标的最近副本；两者跨接缝时把基准位置整体搬到同一副本，
		# 3×3 平铺让这次整图宽的搬移在画面上不可见，角色不会留在对侧画面外。
		var anchored := GridPathfinder.anchor_to_nearest(target_pos, _base_pos,
				GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
		var shift := anchored - target_pos
		if shift != Vector2.ZERO:
			_base_pos -= shift
		var desired := target_pos + Vector2(0.0, PlayerParams.cam_y_bias)
		var dx := desired.x - _base_pos.x
		if absf(dx) > PlayerParams.cam_deadzone:
			_base_pos.x += (dx - signf(dx) * PlayerParams.cam_deadzone) \
					* (1.0 - exp(-PlayerParams.cam_smooth_x * delta))
		var dy := desired.y - _base_pos.y
		if absf(dy) > PlayerParams.cam_deadzone:
			_base_pos.y += (dy - signf(dy) * PlayerParams.cam_deadzone) \
					* (1.0 - exp(-PlayerParams.cam_smooth_y * delta))
	_shake_offset = Vector2.ZERO
	if _shake_time > 0.0:
		_shake_time = maxf(_shake_time - delta, 0.0)
		var amount := _shake_amt * (_shake_time / maxf(_shake_dur, SHAKE_EPS))
		_shake_offset = Vector2(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)) * amount
	global_position = _base_pos + _shake_offset
