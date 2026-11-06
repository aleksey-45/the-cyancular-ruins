class_name RoomTypes
extends RefCounted



class Room:
	var mode: String = ""
	var code: String = ""
	var host_peer: int = 0
	var players: Array[int] = []
	var player_role: Dictionary = {}
	var in_match := false
	var worker_port: int = 0
	var worker_pid: int = 0
	var roster: Array = []
	var created_at: float = 0.0
	var is_public := true
	var invite_code := ""
	var team_of: Dictionary = {}
	var max_players := 0
	var beta := false
	var time_rules: Dictionary = {}
	var map := ""
	var match_time := 0

	# 1v1 的旧字段名:lobby_snapshot / rejoin_probe 读它、room_manager 写它。同一份值,不是第二份真相。
	var started: bool:
		get:
			return in_match
		set(value):
			in_match = value

	func is_duel() -> bool:
		return mode == ModeDefs.MODE_PVP

	func is_royale() -> bool:
		return mode == ModeDefs.MODE_ROYALE

	func is_team() -> bool:
		return mode == ModeDefs.MODE_TEAM



static func team_ready(by_team: Dictionary) -> bool:
	return (by_team.get(1, []) as Array).size() >= TeamRules.MIN_PER_TEAM \
			and (by_team.get(2, []) as Array).size() >= TeamRules.MIN_PER_TEAM


static func team_can_join(by_team: Dictionary, team: int, size: int = ModeDefs.TEAM_SIZE) -> bool:
	return (by_team.get(team, []) as Array).size() < size


static func team_next_role(used_roles: Array) -> int:
	var role := 1
	while used_roles.has(role):
		role += 1
	return role


# {队号: [role, …]} —— 判据的入参形状(单一来源,别在 handler 里另算一遍)。
static func by_team(room: Room) -> Dictionary:
	var out := {1: [], 2: []}
	for role in room.team_of:
		var t := int(room.team_of[role])
		if out.has(t):
			(out[t] as Array).append(int(role))
	return out


static func team_room_ready(room: Room) -> bool:
	return team_ready(by_team(room))


static func team_autofill(room: Room) -> Dictionary:
	var out := {}
	var unassigned: Array = []
	for role in room.player_role.values():
		var r := int(role)
		var t := int(room.team_of.get(r, 0))
		if t == 1 or t == 2:
			out[r] = t
		else:
			unassigned.append(r)
	unassigned.sort()
	var counts := {1: 0, 2: 0}
	for r in out:
		counts[int(out[r])] = int(counts[int(out[r])]) + 1
	for r in unassigned:
		var pick := 1 if int(counts[1]) <= int(counts[2]) else 2
		out[int(r)] = pick
		counts[pick] = int(counts[pick]) + 1
	return out


# 列表载荷里的三档人数。★ 键必须是字符串:客户端 `room_list.gd` 按 `"1"/"2"/"0"` 读(读取契约;
# RPC 的 Variant 编码保不住 int 键)—— 从 room_registry 挪来的同一份实现。
static func team_counts_of(room: Room) -> Dictionary:
	var counts := {"1": 0, "2": 0, "0": 0}
	for role in room.player_role.values():
		var t := int(room.team_of.get(int(role), 0))
		var k := str(t if t == 1 or t == 2 else 0)
		counts[k] = int(counts[k]) + 1
	return counts


