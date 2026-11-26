class_name MapEditorFiles
extends Node

const DEFAULT_SIZE := Vector2i(500, 300)
const DRAFT_PATH := "user://map-editor.draft"

var session: MapEditSession
var say: Callable
var draft_path := DRAFT_PATH

var _draft_revision := -1

func _init(p_session: MapEditSession, p_say: Callable) -> void:
	session = p_session
	say = p_say
	session.changed.connect(_discard_saved_draft)

func open_document(map: Dictionary, path: String, dirty := false) -> void:
	session.open(map, path, dirty)
	_draft_revision = session.revision

func _discard_saved_draft() -> void:
	if not session.dirty():
		_draft_revision = session.revision
		discard_draft()

func write_draft() -> void:
	if _draft_revision == session.revision:
		return
	var error := MapEditFiles.save_draft(draft_path, session.map, session.path)
	if error == OK:
		_draft_revision = session.revision
	else:
		say.call("草稿保存失败 · " + error_string(error))

func save(path := "") -> void:
	if path.is_empty():
		path = session.path
	if path.is_empty() or path.begins_with("res://"):
		open_dialog(true)
		return
	var error := CyrmMap.save_file(session.map, path)
	if error != OK:
		say.call("保存失败 · " + error_string(error))
		return
	session.mark_saved(path)
	say.call("已保存 " + path.get_file())

func open_file(path: String) -> void:
	var map := CyrmMap.load_file(path)
	if map.is_empty():
		say.call("打开失败 · 无效的地图")
		return
	open_document(map, path)
	say.call("已打开 " + path.get_file())

func open_dialog(saving := false) -> void:
	var directory := ProjectSettings.globalize_path(MapCatalog.USER_DIR)
	var error := DirAccess.make_dir_recursive_absolute(directory)
	if error == OK:
		var filename := session.path.get_file() if not session.path.is_empty() else "新地图.cyrm"
		error = DisplayServer.file_dialog_show(
			"另存为" if saving else "打开地图", directory, filename if saving else "", false,
			DisplayServer.FILE_DIALOG_MODE_SAVE_FILE if saving else DisplayServer.FILE_DIALOG_MODE_OPEN_FILE,
			PackedStringArray(["*.cyrm;CYRM 地图"]), file_selected.bind(saving), get_window().get_window_id())
	if error != OK:
		say.call("无法打开系统文件窗口 · " + error_string(error))

func confirm_discard(proceed: Callable) -> void:
	if session.dirty():
		confirm("当前地图有未保存的修改。放弃这些修改？", "放弃修改", proceed)
	else:
		proceed.call()

func show_dialog(dialog: ConfirmationDialog, size_hint := Vector2i.ZERO) -> void:
	dialog.cancel_button_text = "取消"
	for button in [dialog.get_ok_button(), dialog.get_cancel_button()]:
		button.theme_type_variation = &"ToolButton"
	get_parent().add_child(dialog)
	dialog.visibility_changed.connect(func() -> void:
		if not dialog.visible: dialog.queue_free())
	dialog.popup_centered(size_hint)

func size_dialog(create: bool) -> void:
	var dialog := ConfirmationDialog.new()
	dialog.title = "新建地图" if create else "调整地图尺寸"
	dialog.ok_button_text = "创建" if create else "调整尺寸"
	var form := VBoxContainer.new()
	form.custom_minimum_size.x = 400
	dialog.add_child(form)
	var initial: Vector2i = DEFAULT_SIZE if create else session.map.size
	var width := UiKit.spin_row(form, "宽（子格）", 1, CyrmMap.MAX_SIZE.x, initial.x)
	var height := UiKit.spin_row(form, "高（子格）", 1, CyrmMap.MAX_SIZE.y, initial.y)
	dialog.confirmed.connect(func() -> void:
		var dims := Vector2i(int(width.value), int(height.value))
		if create:
			confirm_discard.call_deferred(open_document.bind(CyrmMap.create(dims), "", false))
		else:
			resize_to.call_deferred(dims))
	show_dialog(dialog)

func discard_draft() -> void:
	MapEditFiles.clear_draft(draft_path)

func file_selected(accepted: bool, paths: PackedStringArray, _filter: int, saving: bool) -> void:
	if not accepted or paths.is_empty():
		return
	var path := paths[0]
	if not saving:
		confirm_discard(open_file.bind(path))
		return
	if path.get_extension().to_lower() != "cyrm":
		path += ".cyrm"
		if FileAccess.file_exists(path):
			confirm("覆盖 %s？" % path.get_file(), "覆盖", save.bind(path))
			return
	save(path)

func confirm(text: String, action: String, proceed: Callable) -> void:
	var dialog := ConfirmationDialog.new()
	dialog.dialog_text = text
	dialog.ok_button_text = action
	dialog.confirmed.connect(proceed)
	show_dialog(dialog, Vector2i(620, 190))

func resize_to(dims: Vector2i) -> void:
	if dims == session.map.size:
		return
	if dims.x < session.map.size.x or dims.y < session.map.size.y:
		var cropped: Array[String] = []
		var bounds := Rect2i(Vector2i.ZERO, dims)
		for row: Dictionary in session.map.points.values():
			if not bounds.has_point(row.cell):
				cropped.append("%s %s" % [row.kind, row.cell])
		var warning := "画布将裁至 %d × %d 格。" % [dims.x, dims.y]
		if not cropped.is_empty():
			warning += "\n将移除 %d 个越界点位：%s" % [cropped.size(), "、".join(cropped.slice(0, 6))]
		confirm(warning + "\n可用撤销恢复。", "调整尺寸", session.resize_map.bind(dims))
	else:
		session.resize_map(dims)
