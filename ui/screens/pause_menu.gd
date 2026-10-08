class_name PauseMenu
extends CanvasLayer

# 暂停菜单（按 Esc 键呼出）：
# - 单人模式：暂停整棵场景树物理与逻辑模拟，提供继续游戏与返回主菜单选项
# - 对战模式：不暂停场景树（服务端权威模拟持续运行），返回主菜单时断开网络连接
# process_mode 设置为 PROCESS_MODE_ALWAYS，确保在场景树暂停时依然响应输入。

signal toggled(open: bool)

var is_pvp := false

var _root: Control = null
var _open := false


func _init(pvp := false) -> void:
	is_pvp = pvp
	layer = 145
	process_mode = Node.PROCESS_MODE_ALWAYS


func _ready() -> void:
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.visible = false
	add_child(_root)

	# 全屏半透明遮罩
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.55)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.add_child(center)

	var panel := UiFactory.menu_panel(Vector2(72, 44))
	center.add_child(panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 28)
	(panel.get_node("Body") as Container).add_child(vb)

	# 标题栏：单人模式显示「—— 已暂停 ——」，对战模式显示「—— 菜单 ——」
	vb.add_child(UiFactory.header_strip("—— 已暂停 ——" if not is_pvp else "—— 菜单 ——", 64))

	var resume := UiFactory.menu_button("继 续 游 戏", 32, Vector2(480, 72), "gold")
	resume.pressed.connect(close)
	vb.add_child(resume)

	var menu := UiFactory.menu_button("回 到 主 菜 单", 32, Vector2(480, 72), "quiet")
	menu.pressed.connect(go_menu)
	vb.add_child(menu)


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
