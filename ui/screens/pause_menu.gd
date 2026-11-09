class_name PauseMenu
extends CanvasLayer

# 暂停菜单(设计系统 v1 / M4):CanvasLayer + Control 叠加层,原地开合。
# ★ 不是 AcceptDialog:暂停菜单要暂停 tree、要 Esc 原地开合、要以 _open 状态回吐 toggled 信号;
#   换成独立模态窗口会改这些语义(契约 §5 括号允许叠加层,皮肤仍全走 Theme 2.0)。
# ★ 遮罩 = UiFactory.C_BG + DIM_ALPHA(颜色来自 token,alpha 是本页版式参数);面板 = Theme Card,
#   按钮 = Primary/Quiet variation;间距/最小宽度只引 UiFactory 的 SP_* token。
# ★ 保留:信号 toggled(open)、export is_pvp、open/close/toggle/go_menu 行为、Esc 处理与所有文本。

signal toggled(open: bool)

# 遮罩不透明度:0.85 时仍能透出一点战局背景(纯黑会被读成整页换场)。
const DIM_ALPHA := 0.85
# 两个按钮统一成同一宽度:SP_10 × 6 = 480(与旧的 480 一致,内容驱动的下限而不是绝对坐标)。
const BUTTON_MIN_W := UiFactory.SP_10 * 6

@export var is_pvp := false

@onready var _root: Control = $Root
@onready var _dim: ColorRect = $Root/Dim
@onready var _header: Label = $Root/Center/Dialog/Body/Header
@onready var _resume: Button = $Root/Center/Dialog/Body/Resume
@onready var _back: Button = $Root/Center/Dialog/Body/Back

var _open := false


func _ready() -> void:
	_root.visible = false
	_dim.color = UiFactory.C_BG
	_dim.modulate.a = DIM_ALPHA
	($Root/Center/Dialog/Body as VBoxContainer).add_theme_constant_override(
			"separation", UiFactory.SP_4)
	_resume.custom_minimum_size = Vector2(BUTTON_MIN_W, 0)
	_back.custom_minimum_size = Vector2(BUTTON_MIN_W, 0)
	_header.text = "—— 已暂停 ——" if not is_pvp else "—— 菜单 ——"
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
