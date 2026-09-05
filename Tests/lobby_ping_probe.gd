extends SceneTree

# 大厅可达性探针:纯 ENet 连 7777,手动 poll,8 秒内 CONNECTION_CONNECTED=在线。
# 用法: Godot_console --headless --path . -s res://Tests/lobby_ping_probe.gd [-- 服务器IP]
# -s 阶段无 autoload/无 MultiplayerAPI 依赖,直接轮询 ENetMultiplayerPeer 状态。

const PORT := 7777

var _t := 0.0
var _addr := "120.53.107.140"
var _peer: ENetMultiplayerPeer = null

func _initialize() -> void:
	for a in OS.get_cmdline_user_args():
		if not a.begins_with("--"):
			_addr = a
	_peer = ENetMultiplayerPeer.new()
	var err := _peer.create_client(_addr, PORT)
	if err != OK:
		print("PROBE: create_client 失败 err=", err)
		quit(1)
		return
	print("PROBE: 正在连 %s:%d(UDP,最多等 8 秒)…" % [_addr, PORT])

func _process(delta: float) -> bool:
	_t += delta
	if _peer != null:
		_peer.poll()
		if _peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
			print("PROBE: %s:%d 大厅在线(已连上)" % [_addr, PORT])
			return true
	if _t > 8.0:
		print("PROBE: 8 秒未连上 → %s:%d 不可达(服务器不在线/防火墙拦 UDP/地址错)" % [_addr, PORT])
		return true   # true = 退出
	return false
