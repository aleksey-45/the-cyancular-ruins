extends SceneTree

# 设置页动作名覆盖守卫:`REMAPPABLE_ACTIONS` 里的每个动作都必须有中文显示名。
# 跑法: "$GODOT" --headless --path . -s res://tests/smoke/settings_actions_smoke.gd
# 通过 = `SETTINGS ACTIONS OK` 退出 0。
#
# ★ 为什么需要它:`settings_menu` 用的是 ACTION_NAMES.get(action, action) —— 漏一条
#   不报错,只是那一行显示裸的动作名(F/Q 曾经就是这样,实测)。
# ★ 用 get_script_constant_map() 读常量,不直接取属性:取不存在的属性会抛错,
#   而 -s 抛错走不到 quit() → 永久挂起。
# ★ 两个方向都查:漏了要红;表里留着已经不可重映射的陈旧动作也要红。

var _fail := 0

func _check(ok: bool, msg: String) -> void:
	if ok:
		return
	_fail += 1
	print("[FAIL] ", msg)

func _const_map(path: String) -> Dictionary:
	var gs: GDScript = load(path)
	return {} if gs == null else gs.get_script_constant_map()

func _initialize() -> void:
	var st := _const_map("res://core/config/settings.gd")
	var sm := _const_map("res://scenes/settings_menu.gd")
	# ★ 空载守卫:读不到就 quit,免得在空表上把"零条"当成"全过"
	if st.is_empty() or sm.is_empty():
		print("SETTINGS ACTIONS FAILED: 读不到 settings.gd / settings_menu.gd 的常量表")
		quit(1)
		return

	var actions: Array = st.get("REMAPPABLE_ACTIONS", [])
	var names: Dictionary = sm.get("ACTION_NAMES", {})
	_check(actions.size() > 0, "REMAPPABLE_ACTIONS 不应为空")
	_check(names.size() > 0, "ACTION_NAMES 不应为空")

	for a in actions:
		_check(names.has(a), "动作 %s 在 ACTION_NAMES 里没有中文显示名" % a)
	for k in names:
		_check(actions.has(k), "ACTION_NAMES 里的 %s 不在 REMAPPABLE_ACTIONS 中(陈旧)" % k)

	if _fail == 0:
		print("SETTINGS ACTIONS OK（%d 个动作）" % actions.size())
		quit(0)
	else:
		print("SETTINGS ACTIONS FAILED: %d" % _fail)
		quit(1)
