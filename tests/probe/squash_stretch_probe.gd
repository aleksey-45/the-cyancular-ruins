extends Node

const SHOT_PATH := "user://squash_stretch_probe.png"
const DT := 1.0 / 60.0
const WORLD_SCALE := 2.5          # 角色缩放比例
const COL_DX := 500.0             # 三栏在屏幕上的横向间距(像素)

# 姿态多边形测试数据：AABB 尺寸 50×120
var _probe_poly := PackedVector2Array([
	Vector2(-10.0, -24.0), Vector2(10.0, -24.0), Vector2(10.0, 24.0), Vector2(-10.0, 24.0),
])

var _fail: int = 0
var _actors: Array[Node2D] = []   # 三栏展示角色节点
var _owned: Array[Node] = []      # 测试自建节点列表，用于结束时释放


func _ok(cond: bool, msg: String) -> void:
	if cond:
		print("  ok   ", msg)
	else:
		_fail += 1
		print("  FAIL ", msg)


func _near(a: float, b: float, eps: float) -> bool:
	return absf(a - b) <= eps


# 构建单栏测试角色：包含缩放 Node2D、AnimatedSprite2D 与 CollisionPolygon2D
func _make_column(x: float, frames: SpriteFrames) -> Array:
	var actor := Node2D.new()
	actor.scale = Vector2(WORLD_SCALE, WORLD_SCALE)
	actor.position = Vector2(x, 0.0)
	add_child(actor)
	_owned.append(actor)

	var spr := AnimatedSprite2D.new()
	spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	spr.sprite_frames = frames
	spr.animation = "idle"
	spr.stop()                 # 冻结在第 0 帧以保证像素对齐可比性
	spr.frame = 0
	actor.add_child(spr)

	var poly := CollisionPolygon2D.new()
	poly.polygon = _probe_poly
	actor.add_child(poly)

	return [actor, spr]


# 获取渲染像素包围盒（非背景色的最小外接矩形）
func _ink_box(img: Image, bg: Color, cx: int) -> Rect2i:
	var x0: int = maxi(cx - int(COL_DX * 0.5) + 20, 0)
	var x1: int = mini(cx + int(COL_DX * 0.5) - 20, img.get_width() - 1)
	var y0: int = maxi(int(_actors[2].global_position.y) - 200, 0)
	var y1: int = mini(int(_actors[2].global_position.y) + 200, img.get_height() - 1)
	var mn := Vector2i(img.get_width(), img.get_height())
	var mx := Vector2i(-1, -1)
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			var c := img.get_pixel(x, y)
			if absf(c.r - bg.r) + absf(c.g - bg.g) + absf(c.b - bg.b) > 0.06:
				mn.x = mini(mn.x, x)
				mn.y = mini(mn.y, y)
				mx.x = maxi(mx.x, x)
				mx.y = maxi(mx.y, y)
	if mx.x < mn.x or mx.y < mn.y:
		return Rect2i()
	return Rect2i(mn.x, mn.y, mx.x - mn.x + 1, mx.y - mn.y + 1)


func _ready() -> void:
	await _run()


func _run() -> void:
	var PP = load("res://core/config/player_params.gd")
	var SS = load("res://scenes/effects/squash_stretch.gd")
	var actor := load("res://scenes/player/player.tscn").instantiate() as Node2D
	var frames: SpriteFrames = actor.get_node("Visuals/AnimatedSprite2D").sprite_frames
	actor.free()

	var vp_size := get_viewport().get_visible_rect().size
	var center := vp_size * 0.5

	# 创建三栏对照：中性(左)、拉伸(中)、挤压(右)
	var c_neutral := _make_column(center.x - COL_DX, frames)
	var c_stretch := _make_column(center.x, frames)
	var c_squash := _make_column(center.x + COL_DX, frames)
	_actors = [c_neutral[0], c_stretch[0], c_squash[0]]

	for a in _actors:
		a.position.y = center.y

	var spr_neutral: AnimatedSprite2D = c_neutral[1]
	var spr_stretch: AnimatedSprite2D = c_stretch[1]
	var spr: AnimatedSprite2D = c_squash[1]

	var s_stretch = SS.new()
	s_stretch.setup(spr_stretch, SS.Profile.PLAYER)
	_owned.append(s_stretch)
	var s = SS.new()
	s.setup(spr, SS.Profile.PLAYER)
	_owned.append(s)

	var base_pos := spr.global_position
	var wr0: Rect2 = CollisionAabb.world_rect(_actors[2])

	# 阶段 1：静止状态下缩放保持为 (1.0, 1.0)
	for i in 60:
		s.tick(DT, 0.0, true, false)
	_ok(is_equal_approx(spr.scale.x, 1.0) and is_equal_approx(spr.scale.y, 1.0),
			"静止 → 单位缩放,实测 %s" % str(spr.scale))

	# 阶段 2：落地冲击触发水平挤压(宽矮形变: x > 1.0, y < 1.0)
	s.tick(DT, 1200.0, true, false)
	_ok(spr.scale.x > 1.0 and spr.scale.y < 1.0, "落地 → 挤压,实测 %s" % str(spr.scale))

	var want: float = 1.0 + 0.5 * PP.squash_amount
	_ok(spr.scale.x >= want, "落地挤压幅度 >= 满幅的 50%%(需 >= %.4f,实测 %.6f,余量 %+.4f)" % [
			want, spr.scale.x, spr.scale.x - want])
	_ok(_near(spr.scale.x + spr.scale.y, 2.0, 1e-5),
			"两轴反向变化(x+y == 2),实测 %.6f" % (spr.scale.x + spr.scale.y))

	# 阶段 3：形变仅修改精灵缩放，不改变全局坐标与碰撞体 AABB
	_ok(spr.global_position == base_pos,
			"形变不改位置(实测 %s,基线 %s)" % [str(spr.global_position), str(base_pos)])
	var wr1: Rect2 = CollisionAabb.world_rect(_actors[2])
	_ok(wr1.position.is_equal_approx(wr0.position) and wr1.size.is_equal_approx(wr0.size),
			"形变不碰碰撞箱(前 %s → 后 %s)" % [str(wr0), str(wr1)])

	# 参照栏测试：起跳拉伸形变
	s_stretch.impulse(SS.Impulse.JUMP)
	s_stretch.tick(DT, 0.0, true, false)
	print("  三联实测: 中性 %s | 拉伸 %s | 挤压 %s" % [
			str(spr_neutral.scale), str(spr_stretch.scale), str(spr.scale)])
	_ok(spr_stretch.scale.x < spr_neutral.scale.x and spr_stretch.scale.y > spr_neutral.scale.y,
			"参照栏方向自洽(拉伸栏比中性栏更窄更高)")

	# 形变仅作用于 animator.scale，精灵 offset 保持为零
	_ok(spr_neutral.offset == Vector2.ZERO and spr_stretch.offset == Vector2.ZERO
			and spr.offset == Vector2.ZERO,
			"形变不写 offset(三栏实测 %s / %s / %s)" % [
				str(spr_neutral.offset), str(spr_stretch.offset), str(spr.offset)])

	# 等待两帧进行画面捕获
	await get_tree().process_frame
	await get_tree().process_frame

	var img: Image = get_viewport().get_texture().get_image()
	if img == null:
		_ok(false, "截图失败(无头渲染环境下视口未激活)")
	else:
		img.save_png(SHOT_PATH)
		print("  取图 → ", ProjectSettings.globalize_path(SHOT_PATH), "(%dx%d)" % [
				img.get_width(), img.get_height()])
		_ok(true, "截图非空")

		# 验证像素包围盒几何尺寸关系：高度满足 拉伸 > 中性 > 挤压，宽度满足 挤压 > 中性 > 拉伸
		var bg := img.get_pixel(0, 0)
		var boxes: Array[Rect2i] = []
		for i in 3:
			boxes.append(_ink_box(img, bg, int(center.x + float(i - 1) * COL_DX)))
		var hn: int = boxes[0].size.y
		var hs: int = boxes[1].size.y
		var hq: int = boxes[2].size.y
		var wn: int = boxes[0].size.x
		var ws: int = boxes[1].size.x
		var wq: int = boxes[2].size.x
		print("  像素包围盒: 中性 %s | 拉伸 %s | 挤压 %s" % [str(boxes[0]), str(boxes[1]), str(boxes[2])])
		_ok(hn > 0 and hs > 0 and wq > 0, "前提: 三栏均正常绘制像素")
		_ok(hs > hn + 2 and hn > hq + 2,
				"渲染高度: 拉伸 %d > 中性 %d > 挤压 %d(每档至少差 2px)" % [hs, hn, hq])
		_ok(wq > wn + 2 and wn > ws + 2,
				"渲染宽度: 挤压 %d > 中性 %d > 拉伸 %d(每档至少差 2px)" % [wq, wn, ws])

	for n in _owned:
		if is_instance_valid(n):
			n.free()
	_owned.clear()

	if _fail == 0:
		print("SQUASH PROBE: ALL-OK")
	else:
		print("SQUASH PROBE: FAIL | %d 条" % _fail)
	get_tree().quit(1 if _fail > 0 else 0)
