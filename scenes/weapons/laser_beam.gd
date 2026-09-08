extends Node2D

# 激光光束视觉:两层 Line2D(外光晕 + 内亮芯)沿折线铺点,存续 lifetime 后淡出销毁。
# 纯视觉/一次性:开火时整条路径已由 BeamTrace.trace 算出,这里只负责把它画出来。
# 无碰撞、无物理、不参与命中判定——伤害在开火瞬间由 laser_gun 结算。
#
# 坐标约定:本节点挂到 viewport、位置 (0,0);points 传世界坐标(与墙体同坐标系)。
# 折线在反射处有硬拐角 → 关节/端帽设 round,避免转折处断裂露出空隙。

var lifetime: float = 0.4

func setup(points: PackedVector2Array, half_width: float, color: Color) -> void:
	var glow: Line2D = $Glow
	var core: Line2D = $Core
	# 关节/端帽 round:反射拐点平滑衔接
	for ln in [glow, core]:
		ln.points = points
		ln.begin_cap_mode = Line2D.LINE_CAP_ROUND
		ln.end_cap_mode = Line2D.LINE_CAP_ROUND
		ln.joint_mode = Line2D.LINE_JOINT_ROUND
	# 光晕:宽、半透明、带武器色;内芯:窄、近白(粗光束的亮芯)
	glow.width = half_width * 5.0
	glow.default_color = Color(color.r, color.g, color.b, 0.30 * color.a)
	core.width = maxf(half_width * 1.4, 3.0)
	core.default_color = Color(1.0, 1.0, 1.0, 0.95)
	# 存续 lifetime 后淡出销毁(光束按 beam_lifetime 存续)
	var tw := create_tween()
	tw.tween_interval(maxf(lifetime - 0.12, 0.0))
	tw.tween_property(self, "modulate:a", 0.0, minf(lifetime, 0.12))
	tw.tween_callback(queue_free)
