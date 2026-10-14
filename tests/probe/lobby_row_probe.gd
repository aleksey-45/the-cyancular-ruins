extends Node

# 统一大厅(mp_lobby)房卡逻辑自动化探针
# 验证标准：输出 "LOBBY ROW PROBE: ALL-OK"

const EXPECTED_CHECKS := 15

# 满员房间(5678)置于前，用于验证未满员优先排序逻辑
const ROWS_1V1 := [
	{"code": "5678", "count": 2, "names": ["阿甲", "bob"], "in_match": true},
	{"code": "1234", "count": 1, "names": ["阿甲"], "in_match": false},
]
const ROWS_N := [
	{"code": "5678", "count": 2, "max_players": 4, "names": ["阿甲", "bob"], "in_match": true},
	{"code": "1234", "count": 1, "max_players": 4, "names": ["阿甲"], "in_match": false},
]

var _checks := 0
var _fails: Array[String] = []


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if ok:
		print("  ok   " + what)
	else:
		_fails.append(what)
		print("  FAIL " + what)


func _ready() -> void:
	_check_page([ROWS_1V1, ROWS_N, ROWS_N], [PvpSession.MODE_PVP,
			PvpSession.MODE_ROYALE, PvpSession.MODE_TEAM])
	_check_join_error()
	_finish()


func _finish() -> void:
	if _checks != EXPECTED_CHECKS:
		_fails.append("实际执行断言数 %d 与预期 EXPECTED_CHECKS=%d 不一致"
				% [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("LOBBY ROW PROBE: ALL-OK(%d 条断言)" % _checks)
		get_tree().quit(0)
	else:
		print("LOBBY ROW PROBE: %d 条失败" % _fails.size())
		for f in _fails:
			print("  ✗ " + f)
		get_tree().quit(1)


# 传入 1v1、大乱斗与 3v3 数据，验证对局中房卡不可点击、普通房卡可点击
func _check_page(rows_per_mode: Array, modes: Array) -> void:
	var p: Node = (load("res://scenes/mp_lobby.tscn") as PackedScene).instantiate()
	p.set("_grid", GridContainer.new())
	p.set("_status", Label.new())
	var rooms: Array = []
	for i in modes.size():
		for row: Dictionary in rows_per_mode[i]:
			var entry := row.duplicate()
			entry["mode"] = modes[i]
			rooms.append(entry)
	p.call("_on_rooms", rooms)
	var grid: Node = p.get("_grid")
	var live := _find_card(grid, "5678")     # 对局中的房卡
	var open_ := _find_card(grid, "1234")    # 未开始的房卡
	_check(live != null and open_ != null,
			"合并后两种卡都在网格里(live=%s / 普通=%s)" % [str(live), str(open_)])
	if live == null or open_ == null:
		p.free()
		return
	_check(live.disabled, "对局中的房卡 disabled 应为 true")
	_check(live.pressed.get_connections().is_empty(),
			"对局中的房卡未连接点击事件处理")
	_check(live.focus_mode == Control.FOCUS_NONE,
			"对局中的房卡焦点模式为 FOCUS_NONE")
	_check(live.modulate.a < 1.0, "对局中的房卡整体透明度降低(modulate.a=%.2f)" % live.modulate.a)
	_check(_has_label_text(live, "对局中"), "对局中的房卡显示「对局中」角标")
	_check(not open_.disabled, "普通房卡 disabled 应为 false")
	_check(open_.pressed.get_connections().size() == 1,
			"普通房卡已连接点击事件处理")
	# 排序检查：未满房间应排在满员房间前面
	var first: Node = grid.get_child(0)
	var first_code := ""
	if first is Button:
		first_code = str((first as Button).get_meta("code", ""))
	_check(first_code == "1234",
			"排序: 未满房间排在满员房间前(网格首张房号: %s, 期望 1234)" % first_code)
	_check(p.call("_card_subtitle", PvpSession.MODE_TEAM,
			{"is_public": true, "team_counts": {0: 1, 1: 2, 2: 3}}) == "公开 · A2 / B3 / 未选1",
			"Variant 整数队伍编号正确显示房卡人数")
	p.free()


func _check_join_error() -> void:
	var p: Node = load("res://scenes/mp_lobby.tscn").instantiate()
	p.set("_status", Label.new())
	p.set("_ack", false)
	p.set("_sent_ms", 100)
	p.set("_join_pending", "00004321")
	p.call("_on_server_message", "房间不存在")
	_check(p.get("_ack"), "加入拒绝有应答")
	_check(p.get("_sent_ms") == 0, "加入拒绝关闭超时计时")
	_check(p.get("_join_pending") == "", "加入拒绝清空待加入房号")
	_check(p.get("_status").text == "房间不存在", "错误直接显示")
	p.call("_on_server_message", "房间已满")
	_check(p.get("_status").text == "房间已满", "第二次错误直接显示")
	p.free()


# 根据 meta 查找对应房号的按钮
func _find_card(grid: Node, code: String) -> Button:
	for c in grid.get_children():
		if c is Button and str((c as Button).get_meta("code", "")) == code:
			return c
	return null


func _has_label_text(node: Node, needle: String) -> bool:
	if node is Label and (node as Label).text.contains(needle):
		return true
	for c in node.get_children():
		if _has_label_text(c, needle):
			return true
	return false
