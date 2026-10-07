class_name BulletTrail
extends Line2D

# 子弹拖尾轨迹特效：挂载于子弹节点下，记录最近若干帧的世界坐标位置绘制尾迹线。
# 启用 top_level 脱离子弹自身的局部旋转与缩放影响，由设置中的“显示敌方武器轨迹”配置项统一控制显隐。

const KEEP_POINTS := 16


static func attach(bullet: Node2D, color: Color) -> void:
	var t := BulletTrail.new()
	t.width = 2.5
	t.default_color = Color(color.r, color.g, color.b, 0.55)
	t.top_level = true
	t.z_index = -1
	bullet.add_child(t)
	t.add_point(bullet.global_position)


func _process(_delta: float) -> void:
	var owner_node := get_parent() as Node2D
	if owner_node == null or not is_instance_valid(owner_node):
		return
	add_point(owner_node.global_position)
	while get_point_count() > KEEP_POINTS:
		remove_point(0)
