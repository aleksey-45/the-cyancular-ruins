extends RefCounted

# 激光光束/枪口光球的视觉构建(纯静态、preload 引用、不引 autoload)。把"已算好的光束几何 →
# 画成视觉节点"从激光武器实例里解耦出来:本地武器开火、PvP 远端收到 beam_fired 事件都调同一套。
# 无 class_name(仓库同款:BeamTrace / TileHitFx 都是 preload-only 静态,省去新类名刷缓存)。
#
# 坐标约定(与 laser_beam.tscn 现约定一致):折线点传"所在 parent 系的世界坐标";
# parent 是能 add_child 的 viewport/节点(本地=武器 get_viewport(),PvP 远端=_world SubViewport),
# 光束节点挂 parent 后 global_position 置 0 → points 直接是世界系。光束淡出自毁,无需外部清理。

const BEAM_SCENE := preload("res://scenes/weapons/laser_beam.tscn")

# 折线光束(FLASH 风格)。style 预留视觉风格分支(现仅 0;未来 SUSTAINED 等在此加)。
static func spawn_beam(parent: Node, points: PackedVector2Array, half_width: float,
		color: Color, lifetime: float, _style: int = 0) -> void:
	if parent == null or points.size() < 2:
		return
	var beam := BEAM_SCENE.instantiate()  # untyped:laser_beam.gd 无 class_name,动态访问属性
	parent.add_child(beam)
	beam.global_position = Vector2.ZERO
	beam.lifetime = lifetime
	if beam.has_method("setup"):
		beam.setup(points, half_width, color)

# 开火时枪口"发射光源"圆球:配色/存续与激光光束同款 —— 外层光晕用 color(仿激光 Glow,
# alpha=0.30)、内芯近白(仿激光 Core),挂满 lifetime、末尾与光束同步淡出。
# 尺寸随光束粗细缩放(细光束时也给个下限保证可见)。挂 parent(世界系,不随枪 2.5x 缩放)。
static func spawn_muzzle_orb(parent: Node, at: Vector2, color: Color, half_width: float, lifetime: float) -> void:
	if parent == null:
		return
	var holder := Node2D.new()
	holder.global_position = at
	# 内芯半径(px)≈ 光束 core 半径;下限 5 保证光束调到很细时枪口球仍可辨
	var core_r := maxf(half_width * 0.7, 5.0)
	var glow_r := core_r * 2.6
	# Explosion.make_circle_texture(size):size px 贴图、圆心在中央,scale=半径/半贴图宽。
	var glow := Sprite2D.new()
	glow.texture = Explosion.make_circle_texture(32)
	glow.modulate = Color(color.r, color.g, color.b, 0.30 * color.a)
	glow.scale = Vector2.ONE * (glow_r / 16.0)
	var core := Sprite2D.new()
	core.texture = Explosion.make_circle_texture(16)
	core.modulate = Color(1.0, 1.0, 1.0, 0.95)
	core.scale = Vector2.ONE * (core_r / 8.0)
	holder.add_child(glow)
	holder.add_child(core)
	parent.add_child(holder)
	# 与激光光束同步存续:满亮撑 lifetime,末尾 0.12s 一起淡出后自毁(同 laser_beam 节奏)。
	var tw := holder.create_tween()
	tw.tween_interval(maxf(lifetime - 0.12, 0.0))
	tw.tween_property(holder, "modulate:a", 0.0, minf(lifetime, 0.12))
	tw.tween_callback(holder.queue_free)
