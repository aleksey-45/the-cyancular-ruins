extends Node

# 大乱斗机器人试玩客户端(test 分支):走真实协议建房/加入/开局,进对局后挂
# BotInputSource(随机移动+跳跃边沿+周期开火+旋转瞄准)驱动服务器权威模拟。
# 用法: Godot_console --headless --path . res://Tests/royale_bot.tscn -- --role=create --index=1
#       Godot_console --headless --path . res://Tests/royale_bot.tscn -- --role=join --index=2
# 结果写 user://royale_playtest_result_<index>.txt;房号经 user://royale_playtest_room.txt 传递。

const ROOM_FILE := "royale_playtest_room.txt"
const RUN_SECONDS := 100.0

var _role := "join"
var _index := 1
var _name := "Bot1"
var _match_role := 0
var _snaps := 0
var _downed_count := 0
var _last_pos := Vector2.INF
var _pos_changed := false
var _scores_seen := false
var _winner_seen := false
var _in_game := false
var _elapsed := 0.0
var _result_written := false
var _room_written := false
var _started_sent := false

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--role="):
			_role = a.trim_prefix("--role=")
		elif a.begins_with("--index="):
			_index = int(a.trim_prefix("--index="))
	_name = "Bot%d" % _index
	PvpSession.player_name = _name
	NetBus.local_room_joined.connect(func(r: int) -> void: print("BOT[%d]: joined role=%d" % [_index, r]))
	NetBus.local_go_match.connect(_on_go_match)
	NetBus.local_match_start.connect(_on_match_start)
	NetBus.local_snapshot.connect(func(_s: Dictionary) -> void: _snaps += 1)
	NetBus.local_round_state.connect(_on_round_state)
	# 大乱斗建房/加入不回 room_created:客户端靠 royale_room_state 广播拿房号
	NetBusExt.local_royale_room_state.connect(_on_royale_state)
	multiplayer.connected_to_server.connect(_on_connected, CONNECT_ONE_SHOT)
	multiplayer.connection_failed.connect(func() -> void:
		print("BOT[%d]: FAIL 连接大厅失败" % _index)
		get_tree().quit(1))
	NetBus.start_client("127.0.0.1")

func _on_connected() -> void:
	NetBus.rpc_id(1, "lobby_name", _name)
	if _role == "create":
		NetBusExt.rpc_id(1, "royale_create", {"is_public": true, "invite_code": "", "max_players": 8})
	else:
		var code: String = await _read_room_code()
		if code == "":
			print("BOT[%d]: FAIL 房号文件未就绪" % _index)
			get_tree().quit(1)
			return
		NetBusExt.rpc_id(1, "royale_join", code, "")

func _on_royale_state(state: Dictionary) -> void:
	if _role != "create":
		return
	var code := str(state.get("code", ""))
	if code == "" or not _room_written:
		if code != "" and not _room_written:
			_room_written = true
			print("BOT[%d]: room_created %s" % [_index, code])
			FileAccess.open("user://" + ROOM_FILE, FileAccess.WRITE).store_string(code)
	if bool(state.get("in_match", false)):
		return
	# 房主:凑齐 5 人自动请求开局
	var plist: Array = state.get("players", [])
	if plist.size() >= 5 and not _started_sent:
		_started_sent = true
		NetBusExt.rpc_id(1, "royale_start")
		print("BOT[%d]: royale_start 已发送(%d 人)" % [_index, plist.size()])

func _read_room_code() -> String:
	for i in range(40):   # 最多等 20s
		var f := FileAccess.open("user://" + ROOM_FILE, FileAccess.READ)
		if f != null:
			var c := f.get_as_text().strip_edges()
			if c != "":
				return c
		await get_tree().create_timer(0.5).timeout
	return ""

func _on_go_match(role: int, port: int) -> void:
	print("BOT[%d]: go_match role=%d port=%d" % [_index, role, port])
	_pending = [role, port]
	_do_go.call_deferred()

var _pending := [-1, -1]
func _do_go() -> void:
	if _pending[0] < 0:
		return
	var role: int = _pending[0]
	var port: int = _pending[1]
	_pending = [-1, -1]
	multiplayer.connected_to_server.connect(_claim.bind(role), CONNECT_ONE_SHOT)
	NetBus.stop()
	NetBus.start_client("127.0.0.1", port)

func _claim(role: int) -> void:
	print("BOT[%d]: claim role=%d" % [_index, role])
	NetBus.rpc_id(1, "claim_role", role, _name)

func _on_match_start(role: int, spawn: Vector2i, map_path: String) -> void:
	print("BOT[%d]: match_start role=%d spawn=%s" % [_index, role, spawn])
	_match_role = role
	PvpSession.role = role
	PvpSession.royale = true
	PvpSession.spawn = spawn
	PvpSession.map_path = map_path
	var tree := get_tree()
	var helper := Node.new()
	helper.set_script(load("res://Tests/royale_bot_helper.gd"))
	helper.set("_bot_index", _index)
	tree.root.add_child.call_deferred(helper)
	get_tree().change_scene_to_file.call_deferred("res://Scenes/royale_game.tscn")

func _on_round_state(data: Dictionary) -> void:
	var state := int(data.get("state", 0))
	if int(data.get("match_winner", -1)) >= 0:
		_winner_seen = true
	if data.has("scores"):
		_scores_seen = true
	if state == 3:
		print("BOT[%d]: MATCH_OVER winner=%s" % [_index, data.get("match_winner", "?")])
		_write_result()

func _write_result() -> void:
	if _result_written:
		return
	_result_written = true
	var f := FileAccess.open("user://royale_playtest_result_%d.txt" % _index, FileAccess.WRITE)
	f.store_string("match_role=%d\nin_game=%s\nsnaps=%d\npos_changed=%s\ndowned=%d\nscores_seen=%s\nwinner_seen=%s\n" %
			[_match_role, _in_game, _snaps, _pos_changed, _downed_count, _scores_seen, _winner_seen])
	print("BOT[%d]: RESULT written (snaps=%d pos_changed=%s downed=%d)" % [_index, _snaps, _pos_changed, _downed_count])
