class_name TimeGlow
extends Node2D

# 时间状态高亮(B13):在实体身上叠一层**加色混合**的贴图副本。
#
# ★ 为什么不用 modulate>1(B9/B12 的第一版做法 —— 用户实测"完全看不出高亮,只看到一切被调暗"):
#   ① 2D 非 HDR 管线里 modulate 在写帧缓冲时被夹到 1.0,1.65 提不亮多少;
#   ② 更要命的是**敌人基类的受击/死亡白闪 `_flash_update()` 每帧都把 modulate 写回
#      WHITE / 3.0** —— 外部写进去的高亮当帧就被覆盖,敌人那边等于完全没生效。
#   加色副本不依赖 HDR、不与白闪抢 modulate,而且色相可控(精英的黄能真"亮眼")。
#
# 挂法:副本挂成**视觉节点(AnimatedSprite2D/Sprite2D)的子节点** —— 父的 position/rotation/
# scale(挤压拉伸)/可见性全部自动继承,只需同步 offset/flip/当前帧。`passes=2` 叠两层
# (精英用"极为亮眼"的黄)。

static var total_created := 0   # 累计创建数(探针用:检测"每帧 free+attach"的抖动)

var color := Color.WHITE
var src: Node2D = null

var _anim: AnimatedSprite2D = null
var _spr: Sprite2D = null
var _ov_anim: Array[AnimatedSprite2D] = []
var _ov_spr: Array[Sprite2D] = []


## 给 target 挂上高亮(已有视觉节点才挂得上;找不到返回 null,调用方当"这帧没高亮"处理)。
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


## 找 target 身上的视觉节点(敌人/玩家的 .tscn 里都叫 AnimatedSprite2D;找不到再递归找 Sprite2D)。
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


## 探针用:取 target 身上已挂的高亮(没有则 null)。
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
			o.scale = Vector2.ONE        # 父的 scale(挤压/镜像)已经继承下来了
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
