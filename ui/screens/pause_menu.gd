class_name PauseMenu
extends CanvasLayer

signal toggled(open: bool)
signal leave_requested

@onready var _root: Control = $Root
@onready var _header: Label = %Header


func _ready() -> void:
	$Root/Dim.color = Color(UiDesign.C_BG, 0.85)
	%Resume.pressed.connect(set_open.bind(false))
	%Back.pressed.connect(_leave)


func mount(online: bool) -> void:
	_header.text = "—— 菜单 ——" if online else "—— 已暂停 ——"


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
