extends SceneTree
# 网络输入源单元冒烟:验证 NetworkInputSource.get_axis 的轴语义。
# 回归覆盖:get_axis("up","down") 曾一律返回水平 ax → 服务器攀爬方向恒 0 → 梯子大量回拉。
# 用法: godot --headless --path . -s res://Tests/network_input_smoke.gd
# (NetworkInputSource 是纯 RefCounted,不依赖 autoload,-s 阶段可安全引用)

func _initialize() -> void:
	var src := NetworkInputSource.new()
	var fail := 0

	# 上爬:held=UP、水平 ax=0 → 垂直轴应 -1,水平轴应 0
	src.apply_packet({"ax": 0.0, "held": NetworkInputSource.BIT_UP, "pressed": 0, "released": 0, "weapon": 0})
	fail += _check("UP held → 垂直 -1", is_equal_approx(src.get_axis("up", "down"), -1.0))
	fail += _check("UP held → 水平 0", is_equal_approx(src.get_axis("left", "right"), 0.0))

	# 下爬:held=DOWN → 垂直 +1
	src.apply_packet({"ax": 0.0, "held": NetworkInputSource.BIT_DOWN, "pressed": 0, "released": 0, "weapon": 0})
	fail += _check("DOWN held → 垂直 +1", is_equal_approx(src.get_axis("up", "down"), 1.0))

	# 未按上下 → 垂直 0(挂住)
	src.apply_packet({"ax": 0.0, "held": 0, "pressed": 0, "released": 0, "weapon": 0})
	fail += _check("无上下 → 垂直 0", is_equal_approx(src.get_axis("up", "down"), 0.0))

	# 水平移动:ax=1 → left/right 返回 1;垂直仍 0(无 held 上下)
	src.apply_packet({"ax": 1.0, "held": 0, "pressed": 0, "released": 0, "weapon": 0})
	fail += _check("ax=1 → 水平 1", is_equal_approx(src.get_axis("left", "right"), 1.0))
	fail += _check("ax=1 时垂直仍 0", is_equal_approx(src.get_axis("up", "down"), 0.0))

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
