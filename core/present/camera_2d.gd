extends Camera2D

@export var target: Node2D = null

const SHAKE_TAIL := 0.7
# 一帧内的"最短取模位移"超过这个量 ⇒ 不是走动/坠落,而是真传送(复活/回溯/换边):直接重锚、不做平滑。
# (跨接缝的取模差 ≈ 0,不会误判成传送;正常走动一帧 ≤ ~30px。)
const SNAP_DIST := 400.0

var _shake_amt: float = 0.0
var _shake_time: float = 0.0
var _shake_dur: float = 0.0
var _base_pos: Vector2 = Vector2.ZERO
var _target_cont: Vector2 = Vector2.ZERO
var _cam_cont: Vector2 = Vector2.ZERO
var _tracked := false

func _ready() -> void:
	zoom = Vector2(PlayerParams.cam_zoom, PlayerParams.cam_zoom)

func shake(amount: float, duration: float) -> void:
	# ★ 不降级:比当前剩余包络弱的震动直接忽略。否则开火(2px/0.1s)/受击(8px/0.25s)会把爆炸(30px/0.5s)顶掉
	#   —— 这是"爆炸震消失得特别快"的主因(不是包络曲线)。等强度允许刷新时长(连发/连爆)。
	var cur := 0.0
	if _shake_time > 0.0:
		cur = _shake_amt * pow(_shake_time / maxf(_shake_dur, 0.0001), SHAKE_TAIL)
	if amount < cur:
		return
	_shake_amt = amount
	_shake_time = duration
	_shake_dur = duration

func get_base_global_position() -> Vector2:
	return _base_pos


func _process(delta: float) -> void:
	if target == null:
		return

	var t := target.global_position
	var want_off := Vector2(0.0, PlayerParams.cam_y_bias)
	if target is CharacterBody2D:
		var vx: float = (target as CharacterBody2D).velocity.x
		want_off.x = clampf(vx / PlayerParams.move_speed, -1.0, 1.0) * PlayerParams.cam_lookahead_x

	if not _tracked:
		_target_cont = t
		_cam_cont = t + want_off
		_tracked = true
	else:
		var d := t - _target_cont
		d.x = wrapf(d.x, -GameParameters.MAP_WIDTH * 0.5, GameParameters.MAP_WIDTH * 0.5)
		d.y = wrapf(d.y, -GameParameters.MAP_HEIGHT * 0.5, GameParameters.MAP_HEIGHT * 0.5)
		if d.length() > SNAP_DIST:
			_target_cont = t
			_cam_cont = t + want_off
		else:
			_target_cont += d

	var dz := PlayerParams.cam_deadzone
	_cam_cont.x = _follow_axis(_cam_cont.x, _target_cont.x + want_off.x, PlayerParams.cam_smooth_x, dz, delta)
	_cam_cont.y = _follow_axis(_cam_cont.y, _target_cont.y + want_off.y, PlayerParams.cam_smooth_y, dz, delta)

	_base_pos = t + (_cam_cont - _target_cont)
	global_position = _base_pos
	if _shake_time > 0.0:
		_shake_time = maxf(_shake_time - delta, 0.0)
		var amt := _shake_amt * pow(_shake_time / maxf(_shake_dur, 0.0001), SHAKE_TAIL)
		global_position += Vector2(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)) * amt
	# ★ 像素契约:相机落点吸附到整数屏幕像素(世界位置 × zoom 取整再除回)。缩放可由 PlayerParams 调,
	#   不吸附时平滑/前瞻/震屏逐帧落在新的亚像素相位上,像素栅格会蠕动。
	var z := maxf(zoom.x, 0.0001)
	global_position = (global_position * z).round() / z


func _follow_axis(cur: float, want: float, k: float, deadzone: float, delta: float) -> float:
	var d := want - cur
	if absf(d) <= deadzone:
		return cur
	var goal := want - signf(d) * deadzone
	var t := 1.0 - exp(-k * delta)
	return lerpf(cur, goal, t)
