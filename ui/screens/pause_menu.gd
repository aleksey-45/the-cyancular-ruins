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

	# 全屏压暗罩(0.55):暂停比中央广播更需要挡住背景 —— 底下是**实时**的游戏世界。
	# 颜色是本文件唯一的字面量(压暗罩是"职责",不属于调色板语义)。
	# ★ 不设 mouse_filter:保持原状的 STOP —— 整屏吃掉鼠标事件(与改版前逐字一致)。
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.55)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.add_child(center)

	# 凿刻面板(外深线 + 内亮线),内容加进它那个名为 `Body` 的 PanelContainer。
	var panel := UiFactory.menu_panel(Vector2(72, 44))
	center.add_child(panel)

	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 28)
	(panel.get_node("Body") as Container).add_child(vb)

	# 标题带:琥珀标题 + C_HEADER 底 + 只有下边一条线。
	# ★ 文案**逐字未改** —— 单机「—— 已暂停 ——」/ PvP「—— 菜单 ——」,字号仍取 64
	#   (L4 视觉守卫按这两条钉着:`tests/probe/kh_l4_visual_probe.gd` 找得到该文本、
	#   且断言它的 font_size == 64)。改文案/字号会当场红。
	vb.add_child(UiFactory.header_strip("—— 已暂停 ——" if not is_pvp else "—— 菜单 ——", 64))

	# 两颗按钮:继续 = 主行动(gold)、回主菜单 = 弱化(quiet)。VBox 会把它们拉齐到面板宽。
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

# 控件工厂(_style/_label/_button)已搬到 ui/ui_factory.gd 的 UiFactory —— 字体/字号/点击音
# 纪律现在只有一份实现,本文件不再自带副本。
