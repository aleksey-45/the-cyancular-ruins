class_name EscMenu
extends CanvasLayer
# ESC 菜单(单机/PvP 共用):全屏灰色遮罩 + 居中「退出」按钮。
# 是否暂停由宿主决定(见 toggled 信号接线),本脚本只负责:
#   1) ESC 开/关 + 发 toggled(open)  2) ExitButton → exit_callback
# 根 process_mode=ALWAYS:单机暂停期间仍能收键鼠。菜单自带节点都在 esc_menu.tscn。

signal toggled(open: bool)

# 宿主注入:「退出」按下后的动作(单机=解暂停回主菜单;PvP=断连回主菜单)。
var exit_callback: Callable = Callable()
# false 时忽略 ESC(PvP 对局已结束/对手已走就关掉,免得与自动回菜单打架)。
var can_toggle := true

@onready var _center: Control = $Center
@onready var _mask: ColorRect = $Mask

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	($Center/VBox/ExitButton as Button).pressed.connect(_on_exit_pressed)
	set_open(false)

func _process(_delta: float) -> void:
	if can_toggle and Input.is_action_just_pressed("ui_cancel"):
		toggle()

func toggle() -> void:
	set_open(not is_open())
	toggled.emit(is_open())

func is_open() -> bool:
	return _center.visible

func set_open(open: bool) -> void:
	_center.visible = open
	_mask.visible = open

func _on_exit_pressed() -> void:
	if exit_callback.is_valid():
		exit_callback.call()
