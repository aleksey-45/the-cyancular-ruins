class_name PauseMenu
extends CanvasLayer

signal toggled(open: bool)
signal leave_requested

var _root := Control.new()

func mount(online: bool) -> void:
	_root.hide()
	UiFactory.cover(self, _root)
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 28)
	UiFactory.centered(_root, body, 0.55, true)
	body.add_child(UiFactory.header_strip("—— 菜单 ——" if online else "—— 已暂停 ——", 64, true))
	UiFactory.action(body, "继续游戏", Vector2(480, 72), &"BtnGold", set_open.bind(false))
	UiFactory.action(body, "回到主菜单", Vector2(480, 72), &"BtnQuiet", _leave)

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		set_open(not _root.visible)
		get_viewport().set_input_as_handled()

func set_open(open: bool) -> void:
	_root.visible = open
	toggled.emit(open)
	Sfx.play("ui")

func _leave() -> void:
	Sfx.play("ui")
	leave_requested.emit()
