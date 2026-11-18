class_name LobbyView
extends Control

signal nickname_changed(text: String)
signal filter_changed(mode: String)
signal create_requested(mode: String, options: Dictionary)
signal join_requested(code: String)
signal room_chosen
signal copy_requested
signal team_requested(side: int)
signal start_requested
signal exit_room_requested
signal back_requested
signal preference_changed(value: Variant, key: StringName)

var _mode := ""
var _filters := {}
var _create: LobbyCreatePanel
var _wait: LobbyWaitPanel
var _join: PanelContainer
var _code := LineEdit.new()
var _browser := Control.new()
var _status := Label.new()
var _card := LobbyRoomCard.new()
var _empty := UiFactory.label("暂无房间", 32, UiFactory.C_TEXT_DIM)
var _create_button: Button
var _join_button: Button

func mount(nickname: String, prefs: Dictionary) -> void:
	theme = UiFactory.MENU_THEME
	UiFactory.place(self, UiFactory.shade(Color(0.07, 0.09, 0.13)), Rect2(0, 0, 1920, 1440))
	var label := Label.new()
	label.text = "昵称"
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	UiFactory.place(self, label, Rect2(76, 76, 240, 72))
	var name_edit := LineEdit.new()
	name_edit.text = nickname
	name_edit.placeholder_text = "昵称(头上显示)"
	name_edit.text_changed.connect(nickname_changed.emit)
	UiFactory.place(self, name_edit, Rect2(332, 76, 620, 72))
	UiFactory.place(self, _code, Rect2(1180, 76, 664, 72))
	_display_code("")
	_code.text_submitted.connect(_join_clicked.unbind(1))

	var group := ButtonGroup.new()
	for i in UiFactory.ROOM_FILTERS.size():
		var row: Array = UiFactory.ROOM_FILTERS[i]
		var button := UiFactory.room_filter(row, group)
		_filters[row[0]] = button
		button.pressed.connect(filter_changed.emit.bind(row[0]))
		UiFactory.place(self, button, Rect2(76 + i * 236, 180, 220, 72))
	_create_button = _fixed_button("＋ 创建房间", Rect2(1180, 180, 320, 72), &"BtnGold", _open_create)
	_join_button = _fixed_button("加入房间", Rect2(1524, 180, 320, 72), &"BtnPrimary", _join_clicked)

	_browser.mouse_filter = MOUSE_FILTER_IGNORE
	UiFactory.place(self, _browser, Rect2(76, 296, 1768, 956))
	_browser.add_child(_empty)
	_browser.add_child(_card)
	_card.hide()
	_card.pressed.connect(func() -> void:
		Sfx.play("ui")
		room_chosen.emit())
	_build_status()
	_fixed_button("返回主菜单", Rect2(1584, 1292, 260, 72), &"BtnPrimary", back_requested.emit)
	_build_join()
	var mask := UiFactory.shade(Color(0, 0, 0, 0.55), true)
	mask.hide()
	UiFactory.cover(self, mask)
	_create = LobbyCreatePanel.new(prefs)
	UiFactory.dialog(_create)
	UiFactory.place(self, _create, Rect2(-779, -462, 1558, 924), Vector2(0.5, 0.5))
	_create.visibility_changed.connect(func() -> void: mask.visible = _create.visible)
	_create.submitted.connect(create_requested.emit)
	_create.preference_changed.connect(preference_changed.emit)
	_wait = LobbyWaitPanel.new(prefs["hue"])
	UiFactory.dialog(_wait)
	UiFactory.place(self, _wait, Rect2(-465, -290.5, 930, 581), Vector2(0.5, 0.5))
	_wait.copy_requested.connect(copy_requested.emit)
	_wait.team_requested.connect(team_requested.emit)
	_wait.start_requested.connect(start_requested.emit)
	_wait.exit_requested.connect(exit_room_requested.emit)
	_wait.hue_changed.connect(preference_changed.emit.bind(&"pvp_color_hue"))

func select_filter(mode: String) -> void:
	_mode = mode
	for key in _filters:
		_filters[key].button_pressed = key == mode

func set_status(message: String) -> void:
	_status.text = message

func show_listing(card: Dictionary) -> void:
	_card.visible = not card.is_empty()
	_empty.visible = not _card.visible
	if _card.visible:
		_card.present(card)

func show_wait(room: Dictionary) -> void:
	var open := not room.is_empty()
	if open:
		_join.hide()
		_create.hide()
		_wait.present(room)
	_wait.visible = open
	for item: Control in [_create_button, _join_button, _browser] + _filters.values():
		item.visible = not open
	_display_code(room.get("code", ""))

func close_create() -> void:
	_create.hide()

func _build_status() -> void:
	_status.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var outer := PanelContainer.new()
	outer.theme_type_variation = &"PanelCarved"
	var frame := PanelContainer.new()
	var style := UiFactory.plate(Color.TRANSPARENT, Vector2(32, 16))
	style.set_border_width_all(1)
	style.border_color = Color8(30, 40, 48)
	frame.add_theme_stylebox_override("panel", style)
	frame.add_child(_status)
	outer.add_child(frame)
	UiFactory.place(self, outer, Rect2(76, 1292, 1500, 72))

func _build_join() -> void:
	var body := VBoxContainer.new()
	body.custom_minimum_size.x = 640
	body.add_theme_constant_override("separation", 16)
	body.add_child(UiFactory.header_strip("加入房间", 32, true))
	var code := LineEdit.new()
	code.custom_minimum_size = Vector2(560, 64)
	code.placeholder_text = "房间号"
	body.add_child(code)
	var buttons := UiFactory.box(body, 16, false)
	_join = UiFactory.framed(body)
	UiFactory.dialog(_join)
	UiFactory.place(self, _join, Rect2(-385, -171, 770, 342), Vector2(0.5, 0.5))
	UiFactory.action(buttons, "加入", Vector2(220, 64), &"BtnGold", func() -> void:
		_join.hide()
		var value := code.text.strip_edges()
		if not value.is_empty():
			_code.text = value
		join_requested.emit(value))
	UiFactory.action(buttons, "取消", Vector2(220, 64), &"BtnQuiet", _join.hide)

func _display_code(code: String) -> void:
	_code.text = code
	_code.editable = code.is_empty()
	_code.placeholder_text = "房间号" if code.is_empty() else "你的房间号(报给对手)"

func _open_create() -> void:
	_create.open(PvpSession.MODE_PVP if _mode.is_empty() else _mode)

func _join_clicked() -> void:
	var code := _code.text.strip_edges()
	if code.is_empty():
		_join.visible = not _join.visible
	else:
		join_requested.emit(code)

func _fixed_button(text: String, rect: Rect2, variant: StringName, pressed: Callable) -> Button:
	var button := UiFactory.menu_button(text, rect.size, variant)
	button.pressed.connect(pressed)
	UiFactory.place(self, button, rect)
	return button
