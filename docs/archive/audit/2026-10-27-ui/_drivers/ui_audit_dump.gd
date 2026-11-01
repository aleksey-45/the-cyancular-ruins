extends Node

# 【一次性】UI 排版审计几何量取器(scratch,收尾删除)。给每个 UI 状态打印控件 rect/min_size,用真实布局数据查重叠/溢出。
# 用法: "<GODOT>" --path . --quit-after 3600 res://audit_shots/ui_audit_dump.tscn -- [流程名 ...]
#   main settings info beta lobby create wait results royale(不给参数 = 全跑)
# ★ 只打印,不存图,可以带 --headless? 不行:headless 下控件树照样建,但本项目 headless 启动也要写 user://;本机已放开权限,带窗口跑最稳。

var _fails := 0


func _ready() -> void:
	await get_tree().process_frame
	var argv := OS.get_cmdline_user_args()
	var want: Array = ["main", "settings", "info", "beta", "lobby", "create", "wait", "results", "royale"] \
			if argv.is_empty() else argv
	for n in want:
		var m := "_dump_" + str(n)
		if not has_method(m):
			print("DUMP: FAIL 无此流程 %s" % str(n))
			_fails += 1
			continue
		print("DUMP: ==== %s ====" % str(n))
		await call(m)
	print("DUMP: DONE fails=%d" % _fails)
	get_tree().quit(0)


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func _reset() -> void:
	get_tree().paused = false
	NetBus.stop()
	for c in get_children():
		remove_child(c)
		c.queue_free()
	await _frames(3)


func _spawn(path: String) -> Node:
	var ps: PackedScene = load(path)
	if ps == null:
		print("DUMP: FAIL load %s" % path)
		_fails += 1
		return null
	var n: Node = ps.instantiate()
	add_child(n)
	return n


func _r(c: Control) -> String:
	var gr := c.get_global_rect()
	var mn := c.get_combined_minimum_size()
	return "rect=(%d,%d %dx%d) min=(%d,%d) vis=%s" % [
			int(gr.position.x), int(gr.position.y), int(gr.size.x), int(gr.size.y),
			int(mn.x), int(mn.y), str(c.visible)]


func _p_ctl(c: Control, depth: int) -> void:
	print("%s%s [%s] %s" % ["  ".repeat(depth), c.name, c.get_class(), _r(c)])


func _walk(n: Node, depth: int, max_depth: int) -> void:
	for c in n.get_children():
		if c is Control:
			if depth <= max_depth:
				_p_ctl(c as Control, depth)
			if depth < max_depth:
				_walk(c, depth + 1, max_depth)
		elif depth <= max_depth:
			print("%s%s [%s]" % ["  ".repeat(depth), c.name, c.get_class()])
			if depth < max_depth:
				_walk(c, depth + 1, max_depth)


func _by_name(n: Node, target: String) -> Control:
	if n is Control and str(n.name) == target:
		return n as Control
	for c in n.get_children():
		var r := _by_name(c, target)
		if r != null:
			return r
	return null


func _dump_main() -> void:
	await _reset()
	var mm := _spawn("res://scenes/main_menu.tscn")
	if mm == null:
		return
	await _wait(1.3)
	print("main_menu 顶层:")
	_walk(mm, 1, 6)


func _dump_settings() -> void:
	await _reset()
	var s := _spawn("res://scenes/settings_menu.tscn")
	if s == null:
		return
	await _wait(0.6)
	print("settings 根->两栏:")
	_walk(s, 1, 3)
	for nm in ["恢复默认键位", "返 回（Esc）"]:
		var b := _find_button_text(s, nm)
		if b != null:
			print("button %s: %s" % [nm, _r(b)])


func _find_button_text(n: Node, text: String) -> Control:
	for c in n.get_children():
		if c is Button and str((c as Button).text).replace(" ", "") == text.replace(" ", ""):
			return c as Button
		var r := _find_button_text(c, text)
		if r != null:
			return r
	return null


func _dump_info() -> void:
	await _reset()
	var info := _spawn("res://scenes/info_menu.tscn")
	if info == null:
		return
	await _wait(0.6)
	_walk(info, 1, 3)


func _dump_beta() -> void:
	await _reset()
	var b := _spawn("res://scenes/beta_menu.tscn")
	if b == null:
		return
	await _wait(0.6)
	_walk(b, 1, 4)


func _dump_lobby() -> void:
	await _reset()
	PvpSession.server_address = "127.0.0.1"
	var lobby := _spawn("res://scenes/mp_lobby.tscn")
	if lobby == null:
		return
	await _wait(1.2)
	print("lobby 顶层控件:")
	_walk(lobby, 1, 1)
	print("card grid / 状态栏:")
	var grid := _by_name(lobby, "CardGrid")
	if grid != null:
		_p_ctl(grid, 0)
	for c in lobby.get_children():
		if c is Control and str(c.name).begins_with("PanelContainer"):
			_p_ctl(c as Control, 0)
	# 注入 6 间假房,再看每张卡的真实 rect 与最小尺寸
	var fake := {
		"pvp": [
			{"code": "2468", "is_public": true, "players": 1, "max_players": 2, "host": "小明",
					"map": "res://maps/newfactory.cyrm", "names": ["小明"]},
			{"code": "1357", "is_public": false, "players": 2, "max_players": 2, "host": "Anon",
					"map": "res://maps/demo.cyrm", "names": ["Anon", "小红"]},
		],
		"royale": [
			{"code": "8642", "is_public": true, "players": 3, "max_players": 8, "host": "甲",
					"map": "res://maps/demo.cyrm", "match_time": 300, "names": ["甲", "乙", "丙"]},
			{"code": "9753", "is_public": true, "players": 5, "max_players": 6,
					"host": "LongEnglishHostName", "map": "res://maps/newfactory.cyrm",
					"match_time": 600,
					"names": ["LongEnglishHostName", "乙", "丙", "丁", "戊"]},
		],
		"team": [
			{"code": "1111", "is_public": true, "players": 4, "max_players": 6, "host": "队长",
					"map": "res://maps/newfactory.cyrm", "team_counts": {"0": 1, "1": 2, "2": 1},
					"names": ["队长", "乙", "丙", "丁"]},
			{"code": "2222", "is_public": true, "players": 6, "max_players": 6, "host": "满房",
					"map": "res://maps/demo.cyrm", "team_counts": {"0": 0, "1": 3, "2": 3},
					"names": ["满房", "乙", "丙", "丁", "戊", "己"]},
		],
	}
	for m in ["pvp", "royale", "team"]:
		lobby.call("_ingest_rooms", m, fake[m])
	await _frames(4)
	print("卡片(注入 6 间后):")
	for c in (grid as Control).get_children():
		if c is Control:
			var cc := c as Control
			if cc is Button:
				var btn := cc as Button
				print("  card %s: %s child_min=%s" % [str(btn.get_meta("code", "?")), _r(btn),
						str((btn.get_child(0) as Control).get_combined_minimum_size())])
			else:
				_p_ctl(cc, 1)


func _dump_create() -> void:
	await _reset()
	PvpSession.server_address = "127.0.0.1"
	var lobby := _spawn("res://scenes/mp_lobby.tscn")
	if lobby == null:
		return
	await _wait(1.0)
	lobby.call("_open_create_dialog")
	await _frames(4)
	print("create dialog 面板:")
	_walk(lobby, 1, 3)
	var dp := _by_name(lobby, "CreatePanel")
	if dp != null:
		print("CreatePanel: %s" % _r(dp as Control))
	# 地图块
	var mb := _by_name(lobby, "MapBlock")
	if mb != null:
		print("MapBlock: %s" % _r(mb as Control))
		var sc := _find_scroll(mb)
		if sc != null:
			print("map picker scroll: %s" % _r(sc))
			var grid := _find_grid(sc)
			if grid != null:
				print("map grid: %s" % _r(grid))
				for c in grid.get_children():
					if c is Control:
						_p_ctl(c as Control, 1)


func _find_scroll(n: Node) -> ScrollContainer:
	if n is ScrollContainer:
		return n
	for c in n.get_children():
		var r := _find_scroll(c)
		if r != null:
			return r
	return null


func _find_grid(n: Node) -> GridContainer:
	if n is GridContainer:
		return n
	for c in n.get_children():
		var r := _find_grid(c)
		if r != null:
			return r
	return null


func _dump_wait() -> void:
	await _reset()
	PvpSession.server_address = "127.0.0.1"
	var lobby := _spawn("res://scenes/mp_lobby.tscn")
	if lobby == null:
		return
	await _wait(1.0)
	var wait = lobby.get("_wait")
	var state := {
		"code": "1111", "is_public": true,
		"players": [{"role": 1, "name": "小明", "team": 1},
				{"role": 2, "name": "Anon", "team": 2},
				{"role": 3, "name": "小红", "team": 1},
				{"role": 4, "name": "A_Very_Long_Player_Name", "team": 2},
				{"role": 5, "name": "戊", "team": 0}],
		"your_role": 2, "host_role": 1, "team_size": 3,
	}
	wait.call("show", state, PvpSession.MODE_TEAM)
	await _frames(4)
	var wp := _by_name(lobby, "WaitPanel")
	if wp != null:
		print("WaitPanel: %s" % _r(wp as Control))
	_walk(wp, 1, 2)


func _dump_results() -> void:
	await _reset()
	var mr := _spawn("res://ui/screens/match_result.tscn")
	if mr == null:
		return
	var team := {
		"stats": {
			1: {"kills": 9, "deaths": 4, "assists": 3, "dealt": 3000, "taken": 1200, "acs": 260},
			2: {"kills": 7, "deaths": 5, "assists": 5, "dealt": 2500, "taken": 1400, "acs": 230},
			3: {"kills": 5, "deaths": 6, "assists": 7, "dealt": 2000, "taken": 1600, "acs": 200},
			4: {"kills": 8, "deaths": 6, "assists": 2, "dealt": 2700, "taken": 1500, "acs": 240},
			5: {"kills": 4, "deaths": 7, "assists": 6, "dealt": 1800, "taken": 1700, "acs": 190},
			6: {"kills": 2, "deaths": 9, "assists": 1, "dealt": 900, "taken": 2100, "acs": 120},
		},
		"rounds_won": {1: 2, 2: 0},
		"match_winner": 1,
		"mvp": 2,
	}
	mr.call("show_result", MatchResultPayload.for_team(team, {
		1: "小明", 2: "Anon", 3: "小红", 4: "丁", 5: "戊", 6: "A_Very_Long_Player_Name"},
		{1: 1, 2: 1, 3: 1, 4: 2, 5: 2, 6: 2}, 1))
	await _frames(4)
	_walk(mr, 1, 4)


func _dump_royale() -> void:
	await _reset()
	PvpSession.map_path = "res://maps/newfactory.cyrm"
	PvpSession.spawn = Vector2i(24, 12)
	PvpSession.role = 1
	PvpSession.player_name = "小明"
	var g := _spawn("res://scenes/royale_game.tscn")
	if g == null:
		return
	await _wait(1.4)
	var hud = g.find_child("RoyaleHud", true, false)
	if hud != null:
		hud.call("_on_round_state", {"state": 1, "timer": 245.0,
				"names": {1: "小明", 2: "Anon", 3: "小红", 4: "A_Very_Long_Player_Name",
						5: "戊", 6: "己"},
				"alive": {1: true, 2: false, 3: true, 4: true, 5: false, 6: true},
				"left": [], "deaths": {1: 1, 2: 3, 3: 2, 4: 0, 5: 4, 6: 1},
				"scores": {1: 6, 2: 3, 3: 4, 4: 7, 5: 1, 6: 2}, "grace": {6: 42.0}})
		await _frames(3)
		print("RoyaleHud 子树:")
		_walk(hud, 1, 2)
		var mm = g.find_child("Minimap", true, false)
		if mm != null and mm is Control:
			print("Minimap: %s" % _r(mm as Control))
	var pp = g.find_child("PingWrap", true, false)
	if pp != null and pp is Control:
		print("PingWrap: %s" % _r(pp as Control))
