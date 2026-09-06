extends Node

# 1v1 匹配 UI 自动化测试(复现「点房间列表里的房间连不进去」+ AI 对战观察):
#   --role=create : 点「建房」→ 等状态栏出现房间号 → 写 user://mm_room.txt → 等 pvp_game
#                   (加 --ai:建房后点「AI 对战」并观察 AI 是否真的在动)
#   --role=list   : 等列表自动刷新出现房间按钮 → 点第一个房间按钮(复现用户操作)→ 等 pvp_game
# 结果写 user://mm_test_result_<index>.txt。挂 root 存活场景切换。

var _role := "create"
var _index := 1

func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--role="):
			_role = a.trim_prefix("--role=")
		elif a.begins_with("--index="):
			_index = int(a.trim_prefix("--index="))
	_run()

func _run() -> void:
	# 实例化 matchmaking 并接管 current_scene(本节点挂 root 存活,后续 go_match 转场正常)
	var mm: Control = load("res://Scenes/matchmaking.tscn").instantiate()
	get_tree().root.add_child.call_deferred(mm)
	await get_tree().process_frame
	await get_tree().process_frame
	if is_instance_valid(mm):
		get_tree().current_scene = mm
	# 等匹配场景就绪
	for i in range(60):
		await get_tree().create_timer(0.5).timeout
		var cur := get_tree().current_scene
		if cur == mm:
			break
	var mm2 := get_tree().current_scene
	if mm2 != mm:
		_fail("未进入 matchmaking 场景")
		return
	mm._addr_edit.text = "127.0.0.1"   # 测试指向本机服务器(不污染云服)
	print("MM[%d]: 匹配场景就绪" % _index)
	await get_tree().create_timer(1.0).timeout

	if _role == "create":
		_press(mm, "建房")
		# 等状态栏出现房间号
		var code := ""
		for i in range(40):
			await get_tree().create_timer(0.5).timeout
			var st: String = mm._status.text
			if st.begins_with("房间号 "):
				code = st.substr(3, 4)
				break
		print("MM[%d]: 建房结果 code=%s" % [_index, code])
		if code == "":
			_fail("建房无房间号 status=" + mm._status.text)
			return
		FileAccess.open("user://mm_room.txt", FileAccess.WRITE).store_string(code)
		if "--ai" in OS.get_cmdline_user_args():
			await get_tree().create_timer(1.0).timeout
			_press(mm, "AI对战")   # 点「AI 对战」按钮(实验性 AI 补位)
			print("MM[%d]: 已点 AI 对战" % _index)
			await _watch_ai(_index)
			return
		await _wait_game(_index)

	elif _role == "list":
		# 等自动刷新把房间列表填上(最多 25s)
		var btn: Button = null
		for i in range(50):
			await get_tree().create_timer(0.5).timeout
			var box: VBoxContainer = mm._list_box
			for c in box.get_children():
				if c is Button:
					btn = c
					break
			if btn != null:
				break
		if btn == null:
			_fail("房间列表没有出现任何房间 status=" + mm._status.text)
			return
		# 模拟真实用户:点列表房间 → 失败(陈旧房间)会触发自动刷新重建列表 → 再点,最多 4 次
		for attempt in range(4):
			var box: VBoxContainer = mm._list_box
			for c in box.get_children():
				if c is Button:
					btn = c
					break
			if btn == null:
				await get_tree().create_timer(1.0).timeout
				continue
			print("MM[%d]: 第%d次点击列表房间 [%s]" % [_index, attempt + 1, btn.text])
			btn.pressed.emit()
			var entered := false
			for i in range(16):   # 8s 内看结果(失败会触发自动刷新重建列表)
				await get_tree().create_timer(0.5).timeout
				var cur := get_tree().current_scene
				if cur != null and cur.scene_file_path.ends_with("pvp_game.tscn"):
					entered = true
					break
			if entered:
				print("MM[%d]: SUCCESS 已进对局场景" % _index)
				var f := FileAccess.open("user://mm_test_result_%d.txt" % _index, FileAccess.WRITE)
				f.store_string("entered=true\n")
				get_tree().quit(0)
				return
		_fail("4 次点击均未进对局 status=" + mm._status.text)


func _wait_game(idx: int) -> void:
	# 等 pvp_game 场景(最多 40s)
	for i in range(80):
		await get_tree().create_timer(0.5).timeout
		var cur := get_tree().current_scene
		if cur != null and cur.scene_file_path.ends_with("pvp_game.tscn"):
			print("MM[%d]: SUCCESS 已进对局场景" % idx)
			var f := FileAccess.open("user://mm_test_result_%d.txt" % idx, FileAccess.WRITE)
			f.store_string("entered=true\n")
			get_tree().quit(0)
			return
	var mm := get_tree().current_scene
	var st: String = mm._status.text if mm != null and "_status" in mm else "<scene=%s>" % (mm.scene_file_path if mm != null else "null")
	_fail("40s 未进对局 status=" + st)


# AI 对局观察:进 pvp_game 后盯快照,验证 AI(role2)真的在动
# (注意:GDScript lambda 按值捕获局部变量 → 计数必须放字典里按引用改)
func _watch_ai(idx: int) -> void:
	Settings.wheel_switch = true
	var stat := {"snaps": 0, "ai_moved": false, "ai_pos": Vector2.INF,
			"r1_w": -1, "r1_switched": false}
	var on_snap := func(s: Dictionary) -> void:
		stat["snaps"] += 1
		var players: Dictionary = s.get("players", {})
		var p2: Dictionary = players.get("2", {})
		if not p2.is_empty():
			var pos: Vector2 = p2.get("pos", Vector2.INF)
			if stat["ai_pos"] != Vector2.INF and pos.distance_to(stat["ai_pos"]) > 12.0:
				stat["ai_moved"] = true
			stat["ai_pos"] = pos
		# 服务器权威槽位(role1)变化 = 滚轮切枪确实同步到了服务器
		var w1: int = int(players.get("1", {}).get("weapon", 0))
		if stat["r1_w"] == -1:
			stat["r1_w"] = w1
		elif w1 != stat["r1_w"]:
			stat["r1_switched"] = true
			stat["r1_w"] = w1
	NetBus.local_snapshot.connect(on_snap)
	for i in range(40):   # 20s
		await get_tree().create_timer(0.5).timeout
		if i % 8 == 3:   # 每 4s 注入一次滚轮上滚
			var ev := InputEventMouseButton.new()
			ev.button_index = MOUSE_BUTTON_WHEEL_UP
			ev.pressed = true
			Input.parse_input_event(ev)
		if i % 4 == 0:
			print("MM[%d]: t=%.1f snaps=%d ai_moved=%s r1_switched=%s" %
					[idx, i * 0.5, stat["snaps"], stat["ai_moved"], stat["r1_switched"]])
	NetBus.local_snapshot.disconnect(on_snap)
	var f := FileAccess.open("user://mm_test_result_%d.txt" % idx, FileAccess.WRITE)
	f.store_string("entered=true\nai_moved=%s\nsnaps=%d\nr1_switched=%s\n" %
			[stat["ai_moved"], stat["snaps"], stat["r1_switched"]])
	print("MM[%d]: AI WATCH DONE ai_moved=%s r1_switched=%s snaps=%d" %
			[idx, stat["ai_moved"], stat["r1_switched"], stat["snaps"]])
	get_tree().quit(0 if (stat["ai_moved"] and stat["r1_switched"]) else 1)


func _press(n: Node, text: String) -> void:
	for c in n.get_children():
		if c is Button and (c as Button).text.replace(" ", "").begins_with(text.replace(" ", "")):
			print("MM[%d]: 点击 %s" % [_index, (c as Button).text])
			(c as Button).pressed.emit()
			return
		_press(c, text)


func _fail(msg: String) -> void:
	print("MM[%d]: FAIL %s" % [_index, msg])
	var f := FileAccess.open("user://mm_test_result_%d.txt" % _index, FileAccess.WRITE)
	f.store_string("entered=false\nreason=%s\n" % msg)
	get_tree().quit(1)
