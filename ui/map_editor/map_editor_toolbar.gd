class_name MapEditorToolbar
extends PanelContainer

signal new_requested
signal open_requested
signal save_requested
signal save_as_requested
signal undo_requested
signal redo_requested
signal copy_requested
signal cut_requested
signal paste_requested
signal resize_requested
signal notes_requested
signal validate_requested
signal play_requested
signal exit_requested

var shortcuts: Dictionary[int, Callable] = {}

var _canvas: MapEditCanvas

func setup(canvas: MapEditCanvas) -> void:
	_canvas = canvas
	_build()

func _build() -> void:
	theme_type_variation = &"Bar"
	var bar := UiDesign.box(self, UiDesign.SP_3, false) as HBoxContainer
	UiKit.label(bar, "地图编辑器", UiDesign.C_GOLD)
	bar.add_child(VSeparator.new())
	var cmd := KEY_MASK_META if OS.has_feature("macos") else KEY_MASK_CTRL

	var files := _command_menu(bar, "文件")
	_command(files, "新建地图…", new_requested.emit, cmd | KEY_N)
	_command(files, "打开地图…", open_requested.emit, cmd | KEY_O)
	files.add_separator()
	_command(files, "保存", save_requested.emit, cmd | KEY_S)
	_command(files, "另存为…", save_as_requested.emit, cmd | KEY_MASK_SHIFT | KEY_S)

	var edit := _command_menu(bar, "编辑")
	_command(edit, "撤销", undo_requested.emit, cmd | KEY_Z)
	_command(edit, "重做", redo_requested.emit, cmd | KEY_MASK_SHIFT | KEY_Z)
	shortcuts[cmd | KEY_Y] = redo_requested.emit
	edit.add_separator()
	_command(edit, "复制选区", copy_requested.emit, cmd | KEY_C)
	_command(edit, "剪切选区", cut_requested.emit, cmd | KEY_X)
	_command(edit, "粘贴", paste_requested.emit, cmd | KEY_V)
	edit.add_separator()
	_command(edit, "调整地图尺寸…", resize_requested.emit)
	_command(edit, "地图注记…", notes_requested.emit)

	var view := _command_menu(bar, "视图")
	_command(view, "适配全图", _canvas.fit)
	view.add_separator()
	for entry in [["坐标标尺", "grid"], ["子格网格", "subgrid"], ["环面预览", "torus"],
			["分区标线", "guides"], ["压暗其他层", "dim_others"]]:
		var index := view.item_count
		view.add_check_item(entry[0], index)
		view.set_item_checked(index, _canvas.get(entry[1]))
		view.set_item_metadata(index, _toggle_view.bind(view, index, entry[1]))

	_build_light_preview(bar)
	bar.add_spacer(false)
	UiKit.button(bar, "保存", save_requested.emit).tooltip_text = "写入当前地图文件"
	UiKit.button(bar, "校验", validate_requested.emit)
	shortcuts[KEY_F5] = play_requested.emit
	var play := UiKit.button(bar, "试玩  F5", play_requested.emit)
	play.theme_type_variation = &"ToolPrimary"
	play.tooltip_text = "从所选点位试玩当前地图，Esc 返回"
	UiKit.button(bar, "退出编辑器", exit_requested.emit).tooltip_text = "返回主菜单 · Esc"

func _build_light_preview(bar: Control) -> void:
	var slider := HSlider.new()
	slider.max_value = Daylight.DAY - 15
	slider.step = 15
	slider.value = Daylight.NOON
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	slider.custom_minimum_size.x = 180
	slider.accessibility_name = "光照预览时刻"
	var preview := CheckBox.new()
	preview.text = "光照预览"
	preview.toggled.connect(func(on: bool) -> void:
		slider.editable = on
		_canvas.preview_minute = slider.value if on else -1.0)
	bar.add_child(preview)
	bar.add_child(slider)
	slider.editable = false
	var clock := UiKit.label(bar, Daylight.time_text(slider.value))
	slider.value_changed.connect(func(value: float) -> void:
		clock.text = Daylight.time_text(value)
		if preview.button_pressed: _canvas.preview_minute = value)

func _toggle_view(menu: PopupMenu, index: int, property: String) -> void:
	var value := not bool(_canvas.get(property))
	menu.set_item_checked(index, value)
	_canvas.set(property, value)
	_canvas.refresh_view()

func _command_menu(parent: Control, title: String) -> PopupMenu:
	var menu := MenuButton.new()
	menu.text = title
	menu.set_disable_shortcuts(true)
	parent.add_child(menu)
	var popup := menu.get_popup()
	popup.index_pressed.connect(func(i: int) -> void: popup.get_item_metadata(i).call())
	return popup

func _command(menu: PopupMenu, text: String, action: Callable, accelerator := 0) -> void:
	var i := menu.item_count
	menu.add_item(text, i, accelerator)
	menu.set_item_metadata(i, action)
	if accelerator: shortcuts[accelerator] = action
