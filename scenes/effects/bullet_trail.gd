class_name BulletTrail
extends Line2D

# 子弹轨迹线(可选视觉,实验分支 KikuchiHeinr):挂在子弹下,记录最近若干位置画尾巴。
# top_level 脱离子弹旋转/缩放,世界坐标取点。设置里的"显示敌方武器轨迹"开关控制。

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
