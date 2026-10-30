class_name LobbySnapshot
extends RefCounted

# 服务端控制台的适配层:把大厅进程里的三张注册表读成 ServerStatus.build() 要的纯字典。
# ★ 这里只有字段搬运,没有判据 —— 判据(state / 人数口径 / 房龄)全在 server_status.gd;
#   搬进来一份就是第二份真相。
# ★ 本文件不能被 -s 冒烟引用:它引用 LobbyRooms,而 lobby_rooms.gd 引用 NetBus(spec §6.1)。
#   ⇒ 它零守卫,靠评审(已登记进 registered-debt)。判据逻辑务必留在 server_status.gd,别挪进来。


static func collect(lobby: LobbyRooms) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	# 1v1 房:没有 host_peer 字段(建房者 = players[0]),容量恒 2
	for code in lobby.rooms:
		var r: LobbyRooms.Room = lobby.rooms[code]
		out.append({
			"kind": "1v1",
			"code": str(r.code),
			"players": r.players.size(),
			"cap": 2,
			"in_match": r.started,
			"host": host_of(lobby, r),
			"map": str(r.map),
			"worker_port": int(r.worker_port),
			"worker_pid": int(r.worker_pid),
			"created_at": float(r.created_at),
			"roster": roster_of(lobby, r),
		})
	for code in lobby.royale_rooms:
		var rr: LobbyRooms.RoyaleRoom = lobby.royale_rooms[code]
		out.append({
			"kind": "royale",
			"code": str(rr.code),
			"players": rr.players.size(),
			"cap": int(rr.max_players),
			"in_match": rr.in_match,
			"host": host_of(lobby, rr),
			"map": str(rr.map),
			"worker_port": int(rr.worker_port),
			"worker_pid": int(rr.worker_pid),
			"created_at": float(rr.created_at),
			"roster": roster_of(lobby, rr),
		})
	for code in lobby.team_rooms:
		var tr: LobbyRooms.TeamRoom = lobby.team_rooms[code]
		out.append({
			"kind": "team",
			"code": str(tr.code),
			"players": tr.players.size(),
			"cap": LobbyRooms.TEAM_ROLES,
			"in_match": tr.in_match,
			"host": host_of(lobby, tr),
			"map": str(tr.map),
			"worker_port": int(tr.worker_port),
			"worker_pid": int(tr.worker_pid),
			"created_at": float(tr.created_at),
			"roster": roster_of(lobby, tr),
		})
	return out



# ── 面板读模型(2026-10-30 S-09:从 `LobbyRooms` 挪来;本文件本来就是"把大厅读成纯字典"的适配层)──
# ★ 这里仍只有字段搬运,判据在 `ServerStatus.host_and_roster` / `roster_of`(纯函数、`-s` 可测)。

static func host_of(lobby: LobbyRooms, room: Variant) -> String:
	var r := room as RoomTypes.Room
	if r == null:
		return "玩家"
	return str(ServerStatus.host_and_roster(r.is_duel(), r.in_match, r.host_peer,
			int(r.player_role.get(r.host_peer, 0)), r.roster, r.players, r.player_role,
			lobby.peer_names)["host"])


static func roster_of(lobby: LobbyRooms, room: Variant) -> Array:
	var r := room as RoomTypes.Room
	if r == null:
		return []
	return ServerStatus.roster_of(r.in_match, r.roster, r.players, r.player_role, lobby.peer_names)


# 服务端控制台用:按 (房号, 种类) 精确取房对象;只读,找不到返回 null。
# ★ 房号空间跨模式重叠(都是 4 位号)⇒ 只按 code 查会查到另一模式的同号房,故必须带 kind。
# ★ 拆除仍必须走 teardown_room 单一收口 —— 本函数不改变任何状态。
static func room_for_panel(lobby: LobbyRooms, code: String, kind: String) -> Variant:
	match kind:
		"1v1":
			return lobby.registry.find(code, ModeDefs.MODE_PVP)
		"royale":
			return lobby.registry.find(code, ModeDefs.MODE_ROYALE)
		"team":
			return lobby.registry.find(code, ModeDefs.MODE_TEAM)
	return null