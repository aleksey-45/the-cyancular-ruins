extends Node2D

# 激光光束视觉特效：由两层 Line2D（外层半透明光晕 + 内层高亮核心）沿折线顶点渲染，并在存续时间 lifetime 结束后淡出销毁。
# 纯表现层组件：开火时完整折线路径由 BeamTrace.trace 预先计算，本节点仅负责视觉绘制；
# 无物理碰撞体，不参与命中判定（伤害在开火当帧由激光武器逻辑即时结算）。
#
# 坐标规范：节点挂载于 Viewport 根部，位置置为 (0,0)；points 传入世界坐标点序列。
# 线段端帽与拐角关节采用 ROUND 圆角模式，确保光束在反射折点处平滑衔接无裂隙。

var lifetime: float = 0.4

func setup(points: PackedVector2Array, half_width: float, color: Color) -> void:
	var glow: Line2D = $Glow
	var core: Line2D = $Core
	# 关节与端帽采用圆角连接：保证反射折点处平滑衔接
	for ln in [glow, core]:
		ln.points = points
		ln.begin_cap_mode = Line2D.LINE_CAP_ROUND
		ln.end_cap_mode = Line2D.LINE_CAP_ROUND
		ln.joint_mode = Line2D.LINE_JOINT_ROUND
	# 外层光晕：半透明且继承武器光束颜色；内层核心：高亮近白色核心线
	glow.width = half_width * 5.0
	glow.default_color = Color(color.r, color.g, color.b, 0.30 * color.a)
	core.width = maxf(half_width * 1.4, 3.0)
	core.default_color = Color(1.0, 1.0, 1.0, 0.95)
	# 存续时长结束后淡出销毁（按 beam_lifetime 持续展示）
	var tw := create_tween()
	tw.tween_interval(maxf(lifetime - 0.12, 0.0))
	tw.tween_property(self, "modulate:a", 0.0, minf(lifetime, 0.12))
	tw.tween_callback(queue_free)
