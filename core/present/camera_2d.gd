extends Camera2D

@export var target: Node2D = null

# 震动包络:振幅 = amount * (剩余/总时长)^SHAKE_TAIL。指数 <1 ⇒ 尾段比线性衰减**更长**;
# 原来的线性曲线 + 每帧随机噪声,峰值只在第一帧,读起来像"一碰就没"。
const SHAKE_TAIL := 0.7
# 一次目标位移超过这些量就当作"传送"(复活 / 换边 / 环面接缝回绕),直接对齐、不做平滑 ——
# 否则镜头的平滑会把一次跨图传送演成一段长距离平移。
const SNAP_X := 600.0
const SNAP_Y := 900.0

var _shake_amt: float = 0.0
var _shake_time: float = 0.0
var _shake_dur: float = 0.0
var _base_pos: Vector2 = Vector2.ZERO
# 平滑后的镜头中心(不含震动)。基向量与"死区判定"都打在这上面。
var _cam: Vector2 = Vector2.ZERO
var _cam_ready := false

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

	# ★★ 跟随 = 前瞻(横向) + 死区 + 指数平滑。旧实现是**每帧直接等于玩家位置**:
	#   自动跳/台沿抬升让玩家 y 在 1~17px 级瞬时变化 ⇒ 整个画面跟着上下跳,这就是"上楼梯画面抖动"。
	#   `PlayerParams` 里本来就有 cam_lookahead_x / cam_smooth_x / cam_smooth_y / cam_deadzone 四个参数,
	#   旧实现一个都没用上(只有 cam_y_bias / cam_zoom),所以"没有死区"这个判断是对的。
	var want := target.global_position + Vector2(0.0, PlayerParams.cam_y_bias)
	# 横向前瞻:朝跑动方向偏一段(满速 = cam_lookahead_x),用平滑后的速度估计,避免冲刺起步时镜头猛甩。
	if target is CharacterBody2D:
		var vx: float = (target as CharacterBody2D).velocity.x
		want.x += clampf(vx / PlayerParams.move_speed, -1.0, 1.0) * PlayerParams.cam_lookahead_x
	# 垂直**不做**前瞻(cam_lookahead_y 保留未用):跳跃时它会叠加成上下摆,正是这次要压掉的东西。

	if not _cam_ready:
		_cam = want
		_cam_ready = true
	elif absf(want.x - _cam.x) > SNAP_X or absf(want.y - _cam.y) > SNAP_Y:
		_cam = want   # 传送(复活/换边/接缝回绕):直接对齐
	else:
		_cam.x = _follow_axis(_cam.x, want.x, PlayerParams.cam_smooth_x, PlayerParams.cam_deadzone, delta)
		_cam.y = _follow_axis(_cam.y, want.y, PlayerParams.cam_smooth_y, PlayerParams.cam_deadzone, delta)

	_base_pos = _cam
	global_position = _base_pos
	if _shake_time > 0.0:
		_shake_time = maxf(_shake_time - delta, 0.0)
		var amt := _shake_amt * pow(_shake_time / maxf(_shake_dur, 0.0001), SHAKE_TAIL)
		global_position += Vector2(randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)) * amt


# 单轴跟随:目标与当前差在死区内 ⇒ 不动(上楼梯的 1 格上下被吃掉);
# 出死区后以指数系数 k 追到"目标 − 死区边界",避免贴边抖。
# 用 1−exp(−k·Δt) 而不是 lerp(常数位),与帧率无关。
func _follow_axis(cur: float, want: float, k: float, deadzone: float, delta: float) -> float:
	var d := want - cur
	if absf(d) <= deadzone:
		return cur
	var goal := want - signf(d) * deadzone
	var t := 1.0 - exp(-k * delta)
	return lerpf(cur, goal, t)
