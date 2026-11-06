class_name PauseMenu
extends CanvasLayer


signal toggled(open: bool)

@export var is_pvp := false

@onready var _root: Control = $Root
@onready var _header: HeaderStripPanel = $Root/Center/Panel/Body/VBox/Header
@onready var _resume: Button = $Root/Center/Panel/Body/VBox/Resume
@onready var _back: Button = $Root/Center/Panel/Body/VBox/Back

var _open := false


func _ready() -> void:
	_root.visible = false
	_header.title = "—— 已暂停 ——" if not is_pvp else "—— 菜单 ——"
	_resume.pressed.connect(close)
	_back.pressed.connect(go_menu)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		toggle()
		get_viewport().set_input_as_handled()


func toggle() -> void:
	if _open:
		close()
	else:
		open()


func open() -> void:
	_open = true
	_root.visible = true
	if not is_pvp:
		get_tree().paused = true
	toggled.emit(true)
	Sfx.play("ui")


func close() -> void:
	_open = false
	_root.visible = false
	if not is_pvp:
		get_tree().paused = false
	toggled.emit(false)
	Sfx.play("ui")


func go_menu() -> void:
	get_tree().paused = false
	Sfx.play("ui")
	if is_pvp:
		NetBus.stop()
	Level0.safe_change_scene(get_tree(), "res://scenes/main_menu.tscn")
