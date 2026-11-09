class_name EditorDoc
extends RefCounted

# P2 文档模型:一张编辑器地图 + 稀疏 cells 撤销栈。纯逻辑、`-s` headless 可测;不碰磁盘、不依赖场景树。
# 契约见 docs/eng/editor-godot.md §4;地图字典形状 = EditorMap.create_map()(7 层,0-2 tex / 3-6 color,4-6 可 null)。
#
# ★ 撤销条目 = {layer:int, idxs:PackedInt32Array, before:PackedInt32Array, after:PackedInt32Array, color:bool}:
#   只记**真正变过的子格**(idxs = sy*sub_cols+sx),一个笔画也只有变动格的内存,不存整图快照。
#   before/after 与 idxs 逐位对应;after 是**每格**的新值(同一笔里可能不同 desc,所以不是单个标量)。
# ★ 环面世界:set_cells/get_subcell/flood_fill 的入参一律 posmod 到 [0,sub_cols)×[0,sub_rows) 兜底,
#   调用方(画布)已经归一化也不冲突;paint_line 的端点可能为负,Bresenham 走原始坐标、写入时再归一化。
# ★ 颜色层(3-6)的值是 RGBA u32 = 0xRRGGBBAA:set_cells 接受任意 int(按 32 位截断),get_subcell/sample
#   返回**无符号 u32**(0xRRGGBBAA);层内 PackedInt32Array 存的是同一批位的有符号读数——高位颜色落成
#   负数是正常的(0xFF336699 存 -13408615),要无符号值请 `v & 0xFFFFFFFF`,别拿存储值直接比颜色。
# ★ 纹理层(0-2)缺席 = 旧文件没有这一层:set_cells/flood_fill 一律无操作返回 0,**绝不**凭空补空层;
#   ensure_layer 只对颜色层按需建层(层从 null 变成 color 会发 structure_changed,画布要整体重建)。
# ★ 失败路径一律「无操作 + 返回 0/false」,不 push_error(编辑器里这些通常是用户输入)。
# ★ 撤销栈双上限:undo_capacity 条 + undo_cells_budget 累计 cells,超了丢最旧;
#   单条就超 budget 时保留最新一条(与 JS 编辑器 createHistory 的 `undos.length > 1` 一致:全丢 = 没有撤销)。
# ★ dirty 只在 load_map/new_map 清 false;undo/redo 不回退 dirty(撤销过的图依然没落盘)。
# ★ 选区/剪贴板/镜像/渐变(契约 .tmp/p2-extras-contract.md §1):
#   selection 是**裁剪到图内**的子格矩形(w/h<=0 = 无选区);clipboard 形状
#   {"kind":"tex"|"color","w":int,"h":int,"values":PackedInt32Array}(纹理↔颜色两种类型不互转)。
#   这些操作各产生一条稀疏 cells 条目(无变化不产生);操作前若笔画未收尾会先 end_stroke。
# ★ meta(出生点/复活点/敌人)编辑产生快照式条目 {"kind":"meta","before","after"}:
#   只发 meta_changed、不发 changed,但 dirty 照样置位;undo/redo 走 _apply_meta_snapshot,
#   永远深拷贝 —— 历史条目与 map 里的数组不许共用引用(JS applySpawns 同款纪律)。


signal changed(layer: int, subcells: PackedInt32Array)   # 子格索引 = sy * sub_cols + sx
signal structure_changed()                               # 换图 / 尺寸变 / 层增删(画布要整体重建)
signal meta_changed()                                    # 出生点/复活点/敌人改动(画布标记/面板刷新)

var map: Dictionary = {}                # 契约 §1 形状;外部可读,别整体替换(用 load_map/new_map)
var active_layer: int = 1               # 0..6;0-2 读写 desc,3-6 读写 rgba(u32)
var selection: Rect2i = Rect2i()        # 子格矩形;w/h<=0 = 无选区(写入时已裁剪到图内)
var clipboard: Dictionary = {}          # {} 或 {"kind":"tex"|"color","w":int,"h":int,"values":PackedInt32Array}
var dirty: bool = false
var undo_capacity: int = 60             # 条数上限(超出丢最旧)
var undo_cells_budget: int = 2_000_000  # 撤销栈累计 cells 上限(超出丢最旧;单条超预算时保留最新一条)

var _undo: Array[Dictionary] = []
var _redo: Array[Dictionary] = []
var _undo_cells: int = 0
var _stroke_open := false
var _stroke_entry: Dictionary = {}
var _stroke_pos: Dictionary = {}         # idx -> 该格在 _stroke_entry 里的位置(同一格重复涂时 before 取第一次)


# ── 文档装载 ────────────────────────────────────────────────────────────────

# 装入一张已有的图(已由 EditorIO 做过 legacy 迁移,本函数不重复迁移)。
func load_map(m: Dictionary) -> void:
	map = m
	_undo.clear()
	_redo.clear()
	_undo_cells = 0
	_stroke_open = false
	_stroke_entry = {}
	_stroke_pos.clear()
	selection = Rect2i()                 # 换图清选区;clipboard 故意保留(跨图粘贴是合理用法)
	dirty = false
	structure_changed.emit()


# 建一张空图;尺寸非法时无操作(不抛错)。meta 出生点不在这里加(调用方的事)。
func new_map(map_name: String, cells_w: int, cells_h: int) -> void:
	if cells_w <= 0 or cells_h <= 0:
		return
	var m: Dictionary = EditorMap.create_map(map_name, cells_w, cells_h)
	if m.is_empty():
		return
	load_map(m)


func sub_size() -> Vector2i:
	return Vector2i(int(map.get("sub_cols", 0)), int(map.get("sub_rows", 0)))


# ── 读取 ────────────────────────────────────────────────────────────────────

# 环面归一化后读 active_layer:纹理层返回 desc,颜色层返回 u32 颜色;缺席层返回 0。
func get_subcell(sx: int, sy: int) -> int:
	var sz := sub_size()
	if sz.x <= 0 or sz.y <= 0:
		return 0
	var layer := active_layer
	if layer < 0 or layer >= EditorConstants.LAYER_COUNT:
		return 0
	var store_v: Variant = _read_array(layer)
	if store_v == null:
		return 0
	var store: PackedInt32Array = store_v
	var idx := posmod(sy, sz.y) * sz.x + posmod(sx, sz.x)
	if idx < 0 or idx >= store.size():
		return 0
	var v := store[idx]
	if EditorConstants.is_color_layer(layer):
		return v & 0xFFFFFFFF
	return v


# 吸管:与 get_subcell 同口径(active_layer 的 desc / 颜色层的 u32 颜色)。
func sample(sx: int, sy: int) -> int:
	return get_subcell(sx, sy)


# ── 写入 ────────────────────────────────────────────────────────────────────

# 批量写 active_layer(环面归一化、去重、跳过写同值),返回实际改动格数。
# 0 改动 ⇒ 不 push undo、不发 changed、不动 dirty。
func set_cells(cells: Array[Vector2i], desc: int) -> int:
	var sz := sub_size()
	if sz.x <= 0 or sz.y <= 0:
		return 0
	var layer := active_layer
	if layer < 0 or layer >= EditorConstants.LAYER_COUNT:
		return 0
	var new_val := _to_i32(desc)
	var store_v: Variant = _read_array(layer)
	if store_v == null:
		if not EditorConstants.is_color_layer(layer):
			return 0                      # 纹理层缺席:不许凭空补层
		if new_val == 0:
			return 0                      # 写「透明」到不存在的颜色层 = 无操作,别白建一层
		store_v = _ensure_color_layer(layer)
		if store_v == null:
			return 0
	var store: PackedInt32Array = store_v
	var seen := {}
	var idxs := PackedInt32Array()
	var before := PackedInt32Array()
	for p in cells:
		var pt: Vector2i = p
		var idx := posmod(pt.y, sz.y) * sz.x + posmod(pt.x, sz.x)
		if seen.has(idx):
			continue
		seen[idx] = true
		var old := store[idx]
		if old == new_val:
			continue
		idxs.append(idx)
		before.append(old)
	if idxs.is_empty():
		return 0
	return _apply_change(layer, store, idxs, before, new_val)


# 直线 = Bresenham(含两端,与旧浏览器编辑器 lineCells 同算法;源已退役,历史见 git);
# 两端坐标可越界/为负,写入时逐格环面归一化。
func paint_line(a: Vector2i, b: Vector2i, desc: int) -> int:
	var cells: Array[Vector2i] = []
	var dx := absi(b.x - a.x)
	var dy := absi(b.y - a.y)
	var sx := 1 if a.x < b.x else -1
	var sy := 1 if a.y < b.y else -1
	var err := dx - dy
	var x := a.x
	var y := a.y
	while true:
		cells.append(Vector2i(x, y))
		if x == b.x and y == b.y:
			break
		var e2 := 2 * err
		if e2 > -dy:
			err -= dy
			x += sx
		if e2 < dx:
			err += dx
			y += sy
	return set_cells(cells, desc)


# 油漆桶:4 邻接、按「当前值相等」扩散,环面接缝算连通;返回实际改动格数。
func flood_fill(start: Vector2i, desc: int) -> int:
	var sz := sub_size()
	if sz.x <= 0 or sz.y <= 0:
		return 0
	var layer := active_layer
	if layer < 0 or layer >= EditorConstants.LAYER_COUNT:
		return 0
	var new_val := _to_i32(desc)
	var store_v: Variant = _read_array(layer)
	if store_v == null:
		if not EditorConstants.is_color_layer(layer):
			return 0                      # 纹理层缺席:不许凭空补层
		if new_val == 0:
			return 0
		store_v = _ensure_color_layer(layer)
		if store_v == null:
			return 0
	var store: PackedInt32Array = store_v
	var n := sz.x * sz.y
	var start_idx := posmod(start.y, sz.y) * sz.x + posmod(start.x, sz.x)
	var target := store[start_idx]
	if target == new_val:
		return 0
	var visited := PackedByteArray()
	visited.resize(n)
	visited[start_idx] = 1
	var queue := PackedInt32Array([start_idx])
	var idxs := PackedInt32Array()
	var before := PackedInt32Array()
	var dirs: Array[Vector2i] = [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]
	while not queue.is_empty():
		var idx := queue[queue.size() - 1]
		queue.remove_at(queue.size() - 1)
		idxs.append(idx)
		before.append(store[idx])
		var cx := idx % sz.x
		var cy := idx / sz.x
		for d in dirs:
			var ni := posmod(cy + d.y, sz.y) * sz.x + posmod(cx + d.x, sz.x)
			if visited[ni] == 1 or store[ni] != target:
				continue
			visited[ni] = 1
			queue.append(ni)
	return _apply_change(layer, store, idxs, before, new_val)


# ── 选区(子格矩形,裁剪到图内)──────────────────────────────────────────────

# 裁剪到 [0,sub_size);w/h<=0(或裁剪后为空)⇒ 清空。越界不报错,也不环面回绕 ——
# 选区是「屏幕上看得到的一块矩形」,回绕会让同一块选区出现两份,画布没法画一个虚框。
func set_selection(sub_rect: Rect2i) -> void:
	var sz := sub_size()
	if sz.x <= 0 or sz.y <= 0 or sub_rect.size.x <= 0 or sub_rect.size.y <= 0:
		selection = Rect2i()
		return
	var x0 := maxi(0, sub_rect.position.x)
	var y0 := maxi(0, sub_rect.position.y)
	var x1 := mini(sz.x, sub_rect.position.x + sub_rect.size.x)
	var y1 := mini(sz.y, sub_rect.position.y + sub_rect.size.y)
	if x1 <= x0 or y1 <= y0:
		selection = Rect2i()
		return
	selection = Rect2i(x0, y0, x1 - x0, y1 - y0)


func clear_selection() -> void:
	selection = Rect2i()


func has_selection() -> bool:
	return selection.size.x > 0 and selection.size.y > 0


func selection_size() -> Vector2i:
	return selection.size if has_selection() else Vector2i.ZERO


# ── 剪贴板(纹理↔颜色两种类型不互转)─────────────────────────────────────────

# 复制 active_layer 的选区到 clipboard;返回 {ok:true,w,h,count}(count = 复制的子格数 w*h,
# 空气格也算)。缺席的纹理层按 0 复制(与旧 JS copyRegion 的 `arr ? … : 0` 一致)。
func copy_selection() -> Dictionary:
	var sz := sub_size()
	if sz.x <= 0 or sz.y <= 0:
		return _fail("地图还没建,无法复制")
	if not has_selection():
		return _fail("先框选一块,再复制")
	var layer := active_layer
	if layer < 0 or layer >= EditorConstants.LAYER_COUNT:
		return _fail("图层号非法: %d" % layer)
	var sel := _clipped_selection()
	var is_color := EditorConstants.is_color_layer(layer)
	var store_v: Variant = _read_array(layer)
	var store := PackedInt32Array()
	if store_v != null:
		store = store_v
	var w := sel.size.x
	var h := sel.size.y
	var values := PackedInt32Array()
	values.resize(w * h)
	for y in h:
		for x in w:
			var idx := posmod(sel.position.y + y, sz.y) * sz.x + posmod(sel.position.x + x, sz.x)
			# 颜色层存的是同一批位的有符号读数;剪贴板按原样存,粘贴时写回同一批位。
			values[y * w + x] = store[idx] if store_v != null else 0
	clipboard = {
		"kind": "color" if is_color else "tex",
		"w": w,
		"h": h,
		"values": values,
	}
	return {"ok": true, "w": w, "h": h, "count": w * h}


# 剪切 = 复制 + 选区置 0。复制不产生历史;置 0 若有改动则恰好一条 cells 条目。
func cut_selection() -> Dictionary:
	if not has_selection():
		return _fail("先框选一块,再剪切")
	var copied := copy_selection()
	if not bool(copied.get("ok", false)):
		return copied
	var w := int(copied.get("w", 0))
	var h := int(copied.get("h", 0))
	clear_selection_cells()
	return {"ok": true, "w": w, "h": h, "count": w * h}


# 以**格** (x,y) 为左上角粘贴(内部 ×SUB_PER_CELL 转子格),目标环面回绕;同一目标子格被多个源格
# 命中时按行主序先到先得(与旧 JS paintCells 的 seen 去重同序)。类型不互转时 ok:false。
func paste_clipboard(at_cell: Vector2i) -> Dictionary:
	var sz := sub_size()
	if sz.x <= 0 or sz.y <= 0:
		return _fail("地图还没建,无法粘贴")
	var layer := active_layer
	if layer < 0 or layer >= EditorConstants.LAYER_COUNT:
		return _fail("图层号非法: %d" % layer)
	if clipboard.is_empty():
		return _fail("剪贴板是空的(先复制或剪切一块)")
	var kind := String(clipboard.get("kind", ""))
	var w := int(clipboard.get("w", 0))
	var h := int(clipboard.get("h", 0))
	var values_v: Variant = clipboard.get("values", null)
	if w <= 0 or h <= 0 or not (values_v is PackedInt32Array) \
			or (values_v as PackedInt32Array).size() < w * h or (kind != "tex" and kind != "color"):
		return _fail("剪贴板内容损坏(形状不对)")
	var layer_is_color := EditorConstants.is_color_layer(layer)
	if layer_is_color and kind != "color":
		return _fail("剪贴板是纹理层内容,不能粘到颜色层(纹理与颜色两种数据类型不互转)")
	if not layer_is_color and kind != "tex":
		return _fail("剪贴板是颜色层内容,不能粘到纹理层(纹理与颜色两种数据类型不互转)")
	var values: PackedInt32Array = values_v
	var base_x := posmod(at_cell.x * EditorConstants.SUB_PER_CELL, sz.x)
	var base_y := posmod(at_cell.y * EditorConstants.SUB_PER_CELL, sz.y)
	var seen := {}
	var target_idxs := PackedInt32Array()
	var target_vals := PackedInt32Array()
	var any_nonzero := false
	for y in h:
		for x in w:
			var idx := posmod(base_y + y, sz.y) * sz.x + posmod(base_x + x, sz.x)
			if seen.has(idx):
				continue
			seen[idx] = true
			var v := _to_i32(values[y * w + x])
			target_idxs.append(idx)
			target_vals.append(v)
			if v != 0:
				any_nonzero = true
	var store_v: Variant = _read_array(layer)
	if store_v == null:
		if not layer_is_color or not any_nonzero:
			return {"ok": true, "count": 0, "w": w, "h": h}
		store_v = _ensure_color_layer(layer)
		if store_v == null:
			return _fail("这一层不存在,无法粘贴")
	var store: PackedInt32Array = store_v
	var changed_idx := PackedInt32Array()
	var before := PackedInt32Array()
	var after := PackedInt32Array()
	for k in target_idxs.size():
		var idx := target_idxs[k]
		var nv := target_vals[k]
		if store[idx] == nv:
			continue
		changed_idx.append(idx)
		before.append(store[idx])
		after.append(nv)
	var changed := changed_idx.size()
	if changed > 0:
		_apply_cells_atomic(layer, store, changed_idx, before, after)
	return {"ok": true, "count": changed, "w": w, "h": h}


# 选区写 0(纹理层 = 空气 / 颜色层 = 黑);返回实际改动数。缺席层无改动、不建层、不产生条目。
func clear_selection_cells() -> int:
	var sz := sub_size()
	if sz.x <= 0 or sz.y <= 0 or not has_selection():
		return 0
	var layer := active_layer
	if layer < 0 or layer >= EditorConstants.LAYER_COUNT:
		return 0
	var store_v: Variant = _read_array(layer)
	if store_v == null:
		return 0
	var store: PackedInt32Array = store_v
	var sel := _clipped_selection()
	var idxs := PackedInt32Array()
	var before := PackedInt32Array()
	for y in sel.size.y:
		for x in sel.size.x:
			var idx := posmod(sel.position.y + y, sz.y) * sz.x + posmod(sel.position.x + x, sz.x)
			if store[idx] == 0:
				continue
			idxs.append(idx)
			before.append(store[idx])
	if idxs.is_empty():
		return 0
	var after := PackedInt32Array()
	after.resize(idxs.size())
	_apply_cells_atomic(layer, store, idxs, before, after)
	return idxs.size()


# ── 镜像(只翻选区,不是整层)────────────────────────────────────────────────

# JS mirrorRegion 语义:目标 (x,y) 写源 (w-1-x,y) / (x,h-1-y);先全部读、再统一写(同时镜像);
# 与目标同值时跳过 ⇒ 回文/单格 = 0 改动、不产生 undo 条目。非法 axis 返回 ok:false。
func mirror_selection(axis: String) -> Dictionary:
	if axis != "h" and axis != "v":
		return _fail("镜像轴非法(只能 h 水平 / v 垂直):实得 " + axis)
	var sz := sub_size()
	if sz.x <= 0 or sz.y <= 0:
		return _fail("地图还没建,无法镜像")
	if not has_selection():
		return _fail("先框选一块,再镜像")
	var layer := active_layer
	if layer < 0 or layer >= EditorConstants.LAYER_COUNT:
		return _fail("图层号非法: %d" % layer)
	var store_v: Variant = _read_array(layer)
	if store_v == null:
		return {"ok": true, "count": 0}    # 缺席层没有内容可翻(不是用户错误)
	var store: PackedInt32Array = store_v
	var sel := _clipped_selection()
	var idxs := PackedInt32Array()
	var before := PackedInt32Array()
	var after := PackedInt32Array()
	for y in sel.size.y:
		for x in sel.size.x:
			var sx := (sel.size.x - 1 - x) if axis == "h" else x
			var sy := (sel.size.y - 1 - y) if axis == "v" else y
			var di := posmod(sel.position.y + y, sz.y) * sz.x + posmod(sel.position.x + x, sz.x)
			var si := posmod(sel.position.y + sy, sz.y) * sz.x + posmod(sel.position.x + sx, sz.x)
			if store[di] == store[si]:
				continue
			idxs.append(di)
			before.append(store[di])
			after.append(store[si])
	if idxs.is_empty():
		return {"ok": true, "count": 0}
	_apply_cells_atomic(layer, store, idxs, before, after)
	return {"ok": true, "count": idxs.size()}


# ── 颜色层渐变(JS createGradientJob 语义)─────────────────────────────────

# t = ((X-ax)*dx + (Y-ay)*dy) / (dx²+dy²),夹 0..1;dx=dy=0 ⇒ t=0;逐通道 round(x+(y-x)*t)&255。
# 默认扫整层(行主序);clip_selection=true 只扫 selection 覆盖的子格。非颜色层 ⇒ ok:false。
func paint_gradient(a_sub: Vector2i, b_sub: Vector2i, rgba0: int, rgba1: int,
		clip_selection: bool = false) -> Dictionary:
	var sz := sub_size()
	if sz.x <= 0 or sz.y <= 0:
		return _fail("地图还没建,无法渐变")
	var layer := active_layer
	if layer < 0 or layer >= EditorConstants.LAYER_COUNT:
		return _fail("图层号非法: %d" % layer)
	if not EditorConstants.is_color_layer(layer):
		# 注意 %% :这段文案里的 50%/25% 是正文,不转义会被当成格式符。
		return _fail("渐变只能用在颜色层(背景 100%%/75%%/50%%/25%%),实得图层 %d" % layer)
	var dx := b_sub.x - a_sub.x
	var dy := b_sub.y - a_sub.y
	var len2 := dx * dx + dy * dy
	var store_v: Variant = _read_array(layer)
	var has_store := store_v != null
	var store := PackedInt32Array()
	if has_store:
		store = store_v
	var sel := selection
	var clip_ok := has_selection()
	var idxs := PackedInt32Array()
	var before := PackedInt32Array()
	var after := PackedInt32Array()
	for Y in sz.y:
		for X in sz.x:
			if clip_selection:
				if not clip_ok:
					continue
				if X < sel.position.x or Y < sel.position.y \
						or X >= sel.position.x + sel.size.x or Y >= sel.position.y + sel.size.y:
					continue
			var t := 0.0
			if len2 != 0:
				t = float((X - a_sub.x) * dx + (Y - a_sub.y) * dy) / float(len2)
				t = clampf(t, 0.0, 1.0)
			var nv := _to_i32(_lerp_rgba(rgba0, rgba1, t))
			var idx := Y * sz.x + X
			var old := store[idx] if has_store else 0
			if old == nv:
				continue
			idxs.append(idx)
			before.append(old)
			after.append(nv)
	if idxs.is_empty():
		return {"ok": true, "count": 0}
	if not has_store:
		var created: Variant = _ensure_color_layer(layer)
		if created == null:
			return _fail("这一层不存在,无法写入渐变")
		store = created
	_apply_cells_atomic(layer, store, idxs, before, after)
	return {"ok": true, "count": idxs.size()}


# JS lerpRGBA:逐通道 round(x+(y-x)*t)&255;结果按 u32 返回。
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


# ── meta:出生点 / 复活点 / 敌人(入 undo 栈,快照式条目)──────────────────────
# 坐标一律先环面归一化到格([0,cells_w)×[0,cells_h));list 里存的也是格坐标(与 validate/MapFormat 同口径)。
# 所有改动 dirty=true、发 meta_changed(每次恰好一次);无改动不产生条目、不发信号。
# add_* 不做重复检查(旧 JS 同款);remove_* 删「坐标等同的第一个」。

func add_player(cell: Vector2i) -> int:
	if not _meta_ready():
		return -1
	var before := meta_snapshot()
	var c := _wrap_cell(cell)
	var players: Array = map.get("players", [])
	players.append({"x": c.x, "y": c.y})
	map["players"] = players
	_commit_meta_change(before)
	return players.size() - 1


func remove_player_at(cell: Vector2i) -> bool:
	if not _meta_ready():
		return false
	var c := _wrap_cell(cell)
	var players: Array = map.get("players", [])
	for i in players.size():
		var d: Dictionary = players[i]
		if int(d.get("x", -1)) == c.x and int(d.get("y", -1)) == c.y:
			var before := meta_snapshot()
			players.remove_at(i)
			map["players"] = players
			_commit_meta_change(before)
			return true
	return false


# side 只认 1|2,否则 -1。
func add_respawn(side: int, cell: Vector2i) -> int:
	if side != 1 and side != 2:
		return -1
	if not _meta_ready():
		return -1
	var before := meta_snapshot()
	var c := _wrap_cell(cell)
	var respawns: Array = map.get("respawns", [])
	respawns.append({"side": side, "x": c.x, "y": c.y})
	map["respawns"] = respawns
	_commit_meta_change(before)
	return respawns.size() - 1


func remove_respawn_at(side: int, cell: Vector2i) -> bool:
	if side != 1 and side != 2:
		return false
	if not _meta_ready():
		return false
	var c := _wrap_cell(cell)
	var respawns: Array = map.get("respawns", [])
	for i in respawns.size():
		var d: Dictionary = respawns[i]
		if int(d.get("side", 0)) == side and int(d.get("x", -1)) == c.x \
				and int(d.get("y", -1)) == c.y:
			var before := meta_snapshot()
			respawns.remove_at(i)
			map["respawns"] = respawns
			_commit_meta_change(before)
			return true
	return false


func add_enemy(enemy_type: String, cell: Vector2i) -> int:
	if not _meta_ready():
		return -1
	var before := meta_snapshot()
	var c := _wrap_cell(cell)
	var enemies: Array = map.get("enemies", [])
	enemies.append({"type": enemy_type, "x": c.x, "y": c.y})
	map["enemies"] = enemies
	_commit_meta_change(before)
	return enemies.size() - 1


func remove_enemy_at(cell: Vector2i) -> bool:
	if not _meta_ready():
		return false
	var c := _wrap_cell(cell)
	var enemies: Array = map.get("enemies", [])
	for i in enemies.size():
		var d: Dictionary = enemies[i]
		if int(d.get("x", -1)) == c.x and int(d.get("y", -1)) == c.y:
			var before := meta_snapshot()
			enemies.remove_at(i)
			map["enemies"] = enemies
			_commit_meta_change(before)
			return true
	return false


# kind 只认 "players"|"respawns"|"enemies"|"all";返回删除条数,非法 kind 返回 -1。
func clear_meta(kind: String) -> int:
	if not _meta_ready():
		return -1
	if kind != "players" and kind != "respawns" and kind != "enemies" and kind != "all":
		return -1
	var before := meta_snapshot()
	var removed := 0
	if kind == "players" or kind == "all":
		var players: Array = map.get("players", [])
		removed += players.size()
		if not players.is_empty():
			map["players"] = []
	if kind == "respawns" or kind == "all":
		var respawns: Array = map.get("respawns", [])
		removed += respawns.size()
		if not respawns.is_empty():
			map["respawns"] = []
	if kind == "enemies" or kind == "all":
		var enemies: Array = map.get("enemies", [])
		removed += enemies.size()
		if not enemies.is_empty():
			map["enemies"] = []
	if removed == 0:
		return 0
	_commit_meta_change(before)
	return removed


# 深拷贝 {"players","respawns","enemies"}:改返回值不影响 doc(undo 快照同样靠它隔离)。
func meta_snapshot() -> Dictionary:
	return {
		"players": _copy_meta_entries(map.get("players", []), "player"),
		"respawns": _copy_meta_entries(map.get("respawns", []), "respawn"),
		"enemies": _copy_meta_entries(map.get("enemies", []), "enemy"),
	}


# ── 校验 / 编码接线 ─────────────────────────────────────────────────────────

func validate() -> Dictionary:
	return EditorValidate.validate_map(map)


func to_bytes(opts: Dictionary = {}) -> Dictionary:
	return EditorCodec.encode_map(map, opts)


# ── 撤销 / 重做 ─────────────────────────────────────────────────────────────

# 连续笔画合并成一条 undo:第一笔前调 begin_stroke,最后一笔后调 end_stroke。
func begin_stroke() -> void:
	if _stroke_open:
		end_stroke()
	_stroke_open = true
	_stroke_entry = {}
	_stroke_pos.clear()


# 结束合并;空笔画(一格没改)不产生 undo 条目。
func end_stroke() -> void:
	if not _stroke_open:
		return
	_stroke_open = false
	_flush_stroke_entry()


func undo() -> bool:
	if _stroke_open:
		end_stroke()                      # 笔画还没收尾:先把它落成一条,再撤它
	if _undo.is_empty():
		return false
	var entry: Dictionary = _undo.pop_back()
	if _is_meta_entry(entry):
		_apply_meta_snapshot(entry["before"])
		_redo.append(entry)
		dirty = true                      # 撤销 ≠ 落盘,保持 dirty
		meta_changed.emit()
		return true
	var idxs: PackedInt32Array = entry["idxs"]
	_undo_cells -= idxs.size()
	var layer := int(entry["layer"])
	var store_v: Variant = _write_target(layer)
	if store_v == null:
		_undo.append(entry)               # 图层没了(外部改坏 map):不动栈
		_undo_cells += idxs.size()
		return false
	_apply_values(layer, store_v, idxs, entry["before"])
	_redo.append(entry)
	dirty = true                          # 撤销 ≠ 落盘,保持 dirty
	changed.emit(layer, idxs)
	return true


func redo() -> bool:
	if _stroke_open:
		end_stroke()                      # 结束笔画会清空 redo 链 ⇒ 这里之后通常直接 false
	if _redo.is_empty():
		return false
	var entry: Dictionary = _redo.pop_back()
	if _is_meta_entry(entry):
		_apply_meta_snapshot(entry["after"])
		_undo.append(entry)
		_trim_undo()
		dirty = true
		meta_changed.emit()
		return true
	var idxs: PackedInt32Array = entry["idxs"]
	var layer := int(entry["layer"])
	var store_v: Variant = _write_target(layer)
	if store_v == null:
		_redo.append(entry)
		return false
	_apply_values(layer, store_v, idxs, entry["after"])
	_undo.append(entry)
	_undo_cells += idxs.size()
	_trim_undo()
	dirty = true
	changed.emit(layer, idxs)
	return true


func can_undo() -> bool:
	return not _undo.is_empty()


func can_redo() -> bool:
	return not _redo.is_empty()


func undo_count() -> int:
	return _undo.size()


# ── 内部:写入与历史 ────────────────────────────────────────────────────────

# 把 idxs 处写成 new_val:落笔、写回层字典、dirty、记 undo/合并笔画、发 changed;返回改动格数。
func _apply_change(layer: int, store: PackedInt32Array, idxs: PackedInt32Array,
		before: PackedInt32Array, new_val: int) -> int:
	for idx in idxs:
		store[idx] = new_val
	_store_write_back(layer, store)
	dirty = true
	if _stroke_open:
		_merge_stroke(layer, idxs, before, new_val)
	else:
		_commit_entry(_make_entry(layer, idxs, before, _filled(idxs.size(), new_val)))
	changed.emit(layer, idxs)
	return idxs.size()


# 高层的原子操作(剪切/粘贴/清除/镜像/渐变)共用:先收尾未结束的笔画(避免半截笔画被并进
# 别人的条目),再写、记一条**多值**稀疏条目、发 changed。after 与 idxs 逐位对应 —— 这点与
# set_cells 的「同一笔同值」不同,所以不能走 _apply_change。
func _apply_cells_atomic(layer: int, store: PackedInt32Array, idxs: PackedInt32Array,
		before: PackedInt32Array, after: PackedInt32Array) -> int:
	if idxs.is_empty():
		return 0
	if _stroke_open:
		end_stroke()
	var count := mini(idxs.size(), after.size())
	for k in count:
		store[idxs[k]] = after[k]
	_store_write_back(layer, store)
	dirty = true
	_commit_entry(_make_entry(layer, idxs, before, after))
	changed.emit(layer, idxs)
	return count


# undo/redo 写回:values 与 idxs 逐位对应。★ 层号必须用条目里的 layer,不能用 active_layer
# (用户可能先切层再按 Ctrl+Z;写回错层会把另一层的数组整个覆盖掉)。
func _apply_values(layer: int, store_v: Variant, idxs: PackedInt32Array, values: PackedInt32Array) -> void:
	var store: PackedInt32Array = store_v
	var count := mini(idxs.size(), values.size())
	for k in count:
		store[idxs[k]] = values[k]
	_store_write_back(layer, store)


func _make_entry(layer: int, idxs: PackedInt32Array, before: PackedInt32Array,
		after: PackedInt32Array) -> Dictionary:
	return {
		"layer": layer,
		"idxs": idxs,
		"before": before,
		"after": after,
		"color": EditorConstants.is_color_layer(layer),
	}


# 一笔里同一格可能被涂多次(after 随最后一次,before 永远是笔画开始前的值)。
func _merge_stroke(layer: int, idxs: PackedInt32Array, before: PackedInt32Array, new_val: int) -> void:
	if _stroke_entry.is_empty() or int(_stroke_entry["layer"]) != layer:
		# 一笔里换了层:先把已有那层落栈,再为当前层开新条目(仍处于 stroke 合并中)
		_flush_stroke_entry()
		_stroke_entry = _make_entry(layer, PackedInt32Array(), PackedInt32Array(), PackedInt32Array())
		_stroke_pos.clear()
	var e_idx: PackedInt32Array = _stroke_entry["idxs"]
	var e_before: PackedInt32Array = _stroke_entry["before"]
	var e_after: PackedInt32Array = _stroke_entry["after"]
	for k in idxs.size():
		var idx := idxs[k]
		if _stroke_pos.has(idx):
			e_after[int(_stroke_pos[idx])] = new_val
		else:
			_stroke_pos[idx] = e_idx.size()
			e_idx.append(idx)
			e_before.append(before[k])
			e_after.append(new_val)
	# Packed 数组是写时复制:改动本地副本后必须写回条目,否则笔画记录丢格
	_stroke_entry["idxs"] = e_idx
	_stroke_entry["before"] = e_before
	_stroke_entry["after"] = e_after


func _flush_stroke_entry() -> void:
	if _stroke_entry.is_empty():
		return
	var e: Dictionary = _stroke_entry
	_stroke_entry = {}
	_stroke_pos.clear()
	if (e["idxs"] as PackedInt32Array).is_empty():
		return                            # 空笔画:不产生 undo 条目
	_commit_entry(e)


# 新编辑入栈并断掉 redo 链(标准语义)。
func _commit_entry(entry: Dictionary) -> void:
	_redo.clear()
	_undo.append(entry)
	_undo_cells += _entry_cells(entry)
	_trim_undo()


func _trim_undo() -> void:
	var cap := maxi(0, undo_capacity)
	while _undo.size() > cap:
		_undo_cells -= _entry_cells(_undo[0])
		_undo.pop_front()
	var budget := maxi(0, undo_cells_budget)
	while _undo_cells > budget and _undo.size() > 1:
		_undo_cells -= _entry_cells(_undo[0])
		_undo.pop_front()


# ── 内部:层访问 ────────────────────────────────────────────────────────────

# 读 active_layer 的存储数组(tex→desc / color→rgba);层缺席或非法返回 null。
func _read_array(layer: int) -> Variant:
	var layers: Array = map.get("layers", [])
	if layer < 0 or layer >= layers.size():
		return null
	var ld = layers[layer]
	if not (ld is Dictionary):
		return null
	var d: Dictionary = ld
	if String(d.get("kind", "")) == "tex":
		return d.get("desc", null)
	return d.get("rgba", null)


# undo/redo 的写目标:颜色层若被外部清成 null 则按需重建;纹理层缺席返回 null。
func _write_target(layer: int) -> Variant:
	var store_v: Variant = _read_array(layer)
	if store_v != null:
		return store_v
	if not EditorConstants.is_color_layer(layer):
		return null
	return _ensure_color_layer(layer)


# 只对颜色层按需建层;建层 = 结构变化,发 structure_changed。
func _ensure_color_layer(layer: int) -> Variant:
	if not EditorConstants.is_color_layer(layer):
		return null
	var sz := sub_size()
	if sz.x <= 0 or sz.y <= 0:
		return null
	var created: Variant = EditorMap.ensure_layer(map, layer)
	if created == null:
		return null
	structure_changed.emit()
	var d: Dictionary = created
	return d.get("rgba", null)


func _store_write_back(layer: int, store: PackedInt32Array) -> void:
	var layers: Array = map.get("layers", [])
	if layer < 0 or layer >= layers.size():
		return
	var ld = layers[layer]
	if not (ld is Dictionary):
		return
	var d: Dictionary = ld
	if String(d.get("kind", "")) == "tex":
		d["desc"] = store
	else:
		d["rgba"] = store


# u32 → PackedInt32Array 里存的有符号 32 位(0xFF000000 存 -16777216 是正常的)。
static func _to_i32(v: int) -> int:
	var u := v & 0xFFFFFFFF
	if u >= 0x80000000:
		return u - 0x100000000
	return u


static func _filled(n: int, v: int) -> PackedInt32Array:
	var a := PackedInt32Array()
	a.resize(n)
	a.fill(v)
	return a


# ── 内部:选区 / 历史条目 / meta 辅助 ───────────────────────────────────────

# 当前选区的防御性裁剪(w/h<=0 或地图尺寸变了 ⇒ 空矩形)。
func _clipped_selection() -> Rect2i:
	if not has_selection():
		return Rect2i()
	var sz := sub_size()
	var x0 := maxi(0, selection.position.x)
	var y0 := maxi(0, selection.position.y)
	var x1 := mini(sz.x, selection.position.x + selection.size.x)
	var y1 := mini(sz.y, selection.position.y + selection.size.y)
	if x1 <= x0 or y1 <= y0:
		return Rect2i()
	return Rect2i(x0, y0, x1 - x0, y1 - y0)


# meta 条目没有 idxs ⇒ 计入撤销栈 cells 预算的格数 = 0。
static func _entry_cells(entry: Dictionary) -> int:
	if String(entry.get("kind", "")) == "meta":
		return 0
	var idxs_v: Variant = entry.get("idxs", null)
	if idxs_v is PackedInt32Array:
		return (idxs_v as PackedInt32Array).size()
	return 0


static func _is_meta_entry(entry: Dictionary) -> bool:
	return String(entry.get("kind", "")) == "meta"


# 失败形状唯一(契约 §0):不抛错、不 push_error。
static func _fail(msg: String) -> Dictionary:
	return {"ok": false, "error": msg}


# 格坐标可写入(地图至少 1×1 格)。0 尺寸地图上 meta 编辑返回 -1/false。
func _meta_ready() -> bool:
	var sz := sub_size()
	return sz.x >= EditorConstants.SUB_PER_CELL and sz.y >= EditorConstants.SUB_PER_CELL


# 格坐标环面归一化(调用方已保证 _meta_ready)。
func _wrap_cell(cell: Vector2i) -> Vector2i:
	var sz := sub_size()
	var cw := sz.x / EditorConstants.SUB_PER_CELL
	var ch := sz.y / EditorConstants.SUB_PER_CELL
	if cw <= 0 or ch <= 0:
		return Vector2i.ZERO
	return Vector2i(posmod(cell.x, cw), posmod(cell.y, ch))


# 改动前后各拍一份深拷贝;无差异 ⇒ 不入栈、不发信号、返回 false。
func _commit_meta_change(before: Dictionary) -> bool:
	var after := meta_snapshot()
	if JSON.stringify(before) == JSON.stringify(after):
		return false
	_commit_entry({"kind": "meta", "before": before, "after": after})
	dirty = true
	meta_changed.emit()
	return true


# 从快照装回 map(逐项深拷贝:map 与历史条目绝不共用数组/字典)。
func _apply_meta_snapshot(snap: Dictionary) -> void:
	map["players"] = _copy_meta_entries(snap.get("players", []), "player")
	map["respawns"] = _copy_meta_entries(snap.get("respawns", []), "respawn")
	map["enemies"] = _copy_meta_entries(snap.get("enemies", []), "enemy")


# meta 三张表的深拷贝;kind = "player" / "respawn" / "enemy"(其它按 respawn 处理)。
static func _copy_meta_entries(list: Variant, kind: String) -> Array:
	var out: Array = []
	if not (list is Array):
		return out
	for it in list:
		if not (it is Dictionary):
			continue
		var d: Dictionary = it
		match kind:
			"player":
				out.append({"x": int(d.get("x", 0)), "y": int(d.get("y", 0))})
			"enemy":
				out.append({"type": String(d.get("type", "")), "x": int(d.get("x", 0)),
						"y": int(d.get("y", 0))})
			_:
				out.append({"side": int(d.get("side", 0)), "x": int(d.get("x", 0)),
						"y": int(d.get("y", 0))})
	return out
