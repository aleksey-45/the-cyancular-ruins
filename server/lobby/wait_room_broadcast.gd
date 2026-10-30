class_name WaitRoomBroadcast
extends RefCounted

# 等待室状态广播的三种「同一件事」(2026-10-30 S-09 第三片:从 `LobbyRooms` 挪出;那里是 Node、引 NetBus,
#   三份 flush 各带一段同样的延帧注释,职责与 RPC handler 混在一起)。
#
# ★ 时序约定(逐字保留,别"优化"成同步发):
#   1) 调用方一律 `WaitRoomBroadcast.flush_*.call_deferred(lobby, room)` —— 帧末起步;
#   2) 体内 `await lobby.get_tree().process_frame` **再等一帧**;
#   3) 真正发送前再判一次 `in_match`/`started`。
#   原因:调用点几乎都在「刚有人断开」的路径上,断开信号还没被 MultiplayerAPI 处理完(实测滞后超过一帧),
#   同步发/帧末发都会踩 `max channels: 0` 且包会丢(6 人局开局瞬间实测 5 条)。
#
# ★ 本文件引用 autoload(NetBus/NetBusExt)⇒ **不可 `-s` 测**(与 lobby_rooms 同款),守卫边界登记在债单。

# 大乱斗等待室:{code, is_public, invite_code, max_players, host_role, players, in_match} + 每人一份 your_role。
static func flush_royale(lobby: LobbyRooms, rr: RoomTypes.Room) -> void:
	await lobby.get_tree().process_frame
	if rr.in_match:
		return
	var plist: Array = []
	for peer_id in rr.players:
		plist.append({"role": rr.player_role[peer_id], "name": lobby.peer_names.get(peer_id, "玩家")})
	var state := {
		"code": rr.code, "is_public": rr.is_public, "invite_code": rr.invite_code,
		"max_players": rr.max_players, "host_role": rr.player_role.get(rr.host_peer, 0),
		"players": plist, "in_match": rr.in_match,
	}
	for peer_id in rr.players:
		if NetBus.is_peer_online(peer_id):
			# ★ 每个 peer 送他自己那一份(多带 your_role):等待室 UI 靠它判「(我)/(房主)」—— 原先让客户端按昵称反查,
			# 两人同名(默认都叫 Anon)时必然匹配到先出现的那个 → 高亮错行、房主看不到开局按钮。
			var mine := state.duplicate()
			mine["your_role"] = rr.player_role[peer_id]
			NetBusExt.rpc_id(peer_id, "royale_room_state", mine)


# 1v1 等待室:{code, players:[{role,name}], host_role, in_match} + 每人一份 your_role。
static func flush_pvp(lobby: LobbyRooms, room: RoomTypes.Room) -> void:
	await lobby.get_tree().process_frame
	if room.in_match or room.started:
		return
	var plist: Array = []
	for peer_id in room.players:
		plist.append({"role": room.player_role[peer_id], "name": lobby.peer_names.get(peer_id, "玩家")})
	var host_role := 0
	if not room.players.is_empty():
		host_role = int(room.player_role.get(room.players[0], 0))
	var state := {"code": room.code, "players": plist, "host_role": host_role, "in_match": room.in_match}
	for peer_id in room.players:
		if NetBus.is_peer_online(peer_id):
			var mine := state.duplicate()
			mine["your_role"] = room.player_role[peer_id]
			NetBusExt.rpc_id(peer_id, "pvp_room_state", mine)


# 3v3 等待室/选边:{code, is_public, invite_code, host_role, team_size, players:[{role,name,team}], in_match} +
# 每人一份 your_role(与 royale 同款:同名玩家不能靠昵称反查)。
static func flush_team(lobby: LobbyRooms, tr: RoomTypes.Room) -> void:
	await lobby.get_tree().process_frame
	if tr.in_match:
		return
	var plist: Array = []
	for peer_id in tr.players:
		var role := int(tr.player_role[peer_id])
		plist.append({"role": role, "name": lobby.peer_names.get(peer_id, "玩家"),
				"team": int(tr.team_of.get(role, 0))})
	var state := {
		"code": tr.code, "is_public": tr.is_public, "invite_code": tr.invite_code,
		"host_role": tr.player_role.get(tr.host_peer, 0), "team_size": ModeDefs.TEAM_SIZE,
		"players": plist, "in_match": tr.in_match,
	}
	for peer_id in tr.players:
		if NetBus.is_peer_online(peer_id):
			var mine := state.duplicate()
			mine["your_role"] = tr.player_role[peer_id]
			NetBusExt.rpc_id(peer_id, "team_room_state", mine)