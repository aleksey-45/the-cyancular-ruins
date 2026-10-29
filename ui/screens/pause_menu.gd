class_name PauseMenu
extends CanvasLayer

# 暂停菜单(Esc 呼出)。单机暂停整棵场景树(敌人/物理全停);PvP 不暂停树(服务器权威继续跑,本地只是弹层),
# 回主菜单 = 断开连接(worker 检测任一方断开即拆局退出,见 server_main._on_peer_left)。
# ★ process_mode=ALWAYS:树暂停时本层仍响应输入;Esc 由本层独占(set_input_as_handled 后场景根不会再拿到),避免双重触发。

# ★ 宿主(PvP)据此锁本地输入:PvP 下不暂停树,没有这道接线就是"菜单开着还能边跑边开枪"。
signal toggled(open: bool)

var is_pvp := false

var _root: Control = null
var _open := false


func _init(pvp := false) -> void:
	is_pvp = pvp
	layer = 145   # 盖过 PvpHud(130)/HUD(129)/PostProcess(128)
	process_mode = Node.PROCESS_MODE_ALWAYS


func _ready() -> void:
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.visible = false
	add_child(_root)

	# ★ 0.55 是本文件唯一的颜色字面量(压暗罩是"职责",不属调色板语义);不设 mouse_filter ⇒ 保持 STOP、整屏吃鼠标事件。
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

	# 标题带:琥珀标题 + C_HEADER 底 + 只有下边一条线。★ 文案与字号 64 是逐字照搬的,零守卫
	# (kh_l4_visual_probe 已删·2026-10-09):改文案/字号今天不会红。
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
	Sfx.play("ui")   # 开与关都有声


func close() -> void:
	_open = false
	_root.visible = false
	# 与 open() 对称:PvP 下没暂停树,close() 就不能解暂停(单机自己也解,防"菜单外被暂停后仍卡住")。
	if not is_pvp:
		get_tree().paused = false
	toggled.emit(false)
	Sfx.play("ui")


func go_menu() -> void:
	# 故意不按 is_pvp 分叉(与 close() 不同):这是整局退出路径,切场景前无条件解暂停是保底,否则回主菜单后整个冻住。
	get_tree().paused = false
	Sfx.play("ui")
	if is_pvp:
		Wire.stop()   # 断开对局(worker 检测断线自动拆局)
	# 世界含全量碰撞,change_scene 同步析构会偶发原生段错误(死亡后回菜单必现路径)⇒ 走 Level0.safe_change_scene。
	Level0.safe_change_scene(get_tree(), "res://scenes/main_menu.tscn")
