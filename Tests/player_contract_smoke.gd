extends SceneTree
# 玩家公开接口契约守卫:拆分重构期间保证公开 API 不被改名/删掉。
# 源码级检查(player.gd 在 -s 阶段因 autoload 无法实例化,见 CLAUDE.md 冒烟注释)。

var _failures: Array[String] = []

func _check(cond: bool, name: String) -> void:
	if cond:
		print("  ok  - " + name)
	else:
		_failures.append(name)
		printerr("  FAIL - " + name)

func _initialize() -> void:
	var src := FileAccess.get_file_as_string("res://Scenes/Player/player.gd")
	var lsrc := FileAccess.get_file_as_string("res://Scenes/Player/climb_component.gd")
	var csrc := FileAccess.get_file_as_string("res://Scenes/Player/combat_component.gd")
	var wsrc := FileAccess.get_file_as_string("res://Scenes/Player/weapon_component.gd")
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
	# 三个组件文件 + class_name
	var comps: Array = [
		[lsrc, "climb_component.gd", "class_name ClimbComponent"],
		[csrc, "combat_component.gd", "class_name CombatComponent"],
		[wsrc, "weapon_component.gd", "class_name WeaponComponent"],
	]
	for pair in comps:
		_check(str(pair[0]).length() > 0 and str(pair[0]).contains(str(pair[2])),
				"含 " + str(pair[1]) + " 的 " + str(pair[2]))
	# 武器注册表 5 槽(挪到 weapon 组件)
	for k in ["1", "2", "3", "4", "5"]:
		_check(wsrc.contains("\"%s\"" % k), "weapon 注册表含槽 %s" % k)
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
