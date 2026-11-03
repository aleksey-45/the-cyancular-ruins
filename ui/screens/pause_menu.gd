class_name PauseMenu
extends CanvasLayer

# 暂停菜单(Esc 呼出)。P1 场景化:骨架/版式在 pause_menu.tscn,本脚本只管开合、暂停与切场景。

# ★ 宿主(PvP)据此锁本地输入:PvP 下不暂停树,没有这道接线就是"菜单开着还能边跑边开枪"。
signal toggled(open: bool)

# 宿主在 add_child 之前赋值(旧的 PauseMenu.new(true/false) 参数由这个属性替代)。
@export var is_pvp := false

@onready var _root: Control = $Root
@onready var _header: HeaderStripPanel = $Root/Center/Panel/Body/VBox/Header
@onready var _resume: Button = $Root/Center/Panel/Body/VBox/Resume
@onready var _back: Button = $Root/Center/Panel/Body/VBox/Back

var _open := false


func _ready() -> void:
	_root.visible = false
	# 文案与字号是 2026-10-27 之前逐字照搬的(零守卫:kh_l4_visual_probe 已删·2026-10-09)。
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
		NetBus.stop()   # 断开对局(worker 检测断线自动拆局)
	# 世界含全量碰撞,change_scene 同步析构会偶发原生段错误(死亡后回菜单必现路径)⇒ 走 Level0.safe_change_scene。
	Level0.safe_change_scene(get_tree(), "res://scenes/main_menu.tscn")
