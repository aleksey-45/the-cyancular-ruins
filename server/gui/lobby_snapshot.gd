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
			"host": lobby.host_name_of(r),
			"map": str(r.map),
			"worker_port": int(r.worker_port),
			"worker_pid": int(r.worker_pid),
			"created_at": float(r.created_at),
			"roster": lobby.display_roster_of(r),
		})
	for code in lobby.royale_rooms:
		var rr: LobbyRooms.RoyaleRoom = lobby.royale_rooms[code]
		out.append({
			"kind": "royale",
			"code": str(rr.code),
			"players": rr.players.size(),
			"cap": int(rr.max_players),
			"in_match": rr.in_match,
			"host": lobby.host_name_of(rr),
			"map": str(rr.map),
			"worker_port": int(rr.worker_port),
			"worker_pid": int(rr.worker_pid),
			"created_at": float(rr.created_at),
			"roster": lobby.display_roster_of(rr),
		})
	for code in lobby.team_rooms:
		var tr: LobbyRooms.TeamRoom = lobby.team_rooms[code]
		out.append({
			"kind": "team",
			"code": str(tr.code),
			"players": tr.players.size(),
			"cap": LobbyRooms.TEAM_ROLES,
			"in_match": tr.in_match,
			"host": lobby.host_name_of(tr),
			"map": str(tr.map),
			"worker_port": int(tr.worker_port),
			"worker_pid": int(tr.worker_pid),
			"created_at": float(tr.created_at),
			"roster": lobby.display_roster_of(tr),
		})
	return out

