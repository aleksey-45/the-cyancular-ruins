extends RefCounted

# 纯决策:Observation[] + 上下文 / 状态 → Intent。不碰节点、不读全局。

const Geo := preload("res://core/sim/grid_pathfinder.gd")

const REL_ENEMY := "enemy"
const SOURCE_VIEW := "view"
const SOURCE_MEMORY := "memory"

const SWITCH_MARGIN := 80.0     # 新目标必须比当前好这么多才换(防来回切)
const STUCK_SPEED := 12.0       # 想动但水平速度低于它 = 可能卡住
const STUCK_JUMP_TIME := 0.4    # 卡住累计这么久才跳一次(防原地连跳)
const STRAFE_FLIP := 1.5
const ROAM_FLIP := 2.5


static func neutral(reason: String) -> Dictionary:
	return {"axis": 0.0, "jump": false, "aim": Vector2.ZERO, "fire": false,
			"reload": false, "switch_to": 0, "pickup": false, "reason": reason}


static func decide(obs: Array, ctx: Dictionary, state: Dictionary) -> Dictionary:
	if not bool(ctx.get("can_act", false)):
		return neutral("frozen")
	var self_pos: Vector2 = ctx.get("self_pos", Vector2.ZERO)
	var delta := float(ctx.get("delta", 0.0))
	var enemies := _enemies(obs)
	if enemies.is_empty():
		return _search(ctx, state, self_pos, delta)
	var map_size: Vector2 = ctx.get("map_size", Vector2.ONE)
	var target := _choose_target(enemies, state, self_pos, map_size)
	var tp: Vector2 = target["pos"]
	var dir := Geo.toroidal_delta_px(self_pos, tp, map_size.x, map_size.y)
	var dist := dir.length()
	state["target_role"] = int(target["role"])
	state["last_seen"] = tp
	var intent := neutral("engage role=%d source=%s dist=%.0f" % [
			int(target["role"]), str(target["source"]), dist])
	if dir.length_squared() > 1.0:
		intent["aim"] = dir.normalized()
	var fire_ok := str(target.get("source", "")) != SOURCE_MEMORY
	return _with_move(intent, ctx, state, dir, dist, delta, fire_ok)


static func _enemies(obs: Array) -> Array:
	var out: Array = []
	for o in obs:
		if str(o.get("relation", "")) == REL_ENEMY:
			out.append(o)
	return out


# 评分 = 越近越好 + 主画面来源加成;滞回:当前目标仍可选且新目标没有明显更好就不换。
static func _choose_target(enemies: Array, state: Dictionary, self_pos: Vector2,
		map_size: Vector2) -> Dictionary:
	var best: Dictionary = enemies[0]
	var best_score := -INF
	for e in enemies:
		var s := _score(e, self_pos, map_size)
		if s > best_score:
			best_score = s
			best = e
	var cur_role := int(state.get("target_role", 0))
	for e in enemies:
		if int(e.get("role", 0)) == cur_role:
			var cur_score := _score(e, self_pos, map_size)
			if best_score <= cur_score + SWITCH_MARGIN:
				return e
			break
	return best


# _choose_target 需要自身位置与地图尺寸,由 decide 通过参数传入(不改 state 形状)。
static func _score(e: Dictionary, self_pos: Vector2, map_size: Vector2) -> float:
	var d := Geo.toroidal_delta_px(self_pos, e.get("pos", self_pos), map_size.x, map_size.y)
	var s := -d.length()
	if str(e.get("source", "")) == SOURCE_VIEW:
		s += 200.0
	return s


static func _with_move(intent: Dictionary, ctx: Dictionary, state: Dictionary,
		dir: Vector2, dist: float, delta: float, fire_ok: bool) -> Dictionary:
	var preferred := float(ctx.get("preferred_range_px", 300.0))
	var backoff := float(ctx.get("backoff_px", 140.0))
	var axis := 0.0
	if dist > preferred:
		axis = signf(dir.x)
	elif dist < backoff:
		axis = -signf(dir.x)
	else:
		state["strafe_t"] = float(state.get("strafe_t", 0.0)) + delta
		if state["strafe_t"] >= STRAFE_FLIP:
			state["strafe_t"] = 0.0
			state["strafe"] = -float(state.get("strafe", 1.0))
		if absf(dir.x) > 15.0:
			state["strafe"] = -signf(dir.x)
		axis = state.get("strafe", 1.0)
	intent["axis"] = axis
	intent["fire"] = fire_ok and dist <= float(ctx.get("fire_range_px", 620.0))
	# 卡住:想动但没速度 ⇒ 累计够久跳一次(≤1 格台阶已由 StepJump 自动处理,这里只兜高台/边缘)
	if axis != 0.0 and absf(float(ctx.get("self_vx", 0.0))) < STUCK_SPEED:
		state["stuck_t"] = float(state.get("stuck_t", 0.0)) + delta
		if float(state["stuck_t"]) >= STUCK_JUMP_TIME:
			state["stuck_t"] = 0.0
			intent["jump"] = true
	else:
		state["stuck_t"] = 0.0
	return intent


static func _search(ctx: Dictionary, state: Dictionary, self_pos: Vector2,
		delta: float) -> Dictionary:
	var map_size: Vector2 = ctx.get("map_size", Vector2.ONE)
	var last: Vector2 = state.get("last_seen", Vector2.ZERO)
	var intent := neutral("search")
	if last != Vector2.ZERO:
		var d := Geo.toroidal_delta_px(self_pos, last, map_size.x, map_size.y)
		if d.length() > 24.0:
			intent["axis"] = signf(d.x)
			intent["aim"] = d.normalized()
			intent["reason"] = "search_last_seen"
			return intent
	state["roam_t"] = float(state.get("roam_t", 0.0)) + delta
	if state["roam_t"] >= ROAM_FLIP:
		state["roam_t"] = 0.0
		state["roam"] = -float(state.get("roam", 1.0))
	intent["axis"] = state.get("roam", 1.0)
	intent["aim"] = Vector2(float(intent["axis"]), 0.0)
	intent["reason"] = "search_roam"
	return intent
