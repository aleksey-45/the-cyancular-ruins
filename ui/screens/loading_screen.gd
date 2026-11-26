class_name LoadingScreen
extends CanvasLayer

const SCENE_PATH := "res://scenes/loading_screen.tscn"

@onready var _header: Label = %HeaderText
@onready var _status: Label = %Status
@onready var _back: Button = %Back


static func find(tree: SceneTree) -> LoadingScreen:
	for child in tree.root.get_children():
		if child is LoadingScreen and not child.is_queued_for_deletion():
			return child
	return null


static func mount(tree: SceneTree) -> LoadingScreen:
	var existing := find(tree)
	if existing != null:
		return existing
	var packed: PackedScene = load(SCENE_PATH)
	var screen: LoadingScreen = packed.instantiate()
	tree.root.add_child(screen)
	return screen


func show_loading(text: String) -> void:
	_header.text = "载入中"
	_header.remove_theme_color_override("font_color")
	_status.text = text
	_back.hide()


func show_failure(text: String) -> void:
	_header.text = "载入失败"
	_header.add_theme_color_override("font_color", UiDesign.C_DANGER)
	_status.text = text
	_back.show()
	_back.grab_focus()


func is_loading() -> bool:
	return not _back.visible


func _input(event: InputEvent) -> void:
	if is_loading():
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		queue_free()
