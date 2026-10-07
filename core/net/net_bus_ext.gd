extends Node

# 网络总线扩展协议（全局单例节点）。
# 独立承载新增的 RPC 方法定义，保持原版 NetBus 接口不变，提供向前兼容与降级保护。
# 包含对局自定义配置、角色色相外观、命中确认反馈、即时光束开火同步、大乱斗与团队模式大厅协议及断线重连握手。

signal local_match_options(opts: Dictionary)      # 服务端下发生效的对局选项
signal local_peer_hues(hues: Dictionary)          # 服务端下发各玩家角色色相配置
signal local_hit_confirm(shooter_role: int, victim_role: int)  # 服务端向射手客户端反馈直接命中事件
signal player_options_received(caller: int, opts: Dictionary)  # 服务端接收客户端上报的偏好选项

# 客户端向服务端上报本端配置选项（角色色相与规则偏好，权威规则以房主为准）。
@rpc("any_peer", "reliable")
func player_options(opts: Dictionary) -> void:
	player_options_received.emit(multiplayer.get_remote_sender_id(), opts)

# 服务端向客户端广播生效的对局规则（禁用武器列表、回合满血等）。
@rpc("authority", "reliable")
func match_options(opts: Dictionary) -> void:
	local_match_options.emit(opts)

# 服务端向客户端广播双方角色色相角度字典。
@rpc("authority", "reliable")
func peer_hues(hues: Dictionary) -> void:
	local_peer_hues.emit(hues)

# 服务端向射手客户端下发直接命中确认（仅对直击弹道生效，范围爆炸不触发）。
@rpc("authority", "reliable")
func hit_confirm(shooter_role: int, victim_role: int) -> void:
	local_hit_confirm.emit(shooter_role, victim_role)

# 即时光束武器视觉同步：服务端开火后向其他客户端广播折线路径与视觉参数。
signal local_beam_fired(data: Dictionary)

@rpc("authority", "reliable")
func beam_fired(data: Dictionary) -> void:
	local_beam_fired.emit(data)

# 客户端向服务端请求自杀脱困（大乱斗模式受困时重置）。
signal suicide_requested(caller: int)

@rpc("any_peer", "reliable")
func suicide_request() -> void:
	suicide_requested.emit(multiplayer.get_remote_sender_id())

# 大乱斗大厅协议信号：
signal royale_create_requested(caller: int, opts: Dictionary)
signal royale_join_requested(caller: int, code: String, invite: String, beta: bool)
signal royale_leave_requested(caller: int)
signal royale_list_requested(caller: int, token: String)
signal royale_start_requested(caller: int)
signal ai_duel_requested(caller: int)             # 1v1 请求与 AI 对战
signal royale_start_ai_requested(caller: int)     # 大乱斗请求 AI 补位开局
signal local_royale_rooms(rooms: Array)           # 公开大乱斗房间列表更新
signal local_royale_room_state(state: Dictionary) # 所在等待房间实时状态更新

# 客户端向大厅请求创建大乱斗房间。
@rpc("any_peer", "reliable")
func royale_create(opts: Dictionary) -> void:
	royale_create_requested.emit(multiplayer.get_remote_sender_id(), opts)

# 客户端向大厅请求加入大乱斗房间（私密房间需携带邀请码）。
@rpc("any_peer", "reliable")
func royale_join(code: String, invite: String, beta: bool) -> void:
	royale_join_requested.emit(multiplayer.get_remote_sender_id(), code, invite, beta)

# 客户端向大厅请求退出当前大乱斗房间。
@rpc("any_peer", "reliable")
func royale_leave() -> void:
	royale_leave_requested.emit(multiplayer.get_remote_sender_id())

# 客户端向大厅请求大乱斗房间列表。携带本端会话凭据以支持私密重连房间可见性。
@rpc("any_peer", "reliable")
func royale_list(token: String) -> void:
	royale_list_requested.emit(multiplayer.get_remote_sender_id(), token)

# 房主向大厅请求开始大乱斗对局。
@rpc("any_peer", "reliable")
func royale_start() -> void:
	royale_start_requested.emit(multiplayer.get_remote_sender_id())

# 1v1 房主请求与 AI 对战。
@rpc("any_peer", "reliable")
func ai_duel() -> void:
	ai_duel_requested.emit(multiplayer.get_remote_sender_id())

# 大乱斗房主请求使用 AI 补位开局。
@rpc("any_peer", "reliable")
func royale_start_ai() -> void:
	royale_start_ai_requested.emit(multiplayer.get_remote_sender_id())

# 大厅向客户端广播公开房间列表。
@rpc("authority", "reliable")
func royale_rooms(rooms: Array) -> void:
	local_royale_rooms.emit(rooms)


# 瓦片子格破坏与时间状态广播：
# 16px 子格被摧毁：客户端更新对应 16px 渲染瓦片并移除本地碰撞体。
signal local_sub_destroyed(sub: Vector2i)


@rpc("authority", "reliable")
func sub_destroyed(sub: Vector2i) -> void:
	local_sub_destroyed.emit(sub)


# 广播各角色的时间颗粒账户状态（包含余额、短期窗口、透支深度及锁定标记）。
signal local_time_state(payload: Dictionary)


@rpc("authority", "reliable")
func time_state(payload: Dictionary) -> void:
	local_time_state.emit(payload)

# 大厅向客户端同步当前房间的实时成员与状态信息。
@rpc("authority", "reliable")
func royale_room_state(state: Dictionary) -> void:
	local_royale_room_state.emit(state)

# 3v3 团队对抗大厅协议：
signal team_create_requested(caller: int, opts: Dictionary)
signal team_join_requested(caller: int, code: String, invite: String, beta: bool)
signal team_pick_requested(caller: int, team: int)
signal team_leave_requested(caller: int)
signal team_start_requested(caller: int)
signal team_list_requested(caller: int, token: String)
signal local_team_rooms(rooms: Array)
signal local_team_room_state(state: Dictionary)

# 客户端向大厅请求创建团队房间。
@rpc("any_peer", "reliable")
func team_create(opts: Dictionary) -> void:
	team_create_requested.emit(multiplayer.get_remote_sender_id(), opts)

# 客户端向大厅请求加入团队房间。
@rpc("any_peer", "reliable")
func team_join(code: String, invite: String, beta: bool) -> void:
	team_join_requested.emit(multiplayer.get_remote_sender_id(), code, invite, beta)

# 客户端向大厅请求选择阵营队伍（1 或 2）。
@rpc("any_peer", "reliable")
func team_pick(team: int) -> void:
	team_pick_requested.emit(multiplayer.get_remote_sender_id(), team)

# 客户端向大厅请求退出团队房间。
@rpc("any_peer", "reliable")
func team_leave() -> void:
	team_leave_requested.emit(multiplayer.get_remote_sender_id())

# 房主向大厅请求开始团队对局（需满足人数平衡要求）。
@rpc("any_peer", "reliable")
func team_start() -> void:
	team_start_requested.emit(multiplayer.get_remote_sender_id())

# 客户端向大厅请求团队房间列表。
@rpc("any_peer", "reliable")
func team_list(token: String) -> void:
	team_list_requested.emit(multiplayer.get_remote_sender_id(), token)

# 大厅向客户端广播公开团队房间列表。
@rpc("authority", "reliable")
func team_rooms(rooms: Array) -> void:
	local_team_rooms.emit(rooms)

# 大厅向客户端同步当前团队房间内队伍与成员名单。
@rpc("authority", "reliable")
func team_room_state(state: Dictionary) -> void:
	local_team_room_state.emit(state)

# 房主向大厅同步所选地图路径，供房间列表卡片展示缩略图。
signal room_map_requested(caller: int, code: String, path: String)

@rpc("any_peer", "reliable")
func room_map(code: String, path: String) -> void:
	room_map_requested.emit(multiplayer.get_remote_sender_id(), code, path)

# 断线重连与会话令牌管理：
# 服务端在客户端进入对局前下发一次性会话令牌，用于断线重连身份核验。
signal local_session_token(token: String)

@rpc("authority", "reliable")
func session_token(token: String) -> void:
	local_session_token.emit(token)

# 客户端进入对局后向服务端报备会话令牌。
signal token_reported(caller: int, token: String)

@rpc("any_peer", "reliable")
func report_token(token: String) -> void:
	token_reported.emit(multiplayer.get_remote_sender_id(), token)

# 客户端在宽限期内携带令牌申请重新认领离线角色实体。
signal reclaim_requested(caller: int, role: int, token: String)

@rpc("any_peer", "reliable")
func reclaim_role(role: int, token: String) -> void:
	reclaim_requested.emit(multiplayer.get_remote_sender_id(), role, token)

# 客户端退出至大厅后，凭会话令牌请求重返进行中的对局。
signal rejoin_requested(caller: int, code: String, token: String)

@rpc("any_peer", "reliable")
func rejoin_request(code: String, token: String) -> void:
	rejoin_requested.emit(multiplayer.get_remote_sender_id(), code, token)

# 大厅拒绝客户端重返请求（凭据无效、房间不存在或对局已结束）。
signal local_rejoin_denied(reason: String)

@rpc("authority", "reliable")
func rejoin_denied(reason: String) -> void:
	local_rejoin_denied.emit(reason)

