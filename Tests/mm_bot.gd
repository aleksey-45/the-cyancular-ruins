extends Node

# 1v1 匹配 UI 自动化测试(复现「点房间列表里的房间连不进去」):
#   --role=create : 点「建房」→ 等状态栏出现房间号 → 写 user://mm_room.txt → 等 pvp_game
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
		_wait_game(_index)

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
