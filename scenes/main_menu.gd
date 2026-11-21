extends Control

const SP_PANEL := preload("res://ui/screens/sp_launch_panel.tscn")
const BACKGROUND := preload("res://core/present/menu_background.gd")
const LOBBY := "res://scenes/mp_lobby.tscn"

var _layer: CanvasLayer
var _launch: SpLaunchPanel

func _ready() -> void:
	if OS.get_cmdline_user_args().has("--server"):
		get_tree().change_scene_to_file.call_deferred("res://server/server_main.tscn")
		return
	_layer = CanvasLayer.new()
	_layer.layer = 140
	add_child(_layer)
	var root := Control.new()
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = UiFactory.MENU_THEME
	UiFactory.cover(_layer, root)
	var background := BACKGROUND.new()
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	UiFactory.cover(root, background)
	var title := UiFactory.label("The Cyancular Ruins", 128, UiFactory.C_ACCENT)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.grow_horizontal = Control.GROW_DIRECTION_BOTH
	UiFactory.place(root, title, Rect2(-78.5, 160, 157, 180), Vector2(0.5, 0.0))

	var menu := VBoxContainer.new()
	menu.grow_vertical = Control.GROW_DIRECTION_BOTH
	menu.grow_horizontal = Control.GROW_DIRECTION_BOTH
	menu.alignment = BoxContainer.ALIGNMENT_CENTER
	menu.add_theme_constant_override("separation", 48)
	UiFactory.place(root, menu, Rect2(0, 170, 0, -170), Vector2(0.5, 0.5))
	_buttons(UiFactory.box(menu, 28, true), [
		["单人模式", Vector2(720, 104), &"BtnAccent", _toggle_single],
		["多人模式", Vector2(640, 88), &"BtnPrimary", _enter_multiplayer],
		["Beta", Vector2(640, 88), &"BtnQuiet", _open.bind("res://scenes/beta_menu.tscn")],
	])
	_separator(menu)
	_buttons(UiFactory.box(menu, 28, true), [
		["地图编辑器", Vector2(560, 76), &"BtnPrimary", _open.bind("res://scenes/map_editor.tscn")],
		["设置", Vector2(560, 76), &"BtnPrimary", _open.bind("res://scenes/settings_menu.tscn")],
		["信息", Vector2(560, 76), &"BtnPrimary", _open.bind("res://scenes/info_menu.tscn")],
	])
	_separator(menu)
	_buttons(menu, [["退出", Vector2(640, 88), &"BtnQuiet", _quit]])
	title.modulate.a = 0.0
	var emerge := create_tween().set_parallel()
	emerge.tween_property(title, "modulate:a", 1.0, 0.6).set_trans(Tween.TRANS_SINE).set_delay(0.1)
	var delay := 0.45
	for group in menu.get_children():
		for item: Control in group.get_children() if group is VBoxContainer else [group]:
			item.modulate.a = 0.0
			emerge.tween_property(item, "modulate:a", 1.0, 0.28).set_trans(Tween.TRANS_SINE).set_delay(delay)
			delay += 0.09

static func _buttons(parent: BoxContainer, rows: Array) -> void:
	for row in rows:
		var button := UiFactory.menu_button(row[0], row[1], row[2])
		parent.add_child(button)
		button.pressed.connect(row[3])

static func _separator(menu: VBoxContainer) -> void:
	var line := UiFactory.shade(Color(0.25, 0.31, 0.4))
	line.custom_minimum_size.y = 2.0
	menu.add_child(line)

func _open(path: String) -> void:
	Sfx.play("ui")
	get_tree().change_scene_to_file(path)

func _enter_multiplayer() -> void:
	PvpSession.reset()
	_open(LOBBY)

func _quit() -> void:
	Sfx.play("ui")
	get_tree().quit()

func _toggle_single() -> void:
	Sfx.play("ui")
	if _launch == null:
		_launch = SP_PANEL.instantiate()
		_launch.initial_map = Settings.sp_map_path
		_launch.disabled = Settings.sp_disabled_weapons
		_launch.play_requested.connect(_play)
		_layer.add_child(_launch)
	else:
		_launch.visible = not _launch.visible

func _play(path: String, disabled: Array[int]) -> void:
	var enabled := WeaponRegistry.enabled_ids(disabled)
	if enabled.is_empty():
		_launch.show_error("请至少启用一种武器")
		return
	var map := MapCatalog.random_map() if path.is_empty() else CyrmMap.load_file(path)
	if map.is_empty():
		_launch.show_error("没有可用的地图" if path.is_empty() else "无法读取地图 %s" % path.get_file())
		return
	var spawn := SpawnPicker.single_spawn(map)
	if spawn == SpawnPicker.NO_CELL:
		_launch.show_error("地图没有可用的玩家出生点")
		return
	Settings.sp_disabled_weapons = disabled
	Settings.sp_map_path = path
	Settings.save()
	var level := SoloLevel.create(map, spawn, enabled)
	get_tree().change_scene_to_node(level)
