extends Node2D


var lifetime: float = 0.4

func setup(points: PackedVector2Array, half_width: float, color: Color) -> void:
	var glow: Line2D = $Glow
	var core: Line2D = $Core
	for ln in [glow, core]:
		ln.points = points
		ln.begin_cap_mode = Line2D.LINE_CAP_ROUND
		ln.end_cap_mode = Line2D.LINE_CAP_ROUND
		ln.joint_mode = Line2D.LINE_JOINT_ROUND
	glow.width = half_width * 5.0
	glow.default_color = Color(color.r, color.g, color.b, 0.30 * color.a)
	core.width = maxf(half_width * 1.4, 3.0)
	core.default_color = Color(1.0, 1.0, 1.0, 0.95)
	var tw := create_tween()
	tw.tween_interval(maxf(lifetime - 0.12, 0.0))
	tw.tween_property(self, "modulate:a", 0.0, minf(lifetime, 0.12))
	tw.tween_callback(queue_free)
