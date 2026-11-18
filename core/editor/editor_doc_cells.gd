extends RefCounted

# 从 EditorDoc 拆出的 格子读写(读 / 写 / 直线 / 油漆桶) 域(无 class_name,由 EditorDoc preload)。
# 纯静态函数:第一个参数是 EditorDoc(数据与信号仍归 doc,这里只放操作)。

# 环面归一化后读 active_layer:纹理层返回 desc,颜色层返回 u32 颜色;缺席层返回 0。
static func get_subcell(doc, sx: int, sy: int) -> int:
	var sz = doc.sub_size()
	if sz.x <= 0 or sz.y <= 0:
		return 0
	var layer = doc.active_layer
	if layer < 0 or layer >= EditorConstants.LAYER_COUNT:
		return 0
	var store_v: Variant = doc._read_array(layer)
	if store_v == null:
		return 0
	var store: PackedInt32Array = store_v
	var idx = posmod(sy, sz.y) * sz.x + posmod(sx, sz.x)
	if idx < 0 or idx >= store.size():
		return 0
	var v = store[idx]
	if EditorConstants.is_color_layer(layer):
		return v & 0xFFFFFFFF
	return v



# 吸管:与 get_subcell 同口径(active_layer 的 desc / 颜色层的 u32 颜色)。
static func sample(doc, sx: int, sy: int) -> int:
	return get_subcell(doc, sx, sy)


# ── 写入 ────────────────────────────────────────────────────────────────────


# 批量写 active_layer(环面归一化、去重、跳过写同值),返回实际改动格数。
# 0 改动 ⇒ 不 push undo、不发 changed、不动 dirty。
static func set_cells(doc, cells: Array[Vector2i], desc: int) -> int:
	var sz = doc.sub_size()
	if sz.x <= 0 or sz.y <= 0:
		return 0
	var layer = doc.active_layer
	if layer < 0 or layer >= EditorConstants.LAYER_COUNT:
		return 0
	var new_val = doc._to_i32(desc)
	var store_v: Variant = doc._read_array(layer)
	if store_v == null:
		if not EditorConstants.is_color_layer(layer):
			return 0                      # 纹理层缺席:不许凭空补层
		if new_val == 0:
			return 0                      # 写「透明」到不存在的颜色层 = 无操作,别白建一层
		store_v = doc._ensure_color_layer(layer)
		if store_v == null:
			return 0
	var store: PackedInt32Array = store_v
	var seen = {}
	var idxs = PackedInt32Array()
	var before = PackedInt32Array()
	for p in cells:
		var pt: Vector2i = p
		var idx = posmod(pt.y, sz.y) * sz.x + posmod(pt.x, sz.x)
		if seen.has(idx):
			continue
		seen[idx] = true
		var old = store[idx]
		if old == new_val:
			continue
		idxs.append(idx)
		before.append(old)
	if idxs.is_empty():
		return 0
	return doc._apply_change(layer, store, idxs, before, new_val)



# 直线 = Bresenham(含两端,与旧浏览器编辑器 lineCells 同算法;源已退役,历史见 git);
# 两端坐标可越界/为负,写入时逐格环面归一化。
static func paint_line(doc, a: Vector2i, b: Vector2i, desc: int) -> int:
	var cells: Array[Vector2i] = []
	var dx = absi(b.x - a.x)
	var dy = absi(b.y - a.y)
	var sx = 1 if a.x < b.x else -1
	var sy = 1 if a.y < b.y else -1
	var err = dx - dy
	var x = a.x
	var y = a.y
	while true:
		cells.append(Vector2i(x, y))
		if x == b.x and y == b.y:
			break
		var e2 = 2 * err
		if e2 > -dy:
			err -= dy
			x += sx
		if e2 < dx:
			err += dx
			y += sy
	return set_cells(doc, cells, desc)



# 油漆桶:4 邻接、按「当前值相等」扩散,环面接缝算连通;返回实际改动格数。
static func flood_fill(doc, start: Vector2i, desc: int) -> int:
	var sz = doc.sub_size()
	if sz.x <= 0 or sz.y <= 0:
		return 0
	var layer = doc.active_layer
	if layer < 0 or layer >= EditorConstants.LAYER_COUNT:
		return 0
	var new_val = doc._to_i32(desc)
	var store_v: Variant = doc._read_array(layer)
	if store_v == null:
		if not EditorConstants.is_color_layer(layer):
			return 0                      # 纹理层缺席:不许凭空补层
		if new_val == 0:
			return 0
		store_v = doc._ensure_color_layer(layer)
		if store_v == null:
			return 0
	var store: PackedInt32Array = store_v
	var n = sz.x * sz.y
	var start_idx = posmod(start.y, sz.y) * sz.x + posmod(start.x, sz.x)
	var target = store[start_idx]
	if target == new_val:
		return 0
	var visited = PackedByteArray()
	visited.resize(n)
	visited[start_idx] = 1
	var queue = PackedInt32Array([start_idx])
	var idxs = PackedInt32Array()
	var before = PackedInt32Array()
	var dirs: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	while not queue.is_empty():
		var idx = queue[queue.size() - 1]
		queue.remove_at(queue.size() - 1)
		idxs.append(idx)
		before.append(store[idx])
		var cx = idx % sz.x
		var cy = idx / sz.x
		for d in dirs:
			var ni = posmod(cy + d.y, sz.y) * sz.x + posmod(cx + d.x, sz.x)
			if visited[ni] == 1 or store[ni] != target:
				continue
			visited[ni] = 1
			queue.append(ni)
	return doc._apply_change(layer, store, idxs, before, new_val)


# ── 选区(子格矩形,裁剪到图内)──────────────────────────────────────────────
