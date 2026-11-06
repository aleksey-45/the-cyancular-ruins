class_name AiNavigator
extends Node


const FIRE_RANGE := 620.0
const APPROACH_DIST := 300.0
const BACKOFF_DIST := 140.0
const AIM_JITTER := 0.10
const TARGET_STICKY := 0.6
const STUCK_JUMP_TIME := 0.4

var host: Node
var role := 0
var src: AiInputSource

var _t := 0.0
var _next_fire := 0.0
var _fire_left := 0.0
var _next_decide := 0.0
var _strafe := 1.0
var _target_role := 0
var _stuck_t := 0.0


func _ready() -> void:
	_t = randf_range(0.0, 10.0)
	_next_fire = _t + randf_range(0.3, 1.2)
	_next_decide = _t + randf_range(0.5, 1.5)


func _physics_process(delta: float) -> void:
	if src == null or host == null or not is_instance_valid(host):
		return
	if int(host._round_state) != int(host.RoundState.PLAYING):
		src.fire = false
		src.axis = 0.0
		return
	_t += delta
	var p: Node2D = host.players.get(role)
	if p == null or not is_instance_valid(p):
		return
	var foe := _pick_target(p)
	var target: Node2D = foe["node"]
	var dist: float = foe["dist"]
	var dir: Vector2 = foe["dir"]
	if target == null:
		src.fire = false
		src.axis = 0.0
		return
	_aim_and_fire(p, target, dist, dir, delta)
	_move(p, dist, dir, delta)


# 黏滞目标:保持当前目标,除非它失效,或新目标明显更近(TARGET_STICKY 倍以内)。
func _pick_target(p: Node2D) -> Dictionary:
	var cur: Node2D = null
	var cur_dist := INF
	if _target_role != 0 and host.players.has(_target_role):
		var c: Node2D = host.players[_target_role]
		if is_instance_valid(c) and not c.is_downed():
			cur = c
			cur_dist = MazeGenerator.toroidal_delta_px(c.global_position, p.global_position,
					GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT).length()
	if cur != null:
		var d := MazeGenerator.toroidal_delta_px(cur.global_position, p.global_position,
				GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
		return {"node": cur, "dist": cur_dist, "dir": -d}
	# 当前目标失效 → 找最近的
	var best_role := 0
	var best_node: Node2D = null
	var best_dist := INF
	var best_dir := Vector2.ZERO
	for r in host.players:
		if int(r) == role:
			continue
		var o: Node2D = host.players[r]
		if not is_instance_valid(o) or o.is_downed():
			continue
		var dd := MazeGenerator.toroidal_delta_px(o.global_position, p.global_position,
				GameParameters.MAP_WIDTH, GameParameters.MAP_HEIGHT)
		if dd.length() < best_dist:
			best_role = int(r)
			best_node = o
			best_dist = dd.length()
			best_dir = dd
	if best_node != null:
		_target_role = best_role
	return {"node": best_node, "dist": best_dist, "dir": -best_dir}


func _aim_and_fire(p: Node2D, target: Node2D, dist: float, dir_to: Vector2, delta: float) -> void:
	src.aim = dir_to.normalized().rotated(randf_range(-AIM_JITTER, AIM_JITTER) * 0.4)
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
		_fire_left -= delta


func _move(p: Node2D, dist: float, dir_to: Vector2, delta: float) -> void:
	if _t >= _next_decide:
		_next_decide = _t + randf_range(1.0, 2.0)
		_strafe = 1.0 if randf() < 0.5 else -1.0
	var move := 0.0
	if dist > APPROACH_DIST:
		move = signf(dir_to.x) if absf(dir_to.x) > 0.15 else _strafe
	elif dist < BACKOFF_DIST:
		move = -signf(dir_to.x) if absf(dir_to.x) > 0.15 else _strafe
	else:
		move = _strafe
	if move != 0.0 and absf(p.velocity.x) < 12.0:
		_stuck_t += delta
	else:
		_stuck_t = 0.0
	if _stuck_t >= STUCK_JUMP_TIME:
		_stuck_t = 0.0
		src.press_jump()
	src.axis = move
