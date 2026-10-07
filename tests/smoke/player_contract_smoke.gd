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
	_check(src.contains("input_source.get_axis"), "player.gd 输入走 input_source")
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
	# 武器类型来自注册表的单一来源(2026-09-26 改写)。
	# - 旧断言查的是 `weapon_component.gd` 里 `"1"`..`"5"` 这几个字符串键 —— 那是当年
	#   那份硬编码表(`WEAPONS`/`DISPLAY_NAMES`/`TIERS`)的形状。注册表那批把那三张表整体删除
	#   (见 docs/eng/weapons.md),于是这条断言始终断言失败(`"1"` 还碰巧在别处出现,`"2"`..`"5"` 不在)
	#   —— 而它现在断言的是新不变量的反面:`enemy_logic_smoke` 的 ⑤b 反向要求那三个标识符
	#   在生产目录里零命中(防半途迁移)。 ->  按本仓纪律"探针因重构变红时改探针认新入口":
	#   契约改成当前形态 —— 组件的武器类型必须取自注册表,而不是自己再抄一份清单。
	_check(wsrc.contains("WeaponRegistry"),
			"weapon_component.gd 的武器类型取自 WeaponRegistry(单一来源)")
	# - 判定条件走 `code_only`(剥注释)而不是裸 `contains`:本仓爱留墓碑注释,而墓碑里很可能
	#   提到被删标识符的名字 —— 直接字符串包含匹配 会测试误报,而测试误报的下场历来是"把断言改松"
	#   (本仓明文禁忌)。与 `enemy_logic_smoke` ⑤b 同口径。
	# - 用 `load()` 而不是静态引用 `ScanUtil`:`-s` 阶段静态引用测试库没有先例
	#   (注册表那批登记过这条未验证项),`load()` 绕开它;取不到就退化成裸源码视图,
	#   并在报告里说明(不静默弱化)。
	var su: Variant = load("res://tests/lib/scan_util.gd")
	var wcode: String = wsrc
	if su != null and su.has_method("code_only"):
		wcode = su.code_only(wsrc)
	else:
		printerr("  (注意:ScanUtil 取不到,本条退化为未剥注释的源码视图)")
	for k in ["WEAPONS", "DISPLAY_NAMES", "TIERS"]:
		_check(not wcode.contains(k),
				"weapon_component.gd 不得再有旧表 %s(半迁移守卫;与 enemy_logic_smoke ⑤b 同口径)" % k)
	# 根每物理帧显式驱动三个组件
	_check(src.contains("climb.update("), "根驱动 climb.update")
	_check(src.contains("combat.apply_knock("), "根驱动 combat.apply_knock")
	_check(src.contains("weapons.movement_multiplier()"), "根驱动 weapons.movement_multiplier")

	if _failures.is_empty():
		print("\nCONTRACT OK")
		quit(0)
	else:
		printerr("\nCONTRACT FAIL: %d 项" % _failures.size())
		quit(1)
