extends Node2D

# 开山砍刀挥砍弧光(卡 wp_machete 评审稿随件特效):一次性扇形弧带,淡出后自毁。
# 画在世界系(machete.gd 加到 get_viewport() 下),角度按开火瞬间的世界瞄准方向给定,
# 不随持有者的镜像/旋转变化——生成后只管播放,与武器解耦。

@export var radius: float = 90.0        # 弧半径(px,= 挥砍射程)
@export var half_arc: float = 1.1345    # 半张角(弧度,默认 ≈65°=卡 arc_deg 130 的一半)
@export var center_angle: float = 0.0   # 中轴角(弧度,世界系瞄准方向)
@export var lifetime: float = 0.14      # 存续秒数
var color: Color = Color(0.85, 0.95, 1.0, 0.55)   # 淡青白(青蓝主调提亮)

var _t := 0.0

func _process(delta: float) -> void:
	_t += delta
	if _t >= lifetime:
		queue_free()
		return
	queue_redraw()

func _draw() -> void:
	var k := clampf(_t / lifetime, 0.0, 1.0)
	var c := color
	c.a = color.a * (1.0 - k)
	# 主弧带:外缘随时间略外扩(扫出去的余韵),粗线圆弧
	var r := radius * (0.82 + 0.18 * k)
	draw_arc(Vector2.ZERO, r, center_angle - half_arc, center_angle + half_arc, 24, c, 7.0)
	# 内圈副弧(更细更淡):读作刀刃扫过的轨迹层次
	var inner := c
	inner.a = c.a * 0.5
	draw_arc(Vector2.ZERO, r * 0.72, center_angle - half_arc * 0.8, center_angle + half_arc * 0.8, 20, inner, 3.0)
