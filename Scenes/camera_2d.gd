extends Camera2D

@export var target: Node2D = null

var _shake_amt: float = 0.0
var _shake_time: float = 0.0
var _shake_dur: float = 0.0

func shake(amount: float, duration: float) -> void:
	_shake_amt = amount
	_shake_time = duration
	_shake_dur = duration


func _process(delta: float) -> void:
	if target == null:
		return

	# 直接跟随玩家。玩家跨接缝时位置取模,相机跟随即可;
	# 视野跳变由环形世界的渲染层处理(见 level_0 的 3x3 铺贴)。
	global_position.x = target.global_position.x
	global_position.y = target.global_position.y + GameParameters.cam_y_bias
	if _shake_time > 0.0:
		_shake_time = maxf(_shake_time - delta, 0.0)
		var amt := _shake_amt * (_shake_time / maxf(_shake_dur, 0.0001))
		global_position += Vector2(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)) * amt
