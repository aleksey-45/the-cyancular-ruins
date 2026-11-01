extends Node

# 【一次性】P0 前后核对:标题带内边距/居中 + 设置/信息页内容最小高。headless 可跑(只读几何,不取图)。
# 用法: "<GODOT>" --headless --path . res://audit_shots/ui_p0_measure.tscn

const BORDER := "================================"

var _fails := 0


func _ready() -> void:
	await get_tree().process_frame
	await _measure_settings()
	await _measure_info()
	await _measure_menu_strips()
	await _measure_lobby()
	await _measure_sp_panel()
	print("MEASURE: DONE fails=%d" % _fails)
	get_tree().quit()


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _wait(sec: float) -> void:
	await get_tree().create_timer(sec).timeout


func _reset() -> void:
	NetBus.stop()
	for c in get_children():
		remove_child(c)
		c.queue_free()
	await _frames(3)


func _spawn(path: String) -> Node:
	var ps: PackedScene = load(path)
	var n: Node = ps.instantiate()
	add_child(n)
	return n


func _m(c: Control) -> String:
	var mn := c.get_combined_minimum_size()
	return "min=(%d,%d)" % [int(mn.x), int(mn.y)]


# 每个 HeaderStrip:带 rect / 文字起点 / 左右内边距(实测字形起点,不是 stylebox 声明值)
func _report_strips(root: Node, tag: String) -> void:
	var found := 0
	for n in _all_controls(root):
		var pc := n as PanelContainer
		if pc == null:
			continue
		if pc.theme_type_variation != &"HeaderStrip":
			continue
		var label: Label = null
		for ch in pc.get_children():
			if ch is Label:
				label = ch as Label
				break
		var band := pc.get_global_rect()
		if label == null:
			print("STRIP[%s] %s band=(%d,%d %dx%d) <无 Label>" % [tag, pc.name, int(band.position.x), int(band.position.y), int(band.size.x), int(band.size.y)])
			continue
		var f: Font = label.get_theme_font("font")
		var fs: int = label.get_theme_font_size("font_size")
		var tw := f.get_string_size(label.text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var lr := label.get_global_rect()
		var align := label.horizontal_alignment
		var start_x := lr.position.x
		if align == HORIZONTAL_ALIGNMENT_CENTER:
			start_x = lr.position.x + (lr.size.x - tw) / 2.0
		elif align == HORIZONTAL_ALIGNMENT_RIGHT:
			start_x = lr.position.x + lr.size.x - tw
		var left_gap := start_x - band.position.x
		var right_gap := (band.position.x + band.size.x) - (start_x + tw)
		print("STRIP[%s] %s  align=%d  文字「%s」 左内边距=%.0fpx 右内边距=%.0fpx  带宽=%d" % [
				tag, pc.name, align, label.text, left_gap, right_gap, int(band.size.x)])
		found += 1
	if found == 0:
		print("STRIP[%s] 没找到 HeaderStrip" % tag)


func _all_controls(n: Node) -> Array:
	var out: Array = []
	if n is Control:
		out.append(n)
	for c in n.get_children():
		out.append_array(_all_controls(c))
	return out


func _measure_settings() -> void:
	print("%s SETTINGS" % BORDER)
	await _reset()
	var s := _spawn("res://scenes/settings_menu.tscn")
	await _frames(4)
	var page := s.get_node("MarginContainer1") as Control
	print("MarginContainer: rect=(%d,%d %dx%d) %s" % [int(page.get_global_rect().position.x), int(page.get_global_rect().position.y),
			int(page.get_global_rect().size.x), int(page.get_global_rect().size.y), _m(page)])
	var vbox := s.get_node("MarginContainer1/VBoxContainer1") as Control
	print("页面 VBox: %s" % _m(vbox))
	for ch in vbox.get_children():
		print("  VBox 子 %s [%s] %s" % [ch.name, ch.get_class(), _m(ch as Control)])
	var hbox := s.get_node("MarginContainer1/VBoxContainer1/HBoxContainer1") as Control
	print("两栏 HBox: %s" % _m(hbox))
	var left := hbox.get_child(0) as Control
	var right := hbox.get_child(1) as Control
	print("  左栏 Panel: %s / 右栏 Panel: %s" % [_m(left), _m(right)])
	print("  左栏内 VBox: %s" % _m(left.get_child(0).get_child(0) as Control))
	print("  右栏内 VBox: %s" % _m(right.get_child(0).get_child(0) as Control))
	var bind := _find_node(s, "BindGrid") as Control
	if bind != null:
		print("  BindGrid: %s 子数=%d v_sep=%d h_sep=%d" % [_m(bind), bind.get_child_count(),
				bind.get_theme_constant("v_separation"), bind.get_theme_constant("h_separation")])
	_deep(right, 2, 2)
	_report_strips(s, "settings")


func _measure_info() -> void:
	print("%s INFO" % BORDER)
	await _reset()
	var s := _spawn("res://scenes/info_menu.tscn")
	await _wait(0.3)
	var page := s.get_node("MarginContainer1") as Control
	print("MarginContainer: %s" % _m(page))
	var vbox := s.get_node("MarginContainer1/VBoxContainer1") as Control
	print("页面 VBox: %s" % _m(vbox))
	for ch in vbox.get_children():
		if ch is Control:
			print("  VBox 子 %s [%s] %s" % [ch.name, ch.get_class(), _m(ch as Control)])
	var hbox := s.get_node("MarginContainer1/VBoxContainer1/HBoxContainer1") as Control
	print("两栏 HBox: %s" % _m(hbox))
	for ch in hbox.get_children():
		if ch is Control:
			print("  栏 %s: %s" % [ch.name, _m(ch as Control)])
			_deep(ch, 1, 3)
	_report_strips(s, "info")


func _measure_menu_strips() -> void:
	print("%s MAIN / BETA" % BORDER)
	await _reset()
	var mm := _spawn("res://scenes/main_menu.tscn")
	await _wait(1.2)
	_report_strips(mm, "main")
	await _reset()
	var b := _spawn("res://scenes/beta_menu.tscn")
	await _wait(0.4)
	_report_strips(b, "beta")


func _measure_lobby() -> void:
	print("%s LOBBY" % BORDER)
	await _reset()
	PvpSession.server_address = "127.0.0.1"
	var lobby := _spawn("res://scenes/mp_lobby.tscn")
	await _wait(0.8)
	_report_strips(lobby, "lobby默认")
	lobby.call("_open_create_dialog")
	await _frames(4)
	_report_strips(lobby, "lobby建房弹层")
	var wait = lobby.get("_wait")
	wait.call("show", {"code": "1111", "is_public": true,
			"players": [{"role": 1, "name": "小明"}, {"role": 2, "name": "Anon"}],
			"your_role": 1, "host_role": 1, "count": 2}, PvpSession.MODE_PVP)
	await _frames(4)
	_report_strips(lobby, "lobby等待室")


func _measure_sp_panel() -> void:
	print("%s SP PANEL" % BORDER)
	await _reset()
	var mm := _spawn("res://scenes/main_menu.tscn")
	await _wait(1.2)
	mm.call("_on_single_pressed")
	await _wait(0.4)
	_report_strips(mm, "sp_panel")


func _deep(n: Node, depth: int, max_depth: int) -> void:
	for c in n.get_children():
		if c is Control:
			var ctl := c as Control
			var extra := ""
			if ctl is VBoxContainer or ctl is HBoxContainer or ctl is GridContainer:
				extra = " sep=%d" % ctl.get_theme_constant("separation")
			print("%s%s [%s] %s%s" % ["  ".repeat(depth), ctl.name, ctl.get_class(), _m(ctl), extra])
			if depth < max_depth:
				_deep(ctl, depth + 1, max_depth)


func _find_node(n: Node, name: String) -> Node:
	if str(n.name) == name:
		return n
	for c in n.get_children():
		var r := _find_node(c, name)
		if r != null:
			return r
	return null
