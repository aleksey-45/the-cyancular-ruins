extends Node

# 扩展协议(autoload,与原版 NetBus 刻意分离)。三条纪律:
#  1) 原 NetBus 保持与原版逐字节一致(与原作者云服互通只能靠它);实验功能全在本节点。
#  2) **方法表永久稳定**:本节点只暴露 ext_c2s / ext_s2c 两个 @rpc 信封,功能靠 kind 字段区分。
#     原因:Godot 按「节点」做 RPC 方法表校验和——以前每加一个功能就加一个 @rpc 方法,
#     新旧构建互连时触发 "rpc node checksum failed",本节点**所有** RPC 一起失效
#     (表现:游戏一更新,旧服务端直接不能用)。信封化后加功能不再动方法表:
#     旧服务端只是"不认识某个 kind",忽略即可,基础玩法(1v1)不受影响。
#  3) 能力协商:客户端连上后发 hello;服务器回 welcome(build + caps)。
#     客户端据此降级 UI(如服务器不支持大乱斗 → 灰掉建房/加入并给出人话提示)。
#
# 与"发布前旧构建"的兼容说明:信封本身是一次性的断点——**本版本之前**发布的旧服务端,
# 其方法表仍是旧的那套,连上依旧 checksum 失败;能力协商的超时提示会明确告知版本不匹配。
# 从本版本起,后续所有版本共用这套信封,旧服务端就能长期可用(只缺新功能)。

signal local_match_options(opts: Dictionary)      # worker → 客户端:生效对局选项(房主下发)
signal local_peer_hues(hues: Dictionary)          # worker → 客户端:双方自选角色颜色 {role -> 色相}
signal local_hit_confirm(shooter_role: int, victim_role: int)  # worker → 射手客户端:你的子弹命中了玩家
signal local_explosion_event(pos: Vector2, radius: float)      # worker → 客户端:权威爆炸位置(视效广播)
signal player_options_received(caller: int, opts: Dictionary)  # worker:某客户端上报的本端选项
signal local_beam_fired(data: Dictionary)
signal local_smoke_event(pos: Vector2, radius: float, duration: float)  # worker → 客户端:权威烟雾区         # worker → 非射手端:激光光束几何(画视觉副本)
signal suicide_requested(caller: int)             # worker:某客户端请求自杀脱困
signal local_welcome(build: String, caps: Dictionary)          # 客户端:服务器握手回应
signal hues_requested(caller: int)                # worker:客户端请求补发 peer_hues(进图后听力才接上)

# 大乱斗大厅(自建服务端,与 1v1 大厅协议并存)
signal royale_create_requested(caller: int, opts: Dictionary)
signal royale_join_requested(caller: int, code: String, invite: String)
signal royale_leave_requested(caller: int)
signal royale_list_requested(caller: int)
signal royale_start_requested(caller: int)
signal ai_duel_requested(caller: int)             # 1v1:房主请求与 AI 对战(实验性)
signal royale_start_ai_requested(caller: int)     # 大乱斗:房主请求 AI 补位开局(实验性)
signal local_royale_rooms(rooms: Array)           # 大厅 → 客户端:公开大乱斗房间列表
signal local_royale_room_state(state: Dictionary) # 大厅 → 客户端:所在房间实时状态(等待室)

# 能力协商结果(客户端侧):服务器 build 串 + 能力集;UI 据此降级
signal server_caps_updated(build: String, caps: Dictionary)

const BUILD_ID := "kh-1.1.3-pubserver"
const CAPS := {
	"royale": true,
	"beam": true,
	"hit_confirm": true,
	"explosion_event": true,
	"suicide": true,
	"player_options": true,
	"ai_fill": true,
}

var server_build := ""            # 客户端:最近一次握手到的服务器构建号
var server_caps: Dictionary = {}  # 客户端:服务器能力集


func server_has(cap: String) -> bool:
	return server_caps.has(cap) and bool(server_caps[cap])


# ── 稳定信封(仅此两个 @rpc,永不增删改) ──
@rpc("any_peer", "reliable")
func ext_c2s(kind: String, payload: Dictionary) -> void:
	_dispatch(kind, payload, multiplayer.get_remote_sender_id())


@rpc("authority", "reliable")
func ext_s2c(kind: String, payload: Dictionary) -> void:
	_dispatch(kind, payload, 0)


# ── 发送帮助(调用方只用这三个;新增功能沿用它们,不改方法表)──
func c2s(kind: String, payload: Dictionary = {}) -> void:
	if multiplayer.multiplayer_peer == null:
		return
	ext_c2s.rpc_id(1, kind, payload)


func s2c(peer: int, kind: String, payload: Dictionary = {}) -> void:
	# 目标 peer 不在连接表里就跳过(避免转连瞬间 ENet "max channels 0" 噪音)
	if multiplayer.multiplayer_peer == null or not multiplayer.get_peers().has(peer):
		return
	ext_s2c.rpc_id(peer, kind, payload)


func s2c_all(kind: String, payload: Dictionary = {}) -> void:
	if multiplayer.multiplayer_peer == null:
		return
	ext_s2c.rpc(kind, payload)


## 客户端连上大厅/worker 后调用:上报本端 build 与能力,换回服务器能力集
func client_hello() -> void:
	c2s("hello", {"build": BUILD_ID, "caps": CAPS})


func _dispatch(kind: String, p: Dictionary, caller: int) -> void:
	match kind:
		"player_options":
			player_options_received.emit(caller, p)
		# ── worker → 客户端 ──
		"match_options":
			local_match_options.emit(p)
		"peer_hues":
			local_peer_hues.emit(p)
		"request_hues":
			hues_requested.emit(caller)   # worker 收到后补发一次 peer_hues
		"hit_confirm":
			local_hit_confirm.emit(int(p.get("shooter_role", 0)), int(p.get("victim_role", 0)))
		"beam_fired":
			local_beam_fired.emit(p)
		"explosion_event":
			local_explosion_event.emit(p.get("pos", Vector2.ZERO), float(p.get("radius", 0.0)))
		"smoke_event":
			local_smoke_event.emit(p.get("pos", Vector2.ZERO), float(p.get("radius", 220.0)),
					float(p.get("duration", 6.0)))
		# ── 客户端 → 大厅 ──
		"suicide_request":
			suicide_requested.emit(caller)
		"royale_create":
			royale_create_requested.emit(caller, p)
		"royale_join":
			royale_join_requested.emit(caller, str(p.get("code", "")), str(p.get("invite", "")))
		"royale_leave":
			royale_leave_requested.emit(caller)
		"royale_list":
			royale_list_requested.emit(caller)
		"royale_start":
			royale_start_requested.emit(caller)
		"ai_duel":
			ai_duel_requested.emit(caller)
		"royale_start_ai":
			royale_start_ai_requested.emit(caller)
		# ── 大厅 → 客户端 ──
		"royale_rooms":
			local_royale_rooms.emit(p.get("rooms", []) as Array)
		"royale_room_state":
			local_royale_room_state.emit(p)
		# ── 握手 ──
		"hello":
			_on_hello(caller, p)
		"welcome":
			_on_welcome(p)
		_:
			pass   # 未知 kind(旧/新构建差异):自然降级,不报错


func _on_hello(caller: int, _p: Dictionary) -> void:
	# 仅服务器侧回 welcome(客户端收到 hello 不应答)
	if caller <= 0 or not multiplayer.is_server():
		return
	s2c(caller, "welcome", {"build": BUILD_ID, "caps": CAPS})


func _on_welcome(p: Dictionary) -> void:
	server_build = str(p.get("build", ""))
	server_caps = p.get("caps", {})
	server_caps_updated.emit(server_build, server_caps)
	local_welcome.emit(server_build, server_caps)
