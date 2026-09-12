extends Control

# 地图导入工具(DevTools):把 .cyrm 地图文件**拖进本窗口**即导入到项目 map/ 目录;
# 也可点「选择文件导入…」。导入后立即被全部模式的「地图选择」下拉看到。
# 跑法:DevTools/launch_map_importer.bat,或 Godot 打开 res://DevTools/map_importer.tscn

const MAP_DIR := "res://map"

var _log: Label = null
var _dialog: FileDialog = null


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Color(0.07, 0.09, 0.13)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	var vb := VBoxContainer.new()
	vb.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vb.offset_left = 80
	vb.offset_right = -80
	vb.offset_top = 80
	vb.offset_bottom = -80
	vb.add_theme_constant_override("separation", 18)
	add_child(vb)
	var title := Label.new()
	title.text = "地图导入工具"
	title.add_theme_font_size_override("font_size", 44)
	title.add_theme_color_override("font_color", Color(0.55, 0.95, 1.0))
	vb.add_child(title)
	var tip := Label.new()
	tip.text = ("把 .cyrm 地图文件直接拖进本窗口即可导入到项目 map/ 目录(v3 格式与旧格式均可,\n"
			+ "旧格式加载时自动 2x2 转换)。重名文件自动加时间码后缀,不会覆盖。\n"
			+ "导入后:主菜单「单人开局」/ 多人对战 / 大乱斗建房页的「地图」下拉立即可选。\n"
			+ "联机注意:地图文件要在**开服方**的 map/ 目录里也有一份(服务端按文件名加载)。")
	tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	tip.add_theme_font_size_override("font_size", 22)
	tip.add_theme_color_override("font_color", Color(0.75, 0.8, 0.85))
	vb.add_child(tip)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	vb.add_child(row)
	var pick := Button.new()
	pick.text = "选择文件导入…"
	pick.custom_minimum_size = Vector2(240, 52)
	pick.add_theme_font_size_override("font_size", 22)
	pick.pressed.connect(_on_pick)
	row.add_child(pick)
	var open_dir := Button.new()
	open_dir.text = "打开 map 目录"
	open_dir.custom_minimum_size = Vector2(220, 52)
	open_dir.add_theme_font_size_override("font_size", 22)
	open_dir.pressed.connect(func() -> void:
		DirAccess.make_dir_recursive_absolute(MAP_DIR)
		OS.shell_open(ProjectSettings.globalize_path(MAP_DIR)))
	row.add_child(open_dir)
	_log = Label.new()
	_log.text = "拖入文件,或点上方按钮。"
	_log.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_log.add_theme_font_size_override("font_size", 22)
	_log.custom_minimum_size = Vector2(0, 300)
	vb.add_child(_log)
	get_window().files_dropped.connect(_on_files_dropped)


func _on_pick() -> void:
	if _dialog == null:
		_dialog = FileDialog.new()
		_dialog.access = FileDialog.ACCESS_FILESYSTEM
		_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILES
		_dialog.filters = ["*.cyrm ; Cyancular 地图"]
		_dialog.files_selected.connect(_on_files_picked)
		add_child(_dialog)
	_dialog.popup_centered(Vector2i(900, 600))


func _on_files_picked(paths: PackedStringArray) -> void:
	for p in paths:
		_import(p)


func _on_files_dropped(files: PackedStringArray) -> void:
	for f in files:
		_import(f)


func _import(src: String) -> void:
	if src.get_extension().to_lower() != "cyrm":
		_log.text += "\n[跳过] %s(仅支持 .cyrm)" % src.get_file()
		return
	var fb := FileAccess.open(src, FileAccess.READ)
	if fb == null:
		_log.text += "\n[失败] 读不到 %s" % src
		return
	var bytes := fb.get_buffer(fb.get_length())
	fb.close()
	if bytes.size() < 16 or bytes.size() > 5 * 1024 * 1024:
		_log.text += "\n[失败] %s 尺寸可疑(%d 字节)" % [src.get_file(), bytes.size()]
		return
	var head := bytes.slice(0, 64).get_string_from_utf8()
	var is_v3 := head.contains("cyrm-v3")
	var name := src.get_file()
	var dst := MAP_DIR + "/" + name
	if FileAccess.file_exists(dst):
		dst = "%s/%s_%s.cyrm" % [MAP_DIR, name.get_basename(),
				Time.get_datetime_string_from_system().replace(":", "").replace("-", "")]
	var f := FileAccess.open(dst, FileAccess.WRITE)
	if f == null:
		_log.text += "\n[失败] 写不进 %s" % dst
		return
	f.store_buffer(bytes)
	f.close()
	_log.text += "\n[已导入] %s → %s(%s)" % [name, dst, "v3" if is_v3 else "旧格式(加载时自动转换)"]
