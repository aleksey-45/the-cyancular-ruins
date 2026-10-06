class_name TimeGlow
extends Node2D

# 时间状态角色高亮特效：在实体视觉节点下叠加层混合模式为 Additive（叠加）的贴图副本。
#
# 实现原理：
#   1. 在 2D 非 HDR 渲染管线下，直接将 modulate 设置大于 1.0 会被截断至 1.0，无法产生明显的提亮效果；
#   2. 敌人基类在受击闪白与死亡闪白时，每帧会将 modulate 覆盖为白色，导致外部设置的色彩会被立即覆盖；
#   3. 使用叠加混合模式（BLEND_MODE_ADD）的子节点贴图副本，独立于 modulate，且色相可精确控制（如精英实体的亮黄高光）。
#
# 节点挂载结构：作为视觉节点（AnimatedSprite2D 或 Sprite2D）的子节点挂载，自动继承父节点的位置、旋转、
# 缩放（包含拉伸挤压）与可见性，每帧仅需同步当前帧、翻转状态与偏移；passes 支持设置多层叠加（精英实体使用 2 层强化亮度）。

static var total_created := 0   # 累计创建次数（测试用：用于检测频繁创建与释放抖动）

var color := Color.WHITE
var src: Node2D = null

var _anim: AnimatedSprite2D = null
var _spr: Sprite2D = null
var _ov_anim: Array[AnimatedSprite2D] = []
var _ov_spr: Array[Sprite2D] = []


## 为目标实体挂载时间高亮效果（要求目标包含有效的视觉节点，未找到则返回 null）。
static func attach(target: Node2D, c: Color, passes: int = 1) -> TimeGlow:
	var vis := find_visual(target)
	if vis == null:
		return null
	var g := TimeGlow.new()
	g.name = "TimeGlow"
	g.color = c
	g.src = vis
	g._anim = vis as AnimatedSprite2D
	if g._anim == null:
		g._spr = vis as Sprite2D
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	for i in maxi(passes, 1):
		if g._anim != null:
			var oa := AnimatedSprite2D.new()
			oa.sprite_frames = g._anim.sprite_frames
			oa.centered = g._anim.centered
			oa.material = mat
			oa.modulate = c
			g.add_child(oa)
			g._ov_anim.append(oa)
		elif g._spr != null:
			var os := Sprite2D.new()
			os.material = mat
			os.modulate = c
			g.add_child(os)
			g._ov_spr.append(os)
	if g._ov_anim.is_empty() and g._ov_spr.is_empty():
		g.free()
		return null
	vis.add_child(g)
	g._sync()
	total_created += 1
	return g


## 查找目标节点上的主要视觉精灵节点（优先获取 AnimatedSprite2D，其次递归查找 Sprite2D）。
static func find_visual(target: Node) -> Node2D:
	if target == null:
		return null
	var named := target.get_node_or_null("AnimatedSprite2D") as AnimatedSprite2D
	if named != null:
		return named
	var stack: Array[Node] = [target]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			if c is AnimatedSprite2D:
				return c as Node2D
			if c is Sprite2D:
				return c as Node2D
			stack.append(c)
	return null


## 获取目标身上已挂载的 TimeGlow 实例（若未挂载则返回 null）。
static func on(target: Node) -> TimeGlow:
	var vis := find_visual(target)
	if vis == null:
		return null
	for c in vis.get_children():
		if c is TimeGlow:
			return c
	return null


func set_color(c: Color) -> void:
	color = c
	_sync()


func passes() -> int:
	return maxi(_ov_anim.size() + _ov_spr.size(), 0)


func _process(_delta: float) -> void:
	if not is_instance_valid(src):
		queue_free()
		return
	_sync()


func _sync() -> void:
	if _anim != null and is_instance_valid(_anim):
		for o in _ov_anim:
			o.sprite_frames = _anim.sprite_frames
			o.animation = _anim.animation
			o.frame = _anim.frame
			o.position = Vector2.ZERO
			o.scale = Vector2.ONE        # 自动继承父节点的缩放与形变
			o.offset = _anim.offset
			o.centered = _anim.centered
			o.flip_h = _anim.flip_h
			o.flip_v = _anim.flip_v
			o.modulate = color
	elif _spr != null and is_instance_valid(_spr):
		for o in _ov_spr:
			o.texture = _spr.texture
			o.position = Vector2.ZERO
			o.scale = Vector2.ONE
			o.offset = _spr.offset
			o.centered = _spr.centered
			o.flip_h = _spr.flip_h
			o.flip_v = _spr.flip_v
			o.region_enabled = _spr.region_enabled
			o.region_rect = _spr.region_rect
			o.modulate = color
