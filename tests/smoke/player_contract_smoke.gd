extends SceneTree

# 玩家对象公开接口规范防御性校验检查：
# 静态源码级断言，确保 Player 核心公开 API、属性与方法签名在重构过程中未被破坏或意外遗漏。
# 运行方式：
#   "$GODOT" --headless --path . -s res://tests/smoke/player_contract_smoke.gd

var _failures: Array[String] = []

func _check(cond: bool, name: String) -> void:
	if cond:
		print("  ok  - " + name)
	else:
		_failures.append(name)
		printerr("  FAIL - " + name)

func _initialize() -> void:
	var src := FileAccess.get_file_as_string("res://scenes/player/player.gd")
	var step := FileAccess.get_file_as_string("res://core/sim/actor_step.gd")
	var lsrc := FileAccess.get_file_as_string("res://scenes/player/climb_component.gd")
	var csrc := FileAccess.get_file_as_string("res://scenes/player/combat_component.gd")
	var wsrc := FileAccess.get_file_as_string("res://scenes/player/weapon_component.gd")
	# 根公开方法(外部调用方依赖,签名必须保持)
	for sig in [
		"func take_hit(",
		"func get_facing(",
		"func set_facing(",
		"func is_downed(",
		"func apply_recoil(",
		"signal hp_changed(",
		"add_to_group(\"player\")",
	]:
		_check(src.contains(sig), "player.gd 含 " + sig)
	# 公开只读属性(HUD 直接读,见 hud.gd:37/39)
	_check(src.contains("var hp: int:"), "player.gd 公开 hp 属性")
	_check(src.contains("var max_hp: int:"), "player.gd 公开 max_hp 属性")
	# 输入源抽象(行为不变重构):根不再直接读全局 Input,且可注入
	_check(step.contains("actor.step_input.get_axis"), "共享步进读取固定输入记录")
	_check(src.contains("func set_input_source("), "player.gd 输入可注入")
	# 三个组件文件 + class_name
	var comps: Array = [
		[lsrc, "climb_component.gd", "class_name ClimbComponent"],
		[csrc, "combat_component.gd", "class_name CombatComponent"],
		[wsrc, "weapon_component.gd", "class_name WeaponComponent"],
	]
	for pair in comps:
		_check(str(pair[0]).length() > 0 and str(pair[0]).contains(str(pair[2])),
				"含 " + str(pair[1]) + " 的 " + str(pair[2]))
	_check(wsrc.contains("WeaponRegistry"),
			"weapon_component.gd 的武器类型取自 WeaponRegistry(单一来源)")
	# 使用 ScanUtil.code_only 过滤注释文本后匹配源码，避免注释中的旧标识符引起误报。
	# 使用 load 动态加载 ScanUtil，加载失败时回退为原始源码视图。
	var su: Variant = load("res://tests/lib/scan_util.gd")
	var wcode: String = wsrc
	if su != null and su.has_method("code_only"):
		wcode = su.code_only(wsrc)
	else:
		printerr("  (注意:ScanUtil 取不到,本条退化为未剥注释的源码视图)")
	for k in ["WEAPONS", "DISPLAY_NAMES", "TIERS"]:
		_check(not wcode.contains(k),
				"weapon_component.gd 不得再有旧表 %s(半迁移守卫;与 enemy_logic_smoke ⑤b 同口径)" % k)
	_check(step.contains("actor.climb.update("), "共享步进驱动 climb.update")
	_check(step.contains("actor.combat.apply_knock("), "共享步进驱动 combat.apply_knock")
	_check(step.contains("actor.weapons.movement_multiplier()"), "共享步进驱动 weapons.movement_multiplier")

	if _failures.is_empty():
		print("\nCONTRACT OK")
		quit(0)
	else:
		printerr("\nCONTRACT FAIL: %d 项" % _failures.size())
		quit(1)
