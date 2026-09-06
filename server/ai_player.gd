class_name AINavigator
extends Node

# AI 玩家控制器(实验性 AI 补位,test-ai 分支):服务端权威视角,知道全场位置。
# 每物理帧写 AIInputSource 字段驱动对应 player(与真人输入包同一条消费路径)。
# 行为 v1:锁定最近存活对手;瞄准加抖动;有视线且距离合适就点射;
#          远则追、近则拉扯、中距左右横移;被墙卡住跳一下。COUNTDOWN/MATCH_OVER 不动。

const FIRE_RANGE := 620.0        # 开火距离上限(px)
const APPROACH_DIST := 300.0     # 追击距离阈值
const BACKOFF_DIST := 140.0      # 过近拉扯阈值
const AIM_JITTER := 0.12         # 瞄准抖动弧度(给玩家留活路)

var host: Node            # MatchHost / RoyaleHost(读 players/_round_state)
var role := 0
var src: AIInputSource

var _t := 0.0
var _next_fire := 0.0
var _fire_left := 0.0
var _next_decide := 0.0
var _strafe := 1.0


func _physics_process(delta: float) -> void:
	if src == null or host == null or not is_instance_valid(host):
		return
	# COUNTDOWN / MATCH_OVER:待机(服务器权威冻结,与真人同款)
	if int(host._round_state) != int(host.RoundState.PLAYING):
		src.fire = false
		src.axis = 0.0
		return
	_t += delta
	_decide()
	_aim_and_fire()
	_src_tick(delta)


func _decide() -> void:
	if _t >= _next_decide:
		_next_decide = _t + randf_range(1.0, 2.0)
		_strafe = 1.0 if randf() < 0.5 else -1.0


func _nearest_foe(p: Node2D) -> Dictionary:
	var best := {"node": null, "dist": INF, "dir": Vector2.ZERO}
	for r in host.players:
		if int(r) == role:
			continue
		var o: Node2D = host.players[r]
		if not is_instance_valid(o) or o.is_downed():
			continue
		var d := MazeGenerator.toroidal_delta_px(o.global_position, p.global_position,
				GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
		var dist := d.length()
		if dist < best["dist"]:
			best = {"node": o, "dist": dist, "dir": -d}   # -d:由我指向对手
	return best


func _aim_and_fire() -> void:
	var p: Node2D = host.players.get(role)
	if p == null or not is_instance_valid(p):
		return
	var foe := _nearest_foe(p)
	var target: Node2D = foe["node"]
	var dist: float = foe["dist"]
	var dir: Vector2 = foe["dir"]
	if target == null:
		src.fire = false
		src.axis = 0.0
		return
	# 瞄准:指向对手 + 抖动
	src.aim = (dir.normalized().rotated(randf_range(-AIM_JITTER, AIM_JITTER) * 0.4))
	# 移动:远追 / 近拉 / 中距横移
	var move := 0.0
	if dist > APPROACH_DIST:
		move = signf(dir.x) if absf(dir.x) > 0.15 else _strafe
	elif dist < BACKOFF_DIST:
		move = -signf(dir.x) if absf(dir.x) > 0.15 else _strafe
	else:
		move = _strafe
	# 卡住检测:想动但水平速度≈0 → 跳
	if move != 0.0 and absf(p.velocity.x) < 12.0 and randf() < 0.25:
		src.press_jump()
	src.axis = move
	# 开火:有视线且在射程内 → 节奏点射(打 0.4s 停 0.5~0.9s)
	var in_range := dist < FIRE_RANGE
	var los := false
	if in_range:
		var ts := GameParameters.TILE_SIZE
		los = MazeGenerator.has_line_of_sight(
				Vector2i(int(p.global_position.x) / ts, int(p.global_position.y) / ts),
				Vector2i(int(target.global_position.x) / ts, int(target.global_position.y) / ts))
	if los and _t >= _next_fire:
		_fire_left = 0.4
		_next_fire = _t + randf_range(0.9, 1.4)
	src.fire = _fire_left > 0.0
	if _fire_left > 0.0:
		_fire_left -= get_physics_process_delta_time()


func _src_tick(_delta: float) -> void:
	pass   # 预留:行为参数随时间演化
