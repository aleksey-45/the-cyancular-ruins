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

const EXPECTED_CHECKS := 18
const MAP := "res://maps/newfactory.cyrm"
const A := "user://maps/_editor_scene_probe_a.cyrm"
const B := "user://maps/_editor_scene_probe_b.cyrm"
const SUB := Vector2i(20, 20)

var _fails: Array[String] = []
var _checks := 0
var _editor: Control = null
var _doc: EditorDoc = null


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)
		print("  ✗ " + msg)


func _ready() -> void:
	await get_tree().process_frame
	_cleanup()

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

	_cleanup()
	_finish()


func _cleanup() -> void:
	for p in [A, B]:
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)


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
