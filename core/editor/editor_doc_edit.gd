extends RefCounted

# 从 EditorDoc 拆出的 选区 / 剪贴板 / 镜像 / 整块移动 / 渐变 域(无 class_name,由 EditorDoc preload)。
# 纯静态函数:第一个参数是 EditorDoc(数据与信号仍归 doc,这里只放操作)。

# 裁剪到 [0,sub_size);w/h<=0(或裁剪后为空)⇒ 清空。越界不报错,也不环面回绕 ——
# 选区是「屏幕上看得到的一块矩形」,回绕会让同一块选区出现两份,画布没法画一个虚框。
static func set_selection(doc, sub_rect: Rect2i) -> void:
	var sz = doc.sub_size()
	if sz.x <= 0 or sz.y <= 0 or sub_rect.size.x <= 0 or sub_rect.size.y <= 0:
		doc.selection = Rect2i()
		return
	var x0 = maxi(0, sub_rect.position.x)
	var y0 = maxi(0, sub_rect.position.y)
	var x1 = mini(sz.x, sub_rect.position.x + sub_rect.size.x)
	var y1 = mini(sz.y, sub_rect.position.y + sub_rect.size.y)
	if x1 <= x0 or y1 <= y0:
		doc.selection = Rect2i()
		return
	doc.selection = Rect2i(x0, y0, x1 - x0, y1 - y0)



static func clear_selection(doc) -> void:
	doc.selection = Rect2i()



static func has_selection(doc) -> bool:
	return doc.selection.size.x > 0 and doc.selection.size.y > 0



static func selection_size(doc) -> Vector2i:
	return doc.selection.size if has_selection(doc) else Vector2i.ZERO


# ── 剪贴板(纹理↔颜色两种类型不互转)─────────────────────────────────────────


# 复制 active_layer 的选区到 clipboard;返回 {ok:true,w,h,count}(count = 复制的子格数 w*h,
# 空气格也算)。缺席的纹理层按 0 复制(与旧 JS copyRegion 的 `arr ? … : 0` 一致)。
static func copy_selection(doc) -> Dictionary:
	var sz = doc.sub_size()
	if sz.x <= 0 or sz.y <= 0:
		return doc._fail("地图还没建,无法复制")
	if not has_selection(doc):
		return doc._fail("先框选一块,再复制")
	var layer = doc.active_layer
	if layer < 0 or layer >= EditorConstants.LAYER_COUNT:
		return doc._fail("图层号非法: %d" % layer)
	var sel = doc._clipped_selection()
	var is_color = EditorConstants.is_color_layer(layer)
	var store_v: Variant = doc._read_array(layer)
	var store = PackedInt32Array()
	if store_v != null:
		store = store_v
	var w = sel.size.x
	var h = sel.size.y
	var values = PackedInt32Array()
	values.resize(w * h)
	for y in h:
		for x in w:
			var idx = posmod(sel.position.y + y, sz.y) * sz.x + posmod(sel.position.x + x, sz.x)
			# 颜色层存的是同一批位的有符号读数;剪贴板按原样存,粘贴时写回同一批位。
			values[y * w + x] = store[idx] if store_v != null else 0
	doc.clipboard = {
		"kind": "color" if is_color else "tex",
		"w": w,
		"h": h,
		"values": values,
	}
	return {"ok": true, "w": w, "h": h, "count": w * h}



# 剪切 = 复制 + 选区置 0。复制不产生历史;置 0 若有改动则恰好一条 cells 条目。
static func cut_selection(doc) -> Dictionary:
	if not has_selection(doc):
		return doc._fail("先框选一块,再剪切")
	var copied = copy_selection(doc)
	if not bool(copied.get("ok", false)):
		return copied
	var w = int(copied.get("w", 0))
	var h = int(copied.get("h", 0))
	clear_selection_cells(doc)
	return {"ok": true, "w": w, "h": h, "count": w * h}



# 以**格** (x,y) 为左上角粘贴(内部 ×SUB_PER_CELL 转子格),目标环面回绕;同一目标子格被多个源格
# 命中时按行主序先到先得(与旧 JS paintCells 的 seen 去重同序)。类型不互转时 ok:false。
static func paste_clipboard(doc, at_cell: Vector2i) -> Dictionary:
	var sz = doc.sub_size()
	if sz.x <= 0 or sz.y <= 0:
		return doc._fail("地图还没建,无法粘贴")
	var layer = doc.active_layer
	if layer < 0 or layer >= EditorConstants.LAYER_COUNT:
		return doc._fail("图层号非法: %d" % layer)
	if doc.clipboard.is_empty():
		return doc._fail("剪贴板是空的(先复制或剪切一块)")
	var kind = String(doc.clipboard.get("kind", ""))
	var w = int(doc.clipboard.get("w", 0))
	var h = int(doc.clipboard.get("h", 0))
	var values_v: Variant = doc.clipboard.get("values", null)
	if w <= 0 or h <= 0 or not (values_v is PackedInt32Array) \
			or (values_v as PackedInt32Array).size() < w * h or (kind != "tex" and kind != "color"):
		return doc._fail("剪贴板内容损坏(形状不对)")
	var layer_is_color = EditorConstants.is_color_layer(layer)
	if layer_is_color and kind != "color":
		return doc._fail("剪贴板是纹理层内容,不能粘到颜色层(纹理与颜色两种数据类型不互转)")
	if not layer_is_color and kind != "tex":
		return doc._fail("剪贴板是颜色层内容,不能粘到纹理层(纹理与颜色两种数据类型不互转)")
	var values: PackedInt32Array = values_v
	var base_x = posmod(at_cell.x * EditorConstants.SUB_PER_CELL, sz.x)
	var base_y = posmod(at_cell.y * EditorConstants.SUB_PER_CELL, sz.y)
	var seen = {}
	var target_idxs = PackedInt32Array()
	var target_vals = PackedInt32Array()
	var any_nonzero = false
	for y in h:
		for x in w:
			var idx = posmod(base_y + y, sz.y) * sz.x + posmod(base_x + x, sz.x)
			if seen.has(idx):
				continue
			seen[idx] = true
			var v = doc._to_i32(values[y * w + x])
			target_idxs.append(idx)
			target_vals.append(v)
			if v != 0:
				any_nonzero = true
	var store_v: Variant = doc._read_array(layer)
	if store_v == null:
		if not layer_is_color or not any_nonzero:
			return {"ok": true, "count": 0, "w": w, "h": h}
		store_v = doc._ensure_color_layer(layer)
		if store_v == null:
			return doc._fail("这一层不存在,无法粘贴")
	var store: PackedInt32Array = store_v
	var changed_idx = PackedInt32Array()
	var before = PackedInt32Array()
	var after = PackedInt32Array()
	for k in target_idxs.size():
		var idx = target_idxs[k]
		var nv = target_vals[k]
		if store[idx] == nv:
			continue
		changed_idx.append(idx)
		before.append(store[idx])
		after.append(nv)
	var changed = changed_idx.size()
	if changed > 0:
		doc._apply_cells_atomic(layer, store, changed_idx, before, after)
	return {"ok": true, "count": changed, "w": w, "h": h}



# 选区写 0(纹理层 = 空气 / 颜色层 = 黑);返回实际改动数。缺席层无改动、不建层、不产生条目。
static func clear_selection_cells(doc) -> int:
	var sz = doc.sub_size()
	if sz.x <= 0 or sz.y <= 0 or not has_selection(doc):
		return 0
	var layer = doc.active_layer
	if layer < 0 or layer >= EditorConstants.LAYER_COUNT:
		return 0
	var store_v: Variant = doc._read_array(layer)
	if store_v == null:
		return 0
	var store: PackedInt32Array = store_v
	var sel = doc._clipped_selection()
	var idxs = PackedInt32Array()
	var before = PackedInt32Array()
	for y in sel.size.y:
		for x in sel.size.x:
			var idx = posmod(sel.position.y + y, sz.y) * sz.x + posmod(sel.position.x + x, sz.x)
			if store[idx] == 0:
				continue
			idxs.append(idx)
			before.append(store[idx])
	if idxs.is_empty():
		return 0
	var after = PackedInt32Array()
	after.resize(idxs.size())
	doc._apply_cells_atomic(layer, store, idxs, before, after)
	return idxs.size()



# 选区整块平移(子格偏移):先读源值,再把源区置 0、目标区写回源值 —— 重叠格以目标写的值为准
# (是「移动」而非「复制」,也不是「先清后写」的 0)。选区跟着平移,尺寸不变。
# ★ 不环面回绕:目标矩形必须完整落在图内,越界 ⇒ ok:false(回绕会让同一块内容出现两份)。
# ★ 缺席的纹理层/颜色层没有内容可搬:选区照样平移、返回 count=0、绝不凭空建层。
# 成功且有改动 ⇒ 恰好一条多值稀疏条目(覆盖源∪目标中真正变过的格)+ 一次 changed + dirty=true。
static func move_selection_content(doc, offset_sub: Vector2i) -> Dictionary:
	var sz = doc.sub_size()
	if sz.x <= 0 or sz.y <= 0:
		return doc._fail("地图还没建,无法移动选区内容")
	var layer = doc.active_layer
	if layer < 0 or layer >= EditorConstants.LAYER_COUNT:
		return doc._fail("图层号非法: %d" % layer)
	if not has_selection(doc):
		return doc._fail("先框选一块,再移动")
	var sel = doc._clipped_selection()
	if sel.size.x <= 0 or sel.size.y <= 0:
		return doc._fail("先框选一块,再移动")
	if offset_sub == Vector2i.ZERO:
		return {"ok": true, "count": 0}
	# 目标矩形必须完整在图内(不环面回绕);失败时选区/图/历史一律不动。
	var tx = sel.position.x + offset_sub.x
	var ty = sel.position.y + offset_sub.y
	if tx < 0 or ty < 0 or tx + sel.size.x > sz.x or ty + sel.size.y > sz.y:
		return doc._fail("移动目标越界,选区不能移出图外(本操作不环面回绕)")
	var new_sel = Rect2i(tx, ty, sel.size.x, sel.size.y)
	var store_v: Variant = doc._read_array(layer)
	if store_v == null:
		doc.selection = new_sel                # 缺席层没有内容可搬:选区照样平移,不建层、不入栈
		return {"ok": true, "count": 0}
	var store: PackedInt32Array = store_v
	# ① 先读源值:后面要先清源再写目标,读晚了会被自己覆盖。
	var w = sel.size.x
	var h = sel.size.y
	var src_vals = PackedInt32Array()
	src_vals.resize(w * h)
	for y in h:
		for x in w:
			src_vals[y * w + x] = store[(sel.position.y + y) * sz.x + sel.position.x + x]
	# ② 每格最终值 = 源置 0 + 目标写源值;同一格既是源又是目标时,目标写覆盖 0(最终值为准)。
	var final_vals = {}
	for y in h:
		for x in w:
			final_vals[(sel.position.y + y) * sz.x + sel.position.x + x] = 0
	for y in h:
		for x in w:
			final_vals[(ty + y) * sz.x + tx + x] = src_vals[y * w + x]
	# ③ 只记真正变过的格(源区里本来就是空气的格不产生条目),一条多值稀疏条目。
	var idxs = PackedInt32Array()
	var before = PackedInt32Array()
	var after = PackedInt32Array()
	for idx in final_vals:
		var nv = int(final_vals[idx])
		if store[idx] == nv:
			continue
		idxs.append(idx)
		before.append(store[idx])
		after.append(nv)
	doc.selection = new_sel
	if idxs.is_empty():
		return {"ok": true, "count": 0}    # 搬了一块空气:无改动、不发信号、不 doc.dirty
	doc._apply_cells_atomic(layer, store, idxs, before, after)
	return {"ok": true, "count": idxs.size()}


# ── 镜像(只翻选区,不是整层)────────────────────────────────────────────────


# JS mirrorRegion 语义:目标 (x,y) 写源 (w-1-x,y) / (x,h-1-y);先全部读、再统一写(同时镜像);
# 与目标同值时跳过 ⇒ 回文/单格 = 0 改动、不产生 undo 条目。非法 axis 返回 ok:false。
static func mirror_selection(doc, axis: String) -> Dictionary:
	if axis != "h" and axis != "v":
		return doc._fail("镜像轴非法(只能 h 水平 / v 垂直):实得 " + axis)
	var sz = doc.sub_size()
	if sz.x <= 0 or sz.y <= 0:
		return doc._fail("地图还没建,无法镜像")
	if not has_selection(doc):
		return doc._fail("先框选一块,再镜像")
	var layer = doc.active_layer
	if layer < 0 or layer >= EditorConstants.LAYER_COUNT:
		return doc._fail("图层号非法: %d" % layer)
	var store_v: Variant = doc._read_array(layer)
	if store_v == null:
		return {"ok": true, "count": 0}    # 缺席层没有内容可翻(不是用户错误)
	var store: PackedInt32Array = store_v
	var sel = doc._clipped_selection()
	var idxs = PackedInt32Array()
	var before = PackedInt32Array()
	var after = PackedInt32Array()
	for y in sel.size.y:
		for x in sel.size.x:
			var sx = (sel.size.x - 1 - x) if axis == "h" else x
			var sy = (sel.size.y - 1 - y) if axis == "v" else y
			var di = posmod(sel.position.y + y, sz.y) * sz.x + posmod(sel.position.x + x, sz.x)
			var si = posmod(sel.position.y + sy, sz.y) * sz.x + posmod(sel.position.x + sx, sz.x)
			if store[di] == store[si]:
				continue
			idxs.append(di)
			before.append(store[di])
			after.append(store[si])
	if idxs.is_empty():
		return {"ok": true, "count": 0}
	doc._apply_cells_atomic(layer, store, idxs, before, after)
	return {"ok": true, "count": idxs.size()}


# ── 颜色层渐变(JS createGradientJob 语义)─────────────────────────────────


# t = ((X-ax)*dx + (Y-ay)*dy) / (dx²+dy²),夹 0..1;dx=dy=0 ⇒ t=0;逐通道 round(x+(y-x)*t)&255。
# 默认扫整层(行主序);clip_selection=true 只扫 selection 覆盖的子格。非颜色层 ⇒ ok:false。
static func paint_gradient(doc, a_sub: Vector2i, b_sub: Vector2i, rgba0: int, rgba1: int,
		clip_selection: bool = false) -> Dictionary:
	var sz = doc.sub_size()
	if sz.x <= 0 or sz.y <= 0:
		return doc._fail("地图还没建,无法渐变")
	var layer = doc.active_layer
	if layer < 0 or layer >= EditorConstants.LAYER_COUNT:
		return doc._fail("图层号非法: %d" % layer)
	if not EditorConstants.is_color_layer(layer):
		# 注意 %% :这段文案里的 50%/25% 是正文,不转义会被当成格式符。
		return doc._fail("渐变只能用在颜色层(背景 100%%/75%%/50%%/25%%),实得图层 %d" % layer)
	var dx = b_sub.x - a_sub.x
	var dy = b_sub.y - a_sub.y
	var len2 = dx * dx + dy * dy
	var store_v: Variant = doc._read_array(layer)
	var has_store = store_v != null
	var store = PackedInt32Array()
	if has_store:
		store = store_v
	var sel = doc.selection
	var clip_ok = has_selection(doc)
	var idxs = PackedInt32Array()
	var before = PackedInt32Array()
	var after = PackedInt32Array()
	for Y in sz.y:
		for X in sz.x:
			if clip_selection:
				if not clip_ok:
					continue
				if X < sel.position.x or Y < sel.position.y \
						or X >= sel.position.x + sel.size.x or Y >= sel.position.y + sel.size.y:
					continue
			var t = 0.0
			if len2 != 0:
				t = float((X - a_sub.x) * dx + (Y - a_sub.y) * dy) / float(len2)
				t = clampf(t, 0.0, 1.0)
			var nv = doc._to_i32(_lerp_rgba(rgba0, rgba1, t))
			var idx = Y * sz.x + X
			var old = store[idx] if has_store else 0
			if old == nv:
				continue
			idxs.append(idx)
			before.append(old)
			after.append(nv)
	if idxs.is_empty():
		return {"ok": true, "count": 0}
	if not has_store:
		var created: Variant = doc._ensure_color_layer(layer)
		if created == null:
			return doc._fail("这一层不存在,无法写入渐变")
		store = created
	doc._apply_cells_atomic(layer, store, idxs, before, after)
	return {"ok": true, "count": idxs.size()}


static func _lerp_rgba(a: int, b: int, t: float) -> int:
	var au := a & 0xFFFFFFFF
	var bu := b & 0xFFFFFFFF
	var out := 0
	for raw_shift in [24, 16, 8, 0]:
		var shift := int(raw_shift)
		var x := (au >> shift) & 255
		var y := (bu >> shift) & 255
		var c := roundi(float(x) + float(y - x) * t) & 255
		out = (out << 8) | c
	return out
