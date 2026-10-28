extends Node

# 【一次性】Phase 1 暂停菜单行为复核(headless):场景实例化、is_pvp 两态文案、开合与暂停树、
# toggled 信号、按钮接线。用法：
#   "<GODOT>" --headless --path . --quit-after 600 res://audit_shots/p1_verify_phase1.tscn

var _fails := 0


func _ready() -> void:
	await get_tree().process_frame
	await _case(false)
	await _case(true)
	print("P1P1VERIFY: DONE fails=%d" % _fails)
	get_tree().quit(0 if _fails == 0 else 1)


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("P1P1VERIFY: OK " + msg)
	else:
		print("P1P1VERIFY: FAIL " + msg)
		_fails += 1


func _case(is_pvp: bool) -> void:
	var ps: PackedScene = load("res://ui/screens/pause_menu.tscn")
	if ps == null:
		_check(false, "读不到 pause_menu.tscn")
		return
	var pm := ps.instantiate() as PauseMenu
	pm.is_pvp = is_pvp
	add_child(pm)
	await get_tree().process_frame
	await get_tree().process_frame
	var tag := "pvp=%s" % str(is_pvp)
	_check(pm.layer == 145 and pm.process_mode == Node.PROCESS_MODE_ALWAYS, "%s layer/process_mode" % tag)
	_check(pm.get_node("Root").visible == false, "%s 初始隐藏" % tag)
	var header := pm.get_node("Root/Center/Panel/Body/VBox/Header") as HeaderStripPanel
	_check(header != null, "%s Header 是 HeaderStripPanel" % tag)
	_check(header.title == ("—— 菜单 ——" if is_pvp else "—— 已暂停 ——"), "%s 标题=%s" % [tag, header.title])
	var got: Array = []
	pm.toggled.connect(func(open: bool) -> void: got.append(open))
	pm.call("open")
	await get_tree().process_frame
	_check(pm.get_node("Root").visible == true, "%s open 后可见" % tag)
	_check(get_tree().paused == (not is_pvp), "%s open 后 paused=%s" % [tag, str(get_tree().paused)])
	pm.get_node("Root/Center/Panel/Body/VBox/Resume").emit_signal("pressed")
	await get_tree().process_frame
	_check(pm.get_node("Root").visible == false, "%s 「继续游戏」= close" % tag)
	_check(get_tree().paused == false, "%s close 后 paused=false" % tag)
	_check(got == [true, false], "%s toggled 序列=%s" % [tag, str(got)])
	remove_child(pm)
	pm.queue_free()
	await get_tree().process_frame
	get_tree().paused = false
