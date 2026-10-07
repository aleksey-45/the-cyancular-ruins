class_name AiNavigator
extends Node

# AI 角色控制器：服务端权威决策，根据全局视野控制补位角色。
# 每物理帧向 AiInputSource 写入操作输入，与真人客户端输入包共用底层消费与执行流程。
# 核心行为：
# - 目标锁定：保持锁定当前目标，避免频繁切换目标造成抖动；
# - 射击机制：瞄准带有适度抖动散布，具备视线判定与节奏点射控制；
# - 移动决策：按距离分级执行追击、拉扯与横向移动，并具备防卡墙跳跃检测；
# - 随机相位：初始化时错开各 AI 实例的内部计时器与开火节奏，避免群体同频抖动。

const FIRE_RANGE := 620.0        # 最大开火距离（像素）
const APPROACH_DIST := 300.0     # 追击距离阈值
const BACKOFF_DIST := 140.0      # 后撤拉扯距离阈值
const AIM_JITTER := 0.10         # 瞄准抖动角度（弧度）
const TARGET_STICKY := 0.6       # 目标黏滞系数：新目标距离小于当前目标的一定比例时才切换
const STUCK_JUMP_TIME := 0.4     # 卡墙累计判定时间（秒），超时后触发跳跃

var host: Node            # MatchHost / RoyaleHost
var role := 0
var src: AiInputSource

var _t := 0.0
var _next_fire := 0.0
var _fire_left := 0.0
var _next_decide := 0.0
var _strafe := 1.0
var _target_role := 0     # 锁定目标角色编号（0 表示未锁定）
var _stuck_t := 0.0       # 卡墙累计时长


func _ready() -> void:
	# 错开各 AI 实例的初始决策与开火计时
	_t = randf_range(0.0, 10.0)
	_next_fire = _t + randf_range(0.3, 1.2)
	_next_decide = _t + randf_range(0.5, 1.5)


func _physics_process(delta: float) -> void:
	if src == null or host == null or not is_instance_valid(host):
		return
	# 倒计时或对局结束阶段保持待机
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


# 目标选取与锁定：优先维持当前目标，直至其失效或存在显著更近的有效目标。
# 返回字典包含：
# - node: 目标角色节点
# - dist: 环面距离
# - dir: 由自身指向目标的环面向量（未归一化）
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
		return {"node": cur, "dist": cur_dist, "dir": -d}   # 反向计算得到从自身指向目标的向量
	# 当前目标失效时寻找最近目标
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
	# 瞄准计算：计算朝向目标的向量并叠加微小随机旋转抖动
	src.aim = dir_to.normalized().rotated(randf_range(-AIM_JITTER, AIM_JITTER) * 0.4)
	# 开火判定：目标在射程内且具备无遮挡视线时触发点射
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
	# 移动决策：在决策周期内保持横移方向，避免逐帧转向抖动
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
	# 卡墙判定：具有移动意图但水平实际速度过低时，累计达阈值触发跳跃脱困
	if move != 0.0 and absf(p.velocity.x) < 12.0:
		_stuck_t += delta
	else:
		_stuck_t = 0.0
	if _stuck_t >= STUCK_JUMP_TIME:
		_stuck_t = 0.0
		src.press_jump()
	src.axis = move
