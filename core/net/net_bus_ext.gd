extends Node

# 实验分支扩展协议(autoload,与原版 NetBus 刻意分离):实测改动原 NetBus 的方法表(改签名/插新方法)会让与原版大厅的 RPC 全部失联。
# ⇒ 原 NetBus 逐字节一致,实验新增 RPC 全放本节点;对原版 worker 本节点不存在 ⇒ 扩展 RPC 静默丢弃、优雅降级(选项/颜色不生效,对局照常)。

signal local_match_options(opts: Dictionary)      # worker → 客户端:生效对局选项(房主下发)
signal local_peer_hues(hues: Dictionary)          # worker → 客户端:双方自选角色颜色 {role -> 色相}
signal local_hit_confirm(shooter_role: int, victim_role: int)  # worker → 射手客户端:你的子弹命中了玩家
signal player_options_received(caller: int, opts: Dictionary)  # worker:某客户端上报的本端选项

@rpc("any_peer", "call_remote", "reliable", 0)
func player_options(opts: Dictionary) -> void:
	player_options_received.emit(multiplayer.get_remote_sender_id(), opts)

@rpc("authority", "call_remote", "reliable", 0)
func match_options(opts: Dictionary) -> void:
	local_match_options.emit(opts)

@rpc("authority", "call_remote", "reliable", 0)
func peer_hues(hues: Dictionary) -> void:
	local_peer_hues.emit(hues)

# worker → 射手客户端:只发给射手本人的命中反馈;仅弹直击发(爆炸 AoE 伤害方不明确,不发;击杀仍有 kill_event)。
@rpc("authority", "call_remote", "reliable", 3)
func hit_confirm(shooter_role: int, victim_role: int) -> void:
	local_hit_confirm.emit(shooter_role, victim_role)

# ── 即时光束武器(激光)── 服务器权威开火 → 非射手客户端画视觉副本:无移动实体,事件里带整条折线;新 RPC 放本节点(原 NetBus 方法表不动)。
signal local_beam_fired(data: Dictionary)

@rpc("authority", "call_remote", "reliable", 3)
func beam_fired(data: Dictionary) -> void:
	local_beam_fired.emit(data)

signal suicide_requested(caller: int)

@rpc("any_peer", "call_remote", "reliable", 0)
func suicide_request() -> void:
	suicide_requested.emit(multiplayer.get_remote_sender_id())

# ── 大乱斗大厅(与 1v1 大厅协议并存;RPC 名不同互不干扰)── 服务器侧经转交信号交给 RoomManager 的 royale 注册表;开局复用原版 go_match(role,port)。

signal royale_create_requested(caller: int, opts: Dictionary)
signal royale_join_requested(caller: int, code: String, invite: String, beta: bool)
signal royale_leave_requested(caller: int)
signal royale_list_requested(caller: int, token: String)
signal royale_start_requested(caller: int)
signal ai_duel_requested(caller: int)             # 1v1:房主请求与 AI 对战(实验性)
signal royale_start_ai_requested(caller: int)     # 大乱斗:房主请求 AI 补位开局(实验性)
signal local_royale_rooms(rooms: Array)        # 大厅 → 客户端:公开大乱斗房间列表
signal local_royale_room_state(state: Dictionary)  # 大厅 → 客户端:所在房间实时状态(等待室)

@rpc("any_peer", "call_remote", "reliable", 0)
func royale_create(opts: Dictionary) -> void:
	royale_create_requested.emit(multiplayer.get_remote_sender_id(), opts)

@rpc("any_peer", "call_remote", "reliable", 0)
func royale_join(code: String, invite: String, beta: bool) -> void:
	royale_join_requested.emit(multiplayer.get_remote_sender_id(), code, invite, beta)

@rpc("any_peer", "call_remote", "reliable", 0)
func royale_leave() -> void:
	royale_leave_requested.emit(multiplayer.get_remote_sender_id())

# ★ token = 本端手里的回局凭据(没有就是 ""):大厅据此把"本人自己那间私密房"也列给他(此前私密房一律不列,私密房里回主菜单的玩家没有回局入口)。
#   它不是身份认证 —— 真正的准入由 rejoin_request 的 RejoinRegistry.decision 判。★ 加参数 = 改 NetBusExt 的方法表,可以:本类是本仓自己的扩展协议。
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


# ── Beta 时间玩法:16px 子格被摧毁(cyrm v4)。客户端清一个 16px 渲染格与本地预测碰撞(与 tile_destroyed 同链路,粒度细到子格)。
signal local_sub_destroyed(sub: Vector2i)


@rpc("authority", "call_remote", "reliable", 3)
func sub_destroyed(sub: Vector2i) -> void:
	local_sub_destroyed.emit(sub)


signal local_time_state(payload: Dictionary)


@rpc("authority", "call_remote", "reliable", 2)
func time_state(payload: Dictionary) -> void:
	local_time_state.emit(payload)

# 大厅 → 客户端:所在房间实时状态(等待室 UI 靠它刷新;仅发给房内成员)。
@rpc("authority", "call_remote", "reliable", 2)
func royale_room_state(state: Dictionary) -> void:
	local_royale_room_state.emit(state)

# ── 1v1 等待室(2026-10-24:1v1 从「两人凑齐自动开局」改成「房主点『开始游戏』」)──
# ★ 通道 0(与会话/生命周期成序列的消息同一条道):room_state 必须排在 room_created / room_joined 之后到达。
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
signal team_list_requested(caller: int, token: String)   # 请求 3v3 房间列表(token 同上,照 royale_list 那一对)
signal local_team_rooms(rooms: Array)             # 大厅 → 客户端:公开 3v3 房间列表
signal local_team_room_state(state: Dictionary)   # 大厅 → 客户端:房间实时状态(等待室/选边)

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

# 大厅 → 客户端:房间实时状态 {code, is_public, invite_code, host_role, team_size, players:[{role,name,team}], in_match, your_role}(等待室靠它渲染两队名单)。
@rpc("authority", "call_remote", "reliable", 2)
func team_room_state(state: Dictionary) -> void:
	local_team_room_state.emit(state)

# ── 统一大厅:房主上报本房地图(仅用于列表展示)。★ 为什么统一走它:1v1 的 create_room 是原版 NetBus 的 RPC、签名冻结,塞不进 payload;
#   而 royale/team 的 create 载荷虽是字典(加键免费),用两条机制会让"地图从哪来"分叉。★ 它写的只是列表上那张缩略图,真正定图的仍是 player_options.map。
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

# 客户端 → worker:把 token 报到本局(claim 之后立刻发);worker 存 role→token 供日后核验。
signal token_reported(caller: int, token: String)

@rpc("any_peer", "call_remote", "reliable", 0)
func report_token(token: String) -> void:
	token_reported.emit(multiplayer.get_remote_sender_id(), token)

# 客户端 → worker:宽限期内重新认领自己那个 role;token 不对一律拒(并踢连接)。
signal reclaim_requested(caller: int, role: int, token: String)

@rpc("any_peer", "call_remote", "reliable", 0)
func reclaim_role(role: int, token: String) -> void:
	reclaim_requested.emit(multiplayer.get_remote_sender_id(), role, token)

# ── 回大厅后回局:玩家按 ESC 回主菜单 → 对应模式的大厅页里自己那间房照常列在列表里;凭(房间号, token)点它 → 大厅把 go_match 原样再发一次,
#   客户端走与首次进场逐字同一条转连/认领路径。★ 入口不是一颗专门的「回到对局」按钮(判据是"这个 caller 有没有资格重进这间房");
#   ★ 成功那一路不另开信号(复用原 NetBus 的 go_match),失败那一路必须显式告诉客户端,否则它会一直等一个永不到来的 go_match。
signal rejoin_requested(caller: int, code: String, token: String)

@rpc("any_peer", "call_remote", "reliable", 0)
func rejoin_request(code: String, token: String) -> void:
	rejoin_requested.emit(multiplayer.get_remote_sender_id(), code, token)

signal local_rejoin_denied(reason: String)

@rpc("authority", "call_remote", "reliable", 0)
func rejoin_denied(reason: String) -> void:
	local_rejoin_denied.emit(reason)
