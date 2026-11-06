class_name WaitRoomBroadcast
extends RefCounted


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
			var mine := state.duplicate()
			mine["your_role"] = rr.player_role[peer_id]
			NetBusExt.rpc_id(peer_id, "royale_room_state", mine)


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