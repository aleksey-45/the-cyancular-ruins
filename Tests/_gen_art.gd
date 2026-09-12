extends SceneTree

# 生成 4 张专属像素画贴图(零外部素材,项目程序化范式)。
# 风格约定(与 weapons.png 同调):1px 深描边 + 2 阶明暗 + 单强调色;最近邻,无抗锯齿。

const OUTLINE := Color(0.08, 0.09, 0.12)
const STEEL_D := Color(0.23, 0.26, 0.30)
const STEEL_M := Color(0.35, 0.39, 0.45)
const STEEL_L := Color(0.52, 0.57, 0.64)
const BRASS := Color(0.72, 0.55, 0.25)


func _initialize() -> void:
	_minigun("res://assets/textures/minigun.png")
	_canister("res://assets/textures/prop_knockback.png",
			Color(0.85, 0.42, 0.17), Color(0.62, 0.30, 0.11), "push")
	_canister("res://assets/textures/prop_attraction.png",
			Color(0.20, 0.66, 0.85), Color(0.13, 0.46, 0.60), "pull")
	_canister("res://assets/textures/prop_smoke.png",
			Color(0.48, 0.52, 0.47), Color(0.34, 0.38, 0.34), "smoke")
	print("ART GEN: OK")
	quit(0)


func _img(w: int, h: int) -> Image:
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	return img


func _px(img: Image, x: int, y: int, c: Color) -> void:
	if x >= 0 and y >= 0 and x < img.get_width() and y < img.get_height():
		img.set_pixel(x, y, c)


func _rect(img: Image, x0: int, y0: int, x1: int, y1: int, c: Color) -> void:
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			_px(img, x, y, c)


func _outline_rect(img: Image, x0: int, y0: int, x1: int, y1: int, fill: Color, edge: Color) -> void:
	_rect(img, x0, y0, x1, y1, fill)
	for x in range(x0, x1 + 1):
		_px(img, x, y0, edge)
		_px(img, x, y1, edge)
	for y in range(y0, y1 + 1):
		_px(img, x0, y, edge)
		_px(img, x1, y, edge)


## 加特林(朝右,64×26):六管旋转枪管组 + 方形机匣 + 弹链 + 握把
func _minigun(path: String) -> void:
	var img := _img(64, 26)
	# 六管枪管组(x2..32,y4..16,每管 2px 高,管间 1px 缝)
	for b in 6:
		var y := 4 + b * 3
		_outline_rect(img, 2, y, 32, y + 1, STEEL_M, OUTLINE)
		_px(img, 30, y, STEEL_L)      # 管口高光
		_px(img, 30, y + 1, STEEL_L)
	# 枪管箍(两道黄铜)
	_outline_rect(img, 8, 3, 10, 17, BRASS, OUTLINE)
	_outline_rect(img, 22, 3, 24, 17, BRASS, OUTLINE)
	# 机匣(x32..50,y3..14)
	_outline_rect(img, 32, 3, 50, 14, STEEL_D, OUTLINE)
	_rect(img, 33, 4, 49, 6, STEEL_M)          # 顶部受弹机
	_rect(img, 33, 12, 49, 13, STEEL_M)
	_px(img, 46, 8, Color(0.85, 0.30, 0.25))   # 机匣红点
	_px(img, 47, 8, Color(0.85, 0.30, 0.25))
	# 握把(x42..46,y15..21)
	_outline_rect(img, 42, 15, 45, 21, STEEL_D, OUTLINE)
	# 弹链(右侧垂下,x50..60,y5..18,黄铜链节)
	for yy in range(6, 19, 3):
		_outline_rect(img, 50, yy, 60, yy + 1, BRASS, OUTLINE)
	# 尾托
	_outline_rect(img, 50, 3, 60, 5, STEEL_M, OUTLINE)
	img.save_png(path)


## 道具罐体(18×24):圆柱罐 + 顶盖引信;mark = push/pull/smoke 三种标识
func _canister(path: String, body: Color, body_d: Color, mark: String) -> void:
	var img := _img(18, 24)
	# 罐体(x3..14,y5..21):左亮右暗圆柱感
	_outline_rect(img, 3, 5, 14, 21, body, OUTLINE)
	for y in range(6, 21):
		_px(img, 4, y, body.lightened(0.18))   # 左侧高光柱
		_px(img, 13, y, body_d)                # 右侧暗部
	# 顶盖(x2..15,y2..5)
	_outline_rect(img, 2, 2, 15, 5, STEEL_M, OUTLINE)
	_rect(img, 3, 3, 14, 4, STEEL_L)
	# 引信钮(x7..10,y0..2)
	_outline_rect(img, 7, 0, 10, 2, BRASS, OUTLINE)
	# 标识(白)
	var w := Color(0.95, 0.95, 0.92)
	match mark:
		"push":
			# 向外双箭头「> <」倒置 → 左右扩张线
			for i in range(4):
				_px(img, 6 + i, 11 - i, w)
				_px(img, 6 + i, 12 + i, w)
				_px(img, 11 - i, 11 - i, w)
				_px(img, 11 - i, 12 + i, w)
		"pull":
			# 向内双箭头
			for i in range(4):
				_px(img, 5 + i, 9 + i, w)
				_px(img, 5 + i, 14 - i, w)
				_px(img, 12 - i, 9 + i, w)
				_px(img, 12 - i, 14 - i, w)
		"smoke":
			# 三道横向散烟孔
			_rect(img, 6, 9, 12, 10, w)
			_rect(img, 6, 13, 12, 14, w)
			_rect(img, 6, 17, 12, 18, w)
	img.save_png(path)
