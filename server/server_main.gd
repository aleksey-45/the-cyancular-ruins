extends Node2D
# 服务器入口(headless 运行)。两种角色,由命令行 user args(位于 `--` 之后)区分:
#  - 无参数:大厅(默认,7777)——只做建房/配对;配对完成后为每局拉起一个 --worker 子进程。
#  - `--worker --port P`:对局 worker——独占 UDP 端口 P,等两名客户端 claim_role 后
#    RoomManager.start_match_on 建权威 MatchHost,任一方离开即拆局退出(释放端口)。

var _host: Node = null
var _claims: Dictionary = {}   # role(int) -> peer_id(worker 视角)
var _claim_names: Dictionary = {}   # role(int) -> 昵称(开局 peer_info 回传两端)
var _claim_opts: Dictionary = {}   # role(int) -> 本端选项(颜色/规则偏好)
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

func _on_role_claimed(caller: int, role: int, player_name: String, opts: Dictionary = {}) -> void:
	# 防串线:对局已开始、或该 role 已被其他 peer 占用 → 这个连接不属于本局,直接踢。
	# (端口复用竞态下,迟到的客户端可能连到旧 worker;不能让它静默留在局里收快照/子弹。)
	if _host != null or (_claims.has(role) and _claims[role] != caller):
		print("worker: 拒绝串线连接 peer=%d(role=%d)" % [caller, role])
		multiplayer.multiplayer_peer.disconnect_peer(caller)
		return
	if _claims.has(role):
		return
	_claims[role] = caller
	_claim_names[role] = player_name
	_claim_opts[role] = opts
	print("worker: 角色 %d = peer %d (%d/2)" % [role, caller, _claims.size()])
	if _claims.size() >= 2:
		NetBus.role_claimed.disconnect(_on_role_claimed)
		# 服务器权威规则项以房主(role1)选项为准
		_host = RoomManager.start_match_on(_claims, RoomManager.PVP_MAP, _claim_opts.get(1, {}))
		add_child(_host)
		# 把双方昵称/颜色回传各端(头顶 ID + 角色染色)
		for r in _claims:
			NetBus.rpc_id(_claims[r], "peer_info", _claim_names, _claim_hues())
		print("worker: 对局开始")

# 各 role 自选的角色颜色(色相旋转度数;缺省 0)
func _claim_hues() -> Dictionary:
	var hues := {}
	for r in _claim_opts:
		hues[r] = float(_claim_opts[r].get("hue", 0.0)) if typeof(_claim_opts[r]) == TYPE_DICTIONARY else 0.0
	return hues

func _on_peer_left(peer_id: int) -> void:
	var is_participant := _claims.values().has(peer_id)
	if _host != null:
		# 对局已开始:只有本局双方的离开才拆局;被踢的串线连接断开不影响对局
		if not is_participant:
			return
		if is_instance_valid(_host):
			_host.queue_free()
		print("worker: 玩家离开,对局结束")
		get_tree().quit(0)
	elif is_participant:
		# 尚未满员就有 claimed 玩家掉线 → 别占着端口干等,退出
		print("worker: 角色报到后掉线,退出")
		get_tree().quit(0)
