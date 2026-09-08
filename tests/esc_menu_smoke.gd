extends SceneTree
# EscMenu 源码级冒烟:实例化 tscn(不渲染/不真实输入),直接驱动公开 API,
# 验证开关状态/toggled 信号/单机接法(open→paused)/退出按钮→exit_callback。
# 宿主契约由宿主各自接:这里验 EscMenu 自身 + 单机「开=暂停」这一种典型接法。
# 注意:-s 的 _initialize 阶段 root 尚未进树,add_child 不会触发 _ready(@onready 仍为
# Nil),所以推迟到第一帧后跑(_run.call_deferred + await process_frame),时序与真实运行一致。

var _fail := 0

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	await process_frame   # 让 root 进树 + 本帧就绪
	var scene: PackedScene = load("res://ui/esc_menu.tscn")
	if scene == null:
		printerr("FAIL - 无法 load esc_menu.tscn")
		quit(1)
		return
	var menu: EscMenu = scene.instantiate() as EscMenu
	root.add_child(menu)   # root 已在树 → 同步触发 _ready,@onready 就位
	_check(!menu.is_open(), "初始应为关闭")
	_check(menu.process_mode == Node.PROCESS_MODE_ALWAYS, "process_mode 应为 ALWAYS(暂停期可用)")

	var exited := [false]
	menu.exit_callback = func() -> void: exited[0] = true

	# 注意:GDScript lambda 捕获外层局部变量是按值拷贝,回调里不能直接改外层标量 → 用数组承载。
	var toggled_vals := []
	menu.toggled.connect(func(open: bool) -> void: toggled_vals.append(open))   # 单机接法:开=暂停

	menu.toggle()
	_check(menu.is_open(), "toggle 后应打开")
	_check(toggled_vals == [true], "打开应发 toggled(true)")

	var exit_btn: Button = menu.get_node("Center/VBox/ExitButton")
	exit_btn.pressed.emit()
	_check(exited[0], "按退出应触发 exit_callback")

	menu.toggle()
	_check(!menu.is_open(), "再 toggle 应关闭")
	_check(toggled_vals == [true, false], "关闭应再发 toggled(false)")

	menu.queue_free()
	if _fail == 0:
		print("ESC MENU SMOKE OK")
	quit(0 if _fail == 0 else 1)

func _check(cond: bool, msg: String) -> void:
	if cond:
		print("  ok - " + msg)
	else:
		_fail += 1
		printerr("FAIL - " + msg)
