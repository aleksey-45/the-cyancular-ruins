class_name PauseMenu
extends CanvasLayer

# 暂停菜单(Esc 呼出,实验分支):
# - 单机:暂停整棵场景树(敌人/物理全停),继续 / 回到主菜单
# - PvP:不暂停树(服务器权威继续跑,本地只是弹层),回到主菜单 = 断开连接
#   (worker 检测对局任一方断开即拆局退出,见 server_main._on_peer_left)
# process_mode=ALWAYS:树暂停时本层仍响应输入。Esc 由本层独占处理(反转序先于场景根收到,
# set_input_as_handled 后场景根的 push_input 不会再拿到),避免双重触发。

# 开关信号(对 KH 原件的有意偏离:原件没有信号,单机宿主靠暂停树本身即可)。
# 宿主(PvP)据此锁本地输入 —— PvP 下不暂停树,没有这道接线就是"菜单开着还能边跑边开枪"。
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

	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.55)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.add_child(dim)

	var vb := VBoxContainer.new()
	vb.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	vb.grow_horizontal = Control.GROW_DIRECTION_BOTH
	vb.grow_vertical = Control.GROW_DIRECTION_BOTH
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", 22)
	_root.add_child(vb)

	# 字号一律取 16 的倍数(本项目的像素字体只在 16 倍数下像素锐利,见 ui/hud.gd)
	vb.add_child(_label("—— 已暂停 ——" if not is_pvp else "—— 菜单 ——", 64, Color(0.55, 0.95, 1.0)))
	var resume := _button("继 续 游 戏", 32)
	resume.pressed.connect(close)
	vb.add_child(resume)
	var menu := _button("回 到 主 菜 单", 32)
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
	# PvP 不暂停树:对局在服务器继续,暂停只会让自己挨打
	if not is_pvp:
		get_tree().paused = true
	toggled.emit(true)
	Sfx.play("ui")   # 开与关都有声:原先只有关闭侧响,ESC 打开是静音的(不一致)


func close() -> void:
	_open = false
	_root.visible = false
	# 与 open() 对称:PvP 下 open() 没暂停树,close() 就不能解暂停
	# (单机自己也解,防"菜单外被暂停后仍卡住")
	if not is_pvp:
		get_tree().paused = false
	toggled.emit(false)
	Sfx.play("ui")


func go_menu() -> void:
	# 本行故意不按 is_pvp 分叉(与 close() 不同):这条是"整局退出"路径,切场景前无条件解暂停
	# 是保底 —— 万一树处于暂停态,回主菜单后会整个冻住(按钮都点不动)。PvP 下本就无人暂停树,
	# 故此处无实害。
	get_tree().paused = false
	Sfx.play("ui")
	if is_pvp:
		NetBus.stop()   # 断开对局(worker 检测断线自动拆局)
	# 游戏世界含全量碰撞,change_scene 同步析构会偶发原生段错误(死亡后回菜单必现路径)
	# → 走退役挂起式切换,见 Level0.safe_change_scene
	Level0.safe_change_scene(get_tree(), "res://scenes/main_menu.tscn")


# ── 控件工厂(像素风格)──
func _style(c: Control, font_size: int) -> void:
	c.add_theme_font_size_override("font_size", font_size)
	var pf: FontFile = load("res://assets/fonts/less_perfect_dos_vga.ttf")
	if pf != null:
		c.add_theme_font_override("font", pf)


func _label(text: String, size: int, color: Color = Color.WHITE) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_color_override("font_color", color)
	_style(l, size)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


func _button(text: String, size: int) -> Button:
	var b := Button.new()
	b.text = text
	_style(b, size)
	b.custom_minimum_size = Vector2(420, 64)
	# 点击音不在这里挂:两个按钮的 handler(close/go_menu)各自会响一声,而 ESC 走的也是同两条
	# 路径 —— 这里再挂一次就是同帧同调两个播放器("ui" 不在 Sfx.PITCH_VARIATION 里,音高也一样),
	# 是能听出来的双响。统一由 open/close/go_menu 三个状态转移出声(键盘与点击同源)。
	return b
