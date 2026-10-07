extends Camera2D

@export var target: Node2D = null

var _shake_amt: float = 0.0
var _shake_time: float = 0.0
var _shake_dur: float = 0.0
var _base_pos: Vector2 = Vector2.ZERO

func _ready() -> void:
	# 视野大小由 zoom 决定：窗口固定为 1920×1440，当 zoom < 1 时可视范围为窗口分辨率 / zoom
	# （如 0.75 对应 2560×1920 视野）。参数由 PlayerParams 统一管理。
	zoom = Vector2(PlayerParams.cam_zoom, PlayerParams.cam_zoom)

func shake(amount: float, duration: float) -> void:
	_shake_amt = amount
	_shake_time = duration
	_shake_dur = duration

# 获取无抖动时的基准位置（weapon_base 瞄准换算使用，避免镜头抖动干扰准星）。
func get_base_global_position() -> Vector2:
	return _base_pos


func _process(delta: float) -> void:
	if target == null:
		return

	# 相机实时跟随目标玩家：玩家跨越地图边界时坐标取模回绕，相机直接同步跟随；
	# 视野连续性由环形世界的渲染图层统一处理（参见 level_0 的 3×3 铺贴逻辑）。
	_base_pos.x = target.global_position.x
	_base_pos.y = target.global_position.y + PlayerParams.cam_y_bias
	global_position = _base_pos
	if _shake_time > 0.0:
		_shake_time = maxf(_shake_time - delta, 0.0)
		var amt := _shake_amt * (_shake_time / maxf(_shake_dur, 0.0001))
		global_position += Vector2(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)) * amt
