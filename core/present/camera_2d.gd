extends Camera2D

@export var target: Node2D = null

# 震动包络:振幅 = amount * (剩余/总时长)^SHAKE_TAIL。指数 <1 ⇒ 尾段比线性衰减**更长**;
# 原来的线性曲线 + 每帧随机噪声,峰值只在第一帧,读起来像"一碰就没"。
const SHAKE_TAIL := 0.7
# 一帧内的"最短取模位移"超过这个量 ⇒ 不是走动/坠落,而是真传送(复活/回退/换边):直接重锚、不做平滑。
# (跨接缝的取模差 ≈ 0,不会误判成传送;正常走动一帧 ≤ ~30px。)
const SNAP_DIST := 400.0

var _shake_amt: float = 0.0
var _shake_time: float = 0.0
var _shake_dur: float = 0.0
var _base_pos: Vector2 = Vector2.ZERO
# ★★ 连续(未取模)空间的玩家位置与镜头中心。环面世界把玩家坐标取模 ⇒ 跨接缝那一帧坐标会瞬间差一整张图;
#   若直接在取模坐标上做死区/平滑,这一帧就会被当成"横穿地图"的大位移(要么平滑出 9600px 平移,要么靠 snap 硬跳一帧)。
#   这里改成:先把玩家位移按"最短取模差"累积成连续坐标,死区/平滑全在连续空间里做,
#   最后镜头节点位置 = 玩家当前取模坐标 + 连续空间里的偏移 —— 跨接缝时玩家与镜头**同帧一起跳**,
#   偏移不变 ⇒ 画面与没加死区时一样无缝(这才是环面相机该有的做法)。
var _target_cont: Vector2 = Vector2.ZERO
var _cam_cont: Vector2 = Vector2.ZERO
var _tracked := false

func _ready() -> void:
	# 视野大小由 zoom 决定:窗口固定 1920×1440,zoom<1 时看到的世界范围 = 窗口/zoom
	# (如 0.75 → 2560×1920)。数值在 PlayerParams,统一调这里。
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

# 无抖动时的基准位置(平滑后的镜头中心)。瞄准换算(weapon_base)用它,避免镜头抖动影响准星。
func get_base_global_position() -> Vector2:
	return _base_pos


func _process(delta: float) -> void:
	if target == null:
		return

	var t := target.global_position
	# 期望偏移:基础上抬 + 横向速度前瞻。纵向**不做**前瞻(cam_lookahead_y 保留未用):
	# 跳跃时它会叠加成上下摆,正是这次要压掉的东西。
	var want_off := Vector2(0.0, PlayerParams.cam_y_bias)
	if target is CharacterBody2D:
		var vx: float = (target as CharacterBody2D).velocity.x
		want_off.x = clampf(vx / PlayerParams.move_speed, -1.0, 1.0) * PlayerParams.cam_lookahead_x

	if not _tracked:
		# 首帧直接对齐到"玩家 + 期望偏移":否则开局镜头会从 (0,0) 滑过来。
		_target_cont = t
		_cam_cont = t + want_off
		_tracked = true
	else:
		var d := t - _target_cont
		d.x = wrapf(d.x, -GameParameters.MAP_WIDTH * 0.5, GameParameters.MAP_WIDTH * 0.5)
		d.y = wrapf(d.y, -GameParameters.MAP_HEIGHT * 0.5, GameParameters.MAP_HEIGHT * 0.5)
		if d.length() > SNAP_DIST:
			# 真传送:重锚,别把一次复活/换边演成跨图平移
			_target_cont = t
			_cam_cont = t + want_off
		else:
			_target_cont += d

	# 死区 + 指数平滑(连续空间):小位移(< deadzone)镜头不动 ⇒ 上楼梯/自动跳的 1 格上下不推画面。
	var dz := PlayerParams.cam_deadzone
	_cam_cont.x = _follow_axis(_cam_cont.x, _target_cont.x + want_off.x, PlayerParams.cam_smooth_x, dz, delta)
	_cam_cont.y = _follow_axis(_cam_cont.y, _target_cont.y + want_off.y, PlayerParams.cam_smooth_y, dz, delta)

	# 输出:镜头节点 = 玩家**当前取模坐标** + 连续空间偏移 ⇒ 永远贴着玩家、跨接缝与玩家同帧跳。
	_base_pos = t + (_cam_cont - _target_cont)
	global_position = _base_pos
	if _shake_time > 0.0:
		_shake_time = maxf(_shake_time - delta, 0.0)
		var amt := _shake_amt * pow(_shake_time / maxf(_shake_dur, 0.0001), SHAKE_TAIL)
		global_position += Vector2(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)) * amt


# 单轴跟随:目标与当前差在死区内 ⇒ 不动;出死区后以指数系数 k 追到"目标 − 死区边界",避免贴边抖。
# 用 1−exp(−k·Δt) 而不是 lerp(常数位),与帧率无关。
func _follow_axis(cur: float, want: float, k: float, deadzone: float, delta: float) -> float:
	var d := want - cur
	if absf(d) <= deadzone:
		return cur
	var goal := want - signf(d) * deadzone
	var t := 1.0 - exp(-k * delta)
	return lerpf(cur, goal, t)
