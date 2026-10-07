extends SceneTree
# 设置界面按 ESC 的回归探针(2026-10-01)。
#
# - 存在的理由:`change_scene_to_file` 在 Godot 4 里**同步 memdelete** 当前场景
#   (仓内另一处佐证见 `scenes/level_0.gd` 的 `safe_change_scene` 注释)。于是
#   "切场景之后还碰 self" 就是 use-after-free —— 表现是整个进程崩掉(不是脚本报错)。
#   本探针把"主菜单 → 设置 → 按 ESC"这条真实输入路径走一遍,并断言场景确实换成了主菜单。
#
# 跑法(必须真渲染? 不需要,headless 即可):
#   godot --headless --path . -s res://tests/probe/settings_esc_probe.gd
# 判据:最后一行 `SETTINGS ESC PROBE: ALL-OK`;崩了就没有这一行(退出码非 0)。

const SETTINGS_SCENE := "res://scenes/settings_menu.tscn"
const MENU_SCENE := "res://scenes/main_menu.tscn"
const WAIT_FRAMES := 6


func _initialize() -> void:
	_run()


func _run() -> void:
	await process_frame
	change_scene_to_file(SETTINGS_SCENE)
	for i in WAIT_FRAMES:
		await process_frame
	if current_scene == null or current_scene.scene_file_path != SETTINGS_SCENE:
		_fail("设置界面没加载起来(current_scene=%s)" % _scene_path())
		return
	print("[esc] 设置界面已就绪")

	# ① 普通态:按 ESC 应当回主菜单
	_send_escape()
	for i in WAIT_FRAMES:
		await process_frame
	var after := _scene_path()
	print("[esc] 按 ESC 之后 current_scene=%s" % after)
	if after != MENU_SCENE:
		_fail("按 ESC 没有回到主菜单(实得 %s)" % after)
		return

	# ② 捕获态:点一个键位按钮进入"按任意键…",再按 ESC 应当只取消捕获、留在本页
	change_scene_to_file(SETTINGS_SCENE)
	for i in WAIT_FRAMES:
		await process_frame
	if current_scene == null:
		_fail("第二次进入设置界面失败")
		return
	var btn: Button = _first_bind_button()
	if btn == null:
		_fail("找不到键位按钮(_bind_buttons 为空?)")
		return
	btn.emit_signal("pressed")
	for i in 2:
		await process_frame
	print("[esc] 进入捕获态,按钮文案=%s" % btn.text)
	_send_escape()
	for i in WAIT_FRAMES:
		await process_frame
	if _scene_path() != SETTINGS_SCENE:
		_fail("捕获态按 ESC 竟然离开了设置界面(实得 %s)" % _scene_path())
		return
	if btn.text.contains("按任意键"):
		_fail("捕获态按 ESC 没有取消捕获(按钮文案还是 %s)" % btn.text)
		return

	print("SETTINGS ESC PROBE: ALL-OK")
	quit(0)


func _scene_path() -> String:
	if current_scene == null:
		return "<null>"
	return current_scene.scene_file_path


func _first_bind_button() -> Button:
	var buttons: Dictionary = current_scene.get("_bind_buttons")
	for k in buttons:
		return buttons[k]
	return null


func _send_escape() -> void:
	# - 两个都要设:真实按键事件 `keycode` 与 `physical_keycode` 都有值 ——
	#   `ui_cancel` 的动作匹配读 `keycode`,而设置页的键位捕获读 `physical_keycode`。
	var down := InputEventKey.new()
	down.keycode = KEY_ESCAPE
	down.physical_keycode = KEY_ESCAPE
	down.unicode = 27
	down.pressed = true
	Input.parse_input_event(down)
	var up := InputEventKey.new()
	up.keycode = KEY_ESCAPE
	up.physical_keycode = KEY_ESCAPE
	up.pressed = false
	Input.parse_input_event(up)


func _fail(why: String) -> void:
	print("SETTINGS ESC PROBE: FAILED —— " + why)
	quit(1)
