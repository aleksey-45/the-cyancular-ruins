class_name SpriteNormalMap
extends RefCounted
# 从精灵的 alpha 剪影烘法线图(与主图集同布局):距离场越深入剪影越"朝向观察者"。
# ★ 烘焙而不是逐帧算:shader 里每像素估距离场要 30+ 次采样,烘一次运行时只有 1 次纹理采样。
# ★ 编码:法线 (n*0.5+0.5) 存 RGB;z 恒为正,背光面靠 NdotL 变暗,不需要双面法线。

const MAX_D := 5             # 距离上限(像素):决定倒角多宽。★ 别大 —— 越大越像"被磨圆的一块肥皂"
const Z_SCALE := 1.3         # z 的放大系数
static var _cache: Dictionary = {}   # Texture2D -> ImageTexture


## 取(或烘)一张法线图。传 null 或空图返回 null,调用方跳过。
static func for_texture(tex: Texture2D) -> ImageTexture:
	if tex == null:
		return null
	if _cache.has(tex):
		return _cache[tex]
	var img := tex.get_image()
	if img == null or img.is_empty():
		return null
	img = img.duplicate()
	img.convert(Image.FORMAT_RGBA8)
	var nm := bake(img)
	_cache[tex] = nm
	return nm


## 核心:alpha → 距离场 → 法线。纯函数,便于单独核对。
static func bake(img: Image) -> ImageTexture:
	var w := img.get_width()
	var h := img.get_height()
	# ① 距离场:透明 = 0,不透明 = 到最近透明像素的近似欧氏距离(3×3 chamfer 两遍扫描)。
	var d := PackedFloat32Array()
	d.resize(w * h)
	const BIG := 1e9
	for y in h:
		for x in w:
			d[y * w + x] = 0.0 if img.get_pixel(x, y).a < 0.5 else BIG
	for y in h:
		for x in w:
			var i := y * w + x
			if d[i] == 0.0:
				continue
			var best := d[i]
			if x > 0:
				best = minf(best, d[i - 1] + 1.0)
			if y > 0:
				best = minf(best, d[i - w] + 1.0)
				if x > 0:
					best = minf(best, d[i - w - 1] + 1.4142136)
				if x < w - 1:
					best = minf(best, d[i - w + 1] + 1.4142136)
			d[i] = best
	for y in range(h - 1, -1, -1):
		for x in range(w - 1, -1, -1):
			var i := y * w + x
			if d[i] == 0.0:
				continue
			var best := d[i]
			if x < w - 1:
				best = minf(best, d[i + 1] + 1.0)
			if y < h - 1:
				best = minf(best, d[i + w] + 1.0)
				if x < w - 1:
					best = minf(best, d[i + w + 1] + 1.4142136)
				if x > 0:
					best = minf(best, d[i + w - 1] + 1.4142136)
			d[i] = best
	# ② 平滑距离场:chamfer 的梯度是**分段常数**(最近的那条边一变,方向就跳),
	#    直接求法线会得到"宝石切面" —— 精灵读成一堆棱面(用户实测:像圆锥/棱锥)。
	#    两遍 3×3 均值把折线摊平,法线才连续。
	for _pass in 2:
		d = _blur3(d, w, h)
	# ③ 法线:梯度(outward = 距离减小的方向),z 用圆弧剖面。
	var out := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in h:
		for x in w:
			var i := y * w + x
			if img.get_pixel(x, y).a < 0.5:
				out.set_pixel(x, y, Color(0.5, 0.5, 1.0, 1.0))   # 透明处给"正对观察者"
				continue
			var dl := d[i - 1] if x > 0 else d[i]
			var dr := d[i + 1] if x < w - 1 else d[i]
			var du := d[i - w] if y > 0 else d[i]
			var dd := d[i + w] if y < h - 1 else d[i]
			var gx := (dr - dl) * 0.5
			var gy := (dd - du) * 0.5
			# ★ z 必须用**圆弧剖面**,不能用线性:
			#   线性 (z ∝ d) 配"横向 ∝ 边缘方向"正好是一个**圆锥** —— 精灵会读成锥体(用户实测)。
			#   圆弧 z = sqrt(t(2−t))(t=0 边缘 → t=1 内部)在边缘上升得快、中心变平,
			#   这才是球/圆柱的剖面:只有贴着轮廓的一圈变暗,内部保持平。
			var t := clampf(d[i] / MAX_D, 0.0, 1.0)
			var z := sqrt(maxf(t * (2.0 - t), 0.0))
			# 朝外(远离内部)= -grad。
			var n := Vector3(-gx, -gy, z * Z_SCALE + 0.20)
			n = n.normalized()
			out.set_pixel(x, y, Color(n.x * 0.5 + 0.5, n.y * 0.5 + 0.5, n.z * 0.5 + 0.5, 1.0))
	return ImageTexture.create_from_image(out)
# 3×3 均值模糊(边界按边缘像素复制),用于把距离场的分段梯度摊平。
static func _blur3(src: PackedFloat32Array, w: int, h: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(w * h)
	for y in h:
		for x in w:
			var acc := 0.0
			for dy in range(-1, 2):
				var yy := clampi(y + dy, 0, h - 1)
				for dx in range(-1, 2):
					var xx := clampi(x + dx, 0, w - 1)
					acc += src[yy * w + xx]
			out[y * w + x] = acc / 9.0
	return out


## 按**剪影本身**拟合椭圆:中心 = 不透明像素质心,半径 = 实际半展(相对帧中心)。
## ★ 为什么不用包围盒:包围盒包含空边、被腿/手撑大,椭球中心和半径都会偏,
##   于是"鼓起"系数怎么调都不对(用户实测:越调越怪)。
## 返回 {center: Vector2, size: Vector2}。
static func ellipse_fit(atlas_img: Image, regions: Array) -> Dictionary:
	var sx := 0.0
	var sy := 0.0
	var n := 0
	var max_x := 8.0
	var max_y := 8.0
	for r in regions:
		var rect := Rect2i(r)
		var cx := float(rect.position.x) + float(rect.size.x) * 0.5
		var cy := float(rect.position.y) + float(rect.size.y) * 0.5
		for y in range(rect.position.y, mini(rect.position.y + rect.size.y, atlas_img.get_height())):
			for x in range(rect.position.x, mini(rect.position.x + rect.size.x, atlas_img.get_width())):
				if atlas_img.get_pixel(x, y).a <= 0.5:
					continue
				sx += float(x) - cx
				sy += float(y) - cy
				n += 1
	if n == 0:
		return {"center": Vector2.ZERO, "size": Vector2(24.0, 24.0)}
	var center := Vector2(sx / float(n), sy / float(n))
	for r in regions:
		var rect := Rect2i(r)
		var cx := float(rect.position.x) + float(rect.size.x) * 0.5
		var cy := float(rect.position.y) + float(rect.size.y) * 0.5
		for y in range(rect.position.y, mini(rect.position.y + rect.size.y, atlas_img.get_height())):
			for x in range(rect.position.x, mini(rect.position.x + rect.size.x, atlas_img.get_width())):
				if atlas_img.get_pixel(x, y).a <= 0.5:
					continue
				max_x = maxf(max_x, absf(float(x) - cx - center.x))
				max_y = maxf(max_y, absf(float(y) - cy - center.y))
	return {"center": center, "size": Vector2(max_x, max_y)}
