extends Control

# 主菜单布局定义在 main_menu.tscn 中。脚本设置标题与版本号，连接菜单操作并播放入场动画。

const SP_PANEL := preload("res://ui/screens/sp_launch_panel.tscn")
const LOBBY := "res://scenes/mp_lobby.tscn"

@onready var _bg: ColorRect = %Bg
@onready var _title: Label = %Title
@onready var _version: Label = %Version
@onready var _menu_box: VBoxContainer = %MenuBox
@onready var _sep_a: ColorRect = %SepA
@onready var _sep_b: ColorRect = %SepB
@onready var _ui_layer: CanvasLayer = %UILayer

var _launch: SpLaunchPanel = null


func _ready() -> void:
	if OS.get_cmdline_user_args().has("--server"):
		get_tree().change_scene_to_file.call_deferred("res://server/server_main.tscn")
		return
	_style_page()
	_wire_menu()
	_play_emerge()


func _style_page() -> void:
	_bg.color = UiDesign.C_BG
	_sep_a.color = UiDesign.C_BORDER_DIM
	_sep_b.color = UiDesign.C_BORDER_DIM
	_title.text = str(ProjectSettings.get_setting("application/config/name"))
	_title.add_theme_color_override("font_color", UiDesign.C_ACCENT)
	UiDesign.style_control(_title, UiDesign.T_HUGE)
	_version.text = "%s v%s" % [
			ProjectSettings.get_setting("application/config/release_prefix"),
			ProjectSettings.get_setting("application/config/version")]
	_version.add_theme_color_override("font_color", UiDesign.C_TEXT_DIM)
	UiDesign.style_control(_version, UiDesign.T_BODY)


func _wire_menu() -> void:
	%StartBtn.pressed.connect(_toggle_single)
	%MultiBtn.pressed.connect(_enter_multiplayer)
	%BetaBtn.pressed.connect(_open.bind("res://scenes/beta_menu.tscn"))
	%EditorBtn.pressed.connect(_open.bind("res://scenes/map_editor.tscn"))
	%SettingsBtn.pressed.connect(_open.bind("res://scenes/settings_menu.tscn"))
	%VerBtn.pressed.connect(_open.bind("res://scenes/info_menu.tscn"))
	%QuitBtn.pressed.connect(_quit)


func _menu_sequence() -> Array:
	var seq: Array = []
	for c in _menu_box.get_children():
		if c is VBoxContainer:
			for item in c.get_children():
				seq.append(item)
		else:
			seq.append(c)
	return seq


# 标题和版本号先淡入，按钮随后依次淡入。
func _play_emerge() -> void:
	_title.modulate.a = 0.0
	_version.modulate.a = 0.0
	var emerge := create_tween().set_parallel()
	emerge.tween_property(_title, "modulate:a", 1.0, 0.6).set_trans(Tween.TRANS_SINE).set_delay(0.1)
	emerge.tween_property(_version, "modulate:a", 1.0, 0.6).set_trans(Tween.TRANS_SINE).set_delay(0.1)
	var delay := 0.45
	for item in _menu_sequence():
		if item is Control:
			(item as Control).modulate.a = 0.0
			emerge.tween_property(item, "modulate:a", 1.0, 0.28).set_trans(Tween.TRANS_SINE).set_delay(delay)
		delay += 0.09


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
		_ui_layer.add_child(_launch)
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
	# 地图、出生点和武器校验完成后，先显示加载界面，再在主线程构建并初始化单人场景。
	var document := map
	var spawn_cell := spawn
	var weapons := enabled
	SceneTransition.change_with_builder(get_tree(), func() -> Node:
		return SoloLevel.create(document, spawn_cell, weapons, true), "正在进入单人…")
