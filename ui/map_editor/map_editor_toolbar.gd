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
signal travel_requested(direction: int)

var shortcuts: Dictionary[int, Callable] = {}

var _canvas: MapEditCanvas

func setup(canvas: MapEditCanvas) -> void:
	_canvas = canvas
	_build()

func _build() -> void:
	var bar := _row(self)
	_label(bar, "地图编辑器", 28, Color("#b7e9d5"))
	bar.add_child(VSeparator.new())
	var cmd := KEY_MASK_META if OS.has_feature("macos") else KEY_MASK_CTRL

	var files := _command_menu(bar, "文件")
	_command(files, "新建地图…", func() -> void: new_requested.emit(), cmd | KEY_N)
	_command(files, "打开地图…", func() -> void: open_requested.emit(), cmd | KEY_O)
	files.add_separator()
	_command(files, "保存", func() -> void: save_requested.emit(), cmd | KEY_S)
	_command(files, "另存为…", func() -> void: save_as_requested.emit(), cmd | KEY_MASK_SHIFT | KEY_S)

	var edit := _command_menu(bar, "编辑")
	_command(edit, "撤销", func() -> void: undo_requested.emit(), cmd | KEY_Z)
	_command(edit, "重做", func() -> void: redo_requested.emit(), cmd | KEY_MASK_SHIFT | KEY_Z)
	_shortcuts_for(cmd | KEY_Y, func() -> void: travel_requested.emit(1))
	edit.add_separator()
	_command(edit, "复制选区", func() -> void: copy_requested.emit(), cmd | KEY_C)
	_command(edit, "剪切选区", func() -> void: cut_requested.emit(), cmd | KEY_X)
	_command(edit, "粘贴", func() -> void: paste_requested.emit(), cmd | KEY_V)
	edit.add_separator()
	_command(edit, "调整地图尺寸…", func() -> void: resize_requested.emit())
	_command(edit, "地图注记…", func() -> void: notes_requested.emit())

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
	_button(bar, "保存", func() -> void: save_requested.emit()).tooltip_text = "写入当前地图文件"
	_button(bar, "校验", func() -> void: validate_requested.emit())
	var play := _button(bar, "试玩  F5", func() -> void: play_requested.emit(), KEY_F5)
	play.theme_type_variation = &"EditorPrimary"
	play.tooltip_text = "从所选点位试玩当前地图，Esc 返回"
	_button(bar, "退出编辑器", func() -> void: exit_requested.emit()).tooltip_text = "返回主菜单 · Esc"

func _build_light_preview(bar: Control) -> void:
	var slider := HSlider.new()
	slider.max_value = Daylight.DAY - 15
	slider.step = 15
	slider.value = Daylight.NOON
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
	var clock := _label(bar, Daylight.time_text(slider.value))
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
	menu.add_theme_color_override("font_color", Color("#d9e3df"))
	parent.add_child(menu)
	var popup := menu.get_popup()
	popup.index_pressed.connect(func(i: int) -> void: popup.get_item_metadata(i).call())
	return popup

func _command(menu: PopupMenu, text: String, action: Callable, accelerator := 0) -> void:
	var i := menu.item_count
	menu.add_item(text, i, accelerator)
	menu.set_item_metadata(i, action)
	if accelerator: _shortcuts_for(accelerator, action)

func _shortcuts_for(key: int, action: Callable) -> void:
	shortcuts[key] = action

func _row(parent: Control) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	parent.add_child(row)
	return row

func _label(parent: Control, text: String, font_size := 24, color := Color("#d9e3df")) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	parent.add_child(label)
	return label

func _button(parent: Control, text: String, action: Callable, shortcut := KEY_NONE) -> Button:
	var button := Button.new()
	button.text = text
	button.add_theme_color_override("font_color", Color("#d9e3df"))
	button.pressed.connect(action)
	parent.add_child(button)
	if shortcut: _shortcuts_for(shortcut, action)
	return button
