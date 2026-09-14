extends Control

# 日志监看器(DevTools/gamelog):浏览 gamelogs/ 下的每次运行会话。
# 左=会话列表(新→旧,绿=正常 黄=异常 红=崩溃);右=选中会话的 report.txt 全文。
# 数据由 tools/gamelog/capture_session.ps1 产生(启动器 bat 调用),本工具只读。

const FONT := "res://assets/fonts/less_perfect_dos_vga.ttf"
const GREEN := Color(0.6, 1.0, 0.7)
const YELLOW := Color(0.95, 0.9, 0.6)
const RED := Color(1.0, 0.62, 0.55)
const CYAN := Color(0.55, 0.95, 1.0)

var _list: ItemList = null
var _view: TextEdit = null
var _sessions: Array = []   # [{dir, name, verdict, color}]

func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Color(0.07, 0.09, 0.13)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var title := _label("运行日志监看器 —— 每次游戏进程的启动/结束/退出原因(gamelogs/)", 26, CYAN)
	title.position = Vector2(20, 12)
	add_child(title)
	var row := HBoxContainer.new()
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.offset_left = 20
	row.offset_top = 52
	row.offset_right = -20
	row.offset_bottom = -20
	row.add_theme_constant_override("separation", 14)
	add_child(row)

	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(520, 0)
	row.add_child(left)
	var brow := HBoxContainer.new()
	brow.add_theme_constant_override("separation", 8)
	left.add_child(brow)
	brow.add_child(_btn("刷新", 22, _refresh))
	brow.add_child(_btn("打开会话文件夹", 22, func() -> void:
		if _sessions.size() > 0 and _list.selected >= 0:
			OS.shell_open(ProjectSettings.globalize_path(_sessions[_list.selected]["dir"]))
		else:
			OS.shell_open(ProjectSettings.globalize_path("res://gamelogs"))))
	var tip := _label("结论颜色:绿=正常  黄=异常退出  红=崩溃。点击条目查看中文报告。", 16, Color(0.75, 0.8, 0.85))
	tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tip.custom_minimum_size = Vector2(500, 0)
	left.add_child(tip)
	_list = ItemList.new()
	_list.custom_minimum_size = Vector2(520, 1280)
	_list.item_selected.connect(func(idx: int) -> void: _show(idx))
	left.add_child(_list)

	var right := VBoxContainer.new()
	right.custom_minimum_size = Vector2(1300, 0)
	row.add_child(right)
	right.add_child(_label("会话报告(report.txt):", 20, CYAN))
	_view = TextEdit.new()
	_view.custom_minimum_size = Vector2(1300, 1240)
	_view.editable = false
	_view.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_view.add_theme_font_size_override("font_size", 18)
	right.add_child(_view)
	_refresh()

func _refresh() -> void:
	_list.clear()
	_sessions.clear()
	# 两个来源:启动器会话(gamelogs/<stamp>_<game|server>/)+ 后台看守归档(gamelogs/archive/<stamp>_<exe>/)
	# 监看器统一浏览:有 report.txt 读结论;只有 run.json(看守)则从 JSON 判定并现场合成中文报告
	var root := ProjectSettings.globalize_path("res://gamelogs")
	var roots := [root, root + "/archive"]
	for r in roots:
		var dir := DirAccess.open(r)
		if dir == null:
			continue
		var names: Array = []
		for d in dir.get_directories():
			names.append(d)
		names.sort()
		names.reverse()   # 新→旧
		for name in names:
			var session_dir: String = r + "/" + name
			var rpath: String = session_dir + "/report.txt"
			var jpath: String = session_dir + "/run.json"
			var verdict := "未知"
			var color := Color(0.7, 0.7, 0.7)
			var src := "launcher"
			if FileAccess.file_exists(rpath):
				var txt := FileAccess.get_file_as_string(rpath)
				var idx := txt.find("【退出结论】")
				if idx >= 0:
					var seg := txt.substr(idx, 220)
					if seg.contains("[OK]"):
						verdict = "正常"; color = GREEN
					elif seg.contains("[X]"):
						verdict = "崩溃"; color = RED
					elif seg.contains("[!]"):
						verdict = "异常"; color = YELLOW
			elif FileAccess.file_exists(jpath):
				src = "watcher"
				var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(jpath))
				if typeof(parsed) == TYPE_DICTIONARY:
					var crash: bool = bool(parsed.get("crash", {}).get("detected", false)) 							or parsed.get("crash") != null and typeof(parsed.get("crash")) == TYPE_DICTIONARY 							and bool((parsed["crash"] as Dictionary).get("detected", false))
					verdict = "崩溃" if crash else "正常"
					color = RED if crash else GREEN
			var display: String = name + "  [" + verdict + "]" + ("  (后台)" if src == "watcher" else "")
			var idx2 := _list.add_item(display)
			_list.set_item_metadata(idx2, session_dir)
			_list.set_item_custom_fg_color(idx2, color)
			_sessions.append({"dir": session_dir, "name": name, "verdict": verdict,
					"color": color, "src": src})

func _show(idx: int) -> void:
	if idx < 0 or idx >= _sessions.size():
		return
	var rpath: String = _sessions[idx]["dir"] + "/report.txt"
	if FileAccess.file_exists(rpath):
		_view.text = FileAccess.get_file_as_string(rpath)
		return
	# 后台看守会话:无 report.txt 时从 run.json 合成中文报告
	var jpath: String = _sessions[idx]["dir"] + "/run.json"
	if not FileAccess.file_exists(jpath):
		_view.text = "该会话没有 report.txt / run.json(捕获中断)"
		return
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(jpath))
	if typeof(parsed) != TYPE_DICTIONARY:
		_view.text = "run.json 解析失败"
		return
	var j: Dictionary = parsed
	var txt := "【会话报告】(后台看守捕获;直接双击 exe 启动的运行由它记录)
"
	txt += "运行程序: " + ", ".join(j.get("exes", [])) + "
"
	txt += "启动时间: " + str(j.get("started_at", "?")) + "
"
	txt += "结束时间: " + str(j.get("ended_at", "?")) + "
"
	txt += "运行时长: " + str(j.get("duration_s", "?")) + " 秒
"
	var crash: Dictionary = j.get("crash", {}) if typeof(j.get("crash")) == TYPE_DICTIONARY else {}
	if bool(crash.get("detected", false)):
		txt += "退出结论: [X] 崩溃 —— 异常代码 " + str(crash.get("exception_code", "?")) 				+ ",故障模块 " + str(crash.get("faulting_module", "?")) 				+ "(偏移 " + str(crash.get("faulting_offset", "?")) + ")
"
	else:
		txt += "退出结论: [OK] 正常结束(未发现崩溃记录)
"
	txt += "捕获日志: " + str((j.get("logs", []) as Array).size()) + " 份
"
	_view.text = txt

func _label(text: String, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	var pf: FontFile = load(FONT)
	if pf != null:
		l.add_theme_font_override("font", pf)
	return l

func _btn(text: String, size: int, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", size)
	var pf: FontFile = load(FONT)
	if pf != null:
		b.add_theme_font_override("font", pf)
	b.pressed.connect(cb)
	return b
