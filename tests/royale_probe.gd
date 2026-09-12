extends Node

# 大乱斗全链路探针(RoyaleServer 分支,场景模式):一个进程当大厅/裁判,再拉起两个
# headless 客户端子进程,走完整流程:
#   c1 建私密房(邀请码 777,房号写中间文件) → c2 读房号 → 错码加入(应被拒)
#   → 对码加入 → c1 见房内 2 人开局 → 双方收 go_match 转连 worker → claim
#   → match_start → RoyaleHost 广播 round_state/snapshot;客户端**拉** match_sync 取生效选项 → 写结果文件。
# 断言(进 _finish 判定,不只打印):match_start 出生点有效 + round_state 到达 +
# **round_state 载荷里的昵称表 names ≥2 项** + match_options 到达 + 快照数 ≥30。
# 中间文件 user://royale_probe_room.txt = 房号;结果 user://royale_probe_c{1,2}.result。
# 用法: Godot_console --headless --path . res://tests/royale_probe.tscn [-- --role=lobby|c1|c2]
# (无参 = lobby/裁判。)

const RESULT_PREFIX := "royale_probe_"
const ROOM_FILE := "user://royale_probe_room.txt"
const INVITE := "777"
const WRONG_INVITE := "000"

var _role := "lobby"
var _snap_count := 0
var _got_round_state := false
var _got_display_names := false
var _got_match_options := false
var _got_match_start := false
var _saw_invite_reject := false

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--role="):
			_role = a.trim_prefix("--role=")
	match _role:
		"lobby":
			_run_orchestrator()
		"c1":
			_run_client_1()
		"c2":
			_run_client_2()

# ── 裁判:起大厅 + 拉起 c1/c2 子进程 + 收结果文件 ──
func _run_orchestrator() -> void:
	var err := NetBus.start_server()
	if err != OK:
		print("PROBE: 大厅监听失败 err=%d(7777 被占?)" % err)
		get_tree().quit(1)
		return
	add_child(RoomManager.new())
	for f in ["c1", "c2"]:
		var p := "user://%s%s.result" % [RESULT_PREFIX, f]
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(p))
	if FileAccess.file_exists(ROOM_FILE):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(ROOM_FILE))
	var exe := OS.get_executable_path()
	for role in ["c1", "c2"]:
		OS.create_process(exe, PackedStringArray(["--headless", "--path",
				ProjectSettings.globalize_path("res://"), "res://tests/royale_probe.tscn",
				"--", "--role=" + role]))
	print("PROBE: 大厅就绪,c1/c2 已拉起")
	var deadline := Time.get_ticks_msec() + 60000
	while Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(1.0).timeout
		var r1 := _read_result("c1")
		var r2 := _read_result("c2")
		if r1.begins_with("FAIL") or r2.begins_with("FAIL"):
			print("PROBE: FAIL\n  c1: %s\n  c2: %s" % [r1, r2])
			get_tree().quit(1)
			return
		if r1.begins_with("OK") and r2.begins_with("OK"):
			print("PROBE: ALL-OK\n  c1: %s\n  c2: %s" % [r1, r2])
			get_tree().quit(0)
			return
	print("PROBE: 超时(60s) FAIL c1=%s c2=%s" % [_read_result("c1"), _read_result("c2")])
	get_tree().quit(1)

func _read_result(who: String) -> String:
	var p := "user://%s%s.result" % [RESULT_PREFIX, who]
	if not FileAccess.file_exists(p):
		return "(未完成)"
	var f := FileAccess.open(p, FileAccess.READ)
	return f.get_as_text().strip_edges() if f != null else "(读取失败)"

func _finish(ok: bool, who: String, msg: String) -> void:
	var f := FileAccess.open("user://%s%s.result" % [RESULT_PREFIX, who], FileAccess.WRITE)
	f.store_string(("OK " if ok else "FAIL ") + msg)
	f.close()
	print("PROBE[%s]: %s" % [who, ("OK " + msg) if ok else ("FAIL " + msg)])
	get_tree().quit(0 if ok else 1)

# ── 公共:连大厅 → lobby_name → on_connected 回调 ──
func _connect_lobby(who: String, on_connected: Callable) -> void:
	multiplayer.connected_to_server.connect(func() -> void:
		print("PROBE[%s]: 已连大厅" % who)
		NetBus.rpc_id(1, "lobby_name", who.to_upper())
		on_connected.call(), CONNECT_ONE_SHOT)
	multiplayer.connection_failed.connect(func() -> void:
		_finish(false, who, "连大厅失败"), CONNECT_ONE_SHOT)
	var err := NetBus.start_client("127.0.0.1")
	if err != OK:
		_finish(false, who, "start_client 失败 %d" % err)
		return
	# 总超时:25s 内没写结果就 FAIL(防挂死;_finish 后节点离树,不再触发)
	get_tree().create_timer(25.0).timeout.connect(func() -> void:
		if is_inside_tree():
			_finish(false, who, "超时(流程未走完)"))

# ── c1:建私密房(房号写中间文件)→ 等 c2 进房 → 开局 → 转连 worker 验证 ──
func _run_client_1() -> void:
	_connect_lobby("c1", func() -> void:
		NetBusExt.local_royale_room_state.connect(func(state: Dictionary) -> void:
			var n: int = (state.get("players", []) as Array).size()
			var code := str(state.get("code", ""))
			if code != "" and not FileAccess.file_exists(ROOM_FILE):
				var rf := FileAccess.open(ROOM_FILE, FileAccess.WRITE)
				rf.store_string(code)
				rf.close()
			if n >= 2 and not _got_match_start:
				print("PROBE[c1]: 房内 %d 人,发起开局" % n)
				NetBusExt.rpc_id(1, "royale_start"))
		NetBusExt.rpc_id(1, "royale_create", {
			"is_public": false, "invite_code": INVITE, "max_players": 4,
			"round_full_heal": false, "disabled_weapons": [3],
		}))
	_go_and_verify("c1")

# ── c2:读房号 → 错码加入(应拒)→ 对码加入 → 转连 worker 验证 ──
func _run_client_2() -> void:
	# 等 c1 把房号写出来
	var code := ""
	for _i in range(100):
		await get_tree().create_timer(0.2).timeout
		if FileAccess.file_exists(ROOM_FILE):
			var rf := FileAccess.open(ROOM_FILE, FileAccess.READ)
			code = rf.get_as_text().strip_edges()
			rf.close()
			if code != "":
				break
	if code == "":
		_finish(false, "c2", "没等到房号文件")
		return
	_connect_lobby("c2", func() -> void:
		await get_tree().create_timer(0.5).timeout
		NetBus.local_server_message.connect(func(t: String) -> void:
			if t.contains("邀请码"):
				_saw_invite_reject = true)
		NetBusExt.rpc_id(1, "royale_join", code, WRONG_INVITE)
		await get_tree().create_timer(0.6).timeout
		if not _saw_invite_reject:
			_finish(false, "c2", "错误邀请码未被拒绝(消息=%s)" % _saw_invite_reject)
			return
		print("PROBE[c2]: 错码被拒 ✓,用对码加入 %s" % code)
		NetBusExt.rpc_id(1, "royale_join", code, INVITE))
	_go_and_verify("c2")

# ── 公共(客户端):等 go_match → 转连 worker → claim → 验证对局广播 ──
func _go_and_verify(who: String) -> void:
	NetBus.local_go_match.connect(func(role: int, port: int) -> void:
		print("PROBE[%s]: go_match role=%d port=%d → 转连 worker" % [who, role, port])
		_to_worker.call_deferred(who, role, port))
	NetBus.local_match_start.connect(func(role: int, spawn: Vector2i, map_path: String) -> void:
		_got_match_start = true
		print("PROBE[%s]: match_start role=%d spawn=%s map=%s" % [who, role, str(spawn), str(map_path)])
		if spawn.x < 0:
			_finish(false, who, "match_start 出生点无效")
			return
		# ★ 批次 3:生效选项改由**进场拉取**下发(服务器那次"推"已删 —— 它与 match_start 落在同一次
		#   poll,而那一刻新场景订阅方还不存在,会静默丢,自检 B2)。
		#   本探针是**轻量监听客户端**(不起真 royale_game),故这里自己发一次 match_sync 并消费应答;
		#   真客户端由各自场景的 `_ready` 发出请求。
		NetBus.local_match_sync.connect(func(payload: Dictionary) -> void:
			if not (payload.get("options", {}) as Dictionary).is_empty():
				_got_match_options = true)
		NetBus.rpc_id(1, "match_sync")
		NetBus.local_round_state.connect(func(data: Dictionary) -> void:
			if not _got_round_state:
				_got_round_state = true
				print("PROBE[%s]: round_state state=%s names=%s" % [who,
						str(data.get("state", -1)), str(data.get("names", {}))])
			if int(data.get("state", -1)) == 0 and (data.get("names", {}) as Dictionary).size() >= 2:
				if not _got_display_names:
					_got_display_names = true
					print("PROBE[%s]: 昵称表已广播 ✓" % who))
		NetBus.local_snapshot_world.connect(func(_snap: Dictionary) -> void:
			_snap_count += 1)
		# 对局验证窗:再收 3 秒快照,汇总断言
		await get_tree().create_timer(3.0).timeout
		var problems: Array = []
		if not _got_round_state:
			problems.append("未收到 round_state")
		if not _got_display_names:
			problems.append("昵称表未广播(round_state 载荷里 names 不足 2 项)")
		if not _got_match_options:
			problems.append("未收到 match_options")
		if _snap_count < 30:
			problems.append("快照过少 %d(<30,60Hz 应≈180)" % _snap_count)
		if problems.is_empty():
			_finish(true, who, "match_start+round_state+昵称表+match_options+%d 快照 全部通过" % _snap_count)
		else:
			_finish(false, who, "; ".join(problems)))

func _to_worker(who: String, role: int, port: int) -> void:
	PvpSession.role = role
	multiplayer.connected_to_server.connect(func() -> void:
		print("PROBE[%s]: 已连 worker,claim role %d" % [who, role])
		NetBus.rpc_id(1, "claim_role", role, who.to_upper())
		NetBusExt.rpc_id(1, "player_options", {"hue": 0.0}), CONNECT_ONE_SHOT)
	multiplayer.connection_failed.connect(func() -> void:
		_finish(false, who, "连 worker 失败"), CONNECT_ONE_SHOT)
	NetBus.stop()
	var err := NetBus.start_client("127.0.0.1", port)
	if err != OK:
		_finish(false, who, "start_client(worker) 失败 %d" % err)
