extends Node2D
# 服务器入口(headless 运行)。两种角色,由命令行 user args(位于 `--` 之后)区分:
#  - 无参数:大厅(默认,7777)——只做建房/配对;配对完成后为每局拉起一个 --worker 子进程。
#  - `--worker --port P`:对局 worker——独占 UDP 端口 P,等两名客户端 claim_role 后
#    RoomManager.start_match_on 建权威 MatchHost,任一方离开即拆局退出(释放端口)。

var _host: Node = null
var _claims: Dictionary = {}   # role(int) -> peer_id(worker 视角)
var _claim_names: Dictionary = {}   # role(int) -> 昵称(开局 peer_info 回传两端)
var _wait_timer := 0.0

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var is_worker := false
	var port := NetBus.DEFAULT_PORT
	for i in range(args.size()):
		match args[i]:
			"--worker":
				is_worker = true
			"--port":
				if i + 1 < args.size():
					port = int(args[i + 1])
	if is_worker:
		_run_worker(port)
		return
	# ── 大厅 ──
	# 先杀掉还占着 7777 的旧服务端(上次没关干净会 bind 失败→闪退),再监听
	_kill_port_holder(NetBus.DEFAULT_PORT)
	var err := NetBus.start_server()
	if err != OK:
		push_error("服务器: 监听失败 %d" % err)
		get_tree().quit(1)
		return
	add_child(RoomManager.new())
	print("服务器就绪,等待玩家……(大厅 7777;配对后自动拉起对局 worker)")

# 杀掉还监听该 UDP 端口的旧进程(Windows:PowerShell 取 UDP 端点属主进程→Stop-Process)。
# 供大厅启动前用,避免旧服务端没关导致新实例 bind 失败瞬间退出(双击 exe 闪退)。
func _kill_port_holder(port: int) -> void:
	var ps := "$p=Get-NetUDPEndpoint -LocalPort " + str(port) + \
			" | % OwningProcess | sort -u; if($p){$p|%{Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue}}"
	OS.execute("powershell.exe", ["-NoProfile", "-Command", ps], [], false, true)

# ── worker:独占端口等两端 claim_role,收齐建局 ──
func _run_worker(port: int) -> void:
	var err := NetBus.start_server(port)
	if err != OK:
		push_error("worker: 监听失败 %d (port %d)" % [err, port])
		get_tree().quit(1)
		return
	NetBus.role_claimed.connect(_on_role_claimed)
	NetBus.peer_left.connect(_on_peer_left)
	print("worker 就绪,等待两名玩家……(port %d)" % port)

func _on_role_claimed(caller: int, role: int, player_name: String) -> void:
	if _claims.has(role) or _host != null:
		return
	_claims[role] = caller
	_claim_names[role] = player_name
	print("worker: 角色 %d = peer %d (%d/2)" % [role, caller, _claims.size()])
	if _claims.size() >= 2:
		NetBus.role_claimed.disconnect(_on_role_claimed)
		_host = RoomManager.start_match_on(_claims)
		add_child(_host)
		# 把双方昵称回传各端(头上显示 ID)
		for r in _claims:
			NetBus.rpc_id(_claims[r], "peer_info", _claim_names)
		print("worker: 对局开始")

func _on_peer_left(peer_id: int) -> void:
	if _host != null:
		# 对局已开始:任一方离开 → 拆局退出
		if is_instance_valid(_host):
			_host.queue_free()
		print("worker: 玩家离开,对局结束")
		get_tree().quit(0)
	elif _claims.values().has(peer_id):
		# 尚未满员就有 claimed 玩家掉线 → 别占着端口干等,退出
		print("worker: 角色报到后掉线,退出")
		get_tree().quit(0)
