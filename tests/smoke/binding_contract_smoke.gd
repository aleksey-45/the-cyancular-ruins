extends SceneTree
# 键位契约守卫(2026-11 用户改令):跳跃只能绑一个键且默认空格 · 冲刺没有独立键 ·
# 键位表与可重绑动作逐条对齐 · 捕获态允许 Shift / Ctrl / Alt / Tab · Esc 仍只用来取消。
# ★ 钉的是用户显式下的令,不是手感:再改键位方案时同步改这里(别让它变成"永远红"的闸)。

const EXPECTED_CHECKS := 7

var _fails: Array[String] = []
var _checks := 0


func _chk(ok: bool, msg: String) -> void:
	_checks += 1
	if not ok:
		_fails.append(msg)


func _key(code: int) -> InputEventKey:
	var ev := InputEventKey.new()
	ev.physical_keycode = code as Key
	ev.pressed = true
	return ev


func _initialize() -> void:
	# ★ 空载守卫(仓规):load() 失败还往下走会在 null 上抛错,而 `-s` 抛错走不到 quit() ⇒ 进程永久挂起。
	var settings_script: GDScript = load("res://core/config/settings.gd")
	var menu_script: GDScript = load("res://scenes/settings_menu.gd")
	if settings_script == null or menu_script == null:
		print("BINDING CONTRACT FAILED: load(settings.gd / settings_menu.gd) 返回 null(-s 空载守卫:不 quit 会挂死)")
		quit(1)
		return

	# ① 跳跃默认只有一个键,且是空格
	var up_codes: Array = []
	for ev in InputMap.action_get_events("up"):
		if ev is InputEventKey:
			up_codes.append(int((ev as InputEventKey).physical_keycode))
	_chk(up_codes.size() == 1 and int(up_codes[0]) == KEY_SPACE,
			"① 跳跃(up)默认必须只有空格一个键(实得 %s)" % str(up_codes))

	# ② 冲刺没有独立键:charge 动作仍在(输入位 / 服务器解码都用它),但没有事件
	_chk(InputMap.has_action("charge") and InputMap.action_get_events("charge").is_empty(),
			"② 冲刺(charge)不得有独立键位(实得 %d 个事件)" % InputMap.action_get_events("charge").size())

	# ③ 可重绑清单里没有冲刺
	var actions: Array = settings_script.REMAPPABLE_ACTIONS
	_chk(not actions.has("charge"), "③ 可重绑动作里不得出现冲刺(实得 %s)" % str(actions))

	# ④ 键位表与可重绑动作逐条对齐(漏一条界面就退化成英文键名)
	var names: Dictionary = menu_script.ACTION_NAMES
	var aligned: bool = names.size() == actions.size()
	for a in actions:
		aligned = aligned and names.has(a)
	_chk(aligned, "④ 键位表(%d 条)必须与可重绑动作(%d 条)逐条对齐" % [names.size(), actions.size()])

	# ⑤ Shift / Ctrl / Alt / Tab 都是合法键位(捕获态不得当修饰键吞掉)
	var accepted: Array = [KEY_SHIFT, KEY_CTRL, KEY_ALT, KEY_TAB]
	var rejected: Array = []
	for code in accepted:
		if int(menu_script.capture_action(_key(int(code)))) != int(menu_script.CAPTURE_ACCEPT):
			rejected.append(OS.get_keycode_string(code))
	_chk(rejected.is_empty(), "⑤ Shift/Ctrl/Alt/Tab 必须能绑成键位(被拒:%s)" % str(rejected))

	# ⑥ Esc 仍是取消,不是可绑键位
	_chk(int(menu_script.capture_action(_key(KEY_ESCAPE))) == int(menu_script.CAPTURE_CANCEL),
			"⑥ Esc 必须仍是取消捕获")

	# ⑦ 落盘往返:修饰键绑定落成单键,且不留残余修饰位(留了会变成"Ctrl+K"而匹配不上)
	var settings = settings_script.new()
	var tmp := "user://binding_contract_smoke.cfg"
	var round_ok := true
	for code in accepted:
		settings.set_binding("rewind", _key(int(code)), tmp)
		var evs := InputMap.action_get_events("rewind")
		round_ok = round_ok and evs.size() == 1 and evs[0] is InputEventKey
		if round_ok:
			var k := evs[0] as InputEventKey
			round_ok = int(k.physical_keycode) == int(code) and not k.shift_pressed \
					and not k.ctrl_pressed and not k.alt_pressed
	_chk(round_ok, "⑦ 修饰键绑定必须落成单键且无残余修饰位")
	settings.free()
	InputMap.load_from_project_settings()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp))

	if _checks != EXPECTED_CHECKS:
		_fails.append("★ 实跑 %d 条断言,与 EXPECTED_CHECKS=%d 对不上(有断言被静默跳过?)"
				% [_checks, EXPECTED_CHECKS])
	if _fails.is_empty():
		print("BINDING CONTRACT OK(%d 条断言):跳跃单键空格 · 冲刺无独立键 · 表对齐 · Shift/Ctrl/Alt/Tab 可绑 · Esc 取消 · 单键落盘" % _checks)
		quit(0)
	else:
		for f in _fails:
			print("  [FAIL] ", f)
		print("BINDING CONTRACT FAILED: %d 处" % _fails.size())
		quit(1)
