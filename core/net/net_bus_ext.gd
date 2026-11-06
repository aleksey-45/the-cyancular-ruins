extends Node

# 实验分支扩展协议(autoload,与原版 NetBus 刻意分离):实测改动原 NetBus 的方法表(改签名/插新方法)会让与原版大厅的 RPC 全部失联。
# ⇒ 原 NetBus 逐字节一致,实验新增 RPC 全放本节点;对原版 worker 本节点不存在 ⇒ 扩展 RPC 静默丢弃、优雅降级(选项不生效,对局照常)。

signal local_match_options(opts: Dictionary)
signal local_hit_confirm(shooter_role: int, victim_role: int)
signal player_options_received(caller: int, opts: Dictionary)

@rpc("any_peer", "call_remote", "reliable", 0)
func player_options(opts: Dictionary) -> void:
	player_options_received.emit(multiplayer.get_remote_sender_id(), opts)

@rpc("authority", "call_remote", "reliable", 0)
func match_options(opts: Dictionary) -> void:
	local_match_options.emit(opts)

@rpc("authority", "call_remote", "reliable", 3)
func hit_confirm(shooter_role: int, victim_role: int) -> void:
	local_hit_confirm.emit(shooter_role, victim_role)

signal suicide_requested(caller: int)

@rpc("any_peer", "call_remote", "reliable", 0)
func suicide_request() -> void:
	suicide_requested.emit(multiplayer.get_remote_sender_id())


signal royale_create_requested(caller: int, opts: Dictionary)
signal royale_join_requested(caller: int, code: String, invite: String, beta: bool)
signal royale_leave_requested(caller: int)
signal royale_list_requested(caller: int, token: String)
signal royale_start_requested(caller: int)
signal ai_duel_requested(caller: int)
signal royale_start_ai_requested(caller: int)
signal local_royale_rooms(rooms: Array)
signal local_royale_room_state(state: Dictionary)

@rpc("any_peer", "call_remote", "reliable", 0)
func royale_create(opts: Dictionary) -> void:
	royale_create_requested.emit(multiplayer.get_remote_sender_id(), opts)

@rpc("any_peer", "call_remote", "reliable", 0)
func royale_join(code: String, invite: String, beta: bool) -> void:
	royale_join_requested.emit(multiplayer.get_remote_sender_id(), code, invite, beta)

@rpc("any_peer", "call_remote", "reliable", 0)
func royale_leave() -> void:
	royale_leave_requested.emit(multiplayer.get_remote_sender_id())

@rpc("any_peer", "call_remote", "reliable", 0)
func royale_list(token: String) -> void:
	royale_list_requested.emit(multiplayer.get_remote_sender_id(), token)

@rpc("any_peer", "call_remote", "reliable", 0)
func royale_start() -> void:
	royale_start_requested.emit(multiplayer.get_remote_sender_id())

@rpc("any_peer", "call_remote", "reliable", 0)
func ai_duel() -> void:
	ai_duel_requested.emit(multiplayer.get_remote_sender_id())

@rpc("any_peer", "call_remote", "reliable", 0)
func royale_start_ai() -> void:
	royale_start_ai_requested.emit(multiplayer.get_remote_sender_id())

@rpc("authority", "call_remote", "reliable", 0)
func royale_rooms(rooms: Array) -> void:
	local_royale_rooms.emit(rooms)


signal local_sub_destroyed(sub: Vector2i, seq: int)


@rpc("authority", "call_remote", "reliable", 3)
func sub_destroyed(sub: Vector2i, seq: int) -> void:
	local_sub_destroyed.emit(sub, seq)


signal local_time_state(payload: Dictionary)


@rpc("authority", "call_remote", "reliable", 2)
func time_state(payload: Dictionary) -> void:
	local_time_state.emit(payload)

@rpc("authority", "call_remote", "reliable", 2)
func royale_room_state(state: Dictionary) -> void:
	local_royale_room_state.emit(state)

signal local_pvp_room_state(state: Dictionary)

@rpc("authority", "call_remote", "reliable", 0)
func pvp_room_state(state: Dictionary) -> void:
	local_pvp_room_state.emit(state)

signal pvp_start_requested(caller: int)

@rpc("any_peer", "call_remote", "reliable", 0)
func pvp_start() -> void:
	pvp_start_requested.emit(multiplayer.get_remote_sender_id())

# ── 3v3 团队大厅(与 1v1 / 大乱斗三套协议并存;RPC 名不同互不干扰)。★ 命名纪律:一律带 team_ 前缀(既避开 NetBus 方法表,也避开 royale_* 同名 = 挂错节点 = 静默 no-op)。
# ★ 选边(team_pick)是 3v3 独有的上行:队伍不由服务器推导(role 号有空洞),玩家自己点。

signal team_create_requested(caller: int, opts: Dictionary)
signal team_join_requested(caller: int, code: String, invite: String, beta: bool)
signal team_pick_requested(caller: int, team: int)
signal team_leave_requested(caller: int)
signal team_start_requested(caller: int)
signal team_list_requested(caller: int, token: String)
signal local_team_rooms(rooms: Array)
signal local_team_room_state(state: Dictionary)

@rpc("any_peer", "call_remote", "reliable", 0)
func team_create(opts: Dictionary) -> void:
	team_create_requested.emit(multiplayer.get_remote_sender_id(), opts)

@rpc("any_peer", "call_remote", "reliable", 0)
func team_join(code: String, invite: String, beta: bool) -> void:
	team_join_requested.emit(multiplayer.get_remote_sender_id(), code, invite, beta)

@rpc("any_peer", "call_remote", "reliable", 0)
func team_pick(team: int) -> void:
	team_pick_requested.emit(multiplayer.get_remote_sender_id(), team)

@rpc("any_peer", "call_remote", "reliable", 0)
func team_leave() -> void:
	team_leave_requested.emit(multiplayer.get_remote_sender_id())

@rpc("any_peer", "call_remote", "reliable", 0)
func team_start() -> void:
	team_start_requested.emit(multiplayer.get_remote_sender_id())

@rpc("any_peer", "call_remote", "reliable", 0)
func team_list(token: String) -> void:
	team_list_requested.emit(multiplayer.get_remote_sender_id(), token)

@rpc("authority", "call_remote", "reliable", 0)
func team_rooms(rooms: Array) -> void:
	local_team_rooms.emit(rooms)

@rpc("authority", "call_remote", "reliable", 2)
func team_room_state(state: Dictionary) -> void:
	local_team_room_state.emit(state)

signal room_map_requested(caller: int, code: String, path: String)

@rpc("any_peer", "call_remote", "reliable", 0)
func room_map(code: String, path: String) -> void:
	room_map_requested.emit(multiplayer.get_remote_sender_id(), code, path)

# ── 断线重连:全部进本节点(理由见文件头:原 NetBus 的方法表一律不动)。对原版 worker 本节点不存在 ⇒ 这三条静默丢弃,优雅降级成"不能重连"。
# 一次性会话令牌由大厅生成、在客户端转连 worker 之前下发(必须早于 go_match —— go_match 一到客户端就 NetBus.stop() 断大厅,之后再发就丢了)。
signal local_session_token(token: String)

@rpc("authority", "call_remote", "reliable", 0)
func session_token(token: String) -> void:
	local_session_token.emit(token)

signal token_reported(caller: int, token: String)

@rpc("any_peer", "call_remote", "reliable", 0)
func report_token(token: String) -> void:
	token_reported.emit(multiplayer.get_remote_sender_id(), token)

signal reclaim_requested(caller: int, role: int, token: String, proto: int)

@rpc("any_peer", "call_remote", "reliable", 0)
func reclaim_role(role: int, token: String, proto: int) -> void:
	reclaim_requested.emit(multiplayer.get_remote_sender_id(), role, token, proto)

signal rejoin_requested(caller: int, code: String, token: String, mode: String)

@rpc("any_peer", "call_remote", "reliable", 0)
func rejoin_request(code: String, token: String, mode: String) -> void:
	rejoin_requested.emit(multiplayer.get_remote_sender_id(), code, token, mode)

signal local_rejoin_denied(reason: String)

@rpc("authority", "call_remote", "reliable", 0)
func rejoin_denied(reason: String) -> void:
	local_rejoin_denied.emit(reason)

signal local_explosion(pos: Vector2, shooter_role: int, visual: String)

@rpc("authority", "call_remote", "reliable", 3)
func explosion(pos: Vector2, shooter_role: int, visual: String) -> void:
	local_explosion.emit(pos, shooter_role, visual)