extends Node

# tests/harness/net_lag_client.gd —— 直连 Worker 进程（可经由 UDP 延迟代理）运行真实 pvp_game 场景，
# 用于在受控延迟环境下采集 [netstat] 网络指标。测试工具类，不参与工程发布。
#
# 为什么绕开大厅:worker 接受任何人的 `claim_role`(token 只归档不校验),所以把
# `lobby_page` 的那三段照抄过来就够 —— `_do_go_match` / `_claim_role_worker` / `_on_match_start`。
# 这样也顺带规避了「让大厅把 worker 端口报成代理端口」那个难题(worker 绑 0.0.0.0,
# 代理没法用"另一个环回 IP 占同一端口"的办法并存)。
#
# 运行方式：
#   "$GODOT" --headless --path . --quit-after 7200 --log-file c1.godotlog \
#       res://tests/harness/net_lag_client.tscn - "--role=1" "--port=7800" "--netstat"
#
# 参数(全在 `--` 之后):
#   --role=N   本端 role(1 / 2)
#   --port=P   连哪个端口(直连 worker 时 = worker 端口;插代理时 = 代理端口)
#   --addr=A   默认 127.0.0.1
#   --name=S   昵称,默认 Anon
#   --drive=0  关掉自动按键(默认开:headless 站着不动测不出回滚)
#   --netstat  透传给 `pvp_match_client`(它自己读 `OS.get_cmdline_user_args()`)


var _role := 1
var _port := 7800
var _addr := "127.0.0.1"
var _name := "Anon"
var _drive := true
# 进哪个对局场景:1v1 是 pvp_game,3v3 是 team_game,大乱斗是 royale_game。
# 三个场景同基类(PvpMatchClient),故本夹具换一个开关就能全模式用。
var _scene := "res://scenes/pvp_game.tscn"


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--role="):
			_role = int(a.substr(7))
		elif a.begins_with("--port="):
			_port = int(a.substr(7))
		elif a.begins_with("--addr="):
			_addr = a.substr(7)
		elif a.begins_with("--name="):
			_name = a.substr(8)
		elif a == "--drive=0":
			_drive = false
		elif a.begins_with("--scene="):
			_scene = a.substr(8)
	PvpSession.server_address = _addr
	PvpSession.role = _role
	PvpSession.player_name = _name
	PvpSession.token = ""      # 直连场景用不上重连,不发 token
	print("[netlag] role=%d 连 %s:%d" % [_role, _addr, _port])
	if _drive:
		# - 驱动器挂 root(不是本场景):`change_scene_to_file` 会把本节点换掉,
		#   而按键要一路跟到对局里 —— 挂场景上会在切场景那一刻消失,玩家原地不动。
		var d := InputDriver.new()
		d.role = _role
		# - 必须 call_deferred:本函数在 root 正在装配子节点的过程中跑,
		#   直接 `add_child` 会失败(实测报 "Parent node is busy setting up children"),
		#   而且失败是静默的 —— 驱动器没挂上、bot 一步不走,完整测试运行看起来却"正常完成"。
		#   我第一版就是这么错的:所有跑次里的 bot 从头到尾没动过。
		get_tree().root.add_child.call_deferred(d)
	NetBus.local_match_start.connect(_on_match_start)
	multiplayer.connected_to_server.connect(_on_connected, CONNECT_ONE_SHOT)
	var err := NetBus.start_client(_addr, _port)
	if err != OK:
		print("[netlag] start_client 失败: %d" % err)
		get_tree().quit(1)


func _on_connected() -> void:
	print("[netlag] 已连上 worker,claim role=%d" % _role)
	NetBus.rpc_id(1, "claim_role", _role, PvpSession.player_name)


func _on_match_start(role: int, spawn: Vector2i, map_path: String) -> void:
	print("[netlag] match_start role=%d spawn=%s map=%s" % [role, str(spawn), map_path])
	PvpSession.role = role
	PvpSession.spawn = spawn
	PvpSession.map_path = map_path
	# - 帧末切场景:本回调在 peer 的 poll() 调用栈里,栈内切会段错误(与 lobby_page 相同处理逻辑)。
	get_tree().change_scene_to_file.call_deferred(_scene)


# 自动按键:让两个客户端都一直在动,并且朝对方走。
#
# - 第一版是每 1.2s 换向 —— 那是错的:两个出生点相距约 7400px,各自原地振荡永远不相遇,
#   于是预测从不产生分歧、回滚恒 0,得到一条毫无意义的"全 0"读数(实测踩到过)。
#   现在 role 1 一路向右、role 2 一路向左,逼它们在中间撞上 —— 只有两具身体真的接触,
#   才会走到「幽灵碰撞体 + 本地预测」那条 C2 分歧路径上。
class InputDriver:
	extends Node

	const STUCK_S := 0.5          # 水平位移连续这么久为 0  ->  判定卡住
	const FLIP_S := 1.5           # 卡太久就反向走这么久,绕开障碍
	const FLIP_AFTER_S := 2.0

	var role := 1
	var _jump_t := 0.0
	var _stuck_t := 0.0
	var _flip_t := 0.0
	var _last_x := NAN

	func _process(delta: float) -> void:
		_jump_t += delta
		var me: Node2D = get_tree().get_first_node_in_group("player")
		var foe: Node2D = get_tree().get_first_node_in_group("player_replica")
		# 兜底保护方向:还没进对局(两个组都空)时按奇偶各走一边
		var dir := 1.0 if role % 2 == 1 else -1.0
		if me != null and is_instance_valid(me):
			# 注意事项：追踪必须用权威 canonical,不能用副本的 `global_position`:
			#   副本的渲染位置是被刻意锚到本地玩家附近的(见 player_replica 的
			#   anchor_to_nearest),所以它永远"就在我旁边",`dx` 指不出对手的真实方向 ——
			#   实测后果:c1 一路乱走到绕了环面一圈、c2 原地卡死,两者从不碰面。
			#   权威位置在副本的 `_opponent_canonical` 里(最新快照的服务器 coordinate)。
			var w := float(GameParameters.MAP_WIDTH)
			var h := float(GameParameters.MAP_HEIGHT)
			var foe_c: Vector2 = Vector2.ZERO
			if foe != null and is_instance_valid(foe):
				var raw = foe.get("_opponent_canonical")
				if raw is Vector2:
					foe_c = raw
			if w > 0.0 and h > 0.0 and foe_c != Vector2.ZERO:
				var mine := MazeGenerator.wrap_to_range(me.global_position, w, h)
				var d := GridPathfinder.toroidal_delta_px(mine, foe_c, w, h)
				if absf(d.x) > 16.0:
					dir = signf(d.x)
			# 卡住检测:水平几乎不动就累计,久了反向绕
			if is_nan(_last_x) or absf(me.global_position.x - _last_x) > 1.0:
				_stuck_t = 0.0
			else:
				_stuck_t += delta
			_last_x = me.global_position.x
		if _stuck_t > FLIP_AFTER_S:
			_stuck_t = 0.0
			_flip_t = FLIP_S
		if _flip_t > 0.0:
			_flip_t -= delta
			dir = -dir

		Input.action_release("left")
		Input.action_release("right")
		if dir > 0.0:
			Input.action_press("right")
		else:
			Input.action_press("left")
		# 跳跃:每 0.4s 一个周期松一下 —— 按住不放只会在第一帧算 just_pressed,跳不起来。
		# 卡住时改成 0.25s 一跳(爬台阶/翻矮墙)。
		var period := 0.25 if _stuck_t > STUCK_S else 0.4
		if _jump_t >= period:
			_jump_t = 0.0
			Input.action_release("up")
		elif _jump_t < period * 0.4:
			Input.action_press("up")
