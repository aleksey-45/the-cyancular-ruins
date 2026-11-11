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

# ── 玩家分部光照:逐帧把剪影分成"身体/左右手/左右腿"5 块,烘成与图集同布局的坐标图
#    (RG = 该块内部的归一化坐标),供 form_light 的 parts 模型逐块算球面法线。
#    ★ 分割以"连通块"为单位:一整块剪影只能属于一个部位,避免最近邻在身体上切出 V 形缝。
#    ★ 手脚与身体粘连的帧(fly/charge)不切块,整身一个椭圆。
static var _parts_cache: Dictionary = {}

# 每块的法线"铺展":手/腿放大归一化尺寸 ⇒ 渐变更缓,不会各自变成一颗小球/一根管。
const _PART_SPREAD := [Vector2(1.15, 1.15), Vector2(1.7, 1.7), Vector2(1.7, 1.7), Vector2(1.25, 2.4), Vector2(1.25, 2.4)]

static func for_parts(regions: Array, atlas: Texture2D) -> ImageTexture:
	if atlas == null:
		return null
	var key := "%d|%s|%s" % [atlas.get_instance_id(), str(regions), str(_PART_SPREAD)]
	if _parts_cache.has(key):
		return _parts_cache[key]
	var img := atlas.get_image()
	if img == null or img.is_empty():
		return null
	if img.is_compressed():
		img.decompress()
	var baked := bake_parts(img, regions)
	_parts_cache[key] = baked
	return baked


static func bake_parts(img: Image, regions: Array) -> ImageTexture:
	var w := img.get_width()
	var h := img.get_height()
	var out := Image.create(w, h, false, Image.FORMAT_RGBA8)
	var prev: Array = []
	for r in regions:
		var rect := Rect2i(r).intersection(Rect2i(0, 0, w, h))
		if rect.size.x < 4 or rect.size.y < 4:
			continue
		var pts: Array[Vector2i] = []
		var comp_of := PackedInt32Array()
		comp_of.resize(rect.size.x * rect.size.y)
		for i in comp_of.size():
			comp_of[i] = -1
		for y in range(rect.position.y, rect.end.y):
			for x in range(rect.position.x, rect.end.x):
				if img.get_pixel(x, y).a > 0.5:
					pts.append(Vector2i(x, y))
		if pts.size() < 24:
			continue
		var comps := _components(img, rect)
		if comps.size() <= 2:
			_bake_single_body(out, pts)
			prev = []
			continue
		# 点 → 连通块编号
		var ci := 0
		for comp in comps:
			for p in comp:
				comp_of[(p.y - rect.position.y) * rect.size.x + (p.x - rect.position.x)] = ci
			ci += 1
		var labels := _label_components(comps, prev)
		var ids := PackedInt32Array()
		ids.resize(pts.size())
		for i in pts.size():
			var p := pts[i]
			var c := comp_of[(p.y - rect.position.y) * rect.size.x + (p.x - rect.position.x)]
			ids[i] = labels[c] if c >= 0 and labels[c] >= 0 else 0
		var acc: Array = [Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO, Vector2.ZERO]
		var cnt := PackedInt32Array([0, 0, 0, 0, 0])
		for i in pts.size():
			acc[ids[i]] += Vector2(pts[i])
			cnt[ids[i]] += 1
		var new_centers: Array = []
		for s in 5:
			if cnt[s] > 0:
				new_centers.append(acc[s] / float(cnt[s]))
			elif prev.size() == 5:
				new_centers.append(prev[s])
			else:
				new_centers.append(Vector2(rect.get_center()))
		var halves: Array = [Vector2(2.0, 2.0), Vector2(2.0, 2.0), Vector2(2.0, 2.0), Vector2(2.0, 2.0), Vector2(2.0, 2.0)]
		for i in pts.size():
			var p := Vector2(pts[i])
			var pid := ids[i]
			var c: Vector2 = new_centers[pid]
			halves[pid] = Vector2(maxf(halves[pid].x, absf(p.x - c.x)), maxf(halves[pid].y, absf(p.y - c.y)))
		for i in pts.size():
			var p := Vector2(pts[i])
			var pid := ids[i]
			var c: Vector2 = new_centers[pid]
			var spread: Vector2 = _PART_SPREAD[pid]
			var hv: Vector2 = halves[pid] * spread
			var q := Vector2((p.x - c.x) / maxf(hv.x, 2.0), (p.y - c.y) / maxf(hv.y, 2.0))
			out.set_pixel(p.x, p.y,
					Color(clampf(q.x, -1.0, 1.0) * 0.5 + 0.5, clampf(q.y, -1.0, 1.0) * 0.5 + 0.5, 1.0, 1.0))
		prev = new_centers
	return ImageTexture.create_from_image(out)


# 连通块 → 部位编号(0 身体,1/2 左手/右手,3/4 左腿/右腿)。最大块=身体;其余按上一帧中心或
# 位置(靠上=手,靠下=腿;左右按 x)归类。整块归一,所以不会把身体切出斜缝。
static func _label_components(comps: Array, prev: Array) -> Array:
	var order: Array = []
	for i in comps.size():
		order.append(i)
	order.sort_custom(func(a: int, b: int) -> bool: return comps[a].size() > comps[b].size())
	var labels: Array = []
	labels.resize(comps.size())
	for i in comps.size():
		labels[i] = -1
	labels[order[0]] = 0
	var rest: Array = []
	for i in range(1, order.size()):
		rest.append(order[i])
	if rest.size() > 4:
		rest = rest.slice(0, 4)
	if prev.size() == 5:
		for ci in rest:
			var cc := _centroid(comps[ci])
			var best := 1
			var bd := INF
			for s in range(1, 5):
				var d := cc.distance_squared_to(prev[s])
				if d < bd:
					bd = d
					best = s
			labels[ci] = best
	else:
		var body_c := _centroid(comps[order[0]])
		var items: Array = []
		for ci in rest:
			var cc := _centroid(comps[ci])
			items.append({"ci": ci, "c": cc})
		items.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return (a["c"] as Vector2).y < (b["c"] as Vector2).y)
		var n := items.size()
		for k in n:
			var side := 1 if (items[k]["c"] as Vector2).x < body_c.x else 2
			var part := side if k < mini(n, 2) else side + 2
			labels[items[k]["ci"]] = part
	return labels


# 合并帧(手脚与身体连成一片):整身当一个椭球,避免把身体切出 V 形明暗缝。
static func _bake_single_body(out: Image, pts: Array[Vector2i]) -> void:
	var c := _centroid(pts)
	var hv := Vector2(2.0, 2.0)
	for p in pts:
		hv = Vector2(maxf(hv.x, absf(float(p.x) - c.x)), maxf(hv.y, absf(float(p.y) - c.y)))
	hv *= _PART_SPREAD[0]
	for p in pts:
		var q := Vector2((float(p.x) - c.x) / maxf(hv.x, 2.0), (float(p.y) - c.y) / maxf(hv.y, 2.0))
		out.set_pixel(p.x, p.y,
				Color(clampf(q.x, -1.0, 1.0) * 0.5 + 0.5, clampf(q.y, -1.0, 1.0) * 0.5 + 0.5, 1.0, 1.0))


static func _centroid(pts: Array) -> Vector2:
	var acc := Vector2.ZERO
	for p in pts:
		acc += Vector2(p)
	return acc / float(maxi(pts.size(), 1))


static func _components(img: Image, rect: Rect2i) -> Array:
	var w := rect.size.x
	var h := rect.size.y
	var seen := PackedByteArray()
	seen.resize(w * h)
	var comps: Array = []
	for y in h:
		for x in w:
			var idx := y * w + x
			if seen[idx] == 1:
				continue
			seen[idx] = 1
			if img.get_pixel(rect.position.x + x, rect.position.y + y).a <= 0.5:
				continue
			var stack: Array[Vector2i] = [Vector2i(x, y)]
			var comp: Array = []
			while not stack.is_empty():
				var c: Vector2i = stack.pop_back()
				comp.append(Vector2i(c.x + rect.position.x, c.y + rect.position.y))
				for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
					var dv: Vector2i = d
					var nx: int = c.x + dv.x
					var ny: int = c.y + dv.y
					if nx < 0 or ny < 0 or nx >= w or ny >= h:
						continue
					var ni := ny * w + nx
					if seen[ni] == 1:
						continue
					seen[ni] = 1
					if img.get_pixel(rect.position.x + nx, rect.position.y + ny).a > 0.5:
						stack.append(Vector2i(nx, ny))
			comps.append(comp)
	return comps
