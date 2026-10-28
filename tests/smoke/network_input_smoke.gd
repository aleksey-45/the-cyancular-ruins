extends SceneTree

# 网络输入源轴向映射单元冒烟测试：
# 验证 PacketInputSource 输入打包与解包时的轴向逻辑（确保垂直与水平分量语义准确）。

func _initialize() -> void:
	var src := PacketInputSource.new()
	var fail := 0

	# 上爬:held=UP、水平 ax=0 -> 垂直轴应 -1,水平轴应 0
	src.apply_packet({"ax": 0.0, "held": PacketInputSource.BIT_UP, "pressed": 0, "released": 0, "winst": 0, "aim": Vector2.RIGHT})
	fail += _check("UP held → 垂直 -1", is_equal_approx(src.get_axis("up", "down"), -1.0))
	fail += _check("UP held → 水平 0", is_equal_approx(src.get_axis("left", "right"), 0.0))

	# 下爬:held=DOWN -> 垂直 +1
	src.apply_packet({"ax": 0.0, "held": PacketInputSource.BIT_DOWN, "pressed": 0, "released": 0, "winst": 0, "aim": Vector2.RIGHT})
	fail += _check("DOWN held → 垂直 +1", is_equal_approx(src.get_axis("up", "down"), 1.0))

	# 未按上下 -> 垂直 0(阻塞挂起)
	src.apply_packet({"ax": 0.0, "held": 0, "pressed": 0, "released": 0, "winst": 0, "aim": Vector2.RIGHT})
	fail += _check("无上下 → 垂直 0", is_equal_approx(src.get_axis("up", "down"), 0.0))

	# 水平移动:ax=1 -> left/right 返回 1;垂直仍 0(无 held 上下)
	src.apply_packet({"ax": 1.0, "held": 0, "pressed": 0, "released": 0, "winst": 0, "aim": Vector2.RIGHT})
	fail += _check("ax=1 → 水平 1", is_equal_approx(src.get_axis("left", "right"), 1.0))
	fail += _check("ax=1 时垂直仍 0", is_equal_approx(src.get_axis("up", "down"), 0.0))
	fail += _check_button_freeze(src)

	if fail == 0:
		print("NET_INPUT_OK: get_axis 垂直轴由 held 推导、水平轴由 ax 返回")
		quit(0)
	else:
		printerr("NET_INPUT_FAIL: %d 项断言失败" % fail)
		quit(1)

func _check(name: String, cond: bool) -> int:
	if cond:
		print("  ok  - " + name)
		return 0
	printerr("  FAIL- " + name)
	return 1

# 紧凑输入与通用接口必须遵守同一控制锁；解冻不能丢失持续输入或瞄准。
func _check_button_freeze(src: PacketInputSource) -> int:
	var command := ActorInput.new()
	var buttons := {"up": PacketInputSource.BIT_UP, "down": PacketInputSource.BIT_DOWN,
			"charge": PacketInputSource.BIT_CHARGE, "attack": PacketInputSource.BIT_ATTACK,
			"R": PacketInputSource.BIT_RELOAD, "haste": PacketInputSource.BIT_HASTE,
			"rewind": PacketInputSource.BIT_REWIND}
	for mask: int in [0, 1, 6, 24, 384, 511]:
		var record := {"ax": 1.0, "held": mask, "pressed": mask ^ 511,
				"released": mask, "winst": 42, "aim": Vector2.UP}
		src.apply_packet(record)
		for locked: bool in [false, true, false]:
			src.frozen = locked
			command.prepare(record, locked)
			for action: String in buttons:
				var bit: int = buttons[action]
				if ((command.held & bit) != 0) != src.is_action_pressed(action) \
						or ((command.pressed & bit) != 0) != src.is_action_just_pressed(action) \
						or ((command.released & bit) != 0) != src.is_action_just_released(action):
					return _check("控制锁与按键边沿契约", false)
			if command.aim != Vector2.UP or command.weapon_inst != src.consume_switch_inst():
				return _check("控制锁保留瞄准和切枪请求", false)
			if command.axis != src.get_axis("left", "right") or command.vertical_axis != src.get_axis("up", "down") \
					or command.raw_axis != 1.0 or command.raw_held != mask:
				return _check("控制锁保留原始输入并冻结模拟移动", false)
	return _check("控制锁前后紧凑输入与通用输入一致", true)
