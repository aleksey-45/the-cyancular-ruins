extends SceneTree

# 设置面板可配置动作名覆盖检查：
# 验证 REMAPPABLE_ACTIONS 中定义的每个按键绑定动作均具有对应本地化显示文本。
# 运行方式：
#   "$GODOT" --headless --path . -s res://tests/smoke/settings_actions_smoke.gd

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
	# - 空载守卫:读不到就 quit,免得在空表上把"零条"当成"全过"
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
