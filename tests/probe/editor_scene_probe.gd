extends Node

# P2 编辑器场景探针:真实例化 editor_root.tscn,走「打开真实地图 → 改一格 → 保存 → 重开 → 再保存」
# 的字节级往返,并检查撤销/重做、校验、画布纹理。
# 去掉什么它才会红:
#   ① 编辑器场景构建失败/缺 API ⇒ ① 组红;
#   ② EditorIO 打开 .cyrm 不迁移/不解码 ⇒ ② 组红;
#   ③ EditorDoc.set_cells 没落到 map(改完读回不一致)⇒ ③ 组红;
#   ④ 保存链 encode/write 丢数据 ⇒ ⑩ 组「重开再存字节相等」红;
#   ⑤ undo/redo 不工作 ⇒ ④ 组红;
#   ⑥ 画布没建视口纹理 ⇒ ⑤ 组红。
# 判据 = 未跑满条数 + 失败清单;退出码只是陪衬。

const EXPECTED_CHECKS := 25
const MAP := "res://maps/newfactory.cyrm"
const A := "user://maps/_editor_scene_probe_a.cyrm"
const EXPORT_C := "user://maps/_editor_scene_probe_export.cyrm"
const USER_EXPORT := "user://maps/untitled.cyrm"
const B := "user://maps/_editor_scene_probe_b.cyrm"
const SUB := Vector2i(20, 20)

var _fails: Array[String] = []
var _checks := 0
var _editor: Control = null
var _doc: EditorDoc = null
var _sp_before := ""
var _mp_before := ""
var _map_before := ""
var _settings_bytes := PackedByteArray()
var _settings_existed := false
var _untitled_existed := false
var _user_export_created := false


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)
		print("  ✗ " + msg)


func _ready() -> void:
	await get_tree().process_frame
	_cleanup()
	_backup_settings()

	var scene: PackedScene = load("res://scenes/editor/editor_root.tscn")
	_chk(scene != null, "① 空载守卫:load(editor_root.tscn) 为 null")
	if scene == null:
		_finish()
		return
	_editor = scene.instantiate() as Control
	_chk(_editor != null, "① editor_root.tscn 实例化失败")
	if _editor == null:
		_finish()
		return
	add_child(_editor)
	_editor.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_editor.size = Vector2(1600, 900)
	await get_tree().process_frame
	await get_tree().process_frame

	_doc = _editor.get_doc() as EditorDoc
	_chk(_doc != null, "① get_doc() 返回 null")
	if _doc == null:
		_finish()
		return

	var opened: Dictionary = _editor.open_path(MAP)
	_chk(bool(opened.get("ok", false)), "② 打开 %s 失败:%s" % [MAP, String(opened.get("error", ""))])
	if not bool(opened.get("ok", false)):
		_finish()
		return
	var sub_size := _doc.sub_size()
	_chk(sub_size.x > 0 and sub_size.y > 0 and (_doc.map["layers"] as Array).size() == 7,
			"② 打开后尺寸/图层不对:sub=%s layers=%d" % [str(sub_size), (_doc.map["layers"] as Array).size()])

	var before := _doc.get_subcell(SUB.x, SUB.y)
	var target := EditorDesc.neutral_desc(6)   # 纹理 6「描边方块」,tile_defs 合法
	_doc.set_cells([SUB], target)
	_chk(_doc.get_subcell(SUB.x, SUB.y) == target,
			"③ set_cells 未落到 map:期望 0x%08X 实得 0x%08X" % [target, _doc.get_subcell(SUB.x, SUB.y)])
	_chk(_doc.dirty, "③ 改图后 dirty 应为 true")

	_chk(_doc.can_undo(), "④ 改图后应有撤销")
	_doc.undo()
	_chk(_doc.get_subcell(SUB.x, SUB.y) == before,
			"④ undo 未恢复旧值:期望 0x%08X 实得 0x%08X" % [before, _doc.get_subcell(SUB.x, SUB.y)])
	_doc.redo()
	_chk(_doc.get_subcell(SUB.x, SUB.y) == target, "④ redo 未恢复新值")

	var save_a: Dictionary = _editor.save_to(A)
	_chk(bool(save_a.get("ok", false)), "② 保存到 %s 失败:%s" % [A, String(save_a.get("error", ""))])

	var reopened: Dictionary = _editor.open_path(A)
	_chk(bool(reopened.get("ok", false)), "② 重开 %s 失败:%s" % [A, String(reopened.get("error", ""))])
	_chk(_doc.get_subcell(SUB.x, SUB.y) == target,
			"② 重开后改动的子格丢了:期望 0x%08X 实得 0x%08X" % [target, _doc.get_subcell(SUB.x, SUB.y)])

	var save_b: Dictionary = _editor.save_to(B)
	_chk(bool(save_b.get("ok", false)), "② 再保存到 %s 失败:%s" % [B, String(save_b.get("error", ""))])
	var raw_a := FileAccess.get_file_as_bytes(A)
	var raw_b := FileAccess.get_file_as_bytes(B)
	_chk(not raw_a.is_empty() and raw_a == raw_b,
			"② 重开再保存不是逐字节相等(%d vs %d 字节)" % [raw_a.size(), raw_b.size()])

	var report: Dictionary = _editor.validate()
	_chk(report.has("errors") and report.has("warnings"), "⑥ validate() 返回形状不对")

	var canvas: EditorCanvas = _editor.call("get_editor_canvas") as EditorCanvas
	_chk(canvas != null, "⑤ get_editor_canvas() 返回 null")
	if canvas != null:
		var tex = canvas.view_texture()
		_chk(tex != null and tex.get_width() > 0 and tex.get_height() > 0,
				"⑤ 画布视口纹理为空(期望非空)")

	_check_export_and_load()
	_restore_settings()
	_cleanup()
	_finish()


# ── P3 导出两动作:只写文件的 export_to + Export&Load 的 Settings/MazeGenerator 状态 ──
func _check_export_and_load() -> void:
	var res: Dictionary = _editor.export_and_load(EXPORT_C, true, false)
	_chk(bool(res.get("ok", false)), "⑥ export_and_load 失败:%s" % String(res.get("error", "")))
	_chk(Settings.sp_map_path == EXPORT_C,
			"⑥ 导出并加载后 Settings.sp_map_path 应为 %s(实得 %s)" % [EXPORT_C, Settings.sp_map_path])
	_chk(MazeGenerator.map_file_path() == EXPORT_C,
			"⑥ 导出并加载后下一次 map_file_path() 应返回该文件(实得 %s)" % MazeGenerator.map_file_path())
	_chk(Settings.mp_map_path == _mp_before,
			"⑥ PvP 地图设置不该被「导出并加载」改动(%s → %s)" % [_mp_before, Settings.mp_map_path])
	# persist=true ⇒ Settings.save() 必须把单人地图路径写进 user://settings.cfg(下次开局仍用它)。
	var cf := ConfigFile.new()
	var cfg_ok := cf.load("user://settings.cfg") == OK
	_chk(cfg_ok and String(cf.get_value("single", "map_path", "")) == EXPORT_C,
			"⑥ 导出并加载的持久化没写进 settings.cfg(single/map_path=「%s」)" % String(cf.get_value("single", "map_path", "")))
	var exp: Dictionary = _editor.export_to("user")
	_chk(bool(exp.get("ok", false)), "⑥ 导出(只写文件)失败:%s" % String(exp.get("error", "")))
	_user_export_created = bool(exp.get("ok", false))
	_chk(_user_export_created and FileAccess.file_exists(USER_EXPORT)
			and FileAccess.get_file_as_bytes(USER_EXPORT).size() > 0,
			"⑥ 导出后文件应存在且非空:%s" % USER_EXPORT)


# 备份/恢复用户设置:探针跑 persist=true 的导出会写 user://settings.cfg,不能污染开发者的设置。
func _backup_settings() -> void:
	_sp_before = Settings.sp_map_path
	_mp_before = Settings.mp_map_path
	_map_before = MazeGenerator.map_file_path()
	_settings_existed = FileAccess.file_exists("user://settings.cfg")
	if _settings_existed:
		_settings_bytes = FileAccess.get_file_as_bytes("user://settings.cfg")
	_untitled_existed = FileAccess.file_exists(USER_EXPORT)


func _restore_settings() -> void:
	Settings.sp_map_path = _sp_before
	Settings.mp_map_path = _mp_before
	MazeGenerator.set_map_file(_map_before)
	if _settings_existed:
		var f := FileAccess.open("user://settings.cfg", FileAccess.WRITE)
		if f != null:
			f.store_buffer(_settings_bytes)
			f.close()
	elif FileAccess.file_exists("user://settings.cfg"):
		DirAccess.remove_absolute("user://settings.cfg")


func _cleanup() -> void:
	for p in [A, B, EXPORT_C]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)
	if _user_export_created and not _untitled_existed and FileAccess.file_exists(USER_EXPORT):
		DirAccess.remove_absolute(USER_EXPORT)


func _finish() -> void:
	if _checks < EXPECTED_CHECKS:
		print("EDITOR SCENE PROBE: FAIL | 只跑了 %d 条 < %d(脚本中途中止)" % [_checks, EXPECTED_CHECKS])
		get_tree().quit(1)
		return
	if not _fails.is_empty():
		print("EDITOR SCENE PROBE: FAIL(%d/%d)" % [_fails.size(), EXPECTED_CHECKS])
		for f in _fails:
			print("  - " + f)
		get_tree().quit(1)
		return
	print("EDITOR SCENE PROBE: ALL-OK(%d 条断言)" % _checks)
	get_tree().quit(0)
