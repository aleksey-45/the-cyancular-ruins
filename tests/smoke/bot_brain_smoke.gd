extends SceneTree

# Bot 纯逻辑守卫(观察 + 决策)。跑法:"$GODOT" --headless --path . -s res://tests/smoke/bot_brain_smoke.gd

const EXPECTED_CHECKS := 25
const Obs := preload("res://tests/harness/bot/bot_observation.gd")
const Brain := preload("res://tests/harness/bot/bot_brain.gd")

const MAP := Vector2(9600, 6400)

var _fails: Array[String] = []
var _checks := 0


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)


func _initialize() -> void:
	_check_relations()
	_check_view()
	_check_radar()
	_check_build()
	_check_brain()
	if _checks < EXPECTED_CHECKS:
		_fails.append("条数闸:%d < %d(有断言没跑到)" % [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("BOT BRAIN ALL-OK (%d checks)" % _checks)
		quit(0)
		return
	for f in _fails:
		printerr("FAIL: " + f)
	print("BOT BRAIN FAIL (%d/%d)" % [_checks, EXPECTED_CHECKS])
	quit(1)


func _check_relations() -> void:
	_chk(Obs.relation_of(2, 1, "team", {1: 1, 2: 2}) == Obs.REL_ENEMY, "对抗:异队是敌人")
	_chk(Obs.relation_of(3, 1, "team", {1: 1, 3: 1}) == Obs.REL_ALLY, "对抗:同队是队友")
	_chk(Obs.relation_of(2, 1, "team", {1: 1}) == Obs.REL_UNKNOWN, "队伍表缺 ⇒ unknown,不猜")
	_chk(Obs.relation_of(2, 1, "royale", {}) == Obs.REL_ENEMY, "大乱斗:其余都是敌人")


func _check_view() -> void:
	_chk(Obs.in_view(Vector2(100, 100), Vector2(200, 100), Vector2(400, 400), MAP),
			"主画面:范围内的点入画")
	_chk(Obs.in_view(Vector2(MAP.x - 100, 100), Vector2(100, 100), Vector2(400, 400), MAP),
			"主画面:接缝另一侧按最短向量仍入画")
	_chk(not Obs.in_view(Vector2(2000, 100), Vector2(100, 100), Vector2(400, 400), MAP),
			"主画面:范围外的点不入画")


func _check_radar() -> void:
	_chk(Obs.in_radar(Vector2(1000, 100), Vector2(100, 100), 900.0, MAP),
			"雷达:半径内")
	_chk(Obs.in_radar(Vector2(MAP.x - 50, 100), Vector2(100, 100), 200.0, MAP),
			"雷达:自身贴接缝时对面近处的点仍可见")
	_chk(not Obs.in_radar(Vector2(2000, 100), Vector2(100, 100), 900.0, MAP),
			"雷达:半径外不可见")


func _ctx(now: float) -> Dictionary:
	return {
		"my_role": 1, "mode": "team", "teams": {1: 1, 2: 2, 3: 1},
		"self_pos": Vector2.ZERO, "cam_center": Vector2.ZERO,
		"view_size": Vector2(400, 400), "map_size": MAP,
		"radar_radius_px": 1500.0, "radar_uncertainty_px": 22.0,
		"now": now, "memory_ttl": 3.0,
	}


func _check_build() -> void:
	var mem := {}
	var cands := [
		{"role": 2, "pos": Vector2(100, 0)},       # 主画面
		{"role": 3, "pos": Vector2(1000, 0)},      # 雷达内、画面外
		{"role": 4, "pos": Vector2(5000, 0)},      # 都不可见,无记忆 ⇒ 丢弃
	]
	var o1: Array = Obs.build(cands, _ctx(10.0), mem)
	_chk(o1.size() == 2, "build:看不见且无记忆的角色不产出观察")
	_chk(_find(o1, 2).get("source", "") == Obs.SOURCE_VIEW, "build:主画面来源优先")
	_chk(_find(o1, 3).get("source", "") == Obs.SOURCE_RADAR, "build:画面外雷达内走雷达来源")
	_chk(float(_find(o1, 3).get("uncertainty", 0.0)) > 0.0, "build:雷达来源必须带位置不确定性")

	# 角色仍在快照里(候选里还有它)但已离开画面/雷达 ⇒ 只能走记忆来源。
	var o2: Array = Obs.build([
		{"role": 2, "pos": Vector2(100, 0)},
		{"role": 3, "pos": Vector2(5000, 0)},
	], _ctx(11.0), mem)
	var m3 := _find(o2, 3)
	_chk(m3.get("source", "") == Obs.SOURCE_MEMORY, "build:短暂消失但仍可见过的角色走记忆来源")
	_chk(float(m3.get("uncertainty", 0.0)) > 22.0, "build:记忆来源的不确定性应更大")
	var o3: Array = Obs.build([
		{"role": 2, "pos": Vector2(100, 0)},
		{"role": 3, "pos": Vector2(5000, 0)},
	], _ctx(15.0), mem)
	_chk(_find(o3, 3).is_empty(), "build:记忆过期后不再产出观察")


func _check_brain() -> void:
	var frozen := Brain.decide([], {"can_act": false}, {})
	_chk(frozen["axis"] == 0.0 and not frozen["fire"], "决策:不可行动时输入归零")

	var bctx := {
		"can_act": true, "self_pos": Vector2.ZERO, "self_vx": 0.0,
		"now": 10.0, "delta": 1.0 / 60.0,
		"fire_range_px": 620.0, "preferred_range_px": 300.0, "backoff_px": 140.0,
		"map_size": MAP,
	}
	var st := {}
	var obs: Array = [
		_obs(2, "radar", Vector2(100, 0)),
		_obs(3, "radar", Vector2(500, 0)),
	]
	var it: Dictionary = Brain.decide(obs, bctx, st)
	_chk(int(st.get("target_role", 0)) == 2, "决策:多敌人时选评分更高的近者")
	_chk(bool(it["fire"]), "决策:射程内且有可见来源时开火")
	_chk((it["aim"] as Vector2).dot(Vector2.RIGHT) > 0.99, "决策:瞄准方向指向目标")

	var st_h := {"target_role": 3}
	var near: Array = [
		_obs(2, "radar", Vector2(100, 0)),
		_obs(3, "radar", Vector2(170, 0)),
	]
	Brain.decide(near, bctx, st_h)
	_chk(int(st_h.get("target_role", 0)) == 3, "决策:新目标未明显更优时不切换(滞回)")

	var st_mem := {}
	var mem_obs: Array = [_obs(2, "memory", Vector2(100, 0))]
	var it_mem: Dictionary = Brain.decide(mem_obs, bctx, st_mem)
	_chk(not bool(it_mem["fire"]), "决策:只凭记忆位置不开火")

	var it_search: Dictionary = Brain.decide([], bctx, {})
	_chk(float(it_search["axis"]) != 0.0 and str(it_search["reason"]).begins_with("search"),
			"决策:无敌人时主动搜索而不是原地不动")

	var st_stuck := {}
	var jumped := false
	for i in 30:
		var it_j: Dictionary = Brain.decide([_obs(2, "radar", Vector2(100, 0))], bctx, st_stuck)
		if bool(it_j["jump"]):
			jumped = true
			break
	_chk(jumped, "决策:想动但无水平速度持续 0.4s ⇒ 跳一次(兜高台/边缘)")


func _obs(role: int, source: String, pos: Vector2) -> Dictionary:
	return {"role": role, "source": source, "relation": Obs.REL_ENEMY, "pos": pos,
			"time": 10.0, "uncertainty": 22.0, "seen_action": ""}


func _find(arr: Array, role: int) -> Dictionary:
	for o in arr:
		if int(o.get("role", 0)) == role:
			return o
	return {}
