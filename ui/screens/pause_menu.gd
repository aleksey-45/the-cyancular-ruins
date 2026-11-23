class_name PauseMenu
extends CanvasLayer

# 暂停菜单(设计系统 v2):CanvasLayer + Control 叠加层,原地开合。
# ★ siri 契约不变:mount(online) / set_open(open) / toggled(open) / leave_requested,原公开入口全部保留;
#   Esc 原地开合,暂停 tree 仍由 MatchController 监听 toggled 后处理(SOLO 暂停 tree+冻结输入,对局冻结输入),
#   返回菜单仍由 MatchController 监听 leave_requested 后走 SceneTransition —— 本页不直接改 tree/切场景。
# ★ main 的 is_pvp / open / close / toggle / go_menu 保留为薄别名(全仓目前无外部调用,仅为契约兼容)。
# ★ 布局:Theme 2.0 的 Card/H2/Primary/Quiet variation + UiDesign token;遮罩色取 UiDesign.C_BG,
#   0.85 不透明度是本页版式参数(与 main 暂停菜单一致),不手写 StyleBox、不写绝对坐标。

signal toggled(open: bool)
signal leave_requested

# 遮罩不透明度:0.85 时仍能透出一点战局背景(纯黑会被读成整页换场)。
const DIM_ALPHA := 0.85
# 两个按钮统一成同一宽度:SP_10 × 6 = 480(与原 siri 480 一致;是内容驱动的下限,不是绝对坐标)。
const BUTTON_MIN_W := UiDesign.SP_10 * 6

@export var is_pvp := false

var _root: Control
var _dim: ColorRect
var _header: Label
var _resume: Button
var _back: Button
var _open := false


func _ready() -> void:
	_ensure_ui()
	_apply_layout()
	_resume.pressed.connect(close)
	_back.pressed.connect(go_menu)
	_root.visible = false


# siri 现有入口:MatchView.mount 传入 online = (mode != SOLO)。
func mount(online: bool) -> void:
	is_pvp = online
	_ensure_ui()
	_apply_layout()
	_open = false
	_root.visible = false


func _unhandled_input(event: InputEvent) -> void:
	if _root != null and event.is_action_pressed("ui_cancel"):
		set_open(not _root.visible)
		get_viewport().set_input_as_handled()


func set_open(open: bool) -> void:
	_ensure_ui()
	_open = open
	_root.visible = open
	toggled.emit(open)
	Sfx.play("ui")


# ── main 契约薄别名(不改变 siri 的暂停归属)──
func open() -> void:
	set_open(true)


func close() -> void:
	set_open(false)


func toggle() -> void:
	set_open(not _open)


func go_menu() -> void:
	Sfx.play("ui")
	leave_requested.emit()


# 旧实现的私有入口,保留成薄别名(无外部调用)。
func _leave() -> void:
	go_menu()


func _ensure_ui() -> void:
	if _root != null:
		return
	# 场景(ui/screens/pause_menu.tscn)实例化:沿用场景骨架;裸脚本挂 CanvasLayer(MatchView.$Pause):就地构建。
	var existing := get_node_or_null("Root") as Control
	if existing != null:
		_root = existing
		_dim = $Root/Dim as ColorRect
		_header = $Root/Center/Dialog/Body/Header as Label
		_resume = $Root/Center/Dialog/Body/Resume as Button
		_back = $Root/Center/Dialog/Body/Back as Button
		return
	_root = Control.new()
	_root.name = "Root"
	_root.theme = UiDesign.MENU_THEME
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_root)
	_dim = ColorRect.new()
	_dim.name = "Dim"
	_dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.add_child(_dim)
	var center := CenterContainer.new()
	center.name = "Center"
	center.mouse_filter = Control.MOUSE_FILTER_STOP
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.add_child(center)
	var dialog := UiDesign.ui_panel("card")
	dialog.name = "Dialog"
	center.add_child(dialog)
	var body := VBoxContainer.new()
	body.name = "Body"
	body.add_theme_constant_override("separation", UiDesign.SP_4)
	dialog.add_child(body)
	_header = UiDesign.ui_label(_title(), "h2")
	_header.name = "Header"
	_header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	body.add_child(_header)
	_resume = UiDesign.ui_button("继续游戏", UiDesign.T_H2, Vector2(BUTTON_MIN_W, 0), "primary")
	_resume.name = "Resume"
	body.add_child(_resume)
	_back = UiDesign.ui_button("回到主菜单", UiDesign.T_H2, Vector2(BUTTON_MIN_W, 0), "quiet")
	_back.name = "Back"
	body.add_child(_back)


func _apply_layout() -> void:
	_dim.color = UiDesign.C_BG
	_dim.modulate.a = DIM_ALPHA
	_header.text = _title()
	_header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	(_header.get_parent() as VBoxContainer).add_theme_constant_override("separation", UiDesign.SP_4)
	_resume.custom_minimum_size = Vector2(BUTTON_MIN_W, 0)
	_back.custom_minimum_size = Vector2(BUTTON_MIN_W, 0)


func _title() -> String:
	return "—— 菜单 ——" if is_pvp else "—— 已暂停 ——"
