class_name ServerStatus
extends RefCounted


const WL := preload("res://server/lobby/worker_launcher.gd")

const STATE_WAITING := "waiting"
const STATE_IN_MATCH := "in_match"
const STATE_STALE := "stale"


static func build(rooms: Array[Dictionary], ports: Array[Dictionary], now_unix: float) -> Dictionary:
	var out_rooms: Array[Dictionary] = []
	var n_waiting := 0
	var n_in_match := 0
	var lobby_players := 0
	for r in rooms:
		var entry := r.duplicate()
		var port := int(r.get("worker_port", 0))
		var pid := int(r.get("worker_pid", 0))
		var alive := _alive_of(ports, port)
		var started := bool(r.get("in_match", false))
		var roster: Array = r.get("roster", [])
		var state := STATE_WAITING
		if started:
			state = STATE_STALE if (port > 0 and pid > 0 and not alive) else STATE_IN_MATCH
		if state == STATE_WAITING:
			n_waiting += 1
			lobby_players += int(r.get("players", 0))
		else:
			n_in_match += 1
		entry["state"] = state
		entry["age_sec"] = maxf(0.0, now_unix - float(r.get("created_at", now_unix)))
		entry["worker_alive"] = alive
		entry["online_known"] = (state == STATE_WAITING)
		entry["players"] = int(r.get("players", 0)) if state == STATE_WAITING else roster.size()
		out_rooms.append(entry)

	var workers_alive := 0
	for p in ports:
		if bool(p.get("alive", false)):
			workers_alive += 1

	return {
		"counts": {
			"rooms": out_rooms.size(),
			"waiting": n_waiting,
			"in_match": n_in_match,
			"lobby_players": lobby_players,
			"workers_alive": workers_alive,
			"ports_used": ports.size(),
			# ★ 单一来源:不写 500。
			"ports_total": WL.WORKER_PORT_SPAN,
		},
		"rooms": out_rooms,
		"ports": ports.duplicate(),
	}


static func _alive_of(ports: Array[Dictionary], port: int) -> bool:
	if port <= 0:
		return false
	for p in ports:
		if int(p.get("port", -1)) == port:
			return bool(p.get("alive", false))
	return false



static func row_key(kind: String, code: String) -> String:
	return "%s/%s" % [kind, code]


static func can_close(armed_code: String, armed_kind: String,
		sel_code: String, sel_kind: String) -> bool:
	return armed_code != "" and armed_code == sel_code and armed_kind == sel_kind


static func host_of(in_match: bool, host_peer: int, host_role: int, frozen: Array,
		live_names: Dictionary) -> String:
	if not in_match:
		return str(live_names.get(host_peer, "玩家"))
	for e in frozen:
		if typeof(e) == TYPE_DICTIONARY and int((e as Dictionary).get("role", 0)) == host_role:
			return str((e as Dictionary).get("name", "玩家"))
	return "玩家"


static func host_and_roster(is_duel: bool, in_match: bool, host_peer: int, host_role: int,
		frozen: Array, players: Array, roles: Dictionary, live_names: Dictionary) -> Dictionary:
	var names: Array = []
	for e in roster_of(in_match, frozen, players, roles, live_names):
		names.append(str((e as Dictionary).get("name", "玩家")))
	var host := "玩家"
	if is_duel:
		if not players.is_empty():
			host = str(live_names.get(players[0], "玩家"))
		elif not frozen.is_empty():
			host = str((frozen[0] as Dictionary).get("name", "玩家"))
	else:
		host = host_of(in_match, host_peer, host_role, frozen, live_names)
	return {"host": host, "names": names}


static func roster_of(in_match: bool, frozen: Array, players: Array, roles: Dictionary,
		live_names: Dictionary) -> Array:
	var out: Array = []
	if in_match:
		for e in frozen:
			if typeof(e) == TYPE_DICTIONARY:
				out.append({"role": int((e as Dictionary).get("role", 0)),
						"name": str((e as Dictionary).get("name", "玩家"))})
		return out
	for pid in players:
		out.append({"role": int(roles.get(pid, 0)), "name": str(live_names.get(pid, "玩家"))})
	return out
