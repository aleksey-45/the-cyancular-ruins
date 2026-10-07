extends Node2D

# 可破坏瓦片受击粒子特效：播放一次性碎屑飞散动画并自动销毁。挂载于世界 Viewport 下渲染。

static var _tex: Texture2D = null


static func _texture() -> Texture2D:
	if _tex == null:
		var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
		img.fill(Color.WHITE)
		_tex = ImageTexture.create_from_image(img)
	return _tex


# 在 parent 节点（通常为世界 Viewport）的指定全局坐标 at 播放受击碎屑特效。
# 根据 texture_id 映射碎屑色相（如树叶绿色、树干棕色等）。
static func spawn(parent: Node, at: Vector2, texture_id: int) -> void:
	if parent == null:
		return
	var color := Color(0.6, 0.6, 0.6)
	if texture_id >= 15 and texture_id <= 18:
		color = Color(0.413, 0.701, 0.57, 1.0)     # 树叶碎片
	elif texture_id >= 19 and texture_id <= 20:
		color = Color(0.301, 0.398, 0.43, 1.0)   # 树干碎片
	var p := CPUParticles2D.new()
	p.texture = _texture()
	p.position = at
	p.amount = 10
	p.lifetime = 0.4
	p.one_shot = true
	p.explosiveness = 1.0
	p.direction = Vector2.UP
	p.spread = 180.0
	p.gravity = Vector2(0, 900.0)
	p.initial_velocity_min = -120.0
	p.initial_velocity_max = 120.0
	p.scale_amount_min = 1.0
	p.scale_amount_max = 2.0
	p.color = color
	parent.add_child(p)
	var tree := parent.get_tree()
	if tree != null:
		tree.create_timer(p.lifetime + 0.1).timeout.connect(p.queue_free)
