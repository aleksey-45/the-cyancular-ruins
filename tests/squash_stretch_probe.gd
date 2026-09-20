extends Node
# SquashStretch 真渲染探针。判据:SQUASH PROBE: ALL-OK
# 跑法:"$GODOT" --path . --quit-after 3600 res://tests/squash_stretch_probe.tscn
#      ★ 不要加 --headless —— 本探针要取图,headless 下截图链给 null。
#
# 两个目的:
#   ① 断言形变真的发生了、且**没有**影响碰撞箱与世界位置(Global Constraints 的硬约束)
#   ② 存一张图给**人眼**验收观感 —— 图要自己读,别推回给用户(历史上这一步抓到过两个
#      数值全绿的 bug)
#
# ★ 与 brief 骨架的两处偏差(都是为了让 ② 真的成立,断言条目与判据文本与 brief 逐字一致):
#   ① 骨架给精灵一个**零帧空 SpriteFrames** ⇒ 渲染不出任何像素,取出来的图是一片纯背景色,
#      "人眼验收方向"就成了一句空话。这里改为从 player.tscn 抄真 SpriteFrames 并冻在 idle
#      第 0 帧(与 PlayerReplica._ready 抄同一份素材同款)。
#   ② 骨架只有一只精灵、画面里没有参照物 ⇒ 静态图上无从判断"哪个方向"。这里摆成
#      **中性 | 拉伸 | 挤压** 三栏,三栏共用同一张贴图与同一个 2.5 倍世界缩放
#      (与 player.tscn / player_replica.tscn 根节点同值),方向一眼可判,顺带能看到
#      2.5× 最近邻放大有没有糊边。
#
# ★ 每栏的结构照抄 player.tscn 的**骨架关系**(而不是简化成一只裸精灵):
#      actor(Node2D, scale=2.5) ├─ AnimatedSprite2D(形变写在这里)
#                               └─ CollisionPolygon2D(与 animator 并列,形变不得碰它)
#   只有这个形状才能真的验到 §5.1 那条"形变不碰碰撞箱":精灵 `centered=true`、局部原点就是
#   actor 原点 ⇒ 连根节点一起缩放时 `spr.global_position` **同样不变**,只看位置抓不到那类错。

const SHOT_PATH := "user://squash_stretch_probe.png"
const DT := 1.0 / 60.0
const WORLD_SCALE := 2.5          # 与 player.tscn / player_replica.tscn 的根节点同值
const COL_DX := 500.0             # 三栏在**屏幕**上的横向间距(px)
# 姿态多边形的探针形状:不求与玩家一致,求的是"AABB 非零、且与 animator 并列"。
# 世界尺寸 = 20×2.5 × 48×2.5 = 50×120。
# ★ 必须是 `var` 不是 `const`:`PackedVector2Array([...])` 不是 GDScript 的常量表达式,
#   写成 const 会**解析期报错** —— 而场景探针的脚本解析失败时场景根没有脚本、
#   一行都不打印也不退出("看着像功能坏了"的那个形态,见 CLAUDE.md 的 `--quit-after` 说明)。
var _probe_poly := PackedVector2Array([
	Vector2(-10.0, -24.0), Vector2(10.0, -24.0), Vector2(10.0, 24.0), Vector2(-10.0, 24.0),
])

var _fail: int = 0
var _actors: Array[Node2D] = []   # 三栏的 actor,末位 = brief 的被测精灵那一栏
var _owned: Array[Node] = []      # 探针自建的节点,退出前 free(输出保持干净)


func _ok(cond: bool, msg: String) -> void:
	if cond:
		print("  ok   ", msg)
	else:
		_fail += 1
		print("  FAIL ", msg)


func _near(a: float, b: float, eps: float) -> bool:
	return absf(a - b) <= eps


# 一栏 = actor(Node2D, scale 2.5) + AnimatedSprite2D + CollisionPolygon2D(见文件头)。
func _make_column(x: float, frames: SpriteFrames) -> Array:
	var actor := Node2D.new()
	actor.scale = Vector2(WORLD_SCALE, WORLD_SCALE)
	actor.position = Vector2(x, 0.0)
	add_child(actor)
	_owned.append(actor)

	var spr := AnimatedSprite2D.new()
	# 项目默认是线性插值,而角色放大 2.5 倍显示 —— 必须显式 nearest,否则糊边。
	# (与 player.tscn / player_replica.tscn / 武器精灵同款约定)
	spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	spr.sprite_frames = frames
	spr.animation = "idle"
	spr.stop()                 # 冻在第 0 帧:三栏必须逐像素可比(否则各帧动画不同)
	spr.frame = 0
	actor.add_child(spr)

	var poly := CollisionPolygon2D.new()
	poly.polygon = _probe_poly
	actor.add_child(poly)

	return [actor, spr]


# 一栏在**渲染结果**里的"墨迹"包围盒(与背景色不同的像素的外接矩形)。
# 只扫本栏窗口(±COL_DX/2)与角色所在的纵向带,别吃到邻栏、也别扫全图找不快。
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
	if mx.x < mn.x:
		return Rect2i()
	return Rect2i(mn, mx - mn + Vector2i.ONE)


func _ready() -> void:
	var SS = load("res://scenes/effects/squash_stretch.gd")
	var PP = load("res://core/config/player_params.gd")
	if SS == null or PP == null:
		print("SQUASH PROBE: FAIL | 加载失败")
		get_tree().quit(1)
		return
	print("== SquashStretch 真渲染探针 ==")

	# 真 SpriteFrames:与 PlayerReplica._ready 同款手法(实例化 player.tscn 后抄它的素材)。
	var tmp := preload("res://scenes/player/player.tscn").instantiate()
	var frames: SpriteFrames = tmp.get_node("AnimatedSprite2D").sprite_frames
	tmp.free()

	var center: Vector2 = get_viewport().get_visible_rect().size * 0.5
	var col_a: Array = _make_column(center.x - COL_DX, frames)   # 左:中性参照(不挂组件)
	var col_b: Array = _make_column(center.x, frames)            # 中:拉伸参照(起跳冲击)
	var col_c: Array = _make_column(center.x + COL_DX, frames)   # 右:brief 的被测精灵(挤压)
	_actors = [col_a[0], col_b[0], col_c[0]]
	for a in _actors:
		(a as Node2D).position.y = center.y

	var spr_neutral: AnimatedSprite2D = col_a[1]
	var spr_stretch: AnimatedSprite2D = col_b[1]
	var spr: AnimatedSprite2D = col_c[1]

	# ── 前提断言(没有它们,下面每一条都可以在"什么都没搭起来"的世界里全绿)──
	_ok(spr.sprite_frames.get_frame_count("idle") >= 1
			and spr.sprite_frames.get_frame_texture("idle", 0) != null,
			"前提:精灵有真贴图(零帧空 SpriteFrames ⇒ 取图是一片背景,人眼验收无从谈起)")
	var wr0: Rect2 = CollisionAabb.world_rect(_actors[2])
	_ok(wr0.size.x > 0.0 and wr0.size.y > 0.0,
			"前提:被测那一栏的碰撞箱是真几何(AABB %s),否则'形变不碰碰撞箱'是空断言" % str(wr0))
	_ok(absf(spr.global_position.x - spr_neutral.global_position.x) > 100.0,
			"前提:三栏确实分开摆(间距 %.1f px)" % absf(spr.global_position.x - spr_neutral.global_position.x))

	var s = SS.new()
	add_child(s)
	_owned.append(s)
	s.setup(spr, SS.Profile.PLAYER)

	var s_stretch = SS.new()
	add_child(s_stretch)
	_owned.append(s_stretch)
	s_stretch.setup(spr_stretch, SS.Profile.PLAYER)

	var base_pos: Vector2 = spr.global_position

	# ① 静止
	for i in 10:
		s.tick(DT, 0.0, true, false)
	_ok(is_equal_approx(spr.scale.x, 1.0) and is_equal_approx(spr.scale.y, 1.0),
			"静止 → 单位缩放,实测 %s" % str(spr.scale))

	# ② 落地冲击真的改了 scale(挤压 = 宽矮:x>1, y<1)
	#    ★ 方向不是凭直觉写的,是从组件自己的代码路径推出来的:
	#      _apply() 是 `Vector2(1 - amount*v, 1 + amount*v)`,而落地项在 tick() 里是
	#      `_impulse -= land_gain * k`(负);vel_y=1200 时 k=clamp((1200-220)/680)=1 →
	#      _impulse = -1,当帧指数回归后的 v = -1·(1 - exp(-9/60)) = -0.86071
	#      ⇒ scale = (1 + 0.10·0.86071, 1 - 0.10·0.86071) = (1.086071, 0.913929)。
	s.tick(DT, 1200.0, true, false)
	_ok(spr.scale.x > 1.0 and spr.scale.y < 1.0, "落地 → 挤压,实测 %s" % str(spr.scale))
	# ②b 幅度:必须压到满幅的一半以上(1.05),且方向不能是"擦边"过线。
	#     实测 1.086071,余量 +0.0361。与 tests/squash_host_water_probe 的 DROP_MIN_SQUASH 同口径,
	#     是对着"公式被翻过来"那次事故设的:反向时这一帧 scale.x = 0.913929,离门槛 0.1361。
	var want: float = 1.0 + 0.5 * PP.squash_amount
	_ok(spr.scale.x >= want, "落地挤压幅度 >= 满幅的 50%%(需 >= %.4f,实测 %.6f,余量 %+.4f)" % [
			want, spr.scale.x, spr.scale.x - want])
	# ②c 两轴必须**反向**:x+y 恒等于 2(公式写成同向、或写成 1+amount·v 配 1-amount·v 之外的
	#     任何形状都会破这条)。它不判方向(方向由 ② 判),判的是"两轴反向"这个结构。
	_ok(_near(spr.scale.x + spr.scale.y, 2.0, 1e-5),
			"两轴反向变化(x+y == 2),实测 %.6f" % (spr.scale.x + spr.scale.y))

	# ③ ★ 硬约束:形变**不得**移动节点、不得改变全局变换的位置部分
	_ok(spr.global_position == base_pos,
			"形变不改位置(实测 %s,基线 %s)" % [str(spr.global_position), str(base_pos)])
	# ③b ★ 硬约束:与 animator **并列**的姿态多边形,世界 AABB 必须一动不动。
	#      只看 ③ 抓不到"有人把形变写到根节点"那类错 —— 见文件头。
	var wr1: Rect2 = CollisionAabb.world_rect(_actors[2])
	_ok(wr1.position.is_equal_approx(wr0.position) and wr1.size.is_equal_approx(wr0.size),
			"形变不碰碰撞箱(前 %s → 后 %s)" % [str(wr0), str(wr1)])

	# ── 参照栏:中性(不挂组件)与拉伸(起跳冲击)──
	# 拉伸项:impulse(JUMP) = +squash_jump(0.75);同一帧 tick 后 v = 0.75·exp(-9/60) = 0.645536
	# ⇒ scale = (1 - 0.0645536, 1 + 0.0645536) = (0.9354464, 1.0645536)。
	s_stretch.impulse(SS.Impulse.JUMP)
	s_stretch.tick(DT, 0.0, true, false)
	print("  三联实测: 中性 %s | 拉伸 %s | 挤压 %s" % [
			str(spr_neutral.scale), str(spr_stretch.scale), str(spr.scale)])
	_ok(spr_stretch.scale.x < spr_neutral.scale.x and spr_stretch.scale.y > spr_neutral.scale.y,
			"参照栏方向自洽(拉伸栏比中性栏更窄更高)")

	# ③d ★ 硬约束:形变**只**写 `animator.scale` —— 精灵的 `offset` 必须仍是零。
	#     这条堵的是"脚底锚定"那条诱惑改法:缩放绕**中心**(`AnimatedSprite2D` 没有 pivot,
	#     `player.tscn` 只设了 `texture_filter`,故 `centered = true` 生效),所以挤压时画出来的
	#     底边会上抬 ~4~5px、拉伸时下沉 ~3.5px。用 `offset` 反向补正能让脚底钉住 —— 但那既破了
	#     "只写 `animator.scale`"的约束,又**没有任何别的探针看得见**(偏移是精灵内部量:
	#     `global_position` ③ 与碰撞箱 ③b 都不动)。CLAUDE.md 有这条登记(判为真现象非缺陷)。
	#     三栏一起判:参照栏也走同一条 `_apply()`,漏一栏就等于给它留了后门。
	_ok(spr_neutral.offset == Vector2.ZERO and spr_stretch.offset == Vector2.ZERO
			and spr.offset == Vector2.ZERO,
			"形变不写 offset(三栏实测 %s / %s / %s)" % [
				str(spr_neutral.offset), str(spr_stretch.offset), str(spr.offset)])

	# ④ 等两帧后取图(让人眼看到挤压那一刻;两帧是 kh_l3_visual_probe 的先例)
	await get_tree().process_frame
	await get_tree().process_frame

	var img: Image = get_viewport().get_texture().get_image()
	if img == null:
		_ok(false, "截图失败 —— 是不是误加了 --headless?(真渲染是本探针的前提)")
	else:
		img.save_png(SHOT_PATH)
		print("  取图 → ", ProjectSettings.globalize_path(SHOT_PATH), "(%dx%d)" % [
				img.get_width(), img.get_height()])
		_ok(true, "截图非空")

		# ④b 像素级方向断言:形变必须真的落到**渲染出来的像素**上(而不是只改了属性)。
		#     每栏取"与背景色不同"的像素包围盒 —— 这是"人眼读图"那一步的自动化版本,
		#     也是本探针唯一能抓到"最终变换没生效 / 方向反了"的判据。
		#     方向由组件代码路径推得(见 ② 的推导):
		#       拉伸栏 scale = (0.9354, 1.0646) ⇒ 更窄(x 变小)更高(y 变大)
		#       挤压栏 scale = (1.0861, 0.9139) ⇒ 更宽(x 变大)更矮(y 变小)
		#     ⇒ 高度必须 拉伸 > 中性 > 挤压,宽度必须 挤压 > 中性 > 拉伸。
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
		_ok(hn > 0 and hs > 0 and wq > 0, "前提:三栏都真的画出了像素(否则本组断言是空转)")
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
