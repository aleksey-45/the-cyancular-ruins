extends Node

# 实验分支扩展协议(autoload,与原版 NetBus 刻意分离):
# Godot 的 RPC 按「节点路径+方法名」解析,但实测改动原 NetBus 的方法列表(改签名/
# 插新方法)会让与原版大厅(120.53.107.140:7777)的 RPC 全部失联——建房间无应答。
# 因此:原 NetBus 保持与原版逐字节一致;实验新增 RPC 全部放本节点。
# 对原版 worker:本节点不存在 → 扩展 RPC 静默丢弃,优雅降级(选项/颜色不生效,对局照常);
# 对自建 worker(同版本构建):选项/颜色功能齐全。

signal local_match_options(opts: Dictionary)      # worker → 客户端:生效对局选项(房主下发)
signal local_peer_hues(hues: Dictionary)          # worker → 客户端:双方自选角色颜色 {role -> 色相}
signal local_hit_confirm(shooter_role: int, victim_role: int)  # worker → 射手客户端:你的子弹命中了玩家
signal player_options_received(caller: int, opts: Dictionary)  # worker:某客户端上报的本端选项

# 客户端 → worker:本端选项(角色颜色/规则偏好)。服务器权威项以房主(role1)为准。
@rpc("any_peer", "reliable")
func player_options(opts: Dictionary) -> void:
	player_options_received.emit(multiplayer.get_remote_sender_id(), opts)

# worker → 客户端:本局生效选项(禁武器/回合回血),进局广播一次
@rpc("authority", "reliable")
func match_options(opts: Dictionary) -> void:
	local_match_options.emit(opts)

# worker → 客户端:双方角色颜色 {role(int) -> 色相度数},开局广播一次
@rpc("authority", "reliable")
func peer_hues(hues: Dictionary) -> void:
	local_peer_hues.emit(hues)

# worker → 射手客户端:你的子弹命中了一名玩家(FPS 式命中反馈,只发给射手本人)。
# 仅弹直击(服务器裁决 _on_bullet_hit)发;爆炸 AoE 不发(伤害方不明确,击杀仍有 kill_event)。
@rpc("authority", "reliable")
func hit_confirm(shooter_role: int, victim_role: int) -> void:
	local_hit_confirm.emit(shooter_role, victim_role)

# ── 即时光束武器(激光)──
# 服务器权威开火 → 非射手客户端画视觉副本(物理子弹走 bullet_spawn;即时光束无移动实体,
# 事件里带整条折线)。原版 NetBus 逐字节不动,新 RPC 进 NetBusExt(与 hit_confirm 同区)。
signal local_beam_fired(data: Dictionary)

@rpc("authority", "reliable")
func beam_fired(data: Dictionary) -> void:
	local_beam_fired.emit(data)

# ── 大乱斗大厅(自建服务器,与 1v1 大厅协议并存;RPC 名不同互不干扰)──
# 服务器侧经转交信号交给 RoomManager 的 royale 注册表;开局复用原版 go_match(role,port)。

signal royale_create_requested(caller: int, opts: Dictionary)
signal royale_join_requested(caller: int, code: String, invite: String)
signal royale_leave_requested(caller: int)
signal royale_list_requested(caller: int)
signal royale_start_requested(caller: int)
signal ai_duel_requested(caller: int)             # 1v1:房主请求与 AI 对战(实验性)
signal royale_start_ai_requested(caller: int)     # 大乱斗:房主请求 AI 补位开局(实验性)
signal local_royale_rooms(rooms: Array)        # 大厅 → 客户端:公开大乱斗房间列表
signal local_royale_room_state(state: Dictionary)  # 大厅 → 客户端:所在房间实时状态(等待室)

# 客户端 → 大厅:建房。opts = {is_public:bool, invite_code:String, max_players:int,
#   round_full_heal:bool, disabled_weapons:Array}(规则项随房存,开局随房主生效)
@rpc("any_peer", "reliable")
func royale_create(opts: Dictionary) -> void:
	royale_create_requested.emit(multiplayer.get_remote_sender_id(), opts)

# 客户端 → 大厅:加入(私密房须带邀请码)
@rpc("any_peer", "reliable")
func royale_join(code: String, invite: String) -> void:
	royale_join_requested.emit(multiplayer.get_remote_sender_id(), code, invite)

# 客户端 → 大厅:退出所在大乱斗房间(开局前)
@rpc("any_peer", "reliable")
func royale_leave() -> void:
	royale_leave_requested.emit(multiplayer.get_remote_sender_id())

# 客户端 → 大厅:请求公开大乱斗房间列表
@rpc("any_peer", "reliable")
func royale_list() -> void:
	royale_list_requested.emit(multiplayer.get_remote_sender_id())

# 客户端 → 大厅:房主请求开局(仅房主有效;人数 ≥2 才开)
@rpc("any_peer", "reliable")
func royale_start() -> void:
	royale_start_requested.emit(multiplayer.get_remote_sender_id())

# 客户端 → 大厅:1v1 房主请求与 AI 对战(实验性;仅自建服务端支持)
@rpc("any_peer", "reliable")
func ai_duel() -> void:
	ai_duel_requested.emit(multiplayer.get_remote_sender_id())

# 客户端 → 大厅:大乱斗房主请求 AI 补位开局(实验性;仅自建服务端支持)
@rpc("any_peer", "reliable")
func royale_start_ai() -> void:
	royale_start_ai_requested.emit(multiplayer.get_remote_sender_id())

# 大厅 → 客户端:公开房间列表 [{code, players, max_players, names}]
@rpc("authority", "reliable")
func royale_rooms(rooms: Array) -> void:
	local_royale_rooms.emit(rooms)

# 大厅 → 客户端:所在房间实时状态 {code, is_public, invite_code, max_players, host_role,
#   players: [{role, name}], in_match}(等待室 UI 靠它刷新;仅发给房内成员)
@rpc("authority", "reliable")
func royale_room_state(state: Dictionary) -> void:
	local_royale_room_state.emit(state)
