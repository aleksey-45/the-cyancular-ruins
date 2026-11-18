class_name SpLaunchPanel
extends PanelContainer

signal play_requested(path: String, disabled_weapons: Array[int])

var initial_map := ""
var disabled: Array[int] = []
var _map := MapPicker.new()
var _weapons: WeaponPicker
var _status: Label

func _ready() -> void:
	var body := VBoxContainer.new()
	body.custom_minimum_size.x = 560
	body.add_theme_constant_override("separation", 28)
	UiFactory.fill_frame(self, body, Vector2(64, 46))
	body.add_child(UiFactory.header_strip("—— 单人开局 ——", 48, true))
	body.add_child(_map)
	_map.setup(initial_map, 2, 300.0)
	body.add_child(UiFactory.header_strip("禁用武器(勾选 = 本局不可用)", 32))
	_weapons = WeaponPicker.new(disabled, 1, 320)
	body.add_child(_weapons)
	var row := UiFactory.box(body, 28, false)
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	var go := UiFactory.menu_button("开始探索", Vector2(420, 88), &"BtnGold")
	row.add_child(go)
	go.pressed.connect(func() -> void:
		Sfx.play("ui")
		play_requested.emit(_map.selected, _weapons.disabled_weapons()))
	var back := UiFactory.menu_button("返回", Vector2(420, 88), &"BtnQuiet")
	row.add_child(back)
	back.pressed.connect(func() -> void:
		Sfx.play("ui")
		hide())
	_status = UiFactory.label("", 32, UiFactory.C_TEXT_DIM)
	_status.hide()
	body.add_child(_status)

func show_error(message: String) -> void:
	_status.text = message
	_status.show()
