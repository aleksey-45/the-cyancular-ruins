extends SceneTree

# SpriteBounds 冒烟:按 sprite 像素 alpha 求包围盒(地面武器碰撞箱的来源)。
# 跑法: "$GODOT" --headless --path . -s res://tests/sprite_bounds_smoke.gd
# 通过 = `SPRITE_BOUNDS OK` 退出 0。
#
# ★ 用运行时生成的贴图当输入,不依赖任何美术资产 —— 断言的是"算得对不对",
#   而不是"某张图长什么样"(后者一改素材就红)。
# ★ 参考系是坑点:Sprite2D 默认 centered,局部原点是**贴图/region 的中心**,
#   不是左上角。三组用例分别压"无 region / 全透明 / 有 region"。

var _fail := 0


func _check(ok: bool, msg: String) -> void:
	if ok:
		return
	_fail += 1
	print("[FAIL] ", msg)


func _make_tex(w: int, h: int, filled: Rect2i) -> ImageTexture:
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(1, 1, 1, 0))
	for y in range(filled.position.y, filled.position.y + filled.size.y):
		for x in range(filled.position.x, filled.position.x + filled.size.x):
			img.set_pixel(x, y, Color(1, 1, 1, 1))
	return ImageTexture.create_from_image(img)


func _initialize() -> void:
	var SB: GDScript = load("res://core/present/sprite_bounds.gd")
	# ★ 空载守卫:load() 失败还往下走会在 null 上抛错,而 -s 抛错走不到 quit() → 永久挂起
	if SB == null:
		print("SPRITE_BOUNDS FAILED: 找不到 core/present/sprite_bounds.gd")
		quit(1)
		return

	# ── 无 region:包围盒贴合实心区,原点在贴图中心 ──
	var spr := Sprite2D.new()
	spr.texture = _make_tex(32, 16, Rect2i(4, 2, 20, 10))
	var r: Rect2 = SB.from_sprite(spr)
	# 贴图中心 (16,8);实心区 x∈[4,23] y∈[2,11] → 局部 x∈[-12,7] y∈[-6,3]
	_check(is_equal_approx(r.position.x, -12.0) and is_equal_approx(r.position.y, -6.0),
		"包围盒左上角应为 (-12,-6),实际 %s" % str(r.position))
	_check(is_equal_approx(r.size.x, 20.0) and is_equal_approx(r.size.y, 10.0),
		"包围盒尺寸应为 (20,10),实际 %s" % str(r.size))
	spr.free()

	# ── 全透明贴图:返回空矩形,不返回"整张贴图" ──
	var spr2 := Sprite2D.new()
	spr2.texture = _make_tex(16, 16, Rect2i(0, 0, 0, 0))
	var r2: Rect2 = SB.from_sprite(spr2)
	_check(r2.size == Vector2.ZERO, "全透明贴图应返回空矩形,实际 %s" % str(r2.size))
	spr2.free()

	# ── region_enabled:只扫 region 内,坐标系以 region 中心为原点 ──
	var spr3 := Sprite2D.new()
	spr3.texture = _make_tex(64, 16, Rect2i(40, 2, 20, 10))
	spr3.region_enabled = true
	spr3.region_rect = Rect2(32, 0, 32, 16)
	var r3: Rect2 = SB.from_sprite(spr3)
	# region 中心 (16,8);实心区在 region 内的偏移 x∈[8,27] y∈[2,11] → 局部 x∈[-8,11] y∈[-6,3]
	_check(is_equal_approx(r3.position.x, -8.0) and is_equal_approx(r3.position.y, -6.0),
		"region 包围盒左上角应为 (-8,-6),实际 %s" % str(r3.position))
	_check(is_equal_approx(r3.size.x, 20.0) and is_equal_approx(r3.size.y, 10.0),
		"region 包围盒尺寸应为 (20,10),实际 %s" % str(r3.size))
	spr3.free()

	# ── region 只覆盖贴图的一部分:必须**不**把 region 外的实心像素算进来 ──
	# 贴图左侧 0..15 全实心,region 只取右半 (32,0,32,16) 里的实心块 —— 若实现漏了
	# region 裁剪、扫了整张贴图,包围盒会向左溢出到 -32 附近。
	var spr4 := Sprite2D.new()
	var img4 := Image.create(64, 16, false, Image.FORMAT_RGBA8)
	img4.fill(Color(1, 1, 1, 1))   # 整张全实心
	spr4.texture = ImageTexture.create_from_image(img4)
	spr4.region_enabled = true
	spr4.region_rect = Rect2(32, 0, 32, 16)
	var r4: Rect2 = SB.from_sprite(spr4)
	_check(is_equal_approx(r4.size.x, 32.0) and is_equal_approx(r4.size.y, 16.0),
		"region 内全实心应得 32x16,实际 %s(=64 宽说明没裁 region)" % str(r4.size))
	spr4.free()

	# ── 无贴图:返回空矩形,不崩 ──
	var spr5 := Sprite2D.new()
	var r5: Rect2 = SB.from_sprite(spr5)
	_check(r5.size == Vector2.ZERO, "无贴图应返回空矩形")
	spr5.free()

	if _fail == 0:
		print("SPRITE_BOUNDS OK")
		quit(0)
	else:
		print("SPRITE_BOUNDS FAILED: %d" % _fail)
		quit(1)
