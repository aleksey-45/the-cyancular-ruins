extends Camera2D

@export var target: Node2D = null

var _shake_amt: float = 0.0
var _shake_time: float = 0.0
var _shake_dur: float = 0.0
var _base_pos: Vector2 = Vector2.ZERO

func shake(amount: float, duration: float) -> void:
	_shake_amt = amount
	_shake_time = duration
	_shake_dur = duration

# 无抖动时的基准位置。瞄准换算(weapon_base)用它,避免镜头抖动影响准星。
func get_base_global_position() -> Vector2:
	return _base_pos


func _process(delta: float) -> void:
	if target == null:
		return

	# 直接跟随玩家。玩家跨接缝时位置取模,相机跟随即可;
	# 视野跳变由环形世界的渲染层处理(见 level_0 的 3x3 铺贴)。
	_base_pos.x = target.global_position.x
	_base_pos.y = target.global_position.y + PlayerParams.cam_y_bias
	global_position = _base_pos
	if _shake_time > 0.0:
		_shake_time = maxf(_shake_time - delta, 0.0)
		var amt := _shake_amt * (_shake_time / maxf(_shake_dur, 0.0001))
		global_position += Vector2(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)) * amt
