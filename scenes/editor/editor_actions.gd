extends RefCounted

# 编辑器的「命令层」:文件/编辑菜单与右栏按钮的落点 + 标准弹层内容(新建/打开/保存为/导出)。
# UI 在 scenes/editor/editor_root.tscn;root 只把按钮信号接到这里。真正的读写逻辑仍在
# EditorIO/EditorDoc(纯逻辑)与 root 的公开 API(open_path/save_to/export_to/…)。
# ★ 进客户端导出包 ⇒ 禁止 RegEx。

const THEME := preload("res://ui/theme/menu_theme.tres")
const DIALOG_PAD := UiFactory.SP_5

var page: Control = null                                  # EditorRoot(只调公开 API)
var _popup: Window = null


func setup(p: Control) -> void:
	page = p


func notify(text: String, is_error: bool = false) -> void:
	page.call("notify", text, is_error)


# ── 编辑命令 ──────────────────────────────────────────────────────────

func undo() -> void:
	if not page.get_doc().undo():
		notify("没有可撤销的操作", true)


func redo() -> void:
	if not page.get_doc().redo():
		notify("没有可重做的操作", true)


func copy() -> void:
	var res: Dictionary = page.get_doc().copy_selection()
	if bool(res.get("ok", false)):
		notify("已复制 %d 个子格" % int(res.get("count", 0)))
	else:
		notify("复制失败:%s" % String(res.get("error", "")), true)


func cut() -> void:
	var res: Dictionary = page.get_doc().cut_selection()
	if bool(res.get("ok", false)):
		notify("已剪切到剪贴板")
	else:
		notify("剪切失败:%s" % String(res.get("error", "")), true)


func paste() -> void:
	var doc: EditorDoc = page.get_doc()
	if doc.clipboard.is_empty():
		notify("剪贴板是空的(先复制或剪切一块)", true)
		return
	var at := Vector2i.ZERO
	if doc.has_selection():
		at = doc.selection.position / EditorConstants.SUB_PER_CELL
	var res: Dictionary = doc.paste_clipboard(at)
	if bool(res.get("ok", false)):
		notify("已粘贴到格 %s" % str(at))
	else:
		notify("粘贴失败:%s" % String(res.get("error", "")), true)


func clear_selection() -> void:
	notify("已清除选区(%d 个子格)" % page.get_doc().clear_selection_cells())


func mirror(axis: String) -> void:
	var doc: EditorDoc = page.get_doc()
	if not doc.has_selection():
		notify("先框选一块,再镜像")
		return
	var res: Dictionary = doc.mirror_selection(axis)
	if bool(res.get("ok", false)):
		notify("镜像 %s:改动 %d 个子格"
				% ["水平" if axis == "h" else "垂直", int(res.get("count", 0))])
	else:
		notify("镜像失败:%s" % String(res.get("error", "")), true)


func validate() -> void:
	page.call("validate")


# ── 文件命令 ──────────────────────────────────────────────────────────

func new_map_dialog() -> void:
	var ctx := {}
	var dlg := _open_dialog("新建地图", "新建", func(body: VBoxContainer) -> void:
		ctx["name"] = _dialog_line(body, "名字", "untitled")
		ctx["w"] = _dialog_line(body, "宽(格)", "125")
		ctx["h"] = _dialog_line(body, "高(格)", "75"))
	dlg.confirmed.connect(func() -> void:
		var size := EditorValidate.clamp_map_size((ctx["w"] as LineEdit).text,
				(ctx["h"] as LineEdit).text)
		page.call("new_map", int(size["w"]), int(size["h"]), (ctx["name"] as LineEdit).text))


func open_dialog() -> void:
	_open_dialog("打开地图", "关闭", func(body: VBoxContainer) -> void:
		var maps := EditorIO.list_maps()
		if maps.is_empty():
			body.add_child(UiFactory.label("没有找到 .cyrm", 16, UiFactory.C_TEXT_DIM))
			return
		var scroll := ScrollContainer.new()
		scroll.custom_minimum_size = Vector2(520, 400)          # 列表可视区 = 内容驱动
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		body.add_child(scroll)
		var list := VBoxContainer.new()
		list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		list.add_theme_constant_override("separation", UiFactory.SP_2)
		scroll.add_child(list)
		for path: String in maps:
			list.add_child(_map_card(path)))


func save_pressed() -> void:
	if String(page.call("current_path")) != "":
		page.call("save_current")
	else:
		save_as_dialog()


func save_as_dialog() -> void:
	var ctx := {}
	var dlg := _open_dialog("保存为", "保存", func(body: VBoxContainer) -> void:
		ctx["path"] = _dialog_line(body, "路径", EditorIO.default_target(String(page.call("map_name")))))
	dlg.confirmed.connect(func() -> void:
		page.call("save_to", (ctx["path"] as LineEdit).text))


func export_dialog() -> void:
	var ctx := {}
	var dlg := _open_dialog("导出到…", "导出", func(body: VBoxContainer) -> void:
		ctx["name"] = _dialog_line(body, "名字", String(page.call("map_name")))
		var target := OptionButton.new()
		target.add_item("user://maps(默认,可写)", 0)
		target.add_item("exe 同目录(外置地图优先)", 1)
		UiFactory.style_control(target, 16)
		body.add_child(target)
		ctx["target"] = target)
	dlg.confirmed.connect(func() -> void:
		page.call("_export_target", (ctx["name"] as LineEdit).text,
				(ctx["target"] as OptionButton).selected == 1))


func export_load_pressed() -> void:
	var path := String(page.call("current_path"))
	page.call("export_and_load", path if path != "" else EditorIO.default_target(
			String(page.call("map_name"))))


func back() -> void:
	page.get_tree().change_scene_to_file("res://scenes/main_menu.tscn")


# ── 标准弹层(内容由调用方填;窗口尺寸 = 内容最小尺寸 + 内边距)────────────

func _open_dialog(title_text: String, ok_text: String, fill: Callable) -> ConfirmationDialog:
	_close_popup()
	var dlg := ConfirmationDialog.new()
	dlg.name = "Dialog"
	dlg.title = title_text
	dlg.ok_button_text = ok_text
	dlg.cancel_button_text = "取消"
	dlg.theme = THEME
	dlg.theme_type_variation = &"Kit"
	var body := VBoxContainer.new()
	body.name = "Body"
	body.add_theme_constant_override("separation", UiFactory.SP_2)
	dlg.add_child(body)
	_popup = dlg
	fill.call(body)
	page.add_child(dlg)
	var want := body.get_combined_minimum_size() + Vector2(DIALOG_PAD * 2, DIALOG_PAD * 3)
	dlg.popup_centered(Vector2i(int(want.x), int(want.y)))
	return dlg


func _close_popup() -> void:
	if is_instance_valid(_popup):
		_popup.hide()
		_popup.queue_free()
	_popup = null


func _dialog_line(parent: VBoxContainer, label_text: String, default_text: String) -> LineEdit:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UiFactory.SP_2)
	row.add_child(UiFactory.label(label_text, 16, UiFactory.C_TEXT_DIM))
	var edit := LineEdit.new()
	edit.text = default_text
	edit.custom_minimum_size = Vector2(320, 36)              # 输入框宽度 = 内容驱动
	UiFactory.style_line_edit(edit)
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(edit)
	parent.add_child(row)
	return edit


# 打开弹层里的地图卡片(缩略图复用 MapCatalog,与主菜单选图同一套缓存/显示名)。
func _map_card(path: String) -> Control:
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", UiFactory.row_box())
	card.custom_minimum_size = Vector2(420, 0)               # 卡片最小宽 = 内容驱动
	card.mouse_filter = Control.MOUSE_FILTER_STOP
	card.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and (ev as InputEventMouseButton).pressed \
				and (ev as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
			page.call("open_path", path)
			_close_popup())
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", UiFactory.SP_2)
	card.add_child(row)
	var thumb := TextureRect.new()
	thumb.texture = MapCatalog.texture(path, 2)
	thumb.custom_minimum_size = Vector2(120, 72)             # 缩略图框 = 内容驱动
	thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	thumb.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	thumb.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	row.add_child(thumb)
	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_theme_constant_override("separation", 2)
	row.add_child(info)
	info.add_child(UiFactory.label(MapCatalog.display_name(path), 16, UiFactory.C_TEXT))
	info.add_child(UiFactory.label(path, 16, UiFactory.C_TEXT_DIM))
	return card
