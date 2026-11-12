extends RefCounted

# 激光光束与枪口发光球体的视觉构建工具（纯静态函数，无 Autoload 依赖）。
# 将“已计算好的光束几何轨迹生成为视觉表现节点”的逻辑与武器业务解耦：
# 本地武器开火与多人联机远端同步接收 beam_fired 事件均复用该实现。
#
# 坐标规范：折线点序列传入 parent 所在坐标系的世界坐标；
# parent 为对应的 Viewport 或场景节点（本地开火为武器所在 Viewport，多人模式远端为权威世界节点）；
# 光束节点挂载后其 global_position 置为 (0,0)，光束表现完成后自动淡出并释放。

const BEAM_SCENE := preload("res://scenes/weapons/laser_beam.tscn")
const HALF_WIDTH := 2.0
const COLOR := Color(0.1, 0.35, 1, 1)
const LIFETIME := 0.25

static func play(parent: Node, path: PackedVector2Array, anchor: Vector2, size: Vector2) -> Node2D:
	var points := _anchored(path, anchor, size)
	var beam := BEAM_SCENE.instantiate()
	parent.add_child(beam)
	beam.global_position = Vector2.ZERO
	beam.lifetime = LIFETIME
	_add_muzzle_orb(beam, COLOR, HALF_WIDTH)
	beam.setup(points, HALF_WIDTH, COLOR)
	return beam

static func correct(beam: Node2D, path: PackedVector2Array, anchor: Vector2, size: Vector2) -> void:
	beam.set_path(_anchored(path, anchor, size))

static func _anchored(path: PackedVector2Array, anchor: Vector2, size: Vector2) -> PackedVector2Array:
	var points := path.duplicate()
	var offset := GridPathfinder.anchor_to_nearest(points[0], anchor, size) - points[0]
	for i in points.size():
		points[i] += offset
	return points

# 开火时枪口"发射光源"圆球:配色/存续与激光光束相同机制 —— 外层光晕用 color(仿激光 Glow,
# alpha=0.30)、内芯近白(仿激光 Core),挂满 lifetime、末尾与光束同步淡出。
# 尺寸随光束粗细缩放(细光束时也给个下限保证可见)。挂 parent(世界系,不随枪 2.5x 缩放)。
static func _add_muzzle_orb(parent: Node, color: Color, half_width: float) -> void:
	var holder := Node2D.new()
	holder.name = "Muzzle"
	# 内芯半径（像素）约等于光束核心半径；下限 5 保证光束较细时枪口光球依然清晰可辨
	var core_r := maxf(half_width * 0.7, 5.0)
	var glow_r := core_r * 2.6
	# ProjectileVisual.circle_texture(size):size px 贴图、圆心在中央,scale=半径/半贴图宽。
	var glow := Sprite2D.new()
	glow.texture = ProjectileVisual.circle_texture(32)
	glow.modulate = Color(color.r, color.g, color.b, 0.30 * color.a)
	glow.scale = Vector2.ONE * (glow_r / 16.0)
	var core := Sprite2D.new()
	core.texture = ProjectileVisual.circle_texture(16)
	core.modulate = Color(1.0, 1.0, 1.0, 0.95)
	core.scale = Vector2.ONE * (core_r / 8.0)
	holder.add_child(glow)
	holder.add_child(core)
	parent.add_child(holder)
